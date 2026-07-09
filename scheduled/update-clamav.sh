#!/bin/bash
# Update ClamAV signatures via freshclam with fallback to official mirrors.

FRESHCLAM="/var/packages/AntiVirus/target/engine/clamav/bin/freshclam"
CONF="/var/packages/AntiVirus/target/engine/clamav/etc/freshclam.conf"
LOG="/var/log/clamav_auto_update.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG"; }

# Try freshclam without --force (downloads incremental updates only)
log "Updating with freshclam..."
if timeout 300 "$FRESHCLAM" --config-file="$CONF" --quiet 2>&1 | tee -a "$LOG"; then
    log "✓ Update successful"
    synopkg restart AntiVirus
    exit 0
fi

# Fallback: retry pointing directly at ClamAV official mirrors
log "⚠ freshclam failed, retrying with official mirrors..."
if timeout 300 "$FRESHCLAM" --config-file="$CONF" --quiet \
    --DatabaseMirror=database.clamav.net 2>&1 | tee -a "$LOG"; then
    log "✓ Update successful via official mirror"
    synopkg restart AntiVirus
    exit 0
fi

log "✗ Update failed. Check connectivity or ClamAV service status."
exit 1
