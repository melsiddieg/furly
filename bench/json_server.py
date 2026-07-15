#!/usr/bin/env python3
"""Threaded JSON server for the furly-vs-httr benchmark.

Unlike webfakes' in-process test server (which handles requests
*sequentially*), this uses ThreadingHTTPServer so concurrent clients are
actually served in parallel -- which is what makes furly's async engine
observable.

Route:  GET /data/<id>?n=<records>&delay=<ms>
        -> a JSON array of <records> objects (JSON-heavy payload),
           after sleeping <delay> milliseconds (simulated latency).

Usage:  python3 json_server.py <port>
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# Pre-build one record template; each response scales it to <n> records with a
# per-record id so payloads are large but cheap to generate.
def make_payload(base_id, n):
    recs = []
    for i in range(n):
        rid = base_id * 1000 + i
        recs.append({
            "id": rid,
            "name": "record-%d" % rid,
            "email": "user%d@example.com" % rid,
            "active": (i % 2 == 0),
            "score": (rid * 7.5) % 100,
            "tags": ["alpha", "beta", "gamma", "delta"][: (i % 4) + 1],
            "meta": {
                "created": "2026-07-15T00:00:%02dZ" % (i % 60),
                "revision": i % 10,
                "notes": "lorem ipsum dolor sit amet consectetur adipiscing " * 2,
            },
            "values": list(range(i, i + 20)),
        })
    return {"id": base_id, "count": n, "records": recs}


# Memoize serialized payloads by (base_id, n). Without this, every request
# re-runs json.dumps() of a large document, and under concurrent load the
# GIL-bound serialization -- not the network or the client -- becomes the
# bottleneck, which would confound a parsing benchmark. With caching the server
# is effectively pure I/O (socket writes release the GIL).
_cache = {}
_cache_lock = __import__("threading").Lock()


def cached_body(base_id, n):
    key = (base_id, n)
    hit = _cache.get(key)
    if hit is not None:
        return hit
    body = json.dumps(make_payload(base_id, n)).encode("utf-8")
    with _cache_lock:
        _cache[key] = body
    return body


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive so curl can reuse connections

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        try:
            base_id = int(parsed.path.rsplit("/", 1)[-1])
        except ValueError:
            base_id = 0
        n = int(qs.get("n", ["200"])[0])
        delay = float(qs.get("delay", ["0"])[0])
        if delay > 0:
            time.sleep(delay / 1000.0)
        body = cached_body(base_id, n)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # quiet


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    print("listening on 127.0.0.1:%d" % port, flush=True)
    srv.serve_forever()
