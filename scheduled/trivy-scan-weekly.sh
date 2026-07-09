#!/bin/bash
DOCKER=/usr/local/bin/docker
CACHE_DIR=/volume1/docker/trivy/cache-weekly
REPORT_DIR=/volume1/docker/trivy/reports
LOG=/volume1/scripts/SYNOLOGY/logs/trivy_scan_weekly.log

exec >> "$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

$DOCKER ps --format '{{.Image}}\t{{.Names}}' | while IFS=$'\t' read -r image name; do
    safe="${name//[^a-zA-Z0-9_-]/_}"
    echo "Scanning $image ($name)..."
    $DOCKER run --rm \
        --network host \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v "$CACHE_DIR:/root/.cache" \
        -v "$REPORT_DIR:/reports" \
        aquasec/trivy:latest image \
        --db-repository ghcr.io/aquasecurity/trivy-db \
        --quiet \
        --format json \
        --output "/reports/${safe}.json" \
        "$image"
    echo "  -> /reports/${safe}.json"
done

echo "Done."
