#!/bin/bash
# Throttle Synology Drive native sync + SynoFinder file indexing for all
# shares to a single 30-second window every hour. Replaces the older
# drive-sync-throttle.sh and finder-index-throttle.sh (kept as separate
# scripts, they drifted out of sync on cadence — merged here into one).
#
# Drive's pause is a self-expiring timer (pause_duration seconds), so it is
# renewed past the next cron run with a buffer. SynoFinder's pause is a
# persistent per-folder flag, so it is explicitly re-applied every cycle.
#
# Shares are discovered dynamically from the API (SYNO.Finder.FileIndexing.Folder
# method=list) instead of hardcoded paths, so this covers every indexed share
# on the system regardless of how many volumes/disks exist or which shares
# are enabled — no per-install editing needed.
#
# Addresses: continuous disk writes/CPU from syncd (Drive NAS<->client sync)
# and fileindexd/synoelasticd (SynoFinder) reacting in near-real-time
# (inotify) to file changes under any indexed share — enough to keep disks
# from ever reaching standby.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBAPI=/usr/syno/bin/synowebapi
LOG_DIR="$SCRIPT_DIR/../logs"
LOG="$LOG_DIR/disk-io-throttle.log"
SYNC_WINDOW=30    # seconds to allow sync/indexing before re-pausing
DRIVE_PAUSE=3630  # seconds (60.5 min buffer past the hourly cron interval)

mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

FOLDER_LIST=$("$WEBAPI" -s --exec api=SYNO.Finder.FileIndexing.Folder version=1 method=list 2>/dev/null \
    | jq -c '.data.folder')

if [ -z "$FOLDER_LIST" ] || [ "$FOLDER_LIST" = "null" ] || [ "$FOLDER_LIST" = "[]" ]; then
    log "ERROR: no folders returned by FileIndexing.Folder list"
    exit 1
fi

# Sets every indexed folder's paused flag to $1 (true|false), reusing the
# folder list fetched once above instead of re-listing on every call.
set_finder_paused() {
    local desired="$1"
    local folders
    folders=$(jq -c --argjson paused "$desired" '[.[] | .paused = $paused]' <<< "$FOLDER_LIST")
    if "$WEBAPI" -s --exec api=SYNO.Finder.FileIndexing.Folder version=1 method=set folder="$folders" > /dev/null 2>&1; then
        log "SynoFinder paused=$desired"
    else
        log "ERROR: SynoFinder paused=$desired call failed"
    fi
}

set_drive_pause() {
    local duration="$1"
    if "$WEBAPI" --exec api=SYNO.SynologyDrive.Index method=set_native_client_index_pause version=1 pause_duration="$duration" > /dev/null 2>&1; then
        log "Drive pause_duration=$duration"
    else
        log "ERROR: Drive pause_duration=$duration call failed"
    fi
}

# Resume both
set_drive_pause 0
set_finder_paused false
log "resumed Drive + SynoFinder (window open for ${SYNC_WINDOW}s)"

sleep "$SYNC_WINDOW"

# Pause both until next cycle
set_drive_pause "$DRIVE_PAUSE"
set_finder_paused true
log "paused Drive (${DRIVE_PAUSE}s) + SynoFinder (until next cycle)"
