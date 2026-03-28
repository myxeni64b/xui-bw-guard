#!/usr/bin/env bash
set -euo pipefail

APP_NAME="3xui-bw-guard"
VERSION="v7"
APP_DIR="/etc/${APP_NAME}"
CONF_FILE="${APP_DIR}/${APP_NAME}.conf"
STATE_DIR="/run/${APP_NAME}"
INSTALL_PATH="/usr/local/sbin/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
NFT_TABLE4="${APP_NAME//-/_}_4"
NFT_TABLE6="${APP_NAME//-/_}_6"
LOCK_DIR="${STATE_DIR}/daemon.lock"

COLOR=1
[[ -t 1 ]] || COLOR=0
c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_blue='\033[34m'; c_mag='\033[35m'; c_cyan='\033[36m'; c_bold='\033[1m'

paint(){ local color="$1"; shift; if [[ "$COLOR" -eq 1 ]]; then printf "%b%s%b\n" "$color" "$*" "$c_reset"; else printf "%s\n" "$*"; fi; }
header(){ paint "$c_bold$c_blue" "== $* =="; }
info(){ paint "$c_cyan" "[i] $*"; }
success(){ paint "$c_green" "[+] $*"; }
warn(){ paint "$c_yellow" "[!] $*"; }
error(){ paint "$c_red" "[x] $*" >&2; }

die(){ error "$*"; exit 1; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
trim(){ local s="$*"; s="${s#${s%%[![:space:]]*}}"; s="${s%${s##*[![:space:]]}}"; printf '%s' "$s"; }
ensure_dirs(){ mkdir -p "$APP_DIR" "$STATE_DIR"; }

banner(){
  if [[ "$COLOR" -eq 1 ]]; then
    printf "%b\n" "$c_bold$c_mag"
    cat <<'BANNER'
   ____      _       _       _                                _
  |___ \_  _(_)_   _| |_____| |__ __      __       __ _ _   _| |
    __) \ \/ / | | | | |_  / | '_ \\ \ /\ / /_____ / _` | | | | |
   / __/ >  <| | |_| | |/ /| | |_) |\ V  V /_____| (_| | |_| | |
  |_____/_/\_\_|\__,_|_/___|_|_.__/  \_/\_/       \__, |\__,_|_|
                                                   |___/
BANNER
    printf "%b\n" "$c_reset"
  else
    printf '%s %s\n' "$APP_NAME" "$VERSION"
  fi
}

join_csv(){ local IFS=,; printf '%s' "$*"; }
normalize_csv(){
  local input="$1" item out=()
  IFS=',' read -r -a arr <<< "$input"
  for item in "${arr[@]:-}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && out+=("$item")
  done
  local IFS=,
  printf '%s' "${out[*]:-}"
}
csv_to_array(){
  local input="$1" cleaned item
  CSV_ITEMS=()
  cleaned="$(normalize_csv "$input")"
  [[ -z "$cleaned" ]] && return 0
  IFS=',' read -r -a raw <<< "$cleaned"
  for item in "${raw[@]:-}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && CSV_ITEMS+=("$item")
  done
}

is_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6(){ [[ "$1" == *:* ]]; }
is_valid_ipv4(){
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=. o
  for o in $1; do
    (( o >= 0 && o <= 255 )) || return 1
  done
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
  die "Unsupported rate format: $1"
}
compute_burst(){
  local rate="$1" interval_ms="$2"
  if [[ "${SMART_BURST,,}" != "yes" ]]; then
    echo "65536b"
    return 0
  fi
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

hash_minor_hex(){ local s="$1" sum; sum="$(printf '%s' "$s" | cksum | awk '{print $1}')"; printf '%x' $(( (sum % 0xff00) + 0x0100 )); }
hash_handle_hex(){ local s="$1" sum; sum="$(printf '%s' "$s" | cksum | awk '{print $1}')"; printf '0x%x' $(( (sum % 0x7fffffff) + 1 )); }

write_default_config(){
  [[ -f "$CONF_FILE" ]] && return 0
  cat > "$CONF_FILE" <<'CFG'
# 3xui-bw-guard configuration
# Bash syntax only. Comments must start with #

IFACE="auto"
INGRESS_IFB="ifb3xui0"
XRAY_CONFIG_PATH="/usr/local/x-ui/bin/config.json"
MANAGED_PORTS="443"
EXCLUDE_PORTS=""
EXEMPT_IPS=""
LIMIT_DOWN="4mbit"
LIMIT_UP="4mbit"
UPLINK_RATE="100mbit"
INGRESS_RATE="100mbit"
MAX_CONN_PER_IP="0"
SMART_BURST="no"
BURST_INTERVAL_MS="120"
SCAN_INTERVAL="1"
FLOW_GRACE_SECONDS="15"
SKIP_HW="yes"
LOG_LEVEL="info"
CFG
  success "Wrote default config: $CONF_FILE"
}

write_service(){
  cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=3x-ui inbound per-IP bandwidth guard
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=${INSTALL_PATH} run-daemon
Restart=on-failure
RestartSec=5

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
    apt-get install -y iproute2 nftables conntrack jq ethtool kmod iptables util-linux
  elif cmd_exists dnf; then
    dnf install -y iproute nftables conntrack-tools jq ethtool kmod iptables util-linux
  elif cmd_exists yum; then
    yum install -y iproute nftables conntrack-tools jq ethtool kmod iptables util-linux
  elif cmd_exists pacman; then
    pacman -Sy --noconfirm iproute2 nftables conntrack-tools jq ethtool kmod iptables util-linux
  elif cmd_exists zypper; then
    zypper --non-interactive install iproute2 nftables conntrack-tools jq ethtool kmod iptables util-linux
  else
    warn "Unsupported package manager. Install manually: iproute2 nftables conntrack-tools jq ethtool kmod iptables util-linux"
  fi
}

load_config(){
  [[ -f "$CONF_FILE" ]] || die "Config not found: $CONF_FILE"
  bash -n "$CONF_FILE" >/dev/null 2>&1 || die "Config syntax error in $CONF_FILE"
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  IFACE="${IFACE:-auto}"
  INGRESS_IFB="${INGRESS_IFB:-ifb3xui0}"
  XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH:-/usr/local/x-ui/bin/config.json}"
  MANAGED_PORTS="$(normalize_csv "${MANAGED_PORTS:-}")"
  EXCLUDE_PORTS="$(normalize_csv "${EXCLUDE_PORTS:-}")"
  EXEMPT_IPS="$(normalize_csv "${EXEMPT_IPS:-}")"
  LIMIT_DOWN="${LIMIT_DOWN:-4mbit}"
  LIMIT_UP="${LIMIT_UP:-4mbit}"
  UPLINK_RATE="${UPLINK_RATE:-100mbit}"
  INGRESS_RATE="${INGRESS_RATE:-100mbit}"
  MAX_CONN_PER_IP="${MAX_CONN_PER_IP:-0}"
  SMART_BURST="${SMART_BURST:-no}"
  BURST_INTERVAL_MS="${BURST_INTERVAL_MS:-120}"
  SCAN_INTERVAL="${SCAN_INTERVAL:-1}"
  FLOW_GRACE_SECONDS="${FLOW_GRACE_SECONDS:-15}"
  SKIP_HW="${SKIP_HW:-yes}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
}

log_debug(){ [[ "${LOG_LEVEL,,}" == "debug" ]] && info "$*" || true; }

detect_iface(){
  if [[ "$IFACE" != "auto" && -n "$IFACE" ]]; then printf '%s' "$IFACE"; return 0; fi
  local d
  d="$(ip -o route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  [[ -z "$d" ]] && d="$(ip -o route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
  [[ -n "$d" ]] || die "Could not auto-detect interface. Set IFACE manually."
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

port_in_csv(){ local port="$1" csv="$2" item; csv_to_array "$csv"; for item in "${CSV_ITEMS[@]:-}"; do [[ "$item" == "$port" ]] && return 0; done; return 1; }

detect_ports(){
  local ports_raw="$MANAGED_PORTS" cfg p
  local final=()
  if [[ -z "$ports_raw" ]]; then
    if cfg="$(detect_xray_config)"; then
      ports_raw="$(jq -r '.inbounds[]? | .port? // empty' "$cfg" 2>/dev/null | awk 'NF' | sort -n | paste -sd, -)"
    fi
  fi
  [[ -n "$ports_raw" ]] || die "No managed ports found. Set MANAGED_PORTS explicitly."
  csv_to_array "$ports_raw"
  for p in "${CSV_ITEMS[@]:-}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    (( p >= 1 && p <= 65535 )) || continue
    if [[ -n "$EXCLUDE_PORTS" ]] && port_in_csv "$p" "$EXCLUDE_PORTS"; then continue; fi
    final+=("$p")
  done
  ((${#final[@]} > 0)) || die "Managed port list empty after exclusions."
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
  HW_OPT=()
  [[ "${SKIP_HW,,}" == "yes" ]] && HW_OPT=(skip_hw)
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

cleanup_qdisc(){
  local iface ifb
  iface="${EFFECTIVE_IFACE:-$(detect_iface 2>/dev/null || true)}"
  ifb="${INGRESS_IFB:-ifb3xui0}"
  [[ -n "$iface" ]] && tc qdisc del dev "$iface" ingress 2>/dev/null || true
  [[ -n "$iface" ]] && tc qdisc del dev "$iface" root 2>/dev/null || true
  if ip link show "$ifb" >/dev/null 2>&1; then
    tc qdisc del dev "$ifb" root 2>/dev/null || true
    ip link set dev "$ifb" down 2>/dev/null || true
    ip link delete "$ifb" type ifb 2>/dev/null || true
  fi
}

setup_qdisc(){
  setup_modules
  local iface="$EFFECTIVE_IFACE" ifb="$INGRESS_IFB"
  ip link show "$ifb" >/dev/null 2>&1 || ip link add "$ifb" type ifb
  ip link set dev "$ifb" up

  tc qdisc del dev "$iface" root 2>/dev/null || true
  tc qdisc add dev "$iface" root handle 1: htb default 999
  tc class replace dev "$iface" parent 1: classid 1:1 htb rate "$EFFECTIVE_UPLINK_RATE" ceil "$EFFECTIVE_UPLINK_RATE" burst "$ROOT_E_BURST" cburst "$ROOT_E_BURST"
  tc class replace dev "$iface" parent 1:1 classid 1:999 htb rate "$EFFECTIVE_UPLINK_RATE" ceil "$EFFECTIVE_UPLINK_RATE" burst "$ROOT_E_BURST" cburst "$ROOT_E_BURST" prio 7
  tc qdisc replace dev "$iface" parent 1:999 fq_codel

  tc qdisc del dev "$iface" ingress 2>/dev/null || true
  tc qdisc add dev "$iface" handle ffff: ingress
  tc filter replace dev "$iface" parent ffff: protocol all matchall action mirred egress redirect dev "$ifb"

  tc qdisc del dev "$ifb" root 2>/dev/null || true
  tc qdisc add dev "$ifb" root handle 2: htb default 999
  tc class replace dev "$ifb" parent 2: classid 2:1 htb rate "$EFFECTIVE_INGRESS_RATE" ceil "$EFFECTIVE_INGRESS_RATE" burst "$ROOT_I_BURST" cburst "$ROOT_I_BURST"
  tc class replace dev "$ifb" parent 2:1 classid 2:999 htb rate "$EFFECTIVE_INGRESS_RATE" ceil "$EFFECTIVE_INGRESS_RATE" burst "$ROOT_I_BURST" cburst "$ROOT_I_BURST" prio 7
  tc qdisc replace dev "$ifb" parent 2:999 fq_codel
}

cleanup_nft(){
  nft delete table ip "$NFT_TABLE4" 2>/dev/null || true
  nft delete table ip6 "$NFT_TABLE6" 2>/dev/null || true
}

normalize_peer_socket(){
  local raw="$1" host
  raw="$(trim "$raw")"
  [[ -z "$raw" ]] && return 1
  if [[ "$raw" =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  host="${host%%%*}"
  if [[ "$host" =~ ^::ffff:([0-9]{1,3}(\.[0-9]{1,3}){3})$ ]]; then
    host="${BASH_REMATCH[1]}"
  fi
  [[ "$host" == "127.0.0.1" || "$host" == "::1" || "$host" == "0.0.0.0" || "$host" == "::" ]] && return 1
  is_valid_ip "$host" || return 1
  printf '%s\n' "$host"
}

client_is_exempt(){ local ip="$1" item; csv_to_array "$EXEMPT_IPS"; for item in "${CSV_ITEMS[@]:-}"; do [[ "$ip" == "$item" ]] && return 0; done; return 1; }

collect_current_clients(){
  declare -gA CURRENT_COUNTS=()
  declare -ga CURRENT_CLIENTS=()
  local port line peer ip

  for port in "${PORTS[@]}"; do
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      peer="$(awk '{print $NF}' <<< "$line")"
      ip="$(normalize_peer_socket "$peer" 2>/dev/null || true)"
      [[ -n "$ip" ]] || continue
      client_is_exempt "$ip" && continue
      CURRENT_COUNTS["$ip"]=$(( ${CURRENT_COUNTS["$ip"]:-0} + 1 ))
    done < <(ss -Htn state established "( sport = :${port} )" 2>/dev/null || true)
  done

  if cmd_exists conntrack; then
    local p ct_out
    ct_out="$(conntrack -L -p udp -o extended 2>/dev/null || true)"
    if [[ -n "$ct_out" ]]; then
      for p in "${PORTS[@]}"; do
        while IFS= read -r ip; do
          [[ -n "$ip" ]] || continue
          client_is_exempt "$ip" && continue
          CURRENT_COUNTS["$ip"]=$(( ${CURRENT_COUNTS["$ip"]:-0} + 1 ))
        done < <(
          awk -v want="$p" '
            {
              s=""; d="";
              for(i=1;i<=NF;i++) {
                if ($i ~ /^src=/ && s == "") s=substr($i,5)
                if ($i ~ /^dport=/ && d == "") d=substr($i,7)
              }
              if (s != "" && d == want) print s
            }
          ' <<< "$ct_out"
        )
      done
    fi
  fi

  if ((${#CURRENT_COUNTS[@]} > 0)); then
    mapfile -t CURRENT_CLIENTS < <(printf '%s\n' "${!CURRENT_COUNTS[@]}" | awk 'NF' | sort)
  fi
}

build_connlimit_tables(){
  cleanup_nft
  (( MAX_CONN_PER_IP > 0 )) || return 0
  local ports_elems blocked4="" blocked6="" ip
  ports_elems="$(printf '%s, ' "${PORTS[@]}" | sed 's/, $//')"
  for ip in "${CURRENT_CLIENTS[@]:-}"; do
    (( ${CURRENT_COUNTS[$ip]:-0} > MAX_CONN_PER_IP )) || continue
    if is_ipv4 "$ip"; then blocked4+="$ip, "; else blocked6+="$ip, "; fi
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

attach_client(){
  local ip="$1" family minor port proto handle
  is_valid_ip "$ip" || return 0
  minor="$(hash_minor_hex "$ip")"
  if is_ipv4 "$ip"; then family="ip"; else family="ipv6"; fi

  if [[ "$LIMIT_DOWN" != "0" && "$LIMIT_DOWN" != "off" && "$LIMIT_DOWN" != "none" ]]; then
    tc class replace dev "$EFFECTIVE_IFACE" parent 1:1 classid "1:${minor}" htb rate "$LIMIT_DOWN" ceil "$LIMIT_DOWN" burst "$DOWN_BURST" cburst "$DOWN_BURST" prio 1
    tc qdisc replace dev "$EFFECTIVE_IFACE" parent "1:${minor}" fq_codel
  fi
  if [[ "$LIMIT_UP" != "0" && "$LIMIT_UP" != "off" && "$LIMIT_UP" != "none" ]]; then
    tc class replace dev "$INGRESS_IFB" parent 2:1 classid "2:${minor}" htb rate "$LIMIT_UP" ceil "$LIMIT_UP" burst "$UP_BURST" cburst "$UP_BURST" prio 1
    tc qdisc replace dev "$INGRESS_IFB" parent "2:${minor}" fq_codel
  fi

  for port in "${PORTS[@]}"; do
    for proto in tcp udp; do
      if [[ "$LIMIT_DOWN" != "0" && "$LIMIT_DOWN" != "off" && "$LIMIT_DOWN" != "none" ]]; then
        handle="$(hash_handle_hex "egress|$family|$proto|$port|$ip")"
        tc filter replace dev "$EFFECTIVE_IFACE" parent 1: protocol "$family" pref 100 handle "$handle" flower "${HW_OPT[@]}" \
          dst_ip "$ip" ip_proto "$proto" src_port "$port" classid "1:${minor}"
      fi
      if [[ "$LIMIT_UP" != "0" && "$LIMIT_UP" != "off" && "$LIMIT_UP" != "none" ]]; then
        handle="$(hash_handle_hex "ingress|$family|$proto|$port|$ip")"
        tc filter replace dev "$INGRESS_IFB" parent 2: protocol "$family" pref 100 handle "$handle" flower "${HW_OPT[@]}" \
          src_ip "$ip" ip_proto "$proto" dst_port "$port" classid "2:${minor}"
      fi
    done
  done
  APPLIED["$ip"]=1
  LAST_SEEN["$ip"]="$(date +%s)"
}

detach_client(){
  local ip="$1" family minor port proto handle
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
  unset 'APPLIED[$ip]'
  unset 'LAST_SEEN[$ip]'
}

reconcile_once(){
  local now ip
  now="$(date +%s)"
  collect_current_clients
  build_connlimit_tables

  if ((${#CURRENT_CLIENTS[@]} > 0)); then
    for ip in "${CURRENT_CLIENTS[@]}"; do
      [[ -n "$ip" ]] || continue
      LAST_SEEN["$ip"]="$now"
      if [[ -z "${APPLIED[$ip]:-}" ]]; then
        log_debug "attach $ip"
        attach_client "$ip"
      fi
    done
  fi

  if ((${#APPLIED[@]} > 0)); then
    for ip in "${!APPLIED[@]}"; do
      [[ -n "$ip" ]] || continue
      if [[ -z "${CURRENT_COUNTS[$ip]:-}" ]]; then
        if (( now - ${LAST_SEEN[$ip]:-0} >= FLOW_GRACE_SECONDS )); then
          log_debug "detach $ip"
          detach_client "$ip"
        fi
      fi
    done
  fi
}

acquire_lock(){
  ensure_dirs
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  if [[ -f "$LOCK_DIR/pid" ]]; then
    local oldpid
    oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      die "Another ${APP_NAME} daemon is already running (PID $oldpid)."
    fi
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}
release_lock(){ rm -rf "$LOCK_DIR" 2>/dev/null || true; }

flush_runtime(){ cleanup_nft; cleanup_qdisc; release_lock; }

run_daemon(){
  need_root
  ensure_dirs
  load_config
  resolve_rates
  ensure_port_array
  acquire_lock
  declare -gA APPLIED=()
  declare -gA LAST_SEEN=()
  cleanup_nft
  cleanup_qdisc
  setup_qdisc

  trap 'flush_runtime; exit 0' INT TERM

  banner
  info "Interface: $EFFECTIVE_IFACE"
  info "Inbound ports: $PORTS_CSV"
  info "Limits: down=$LIMIT_DOWN up=$LIMIT_UP"
  info "Scan interval: ${SCAN_INTERVAL}s"

  reconcile_once
  while true; do
    reconcile_once
    sleep "$SCAN_INTERVAL"
  done
}

stop_runtime(){ need_root; load_config || true; resolve_rates || true; flush_runtime; success "Runtime flushed"; }

configtest(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  header "Configuration test"
  printf '%-22s %s\n' "Version" "$VERSION"
  printf '%-22s %s\n' "Interface" "$EFFECTIVE_IFACE"
  printf '%-22s %s\n' "Inbound ports" "$PORTS_CSV"
  printf '%-22s %s\n' "Limit down" "$LIMIT_DOWN"
  printf '%-22s %s\n' "Limit up" "$LIMIT_UP"
  printf '%-22s %s\n' "Uplink rate" "$EFFECTIVE_UPLINK_RATE"
  printf '%-22s %s\n' "Ingress rate" "$EFFECTIVE_INGRESS_RATE"
  printf '%-22s %s\n' "Down burst" "$DOWN_BURST"
  printf '%-22s %s\n' "Up burst" "$UP_BURST"
  printf '%-22s %s\n' "Max conn / IP" "$MAX_CONN_PER_IP"
  printf '%-22s %s\n' "Exempt IPs" "${EXEMPT_IPS:-<none>}"
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
  printf '%-22s %s\n' "Burst interval" "$BURST_INTERVAL_MS"
  printf '%-22s %s\n' "Scan interval" "$SCAN_INTERVAL"
  printf '%-22s %s\n' "Grace seconds" "$FLOW_GRACE_SECONDS"
  printf '%-22s %s\n' "Skip HW" "$SKIP_HW"
  printf '%-22s %s\n' "Log level" "$LOG_LEVEL"
}
cmd_clients(){
  need_root
  load_config
  resolve_rates
  ensure_port_array
  collect_current_clients
  header "Discovered clients"
  if ((${#CURRENT_CLIENTS[@]} == 0)); then echo "<none>"; return 0; fi
  local ip
  for ip in "${CURRENT_CLIENTS[@]}"; do
    printf '%-40s %s\n' "$ip" "connections=${CURRENT_COUNTS[$ip]:-0}"
  done
}
cmd_hits(){
  need_root
  load_config || true
  resolve_rates || true
  header "Egress filters on ${EFFECTIVE_IFACE:-eth0}"
  tc -s filter show dev "${EFFECTIVE_IFACE:-eth0}" parent 1: 2>/dev/null || true
  echo
  header "Ingress filters on ${INGRESS_IFB:-ifb3xui0}"
  tc -s filter show dev "${INGRESS_IFB:-ifb3xui0}" parent 2: 2>/dev/null || true
  echo
  header "Egress classes on ${EFFECTIVE_IFACE:-eth0}"
  tc -s class show dev "${EFFECTIVE_IFACE:-eth0}" 2>/dev/null || true
  echo
  header "Ingress classes on ${INGRESS_IFB:-ifb3xui0}"
  tc -s class show dev "${INGRESS_IFB:-ifb3xui0}" 2>/dev/null || true
}
cmd_doctor(){
  need_root
  load_config || true
  header "Doctor"
  local c
  for c in tc ss nft conntrack jq awk sed grep ip bash; do
    if cmd_exists "$c"; then success "found: $c"; else warn "missing: $c"; fi
  done
  local iface
  iface="$(detect_iface 2>/dev/null || true)"
  [[ -n "$iface" && -d "/sys/class/net/$iface" ]] && success "interface exists: $iface" || warn "interface not found"
  detect_xray_config >/dev/null 2>&1 && success "xray config found" || warn "xray config not found"
  systemctl is-enabled nftables >/dev/null 2>&1 && success "nftables service enabled" || warn "nftables service not enabled"
  for mod in ifb cls_flower act_mirred sch_htb; do
    modprobe -n "$mod" >/dev/null 2>&1 && success "kernel module available: $mod" || warn "kernel module unavailable: $mod"
  done
}
show_status(){ header "Service status"; systemctl --no-pager --full status "$APP_NAME" || true; }
show_logs(){ journalctl -u "$APP_NAME" -n 120 --no-pager; }

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
SKIP_HW="${SKIP_HW}"
LOG_LEVEL="${LOG_LEVEL}"
CFG
  success "Saved configuration to $CONF_FILE"
  configtest
}

install_all(){ need_root; banner; install_deps; ensure_dirs; copy_self; write_default_config; write_service; success "Install complete"; }
update_all(){ need_root; banner; copy_self; write_service; success "Updated installed script and service"; }
uninstall_all(){ need_root; systemctl disable --now "$APP_NAME" 2>/dev/null || true; flush_runtime || true; rm -f "$SERVICE_FILE" "$INSTALL_PATH"; rm -rf "$APP_DIR" "$STATE_DIR"; systemctl daemon-reload; success "Uninstalled $APP_NAME"; }

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
  logs) show_logs ;;
  configtest) configtest ;;
  config) cmd_config ;;
  clients) cmd_clients ;;
  hits) cmd_hits ;;
  doctor) cmd_doctor ;;
  wizard) cmd_wizard ;;
  run-daemon) run_daemon ;;
  stop-runtime|flush) stop_runtime ;;
  *)
    banner
    cat <<USAGE
Usage: $0 {install|update|uninstall|enable|disable|start|stop|restart|status|logs|configtest|config|clients|hits|doctor|wizard|run-daemon|stop-runtime|flush}
USAGE
    exit 1
    ;;
esac
