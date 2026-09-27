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
import ssl
import sys
import threading
import time


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
        return super().do_GET()


def serve(port, directory, cert=None, key=None):
    handler = functools.partial(Quiet, directory=directory)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    if cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
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
