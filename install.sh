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
ZFdKelkzSnBjSFJwYjI0bk95QmxlR2wwSURFN0lIMEtabWtLZEhJZwpMV1FnSjF4eUp5QThJQ0lr
ZEcxd0wyUmxZMjlrWldRaUlENGdJaVIwYlhBdlpHVmpiMlJsWkM1amJHVmhiaUk3SUcxMklDSWtk
RzF3CkwyUmxZMjlrWldRdVkyeGxZVzRpSUNJa2RHMXdMMlJsWTI5a1pXUWlDbk5sWkNBdGJpQW5M
MTUyYkdWemN6cGNMMXd2TDNBbklDSWsKZEcxd0wyUmxZMjlrWldRaUlENGdJaVIwYlhBdmRteGxj
M011ZEhoMElncGJJQzF6SUNJa2RHMXdMM1pzWlhOekxuUjRkQ0lnWFNCOApmQ0I3SUdWamFHOGdK
MDV2SUZaTVJWTlRJSE5sY25abGNuTTdJSEJ5WlhacGIzVnpJSE4xWW5OamNtbHdkR2x2YmlCclpY
QjBKenNnClpYaHBkQ0F4T3lCOUNqb2dQaUFpSkhSdGNDOXpaWEoyWlhKekxtcHpiMjVzSWdwcFBU
QUtkMmhwYkdVZ1NVWlRQU0J5WldGa0lDMXkKSUhWeWFUc2daRzhLSUc1aGJXVTlKSHQxY21raktp
TjlDaUFqSUZCUFUwbFlJSEJ5YVc1MFppQnpkWEJ3YjNKMGN5QnZZM1JoYkNCbApjMk5oY0dWek95
Qm9aWGhoWkdWamFXMWhiQ0JsYzJOaGNHVnpJR1JwWm1abGNpQmllU0J6YUdWc2JDNEtJRzVoYldV
OUpDaHdjbWx1CmRHWWdKeVZpSnlBaUpDaHdjbWx1ZEdZZ0p5VnpKeUFpSkc1aGJXVWlJSHdnVEVO
ZlFVeE1QVU1nWVhkcklDY0tJRUpGUjBsT0lIdG8KWlhnOUlqQXhNak0wTlRZM09EbGhZbU5rWldZ
aWZRb2dlMlp2Y2lBb2JqMHhPeUJ1UEQxc1pXNW5kR2dvSkRBcE95QnVLeXNwSUhzSwpJQ0FnWXox
emRXSnpkSElvSkRBc2Jpd3hLVHNnY0dGcGNqMTBiMnh2ZDJWeUtITjFZbk4wY2lna01DeHVLekVz
TWlrcENpQWdJR2xtCklDaGpQVDBpSlNJZ0ppWWdiR1Z1WjNSb0tIQmhhWElwUFQweUlDWW1JSEJo
YVhJZ2ZpQXZYbHN3TFRsaExXWmRXekF0T1dFdFpsMGsKTHlrZ2V3b2dJQ0FnSUdKNWRHVTlLR2x1
WkdWNEtHaGxlQ3h6ZFdKemRISW9jR0ZwY2l3eExERXBLUzB4S1NveE5pdHBibVJsZUNobwpaWGdz
YzNWaWMzUnlLSEJoYVhJc01pd3hLU2t0TVFvZ0lDQWdJSEJ5YVc1MFppQWlYRnd3SlRBemJ5SXNZ
bmwwWlRzZ2JpczlNZ29nCklDQjlJR1ZzYzJVZ2FXWWdLR005UFNKY1hDSXBJSEJ5YVc1MFppQWlY
RnhjWENJS0lDQWdaV3h6WlNCd2NtbHVkR1lnSWlWeklpeGoKQ2lCOWZTY3BJaWtLSUdWdVpIQnZh
VzUwUFNSN2RYSnBJeXBBZlRzZ1pXNWtjRzlwYm5ROUpIdGxibVJ3YjJsdWRDVWxYRDhxZlRzZwpa
VzVrY0c5cGJuUTlKSHRsYm1Sd2IybHVkQ1VsSXlwOUNpQmpZWE5sSUNJa1pXNWtjRzlwYm5RaUlH
bHVDaUFnWEZzcVhGMDZLaWtnCllXUmtjbVZ6Y3owa2UyVnVaSEJ2YVc1MEpUb3FmVHNnY0c5eWRE
MGtlMlZ1WkhCdmFXNTBJeU1xT24wN093b2dJRnhiS2x4ZEtTQmgKWkdSeVpYTnpQU1JsYm1Sd2Iy
bHVkRHNnY0c5eWREMDBORE03T3dvZ0lDbzZLaWtnWVdSa2NtVnpjejBrZTJWdVpIQnZhVzUwSlRv
cQpmVHNnY0c5eWREMGtlMlZ1WkhCdmFXNTBJeU1xT24wN093b2dJQ29wSUdGa1pISmxjM005SkdW
dVpIQnZhVzUwT3lCd2IzSjBQVFEwCk16czdDaUJsYzJGakNpQmhaR1J5WlhOelBTUjdZV1JrY21W
emN5TmNXMzA3SUdGa1pISmxjM005Skh0aFpHUnlaWE56SlZ4ZGZRb2cKWTJGelpTQWlKSFZ5YVNJ
Z2FXNGdLaWNqSnlvcElEczdJQ29wSUc1aGJXVTlKR0ZrWkhKbGMzTTdPeUJsYzJGakNpQnFjU0F0
Ym1NZwpMUzFoY21jZ2NtRjNJQ0lrZFhKcElpQXRMV0Z5WnlCdVlXMWxJQ0lrYm1GdFpTSWdMUzFo
Y21jZ1lXUmtjaUFpSkdGa1pISmxjM01pCklDMHRZWEpuYW5OdmJpQndiM0owSUNJa2NHOXlkQ0ln
TFMxaGNtZHFjMjl1SUdsa0lDSWthU0lnSjN0cFpEb2thV1FzYm1GdFpUb2sKYm1GdFpTeGhaR1J5
WlhOek9pUmhaR1J5TEhCdmNuUTZKSEJ2Y25Rc2NISnZkRzlqYjJ3NkluWnNaWE56SWl4aFkzUnBk
bVU2Wm1GcwpjMlVzYkdGMFpXNWplVjl0Y3pvdE1TeHlZWGRmZFhKcE9pUnlZWGQ5SnlBK1BpQWlK
SFJ0Y0M5elpYSjJaWEp6TG1wemIyNXNJZ29nCmFUMGtLQ2hwS3pFcEtRcGtiMjVsSUR3Z0lpUjBi
WEF2ZG14bGMzTXVkSGgwSWdwcWNTQXRjeUF0TFhOc2RYSndabWxzWlNCdmJHUWcKSWlSa1lYUmhJ
aUFuQ2lBb0pHOXNaRnN3WFM1elpYSjJaWEp6ZkcxaGNDaHpaV3hsWTNRb0xtRmpkR2wyWlNrcGZD
NWJNRjB1Y21GMwpYM1Z5YVNBdkx5QWlJaWtnWVhNZ0pHRmpkR2wyWlZWU1NTQjhDaUFvYldGd0tI
TmxiR1ZqZENndWNtRjNYM1Z5YVQwOUpHRmpkR2wyClpWVlNTU2twZkM1Yk1GMHVhV1FnTHk4Z0xU
RXBJR0Z6SUNSaFkzUnBkbVVnZkFvZ2UzVnliRG9pYUhSMGNEb3ZMekV5Tnk0d0xqQXUKTVRveE9E
QTRNQzkyYkdWemN5NTBlSFFpTEd4aGMzUmZkWEJrWVhSbFpEb29ibTkzZkhSdlpHRjBaU2tzWVdO
MGFYWmxYMmxrT2lSaApZM1JwZG1Vc2MyVnlkbVZ5Y3pwdFlYQW9MbUZqZEdsMlpUMG9MbWxrUFQw
a1lXTjBhWFpsS1NsOUNpY2dJaVIwYlhBdmMyVnlkbVZ5CmN5NXFjMjl1YkNJZ1BpQWlKSFJ0Y0M5
emRXSnpZM0pwY0hScGIyNHVhbk52YmlJS1d5QXRjeUFpSkhSdGNDOXpkV0p6WTNKcGNIUnAKYjI0
dWFuTnZiaUlnWFNCOGZDQjdJR1ZqYUc4Z0owTmhibTV2ZENCd2NtVnpaWEoyWlNCaFkzUnBkbVVn
YzJWeWRtVnlKenNnWlhocApkQ0F4T3lCOUNtTndJQ0lrWkdGMFlTSWdJaVJ5YjI5MEwzTjFZbk5q
Y21sd2RHbHZiaTV3Y21WMmFXOTFjeTVxYzI5dUlncHphQ0F2CmIzQjBMMlYwWXk5cGJtbDBMbVF2
VXprNWVHdGxaVzR0Y0dGdVpXd2djM1J2Y0NBK0wyUmxkaTl1ZFd4c0NtTndJQ0lrZEcxd0wzWnMK
WlhOekxuUjRkQ0lnTDI5d2RDOTJZWEl2YzNWaWMyTnlhWEIwYVc5dUwzWnNaWE56TG5SNGRDNXVa
WGNLYlhZZ0wyOXdkQzkyWVhJdgpjM1ZpYzJOeWFYQjBhVzl1TDNac1pYTnpMblI0ZEM1dVpYY2dM
Mjl3ZEM5MllYSXZjM1ZpYzJOeWFYQjBhVzl1TDNac1pYTnpMblI0CmRBcGpjQ0FpSkhSdGNDOXpk
V0p6WTNKcGNIUnBiMjR1YW5OdmJpSWdJaVJrWVhSaExtNWxkeUk3SUcxMklDSWtaR0YwWVM1dVpY
Y2kKSUNJa1pHRjBZU0k3SUhONWJtTUthV1lnV3lBaUpHMXZaR1VpSUNFOUlHbHRjRzl5ZENCZE95
QjBhR1Z1Q2lCamNDQWlKSFJ0Y0M5aQpiMlI1SWlBdmIzQjBMM1poY2k5emRXSnpZM0pwY0hScGIy
NHZiM1psY25OMVlpNTBlSFF1Ym1WM0NpQnRkaUF2YjNCMEwzWmhjaTl6CmRXSnpZM0pwY0hScGIy
NHZiM1psY25OMVlpNTBlSFF1Ym1WM0lDOXZjSFF2ZG1GeUwzTjFZbk5qY21sd2RHbHZiaTl2ZG1W
eWMzVmkKTG5SNGRBcG1hUXBwWmlCYklDSWtiVzlrWlNJZ1BTQmphR0Z1WjJVZ1hUc2dkR2hsYmdv
Z1kzQWdJaVIwYlhBdmMyOTFjbU5sTFhWeQpiQ0lnSWlSeWIyOTBMM052ZFhKalpTMTFjbXd1Ym1W
M0lnb2diWFlnSWlSeWIyOTBMM052ZFhKalpTMTFjbXd1Ym1WM0lpQWlKSEp2CmIzUXZjMjkxY21O
bExYVnliQ0lLWm1rS2MzbHVZd3B6YUNBdmIzQjBMMlYwWXk5cGJtbDBMbVF2VXprNWVHdGxaVzR0
Y0dGdVpXd2cKYzNSaGNuUWdQaTlrWlhZdmJuVnNiQXBsWTJodklDSldURVZUVXlCelpYSjJaWEp6
T2lBa2FTNGdRV04wYVhabElGaHlZWGtnWTI5dQpibVZqZEdsdmJpQjFibU5vWVc1blpXUXVJZ3Bw
WmlCYklDSWtLR3B4SUMxeUlDY3VZV04wYVhabFgybGtKeUFpSkdSaGRHRWlLU0lnClBTQXRNU0Jk
T3lCMGFHVnVDaUJsWTJodklDZFFjbVYyYVc5MWN5QnpaWEoyWlhJZ2JtOTBJR2x1SUc1bGR5QnNh
WE4wTGlCVFpXeGwKWTNRZ1lTQnpaWEoyWlhJZ2JXRnVkV0ZzYkhrdUp3cG1hUW89ClBBWUxPQURf
RU5ECmJhc2U2NCAtZCA+IC9vcHQvc2Jpbi94c2VydmVyIDw8J1BBWUxPQURfRU5EJwpJeUV2WW1s
dUwzTm9Dbk5sZENBdFpYVUtkVzFoYzJzZ01EYzNDbVJoZEdFOUwyOXdkQzlsZEdNdmVHdGxaVzR0
Y0dGdVpXd3ZaR0YwCllTOXpkV0p6WTNKcGNIUnBiMjR1YW5OdmJncGpiV1E5SkhzeE9pMXRaVzUx
ZlFwc2FYTjBLQ2tnZXlCcWNTQXRjaUFuTG5ObGNuWmwKY25OYlhTQjhJQ0pjS0M1cFpDc3hLVngw
WENocFppQXVZV04wYVhabElIUm9aVzRnSWlvaUlHVnNjMlVnSWlBaUlHVnVaQ2tnWENndQpibUZ0
WlNsY2RGd29MbXhoZEdWdVkzbGZiWE1wSUcxeklpY2dJaVJrWVhSaElqc2dmUXBwWmlCYklDSWtZ
MjFrSWlBOUlHMWxiblVnClhUc2dkR2hsYmdvZ2JHbHpkQW9nY0hKcGJuUm1JQ2RPZFcxaVpYSWdk
RzhnYzNkcGRHTm9MQ0J3SUU1VlRVSkZVaUIwYnlCMFpYTjAKTENCeElIUnZJSEYxYVhRNklDY0tJ
RWxHVXowZ2NtVmhaQ0F0Y2lCcGJuQjFkQW9nWTJGelpTQWlKR2x1Y0hWMElpQnBiaUJ4ZkNjbgpL
U0JsZUdsMElEQTdPeUJ3WENBcUtTQmpiV1E5Y0dsdVp6c2diajBrZTJsdWNIVjBJM0FnZlRzN0lD
b3BJR050WkQxMWMyVTdJRzQ5CkpHbHVjSFYwT3pzZ1pYTmhZd3BsYkdsbUlGc2dJaVJqYldRaUlE
MGdiR2x6ZENCZE95QjBhR1Z1SUd4cGMzUTdJR1Y0YVhRZ01BcGwKYkhObElHNDlKSHN5T2kxOU95
Qm1hUXBqWVhObElDSWtZMjFrSWlCcGJpQndhVzVuZkhWelpTa2dPenNnS2lrZ1pXTm9ieUFuVlhO
aApaMlU2SUhoelpYSjJaWElnVzJ4cGMzUWdmQ0J3YVc1bklFNVZUVUpGVWlCOElIVnpaU0JPVlUx
Q1JWSmRKenNnWlhocGRDQXhPenNnClpYTmhZd3BqWVhObElDSWtiaUlnYVc0Z0p5ZDhLbHNoTUMw
NVhTb3BJR1ZqYUc4Z0owbHVkbUZzYVdRZ2JuVnRZbVZ5SnpzZ1pYaHAKZENBeE96c2daWE5oWXdw
cFpIZzlKQ2dvYmkweEtTa0thbkVnTFdVZ0xTMWhjbWRxYzI5dUlHa2dJaVJwWkhnaUlDY3VjMlZ5
ZG1WeQpjMXNrYVYwZ0lUMGdiblZzYkNCaGJtUWdKR2srUFRBbklDSWtaR0YwWVNJZ1BpOWtaWFl2
Ym5Wc2JDQjhmQ0I3SUdWamFHOGdKMDV2CklITjFZMmdnYzJWeWRtVnlKenNnWlhocGRDQXhPeUI5
Q20xclpHbHlJQzF3SUM5dmNIUXZkRzF3TDNoelpYSjJaWElLYld0a2FYSWcKTDI5d2RDOTBiWEF2
ZUhObGNuWmxjaTFqYkdrdWJHOWpheUF5UGk5a1pYWXZiblZzYkNCOGZDQjdJR1ZqYUc4Z0owRnVi
M1JvWlhJZwpiM0JsY21GMGFXOXVJR2x6SUhKMWJtNXBibWNuT3lCbGVHbDBJREU3SUgwS2RHMXdQ
U1FvYld0MFpXMXdJQzFrSUM5dmNIUXZkRzF3CkwzaHpaWEoyWlhJdlkyeHBMbGhZV0ZoWVdDa0tj
R2xrUFNjbkNtTnNaV0Z1ZFhBb0tTQjdJRnNnTFhvZ0lpUndhV1FpSUYwZ2ZId2cKYTJsc2JDQWlK
SEJwWkNJZ01qNHZaR1YyTDI1MWJHd2dmSHdnZEhKMVpUc2djbTBnTFdZZ0wyOXdkQzkyWVhJdmMz
VmljMk55YVhCMAphVzl1TDJOb2IybGpaUzUwZUhRN0lISnRJQzF5WmlBaUpIUnRjQ0k3SUhKdFpH
bHlJQzl2Y0hRdmRHMXdMM2h6WlhKMlpYSXRZMnhwCkxteHZZMnM3SUgwS2RISmhjQ0JqYkdWaGJu
VndJRVZZU1ZRZ1NGVlFJRWxPVkNCVVJWSk5DbXB4SUMxeUlDMHRZWEpuYW5OdmJpQnAKSUNJa2FX
UjRJaUFuTG5ObGNuWmxjbk5iSkdsZExuSmhkMTkxY21rbklDSWtaR0YwWVNJZ1BpQXZiM0IwTDNa
aGNpOXpkV0p6WTNKcApjSFJwYjI0dlkyaHZhV05sTG5SNGRBb3ZiM0IwTDNOaWFXNHZlR3RsWlc0
dGMzVmljMk55YVhCMGFXOXVMWGRoZEdOb1pYSWdMUzF6CmFXNW5iR1V0Y0hKdmVIa2dMUzF1Ynkx
eVpYTjBZWEowSUMwdGIzVjBjSFYwTFdScGNpQWlKSFJ0Y0NJZ0oyTm9iMmxqWlQxb2RIUncKT2k4
dk1USTNMakF1TUM0eE9qRTRNRGd3TDJOb2IybGpaUzUwZUhRbklENGdJaVIwYlhBdlkyOXVkbVZ5
ZEM1c2IyY2lJREkrSmpFSwphbkVnTFdVZ0p5NXZkWFJpYjNWdVpITjhiR1Z1WjNSb1BUMHhKeUFp
SkhSdGNDOHdORjl2ZFhSaWIzVnVaSE11WTJodmFXTmxMbXB6CmIyNGlJRDR2WkdWMkwyNTFiR3dL
YVdZZ1d5QWlKR050WkNJZ1BTQndhVzVuSUYwN0lIUm9aVzRLSUdweElDZDdiRzluT250c2IyZHMK
WlhabGJEb2lkMkZ5Ym1sdVp5SjlMR2x1WW05MWJtUnpPbHQ3YkdsemRHVnVPaUl4TWpjdU1DNHdM
akVpTEhCdmNuUTZNVEU0T1N4dwpjbTkwYjJOdmJEb2ljMjlqYTNNaUxITmxkSFJwYm1kek9udGhk
WFJvT2lKdWIyRjFkR2dpTEhWa2NEcG1ZV3h6WlgxOVhTeHZkWFJpCmIzVnVaSE02TG05MWRHSnZk
VzVrYzMwbklDSWtkRzF3THpBMFgyOTFkR0p2ZFc1a2N5NWphRzlwWTJVdWFuTnZiaUlnUGlBaUpI
UnQKY0M5d2NtOWlaUzVxYzI5dUlnb2dMMjl3ZEM5elltbHVMM2h5WVhrZ2NuVnVJQzEwWlhOMElD
MWpJQ0lrZEcxd0wzQnliMkpsTG1wegpiMjRpSUQ0Z0lpUjBiWEF2Y0hKdlltVXViRzluSWlBeVBp
WXhDaUF2YjNCMEwzTmlhVzR2ZUhKaGVTQnlkVzRnTFdNZ0lpUjBiWEF2CmNISnZZbVV1YW5OdmJp
SWdQajRnSWlSMGJYQXZjSEp2WW1VdWJHOW5JaUF5UGlZeElDWWdjR2xrUFNRaENpQnpiR1ZsY0NB
eENpQnEKY1NBdGNpQXRMV0Z5WjJwemIyNGdhU0FpSkdsa2VDSWdKeTV6WlhKMlpYSnpXeVJwWFM1
dVlXMWxKeUFpSkdSaGRHRWlDaUJ5WlhOMQpiSFE5SkNoamRYSnNJQzB0Y0hKdmVIa2djMjlqYTNN
MWFEb3ZMekV5Tnk0d0xqQXVNVG94TVRnNUlDMHRZMjl1Ym1WamRDMTBhVzFsCmIzVjBJRFVnTFMx
dFlYZ3RkR2x0WlNBeE1pQXRjMU1nTFc4Z0wyUmxkaTl1ZFd4c0lDMTNJQ2NsZTJoMGRIQmZZMjlr
WlgwZ0pYdDAKYVcxbFgzUnZkR0ZzZlNjZ2FIUjBjSE02THk5M2QzY3VaM04wWVhScFl5NWpiMjB2
WjJWdVpYSmhkR1ZmTWpBMEtTQjhmQ0I3SUdWagphRzhnSjFCeWIzaDVJSEpsY1hWbGMzUWdabUZw
YkdWa0p6c2daWGhwZENBeE95QjlDaUJqYjJSbFBTUjdjbVZ6ZFd4MEpTVWdLbjA3CklHVnNZWEJ6
WldROUpIdHlaWE4xYkhRaktpQjlDaUJsWTJodklDSklWRlJRSUNSamIyUmxPeUJtZFd4c0lFaFVW
RkJUSUhKbGNYVmwKYzNRZ0pHVnNZWEJ6WldRZ2N5SUtJRnNnSWlSamIyUmxJaUE5SURJd05DQmRJ
SHg4SUhzZ1pXTm9ieUFuVlc1bGVIQmxZM1JsWkNCbwpaV0ZzZEdndFkyaGxZMnNnY21WemNHOXVj
MlVuT3lCbGVHbDBJREU3SUgwS0lHVjRhWFFLWm1rS2FuRWdKM3R2ZFhSaWIzVnVaSE02ClczdDBZ
V2M2SW1ScGNtVmpkQ0lzY0hKdmRHOWpiMnc2SW1aeVpXVmtiMjBpZlN4N2RHRm5PaUppYkc5amF5
SXNjSEp2ZEc5amIydzYKSW1Kc1lXTnJhRzlzWlNKOUxDZ3ViM1YwWW05MWJtUnpXekJkZkM1MFlX
YzlJblpzWlhOekxYSmxZV3hwZEhraUtWMTlKeUFpSkhSdApjQzh3TkY5dmRYUmliM1Z1WkhNdVky
aHZhV05sTG1wemIyNGlJRDRnSWlSMGJYQXZiM1YwWW05MWJtUnpMbXB6YjI0aUNtMXJaR2x5CklD
SWtkRzF3TDNOMFlXZGxJZ3BqY0NBdmIzQjBMMlYwWXk5NGNtRjVMMk52Ym1acFozTXZLaTVxYzI5
dUlDSWtkRzF3TDNOMFlXZGwKTHlJS1kzQWdJaVIwYlhBdmIzVjBZbTkxYm1SekxtcHpiMjRpSUNJ
a2RHMXdMM04wWVdkbEx6QTBYMjkxZEdKdmRXNWtjeTVxYzI5dQpJZ292YjNCMEwzTmlhVzR2ZUhK
aGVTQnlkVzRnTFhSbGMzUWdMV052Ym1aa2FYSWdJaVIwYlhBdmMzUmhaMlVpSUQ0Z0lpUjBiWEF2
CmRHVnpkQzVzYjJjaUlESStKakVLWTNBZ0wyOXdkQzlsZEdNdmVISmhlUzlqYjI1bWFXZHpMekEw
WDI5MWRHSnZkVzVrY3k1cWMyOXUKSUNJa2RHMXdMM0J5WlhacGIzVnpMbXB6YjI0aUNtTndJQ0lr
WkdGMFlTSWdJaVIwYlhBdmNISmxkbWx2ZFhNdGMzVmljMk55YVhCMAphVzl1TG1wemIyNGlDbXB4
SUMwdFlYSm5hbk52YmlCcElDSWthV1I0SWlBbkxtRmpkR2wyWlY5cFpEMGthU0I4SUM1elpYSjJa
WEp6CklIdzlJRzFoY0NndVlXTjBhWFpsUFNndWFXUTlQU1JwS1NrbklDSWtaR0YwWVNJZ1BpQWlK
SFJ0Y0M5emRXSnpZM0pwY0hScGIyNHUKYW5OdmJpSUtjMmdnTDI5d2RDOWxkR012YVc1cGRDNWtM
MU01T1hoclpXVnVMWEJoYm1Wc0lITjBiM0FnUGk5a1pYWXZiblZzYkFwagpjQ0FpSkhSdGNDOXZk
WFJpYjNWdVpITXVhbk52YmlJZ0wyOXdkQzlsZEdNdmVISmhlUzlqYjI1bWFXZHpMekEwWDI5MWRH
SnZkVzVrCmN5NXFjMjl1TG01bGR3cHRkaUF2YjNCMEwyVjBZeTk0Y21GNUwyTnZibVpwWjNNdk1E
UmZiM1YwWW05MWJtUnpMbXB6YjI0dWJtVjMKSUM5dmNIUXZaWFJqTDNoeVlYa3ZZMjl1Wm1sbmN5
OHdORjl2ZFhSaWIzVnVaSE11YW5OdmJncGpjQ0FpSkhSdGNDOXpkV0p6WTNKcApjSFJwYjI0dWFu
TnZiaUlnSWlSa1lYUmhMbTVsZHlJN0lHMTJJQ0lrWkdGMFlTNXVaWGNpSUNJa1pHRjBZU0k3SUhO
NWJtTUtjbVZ6CmRHRnlkRjl2YXoxNVpYTUtlR3RsWlc0Z0xYSmxjM1JoY25RZ1BpQWlKSFJ0Y0M5
eVpYTjBZWEowTG14dlp5SWdNajRtTVNCOGZDQnkKWlhOMFlYSjBYMjlyUFc1dkNuTnNaV1Z3SURJ
S2FXWWdXeUFpSkhKbGMzUmhjblJmYjJzaUlEMGdibThnWFNCOGZDQWhJSEJwWkc5bQpJSGh5WVhr
Z1BpOWtaWFl2Ym5Wc2JEc2dkR2hsYmdvZ1kzQWdJaVIwYlhBdmNISmxkbWx2ZFhNdWFuTnZiaUln
TDI5d2RDOWxkR012CmVISmhlUzlqYjI1bWFXZHpMekEwWDI5MWRHSnZkVzVrY3k1cWMyOXVMbTVs
ZHdvZ2JYWWdMMjl3ZEM5bGRHTXZlSEpoZVM5amIyNW0KYVdkekx6QTBYMjkxZEdKdmRXNWtjeTVx
YzI5dUxtNWxkeUF2YjNCMEwyVjBZeTk0Y21GNUwyTnZibVpwWjNNdk1EUmZiM1YwWW05MQpibVJ6
TG1wemIyNEtJR053SUNJa2RHMXdMM0J5WlhacGIzVnpMWE4xWW5OamNtbHdkR2x2Ymk1cWMyOXVJ
aUFpSkdSaGRHRXVibVYzCklqc2diWFlnSWlSa1lYUmhMbTVsZHlJZ0lpUmtZWFJoSWpzZ2MzbHVZ
d29nZUd0bFpXNGdMWEpsYzNSaGNuUWdQaUFpSkhSdGNDOXkKYjJ4c1ltRmpheTVzYjJjaUlESStK
akVnZkh3Z2RISjFaUW9nYzJnZ0wyOXdkQzlsZEdNdmFXNXBkQzVrTDFNNU9YaHJaV1Z1TFhCaApi
bVZzSUhOMFlYSjBJRDR2WkdWMkwyNTFiR3dLSUdWamFHOGdKMU4wWVhKMElHWmhhV3hsWkRzZ2NI
SmxkbWx2ZFhNZ1kyOXVabWxuCmRYSmhkR2x2YmlCeVpYTjBiM0psWkNjN0lHVjRhWFFnTVFwbWFR
cHphQ0F2YjNCMEwyVjBZeTlwYm1sMExtUXZVems1ZUd0bFpXNHQKY0dGdVpXd2djM1JoY25RZ1Bp
OWtaWFl2Ym5Wc2JBcHFjU0F0Y2lBdExXRnlaMnB6YjI0Z2FTQWlKR2xrZUNJZ0p5SlRaV3hsWTNS
bApaRG9nSWlzdWMyVnlkbVZ5YzFza2FWMHVibUZ0WlNjZ0lpUmtZWFJoSWdvPQpQQVlMT0FEX0VO
RApiYXNlNjQgLWQgPiAvb3B0L3NiaW4veHN1Yi1ndWFyZCA8PCdQQVlMT0FEX0VORCcKSXlFdllt
bHVMM05vQ25ObGRDQXRaWFVLZFcxaGMyc2dNRGMzQ21ScGNqMHZiM0IwTDJWMFl5OTRhMlZsYmkx
d1lXNWxiQzlrWVhSaApDbVJoZEdFOUlpUmthWEl2YzNWaWMyTnlhWEIwYVc5dUxtcHpiMjRpQ21k
dmIyUTlJaVJrYVhJdmMzVmljMk55YVhCMGFXOXVMbXhoCmMzUXRaMjl2WkM1cWMyOXVJZ3B0YTJS
cGNpQXRjQ0F2YjNCMEwzUnRjQzk0YzJWeWRtVnlDbTFyWkdseUlDOXZjSFF2ZEcxd0wzaHoKWlhK
MlpYSXZjM1ZpYzJOeWFYQjBhVzl1TFdkMVlYSmtMbXh2WTJzZ01qNHZaR1YyTDI1MWJHd2dmSHdn
WlhocGRDQXdDblJ0Y0QwaQpKR1JwY2k4dWMzVmljMk55YVhCMGFXOXVMV2QxWVhKa0xTUWtJZ3Aw
Y21Gd0lDZHliU0F0WmlBaUpIUnRjQ0k3SUhKdFpHbHlJQzl2CmNIUXZkRzF3TDNoelpYSjJaWEl2
YzNWaWMyTnlhWEIwYVc5dUxXZDFZWEprTG14dlkyc25JRVZZU1ZRZ1NGVlFJRWxPVkNCVVJWSk4K
Q25aaGJHbGtLQ2tnZXdvZ1d5QXRjeUFpSkRFaUlGMGdKaVlnYW5FZ0xXVWdKM1I1Y0dVOVBTSnZZ
bXBsWTNRaUlHRnVaQ0FvTG5ObApjblpsY25OOGRIbHdaVDA5SW1GeWNtRjVJaUJoYm1RZ2JHVnVa
M1JvUGpBcElHRnVaQ0FvTG1GamRHbDJaVjlwWkh4MGVYQmxQVDBpCmJuVnRZbVZ5SWlrZ1lXNWtJ
R0ZzYkNndWMyVnlkbVZ5YzF0ZE95QW9MbkpoZDE5MWNtbDhkSGx3WlQwOUluTjBjbWx1WnlJZ1lX
NWsKSUhOMFlYSjBjM2RwZEdnb0luWnNaWE56T2k4dklpa3BLU2NnSWlReElpQStMMlJsZGk5dWRX
eHNJREkrSmpFS2ZRcHpibUZ3YzJodgpkQ2dwSUhzS0lHTndJQ0lrWkdGMFlTSWdJaVIwYlhBaUlE
SStMMlJsZGk5dWRXeHNJSHg4SUhKbGRIVnliaUF3Q2lCcFppQjJZV3hwClpDQWlKSFJ0Y0NJN0lI
Um9aVzRLSUNCcFppQWhJR050Y0NBdGN5QWlKSFJ0Y0NJZ0lpUm5iMjlrSWpzZ2RHaGxiZ29nSUNC
dGRpQWkKSkhSdGNDSWdJaVJuYjI5a0lnb2dJQ0J6ZVc1akNpQWdabWtLSUdacENuMEtZMkZ6WlNB
aUpIc3hPaTFqYUdWamEzQnZhVzUwZlNJZwphVzRLSUdOb1pXTnJjRzlwYm5RcElITnVZWEJ6YUc5
ME96c0tJSEpsWTI5MlpYSXBDaUJwWmlCMllXeHBaQ0FpSkdSaGRHRWlPeUIwCmFHVnVJSE51WVhC
emFHOTBPeUJsZUdsMElEQTdJR1pwQ2lCcFppQmJJQ0VnTFdVZ0lpUm5iMjlrSWlCZElDWW1JR3B4
SUMxbElDY3UKYzJWeWRtVnljM3gwZVhCbFBUMGlZWEp5WVhraUlHRnVaQ0JzWlc1bmRHZzlQVEFu
SUNJa1pHRjBZU0lnUGk5a1pYWXZiblZzYkNBeQpQaVl4T3lCMGFHVnVJR1Y0YVhRZ01Ec2dabWtL
SUhOdmRYSmpaVDBuSndvZ1ptOXlJR05oYm1ScFpHRjBaU0JwYmlBaUpHZHZiMlFpCklDOXZjSFF2
WlhSakwzaHpaWEoyWlhJdmMzVmljMk55YVhCMGFXOXVMbkJ5WlhacGIzVnpMbXB6YjI0N0lHUnZD
aUFnYVdZZ2RtRnMKYVdRZ0lpUmpZVzVrYVdSaGRHVWlPeUIwYUdWdUlITnZkWEpqWlQwaUpHTmhi
bVJwWkdGMFpTSTdJR0p5WldGck95Qm1hUW9nWkc5dQpaUW9nYVdZZ1d5QXRlaUFpSkhOdmRYSmpa
U0lnWFRzZ2RHaGxiZ29nSUd4dloyZGxjaUF0ZENCNGEyVmxiaTF6ZFdJdFozVmhjbVFnCkoxTjFZ
bk5qY21sd2RHbHZiaUJwYm5aaGJHbGtPeUJ1YnlCMllXeHBaQ0JpWVdOcmRYQW5DaUFnWlhocGRD
QXhDaUJtYVFvZ1kzQWcKSWlSemIzVnlZMlVpSUNJa2RHMXdJZ29nWTJodGIyUWdOakF3SUNJa2RH
MXdJZ29nYlhZZ0lpUjBiWEFpSUNJa1pHRjBZU0lLSUhONQpibU1LSUhOdVlYQnphRzkwQ2lCc2Iy
ZG5aWElnTFhRZ2VHdGxaVzR0YzNWaUxXZDFZWEprSUNkVGRXSnpZM0pwY0hScGIyNGdjbVZ6CmRH
OXlaV1FnWm5KdmJTQjJZV3hwWkdGMFpXUWdZbUZqYTNWd0p3b2dPenNLSUNvcElHVmphRzhnSjFW
ellXZGxPaUI0YzNWaUxXZDEKWVhKa0lHTm9aV05yY0c5cGJuUWdmQ0J5WldOdmRtVnlKenNnWlho
cGRDQXhPenNLWlhOaFl3bz0KUEFZTE9BRF9FTkQKCmNobW9kIDcwMCAvb3B0L3NiaW4veHN1YiAv
b3B0L3NiaW4veHNlcnZlciAvb3B0L3NiaW4veHN1Yi1ndWFyZApmb3Igc2NyaXB0IGluIHhzdWIg
eHNlcnZlciB4c3ViLWd1YXJkOyBkbyBzaCAtbiAiL29wdC9zYmluLyRzY3JpcHQiOyBkb25lCmNh
dCA+IC9vcHQvZXRjL2luaXQuZC9TOTl4a2Vlbi1wYW5lbCA8PCdQQU5FTF9JTklUJwojIS9iaW4v
c2gKRU5BQkxFRD15ZXMKUFJPQ1M9InhrZWVuLXBhbmVsIgpBUkdTPSItY29uZmlnIC9vcHQvZXRj
L3hrZWVuLXBhbmVsL2NvbmZpZy55YW1sIgpERVNDPSJYS2VlbiBQYW5lbCIKUFJFQVJHUz0iIgpj
YXNlICIkMSIgaW4KIHN0YXJ0fHJlc3RhcnQpIC9vcHQvc2Jpbi94c3ViLWd1YXJkIHJlY292ZXIg
fHwgZXhpdCAxOzsKIHN0b3B8a2lsbCkgL29wdC9zYmluL3hzdWItZ3VhcmQgY2hlY2twb2ludDs7
CmVzYWMKLiAvb3B0L2V0Yy9pbml0LmQvcmMuZnVuYwpQQU5FTF9JTklUCiMgUmV1c2UgYW4gZXhp
c3RpbmcgbGlzdGVuZXIuIE90aGVyd2lzZSBjcmVhdGUgYSBzZXBhcmF0ZSBsb29wYmFjay1vbmx5
IEhUVFAgc2VydmljZS4KY2F0ID4gL29wdC9ldGMveHNlcnZlci9saWdodHRwZC5jb25mIDw8J0hU
VFBfQ09ORklHJwpzZXJ2ZXIuZG9jdW1lbnQtcm9vdCA9ICIvb3B0L3Zhci9zdWJzY3JpcHRpb24i
CnNlcnZlci5iaW5kID0gIjEyNy4wLjAuMSIKc2VydmVyLnBvcnQgPSAxODA4MApzZXJ2ZXIucGlk
LWZpbGUgPSAiL29wdC92YXIvcnVuL3hzdWItaHR0cC5waWQiCm1pbWV0eXBlLmFzc2lnbiA9ICgg
Ii50eHQiID0+ICJ0ZXh0L3BsYWluIiApCkhUVFBfQ09ORklHCmNhdCA+IC9vcHQvZXRjL2luaXQu
ZC9TNzl4c3ViLWh0dHAgPDwnSFRUUF9JTklUJwojIS9iaW4vc2gKY2FzZSAiJDEiIGluCiBzdGFy
dCkKICBta2RpciAtcCAvb3B0L3Zhci9ydW4gL29wdC92YXIvc3Vic2NyaXB0aW9uCiAgL29wdC9i
aW4vY3VybCAtZnNTIC0tbWF4LXRpbWUgMiBodHRwOi8vMTI3LjAuMC4xOjE4MDgwL3ZsZXNzLnR4
dCA+L2Rldi9udWxsIDI+JjEgJiYgZXhpdCAwCiAgIyBEbyBub3QgY29tcGV0ZSB3aXRoIGFuIGV4
aXN0aW5nIGxpc3RlbmVyLCBldmVuIGlmIGl0cyBzdWJzY3JpcHRpb24gaXMgbm90IHJlYWR5Lgog
IG5ldHN0YXQgLWxudCAyPi9kZXYvbnVsbCB8IGdyZXAgLXEgJzEyNy4wLjAuMToxODA4MCAnICYm
IGV4aXQgMAogIC9vcHQvc2Jpbi9saWdodHRwZCAtZiAvb3B0L2V0Yy94c2VydmVyL2xpZ2h0dHBk
LmNvbmYKICA7Owogc3RvcCkKICBpZiBbIC1zIC9vcHQvdmFyL3J1bi94c3ViLWh0dHAucGlkIF07
IHRoZW4KICAgcGlkPSQoY2F0IC9vcHQvdmFyL3J1bi94c3ViLWh0dHAucGlkKQogICBjYXNlICIk
cGlkIiBpbiAnJ3wqWyEwLTldKikgZXhpdCAxOzsgZXNhYwogICBpZiBbIC1yICIvcHJvYy8kcGlk
L2NtZGxpbmUiIF0gJiYgdHIgJ1wwMDAnICcgJyA8ICIvcHJvYy8kcGlkL2NtZGxpbmUiIHwgZ3Jl
cCAtcSAnL29wdC9ldGMveHNlcnZlci9saWdodHRwZC5jb25mJzsgdGhlbiBraWxsICIkcGlkIjsg
ZmkKICBmaQogIDs7CiByZXN0YXJ0KSAiJDAiIHN0b3A7ICIkMCIgc3RhcnQ7OwogKikgZWNobyAn
VXNhZ2U6IFM3OXhzdWItaHR0cCBzdGFydHxzdG9wfHJlc3RhcnQnOyBleGl0IDE7Owplc2FjCkhU
VFBfSU5JVApjaG1vZCA3NTUgL29wdC9ldGMvaW5pdC5kL1M5OXhrZWVuLXBhbmVsIC9vcHQvZXRj
L2luaXQuZC9TNzl4c3ViLWh0dHAKaWYgWyAiJHJvdXRpbmciID0geWVzIF07IHRoZW4KIGNwIC9v
cHQvZXRjL3hyYXkvY29uZmlncy8wNV9yb3V0aW5nLmpzb24gIiRiYWNrdXAvcm91dGluZy1iZWZv
cmUuanNvbiIKIGNhdCA+IC9vcHQvZXRjL3hyYXkvY29uZmlncy8wNV9yb3V0aW5nLmpzb24ubmV3
IDw8J1JPVVRJTkcnCnsicm91dGluZyI6eyJydWxlcyI6W3sidHlwZSI6ImZpZWxkIiwiaXAiOlsi
MTAuMC4wLjAvOCIsIjE3Mi4xNi4wLjAvMTIiLCIxOTIuMTY4LjAuMC8xNiIsIjEyNy4wLjAuMC84
IiwiOjoxLzEyOCIsImZjMDA6Oi83IiwiZmU4MDo6LzEwIl0sIm91dGJvdW5kVGFnIjoiZGlyZWN0
In0seyJ0eXBlIjoiZmllbGQiLCJpbmJvdW5kVGFnIjpbInJlZGlyZWN0IiwidHByb3h5IiwiZm9y
Y2UtcHJveHktcmVkaXJlY3QiLCJmb3JjZS1wcm94eS10cHJveHkiXSwib3V0Ym91bmRUYWciOiJ2
bGVzcy1yZWFsaXR5In1dfX0KUk9VVElORwogbXYgL29wdC9ldGMveHJheS9jb25maWdzLzA1X3Jv
dXRpbmcuanNvbi5uZXcgL29wdC9ldGMveHJheS9jb25maWdzLzA1X3JvdXRpbmcuanNvbgogZWNo
byAnUm91dGluZyBwcmVwYXJlZCBmb3IgdHJhbnNwYXJlbnQgaW5ib3VuZHMgMTE4MS8xMTkxOyB0
YWtlcyBlZmZlY3Qgb24gbWFudWFsIHNlcnZlciBzZWxlY3Rpb24uJwpmaQooY3JvbnRhYiAtbCAy
Pi9kZXYvbnVsbCB8fCB0cnVlKSA+ICIkdG1wL2Nyb250YWIiCmdyZXAgLXEgJy9vcHQvc2Jpbi94
c3ViLWd1YXJkJyAiJHRtcC9jcm9udGFiIiB8fCBlY2hvICcqICogKiAqICogL29wdC9zYmluL3hz
dWItZ3VhcmQgY2hlY2twb2ludCA+L2Rldi9udWxsIDI+JjEnID4+ICIkdG1wL2Nyb250YWIiCmNy
b250YWIgIiR0bXAvY3JvbnRhYiIKaWYgISBwaWRvZiBjcm9uZCA+L2Rldi9udWxsOyB0aGVuIHNo
IC9vcHQvZXRjL2luaXQuZC9TMDVjcm9uZCBzdGFydDsgZmkKc2ggL29wdC9ldGMvaW5pdC5kL1M3
OXhzdWItaHR0cCBzdGFydApzaCAvb3B0L2V0Yy9pbml0LmQvUzk5eGtlZW4tcGFuZWwgc3RhcnQK
c3luYwplY2hvICJJbnN0YWxsZWQuIEJhY2t1cDogJGJhY2t1cCIKZWNobyAnTmV4dDogeHN1YiBj
aGFuZ2U7IHhzZXJ2ZXIgKHNlbGVjdCBhIHNlcnZlciBtYW51YWxseSkuJwplY2hvICdQYW5lbDog
aHR0cDovLzE5Mi4xNjguMS4xOjMwMDAgOyBhc3NpZ24gY2xpZW50cyBhbmQgV0FOIHBlcm1pc3Np
b25zIGluIEtlZW5ldGljIHlvdXJzZWxmLicK
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
