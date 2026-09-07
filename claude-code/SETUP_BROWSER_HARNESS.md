# Browser Harness Setup Log

Date: 2026-07-05

This environment now has `browser-use/browser-harness` installed, registered as a Codex skill, connected to a working local headless Chrome instance, and backed by an idempotent setup script in this repository.

## Completed installation

1. Read `install.md` from `https://github.com/browser-use/browser-harness`.
2. Cloned the repository to `~/Developer/browser-harness` for a durable local checkout.
3. Installed the current stable CLI with:

   ```bash
   uv tool install --python 3.12 --upgrade --force browser-harness
   uv tool inject browser-harness firecrawl-py tavily-python playwright-stealth camoufox
   ```

4. Injected the requested optional packages into the browser-harness tool environment: `firecrawl-py`, `tavily-python`, `playwright-stealth`, and `camoufox`. The installed `uv` version in this container does not expose `uv tool inject`, so the setup script falls back to the equivalent `uv tool install --with ...` flow when needed.
5. Persisted the Tavily and Firecrawl API keys in `~/.bashrc` for future shells and hoisted those existing exports above Ubuntu’s non-interactive `.bashrc` guard so `source ~/.bashrc` works in scripts too. The actual secret values are intentionally not stored in this repository.
6. Added `playwright` as a local tooling dependency so the requested `uv run playwright install --with-deps` command works directly, then installed Playwright browser dependencies and browser binaries with that exact command.
7. Verified the CLI is available at `/root/.local/bin/browser-harness` and reports version `0.1.4`.
8. Registered the Codex global skill with:

   ```bash
   mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills/browser-harness"
   browser-harness skill > "${CODEX_HOME:-$HOME/.codex}/skills/browser-harness/SKILL.md"
   ```

## Completed browser connection

The default container did not include a running Chrome instance, so the setup uses the documented isolated-browser path:

1. Installed Google Chrome Stable from Google's Linux `.deb` package.
2. Added a local `browser-harness` wrapper at `/root/.local/bin/browser-harness` that:
   - preserves the uv-installed CLI as `/root/.local/bin/browser-harness.uv`,
   - defaults `BU_CDP_URL` to `http://127.0.0.1:9222` when no explicit CDP endpoint is configured,
   - starts headless Google Chrome on port `9222` with an isolated profile at `/tmp/browser-harness-chrome-profile` when needed,
   - ignores certificate errors for this isolated automation browser so the GitHub smoke test is not blocked by the container CA store,
   - passes all arguments and stdin through to the real browser-harness CLI.
3. Verified the exact requested smoke test succeeds:

   ```bash
   browser-harness <<'PY'
   print(page_info())
   PY
   ```

   Example successful output:

   ```text
   {'url': 'data:,', 'title': '', 'w': 780, 'h': 437, 'sx': 0, 'sy': 0, 'pw': 780, 'ph': 437}
   ```

4. Ran the first-time demo from `install.md` by opening the browser-harness GitHub repository in a new tab and printing page info. The harness successfully attached to Chrome and loaded `https://github.com/browser-use/browser-harness`.

## Reproducible setup script

The full setup is captured in `scripts/setup-browser-harness.sh`. It is safe to rerun and performs the same end-to-end work:

1. clones or fast-forwards `~/Developer/browser-harness`,
2. installs or upgrades the `browser-harness` CLI with Python 3.12,
3. injects `firecrawl-py`, `tavily-python`, `playwright-stealth`, and `camoufox` using `uv tool inject` when available or `uv tool install --with ...` on older uv versions,
4. registers the Codex skill from `browser-harness skill`,
5. makes existing Tavily and Firecrawl `.bashrc` exports sourceable in non-interactive shells without storing secret values,
6. installs Google Chrome Stable automatically when running as root on an apt-based system,
7. installs Playwright browser system dependencies and browser binaries,
8. writes the auto-start wrapper,
9. runs `print(page_info())` as the smoke test.

Run it with:

```bash
./scripts/setup-browser-harness.sh
```

## API keys and Playwright

The requested Tavily and Firecrawl API key exports were appended to `~/.bashrc`, hoisted above the default non-interactive-shell return guard, and sourced. To avoid committing secrets, this repository only records that the variables must exist:

```bash
export TAVILY_API_KEY=<redacted>
export FIRECRAWL_API_KEY=<redacted>
```

Playwright, `playwright-stealth`, and `camoufox` are declared in `pyproject.toml` as local tooling dependencies and installed by the setup script with the requested command:

```bash
uv run playwright install --with-deps
```

## Workspace inventory checked

The browser-harness checkout includes the agent workspace and packaged skill files expected by the install docs:

- `~/Developer/browser-harness/agent-workspace/agent_helpers.py`
- `~/Developer/browser-harness/agent-workspace/domain-skills/` with 97 domain directories and 109 files
- `~/Developer/browser-harness/skills/browser-harness/SKILL.md`
- `~/Developer/browser-harness/skills/browser-harness/references/install.md`

I used `find` rather than `ls -R` for the recursive inventory because this repository's environment guidelines explicitly avoid `ls -R` in large trees.

## Useful commands

Re-run the connection smoke test:

```bash
browser-harness <<'PY'
print(page_info())
PY
```

Open the browser-harness demo page again:

```bash
browser-harness <<'PY'
new_tab('https://github.com/browser-use/browser-harness')
wait_for_load()
print(page_info())
PY
```

Run diagnostics:

```bash
browser-harness --doctor
```

## Stealth and production hardening

The setup intentionally installs two stealth-capable packages, but they do **not** sit at the same layer:

- `playwright-stealth` is the default companion for the current browser-harness model because Playwright can attach to the same Chromium instance over CDP with `chromium.connect_over_cdp("http://127.0.0.1:9222")`, then apply stealth init scripts to pages/contexts opened from that attachment. Upstream browser-harness describes its architecture as one WebSocket to Chrome, so this is the compatible layer for the existing Chrome/CDP path.
- `camoufox` is a separate hardened Firefox-family engine with its own Playwright-compatible remote server path. It is not a transparent replacement for Chrome's CDP endpoint on port `9222`; use it as an escape hatch when Chromium plus `playwright-stealth` is not enough.

### Default CDP stealth helper

Use this pattern when a task needs Playwright-level stealth while staying attached to the browser-harness-managed Chrome instance:

```python
from playwright.sync_api import sync_playwright
from playwright_stealth import Stealth

with sync_playwright() as p:
    browser = p.chromium.connect_over_cdp("http://127.0.0.1:9222")
    context = browser.contexts[0] if browser.contexts else browser.new_context()
    page = context.new_page()
    Stealth().apply_stealth_sync(page)
    page.goto("https://example.com")
```

Operational rule: apply `Stealth().apply_stealth_sync(page)` immediately after creating a Playwright page and before navigation. The shell wrapper can guarantee that Chrome is alive and reachable over CDP, but page-level stealth still belongs in the page/context creation path because browser-harness itself is the process creating tabs.

### Camoufox escape-hatch path

Use Camoufox separately when target defenses require engine-level Firefox fingerprint hardening:

```bash
python3 -m camoufox server
```

The server prints a Playwright-compatible WebSocket endpoint. Connect to that endpoint from a dedicated Camoufox workflow rather than trying to route it through Chrome's CDP port `9222`.

### Recommended routing rule

| Scenario | Route |
|---|---|
| Standard browser-harness CDP session | Chrome on `BU_CDP_URL`, optionally patched with `playwright-stealth` at page creation |
| Target defeats Chromium plus `playwright-stealth` | Dedicated Camoufox server/session |
| Agent-Reach social/data lookup | Agent-Reach lightweight fetchers; no browser-rendering stealth layer |
| Authenticated desktop workflow or visual/manual simulation | browser-harness attached to the user's real Chrome profile |

### Proxy pool support

The wrapper now supports a simple proxy pool for the managed headless Chrome process. Put one proxy per line in a file, with blank lines and `#` comments allowed:

```text
http://user:pass@residential-proxy-1.example:8080
socks5://user:pass@residential-proxy-2.example:1080
```

Then run the setup with:

```bash
BH_PROXY_POOL_FILE=/path/to/proxies.txt ./scripts/setup-browser-harness.sh
```

The generated wrapper passes the selected proxy to Chrome with `--proxy-server=...` when it launches the managed browser. For authenticated or long-lived accounts, prefer sticky residential sessions so the browser profile, cookies, and GeoIP stay consistent for the duration of that session. Do not rotate IPs in the middle of a logged-in workflow unless the account and target site tolerate it.

### Memory and lifecycle guardrails

Long-running browser automation tends to leak state through open pages, contexts, caches, and the browser process itself. The wrapper now keeps a managed-browser PID file and an invocation counter. When the count reaches `BH_RESTART_AFTER` (default `50`), it stops only the Chrome process it launched, resets the counter, and starts a fresh managed Chrome on the next invocation.

Override the threshold when needed:

```bash
BH_RESTART_AFTER=25 ./scripts/setup-browser-harness.sh
```

This restart policy intentionally applies only to the wrapper-managed headless Chrome. If you set `BU_CDP_URL` or `BU_CDP_WS` to attach to your own desktop browser, the wrapper will not kill that browser.

### Cloudflare/Turnstile handling pattern

Treat challenge pages as a routing signal, not something to brute-force in a tight retry loop. Watch for any combination of:

- `cf-mitigated` response headers,
- Turnstile iframe URLs or challenge containers,
- repeated 403/503 challenge responses after a previously healthy session,
- sudden login/session invalidation after an IP or fingerprint change.

On detection, close the current page/context, preserve debug artifacts, and escalate in this order:

1. retry once with a fresh Chrome context plus `playwright-stealth`,
2. retry with a sticky residential proxy that matches the account/session geography,
3. escalate to a separate Camoufox session if Chromium remains blocked,
4. use browser-harness attached to a real, authenticated desktop profile when manual continuity is required.

### Container deployment pattern

For scalable deployment, bake the setup output into an image instead of installing tools at container start:

1. install Chrome, Python 3.12, `uv`, Playwright browsers, and browser-harness at image build time,
2. register the browser-harness skill and injected packages during build,
3. run one browser process per container with its own isolated profile directory,
4. expose CDP only on the container's private network,
5. persist screenshots, HTML dumps, logs, and wrapper PID/counter files outside the ephemeral container filesystem,
6. scale horizontally with more containers rather than sharing one browser process across unrelated jobs.

A minimal Dockerfile should call `./scripts/setup-browser-harness.sh` during build only after package prerequisites are present, then use the generated wrapper as the container entrypoint or health-check target.

## Production playbook helpers

This repository now includes two operational helper scripts so the playbook is executable rather than only descriptive:

- `scripts/browser-harness-healthcheck.sh` checks the active CDP endpoint at `/json/version`, validates the managed Chrome PID when present, and confirms the response includes the expected DevTools fields.
- `scripts/browser-harness-playwright-session.py` bootstraps the browser-harness wrapper when CDP is not yet reachable, attaches to browser-harness Chrome over CDP, optionally applies `playwright-stealth`, loads and saves Playwright `storage_state`, supports a proxy per Playwright context, detects obvious Cloudflare/Turnstile challenge signals, and writes HTML/screenshot artifacts for crash forensics.

### Session persistence automation

Playwright `storage_state` captures reusable authenticated browser state such as cookies and localStorage, and newer Playwright releases can also include IndexedDB state. Use the helper to save state after a successful login workflow:

```bash
uv run python scripts/browser-harness-playwright-session.py \
  --url https://target.example/dashboard \
  --save-storage-state .browser-state/target-auth.json \
  --artifact-dir .browser-artifacts/login-refresh
```

Reuse that state on later runs:

```bash
uv run python scripts/browser-harness-playwright-session.py \
  --url https://target.example/dashboard \
  --storage-state .browser-state/target-auth.json \
  --artifact-dir .browser-artifacts/dashboard-check
```

Keep these files out of Git because storage-state JSON can contain live cookies or tokens. For sites that rely on sessionStorage instead of cookies/localStorage/IndexedDB, add a site-specific pre-navigation restore step and post-navigation snapshot step in the helper before treating the state file as complete.

### Context-level residential proxy rotation

For CDP-attached Playwright helper sessions, use context-level proxies from a pool file:

```text
# proxies.txt
http://user:pass@res-proxy-1.example:8080
{"server":"http://res-proxy-2.example:8080","username":"user","password":"pass"}
```

Run one context with a selected proxy:

```bash
uv run python scripts/browser-harness-playwright-session.py \
  --url https://target.example \
  --proxy-pool-file proxies.txt \
  --proxy-index 0 \
  --storage-state .browser-state/target-auth.json
```

Use one sticky proxy for the entire authenticated session. Rotate only between sessions or accounts; rapid mid-session IP churn is a strong anomaly signal for fraud and bot defenses.

### Cloudflare/Turnstile escalation flow

The helper exits with code `42` when it detects challenge indicators such as `cf-mitigated`, challenge-like 403/429/503 statuses, Turnstile markup, or Cloudflare challenge frames. Supervisors should treat that code as a routing signal:

1. preserve the helper artifacts,
2. retry once with a fresh Chrome context plus `playwright-stealth`,
3. retry with the same storage state and a sticky residential proxy matching the session geography,
4. escalate to a separate Camoufox server/session when Chromium remains challenged,
5. use a real desktop Chrome profile through browser-harness when the workflow requires manual continuity.

Do not hammer the same challenged page/context in a tight loop; that converts a recoverable fingerprint or IP-reputation event into a stronger block signal.

### Monitoring and auto-restart

Use the healthcheck in local supervisors, Docker Compose, Kubernetes liveness probes, or cron-style watchdogs:

```bash
scripts/browser-harness-healthcheck.sh
```

The wrapper already recycles managed Chrome after `BH_RESTART_AFTER` invocations, while the healthcheck covers the external supervisor layer: it verifies CDP responsiveness and catches stale managed-browser PID files. A container deployment should wire this command into the orchestrator healthcheck and let the orchestrator replace the whole container if CDP stops responding.

### Debug artifacts and crash forensics

Always pass `--artifact-dir` for long-lived or production runs. The helper writes both HTML and full-page screenshots, which should be persisted to external storage in containerized deployments before the container is recycled. Pair artifacts with storage-state snapshots so that a failed run can be replayed against the same session state instead of starting from a blank browser.

## Enterprise anti-bot routing beyond Cloudflare

Use this section only for authorized monitoring, testing, and collection workflows. Cloudflare is not the only enterprise anti-bot system that matters at scale; the practical routing rule is to treat each vendor as a different fingerprint-coherence problem rather than assuming one stealth setting will fit all targets.

| Vendor | Dominant signals to watch | Recommended route |
|---|---|---|
| DataDome | Behavioral fingerprinting, browser fingerprint consistency, IP reputation | Prefer persistent profiles, sticky residential/mobile proxies, and Camoufox-class engine-level fingerprinting for high-friction targets. |
| PerimeterX / HUMAN | Short-lived `_px` token family, behavioral enforcement after valuable actions, browser and network coherence | Reuse stable profile/proxy pairs, refresh sessions before token expiry, and preserve artifacts when token refresh starts failing. |
| Akamai | TLS/JA-family network fingerprinting plus browser fingerprinting | Prefer mobile/4G/5G or high-quality residential egress with consistent device identity; do not rely on JS stealth alone. |
| Kasada | Client-side integrity checks, dynamic challenge scripts, request sequencing | Escalate to persistent browser profiles and engine-level fingerprinting; avoid replay-only HTTP clients for protected flows. |
| Imperva Incapsula | IP reputation, device fingerprinting, session reputation, challenge pages | Keep proxy/profile/account triples stable and alert on challenge redirects rather than tight-loop retries. |

The practical hierarchy for this stack is:

1. **Agent-Reach** for read-only social/listening fetches that do not require browser rendering.
2. **browser-harness + Chrome/CDP + playwright-stealth** for standard browser automation.
3. **persistent profile + sticky proxy** when the target tracks login/session continuity.
4. **Camoufox standalone session** when engine-level fingerprinting is required.
5. **manual desktop Chrome profile attached through browser-harness** when the workflow needs authenticated human continuity.

## Playwright versus Puppeteer memory posture

Do not switch this stack to Puppeteer just for memory. Puppeteer can be leaner for a single Chromium-only task, but this project already depends on Playwright-compatible features: `playwright-stealth`, Camoufox's Playwright-compatible server workflow, context-level proxy configuration, storage-state handling, and cross-browser operational tooling.

The real memory failure mode is unclosed browser state. For either framework:

- close every page/context explicitly,
- cap work per browser process,
- recycle the browser after a fixed threshold,
- use one container/browser profile per worker identity,
- persist artifacts before restart.

The wrapper's `BH_RESTART_AFTER` counter and the helper's explicit `context.close()` implement the framework-agnostic fix rather than changing libraries.

## Persistent browser profiles

`storage_state` is lightweight and portable, but a persistent profile directory is stronger for long-running authenticated monitors because it preserves the browser identity as a whole. The Playwright helper supports this directly with `--persistent-profile-dir`:

```bash
uv run python scripts/browser-harness-playwright-session.py \
  --persistent-profile-dir browser-profiles/session_1 \
  --headed \
  --url https://target.example/login \
  --artifact-dir .browser-artifacts/session_1-login
```

After the first manual or scripted login, reuse the same profile headlessly:

```bash
uv run python scripts/browser-harness-playwright-session.py \
  --persistent-profile-dir browser-profiles/session_1 \
  --headless \
  --url https://target.example/dashboard \
  --artifact-dir .browser-artifacts/session_1-dashboard
```

Pair each durable identity with its own profile directory and sticky proxy:

```text
proxy_profile=session_1
user_data_dir=browser-profiles/session_1
proxy=http://127.0.0.1:8899
```

Do not reuse one profile across unrelated proxies or accounts. That creates exactly the identity/GeoIP mismatch that enterprise bot systems flag. The repository `.gitignore` excludes `.browser-state/`, `.browser-artifacts/`, and `browser-profiles/` because those directories can contain live session material.

## Proxy authentication for Chrome/CDP

Chrome's `--proxy-server` launch flag is appropriate for unauthenticated proxies, but authenticated upstream residential proxies are safer through one of these two paths:

1. **Playwright context proxy auth** for helper-created contexts:

   ```bash
   uv run python scripts/browser-harness-playwright-session.py \
     --proxy-pool-file proxies.jsonl \
     --proxy-index 0 \
     --url https://target.example
   ```

   with a JSON-line proxy entry:

   ```json
   {"server":"http://proxy-host:8080","username":"user1","password":"pass1"}
   ```

2. **Local unauthenticated forwarding proxy** for Chrome launch/CDP workflows. Start the forwarder with upstream credentials:

   ```bash
   uv run python scripts/proxy-auth-forwarder.py \
     --listen-host 127.0.0.1 \
     --listen-port 8899 \
     --upstream http://user1:pass1@proxy-host:8080
   ```

   Then point the wrapper-managed Chrome at the local proxy:

   ```bash
   printf 'http://127.0.0.1:8899\n' > /tmp/browser-harness-local-proxy.txt
   BH_PROXY_POOL_FILE=/tmp/browser-harness-local-proxy.txt ./scripts/setup-browser-harness.sh
   ```

This keeps credentials out of Chrome command-line arguments and avoids headless proxy-auth prompts while preserving the existing browser-harness CDP model.

## Container image

`Dockerfile.browser-harness` bakes the production setup into an image using the official Playwright Python base image, installs `uv`, syncs the locked tooling environment, runs the browser-harness setup at build time, and wires `scripts/browser-harness-healthcheck.sh` into the Docker `HEALTHCHECK`.

Build and run locally with:

```bash
docker build -f Dockerfile.browser-harness -t browser-harness-stack .
docker run --rm browser-harness-stack
```

For scale-out deployments, keep the same identity rule as local runs: one container equals one browser process, one isolated profile, and one stable proxy identity. Persist `.browser-artifacts/`, `.browser-state/`, and browser profile volumes to durable storage if you need post-crash replay or auditability.

## Production readiness verification status

Two checks are intentionally separated from the sandbox setup because they require host capabilities this container may not have:

1. **Docker image build/run** — this repository includes `Dockerfile.browser-harness`, but a passing `docker build` requires Docker on the host. The sandbox used for setup may not include Docker, so treat the image as unverified until it is built and smoke-tested on a Docker-capable Linux machine.
2. **Real desktop Chrome CDP attachment** — successful sandbox smoke tests use the wrapper-managed isolated headless Chrome profile. That proves browser-harness can control Chrome through CDP, but it does **not** prove attachment to the user's real authenticated desktop browser profile.

Run the production verifier:

```bash
./scripts/verify-browser-harness-production.sh
```

On a Docker-capable host, build and smoke-run the image too:

```bash
BH_VERIFY_DOCKER_BUILD=1 ./scripts/verify-browser-harness-production.sh
```

To verify a real desktop Chrome session, start Chrome on the host machine with remote debugging and a durable profile:

```bash
google-chrome --remote-debugging-port=9222 --user-data-dir=$HOME/.browser-harness-profile
```

Then run:

```bash
BH_DESKTOP_CDP_URL=http://127.0.0.1:9222 ./scripts/verify-browser-harness-production.sh
```

If the wrapper-managed Chrome PID is still alive on the same `127.0.0.1:9222` endpoint, the verifier warns instead of falsely claiming desktop-profile coverage. Stop the managed Chrome or use a different `BH_DESKTOP_CDP_URL` before treating this as a real-browser attach test.
