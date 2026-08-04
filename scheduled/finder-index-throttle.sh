#!/bin/bash
# Throttle SynoFinder (Universal Search) file indexing for all shares to a
# 30-second window every 30 minutes, mirroring drive-sync-throttle.sh.
#
# Unlike Drive's self-expiring pause_duration timer, SynoFinder's
# FileIndexing API exposes a persistent per-folder "paused" flag
# (SYNO.Finder.FileIndexing.Folder), so this script explicitly resumes then
# re-pauses on each cron run; the pause holds until the next cycle.
#
# Shares are discovered dynamically from the API instead of hardcoded, so
# this script carries no household usernames/paths in source control.
#
# Addresses: continuous disk writes/CPU from fileindexd + synoelasticd
# reacting in near-real-time (inotify) to changes under any indexed share
# (e.g. an editor or agent writing session data continuously).

WEBAPI=/usr/syno/bin/synowebapi
LOG=/volume1/scripts/SYNOLOGY/logs/finder-index-throttle.log
SYNC_WINDOW=30   # seconds to allow indexing before re-pausing

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
set_all_paused() {
    local desired="$1"
    local folders
    folders=$(jq -c --argjson paused "$desired" '[.[] | .paused = $paused]' <<< "$FOLDER_LIST")
    "$WEBAPI" -s --exec api=SYNO.Finder.FileIndexing.Folder version=1 method=set folder="$folders" > /dev/null 2>&1
}

set_all_paused false && log "resumed all shares (index window open for ${SYNC_WINDOW}s)"

sleep "$SYNC_WINDOW"

set_all_paused true && log "paused all shares (until next cycle)"
