"""USB Entware installation; private state never belongs in the repository."""
import argparse
import base64
import copy
import getpass
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

APP = Path('/opt/share/zapret-gui')
SETTINGS = Path('/opt/etc/zapret-gui/settings.json')
CONFIG = Path('/opt/etc/mihomo/home-tun.yaml')
GUI_INIT = Path('/opt/etc/init.d/S99zapret-gui')
CORE_INIT = Path('/opt/etc/init.d/S53mihomo-gui')
CORE = Path('/opt/usr/sbin/mihomo')
BACKUPS = Path('/opt/var/backups/keenetic-tun')
OWNED = [APP, SETTINGS.parent, CONFIG.parent, CORE, GUI_INIT, CORE_INIT,
         Path('/opt/etc/ndm/netfilter.d/101-zapret-gui-routing.sh')]
ROUTE_ID = 'installer-home-lan'


def write_private(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.new')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(text)
    os.replace(tmp, path)
    path.chmod(0o600)


def default_config(cidr):
    cidr = str(ipaddress.ip_network(cidr, strict=False))
    return {
        'mode': 'rule', 'log-level': 'info', 'ipv6': False,
        'mixed-port': 17890, 'bind-address': '127.0.0.1', 'allow-lan': False,
        'external-controller': '127.0.0.1:9090', 'secret': secrets.token_hex(32),
        'profile': {'store-selected': True},
        'tun': {'enable': True, 'device': 'mihomo-tun', 'stack': 'gvisor', 'mtu': 1400,
                'auto-route': False, 'auto-redirect': False, 'auto-detect-interface': True,
                'dns-hijack': ['any:53', 'tcp://any:53']},
        'dns': {'enable': True, 'listen': '127.0.0.1:1053', 'ipv6': False,
                'enhanced-mode': 'redir-host', 'respect-rules': True,
                'default-nameserver': ['system'], 'proxy-server-nameserver': ['system'],
                'nameserver': ['https://8.8.8.8/dns-query#PROXY', 'https://9.9.9.9/dns-query#PROXY']},
        'proxies': [], 'proxy-groups': [{'name': 'PROXY', 'type': 'select', 'proxies': ['REJECT']}],
        'rules': ['IP-CIDR,' + cidr + ',DIRECT,no-resolve', 'MATCH,PROXY'],
    }


def lan_address():
    text = subprocess.check_output(['ip', '-o', '-4', 'addr', 'show', 'dev', 'br0'], text=True)
    match = re.search(r'\binet\s+([0-9.]+/\d+)', text)
    if not match:
        raise RuntimeError('Не найден IPv4 LAN-интерфейса br0.')
    address = ipaddress.ip_interface(match.group(1))
    return str(address.ip), str(address.network)


def ask(message, default=''):
    value = input(message + (f' [{default}]' if default else '') + ': ').strip()
    return value or default


def inputs():
    # No unattended defaults for subscription/password; EOF means no authorization.
    if not sys.stdin.isatty():
        raise RuntimeError('Запустите сохранённый скрипт в интерактивном SSH, без pipe в sh.')
    host, cidr = lan_address()
    existing = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
    gui = existing.get('gui', {})
    password = gui.get('auth_password') if gui.get('auth_enabled') else ''
    if not password:
        while True:
            password = getpass.getpass('Придумайте пароль веб-панели (минимум 8 символов): ')
            if len(password) >= 8 and password == getpass.getpass('Повторите пароль: '):
                break
            print('Пароли должны совпадать и содержать минимум 8 символов.')
    saved_url = existing.get('mihomo_subscription', {}).get('url', '')
    while True:
        url = getpass.getpass('HTTPS URL подписки' + (' (Enter — оставить сохранённый)' if saved_url else '') + ': ').strip() or saved_url
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme == 'https' and parsed.hostname:
            break
        print('Введите HTTPS-ссылку подписки.')
    whole_lan = False
    if not CONFIG.exists():
        whole_lan = ask(f'Направить всю сеть {cidr} через TUN? да / нет (устройства позже в панели)', 'да').lower() in ('да', 'yes', 'y')
    else:
        print('Повторная установка: DNS, маршруты, устройства и пароль будут сохранены.')
    return dict(host=host, cidr=cidr, password=password, user=gui.get('auth_user', 'admin'),
                port=int(gui.get('port', 8080)), url=url, whole_lan=whole_lan)


def api(host, port, user, password, path, data=None, method=None, timeout=70):
    credentials = base64.b64encode((user + ':' + password).encode()).decode()
    req = urllib.request.Request(f'http://{host}:{port}' + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Authorization': 'Basic ' + credentials, 'Content-Type': 'application/json'}, method=method)
    # Local panel requests must never follow system proxy environment variables.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as response:
            result = json.load(response)
    except urllib.error.HTTPError:
        raise RuntimeError('Панель отклонила запрос ' + path) from None
    if result.get('ok') is False:
        raise RuntimeError(result.get('error', 'Ошибка API панели'))
    return result


def service(path, action, required=False):
    if path.exists():
        result = subprocess.run(['sh', str(path), action], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if required and result.returncode:
            raise RuntimeError(f'Не запустился {path.name}. Подробности: /tmp/zapret-gui-server.log')


def backup():
    folder = BACKUPS / (time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3))
    folder.mkdir(parents=True, mode=0o700)
    manifest = []
    for i, path in enumerate(OWNED):
        manifest.append({'path': str(path), 'exists': path.exists()})
        if path.is_dir():
            shutil.copytree(path, folder / str(i), symlinks=True)
        elif path.exists():
            shutil.copy2(path, folder / str(i))
    write_private(folder / 'manifest.json', json.dumps(manifest))
    return folder


def remove_owned(path):
    if path not in OWNED:
        raise RuntimeError('Отказ удаления пути вне списка установки.')
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def restore(folder):
    folder = folder.resolve()
    if folder.parent != BACKUPS.resolve():
        raise RuntimeError('Резервная копия должна находиться в ' + str(BACKUPS))
    manifest = json.loads((folder / 'manifest.json').read_text())
    if [item['path'] for item in manifest] != [str(p) for p in OWNED]:
        raise RuntimeError('Неверный список файлов резервной копии.')
    for i, item in enumerate(manifest):
        if item['exists'] and not (folder / str(i)).exists():
            raise RuntimeError('Неполная резервная копия.')
    service(GUI_INIT, 'stop')
    service(CORE_INIT, 'stop')
    for i, item in enumerate(manifest):
        path = Path(item['path'])
        remove_owned(path)
        if item['exists']:
            src = folder / str(i)
            path.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir():
                shutil.copytree(src, path, symlinks=True)
            else:
                shutil.copy2(src, path)
    service(CORE_INIT, 'start')
    service(GUI_INIT, 'start')
    print('Файлы восстановлены. Пакеты Entware, установленные через opkg, оставлены.')


def deps(source):
    # Bottle is vendored by upstream, but Entware splits its stdlib dependencies.
    for _ in range(20):
        result = subprocess.run([sys.executable, '-c',
            'import sys; sys.path.insert(0, sys.argv[1]); import bottle', str(source / 'vendor')], capture_output=True, text=True)
        if result.returncode == 0:
            return
        match = re.search(r"No module named '([^']+)'", result.stderr)
        if not match:
            raise RuntimeError('Не импортируется встроенный Bottle.')
        name = match.group(1).split('.')[0]
        pkg = {'unicodedata': 'python3-codecs', 'email': 'python3-email', 'ssl': 'python3-openssl',
               '_hashlib': 'python3-openssl'}.get(name, 'python3-' + name)
        subprocess.run(['opkg', 'install', pkg], check=True)
    raise RuntimeError('Не удалось установить зависимости Bottle.')


def select_server(cfg):
    """Find one usable outbound before applying the LAN route; preserve working choice."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    endpoint = 'http://127.0.0.1:9090'
    headers = {'Authorization': 'Bearer ' + cfg['secret'], 'Content-Type': 'application/json'}

    def core_api(path, data=None):
        req = urllib.request.Request(endpoint + path, headers=headers,
            data=json.dumps(data).encode() if data is not None else None,
            method='PUT' if data is not None else 'GET')
        with opener.open(req, timeout=6) as response:
            body = response.read()
            return json.loads(body) if body else {}

    current = core_api('/proxies/PROXY').get('now')
    names = [p['name'] for p in cfg['proxies']]
    if current in names:
        names.remove(current)
        names.insert(0, current)
    query = urllib.parse.urlencode({'url': 'https://www.gstatic.com/generate_204', 'timeout': 3000})
    for index, name in enumerate(names, 1):
        print(f'Проверка сервера {index}/{len(names)}…', flush=True)
        try:
            result = core_api('/proxies/' + urllib.parse.quote(name, safe='') + '/delay?' + query)
            if result.get('delay', 0) > 0:
                core_api('/proxies/PROXY', {'name': name})
                print('Выбран доступный сервер: ' + name)
                return name
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            continue
    raise RuntimeError('Ни один сервер не прошёл HTTPS-проверку. Маршрут всей сети не включён.')


def verify_route_result(result):
    applied = result.get('applied')
    if not isinstance(applied, dict) or not applied.get('ok'):
        raise RuntimeError('Панель сохранила маршрут, но не смогла его применить.')


def install(stage):
    opts = inputs()
    saved = backup()
    print('Резервная копия: ' + str(saved), flush=True)
    route_added = False
    call = lambda path, data=None, method=None: api(opts['host'], opts['port'], opts['user'], opts['password'], path, data, method)
    try:
        service(GUI_INIT, 'stop')
        service(CORE_INIT, 'stop')
        source = stage / 'upstream'
        # Keep user strategies/lists; replace upstream source files with the pinned snapshot.
        APP.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / 'app.py', APP / 'app.py')
        for name in ('api', 'core', 'web', 'vendor', 'catalogs', 'data', 'config', 'tests'):
            if (source / name).exists():
                shutil.copytree(source / name, APP / name, dirs_exist_ok=True)
        for name in ('api/mihomo.py', 'api/mihomo_subscription.py', 'web/js/pages/mihomo.js', 'core/mihomo_autostart.py'):
            shutil.copy2(stage / name, APP / name)
        for root, dirs, files in os.walk(APP):
            if '__pycache__' in dirs:
                shutil.rmtree(Path(root) / '__pycache__')
                dirs.remove('__pycache__')
        CORE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(stage / 'mihomo', CORE)
        CORE.chmod(0o755)
        sys.path.insert(0, str(APP))
        from core.config_manager import DEFAULT_CONFIG
        settings = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else copy.deepcopy(DEFAULT_CONFIG)
        settings.setdefault('gui', {}).update(host=opts['host'], port=opts['port'], auth_enabled=True,
                auth_user=opts['user'], auth_password=opts['password'])
        # Native GUI updates would overwrite the local subscription/autostart extension.
        settings.setdefault('update_checker', {})['enabled'] = False
        write_private(SETTINGS, json.dumps(settings, ensure_ascii=False, indent=2))
        write_private(SETTINGS.parent / 'server.conf', f"GUI_HOST={opts['host']}\nGUI_PORT={opts['port']}\numask 077\n")
        if not CONFIG.exists():
            write_private(CONFIG, json.dumps(default_config(opts['cidr']), ensure_ascii=False, indent=2))
        shutil.copy2(stage / 'panel-service.sh', GUI_INIT)
        GUI_INIT.chmod(0o755)
        service(GUI_INIT, 'start', required=True)
        for _ in range(30):
            try:
                call('/api/mihomo/home-subscription')
                break
            except (OSError, RuntimeError, ValueError):
                time.sleep(1)
        else:
            raise RuntimeError('Панель не отвечает после запуска.')
        imported = call('/api/mihomo/home-subscription', {'url': opts['url']})
        print(f"Импортировано серверов: {imported['servers']}; пропущено: {imported['skipped']}")
        for warning in imported.get('warnings', []):
            print(warning)
        call('/api/mihomo/configs/home-tun/up', {})
        call('/api/mihomo/autostart/home-tun', {'enabled': True})
        import yaml
        cfg = yaml.safe_load(CONFIG.read_text())
        select_server(cfg)
        if opts['whole_lan']:
            # Remember intent before HTTP request: a lost response may still have saved the route.
            route_added = True
            result = call('/api/unified/routes', {
                'id': ROUTE_ID, 'name': 'Вся домашняя сеть через TUN', 'method': 'mihomo:mihomo-tun',
                'enabled': True, 'monitor_enabled': False, 'failover_enabled': False,
                'devices': [{'ip': opts['cidr']}],
            })
            verify_route_result(result)
        subprocess.run(['ip', 'link', 'show', 'mihomo-tun'], check=True, stdout=subprocess.DEVNULL)
        status = call('/api/mihomo/configs/home-tun/status')
        if not status.get('status', {}).get('active'):
            raise RuntimeError('Ядро остановилось после запуска.')
        # Make the overlay recoverable locally as well as in Git.
        write_private(SETTINGS.parent / 'keenetic-tun-version.json', json.dumps({
            'upstream_commit': 'bcffb595af46bac72727c8a5b05ea82635b58efa', 'mihomo': 'v1.19.32', 'addon': 1}))
        print(f"\nГотово: http://{opts['host']}:{opts['port']}/#mihomo\nЛогин: {opts['user']}\nПароль: введённый вами / ранее сохранённый")
        print('Устройства: Маршрутизация → маршрут → Устройства. DNS: Mihomo → Инстансы → home-tun → Редактировать.')
        print('IPv4 TUN готов. IPv6 и DNS клиентов, обращающихся к самому роутеру, требуют отдельной настройки.')
        print('Восстановление: sh /tmp/keenetic-tun-install.sh --restore ' + str(saved))
    except BaseException:
        if route_added:
            try:
                call('/api/unified/routes/' + ROUTE_ID, method='DELETE')
            except Exception:
                print('Не удалось убрать новый маршрут через API; проверьте таблицу 233 после восстановления.', file=sys.stderr)
        print('Установка не завершилась; восстанавливаю прежние файлы…', file=sys.stderr)
        restore(saved)
        raise


def check():
    import yaml
    cfg = yaml.safe_load(CONFIG.read_text())
    subprocess.run([str(CORE), '-t', '-d', str(CONFIG.parent), '-f', str(CONFIG)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['ip', 'link', 'show', 'mihomo-tun'], check=True)
    subprocess.run(['ip', 'rule', 'show'], check=True)
    subprocess.run(['ip', 'route', 'show', 'table', '233'], check=True)
    print('DNS: ' + ', '.join(cfg.get('dns', {}).get('nameserver', [])))
    print('Серверов: ' + str(len(cfg.get('proxies', []))))
    print('Конфигурация валидна; это не проверка доступности каждого сервера или корпоративного VPN.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--install', type=Path)
    parser.add_argument('--restore', type=Path)
    parser.add_argument('--deps', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        if args.install:
            install(args.install)
        elif args.restore:
            restore(args.restore)
        elif args.deps:
            deps(args.deps)
        elif args.check:
            check()
        else:
            parser.error('Укажите режим работы.')
    except Exception as exc:
        # Exception may contain provider credentials; don't print raw URLs or tracebacks.
        message = re.sub(r'https?://\S+', '[URL скрыт]', str(exc))
        print('Ошибка: ' + message, file=sys.stderr)
        sys.exit(1)
