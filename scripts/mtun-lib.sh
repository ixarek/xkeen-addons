#!/bin/sh
# Shared by mtun and its Entware service. No eval of configuration or user input.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
MT_HOME=/opt/etc/mihomo-tun
MT_RUN=/tmp/mihomo-tun
MT_TABLE=2023
MT_PREF=100
MT_DEV=mhtun0
mt_die() { echo "ERROR: $*" >&2; exit 1; }
# API URL must precede curl's remaining options; keep credentials out of URLs.
mt_request() {
 mt_path=$1; shift
 mt_host=$(jq -r '.["external-controller"]' "$MT_HOME/config.json")
 mt_secret=$(jq -r '.secret' "$MT_HOME/config.json")
 curl --noproxy '*' -fsS --connect-timeout 3 --max-time 15 -H "Authorization: Bearer $mt_secret" "$@" "http://$mt_host$mt_path"
}
mt_ipv4() {
 printf '%s\n' "$1" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i+0>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1; if($1==0 || $1==127 || $1>=224) exit 1}'
}
mt_validate_clients() {
 [ -s "$1" ] || return 1
 while read -r mt_ip mt_mac mt_extra; do
  mt_ipv4 "$mt_ip" || return 1
  [ -z "$mt_extra" ] || return 1
  printf '%s\n' "$mt_mac" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || return 1
 done < "$1"
}
mt_pid() {
 [ -s "$MT_RUN/pid" ] || return 1
 mt_pid_value=$(cat "$MT_RUN/pid")
 case "$mt_pid_value" in ''|*[!0-9]*) return 1;; esac
 kill -0 "$mt_pid_value" 2>/dev/null || return 1
 # Avoid signalling another process after PID reuse.
 [ /proc/"$mt_pid_value"/exe -ef /opt/sbin/mihomo-tun-core ]
}
mt_generate() {
 # JSON is valid YAML. All provider data stays in its own file and cannot
 # override listeners, routing, API credentials or TUN settings.
 jq -n --arg lan "$1" --arg secret "$2" --argjson tun "$3" '{
  "mixed-port":17890,"bind-address":"127.0.0.1","allow-lan":false,
  "mode":"rule","log-level":"warning","ipv6":false,
  "external-controller":($lan+":9090"),"external-ui":"ui","secret":$secret,
  "profile":{"store-selected":true},
  "tun":{"enable":$tun,"device":"mhtun0","stack":"gvisor","mtu":1400,
         "auto-route":false,"auto-redirect":false,"auto-detect-interface":true,
         "dns-hijack":["any:53","tcp://any:53"]},
  "dns":{"enable":true,"listen":($lan+":1053"),"ipv6":false,
         "enhanced-mode":"redir-host","respect-rules":true,
         "default-nameserver":["system"],"proxy-server-nameserver":["system"],
         "nameserver":["https://1.1.1.1/dns-query#PROXY","https://8.8.8.8/dns-query#PROXY"]},
  "proxy-providers":{"subscription":{"type":"file","path":"./subscription.txt",
      "health-check":{"enable":false}}},
  "proxy-groups":[{"name":"PROXY","type":"select","use":["subscription"]}],
  "rules":["MATCH,PROXY"]
 }'
}
mt_validate_provider() (
 # The subshell owns its validator process and cleans it on every exit path.
 mt_dir=$1
 mt_core=${2:-/opt/sbin/mihomo-tun-core}
 mt_secret=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
 jq --arg secret "$mt_secret" '.secret=$secret | .tun.enable=false | .["external-controller"]="127.0.0.1:19091" | .["mixed-port"]=0 | .dns.enable=false | del(.["external-ui"]) | .profile["store-selected"]=false' "$mt_dir/config.json" > "$mt_dir/validate.json"
 "$mt_core" -t -d "$mt_dir" -f "$mt_dir/validate.json" > "$mt_dir/validate.log" 2>&1 || exit 1
 "$mt_core" -d "$mt_dir" -f "$mt_dir/validate.json" > "$mt_dir/validate.log" 2>&1 &
 mt_validator=$!
 trap 'kill "$mt_validator" 2>/dev/null || true; wait "$mt_validator" 2>/dev/null || true' EXIT
 mt_tries=0
 until curl --noproxy '*' -fsS --max-time 2 -H "Authorization: Bearer $mt_secret" http://127.0.0.1:19091/providers/proxies/subscription > "$mt_dir/proxies.json" 2>/dev/null && jq -e '.proxies|length>0' "$mt_dir/proxies.json" >/dev/null; do
  kill -0 "$mt_validator" 2>/dev/null || exit 1
  mt_tries=$((mt_tries+1)); [ "$mt_tries" -lt 15 ] || exit 1
  sleep 1
 done
)
mt_guard_routes() {
 # The table always ends in unreachable, even if the TUN process crashes.
 # LAN management uses the local table (priority 0) and explicit LAN routes.
 mt_validate_clients "$MT_HOME/clients" || mt_die 'Invalid clients file (IPv4 MAC per line).'
 ip -4 route replace unreachable default metric 32760 table "$MT_TABLE"
 ip -4 route show table main scope link | while IFS= read -r mt_route; do
  # Copy only connected LAN networks, never WAN or broad private-IP bypasses.
  case " $mt_route " in *' dev br0 '*)
   mt_net=${mt_route%% *}
   case "$mt_net" in *[!0-9./]*) continue;; esac
   ip -4 route replace "$mt_net" dev br0 table "$MT_TABLE"
  ;; esac
 done
 # Remove only clients no longer configured; keep live rules during refresh.
 # Never remove a rule by priority alone.
 if [ -f "$MT_RUN/applied-clients" ]; then
  while read -r mt_ip mt_mac; do
   if ! awk -v client="$mt_ip" '$1==client {found=1} END {exit !found}' "$MT_HOME/clients"; then
    while ip -4 rule del pref "$MT_PREF" from "$mt_ip/32" table "$MT_TABLE" 2>/dev/null; do :; done
   fi
  done < "$MT_RUN/applied-clients"
 fi
 while read -r mt_ip mt_mac; do
  if ! ip -4 rule show | awk -v client="$mt_ip" -v pref="$MT_PREF:" -v table="$MT_TABLE" '$1==pref && $2=="from" && ($3==client || $3==client"/32") && $4=="lookup" && $5==table {found=1} END {exit !found}'; then
   ip -4 rule add pref "$MT_PREF" from "$mt_ip/32" table "$MT_TABLE"
  fi
 done < "$MT_HOME/clients"
 cp "$MT_HOME/clients" "$MT_RUN/applied-clients"
}
mt_firewall() {
 # Owned chains are refreshed by the Keenetic netfilter hook. Nothing is
 # attached to WAN INPUT; the API and DNS listeners bind only to the LAN IP.
 for mt_spec in 'filter MHTUN_FWD' 'nat MHTUN_DNS' 'mangle MHTUN_MSS'; do
  set -- $mt_spec
  iptables -t "$1" -N "$2" 2>/dev/null || true
  iptables -t "$1" -F "$2"
 done
 mt_lan=$(jq -r '.["dns"].listen | split(":")[0]' "$MT_HOME/config.json")
 while read -r mt_ip mt_mac; do
  # LAN neighbours and management are reachable without the remote server.
  ip -4 route show table main scope link | while IFS= read -r mt_route; do
   case " $mt_route " in *' dev br0 '*)
    mt_net=${mt_route%% *}
    case "$mt_net" in *[!0-9./]*) continue;; esac
    iptables -A MHTUN_FWD -s "$mt_ip" -d "$mt_net" -j RETURN
   ;; esac
  done
  iptables -A MHTUN_FWD -s "$mt_ip" -o "$MT_DEV" -j ACCEPT
  iptables -A MHTUN_FWD -i "$MT_DEV" -d "$mt_ip" -j ACCEPT
  iptables -A MHTUN_FWD -s "$mt_ip" -j REJECT
  for mt_proto in udp tcp; do
   iptables -t nat -A MHTUN_DNS -s "$mt_ip" -p "$mt_proto" --dport 53 -j DNAT --to-destination "$mt_lan:1053"
  done
  iptables -t mangle -A MHTUN_MSS -s "$mt_ip" -o "$MT_DEV" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  iptables -t mangle -A MHTUN_MSS -i "$MT_DEV" -d "$mt_ip" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
 done < "$MT_HOME/clients"
 iptables -C FORWARD -j MHTUN_FWD 2>/dev/null || iptables -I FORWARD 1 -j MHTUN_FWD
 iptables -t nat -C PREROUTING -i br0 -j MHTUN_DNS 2>/dev/null || iptables -t nat -I PREROUTING 1 -i br0 -j MHTUN_DNS
 iptables -t mangle -C FORWARD -j MHTUN_MSS 2>/dev/null || iptables -t mangle -I FORWARD 1 -j MHTUN_MSS
 # Prevent IPv6 from silently bypassing this IPv4 TUN. Match the device MAC
 # so IPv6 temporary addresses need not be enumerated.
 if [ -e /proc/net/if_inet6 ]; then
  command -v ip6tables >/dev/null || mt_die 'IPv6 active but ip6tables unavailable.'
  ip6tables -N MHTUN6 2>/dev/null || true
  ip6tables -F MHTUN6
  while read -r mt_ip mt_mac; do
   ip6tables -A MHTUN6 -i br0 -m mac --mac-source "$mt_mac" -j REJECT
  done < "$MT_HOME/clients"
  ip6tables -C FORWARD -j MHTUN6 2>/dev/null || ip6tables -I FORWARD 1 -j MHTUN6
 fi
}
mt_apply() {
 mkdir -p "$MT_RUN"
 mt_guard_routes
 mt_firewall
 if mt_pid && ip link show "$MT_DEV" >/dev/null 2>&1; then
  # Strict reverse-path filtering would discard replies arriving from TUN.
  # Keep original values for an explicit stop; per-WAN settings stay intact.
  for mt_iface in all br0 "$MT_DEV"; do
   mt_sysctl="/proc/sys/net/ipv4/conf/$mt_iface/rp_filter"
   if [ -f "$mt_sysctl" ]; then
    if [ ! -f "$MT_RUN/rp_filter.$mt_iface" ]; then cat "$mt_sysctl" > "$MT_RUN/rp_filter.$mt_iface"; fi
    echo 0 > "$mt_sysctl"
   fi
  done
  ip link set "$MT_DEV" up
  ip -4 route replace default dev "$MT_DEV" metric 10 table "$MT_TABLE"
 else
  ip -4 route del default dev "$MT_DEV" metric 10 table "$MT_TABLE" 2>/dev/null || true
 fi
}
mt_clear() {
 if [ -f "$MT_RUN/applied-clients" ]; then
  while read -r mt_ip mt_mac; do
   while ip -4 rule del pref "$MT_PREF" from "$mt_ip/32" table "$MT_TABLE" 2>/dev/null; do :; done
  done < "$MT_RUN/applied-clients"
 fi
 for mt_spec in 'filter FORWARD MHTUN_FWD' 'mangle FORWARD MHTUN_MSS'; do
  set -- $mt_spec
  while iptables -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done
  iptables -t "$1" -F "$3" 2>/dev/null || true
  iptables -t "$1" -X "$3" 2>/dev/null || true
 done
 while iptables -t nat -D PREROUTING -i br0 -j MHTUN_DNS 2>/dev/null; do :; done
 iptables -t nat -F MHTUN_DNS 2>/dev/null || true
 iptables -t nat -X MHTUN_DNS 2>/dev/null || true
 while ip6tables -D FORWARD -j MHTUN6 2>/dev/null; do :; done
 ip6tables -F MHTUN6 2>/dev/null || true
 ip6tables -X MHTUN6 2>/dev/null || true
 ip -4 route flush table "$MT_TABLE" 2>/dev/null || true
 for mt_iface in all br0 "$MT_DEV"; do
  mt_sysctl="/proc/sys/net/ipv4/conf/$mt_iface/rp_filter"
  if [ -f "$MT_RUN/rp_filter.$mt_iface" ] && [ -f "$mt_sysctl" ] && [ "$(cat "$mt_sysctl")" = 0 ]; then
   cat "$MT_RUN/rp_filter.$mt_iface" > "$mt_sysctl"
  fi
  rm -f "$MT_RUN/rp_filter.$mt_iface"
 done
 rm -f "$MT_RUN/applied-clients"
}
