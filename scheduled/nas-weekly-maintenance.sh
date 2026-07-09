#!/bin/bash
# =============================================================================
# nas-weekly-maintenance.sh — Weekly maintenance for DS218+
# Requires root | Task Scheduler: Sundays 02:00
# =============================================================================

START_TS=$(date +%s)
SCRIPT_DIR="/volume1/scripts/SYNOLOGY"
LOG_FILE="$SCRIPT_DIR/logs/weekly-maintenance.log"
WARN=0
ERR=0
STEPS_OK=0

# Data volumes to inspect — auto-detected
# To force a subset: VOLUMES="/volume1 /volume3"
VOLUMES=$(df 2>/dev/null | awk '$NF ~ /^\/volume[0-9]+$/ {print $NF}' | sort -u | tr '\n' ' ')
[ -z "$VOLUMES" ] && VOLUMES="/volume1"

# DSM HTTPS port — adjust if you changed the default
DSM_HTTPS_PORT=5001

# Rotate log if over 512 KB (keep 3 previous)
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 524288 ]; then
    [ -f "${LOG_FILE}.3" ] && rm -f "${LOG_FILE}.3"
    [ -f "${LOG_FILE}.2" ] && mv "${LOG_FILE}.2" "${LOG_FILE}.3"
    [ -f "${LOG_FILE}.1" ] && mv "${LOG_FILE}.1" "${LOG_FILE}.2"
    mv "$LOG_FILE" "${LOG_FILE}.1"
fi

# Redirect all stdout+stderr to log and terminal
exec > >(tee -a "$LOG_FILE") 2>&1

ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log()     { echo "[$(ts)] $1"; }
ok()      { log "✓  $1"; STEPS_OK=$((STEPS_OK + 1)); }
warn()    { log "⚠  WARNING: $1"; WARN=$((WARN + 1)); }
error()   { log "✗  ERROR: $1"; ERR=$((ERR + 1)); }
section() { log ""; log "━━━  $1  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

log "============================================================="
log "  NAS WEEKLY MAINTENANCE — DS218+"
log "  Start: $(ts)"
log "============================================================="

# =============================================================================
# 1. KERNEL — PERFORMANCE AND SECURITY
# =============================================================================
section "1/19  Kernel — performance and security"

if bash "$SCRIPT_DIR/setup/optimize-kernel.sh" >/dev/null 2>&1; then
    ok "optimize-kernel.sh applied"
else
    error "optimize-kernel.sh exited with errors"
fi

# Verify critical sysctl values after apply
KERN_FAIL=0
for _check in "kernel.kptr_restrict:1" \
              "kernel.dmesg_restrict:1" \
              "kernel.unprivileged_bpf_disabled:1" \
              "fs.protected_hardlinks:1" \
              "net.ipv4.conf.default.accept_source_route:0" \
              "net.ipv4.tcp_rfc1337:1" \
              "net.ipv4.tcp_challenge_ack_limit:2147483647" \
              "net.ipv4.tcp_keepalive_time:600"; do
    _key="${_check%%:*}" _exp="${_check#*:}"
    _cur=$(sysctl -n "$_key" 2>/dev/null)
    if [ -z "$_cur" ]; then
        log "  Not available: $_key"
    elif [ "$_cur" != "$_exp" ]; then
        error "Wrong value: $_key = $_cur (expected: $_exp)"
        KERN_FAIL=$((KERN_FAIL + 1))
    else
        log "  OK: $_key = $_cur"
    fi
done
[ "$KERN_FAIL" -eq 0 ] && ok "Security parameters verified"

# I/O scheduler and readahead (not sysctl — check /sys)
for disk in sda sdb; do
    [ -b "/dev/$disk" ] || continue
    SCHED=$(cat "/sys/block/$disk/queue/scheduler" 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
    RA=$(cat "/sys/block/$disk/queue/read_ahead_kb" 2>/dev/null)
    if [ "$SCHED" = "deadline" ] && [ "$RA" = "1024" ]; then
        log "  OK: $disk — scheduler=deadline readahead=1024KB"
    else
        warn "$disk — scheduler=${SCHED:-?} readahead=${RA:-?}KB (expected: deadline/1024KB)"
    fi
done

if ls /usr/local/etc/rc.d/optimize-kernel* >/dev/null 2>&1; then
    ok "rc.d registered — persistent across reboots"
else
    warn "optimize-kernel.sh NOT in rc.d — will not survive reboot"
fi

# =============================================================================
# 2. SERVICE CHECK
# =============================================================================
section "2/19  Critical services"

# fileindexd — should be stopped (causes continuous Btrfs writes when running)
if pgrep -x fileindexd >/dev/null 2>&1; then
    warn "fileindexd is running — causes continuous Btrfs writes"
else
    ok "fileindexd stopped"
fi

# QuickConnect — should be installed but stopped and not auto-starting
if [ ! -f "/var/packages/QuickConnect/enabled" ]; then
    ok "QuickConnect autostart disabled"
else
    warn "QuickConnect autostart active — disable in DSM > Control Panel > QuickConnect"
fi

if synopkg is-running QuickConnect 2>/dev/null | grep -qi "true"; then
    warn "QuickConnect is running — run: synopkg stop QuickConnect"
else
    ok "QuickConnect stopped"
fi

# Vaultwarden
DOCKER_BIN="/usr/local/bin/docker"
if [ -x "$DOCKER_BIN" ]; then
    if "$DOCKER_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qi vaultwarden; then
        ok "Vaultwarden running"
    else
        error "Vaultwarden NOT running"
    fi
fi

# =============================================================================
# 3. NGINX
# =============================================================================
section "3/19  nginx"

if pgrep -f "/usr/bin/nginx" >/dev/null 2>&1; then
    ok "nginx process active"
else
    error "nginx NOT running"
fi

NGINX_TEST=$(nginx -t 2>&1)
if echo "$NGINX_TEST" | grep -q "test is successful"; then
    ok "nginx config valid"
else
    error "nginx config invalid — $(echo "$NGINX_TEST" | grep -i 'emerg\|error' | head -1)"
fi

# Verify DSM responds on HTTPS port
if command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://localhost:${DSM_HTTPS_PORT}/" 2>/dev/null)
    if [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 500 ] 2>/dev/null; then
        ok "DSM responding on :${DSM_HTTPS_PORT} (HTTP $HTTP_CODE)"
    else
        warn "DSM not responding on :${DSM_HTTPS_PORT} (code: ${HTTP_CODE:-no response})"
    fi
fi

# =============================================================================
# 4. TAILSCALE
# =============================================================================
section "4/19  Tailscale"

TS_BIN=""
for _p in /var/packages/Tailscale/target/bin/tailscale /usr/local/bin/tailscale; do
    [ -x "$_p" ] && TS_BIN="$_p" && break
done
[ -z "$TS_BIN" ] && command -v tailscale >/dev/null 2>&1 && TS_BIN="tailscale"

if [ -z "$TS_BIN" ]; then
    log "  Tailscale not installed — skipping"
else
    TS_STATUS=$("$TS_BIN" status 2>/dev/null)
    if echo "$TS_STATUS" | grep -qi "stopped\|not running\|NeedsLogin\|NoState"; then
        error "Tailscale stopped or disconnected"
    else
        TS_IP=$("$TS_BIN" ip 2>/dev/null | head -1)
        ok "Tailscale active — IP: ${TS_IP:-unknown}"
    fi
fi

# =============================================================================
# 5. BTRFS NOCOW ATTRIBUTES
# =============================================================================
section "5/19  Btrfs nocow"

check_nocow() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        log "  Does not exist: $dir"
        return
    fi
    local flags
    flags=$(lsattr -d "$dir" 2>/dev/null | awk '{print $1}')
    if echo "$flags" | grep -q "C"; then
        ok "nocow active: $dir"
    else
        warn "nocow NOT active on: $dir (apply: chattr +C $dir)"
    fi
}

check_nocow "/volume1/docker"
check_nocow "/volume1/@appdata/PostgreSQL"
check_nocow "/volume1/@synologydrive/log"
check_nocow "/volume1/@appdata/SynoFinder/fileindexdb"

# =============================================================================
# 6. FILESYSTEM INTEGRITY
# =============================================================================
section "6/19  Filesystem integrity"

for vol in $VOLUMES; do
    [ -d "$vol" ] || continue
    FSTYPE=$(df -T "$vol" 2>/dev/null | awk 'NR==2 {print $2}')
    DEV=$(df "$vol" 2>/dev/null | awk 'NR==2 {print $1}')

    if [ "$FSTYPE" = "btrfs" ]; then
        STATUS=$(btrfs scrub status "$vol" 2>/dev/null)
        SCRUB_RC=$?
        if [ $SCRUB_RC -ne 0 ] || [ -z "$STATUS" ] || echo "$STATUS" | grep -qi "no scrubs\|not found"; then
            warn "$vol [btrfs] — no scrub history (configure in DSM > Storage Manager > Scrubbing Schedule)"
            continue
        fi
        ERRORS=$(echo "$STATUS" | grep -oE '[0-9]+ error' | awk '{s+=$1} END{print s+0}')
        DATE=$(echo "$STATUS" | grep -i "started" | tail -1 \
            | sed 's/.*started at //' | sed 's/ and.*//')
        DURATION=$(echo "$STATUS" | grep -iE "finished after" | tail -1 \
            | grep -oE '[0-9]+:[0-9]+:[0-9]+' | tail -1)
        log "  $vol [btrfs] | Last scrub: ${DATE:-unknown} | Duration: ${DURATION:-?}"
        if [ "${ERRORS:-0}" -gt 0 ]; then
            error "$vol — scrub reported ${ERRORS} error(s) — possible bad sectors"
        else
            ok "$vol — btrfs scrub OK (0 errors)"
        fi

    elif [ "$FSTYPE" = "ext4" ] || [ "$FSTYPE" = "ext3" ]; then
        if [ -x "$(command -v tune2fs)" ] && [ -n "$DEV" ]; then
            TUNE=$(tune2fs -l "$DEV" 2>/dev/null)
            LAST_CHECK=$(echo "$TUNE" | awk -F': ' '/Last checked:/ {print $2}' | xargs)
            ERRORS=$(echo "$TUNE"  | awk -F': ' '/Filesystem errors behaviour:/ {print $2}' | xargs)
            MOUNTS=$(echo "$TUNE"  | awk -F': ' '/Mount count:/ {print $2}' | xargs)
            MAX_MOUNTS=$(echo "$TUNE" | awk -F': ' '/Maximum mount count:/ {print $2}' | xargs)
            log "  $vol [ext4] | Last fsck: ${LAST_CHECK:-unknown} | Mounts: ${MOUNTS:-?}/${MAX_MOUNTS:-?}"
            ok "$vol — ext4 OK (fsck auto on unmount)"
        else
            log "  $vol [ext4] — tune2fs not available"
        fi
    else
        log "  $vol — filesystem $FSTYPE not handled by this section"
    fi
done

# =============================================================================
# 7. TEMP FILES AND CACHE CLEANUP
# =============================================================================
section "7/19  Temp cleanup"

find /tmp /var/tmp -xdev -type f -mtime +10 -delete 2>/dev/null
ok "Temp files > 10 days removed"

EADIR_COUNT=0
for vol in $VOLUMES; do
    EADIR_COUNT=$((EADIR_COUNT + $(find "$vol" -maxdepth 3 -xdev -type d -name "@eaDir" -empty 2>/dev/null | wc -l)))
    find "$vol" -maxdepth 3 -xdev -type d -name "@eaDir" -empty -exec rmdir {} \; 2>/dev/null
done
ok "Empty @eaDir removed: $EADIR_COUNT"

COREDUMPS_SCRIPT="$SCRIPT_DIR/external/coredumps/syno_clean_coredumps.sh"
if [ -x "$COREDUMPS_SCRIPT" ]; then
    COREDUMP_OUT=$(bash "$COREDUMPS_SCRIPT" --age 7 2>/dev/null)
    # Output format: "Deleted X files (total Y.YY MB)"
    COREDUMP_DELETED=$(echo "$COREDUMP_OUT" | grep -oE 'Deleted [0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
    COREDUMP_SIZE=$(echo "$COREDUMP_OUT" | grep -oE 'total [0-9.]+ MB' | grep -oE '[0-9.]+ MB' | tail -1)
    if [ "${COREDUMP_DELETED:-0}" -gt 0 ] 2>/dev/null; then
        ok "Core dumps > 7d: ${COREDUMP_DELETED} file(s) removed${COREDUMP_SIZE:+ (${COREDUMP_SIZE})}"
    else
        ok "Core dumps > 7d: none found"
    fi
else
    for vol in $VOLUMES; do
        find "$vol" -name "*.core.gz" -mtime +7 -delete 2>/dev/null
    done
    ok "Core dumps > 7 days removed"
fi

command -v net >/dev/null 2>&1 && net cache flush >/dev/null 2>&1 && ok "SMB cache flushed"

# =============================================================================
# 8. SYSTEM LOG CLEANUP
# =============================================================================
section "8/19  System log cleanup"

GZ_COUNT=$(find /var/log -type f -name "*.log.gz" -mtime +45 2>/dev/null | wc -l)
find /var/log -type f -name "*.log.gz" -mtime +45 -delete 2>/dev/null
log "  Compressed logs > 45d: $GZ_COUNT removed"

SYN_COUNT=$(find /var/log/synolog -type f -mtime +90 2>/dev/null | wc -l)
find /var/log/synolog -type f -mtime +90 -delete 2>/dev/null
log "  Synolog > 90d: $SYN_COUNT removed"

rm -f /var/log/synopkg.log.[1-9] 2>/dev/null

# Synology Drive — rotate old logs (keep only _0 _1 _2)
DRIVE_LOG="/volume1/@synologydrive/log"
if [ -d "$DRIVE_LOG" ]; then
    SIZE_BEFORE=$(du -sh "$DRIVE_LOG" 2>/dev/null | cut -f1)
    for prefix in client syncfolder cloud-workerd backup; do
        find "$DRIVE_LOG" -name "${prefix}.log_[3-9]" -delete 2>/dev/null
        find "$DRIVE_LOG" -name "${prefix}.log_[0-9][0-9]" -delete 2>/dev/null
    done
    SIZE_AFTER=$(du -sh "$DRIVE_LOG" 2>/dev/null | cut -f1)
    ok "Drive logs rotated: ${SIZE_BEFORE} → ${SIZE_AFTER}"
fi

[ "$GZ_COUNT" -eq 0 ] && [ "$SYN_COUNT" -eq 0 ] && ok "System logs clean"

# =============================================================================
# 9. DOCKER
# =============================================================================
section "9/19  Docker"

if [ -x "$DOCKER_BIN" ]; then
    "$DOCKER_BIN" container prune -f --filter "until=168h" >/dev/null 2>&1
    "$DOCKER_BIN" network prune -f >/dev/null 2>&1
    "$DOCKER_BIN" image prune -f >/dev/null 2>&1
    "$DOCKER_BIN" builder prune -f --filter "until=168h" >/dev/null 2>&1

    RUNNING=$("$DOCKER_BIN" ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
    ok "Docker pruned | Running: ${RUNNING:-none}"

    DOCKER_DISK=$("$DOCKER_BIN" system df 2>/dev/null | tail -1 | awk '{print $4}')
    [ -n "$DOCKER_DISK" ] && log "  Reclaimable space: $DOCKER_DISK"
else
    log "  Docker not available"
fi

# =============================================================================
# 10. CLAMAV — SIGNATURE UPDATE
# =============================================================================
section "10/19  ClamAV — signature update"

CLAMAV_SCRIPT="$SCRIPT_DIR/scheduled/update-clamav.sh"
if [ -x "$CLAMAV_SCRIPT" ]; then
    if bash "$CLAMAV_SCRIPT" >/dev/null 2>&1; then
        ok "ClamAV signatures updated"
    else
        warn "ClamAV: update errors — check /var/log/clamav_auto_update.log"
    fi
else
    warn "update-clamav.sh not found or not executable: $CLAMAV_SCRIPT"
fi

# =============================================================================
# 11. IP BLOCKLISTS
# =============================================================================
section "11/19  IP blocklists"

BLOCKIP_SCRIPT="$SCRIPT_DIR/scheduled/auto-block-ip.sh"
if [ -x "$BLOCKIP_SCRIPT" ]; then
    if bash "$BLOCKIP_SCRIPT" >/dev/null 2>&1; then
        ok "IP blocklists updated (feodotracker, 3coresec, blocklist.de)"
    else
        warn "IP blocklists: update error"
    fi
else
    warn "auto-block-ip.sh not found: $BLOCKIP_SCRIPT"
fi

# =============================================================================
# 12. SYNOLOGY DATABASES + RAM
# =============================================================================
section "12/19  DB Synology + RAM"

if [ -x /usr/syno/bin/synodbtool ]; then
    /usr/syno/bin/synodbtool --compact-all-db >/dev/null 2>&1 && ok "Synology databases compacted"
else
    log "  synodbtool not available"
fi

MEM_BEFORE=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
sync
if [ -w /proc/sys/vm/drop_caches ]; then
    echo 1 > /proc/sys/vm/drop_caches
    MEM_AFTER=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    FREED=$(( (MEM_AFTER - MEM_BEFORE) / 1024 ))
    ok "PageCache dropped | Before: $((MEM_BEFORE / 1024))MB → After: $((MEM_AFTER / 1024))MB (freed: ${FREED}MB)"
fi

# =============================================================================
# 13. SMART — DISK HEALTH
# =============================================================================
section "13/19  SMART"

SMART_SCRIPT="$SCRIPT_DIR/external/smart_info/syno_smart_info.sh"
SMART_FAIL=0
for disk in /dev/sda /dev/sdb; do
    [ -b "$disk" ] || continue
    STATUS=$(smartctl -H "$disk" 2>/dev/null | awk '/result|overall-health/ {print $NF}')
    [ -z "$STATUS" ] && STATUS=$(smartctl -H "$disk" -d sat 2>/dev/null | awk '/result|overall-health/ {print $NF}')
    SMART_FLAGS=""; echo "$STATUS" | grep -q "PASSED\|OK" || SMART_FLAGS="-d sat"
    [ -z "$STATUS" ] && SMART_FLAGS="-d sat"
    TEMP=$(smartctl -A "$disk" $SMART_FLAGS 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temp/ {print $10; exit}')
    HOURS=$(smartctl -A "$disk" $SMART_FLAGS 2>/dev/null | awk '/Power_On_Hours/ {print $10}')
    REALLOCATED=$(smartctl -A "$disk" $SMART_FLAGS 2>/dev/null | awk '/Reallocated_Sector/ {print $10}')
    log "  $disk | Status: ${STATUS:-?} | Temp: ${TEMP:-?}°C | Hours: ${HOURS:-?} | Reallocated: ${REALLOCATED:-?}"
    if [ -z "$STATUS" ]; then
        warn "SMART not available on $disk (unsupported drive or access denied)"
    elif ! echo "$STATUS" | grep -qi "PASSED\|OK"; then
        error "SMART failure on $disk: $STATUS"
        SMART_FAIL=$((SMART_FAIL + 1))
    fi
done
[ "$SMART_FAIL" -eq 0 ] && ok "SMART OK on supported disks"

# Detailed attribute report (syno_smart_info.sh)
if [ -x "$SMART_SCRIPT" ]; then
    log "  [Detailed SMART attributes — syno_smart_info v1.4.38]"
    bash "$SMART_SCRIPT" -e 2>/dev/null | grep -v '^$' | sed 's/^/  /'
fi

# =============================================================================
# 14. DISK SPACE
# =============================================================================
section "14/19  Disk space"

DISK_OK=1
for vol in $VOLUMES; do
    VOL_PCT=$(df "$vol" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    VOL_INFO=$(df -h "$vol" 2>/dev/null | awk 'NR==2 {print $3" used, "$4" free"}')
    log "  $vol: $VOL_INFO (${VOL_PCT:-?}%)"
    [ "${VOL_PCT:-0}" -ge 90 ] && error "$vol at ${VOL_PCT}% — CRITICAL" && DISK_OK=0
    [ "${VOL_PCT:-0}" -ge 85 ] && [ "${VOL_PCT:-0}" -lt 90 ] && warn "$vol at ${VOL_PCT}% — low space" && DISK_OK=0
done
[ "$DISK_OK" -eq 1 ] && ok "Disk space OK"

# =============================================================================
# 15. HYPERBACKUP — STATUS
# =============================================================================
section "15/19  HyperBackup"

BACKUP_LAST="/volume1/@appdata/HyperBackup/last_result/backup.last"
if [ -f "$BACKUP_LAST" ]; then
    BACKUP_DATE=$(stat -c '%y' "$BACKUP_LAST" 2>/dev/null | cut -d' ' -f1)
    BACKUP_AGE_DAYS=$(( ( $(date +%s) - $(stat -c '%Y' "$BACKUP_LAST" 2>/dev/null) ) / 86400 ))
    BACKUP_RESULT=$(grep -i "result\|error\|success\|fail" "$BACKUP_LAST" 2>/dev/null | head -2 | tr '\n' ' ')
    log "  Last backup: $BACKUP_DATE (${BACKUP_AGE_DAYS} day(s) ago)"
    [ -n "$BACKUP_RESULT" ] && log "  Status: $BACKUP_RESULT"
    if [ "$BACKUP_AGE_DAYS" -gt 2 ]; then
        warn "HyperBackup not run in ${BACKUP_AGE_DAYS} days"
    else
        ok "HyperBackup recent (${BACKUP_AGE_DAYS}d)"
    fi
else
    warn "HyperBackup status not found: $BACKUP_LAST"
fi

# =============================================================================
# 16. ANTIVIRUS — STATUS
# =============================================================================
section "16/19  AntiVirus"

AV_REPORT="/var/packages/AntiVirus/var/.report"
if [ -f "$AV_REPORT" ]; then
    AV_AGE_DAYS=$(( ( $(date +%s) - $(stat -c '%Y' "$AV_REPORT" 2>/dev/null) ) / 86400 ))
    AV_DATE=$(stat -c '%y' "$AV_REPORT" 2>/dev/null | cut -d'.' -f1)
    # Count only threat/virus rows (exclude scanner info events)
    AV_LATEST=$(/usr/bin/sqlite3 "$AV_REPORT" "SELECT eventArgs FROM report WHERE eventKey='report_all_handled' ORDER BY logTime DESC LIMIT 1;" 2>/dev/null)
    AV_SCANNED=$(echo "$AV_LATEST" | grep -oP '^\[(\d+)' | grep -oP '\d+' || echo "?")
    AV_THREATS=$(echo "$AV_LATEST" | grep -oP ',(\d+)\]$' | grep -oP '\d+' || echo "?")
    log "  Last scan: $AV_DATE (${AV_AGE_DAYS}d ago) | Files scanned: $AV_SCANNED"
    if [ -z "$AV_LATEST" ]; then
        warn "Could not read AntiVirus report"
    elif [ "${AV_THREATS}" -gt 0 ] 2>/dev/null; then
        error "AntiVirus: ${AV_THREATS} threat(s) detected — check DSM > AntiVirus"
    else
        ok "AntiVirus: 0 threats | last scan ${AV_AGE_DAYS}d ago"
    fi
    [ "$AV_AGE_DAYS" -gt 8 ] && warn "AntiVirus has not scanned in ${AV_AGE_DAYS} days — verify schedule"
else
    warn "AntiVirus report not found: $AV_REPORT"
fi

# =============================================================================
# 17. TLS CERTIFICATES
# =============================================================================
section "17/19  TLS certificates"

CERT_FOUND=0
while IFS= read -r cert; do
    [ -f "$cert" ] || continue
    CERT_FOUND=$((CERT_FOUND + 1))
    EXPIRY=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2)
    LABEL=$(echo "$cert" | sed 's|/usr/syno/etc/certificate/||' | sed 's|/cert.pem||')
    if ! openssl x509 -noout -checkend 0 -in "$cert" >/dev/null 2>&1; then
        error "Certificate EXPIRED: $LABEL (expired: $EXPIRY)"
    elif ! openssl x509 -noout -checkend 864000 -in "$cert" >/dev/null 2>&1; then
        error "TLS expires in <10 days: $LABEL — $EXPIRY — renew URGENTLY"
    elif ! openssl x509 -noout -checkend 2592000 -in "$cert" >/dev/null 2>&1; then
        warn "TLS expires in <30 days: $LABEL — $EXPIRY"
    else
        ok "TLS OK — $LABEL — expires: $EXPIRY"
    fi
done < <(find /usr/syno/etc/certificate -name "cert.pem" ! -path "*/_archive/*" 2>/dev/null)

[ "$CERT_FOUND" -eq 0 ] && warn "No certificates found in /usr/syno/etc/certificate"

# =============================================================================
# 18. TRIVY — IMAGE SCAN
# =============================================================================
section "18/19  Trivy — image scan"

TRIVY_SCRIPT="$SCRIPT_DIR/scheduled/trivy-scan-weekly.sh"
if [ -x "$TRIVY_SCRIPT" ]; then
    if bash "$TRIVY_SCRIPT" >/dev/null 2>&1; then
        ok "Trivy: scan complete — JSON in /volume1/docker/trivy/reports/"
    else
        warn "Trivy: scan errors — check $SCRIPT_DIR/logs/trivy_scan_weekly.log"
    fi
else
    warn "trivy-scan-weekly.sh not found: $TRIVY_SCRIPT"
fi

# =============================================================================
# 19. HIBERNATION — VERIFY SYNOCROND + NOATIME CONFIG
# =============================================================================
section "19/19  HDD hibernation"

HIB_OK=1
SYNO_CROND_DIR="/usr/syno/share/synocron.d"

# Tasks that must be at weekly or monthly (not daily)
for _check in \
    "libhwcontrol.conf:disk_daily_routine" \
    "libsynostorage.conf:syno_disk_db_update" \
    "libsynostorage.conf:syno_btrfs_metadata_check" \
    "synolegalnotifier.conf:synolegalnotifier"; do
    _file="${_check%%:*}"
    _task="${_check##*:}"
    _fpath="$SYNO_CROND_DIR/$_file"
    if [ -f "$_fpath" ]; then
        _period=$(python3 -c "
import json
tasks = json.load(open('$_fpath'))
if isinstance(tasks, dict): tasks = [tasks]
for t in tasks:
    if t.get('name') == '$_task':
        print(t.get('period','?'))
        break
" 2>/dev/null)
        case "$_period" in
            weekly|monthly) ok "  synocrond $_task: $_period" ;;
            *) warn "  synocrond $_task: $_period (should be weekly/monthly — re-run configure-synocrond.sh)" && HIB_OK=0 ;;
        esac
    fi
done

# noatime on data volumes
for vol in $VOLUMES; do
    if mount | grep -qE " on $vol (type |\().*noatime"; then
        ok "  $vol: noatime active"
    else
        warn "  $vol: no noatime (applied on next boot via optimize-kernel.sh)" && HIB_OK=0
    fi
done

# Redis timeout
REDIS_CONF="/usr/syno/etc/synocached/synocached.default.conf"
if [ -f "$REDIS_CONF" ]; then
    if grep -q "^timeout 900" "$REDIS_CONF"; then
        ok "  Redis timeout: 900s"
    else
        _rtimeout=$(grep "^timeout" "$REDIS_CONF" 2>/dev/null | head -1)
        warn "  Redis timeout not at 900s ($_rtimeout) — re-run configure-synocrond.sh" && HIB_OK=0
    fi
fi

[ "$HIB_OK" -eq 1 ] && ok "Hibernation config correct"

# =============================================================================
# SUMMARY
# =============================================================================
END_TS=$(date +%s)
DURATION=$(( END_TS - START_TS ))
DURATION_MIN=$(( DURATION / 60 ))
DURATION_SEC=$(( DURATION % 60 ))

log ""
log "============================================================="
log "  SUMMARY"
log "  End: $(ts) | Duration: ${DURATION_MIN}m ${DURATION_SEC}s"
DISK_SUMMARY=$(df -h $VOLUMES 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); printf "%s:%s%% ", $NF, $5}')
log "  Steps OK: $STEPS_OK | Warnings: $WARN | Errors: $ERR"
log "  Disk: ${DISK_SUMMARY:-?}"
log "============================================================="

# DSM notification
if [ -x /usr/syno/bin/synodsmnotify ]; then
    if [ "$ERR" -gt 0 ]; then
        MSG="ERROR(${ERR}) WARNING(${WARN}) — check log. ${DISK_SUMMARY}"
    elif [ "$WARN" -gt 0 ]; then
        MSG="Completed with ${WARN} warning(s). ${DISK_SUMMARY}"
    else
        MSG="Completed without issues. ${DISK_SUMMARY}(${DURATION_MIN}m ${DURATION_SEC}s)"
    fi
    /usr/syno/bin/synodsmnotify @administrators "NAS Weekly Maintenance" "$MSG" >/dev/null 2>&1 || true
fi

exit 0
