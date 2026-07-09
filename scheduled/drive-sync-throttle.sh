#!/bin/bash
# Throttle Synology Drive native client sync to once every ~30 minutes.
# Runs from cron every 30 min. Opens a 30-second sync window, then pauses
# for 1830 seconds (ensures pause outlasts the cron interval with a buffer).
#
# Addresses: continuous disk writes from Drive syncing Claude session files.
# The NativeUpload direction (NAS→Windows) is what this controls.

WEBAPI=/usr/syno/bin/synowebapi
LOG=/volume1/scripts/SYNOLOGY/logs/drive-sync-throttle.log
SYNC_WINDOW=30       # seconds to allow sync
PAUSE_DURATION=1830  # seconds to pause after sync window (30.5 min buffer)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# Resume: let queued events flush
$WEBAPI --exec api=SYNO.SynologyDrive.Index method=set_native_client_index_pause version=1 pause_duration=0 > /dev/null 2>&1
log "resumed (sync window open for ${SYNC_WINDOW}s)"

sleep $SYNC_WINDOW

# Pause until next cycle
$WEBAPI --exec api=SYNO.SynologyDrive.Index method=set_native_client_index_pause version=1 pause_duration=$PAUSE_DURATION > /dev/null 2>&1
log "paused for ${PAUSE_DURATION}s"
