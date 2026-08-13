#!/usr/bin/env bash
set -euo pipefail
# Lightweight POSIX/Linux telemetry agent. Sends JSON with curl.
SERVER_URL="${SERVER_URL:-http://127.0.0.1:5000/api/v1/telemetry}"
NODE_ID="${NODE_ID:-$(hostname -s)}"
INTERVAL="${INTERVAL:-10}"
API_TOKEN="${API_TOKEN:-change-me}"
LOG_FILE="${LOG_FILE:-/var/log/syslog}"
STATE_DIR="${STATE_DIR:-/tmp/dla-agent}"
mkdir -p "$STATE_DIR"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

read_cpu() {
  awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8; print $5}' /proc/stat
}
cpu_sample() {
  local a b total1 idle1 total2 idle2
  read -r total1 idle1 < <(read_cpu)
  sleep 0.15
  read -r total2 idle2 < <(read_cpu)
  awk -v t1="$total1" -v i1="$idle1" -v t2="$total2" -v i2="$idle2" \
    'BEGIN { d=t2-t1; if (d<=0) print 0; else printf "%.2f", (1-(i2-i1)/d)*100 }'
}
ram_percent() {
  awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {if(t>0) printf "%.2f", (1-a/t)*100; else print 0}' /proc/meminfo
}
recent_logs() {
  if [ -r "$LOG_FILE" ]; then
    tail -n 20 "$LOG_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().splitlines()))'
  else
    printf '[]'
  fi
}

while true; do
  CPU="$(cpu_sample)"
  RAM="$(ram_percent)"
  LOGS="$(recent_logs)"
  PAYLOAD="$(python3 - "$NODE_ID" "$CPU" "$RAM" "$LOGS" <<'PY'
import json,sys,datetime
node,cpu,ram,logs=sys.argv[1:]
print(json.dumps({
  "node_id": node,
  "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "metrics": {"cpu_percent": float(cpu), "ram_percent": float(ram)},
  "logs": json.loads(logs)
}))
PY
)"
  curl -fsS --max-time 5 \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${API_TOKEN}" \
    --data "$PAYLOAD" "$SERVER_URL" >/dev/null || \
    printf '%s telemetry delivery failed\n' "$(date -Is)" >> "$STATE_DIR/errors.log"
  sleep "$INTERVAL"
done
