# Wasm worker example

Shows the opt-in dart2wasm worker backend (ADR-018). `dwi.yaml` declares the
target once; the Flutter build hook and `dwi build` read it.

```bash
cd examples/wasm_worker
dart pub get
dart run dwi_builder:dwi build     # or `dwi build --target=wasm`
dart compile js -O1 -o web/main.dart.js lib/main.dart
# serve web/ with .wasm as application/wasm and .mjs as text/javascript
```

The host configures:

```dart
Dwi.configure(const DwiConfig(
  workerBackend: DwiWorkerBackend.wasm,
  workerScript: DwiConfig.defaultWasmWorkerScript, // dwi/worker.boot.mjs
));
```

Deployment requirements: `.wasm` served as `application/wasm`, `.mjs` as a
JavaScript MIME, the entry and its `gen-<hash>/` directory same-origin with the
page, and a CSP that allows `worker-src` plus `'wasm-unsafe-eval'`. Unsupported
configurations raise a typed `DwiStartupException`; there is no JS or
main-thread fallback.

`target: js` (or omitting `dwi.yaml`) keeps the default dart2js worker. The
Flutter workload can request the same target without a separate command.
