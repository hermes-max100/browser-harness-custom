# Browser Harness Custom

A production-oriented browser automation stack built around [browser-use/browser-harness](https://github.com/browser-use/browser-harness), Chrome DevTools Protocol (CDP), and Playwright.

This repository packages the custom integration layer used to turn Browser Harness into a reproducible, persistent browser-control environment for coding agents such as Codex. It adds automated Chrome lifecycle management, Playwright/CDP sessions, health checks, session persistence, proxy support, diagnostics, container deployment, and production verification.

## What This Adds

- **Direct CDP browser control** through Browser Harness.
- **Automatic Chrome bootstrap** on `127.0.0.1:9222` using an isolated browser profile.
- **Global Codex skill** for browser automation and browser-based agent tasks.
- **Playwright/CDP integration** for richer browser workflows.
- **Optional `playwright-stealth` integration** for compatibility testing and automation reliability.
- **Persistent browser state** using Playwright `storage_state` or persistent profiles.
- **Proxy pool support**, including an authenticated upstream proxy forwarder.
- **Browser lifecycle controls** with configurable managed-Chrome restart thresholds.
- **Cloudflare/Turnstile detection** so challenge pages can be surfaced rather than blindly retried.
- **Debug artifacts** including screenshots and HTML captures.
- **Health checks and production verification** scripts.
- **Docker deployment pattern** for isolated browser workers.
- **Reproducible installation** through an idempotent setup script.

## Repository Layout

```text
.
├── claude-code/
│   ├── Dockerfile.browser-harness
│   ├── SETUP_BROWSER_HARNESS.md
│   └── scripts/
│       ├── setup-browser-harness.sh
│       ├── browser-harness-healthcheck.sh
│       ├── browser-harness-playwright-session.py
│       ├── proxy-auth-forwarder.py
│       └── verify-browser-harness-production.sh
├── codex-skill/
│   └── SKILL.md
├── browser-harness-upstream/
│   ├── src/
│   ├── README.md
│   ├── install.md
│   ├── SKILL.md
│   └── pyproject.toml
├── provenance/
│   ├── SHA256SUMS
│   ├── claude-code-git.txt
│   └── upstream-git.txt
└── RECOVERY_MANIFEST.txt
```

## Architecture

```text
Coding Agent / Codex
        |
        v
Browser Harness skill
        |
        v
browser-harness CLI
        |
        v
Chrome DevTools Protocol
        |
        +----> Managed Chrome / Chromium
        |          127.0.0.1:9222
        |
        +----> Existing external Chrome CDP endpoint
        |
        +----> Playwright CDP session
                    |
                    +--> storage state
                    +--> screenshots / HTML artifacts
                    +--> proxy context
                    +--> challenge detection
```

## Quick Start

The full installation procedure is documented in [`claude-code/SETUP_BROWSER_HARNESS.md`](claude-code/SETUP_BROWSER_HARNESS.md).

On a compatible Linux environment:

```bash
cd claude-code
chmod +x scripts/*.sh
./scripts/setup-browser-harness.sh
```

Then test the Browser Harness connection:

```bash
browser-harness <<PY
print(page_info())
PY
```

Run diagnostics:

```bash
browser-harness --doctor
```

Run the health check:

```bash
./claude-code/scripts/browser-harness-healthcheck.sh
```

## Browser Session Helper

The Playwright helper can attach to the Browser Harness-managed Chrome instance and capture debugging artifacts:

```bash
uv run python claude-code/scripts/browser-harness-playwright-session.py \
  --url https://example.com \
  --artifact-dir .browser-artifacts/example
```

It can also load or save Playwright browser state for authorized sessions. Treat storage-state files as credentials: keep them out of Git and never publish them.

## Codex Skill

The recovered global Codex skill is included at:

```text
codex-skill/SKILL.md
```

A typical global installation location is:

```text
${CODEX_HOME:-$HOME/.codex}/skills/browser-harness/SKILL.md
```

## Security

This public repository intentionally excludes live credentials, cookies, API-key values, Playwright storage-state files, and browser authentication material.

Use this project only with browsers, accounts, applications, and infrastructure you own or are authorized to automate. Challenge detection and browser compatibility features are intended for legitimate automation/testing workflows, not for defeating access controls.

Before committing changes, scan for secrets and ensure browser-state artifacts remain excluded.

## Provenance

The custom integration was developed as a layer around the upstream Browser Harness project. The recovery snapshot preserves Git provenance and SHA-256 checksums under [`provenance/`](provenance/).

Custom integration history recovered from the original development repository includes:

```text
f57d06b  Make browser-harness setup fully reproducible
e0b040c  Harden browser-harness stealth and lifecycle setup
9cd9b1b  Add browser-harness production playbook helpers
de0e908  Expand browser-harness production hardening
2f4923c  Add production verification checklist
4741cde  Address browser harness review feedback
```

## Upstream

Browser Harness is based on the open-source [`browser-use/browser-harness`](https://github.com/browser-use/browser-harness) project. Review the upstream repository and its license for the underlying Browser Harness implementation.

This repository contains additional integration, deployment, operational, and recovery material layered around that upstream project.

## License

Upstream Browser Harness files retain their applicable upstream licensing. Review [`browser-harness-upstream/`](browser-harness-upstream/) and the upstream project before redistributing or incorporating those components into another project.
