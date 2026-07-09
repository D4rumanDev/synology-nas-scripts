#!/bin/bash
# Installs the Python bouncer, replacing the legacy bash bouncer.
# Run as root: sudo bash /volume1/scripts/SYNOLOGY/setup/install-crowdsec-bouncer.sh

SCRIPT_SRC="/volume1/scripts/SYNOLOGY/setup/crowdsec-bouncer.py"
DAEMON="/usr/local/bin/crowdsec-bouncer.py"
RCD="/usr/local/etc/rc.d/crowdsec-bouncer.sh"
CONF="/etc/crowdsec/cs-py-bouncer.conf"
COMPOSE_DIR="/volume1/docker/crowdsec"

# ── 1. Stop and remove the old bash bouncer ───────────────────────────────────
echo "[1/5] Removing old bash bouncer..."

# Kill by PID directly (don't call old rc.d — it may kill the parent shell)
OLD_PID=""
[ -f /var/run/crowdsec-bouncer.pid ] && OLD_PID=$(cat /var/run/crowdsec-bouncer.pid)
if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill -TERM "$OLD_PID" 2>/dev/null || true
    sleep 3
    kill -KILL "$OLD_PID" 2>/dev/null || true
fi
rm -f /var/run/crowdsec-bouncer.pid

# Kill any residual crowdsec-bouncer process (exact name, not this script)
pkill -x crowdsec-bouncer 2>/dev/null || true
pkill -f "/usr/local/bin/crowdsec-bouncer$" 2>/dev/null || true
sleep 1

# Remove residual iptables chain if it exists
iptables -D INPUT   -j CROWDSEC 2>/dev/null || true
iptables -D FORWARD -j CROWDSEC 2>/dev/null || true
iptables -F CROWDSEC 2>/dev/null || true
iptables -X CROWDSEC 2>/dev/null || true

rm -f /usr/local/bin/crowdsec-bouncer   # old bash script

# ── 2. Install the Python bouncer ─────────────────────────────────────────────
echo "[2/5] Installing Python bouncer..."
cp "$SCRIPT_SRC" "$DAEMON"
chmod 755 "$DAEMON"

# ── 3. Start CrowdSec container and generate API key ──────────────────────────
echo "[3/5] Starting CrowdSec LAPI..."
cd "$COMPOSE_DIR"
docker compose up -d

echo "  Waiting for LAPI to be ready..."
for i in $(seq 1 30); do
    curl -sf http://localhost:8080/health >/dev/null 2>&1 && break
    sleep 2
done

# Remove old bouncer entry if it exists
docker exec crowdsec cscli bouncers delete cs-py-bouncer 2>/dev/null || true

echo "  Generating API key..."
API_KEY=$(docker exec crowdsec cscli bouncers add cs-py-bouncer -o raw)
if [ -z "$API_KEY" ]; then
    echo "ERROR: failed to generate API key" >&2
    exit 1
fi
echo "  API key generated OK"

# ── 4. Write config ───────────────────────────────────────────────────────────
echo "[4/5] Writing config to $CONF..."
cat > "$CONF" << EOF
api_key = $API_KEY
lapi_url = http://localhost:8080
poll_interval = 30
EOF
chmod 600 "$CONF"

# ── 5. Write rc.d and start ───────────────────────────────────────────────────
echo "[5/5] Updating rc.d and starting bouncer..."
cat > "$RCD" << 'RCEOF'
#!/bin/bash
DAEMON=/usr/local/bin/crowdsec-bouncer.py
PID_FILE=/var/run/crowdsec-bouncer.pid

start() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
        echo "Bouncer already running"
        return 0
    fi
    nohup /bin/python3 "$DAEMON" >> /var/log/crowdsec-bouncer.log 2>&1 &
    echo $! > "$PID_FILE"
    echo "Bouncer started (PID $(cat $PID_FILE))"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        kill -0 "$PID" 2>/dev/null && kill -TERM "$PID"
        for i in $(seq 1 10); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 1
        done
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID"
        rm -f "$PID_FILE"
        echo "Bouncer stopped"
    else
        echo "Bouncer was not running"
    fi
}

status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
        echo "Running (PID $(cat $PID_FILE))"
    else
        echo "Stopped"
    fi
}

case "$1" in
    start)   start   ;;
    stop)    stop    ;;
    restart) stop; sleep 2; start ;;
    status)  status  ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
RCEOF
chmod 755 "$RCD"

"$RCD" start

echo ""
echo "✓ Installation complete."
echo "  Log:    tail -f /var/log/crowdsec-bouncer.log"
echo "  Status: $RCD status"
echo "  Banned IPs: iptables -L CROWDSEC -n | wc -l"
