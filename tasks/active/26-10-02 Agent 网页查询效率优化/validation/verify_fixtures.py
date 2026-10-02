#!/usr/bin/env python3
"""Hit local fixture routes and validate format/lifecycle oracles.

All reported passes describe only the fixture server and test assets. They do
not indicate that MinisX, an iOS build, or a real Agent session passed.
"""
from __future__ import annotations

import argparse
import http.client
import io
import json
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http.cookiejar import CookieJar
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import HTTPCookieProcessor, Request, build_opener

from PIL import Image
from pypdf import PdfReader
from pypdf.errors import PdfReadError

import fixture_server


DEFAULT_OUTPUT = Path("/private/tmp/web-read-fixture-selfcheck.json")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def open_response(opener, url: str, *, timeout: float = 3.0):
    try:
        response = opener.open(url, timeout=timeout)
    except HTTPError as error:
        return error.code, error.headers, error.read(), error.geturl()
    with response:
        return response.status, response.headers, response.read(), response.geturl()


def raw_request(host: str, port: int, path: str, *, timeout: float = 2.0, read_bytes: int | None = None):
    connection = http.client.HTTPConnection(host, port, timeout=timeout)
    connection.request("GET", path)
    response = connection.getresponse()
    body = response.read(read_bytes) if read_bytes is not None else response.read()
    return connection, response, body


class LongHTMLAudit(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.text_chunks: list[str] = []
        self.table_rows: list[list[str]] = []
        self.code_chunks: list[str] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None
        self._in_code = False

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag == "tr":
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []
        elif tag == "code":
            self._in_code = True

    def handle_endtag(self, tag: str) -> None:
        if tag in ("td", "th") and self._row is not None and self._cell is not None:
            self._row.append("".join(self._cell).strip())
            self._cell = None
        elif tag == "tr" and self._row is not None:
            self.table_rows.append(self._row)
            self._row = None
        elif tag == "code":
            self._in_code = False

    def handle_data(self, data: str) -> None:
        self.text_chunks.append(data)
        if self._cell is not None:
            self._cell.append(data)
        if self._in_code:
            self.code_chunks.append(data)


def run_checks() -> dict:
    server = fixture_server.build_server("127.0.0.1", 0, max_threads=8, max_response_bytes=1024 * 1024)
    serve_thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, name="fixture-serve", daemon=True)
    serve_thread.start()
    servers: list[tuple[fixture_server.BoundedThreadingHTTPServer, threading.Thread]] = [(server, serve_thread)]
    host, port = server.server_address[:2]
    base = f"http://{host}:{port}"
    opener = build_opener()
    checks: list[dict[str, str]] = []

    def passed(check_id: str, detail: str) -> None:
        checks.append({"id": check_id, "status": "fixture_selfcheck_pass", "detail": detail})

    try:
        status, _, body, _ = open_response(opener, base + "/health")
        require(status == 200 and body == b"FIXTURE-HEALTH-1", "health route did not return its fixed body")
        passed("route-health", "Actual HTTP GET to /health returned the fixed response.")

        status, headers, text_pdf, _ = open_response(opener, base + "/pdf/text")
        reader = PdfReader(io.BytesIO(text_pdf))
        text = "\n".join(page.extract_text() or "" for page in reader.pages)
        require(status == 200 and len(reader.pages) == 2, "text PDF is not a two-page PDF")
        for token in ("PDF-PAGE-ONE-4107", "Basic", "39", "Pro", "99", "PDF-END-MARKER-82C1"):
            require(token in text, f"text PDF did not extract expected fixture token: {token}")
        passed("pdf-multipage-table", f"HTTP returned {len(reader.pages)} valid pages with table and last-page text.")

        status, _, scanned_bytes, _ = open_response(opener, base + "/pdf/scanned")
        scanned_reader = PdfReader(io.BytesIO(scanned_bytes))
        scan_text = "\n".join(page.extract_text() or "" for page in scanned_reader.pages).strip()
        require(status == 200 and len(scanned_reader.pages) == 1 and scan_text == "", "scanned PDF unexpectedly has a text layer")
        passed("pdf-scanned-no-text", "Actual PDF response has one page and no extractable text layer.")

        status, _, encrypted_bytes, _ = open_response(opener, base + "/pdf/encrypted")
        encrypted_reader = PdfReader(io.BytesIO(encrypted_bytes))
        require(status == 200 and encrypted_reader.is_encrypted, "encrypted PDF fixture is not encrypted")
        passed("pdf-encrypted", "pypdf identified an encrypted PDF from the served route.")

        status, _, corrupt_bytes, _ = open_response(opener, base + "/pdf/corrupt")
        parse_failed = False
        try:
            PdfReader(io.BytesIO(corrupt_bytes))
        except (PdfReadError, ValueError, OSError):
            parse_failed = True
        require(status == 200 and parse_failed, "corrupt PDF fixture unexpectedly parsed")
        passed("pdf-corrupt", "Served bytes are rejected by the PDF parser.")

        status, wrong_headers, wrong_bytes, _ = open_response(opener, base + "/pdf/wrong-mime")
        require(status == 200 and "text/html" in wrong_headers.get("Content-Type", "") and wrong_bytes.startswith(b"%PDF"), "wrong-MIME PDF mismatch not present")
        require(len(PdfReader(io.BytesIO(wrong_bytes)).pages) == 2, "wrong-MIME PDF body is not valid")
        passed("pdf-wrong-mime", "Valid two-page PDF bytes were served under text/html Content-Type.")

        status, _, large_pdf_bytes, _ = open_response(opener, base + "/pdf/large", timeout=5.0)
        large_reader = PdfReader(io.BytesIO(large_pdf_bytes))
        require(status == 200 and len(large_pdf_bytes) > 500 * 1024 and len(large_pdf_bytes) <= server.max_response_bytes, "large PDF is outside expected byte bounds")
        require(len(large_reader.pages) == 32, "large PDF page count changed")
        require("LARGE-PDF-END-MARKER-88F3" in (large_reader.pages[-1].extract_text() or ""), "large PDF final marker is missing")
        passed("pdf-large", f"Valid {len(large_reader.pages)}-page PDF was delivered within the fixture cap ({len(large_pdf_bytes)} bytes).")

        for route, expected_format in (("/images/direct.png", "PNG"), ("/images/direct.jpg", "JPEG"), ("/images/assets/sales-chart.png", "PNG")):
            status, headers, image_bytes, _ = open_response(opener, base + route)
            image = Image.open(io.BytesIO(image_bytes))
            image.verify()
            require(status == 200 and image.format == expected_format and len(image_bytes) <= server.max_response_bytes, f"{route} failed image decode/format check")
            passed("image-" + expected_format.lower() + "-" + route.rsplit("/", 1)[-1], f"Pillow decoded the actual {expected_format} route ({headers.get('Content-Type')}).")

        status, _, html, page_url = open_response(opener, base + "/images/relative/page.html")
        require(status == 200 and b"../assets/price-table.png" in html, "relative image page did not expose expected source")
        relative = urljoin(page_url, "../assets/price-table.png")
        require(relative == base + "/images/assets/price-table.png", "relative source resolved to an unexpected route")
        status, _, relative_bytes, _ = open_response(opener, relative)
        Image.open(io.BytesIO(relative_bytes)).verify()
        passed("image-relative-src", "Relative src resolved against the response URL and the resulting PNG was fetched and decoded.")

        status, _, mixed_html, _ = open_response(opener, base + "/images/mixed.html")
        require(status == 200 and mixed_html.count(b"<img") == 3 and b"/images/direct.jpg" in mixed_html, "mixed/multiple image markup is incomplete")
        passed("image-mixed-and-multiple", "HTML route contains distinct PNG, JPEG, and chart resource references.")

        status, _, lazy_html, _ = open_response(opener, base + "/images/lazy.html")
        require(status == 200 and b"setTimeout" in lazy_html and b"sales-chart.png" in lazy_html, "delayed image script is absent")
        passed("image-lazy-route", "Actual HTML response carries a delayed image insertion script; script execution is not claimed.")

        status, _, misleading_html, _ = open_response(opener, base + "/images/misleading-alt.html")
        status_img, _, image_bytes, _ = open_response(opener, base + "/images/assets/misleading-alt.png")
        require(status == 200 and status_img == 200 and b"Monthly report" in misleading_html, "misleading alt fixture is incomplete")
        Image.open(io.BytesIO(image_bytes)).verify()
        passed("image-misleading-alt", "HTML alt text and decodable image are separately available; this check makes no OCR claim.")

        status, _, broken_html, _ = open_response(opener, base + "/images/broken.html")
        image_status, _, _, _ = open_response(opener, base + "/images/missing.png")
        require(status == 200 and b"/images/missing.png" in broken_html and image_status == 404, "broken image route did not return 404")
        passed("image-broken", "HTML references an asset that the server actually returns as 404.")

        anon_status, _, _, _ = open_response(opener, base + "/auth/private")
        jar = CookieJar()
        cookie_opener = build_opener(HTTPCookieProcessor(jar))
        grant_status, _, _, _ = open_response(cookie_opener, base + "/auth/grant")
        private_status, _, private_body, _ = open_response(cookie_opener, base + "/auth/private")
        fresh_status, _, fresh_body, _ = open_response(build_opener(), base + "/auth/private")
        require(anon_status == 401 and grant_status == 200 and private_status == 200 and private_body == fixture_server.PRIVATE_MARKER, "cookie grant did not change the private response")
        require(fresh_status == 401 and fixture_server.PRIVATE_MARKER not in fresh_body, "fresh anonymous opener inherited the test cookie")
        passed("auth-cookie-before-after", "A cookie-jar request got the private marker; a fresh anonymous opener still got 401.")

        denied_status, _, denied_body, _ = open_response(opener, base + "/auth/403")
        form_status, _, form_body, _ = open_response(opener, base + "/auth/form")
        require(denied_status == 403 and denied_body == b"ACCESS-DENIED-403", "403 fixture changed")
        require(form_status == 200 and b"type=\"password\"" in form_body, "200 login form fixture changed")
        passed("auth-403-and-200-form", "Actual routes distinguish a 403 denial from a 200 password form.")

        redir_status, _, _, redir_url = open_response(opener, base + "/auth/redirect")
        restricted_status, _, _, restricted_url = open_response(opener, base + "/auth/restricted-redirect")
        require(redir_status == 200 and redir_url.endswith("/auth/form"), "login redirect did not finish at form")
        require(restricted_status == 401 and restricted_url.endswith("/auth/private"), "restricted redirect did not finish at 401 route")
        passed("auth-redirects", "HTTP client followed both redirect paths and observed their distinct final URLs/statuses.")

        status, _, mixed_auth, _ = open_response(opener, base + "/auth/mixed")
        require(status == 200 and b"PUBLIC-MARKER-5B31" in mixed_auth and b"/auth/private" in mixed_auth, "mixed public/restricted fixture is incomplete")
        passed("auth-public-plus-restricted", "One page contains a public marker and a separately protected link.")

        _, _, session_a, _ = open_response(opener, base + "/session/a")
        _, session_a_headers, _, _ = open_response(opener, base + "/session/a")
        _, _, session_b, _ = open_response(opener, base + "/session/b")
        require(session_a == b"SESSION-A-MARKER-80B4" and session_b == b"SESSION-B-MARKER-21F7" and session_a != session_b, "session fixture bodies are not distinct")
        require("no-store" in session_a_headers.get("Cache-Control", ""), "session route does not disable caching")
        passed("session-cache-fixture", "Distinct no-store session route bodies were fetched; this does not prove app cache isolation.")

        status, _, long_html, _ = open_response(opener, base + "/long/html")
        status_md, md_headers, markdown, _ = open_response(opener, base + "/long/public.md")
        range_request = Request(base + "/long/html", headers={"Range": "bytes=30000-"})
        range_response = opener.open(range_request, timeout=3.0)
        with range_response:
            range_status, range_headers, range_body = range_response.status, range_response.headers, range_response.read()
        audit = LongHTMLAudit()
        audit.feed(long_html.decode("utf-8"))
        text_content = "".join(audit.text_chunks)
        tail_position = text_content.find("END-READ-MARKER-90631")
        require(status == 200 and len(long_html) > 30000, "long HTML is not large enough to cross the configured read/format limits")
        require(tail_position > 30000, f"exact textContent marker is not beyond 30000 characters: {tail_position}")
        require(status_md == 200 and "text/markdown" in md_headers.get("Content-Type", "") and b"MARKDOWN-EXCERPT-END-4C2D" in markdown, "Markdown alternative is incomplete")
        require(b'href="/long/public.md"' in long_html, "HTML does not explicitly advertise its public Markdown alternative")
        require(range_status == 206 and "bytes 30000-" in range_headers.get("Content-Range", "") and b"END-READ-" in range_body and b"90631" in range_body, "bounded range continuation did not return the long-page tail")
        require(audit.table_rows[-3:] == [["Plan", "Price"], ["Basic", "39"], ["Pro", "99"]], f"HTML table row/column relation changed: {audit.table_rows[-3:]}")
        require("def fixture_value()" in "".join(audit.code_chunks) and "return 'CODE-END-MARKER-513E'" in "".join(audit.code_chunks), "HTML code block text/inline identifier changed")
        require(b"FIXTURE-HEADER-NOISE" in long_html and b"FIXTURE-FOOTER-NOISE" in long_html, "long-page chrome controls are missing")
        require(b"| Basic | 39 |" in markdown, "Markdown table relation changed")
        require(b"not a complete copy" in markdown and b"return 'CODE-END-MARKER-513E'" in markdown, "Markdown subset provenance or same-code relation changed")
        passed("content-long-tail-markdown", f"HTTP fetched {len(long_html)} HTML bytes; reconstructed textContent tail is at offset {tail_position}; table/code structure, public Markdown link and byte-range continuation were checked.")

        revision_status, _, revision_body, revision_url = open_response(opener, base + "/revision/old")
        require(revision_status == 200 and revision_url.endswith("/revision/new") and b"FINAL-DOM-MARKER-7C42" in revision_body and b"OLD-DOCUMENT" not in revision_body, "navigation did not expose the new document")
        passed("revision-old-to-new", "Old route redirected and actual final response contained only the new document marker.")

        status, _, partial_html, _ = open_response(opener, base + "/partial")
        require(status == 200 and b"EARLY-PARTIAL-BODY-19E3" in partial_html and b"setTimeout" in partial_html and b"TARGETED-CONTINUATION-8E3" in partial_html, "partial dynamic fixture changed")
        passed("content-partial-dynamic", "HTML source contains an early marker and a later script insertion; no script execution is claimed.")

        started = time.monotonic()
        status, _, slow_body, _ = open_response(opener, base + "/slow-main?ms=250", timeout=2.0)
        elapsed = time.monotonic() - started
        require(status == 200 and slow_body == b"SLOW-MAIN-MARKER-3D26" and 0.20 <= elapsed < 1.8, f"slow main delay outside expected range: {elapsed:.3f}s")
        passed("resource-slow-main", f"HTTP request took {elapsed:.3f}s for a configured 250 ms wait.")

        status, _, early_html, _ = open_response(opener, base + "/slow-resource-page")
        require(status == 200 and b"STATIC-READY-MARKER-4E71" in early_html and b"hang-resource?ms=4500" in early_html, "delayed-subresource HTML fixture is incomplete")
        passed("resource-slow-subresource", "Main HTML returned while naming a separately delayed resource route.")

        status, _, large_payload, _ = open_response(opener, base + "/large?bytes=768000", timeout=5.0)
        require(status == 200 and len(large_payload) == 768000, "bounded large body route returned unexpected size")
        capped_status, _, capped_body, _ = open_response(opener, base + "/large?bytes=2000000", timeout=3.0)
        require(capped_status == 413 and len(capped_body) < 256, "fixture response cap was not enforced")
        passed("resource-response-cap", "Large test body fits the configured cap; larger request receives a small 413 response.")

        conn, response, first_chunk = raw_request(host, port, "/slow-stream", read_bytes=512)
        require(response.status == 200 and len(first_chunk) == 512, "slow stream did not send its first bounded chunk")
        conn.close()
        follow_status, _, follow_body, _ = open_response(opener, base + "/health")
        require(follow_status == 200 and follow_body == b"FIXTURE-HEALTH-1", "server did not answer after client disconnect")
        passed("resource-disconnect-recovery", "Client closed a streamed body early; a subsequent real request succeeded.")

        disconnect_seen = False
        try:
            open_response(opener, base + "/disconnect", timeout=2.0)
        except (http.client.IncompleteRead, URLError, OSError):
            disconnect_seen = True
        require(disconnect_seen, "truncated response was not surfaced as a client transport error")
        passed("resource-truncated-response", "HTTP client detected the Content-Length/body mismatch on /disconnect.")

        # Fill the configured request slots with accepted but incomplete HTTP
        # connections. A ninth request must be rejected, and shutdown must
        # close each accepted socket and wait for all handlers to release.
        connected_sockets: list[socket.socket] = []
        for _ in range(4):
            connected_sockets.append(socket.create_connection((host, port), timeout=1.5))
        for _ in range(4):
            partial = socket.create_connection((host, port), timeout=1.5)
            partial.sendall(b"GET /health HTTP/1.1\r\nHost: fixture\r\nX-Incomplete:")
            connected_sockets.append(partial)
        deadline = time.monotonic() + 1.25
        while time.monotonic() < deadline and server.active_requests < 8:
            time.sleep(0.01)
        require(server.active_requests == 8 and server.peak_requests <= 8 and server.peak_requests == 8, f"server did not enforce exactly eight occupied request slots: active={server.active_requests}, peak={server.peak_requests}")
        overflow = socket.create_connection((host, port), timeout=1.0)
        overflow.settimeout(1.0)
        overflow.sendall(b"GET /health HTTP/1.1\r\nHost: fixture\r\nConnection: close\r\n\r\n")
        overflow_reply = overflow.recv(256)
        overflow.close()
        require(overflow_reply.startswith(b"HTTP/1.0 503"), "ninth simultaneous request was not rejected at the thread cap")
        shutdown_started = time.monotonic()
        stopped = server.bounded_shutdown(timeout=1.75)
        shutdown_elapsed = time.monotonic() - shutdown_started
        serve_thread.join(0.5)
        for active_socket in connected_sockets:
            active_socket.settimeout(0.5)
            closed = False
            drained = 0
            try:
                while drained <= 2048:
                    received = active_socket.recv(512)
                    if not received:
                        closed = True
                        break
                    drained += len(received)
            except OSError:
                closed = True
            require(closed and drained <= 2048, f"accepted idle/partial-header socket remained open or emitted excess bytes: {drained}")
            active_socket.close()
        with server._counter_lock:
            remaining = server.active_requests
            remaining_sockets = len(server._active_sockets)
        require(stopped and not serve_thread.is_alive() and shutdown_elapsed < 1.75, f"bounded fixture shutdown failed ({shutdown_elapsed:.3f}s)")
        require(remaining == 0 and remaining_sockets == 0, f"active request/socket tracking did not drain: requests={remaining}, sockets={remaining_sockets}")
        passed("resource-idle-partial-shutdown", f"Eight idle/partial-header clients filled (but did not exceed) the worker cap; ninth got 503; shutdown closed all sockets and drained handlers in {shutdown_elapsed:.3f}s.")

        low_cap_server = fixture_server.build_server("127.0.0.1", 0, max_threads=2, max_response_bytes=1024)
        low_cap_thread = threading.Thread(target=low_cap_server.serve_forever, kwargs={"poll_interval": 0.05}, name="fixture-low-cap-serve", daemon=True)
        low_cap_thread.start()
        servers.append((low_cap_server, low_cap_thread))
        low_host, low_port = low_cap_server.server_address[:2]
        low_status, _, low_stream, _ = open_response(build_opener(), f"http://{low_host}:{low_port}/slow-stream", timeout=2.0)
        require(low_status == 200 and len(low_stream) <= low_cap_server.max_response_bytes, "streamed response exceeded the configured low response cap")
        require(low_cap_server.bounded_shutdown(timeout=1.0), "low-cap fixture failed to close")
        low_cap_thread.join(0.3)
        require(not low_cap_thread.is_alive(), "low-cap serve loop remained active after shutdown")
        passed("resource-stream-response-cap", f"With a 1024-byte configured cap, streamed route returned {len(low_stream)} bytes and stayed within the limit.")

        # Also interrupt a real route waiting on its bounded delay. This checks
        # server fixture teardown only, not iOS cancellation semantics.
        delayed_server = fixture_server.build_server("127.0.0.1", 0, max_threads=2, max_response_bytes=1024 * 1024)
        delayed_thread = threading.Thread(target=delayed_server.serve_forever, kwargs={"poll_interval": 0.05}, name="fixture-delayed-serve", daemon=True)
        delayed_thread.start()
        servers.append((delayed_server, delayed_thread))
        delayed_host, delayed_port = delayed_server.server_address[:2]
        delayed_base = f"http://{delayed_host}:{delayed_port}"
        shutdown_result: dict[str, object] = {}

        def pending_request() -> None:
            try:
                result = open_response(opener, delayed_base + "/timeout?ms=4800", timeout=6.0)
                shutdown_result["result"] = result[0]
            except (HTTPError, URLError, OSError, http.client.HTTPException) as exc:
                shutdown_result["result"] = type(exc).__name__

        pending = threading.Thread(target=pending_request, name="fixture-pending-client", daemon=True)
        pending.start()
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline and delayed_server.active_requests == 0:
            time.sleep(0.01)
        require(delayed_server.active_requests > 0, "delayed shutdown request never reached the fixture server")
        delayed_started = time.monotonic()
        delayed_stopped = delayed_server.bounded_shutdown(timeout=1.75)
        delayed_elapsed = time.monotonic() - delayed_started
        delayed_thread.join(0.5)
        pending.join(0.5)
        require(delayed_stopped and not delayed_thread.is_alive() and not pending.is_alive() and delayed_elapsed < 1.75, "delayed response did not release during bounded shutdown")
        require(shutdown_result.get("result") != 200, "delayed route completed as success after fixture shutdown")
        passed("resource-delayed-shutdown", f"A real delayed route was active; shutdown interrupted it and released the client in {delayed_elapsed:.3f}s.")

        return {
            "schema_version": 1,
            "evidence_scope": "fixture_server_only",
            "product_acceptance": "not_tested",
            "agent_end_to_end": "not_tested",
            "server": {"host": host, "port": port, "max_threads": server.max_threads, "max_response_bytes": server.max_response_bytes, "active_requests_after_shutdown": remaining, "active_sockets_after_shutdown": remaining_sockets},
            "checks": checks,
            "summary": {"fixture_checks_passed": len(checks), "fixture_checks_failed": 0},
        }
    finally:
        for running_server, running_thread in servers:
            if running_thread.is_alive():
                running_server.bounded_shutdown(timeout=1.5)
                running_thread.join(0.5)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="write fixture-only result JSON; default is /private/tmp")
    args = parser.parse_args()
    try:
        report = run_checks()
    except Exception as exc:
        report = {
            "schema_version": 1,
            "evidence_scope": "fixture_server_only",
            "product_acceptance": "not_tested",
            "agent_end_to_end": "not_tested",
            "failure": {"type": type(exc).__name__, "detail": str(exc)},
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        print(f"Fixture self-check failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        print(f"Fixture-only output saved: {args.output}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report["generated_at"] = datetime.now(timezone.utc).isoformat()
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(f"Fixture-only checks passed: {report['summary']['fixture_checks_passed']}; product and Agent acceptance: not tested.")
    print(f"Fixture-only output saved: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
