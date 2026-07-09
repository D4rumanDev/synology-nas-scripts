#!/bin/sh
# Kernel performance & security tuning — DS218+ (Celeron J3355, 6 GB RAM)
# Installed as /usr/local/etc/rc.d/optimize-kernel.sh (symlink)

case "$1" in
    stop) exit 0 ;;
esac

# =============================================================================
# PERFORMANCE — MEMORY / VM
# =============================================================================

sysctl -w vm.swappiness=15
sysctl -w vm.vfs_cache_pressure=50
sysctl -w vm.dirty_background_ratio=5
sysctl -w vm.dirty_ratio=15

# =============================================================================
# PERFORMANCE — NETWORK
# =============================================================================

sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.core.rmem_default=1048576
sysctl -w net.core.wmem_default=1048576
sysctl -w net.core.netdev_max_backlog=5000
sysctl -w net.ipv4.tcp_rmem='4096 87380 8388608'
sysctl -w net.ipv4.tcp_wmem='4096 65536 8388608'
sysctl -w net.ipv4.tcp_max_syn_backlog=2048
sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_keepalive_time=600
sysctl -w net.ipv4.tcp_keepalive_intvl=30
sysctl -w net.ipv4.tcp_keepalive_probes=5
sysctl -w net.ipv4.tcp_slow_start_after_idle=0
sysctl -w "net.ipv4.ip_local_port_range=10000 65535"

# =============================================================================
# PERFORMANCE — I/O
# =============================================================================

# deadline scheduler for HDDs (lower latency than cfq for sequential access)
echo deadline > /sys/block/sda/queue/scheduler
echo deadline > /sys/block/sdb/queue/scheduler

# 1 MB readahead: improves sequential reads (photos, backup, streaming)
echo 1024 > /sys/block/sda/queue/read_ahead_kb
echo 1024 > /sys/block/sdb/queue/read_ahead_kb

# APM level 254: max performance, no head parking on idle.
# Prevents clicking/thudding when parking/waking during intermittent activity.
# Note: Synology DSM may override this if disk hibernation is enabled.
/bin/hdparm -B 254 /dev/sda > /dev/null 2>&1
/bin/hdparm -B 254 /dev/sdb > /dev/null 2>&1

# =============================================================================
# I/O — MOUNT OPTIONS
# =============================================================================

# noatime: skip atime writes on reads → reduces unnecessary I/O.
# / (md0) already has noatime in DSM 7; only touch data volumes.
for vol in $(df 2>/dev/null | awk '$NF ~ /^\/volume[0-9]+$/ {print $NF}' | sort -u); do
    if mount | grep -qE " on $vol (type |\().*noatime"; then
        : # already has noatime
    elif mount | grep -qE " on $vol "; then
        mount -o noatime,remount "$vol" 2>/dev/null || true
    fi
done

# =============================================================================
# SECURITY — KERNEL HARDENING
# =============================================================================

# Hide kernel pointers from unprivileged processes (hardens exploit development)
sysctl -w kernel.kptr_restrict=1

# Only root can read dmesg (prevents kernel info leakage)
sysctl -w kernel.dmesg_restrict=1

# Only root can use perf counters (reduces Spectre side-channel surface)
sysctl -w kernel.perf_event_paranoid=3

# Disable unprivileged eBPF (Spectre side-channel attack vector)
sysctl -w kernel.unprivileged_bpf_disabled=1

# Add PID to core dump filename (prevents overwrites between processes)
sysctl -w kernel.core_uses_pid=1

# =============================================================================
# SECURITY — NETWORK
# =============================================================================

# Disable source routing — allows attackers to dictate packet paths
sysctl -w net.ipv4.conf.all.accept_source_route=0
sysctl -w net.ipv4.conf.default.accept_source_route=0

# Reverse path filter in loose mode (=2): anti-spoofing compatible with Docker+Tailscale.
# Strict mode (=1) would break asymmetric routing for container forwarding.
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2

# Log packets with impossible source IPs (detects spoofing attempts)
sysctl -w net.ipv4.conf.all.log_martians=1
sysctl -w net.ipv4.conf.default.log_martians=1

# Disable IPv6 Router Advertisements — no real IPv6 in use, prevents RA spoofing
sysctl -w net.ipv6.conf.all.accept_ra=0
sysctl -w net.ipv6.conf.default.accept_ra=0

# TIME-WAIT assassination protection (RFC 1337)
sysctl -w net.ipv4.tcp_rfc1337=1

# CVE-2016-5696 — TCP ACK side-channel on kernel 4.4: disable rate limit
sysctl -w net.ipv4.tcp_challenge_ack_limit=2147483647

# =============================================================================
# SECURITY — FILESYSTEM
# =============================================================================

# Block hardlinks to files the user cannot access (prevents privilege escalation via races)
sysctl -w fs.protected_hardlinks=1

# Block symlink attacks in sticky directories like /tmp
sysctl -w fs.protected_symlinks=1

# =============================================================================
# NGINX — security headers + rate limit + access log
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/nginx-security-headers.sh"

# =============================================================================
# HIBERNATION — SYNOCROND + REDIS TIMEOUT
# =============================================================================

# Apply hibernation config on every boot (idempotent).
# Reverts changes that DSM updates reset to their defaults.
"$SCRIPT_DIR/configure-synocrond.sh" >/dev/null 2>&1 || true
