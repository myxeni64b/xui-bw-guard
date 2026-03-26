# Changelog

## 2.0.0 - 2026-03-26

- added a cleaner terminal banner
- added interactive `wizard` command for guided setup
- added `doctor` command for environment checks
- added `config` command to print the current config file
- improved install flow so wizard can run immediately after installation
- expanded README with setup, commands, tuning, and troubleshooting
- added `CHANGELOG.md` for GitHub readiness

## 1.0.0 - 2026-03-26

- initial public package
- per-IP inbound client bandwidth shaping with `tc`, `HTB`, `IFB`
- active client discovery via `conntrack`
- optional per-IP connection limiting via `nftables`
- systemd service management
