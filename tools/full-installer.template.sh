#!/bin/sh
# Full ARM64 Keenetic setup after Entware. Built by tools/build.ps1.
set -eu
umask 077
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
mode=install
case "${1:-}" in
 --check) mode=check;;
 --help|-h) echo 'Usage: sh install.sh [--check]'; exit 0;;
 '') ;;
 *) echo 'Unknown option. Use --check or --help.'; exit 1;;
esac
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
phase() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" = 0 ] || die 'Run through SSH as root.'
[ "$(uname -m)" = aarch64 ] || die 'Supported architecture: ARM64/aarch64 only.'
command -v opkg >/dev/null 2>&1 || die 'Install Entware manually first.'
command -v ndmc >/dev/null 2>&1 || die 'Keenetic ndmc not found.'
[ -d /opt/etc ] && [ -w /opt/etc ] || die 'Entware /opt is not writable.'
free_kb=$(df -Pk /opt | awk 'NR==2 {print $4}')
required_kb=49152
if [ -x /opt/sbin/xkeen ] && [ -x /opt/sbin/xray ]; then required_kb=32768; fi
[ "$free_kb" -ge "$required_kb" ] || die "Insufficient flash space: need $required_kb KiB free, have $free_kb."
if [ "$mode" = check ]; then
 echo "Entware/ARM64 prerequisites OK; free flash: $free_kb KiB."
 if [ -x /opt/sbin/xkeen ]; then echo 'XKeen: keep installed version'; else echo 'XKeen: install pinned 2.1'; fi
 if [ -x /opt/sbin/xray ]; then echo 'Xray: keep installed version'; else echo 'Xray: install pinned v26.9.30'; fi
 echo 'Only Xray; no Mihomo, geo databases or GeoIPSET. Panel, subscription tools, recovery and startup included.'
 echo 'Install mode will request a subscription URL; KeeneticOS 5.2+ may also need an RCI token.'
 echo 'Check mode made no changes.'
 exit 0
fi
# All prompts use the controlling terminal; downloading this file through a pipe
# must not accidentally consume shell source as the subscription URL.
exec 3<>/dev/tty || die 'Interactive SSH terminal required.'
tmp=$(mktemp -d /tmp/xkeen-setup.XXXXXX)
success=no
cleanup() {
 stty echo <&3 2>/dev/null || true
 rm -rf "$tmp"
 if [ "$success" != yes ]; then
  echo 'Setup did not finish. Existing backups are in /opt/etc/xserver. Fix the reported problem and rerun.' >&2
 fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
read_secret() {
 printf '%s' "$1" >&3
 stty -echo <&3
 if ! IFS= read -r secret <&3; then stty echo <&3; die 'Input cancelled.'; fi
 stty echo <&3
 printf '\n' >&3
}
phase 'Subscription'
read_secret 'HTTPS subscription URL: '
case "$secret" in https://?*) ;; *) die 'Use an HTTPS URI-list/Base64 subscription URL.';; esac
printf '%s\n' "$secret" > "$tmp/subscription-url"
unset secret
phase 'Entware dependencies'
had_lighttpd_init=no
[ ! -e /opt/etc/init.d/S80lighttpd ] || had_lighttpd_init=yes
opkg update
opkg install curl jq tar ca-bundle
fetch() {
 curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 180 "$1" -o "$2"
}
mkdir -p /opt/etc/xserver /opt/etc/xkeen
backup="/opt/etc/xserver/setup-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup"
if [ -d /opt/etc/xray/configs ]; then cp -a /opt/etc/xray/configs "$backup/configs"; fi
if [ -f /opt/etc/xkeen/xkeen.json ]; then cp -a /opt/etc/xkeen/xkeen.json "$backup/xkeen.json"; fi
# XKeen uses local RCI itself. Do not pretend that a rejected RCI call is an
# empty policy list, and do not disable firmware authentication.
rci_token=''
if [ -f /opt/etc/xkeen/xkeen.json ]; then
 rci_token=$(sed -n 's/.*"rci_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /opt/etc/xkeen/xkeen.json | head -n 1)
fi
rci_get() {
 if [ -n "$rci_token" ]; then
  curl -fsS --connect-timeout 3 --max-time 8 -H "X-Ndma-Tkn: $rci_token" "http://127.0.0.1:79/rci/$1"
 else
  curl -fsS --connect-timeout 3 --max-time 8 "http://127.0.0.1:79/rci/$1"
 fi
}
if ! rci_get show/ip/policy > "$tmp/policies.json" 2>/dev/null; then
 echo 'Local RCI is protected. KeeneticOS 5.2+: create an access token in Users and access.'
 read_secret 'RCI access token: '
 rci_token=$secret; unset secret
 [ -n "$rci_token" ] || die 'An RCI token is required by this firmware.'
 rci_get show/ip/policy > "$tmp/policies.json" 2>/dev/null || die 'RCI token rejected or RCI unavailable.'
 if [ ! -f /opt/etc/xkeen/xkeen.json ]; then printf '{}\n' > /opt/etc/xkeen/xkeen.json; fi
 jq --arg token "$rci_token" '.rci_token=$token' /opt/etc/xkeen/xkeen.json > "$tmp/xkeen.json" || die 'Existing xkeen.json must be valid JSON before adding a token.'
 cp "$tmp/xkeen.json" /opt/etc/xkeen/xkeen.json.new
 mv /opt/etc/xkeen/xkeen.json.new /opt/etc/xkeen/xkeen.json
fi
jq -e 'type=="array"' "$tmp/policies.json" >/dev/null || die 'Unexpected RCI policy response.'
phase 'XKeen and Xray'
fresh=no
if [ ! -x /opt/sbin/xkeen ] || [ ! -x /opt/etc/init.d/S05xkeen ]; then
 fresh=yes
 fetch https://github.com/jameszeroX/XKeen/releases/download/2.1/xkeen.tar.gz "$tmp/xkeen.tar.gz"
 echo "4b9350b11fab7fd3e4973db609db0fb780994f4b5ab0096f0549bc52acac8c73  $tmp/xkeen.tar.gz" | sha256sum -c - >/dev/null || die 'XKeen release checksum mismatch.'
 mkdir "$tmp/upstream"
 tar -xzf "$tmp/xkeen.tar.gz" -C "$tmp/upstream"
 [ -f "$tmp/upstream/xkeen" ] && [ -d "$tmp/upstream/_xkeen" ] || die 'Invalid XKeen release layout.'
 cp "$tmp/upstream/xkeen" /opt/sbin/xkeen.new
 chmod 755 /opt/sbin/xkeen.new
 mv /opt/sbin/xkeen.new /opt/sbin/xkeen
 cp -a "$tmp/upstream/_xkeen" /opt/sbin/.xkeen.stage.$$
 if [ -d /opt/sbin/.xkeen ]; then mv /opt/sbin/.xkeen "$backup/xkeen-modules"; fi
 mv /opt/sbin/.xkeen.stage.$$ /opt/sbin/.xkeen
 # Supported upstream automation, not a stream of guessed menu answers.
 XKEEN_FOREGROUND=1 /opt/sbin/xkeen -i auto cores=xray xray=v26.9.30 geo=off geoipset=off cron=off autostart=on > "$backup/xkeen-install.log" 2>&1 || die "XKeen auto-install failed. See $backup/xkeen-install.log"
elif [ ! -x /opt/sbin/xray ]; then
 XKEEN_FOREGROUND=1 /opt/sbin/xkeen -ux v26.9.30 > "$backup/xray-install.log" 2>&1 || die "Xray install failed. See $backup/xray-install.log"
fi
[ -x /opt/sbin/xray ] && [ -x /opt/etc/init.d/S05xkeen ] || die 'XKeen 2.x/Xray installation incomplete.'
phase 'Panel and subscription tools'
base64 -d > "$tmp/addons.sh" <<'ADDONS_END'
__ADDON_INSTALLER__
ADDONS_END
if [ "$fresh" = yes ]; then
 sh "$tmp/addons.sh" --configure-routing
else
 sh "$tmp/addons.sh"
fi
if [ "$had_lighttpd_init" = no ] && [ -e /opt/etc/init.d/S80lighttpd ]; then chmod -x /opt/etc/init.d/S80lighttpd; fi
phase 'Keenetic access policy'
policy=$(jq -r '[.[] | select((.description // "" | ascii_downcase)=="xkeen") | .name] | .[0] // empty' "$tmp/policies.json")
if [ -z "$policy" ]; then
 number=0
 while jq -e --arg name "Policy$number" 'any(.[]; .name==$name)' "$tmp/policies.json" >/dev/null; do
  number=$((number+1)); [ "$number" -lt 64 ] || die 'No free policy identifier.'
 done
 policy="Policy$number"
 ndmc -c "ip policy $policy description XKeen" > "$backup/policy-create.log" 2>&1 || die 'Cannot create XKeen access policy.'
 # Same WAN set as the router's globally configured connections. No clients
 # are moved into this policy without the user's device selection.
 ndmc -c 'show running-config' | awk '/^interface / {iface=$2} /^[[:space:]]+ip global([[:space:]]|$)/ {print iface}' > "$tmp/uplinks"
 [ -s "$tmp/uplinks" ] || die 'No global internet uplink found; configure WAN/Wi-Fi internet in Keenetic.'
 while IFS= read -r iface; do
  case "$iface" in *[!A-Za-z0-9_/-]*|'') die 'Unexpected interface identifier.';; esac
  ndmc -c "ip policy $policy permit global $iface" >> "$backup/policy-create.log" 2>&1 || die 'Cannot permit a WAN uplink for XKeen.'
 done < "$tmp/uplinks"
 ndmc -c 'system configuration save' > "$backup/policy-save.log" 2>&1 || die 'Cannot save Keenetic configuration.'
fi
case "$policy" in *[!A-Za-z0-9_-]*|'') die 'Unexpected policy identifier.';; esac
rci_get show/ip/policy > "$tmp/updated-policies.json" || die 'Cannot verify the XKeen policy.'
jq -e --arg policy "$policy" 'any(.[]; .name==$policy and ((.description // "" | ascii_downcase)=="xkeen"))' "$tmp/updated-policies.json" >/dev/null || die 'Keenetic did not create the expected XKeen policy.'
table=$(jq -r --arg policy "$policy" '.[] | select(.name==$policy) | .table4 // empty' "$tmp/updated-policies.json")
case "$table" in ''|*[!0-9]*) die 'Cannot identify the XKeen IPv4 routing table.';; esac
attempt=0
until ip -4 route show table "$table" | grep -E '^default ' | grep -vq unreachable; do
 attempt=$((attempt+1))
 [ "$attempt" -lt 6 ] || die 'XKeen policy has no internet route. Permit a working WAN/Wi-Fi connection for it in Keenetic and rerun.'
 sleep 1
done
echo "Policy: $policy (XKeen). Existing client assignments preserved."
phase 'Import subscription'
/opt/sbin/xsub change < "$tmp/subscription-url" || die 'Subscription download/conversion failed; previous active Xray config kept.'
data=/opt/etc/xkeen-panel/data/subscription.json
count=$(jq '.servers|length' "$data")
[ "$count" -gt 0 ] || die 'No VLESS servers in subscription.'
# Ensure normal transparent inbounds actually use the chosen outbound. Existing
# custom routing is kept; an incomplete template cannot silently report success.
if ! grep -q '"outboundTag"[[:space:]]*:[[:space:]]*"vless-reality"' /opt/etc/xray/configs/05_routing.json; then
 die 'Existing routing does not reference vless-reality. Configure it or run the add-on installer with --configure-routing.'
fi
phase 'Initial HTTPS check and server selection'
current=$(jq -r 'if .active_id>=0 then .active_id+1 else 0 end' "$data")
selected=0
if [ "$current" -gt 0 ]; then
 echo "Checking previous server $current/$count..."
 if /opt/sbin/xserver ping "$current" > "$tmp/probe.log" 2>&1; then selected=$current; fi
fi
if [ "$selected" = 0 ]; then
 number=1
 while [ "$number" -le "$count" ]; do
  echo "Checking server $number/$count..."
  if /opt/sbin/xserver ping "$number" > "$tmp/probe.log" 2>&1; then selected=$number; break; fi
  number=$((number+1))
 done
fi
[ "$selected" -gt 0 ] || die 'No server passed the HTTPS proxy check. List is available in the panel; try another subscription or xserver ping NUMBER.'
/opt/sbin/xserver use "$selected" || die 'Cannot apply the checked server.'
phase 'Final checks'
/opt/sbin/xray run -test -confdir /opt/etc/xray/configs > "$backup/final-test.log" 2>&1 || die 'Combined Xray configuration test failed.'
pidof xray >/dev/null || die 'Xray is not running.'
curl -fsS --max-time 5 http://127.0.0.1:18080/vless.txt >/dev/null || die 'Local subscription HTTP service failed.'
curl -fsS --max-time 5 http://127.0.0.1:3000/api/auth/status > "$tmp/auth-status.json" || die 'Panel health check failed.'
/opt/sbin/xsub-guard checkpoint
sync
lan_ip=$(ip -4 addr show br0 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}')
lan_ip=${lan_ip:-192.168.1.1}
echo "Ready: $count VLESS servers; initial server $selected passed HTTPS through the proxy."
echo "Panel: http://$lan_ip:3000"
echo 'Server switching is manual. Commands: xserver, xsub update, xsub change.'
echo 'In Keenetic, assign the desired devices to the XKeen policy.'
if jq -e '.setup_required==true' "$tmp/auth-status.json" >/dev/null; then
 echo 'First panel login: create your account and enroll TOTP in the panel.'
fi
echo "Backup and install diagnostics: $backup"
success=yes
