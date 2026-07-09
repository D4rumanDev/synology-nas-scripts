#!/bin/sh
# Throttle Synology Photos AI background processing.
# Task Scheduler: daily 07:00, root.
#
# What it does:
#   1. Stops the 3 AI workers (concept detection, face extraction, person clustering)
#      which cause continuous I/O by reading photos and writing to the postgres DB.
#   2. Reduces task-center concurrency from 4 to 1 thread.
#
# To re-enable: synopkg stop SynologyPhotos && synopkg start SynologyPhotos
# To disable this throttle: remove the task from Task Scheduler.

LOG="/volume1/scripts/SYNOLOGY/logs/throttle-photos-ai.log"
DATE="$(date '+%Y-%m-%d %H:%M:%S')"

echo "[$DATE] Throttling Photos AI..." >> "$LOG"

# Stop AI workers (they only restart on full package restart)
for SVC in \
    pkg-SynologyPhotos-concept-detection.service \
    pkg-SynologyPhotos-face-extraction.service \
    pkg-SynologyPhotos-person-clustering.service; do
    synosystemctl stop "$SVC" >> "$LOG" 2>&1 && \
        echo "  [OK] Stopped: $SVC" >> "$LOG" || \
        echo "  [--] Not running or error: $SVC" >> "$LOG"
done

# Reduce task-center concurrency to 1 thread and restart it
CONFIG="/volume1/@appconf/SynologyPhotos/task_center_config.json"
if [ -f "$CONFIG" ]; then
    echo '{"concurrency":1}' > "$CONFIG"
    synosystemctl restart pkg-SynologyPhotos-task-center.service >> "$LOG" 2>&1
    echo "  [OK] Concurrency reduced to 1, task-center restarted" >> "$LOG"
fi

echo "[$DATE] Done." >> "$LOG"
