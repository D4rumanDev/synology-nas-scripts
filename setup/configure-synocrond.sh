#!/bin/bash
# =============================================================================
# configure-synocrond.sh — Reduce synocrond task frequency to allow HDD hibernation
# Synology DS218+ / DSM 7.x | Requires root | Idempotent
#
# Inspired by: https://github.com/AlexFromChaos/synology_hibernation_fixer
# Re-run after every DSM update — tasks revert to defaults on system upgrades.
# =============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: requires root. Run with: sudo $0" >&2
    exit 1
fi

BACKUP_DIR="/volume1/scripts/SYNOLOGY/backups/synocrond-$(date +%Y%m%d_%H%M%S)"
SYNO_CROND="/usr/syno/share/synocron.d"
REDIS_CONF="/usr/syno/etc/synocached/synocached.default.conf"
LOG="/tmp/configure-synocrond.log"
CHANGED=0

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓  $*" | tee -a "$LOG"; }
skip() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ─  $*" | tee -a "$LOG"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠  $*" | tee -a "$LOG"; }

log "==================================================================="
log "  configure-synocrond.sh — start"
log "==================================================================="

# =============================================================================
# 1. Backup
# =============================================================================
mkdir -p "$BACKUP_DIR"
for name in libhwcontrol libsynostorage synolegalnotifier \
            synosharesnaptree_reconstruct synoupgrade_routine; do
    f="$SYNO_CROND/${name}.conf"
    [ -f "$f" ] && cp "$f" "$BACKUP_DIR/"
done
[ -f "$REDIS_CONF" ] && cp "$REDIS_CONF" "$BACKUP_DIR/"
ok "Backup saved to $BACKUP_DIR"

# =============================================================================
# 2. Reduce synocrond task frequency
#    Edits JSON in-place with Python3. Removes "crontab" key when changing period.
# =============================================================================
log ""
log "── synocrond tasks ───────────────────────────────────────────────"

set_task_period() {
    local file="$1" task_name="$2" new_period="$3"
    [ -f "$file" ] || { warn "  $file not found"; return; }

    result=$(python3 << PYEOF
import json, sys

fpath      = "$file"
task_name  = "$task_name"
new_period = "$new_period"

with open(fpath) as f:
    raw = json.load(f)

is_list = isinstance(raw, list)
tasks   = raw if is_list else [raw]
changed = False

for task in tasks:
    if task.get("name") == task_name:
        cur = task.get("period", "?")
        if cur == new_period and "crontab" not in task:
            print(f"SKIP:{task_name}:{cur}")
        else:
            old = f"{cur}" + (f" ({task['crontab']})" if "crontab" in task else "")
            task["period"] = new_period
            task.pop("crontab", None)
            changed = True
            print(f"SET:{task_name}:{old}:{new_period}")

if changed:
    with open(fpath, "w") as f:
        json.dump(raw if is_list else tasks[0], f, indent=4)
PYEOF
)
    case "$result" in
        SKIP:*) skip "  $task_name: already at $new_period" ;;
        SET:*)
            old=$(echo "$result" | cut -d: -f3)
            new=$(echo "$result" | cut -d: -f4)
            ok "  $task_name: $old → $new"
            CHANGED=1
            ;;
        *) warn "  $task_name: no changes (task not found in $file)" ;;
    esac
}

set_task_period "$SYNO_CROND/libhwcontrol.conf"              "disk_daily_routine"           "weekly"
set_task_period "$SYNO_CROND/libsynostorage.conf"            "syno_disk_db_update"          "monthly"
set_task_period "$SYNO_CROND/libsynostorage.conf"            "syno_btrfs_metadata_check"    "monthly"
set_task_period "$SYNO_CROND/synolegalnotifier.conf"         "synolegalnotifier"            "monthly"

# synosharesnaptree_reconstruct and synoupgrade_routine are objects without a "name" key
for name in synosharesnaptree_reconstruct synoupgrade_routine; do
    f="$SYNO_CROND/${name}.conf"
    [ -f "$f" ] || { warn "  $name.conf not found (package not installed)"; continue; }

    cur=$(python3 -c "
import json
d = json.load(open('$f'))
t = d if isinstance(d, dict) else d[0]
print(t.get('period', '?'))
" 2>/dev/null)

    if [ "$cur" = "weekly" ] || [ "$cur" = "monthly" ]; then
        skip "  $name: already at $cur"
    else
        python3 << PYEOF
import json
fpath = "$f"
with open(fpath) as f: raw = json.load(f)
is_list = isinstance(raw, list)
tasks = raw if is_list else [raw]
for t in tasks:
    t["period"] = "weekly"
    t.pop("crontab", None)
with open(fpath, "w") as f:
    json.dump(raw if is_list else tasks[0], f, indent=4)
PYEOF
        ok "  $name: $cur → weekly"
        CHANGED=1
    fi
done

# =============================================================================
# 3. Redis timeout: 3600s (1h) → 900s (15 min)
#    Prevents DSM from keeping disks active 1h after closing the WebUI
# =============================================================================
log ""
log "── Redis (synocached) ────────────────────────────────────────────"

if [ -f "$REDIS_CONF" ]; then
    if grep -q "^timeout 3600" "$REDIS_CONF"; then
        sed -i "s/^timeout 3600/timeout 900/" "$REDIS_CONF"
        ok "Redis timeout: 3600s → 900s"
        CHANGED=1
    elif grep -q "^timeout 900" "$REDIS_CONF"; then
        skip "Redis timeout already at 900s"
    else
        warn "Pattern 'timeout 3600' not found — check $REDIS_CONF"
    fi
else
    warn "$REDIS_CONF does not exist in this DSM version"
fi

# =============================================================================
# 4. noatime on data volumes
#    / (md0) already has noatime in DSM 7 — only touch volume1/volume2/etc
# =============================================================================
log ""
log "── Mount options (noatime) ───────────────────────────────────────"

remount_noatime() {
    local vol="$1"
    [ -d "$vol" ] || return
    if mount | grep -qE " on $vol (type |\().*noatime"; then
        skip "$vol: already mounted with noatime"
    elif mount | grep -qE " on $vol "; then
        if mount -o noatime,remount "$vol" 2>/dev/null; then
            ok "$vol: remounted with noatime"
        else
            warn "$vol: remount failed (normal on btrfs with subvolumes — no critical impact)"
        fi
    fi
}

for _vol in $(df 2>/dev/null | awk '$NF ~ /^\/volume[0-9]+$/ {print $NF}' | sort -u); do
    remount_noatime "$_vol"
done

# =============================================================================
# 5. Restart synocrond if anything changed
# =============================================================================
log ""
if [ "$CHANGED" -eq 1 ]; then
    log "── Restarting synocrond ──────────────────────────────────────────"
    if systemctl restart synocrond 2>/dev/null; then
        ok "synocrond restarted"
    else
        warn "systemctl restart failed — restart synocrond manually or reboot the NAS"
    fi
else
    skip "No changes — synocrond restart not needed"
fi

# Keep only the 5 most recent backups
ls -dt /volume1/scripts/SYNOLOGY/backups/synocrond-* 2>/dev/null | tail -n +6 | xargs rm -rf 2>/dev/null

log ""
log "==================================================================="
log "  Done | Backup: $BACKUP_DIR | Log: $LOG"
log "==================================================================="
log ""
log "NOTE: DSM may revert these changes after an update."
log "      This script runs automatically on every boot via optimize-kernel.sh."
