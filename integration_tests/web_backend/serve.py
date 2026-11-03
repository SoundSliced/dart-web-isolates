"""Serves build/ and records POST /result for the web backend integration test.

Usage (from integration_tests/web_backend):
    dart pub get
    dart compile js -O1 -o build/worker.js worker.dart
    dart compile js -O1 -o build/client.js test_client.dart
    cp index.html build/index.html
    python3 serve.py
    # open http://127.0.0.1:8090/ in a browser
"""

import http.server
import pathlib
import time

ROOT = pathlib.Path(__file__).resolve().parent
WEB = ROOT / "build"
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


print("serving", WEB, "on http://127.0.0.1:8090", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", 8090), Handler).serve_forever()
