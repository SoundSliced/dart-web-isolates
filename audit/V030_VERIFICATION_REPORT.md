# DWI v0.3 — Independent Verification Report

- **Audit date:** 2026-11-03
- **Repository:** `SoundSliced/dart-web-isolates` @ `e105f29` + uncommitted v0.3 work
- **Auditor:** lead-engineer audit (independent of the v0.3 implementation report)
- **Verdict:** **PASS WITH CRITICAL LIMITATIONS.** Every reported v0.3 capability
  exists in source and the 61 reported unit tests reproduce. However, the
  advertised payload type support does not survive a browser round-trip, and the
  worker pool can starve queued callers forever after a timeout. v0.3 must not
  be described as production-ready until the fixes below land.

## 1. Environment

| Item | Value |
| --- | --- |
| OS | macOS arm64 |
| Dart SDK | 3.13.5 (stable), invoked directly from the Flutter SDK cache |
| Flutter | 3.47.6 (stable), engine `b8c8d3d8d5d0` |
| Browser | Google Chrome 156 (headless + interactive) |
| Node | v24.19.0 |
| Package cache | `~/.pub-cache` is read-only in the audit sandbox; a writable copy (`PUB_CACHE=$TMPDIR/pubcache`) was used for `dart pub get --offline` |

No Flutter or Dart SDK file was modified. Because the installed Flutter cache is
read-only in the sandbox, a writable *shadow* Flutter root (symlinks to the SDK
plus a writable `bin/cache`) was created under `$TMPDIR` to run `flutter build
web`. This is an environment workaround, not a DWI change.

## 2. Reported capabilities vs. observed evidence

| Capability | Source exists | Independently observed |
| --- | --- | --- |
| `@DwiTask` annotation discovery (resolved AST) | yes, `discovery.dart` | yes |
| Deterministic worker entrypoint + typed proxies | yes, `generator.dart` | yes, byte-stable on repeated runs |
| Manifest + SHA-256 caching | yes, `builder.dart`/`hasher.dart` | yes; cache hit, invalidation on dependency changes |
| `dart compile js` compilation | yes, `toolchain.dart` | yes (257 KB worker, hash `e1bc001efa54`) |
| Diagnostics `DWI001`–`DWI010` | partially | codes exist, but type support is misclassified (§4, F-01) |
| Chrome integration | no committed automatic-worker evidence | yes, re-run by this audit |
| 61 tests | yes | yes: protocol 8, core 10, native 6, web 8, dwi 7, annotations 2, builder 20 |

`integration_tests/README.md` still says "Nothing has been implemented yet" and
the only committed browser evidence (`integration_tests/web_backend/evidence/
chrome-156.json`) predates the automatic-worker path. The v0.3 claim "verified in
Chrome" was therefore not backed by committed evidence; this audit supplies new
evidence under `audit/evidence/`.

## 3. Test and build commands

```bash
# Unit tests (7 packages)
export PATH=<dart-sdk>/bin:$PATH
export PUB_CACHE=$TMPDIR/pubcache
for p in packages/dwi_protocol packages/dwi_core packages/dwi_native \
         packages/dwi_web packages/dwi packages/dwi_annotations \
         packages/dwi_builder; do
  (cd "$p" && dart pub get --offline && dart test --reporter=expanded)
done

# Example
cd examples/automatic_worker
dart run dwi_builder:dwi build --force
dart compile js -O1 -o web/main.dart.js lib/main.dart
python3 -m http.server 8791 --directory web

# Separate Flutter consumer (scratch app)
flutter create --no-pub --platforms=web --project-name dwi_consumer <app>
# add path deps on dwi, dwi_annotations, dwi_builder; add @DwiTask tasks
dart run dwi_builder:dwi build --flutter-build -- --release --base-href /sub/app/
# serve build/web under <root>/sub/app and open it
```

Observed results:

- All 61 tests passed on Dart 3.13.5.
- `examples/automatic_worker` displayed **`Hello, DWI! Primes: 148933 (110 ms)`**
  from the worker-backed generated proxies.
- A raw-protocol probe received `ready` and then
  `{"type":"result","id":1,"payload":25}` for `calculatePrimes(100)`.
- Separate Flutter release app served at `/sub/app/`: `document.title` became
  **`DWI:Hello, Flutter! sum=500500`** and the browser requested
  `/sub/app/dwi/worker.dart.js`. Base href and subpath deployment are correct.
- Cache: unchanged → reused (`2a0e8cf2e720`); local helper edit → recompiled
  (`ff87d9e73df8`); cross-package helper edit → `dwi check` failed, rebuild
  recompiled. Generated worker text did not change, so dependency hashing works.

## 4. Defects found

Severity is impact on users of the v0.3 surface. "Fixed" refers to the follow-up
patch made during this audit (§7).

### F-01 — CRITICAL: typed collections and interface types do not round-trip

Discovery accepts `List<T>`, `Map<K,V>`, `Set<T>` and (with a warning) custom
classes, enums and `DateTime`. In Chrome, only primitives, `dynamic`, `Object?`
and `FutureOr<T>` of those work.

| Declared task signature | Observed |
| --- | --- |
| `List<int> echo(List<int>)` | worker: `JSArray<dynamic>` is not `List<int>` |
| `List<int>? echo(List<int>?)` | worker: `JSArray<dynamic>` is not `List<int>?` |
| `Set<int> echo(Set<int>)` | worker: `JSArray<dynamic>` is not `Set<int>` |
| `Map<String,int> echo(Map<String,int>)` | worker: `JsLinkedHashMap<Object?,Object?>` is not `Map<String,int>` |
| `List<int>` return, called as `Dwi.run<List<int>>` | host: `DwiResultTypeException`, returned `JSArray<dynamic>` |
| `dynamic makePoint(int)` returning a class | typed proxy returned `{}` and passed the `is Point` check |
| `dynamic makeColor(int)` returning an enum | typed proxy returned a plain JS object and passed the `is Color` check |

Cause: the wire codec is `Map.jsify()` / `JSAny.dartify()` with no type-directed
decoding. `jsify` erases Dart generic types, turns `Set` into a JS array, and
turns arbitrary objects into plain JS objects. Class/enum proxy results are
**silently type-unsound**, which violates the "generated Dart types are accurate"
requirement.

Status: **fixed in the v0.3 patch by rejecting types that cannot round-trip at
build time** (typed collections, classes, enums, `DateTime`, unknown interface
types). Untyped `List`/`Map`/`Set` payloads remain available through `dynamic`.
A real type-directed codec is v0.4 work; see the v0.4 ADR.

### F-02 — CRITICAL: queued callers starve forever after a timeout or worker failure

Reproduction: `maxWorkers=2`, `maxQueuedTasks=2`, `taskTimeout=700 ms`, then six
concurrent `slow(5000)` calls. The two running calls time out and their workers
are removed by `_terminate`, but `_terminate`/`_fail` never wake `_waiters`, and
released capacity is never re-offered. The two queued calls never complete (the
harness guard fired after 6 s). Every later call can also be stuck behind those
stale waiters.

Status: **fixed in the v0.3 patch** (replacement workers are spawned for waiters
after termination/failure, with tests).

### F-03 — HIGH: non-cloneable payloads are silently delivered as `{}`

- Returning a closure from a task (`dynamic badValue(...) => (int x) => x`)
  produced `badResult=OK:{}`.
- Passing a closure as input produced `badInput=OK:{}`.

`jsify()` does not throw for Dart functions in this SDK; it yields an empty JS
object, which structured-clones successfully. The previous claim that
`DwiWorkerRuntime._send` catches serialization failures does not cover this case.

Status: **fixed in the v0.3 patch** by validating payloads before send (host and
worker) and failing with `DwiSerializationException`.

### F-04 — HIGH: a synchronous `postMessage` failure leaks a busy worker slot

In `WebBackend.run`, `slot.pending[id]` is registered and the slot is marked
busy, but `postMessage` runs before the `try/finally`. A `DataCloneError` (for
example, an unsupported value that validation misses, or a future transfer list)
throws out of `run` and the slot stays busy forever, reducing pool capacity and
leaking the pending completer.

Status: **fixed in the v0.3 patch** (guarded send; slot released on failure).

### F-05 — MEDIUM: `capabilities().transferables` is a false claim

`WebBackend.capabilities()` returns `transferables: true` whenever the global
`ArrayBuffer` exists, which is always true in a browser. DWI v0.3 has no
transfer API and copies everything. This violates the "do not emulate
unsupported behaviour deceptively" rule and the capability's own name.

Status: **fixed in the v0.3 patch** (returns `false` until transfer semantics
exist).

### F-06 — MEDIUM: `DwiConfig.maxPayloadBytes` is not enforced (fixed approximately)

The field is validated (`> 0`) and documented as an upper bound, but v0.3 code
never measured or rejected a payload. Large payloads could block the main thread
during `jsify`/structured clone with no limit.

Status: **fixed approximately in the v0.3.1 patch.** The payload validator
counts an estimated size (primitives, string code units, container overhead,
typed-data bytes), the host enforces `maxPayloadBytes` before sending, and the
limit is carried in request metadata so the worker rejects oversized results.
The estimate is a resource guard, not an exact wire size.

### F-07 — MEDIUM: docs say `dwi generate` writes the manifest; it does not

`build_test.dart:34` asserts that generation-only writes no manifest, while
`docs/automatic-workers.md` and its pipeline diagram show
`.dwi/worker_manifest.json` as a generation output. Observed: after `generate`,
the old manifest (with `"compiled": true` and a stale hash) remains, and
`dwi check` reports a hash mismatch. `dwi build --no-compile` behaves the same
way but still prints the manifest path.

Status: **fixed as a documentation correction** (manifest is written by
compilation; `generate`/`--no-compile` intentionally do not claim a compiled
artefact). The CLI output is adjusted to say so.

### F-08 — MEDIUM: breaking API rename shipped without a version bump

ADR-008 renames the `DwiTask` typedef to `DwiTaskFunction`. Any downstream code
declaring a parameter of type `DwiTask` (the old function typedef) now fails to
compile, and any code importing `package:dwi/dwi.dart` expecting `DwiTask` to be
that typedef now gets the annotation class. `packages/dwi`, `dwi_core`,
`dwi_native`, `dwi_web` and `dwi_protocol` still declare `version: 0.2.0` while
`CHANGELOG.md` calls the release 0.3.0.

Status: **fixed in the v0.3 patch** (all packages bumped to 0.3.0 and the
migration note is explicit).

### F-09 — LOW: `close()` is not terminal

`Dwi.close()` nulls the backend; the next `Dwi.run` lazily creates a fresh
backend with default configuration and succeeds (`afterClose=OK:1`). This is
consistent with "forgets configuration" but contradicts a natural reading of
"terminates workers and closes". Either behaviour is defensible; it must be
documented.

Status: open (documented).

### F-10 — NOT A DEFECT: duplicate exception name was probe formatting

The probe printed `'${error.runtimeType}: $error'`, while `DwiException.toString`
already starts with the runtime type, producing the apparent duplicate. The
library output is correct (`DwiUnknownTaskException: unknown task "missing"`).
No change made.

Status: closed, not a defect.

### F-11 — LOW: cache hash is not portable for out-of-project dependencies

`computeWorkerHash` uses an absolute path as the label for files outside the
project root. Two machines/checkouts therefore hash the same source differently.
This does not break local invalidation but makes remote/shared caches impossible.

Status: open; v0.4.

### F-12 — INFO / RISK: worker URL has no cache-busting

The worker is always fetched from `dwi/worker.dart.js`. After a deployment, a
browser HTTP cache or a Flutter service worker may serve an old worker while the
app bundle is new. This was **not measured**; no cache-busting mechanism exists
in the code.

Status: open; v0.4 (content-hash query parameter in the manifest and config).

### F-13 — INFO: watcher scope

`dwi watch` polls only `--include` paths plus `pubspec.yaml` (500 ms). It does
not watch cross-package dependencies (which do invalidate the hash on a build)
and it does not trigger a page reload or a Flutter rebuild.

Status: open; Mission 3.

### F-14 — INFO: no genuine crash-path test

`onerror` and termination are covered manually; a worker killed by the browser
(OOM, renderer crash) was not reproduced. `onmessageerror` is not subscribed.
Firefox, Safari and Edge were not exercised. `dart2wasm` worker generation does
not exist (JS backend only).

## 5. Rename analysis (`DwiTask` → `DwiTaskFunction`)

- The old `typedef DwiTask = Object? Function(Object? input)` is gone from
  `dwi_core`; `DwiTaskFunction` replaces it and is exported by `package:dwi`.
- The name `DwiTask` is now the annotation class from `dwi_annotations`.
- Source compatibility breaks only for code that used the **type**, not the
  annotation. Such code fails loudly at compile time (no silent mismatch).
- Worker generated code and the public facade are internally consistent.
- Defect: the package versions were not bumped (F-08, fixed here).
- Recommendation: keep the rename (the annotation name is the better public
  name), publish migration notes, and add a `deprecated` alias of the old
  typedef only if a v0.2 consumer actually exists. No downstream repository is
  present in this workspace to measure real breakage.

## 6. Browser and platform coverage

| Target | Status |
| --- | --- |
| Chrome 156, dart2js, Flutter Web release | **verified by this audit** |
| Chrome 156, plain `dart compile js` app | **verified by this audit** |
| Chrome 156, subpath `/sub/app/` + base href | **verified by this audit** |
| Firefox / Safari / Edge | **not verified** (unverified, not failed) |
| Chrome with `dart2wasm` workers | **unsupported** (no Wasm worker generation) |
| Native isolates | 6 VM tests pass; unchanged |
| Flutter tasks importing `package:flutter`/`dart:ui` | **rejected by design** (`DWI002`) |

## 7. Fixes applied in this audit (Mission 2)

Verified after the fixes (Chrome probe, `audit/evidence/runtime-fixes-2026-11-03.txt`):

- `badResult`/`badInput` now throw `DwiSerializationException` (previously `OK:{}`).
- Six concurrent tasks under a 2-worker/2-queue cap settle in 1018 ms
  (four `DwiTimeoutException`, two `DwiUnsupportedException`) instead of hanging.
- Timeout and non-cooperative tasks still recover for the next call.
- `capabilities.transferables` is `false`.
- All 76 package tests pass (8 protocol, 10 core, 6 native, 16 web, 7 facade,
  2 annotations, 27 builder); `dart analyze` reports no issues in the changed
  packages; the automatic-worker example still runs in Chrome.

1. Worker-pool scheduling: waiters are woken and replacement workers spawned on
   termination/failure; queued callers no longer starve (F-02).
2. Guarded `postMessage`, slot release on send failure (F-04).
3. Payload validation in both directions, `DwiSerializationException` instead of
   silent `{}` (F-03).
4. Build-time rejection of types that cannot round-trip: typed collections,
   classes, enums, `DateTime`, unknown interface types (F-01).
5. `transferables: false` until transfer semantics exist (F-05).
6. Package versions bumped to 0.3.0 (F-08).
7. Documentation corrected: manifest is a compilation output; supported payload
   matrix; limitations.

## 7a. Mission 3 — Zero-command Flutter Web (ADR-009)

The v0.3 research conclusion "Flutter exposes no web build hook" is **false for
Flutter 3.47.6** and is corrected by ADR-009.

- `flutter_tools` contains `BuildHooks(platform: HookPlatform.web)` and wires it
  into the web build graph (`build_system/targets/web.dart:604`).
- `flutter build web --release -v` logs `Running build hooks for web` and runs
  `hook/build.dart` before `dart2js`; `flutter run -d web-server` does the same
  in debug mode.
- A probe hook successfully ran `Process.run('dart', ['--version'])`, wrote
  files, and read the app's package config through `Platform.packageConfig`.
- Only **regular dependencies** are scanned for hooks: a dev-dependency hook and
  an app-root `hook/build.dart` did not run.
- `dwi_builder` now ships `hook/build.dart`. With `dwi_builder` as a normal
  dependency, the hook finds the app package, runs `DwiBuilder`, and declares
  task dependencies for caching.
- End-to-end observed: `flutter build web --release --base-href /sub/app/`
  produced `web/dwi/worker.dart.js` and `build/web/dwi/worker.dart.js`; changing
  a task re-ran the hook; an unchanged build printed
  `Skipping target: build_hooks`.
- Resolver unit tests: `packages/dwi_builder/test/hook_support_test.dart`
  (5 tests ).

Limitations: Flutter >= 3.47 only; `dwi_builder` becomes a normal (build-time)
dependency, pulling `analyzer` into the app's package graph; hooks expose no
target OS, so multi-platform apps with `web/index.html` also run the cached
worker build for native targets; Dart workspaces without an app-local package
config are not resolved; a running worker still needs a page reload. The CLI
remains for older Flutter, plain Dart web apps and CI.

Not fixed (tracked for v0.4): cache-busting (F-12), portable cross-package
hashes (F-11), `close()` recreation semantics (F-09), watcher scope (F-13),
genuine crash and multi-browser coverage (F-14).

## 7b. Mission 4/5 status (v0.4+)

**Implemented and verified in this patch (non-breaking):**

- Bounded queue with waiter wake-up/replacement after timeout or worker failure
  (F-02), and slot release on `postMessage` failure (F-04).
- Approximate `maxPayloadBytes` enforcement in both directions (F-06).
- Typed serialization failures in both directions (F-03).
- Timeout and non-cooperative-task termination with recovery; concurrent requests
  and queue overflow exercised in Chrome (`audit/evidence/runtime-fixes-2026-11-03.txt`).

**Proposed but NOT implemented (ADR-010, requires API approval):**

- Queued-task cancellation and cancellation of running tasks via termination;
  cooperative cancellation tokens.
- Transferable binary data with explicit ownership/detach semantics.
- Heartbeat-based crash detection and a bounded restart policy.
- Committed browser stress/benchmark suites and Firefox/Safari/Edge coverage.

v0.5 (ports/streams/diagnostics), v0.6 (Wasm worker backend), v0.7 (Flutter
integration beyond the build hook), v0.8 (compiler integration), v0.9 (SDK
isolate compatibility) and v1.0 are **not started**. No claim in this report
should be read as completing them.

## 8. What was verified, what was not, what could not be determined

**Verified:** source-level presence of every reported v0.3 feature; all 61
original unit tests (76 after the audit's regression tests); example build and
browser execution; automatic worker generation and compilation; cache hit, local
and cross-package invalidation; `dwi check` stale detection; a separate Flutter
release app under a subpath; error propagation, timeouts, concurrency, worker
recovery, and generated-type round-trips in Chrome; Flutter web build hooks on
Flutter 3.47.6, including a zero-command `flutter build web` integration.

**Not verified:** Firefox/Safari/Edge; real browser crashes (OOM/process kill);
hot reload of a running worker; very large payloads; deployment through a CDN or
Flutter service worker cache; Windows/Linux; Flutter versions older than 3.47.

**Could not determine:** whether `dart2wasm` can host workers with the current
protocol without a second toolchain; real downstream usage of the old `DwiTask`
typedef (no consumer repositories available); whether a future Flutter release
keeps the web hook surface unchanged (ADR-009 depends on it).
