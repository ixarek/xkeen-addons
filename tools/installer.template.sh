#!/bin/sh
# XKeen add-ons for ARM64 Keenetic + Entware; no subscription credentials included.
set -eu
umask 077
mode=install
routing=no
for arg in "$@"; do
 case "$arg" in
  --check) mode=check;;
  --configure-routing) routing=yes;;
  --help) echo 'Usage: sh install-xkeen-addons.sh [--check] [--configure-routing]'; exit 0;;
  *) echo "Unknown option: $arg"; exit 1;;
 esac
done
[ "$(id -u)" = 0 ] || { echo 'Run as root'; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo 'This installer targets ARM64/aarch64 Keenetic only'; exit 1; }
[ -x /opt/sbin/xkeen ] && [ -x /opt/sbin/xray ] || { echo 'Install Entware, XKeen 2.x and Xray first'; exit 1; }
command -v opkg >/dev/null || { echo 'Entware opkg not found'; exit 1; }
available=$(df -Pk /opt | awk 'NR==2 {print $4}')
[ "$available" -ge 32768 ] || { echo 'At least 32 MiB free in /opt required for installation'; exit 1; }
if [ "$mode" = check ]; then
 echo "Prerequisites OK; free space: $available KiB"
 for cmd in curl jq lighttpd xkeen-subscription-watcher; do
  if command -v "$cmd" >/dev/null; then echo "$cmd: installed"; else echo "$cmd: will install"; fi
 done
 echo 'No changes made. ARM64 installer; panel v1.3.0; subscription converter v0.4.0.'
 exit 0
fi
mkdir -p /opt/tmp/xserver /opt/etc/xserver /opt/etc/xkeen-panel/data /opt/var/subscription /opt/var/log
tmp=$(mktemp -d /opt/tmp/xserver/install.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
backup="/opt/etc/xserver/install-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup"
for item in /opt/etc/xkeen-panel /opt/etc/xray/configs /opt/etc/init.d/S99xkeen-panel /opt/etc/init.d/S79xsub-http /opt/sbin/xsub /opt/sbin/xserver /opt/sbin/xsub-guard; do
 [ ! -e "$item" ] || cp -a "$item" "$backup/"
done
missing=''
had_lighttpd_init=no
[ ! -e /opt/etc/init.d/S80lighttpd ] || had_lighttpd_init=yes
for pair in 'curl:curl' 'jq:jq' 'lighttpd:lighttpd'; do
 cmd=${pair%%:*}; package=${pair#*:}
 command -v "$cmd" >/dev/null || missing="$missing $package"
done
if [ -n "$missing" ]; then opkg update; opkg install $missing ca-bundle; fi
# A newly installed stock lighttpd config must not take over the router's port 80.
if [ "$had_lighttpd_init" = no ] && [ -e /opt/etc/init.d/S80lighttpd ]; then chmod -x /opt/etc/init.d/S80lighttpd; fi
fetch() {
 url=$1; file=$2; digest=$3
 curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 180 "$url" -o "$file"
 echo "$digest  $file" | sha256sum -c - >/dev/null
 chmod 755 "$file"
}
if [ ! -x /opt/sbin/xkeen-panel ]; then
 fetch https://github.com/Dearonski/xkeen-panel/releases/download/v1.3.0/xkeen-panel-aarch64 "$tmp/xkeen-panel" 3cb6229e422222f74d9efe55c0f61fe0894e6e9a37656b184457154419d1fc6a
 mv "$tmp/xkeen-panel" /opt/sbin/xkeen-panel
fi
if [ ! -x /opt/sbin/xkeen-subscription-watcher ]; then
 fetch https://github.com/tkukushkin/xkeen-subscription-watcher/releases/download/v0.4.0/xkeen-subscription-watcher-linux-arm64 "$tmp/xkeen-subscription-watcher" 78699ac5ee33f2bd357fc3c2a93f2ca0dcfe2e8698e7a668ea31fddec4abf712
 mv "$tmp/xkeen-subscription-watcher" /opt/sbin/xkeen-subscription-watcher
fi
if [ -f /opt/etc/init.d/S99xkeen-panel ]; then sh /opt/etc/init.d/S99xkeen-panel stop || true; fi
if [ ! -f /opt/etc/xkeen-panel/config.yaml ]; then
 cat > /opt/etc/xkeen-panel/config.yaml <<'CONFIG'
port: 3000
data_dir: /opt/etc/xkeen-panel/data
xkeen_path: /opt/sbin/xkeen
outbounds_file: /opt/etc/xray/configs/04_outbounds.json
check_interval: 120
check_url: https://www.google.com
max_fails: 3
log_file: /opt/var/log/xkeen-panel.log
watchdog_auto_start: false
subscription_refresh_interval: 0
CONFIG
else
 sed -i '/^watchdog_auto_start:/d; /^subscription_refresh_interval:/d' /opt/etc/xkeen-panel/config.yaml
 printf '\nwatchdog_auto_start: false\nsubscription_refresh_interval: 0\n' >> /opt/etc/xkeen-panel/config.yaml
fi
if [ ! -e /opt/etc/xkeen-panel/data/subscription.json ]; then
 printf '%s\n' '{"url":"http://127.0.0.1:18080/vless.txt","servers":[],"active_id":-1}' > /opt/etc/xkeen-panel/data/subscription.json
fi
# Embedded command payloads are decoded below. They contain no user secrets.
__PAYLOADS__

chmod 700 /opt/sbin/xsub /opt/sbin/xserver /opt/sbin/xsub-guard
for script in xsub xserver xsub-guard; do sh -n "/opt/sbin/$script"; done
cat > /opt/etc/init.d/S99xkeen-panel <<'PANEL_INIT'
#!/bin/sh
ENABLED=yes
PROCS="xkeen-panel"
ARGS="-config /opt/etc/xkeen-panel/config.yaml"
DESC="XKeen Panel"
PREARGS=""
case "$1" in
 start|restart) /opt/sbin/xsub-guard recover || exit 1;;
 stop|kill) /opt/sbin/xsub-guard checkpoint;;
esac
. /opt/etc/init.d/rc.func
PANEL_INIT
# Reuse an existing listener. Otherwise create a separate loopback-only HTTP service.
cat > /opt/etc/xserver/lighttpd.conf <<'HTTP_CONFIG'
server.document-root = "/opt/var/subscription"
server.bind = "127.0.0.1"
server.port = 18080
server.pid-file = "/opt/var/run/xsub-http.pid"
mimetype.assign = ( ".txt" => "text/plain" )
HTTP_CONFIG
cat > /opt/etc/init.d/S79xsub-http <<'HTTP_INIT'
#!/bin/sh
case "$1" in
 start)
  mkdir -p /opt/var/run /opt/var/subscription
  /opt/bin/curl -fsS --max-time 2 http://127.0.0.1:18080/vless.txt >/dev/null 2>&1 && exit 0
  # Do not compete with an existing listener, even if its subscription is not ready.
  netstat -lnt 2>/dev/null | grep -q '127.0.0.1:18080 ' && exit 0
  /opt/sbin/lighttpd -f /opt/etc/xserver/lighttpd.conf
  ;;
 stop)
  if [ -s /opt/var/run/xsub-http.pid ]; then
   pid=$(cat /opt/var/run/xsub-http.pid)
   case "$pid" in ''|*[!0-9]*) exit 1;; esac
   if [ -r "/proc/$pid/cmdline" ] && tr '\000' ' ' < "/proc/$pid/cmdline" | grep -q '/opt/etc/xserver/lighttpd.conf'; then kill "$pid"; fi
  fi
  ;;
 restart) "$0" stop; "$0" start;;
 *) echo 'Usage: S79xsub-http start|stop|restart'; exit 1;;
esac
HTTP_INIT
chmod 755 /opt/etc/init.d/S99xkeen-panel /opt/etc/init.d/S79xsub-http
if [ "$routing" = yes ]; then
 cp /opt/etc/xray/configs/05_routing.json "$backup/routing-before.json"
 cat > /opt/etc/xray/configs/05_routing.json.new <<'ROUTING'
{"routing":{"rules":[{"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","::1/128","fc00::/7","fe80::/10"],"outboundTag":"direct"},{"type":"field","inboundTag":["redirect","tproxy","force-proxy-redirect","force-proxy-tproxy"],"outboundTag":"vless-reality"}]}}
ROUTING
 mv /opt/etc/xray/configs/05_routing.json.new /opt/etc/xray/configs/05_routing.json
 echo 'Routing prepared for transparent inbounds 1181/1191; takes effect on manual server selection.'
fi
(crontab -l 2>/dev/null || true) > "$tmp/crontab"
grep -q '/opt/sbin/xsub-guard' "$tmp/crontab" || echo '* * * * * /opt/sbin/xsub-guard checkpoint >/dev/null 2>&1' >> "$tmp/crontab"
crontab "$tmp/crontab"
if ! pidof crond >/dev/null; then sh /opt/etc/init.d/S05crond start; fi
sh /opt/etc/init.d/S79xsub-http start
sh /opt/etc/init.d/S99xkeen-panel start
sync
echo "Installed. Backup: $backup"
echo 'Next: xsub change; xserver (select a server manually).'
echo 'Panel: http://192.168.1.1:3000 ; assign clients and WAN permissions in Keenetic yourself.'
