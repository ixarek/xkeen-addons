import base64
from contextlib import ExitStack, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from wsgiref.util import setup_testing_defaults

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ['ZAPRET_SOURCE']).resolve()
sys.path[:0] = [str(SOURCE), str(SOURCE / 'vendor')]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


installer = module('installer', ROOT / 'tools/installer.py')
subscription = module('subscription', ROOT / 'addon/api/mihomo_subscription.py')
from bottle import Bottle
from core.clash_yaml import parse_yaml


class ConfigTests(unittest.TestCase):
    def test_network_dns_and_no_global_route(self):
        cfg = installer.default_config('192.168.8.1/24')
        self.assertEqual(cfg['rules'], ['IP-CIDR,192.168.8.0/24,DIRECT,no-resolve', 'MATCH,PROXY'])
        self.assertEqual(cfg['dns']['nameserver'], ['https://8.8.8.8/dns-query#PROXY', 'https://9.9.9.9/dns-query#PROXY'])
        self.assertFalse(cfg['tun']['auto-route'])
        self.assertEqual(cfg['external-controller'], '127.0.0.1:9090')
        self.assertFalse(cfg['allow-lan'])
        self.assertNotEqual(cfg['secret'], installer.default_config('192.168.8.0/24')['secret'])

    def test_failed_apply_is_not_success(self):
        for value in ({'ok': True}, {'ok': True, 'applied': {'ok': False}}, {'ok': True, 'applied': None}):
            with self.assertRaises(RuntimeError):
                installer.verify_route_result(value)
        installer.verify_route_result({'ok': True, 'applied': {'ok': True}})

    def test_restore_rejects_outside_backup_folder(self):
        with self.assertRaises(RuntimeError):
            installer.restore(Path('/tmp/untrusted'))

    def test_private_write_atomic(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'config.json'
            installer.write_private(path, '{"ok":true}')
            self.assertEqual(json.loads(path.read_text()), {'ok': True})
            self.assertFalse(path.with_name('config.json.new').exists())
            if os.name != 'nt':
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_backup_restore(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            owned = [root / 'app', root / 'settings.json', root / 'new-file']
            owned[0].mkdir()
            (owned[0] / 'file').write_text('original')
            owned[1].write_text('private')
            with patch.object(installer, 'OWNED', owned), patch.object(installer, 'BACKUPS', root / 'backups'), patch.object(installer, 'service'):
                saved = installer.backup()
                (owned[0] / 'file').write_text('changed')
                owned[1].unlink()
                owned[2].write_text('created')
                installer.restore(saved)
                self.assertEqual((owned[0] / 'file').read_text(), 'original')
                self.assertEqual(owned[1].read_text(), 'private')
                self.assertFalse(owned[2].exists())

    def test_native_mihomo_validation(self):
        binary = os.environ.get('MIHOMO_BIN')
        if not binary:
            self.skipTest('MIHOMO_BIN not set')
        with tempfile.TemporaryDirectory() as folder:
            cfg = installer.default_config('192.168.4.0/24')
            cfg['proxies'] = [SubscriptionTests.proxy()]
            cfg['proxy-groups'][0]['proxies'] = ['Test']
            path = Path(folder) / 'home.yaml'
            path.write_text(json.dumps(cfg))
            subprocess.run([binary, '-t', '-d', folder, '-f', str(path)], check=True, capture_output=True)


class SubscriptionTests(unittest.TestCase):
    @staticmethod
    def proxy():
        return {'name': 'Test', 'type': 'trojan', 'server': 'example.com', 'port': 443, 'password': 'test-only'}

    def setUp(self):
        self.app = Bottle()
        subscription.register(self.app)
        self.old = installer.default_config('192.168.4.0/24')
        self.old['dns']['nameserver'] = ['https://9.9.9.9/dns-query#PROXY']
        self.text = json.dumps(self.old)
        self.saves = []
        self.restarts = []
        self.valid = True
        self.fail_restart = False
        self.url_saved = []
        outer = self

        class Manager:
            def get_config(self, name): return {'ok': True, 'text': outer.text}
            def validate_via_binary(self, name, text): return {'ok': outer.valid}
            def is_running(self, name): return True
            def save_config(self, name, text):
                outer.saves.append(text)
                outer.text = text
                return {'ok': True}
            def restart(self, name):
                outer.restarts.append(name)
                return {'ok': not outer.fail_restart or len(outer.restarts) > 1}

        class Settings:
            def get(self, *args, **kwargs): return 'https://example.com/test-subscription'
            def set(self, *args): outer.url_saved.append(args)
            def save(self): pass

        self.patches = [
            patch('core.config_manager.get_config_manager', return_value=Settings()),
            patch('core.mihomo_manager.get_mihomo_manager', return_value=Manager()),
            patch('core.subscription_importer.fetch_subscription', return_value=json.dumps({'proxies': [self.proxy()]})),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def post(self, payload=None):
        body = json.dumps(payload or {}).encode()
        env = {}
        setup_testing_defaults(env)
        env.update(REQUEST_METHOD='POST', PATH_INFO='/api/mihomo/home-subscription',
            CONTENT_TYPE='application/json', CONTENT_LENGTH=str(len(body)))
        env['wsgi.input'] = io.BytesIO(body)
        response = b''.join(self.app(env, lambda status, headers, exc_info=None: None))
        return json.loads(response)

    def test_preserve_tun_dns_rules(self):
        result = self.post()
        self.assertTrue(result['ok'], result)
        current = parse_yaml(self.text)
        for key in ('dns', 'tun', 'rules', 'secret'):
            self.assertEqual(current[key], self.old[key])
        self.assertEqual(len(current['proxies']), 1)

    def test_reject_invalid_binary_config(self):
        self.valid = False
        self.assertFalse(self.post()['ok'])
        self.assertFalse(self.saves)
        self.assertFalse(self.url_saved)

    def test_rollback_failed_restart(self):
        self.fail_restart = True
        result = self.post()
        self.assertFalse(result['ok'])
        self.assertTrue(result['restored'])
        self.assertEqual(parse_yaml(self.text), self.old)
        self.assertEqual(len(self.restarts), 2)
        self.assertFalse(self.url_saved)

    def test_download_failure_keeps_old(self):
        with patch('core.subscription_importer.fetch_subscription', side_effect=OSError('offline')):
            self.assertFalse(self.post()['ok'])
        self.assertFalse(self.saves)

    def test_internal_or_http_url_rejected(self):
        for url in ('http://example.com/sub', 'https://127.0.0.1/sub', 'https://192.168.4.1/sub'):
            self.assertFalse(self.post({'url': url})['ok'])
        self.assertFalse(self.saves)

    def test_base64_uri_and_russian_name(self):
        uri = 'trojan://test-only@example.com:443?security=tls#' + urllib_quote('Москва тест')
        with patch('core.subscription_importer.fetch_subscription', return_value=base64.b64encode(uri.encode()).decode()):
            result = self.post()
        self.assertTrue(result['ok'], result)
        self.assertEqual(parse_yaml(self.text)['proxies'][0]['name'], 'Москва тест')

    def test_xhttp_mapping(self):
        extra = json.dumps({'xmux': {'maxConcurrency': 4}, 'scMaxConcurrentPosts': 8})
        uri = 'vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls&type=xhttp&path=%2Ftest&extra=' + urllib_quote(extra) + '#Test'
        result = subscription.convert_uri(uri)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['proxy']['network'], 'xhttp')
        self.assertEqual(result['proxy']['xhttp-opts']['reuse-settings']['max-concurrency'], 4)
        self.assertIn('warning', result)


def urllib_quote(value):
    from urllib.parse import quote
    return quote(value, safe='')


class BuildTests(unittest.TestCase):
    def test_payload_integrity_and_no_private_data(self):
        text = (ROOT / 'install.sh').read_text(encoding='utf-8')
        header, data = text.split('__PAYLOAD_BELOW__\n', 1)
        payload = base64.b64decode(data)
        checksum = next(line.split('=', 1)[1] for line in header.splitlines() if line.startswith('PAYLOAD_SHA='))
        self.assertEqual(hashlib.sha256(payload).hexdigest(), checksum)
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
            self.assertEqual(set(archive.getnames()), {'api/mihomo.py', 'api/mihomo_subscription.py', 'core/mihomo_autostart.py', 'web/js/pages/mihomo.js', 'installer.py', 'panel-service.sh'})
            content = b'\n'.join(archive.extractfile(p).read() for p in archive.getmembers())
            self.assertNotIn(b'oversub.cloud', content)
            self.assertNotIn(b'keenetic\r', content)

    def test_reproducible_build(self):
        before = (ROOT / 'install.sh').read_bytes()
        subprocess.run([sys.executable, str(ROOT / 'tools/build.py')], check=True)
        self.assertEqual(before, (ROOT / 'install.sh').read_bytes())


class LifecycleTests(unittest.TestCase):
    def test_install_and_failed_route_rollback(self):
        # Exercise all filesystem mutations, backup and rollback in an isolated root.
        # No real service/network/firewall commands run here.
        for fail_route in (False, True):
            with self.subTest(fail_route=fail_route), tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
                root = Path(folder)
                names = {'APP': 'app', 'SETTINGS': 'settings/settings.json', 'CONFIG': 'mihomo/home-tun.yaml',
                         'CORE': 'bin/mihomo', 'GUI_INIT': 'init/S99gui', 'CORE_INIT': 'init/S53core'}
                paths = {k: root / v for k, v in names.items()}
                owned = [paths['APP'], paths['SETTINGS'].parent, paths['CONFIG'].parent,
                         paths['CORE'], paths['GUI_INIT'], paths['CORE_INIT'], root / 'hook.sh']
                for k, p in paths.items():
                    stack.enter_context(patch.object(installer, k, p))
                stack.enter_context(patch.object(installer, 'OWNED', owned))
                stack.enter_context(patch.object(installer, 'BACKUPS', root / 'backups'))
                paths['APP'].mkdir()
                (paths['APP'] / 'original').write_text('keep')
                paths['GUI_INIT'].parent.mkdir()
                stage = root / 'stage'
                (stage / 'upstream').mkdir(parents=True)
                (stage / 'upstream/app.py').write_text('# fake upstream')
                for name in ('api/mihomo.py', 'api/mihomo_subscription.py', 'web/js/pages/mihomo.js', 'core/mihomo_autostart.py'):
                    (stage / name).parent.mkdir(parents=True, exist_ok=True)
                    (paths['APP'] / name).parent.mkdir(parents=True, exist_ok=True)
                    (stage / name).write_text('# fake extension')
                (stage / 'mihomo').write_text('fake binary')
                (stage / 'panel-service.sh').write_text('# fake init')
                opts = dict(host='192.168.4.1', cidr='192.168.4.0/24', user='admin',
                            password='test-only-password', port=8080, url='https://example.com/sub', whole_lan=True)
                calls = []

                def fake_api(host, port, user, password, path, data=None, method=None):
                    calls.append((path, method))
                    if path.endswith('/home-subscription') and data:
                        return {'ok': True, 'servers': 1, 'skipped': 0}
                    if path == '/api/unified/routes':
                        return {'ok': True, 'applied': {'ok': not fail_route}}
                    if path.endswith('/status'):
                        return {'ok': True, 'status': {'active': True}}
                    return {'ok': True}

                stack.enter_context(patch.object(installer, 'inputs', return_value=opts))
                stack.enter_context(patch.object(installer, 'api', side_effect=fake_api))
                stack.enter_context(patch.object(installer, 'service'))
                stack.enter_context(patch.object(installer, 'select_server', return_value='Test'))
                stack.enter_context(patch.object(installer.subprocess, 'run'))
                stack.enter_context(redirect_stdout(io.StringIO()))
                if fail_route:
                    with self.assertRaises(RuntimeError):
                        installer.install(stage)
                    self.assertFalse(paths['CONFIG'].exists())
                    self.assertFalse(paths['SETTINGS'].exists())
                    self.assertEqual((paths['APP'] / 'original').read_text(), 'keep')
                    self.assertIn(('/api/unified/routes/' + installer.ROUTE_ID, 'DELETE'), calls)
                else:
                    installer.install(stage)
                    cfg = parse_yaml(paths['CONFIG'].read_text())
                    self.assertEqual(cfg['dns']['nameserver'], installer.default_config(opts['cidr'])['dns']['nameserver'])
                    settings = json.loads(paths['SETTINGS'].read_text())
                    self.assertTrue(settings['gui']['auth_enabled'])
                    self.assertEqual(settings['gui']['host'], opts['host'])


if __name__ == '__main__':
    unittest.main()
