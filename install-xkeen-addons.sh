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
YW5nZSkKIHByaW50ZiAnSFRUUFMgc3Vic2NyaXB0aW9uIFVSTDogJwogc3R0eSAtZWNobwogSUZT
PSByZWFkIC1yIHVybAogc3R0eSBlY2hvCiBwcmludGYgJ1xuJwogY2FzZSAiJHVybCIgaW4gaHR0
cHM6Ly8qKSA7OyAqKSBlY2hvICdIVFRQUyBVUkwgcmVxdWlyZWQnOyBleGl0IDE7OyBlc2FjCiBw
cmludGYgJyVzXG4nICIkdXJsIiA+ICIkdG1wL3NvdXJjZS11cmwiCiA7OwogdXBkYXRlKQogaWYg
WyAhIC1zICIkcm9vdC9zb3VyY2UtdXJsIiBdOyB0aGVuIGVjaG8gJ1J1biB4c3ViIGNoYW5nZSBm
aXJzdCc7IGV4aXQgMTsgZmkKIHVybD0kKGNhdCAiJHJvb3Qvc291cmNlLXVybCIpCiA7OwogaW1w
b3J0KSBjcCAvb3B0L3Zhci9zdWJzY3JpcHRpb24vb3ZlcnN1Yi50eHQgIiR0bXAvYm9keSI7Owog
KikgZWNobyAnVXNhZ2U6IHhzdWIgY2hhbmdlIHwgdXBkYXRlIHwgaW1wb3J0JzsgZXhpdCAxOzsK
ZXNhYwppZiBbICIkbW9kZSIgIT0gaW1wb3J0IF07IHRoZW4KIGN1cmwgLS1wcm90byAnPWh0dHBz
JyAtLXByb3RvLXJlZGlyICc9aHR0cHMnIC1mTHNTIC0tY29ubmVjdC10aW1lb3V0IDEwIC0tbWF4
LXRpbWUgNjAgLS1tYXgtZmlsZXNpemUgMjA5NzE1MiAiJHVybCIgPiAiJHRtcC9ib2R5IiAyPiIk
dG1wL2Rvd25sb2FkLmxvZyIgfHwgeyBlY2hvICdEb3dubG9hZCBmYWlsZWQ7IHByZXZpb3VzIHN1
YnNjcmlwdGlvbiBrZXB0JzsgZXhpdCAxOyB9CmZpCnRyIC1kICdccicgPCAiJHRtcC9ib2R5IiA+
ICIkdG1wL2JvZHkuY2xlYW4iOyBtdiAiJHRtcC9ib2R5LmNsZWFuIiAiJHRtcC9ib2R5IgppZiBn
cmVwIC1xICdedmxlc3M6Ly8nICIkdG1wL2JvZHkiOyB0aGVuCiBjcCAiJHRtcC9ib2R5IiAiJHRt
cC9kZWNvZGVkIgplbHNlCiBiYXNlNjQgLWQgIiR0bXAvYm9keSIgPiAiJHRtcC9kZWNvZGVkIiAy
Pi9kZXYvbnVsbCB8fCB7IGVjaG8gJ05vdCBhIFVSSS9CYXNlNjQgc3Vic2NyaXB0aW9uJzsgZXhp
dCAxOyB9CmZpCnNlZCAtbiAnL152bGVzczpcL1wvL3AnICIkdG1wL2RlY29kZWQiID4gIiR0bXAv
dmxlc3MudHh0IgpbIC1zICIkdG1wL3ZsZXNzLnR4dCIgXSB8fCB7IGVjaG8gJ05vIFZMRVNTIHNl
cnZlcnM7IHByZXZpb3VzIHN1YnNjcmlwdGlvbiBrZXB0JzsgZXhpdCAxOyB9CjogPiAiJHRtcC9z
ZXJ2ZXJzLmpzb25sIgppPTAKd2hpbGUgSUZTPSByZWFkIC1yIHVyaTsgZG8KIG5hbWU9JHt1cmkj
KiN9CiBuYW1lPSQocHJpbnRmICclYicgIiQocHJpbnRmICclcycgIiRuYW1lIiB8IHNlZCAncy8l
L1xceC9nJykiKQogZW5kcG9pbnQ9JHt1cmkjKkB9OyBlbmRwb2ludD0ke2VuZHBvaW50JSVcPyp9
OyBlbmRwb2ludD0ke2VuZHBvaW50JSUjKn0KIGFkZHJlc3M9JHtlbmRwb2ludCU6Kn07IGFkZHJl
c3M9JHthZGRyZXNzI1xbfTsgYWRkcmVzcz0ke2FkZHJlc3MlXF19OyBwb3J0PSR7ZW5kcG9pbnQj
Iyo6fQoganEgLW5jIC0tYXJnIHJhdyAiJHVyaSIgLS1hcmcgbmFtZSAiJG5hbWUiIC0tYXJnIGFk
ZHIgIiRhZGRyZXNzIiAtLWFyZ2pzb24gcG9ydCAiJHBvcnQiIC0tYXJnanNvbiBpZCAiJGkiICd7
aWQ6JGlkLG5hbWU6JG5hbWUsYWRkcmVzczokYWRkcixwb3J0OiRwb3J0LHByb3RvY29sOiJ2bGVz
cyIsYWN0aXZlOmZhbHNlLGxhdGVuY3lfbXM6LTEscmF3X3VyaTokcmF3fScgPj4gIiR0bXAvc2Vy
dmVycy5qc29ubCIKIGk9JCgoaSsxKSkKZG9uZSA8ICIkdG1wL3ZsZXNzLnR4dCIKanEgLXMgLS1z
bHVycGZpbGUgb2xkICIkZGF0YSIgJwogKCRvbGRbMF0uc2VydmVyc3xtYXAoc2VsZWN0KC5hY3Rp
dmUpKXwuWzBdLnJhd191cmkgLy8gIiIpIGFzICRhY3RpdmVVUkkgfAogKG1hcChzZWxlY3QoLnJh
d191cmk9PSRhY3RpdmVVUkkpKXwuWzBdLmlkIC8vIC0xKSBhcyAkYWN0aXZlIHwKIHt1cmw6Imh0
dHA6Ly8xMjcuMC4wLjE6MTgwODAvdmxlc3MudHh0IixsYXN0X3VwZGF0ZWQ6KG5vd3x0b2RhdGUp
LGFjdGl2ZV9pZDokYWN0aXZlLHNlcnZlcnM6bWFwKC5hY3RpdmU9KC5pZD09JGFjdGl2ZSkpfQon
ICIkdG1wL3NlcnZlcnMuanNvbmwiID4gIiR0bXAvc3Vic2NyaXB0aW9uLmpzb24iClsgLXMgIiR0
bXAvc3Vic2NyaXB0aW9uLmpzb24iIF0gfHwgeyBlY2hvICdDYW5ub3QgcHJlc2VydmUgYWN0aXZl
IHNlcnZlcic7IGV4aXQgMTsgfQpjcCAiJGRhdGEiICIkcm9vdC9zdWJzY3JpcHRpb24ucHJldmlv
dXMuanNvbiIKc2ggL29wdC9ldGMvaW5pdC5kL1M5OXhrZWVuLXBhbmVsIHN0b3AgPi9kZXYvbnVs
bApjcCAiJHRtcC92bGVzcy50eHQiIC9vcHQvdmFyL3N1YnNjcmlwdGlvbi92bGVzcy50eHQubmV3
Cm12IC9vcHQvdmFyL3N1YnNjcmlwdGlvbi92bGVzcy50eHQubmV3IC9vcHQvdmFyL3N1YnNjcmlw
dGlvbi92bGVzcy50eHQKY3AgIiR0bXAvc3Vic2NyaXB0aW9uLmpzb24iICIkZGF0YS5uZXciOyBt
diAiJGRhdGEubmV3IiAiJGRhdGEiCmlmIFsgIiRtb2RlIiAhPSBpbXBvcnQgXTsgdGhlbgogY3Ag
IiR0bXAvYm9keSIgL29wdC92YXIvc3Vic2NyaXB0aW9uL292ZXJzdWIudHh0CmZpCmlmIFsgIiRt
b2RlIiA9IGNoYW5nZSBdOyB0aGVuIGNwICIkdG1wL3NvdXJjZS11cmwiICIkcm9vdC9zb3VyY2Ut
dXJsIjsgZmkKc2ggL29wdC9ldGMvaW5pdC5kL1M5OXhrZWVuLXBhbmVsIHN0YXJ0ID4vZGV2L251
bGwKZWNobyAiVkxFU1Mgc2VydmVyczogJGkuIEFjdGl2ZSBYcmF5IGNvbm5lY3Rpb24gdW5jaGFu
Z2VkLiIKaWYgWyAiJChqcSAtciAnLmFjdGl2ZV9pZCcgIiRkYXRhIikiID0gLTEgXTsgdGhlbgog
ZWNobyAnUHJldmlvdXMgc2VydmVyIG5vdCBpbiBuZXcgbGlzdC4gU2VsZWN0IGEgc2VydmVyIG1h
bnVhbGx5LicKZmkK
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
cSAtciAtLWFyZ2pzb24gaSAiJGlkeCIgJy5zZXJ2ZXJzWyRpXS5uYW1lJyAiJGRhdGEiCiBjdXJs
IC0tcHJveHkgc29ja3M1aDovLzEyNy4wLjAuMToxMTg5IC0tY29ubmVjdC10aW1lb3V0IDUgLS1t
YXgtdGltZSAxMiAtc1MgLW8gL2Rldi9udWxsIC13ICdIVFRQICV7aHR0cF9jb2RlfTsgZnVsbCBI
VFRQUyByZXF1ZXN0ICV7dGltZV90b3RhbH0gc1xuJyBodHRwczovL3d3dy5nc3RhdGljLmNvbS9n
ZW5lcmF0ZV8yMDQKIGV4aXQKZmkKanEgJ3tvdXRib3VuZHM6W3t0YWc6ImRpcmVjdCIscHJvdG9j
b2w6ImZyZWVkb20ifSx7dGFnOiJibG9jayIscHJvdG9jb2w6ImJsYWNraG9sZSJ9LCgub3V0Ym91
bmRzWzBdfC50YWc9InZsZXNzLXJlYWxpdHkiKV19JyAiJHRtcC8wNF9vdXRib3VuZHMuY2hvaWNl
Lmpzb24iID4gIiR0bXAvb3V0Ym91bmRzLmpzb24iCm1rZGlyICIkdG1wL3N0YWdlIgpjcCAvb3B0
L2V0Yy94cmF5L2NvbmZpZ3MvKi5qc29uICIkdG1wL3N0YWdlLyIKY3AgIiR0bXAvb3V0Ym91bmRz
Lmpzb24iICIkdG1wL3N0YWdlLzA0X291dGJvdW5kcy5qc29uIgovb3B0L3NiaW4veHJheSBydW4g
LXRlc3QgLWNvbmZkaXIgIiR0bXAvc3RhZ2UiID4gIiR0bXAvdGVzdC5sb2ciIDI+JjEKY3AgL29w
dC9ldGMveHJheS9jb25maWdzLzA0X291dGJvdW5kcy5qc29uICIkdG1wL3ByZXZpb3VzLmpzb24i
CmNwICIkZGF0YSIgIiR0bXAvcHJldmlvdXMtc3Vic2NyaXB0aW9uLmpzb24iCmpxIC0tYXJnanNv
biBpICIkaWR4IiAnLmFjdGl2ZV9pZD0kaSB8IC5zZXJ2ZXJzIHw9IG1hcCguYWN0aXZlPSguaWQ9
PSRpKSknICIkZGF0YSIgPiAiJHRtcC9zdWJzY3JpcHRpb24uanNvbiIKc2ggL29wdC9ldGMvaW5p
dC5kL1M5OXhrZWVuLXBhbmVsIHN0b3AgPi9kZXYvbnVsbApjcCAiJHRtcC9vdXRib3VuZHMuanNv
biIgL29wdC9ldGMveHJheS9jb25maWdzLzA0X291dGJvdW5kcy5qc29uCmNwICIkdG1wL3N1YnNj
cmlwdGlvbi5qc29uIiAiJGRhdGEubmV3IjsgbXYgIiRkYXRhLm5ldyIgIiRkYXRhIjsgc3luYwp4
a2VlbiAtcmVzdGFydCA+ICIkdG1wL3Jlc3RhcnQubG9nIiAyPiYxCnNsZWVwIDIKaWYgISBwaWRv
ZiB4cmF5ID4vZGV2L251bGw7IHRoZW4KIGNwICIkdG1wL3ByZXZpb3VzLmpzb24iIC9vcHQvZXRj
L3hyYXkvY29uZmlncy8wNF9vdXRib3VuZHMuanNvbgogY3AgIiR0bXAvcHJldmlvdXMtc3Vic2Ny
aXB0aW9uLmpzb24iICIkZGF0YS5uZXciOyBtdiAiJGRhdGEubmV3IiAiJGRhdGEiOyBzeW5jCiB4
a2VlbiAtcmVzdGFydCA+ICIkdG1wL3JvbGxiYWNrLmxvZyIgMj4mMQogc2ggL29wdC9ldGMvaW5p
dC5kL1M5OXhrZWVuLXBhbmVsIHN0YXJ0ID4vZGV2L251bGwKIGVjaG8gJ1N0YXJ0IGZhaWxlZDsg
cHJldmlvdXMgY29uZmlndXJhdGlvbiByZXN0b3JlZCc7IGV4aXQgMQpmaQpzaCAvb3B0L2V0Yy9p
bml0LmQvUzk5eGtlZW4tcGFuZWwgc3RhcnQgPi9kZXYvbnVsbApqcSAtciAtLWFyZ2pzb24gaSAi
JGlkeCIgJyJTZWxlY3RlZDogIisuc2VydmVyc1skaV0ubmFtZScgIiRkYXRhIgo=
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
