#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="3xui-bw-guard"
VERSION="v7.4.1"
APP_DIR="/etc/${APP_NAME}"
CONF_FILE="${APP_DIR}/${APP_NAME}.conf"
STATE_DIR="/run/${APP_NAME}"
INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
NFT_TABLE4="${APP_NAME//-/_}_v4"
NFT_TABLE6="${APP_NAME//-/_}_v6"
LOCK_FILE="/run/${APP_NAME}.lock"

COLOR=1
if [[ ! -t 1 ]]; then COLOR=0; fi
c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_blue='\033[34m'; c_mag='\033[35m'; c_cyan='\033[36m'; c_bold='\033[1m'

paint(){ local color="$1"; shift; if [[ "$COLOR" -eq 1 ]]; then printf "%b%s%b\n" "$color" "$*" "$c_reset"; else printf "%s\n" "$*"; fi; }
header(){ paint "$c_bold$c_blue" "== $* =="; }
info(){ paint "$c_cyan" "[i] $*"; }
success(){ paint "$c_green" "[+] $*"; }
warn(){ paint "$c_yellow" "[!] $*"; }
error(){ paint "$c_red" "[x] $*" >&2; }

banner(){
  if [[ "$COLOR" -eq 1 ]]; then
    printf "%b\n" "$c_bold$c_mag"
    cat <<'BANNER'
   ____      _       _       _                                _
  |___ \_  _(_)_   _| |_____| |__ __      __       __ _ _   _| |
    __) \ \/ / | | | | |_  / | '_ \\ \ /\ / /_____ / _` | | | | |
   / __/ >  <| | |_| | |/ /| | |_) |\ V  V /_____| (_| | |_| | |
  |_____/_/\_\_|\__,_|_/___|_|_.__/  \_/\_/       \__, |\__, |_|
                                                   |___/ |___/
BANNER
    printf "%b\n" "$c_reset"
  else
    printf "%s %s\n" "$APP_NAME" "$VERSION"
  fi
}

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { error "Run as root."; exit 1; }; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
trim(){ local s="$*"; s="${s#${s%%[![:space:]]*}}"; s="${s%${s##*[![:space:]]}}"; printf '%s' "$s"; }
ensure_dirs(){ mkdir -p "$APP_DIR" "$STATE_DIR"; }

trap 'rc=$?; [[ $rc -ne 0 ]] && echo "[ERR] line=$LINENO cmd=$BASH_COMMAND rc=$rc" >&2' ERR

normalize_csv(){
  local input="$1" out=() item
  IFS=',' read -r -a arr <<< "$input"
  for item in "${arr[@]:-}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && out+=("$item")
  done
  local IFS=,
  printf '%s' "${out[*]:-}"
}

csv_to_array(){
  local input="$1" item cleaned
  cleaned="$(normalize_csv "$input")"
  CSV_ITEMS=()
  [[ -z "$cleaned" ]] && return 0
  IFS=',' read -r -a tmp <<< "$cleaned"
  for item in "${tmp[@]:-}"; do
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
  local bps bytes mtu=1500 min max
  if [[ "${STRICT_MODE,,}" == "yes" ]]; then
    [[ "$rate" == "0" || "$rate" == "off" || "$rate" == "none" ]] && { echo "8kb"; return 0; }
    echo "16kb"
    return 0
  fi
  if [[ "${SMART_BURST,,}" != "yes" ]]; then
    echo "64kb"
    return 0
  fi
  bps="$(rate_to_bps "$rate")"
  (( bps > 0 )) || { echo "16kb"; return 0; }
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

write_default_config(){
  [[ -f "$CONF_FILE" ]] && return 0
  cat > "$CONF_FILE" <<'CFG'
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
STRICT_MODE="no"
STRICT_DISABLE_OFFLOADS="no"
STRICT_R2Q="1"
STRICT_QUANTUM="1514"
DEBUG_BYPASS_WARN_RATIO="0.30"
LOG_LEVEL="info"
CFG
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
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
}

copy_self(){
  local src
  src="$(readlink -f "$0")"
  install -m 0755 "$src" "$INSTALL_PATH"
}

install_deps(){
  if cmd_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iproute2 nftables conntrack jq ethtool kmod iptables >/dev/null
  elif cmd_exists dnf; then
    dnf install -y iproute nftables conntrack-tools jq ethtool kmod iptables >/dev/null
  elif cmd_exists yum; then
    yum install -y iproute nftables conntrack-tools jq ethtool kmod iptables >/dev/null
  elif cmd_exists pacman; then
    pacman -Sy --noconfirm iproute2 nftables conntrack-tools jq ethtool kmod iptables >/dev/null
  elif cmd_exists zypper; then
    zypper --non-interactive install iproute2 nftables conntrack-tools jq ethtool kmod iptables >/dev/null
  else
    warn "Install dependencies manually: iproute2 nftables conntrack-tools jq ethtool kmod iptables"
  fi
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
  STRICT_MODE="${STRICT_MODE:-no}"
  STRICT_DISABLE_OFFLOADS="${STRICT_DISABLE_OFFLOADS:-no}"
  STRICT_R2Q="${STRICT_R2Q:-1}"
  STRICT_QUANTUM="${STRICT_QUANTUM:-1514}"
  DEBUG_BYPASS_WARN_RATIO="${DEBUG_BYPASS_WARN_RATIO:-0.30}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
}

log_debug(){ [[ "${LOG_LEVEL,,}" == "debug" ]] && info "$*" || true; }

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
  for item in "${CSV_ITEMS[@]:-}"; do [[ "$item" == "$port" ]] && return 0; done
  return 1
}

detect_ports(){
  local ports_raw="$MANAGED_PORTS" cfg p
  local final=()
  if [[ -z "$ports_raw" ]]; then
    if cfg="$(detect_xray_config)"; then
      ports_raw="$(jq -r '.inbounds[]? | .port? // empty' "$cfg" 2>/dev/null | awk 'NF' | sort -n | paste -sd, -)"
    fi
  fi
  [[ -n "$ports_raw" ]] || { error "No managed ports found. Set MANAGED_PORTS explicitly."; exit 1; }
  csv_to_array "$ports_raw"
  for p in "${CSV_ITEMS[@]:-}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    (( p >= 1 && p <= 65535 )) || continue
    if [[ -n "$EXCLUDE_PORTS" ]] && port_in_csv "$p" "$EXCLUDE_PORTS"; then continue; fi
    final+=("$p")
  done
  ((${#final[@]} > 0)) || { error "Managed port list empty after exclusions."; exit 1; }
  printf '%s\n' "${final[@]}" | sort -n -u
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
  if [[ "${STRICT_MODE,,}" == "yes" ]]; then
    ROOT_R2Q="$STRICT_R2Q"
    CLASS_QUANTUM="$STRICT_QUANTUM"
  else
    ROOT_R2Q="10"
    CLASS_QUANTUM=""
  fi
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

strict_mode_apply(){
  [[ "${STRICT_MODE,,}" == "yes" ]] || return 0
  [[ "${STRICT_DISABLE_OFFLOADS,,}" == "yes" ]] || return 0
  if cmd_exists ethtool; then
    ethtool -K "$EFFECTIVE_IFACE" tso off gso off gro off lro off >/dev/null 2>&1 || true
  fi
}

setup_qdisc(){
  setup_modules
  local iface="$EFFECTIVE_IFACE" ifb="$INGRESS_IFB"
  ip link show "$ifb" >/dev/null 2>&1 || ip link add "$ifb" type ifb
  ip link set dev "$ifb" up

  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: htb default 999 r2q "$ROOT_R2Q"
  tc class replace dev "$iface" parent 1: classid 1:1 htb rate "$EFFECTIVE_UPLINK_RATE" ceil "$EFFECTIVE_UPLINK_RATE" burst "$ROOT_E_BURST" cburst "$ROOT_E_BURST"
  tc class replace dev "$iface" parent 1:1 classid 1:999 htb rate "$EFFECTIVE_UPLINK_RATE" ceil "$EFFECTIVE_UPLINK_RATE" burst "$ROOT_E_BURST" cburst "$ROOT_E_BURST" prio 7
  tc qdisc replace dev "$iface" parent 1:999 fq_codel

  tc qdisc del dev "$iface" ingress 2>/dev/null || true
  tc qdisc add dev "$iface" handle ffff: ingress
  tc filter replace dev "$iface" parent ffff: protocol all matchall action mirred egress redirect dev "$ifb"

  tc qdisc del dev "$ifb" root 2>/dev/null || true
  tc qdisc add dev "$ifb" root handle 2: htb default 999 r2q "$ROOT_R2Q"
  tc class replace dev "$ifb" parent 2: classid 2:1 htb rate "$EFFECTIVE_INGRESS_RATE" ceil "$EFFECTIVE_INGRESS_RATE" burst "$ROOT_I_BURST" cburst "$ROOT_I_BURST"
  tc class replace dev "$ifb" parent 2:1 classid 2:999 htb rate "$EFFECTIVE_INGRESS_RATE" ceil "$EFFECTIVE_INGRESS_RATE" burst "$ROOT_I_BURST" cburst "$ROOT_I_BURST" prio 7
  tc qdisc replace dev "$ifb" parent 2:999 fq_codel
}

cleanup_qdisc(){
  local iface ifb
  iface="$(detect_iface 2>/dev/null || true)"
  ifb="${INGRESS_IFB:-ifb3xui0}"
  [[ -n "$iface" ]] && tc qdisc del dev "$iface" root 2>/dev/null || true
  [[ -n "$iface" ]] && tc qdisc del dev "$iface" ingress 2>/dev/null || true
  ip link show "$ifb" >/dev/null 2>&1 && tc qdisc del dev "$ifb" root 2>/dev/null || true
}

cleanup_nft(){
  nft delete table ip "$NFT_TABLE4" 2>/dev/null || true
  nft delete table ip6 "$NFT_TABLE6" 2>/dev/null || true
}

normalize_peer_socket(){
  local raw="$1" host port
  raw="$(trim "$raw")"
  [[ -z "$raw" ]] && return 1
  if [[ "$raw" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  host="${host%%%*}"
  if [[ "$host" =~ ^::ffff:([0-9]{1,3}(\.[0-9]{1,3}){3})$ ]]; then
    host="${BASH_REMATCH[1]}"
  fi
  [[ "$host" == "127.0.0.1" || "$host" == "::1" || "$host" == "0.0.0.0" || "$host" == "::" ]] && return 1
  is_valid_ip "$host" || return 1
  printf '%s %s\n' "$host" "$port"
}

load_exempt_set(){
  declare -gA EXEMPT_SET=()
  csv_to_array "$EXEMPT_IPS"
  local ip
  for ip in "${CSV_ITEMS[@]:-}"; do EXEMPT_SET["$ip"]=1; done
}

client_is_exempt(){ [[ -n "${EXEMPT_SET[$1]:-}" ]]; }

fresh_collect_current_clients(){
  declare -gA CURRENT_COUNTS=()
  declare -ga CURRENT_CLIENTS=()
  local line local_sock peer parsed host lport ip cnt ss_expr ct_expr port p item local_port

  if ((${#PORTS[@]} == 0)); then return 0; fi

  ss_expr=""
  for p in "${PORTS[@]}"; do
    if [[ -z "$ss_expr" ]]; then ss_expr="( sport = :${p} )"; else ss_expr="${ss_expr} or ( sport = :${p} )"; fi
  done

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local_sock="$(awk '{print $(NF-1)}' <<< "$line")"
    peer="$(awk '{print $NF}' <<< "$line")"
    parsed="$(normalize_peer_socket "$peer" 2>/dev/null || true)"
    [[ -n "$parsed" ]] || continue
    ip="${parsed% *}"
    local_port=""
    if [[ "$local_sock" =~ ^\[[^]]+\]:([0-9]+)$ ]]; then local_port="${BASH_REMATCH[1]}"; fi
    if [[ "$local_sock" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]+)$ ]]; then local_port="${BASH_REMATCH[3]}"; fi
    [[ -n "$local_port" ]] || continue
    port_in_csv "$local_port" "$PORTS_CSV" || continue
    client_is_exempt "$ip" && continue
    cnt="${CURRENT_COUNTS[$ip]:-0}"
    CURRENT_COUNTS["$ip"]=$(( cnt + 1 ))
  done < <(ss -Htn state established "$ss_expr" 2>/dev/null || true)

  ct_expr="$(conntrack -L -p udp -o extended 2>/dev/null || true)"
  if [[ -n "$ct_expr" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      ip=""
      lport=""
      for item in $line; do
        [[ -z "$ip" && "$item" == src=* ]] && ip="${item#src=}"
        [[ -z "$lport" && "$item" == dport=* ]] && lport="${item#dport=}"
      done
      [[ -n "$ip" && -n "$lport" ]] || continue
      port_in_csv "$lport" "$PORTS_CSV" || continue
      is_valid_ip "$ip" || continue
      client_is_exempt "$ip" && continue
      cnt="${CURRENT_COUNTS[$ip]:-0}"
      CURRENT_COUNTS["$ip"]=$(( cnt + 1 ))
    done <<< "$ct_expr"
  fi

  if ((${#CURRENT_COUNTS[@]} > 0)); then
    mapfile -t CURRENT_CLIENTS < <(printf '%s\n' "${!CURRENT_COUNTS[@]}" | sort)
  fi
}

load_attached_state(){
  declare -gA ATTACHED_SET=()
  if [[ -f "$STATE_DIR/attached.db" ]]; then
    while read -r ip; do
      [[ -n "$ip" ]] && ATTACHED_SET["$ip"]=1
    done < "$STATE_DIR/attached.db"
  fi
}

save_attached_state(){
  mkdir -p "$STATE_DIR"
  local tmp="$STATE_DIR/attached.db.tmp"
  : > "$tmp"
  local ip
  if ((${#ATTACHED_SET[@]} > 0)); then
    for ip in "${!ATTACHED_SET[@]}"; do
      [[ -n "$ip" ]] || continue
      printf '%s\n' "$ip" >> "$tmp"
    done
  fi
  mv -f "$tmp" "$STATE_DIR/attached.db"
}

load_seen_state(){
  declare -gA LAST_SEEN=()
  if [[ -f "$STATE_DIR/seen.db" ]]; then
    local ip ts
    while read -r ip ts; do
      [[ -n "$ip" && -n "$ts" ]] && LAST_SEEN["$ip"]="$ts"
    done < "$STATE_DIR/seen.db"
  fi
}

save_seen_state(){
  mkdir -p "$STATE_DIR"
  local tmp="$STATE_DIR/seen.db.tmp"
  : > "$tmp"
  local ip
  if ((${#LAST_SEEN[@]} > 0)); then
    for ip in "${!LAST_SEEN[@]}"; do
      [[ -n "$ip" ]] || continue
      printf '%s %s\n' "$ip" "${LAST_SEEN[$ip]}" >> "$tmp"
    done
  fi
  mv -f "$tmp" "$STATE_DIR/seen.db"
}

save_current_clients(){
  mkdir -p "$STATE_DIR"
  local tmp="$STATE_DIR/clients.db.tmp"
  : > "$tmp"
  printf '# updated %s\n' "$(date +%s)" >> "$tmp"
  local ip
  if ((${#CURRENT_CLIENTS[@]} > 0)); then
    for ip in "${CURRENT_CLIENTS[@]}"; do
      [[ -n "$ip" ]] || continue
      printf '%s %s\n' "$ip" "${CURRENT_COUNTS[$ip]:-0}" >> "$tmp"
    done
  fi
  mv -f "$tmp" "$STATE_DIR/clients.db"
}

apply_grace_window(){
  local now="$1" ip
  for ip in "${CURRENT_CLIENTS[@]:-}"; do
    [[ -n "$ip" ]] || continue
    LAST_SEEN["$ip"]="$now"
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

add_client_filters(){
  local ip="$1" family minor port proto handle class_opts=()
  is_valid_ip "$ip" || return 0
  minor="$(hash_minor_hex "$ip")"
  [[ -n "$CLASS_QUANTUM" ]] && class_opts+=(quantum "$CLASS_QUANTUM")
  if [[ "$LIMIT_DOWN" != "0" && "$LIMIT_DOWN" != "off" && "$LIMIT_DOWN" != "none" ]]; then
    tc class replace dev "$EFFECTIVE_IFACE" parent 1:1 classid "1:${minor}" htb rate "$LIMIT_DOWN" ceil "$LIMIT_DOWN" burst "$DOWN_BURST" cburst "$DOWN_BURST" prio 1 "${class_opts[@]}"
    tc qdisc replace dev "$EFFECTIVE_IFACE" parent "1:${minor}" fq_codel
  fi
  if [[ "$LIMIT_UP" != "0" && "$LIMIT_UP" != "off" && "$LIMIT_UP" != "none" ]]; then
    tc class replace dev "$INGRESS_IFB" parent 2:1 classid "2:${minor}" htb rate "$LIMIT_UP" ceil "$LIMIT_UP" burst "$UP_BURST" cburst "$UP_BURST" prio 1 "${class_opts[@]}"
    tc qdisc replace dev "$INGRESS_IFB" parent "2:${minor}" fq_codel
  fi
  if is_ipv4 "$ip"; then family="ip"; else family="ipv6"; fi
  for port in "${PORTS[@]}"; do
    for proto in tcp udp; do
      if [[ "$LIMIT_DOWN" != "0" && "$LIMIT_DOWN" != "off" && "$LIMIT_DOWN" != "none" ]]; then
        handle="$(hash_handle_hex "egress|$family|$proto|$port|$ip")"
        tc filter replace dev "$EFFECTIVE_IFACE" parent 1: protocol "$family" pref 100 handle "$handle" flower ${HW_OPT:+$HW_OPT} \
          dst_ip "$ip" ip_proto "$proto" src_port "$port" classid "1:${minor}" >/dev/null 2>&1 || true
      fi
      if [[ "$LIMIT_UP" != "0" && "$LIMIT_UP" != "off" && "$LIMIT_UP" != "none" ]]; then
        handle="$(hash_handle_hex "ingress|$family|$proto|$port|$ip")"
        tc filter replace dev "$INGRESS_IFB" parent 2: protocol "$family" pref 100 handle "$handle" flower ${HW_OPT:+$HW_OPT} \
          src_ip "$ip" ip_proto "$proto" dst_port "$port" classid "2:${minor}" >/dev/null 2>&1 || true
      fi
    done
  done
}

run_gc(){
  local now="$1" ip removed=0
  if ((${#LAST_SEEN[@]} == 0)); then return 0; fi
  for ip in "${!LAST_SEEN[@]}"; do
    [[ -n "$ip" ]] || continue
    if (( now - LAST_SEEN[$ip] > FLOW_GRACE_SECONDS )); then
      unset 'LAST_SEEN[$ip]'
      if [[ -n "${ATTACHED_SET[$ip]:-}" ]]; then
        remove_client_filters "$ip"
        unset 'ATTACHED_SET[$ip]'
        removed=1
      fi
    fi
  done
  (( removed == 1 )) && save_attached_state
  save_seen_state
}

build_connlimit_tables(){
  cleanup_nft
  (( MAX_CONN_PER_IP > 0 )) || return 0
  local ports_elems blocked4="" blocked6="" ip
  ports_elems="$(printf '%s, ' "${PORTS[@]}" | sed 's/, $//')"
  for ip in "${CURRENT_CLIENTS[@]:-}"; do
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

reconcile_once(){
  local now last_gc attach_count=0 ip
  now="$(date +%s)"
  fresh_collect_current_clients
  apply_grace_window "$now"
  save_current_clients
  build_connlimit_tables

  if ((${#CURRENT_CLIENTS[@]} > 0)); then
    for ip in "${CURRENT_CLIENTS[@]}"; do
      [[ -n "$ip" ]] || continue
      [[ -n "${ATTACHED_SET[$ip]:-}" ]] && continue
      add_client_filters "$ip"
      ATTACHED_SET["$ip"]=1
      attach_count=$(( attach_count + 1 ))
      (( attach_count >= MAX_ATTACH_PER_CYCLE )) && break
    done
    (( attach_count > 0 )) && save_attached_state
  fi

  last_gc=0
  [[ -f "$STATE_DIR/last_gc" ]] && last_gc="$(cat "$STATE_DIR/last_gc" 2>/dev/null || echo 0)"
  if (( now - last_gc >= GC_INTERVAL )); then
    run_gc "$now"
    printf '%s' "$now" > "$STATE_DIR/last_gc"
  fi
}

flush_runtime(){
  rm -f "$STATE_DIR/clients.db" "$STATE_DIR/clients.db.tmp" "$STATE_DIR/attached.db" "$STATE_DIR/attached.db.tmp" \
        "$STATE_DIR/seen.db" "$STATE_DIR/seen.db.tmp" "$STATE_DIR/last_gc"
  cleanup_nft
  cleanup_qdisc
}

stop_runtime(){
  load_config 2>/dev/null || true
  flush_runtime
  success "Runtime cleaned up"
}

configtest(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  header "Configuration test"
  printf '%-24s %s\n' "Interface" "$EFFECTIVE_IFACE"
  printf '%-24s %s\n' "Inbound ports" "$PORTS_CSV"
  printf '%-24s %s\n' "Limit down" "$LIMIT_DOWN"
  printf '%-24s %s\n' "Limit up" "$LIMIT_UP"
  printf '%-24s %s\n' "Strict mode" "$STRICT_MODE"
  printf '%-24s %s\n' "Scan interval" "$SCAN_INTERVAL"
  printf '%-24s %s\n' "GC interval" "$GC_INTERVAL"
  printf '%-24s %s\n' "Attach batch" "$MAX_ATTACH_PER_CYCLE"
}

cmd_config(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  header "Effective configuration"
  printf '%-24s %s\n' "Version" "$VERSION"
  printf '%-24s %s\n' "Interface" "$EFFECTIVE_IFACE"
  printf '%-24s %s\n' "IFB" "$INGRESS_IFB"
  printf '%-24s %s\n' "Managed ports" "$PORTS_CSV"
  printf '%-24s %s\n' "Limit down" "$LIMIT_DOWN"
  printf '%-24s %s\n' "Limit up" "$LIMIT_UP"
  printf '%-24s %s\n' "Strict mode" "$STRICT_MODE"
  printf '%-24s %s\n' "Strict offloads" "$STRICT_DISABLE_OFFLOADS"
  printf '%-24s %s\n' "r2q" "$ROOT_R2Q"
  printf '%-24s %s\n' "quantum" "${CLASS_QUANTUM:-auto}"
  printf '%-24s %s\n' "Scan interval" "$SCAN_INTERVAL"
  printf '%-24s %s\n' "Grace seconds" "$FLOW_GRACE_SECONDS"
  printf '%-24s %s\n' "GC interval" "$GC_INTERVAL"
  printf '%-24s %s\n' "Attach batch" "$MAX_ATTACH_PER_CYCLE"
}

print_clients_from_cache(){
  local shown=0 ip cnt
  [[ -s "$STATE_DIR/clients.db" ]] || return 1
  while read -r ip cnt; do
    [[ -n "$ip" ]] || continue
    [[ "$ip" == \#* ]] && continue
    printf '%-40s %s\n' "$ip" "connections=${cnt:-0}"
    shown=1
  done < "$STATE_DIR/clients.db"
  (( shown == 1 ))
}

cmd_clients(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  load_exempt_set
  header "Discovered clients"
  if [[ "${2:-${1:-}}" == "--fresh" ]]; then
    fresh_collect_current_clients
    if ((${#CURRENT_CLIENTS[@]} == 0)); then echo "<none>"; return 0; fi
    local ip
    for ip in "${CURRENT_CLIENTS[@]}"; do
      printf '%-40s %s\n' "$ip" "connections=${CURRENT_COUNTS[$ip]:-0}"
    done
    return 0
  fi
  if ! print_clients_from_cache; then
    fresh_collect_current_clients
    if ((${#CURRENT_CLIENTS[@]} == 0)); then echo "<none>"; return 0; fi
    local ip
    for ip in "${CURRENT_CLIENTS[@]}"; do
      printf '%-40s %s\n' "$ip" "connections=${CURRENT_COUNTS[$ip]:-0}"
    done
  fi
}

cmd_hits(){
  need_root
  load_config
  resolve_rates
  header "Egress filters on ${EFFECTIVE_IFACE}"
  tc -s filter show dev "$EFFECTIVE_IFACE" parent 1: 2>/dev/null || true
  echo
  header "Ingress filters on ${INGRESS_IFB}"
  tc -s filter show dev "$INGRESS_IFB" parent 2: 2>/dev/null || true
  echo
  header "Egress classes on ${EFFECTIVE_IFACE}"
  tc -s class show dev "$EFFECTIVE_IFACE" 2>/dev/null || true
  echo
  header "Ingress classes on ${INGRESS_IFB}"
  tc -s class show dev "$INGRESS_IFB" 2>/dev/null || true
}


get_class_sent_bytes() {
  local dev="$1" classid="$2"
  awk -v want="$classid" '
    $1=="class" && $2=="htb" && $3==want { found=1; next }
    found && $1=="Sent" { print $2; exit }
  ' < <(tc -s class show dev "$dev" 2>/dev/null)
}

get_class_overlimits() {
  local dev="$1" classid="$2"
  awk -v want="$classid" '
    $1=="class" && $2=="htb" && $3==want { found=1; next }
    found && /overlimits/ {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^overlimits$/) {
          gsub(/[^0-9]/, "", $(i+1))
          print $(i+1)
          exit
        }
      }
      match($0, /overlimits ([0-9]+)/, m)
      if (m[1] != "") { print m[1]; exit }
    }
  ' < <(tc -s class show dev "$dev" 2>/dev/null)
}

get_filter_sent_bytes() {
  local dev="$1" parent="$2"
  awk '
    /^[[:space:]]*Sent[[:space:]]+[0-9]+[[:space:]]+bytes[[:space:]]+[0-9]+[[:space:]]+pkt/ { bytes += $2 }
    END { print bytes+0 }
  ' < <(tc -s filter show dev "$dev" parent "$parent" 2>/dev/null)
}

cmd_debug(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  header "Debug shaping summary"

  local clients_count attached_count default_e default_i shaped_e shaped_i filter_e filter_i
  clients_count=0
  attached_count=0
  [[ -f "$STATE_DIR/clients.db" ]] && clients_count="$(grep -vc '^#' "$STATE_DIR/clients.db" 2>/dev/null || echo 0)"
  [[ -f "$STATE_DIR/attached.db" ]] && attached_count="$(wc -l < "$STATE_DIR/attached.db" 2>/dev/null || echo 0)"

  default_e="$(get_class_sent_bytes "$EFFECTIVE_IFACE" "1:999")"
  default_i="$(get_class_sent_bytes "$INGRESS_IFB" "2:999")"
  shaped_e="$(awk '$1=="class" && $2=="htb" && $3!="1:999" && $3 ~ /^1:[0-9a-f]+$/ && $5=="1:1" {found=1; next} found && $1=="Sent" {sum+=$2; found=0} END{print sum+0}' < <(tc -s class show dev "$EFFECTIVE_IFACE" 2>/dev/null))"
  shaped_i="$(awk '$1=="class" && $2=="htb" && $3!="2:999" && $3 ~ /^2:[0-9a-f]+$/ && $5=="2:1" {found=1; next} found && $1=="Sent" {sum+=$2; found=0} END{print sum+0}' < <(tc -s class show dev "$INGRESS_IFB" 2>/dev/null))"
  filter_e="$(get_filter_sent_bytes "$EFFECTIVE_IFACE" "1:")"
  filter_i="$(get_filter_sent_bytes "$INGRESS_IFB" "2:")"

  printf '%-28s %s
' "Cached clients" "$clients_count"
  printf '%-28s %s
' "Attached classes" "$attached_count"
  printf '%-28s %s
' "Default egress bytes" "${default_e:-0}"
  printf '%-28s %s
' "Shaped egress bytes" "${shaped_e:-0}"
  printf '%-28s %s
' "Filter egress bytes" "${filter_e:-0}"
  printf '%-28s %s
' "Default ingress bytes" "${default_i:-0}"
  printf '%-28s %s
' "Shaped ingress bytes" "${shaped_i:-0}"
  printf '%-28s %s
' "Filter ingress bytes" "${filter_i:-0}"

  if [[ "${shaped_e:-0}" =~ ^[0-9]+$ && "${default_e:-0}" =~ ^[0-9]+$ && "${shaped_e:-0}" -gt 0 ]]; then
    awk -v d="${default_e:-0}" -v s="${shaped_e:-0}" -v r="$DEBUG_BYPASS_WARN_RATIO" 'BEGIN{ if (d > s*r) print "[!] bypass warning: default egress class is carrying significant traffic"; else print "[+] egress shaping looks engaged"; }'
  fi
  if [[ "${shaped_i:-0}" =~ ^[0-9]+$ && "${default_i:-0}" =~ ^[0-9]+$ && "${shaped_i:-0}" -gt 0 ]]; then
    awk -v d="${default_i:-0}" -v s="${shaped_i:-0}" -v r="$DEBUG_BYPASS_WARN_RATIO" 'BEGIN{ if (d > s*r) print "[!] bypass warning: default ingress class is carrying significant traffic"; else print "[+] ingress shaping looks engaged"; }'
  fi
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
  if detect_xray_config >/dev/null 2>&1; then success "xray config found"; else warn "xray config not found"; fi
  systemctl is-enabled nftables >/dev/null 2>&1 && success "nftables service enabled" || warn "nftables service not enabled"
  modprobe -n ifb >/dev/null 2>&1 && success "kernel module available: ifb" || warn "kernel module unavailable: ifb"
  modprobe -n cls_flower >/dev/null 2>&1 && success "kernel module available: cls_flower" || warn "kernel module unavailable: cls_flower"
  modprobe -n act_mirred >/dev/null 2>&1 && success "kernel module available: act_mirred" || warn "kernel module unavailable: act_mirred"
}

show_status(){
  header "Service status"
  systemctl --no-pager --full status "$APP_NAME" || true
}

run_daemon(){
  need_root
  exec 9> "$LOCK_FILE"
  if ! flock -n 9; then
    error "another daemon instance is already running"
    exit 1
  fi
  ensure_dirs
  load_config
  resolve_rates
  ensure_port_array
  load_exempt_set
  load_attached_state
  load_seen_state
  strict_mode_apply
  cleanup_nft
  cleanup_qdisc
  setup_qdisc
  banner
  info "Interface: $EFFECTIVE_IFACE"
  info "Inbound ports: $PORTS_CSV"
  info "Limits: down=$LIMIT_DOWN up=$LIMIT_UP"
  info "Scan interval: ${SCAN_INTERVAL}s"
  trap 'exit 0' INT TERM
  fresh_collect_current_clients
  apply_grace_window "$(date +%s)"
  save_current_clients
  reconcile_once
  while true; do
    reconcile_once
    sleep "$SCAN_INTERVAL"
  done
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
  read -r -p "Scan interval seconds [${SCAN_INTERVAL}]: " v; SCAN_INTERVAL="${v:-$SCAN_INTERVAL}"
  read -r -p "Grace seconds [${FLOW_GRACE_SECONDS}]: " v; FLOW_GRACE_SECONDS="${v:-$FLOW_GRACE_SECONDS}"
  read -r -p "GC interval seconds [${GC_INTERVAL}]: " v; GC_INTERVAL="${v:-$GC_INTERVAL}"
  read -r -p "Max attach per cycle [${MAX_ATTACH_PER_CYCLE}]: " v; MAX_ATTACH_PER_CYCLE="${v:-$MAX_ATTACH_PER_CYCLE}"
  read -r -p "Skip hardware offload yes/no [${SKIP_HW}]: " v; SKIP_HW="${v:-$SKIP_HW}"
  read -r -p "Strict mode yes/no [${STRICT_MODE}]: " v; STRICT_MODE="${v:-$STRICT_MODE}"
  read -r -p "Disable NIC offloads in strict mode yes/no [${STRICT_DISABLE_OFFLOADS}]: " v; STRICT_DISABLE_OFFLOADS="${v:-$STRICT_DISABLE_OFFLOADS}"
  read -r -p "Strict r2q [${STRICT_R2Q}]: " v; STRICT_R2Q="${v:-$STRICT_R2Q}"
  read -r -p "Strict quantum [${STRICT_QUANTUM}]: " v; STRICT_QUANTUM="${v:-$STRICT_QUANTUM}"
  read -r -p "Log level info/debug [${LOG_LEVEL}]: " v; LOG_LEVEL="${v:-$LOG_LEVEL}"
  cat > "$CONF_FILE" <<CFG
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
STRICT_MODE="${STRICT_MODE}"
STRICT_DISABLE_OFFLOADS="${STRICT_DISABLE_OFFLOADS}"
STRICT_R2Q="${STRICT_R2Q}"
STRICT_QUANTUM="${STRICT_QUANTUM}"
DEBUG_BYPASS_WARN_RATIO="${DEBUG_BYPASS_WARN_RATIO}"
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
  success "Updated installed script and service"
}

uninstall_all(){
  need_root
  systemctl disable --now "$APP_NAME" 2>/dev/null || true
  flush_runtime
  rm -f "$SERVICE_FILE" "$INSTALL_PATH"
  rm -rf "$APP_DIR"
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
  clients) shift || true; cmd_clients "$@" ;;
  hits) cmd_hits ;;
  debug) cmd_debug ;;
  doctor) cmd_doctor ;;
  wizard) cmd_wizard ;;
  logs) cmd_logs ;;
  flush) flush_runtime ;;
  run-daemon) run_daemon ;;
  stop-runtime) stop_runtime ;;
  *)
    banner
    cat <<USAGE
Usage: $0 {install|update|uninstall|enable|disable|start|stop|restart|status|configtest|config|clients [--fresh]|hits|debug|doctor|wizard|logs|flush|run-daemon|stop-runtime}
USAGE
    exit 1
    ;;
esac
