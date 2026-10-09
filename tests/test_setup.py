"""Offline tests: real shell/jq, isolated files, fake downloads and proxy core.

Run: python tests/test_setup.py
On Windows set BASH_BIN and JQ_BIN to Git Bash and an official jq executable.
These tests do not install packages or change the router.
"""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")
JQ = os.environ.get("JQ_BIN") or shutil.which("jq")


def posix(path):
    value = str(Path(path).resolve()).replace("\\", "/")
    if re.match(r"^[A-Za-z]:", value):
        value = "/" + value[0].lower() + value[2:]
    return value


@unittest.skipUnless(BASH and JQ, "bash and jq are required")
class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xkeen-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.opt = self.root / "opt"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, JQ_BIN=posix(JQ))
        self.env["PATH"] = posix(self.bin) + ":/usr/bin:/bin"
        self.env["TEST_BODY"] = posix(self.root / "body")
        self.env["TEST_TRACE"] = posix(self.root / "trace")
        self.env["TEST_SELECTED"] = posix(self.root / "selected")
        self.write(self.bin / "jq", '#!/bin/sh\nexec "$JQ_BIN" "$@"\n')
        self.write(self.bin / "stty", "#!/bin/sh\nexit 0\n")
        self.write(self.bin / "sync", "#!/bin/sh\nexit 0\n")
        self.write(self.bin / "curl", '''#!/bin/sh
printf 'curl\n' >> "$TEST_TRACE"
[ "${TEST_NETWORK_FAIL:-no}" = no ] || exit 7
case "$*" in
 *socks5h://*) printf '%s' "${TEST_HTTP:-204 0.125000}";;
 *) cat "$TEST_BODY";;
esac
''')
        for directory in ("sbin", "etc/init.d", "etc/xray/configs",
                          "etc/xserver", "etc/xkeen-panel/data",
                          "var/subscription", "tmp/xserver"):
            (self.opt / directory).mkdir(parents=True, exist_ok=True)
        (self.opt / "bin").mkdir()
        self.write(self.opt / "etc/init.d/S99xkeen-panel", '''#!/bin/sh
printf 'panel %s\n' "$1" >> "$TEST_TRACE"
''')
        self.data = self.opt / "etc/xkeen-panel/data/subscription.json"
        self.data.write_text(json.dumps({"servers": [], "active_id": -1}), encoding="utf-8")
        self.write(self.opt / "sbin/xkeen-subscription-watcher", '''#!/bin/sh
while [ "$#" -gt 0 ]; do
 if [ "$1" = --output-dir ]; then dir=$2; shift; fi
 shift
done
printf '%s\n' '{"outbounds":[{"tag":"choice","protocol":"vless","settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]}}]}' > "$dir/04_outbounds.choice.json"
''')
        self.write(self.opt / "sbin/xray", '''#!/bin/sh
case " $* " in *' -test '*) exit 0;; esac
exec sleep 60
''')

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def sandbox(self, text):
        return text.replace("/opt/", posix(self.opt) + "/")

    def command(self, script, *args, stdin="", environment=None):
        path = self.root / "run.sh"
        self.write(path, self.sandbox(script))
        env = dict(self.env, **(environment or {}))
        # Git Bash translates native environment PATH differently; set it inside sh.
        launcher = f'export PATH="{posix(self.bin)}:/usr/bin:/bin"; exec sh "$@"'
        return subprocess.run([BASH, "-c", launcher, "test", posix(path), *args],
                              input=stdin, text=True, capture_output=True,
                              encoding="utf-8", env=env, timeout=30)

    def import_body(self, body, encoded=False):
        if encoded:
            body = base64.b64encode(body.encode()).decode()
        (self.root / "body").write_text(body, encoding="utf-8")
        source = (REPO / "scripts/xsub").read_text(encoding="utf-8")
        return self.command(source, "change", stdin="https://example.com/sub/test\n")

    def test_fresh_base64_import_unicode_ipv6_and_default_port(self):
        body = ("vless://11111111-1111-1111-1111-111111111111@example.com?type=tcp#%D0%A2%D0%B5%D1%81%D1%82\r\n"
                "vless://11111111-1111-1111-1111-111111111111@[2001:db8::1]:8443?type=xhttp#IPv6\r\n"
                "trojan://fake@example.com:443#Excluded\r\n")
        result = self.import_body(body, encoded=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        data = json.loads(self.data.read_text(encoding="utf-8"))
        self.assertEqual(len(data["servers"]), 2)
        self.assertEqual(data["active_id"], -1)
        self.assertEqual(data["servers"][0]["name"], "Тест")
        self.assertEqual(data["servers"][0]["port"], 443)
        self.assertEqual(data["servers"][1]["address"], "2001:db8::1")
        self.assertIn("type=xhttp", data["servers"][1]["raw_uri"])
        self.assertNotIn("https://example.com/sub/test", result.stdout)

    def test_refresh_retains_server_by_uri_when_order_changes(self):
        a = "vless://11111111-1111-1111-1111-111111111111@a.example:443?type=tcp#A"
        b = "vless://11111111-1111-1111-1111-111111111111@b.example:443?type=tcp#B"
        self.assertEqual(self.import_body(a + "\n" + b + "\n").returncode, 0)
        data = json.loads(self.data.read_text())
        data["active_id"] = 1
        data["servers"][1]["active"] = True
        self.data.write_text(json.dumps(data), encoding="utf-8")
        result = self.import_body(b + "\n" + a + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(self.data.read_text())
        self.assertEqual(data["active_id"], 0)
        self.assertEqual(data["servers"][0]["raw_uri"], b)

    def test_bad_subscription_does_not_overwrite_existing_state(self):
        original = self.data.read_bytes()
        result = self.import_body("<html>provider error</html>")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.data.read_bytes(), original)
        self.assertNotIn("panel stop", (self.root / "trace").read_text())

    def test_failed_download_does_not_replace_saved_url(self):
        url_file = self.opt / "etc/xserver/source-url"
        url_file.write_text("https://old.example/sub\n")
        source = (REPO / "scripts/xsub").read_text()
        result = self.command(source, "change", stdin="https://new.example/sub\n",
                              environment={"TEST_NETWORK_FAIL": "yes"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(url_file.read_text(), "https://old.example/sub\n")

    def test_proxy_probe_requires_204(self):
        self.data.write_text(json.dumps({"active_id": -1, "servers": [{
            "id": 0, "name": "Test", "active": False,
            "raw_uri": "vless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp"}]}))
        source = (REPO / "scripts/xserver").read_text()
        for code in ("204", "200", "503"):
            with self.subTest(code=code):
                result = self.command(source, "ping", "1", environment={"TEST_HTTP": code + " 0.125000"})
                self.assertEqual(result.returncode == 0, code == "204", result.stderr)
                self.assertFalse((self.opt / "tmp/xserver-cli.lock").exists())

    def selection(self, active, healthy):
        self.data.write_text(json.dumps({"active_id": active, "servers": [{"id": i} for i in range(3)]}))
        self.write(self.opt / "sbin/xserver", '''#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$TEST_TRACE"
case "$1" in
 ping) case ",${TEST_HEALTHY}," in *",$2,"*) exit 0;; *) exit 1;; esac;;
 use) printf '%s' "$2" > "$TEST_SELECTED";;
esac
''')
        template = (REPO / "tools/full-installer.template.sh").read_text()
        body = template.split("phase 'Initial HTTPS check and server selection'", 1)[1].split("phase 'Final checks'", 1)[0]
        source = ('#!/bin/sh\nset -eu\ndie() { echo "$*" >&2; exit 1; }\n'
                  'data=/opt/etc/xkeen-panel/data/subscription.json\ncount=3\n'
                  'tmp=/opt/tmp/xserver\n' + body)
        return self.command(source, environment={"TEST_HEALTHY": healthy})

    def test_initial_selection_keeps_healthy_previous_server(self):
        result = self.selection(2, "1,3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "selected").read_text(), "3")
        self.assertEqual((self.root / "trace").read_text().splitlines(), ["ping 3", "use 3"])

    def test_initial_selection_skips_failed_servers(self):
        result = self.selection(-1, "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "selected").read_text(), "2")
        self.assertEqual((self.root / "trace").read_text().splitlines(), ["ping 1", "ping 2", "use 2"])

    def test_no_healthy_server_does_not_apply_any(self):
        result = self.selection(-1, "")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "selected").exists())

    def test_embedded_installer_and_scripts_match_sources(self):
        addon = (REPO / "install-xkeen-addons.sh").read_text()
        for name in ("xsub", "xserver", "xsub-guard"):
            match = re.search(r"base64 -d > /opt/sbin/" + re.escape(name) +
                              r" <<'PAYLOAD_END'\n(.*?)\nPAYLOAD_END", addon, re.S)
            self.assertIsNotNone(match, name)
            self.assertEqual(base64.b64decode(match[1]).decode(), (REPO / "scripts" / name).read_text())
        full = (REPO / "install.sh").read_text()
        payload = full.split("<<'ADDONS_END'\n", 1)[1].split("\nADDONS_END", 1)[0]
        self.assertEqual(base64.b64decode(payload).decode(), addon)

    def test_check_mode_on_fresh_entware_makes_no_install_calls(self):
        for name, source in {
            "id": "echo 0",
            "uname": "echo aarch64",
            "df": "printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nflash 100000 30000 70000 30%% /opt\\n'",
            "ndmc": "echo 'ndmc called' >> \"$TEST_TRACE\"",
            "opkg": "echo 'opkg called' >> \"$TEST_TRACE\"; exit 99",
        }.items():
            self.write(self.opt / "bin" / name, "#!/bin/sh\n" + source + "\n")
        (self.opt / "sbin/xray").unlink()
        source = (REPO / "install.sh").read_text()
        result = self.command(source, "--check")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("install pinned 2.1", result.stdout)
        self.assertIn("install pinned v26.9.30", result.stdout)
        self.assertFalse((self.root / "trace").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
