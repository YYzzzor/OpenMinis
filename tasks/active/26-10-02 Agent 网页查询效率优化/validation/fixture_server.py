#!/usr/bin/env python3
"""Bounded, loopback-only fixtures for the web-read validation matrix.

This server has no production credentials, RPC cache, arbitrary file route, or
external binding mode. Request paths are matched against a fixed route table.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
MAX_THREADS = 8
DEFAULT_MAX_RESPONSE_BYTES = 1024 * 1024
MAX_DELAY_MS = 5000
TEST_COOKIE = "fixture_auth=TEST-COOKIE-7F91"
PRIVATE_MARKER = b"PRIVATE-MARKER-A7C4"

PDF_FILES = {
    "/pdf/text": ("multipage-table.pdf", "application/pdf"),
    "/pdf/scanned": ("scanned-only.pdf", "application/pdf"),
    "/pdf/encrypted": ("encrypted.pdf", "application/pdf"),
    "/pdf/corrupt": ("corrupt.pdf", "application/pdf"),
    "/pdf/large": ("large.pdf", "application/pdf"),
    "/pdf/wrong-mime": ("multipage-table.pdf", "text/html; charset=utf-8"),
}
IMAGE_FILES = {
    "/images/direct.png": ("price-table.png", "image/png"),
    "/images/direct.jpg": ("price-table.jpg", "image/jpeg"),
    "/images/assets/price-table.png": ("price-table.png", "image/png"),
    "/images/assets/sales-chart.png": ("sales-chart.png", "image/png"),
    "/images/assets/misleading-alt.png": ("misleading-alt.png", "image/png"),
    "/images/assets/multipage.pdf": ("multipage-table.pdf", "application/pdf"),
}


def _esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _long_html() -> bytes:
    sections = []
    filler = "Fixed ASCII body text crosses formatter limits while preserving paragraph boundaries. "
    for index in range(1, 401):
        sections.append(f"<p>Long body paragraph {index:03d}: STATIC-BODY-{index:03d}-174B. {filler}</p>")
    sections.append(
        '<table><thead><tr><th>Plan</th><th>Price</th></tr></thead>'
        '<tbody><tr><td>Basic</td><td>39</td></tr><tr><td>Pro</td><td>99</td></tr></tbody></table>'
    )
    sections.append("<pre><code>def fixture_<span>value</span>():\n    return 'CODE-END-MARKER-513E'</code></pre>")
    sections.append('<p><a href="/long/public.md">Public Markdown alternative</a></p>')
    sections.append("<p>END-READ-<em>MARKER</em>-90631</p>")
    return ("<!doctype html><html><head><meta charset=utf-8><title>Long fixture</title></head><body><header>FIXTURE-HEADER-NOISE</header><nav>FIXTURE-NAV-NOISE</nav><main>" + "".join(sections) + "</main><footer>FIXTURE-FOOTER-NOISE</footer></body></html>").encode("ascii")


LONG_HTML = _long_html()
LONG_MARKDOWN = (
    "# Public Markdown alternative\n\n"
    "This is a public same-origin excerpt, not a complete copy of the long HTML body.\n\n"
    "| Plan | Monthly price |\n| --- | ---: |\n| Basic | 39 |\n| Pro | 99 |\n\n"
    "```python\n"
    "def fixture_value():\n"
    "    return 'CODE-END-MARKER-513E'\n"
    "```\n\n"
    "MARKDOWN-EXCERPT-END-4C2D\n"
).encode("ascii")


def _page(title: str, body: str, *, lang: str = "en") -> bytes:
    return (
        f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">'
        f"<title>{_esc(title)}</title></head><body>{body}</body></html>"
    ).encode("utf-8")


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    request_queue_size = 16

    def __init__(self, address: tuple[str, int], handler: type[BaseHTTPRequestHandler], *, max_threads: int, max_response_bytes: int, connection_timeout_seconds: float = 2.0):
        super().__init__(address, handler)
        self.max_threads = max_threads
        self.max_response_bytes = max_response_bytes
        self.connection_timeout_seconds = connection_timeout_seconds
        self.timeout = connection_timeout_seconds
        self._slots = threading.BoundedSemaphore(max_threads)
        self.closing_event = threading.Event()
        self._counter_lock = threading.Lock()
        self._active_sockets: set[socket.socket] = set()
        self.active_requests = 0
        self.peak_requests = 0

    def process_request(self, request: socket.socket, client_address: tuple[str, int]) -> None:
        if not self._slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            request.settimeout(self.connection_timeout_seconds)
        except OSError:
            self._slots.release()
            self.shutdown_request(request)
            return
        with self._counter_lock:
            self.active_requests += 1
            self.peak_requests = max(self.peak_requests, self.active_requests)
            self._active_sockets.add(request)
        try:
            super().process_request(request, client_address)
        except BaseException:
            with self._counter_lock:
                self.active_requests -= 1
                self._active_sockets.discard(request)
            self._slots.release()
            raise

    def process_request_thread(self, request: socket.socket, client_address: tuple[str, int]) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self._counter_lock:
                self.active_requests -= 1
                self._active_sockets.discard(request)
            self._slots.release()

    def handle_error(self, _request: socket.socket, _client_address: tuple[str, int]) -> None:
        # Client disconnects and forced shutdown are expected stimuli; never log request data.
        return

    def bounded_shutdown(self, timeout: float = 2.0) -> bool:
        """Stop accepting, close accepted sockets, then wait for bounded cleanup."""
        deadline = time.monotonic() + timeout
        self.closing_event.set()
        stop_thread = threading.Thread(target=self.shutdown, name="fixture-stop-accepting", daemon=True)
        stop_thread.start()
        stop_thread.join(min(0.35, timeout * 0.25))
        with self._counter_lock:
            active_sockets = list(self._active_sockets)
        for active_socket in active_sockets:
            try:
                active_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                active_socket.close()
            except OSError:
                pass
        self.server_close()
        stop_thread.join(max(0.0, deadline - time.monotonic()))
        while time.monotonic() < deadline:
            with self._counter_lock:
                if self.active_requests == 0 and not self._active_sockets:
                    break
            time.sleep(0.01)
        with self._counter_lock:
            idle = self.active_requests == 0 and not self._active_sockets
        return not stop_thread.is_alive() and idle


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "WebReadFixture/1"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        # Never print paths, query strings, headers, cookies, or response bodies.
        return

    def _headers(self, status: int, length: int, content_type: str, extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store, private, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()

    def _send(self, status: int, body: bytes, content_type: str = "text/html; charset=utf-8", extra: dict[str, str] | None = None) -> None:
        if len(body) > self.server.max_response_bytes:
            status = 413
            content_type = "application/json; charset=utf-8"
            body = json.dumps({"error": "fixture response cap exceeded", "capBytes": self.server.max_response_bytes}, separators=(",", ":")).encode("ascii")
        self._headers(status, len(body), content_type, extra)
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True

    def _delay(self, default_ms: int) -> bool:
        query = parse_qs(urlsplit(self.path).query)
        try:
            delay_ms = int(query.get("ms", [str(default_ms)])[0])
        except ValueError:
            delay_ms = default_ms
        delay_ms = max(0, min(delay_ms, MAX_DELAY_MS))
        return self.server.closing_event.wait(delay_ms / 1000)

    def _cookie_ok(self) -> bool:
        return self.headers.get("Cookie", "") == TEST_COOKIE

    def do_HEAD(self) -> None:
        self.do_GET(head_only=True)

    def do_GET(self, head_only: bool = False) -> None:
        raw_path = self.path
        if len(raw_path) > 2048:
            self._send(414, b"request target too long", "text/plain; charset=utf-8")
            return
        path = urlsplit(raw_path).path
        if path == "/health":
            self._send(200, b"FIXTURE-HEALTH-1", "text/plain; charset=ascii")
            return
        if path in PDF_FILES or path in IMAGE_FILES:
            filename, content_type = (PDF_FILES | IMAGE_FILES)[path]
            self._send(200, (FIXTURES / filename).read_bytes(), content_type)
            return
        if path == "/pdf/slow":
            interrupted = self._delay(3000)
            if interrupted:
                self._send(503, b"FIXTURE-SHUTDOWN", "text/plain; charset=ascii")
                return
            self._send(200, (FIXTURES / "multipage-table.pdf").read_bytes(), "application/pdf")
            return
        if path == "/images/mixed.html":
            body = '<main><h1>Image evidence page IMG-MIXED-7A06</h1><img src="/images/direct.png" alt="Price table"><img src="/images/direct.jpg" alt="JPEG price table"><img src="/images/assets/sales-chart.png" alt="Weekly chart"></main>'
            self._send(200, _page("Mixed images", body))
            return
        if path == "/images/relative/page.html":
            body = '<main><h1>Relative asset page IMG-RELATIVE-13B8</h1><img src="../assets/price-table.png" alt="Relative price table"></main>'
            self._send(200, _page("Relative image", body))
            return
        if path == "/images/multiple.html":
            body = '<main><h1>Two independent images</h1><img src="/images/direct.png" alt="Price"><img src="/images/assets/sales-chart.png" alt="Chart"></main>'
            self._send(200, _page("Multiple images", body))
            return
        if path == "/images/lazy.html":
            body = ('<main><h1>Delayed image page</h1><img id="late" alt="Delayed chart">'
                    '<script>setTimeout(()=>{document.querySelector("#late").src="/images/assets/sales-chart.png"},1200)</script></main>')
            self._send(200, _page("Lazy image", body))
            return
        if path == "/images/misleading-alt.html":
            body = '<main><h1>Image-only values</h1><img src="/images/assets/misleading-alt.png" alt="Monthly report"></main>'
            self._send(200, _page("Misleading alt", body))
            return
        if path == "/interaction":
            body = (
                '<main><h1>Interaction fixture</h1>'
                '<label for="note">备注</label><input id="note" type="text">'
                '<button id="apply" type="button">应用</button>'
                '<p id="output">尚未应用</p>'
                '<div style="height:2400px">SCROLL-AREA-FOR-TEST</div>'
                '<p id="scroll-end">INTERACTION-END-9D21</p></main>'
                '<script>document.querySelector("#apply").addEventListener("click",()=>{'
                'document.querySelector("#output").textContent="已应用："+'
                'document.querySelector("#note").value})</script>'
            )
            self._send(200, _page("Interaction fixture", body, lang="zh-Hant"))
            return
        if path == "/images/broken.html":
            body = '<main><h1>Broken image page</h1><p>Image fetch failure must be reported.</p><img src="/images/missing.png" alt="Missing price table"></main>'
            self._send(200, _page("Broken image", body))
            return
        if path == "/html/assets/price-table.png":
            self._send(200, (FIXTURES / "price-table.png").read_bytes(), "image/png")
            return
        if path == "/images/missing.png":
            self._send(404, b"IMAGE-ASSET-NOT-FOUND", "text/plain; charset=ascii")
            return
        if path == "/html/image-and-relative.html":
            body = '<main><h1>Relative source page</h1><img src="assets/price-table.png" alt="Price table"></main>'
            self._send(200, _page("Relative image source", body))
            return
        if path == "/html/mixed-assets.html":
            body = '<main><h1>Mixed HTML and assets</h1><p>HTML-DATA-MARKER-8A74</p><img src="/images/direct.jpg" alt="Visual evidence"></main>'
            self._send(200, _page("Mixed content", body))
            return
        if path == "/auth/grant":
            self._send(200, _page("Fixture access grant", '<main>TEST-COOKIE-GRANTED</main>'), extra={"Set-Cookie": f"{TEST_COOKIE}; Path=/; HttpOnly; SameSite=Strict"})
            return
        if path == "/auth/private":
            if self._cookie_ok():
                self._send(200, PRIVATE_MARKER, "text/plain; charset=ascii", {"Cache-Control": "no-store, private"})
            else:
                self._send(401, b"AUTH-REQUIRED-401", "text/plain; charset=ascii", {"WWW-Authenticate": 'Fixture realm="web-read-test"'})
            return
        if path == "/auth/browser-state":
            if not self._cookie_ok():
                self._send(401, b"AUTH-REQUIRED-401", "text/plain; charset=ascii", {"WWW-Authenticate": 'Fixture realm="web-read-test"'})
                return
            body = (
                '<main><h1>Private browser state</h1>'
                '<p id="private-marker">PRIVATE-MARKER-A7C4</p>'
                '<label for="note">备注</label><input id="note" type="text">'
                '<button id="apply" type="button">应用</button>'
                '<p id="output">尚未应用</p>'
                '<div style="height:2400px">SCROLL-AREA-FOR-TEST</div>'
                '<p id="scroll-end">PRIVATE-STATE-END-2A64</p></main>'
                '<script>document.querySelector("#apply").addEventListener("click",()=>{'
                'document.querySelector("#output").textContent="已应用："+'
                'document.querySelector("#note").value})</script>'
            )
            self._send(200, _page("Private browser state", body, lang="zh-Hant"), extra={"Cache-Control": "no-store, private"})
            return
        if path == "/auth/basic":
            self._send(401, b"BASIC-AUTH-REQUIRED", "text/plain; charset=ascii", {"WWW-Authenticate": 'Basic realm="fixture"'})
            return
        if path == "/auth/403":
            self._send(403, b"ACCESS-DENIED-403", "text/plain; charset=ascii")
            return
        if path == "/auth/form":
            body = '<main><h1>Sign in required</h1><form><label>User<input name="username"></label><label>Password<input type="password" name="password"></label><button>Continue</button></form></main>'
            self._send(200, _page("Sign in", body))
            return
        if path == "/auth/redirect":
            self._headers(302, 0, "text/plain; charset=ascii", {"Location": "/auth/form"})
            return
        if path == "/auth/restricted-redirect":
            self._headers(302, 0, "text/plain; charset=ascii", {"Location": "/auth/private"})
            return
        if path == "/auth/mixed":
            body = '<main><p>PUBLIC-MARKER-5B31</p><a href="/auth/private">Restricted details</a></main>'
            self._send(200, _page("Public plus restricted", body))
            return
        if path == "/session/a":
            self._send(200, b"SESSION-A-MARKER-80B4", "text/plain; charset=ascii")
            return
        if path == "/session/b":
            self._send(200, b"SESSION-B-MARKER-21F7", "text/plain; charset=ascii")
            return
        if path == "/long/html":
            body = LONG_HTML
            range_header = self.headers.get("Range", "")
            if range_header.startswith("bytes="):
                try:
                    start_text, end_text = range_header[6:].split("-", 1)
                    start = int(start_text)
                    end = int(end_text) if end_text else len(body) - 1
                except (ValueError, TypeError):
                    self._send(416, b"INVALID-RANGE", "text/plain; charset=ascii")
                    return
                if start < 0 or start >= len(body) or end < start:
                    self._send(416, b"RANGE-OUT-OF-BOUNDS", "text/plain; charset=ascii")
                    return
                end = min(end, len(body) - 1)
                selected = body[start:end + 1]
                self._send(206, selected, "text/html; charset=utf-8", {"Content-Range": f"bytes {start}-{end}/{len(body)}", "Accept-Ranges": "bytes"})
                return
            self._send(200, body, extra={"Accept-Ranges": "bytes"})
            return
        if path == "/long/public.md":
            self._send(200, LONG_MARKDOWN, "text/markdown; charset=utf-8")
            return
        if path == "/alternate/html":
            body = (
                '<!doctype html><html><head><meta charset="utf-8">'
                '<title>Declared alternate fixture</title>'
                '<link rel="alternate" type="text/markdown" href="/long/public.md">'
                '</head><body><main><h1>Primary HTML excerpt</h1>'
                '<p>PRIMARY-HTML-MARKER-31AF</p></main></body></html>'
            ).encode("utf-8")
            self._send(200, body)
            return
        if path == "/revision/old":
            self._headers(302, 0, "text/plain; charset=ascii", {"Location": "/revision/new"})
            return
        if path == "/revision/new":
            self._send(200, _page("New document", '<main><h1>NEW-DOCUMENT-ONLY</h1><p>FINAL-DOM-MARKER-7C42</p></main>'))
            return
        if path == "/partial":
            script = ('<main><p>EARLY-PARTIAL-BODY-19E3</p><p id="late">Loading</p></main>'
                      '<script>setTimeout(()=>document.querySelector("#late").textContent="TARGETED-CONTINUATION-8E3",900)</script>')
            self._send(200, _page("Partial dynamic body", script))
            return
        if path == "/busy-empty":
            body = '<main><p>BUSY-BODY-READABLE-4A21 The article remains readable while this progress indicator has no visible status text.</p><progress></progress></main>'
            self._send(200, _page("Busy body without status text", body))
            return
        if path == "/redirect":
            self._headers(302, 0, "text/plain; charset=ascii", {"Location": "/static"})
            return
        if path == "/static":
            body = '<header>HEADER-NOISE</header><nav>NAV-NOISE</nav><main><h1>STATIC-BODY-READY</h1><p>STATIC-READY-MARKER-4E71</p><table><tr><th>Plan</th><th>Price</th></tr><tr><td>Basic</td><td>39</td></tr></table></main><footer>FOOTER-NOISE</footer>'
            self._send(200, _page("Static body", body))
            return
        if path == "/slow-resource-page":
            body = '<main><h1>STATIC-BODY-READY</h1><p>STATIC-READY-MARKER-4E71</p><img src="/hang-resource?ms=4500" alt="Decorative delayed asset"></main>'
            self._send(200, _page("Body before resource", body))
            return
        if path == "/hang-resource":
            if self._delay(4500):
                self._send(503, b"FIXTURE-SHUTDOWN", "text/plain; charset=ascii")
                return
            self._send(200, b"DECORATIVE-RESOURCE-DONE", "text/plain; charset=ascii")
            return
        if path == "/slow-main":
            if self._delay(1800):
                self._send(503, b"FIXTURE-SHUTDOWN", "text/plain; charset=ascii")
                return
            self._send(200, b"SLOW-MAIN-MARKER-3D26", "text/plain; charset=ascii")
            return
        if path == "/timeout":
            if self._delay(4800):
                self._send(503, b"FIXTURE-SHUTDOWN", "text/plain; charset=ascii")
                return
            self._send(200, b"TIMEOUT-END-MARKER-2F63", "text/plain; charset=ascii")
            return
        if path == "/slow-stream":
            self._slow_stream()
            return
        if path == "/disconnect":
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Length", "1024")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(b"%PDF-partial")
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.close_connection = True
            return
        if path == "/large":
            query = parse_qs(urlsplit(self.path).query)
            try:
                size = int(query.get("bytes", ["768000"])[0])
            except ValueError:
                size = 768000
            size = max(0, min(size, self.server.max_response_bytes + 1))
            self._send(200, b"L" * size, "application/octet-stream")
            return
        self._send(404, b"FIXTURE-ROUTE-NOT-FOUND", "text/plain; charset=ascii")

    def _slow_stream(self) -> None:
        total = min(16384, (self.server.max_response_bytes // 512) * 512)
        if total < 512:
            self._send(413, b"STREAM-EXCEEDS-RESPONSE-CAP", "text/plain; charset=ascii")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total))
        self.send_header("Cache-Control", "no-store, private")
        self.send_header("Connection", "close")
        self.end_headers()
        chunk = b"S" * 512
        try:
            for _ in range(total // len(chunk)):
                if self.server.closing_event.wait(0.15):
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True


def require_loopback(host: str) -> str:
    if host.lower() == "localhost":
        return host
    try:
        address = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError as exc:
        raise argparse.ArgumentTypeError("host must be localhost or a loopback IP address") from exc
    if not address.is_loopback:
        raise argparse.ArgumentTypeError("fixture server refuses non-loopback binding")
    return host


def build_server(host: str = "127.0.0.1", port: int = 0, *, max_threads: int = MAX_THREADS, max_response_bytes: int = DEFAULT_MAX_RESPONSE_BYTES) -> BoundedThreadingHTTPServer:
    require_loopback(host)
    if not 0 <= port <= 65535:
        raise ValueError("port must be between 0 and 65535")
    if not 1 <= max_threads <= 16:
        raise ValueError("thread limit must be between 1 and 16")
    if not 1024 <= max_response_bytes <= 2 * 1024 * 1024:
        raise ValueError("response cap must be between 1 KiB and 2 MiB")
    if not FIXTURES.is_dir():
        raise RuntimeError("fixture assets are missing; run generate_fixtures.py first")
    return BoundedThreadingHTTPServer((host, port), Handler, max_threads=max_threads, max_response_bytes=max_response_bytes)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=require_loopback, default="127.0.0.1", help="localhost/loopback only")
    parser.add_argument("--port", type=int, default=0, help="port 0 selects a random available port")
    parser.add_argument("--max-threads", type=int, default=MAX_THREADS)
    parser.add_argument("--max-response-bytes", type=int, default=DEFAULT_MAX_RESPONSE_BYTES)
    args = parser.parse_args()
    server = build_server(args.host, args.port, max_threads=args.max_threads, max_response_bytes=args.max_response_bytes)
    host, port = server.server_address[:2]
    print(f"FIXTURE_LISTENING http://{host}:{port}/ threads={args.max_threads} response_cap={args.max_response_bytes}", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.closing_event.set()
        server.server_close()


if __name__ == "__main__":
    main()
