# synology-nas-scripts

![DSM 7.x](https://img.shields.io/badge/DSM-7.x-blue)
![DS218+](https://img.shields.io/badge/Tested%20on-DS218%2B-informational)
![Celeron J3355](https://img.shields.io/badge/CPU-Celeron%20J3355-lightgrey)
![Kernel 4.4](https://img.shields.io/badge/Kernel-4.4-lightgrey)
![License MIT](https://img.shields.io/badge/License-MIT-green)

Maintenance, security hardening and optimization scripts for Synology NAS running DSM 7.x.
Tested on DS218+ but compatible with most Synology models on DSM 7.

All scripts are written around the constraints of a low-power entry-level NAS: kernel 4.4.x, no `ipset`, no `nftables`, no BBR.

---

## Hardware tested

| | |
|---|---|
| **Model** | Synology DS218+ |
| **CPU** | Intel Celeron J3355 (2 cores) |
| **RAM** | 6 GB |
| **Kernel** | 4.4.302+ (Synology custom — no ipset, no nftables, no BBR) |
| **DSM** | 7.2 stable |
| **Storage** | 2 × HDD (JBOD) |

---

## Scripts

### setup/

One-time setup and boot-time scripts. `optimize-kernel.sh` is registered as an rc.d service and calls the others on every boot.

| File | What it does | How to install / run |
|------|-------------|----------------------|
| `setup/optimize-kernel.sh` | sysctl tuning (VM, network buffers, TCP) + kernel security hardening (kptr_restrict, dmesg_restrict, BPF, RP filter, RFC1337, CVE-2016-5696). Sets I/O scheduler to `deadline` and read-ahead to 1 MB on both drives. APM level 254 (no head parking). Calls `nginx-security-headers.sh` and `configure-synocrond.sh` at the end. | Symlink to `/usr/local/etc/rc.d/` — runs on every boot |
| `setup/nginx-security-headers.sh` | Generates two nginx config files: `http.rate-limit.conf` (rate-limit zone scoped only to `/webapi/auth.cgi` via `map` — empty key elsewhere so Photos/Drive are unaffected) and `dsm.hardening.conf` (security headers, HSTS, `limit_req`). Validates with `nginx -t` before reload. | Called automatically by `optimize-kernel.sh`. Manual: `sudo bash setup/nginx-security-headers.sh` |
| `setup/configure-synocrond.sh` | Reduces synocrond task frequency (daily→weekly/monthly) and Redis timeout (3600s→900s) to allow HDD hibernation. Idempotent — safe to re-run after DSM updates, which revert these settings to defaults. | Auto via `optimize-kernel.sh` on every boot. Manual: `sudo bash setup/configure-synocrond.sh` |
| `setup/crowdsec-bouncer.py` | CrowdSec iptables bouncer for NAS without ipset/nftables — see [dedicated section](#crowdsec-bouncer) | |
| `setup/install-crowdsec-bouncer.sh` | Automated installer for `crowdsec-bouncer.py` — see [dedicated section](#crowdsec-bouncer) | |

### scheduled/

Scripts meant to run on a schedule via DSM Task Scheduler.

| File | What it does | How to run |
|------|-------------|------------|
| `scheduled/nas-weekly-maintenance.sh` | 19-section weekly maintenance runner: kernel, services, nginx, Tailscale, btrfs/ext4 scrub, tmp/log cleanup, Docker, ClamAV update, IP blocklists, SMART, disk usage, HyperBackup check, AntiVirus, TLS cert expiry, Trivy scan, HDD hibernation check. Log file with rotation at 512 KB. | Task Scheduler DSM — user: root — Sundays 02:00 |
| `scheduled/autoclean.sh` | Daily lightweight cleanup: removes tmp files, rotates logs, prunes Docker artifacts older than 7 days, clears SMB cache and PageCache, compacts Synology databases. | Task Scheduler DSM — root — daily 07:00 |
| `scheduled/drive-sync-throttle.sh` | Throttles Synology Drive native client sync to a 30-second window every 30 minutes, then pauses indexing for 1830 seconds. Prevents continuous disk writes caused by Drive uploading frequently-changing files (e.g., editor session data). | cron every 30 min: `*/30 * * * * bash /path/to/drive-sync-throttle.sh` |
| `scheduled/update-clamav.sh` | Runs `freshclam` with fallback mirror to `database.clamav.net`. Restarts the Synology AntiVirus package after a successful signature update. | Task Scheduler DSM — root — daily |
| `scheduled/throttle-photos-ai.sh` | Stops Synology Photos AI workers (concept detection, face extraction, person clustering) to reduce I/O and RAM pressure. DSM restarts them on demand when Photos is accessed. | On demand, or after DSM spontaneously restarts AI workers |
| `scheduled/trivy-scan-weekly.sh` | Scans all running Docker images with `docker run --rm aquasec/trivy image`. Saves JSON reports to `/volume1/docker/trivy/reports/` (read by trivy-ui on `:9954`). | Task Scheduler DSM — root — weekly |

### external/

Scripts downloaded from third-party repositories and kept here for convenience. They are not modified.

| File | Source | Version |
|------|--------|---------|
| `external/smart_info/syno_smart_info.sh` | [007revad/Synology_SMART_info](https://github.com/007revad/Synology_SMART_info) | v1.4.38 |
| `external/smart_info/updateLocalScript.sh` | [007revad/Synology_SMART_info](https://github.com/007revad/Synology_SMART_info) | bundled |
| `external/coredumps/syno_clean_coredumps.sh` | [007revad/Synology_Cleanup_Coredumps](https://github.com/007revad/Synology_Cleanup_Coredumps) | v1.2.4 |

---

## CrowdSec Bouncer

### Why a custom bouncer?

The DS218+ runs kernel 4.4.x, which has no `ipset` and no `nftables`. The official CrowdSec bouncer packages (`crowdsec-firewall-bouncer`) require one or both, so they fail silently or crash on this hardware.

The previous bash bouncer consumed ~55% CPU during bulk IP processing. `crowdsec-bouncer.py` replaces it with an efficient Python daemon using only stdlib.

### How it works

- Connects to the CrowdSec LAPI via `/v1/decisions/stream` (incremental updates, 30 s poll)
- Applies adds/deletes in a single `iptables-restore` batch per cycle
- Uses `/usr/bin/xtables-legacy-multi iptables-restore --noflush` directly — the Synology `/sbin/iptables-restore` wrapper calls `usleep` which is unavailable on this system
- Maintains a dedicated `CROWDSEC` chain, prepended to both `INPUT` and `FORWARD`
- API key is never in the code — read from `/etc/crowdsec/cs-py-bouncer.conf` (chmod 600)
- IPv6 decisions are silently skipped (no ip6tables wiring on this setup)

Files:

| Path | Purpose |
|------|---------|
| `/usr/local/bin/crowdsec-bouncer.py` | Daemon |
| `/etc/crowdsec/cs-py-bouncer.conf` | Config (api_key, lapi_url, poll_interval) |
| `/var/log/crowdsec-bouncer.log` | Log |
| `/var/run/crowdsec-bouncer.pid` | PID |
| `/usr/local/etc/rc.d/crowdsec-bouncer.sh` | rc.d service (autostart on boot) |

### Installation — automated

Edit `SCRIPT_SRC` and `COMPOSE_DIR` at the top of `setup/install-crowdsec-bouncer.sh` if your paths differ, then:

```bash
sudo bash setup/install-crowdsec-bouncer.sh
```

The installer: stops the old bouncer, installs the Python daemon, waits for the CrowdSec Docker LAPI, generates a fresh API key via `cscli`, writes the config, and enables the rc.d service.

### Installation — manual

```bash
# 1. Generate API key
docker exec crowdsec cscli bouncers add cs-py-bouncer -o raw

# 2. Write config
echo "api_key = <KEY_FROM_ABOVE>
lapi_url = http://localhost:8080
poll_interval = 30" | sudo tee /etc/crowdsec/cs-py-bouncer.conf
sudo chmod 600 /etc/crowdsec/cs-py-bouncer.conf

# 3. Install daemon
sudo cp setup/crowdsec-bouncer.py /usr/local/bin/
sudo chmod 755 /usr/local/bin/crowdsec-bouncer.py

# 4. Start and verify
sudo /usr/local/etc/rc.d/crowdsec-bouncer.sh start
iptables -L CROWDSEC -n | wc -l   # number of banned IPs
tail -f /var/log/crowdsec-bouncer.log
```

---

## IP Blocklists

`scheduled/nas-weekly-maintenance.sh` section 11 expects a script at `scheduled/auto-block-ip.sh`.
That script is not included here — it is a site-specific wrapper around
[**AutoBlockIPList**](https://github.com/kichetof/AutoBlockIPList) by @kichetof.
If the script is absent the maintenance runner logs a warning and continues.

To wire it up: clone AutoBlockIPList, write your own `scheduled/auto-block-ip.sh` wrapper,
and schedule it separately via Task Scheduler.

---

## Docker cleanup

No separate script needed. Quick one-liner:

```bash
docker system prune -f && docker network prune -f && docker image prune -f
```

---

## Installation paths

```
/volume1/scripts/SYNOLOGY/          ← clone this repo here
/volume1/scripts/SYNOLOGY/setup/    ← boot-time scripts
/volume1/scripts/SYNOLOGY/scheduled/  ← scheduled task scripts
/volume1/scripts/SYNOLOGY/external/   ← third-party scripts
```

### setup/optimize-kernel.sh — persist across reboots

DSM resets most sysctl values on reboot. Register as rc.d to apply automatically:

```bash
sudo ln -sf /volume1/scripts/SYNOLOGY/setup/optimize-kernel.sh \
            /usr/local/etc/rc.d/optimize-kernel.sh

# Apply immediately without rebooting
sudo bash /volume1/scripts/SYNOLOGY/setup/optimize-kernel.sh
```

### scheduled/nas-weekly-maintenance.sh — Task Scheduler

**Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script**

| Field | Value |
|-------|-------|
| Task name | NAS Weekly Maintenance |
| User | `root` |
| Schedule | Weekly — Sunday 02:00 |
| Run command | `bash /volume1/scripts/SYNOLOGY/scheduled/nas-weekly-maintenance.sh` |

Add the other `scheduled/` scripts the same way with their recommended frequencies.

---

## Sudoers

All scripts require root. Options:

- Run via Task Scheduler with user `root` (recommended — no sudoers changes needed)
- SSH as admin and `sudo bash script.sh`
- For automated SSH triggers, add a NOPASSWD entry in `/etc/sudoers.d/`:
  ```
  your_user ALL=(root) NOPASSWD: /volume1/scripts/SYNOLOGY/scheduled/nas-weekly-maintenance.sh
  ```

---

## Notes

- Paths use `/volume1/` — adjust if your scripts live on a different volume
- All scripts are idempotent and safe to re-run
- Tested on DSM 7.2; should work on any DSM 7.x release
- `nas-weekly-maintenance.sh` uses `DSM_HTTPS_PORT=5001` — change this variable if you use a non-default port

---

## Compatibility

| Feature | Status on kernel 4.4 |
|---------|----------------------|
| `ipset` | Not available |
| `nftables` | Not available |
| BBR congestion control | Not available (`tcp_cubic` used) |
| `iptables` / `iptables-restore` | Available |
| `xtables-legacy-multi` | Available at `/usr/bin/xtables-legacy-multi` |
| `ip6tables` | Available (not used in these scripts) |

---

## External sources

Some scripts are original work; others are downloaded from public repositories or inspired by them:

| Script | Repository | Type |
|--------|-----------|------|
| `external/smart_info/syno_smart_info.sh` | [007revad/Synology_SMART_info](https://github.com/007revad/Synology_SMART_info) | downloaded (v1.4.38) |
| `external/coredumps/syno_clean_coredumps.sh` | [007revad/Synology_Cleanup_Coredumps](https://github.com/007revad/Synology_Cleanup_Coredumps) | downloaded (v1.2.4) |
| `setup/configure-synocrond.sh` | [AlexFromChaos/synology_hibernation_fixer](https://github.com/AlexFromChaos/synology_hibernation_fixer) · fork [007revad](https://github.com/007revad/synology_hibernation_fixer) | original, inspired by |

All other scripts (`scheduled/nas-weekly-maintenance.sh`, `setup/optimize-kernel.sh`, `setup/nginx-security-headers.sh`, `scheduled/update-clamav.sh`, `setup/crowdsec-bouncer.py`, `scheduled/drive-sync-throttle.sh` and the rest of `scheduled/`) are original work.

---

## License

MIT — see [LICENSE](LICENSE).
