# Upstream Strategy

How DWI could become more than a package, and what must be true first.
Evidence: R010 (issues), R002 (Flutter build), R005 (Wasm).

## Position

DWI starts as a package. SDK and Flutter changes are **not** part of v1.0 and
must not be required for it (master plan §53). The upstream path is a
consequence of evidence, not a plan the package depends on.

## What upstream would need to believe

1. The problem is real and persistent (flutter#33577: 103 comments, open since
   2019).
2. A restricted model is acceptable (dart-lang/sdk#55364 contemplates exactly
   that: limited transferable types, duplicated data).
3. The build cost is bearable (a second compilation and a served artefact).
4. The semantics are stated honestly and do not break existing code.
5. Measured behaviour exists across engines, not just Chrome.
6. Maintenance cost is bounded: one protocol, one backend, no forks.

## Staged path

| Stage | Artefact | Gate |
| --- | --- | --- |
| 1 | This repository: package + evidence + protocol | M001 PASS (done, with engine limits) |
| 2 | v0.3 generated entrypoints + typed tasks (shipped) | tests, tree-shaking probe, browser matrix; Flutter hook still absent |
| 3 | Wasm worker backend | WasmGC/`js-string` matrix, COOP/COEP guidance |
| 4 | Design discussion (Dart SDK) | benchmarks, semantic table, no API breakage |
| 5 | Compiler/build integration proposal | agreed hook with Flutter tooling |
| 6 | `compute()` / `dart:isolate` experiments | explicit maintainer sponsorship |

## Smallest credible first ask

Not “add isolates to the web”. Instead:

> A supported way for a package to compile a secondary Dart entrypoint into a
> served artefact during `flutter build web`, so worker code is not a manual
> side-channel.

That is a tooling gap with a concrete, demonstrable workaround (M001), and it
does not require a concurrency design debate.

## What would make upstream reject it

- Claiming semantic parity with `dart:isolate`.
- A public API that cannot be implemented without compiler changes.
- Unverified browser support.
- A second build system that fights `flutter build web`.
- Any proposal that requires shared memory by default.

## Non-goals

- Forking the SDK now.
- Changing `compute()` semantics without a separate proposal.
- Publishing a “replacement” for `dart:isolate`.

## Next concrete upstream action

After v0.3 and a filled browser matrix: open a discussion (not a PR) linking
M001 measurements, the protocol spec, and the secondary-entrypoint tooling gap.

**Prepared 2026-11-10:** the ordering-specific ask is written up in
`docs/upstream/flutter-web-hook-ordering.md` — minimal reproduction, 3.47.6
build-graph references, the proposed `BuildHooks(platform: web)` dependency on
`Dart2WebTarget`, a disposable-SDK prototype that passes on the first command
for js and wasm, the Flutter tool regression tests, and the measured cost. It is
ready for review and has not been posted.
