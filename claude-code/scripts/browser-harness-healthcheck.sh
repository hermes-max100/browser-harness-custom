#!/usr/bin/env bash
set -euo pipefail

BH_CDP_URL="${BH_CDP_URL:-${BU_CDP_URL:-http://127.0.0.1:9222}}"
BH_CDP_WS="${BH_CDP_WS:-${BU_CDP_WS:-}}"
BH_CHROME_PID="${BH_CHROME_PID:-/tmp/browser-harness-chrome.pid}"
BH_HEALTH_TIMEOUT="${BH_HEALTH_TIMEOUT:-3}"

fail() {
  printf 'browser-harness healthcheck failed: %s\n' "$1" >&2
  exit 1
}

if [[ -f "$BH_CHROME_PID" ]]; then
  pid="$(cat "$BH_CHROME_PID")"
  if [[ -n "$pid" ]] && ! kill -0 "$pid" >/dev/null 2>&1; then
    fail "managed Chrome PID $pid is not alive"
  fi
fi

if [[ -n "$BH_CDP_WS" ]]; then
  python3 - "$BH_CDP_WS" "$BH_HEALTH_TIMEOUT" <<'PY_WS' || fail "CDP WebSocket endpoint not reachable at $BH_CDP_WS"
import socket
import ssl
import sys
from urllib.parse import urlparse
url = urlparse(sys.argv[1])
timeout = float(sys.argv[2])
if url.scheme not in {"ws", "wss"} or not url.hostname:
    raise SystemExit("invalid WebSocket CDP URL")
port = url.port or (443 if url.scheme == "wss" else 80)
with socket.create_connection((url.hostname, port), timeout=timeout) as sock:
    if url.scheme == "wss":
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(sock, server_hostname=url.hostname):
            pass
print("ok: CDP WebSocket endpoint is reachable")
PY_WS
  exit 0
fi

json="$(curl -fsS --max-time "$BH_HEALTH_TIMEOUT" "$BH_CDP_URL/json/version")" || fail "CDP endpoint not reachable at $BH_CDP_URL/json/version"
python3 - "$json" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
missing = [key for key in ("Browser", "Protocol-Version", "webSocketDebuggerUrl") if key not in payload]
if missing:
    raise SystemExit(f"missing expected CDP keys: {', '.join(missing)}")
print(f"ok: {payload['Browser']} protocol={payload['Protocol-Version']}")
PY
