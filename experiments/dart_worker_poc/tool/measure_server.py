"""Serves build/web and records POST /result payloads from `?auto=1` runs.

Usage (from experiments/dart_worker_poc):
    dart run tool/build_worker.dart
    flutter build web --release
    python3 tool/measure_server.py
    # then open http://127.0.0.1:8082/?auto=1 in a browser

Results are written next to this script as `results/run-<timestamp>.json`.
"""

import http.server
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "build" / "web"
OUT = ROOT / "results"
OUT.mkdir(exist_ok=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB), **kwargs)

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        (OUT / f"run-{stamp}.json").write_bytes(body)
        print("wrote", stamp, len(body), "bytes", flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


print("serving", WEB, "on http://127.0.0.1:8082", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", 8082), Handler).serve_forever()
