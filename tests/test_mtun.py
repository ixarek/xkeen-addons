"""Native Mihomo provider/API integration plus isolated routing checks.

MIHOMO_BIN points to the pinned upstream executable. No real router or TUN
interface is changed by these tests. Uses only Python's standard library.
"""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

from test_setup import BASH, JQ, REPO, posix

CORE = os.environ.get("MIHOMO_BIN")


@unittest.skipUnless(BASH and JQ, "bash and jq required")
class TunScripts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mtun-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write(self.bin / "jq", '#!/bin/sh\nexec "$TEST_JQ" "$@"\n')
        self.env = dict(os.environ, TEST_JQ=posix(JQ), TEST_BIN=posix(self.bin),
                        TEST_TRACE=posix(self.root / "trace"))

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def shell(self, code, *args):
        source = (REPO / "scripts/mtun-lib.sh").read_text()
        source += '\nPATH="$TEST_BIN:/usr/bin:/bin"\n' + code
        path = self.root / "test.sh"
        self.write(path, source)
        return subprocess.run([BASH, posix(path), *args], env=self.env,
                              capture_output=True, encoding="utf-8", timeout=30)

    def config(self):
        result = self.shell('mt_generate "$1" "$2" true', "192.168.1.1", "test-secret")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_config_has_native_tun_and_no_direct_fallback(self):
        config = self.config()
        self.assertTrue(config["tun"]["enable"])
        self.assertFalse(config["tun"]["auto-route"])
        self.assertFalse(config["tun"]["auto-redirect"])
        self.assertEqual(config["rules"], ["MATCH,PROXY"])
        self.assertNotIn("DIRECT", config["proxy-groups"][0].get("proxies", []))
        self.assertEqual(config["dns"]["enhanced-mode"], "redir-host")
        self.assertTrue(all(x.endswith("#PROXY") for x in config["dns"]["nameserver"]))
        self.assertEqual(config["external-controller"], "192.168.1.1:9090")

    def test_client_validation_rejects_injection_and_invalid_addresses(self):
        for ip, mac, valid in [
            ("192.168.1.20", "aa:bb:cc:dd:ee:ff", True),
            ("192.168.1.300", "aa:bb:cc:dd:ee:ff", False),
            ("192.168.1.020", "aa:bb:cc:dd:ee:ff", False),
            ("127.0.0.1", "aa:bb:cc:dd:ee:ff", False),
            ("192.168.1.20;id", "aa:bb:cc:dd:ee:ff", False),
            ("192.168.1.20", "$(id)", False),
        ]:
            with self.subTest(ip=ip, mac=mac):
                path = self.root / "clients"
                self.write(path, f"{ip} {mac}\n")
                result = self.shell('mt_validate_clients "$1"', posix(path))
                self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_routes_and_dns_are_limited_to_selected_client(self):
        self.write(self.bin / "ip", '''#!/bin/sh
printf 'ip %s\n' "$*" >> "$TEST_TRACE"
case "$*" in
 '-4 rule del '*) exit 2;;
 '-4 route show table main scope link')
 echo '192.168.1.0/24 dev br0 proto kernel scope link src 192.168.1.1'
 echo '203.0.113.0/24 dev eth3 proto kernel scope link src 203.0.113.10';;
esac
''')
        for name in ("iptables", "ip6tables"):
            self.write(self.bin / name, '''#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$TEST_TRACE"
case " $* " in *' -C '*) exit 1;; esac
''')
        home = self.root / "home"
        run = self.root / "run"
        run.mkdir()
        self.write(home / "clients", "192.168.1.20 aa:bb:cc:dd:ee:ff\n")
        self.write(home / "config.json", json.dumps(self.config()))
        result = self.shell('MT_HOME=$1; MT_RUN=$2; mt_guard_routes; mt_firewall', posix(home), posix(run))
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = (self.root / "trace").read_text()
        self.assertIn("unreachable default metric 32760 table 2023", trace)
        self.assertIn("rule add pref 100 from 192.168.1.20/32 table 2023", trace)
        self.assertIn("route replace 192.168.1.0/24 dev br0 table 2023", trace)
        self.assertNotIn("route replace 203.0.113.0/24", trace)
        self.assertIn("-s 192.168.1.20 -p udp --dport 53 -j DNAT", trace)
        self.assertIn("-s 192.168.1.20 -j REJECT", trace)

    def test_embedded_scripts_match(self):
        import re
        installer = (REPO / "install-mihomo-tun.sh").read_text()
        for name, target in [("mtun-lib.sh", "/opt/lib/mtun-lib.sh"),
                             ("mtun", "/opt/sbin/mtun"),
                             ("S80mihomo-tun", "/opt/etc/init.d/S80mihomo-tun")]:
            match = re.search(r"base64 -d > " + re.escape(target) +
                              r" <<'TUN_PAYLOAD_END'\n(.*?)\nTUN_PAYLOAD_END", installer, re.S)
            self.assertIsNotNone(match)
            self.assertEqual(base64.b64decode(match[1]).decode(), (REPO / "scripts" / name).read_text())

    def test_check_mode_does_not_install_or_write_configuration(self):
        opt = self.root / "opt"
        (opt / "etc").mkdir(parents=True)
        self.write(self.root / "meminfo", "MemAvailable: 400000 kB\n")
        for name, source in {
            "id": "echo 0",
            "uname": "echo aarch64",
            "df": "printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/sda1 1000000 10000 990000 1%% /opt\\n'",
            "ndmc": "exit 99",
            "opkg": 'echo MUTATION >> "$TEST_TRACE"; exit 99',
            "ip": "exit 0",
            "iptables": "exit 0",
        }.items():
            self.write(self.bin / name, "#!/bin/sh\n" + source + "\n")
        source = (REPO / "install-mihomo-tun.sh").read_text()
        source = source.replace("/opt/", posix(opt) + "/")
        source = source.replace("/proc/meminfo", posix(self.root / "meminfo"))
        source = source.replace("export PATH", 'PATH="$TEST_BIN:/usr/bin:/bin"; export PATH', 1)
        path = self.root / "check.sh"
        self.write(path, source)
        result = subprocess.run([BASH, posix(path), "--check"], env=self.env,
                                capture_output=True, encoding="utf-8", timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No changes made", result.stdout)
        self.assertFalse((self.root / "trace").exists())
        self.assertEqual(list((opt / "etc").iterdir()), [])

    def test_shutdown_preserves_autostart_but_explicit_disable_removes_it(self):
        home, run = self.root / "home", self.root / "run"
        self.write(home / "enabled", "")
        library = self.root / "service-lib.sh"
        self.write(library, 'MT_HOME="$1"\nMT_RUN="$2"\n'
                   'mt_pid() { return 1; }\nmt_clear() { :; }\n')
        source = (REPO / "scripts/S80mihomo-tun").read_text()
        # The service receives command as $1. Fixture paths are environment values.
        self.write(library, 'MT_HOME="$TEST_HOME"\nMT_RUN="$TEST_RUN"\n'
                   'mt_pid() { return 1; }\nmt_clear() { :; }\n')
        source = source.replace(". /opt/lib/mtun-lib.sh", '. "$TEST_LIBRARY"')
        script = self.root / "service.sh"
        self.write(script, source)
        env = dict(self.env, TEST_HOME=posix(home), TEST_RUN=posix(run), TEST_LIBRARY=posix(library))
        for command in ("stop", "disable"):
            result = subprocess.run([BASH, posix(script), command], env=env,
                                    capture_output=True, encoding="utf-8", timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((home / "enabled").exists(), command == "stop")
            self.assertTrue((run / "stopped").exists())
            self.assertFalse((run / "lock").exists())


@unittest.skipUnless(CORE and BASH and JQ, "MIHOMO_BIN, bash and jq required")
class RealMihomo(TunScripts):
    # Keep integration cases separate from the script-only test count.
    test_config_has_native_tun_and_no_direct_fallback = None
    test_client_validation_rejects_injection_and_invalid_addresses = None
    test_routes_and_dns_are_limited_to_selected_client = None
    test_embedded_scripts_match = None
    test_check_mode_does_not_install_or_write_configuration = None
    test_shutdown_preserves_autostart_but_explicit_disable_removes_it = None

    def start(self, body):
        self.write(self.root / "subscription.txt", body)
        config = self.config()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        config.update({"external-controller": f"127.0.0.1:{self.port}", "mixed-port": 0})
        config.pop("external-ui")
        config["dns"]["enable"] = False
        config["tun"]["enable"] = False
        self.write(self.root / "config.json", json.dumps(config))
        self.log = open(self.root / "core.log", "w", encoding="utf-8")
        self.addCleanup(self.log.close)
        self.process = subprocess.Popen([CORE, "-d", str(self.root), "-f", str(self.root / "config.json")],
                                        stdout=self.log, stderr=subprocess.STDOUT,
                                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.addCleanup(self.stop)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                self.request("/version")
                return
            except (OSError, urllib.error.URLError):
                if self.process.poll() is not None:
                    break
                time.sleep(0.1)
        self.fail((self.root / "core.log").read_text())

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=10)

    def request(self, path, method="GET", body=None, auth=True):
        headers = {"Content-Type": "application/json"}
        if auth:
            headers["Authorization"] = "Bearer test-secret"
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}",
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=3) as response:
            raw = response.read()
        return json.loads(raw) if raw else None

    def test_native_base64_import_and_manual_selection(self):
        body = ("vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=grpc&serviceName=test#%D0%A2%D0%B5%D1%81%D1%82\r\n"
                "trojan://fake-password@trojan.example:443?security=tls#Trojan\r\n")
        self.start(base64.b64encode(body.encode()).decode())
        proxies = self.request("/providers/proxies/subscription")["proxies"]
        self.assertEqual(len(proxies), 2, (self.root / "core.log").read_text())
        names = self.request("/proxies/PROXY")["all"]
        self.assertIn("Тест", names)
        self.assertIn("Trojan", names)
        self.request("/proxies/PROXY", "PUT", {"name": "Trojan"})
        self.assertEqual(self.request("/proxies/PROXY")["now"], "Trojan")
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/proxies", auth=False)
        self.assertEqual(error.exception.code, 401)

    def test_yaml_provider_cannot_override_global_configuration(self):
        self.start('mixed-port: 9999\nsecret: attacker\nproxies:\n'
                   '  - name: YAML\n    type: socks5\n    server: 127.0.0.1\n    port: 9999\n')
        self.assertEqual(self.request("/proxies/PROXY")["all"], ["YAML"])
        config = self.request("/configs")
        self.assertEqual(config["mixed-port"], 0)

    def test_production_tun_dns_configuration_parses(self):
        config = self.config()
        self.write(self.root / "subscription.txt", "trojan://fake@example.com:443#Test\n")
        self.write(self.root / "config.json", json.dumps(config))
        result = subprocess.run([CORE, "-t", "-d", str(self.root), "-f", str(self.root / "config.json")],
                                capture_output=True, encoding="utf-8", timeout=15,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_selected_server_survives_core_restart(self):
        self.start("trojan://fake@example.com:443#One\ntrojan://fake@example.com:443#Two\n")
        self.request("/proxies/PROXY", "PUT", {"name": "Two"})
        self.stop()
        self.start((self.root / "subscription.txt").read_text())
        self.assertEqual(self.request("/proxies/PROXY")["now"], "Two")

    @unittest.skipIf(os.name == "nt", "validator process lifecycle uses POSIX signals")
    def test_isolated_validator_rejects_bad_subscription(self):
        self.write(self.root / "config.json", json.dumps(self.config()))
        self.write(self.root / "subscription.txt", "<html>provider error</html>\n")
        result = self.shell('mt_validate_provider "$1" "$2"', posix(self.root), posix(CORE))
        self.assertNotEqual(result.returncode, 0)

    @unittest.skipIf(os.name == "nt", "validator process lifecycle uses POSIX signals")
    def test_isolated_validator_accepts_native_base64(self):
        self.write(self.root / "config.json", json.dumps(self.config()))
        self.write(self.root / "subscription.txt", base64.b64encode(b"trojan://fake@example.com:443#Test\n").decode())
        result = self.shell('mt_validate_provider "$1" "$2"', posix(self.root), posix(CORE))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr + (self.root / "validate.log").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
