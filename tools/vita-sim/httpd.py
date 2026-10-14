#!/usr/bin/env python3
"""Local web servers for the simulator's network pages (tools/run-vita-sim.sh).

Serves one directory three ways, so the Vita frontend's curl + mbedTLS path
is exercised end to end without the internet:

    --http PORT                       plain HTTP
    --https PORT CERT KEY             HTTPS; CERT chains to a test CA that
                                      the simulator's ca-bundle.pem trusts
    --https-bad PORT CERT KEY         HTTPS with a certificate nobody signed:
                                      the fetch must be refused

Runs until killed. Stdlib only.
"""

import argparse
import functools
import http.server
import json
import ssl
import sys
import threading
import time


# GETs per path (query dropped), shared by every server in this process:
# /fetch-count?prefix=P answers {path: count} for the paths under P, so a
# page can see its own duplicate fetches (JS-module-dedupe.html).
GETS = {}
GETS_LOCK = threading.Lock()


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("httpd %s %s\n" % (self.server.server_port,
                                            fmt % args))

    # Patch 131 (S5/B1): streaming endpoints for JS-streaming.html.
    # /progress-stream: a body in several chunks, no Content-Length (so
    #   XHR onprogress has lengthComputable=false and the progress is real,
    #   not one delivery).
    # /sse: a text/event-stream with the events the page checks, then the
    #   server closes the connection (the page's close() must stop the
    #   client before it would reconnect).
    def stream_start(self, ctype):
        # Chunked framing is HTTP/1.1: answered as the handler's default
        # HTTP/1.0, curl would pass the chunk-size lines through as body.
        # One response per connection, so nothing else needs keep-alive.
        self.protocol_version = "HTTP/1.1"
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/fetch-count":
            prefix = ""
            if "?prefix=" in self.path:
                prefix = self.path.split("?prefix=", 1)[1]
            with GETS_LOCK:
                counts = {k: v for k, v in GETS.items()
                          if k.startswith(prefix)}
            body = json.dumps(counts, sort_keys=True).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        with GETS_LOCK:
            GETS[path] = GETS.get(path, 0) + 1
        if self.path == "/progress-stream":
            self.stream_start("text/plain")
            for i in range(20):
                self.wfile.write(("%08x\r\n" % len("chunk%d " % i))
                                 .encode() + ("chunk%d " % i).encode()
                                 + b"\r\n")
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        if self.path == "/split-utf8":
            # Patch 132: UTF-8 split mid-character across chunks, so a
            # fetch() body reader must decode with {stream: true}.
            self.stream_start("text/plain; charset=utf-8")
            body = "caf\u00e9 ok \u2713".encode("utf-8")
            for part in (body[:4], body[4:9], body[9:11], body[11:]):
                self.wfile.write(("%08x\r\n" % len(part)).encode()
                                 + part + b"\r\n")
                self.wfile.flush()
                time.sleep(0.1)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        if self.path == "/sse":
            self.stream_start("text/event-stream")
            events = [
                "data: 1\n\n",
                "data: 2\n\n",
                "data: 3\n\n",
                "data: 4\n\n",
                "data: 5\n\n",
                "event: tick\nid: 42\ndata: hello\n\n",
                "event: multi\ndata: line1\ndata: line2\n\n",
            ]
            for ev in events:
                body = ev.encode()
                self.wfile.write(("%08x\r\n" % len(body)).encode()
                                 + body + b"\r\n")
                self.wfile.flush()
                time.sleep(0.3)
            # Keep the stream open: a real SSE connection is long-lived.
            # Closing it here makes the client fire "error" + reconnect
            # (the C layer treats a server close as a failed stream), so
            # the page's own close() must be what ends it. httpd is a
            # daemon killed at the end of the run, so this handler just
            # parks until the connection dies (client close() -> RST).
            try:
                while True:
                    time.sleep(1.0)
            except Exception:
                pass
            return
        if self.path == "/stall-js":
            # Patch 299: accept and hold. Not one byte is ever sent --
            # no headers, no body -- and the connection stays open.
            # A parser-blocking script pointing here can only be
            # unblocked by a client-side no-progress policy; httpd is
            # a daemon killed at the end of the run, so this handler
            # just parks.
            try:
                while True:
                    time.sleep(1.0)
            except Exception:
                pass
            return
        if self.path == "/drip-js":
            # Patch 299: slow but progressing. A complete, tiny script
            # body dripped 4 bytes every 2 s (2 B/s -- above curl's
            # 1 B/s low-speed floor, so only a policy that confuses
            # slow with stalled would kill it). A no-PROGRESS policy
            # must let it finish: window.__nsDrip is the receipt.
            self.protocol_version = "HTTP/1.1"
            self.close_connection = True
            body = b"window.__nsDrip=1;\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            for i in range(0, len(body), 4):
                self.wfile.write(body[i:i + 4])
                self.wfile.flush()
                if i + 4 < len(body):
                    time.sleep(2.0)
            return
        if self.path == "/slow-headers":
            # Patch 135: fetch() must resolve at the header block, not at
            # the first body byte. Send a complete header block, flush it,
            # wait 2 s (long enough to prove promise settlement), then send
            # the body. JS-fetch-headers.html asserts the promise resolved
            # >= 1 s before the first body byte arrived.
            self.protocol_version = "HTTP/1.1"
            self.close_connection = True
            body = b"hello world"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("X-Slow-Test", "yes")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            time.sleep(2.0)
            self.wfile.write(body)
            self.wfile.flush()
            return
        if self.path.startswith("/slow/"):
            # Patch 160 (WS-C1): a file served after 1 s, so a module graph
            # has a transfer that takes real time. JS-module-static-async
            # proves timers keep running while it is in flight.
            time.sleep(1.0)
            self.path = self.path[len("/slow"):]
        return super().do_GET()

    def do_POST(self):
        if self.path.startswith("/form-check"):
            # Patch 283: a form submission checked. Answers a page whose
            # title is "FORMCHECK <case> ok <digest>" -- the body well
            # formed (multipart: the boundary a valid token matching the
            # Content-Type, every delimiter and header line CRLF, each part
            # a form-data disposition with a quoted name, a file part's
            # filename and type; Content-Length exact) and a digest of
            # its entries, every byte except the boundary -- or
            # "FORMCHECK <case> BAD <why>". The pages compare the digest
            # with Chromium's for the same form; the page tells its parent
            # (the form's target is a frame) with postMessage.
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length) if length > 0 else b""
            case = self.path.partition("case=")[2].split("&")[0] or "-"
            verdict, listing = form_check(
                self.headers.get("Content-Type", ""), body,
                self.headers.get("Content-Length"),
                self.headers.get("Transfer-Encoding"))
            out = ("<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
                   "<title>FORMCHECK %s %s</title></head><body><pre>%s"
                   "</pre><script>try { parent.postMessage(document.title,"
                   " '*'); } catch (e) {}</script></body></html>"
                   % (case, verdict, listing)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(out)
            self.wfile.flush()
            return
        if self.path == "/echo":
            # Patch 140: echo the request body back for fetch/XHR body tests.
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length > 0 else b""
            ctype = self.headers.get("Content-Type", "")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("X-Echo-Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return
        self.send_response(404)
        self.end_headers()


def form_check(ctype, body, clen, te):
    """(verdict, listing) for a submitted form body: see do_POST"""
    import hashlib
    import html
    import re
    entries, why = [], None
    if clen is None or te:
        why = "no Content-Length"
    elif ctype.startswith("multipart/form-data"):
        m = re.search(r";\s*boundary=(\S+)$", ctype)
        bd = m.group(1).strip('"').encode() if m else b""
        if not re.fullmatch(rb"[0-9A-Za-z'()+_,\-./:=?]{1,70}", bd):
            why = "boundary %r not a valid token" % bd
        elif not body.startswith(b"--" + bd + b"\r\n"):
            why = "body does not open with the boundary"
        elif not body.endswith(b"\r\n--" + bd + b"--\r\n"):
            why = "body does not close with the boundary"
        else:
            inner = body[len(bd) + 4:-(len(bd) + 8)]
            for part in inner.split(b"\r\n--" + bd + b"\r\n"):
                head, sep, value = part.partition(b"\r\n\r\n")
                lines = head.split(b"\r\n")
                if not sep or b"\n" in head.replace(b"\r\n", b""):
                    why = "a part's headers are not CRLF lines"
                    break
                dm = re.fullmatch(rb'Content-Disposition: form-data; '
                                  rb'name="([^"\r\n]*)"(; filename="([^"\r\n]*)")?',
                                  lines[0])
                if not dm:
                    why = "a part's disposition: %r" % lines[0][:80]
                    break
                if dm.group(2) is not None and (
                        len(lines) != 2 or not lines[1].startswith(b"Content-Type: ")):
                    why = "a file part without its type"
                    break
                if dm.group(2) is None and len(lines) != 1:
                    why = "a text part with extra headers"
                    break
                entries.append(lines + [value])
    elif ctype.startswith("application/x-www-form-urlencoded"):
        entries = [[p] for p in body.split(b"&")] if body else []
    else:
        why = "Content-Type %r" % ctype
    digest = hashlib.sha256(repr(entries).encode()).hexdigest()[:12]
    listing = html.escape("\n".join(" | ".join(repr(x)[2:-1] for x in e)
                                     for e in entries))
    return ("BAD %s" % why if why else "ok %s" % digest), listing


class TLSThreadingServer(http.server.ThreadingHTTPServer):
    """TLS handshakes in each connection's own thread.

    Wrapping the listening socket made accept() do the handshake in the one
    serving thread: a client that connected and stalled mid-handshake (the
    gate aborts some on purpose: the rogue-certificate pages) held up every
    later https connection, and a page's streams got no byte before the
    next navigation (JS-streaming-https "script did not run", 2026-10-11).
    """
    ssl_ctx = None

    def finish_request(self, request, client_address):
        request.settimeout(10)
        try:
            request = self.ssl_ctx.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            return
        request.settimeout(None)
        try:
            super().finish_request(request, client_address)
        finally:
            try:
                request.close()
            except OSError:
                pass


def serve(port, directory, cert=None, key=None):
    handler = functools.partial(Quiet, directory=directory)
    if cert:
        srv = TLSThreadingServer(("127.0.0.1", port), handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        srv.ssl_ctx = ctx
    else:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--http", type=int)
    ap.add_argument("--https", nargs=3, metavar=("PORT", "CERT", "KEY"))
    ap.add_argument("--https-bad", nargs=3, metavar=("PORT", "CERT", "KEY"))
    a = ap.parse_args()
    if a.http:
        serve(a.http, a.dir)
    if a.https:
        serve(int(a.https[0]), a.dir, a.https[1], a.https[2])
    if a.https_bad:
        serve(int(a.https_bad[0]), a.dir, a.https_bad[1], a.https_bad[2])
    print("httpd: serving %s" % a.dir, flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    main()
