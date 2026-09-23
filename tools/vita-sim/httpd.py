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


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("httpd %s %s\n" % (self.server.server_port,
                                            fmt % args))


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
