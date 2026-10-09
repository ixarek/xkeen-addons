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
IyEvYmluL3NoCiMgWEtlZW4gYWRkLW9ucyBmb3IgQVJNNjQgS2VlbmV0aWMgKyBFbnR3YXJlOyBu
byBzdWJzY3JpcHRpb24gY3JlZGVudGlhbHMgaW5jbHVkZWQuCnNldCAtZXUKdW1hc2sgMDc3Cm1v
ZGU9aW5zdGFsbApyb3V0aW5nPW5vCmZvciBhcmcgaW4gIiRAIjsgZG8KIGNhc2UgIiRhcmciIGlu
CiAgLS1jaGVjaykgbW9kZT1jaGVjazs7CiAgLS1jb25maWd1cmUtcm91dGluZykgcm91dGluZz15
ZXM7OwogIC0taGVscCkgZWNobyAnVXNhZ2U6IHNoIGluc3RhbGwteGtlZW4tYWRkb25zLnNoIFst
LWNoZWNrXSBbLS1jb25maWd1cmUtcm91dGluZ10nOyBleGl0IDA7OwogICopIGVjaG8gIlVua25v
d24gb3B0aW9uOiAkYXJnIjsgZXhpdCAxOzsKIGVzYWMKZG9uZQpbICIkKGlkIC11KSIgPSAwIF0g
fHwgeyBlY2hvICdSdW4gYXMgcm9vdCc7IGV4aXQgMTsgfQpbICIkKHVuYW1lIC1tKSIgPSBhYXJj
aDY0IF0gfHwgeyBlY2hvICdUaGlzIGluc3RhbGxlciB0YXJnZXRzIEFSTTY0L2FhcmNoNjQgS2Vl
bmV0aWMgb25seSc7IGV4aXQgMTsgfQpbIC14IC9vcHQvc2Jpbi94a2VlbiBdICYmIFsgLXggL29w
dC9zYmluL3hyYXkgXSB8fCB7IGVjaG8gJ0luc3RhbGwgRW50d2FyZSwgWEtlZW4gMi54IGFuZCBY
cmF5IGZpcnN0JzsgZXhpdCAxOyB9CmNvbW1hbmQgLXYgb3BrZyA+L2Rldi9udWxsIHx8IHsgZWNo
byAnRW50d2FyZSBvcGtnIG5vdCBmb3VuZCc7IGV4aXQgMTsgfQphdmFpbGFibGU9JChkZiAtUGsg
L29wdCB8IGF3ayAnTlI9PTIge3ByaW50ICQ0fScpClsgIiRhdmFpbGFibGUiIC1nZSAzMjc2OCBd
IHx8IHsgZWNobyAnQXQgbGVhc3QgMzIgTWlCIGZyZWUgaW4gL29wdCByZXF1aXJlZCBmb3IgaW5z
dGFsbGF0aW9uJzsgZXhpdCAxOyB9CmlmIFsgIiRtb2RlIiA9IGNoZWNrIF07IHRoZW4KIGVjaG8g
IlByZXJlcXVpc2l0ZXMgT0s7IGZyZWUgc3BhY2U6ICRhdmFpbGFibGUgS2lCIgogZm9yIGNtZCBp
biBjdXJsIGpxIGxpZ2h0dHBkIHhrZWVuLXN1YnNjcmlwdGlvbi13YXRjaGVyOyBkbwogIGlmIGNv
bW1hbmQgLXYgIiRjbWQiID4vZGV2L251bGw7IHRoZW4gZWNobyAiJGNtZDogaW5zdGFsbGVkIjsg
ZWxzZSBlY2hvICIkY21kOiB3aWxsIGluc3RhbGwiOyBmaQogZG9uZQogZWNobyAnTm8gY2hhbmdl
cyBtYWRlLiBBUk02NCBpbnN0YWxsZXI7IHBhbmVsIHYxLjMuMDsgc3Vic2NyaXB0aW9uIGNvbnZl
cnRlciB2MC40LjAuJwogZXhpdCAwCmZpCm1rZGlyIC1wIC9vcHQvdG1wL3hzZXJ2ZXIgL29wdC9l
dGMveHNlcnZlciAvb3B0L2V0Yy94a2Vlbi1wYW5lbC9kYXRhIC9vcHQvdmFyL3N1YnNjcmlwdGlv
biAvb3B0L3Zhci9sb2cKdG1wPSQobWt0ZW1wIC1kIC9vcHQvdG1wL3hzZXJ2ZXIvaW5zdGFsbC5Y
WFhYWFgpCnRyYXAgJ3JtIC1yZiAiJHRtcCInIEVYSVQgSFVQIElOVCBURVJNCmJhY2t1cD0iL29w
dC9ldGMveHNlcnZlci9pbnN0YWxsLWJhY2t1cC0kKGRhdGUgKyVZJW0lZC0lSCVNJVMpLSQkIgpt
a2RpciAtcCAiJGJhY2t1cCIKZm9yIGl0ZW0gaW4gL29wdC9ldGMveGtlZW4tcGFuZWwgL29wdC9l
dGMveHJheS9jb25maWdzIC9vcHQvZXRjL2luaXQuZC9TOTl4a2Vlbi1wYW5lbCAvb3B0L2V0Yy9p
bml0LmQvUzc5eHN1Yi1odHRwIC9vcHQvc2Jpbi94c3ViIC9vcHQvc2Jpbi94c2VydmVyIC9vcHQv
c2Jpbi94c3ViLWd1YXJkOyBkbwogWyAhIC1lICIkaXRlbSIgXSB8fCBjcCAtYSAiJGl0ZW0iICIk
YmFja3VwLyIKZG9uZQptaXNzaW5nPScnCmhhZF9saWdodHRwZF9pbml0PW5vClsgISAtZSAvb3B0
L2V0Yy9pbml0LmQvUzgwbGlnaHR0cGQgXSB8fCBoYWRfbGlnaHR0cGRfaW5pdD15ZXMKZm9yIHBh
aXIgaW4gJ2N1cmw6Y3VybCcgJ2pxOmpxJyAnbGlnaHR0cGQ6bGlnaHR0cGQnOyBkbwogY21kPSR7
cGFpciUlOip9OyBwYWNrYWdlPSR7cGFpciMqOn0KIGNvbW1hbmQgLXYgIiRjbWQiID4vZGV2L251
bGwgfHwgbWlzc2luZz0iJG1pc3NpbmcgJHBhY2thZ2UiCmRvbmUKaWYgWyAtbiAiJG1pc3Npbmci
IF07IHRoZW4gb3BrZyB1cGRhdGU7IG9wa2cgaW5zdGFsbCAkbWlzc2luZyBjYS1idW5kbGU7IGZp
CiMgQSBuZXdseSBpbnN0YWxsZWQgc3RvY2sgbGlnaHR0cGQgY29uZmlnIG11c3Qgbm90IHRha2Ug
b3ZlciB0aGUgcm91dGVyJ3MgcG9ydCA4MC4KaWYgWyAiJGhhZF9saWdodHRwZF9pbml0IiA9IG5v
IF0gJiYgWyAtZSAvb3B0L2V0Yy9pbml0LmQvUzgwbGlnaHR0cGQgXTsgdGhlbiBjaG1vZCAteCAv
b3B0L2V0Yy9pbml0LmQvUzgwbGlnaHR0cGQ7IGZpCmZldGNoKCkgewogdXJsPSQxOyBmaWxlPSQy
OyBkaWdlc3Q9JDMKIGN1cmwgLS1wcm90byAnPWh0dHBzJyAtLXByb3RvLXJlZGlyICc9aHR0cHMn
IC1mTHNTIC0tY29ubmVjdC10aW1lb3V0IDE1IC0tbWF4LXRpbWUgMTgwICIkdXJsIiAtbyAiJGZp
bGUiCiBlY2hvICIkZGlnZXN0ICAkZmlsZSIgfCBzaGEyNTZzdW0gLWMgLSA+L2Rldi9udWxsCiBj
aG1vZCA3NTUgIiRmaWxlIgp9CmlmIFsgISAteCAvb3B0L3NiaW4veGtlZW4tcGFuZWwgXTsgdGhl
bgogZmV0Y2ggaHR0cHM6Ly9naXRodWIuY29tL0RlYXJvbnNraS94a2Vlbi1wYW5lbC9yZWxlYXNl
cy9kb3dubG9hZC92MS4zLjAveGtlZW4tcGFuZWwtYWFyY2g2NCAiJHRtcC94a2Vlbi1wYW5lbCIg
M2NiNjIyOWU0MjIyMjJmNzRkOWVmZTU1YzBmNjFmZTA4OTRlNmU5YTM3NjU2YjE4NDQ1NzE1NDQx
OWQxZmM2YQogbXYgIiR0bXAveGtlZW4tcGFuZWwiIC9vcHQvc2Jpbi94a2Vlbi1wYW5lbApmaQpp
ZiBbICEgLXggL29wdC9zYmluL3hrZWVuLXN1YnNjcmlwdGlvbi13YXRjaGVyIF07IHRoZW4KIGZl
dGNoIGh0dHBzOi8vZ2l0aHViLmNvbS90a3VrdXNoa2luL3hrZWVuLXN1YnNjcmlwdGlvbi13YXRj
aGVyL3JlbGVhc2VzL2Rvd25sb2FkL3YwLjQuMC94a2Vlbi1zdWJzY3JpcHRpb24td2F0Y2hlci1s
aW51eC1hcm02NCAiJHRtcC94a2Vlbi1zdWJzY3JpcHRpb24td2F0Y2hlciIgNzg2OTlhYzVlZTMz
ZjJiZDM1N2ZjM2MyYTkzZjJjYTBkY2ZlMmU4Njk4ZTdhNjY4ZWEzMWZkZGVjNGFiZjcxMgogbXYg
IiR0bXAveGtlZW4tc3Vic2NyaXB0aW9uLXdhdGNoZXIiIC9vcHQvc2Jpbi94a2Vlbi1zdWJzY3Jp
cHRpb24td2F0Y2hlcgpmaQppZiBbIC1mIC9vcHQvZXRjL2luaXQuZC9TOTl4a2Vlbi1wYW5lbCBd
OyB0aGVuIHNoIC9vcHQvZXRjL2luaXQuZC9TOTl4a2Vlbi1wYW5lbCBzdG9wIHx8IHRydWU7IGZp
CmlmIFsgISAtZiAvb3B0L2V0Yy94a2Vlbi1wYW5lbC9jb25maWcueWFtbCBdOyB0aGVuCiBjYXQg
PiAvb3B0L2V0Yy94a2Vlbi1wYW5lbC9jb25maWcueWFtbCA8PCdDT05GSUcnCnBvcnQ6IDMwMDAK
ZGF0YV9kaXI6IC9vcHQvZXRjL3hrZWVuLXBhbmVsL2RhdGEKeGtlZW5fcGF0aDogL29wdC9zYmlu
L3hrZWVuCm91dGJvdW5kc19maWxlOiAvb3B0L2V0Yy94cmF5L2NvbmZpZ3MvMDRfb3V0Ym91bmRz
Lmpzb24KY2hlY2tfaW50ZXJ2YWw6IDEyMApjaGVja191cmw6IGh0dHBzOi8vd3d3Lmdvb2dsZS5j
b20KbWF4X2ZhaWxzOiAzCmxvZ19maWxlOiAvb3B0L3Zhci9sb2cveGtlZW4tcGFuZWwubG9nCndh
dGNoZG9nX2F1dG9fc3RhcnQ6IGZhbHNlCnN1YnNjcmlwdGlvbl9yZWZyZXNoX2ludGVydmFsOiAw
CkNPTkZJRwplbHNlCiBzZWQgLWkgJy9ed2F0Y2hkb2dfYXV0b19zdGFydDovZDsgL15zdWJzY3Jp
cHRpb25fcmVmcmVzaF9pbnRlcnZhbDovZCcgL29wdC9ldGMveGtlZW4tcGFuZWwvY29uZmlnLnlh
bWwKIHByaW50ZiAnXG53YXRjaGRvZ19hdXRvX3N0YXJ0OiBmYWxzZVxuc3Vic2NyaXB0aW9uX3Jl
ZnJlc2hfaW50ZXJ2YWw6IDBcbicgPj4gL29wdC9ldGMveGtlZW4tcGFuZWwvY29uZmlnLnlhbWwK
ZmkKaWYgWyAhIC1lIC9vcHQvZXRjL3hrZWVuLXBhbmVsL2RhdGEvc3Vic2NyaXB0aW9uLmpzb24g
XTsgdGhlbgogcHJpbnRmICclc1xuJyAneyJ1cmwiOiJodHRwOi8vMTI3LjAuMC4xOjE4MDgwL3Zs
ZXNzLnR4dCIsInNlcnZlcnMiOltdLCJhY3RpdmVfaWQiOi0xfScgPiAvb3B0L2V0Yy94a2Vlbi1w
YW5lbC9kYXRhL3N1YnNjcmlwdGlvbi5qc29uCmZpCiMgRW1iZWRkZWQgY29tbWFuZCBwYXlsb2Fk
cyBhcmUgZGVjb2RlZCBiZWxvdy4gVGhleSBjb250YWluIG5vIHVzZXIgc2VjcmV0cy4KYmFzZTY0
IC1kID4gL29wdC9zYmluL3hzdWIgPDwnUEFZTE9BRF9FTkQnCkl5RXZZbWx1TDNOb0NuTmxkQ0F0
WlhVS2RXMWhjMnNnTURjM0NuSnZiM1E5TDI5d2RDOWxkR012ZUhObGNuWmxjZ3BrWVhSaFBTOXYK
Y0hRdlpYUmpMM2hyWldWdUxYQmhibVZzTDJSaGRHRXZjM1ZpYzJOeWFYQjBhVzl1TG1wemIyNEti
V3RrYVhJZ0xYQWdJaVJ5YjI5MApJaUF2YjNCMEwzUnRjQzk0YzJWeWRtVnlDblJ0Y0Qwa0tHMXJk
R1Z0Y0NBdFpDQXZiM0IwTDNSdGNDOTRjMlZ5ZG1WeUwzTjFZaTVZCldGaFlXRmdwQ25SeVlYQWdK
M04wZEhrZ1pXTm9ieUF5UGk5a1pYWXZiblZzYkNCOGZDQjBjblZsT3lCeWJTQXRjbVlnSWlSMGJY
QWkKSnlCRldFbFVJRWhWVUNCSlRsUWdWRVZTVFFwdGIyUmxQU1I3TVRvdGRYQmtZWFJsZlFwallY
TmxJQ0lrYlc5a1pTSWdhVzRLSUdObwpZVzVuWlNrS0lIQnlhVzUwWmlBblNGUlVVRk1nYzNWaWMy
TnlhWEIwYVc5dUlGVlNURG9nSndvZ2FXWWdXeUF0ZENBd0lGMDdJSFJvClpXNGdjM1IwZVNBdFpX
Tm9ienNnWm1rS0lFbEdVejBnY21WaFpDQXRjaUIxY213S0lHbG1JRnNnTFhRZ01DQmRPeUIwYUdW
dUlITjAKZEhrZ1pXTm9ienNnWm1rS0lIQnlhVzUwWmlBblhHNG5DaUJqWVhObElDSWtkWEpzSWlC
cGJpQm9kSFJ3Y3pvdkx5b3BJRHM3SUNvcApJR1ZqYUc4Z0owaFVWRkJUSUZWU1RDQnlaWEYxYVhK
bFpDYzdJR1Y0YVhRZ01UczdJR1Z6WVdNS0lIQnlhVzUwWmlBbkpYTmNiaWNnCklpUjFjbXdpSUQ0
Z0lpUjBiWEF2YzI5MWNtTmxMWFZ5YkNJS0lEczdDaUIxY0dSaGRHVXBDaUJwWmlCYklDRWdMWE1n
SWlSeWIyOTAKTDNOdmRYSmpaUzExY213aUlGMDdJSFJvWlc0Z1pXTm9ieUFuVW5WdUlIaHpkV0ln
WTJoaGJtZGxJR1pwY25OMEp6c2daWGhwZENBeApPeUJtYVFvZ2RYSnNQU1FvWTJGMElDSWtjbTl2
ZEM5emIzVnlZMlV0ZFhKc0lpa0tJRHM3Q2lCcGJYQnZjblFwSUdOd0lDOXZjSFF2CmRtRnlMM04x
WW5OamNtbHdkR2x2Ymk5dmRtVnljM1ZpTG5SNGRDQWlKSFJ0Y0M5aWIyUjVJanM3Q2lBcUtTQmxZ
Mmh2SUNkVmMyRm4KWlRvZ2VITjFZaUJqYUdGdVoyVWdmQ0IxY0dSaGRHVWdmQ0JwYlhCdmNuUW5P
eUJsZUdsMElERTdPd3BsYzJGakNtbG1JRnNnSWlSdApiMlJsSWlBaFBTQnBiWEJ2Y25RZ1hUc2dk
R2hsYmdvZ1kzVnliQ0F0TFhCeWIzUnZJQ2M5YUhSMGNITW5JQzB0Y0hKdmRHOHRjbVZrCmFYSWdK
ejFvZEhSd2N5Y2dMV1pNYzFNZ0xTMWpiMjV1WldOMExYUnBiV1Z2ZFhRZ01UQWdMUzF0WVhndGRH
bHRaU0EyTUNBdExXMWgKZUMxbWFXeGxjMmw2WlNBeU1EazNNVFV5SUNJa2RYSnNJaUErSUNJa2RH
MXdMMkp2WkhraUlESStJaVIwYlhBdlpHOTNibXh2WVdRdQpiRzluSWlCOGZDQjdJR1ZqYUc4Z0ow
UnZkMjVzYjJGa0lHWmhhV3hsWkRzZ2NISmxkbWx2ZFhNZ2MzVmljMk55YVhCMGFXOXVJR3RsCmNI
UW5PeUJsZUdsMElERTdJSDBLWm1rS2RISWdMV1FnSjF4eUp5QThJQ0lrZEcxd0wySnZaSGtpSUQ0
Z0lpUjBiWEF2WW05a2VTNWoKYkdWaGJpSTdJRzEySUNJa2RHMXdMMkp2WkhrdVkyeGxZVzRpSUNJ
a2RHMXdMMkp2WkhraUNtbG1JR2R5WlhBZ0xYRWdKMTUyYkdWegpjem92THljZ0lpUjBiWEF2WW05
a2VTSTdJSFJvWlc0S0lHTndJQ0lrZEcxd0wySnZaSGtpSUNJa2RHMXdMMlJsWTI5a1pXUWlDbVZz
CmMyVUtJR0poYzJVMk5DQXRaQ0FpSkhSdGNDOWliMlI1SWlBK0lDSWtkRzF3TDJSbFkyOWtaV1Fp
SURJK0wyUmxkaTl1ZFd4c0lIeDgKSUhzZ1pXTm9ieUFuVG05MElHRWdWVkpKTDBKaGMyVTJOQ0J6
ZFdKelkzSnBjSFJwYjI0bk95QmxlR2wwSURFN0lIMEtabWtLYzJWawpJQzF1SUNjdlhuWnNaWE56
T2x3dlhDOHZjQ2NnSWlSMGJYQXZaR1ZqYjJSbFpDSWdQaUFpSkhSdGNDOTJiR1Z6Y3k1MGVIUWlD
bHNnCkxYTWdJaVIwYlhBdmRteGxjM011ZEhoMElpQmRJSHg4SUhzZ1pXTm9ieUFuVG04Z1ZreEZV
MU1nYzJWeWRtVnljenNnY0hKbGRtbHYKZFhNZ2MzVmljMk55YVhCMGFXOXVJR3RsY0hRbk95Qmxl
R2wwSURFN0lIMEtPaUErSUNJa2RHMXdMM05sY25abGNuTXVhbk52Ym13aQpDbWs5TUFwM2FHbHNa
U0JKUmxNOUlISmxZV1FnTFhJZ2RYSnBPeUJrYndvZ2JtRnRaVDBrZTNWeWFTTXFJMzBLSUc1aGJX
VTlKQ2h3CmNtbHVkR1lnSnlWaUp5QWlKQ2h3Y21sdWRHWWdKeVZ6SnlBaUpHNWhiV1VpSUh3Z2My
VmtJQ2R6THlVdlhGeDRMMmNuS1NJcENpQmwKYm1Sd2IybHVkRDBrZTNWeWFTTXFRSDA3SUdWdVpI
QnZhVzUwUFNSN1pXNWtjRzlwYm5RbEpWdy9LbjA3SUdWdVpIQnZhVzUwUFNSNwpaVzVrY0c5cGJu
UWxKU01xZlFvZ1kyRnpaU0FpSkdWdVpIQnZhVzUwSWlCcGJnb2dJRnhiS2x4ZE9pb3BJR0ZrWkhK
bGMzTTlKSHRsCmJtUndiMmx1ZENVNktuMDdJSEJ2Y25ROUpIdGxibVJ3YjJsdWRDTWpLanA5T3pz
S0lDQmNXeXBjWFNrZ1lXUmtjbVZ6Y3owa1pXNWsKY0c5cGJuUTdJSEJ2Y25ROU5EUXpPenNLSUNB
cU9pb3BJR0ZrWkhKbGMzTTlKSHRsYm1Sd2IybHVkQ1U2S24wN0lIQnZjblE5Skh0bApibVJ3YjJs
dWRDTWpLanA5T3pzS0lDQXFLU0JoWkdSeVpYTnpQU1JsYm1Sd2IybHVkRHNnY0c5eWREMDBORE03
T3dvZ1pYTmhZd29nCllXUmtjbVZ6Y3owa2UyRmtaSEpsYzNNalhGdDlPeUJoWkdSeVpYTnpQU1I3
WVdSa2NtVnpjeVZjWFgwS0lHTmhjMlVnSWlSMWNta2kKSUdsdUlDb25JeWNxS1NBN095QXFLU0J1
WVcxbFBTUmhaR1J5WlhOek96c2daWE5oWXdvZ2FuRWdMVzVqSUMwdFlYSm5JSEpoZHlBaQpKSFZ5
YVNJZ0xTMWhjbWNnYm1GdFpTQWlKRzVoYldVaUlDMHRZWEpuSUdGa1pISWdJaVJoWkdSeVpYTnpJ
aUF0TFdGeVoycHpiMjRnCmNHOXlkQ0FpSkhCdmNuUWlJQzB0WVhKbmFuTnZiaUJwWkNBaUpHa2lJ
Q2Q3YVdRNkpHbGtMRzVoYldVNkpHNWhiV1VzWVdSa2NtVnoKY3pva1lXUmtjaXh3YjNKME9pUndi
M0owTEhCeWIzUnZZMjlzT2lKMmJHVnpjeUlzWVdOMGFYWmxPbVpoYkhObExHeGhkR1Z1WTNsZgpi
WE02TFRFc2NtRjNYM1Z5YVRva2NtRjNmU2NnUGo0Z0lpUjBiWEF2YzJWeWRtVnljeTVxYzI5dWJD
SUtJR2s5SkNnb2FTc3hLU2tLClpHOXVaU0E4SUNJa2RHMXdMM1pzWlhOekxuUjRkQ0lLYW5FZ0xY
TWdMUzF6YkhWeWNHWnBiR1VnYjJ4a0lDSWtaR0YwWVNJZ0p3b2cKS0NSdmJHUmJNRjB1YzJWeWRt
VnljM3h0WVhBb2MyVnNaV04wS0M1aFkzUnBkbVVwS1h3dVd6QmRMbkpoZDE5MWNta2dMeThnSWlJ
cApJR0Z6SUNSaFkzUnBkbVZWVWtrZ2ZBb2dLRzFoY0NoelpXeGxZM1FvTG5KaGQxOTFjbWs5UFNS
aFkzUnBkbVZWVWtrcEtYd3VXekJkCkxtbGtJQzh2SUMweEtTQmhjeUFrWVdOMGFYWmxJSHdLSUh0
MWNtdzZJbWgwZEhBNkx5OHhNamN1TUM0d0xqRTZNVGd3T0RBdmRteGwKYzNNdWRIaDBJaXhzWVhO
MFgzVndaR0YwWldRNktHNXZkM3gwYjJSaGRHVXBMR0ZqZEdsMlpWOXBaRG9rWVdOMGFYWmxMSE5s
Y25abApjbk02YldGd0tDNWhZM1JwZG1VOUtDNXBaRDA5SkdGamRHbDJaU2twZlFvbklDSWtkRzF3
TDNObGNuWmxjbk11YW5OdmJtd2lJRDRnCklpUjBiWEF2YzNWaWMyTnlhWEIwYVc5dUxtcHpiMjRp
Q2xzZ0xYTWdJaVIwYlhBdmMzVmljMk55YVhCMGFXOXVMbXB6YjI0aUlGMGcKZkh3Z2V5QmxZMmh2
SUNkRFlXNXViM1FnY0hKbGMyVnlkbVVnWVdOMGFYWmxJSE5sY25abGNpYzdJR1Y0YVhRZ01Uc2dm
UXBqY0NBaQpKR1JoZEdFaUlDSWtjbTl2ZEM5emRXSnpZM0pwY0hScGIyNHVjSEpsZG1sdmRYTXVh
bk52YmlJS2MyZ2dMMjl3ZEM5bGRHTXZhVzVwCmRDNWtMMU01T1hoclpXVnVMWEJoYm1Wc0lITjBi
M0FnUGk5a1pYWXZiblZzYkFwamNDQWlKSFJ0Y0M5MmJHVnpjeTUwZUhRaUlDOXYKY0hRdmRtRnlM
M04xWW5OamNtbHdkR2x2Ymk5MmJHVnpjeTUwZUhRdWJtVjNDbTEySUM5dmNIUXZkbUZ5TDNOMVlu
TmpjbWx3ZEdsdgpiaTkyYkdWemN5NTBlSFF1Ym1WM0lDOXZjSFF2ZG1GeUwzTjFZbk5qY21sd2RH
bHZiaTkyYkdWemN5NTBlSFFLWTNBZ0lpUjBiWEF2CmMzVmljMk55YVhCMGFXOXVMbXB6YjI0aUlD
SWtaR0YwWVM1dVpYY2lPeUJ0ZGlBaUpHUmhkR0V1Ym1WM0lpQWlKR1JoZEdFaU95QnoKZVc1akNt
bG1JRnNnSWlSdGIyUmxJaUFoUFNCcGJYQnZjblFnWFRzZ2RHaGxiZ29nWTNBZ0lpUjBiWEF2WW05
a2VTSWdMMjl3ZEM5MgpZWEl2YzNWaWMyTnlhWEIwYVc5dUwyOTJaWEp6ZFdJdWRIaDBMbTVsZHdv
Z2JYWWdMMjl3ZEM5MllYSXZjM1ZpYzJOeWFYQjBhVzl1CkwyOTJaWEp6ZFdJdWRIaDBMbTVsZHlB
dmIzQjBMM1poY2k5emRXSnpZM0pwY0hScGIyNHZiM1psY25OMVlpNTBlSFFLWm1rS2FXWWcKV3lB
aUpHMXZaR1VpSUQwZ1kyaGhibWRsSUYwN0lIUm9aVzRLSUdOd0lDSWtkRzF3TDNOdmRYSmpaUzEx
Y213aUlDSWtjbTl2ZEM5egpiM1Z5WTJVdGRYSnNMbTVsZHlJS0lHMTJJQ0lrY205dmRDOXpiM1Z5
WTJVdGRYSnNMbTVsZHlJZ0lpUnliMjkwTDNOdmRYSmpaUzExCmNtd2lDbVpwQ25ONWJtTUtjMmdn
TDI5d2RDOWxkR012YVc1cGRDNWtMMU01T1hoclpXVnVMWEJoYm1Wc0lITjBZWEowSUQ0dlpHVjIK
TDI1MWJHd0taV05vYnlBaVZreEZVMU1nYzJWeWRtVnljem9nSkdrdUlFRmpkR2wyWlNCWWNtRjVJ
R052Ym01bFkzUnBiMjRnZFc1agphR0Z1WjJWa0xpSUthV1lnV3lBaUpDaHFjU0F0Y2lBbkxtRmpk
R2wyWlY5cFpDY2dJaVJrWVhSaElpa2lJRDBnTFRFZ1hUc2dkR2hsCmJnb2daV05vYnlBblVISmxk
bWx2ZFhNZ2MyVnlkbVZ5SUc1dmRDQnBiaUJ1WlhjZ2JHbHpkQzRnVTJWc1pXTjBJR0VnYzJWeWRt
VnkKSUcxaGJuVmhiR3g1TGljS1pta0sKUEFZTE9BRF9FTkQKYmFzZTY0IC1kID4gL29wdC9zYmlu
L3hzZXJ2ZXIgPDwnUEFZTE9BRF9FTkQnCkl5RXZZbWx1TDNOb0NuTmxkQ0F0WlhVS2RXMWhjMnNn
TURjM0NtUmhkR0U5TDI5d2RDOWxkR012ZUd0bFpXNHRjR0Z1Wld3dlpHRjAKWVM5emRXSnpZM0pw
Y0hScGIyNHVhbk52YmdwamJXUTlKSHN4T2kxdFpXNTFmUXBzYVhOMEtDa2dleUJxY1NBdGNpQW5M
bk5sY25abApjbk5iWFNCOElDSmNLQzVwWkNzeEtWeDBYQ2hwWmlBdVlXTjBhWFpsSUhSb1pXNGdJ
aW9pSUdWc2MyVWdJaUFpSUdWdVpDa2dYQ2d1CmJtRnRaU2xjZEZ3b0xteGhkR1Z1WTNsZmJYTXBJ
RzF6SWljZ0lpUmtZWFJoSWpzZ2ZRcHBaaUJiSUNJa1kyMWtJaUE5SUcxbGJuVWcKWFRzZ2RHaGxi
Z29nYkdsemRBb2djSEpwYm5SbUlDZE9kVzFpWlhJZ2RHOGdjM2RwZEdOb0xDQndJRTVWVFVKRlVp
QjBieUIwWlhOMApMQ0J4SUhSdklIRjFhWFE2SUNjS0lFbEdVejBnY21WaFpDQXRjaUJwYm5CMWRB
b2dZMkZ6WlNBaUpHbHVjSFYwSWlCcGJpQnhmQ2NuCktTQmxlR2wwSURBN095QndYQ0FxS1NCamJX
UTljR2x1WnpzZ2JqMGtlMmx1Y0hWMEkzQWdmVHM3SUNvcElHTnRaRDExYzJVN0lHNDkKSkdsdWNI
VjBPenNnWlhOaFl3cGxiR2xtSUZzZ0lpUmpiV1FpSUQwZ2JHbHpkQ0JkT3lCMGFHVnVJR3hwYzNR
N0lHVjRhWFFnTUFwbApiSE5sSUc0OUpIc3lPaTE5T3lCbWFRcGpZWE5sSUNJa1kyMWtJaUJwYmlC
d2FXNW5mSFZ6WlNrZ096c2dLaWtnWldOb2J5QW5WWE5oCloyVTZJSGh6WlhKMlpYSWdXMnhwYzNR
Z2ZDQndhVzVuSUU1VlRVSkZVaUI4SUhWelpTQk9WVTFDUlZKZEp6c2daWGhwZENBeE96c2cKWlhO
aFl3cGpZWE5sSUNJa2JpSWdhVzRnSnlkOEtsc2hNQzA1WFNvcElHVmphRzhnSjBsdWRtRnNhV1Fn
Ym5WdFltVnlKenNnWlhocApkQ0F4T3pzZ1pYTmhZd3BwWkhnOUpDZ29iaTB4S1NrS2FuRWdMV1Vn
TFMxaGNtZHFjMjl1SUdrZ0lpUnBaSGdpSUNjdWMyVnlkbVZ5CmMxc2thVjBnSVQwZ2JuVnNiQ0Jo
Ym1RZ0pHaytQVEFuSUNJa1pHRjBZU0lnUGk5a1pYWXZiblZzYkNCOGZDQjdJR1ZqYUc4Z0owNXYK
SUhOMVkyZ2djMlZ5ZG1WeUp6c2daWGhwZENBeE95QjlDbTFyWkdseUlDMXdJQzl2Y0hRdmRHMXdM
M2h6WlhKMlpYSUtiV3RrYVhJZwpMMjl3ZEM5MGJYQXZlSE5sY25abGNpMWpiR2t1Ykc5amF5QXlQ
aTlrWlhZdmJuVnNiQ0I4ZkNCN0lHVmphRzhnSjBGdWIzUm9aWElnCmIzQmxjbUYwYVc5dUlHbHpJ
SEoxYm01cGJtY25PeUJsZUdsMElERTdJSDBLZEcxd1BTUW9iV3QwWlcxd0lDMWtJQzl2Y0hRdmRH
MXcKTDNoelpYSjJaWEl2WTJ4cExsaFlXRmhZV0NrS2NHbGtQU2NuQ21Oc1pXRnVkWEFvS1NCN0lG
c2dMWG9nSWlSd2FXUWlJRjBnZkh3ZwphMmxzYkNBaUpIQnBaQ0lnTWo0dlpHVjJMMjUxYkd3Z2ZI
d2dkSEoxWlRzZ2NtMGdMV1lnTDI5d2RDOTJZWEl2YzNWaWMyTnlhWEIwCmFXOXVMMk5vYjJsalpT
NTBlSFE3SUhKdElDMXlaaUFpSkhSdGNDSTdJSEp0WkdseUlDOXZjSFF2ZEcxd0wzaHpaWEoyWlhJ
dFkyeHAKTG14dlkyczdJSDBLZEhKaGNDQmpiR1ZoYm5Wd0lFVllTVlFnU0ZWUUlFbE9WQ0JVUlZK
TkNtcHhJQzF5SUMwdFlYSm5hbk52YmlCcApJQ0lrYVdSNElpQW5Mbk5sY25abGNuTmJKR2xkTG5K
aGQxOTFjbWtuSUNJa1pHRjBZU0lnUGlBdmIzQjBMM1poY2k5emRXSnpZM0pwCmNIUnBiMjR2WTJo
dmFXTmxMblI0ZEFvdmIzQjBMM05pYVc0dmVHdGxaVzR0YzNWaWMyTnlhWEIwYVc5dUxYZGhkR05v
WlhJZ0xTMXoKYVc1bmJHVXRjSEp2ZUhrZ0xTMXVieTF5WlhOMFlYSjBJQzB0YjNWMGNIVjBMV1Jw
Y2lBaUpIUnRjQ0lnSjJOb2IybGpaVDFvZEhSdwpPaTh2TVRJM0xqQXVNQzR4T2pFNE1EZ3dMMk5v
YjJsalpTNTBlSFFuSUQ0Z0lpUjBiWEF2WTI5dWRtVnlkQzVzYjJjaUlESStKakVLCmFuRWdMV1Vn
Snk1dmRYUmliM1Z1WkhOOGJHVnVaM1JvUFQweEp5QWlKSFJ0Y0M4d05GOXZkWFJpYjNWdVpITXVZ
Mmh2YVdObExtcHoKYjI0aUlENHZaR1YyTDI1MWJHd0thV1lnV3lBaUpHTnRaQ0lnUFNCd2FXNW5J
RjA3SUhSb1pXNEtJR3B4SUNkN2JHOW5PbnRzYjJkcwpaWFpsYkRvaWQyRnlibWx1WnlKOUxHbHVZ
bTkxYm1Sek9sdDdiR2x6ZEdWdU9pSXhNamN1TUM0d0xqRWlMSEJ2Y25RNk1URTRPU3h3CmNtOTBi
Mk52YkRvaWMyOWphM01pTEhObGRIUnBibWR6T250aGRYUm9PaUp1YjJGMWRHZ2lMSFZrY0RwbVlX
eHpaWDE5WFN4dmRYUmkKYjNWdVpITTZMbTkxZEdKdmRXNWtjMzBuSUNJa2RHMXdMekEwWDI5MWRH
SnZkVzVrY3k1amFHOXBZMlV1YW5OdmJpSWdQaUFpSkhSdApjQzl3Y205aVpTNXFjMjl1SWdvZ0wy
OXdkQzl6WW1sdUwzaHlZWGtnY25WdUlDMTBaWE4wSUMxaklDSWtkRzF3TDNCeWIySmxMbXB6CmIy
NGlJRDRnSWlSMGJYQXZjSEp2WW1VdWJHOW5JaUF5UGlZeENpQXZiM0IwTDNOaWFXNHZlSEpoZVNC
eWRXNGdMV01nSWlSMGJYQXYKY0hKdlltVXVhbk52YmlJZ1BqNGdJaVIwYlhBdmNISnZZbVV1Ykc5
bklpQXlQaVl4SUNZZ2NHbGtQU1FoQ2lCemJHVmxjQ0F4Q2lCcQpjU0F0Y2lBdExXRnlaMnB6YjI0
Z2FTQWlKR2xrZUNJZ0p5NXpaWEoyWlhKeld5UnBYUzV1WVcxbEp5QWlKR1JoZEdFaUNpQnlaWE4x
CmJIUTlKQ2hqZFhKc0lDMHRjSEp2ZUhrZ2MyOWphM00xYURvdkx6RXlOeTR3TGpBdU1Ub3hNVGc1
SUMwdFkyOXVibVZqZEMxMGFXMWwKYjNWMElEVWdMUzF0WVhndGRHbHRaU0F4TWlBdGMxTWdMVzhn
TDJSbGRpOXVkV3hzSUMxM0lDY2xlMmgwZEhCZlkyOWtaWDBnSlh0MAphVzFsWDNSdmRHRnNmU2Nn
YUhSMGNITTZMeTkzZDNjdVozTjBZWFJwWXk1amIyMHZaMlZ1WlhKaGRHVmZNakEwS1NCOGZDQjdJ
R1ZqCmFHOGdKMUJ5YjNoNUlISmxjWFZsYzNRZ1ptRnBiR1ZrSnpzZ1pYaHBkQ0F4T3lCOUNpQmpi
MlJsUFNSN2NtVnpkV3gwSlNVZ0tuMDcKSUdWc1lYQnpaV1E5Skh0eVpYTjFiSFFqS2lCOUNpQmxZ
Mmh2SUNKSVZGUlFJQ1JqYjJSbE95Qm1kV3hzSUVoVVZGQlRJSEpsY1hWbApjM1FnSkdWc1lYQnpa
V1FnY3lJS0lGc2dJaVJqYjJSbElpQTlJREl3TkNCZElIeDhJSHNnWldOb2J5QW5WVzVsZUhCbFkz
UmxaQ0JvClpXRnNkR2d0WTJobFkyc2djbVZ6Y0c5dWMyVW5PeUJsZUdsMElERTdJSDBLSUdWNGFY
UUtabWtLYW5FZ0ozdHZkWFJpYjNWdVpITTYKVzN0MFlXYzZJbVJwY21WamRDSXNjSEp2ZEc5amIy
dzZJbVp5WldWa2IyMGlmU3g3ZEdGbk9pSmliRzlqYXlJc2NISnZkRzlqYjJ3NgpJbUpzWVdOcmFH
OXNaU0o5TENndWIzVjBZbTkxYm1Seld6QmRmQzUwWVdjOUluWnNaWE56TFhKbFlXeHBkSGtpS1Yx
OUp5QWlKSFJ0CmNDOHdORjl2ZFhSaWIzVnVaSE11WTJodmFXTmxMbXB6YjI0aUlENGdJaVIwYlhB
dmIzVjBZbTkxYm1SekxtcHpiMjRpQ20xclpHbHkKSUNJa2RHMXdMM04wWVdkbElncGpjQ0F2YjNC
MEwyVjBZeTk0Y21GNUwyTnZibVpwWjNNdktpNXFjMjl1SUNJa2RHMXdMM04wWVdkbApMeUlLWTNB
Z0lpUjBiWEF2YjNWMFltOTFibVJ6TG1wemIyNGlJQ0lrZEcxd0wzTjBZV2RsTHpBMFgyOTFkR0p2
ZFc1a2N5NXFjMjl1Cklnb3ZiM0IwTDNOaWFXNHZlSEpoZVNCeWRXNGdMWFJsYzNRZ0xXTnZibVpr
YVhJZ0lpUjBiWEF2YzNSaFoyVWlJRDRnSWlSMGJYQXYKZEdWemRDNXNiMmNpSURJK0pqRUtZM0Fn
TDI5d2RDOWxkR012ZUhKaGVTOWpiMjVtYVdkekx6QTBYMjkxZEdKdmRXNWtjeTVxYzI5dQpJQ0lr
ZEcxd0wzQnlaWFpwYjNWekxtcHpiMjRpQ21Od0lDSWtaR0YwWVNJZ0lpUjBiWEF2Y0hKbGRtbHZk
WE10YzNWaWMyTnlhWEIwCmFXOXVMbXB6YjI0aUNtcHhJQzB0WVhKbmFuTnZiaUJwSUNJa2FXUjRJ
aUFuTG1GamRHbDJaVjlwWkQwa2FTQjhJQzV6WlhKMlpYSnoKSUh3OUlHMWhjQ2d1WVdOMGFYWmxQ
U2d1YVdROVBTUnBLU2tuSUNJa1pHRjBZU0lnUGlBaUpIUnRjQzl6ZFdKelkzSnBjSFJwYjI0dQph
bk52YmlJS2MyZ2dMMjl3ZEM5bGRHTXZhVzVwZEM1a0wxTTVPWGhyWldWdUxYQmhibVZzSUhOMGIz
QWdQaTlrWlhZdmJuVnNiQXBqCmNDQWlKSFJ0Y0M5dmRYUmliM1Z1WkhNdWFuTnZiaUlnTDI5d2RD
OWxkR012ZUhKaGVTOWpiMjVtYVdkekx6QTBYMjkxZEdKdmRXNWsKY3k1cWMyOXVMbTVsZHdwdGRp
QXZiM0IwTDJWMFl5OTRjbUY1TDJOdmJtWnBaM012TURSZmIzVjBZbTkxYm1SekxtcHpiMjR1Ym1W
MwpJQzl2Y0hRdlpYUmpMM2h5WVhrdlkyOXVabWxuY3k4d05GOXZkWFJpYjNWdVpITXVhbk52Ymdw
amNDQWlKSFJ0Y0M5emRXSnpZM0pwCmNIUnBiMjR1YW5OdmJpSWdJaVJrWVhSaExtNWxkeUk3SUcx
MklDSWtaR0YwWVM1dVpYY2lJQ0lrWkdGMFlTSTdJSE41Ym1NS2NtVnoKZEdGeWRGOXZhejE1WlhN
S2VHdGxaVzRnTFhKbGMzUmhjblFnUGlBaUpIUnRjQzl5WlhOMFlYSjBMbXh2WnlJZ01qNG1NU0I4
ZkNCeQpaWE4wWVhKMFgyOXJQVzV2Q25Oc1pXVndJRElLYVdZZ1d5QWlKSEpsYzNSaGNuUmZiMnNp
SUQwZ2JtOGdYU0I4ZkNBaElIQnBaRzltCklIaHlZWGtnUGk5a1pYWXZiblZzYkRzZ2RHaGxiZ29n
WTNBZ0lpUjBiWEF2Y0hKbGRtbHZkWE11YW5OdmJpSWdMMjl3ZEM5bGRHTXYKZUhKaGVTOWpiMjVt
YVdkekx6QTBYMjkxZEdKdmRXNWtjeTVxYzI5dUxtNWxkd29nYlhZZ0wyOXdkQzlsZEdNdmVISmhl
UzlqYjI1bQphV2R6THpBMFgyOTFkR0p2ZFc1a2N5NXFjMjl1TG01bGR5QXZiM0IwTDJWMFl5OTRj
bUY1TDJOdmJtWnBaM012TURSZmIzVjBZbTkxCmJtUnpMbXB6YjI0S0lHTndJQ0lrZEcxd0wzQnla
WFpwYjNWekxYTjFZbk5qY21sd2RHbHZiaTVxYzI5dUlpQWlKR1JoZEdFdWJtVjMKSWpzZ2JYWWdJ
aVJrWVhSaExtNWxkeUlnSWlSa1lYUmhJanNnYzNsdVl3b2dlR3RsWlc0Z0xYSmxjM1JoY25RZ1Bp
QWlKSFJ0Y0M5eQpiMnhzWW1GamF5NXNiMmNpSURJK0pqRWdmSHdnZEhKMVpRb2djMmdnTDI5d2RD
OWxkR012YVc1cGRDNWtMMU01T1hoclpXVnVMWEJoCmJtVnNJSE4wWVhKMElENHZaR1YyTDI1MWJH
d0tJR1ZqYUc4Z0oxTjBZWEowSUdaaGFXeGxaRHNnY0hKbGRtbHZkWE1nWTI5dVptbG4KZFhKaGRH
bHZiaUJ5WlhOMGIzSmxaQ2M3SUdWNGFYUWdNUXBtYVFwemFDQXZiM0IwTDJWMFl5OXBibWwwTG1R
dlV6azVlR3RsWlc0dApjR0Z1Wld3Z2MzUmhjblFnUGk5a1pYWXZiblZzYkFwcWNTQXRjaUF0TFdG
eVoycHpiMjRnYVNBaUpHbGtlQ0lnSnlKVFpXeGxZM1JsClpEb2dJaXN1YzJWeWRtVnljMXNrYVYw
dWJtRnRaU2NnSWlSa1lYUmhJZ289ClBBWUxPQURfRU5ECmJhc2U2NCAtZCA+IC9vcHQvc2Jpbi94
c3ViLWd1YXJkIDw8J1BBWUxPQURfRU5EJwpJeUV2WW1sdUwzTm9Dbk5sZENBdFpYVUtkVzFoYzJz
Z01EYzNDbVJwY2owdmIzQjBMMlYwWXk5NGEyVmxiaTF3WVc1bGJDOWtZWFJoCkNtUmhkR0U5SWlS
a2FYSXZjM1ZpYzJOeWFYQjBhVzl1TG1wemIyNGlDbWR2YjJROUlpUmthWEl2YzNWaWMyTnlhWEIw
YVc5dUxteGgKYzNRdFoyOXZaQzVxYzI5dUlncHRhMlJwY2lBdGNDQXZiM0IwTDNSdGNDOTRjMlZ5
ZG1WeUNtMXJaR2x5SUM5dmNIUXZkRzF3TDNoegpaWEoyWlhJdmMzVmljMk55YVhCMGFXOXVMV2Qx
WVhKa0xteHZZMnNnTWo0dlpHVjJMMjUxYkd3Z2ZId2daWGhwZENBd0NuUnRjRDBpCkpHUnBjaTh1
YzNWaWMyTnlhWEIwYVc5dUxXZDFZWEprTFNRa0lncDBjbUZ3SUNkeWJTQXRaaUFpSkhSdGNDSTdJ
SEp0WkdseUlDOXYKY0hRdmRHMXdMM2h6WlhKMlpYSXZjM1ZpYzJOeWFYQjBhVzl1TFdkMVlYSmtM
bXh2WTJzbklFVllTVlFnU0ZWUUlFbE9WQ0JVUlZKTgpDblpoYkdsa0tDa2dld29nV3lBdGN5QWlK
REVpSUYwZ0ppWWdhbkVnTFdVZ0ozUjVjR1U5UFNKdlltcGxZM1FpSUdGdVpDQW9Mbk5sCmNuWmxj
bk44ZEhsd1pUMDlJbUZ5Y21GNUlpQmhibVFnYkdWdVozUm9QakFwSUdGdVpDQW9MbUZqZEdsMlpW
OXBaSHgwZVhCbFBUMGkKYm5WdFltVnlJaWtnWVc1a0lHRnNiQ2d1YzJWeWRtVnljMXRkT3lBb0xu
SmhkMTkxY21sOGRIbHdaVDA5SW5OMGNtbHVaeUlnWVc1awpJSE4wWVhKMGMzZHBkR2dvSW5ac1pY
TnpPaTh2SWlrcEtTY2dJaVF4SWlBK0wyUmxkaTl1ZFd4c0lESStKakVLZlFwemJtRndjMmh2CmRD
Z3BJSHNLSUdOd0lDSWtaR0YwWVNJZ0lpUjBiWEFpSURJK0wyUmxkaTl1ZFd4c0lIeDhJSEpsZEhW
eWJpQXdDaUJwWmlCMllXeHAKWkNBaUpIUnRjQ0k3SUhSb1pXNEtJQ0JwWmlBaElHTnRjQ0F0Y3lB
aUpIUnRjQ0lnSWlSbmIyOWtJanNnZEdobGJnb2dJQ0J0ZGlBaQpKSFJ0Y0NJZ0lpUm5iMjlrSWdv
Z0lDQnplVzVqQ2lBZ1pta0tJR1pwQ24wS1kyRnpaU0FpSkhzeE9pMWphR1ZqYTNCdmFXNTBmU0ln
CmFXNEtJR05vWldOcmNHOXBiblFwSUhOdVlYQnphRzkwT3pzS0lISmxZMjkyWlhJcENpQnBaaUIy
WVd4cFpDQWlKR1JoZEdFaU95QjAKYUdWdUlITnVZWEJ6YUc5ME95QmxlR2wwSURBN0lHWnBDaUJw
WmlCYklDRWdMV1VnSWlSbmIyOWtJaUJkSUNZbUlHcHhJQzFsSUNjdQpjMlZ5ZG1WeWMzeDBlWEJs
UFQwaVlYSnlZWGtpSUdGdVpDQnNaVzVuZEdnOVBUQW5JQ0lrWkdGMFlTSWdQaTlrWlhZdmJuVnNi
Q0F5ClBpWXhPeUIwYUdWdUlHVjRhWFFnTURzZ1pta0tJSE52ZFhKalpUMG5Kd29nWm05eUlHTmhi
bVJwWkdGMFpTQnBiaUFpSkdkdmIyUWkKSUM5dmNIUXZaWFJqTDNoelpYSjJaWEl2YzNWaWMyTnlh
WEIwYVc5dUxuQnlaWFpwYjNWekxtcHpiMjQ3SUdSdkNpQWdhV1lnZG1GcwphV1FnSWlSallXNWth
V1JoZEdVaU95QjBhR1Z1SUhOdmRYSmpaVDBpSkdOaGJtUnBaR0YwWlNJN0lHSnlaV0ZyT3lCbWFR
b2daRzl1ClpRb2dhV1lnV3lBdGVpQWlKSE52ZFhKalpTSWdYVHNnZEdobGJnb2dJR3h2WjJkbGNp
QXRkQ0I0YTJWbGJpMXpkV0l0WjNWaGNtUWcKSjFOMVluTmpjbWx3ZEdsdmJpQnBiblpoYkdsa095
QnVieUIyWVd4cFpDQmlZV05yZFhBbkNpQWdaWGhwZENBeENpQm1hUW9nWTNBZwpJaVJ6YjNWeVky
VWlJQ0lrZEcxd0lnb2dZMmh0YjJRZ05qQXdJQ0lrZEcxd0lnb2diWFlnSWlSMGJYQWlJQ0lrWkdG
MFlTSUtJSE41CmJtTUtJSE51WVhCemFHOTBDaUJzYjJkblpYSWdMWFFnZUd0bFpXNHRjM1ZpTFdk
MVlYSmtJQ2RUZFdKelkzSnBjSFJwYjI0Z2NtVnoKZEc5eVpXUWdabkp2YlNCMllXeHBaR0YwWldR
Z1ltRmphM1Z3SndvZ096c0tJQ29wSUdWamFHOGdKMVZ6WVdkbE9pQjRjM1ZpTFdkMQpZWEprSUdO
b1pXTnJjRzlwYm5RZ2ZDQnlaV052ZG1WeUp6c2daWGhwZENBeE96c0taWE5oWXdvPQpQQVlMT0FE
X0VORAoKY2htb2QgNzAwIC9vcHQvc2Jpbi94c3ViIC9vcHQvc2Jpbi94c2VydmVyIC9vcHQvc2Jp
bi94c3ViLWd1YXJkCmZvciBzY3JpcHQgaW4geHN1YiB4c2VydmVyIHhzdWItZ3VhcmQ7IGRvIHNo
IC1uICIvb3B0L3NiaW4vJHNjcmlwdCI7IGRvbmUKY2F0ID4gL29wdC9ldGMvaW5pdC5kL1M5OXhr
ZWVuLXBhbmVsIDw8J1BBTkVMX0lOSVQnCiMhL2Jpbi9zaApFTkFCTEVEPXllcwpQUk9DUz0ieGtl
ZW4tcGFuZWwiCkFSR1M9Ii1jb25maWcgL29wdC9ldGMveGtlZW4tcGFuZWwvY29uZmlnLnlhbWwi
CkRFU0M9IlhLZWVuIFBhbmVsIgpQUkVBUkdTPSIiCmNhc2UgIiQxIiBpbgogc3RhcnR8cmVzdGFy
dCkgL29wdC9zYmluL3hzdWItZ3VhcmQgcmVjb3ZlciB8fCBleGl0IDE7Owogc3RvcHxraWxsKSAv
b3B0L3NiaW4veHN1Yi1ndWFyZCBjaGVja3BvaW50OzsKZXNhYwouIC9vcHQvZXRjL2luaXQuZC9y
Yy5mdW5jClBBTkVMX0lOSVQKIyBSZXVzZSBhbiBleGlzdGluZyBsaXN0ZW5lci4gT3RoZXJ3aXNl
IGNyZWF0ZSBhIHNlcGFyYXRlIGxvb3BiYWNrLW9ubHkgSFRUUCBzZXJ2aWNlLgpjYXQgPiAvb3B0
L2V0Yy94c2VydmVyL2xpZ2h0dHBkLmNvbmYgPDwnSFRUUF9DT05GSUcnCnNlcnZlci5kb2N1bWVu
dC1yb290ID0gIi9vcHQvdmFyL3N1YnNjcmlwdGlvbiIKc2VydmVyLmJpbmQgPSAiMTI3LjAuMC4x
IgpzZXJ2ZXIucG9ydCA9IDE4MDgwCnNlcnZlci5waWQtZmlsZSA9ICIvb3B0L3Zhci9ydW4veHN1
Yi1odHRwLnBpZCIKbWltZXR5cGUuYXNzaWduID0gKCAiLnR4dCIgPT4gInRleHQvcGxhaW4iICkK
SFRUUF9DT05GSUcKY2F0ID4gL29wdC9ldGMvaW5pdC5kL1M3OXhzdWItaHR0cCA8PCdIVFRQX0lO
SVQnCiMhL2Jpbi9zaApjYXNlICIkMSIgaW4KIHN0YXJ0KQogIG1rZGlyIC1wIC9vcHQvdmFyL3J1
biAvb3B0L3Zhci9zdWJzY3JpcHRpb24KICAvb3B0L2Jpbi9jdXJsIC1mc1MgLS1tYXgtdGltZSAy
IGh0dHA6Ly8xMjcuMC4wLjE6MTgwODAvdmxlc3MudHh0ID4vZGV2L251bGwgMj4mMSAmJiBleGl0
IDAKICAjIERvIG5vdCBjb21wZXRlIHdpdGggYW4gZXhpc3RpbmcgbGlzdGVuZXIsIGV2ZW4gaWYg
aXRzIHN1YnNjcmlwdGlvbiBpcyBub3QgcmVhZHkuCiAgbmV0c3RhdCAtbG50IDI+L2Rldi9udWxs
IHwgZ3JlcCAtcSAnMTI3LjAuMC4xOjE4MDgwICcgJiYgZXhpdCAwCiAgL29wdC9zYmluL2xpZ2h0
dHBkIC1mIC9vcHQvZXRjL3hzZXJ2ZXIvbGlnaHR0cGQuY29uZgogIDs7CiBzdG9wKQogIGlmIFsg
LXMgL29wdC92YXIvcnVuL3hzdWItaHR0cC5waWQgXTsgdGhlbgogICBwaWQ9JChjYXQgL29wdC92
YXIvcnVuL3hzdWItaHR0cC5waWQpCiAgIGNhc2UgIiRwaWQiIGluICcnfCpbITAtOV0qKSBleGl0
IDE7OyBlc2FjCiAgIGlmIFsgLXIgIi9wcm9jLyRwaWQvY21kbGluZSIgXSAmJiB0ciAnXDAwMCcg
JyAnIDwgIi9wcm9jLyRwaWQvY21kbGluZSIgfCBncmVwIC1xICcvb3B0L2V0Yy94c2VydmVyL2xp
Z2h0dHBkLmNvbmYnOyB0aGVuIGtpbGwgIiRwaWQiOyBmaQogIGZpCiAgOzsKIHJlc3RhcnQpICIk
MCIgc3RvcDsgIiQwIiBzdGFydDs7CiAqKSBlY2hvICdVc2FnZTogUzc5eHN1Yi1odHRwIHN0YXJ0
fHN0b3B8cmVzdGFydCc7IGV4aXQgMTs7CmVzYWMKSFRUUF9JTklUCmNobW9kIDc1NSAvb3B0L2V0
Yy9pbml0LmQvUzk5eGtlZW4tcGFuZWwgL29wdC9ldGMvaW5pdC5kL1M3OXhzdWItaHR0cAppZiBb
ICIkcm91dGluZyIgPSB5ZXMgXTsgdGhlbgogY3AgL29wdC9ldGMveHJheS9jb25maWdzLzA1X3Jv
dXRpbmcuanNvbiAiJGJhY2t1cC9yb3V0aW5nLWJlZm9yZS5qc29uIgogY2F0ID4gL29wdC9ldGMv
eHJheS9jb25maWdzLzA1X3JvdXRpbmcuanNvbi5uZXcgPDwnUk9VVElORycKeyJyb3V0aW5nIjp7
InJ1bGVzIjpbeyJ0eXBlIjoiZmllbGQiLCJpcCI6WyIxMC4wLjAuMC84IiwiMTcyLjE2LjAuMC8x
MiIsIjE5Mi4xNjguMC4wLzE2IiwiMTI3LjAuMC4wLzgiLCI6OjEvMTI4IiwiZmMwMDo6LzciLCJm
ZTgwOjovMTAiXSwib3V0Ym91bmRUYWciOiJkaXJlY3QifSx7InR5cGUiOiJmaWVsZCIsImluYm91
bmRUYWciOlsicmVkaXJlY3QiLCJ0cHJveHkiLCJmb3JjZS1wcm94eS1yZWRpcmVjdCIsImZvcmNl
LXByb3h5LXRwcm94eSJdLCJvdXRib3VuZFRhZyI6InZsZXNzLXJlYWxpdHkifV19fQpST1VUSU5H
CiBtdiAvb3B0L2V0Yy94cmF5L2NvbmZpZ3MvMDVfcm91dGluZy5qc29uLm5ldyAvb3B0L2V0Yy94
cmF5L2NvbmZpZ3MvMDVfcm91dGluZy5qc29uCiBlY2hvICdSb3V0aW5nIHByZXBhcmVkIGZvciB0
cmFuc3BhcmVudCBpbmJvdW5kcyAxMTgxLzExOTE7IHRha2VzIGVmZmVjdCBvbiBtYW51YWwgc2Vy
dmVyIHNlbGVjdGlvbi4nCmZpCihjcm9udGFiIC1sIDI+L2Rldi9udWxsIHx8IHRydWUpID4gIiR0
bXAvY3JvbnRhYiIKZ3JlcCAtcSAnL29wdC9zYmluL3hzdWItZ3VhcmQnICIkdG1wL2Nyb250YWIi
IHx8IGVjaG8gJyogKiAqICogKiAvb3B0L3NiaW4veHN1Yi1ndWFyZCBjaGVja3BvaW50ID4vZGV2
L251bGwgMj4mMScgPj4gIiR0bXAvY3JvbnRhYiIKY3JvbnRhYiAiJHRtcC9jcm9udGFiIgppZiAh
IHBpZG9mIGNyb25kID4vZGV2L251bGw7IHRoZW4gc2ggL29wdC9ldGMvaW5pdC5kL1MwNWNyb25k
IHN0YXJ0OyBmaQpzaCAvb3B0L2V0Yy9pbml0LmQvUzc5eHN1Yi1odHRwIHN0YXJ0CnNoIC9vcHQv
ZXRjL2luaXQuZC9TOTl4a2Vlbi1wYW5lbCBzdGFydApzeW5jCmVjaG8gIkluc3RhbGxlZC4gQmFj
a3VwOiAkYmFja3VwIgplY2hvICdOZXh0OiB4c3ViIGNoYW5nZTsgeHNlcnZlciAoc2VsZWN0IGEg
c2VydmVyIG1hbnVhbGx5KS4nCmVjaG8gJ1BhbmVsOiBodHRwOi8vMTkyLjE2OC4xLjE6MzAwMCA7
IGFzc2lnbiBjbGllbnRzIGFuZCBXQU4gcGVybWlzc2lvbnMgaW4gS2VlbmV0aWMgeW91cnNlbGYu
Jwo=
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
