#!/usr/bin/env bash
set -euo pipefail

APP_NAME="3xui-bw-guard"
VERSION="v7.3.1"
APP_DIR="/etc/${APP_NAME}"
CONF_FILE="${APP_DIR}/${APP_NAME}.conf"
STATE_DIR="/run/${APP_NAME}"
INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
NFT_TABLE4="${APP_NAME//-/_}_4"
NFT_TABLE6="${APP_NAME//-/_}_6"

COLOR=1
[[ -t 1 ]] || COLOR=0
c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_blue='\033[34m'; c_mag='\033[35m'; c_cyan='\033[36m'; c_bold='\033[1m'
paint(){ local color="$1"; shift; if [[ "$COLOR" -eq 1 ]]; then printf "%b%s%b\n" "$color" "$*" "$c_reset"; else printf "%s\n" "$*"; fi; }
header(){ paint "$c_bold$c_blue" "== $* =="; }
info(){ paint "$c_cyan" "[i] $*"; }
success(){ paint "$c_green" "[+] $*"; }
warn(){ paint "$c_yellow" "[!] $*"; }
error(){ paint "$c_red" "[x] $*" >&2; }
log_debug(){ [[ "${LOG_LEVEL,,}" == "debug" ]] && info "$*" || true; }

banner(){
  if [[ "$COLOR" -eq 1 ]]; then
    printf "%b\n" "$c_bold$c_mag"
    cat <<'BANNER'
   ____      _       _       _                                _
  |___ \_  _(_)_   _| |_____| |__ __      __       __ _ _   _| |
    __) \ \/ / | | | | |_  / | '_ \\ \ /\ / /_____ / _` | | | | |
   / __/ >  <| | |_| | |/ /| | |_) |\ V  V /_____| (_| | |_| | |
  |_____/_/\_\\_|\__,_|_/___|_|_.__/  \_/\_/       \__, |\__,_|_|
                                                   |___/
BANNER
    printf "%b\n" "$c_reset"
  else
    echo "${APP_NAME} ${VERSION}"
  fi
}

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { error "Run as root."; exit 1; }; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
trim(){ local s="$*"; s="${s#${s%%[![:space:]]*}}"; s="${s%${s##*[![:space:]]}}"; printf '%s' "$s"; }
ensure_dirs(){ mkdir -p "$APP_DIR" "$STATE_DIR"; }

normalize_csv(){
  local input="$1" out=() item
  IFS=',' read -r -a arr <<< "$input"
  for item in "${arr[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && out+=("$item")
  done
  local IFS=,
  printf '%s' "${out[*]:-}"
}

csv_to_array(){
  local input="$1" item
  CSV_ITEMS=()
  input="$(normalize_csv "$input")"
  [[ -z "$input" ]] && return 0
  IFS=',' read -r -a tmp <<< "$input"
  for item in "${tmp[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && CSV_ITEMS+=("$item")
  done
}

is_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6(){ [[ "$1" == *:* ]]; }
is_valid_ipv4(){
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=. o
  for o in $1; do (( o >= 0 && o <= 255 )) || return 1; done
  return 0
}
is_valid_ipv6(){ [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]]; }
is_valid_ip(){ is_valid_ipv4 "$1" || is_valid_ipv6 "$1"; }

write_default_config(){
  [[ -f "$CONF_FILE" ]] && return 0
  cat > "$CONF_FILE" <<'CFG'
# 3xui-bw-guard configuration
# Bash syntax only. Comments must start with #

IFACE="auto"
INGRESS_IFB="ifb3xui0"
XRAY_CONFIG_PATH="/usr/local/x-ui/bin/config.json"
MANAGED_PORTS=""
EXCLUDE_PORTS=""
EXEMPT_IPS=""
LIMIT_DOWN="4mbit"
LIMIT_UP="4mbit"
UPLINK_RATE="auto"
INGRESS_RATE="auto"
MAX_CONN_PER_IP="0"
SMART_BURST="yes"
BURST_INTERVAL_MS="120"
SCAN_INTERVAL="2"
FLOW_GRACE_SECONDS="30"
GC_INTERVAL="60"
MAX_ATTACH_PER_CYCLE="128"
SKIP_HW="yes"
LOG_LEVEL="info"
CFG
  success "Wrote default config: $CONF_FILE"
}

load_config(){
  [[ -f "$CONF_FILE" ]] || { error "Config not found: $CONF_FILE"; exit 1; }
  bash -n "$CONF_FILE" >/dev/null 2>&1 || { error "Config syntax error in $CONF_FILE"; exit 1; }
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  IFACE="${IFACE:-auto}"
  INGRESS_IFB="${INGRESS_IFB:-ifb3xui0}"
  XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH:-/usr/local/x-ui/bin/config.json}"
  MANAGED_PORTS="$(normalize_csv "${MANAGED_PORTS:-}")"
  EXCLUDE_PORTS="$(normalize_csv "${EXCLUDE_PORTS:-}")"
  EXEMPT_IPS="$(normalize_csv "${EXEMPT_IPS:-}")"
  LIMIT_DOWN="${LIMIT_DOWN:-4mbit}"
  LIMIT_UP="${LIMIT_UP:-4mbit}"
  UPLINK_RATE="${UPLINK_RATE:-auto}"
  INGRESS_RATE="${INGRESS_RATE:-auto}"
  MAX_CONN_PER_IP="${MAX_CONN_PER_IP:-0}"
  SMART_BURST="${SMART_BURST:-yes}"
  BURST_INTERVAL_MS="${BURST_INTERVAL_MS:-120}"
  SCAN_INTERVAL="${SCAN_INTERVAL:-2}"
  FLOW_GRACE_SECONDS="${FLOW_GRACE_SECONDS:-30}"
  GC_INTERVAL="${GC_INTERVAL:-60}"
  MAX_ATTACH_PER_CYCLE="${MAX_ATTACH_PER_CYCLE:-128}"
  SKIP_HW="${SKIP_HW:-yes}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
}

detect_iface(){
  if [[ "$IFACE" != "auto" && -n "$IFACE" ]]; then printf '%s' "$IFACE"; return 0; fi
  local d
  d="$(ip -o route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  [[ -z "$d" ]] && d="$(ip -o route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  [[ -n "$d" ]] || { error "Could not auto-detect interface. Set IFACE manually."; exit 1; }
  printf '%s' "$d"
}

detect_xray_config(){
  local c
  for c in "$XRAY_CONFIG_PATH" \
           "/usr/local/x-ui/bin/config.json" \
           "/etc/x-ui/config.json" \
           "/usr/local/etc/x-ui/config.json" \
           "/opt/3x-ui/bin/config.json"; do
    [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

port_in_csv(){
  local port="$1" csv="$2" item
  csv_to_array "$csv"
  for item in "${CSV_ITEMS[@]}"; do [[ "$item" == "$port" ]] && return 0; done
  return 1
}

detect_ports(){
  local ports_raw="$MANAGED_PORTS" cfg p final=()
  if [[ -z "$ports_raw" ]]; then
    if cfg="$(detect_xray_config)"; then
      ports_raw="$(jq -r '.inbounds[]? | .port? // empty' "$cfg" 2>/dev/null | awk 'NF' | sort -n | paste -sd, -)"
    fi
  fi
  [[ -n "$ports_raw" ]] || { error "No managed ports found. Set MANAGED_PORTS explicitly."; exit 1; }
  csv_to_array "$ports_raw"
  for p in "${CSV_ITEMS[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    (( p >= 1 && p <= 65535 )) || continue
    if [[ -n "$EXCLUDE_PORTS" ]] && port_in_csv "$p" "$EXCLUDE_PORTS"; then continue; fi
    final+=("$p")
  done
  ((${#final[@]} > 0)) || { error "Managed port list empty after exclusions."; exit 1; }
  printf '%s\n' "${final[@]}" | sort -n -u
}

rate_to_bps(){
  local rate="${1,,}"
  [[ "$rate" == "0" || "$rate" == "off" || "$rate" == "none" ]] && { echo 0; return 0; }
  if [[ "$rate" =~ ^([0-9]+)(kbit|mbit|gbit)$ ]]; then
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    case "$u" in
      kbit) echo $((n * 1000));;
      mbit) echo $((n * 1000 * 1000));;
      gbit) echo $((n * 1000 * 1000 * 1000));;
    esac
    return 0
  fi
  error "Unsupported rate format: $1"
  exit 1
}

compute_burst(){
  local rate="$1" interval_ms="$2"
  if [[ "${SMART_BURST,,}" != "yes" ]]; then echo "65536b"; return 0; fi
  local bps bytes mtu=1500 min max
  bps="$(rate_to_bps "$rate")"
  (( bps > 0 )) || { echo "16384b"; return 0; }
  bytes=$(( (bps * interval_ms) / 8000 ))
  min=$(( mtu * 20 ))
  max=$(( 4 * 1024 * 1024 ))
  (( bytes < min )) && bytes=$min
  (( bytes > max )) && bytes=$max
  echo "${bytes}b"
}

auto_link_rate(){
  local iface="$1" speed
  if cmd_exists ethtool; then
    speed="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {print tolower($2)}' | head -n1)"
    if [[ "$speed" =~ ^([0-9]+)mb/s$ ]]; then echo "${BASH_REMATCH[1]}mbit"; return 0; fi
    if [[ "$speed" =~ ^([0-9]+)gb/s$ ]]; then echo "${BASH_REMATCH[1]}gbit"; return 0; fi
  fi
  if [[ -r "/sys/class/net/${iface}/speed" ]]; then
    speed="$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)"
    if [[ "$speed" =~ ^[0-9]+$ && "$speed" -gt 0 ]]; then echo "${speed}mbit"; return 0; fi
  fi
  echo "1gbit"
}

resolve_rates(){
  EFFECTIVE_IFACE="$(detect_iface)"
  EFFECTIVE_UPLINK_RATE="$UPLINK_RATE"
  EFFECTIVE_INGRESS_RATE="$INGRESS_RATE"
  [[ "${EFFECTIVE_UPLINK_RATE,,}" == "auto" ]] && EFFECTIVE_UPLINK_RATE="$(auto_link_rate "$EFFECTIVE_IFACE")"
  [[ "${EFFECTIVE_INGRESS_RATE,,}" == "auto" ]] && EFFECTIVE_INGRESS_RATE="$EFFECTIVE_UPLINK_RATE"
  DOWN_BURST="$(compute_burst "$LIMIT_DOWN" "$BURST_INTERVAL_MS")"
  UP_BURST="$(compute_burst "$LIMIT_UP" "$BURST_INTERVAL_MS")"
  ROOT_E_BURST="$(compute_burst "$EFFECTIVE_UPLINK_RATE" "$BURST_INTERVAL_MS")"
  ROOT_I_BURST="$(compute_burst "$EFFECTIVE_INGRESS_RATE" "$BURST_INTERVAL_MS")"
  HW_OPT=""
  [[ "${SKIP_HW,,}" == "yes" ]] && HW_OPT="skip_hw"
}

ensure_port_array(){
  mapfile -t PORTS < <(detect_ports)
  PORTS_CSV="$(printf '%s,' "${PORTS[@]}" | sed 's/,$//')"
}

setup_modules(){
  modprobe ifb >/dev/null 2>&1 || true
  modprobe sch_htb >/dev/null 2>&1 || true
  modprobe sch_fq_codel >/dev/null 2>&1 || true
  modprobe cls_flower >/dev/null 2>&1 || true
  modprobe act_mirred >/dev/null 2>&1 || true
}

precompute_maps(){
  declare -gA PORT_MAP=() EXEMPT_MAP=()
  local p ip
  for p in "${PORTS[@]}"; do PORT_MAP["$p"]=1; done
  csv_to_array "$EXEMPT_IPS"
  for ip in "${CSV_ITEMS[@]}"; do EXEMPT_MAP["$ip"]=1; done
}
client_is_exempt(){ [[ -n "${EXEMPT_MAP[$1]:-}" ]]; }

hash_minor_hex(){
  local s="$1" sum
  sum="$(printf '%s' "$s" | cksum | awk '{print $1}')"
  printf '%x' $(( (sum % 0xff00) + 0x0100 ))
}
hash_handle_hex(){
  local s="$1" sum
  sum="$(printf '%s' "$s" | cksum | awk '{print $1}')"
  printf '0x%x' $(( (sum % 0x7fffffff ) + 1 ))
}

cleanup_nft(){
  nft delete table ip "$NFT_TABLE4" 2>/dev/null || true
  nft delete table ip6 "$NFT_TABLE6" 2>/dev/null || true
}

cleanup_qdisc(){
  local iface ifb
  iface="$(detect_iface 2>/dev/null || true)"
  ifb="${INGRESS_IFB:-ifb3xui0}"
  [[ -n "$iface" ]] && tc qdisc del dev "$iface" root 2>/dev/null || true
  [[ -n "$iface" ]] && tc qdisc del dev "$iface" ingress 2>/dev/null || true
  ip link show "$ifb" >/dev/null 2>&1 && tc qdisc del dev "$ifb" root 2>/dev/null || true
  ip link show "$ifb" >/dev/null 2>&1 && ip link set dev "$ifb" down 2>/dev/null || true
  ip link show "$ifb" >/dev/null 2>&1 && ip link delete "$ifb" type ifb 2>/dev/null || true
}

setup_qdisc(){
  setup_modules
  local iface="$EFFECTIVE_IFACE" ifb="$INGRESS_IFB"

  ip link show "$ifb" >/dev/null 2>&1 || ip link add "$ifb" type ifb
  ip link set dev "$ifb" up

  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: htb default 999 r2q 1000
  tc class replace dev "$iface" parent 1: classid 1:1 htb rate "$EFFECTIVE_UPLINK_RATE" ceil "$EFFECTIVE_UPLINK_RATE" burst "$ROOT_E_BURST" cburst "$ROOT_E_BURST"
  tc class replace dev "$iface" parent 1:1 classid 1:999 htb rate "$EFFECTIVE_UPLINK_RATE" ceil "$EFFECTIVE_UPLINK_RATE" burst "$ROOT_E_BURST" cburst "$ROOT_E_BURST" prio 7
  tc qdisc replace dev "$iface" parent 1:999 fq_codel

  tc qdisc del dev "$iface" ingress 2>/dev/null || true
  tc qdisc add dev "$iface" handle ffff: ingress
  tc filter replace dev "$iface" parent ffff: protocol all matchall action mirred egress redirect dev "$ifb"

  tc qdisc del dev "$ifb" root 2>/dev/null || true
  tc qdisc add dev "$ifb" root handle 2: htb default 999 r2q 1000
  tc class replace dev "$ifb" parent 2: classid 2:1 htb rate "$EFFECTIVE_INGRESS_RATE" ceil "$EFFECTIVE_INGRESS_RATE" burst "$ROOT_I_BURST" cburst "$ROOT_I_BURST"
  tc class replace dev "$ifb" parent 2:1 classid 2:999 htb rate "$EFFECTIVE_INGRESS_RATE" ceil "$EFFECTIVE_INGRESS_RATE" burst "$ROOT_I_BURST" cburst "$ROOT_I_BURST" prio 7
  tc qdisc replace dev "$ifb" parent 2:999 fq_codel
}

load_runtime_state(){
  declare -gA ATTACHED_MAP=() LAST_SEEN_MAP=()
  local ip ts
  if [[ -f "$STATE_DIR/attached.db" ]]; then
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      ATTACHED_MAP["$ip"]=1
    done < "$STATE_DIR/attached.db"
  fi
  if [[ -f "$STATE_DIR/seen.db" ]]; then
    while read -r ip ts; do
      [[ -n "$ip" && -n "${ts:-}" ]] || continue
      LAST_SEEN_MAP["$ip"]="$ts"
    done < "$STATE_DIR/seen.db"
  fi
}

save_runtime_state(){
  local ip
  : > "$STATE_DIR/attached.db"
  if ((${#ATTACHED_MAP[@]} > 0)); then
    for ip in "${!ATTACHED_MAP[@]}"; do
      printf '%s\n' "$ip" >> "$STATE_DIR/attached.db"
    done
  fi
  : > "$STATE_DIR/seen.db"
  if ((${#LAST_SEEN_MAP[@]} > 0)); then
    for ip in "${!LAST_SEEN_MAP[@]}"; do
      printf '%s %s\n' "$ip" "${LAST_SEEN_MAP[$ip]}" >> "$STATE_DIR/seen.db"
    done
  fi
}

write_clients_cache(){
  local now="$1" ip age count attached
  : > "$STATE_DIR/clients.cache"
  declare -A union=()
  for ip in "${!CURRENT_COUNTS[@]}"; do union["$ip"]=1; done
  for ip in "${!LAST_SEEN_MAP[@]}"; do union["$ip"]=1; done
  if ((${#union[@]} == 0)); then return 0; fi
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    count="${CURRENT_COUNTS[$ip]:-0}"
    age=0
    [[ -n "${LAST_SEEN_MAP[$ip]:-}" ]] && age=$(( now - LAST_SEEN_MAP[$ip] ))
    attached="no"
    [[ -n "${ATTACHED_MAP[$ip]:-}" ]] && attached="yes"
    printf '%s %s %s %s\n' "$ip" "$count" "$age" "$attached" >> "$STATE_DIR/clients.cache"
  done < <(printf '%s\n' "${!union[@]}" | sort)
}

scan_tcp_clients(){
  declare -gA TCP_COUNTS=()
  local ip cnt
  while read -r ip cnt; do
    [[ -n "$ip" && -n "${cnt:-}" ]] || continue
    is_valid_ip "$ip" || continue
    client_is_exempt "$ip" && continue
    TCP_COUNTS["$ip"]="$cnt"
  done < <(
    ss -Htn state established 2>/dev/null | awk -v ports_csv="$PORTS_CSV" '
      BEGIN{
        n=split(ports_csv,a,",");
        for(i=1;i<=n;i++) want[a[i]]=1
      }
      function local_port(sock,   m){
        if (match(sock, /\]:([0-9]+)$/, m)) return m[1]
        if (match(sock, /:([0-9]+)$/, m)) return m[1]
        return ""
      }
      function peer_host(peer,   m,h){
        if (match(peer, /^\[::ffff:([0-9.]+)\]:[0-9]+$/, m)) h=m[1]
        else if (match(peer, /^\[([0-9A-Fa-f:]+)\]:[0-9]+$/, m)) h=m[1]
        else if (match(peer, /^([0-9.]+):[0-9]+$/, m)) h=m[1]
        else return ""
        sub(/%.*/, "", h)
        return h
      }
      {
        p=local_port($(NF-1))
        if (!(p in want)) next
        h=peer_host($NF)
        if (h=="" || h=="127.0.0.1" || h=="::1" || h=="::" || h=="0.0.0.0") next
        cnt[h]++
      }
      END { for (h in cnt) print h, cnt[h] }
    '
  )
}

scan_udp_clients(){
  declare -gA UDP_COUNTS=()
  local ip cnt
  while read -r ip cnt; do
    [[ -n "$ip" && -n "${cnt:-}" ]] || continue
    is_valid_ip "$ip" || continue
    client_is_exempt "$ip" && continue
    UDP_COUNTS["$ip"]="$cnt"
  done < <(
    conntrack -L -p udp -o extended 2>/dev/null | awk -v ports_csv="$PORTS_CSV" '
      BEGIN{
        n=split(ports_csv,a,",")
        for(i=1;i<=n;i++) want[a[i]]=1
      }
      {
        s=""; d="";
        for(i=1;i<=NF;i++){
          if(s=="" && $i ~ /^src=/) s=substr($i,5)
          else if(d=="" && $i ~ /^dport=/) d=substr($i,7)
        }
        if(s != "" && (d in want)) cnt[s]++
      }
      END { for(h in cnt) print h, cnt[h] }
    '
  )
}

collect_current_clients(){
  declare -gA CURRENT_COUNTS=()
  scan_tcp_clients
  scan_udp_clients
  local ip
  for ip in "${!TCP_COUNTS[@]}"; do CURRENT_COUNTS["$ip"]=$(( ${CURRENT_COUNTS[$ip]:-0} + ${TCP_COUNTS[$ip]} )); done
  for ip in "${!UDP_COUNTS[@]}"; do CURRENT_COUNTS["$ip"]=$(( ${CURRENT_COUNTS[$ip]:-0} + ${UDP_COUNTS[$ip]} )); done
}

add_client_filters(){
  local ip="$1" family minor port proto handle
  is_valid_ip "$ip" || return 0
  minor="$(hash_minor_hex "$ip")"
  if [[ "$LIMIT_DOWN" != "0" && "$LIMIT_DOWN" != "off" && "$LIMIT_DOWN" != "none" ]]; then
    tc class replace dev "$EFFECTIVE_IFACE" parent 1:1 classid "1:${minor}" htb rate "$LIMIT_DOWN" ceil "$LIMIT_DOWN" burst "$DOWN_BURST" cburst "$DOWN_BURST" quantum 1514 prio 1
    tc qdisc replace dev "$EFFECTIVE_IFACE" parent "1:${minor}" fq_codel
  fi
  if [[ "$LIMIT_UP" != "0" && "$LIMIT_UP" != "off" && "$LIMIT_UP" != "none" ]]; then
    tc class replace dev "$INGRESS_IFB" parent 2:1 classid "2:${minor}" htb rate "$LIMIT_UP" ceil "$LIMIT_UP" burst "$UP_BURST" cburst "$UP_BURST" quantum 1514 prio 1
    tc qdisc replace dev "$INGRESS_IFB" parent "2:${minor}" fq_codel
  fi
  if is_ipv4 "$ip"; then family="ip"; else family="ipv6"; fi
  for port in "${PORTS[@]}"; do
    for proto in tcp udp; do
      if [[ "$LIMIT_DOWN" != "0" && "$LIMIT_DOWN" != "off" && "$LIMIT_DOWN" != "none" ]]; then
        handle="$(hash_handle_hex "egress|$family|$proto|$port|$ip")"
        tc filter replace dev "$EFFECTIVE_IFACE" parent 1: protocol "$family" pref 100 handle "$handle" flower ${HW_OPT:+$HW_OPT} \
          dst_ip "$ip" ip_proto "$proto" src_port "$port" classid "1:${minor}" >/dev/null
      fi
      if [[ "$LIMIT_UP" != "0" && "$LIMIT_UP" != "off" && "$LIMIT_UP" != "none" ]]; then
        handle="$(hash_handle_hex "ingress|$family|$proto|$port|$ip")"
        tc filter replace dev "$INGRESS_IFB" parent 2: protocol "$family" pref 100 handle "$handle" flower ${HW_OPT:+$HW_OPT} \
          src_ip "$ip" ip_proto "$proto" dst_port "$port" classid "2:${minor}" >/dev/null
      fi
    done
  done
}

remove_client_filters(){
  local ip="$1" family port proto minor handle
  is_valid_ip "$ip" || return 0
  minor="$(hash_minor_hex "$ip")"
  if is_ipv4 "$ip"; then family="ip"; else family="ipv6"; fi
  for port in "${PORTS[@]}"; do
    for proto in tcp udp; do
      handle="$(hash_handle_hex "egress|$family|$proto|$port|$ip")"
      tc filter del dev "$EFFECTIVE_IFACE" parent 1: protocol "$family" pref 100 handle "$handle" flower 2>/dev/null || true
      handle="$(hash_handle_hex "ingress|$family|$proto|$port|$ip")"
      tc filter del dev "$INGRESS_IFB" parent 2: protocol "$family" pref 100 handle "$handle" flower 2>/dev/null || true
    done
  done
  tc qdisc del dev "$EFFECTIVE_IFACE" parent "1:${minor}" 2>/dev/null || true
  tc qdisc del dev "$INGRESS_IFB" parent "2:${minor}" 2>/dev/null || true
  tc class del dev "$EFFECTIVE_IFACE" classid "1:${minor}" 2>/dev/null || true
  tc class del dev "$INGRESS_IFB" classid "2:${minor}" 2>/dev/null || true
}

attach_new_clients(){
  local ip attached=0
  if ((${#CURRENT_COUNTS[@]} == 0)); then return 0; fi
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    [[ -z "${ATTACHED_MAP[$ip]:-}" ]] || continue
    add_client_filters "$ip"
    ATTACHED_MAP["$ip"]=1
    attached=$((attached + 1))
    log_debug "attached $ip"
    (( attached >= MAX_ATTACH_PER_CYCLE )) && break
  done < <(printf '%s\n' "${!CURRENT_COUNTS[@]}" | sort)
}

gc_stale_clients(){
  local now="$1" ip
  if ((${#LAST_SEEN_MAP[@]} == 0)); then return 0; fi
  for ip in "${!LAST_SEEN_MAP[@]}"; do
    [[ -n "$ip" ]] || continue
    if (( now - LAST_SEEN_MAP[$ip] > FLOW_GRACE_SECONDS )); then
      if [[ -n "${ATTACHED_MAP[$ip]:-}" ]]; then
        remove_client_filters "$ip"
        unset 'ATTACHED_MAP[$ip]'
        log_debug "detached $ip"
      fi
      unset 'LAST_SEEN_MAP[$ip]'
    fi
  done
}

update_seen_from_current(){
  local now="$1" ip
  for ip in "${!CURRENT_COUNTS[@]}"; do
    LAST_SEEN_MAP["$ip"]="$now"
  done
}

blocked_set_hash(){
  local ip out=""
  (( MAX_CONN_PER_IP > 0 )) || { echo "disabled"; return 0; }
  if ((${#CURRENT_COUNTS[@]} == 0)); then echo "empty"; return 0; fi
  while IFS= read -r ip; do
    (( ${CURRENT_COUNTS[$ip]:-0} > MAX_CONN_PER_IP )) || continue
    out+="${ip}"$'\n'
  done < <(printf '%s\n' "${!CURRENT_COUNTS[@]}" | sort)
  [[ -n "$out" ]] || { echo "empty"; return 0; }
  printf '%s' "$out" | cksum | awk '{print $1":"$2}'
}

build_connlimit_tables(){
  cleanup_nft
  (( MAX_CONN_PER_IP > 0 )) || return 0
  local ports_elems blocked4="" blocked6="" ip
  ports_elems="$(printf '%s, ' "${PORTS[@]}" | sed 's/, $//')"
  for ip in "${!CURRENT_COUNTS[@]}"; do
    (( ${CURRENT_COUNTS[$ip]:-0} > MAX_CONN_PER_IP )) || continue
    if is_ipv4 "$ip"; then blocked4+="${ip}, "; else blocked6+="${ip}, "; fi
  done
  blocked4="${blocked4%, }"
  blocked6="${blocked6%, }"
  {
    echo "table ip ${NFT_TABLE4} {"
    echo "  set blocked { type ipv4_addr; flags interval; }"
    echo "  chain input { type filter hook input priority -5; policy accept;"
    echo "    tcp dport { ${ports_elems} } ct state new ip saddr @blocked drop"
    echo "    udp dport { ${ports_elems} } ct state new ip saddr @blocked drop"
    echo "  }"
    echo "}"
    echo "table ip6 ${NFT_TABLE6} {"
    echo "  set blocked { type ipv6_addr; flags interval; }"
    echo "  chain input { type filter hook input priority -5; policy accept;"
    echo "    tcp dport { ${ports_elems} } ct state new ip6 saddr @blocked drop"
    echo "    udp dport { ${ports_elems} } ct state new ip6 saddr @blocked drop"
    echo "  }"
    echo "}"
  } | nft -f - >/dev/null 2>&1 || true
  [[ -n "$blocked4" ]] && nft add element ip "$NFT_TABLE4" blocked "{ ${blocked4} }" >/dev/null 2>&1 || true
  [[ -n "$blocked6" ]] && nft add element ip6 "$NFT_TABLE6" blocked "{ ${blocked6} }" >/dev/null 2>&1 || true
}

load_block_hash(){ LAST_BLOCK_HASH=""; [[ -f "$STATE_DIR/blocked.hash" ]] && LAST_BLOCK_HASH="$(cat "$STATE_DIR/blocked.hash" 2>/dev/null || true)"; }
save_block_hash(){ printf '%s' "$1" > "$STATE_DIR/blocked.hash"; }

flush_runtime(){
  cleanup_nft
  cleanup_qdisc
  rm -f "$STATE_DIR/attached.db" "$STATE_DIR/seen.db" "$STATE_DIR/clients.db" "$STATE_DIR/clients.db.tmp" "$STATE_DIR/blocked.hash"
  success "Runtime flushed"
}

write_service(){
  cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=3x-ui inbound per-IP bandwidth guard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} run-daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
  success "Wrote systemd service: $SERVICE_FILE"
}

copy_self(){
  local src
  src="$(readlink -f "$0")"
  install -m 0755 "$src" "$INSTALL_PATH"
  success "Installed script to $INSTALL_PATH"
}

install_deps(){
  header "Installing dependencies"
  if cmd_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iproute2 nftables conntrack jq ethtool kmod iptables
  elif cmd_exists dnf; then
    dnf install -y iproute nftables conntrack-tools jq ethtool kmod iptables
  elif cmd_exists yum; then
    yum install -y iproute nftables conntrack-tools jq ethtool kmod iptables
  elif cmd_exists pacman; then
    pacman -Sy --noconfirm iproute2 nftables conntrack-tools jq ethtool kmod iptables
  elif cmd_exists zypper; then
    zypper --non-interactive install iproute2 nftables conntrack-tools jq ethtool kmod iptables
  else
    warn "Unsupported package manager. Install manually: iproute2 nftables conntrack-tools jq ethtool kmod iptables"
  fi
}

configtest(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  precompute_maps
  header "Configuration test"
  printf '%-22s %s\n' "Version" "$VERSION"
  printf '%-22s %s\n' "Interface" "$EFFECTIVE_IFACE"
  printf '%-22s %s\n' "Inbound ports" "$PORTS_CSV"
  printf '%-22s %s\n' "Limit down" "$LIMIT_DOWN"
  printf '%-22s %s\n' "Limit up" "$LIMIT_UP"
  printf '%-22s %s\n' "Uplink rate" "$EFFECTIVE_UPLINK_RATE"
  printf '%-22s %s\n' "Ingress rate" "$EFFECTIVE_INGRESS_RATE"
  printf '%-22s %s\n' "Scan interval" "$SCAN_INTERVAL"
  printf '%-22s %s\n' "Grace seconds" "$FLOW_GRACE_SECONDS"
  printf '%-22s %s\n' "GC interval" "$GC_INTERVAL"
  printf '%-22s %s\n' "Max attach/cycle" "$MAX_ATTACH_PER_CYCLE"
}

cmd_config(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  header "Effective configuration"
  printf '%-22s %s\n' "Version" "$VERSION"
  printf '%-22s %s\n' "Config file" "$CONF_FILE"
  printf '%-22s %s\n' "Interface" "$EFFECTIVE_IFACE"
  printf '%-22s %s\n' "IFB" "$INGRESS_IFB"
  printf '%-22s %s\n' "Managed ports" "$PORTS_CSV"
  printf '%-22s %s\n' "Excluded ports" "${EXCLUDE_PORTS:-<none>}"
  printf '%-22s %s\n' "Exempt IPs" "${EXEMPT_IPS:-<none>}"
  printf '%-22s %s\n' "Limit down" "$LIMIT_DOWN"
  printf '%-22s %s\n' "Limit up" "$LIMIT_UP"
  printf '%-22s %s\n' "Uplink rate" "$EFFECTIVE_UPLINK_RATE"
  printf '%-22s %s\n' "Ingress rate" "$EFFECTIVE_INGRESS_RATE"
  printf '%-22s %s\n' "Max conn / IP" "$MAX_CONN_PER_IP"
  printf '%-22s %s\n' "Smart burst" "$SMART_BURST"
  printf '%-22s %s\n' "Scan interval" "$SCAN_INTERVAL"
  printf '%-22s %s\n' "Grace seconds" "$FLOW_GRACE_SECONDS"
  printf '%-22s %s\n' "GC interval" "$GC_INTERVAL"
  printf '%-22s %s\n' "Max attach/cycle" "$MAX_ATTACH_PER_CYCLE"
  printf '%-22s %s\n' "Skip HW" "$SKIP_HW"
}

cmd_clients(){
  need_root
  local fresh="no" arg
  for arg in "$@"; do
    [[ "$arg" == "--fresh" ]] && fresh="yes"
  done

  load_config
  resolve_rates
  ensure_port_array
  precompute_maps

  header "Discovered clients"

  if [[ "$fresh" == "yes" ]]; then
    collect_current_clients
    if ((${#CURRENT_COUNTS[@]} == 0)); then echo "<none>"; return 0; fi
    local ip
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      printf '%-40s %s
' "$ip" "connections=${CURRENT_COUNTS[$ip]:-0}"
    done < <(printf '%s
' "${!CURRENT_COUNTS[@]}" | sort)
    return 0
  fi

  if [[ -s "$STATE_DIR/clients.db" ]]; then
    local found=0 ip count age attached
    while read -r ip count age attached; do
      [[ -n "${ip:-}" ]] || continue
      [[ "$ip" == \#* ]] && continue
      printf '%-40s connections=%s attached=%s age=%ss
' "$ip" "$count" "$attached" "$age"
      found=1
    done < "$STATE_DIR/clients.db"
    (( found == 1 )) && return 0
  fi

  collect_current_clients
  if ((${#CURRENT_COUNTS[@]} == 0)); then echo "<none>"; return 0; fi
  local ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    printf '%-40s %s
' "$ip" "connections=${CURRENT_COUNTS[$ip]:-0}"
  done < <(printf '%s
' "${!CURRENT_COUNTS[@]}" | sort)
}


cmd_hits(){
  need_root
  load_config || true
  EFFECTIVE_IFACE="$(detect_iface 2>/dev/null || echo eth0)"
  header "Egress filters on ${EFFECTIVE_IFACE}"
  tc -s filter show dev "$EFFECTIVE_IFACE" parent 1: 2>/dev/null || true
  echo
  header "Ingress filters on ${INGRESS_IFB:-ifb3xui0}"
  tc -s filter show dev "${INGRESS_IFB:-ifb3xui0}" parent 2: 2>/dev/null || true
  echo
  header "Egress classes on ${EFFECTIVE_IFACE}"
  tc -s class show dev "$EFFECTIVE_IFACE" 2>/dev/null || true
  echo
  header "Ingress classes on ${INGRESS_IFB:-ifb3xui0}"
  tc -s class show dev "${INGRESS_IFB:-ifb3xui0}" 2>/dev/null || true
}

cmd_logs(){ journalctl -u "$APP_NAME" -n 120 --no-pager; }

cmd_doctor(){
  need_root
  load_config || true
  header "Doctor"
  local c iface
  for c in tc ss nft conntrack jq awk sed grep ip; do
    if cmd_exists "$c"; then success "found: $c"; else warn "missing: $c"; fi
  done
  iface="$(detect_iface 2>/dev/null || true)"
  [[ -n "$iface" && -d "/sys/class/net/$iface" ]] && success "interface exists: $iface" || warn "interface not found"
  detect_xray_config >/dev/null 2>&1 && success "xray config found" || warn "xray config not found"
  systemctl is-enabled nftables >/dev/null 2>&1 && success "nftables service enabled" || warn "nftables service not enabled"
  modprobe -n ifb >/dev/null 2>&1 && success "kernel module available: ifb" || warn "kernel module unavailable: ifb"
  modprobe -n cls_flower >/dev/null 2>&1 && success "kernel module available: cls_flower" || warn "kernel module unavailable: cls_flower"
  modprobe -n act_mirred >/dev/null 2>&1 && success "kernel module available: act_mirred" || warn "kernel module unavailable: act_mirred"
}

show_status(){ header "Service status"; systemctl --no-pager --full status "$APP_NAME" || true; }

daemon_loop(){
  local now next_gc blocked_hash
  next_gc=0
  while true; do
    now="$(date +%s)"
    collect_current_clients
    update_seen_from_current "$now"
    attach_new_clients
    load_block_hash
    blocked_hash="$(blocked_set_hash)"
    if [[ "$blocked_hash" != "$LAST_BLOCK_HASH" ]]; then
      build_connlimit_tables
      save_block_hash "$blocked_hash"
    fi
    if (( now >= next_gc )); then
      gc_stale_clients "$now"
      next_gc=$(( now + GC_INTERVAL ))
    fi
    write_clients_cache "$now"
    save_runtime_state
    sleep "$SCAN_INTERVAL"
  done
}

run_daemon(){
  need_root
  ensure_dirs
  load_config
  resolve_rates
  ensure_port_array
  precompute_maps
  cleanup_nft
  cleanup_qdisc
  setup_qdisc
  declare -gA ATTACHED_MAP=() LAST_SEEN_MAP=()
  rm -f "$STATE_DIR/attached.db" "$STATE_DIR/seen.db" "$STATE_DIR/clients.db" "$STATE_DIR/clients.db.tmp" "$STATE_DIR/blocked.hash"
  banner
  info "Interface: $EFFECTIVE_IFACE"
  info "Inbound ports: $PORTS_CSV"
  info "Limits: down=$LIMIT_DOWN up=$LIMIT_UP"
  info "Scan interval: ${SCAN_INTERVAL}s"
  info "GC interval: ${GC_INTERVAL}s"
  info "Max attach/cycle: ${MAX_ATTACH_PER_CYCLE}"
  collect_current_clients
  write_clients_cache "$(date +%s)"
  trap 'flush_runtime >/dev/null 2>&1 || true; exit 0' INT TERM
  daemon_loop
}

cmd_wizard(){
  need_root
  ensure_dirs
  write_default_config
  load_config
  banner
  header "Interactive wizard"
  local v
  printf 'Press Enter to keep the value in [brackets].\n\n'
  read -r -p "WAN interface [${IFACE}]: " v; IFACE="${v:-$IFACE}"
  read -r -p "Managed inbound ports, comma separated [${MANAGED_PORTS:-443}]: " v; MANAGED_PORTS="$(normalize_csv "${v:-${MANAGED_PORTS:-443}}")"
  read -r -p "Exclude ports [${EXCLUDE_PORTS}]: " v; EXCLUDE_PORTS="$(normalize_csv "${v:-$EXCLUDE_PORTS}")"
  read -r -p "Exempt IPs [${EXEMPT_IPS}]: " v; EXEMPT_IPS="$(normalize_csv "${v:-$EXEMPT_IPS}")"
  read -r -p "Per-client download limit [${LIMIT_DOWN}]: " v; LIMIT_DOWN="${v:-$LIMIT_DOWN}"
  read -r -p "Per-client upload limit [${LIMIT_UP}]: " v; LIMIT_UP="${v:-$LIMIT_UP}"
  read -r -p "Root uplink rate [${UPLINK_RATE}]: " v; UPLINK_RATE="${v:-$UPLINK_RATE}"
  read -r -p "Root ingress rate [${INGRESS_RATE}]: " v; INGRESS_RATE="${v:-$INGRESS_RATE}"
  read -r -p "Max connections per IP (0=off) [${MAX_CONN_PER_IP}]: " v; MAX_CONN_PER_IP="${v:-$MAX_CONN_PER_IP}"
  read -r -p "Smart burst yes/no [${SMART_BURST}]: " v; SMART_BURST="${v:-$SMART_BURST}"
  read -r -p "Burst interval ms [${BURST_INTERVAL_MS}]: " v; BURST_INTERVAL_MS="${v:-$BURST_INTERVAL_MS}"
  read -r -p "Scan interval seconds [${SCAN_INTERVAL}]: " v; SCAN_INTERVAL="${v:-$SCAN_INTERVAL}"
  read -r -p "Grace seconds [${FLOW_GRACE_SECONDS}]: " v; FLOW_GRACE_SECONDS="${v:-$FLOW_GRACE_SECONDS}"
  read -r -p "GC interval seconds [${GC_INTERVAL}]: " v; GC_INTERVAL="${v:-$GC_INTERVAL}"
  read -r -p "Max attach per cycle [${MAX_ATTACH_PER_CYCLE}]: " v; MAX_ATTACH_PER_CYCLE="${v:-$MAX_ATTACH_PER_CYCLE}"
  read -r -p "Skip hardware offload yes/no [${SKIP_HW}]: " v; SKIP_HW="${v:-$SKIP_HW}"
  read -r -p "Log level info/debug [${LOG_LEVEL}]: " v; LOG_LEVEL="${v:-$LOG_LEVEL}"
  cat > "$CONF_FILE" <<CFG
# 3xui-bw-guard configuration
# Bash syntax only. Comments must start with #

IFACE="${IFACE}"
INGRESS_IFB="${INGRESS_IFB}"
XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH}"
MANAGED_PORTS="${MANAGED_PORTS}"
EXCLUDE_PORTS="${EXCLUDE_PORTS}"
EXEMPT_IPS="${EXEMPT_IPS}"
LIMIT_DOWN="${LIMIT_DOWN}"
LIMIT_UP="${LIMIT_UP}"
UPLINK_RATE="${UPLINK_RATE}"
INGRESS_RATE="${INGRESS_RATE}"
MAX_CONN_PER_IP="${MAX_CONN_PER_IP}"
SMART_BURST="${SMART_BURST}"
BURST_INTERVAL_MS="${BURST_INTERVAL_MS}"
SCAN_INTERVAL="${SCAN_INTERVAL}"
FLOW_GRACE_SECONDS="${FLOW_GRACE_SECONDS}"
GC_INTERVAL="${GC_INTERVAL}"
MAX_ATTACH_PER_CYCLE="${MAX_ATTACH_PER_CYCLE}"
SKIP_HW="${SKIP_HW}"
LOG_LEVEL="${LOG_LEVEL}"
CFG
  success "Saved configuration to $CONF_FILE"
  configtest
}

install_all(){
  need_root
  banner
  install_deps
  ensure_dirs
  copy_self
  write_default_config
  write_service
  success "Install complete"
}

update_all(){
  need_root
  copy_self
  write_service
  systemctl daemon-reload
  success "Updated installed script and service"
}

uninstall_all(){
  need_root
  systemctl disable --now "$APP_NAME" 2>/dev/null || true
  flush_runtime >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$INSTALL_PATH"
  rm -rf "$APP_DIR" "$STATE_DIR"
  systemctl daemon-reload
  success "Uninstalled $APP_NAME"
}

case "${1:-}" in
  install) install_all ;;
  update) update_all ;;
  uninstall) uninstall_all ;;
  enable) systemctl enable "$APP_NAME" ;;
  disable) systemctl disable "$APP_NAME" ;;
  start) systemctl start "$APP_NAME" ;;
  stop) systemctl stop "$APP_NAME" ;;
  restart) systemctl restart "$APP_NAME" ;;
  status) show_status ;;
  configtest) configtest ;;
  config) cmd_config ;;
  clients) cmd_clients "$@" ;;
  hits) cmd_hits ;;
  logs) cmd_logs ;;
  doctor) cmd_doctor ;;
  wizard) cmd_wizard ;;
  run-daemon) run_daemon ;;
  stop-runtime|flush) flush_runtime ;;
  *)
    banner
    cat <<USAGE
Usage: $0 {install|update|uninstall|enable|disable|start|stop|restart|status|configtest|config|clients [--fresh]|hits|logs|doctor|wizard|run-daemon|stop-runtime|flush}
USAGE
    exit 1
    ;;
esac
