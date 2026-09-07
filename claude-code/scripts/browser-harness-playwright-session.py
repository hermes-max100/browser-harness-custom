#!/usr/bin/env python3
"""Playwright/CDP helper for browser-harness production sessions.

This helper attaches to the Chrome instance managed by browser-harness, optionally
applies playwright-stealth, loads/saves Playwright storage_state, supports one
proxy per context, detects obvious Cloudflare Turnstile/challenge signals, and
persists debug artifacts for supervised restarts.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from urllib.parse import unquote, urlparse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from playwright.sync_api import Browser, BrowserContext, Page, Response, TimeoutError, sync_playwright
from playwright_stealth import Stealth

TURNSTILE_PATTERNS = (
    "cf-turnstile",
    "challenges.cloudflare.com",
    "turnstile",
    "cf-challenge",
    "cf_clearance",
)


@dataclass(frozen=True)
class ProxyConfig:
    server: str
    username: str | None = None
    password: str | None = None
    bypass: str | None = None

    def as_playwright(self) -> dict[str, str]:
        data = {"server": self.server}
        if self.username:
            data["username"] = self.username
        if self.password:
            data["password"] = self.password
        if self.bypass:
            data["bypass"] = self.bypass
        return data


def parse_proxy_line(line: str) -> ProxyConfig:
    line = line.strip()
    if not line:
        raise ValueError("empty proxy line")
    if line.startswith("{"):
        data = json.loads(line)
        return ProxyConfig(
            server=data["server"],
            username=data.get("username"),
            password=data.get("password"),
            bypass=data.get("bypass"),
        )
    parsed = urlparse(line)
    if parsed.scheme and parsed.hostname:
        netloc = parsed.hostname
        if parsed.port:
            netloc = f"{netloc}:{parsed.port}"
        server = f"{parsed.scheme}://{netloc}"
        return ProxyConfig(
            server=server,
            username=unquote(parsed.username) if parsed.username is not None else None,
            password=unquote(parsed.password) if parsed.password is not None else None,
        )
    return ProxyConfig(server=line)


def load_proxy(proxy_pool_file: str | None, proxy_index: int) -> ProxyConfig | None:
    if not proxy_pool_file:
        return None
    path = Path(proxy_pool_file)
    lines = [line.strip() for line in path.read_text().splitlines()]
    entries = [line for line in lines if line and not line.startswith("#")]
    if not entries:
        raise ValueError(f"proxy pool is empty: {path}")
    return parse_proxy_line(entries[proxy_index % len(entries)])


def context_options(args: argparse.Namespace) -> dict[str, Any]:
    options: dict[str, Any] = {}
    if args.storage_state and Path(args.storage_state).exists():
        options["storage_state"] = args.storage_state
    proxy = load_proxy(args.proxy_pool_file, args.proxy_index)
    if proxy:
        options["proxy"] = proxy.as_playwright()
    return options


def detect_turnstile(page: Page, response: Response | None) -> list[str]:
    signals: list[str] = []
    if response:
        headers = {key.lower(): value for key, value in response.headers.items()}
        if "cf-mitigated" in headers:
            signals.append("cf-mitigated response header")
        status = response.status
        if status in {403, 429, 503}:
            signals.append(f"challenge-like HTTP status {status}")
    html = page.content().lower()
    for pattern in TURNSTILE_PATTERNS:
        if pattern in html:
            signals.append(f"page contains {pattern}")
    frames = [frame.url.lower() for frame in page.frames]
    if any("challenges.cloudflare.com" in url for url in frames):
        signals.append("Cloudflare challenge iframe present")
    return sorted(set(signals))


def write_artifacts(page: Page, artifact_dir: str | None, prefix: str) -> None:
    if not artifact_dir:
        return
    path = Path(artifact_dir)
    path.mkdir(parents=True, exist_ok=True)
    safe_prefix = re.sub(r"[^A-Za-z0-9_.-]+", "-", prefix).strip("-") or "page"
    (path / f"{safe_prefix}.html").write_text(page.content(), encoding="utf-8")
    page.screenshot(path=str(path / f"{safe_prefix}.png"), full_page=True)


def open_context(browser: Browser, args: argparse.Namespace) -> BrowserContext:
    return browser.new_context(**context_options(args))


def persistent_context_options(args: argparse.Namespace) -> dict[str, Any]:
    options: dict[str, Any] = {
        "headless": args.headless,
        "timeout": args.timeout_ms,
    }
    proxy = load_proxy(args.proxy_pool_file, args.proxy_index)
    if proxy:
        options["proxy"] = proxy.as_playwright()
    return options


def cdp_is_ready(cdp_url: str, timeout: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(f"{cdp_url.rstrip('/')}/json/version", timeout=timeout) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def ensure_cdp(cdp_url: str) -> None:
    if cdp_is_ready(cdp_url):
        return
    env = os.environ.copy()
    env["BU_CDP_URL"] = cdp_url
    subprocess.run(
        ["browser-harness"],
        input="print(page_info())\n",
        text=True,
        check=True,
        stdout=subprocess.DEVNULL,
        env=env,
    )
    if not cdp_is_ready(cdp_url):
        raise RuntimeError(f"CDP endpoint is still unavailable after browser-harness bootstrap: {cdp_url}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cdp-url", default="http://127.0.0.1:9222")
    parser.add_argument("--url", default="data:text/html,<title>browser-harness-session</title><h1>ok</h1>")
    parser.add_argument("--storage-state", help="Load storage state from this JSON path when it exists.")
    parser.add_argument("--save-storage-state", help="Persist storage state to this JSON path after navigation.")
    parser.add_argument("--proxy-pool-file", help="Proxy pool file; supports URL lines or JSON objects with server/user/pass.")
    parser.add_argument("--proxy-index", type=int, default=0)
    parser.add_argument("--artifact-dir", help="Write HTML and PNG debug artifacts to this directory.")
    parser.add_argument("--artifact-prefix", default="browser-harness-session")
    parser.add_argument("--timeout-ms", type=int, default=30000)
    parser.add_argument("--stealth", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--detect-turnstile", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--ensure-cdp", action=argparse.BooleanOptionalAction, default=True, help="Bootstrap the browser-harness wrapper when CDP is not yet reachable.")
    parser.add_argument("--persistent-profile-dir", help="Use Playwright launch_persistent_context with this user-data directory instead of CDP attach.")
    parser.add_argument("--headless", action=argparse.BooleanOptionalAction, default=True, help="Headless mode for --persistent-profile-dir sessions.")
    parser.add_argument("--headed", dest="headless", action="store_false", help="Alias for --no-headless during first-login profile capture.")
    args = parser.parse_args()

    if args.persistent_profile_dir and args.storage_state:
        raise SystemExit("--persistent-profile-dir and --storage-state are mutually exclusive; the profile directory already owns session state")

    if args.ensure_cdp and not args.persistent_profile_dir:
        ensure_cdp(args.cdp_url)

    with sync_playwright() as p:
        if args.persistent_profile_dir:
            Path(args.persistent_profile_dir).mkdir(parents=True, exist_ok=True)
            context = p.chromium.launch_persistent_context(
                args.persistent_profile_dir,
                **persistent_context_options(args),
            )
        else:
            browser = p.chromium.connect_over_cdp(args.cdp_url, timeout=args.timeout_ms)
            context = open_context(browser, args)
        page = context.new_page()
        if args.stealth:
            Stealth().apply_stealth_sync(page)
        try:
            response = page.goto(args.url, wait_until="domcontentloaded", timeout=args.timeout_ms)
            page.wait_for_load_state("networkidle", timeout=min(args.timeout_ms, 10000))
        except TimeoutError:
            response = None
        signals = detect_turnstile(page, response) if args.detect_turnstile else []
        write_artifacts(page, args.artifact_dir, args.artifact_prefix)
        if args.save_storage_state:
            Path(args.save_storage_state).parent.mkdir(parents=True, exist_ok=True)
            context.storage_state(path=args.save_storage_state)
        summary = {
            "url": page.url,
            "title": page.title(),
            "turnstile_signals": signals,
            "storage_state_saved": bool(args.save_storage_state),
            "persistent_profile_dir": args.persistent_profile_dir,
            "artifacts_dir": args.artifact_dir,
        }
        print(json.dumps(summary, indent=2, sort_keys=True))
        context.close()
        return 42 if signals else 0


if __name__ == "__main__":
    raise SystemExit(main())
