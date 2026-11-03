# Web backend integration test

Exercises the real protocol end to end in a browser:

- `worker.dart` — a worker entrypoint speaking DWI protocol v1, with `echo`,
  `primes` and `boom` tasks plus unknown-task handling.
- `test_client.dart` — compiled with dart2js; drives `dwi_web`'s `WebBackend`
  and posts a JSON report.
- `index.html` / `serve.py` — harness.

## Run

```bash
cd integration_tests/web_backend
dart pub get
dart compile js -O1 -o build/worker.js worker.dart
dart compile js -O1 -o build/client.js test_client.dart
cp index.html build/index.html
python3 serve.py &
# open http://127.0.0.1:8090/
# headless:
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --no-sandbox --disable-gpu \
  --user-data-dir="$TMPDIR/chrome-dwi-it" http://127.0.0.1:8090/
```

Results are written to `results/run-<timestamp>.json` (gitignored) and rendered
on the page.

## What it proves

| Check | Expected |
| --- | --- |
| `echo` round trip | `{"a": 1}` returned unchanged |
| unknown task | `DwiUnknownTaskException` with the task name |
| task throwing | `DwiRemoteException` with `remoteType: StateError` and a captured stack |
| capabilities | `backend: worker`, `protocolVersion: 1` |

It does **not** prove: Firefox/Safari/Edge behaviour, Wasm, transferables above
the structured-clone path, or cancellation.
