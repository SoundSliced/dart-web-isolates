# R010 — Upstream Dart and Flutter Issues

Status: research report · Evidence: GitHub issue metadata fetched 2026-11-03 via
the authenticated `gh` CLI. Issue bodies and dates are quoted; conclusions drawn
from them are marked as inference.

## Summary

- The Dart SDK has an open design-space issue for web concurrency:
  `dart-lang/sdk#55364` (opened 2024-04-03, updated 2025-10-15) explicitly
  discusses a *simplified* isolate model for Wasm with limited transferable types
  and duplicated data.
- Flutter's request for real web background compute is `flutter/flutter#33577`
  (opened 2019-05-30, updated 2025-01-14, 103 comments, still open).
- The `dart:isolate` web stub has been a known, deliberate limitation for a
  decade: `dart-lang/sdk#32684` "Deprecate `dart:isolate` on the web" (closed
  2020) and `dart-lang/sdk#4689` "dart2js not using web worker for isolate"
  (closed 2015).
- Flutter already ships WebAssembly workers in its renderer: `flutter/flutter#193801`
  "Use Wasm Worker semaphores for contended Skia locks" was closed on
  2026-11-03, describing `-sWASM_WORKERS=1` and worker-side semaphores.
- Inference: upstream appetite exists for *restricted* concurrency, but not for
  pretending web isolates are VM isolates. A proposal that promises full
  `dart:isolate` parity will be rejected; one with measured limits and a small
  compiler/tooling surface has a plausible path.

## Key issues

### `dart-lang/sdk#55364` — Shared-Everything Threads and isolates on web

- State: open. Created 2024-04-03, last updated 2025-10-15, 9 comments.
- Body: “Currently, `dart2wasm` lacks support for isolates”; references the
  WebAssembly `shared-everything-threads` proposal as an upstream dependency and
  states “It will takes years until this is fully specified and implemented”.
- It reports a suggestion from a Dart team member (`@mraleph`) that a simplified
  isolate model is possible with limitations: only specific types transferable,
  and data transfer requires duplication.
- Relevance: this is the closest thing to an upstream statement that a
  worker-backed, copy-based isolate model is acceptable *as a limited feature*.
  It also confirms that shared-memory isolates are not imminent.

### `flutter/flutter#33577` — Support compute on a separate thread in Flutter Web

- State: open. Created 2019-05-30, last updated 2025-01-14, 103 comments.
- Body quotes an older web `compute` implementation that simply calls the
  callback and states it “freezes the web UI”.
- Current source (R002) adds `await null` before the callback, which yields a
  microtask but does not make the work concurrent. The issue's complaint is
  unchanged in substance.
- Relevance: names the product gap DWI addresses and shows sustained demand.

### `flutter/flutter#145132` — Wasm isolates unsupported (ReceivePort error)

- State: closed. Reported 2024, closed 2024-03-28.
- Reproduces `Unsupported operation: ReceivePort` under `flutter build web --wasm`
  and discusses COOP/COEP serving.
- Relevance: confirms R005's finding from a user-facing angle; also shows that
  cross-origin isolation is already part of Flutter Wasm deployment advice.

### `flutter/flutter#193801` — Wasm Worker semaphores for Skia locks

- State: closed 2026-11-03 (same day as this research).
- Body: “With `-sWASM_WORKERS=1` without pthreads, SkSemaphore's contended path
  calls POSIX semaphore stubs… Use Emscripten's Wasm Worker semaphores… Workers
  block while waiting; the browser main thread retries a nonblocking acquire.”
- Relevance: Flutter's own engine already runs Wasm workers and coordinates them
  with semaphores. This is evidence that worker-based concurrency is acceptable
  inside Flutter's architecture — for engine work, at least.

### `dart-lang/sdk#32684` — Deprecate `dart:isolate` on the web

- State: closed (2020-11-12).
- Relevance: historical record that the stub is intentional. Any proposal to
  “just implement isolates” must explain why the earlier decision should change.

### `dart-lang/sdk#4689` — dart2js not using web worker for isolate

- State: closed (2015-06-03).
- Relevance: the idea is at least a decade old; the blocker has always been the
  object model and build pipeline, not awareness.

## What this implies for an upstream strategy

1. **Do not propose `dart:isolate` parity.** Propose a restricted runtime with
   enumerated transferable types and explicit copy semantics — the shape
   `#55364` already contemplates.
2. **Bring measurements, not architecture diagrams.** The Flutter issue has 103
   comments and no implementation; a benchmark-backed proposal is the differentiator.
3. **Start at the tooling edge.** A package that compiles worker entrypoints and
   a protocol that survives review is a smaller ask than compiler changes.
4. **Respect the Wasm split.** JS workers can ship now; Wasm workers depend on
   loader and COOP/COEP work and should be a separate proposal.
5. **Align with existing engine practice** (`#193801`): workers + semaphores are
   already used internally, so the argument is about the *Dart developer API*,
   not whether workers are acceptable.

## Unresolved

- Whether any Dart team member has published a design doc beyond the comments in
  `#55364`.
- Current status of the `shared-everything-threads` proposal in 2026 (not fetched).
- Whether Flutter's web `compute` could be changed without a breaking semantic
  change; no maintainer statement found.

## Verification status

- **Verified**: issue numbers, states, dates, quoted body text (GitHub API,
  2026-11-03).
- **Unverified**: proposal status, internal Dart team plans, any unpublished
  design work.
