#!/usr/bin/env python3
"""
CrowdSec iptables bouncer — Synology NAS (no ipset, no nftables)
Uses LAPI /v1/decisions/stream for incremental updates.
"""
from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CONFIG_FILE = "/etc/crowdsec/cs-py-bouncer.conf"
LOG_FILE    = "/var/log/crowdsec-bouncer.log"
PID_FILE    = "/var/run/crowdsec-bouncer.pid"
CHAIN       = "CROWDSEC"

# Defaults (overridden by config file)
LAPI_URL       = "http://localhost:8080"
API_KEY        = ""
POLL_INTERVAL  = 30


def load_config():
    global LAPI_URL, API_KEY, POLL_INTERVAL
    try:
        with open(CONFIG_FILE) as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if k == "api_key":
                    API_KEY = v
                elif k == "lapi_url":
                    LAPI_URL = v
                elif k == "poll_interval":
                    POLL_INTERVAL = int(v)
    except FileNotFoundError:
        print(f"Config not found: {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)


def log_setup():
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )


def run(cmd, check=False):
    return subprocess.run(cmd, capture_output=True, check=check)


def setup_chain():
    """Create CROWDSEC chain and flush any stale rules from a previous run."""
    run(["iptables", "-N", CHAIN])           # no-op if exists
    run(["iptables", "-F", CHAIN])           # flush stale rules

    for table in ("INPUT", "FORWARD"):
        if run(["iptables", "-C", table, "-j", CHAIN]).returncode != 0:
            run(["iptables", "-I", table, "1", "-j", CHAIN], check=True)


def cleanup_chain():
    logging.info("Removing iptables rules")
    for table in ("INPUT", "FORWARD"):
        run(["iptables", "-D", table, "-j", CHAIN])
    run(["iptables", "-F", CHAIN])
    run(["iptables", "-X", CHAIN])


# ─── iptables-restore batch helpers ──────────────────────────────────────────

# /sbin/iptables-restore on Synology is a bash wrapper that calls `usleep`
# (not available on this system). Use the real binary directly.
_XTABLES = "/usr/bin/xtables-legacy-multi"

def _restore(rules: list[str]):
    """Apply a list of raw iptables-restore lines atomically."""
    # Include chain declaration so it's auto-created if missing
    block = f"*filter\n:{CHAIN} - [0:0]\n" + "\n".join(rules) + "\nCOMMIT\n"
    proc = subprocess.run(
        [_XTABLES, "iptables-restore", "--noflush"],
        input=block.encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode().strip()
        logging.warning("iptables-restore failed (%s), recreando chain...", err)
        try:
            setup_chain()
        except Exception:
            pass
        proc = subprocess.run(
            [_XTABLES, "iptables-restore", "--noflush"],
            input=block.encode(),
            capture_output=True,
        )
        if proc.returncode != 0:
            logging.error("iptables-restore failed: %s", proc.stderr.decode().strip())


def _is_ipv4(ip: str) -> bool:
    return ":" not in ip


def apply_batch(to_add: list[str], to_del: list[str]):
    lines = []
    for ip in to_del:
        if _is_ipv4(ip):
            lines.append(f"-D {CHAIN} -s {ip} -j DROP")
    for ip in to_add:
        if _is_ipv4(ip):
            lines.append(f"-A {CHAIN} -s {ip} -j DROP")
    if lines:
        _restore(lines)


# ─── LAPI polling ─────────────────────────────────────────────────────────────

def api_get(path: str):
    req = Request(
        f"{LAPI_URL}{path}",
        headers={"X-Api-Key": API_KEY, "Accept": "application/json"},
    )
    with urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


_startup = True
banned: set[str] = set()


def poll():
    global _startup

    path = "/v1/decisions/stream?startup=true" if _startup else "/v1/decisions/stream"
    try:
        data = api_get(path)
    except (URLError, HTTPError, OSError) as exc:
        logging.warning("LAPI unreachable: %s", exc)
        return
    except Exception as exc:
        logging.error("Unexpected error polling LAPI: %s", exc)
        return

    new_raw = data.get("new") or []
    del_raw = data.get("deleted") or []

    to_add = [d["value"] for d in new_raw if d.get("type") == "ban" and d.get("value") and d["value"] not in banned]
    to_del = [d["value"] for d in del_raw if d.get("value") and d["value"] in banned]

    if to_add or to_del:
        apply_batch(to_add, to_del)
        for ip in to_add:
            banned.add(ip)
        for ip in to_del:
            banned.discard(ip)

    if _startup:
        logging.info("Startup: %d IPs loaded", len(banned))
        _startup = False
    elif to_add or to_del:
        logging.info("Delta: +%d -%d (total %d)", len(to_add), len(to_del), len(banned))


# ─── main ─────────────────────────────────────────────────────────────────────

running = True


def _on_signal(signum, _frame):
    global running
    logging.info("Signal %d received, stopping", signum)
    running = False


def main():
    log_setup()
    load_config()

    if not API_KEY:
        logging.error("api_key not configured in %s", CONFIG_FILE)
        sys.exit(1)

    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    logging.info("CrowdSec bouncer started (PID %d)", os.getpid())

    try:
        setup_chain()
    except subprocess.CalledProcessError as exc:
        logging.error("iptables setup failed: %s", exc)
        sys.exit(1)

    while running:
        poll()
        if running:
            time.sleep(POLL_INTERVAL)

    cleanup_chain()
    try:
        os.unlink(PID_FILE)
    except OSError:
        pass
    logging.info("Bouncer stopped cleanly")


if __name__ == "__main__":
    main()
