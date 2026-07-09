#!/bin/bash
# =============================================================================
# autoclean.sh — Daily lightweight cleanup for DS218+
# Task Scheduler: daily 07:00, root
# Complements nas-weekly-maintenance.sh (weekly) with tasks better run daily:
# temp files, logs, Docker, RAM. No heavy I/O operations.
# =============================================================================

LOG_FILE="/volume1/scripts/SYNOLOGY/logs/daily-cleanup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

{
log "========================================================="
log "AUTOCLEAN DS218+ — $(date '+%Y-%m-%d')"
log "========================================================="

# ---------------------------------------------------------------
# 1. TEMP FILES
# ---------------------------------------------------------------
log "[1/6] Temp files..."
find /tmp /var/tmp -xdev -type f -mtime +10 -delete 2>/dev/null
for vol in /volume*; do
    find "$vol" -maxdepth 2 -xdev -type d -name "@eaDir" -empty -exec rmdir {} \; 2>/dev/null
done

# ---------------------------------------------------------------
# 2. LOGS
# ---------------------------------------------------------------
log "[2/6] Logs..."
find /var/log -type f -name "*.log.gz" -mtime +45 -delete 2>/dev/null
find /var/log/synolog -type f -mtime +90 -delete 2>/dev/null
rm -f /var/log/synopkg.log.[1-9] 2>/dev/null
DRIVE_LOG_DIR="/volume1/@synologydrive/log"
if [ -d "$DRIVE_LOG_DIR" ]; then
    for prefix in client syncfolder cloud-workerd backup; do
        find "$DRIVE_LOG_DIR" -name "${prefix}.log_[3-9]" -delete 2>/dev/null
        find "$DRIVE_LOG_DIR" -name "${prefix}.log_[0-9][0-9]" -delete 2>/dev/null
    done
fi

# ---------------------------------------------------------------
# 3. SMB CACHE
# ---------------------------------------------------------------
log "[3/6] SMB cache..."
command -v net >/dev/null 2>&1 && net cache flush 2>/dev/null

# ---------------------------------------------------------------
# 4. DOCKER
# ---------------------------------------------------------------
log "[4/6] Docker prune..."
if [ -x /usr/local/bin/docker ]; then
    /usr/local/bin/docker system prune -f --filter "until=168h" >/dev/null 2>&1
fi

# ---------------------------------------------------------------
# 5. SYNOLOGY DATABASES
# ---------------------------------------------------------------
log "[5/6] DB Synology..."
[ -x /usr/syno/bin/synodbtool ] && /usr/syno/bin/synodbtool --compact-all-db >/dev/null 2>&1

# ---------------------------------------------------------------
# 6. RAM — drop pagecache
# ---------------------------------------------------------------
log "[6/6] RAM..."
sync
[ -w /proc/sys/vm/drop_caches ] && echo 1 > /proc/sys/vm/drop_caches

log "========================================================="
log "DONE"
log "========================================================="

} | tee -a "$LOG_FILE"

exit 0
