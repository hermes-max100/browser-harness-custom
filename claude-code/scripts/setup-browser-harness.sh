#!/usr/bin/env bash
set -euo pipefail

BH_REPO_URL="${BH_REPO_URL:-https://github.com/browser-use/browser-harness.git}"
BH_REPO_DIR="${BH_REPO_DIR:-$HOME/Developer/browser-harness}"
BH_CDP_URL="${BH_CDP_URL:-http://127.0.0.1:9222}"
BH_CHROME_PROFILE="${BH_CHROME_PROFILE:-/tmp/browser-harness-chrome-profile}"
BH_CHROME_LOG="${BH_CHROME_LOG:-/tmp/browser-harness-chrome.log}"
BH_CHROME_PID="${BH_CHROME_PID:-/tmp/browser-harness-chrome.pid}"
BH_INVOCATION_COUNT_FILE="${BH_INVOCATION_COUNT_FILE:-/tmp/browser-harness-invocations.count}"
BH_RESTART_AFTER="${BH_RESTART_AFTER:-50}"
BH_PROXY_POOL_FILE="${BH_PROXY_POOL_FILE:-}"
BH_REAL_BIN="${BH_REAL_BIN:-$HOME/.local/bin/browser-harness.uv}"
BH_WRAPPER_BIN="${BH_WRAPPER_BIN:-$HOME/.local/bin/browser-harness}"
BH_EXTRA_PACKAGES=(firecrawl-py tavily-python playwright-stealth camoufox)
CODEX_SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/browser-harness"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

install_google_chrome_if_possible() {
  if command -v google-chrome >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$(id -u)" != "0" ]] || ! command -v apt-get >/dev/null 2>&1; then
    printf 'google-chrome is not installed. Install Google Chrome Stable, then rerun this script.\n' >&2
    exit 1
  fi

  local arch
  arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "amd64" ]]; then
    printf 'google-chrome automatic install is only supported on amd64 (detected %s). Install a compatible Chrome/Chromium package, then rerun this script.\n' "$arch" >&2
    exit 1
  fi

  local deb=/tmp/google-chrome-stable_current_amd64.deb
  curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o "$deb"
  apt-get update
  apt-get install -y "$deb"
}

ensure_bashrc_api_exports_sourceable() {
  local bashrc="$HOME/.bashrc"
  [[ -f "$bashrc" ]] || return 0

  # User-provided API key exports are often appended to the end of ~/.bashrc.
  # Ubuntu's default ~/.bashrc returns early for non-interactive shells, so hoist
  # existing key exports above that guard without recording any secret values here.
  python3 - "$bashrc" <<'PY_BASHRC_EXPORTS'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines()
keys = ("export TAVILY_API_KEY=", "export FIRECRAWL_API_KEY=")
exports = []
rest = []
for line in lines:
    if line.startswith(keys):
        if line not in exports:
            exports.append(line)
    else:
        rest.append(line)
if not exports:
    raise SystemExit(0)
insert_at = len(rest)
for i, line in enumerate(rest):
    stripped = line.strip()
    if '[ -z "$PS1" ] && return' in line or stripped.startswith('case $-') or stripped.startswith('case "$-"'):
        insert_at = i
        break
path.write_text("\n".join(rest[:insert_at] + exports + rest[insert_at:]) + "\n")
PY_BASHRC_EXPORTS
}

install_playwright_browsers() {
  uv run playwright install --with-deps
}

install_browser_harness_tool() {
  uv tool install --python 3.12 --upgrade --force browser-harness

  # Newer uv releases support `uv tool inject`; older uv releases only support
  # reinstalling the tool with repeated `--with` flags. Support both so the
  # requested injected packages are present regardless of the host uv version.
  if uv tool inject --help >/dev/null 2>&1; then
    uv tool inject browser-harness "${BH_EXTRA_PACKAGES[@]}"
  else
    local with_args=()
    local package
    for package in "${BH_EXTRA_PACKAGES[@]}"; do
      with_args+=(--with "$package")
    done
    uv tool install --python 3.12 --upgrade --force browser-harness "${with_args[@]}"
  fi
}

need git
need uv
need curl
need python3

ensure_bashrc_api_exports_sourceable

mkdir -p "$(dirname "$BH_REPO_DIR")"
if [[ -d "$BH_REPO_DIR/.git" ]]; then
  git -C "$BH_REPO_DIR" pull --ff-only
else
  git clone "$BH_REPO_URL" "$BH_REPO_DIR"
fi

install_browser_harness_tool
mkdir -p "$CODEX_SKILL_DIR"
"$BH_WRAPPER_BIN" skill > "$CODEX_SKILL_DIR/SKILL.md"

install_google_chrome_if_possible
install_playwright_browsers

# Preserve the uv-installed entrypoint before replacing it with the auto-start wrapper.
cp "$BH_WRAPPER_BIN" "$BH_REAL_BIN"

cat > "$BH_WRAPPER_BIN" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
REAL_BROWSER_HARNESS="__BH_REAL_BIN__"
DEFAULT_CDP_URL="${BU_CDP_URL:-__BH_CDP_URL__}"
PROFILE_DIR="__BH_CHROME_PROFILE__"
LOG_FILE="__BH_CHROME_LOG__"
PID_FILE="__BH_CHROME_PID__"
COUNT_FILE="__BH_INVOCATION_COUNT_FILE__"
RESTART_AFTER="${BH_RESTART_AFTER:-__BH_RESTART_AFTER__}"
PROXY_POOL_FILE="${BH_PROXY_POOL_FILE:-__BH_PROXY_POOL_FILE__}"

if [[ -z "${BU_CDP_WS:-}" && -z "${BU_CDP_URL:-}" ]]; then
  export BU_CDP_URL="$DEFAULT_CDP_URL"
fi

cdp_ready() {
  curl -fsS "$DEFAULT_CDP_URL/json/version" >/dev/null 2>&1
}

cdp_port() {
  python3 - "$DEFAULT_CDP_URL" <<'PY_CDP_PORT'
from urllib.parse import urlparse
import sys
parsed = urlparse(sys.argv[1])
if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "localhost"}:
    raise SystemExit(f"managed Chrome can only auto-start for local HTTP(S) CDP URLs: {sys.argv[1]}")
print(parsed.port or (443 if parsed.scheme == "https" else 80))
PY_CDP_PORT
}

current_count() {
  if [[ -f "$COUNT_FILE" ]]; then
    cat "$COUNT_FILE"
  else
    printf '0'
  fi
}

record_invocation() {
  local count
  count="$(current_count)"
  count=$((count + 1))
  printf '%s' "$count" > "$COUNT_FILE"
}

select_proxy_arg() {
  [[ -n "$PROXY_POOL_FILE" && -f "$PROXY_POOL_FILE" ]] || return 0
  mapfile -t proxies < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$PROXY_POOL_FILE")
  [[ "${#proxies[@]}" -gt 0 ]] || return 0
  local count index
  count="$(current_count)"
  index=$((count % ${#proxies[@]}))
  local proxy="${proxies[$index]}"
  if [[ "$proxy" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/@]+@ ]]; then
    printf 'authenticated proxy entries are not supported by Chrome --proxy-server; run scripts/proxy-auth-forwarder.py and use its local URL instead: %s\n' "$proxy" >&2
    return 1
  fi
  printf -- '--proxy-server=%s' "$proxy"
}

managed_chrome_pid_is_valid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  local cmdline
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  [[ "$cmdline" == *google-chrome* && "$cmdline" == *"--user-data-dir=$PROFILE_DIR"* ]]
}

stop_managed_chrome_if_needed() {
  [[ -f "$PID_FILE" ]] || return 0
  local pid
  pid="$(cat "$PID_FILE")"
  if managed_chrome_pid_is_valid "$pid"; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 0.25
    done
  fi
  rm -f "$PID_FILE"
}

restart_if_threshold_reached() {
  [[ "$RESTART_AFTER" =~ ^[0-9]+$ && "$RESTART_AFTER" -gt 0 ]] || return 0
  local count
  count="$(current_count)"
  if [[ "$count" -ge "$RESTART_AFTER" ]]; then
    stop_managed_chrome_if_needed
    printf '0' > "$COUNT_FILE"
  fi
}

start_managed_chrome() {
  mkdir -p "$PROFILE_DIR" "$(dirname "$PID_FILE")" "$(dirname "$COUNT_FILE")"
  local proxy_arg port
  proxy_arg="$(select_proxy_arg)"
  port="$(cdp_port)"
  local chrome_args=(
    --headless=new
    --no-sandbox
    --disable-dev-shm-usage
    --disable-gpu
    --ignore-certificate-errors
    --no-first-run
    --no-default-browser-check
    --remote-debugging-address=127.0.0.1
    --remote-debugging-port="$port"
    --user-data-dir="$PROFILE_DIR"
  )
  if [[ -n "$proxy_arg" ]]; then
    chrome_args+=("$proxy_arg")
  fi
  nohup google-chrome "${chrome_args[@]}" data:, >"$LOG_FILE" 2>&1 &
  printf '%s' "$!" > "$PID_FILE"
  for _ in $(seq 1 60); do
    if cdp_ready; then
      return 0
    fi
    sleep 0.5
  done
  printf 'managed Chrome did not expose CDP at %s; see %s\n' "$DEFAULT_CDP_URL" "$LOG_FILE" >&2
  return 1
}

if [[ "${BU_CDP_URL:-}" == "$DEFAULT_CDP_URL" ]]; then
  record_invocation
  restart_if_threshold_reached
  if ! cdp_ready; then
    start_managed_chrome
  fi
fi

exec "$REAL_BROWSER_HARNESS" "$@"
WRAPPER

python3 - "$BH_WRAPPER_BIN" "$BH_REAL_BIN" "$BH_CDP_URL" "$BH_CHROME_PROFILE" "$BH_CHROME_LOG" "$BH_CHROME_PID" "$BH_INVOCATION_COUNT_FILE" "$BH_RESTART_AFTER" "$BH_PROXY_POOL_FILE" <<'PY'
from pathlib import Path
import sys
path, real_bin, cdp_url, profile, log, pid, count_file, restart_after, proxy_pool_file = map(str, sys.argv[1:])
text = Path(path).read_text()
for key, value in {
    "__BH_REAL_BIN__": real_bin,
    "__BH_CDP_URL__": cdp_url,
    "__BH_CHROME_PROFILE__": profile,
    "__BH_CHROME_LOG__": log,
    "__BH_CHROME_PID__": pid,
    "__BH_INVOCATION_COUNT_FILE__": count_file,
    "__BH_RESTART_AFTER__": restart_after,
    "__BH_PROXY_POOL_FILE__": proxy_pool_file,
}.items():
    text = text.replace(key, value)
Path(path).write_text(text)
PY
chmod +x "$BH_WRAPPER_BIN"

"$BH_WRAPPER_BIN" <<'PY'
print(page_info())
PY
