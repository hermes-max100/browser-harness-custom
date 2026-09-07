#!/usr/bin/env python3
"""Local unauthenticated proxy that forwards through an authenticated upstream proxy.

Chrome's --proxy-server flag can point at this local listener without embedding
credentials. The forwarder adds Proxy-Authorization when connecting to the
upstream residential/mobile proxy.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import signal
from urllib.parse import unquote, urlparse


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


class ProxyForwarder:
    def __init__(self, upstream: str) -> None:
        parsed = urlparse(upstream)
        if parsed.scheme not in {"http", "https"}:
            raise ValueError("upstream must be an http(s) proxy URL")
        if not parsed.hostname:
            raise ValueError("upstream proxy URL must include a host")
        self.upstream_host = parsed.hostname
        self.upstream_port = parsed.port or (443 if parsed.scheme == "https" else 80)
        self.upstream_tls = parsed.scheme == "https"
        self.auth_header = None
        if parsed.username is not None:
            username = unquote(parsed.username or "")
            password = unquote(parsed.password or "")
            token = base64.b64encode(f"{username}:{password}".encode()).decode()
            self.auth_header = f"Proxy-Authorization: Basic {token}\r\n"

    async def handle(self, client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
        try:
            request_head = await client_reader.readuntil(b"\r\n\r\n")
        except asyncio.IncompleteReadError:
            client_writer.close()
            await client_writer.wait_closed()
            return

        upstream_reader, upstream_writer = await asyncio.open_connection(
            self.upstream_host,
            self.upstream_port,
            ssl=self.upstream_tls,
        )
        head = request_head.decode("iso-8859-1")
        if self.auth_header and "\r\nProxy-Authorization:" not in head:
            head = head.replace("\r\n\r\n", f"\r\n{self.auth_header}\r\n", 1)
        upstream_writer.write(head.encode("iso-8859-1"))
        await upstream_writer.drain()

        await asyncio.gather(
            pipe(client_reader, upstream_writer),
            pipe(upstream_reader, client_writer),
        )


async def amain() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=8899)
    parser.add_argument("--upstream", required=True, help="Authenticated upstream proxy URL, e.g. http://user:pass@host:8080")
    args = parser.parse_args()

    forwarder = ProxyForwarder(args.upstream)
    server = await asyncio.start_server(forwarder.handle, args.listen_host, args.listen_port)
    sockets = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    print(f"proxy-auth-forwarder listening on {sockets}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(signum, stop.set)
    async with server:
        await stop.wait()


def main() -> None:
    asyncio.run(amain())


if __name__ == "__main__":
    main()
