# DWI 0.8.0 — release review (prepared, not published)

Status: **published to pub.dev on 2026-11-10** from `main` at `fcb8af6`, in the
upload order below, with each package verified before the next
(`audit/evidence/pub-0.8.0-upload-2026-11-10.txt`). This release adds the opt-in
dart2wasm worker backend (ADR-018); the dart2js worker remains the default and
its contracts are unchanged.

| Package | Version | Upload order |
| --- | --- | --- |
| `dwi_annotations` | 0.8.0 | 1 |
| `dwi_protocol` | 0.8.0 | 2 |
| `dwi_core` | 0.8.0 | 3 |
| `dwi_native` | 0.8.0 | 4 |
| `dwi_web` | 0.8.0 | 5 |
| `dwi_builder` | 0.8.0 | 6 |
| `dwi` | 0.8.0 | 7 |

Upload in that order: the `^0.8.0` constraints must be satisfiable on pub.dev
before the dependent package is uploaded. `dwi` depends on `dwi_annotations`,
`dwi_core`, `dwi_native` and `dwi_web`; `dwi_builder` on `dwi_annotations`;
`dwi_native` and `dwi_web` on `dwi_core`; `dwi_web` also on `dwi_protocol`.

## Highlights

### 1. Opt-in dart2wasm worker (ADR-018)

```dart
await Dwi.configure(const DwiConfig(
  workerBackend: DwiWorkerBackend.wasm,
  workerScript: DwiConfig.defaultWasmWorkerScript, // dwi/worker.boot.mjs
));
```

or, for the Flutter hook and CLI together:

```yaml
# dwi.yaml
target: wasm
```

- Default stays `DwiWorkerBackend.js`. There is no automatic fallback to JS or
  the main thread.
- `dwi build --target=wasm` publishes a content-addressed `gen-<hash>/`
  directory (module and compiler loader) plus a small `worker.boot.mjs` entry.
  The entry is switched atomically only after the generation is complete, so a
  reader sees the old pair or the new pair, never a mix.
- The manifest records `target`, `generation`, and a SHA-256 digest per file.
  `dwi check` rejects mixed, corrupt or target-mismatched sets; `clean` removes
  every generation. A normal build never deletes a published generation: a
  browser can keep the `worker.boot.mjs` it cached, and that bootstrap names one
  generation until it is revalidated. Old generations are removed only by an
  explicit deployment-maintenance action (ADR-018, amended 2026-11-10).
- The worker reports its compiler in the `ready` capabilities; a
  requested/observed mismatch is a typed `DwiStartupException`.
- Generated `int` decoders and worker/host channel meta accept integral
  doubles, which a dart2wasm boundary yields.

### 2. One target setting for Flutter and the CLI

The Flutter build hook and `dwi build` both read `dwi.yaml`; an explicit
`--target` overrides it. Invalid settings fail the build. The hook declares the
file as a dependency, so a target change re-runs it. The hook can never replace
a requested Wasm worker with a JS one.

### 3. Deployment and cache contract

`.wasm` must be served as `application/wasm`, `.mjs` as a JavaScript MIME, the
entry and its generation must be same-origin with the page, and a CSP must allow
`worker-src` plus `'wasm-unsafe-eval'`. Unsupported configurations produce a
typed `DwiStartupException`; message text differs per engine. Non-root base
paths need no rebuild.

Generation retention is a deployment rule, because a cached bootstrap can name
an older generation:

- Upload every `gen-<generation>/` directory the new entry references **before**
  replacing `worker.boot.mjs`; delete old generations **last**.
- Serve `worker.boot.mjs` with `no-cache` (or a `max-age` shorter than the
  generation retention window) and `gen-*` files as immutable
  (`Cache-Control: public, max-age=31536000, immutable`).
- Keep a generation for as long as any bootstrap that names it can still be
  served from a cache. A client is safe only while its generation is retained by
  the deployment or still in the browser cache.
- A cached bootstrap whose generation is gone fails with a typed
  `DwiStartupException`; it never executes a mixed generation. That configuration
  is unsupported, not silently tolerated.
- `dwi clean` deletes all generations; it is a local reset, not a deployment
  operation.
- Flutter 3.47.6's generated service worker caches nothing (it unregisters
  itself), so these are HTTP cache-header decisions, not service-worker
  decisions.

## Verification (2026-11-10)

- Analysis: zero issues in all seven packages and `benchmarks/wasm_worker`.
- VM suites: `dwi_core` 35, `dwi_protocol` 14, `dwi_native` 62, `dwi_web` 24,
  `dwi` 38 — all pass.
- `dwi_builder` non-browser suite: 65/65, including publication fault injection,
  mixed-set rejection, generation retention and the shared target switch.
- Browser regression (dart2js worker): 10/10, including the handle and scoped
  contracts in Chrome, Safari, Firefox and Edge.
- Wasm-worker deployment: the live-rebuild test with realistic cache headers
  (entry `no-cache`, generations `immutable`) passes in Chrome, Safari, Firefox
  and Edge across three successive deployments. The cached-bootstrap retention
  case passes at `/` and `/sub/app/` in all four engines (generation A keeps
  loading across B, C and D builds), and a removed generation fails typed
  without requesting any other generation
  (`audit/evidence/cached-bootstrap-deployment-2026-11-10.txt`).
- Flutter 3.47.6 production build in Chrome 157, Edge 157, Firefox 159 and
  Safari 26.5: the generated service worker is a self-unregistering stub with no
  cache, so cache behaviour comes from the deployment headers. A cached client
  keeps working while its generation is retained or cached, and fails typed once
  the generation is pruned
  (`audit/evidence/flutter-production-cache-four-engines-2026-11-10.txt`).
- Wasm worker contracts: Chrome, Edge, Firefox and Safari, `dart2js` and
  `dart2wasm` hosts, at `/` and `/sub/app/`; the `dart2wasm` host + `dart2js`
  worker control also passes. Contracts: typed proxy, unknown task, state,
  cancellation/stop reason, restart, crash detection, channels, transferable
  bytes, timeout recovery, prompt close with a paused listener, and typed
  startup failures.
- Post-publication checks: queue timeout and prompt close with a paused stops
  listener pass in all four engines at `/` and `/sub/app/` on the
  content-addressed layout.
- Deployment: correct MIME at `/` and `/sub/app/`; wrong MIME, missing/corrupt
  companions, blocked CSP and cross-origin workers all fail typed.
- Benchmark: `audit/evidence/wasm-worker-benchmark-2026-11-10.json` (Chrome 157).
  Wasm worker artefact ~68% smaller; startup and dispatch comparable; Wasm
  faster on the measured sieve workload; both keep the UI timer running while
  the main-thread control blocks it.

## Archive inspection and dry-runs

Run on 2026-11-10 with Dart 3.13.5: `dart pub publish --dry-run` in all seven
packages. **7/7 completed with exit 0 and zero warnings.** Compressed archive
sizes: `dwi_annotations` 3 KB, `dwi_protocol` 5 KB, `dwi_core` 15 KB,
`dwi_native` 16 KB, `dwi_web` 19 KB, `dwi_builder` 66 KB, `dwi` 10 KB.

The only notices were hints that `pubspec_overrides.yaml` (present for local
path development in `dwi`, `dwi_builder`, `dwi_native` and `dwi_web`) overrides
non-dev dependencies. That is expected on this checkout; the published
constraints are `^0.8.0`.

## Publication (2026-11-10)

All seven packages were uploaded in the order above, each verified on pub.dev
before the next. A clean consumer declaring every package at `^0.8.0` with no
path overrides resolves the whole graph from pub.dev (`dwi` 0.8.0 depends on
`dwi_annotations`, `dwi_core`, `dwi_native` and `dwi_web`; `dwi_web` on
`dwi_core` and `dwi_protocol`). pub.dev edge indexing lagged the upload by
minutes per package; the public API listed the new version before the pub client
did. Details: `audit/evidence/pub-0.8.0-upload-2026-11-10.txt`.

## Compatibility and limits

- No default change; no protocol v2 wire change.
- Not measured: debug/profile wasm-host builds, hot restart, cross-origin
  worker assets (rejected by the engines), browser cache eviction/revalidation
  timing, a dart2wasm host in the cached-bootstrap fixture, and non-Chrome
  benchmarks. Flutter's service worker was measured in 3.47.6 only, where it
  caches nothing.
- Fresh Flutter projects still need the one-time proxy generation before the
  first build; the typed-proxy ordering limitation is unchanged.
