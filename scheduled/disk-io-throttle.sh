#!/bin/bash
# Throttle SynoFinder file indexing (all shares) to a single 60-second window
# every 30 minutes. Must run as root (synowebapi returns nothing otherwise).
#
# SynoFinder's indexing pause is a persistent per-folder flag, so it is
# explicitly re-applied every cycle. Pausing indexing is what stops the
# continuous writes from synoelasticd/fileindexd reacting (inotify) to files
# that change all the time.
#
# Deliberately NOT throttled:
# - Synology Drive sync: pausing it broke desktop client sync.
# - Content extraction (synocontentextractd): stopping its service also stops
#   synocontentextract-gen-enable-file.service (PartOf=), whose ExecStop
#   deletes synoindex's INFO flag, so synoindex sees content extraction as
#   disabled rather than paused. It is also restarted by fileindexd (Wants=,
#   Restart=always) and already runs at Nice=15.
#
# Shares are discovered dynamically from the API (SYNO.Finder.FileIndexing.Folder
# method=list) instead of hardcoded paths, so this covers every indexed share
# on the system regardless of how many volumes/disks exist or which shares
# are enabled — no per-install editing needed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBAPI=/usr/syno/bin/synowebapi
LOG_DIR="$SCRIPT_DIR/../logs"
LOG="$LOG_DIR/disk-io-throttle.log"
SYNC_WINDOW=60    # seconds to allow indexing before re-pausing
API_TIMEOUT=120   # seconds before a hung synowebapi call is abandoned

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (synowebapi returns nothing otherwise)" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# Collapses multi-line API output into one log line.
one_line() {
    tr '\n' ' ' <<< "$1" | cut -c1-300
}

# One run at a time: a hung run must not re-pause over a newer run's window.
# Children get fd 9 closed (9>&-) so an orphaned child cannot keep the lock.
# '>>' so an unexpected symlink at the lock path is never truncated.
exec 9>> "$LOG_DIR/.disk-io-throttle.lock"
if ! flock -n 9; then
    log "INFO: previous run still active, skipping this cycle"
    exit 0
fi

# stderr goes to its own file: mixed into stdout it would break the JSON
# parsing, discarded it would leave failures without a reason.
ERR_FILE="$LOG_DIR/.disk-io-throttle.err"

LIST_OUTPUT=$(timeout -k 10 "$API_TIMEOUT" "$WEBAPI" -s --exec api=SYNO.Finder.FileIndexing.Folder version=1 method=list 2> "$ERR_FILE" 9>&-)
FOLDER_LIST=$(jq -c '.data.folder' <<< "$LIST_OUTPUT" 2>/dev/null)

if [ -z "$FOLDER_LIST" ] || [ "$FOLDER_LIST" = "null" ] || [ "$FOLDER_LIST" = "[]" ]; then
    log "ERROR: no folders returned by FileIndexing.Folder list: $(one_line "$LIST_OUTPUT $(cat "$ERR_FILE")")"
    exit 1
fi

# Sets every indexed folder's paused flag to $1 (true|false), reusing the
# folder list fetched once above instead of re-listing on every call.
# synowebapi can exit 0 with {"success":false}, so the JSON is checked too.
set_finder_paused() {
    local desired="$1"
    local folders output
    folders=$(jq -c --argjson paused "$desired" '[.[] | .paused = $paused]' <<< "$FOLDER_LIST")
    if output=$(timeout -k 10 "$API_TIMEOUT" "$WEBAPI" -s --exec api=SYNO.Finder.FileIndexing.Folder version=1 method=set folder="$folders" 2> "$ERR_FILE" 9>&-) \
        && jq -e '.success == true' <<< "$output" > /dev/null 2>&1; then
        log "SynoFinder paused=$desired"
        return 0
    fi
    log "ERROR: SynoFinder paused=$desired call failed: $(one_line "$output $(cat "$ERR_FILE")")"
    return 1
}

# If the script is killed before the final re-pause succeeds, leave indexing
# paused. The handler disarms itself first so a second signal cannot re-enter
# it. (SIGKILL cannot be trapped; the next run re-pauses within 30 minutes.)
on_signal() {
    trap '' INT TERM HUP
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    set_finder_paused true
    exit 1
}
trap on_signal INT TERM HUP

if ! set_finder_paused false; then
    set_finder_paused true
    exit 1
fi
log "resumed SynoFinder (window open for ${SYNC_WINDOW}s)"

# Backgrounded so a trapped signal is handled at once, not after the sleep.
sleep "$SYNC_WINDOW" 9>&- &
SLEEP_PID=$!
wait "$SLEEP_PID"
SLEEP_PID=

if ! set_finder_paused true; then
    exit 1
fi
trap - INT TERM HUP
log "paused SynoFinder (until next cycle)"
