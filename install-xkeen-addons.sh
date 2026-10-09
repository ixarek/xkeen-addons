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
base64 -d > /opt/sbin/xsub <<'PAYLOAD_END'
IyEvYmluL3NoCnNldCAtZXUKdW1hc2sgMDc3CnJvb3Q9L29wdC9ldGMveHNlcnZlcgpkYXRhPS9v
cHQvZXRjL3hrZWVuLXBhbmVsL2RhdGEvc3Vic2NyaXB0aW9uLmpzb24KbWtkaXIgLXAgIiRyb290
IiAvb3B0L3RtcC94c2VydmVyCnRtcD0kKG1rdGVtcCAtZCAvb3B0L3RtcC94c2VydmVyL3N1Yi5Y
WFhYWFgpCnRyYXAgJ3N0dHkgZWNobyAyPi9kZXYvbnVsbCB8fCB0cnVlOyBybSAtcmYgIiR0bXAi
JyBFWElUIEhVUCBJTlQgVEVSTQptb2RlPSR7MTotdXBkYXRlfQpjYXNlICIkbW9kZSIgaW4KIGNo
YW5nZSkKIHByaW50ZiAnSFRUUFMgc3Vic2NyaXB0aW9uIFVSTDogJwogaWYgWyAtdCAwIF07IHRo
ZW4gc3R0eSAtZWNobzsgZmkKIElGUz0gcmVhZCAtciB1cmwKIGlmIFsgLXQgMCBdOyB0aGVuIHN0
dHkgZWNobzsgZmkKIHByaW50ZiAnXG4nCiBjYXNlICIkdXJsIiBpbiBodHRwczovLyopIDs7ICop
IGVjaG8gJ0hUVFBTIFVSTCByZXF1aXJlZCc7IGV4aXQgMTs7IGVzYWMKIHByaW50ZiAnJXNcbicg
IiR1cmwiID4gIiR0bXAvc291cmNlLXVybCIKIDs7CiB1cGRhdGUpCiBpZiBbICEgLXMgIiRyb290
L3NvdXJjZS11cmwiIF07IHRoZW4gZWNobyAnUnVuIHhzdWIgY2hhbmdlIGZpcnN0JzsgZXhpdCAx
OyBmaQogdXJsPSQoY2F0ICIkcm9vdC9zb3VyY2UtdXJsIikKIDs7CiBpbXBvcnQpIGNwIC9vcHQv
dmFyL3N1YnNjcmlwdGlvbi9vdmVyc3ViLnR4dCAiJHRtcC9ib2R5Ijs7CiAqKSBlY2hvICdVc2Fn
ZTogeHN1YiBjaGFuZ2UgfCB1cGRhdGUgfCBpbXBvcnQnOyBleGl0IDE7Owplc2FjCmlmIFsgIiRt
b2RlIiAhPSBpbXBvcnQgXTsgdGhlbgogY3VybCAtLXByb3RvICc9aHR0cHMnIC0tcHJvdG8tcmVk
aXIgJz1odHRwcycgLWZMc1MgLS1jb25uZWN0LXRpbWVvdXQgMTAgLS1tYXgtdGltZSA2MCAtLW1h
eC1maWxlc2l6ZSAyMDk3MTUyICIkdXJsIiA+ICIkdG1wL2JvZHkiIDI+IiR0bXAvZG93bmxvYWQu
bG9nIiB8fCB7IGVjaG8gJ0Rvd25sb2FkIGZhaWxlZDsgcHJldmlvdXMgc3Vic2NyaXB0aW9uIGtl
cHQnOyBleGl0IDE7IH0KZmkKdHIgLWQgJ1xyJyA8ICIkdG1wL2JvZHkiID4gIiR0bXAvYm9keS5j
bGVhbiI7IG12ICIkdG1wL2JvZHkuY2xlYW4iICIkdG1wL2JvZHkiCmlmIGdyZXAgLXEgJ152bGVz
czovLycgIiR0bXAvYm9keSI7IHRoZW4KIGNwICIkdG1wL2JvZHkiICIkdG1wL2RlY29kZWQiCmVs
c2UKIGJhc2U2NCAtZCAiJHRtcC9ib2R5IiA+ICIkdG1wL2RlY29kZWQiIDI+L2Rldi9udWxsIHx8
IHsgZWNobyAnTm90IGEgVVJJL0Jhc2U2NCBzdWJzY3JpcHRpb24nOyBleGl0IDE7IH0KZmkKc2Vk
IC1uICcvXnZsZXNzOlwvXC8vcCcgIiR0bXAvZGVjb2RlZCIgPiAiJHRtcC92bGVzcy50eHQiClsg
LXMgIiR0bXAvdmxlc3MudHh0IiBdIHx8IHsgZWNobyAnTm8gVkxFU1Mgc2VydmVyczsgcHJldmlv
dXMgc3Vic2NyaXB0aW9uIGtlcHQnOyBleGl0IDE7IH0KOiA+ICIkdG1wL3NlcnZlcnMuanNvbmwi
Cmk9MAp3aGlsZSBJRlM9IHJlYWQgLXIgdXJpOyBkbwogbmFtZT0ke3VyaSMqI30KIG5hbWU9JChw
cmludGYgJyViJyAiJChwcmludGYgJyVzJyAiJG5hbWUiIHwgc2VkICdzLyUvXFx4L2cnKSIpCiBl
bmRwb2ludD0ke3VyaSMqQH07IGVuZHBvaW50PSR7ZW5kcG9pbnQlJVw/Kn07IGVuZHBvaW50PSR7
ZW5kcG9pbnQlJSMqfQogY2FzZSAiJGVuZHBvaW50IiBpbgogIFxbKlxdOiopIGFkZHJlc3M9JHtl
bmRwb2ludCU6Kn07IHBvcnQ9JHtlbmRwb2ludCMjKjp9OzsKICBcWypcXSkgYWRkcmVzcz0kZW5k
cG9pbnQ7IHBvcnQ9NDQzOzsKICAqOiopIGFkZHJlc3M9JHtlbmRwb2ludCU6Kn07IHBvcnQ9JHtl
bmRwb2ludCMjKjp9OzsKICAqKSBhZGRyZXNzPSRlbmRwb2ludDsgcG9ydD00NDM7OwogZXNhYwog
YWRkcmVzcz0ke2FkZHJlc3MjXFt9OyBhZGRyZXNzPSR7YWRkcmVzcyVcXX0KIGNhc2UgIiR1cmki
IGluIConIycqKSA7OyAqKSBuYW1lPSRhZGRyZXNzOzsgZXNhYwoganEgLW5jIC0tYXJnIHJhdyAi
JHVyaSIgLS1hcmcgbmFtZSAiJG5hbWUiIC0tYXJnIGFkZHIgIiRhZGRyZXNzIiAtLWFyZ2pzb24g
cG9ydCAiJHBvcnQiIC0tYXJnanNvbiBpZCAiJGkiICd7aWQ6JGlkLG5hbWU6JG5hbWUsYWRkcmVz
czokYWRkcixwb3J0OiRwb3J0LHByb3RvY29sOiJ2bGVzcyIsYWN0aXZlOmZhbHNlLGxhdGVuY3lf
bXM6LTEscmF3X3VyaTokcmF3fScgPj4gIiR0bXAvc2VydmVycy5qc29ubCIKIGk9JCgoaSsxKSkK
ZG9uZSA8ICIkdG1wL3ZsZXNzLnR4dCIKanEgLXMgLS1zbHVycGZpbGUgb2xkICIkZGF0YSIgJwog
KCRvbGRbMF0uc2VydmVyc3xtYXAoc2VsZWN0KC5hY3RpdmUpKXwuWzBdLnJhd191cmkgLy8gIiIp
IGFzICRhY3RpdmVVUkkgfAogKG1hcChzZWxlY3QoLnJhd191cmk9PSRhY3RpdmVVUkkpKXwuWzBd
LmlkIC8vIC0xKSBhcyAkYWN0aXZlIHwKIHt1cmw6Imh0dHA6Ly8xMjcuMC4wLjE6MTgwODAvdmxl
c3MudHh0IixsYXN0X3VwZGF0ZWQ6KG5vd3x0b2RhdGUpLGFjdGl2ZV9pZDokYWN0aXZlLHNlcnZl
cnM6bWFwKC5hY3RpdmU9KC5pZD09JGFjdGl2ZSkpfQonICIkdG1wL3NlcnZlcnMuanNvbmwiID4g
IiR0bXAvc3Vic2NyaXB0aW9uLmpzb24iClsgLXMgIiR0bXAvc3Vic2NyaXB0aW9uLmpzb24iIF0g
fHwgeyBlY2hvICdDYW5ub3QgcHJlc2VydmUgYWN0aXZlIHNlcnZlcic7IGV4aXQgMTsgfQpjcCAi
JGRhdGEiICIkcm9vdC9zdWJzY3JpcHRpb24ucHJldmlvdXMuanNvbiIKc2ggL29wdC9ldGMvaW5p
dC5kL1M5OXhrZWVuLXBhbmVsIHN0b3AgPi9kZXYvbnVsbApjcCAiJHRtcC92bGVzcy50eHQiIC9v
cHQvdmFyL3N1YnNjcmlwdGlvbi92bGVzcy50eHQubmV3Cm12IC9vcHQvdmFyL3N1YnNjcmlwdGlv
bi92bGVzcy50eHQubmV3IC9vcHQvdmFyL3N1YnNjcmlwdGlvbi92bGVzcy50eHQKY3AgIiR0bXAv
c3Vic2NyaXB0aW9uLmpzb24iICIkZGF0YS5uZXciOyBtdiAiJGRhdGEubmV3IiAiJGRhdGEiOyBz
eW5jCmlmIFsgIiRtb2RlIiAhPSBpbXBvcnQgXTsgdGhlbgogY3AgIiR0bXAvYm9keSIgL29wdC92
YXIvc3Vic2NyaXB0aW9uL292ZXJzdWIudHh0Lm5ldwogbXYgL29wdC92YXIvc3Vic2NyaXB0aW9u
L292ZXJzdWIudHh0Lm5ldyAvb3B0L3Zhci9zdWJzY3JpcHRpb24vb3ZlcnN1Yi50eHQKZmkKaWYg
WyAiJG1vZGUiID0gY2hhbmdlIF07IHRoZW4KIGNwICIkdG1wL3NvdXJjZS11cmwiICIkcm9vdC9z
b3VyY2UtdXJsLm5ldyIKIG12ICIkcm9vdC9zb3VyY2UtdXJsLm5ldyIgIiRyb290L3NvdXJjZS11
cmwiCmZpCnN5bmMKc2ggL29wdC9ldGMvaW5pdC5kL1M5OXhrZWVuLXBhbmVsIHN0YXJ0ID4vZGV2
L251bGwKZWNobyAiVkxFU1Mgc2VydmVyczogJGkuIEFjdGl2ZSBYcmF5IGNvbm5lY3Rpb24gdW5j
aGFuZ2VkLiIKaWYgWyAiJChqcSAtciAnLmFjdGl2ZV9pZCcgIiRkYXRhIikiID0gLTEgXTsgdGhl
bgogZWNobyAnUHJldmlvdXMgc2VydmVyIG5vdCBpbiBuZXcgbGlzdC4gU2VsZWN0IGEgc2VydmVy
IG1hbnVhbGx5LicKZmkK
PAYLOAD_END
base64 -d > /opt/sbin/xserver <<'PAYLOAD_END'
IyEvYmluL3NoCnNldCAtZXUKdW1hc2sgMDc3CmRhdGE9L29wdC9ldGMveGtlZW4tcGFuZWwvZGF0
YS9zdWJzY3JpcHRpb24uanNvbgpjbWQ9JHsxOi1tZW51fQpsaXN0KCkgeyBqcSAtciAnLnNlcnZl
cnNbXSB8ICJcKC5pZCsxKVx0XChpZiAuYWN0aXZlIHRoZW4gIioiIGVsc2UgIiAiIGVuZCkgXCgu
bmFtZSlcdFwoLmxhdGVuY3lfbXMpIG1zIicgIiRkYXRhIjsgfQppZiBbICIkY21kIiA9IG1lbnUg
XTsgdGhlbgogbGlzdAogcHJpbnRmICdOdW1iZXIgdG8gc3dpdGNoLCBwIE5VTUJFUiB0byB0ZXN0
LCBxIHRvIHF1aXQ6ICcKIElGUz0gcmVhZCAtciBpbnB1dAogY2FzZSAiJGlucHV0IiBpbiBxfCcn
KSBleGl0IDA7OyBwXCAqKSBjbWQ9cGluZzsgbj0ke2lucHV0I3AgfTs7ICopIGNtZD11c2U7IG49
JGlucHV0OzsgZXNhYwplbGlmIFsgIiRjbWQiID0gbGlzdCBdOyB0aGVuIGxpc3Q7IGV4aXQgMApl
bHNlIG49JHsyOi19OyBmaQpjYXNlICIkY21kIiBpbiBwaW5nfHVzZSkgOzsgKikgZWNobyAnVXNh
Z2U6IHhzZXJ2ZXIgW2xpc3QgfCBwaW5nIE5VTUJFUiB8IHVzZSBOVU1CRVJdJzsgZXhpdCAxOzsg
ZXNhYwpjYXNlICIkbiIgaW4gJyd8KlshMC05XSopIGVjaG8gJ0ludmFsaWQgbnVtYmVyJzsgZXhp
dCAxOzsgZXNhYwppZHg9JCgobi0xKSkKanEgLWUgLS1hcmdqc29uIGkgIiRpZHgiICcuc2VydmVy
c1skaV0gIT0gbnVsbCBhbmQgJGk+PTAnICIkZGF0YSIgPi9kZXYvbnVsbCB8fCB7IGVjaG8gJ05v
IHN1Y2ggc2VydmVyJzsgZXhpdCAxOyB9Cm1rZGlyIC1wIC9vcHQvdG1wL3hzZXJ2ZXIKbWtkaXIg
L29wdC90bXAveHNlcnZlci1jbGkubG9jayAyPi9kZXYvbnVsbCB8fCB7IGVjaG8gJ0Fub3RoZXIg
b3BlcmF0aW9uIGlzIHJ1bm5pbmcnOyBleGl0IDE7IH0KdG1wPSQobWt0ZW1wIC1kIC9vcHQvdG1w
L3hzZXJ2ZXIvY2xpLlhYWFhYWCkKcGlkPScnCmNsZWFudXAoKSB7IFsgLXogIiRwaWQiIF0gfHwg
a2lsbCAiJHBpZCIgMj4vZGV2L251bGwgfHwgdHJ1ZTsgcm0gLWYgL29wdC92YXIvc3Vic2NyaXB0
aW9uL2Nob2ljZS50eHQ7IHJtIC1yZiAiJHRtcCI7IHJtZGlyIC9vcHQvdG1wL3hzZXJ2ZXItY2xp
LmxvY2s7IH0KdHJhcCBjbGVhbnVwIEVYSVQgSFVQIElOVCBURVJNCmpxIC1yIC0tYXJnanNvbiBp
ICIkaWR4IiAnLnNlcnZlcnNbJGldLnJhd191cmknICIkZGF0YSIgPiAvb3B0L3Zhci9zdWJzY3Jp
cHRpb24vY2hvaWNlLnR4dAovb3B0L3NiaW4veGtlZW4tc3Vic2NyaXB0aW9uLXdhdGNoZXIgLS1z
aW5nbGUtcHJveHkgLS1uby1yZXN0YXJ0IC0tb3V0cHV0LWRpciAiJHRtcCIgJ2Nob2ljZT1odHRw
Oi8vMTI3LjAuMC4xOjE4MDgwL2Nob2ljZS50eHQnID4gIiR0bXAvY29udmVydC5sb2ciIDI+JjEK
anEgLWUgJy5vdXRib3VuZHN8bGVuZ3RoPT0xJyAiJHRtcC8wNF9vdXRib3VuZHMuY2hvaWNlLmpz
b24iID4vZGV2L251bGwKaWYgWyAiJGNtZCIgPSBwaW5nIF07IHRoZW4KIGpxICd7bG9nOntsb2ds
ZXZlbDoid2FybmluZyJ9LGluYm91bmRzOlt7bGlzdGVuOiIxMjcuMC4wLjEiLHBvcnQ6MTE4OSxw
cm90b2NvbDoic29ja3MiLHNldHRpbmdzOnthdXRoOiJub2F1dGgiLHVkcDpmYWxzZX19XSxvdXRi
b3VuZHM6Lm91dGJvdW5kc30nICIkdG1wLzA0X291dGJvdW5kcy5jaG9pY2UuanNvbiIgPiAiJHRt
cC9wcm9iZS5qc29uIgogL29wdC9zYmluL3hyYXkgcnVuIC10ZXN0IC1jICIkdG1wL3Byb2JlLmpz
b24iID4gIiR0bXAvcHJvYmUubG9nIiAyPiYxCiAvb3B0L3NiaW4veHJheSBydW4gLWMgIiR0bXAv
cHJvYmUuanNvbiIgPj4gIiR0bXAvcHJvYmUubG9nIiAyPiYxICYgcGlkPSQhCiBzbGVlcCAxCiBq
cSAtciAtLWFyZ2pzb24gaSAiJGlkeCIgJy5zZXJ2ZXJzWyRpXS5uYW1lJyAiJGRhdGEiCiByZXN1
bHQ9JChjdXJsIC0tcHJveHkgc29ja3M1aDovLzEyNy4wLjAuMToxMTg5IC0tY29ubmVjdC10aW1l
b3V0IDUgLS1tYXgtdGltZSAxMiAtc1MgLW8gL2Rldi9udWxsIC13ICcle2h0dHBfY29kZX0gJXt0
aW1lX3RvdGFsfScgaHR0cHM6Ly93d3cuZ3N0YXRpYy5jb20vZ2VuZXJhdGVfMjA0KSB8fCB7IGVj
aG8gJ1Byb3h5IHJlcXVlc3QgZmFpbGVkJzsgZXhpdCAxOyB9CiBjb2RlPSR7cmVzdWx0JSUgKn07
IGVsYXBzZWQ9JHtyZXN1bHQjKiB9CiBlY2hvICJIVFRQICRjb2RlOyBmdWxsIEhUVFBTIHJlcXVl
c3QgJGVsYXBzZWQgcyIKIFsgIiRjb2RlIiA9IDIwNCBdIHx8IHsgZWNobyAnVW5leHBlY3RlZCBo
ZWFsdGgtY2hlY2sgcmVzcG9uc2UnOyBleGl0IDE7IH0KIGV4aXQKZmkKanEgJ3tvdXRib3VuZHM6
W3t0YWc6ImRpcmVjdCIscHJvdG9jb2w6ImZyZWVkb20ifSx7dGFnOiJibG9jayIscHJvdG9jb2w6
ImJsYWNraG9sZSJ9LCgub3V0Ym91bmRzWzBdfC50YWc9InZsZXNzLXJlYWxpdHkiKV19JyAiJHRt
cC8wNF9vdXRib3VuZHMuY2hvaWNlLmpzb24iID4gIiR0bXAvb3V0Ym91bmRzLmpzb24iCm1rZGly
ICIkdG1wL3N0YWdlIgpjcCAvb3B0L2V0Yy94cmF5L2NvbmZpZ3MvKi5qc29uICIkdG1wL3N0YWdl
LyIKY3AgIiR0bXAvb3V0Ym91bmRzLmpzb24iICIkdG1wL3N0YWdlLzA0X291dGJvdW5kcy5qc29u
Igovb3B0L3NiaW4veHJheSBydW4gLXRlc3QgLWNvbmZkaXIgIiR0bXAvc3RhZ2UiID4gIiR0bXAv
dGVzdC5sb2ciIDI+JjEKY3AgL29wdC9ldGMveHJheS9jb25maWdzLzA0X291dGJvdW5kcy5qc29u
ICIkdG1wL3ByZXZpb3VzLmpzb24iCmNwICIkZGF0YSIgIiR0bXAvcHJldmlvdXMtc3Vic2NyaXB0
aW9uLmpzb24iCmpxIC0tYXJnanNvbiBpICIkaWR4IiAnLmFjdGl2ZV9pZD0kaSB8IC5zZXJ2ZXJz
IHw9IG1hcCguYWN0aXZlPSguaWQ9PSRpKSknICIkZGF0YSIgPiAiJHRtcC9zdWJzY3JpcHRpb24u
anNvbiIKc2ggL29wdC9ldGMvaW5pdC5kL1M5OXhrZWVuLXBhbmVsIHN0b3AgPi9kZXYvbnVsbApj
cCAiJHRtcC9vdXRib3VuZHMuanNvbiIgL29wdC9ldGMveHJheS9jb25maWdzLzA0X291dGJvdW5k
cy5qc29uLm5ldwptdiAvb3B0L2V0Yy94cmF5L2NvbmZpZ3MvMDRfb3V0Ym91bmRzLmpzb24ubmV3
IC9vcHQvZXRjL3hyYXkvY29uZmlncy8wNF9vdXRib3VuZHMuanNvbgpjcCAiJHRtcC9zdWJzY3Jp
cHRpb24uanNvbiIgIiRkYXRhLm5ldyI7IG12ICIkZGF0YS5uZXciICIkZGF0YSI7IHN5bmMKcmVz
dGFydF9vaz15ZXMKeGtlZW4gLXJlc3RhcnQgPiAiJHRtcC9yZXN0YXJ0LmxvZyIgMj4mMSB8fCBy
ZXN0YXJ0X29rPW5vCnNsZWVwIDIKaWYgWyAiJHJlc3RhcnRfb2siID0gbm8gXSB8fCAhIHBpZG9m
IHhyYXkgPi9kZXYvbnVsbDsgdGhlbgogY3AgIiR0bXAvcHJldmlvdXMuanNvbiIgL29wdC9ldGMv
eHJheS9jb25maWdzLzA0X291dGJvdW5kcy5qc29uLm5ldwogbXYgL29wdC9ldGMveHJheS9jb25m
aWdzLzA0X291dGJvdW5kcy5qc29uLm5ldyAvb3B0L2V0Yy94cmF5L2NvbmZpZ3MvMDRfb3V0Ym91
bmRzLmpzb24KIGNwICIkdG1wL3ByZXZpb3VzLXN1YnNjcmlwdGlvbi5qc29uIiAiJGRhdGEubmV3
IjsgbXYgIiRkYXRhLm5ldyIgIiRkYXRhIjsgc3luYwogeGtlZW4gLXJlc3RhcnQgPiAiJHRtcC9y
b2xsYmFjay5sb2ciIDI+JjEgfHwgdHJ1ZQogc2ggL29wdC9ldGMvaW5pdC5kL1M5OXhrZWVuLXBh
bmVsIHN0YXJ0ID4vZGV2L251bGwKIGVjaG8gJ1N0YXJ0IGZhaWxlZDsgcHJldmlvdXMgY29uZmln
dXJhdGlvbiByZXN0b3JlZCc7IGV4aXQgMQpmaQpzaCAvb3B0L2V0Yy9pbml0LmQvUzk5eGtlZW4t
cGFuZWwgc3RhcnQgPi9kZXYvbnVsbApqcSAtciAtLWFyZ2pzb24gaSAiJGlkeCIgJyJTZWxlY3Rl
ZDogIisuc2VydmVyc1skaV0ubmFtZScgIiRkYXRhIgo=
PAYLOAD_END
base64 -d > /opt/sbin/xsub-guard <<'PAYLOAD_END'
IyEvYmluL3NoCnNldCAtZXUKdW1hc2sgMDc3CmRpcj0vb3B0L2V0Yy94a2Vlbi1wYW5lbC9kYXRh
CmRhdGE9IiRkaXIvc3Vic2NyaXB0aW9uLmpzb24iCmdvb2Q9IiRkaXIvc3Vic2NyaXB0aW9uLmxh
c3QtZ29vZC5qc29uIgpta2RpciAtcCAvb3B0L3RtcC94c2VydmVyCm1rZGlyIC9vcHQvdG1wL3hz
ZXJ2ZXIvc3Vic2NyaXB0aW9uLWd1YXJkLmxvY2sgMj4vZGV2L251bGwgfHwgZXhpdCAwCnRtcD0i
JGRpci8uc3Vic2NyaXB0aW9uLWd1YXJkLSQkIgp0cmFwICdybSAtZiAiJHRtcCI7IHJtZGlyIC9v
cHQvdG1wL3hzZXJ2ZXIvc3Vic2NyaXB0aW9uLWd1YXJkLmxvY2snIEVYSVQgSFVQIElOVCBURVJN
CnZhbGlkKCkgewogWyAtcyAiJDEiIF0gJiYganEgLWUgJ3R5cGU9PSJvYmplY3QiIGFuZCAoLnNl
cnZlcnN8dHlwZT09ImFycmF5IiBhbmQgbGVuZ3RoPjApIGFuZCAoLmFjdGl2ZV9pZHx0eXBlPT0i
bnVtYmVyIikgYW5kIGFsbCguc2VydmVyc1tdOyAoLnJhd191cml8dHlwZT09InN0cmluZyIgYW5k
IHN0YXJ0c3dpdGgoInZsZXNzOi8vIikpKScgIiQxIiA+L2Rldi9udWxsIDI+JjEKfQpzbmFwc2hv
dCgpIHsKIGNwICIkZGF0YSIgIiR0bXAiIDI+L2Rldi9udWxsIHx8IHJldHVybiAwCiBpZiB2YWxp
ZCAiJHRtcCI7IHRoZW4KICBpZiAhIGNtcCAtcyAiJHRtcCIgIiRnb29kIjsgdGhlbgogICBtdiAi
JHRtcCIgIiRnb29kIgogICBzeW5jCiAgZmkKIGZpCn0KY2FzZSAiJHsxOi1jaGVja3BvaW50fSIg
aW4KIGNoZWNrcG9pbnQpIHNuYXBzaG90OzsKIHJlY292ZXIpCiBpZiB2YWxpZCAiJGRhdGEiOyB0
aGVuIHNuYXBzaG90OyBleGl0IDA7IGZpCiBpZiBbICEgLWUgIiRnb29kIiBdICYmIGpxIC1lICcu
c2VydmVyc3x0eXBlPT0iYXJyYXkiIGFuZCBsZW5ndGg9PTAnICIkZGF0YSIgPi9kZXYvbnVsbCAy
PiYxOyB0aGVuIGV4aXQgMDsgZmkKIHNvdXJjZT0nJwogZm9yIGNhbmRpZGF0ZSBpbiAiJGdvb2Qi
IC9vcHQvZXRjL3hzZXJ2ZXIvc3Vic2NyaXB0aW9uLnByZXZpb3VzLmpzb247IGRvCiAgaWYgdmFs
aWQgIiRjYW5kaWRhdGUiOyB0aGVuIHNvdXJjZT0iJGNhbmRpZGF0ZSI7IGJyZWFrOyBmaQogZG9u
ZQogaWYgWyAteiAiJHNvdXJjZSIgXTsgdGhlbgogIGxvZ2dlciAtdCB4a2Vlbi1zdWItZ3VhcmQg
J1N1YnNjcmlwdGlvbiBpbnZhbGlkOyBubyB2YWxpZCBiYWNrdXAnCiAgZXhpdCAxCiBmaQogY3Ag
IiRzb3VyY2UiICIkdG1wIgogY2htb2QgNjAwICIkdG1wIgogbXYgIiR0bXAiICIkZGF0YSIKIHN5
bmMKIHNuYXBzaG90CiBsb2dnZXIgLXQgeGtlZW4tc3ViLWd1YXJkICdTdWJzY3JpcHRpb24gcmVz
dG9yZWQgZnJvbSB2YWxpZGF0ZWQgYmFja3VwJwogOzsKICopIGVjaG8gJ1VzYWdlOiB4c3ViLWd1
YXJkIGNoZWNrcG9pbnQgfCByZWNvdmVyJzsgZXhpdCAxOzsKZXNhYwo=
PAYLOAD_END

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
