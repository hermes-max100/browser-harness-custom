#!/usr/bin/env bash
set -euo pipefail

BH_IMAGE_TAG="${BH_IMAGE_TAG:-browser-harness-stack:local}"
BH_DESKTOP_CDP_URL="${BH_DESKTOP_CDP_URL:-http://127.0.0.1:9222}"
BH_CHROME_PID="${BH_CHROME_PID:-/tmp/browser-harness-chrome.pid}"
BH_STRICT="${BH_STRICT:-0}"
BH_VERIFY_DOCKER_BUILD="${BH_VERIFY_DOCKER_BUILD:-0}"

warnings=0

warn() {
  warnings=$((warnings + 1))
  printf 'WARN: %s\n' "$*" >&2
}

pass() {
  printf 'OK: %s\n' "$*"
}

if command -v docker >/dev/null 2>&1; then
  pass "docker CLI available: $(docker --version)"
  if [[ "$BH_VERIFY_DOCKER_BUILD" == "1" ]]; then
    docker build -f Dockerfile.browser-harness -t "$BH_IMAGE_TAG" .
    docker run --rm "$BH_IMAGE_TAG" browser-harness --version
    pass "Docker image built and smoke-ran as $BH_IMAGE_TAG"
  else
    warn "Docker CLI exists, but image build was skipped. Set BH_VERIFY_DOCKER_BUILD=1 to build and run Dockerfile.browser-harness."
  fi
else
  warn "Docker CLI is not installed here; Dockerfile.browser-harness remains unbuilt in this environment. Build it on a Docker-capable Linux host."
fi

if command -v browser-harness >/dev/null 2>&1; then
  browser-harness <<'PY' >/tmp/browser-harness-production-managed-smoke.txt
print(page_info())
PY
  pass "wrapper-managed headless Chrome smoke test passed"
else
  warn "browser-harness CLI is not installed in PATH; run ./scripts/setup-browser-harness.sh first."
fi

managed_pid_alive=0
if [[ -f "$BH_CHROME_PID" ]]; then
  managed_pid="$(cat "$BH_CHROME_PID")"
  if [[ -n "$managed_pid" ]] && kill -0 "$managed_pid" >/dev/null 2>&1; then
    managed_pid_alive=1
  fi
fi

if curl -fsS --max-time 3 "$BH_DESKTOP_CDP_URL/json/version" >/tmp/browser-harness-desktop-cdp-version.json 2>/dev/null; then
  if [[ "$managed_pid_alive" == "1" && "$BH_DESKTOP_CDP_URL" == "http://127.0.0.1:9222" ]]; then
    warn "CDP is reachable at $BH_DESKTOP_CDP_URL, but the wrapper-managed Chrome PID is alive; this does not prove attachment to a real desktop Chrome profile."
  else
    BU_CDP_URL="$BH_DESKTOP_CDP_URL" browser-harness <<'PY' >/tmp/browser-harness-desktop-smoke.txt
print(page_info())
PY
    pass "desktop/external CDP smoke test passed at $BH_DESKTOP_CDP_URL"
  fi
else
  warn "No desktop/external Chrome CDP endpoint is reachable at $BH_DESKTOP_CDP_URL. On the real host, run: google-chrome --remote-debugging-port=9222 --user-data-dir=\$HOME/.browser-harness-profile"
fi

if [[ "$warnings" -gt 0 ]]; then
  printf 'Verification completed with %s warning(s).\n' "$warnings" >&2
  if [[ "$BH_STRICT" == "1" ]]; then
    exit 1
  fi
fi
