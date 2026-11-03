# M001 — Dart in a Worker (proof of concept)

Question: can a Flutter Web app run CPU-bound Dart code in a browser Web Worker
while the Flutter UI keeps rendering?

Answer: yes, with limitations. See [`M001_FINDINGS.md`](M001_FINDINGS.md).

## What is here

| File | Purpose |
| --- | --- |
| `lib/main.dart` | Flutter UI: running animation, main-thread and worker buttons, live frame stats, measured comparison table, `?auto=1` headless mode |
| `lib/src/primes.dart` | Prime sieve shared by both programs |
| `worker.dart` | Worker entrypoint, compiled separately with `dart compile js` |
| `tool/build_worker.dart` | Compiles the worker into `web/dwi/worker.dart.js`, refuses silently-stale artefacts |
| `evidence/` | Raw JSON from Chrome measurement runs |
| `M001_FINDINGS.md` | Verdict, measurements, limitations |

## The demo

- A repeating animation runs continuously.
- **RUN ON MAIN THREAD** runs 40 sieve passes of 5,000,000 on the page's thread.
- **RUN ON DWI WORKER** runs the same work in a dedicated Web Worker started from
  `dwi/worker.dart.js`.
- The UI reports task wall time, frames rendered during the task, estimated
  dropped frames at 60 Hz, worst frame, worker startup and message round trip.
- All numbers are measured. There are no illustrative values.

## Running it

Requirements: Flutter (Dart 3.13+), Chrome. The worker is compiled separately;
`flutter build web` does not compile secondary entrypoints.

```bash
cd experiments/dart_worker_poc
flutter pub get
dart run tool/build_worker.dart        # -> web/dwi/worker.dart.js
flutter build web --release
# serve build/web over HTTP (workers cannot be constructed from file://)
python3 -m http.server 8080 --directory build/web
```

Open `http://127.0.0.1:8080/` and press both buttons.

### Headless measurement

The page supports `?auto=1`: it runs the worker task, an error probe and the
main-thread task, then POSTs the JSON result to `/result`.

```bash
# terminal 1: a server that records POST /result
python3 tool/measure_server.py

# terminal 2
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --no-sandbox --disable-gpu \
  --user-data-dir="$TMPDIR/chrome-m001" "http://127.0.0.1:8082/?auto=1"
```

Why `--no-sandbox`: this development sandbox blocks Chrome's own sandbox
initialisation. It is a harness workaround, not a recommendation.

## Design notes (constraints found while building this)

1. **The worker is a second program.** It is compiled with `dart compile js` and
   served as a static file; Flutter's build copies `web/` into `build/web/`.
2. **No closures cross the boundary.** The UI sends an operation name
   (`primes`) and parameters; the worker has a compiled dispatch table.
3. **Startup is visible but small.** Measured 7–15 ms after an initial load, but
   the script is ~160 KB and includes the Dart runtime.
4. **Frame counting must come from a Ticker, not frame timings.** A fully
   blocked main thread produces *no* `FrameTiming` entries for the blocked
   period, so "worst frame" understates the stall. `framesDuring` is the Ticker
   delta and `droppedFrames` is derived from wall time at 60 Hz.
5. **Cache busting matters.** Chrome cached the worker script and the app bundle
   across rebuilds; the worker URL carries `?v=2` and headless runs use a fresh
   profile.
