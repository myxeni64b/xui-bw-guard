# 3xui-bw-guard

Per-client bandwidth limiter and connection guard for **3x-ui / Xray inbound users** on Linux.

`3xui-bw-guard` is a Bash-based traffic shaping manager that detects clients connected to your 3x-ui inbound ports and applies **per-IP speed limits** and optional **max connections per IP**, without intentionally throttling unrelated outbound traffic.

It is designed for admins who want to prevent a few users from abusing the full server bandwidth while keeping sessions alive and stable.

## Highlights

- Per-client IP speed limiting
- Separate **download** and **upload** limits
- Optional **max connections per IP**
- Supports **excluded inbound ports**
- Supports **exempt IPs**
- Supports **smart burst calculation**
- Uses `tc` + `HTB` + `IFB`
- Uses `conntrack` to detect active inbound client IPs
- Uses `nftables` for optional connection limiting
- Runs as a clean `systemd` service
- Includes an interactive **wizard** and **doctor** command
- Supports multiple Linux distributions
- Terminal-friendly output and simple management commands

---

## What this project does

- Detects remote client IPs currently connected to your configured 3x-ui/Xray inbound ports
- Applies per-IP traffic shaping for those client flows
- Optionally limits excessive new connections from the same client IP if `MAX_CONN_PER_IP` is enabled
- Keeps existing sessions alive and shapes traffic instead of hard-disconnecting users

## What it does not try to do

- It does **not** intentionally throttle all server traffic
- It does **not** intentionally shape unrelated outbound services on your machine
- It does **not** replace a full anti-DDoS stack or upstream mitigation
- It does **not** solve fairness for many users behind the same NAT IP

---

## How it works

Linux traffic shaping is egress-first, so the script uses both the main network interface and an IFB interface:

- **Download to client** is shaped on your main network interface egress
- **Upload from client** is redirected from ingress to an **IFB** interface and shaped there
- Active client IPs are discovered through **conntrack**
- Optional per-IP connection caps are enforced with **nftables**

This lets you limit traffic for inbound users without dropping their current sessions.

---

## Requirements

- Linux server with root access
- `systemd`
- 3x-ui / Xray running on the server
- Kernel support for:
  - `ifb`
  - `sch_htb`
  - `cls_flower`
  - `act_mirred`
- Required packages:
  - `iproute2`
  - `nftables`
  - `conntrack-tools` or `conntrack`
  - `jq`
  - `ethtool`
  - `kmod`

---

## Supported environments

Designed for Linux systems where 3x-ui can run, including:

- Ubuntu
- Debian
- AlmaLinux / Rocky / CentOS
- Fedora
- Arch Linux
- openSUSE

Primary target in this release: **Ubuntu 24**.

---

## Repository layout

```text
3xui-bw-guard/
├── 3xui-bw-guard.sh
├── README.md
├── CHANGELOG.md
├── LICENSE
├── .gitignore
├── GITHUB_NOTES.md
└── examples/
    └── 3xui-bw-guard.conf
```

---

## Installation

### 1) Clone the repository

```bash
git clone <your-repo-url>
cd 3xui-bw-guard
chmod +x 3xui-bw-guard.sh
```

### 2) Install

```bash
sudo ./3xui-bw-guard.sh install
```

This will:

- install required dependencies
- copy the script to `/usr/local/sbin/3xui-bw-guard`
- create the config file at `/etc/3xui-bw-guard/3xui-bw-guard.conf`
- create the systemd service at `/etc/systemd/system/3xui-bw-guard.service`
- optionally start the setup wizard

---

## Fastest setup path

After install, run the wizard:

```bash
sudo /usr/local/sbin/3xui-bw-guard wizard
```

Then:

```bash
sudo /usr/local/sbin/3xui-bw-guard configtest
sudo systemctl enable --now 3xui-bw-guard
sudo /usr/local/sbin/3xui-bw-guard status
```

---

## Quick start example

A solid initial config for a medium node:

```bash
IFACE="auto"
INGRESS_IFB="ifb3xui0"
XRAY_CONFIG_PATH="/usr/local/x-ui/bin/config.json"
MANAGED_PORTS=""
EXCLUDE_PORTS=""
EXEMPT_IPS="127.0.0.1,::1,198.51.100.10"
LIMIT_DOWN="5mbit"
LIMIT_UP="1mbit"
UPLINK_RATE="100mbit"
INGRESS_RATE="100mbit"
MAX_CONN_PER_IP="8"
SMART_BURST="yes"
BURST_INTERVAL_MS="120"
SCAN_INTERVAL="5"
FLOW_GRACE_SECONDS="30"
LOG_LEVEL="info"
```

---

## Commands

After installation, the main management commands are:

```bash
/usr/local/sbin/3xui-bw-guard install
/usr/local/sbin/3xui-bw-guard uninstall
/usr/local/sbin/3xui-bw-guard wizard
/usr/local/sbin/3xui-bw-guard doctor
/usr/local/sbin/3xui-bw-guard config
/usr/local/sbin/3xui-bw-guard configtest
/usr/local/sbin/3xui-bw-guard enable
/usr/local/sbin/3xui-bw-guard disable
/usr/local/sbin/3xui-bw-guard start
/usr/local/sbin/3xui-bw-guard stop
/usr/local/sbin/3xui-bw-guard restart
/usr/local/sbin/3xui-bw-guard status
/usr/local/sbin/3xui-bw-guard apply
/usr/local/sbin/3xui-bw-guard version
```

---

## Interactive wizard

The wizard helps you generate the config file cleanly:

```bash
sudo /usr/local/sbin/3xui-bw-guard wizard
```

It asks for:

- interface name or `auto`
- IFB interface name
- Xray config path
- managed inbound ports or auto-detection
- excluded ports
- exempt IPs
- per-client download limit
- per-client upload limit
- real uplink / ingress capacity
- per-IP connection cap
- smart burst toggle
- burst interval
- scan interval
- flow grace window
- log level

At the end it can run `configtest` and enable/start the service for you.

---

## Doctor mode

Use this before going live:

```bash
sudo /usr/local/sbin/3xui-bw-guard doctor
```

It checks:

- required commands
- config presence
- likely kernel module availability
- current configured paths

---

## Configuration reference

### `IFACE`
Network interface to shape.

Examples:

```bash
IFACE="eth0"
IFACE="ens3"
IFACE="auto"
```

If set to `auto`, the script tries to detect the default WAN interface.

### `INGRESS_IFB`
Name of the IFB interface used to shape client upload traffic.

Example:

```bash
INGRESS_IFB="ifb3xui0"
```

### `XRAY_CONFIG_PATH`
Path to Xray / 3x-ui `config.json`.

Example:

```bash
XRAY_CONFIG_PATH="/usr/local/x-ui/bin/config.json"
```

If `MANAGED_PORTS` is empty, the script tries to detect inbound ports from this file.

### `MANAGED_PORTS`
Comma-separated list of inbound ports to manage manually.

Example:

```bash
MANAGED_PORTS="443,8443,2053"
```

### `EXCLUDE_PORTS`
Ports that should be ignored even if they are detected.

Example:

```bash
EXCLUDE_PORTS="22,80"
```

### `EXEMPT_IPS`
Comma-separated list of IPs that should never be shaped or connection-limited.

Example:

```bash
EXEMPT_IPS="127.0.0.1,::1,203.0.113.10"
```

Use this for your own admin IP, monitoring systems, trusted relays, or localhost.

### `LIMIT_DOWN`
Maximum client download speed.

Examples:

```bash
LIMIT_DOWN="512kbit"
LIMIT_DOWN="2mbit"
LIMIT_DOWN="25mbit"
```

### `LIMIT_UP`
Maximum client upload speed.

Examples:

```bash
LIMIT_UP="256kbit"
LIMIT_UP="1mbit"
LIMIT_UP="10mbit"
```

### `UPLINK_RATE`
Total available egress bandwidth for the root shaping class.

Examples:

```bash
UPLINK_RATE="100mbit"
UPLINK_RATE="1gbit"
UPLINK_RATE="auto"
```

For best accuracy, set this close to your real usable WAN bandwidth.

### `INGRESS_RATE`
Total available ingress shaping bandwidth for the IFB root class.

Examples:

```bash
INGRESS_RATE="100mbit"
INGRESS_RATE="auto"
```

### `MAX_CONN_PER_IP`
Optional maximum simultaneous new connections per client IP.

Examples:

```bash
MAX_CONN_PER_IP="0"
MAX_CONN_PER_IP="4"
MAX_CONN_PER_IP="8"
```

- `0` disables connection limiting
- any value above `0` enables nftables connection limiting

### `SMART_BURST`
Enable automatic burst calculation based on rate and interval.

```bash
SMART_BURST="yes"
```

Recommended value: `yes`

### `BURST_INTERVAL_MS`
Burst window in milliseconds.

```bash
BURST_INTERVAL_MS="120"
```

Higher values allow more short-term burst tolerance. Lower values make shaping stricter.

### `SCAN_INTERVAL`
How often the script scans active tracked connections.

```bash
SCAN_INTERVAL="5"
```

Units are seconds.

### `FLOW_GRACE_SECONDS`
How long to wait before removing a client class after traffic disappears.

```bash
FLOW_GRACE_SECONDS="30"
```

### `LOG_LEVEL`
Logging verbosity.

```bash
LOG_LEVEL="info"
LOG_LEVEL="debug"
```

---

## Recommended production tuning

### Small VPS

```bash
LIMIT_DOWN="2mbit"
LIMIT_UP="512kbit"
MAX_CONN_PER_IP="4"
SCAN_INTERVAL="5"
FLOW_GRACE_SECONDS="20"
SMART_BURST="yes"
BURST_INTERVAL_MS="100"
```

### Medium node

```bash
LIMIT_DOWN="5mbit"
LIMIT_UP="1mbit"
MAX_CONN_PER_IP="8"
SCAN_INTERVAL="5"
FLOW_GRACE_SECONDS="30"
SMART_BURST="yes"
BURST_INTERVAL_MS="120"
```

### Larger node

```bash
LIMIT_DOWN="10mbit"
LIMIT_UP="2mbit"
MAX_CONN_PER_IP="10"
SCAN_INTERVAL="3"
FLOW_GRACE_SECONDS="20"
SMART_BURST="yes"
BURST_INTERVAL_MS="150"
```

---

## Logs and live checks

Follow service logs:

```bash
journalctl -u 3xui-bw-guard -f
```

Check current config:

```bash
sudo /usr/local/sbin/3xui-bw-guard config
```

Check service and tc status:

```bash
sudo /usr/local/sbin/3xui-bw-guard status
```

---

## Troubleshooting

### Service starts but no clients are shaped

Check the interface:

```bash
ip route
```

Check resolved ports:

```bash
sudo /usr/local/sbin/3xui-bw-guard configtest
```

Check whether conntrack sees the flows:

```bash
sudo conntrack -L
```

Check the Xray config path:

```bash
ls -l /usr/local/x-ui/bin/config.json
```

### Shaping feels inaccurate

Possible causes:

- `UPLINK_RATE` or `INGRESS_RATE` is too high or too low
- NIC offloading behavior
- virtualization overhead
- burst values are too permissive
- ISP bandwidth is inconsistent

A stricter start point is:

```bash
SMART_BURST="yes"
BURST_INTERVAL_MS="80"
```

Also set real line capacity, not only the NIC port speed.

### nftables connection limiting seems inactive

Check:

```bash
sudo nft list ruleset
```

Make sure `MAX_CONN_PER_IP` is above `0`.

### IFB module missing

Try:

```bash
sudo modprobe ifb
```

### flower classifier error

Load likely-required modules:

```bash
sudo modprobe cls_flower
sudo modprobe act_mirred
sudo modprobe sch_htb
```

---

## Uninstall

```bash
sudo /usr/local/sbin/3xui-bw-guard uninstall
```

This removes:

- the systemd service
- nftables tables created by the script
- IFB and shaping runtime state
- installed binary and config files

---

## Safety notes

- Test on a non-critical server first
- Use real bandwidth values for best results
- Exempt your own management IP if remote SSH access matters
- Keep SSH and management ports outside managed inbound ports unless you intentionally want them shaped
- This project shapes traffic, but it is not a complete anti-DDoS system

---

## Limitations

- Per-IP control means many users behind the same NAT may share one limit
- Connection tracking quality depends on kernel visibility and routing style
- Very unusual NAT or policy-routing setups may require tuning
- Some customized Xray deployments may need explicit `MANAGED_PORTS` instead of auto-detection

---

## Roadmap ideas

- direct port discovery from the 3x-ui SQLite database
- hot reload when inbounds change
- optional per-port speed profiles
- JSON status output for monitoring
- safer detection for more exotic routing layouts

---

## License

MIT

See `LICENSE`.
