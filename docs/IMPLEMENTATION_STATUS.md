# Implementation Status — 2026-11-11

Every objective in [`MASTER_PLAN.md`](MASTER_PLAN.md),
[`ENGINEERING_HANDOFF.md`](ENGINEERING_HANDOFF.md) and
[`ZERO_BOILERPLATE_ADDENDUM.md`](ZERO_BOILERPLATE_ADDENDUM.md), classified
against the repository at `b0bc103` plus the uncommitted ADR-020 work. Remaining
work is scheduled in [`completion-plan.md`](completion-plan.md); the letter in
the last column is its tranche.

Classes: **complete**, **limited** (complete with stated limitations),
**partial**, **open** (not started), **superseded**, **infeasible**,
**SDK** (needs compiler or SDK change).

## 1. Where the plans and the implementation differ (no conflict to fix)

These are deliberate, recorded decisions. The implementation stands; the plan
text is the older intent.

| Plan text | Implementation | Recorded in |
| --- | --- | --- |
| `Dwi.runTask('name', input)` | `Dwi.run<R>('name', input)` | ADR-002 |
| `Dwi.run(function, input)` (Level B) | `DwiFunctions.run(function, input)` in the generated file, for annotated functions only; no overload on `Dwi.run` | ADR-019, ADR-020 |
| `adr/` directory, `tools/`, `docs/security.md` | ADRs live in `docs/architecture.md`; `tooling/`; `SECURITY.md` plus `docs/critical-review.md` | repository layout |
| Roadmap v0.5 ports/streams, v0.6 Wasm, v0.7 Flutter | handles 0.5, channels 0.6, observation 0.7, Wasm worker 0.8 | `CHANGELOG.md` |
| Research R001–R013, `R012_CLOSURE_FEASIBILITY.md` | R011 and R012 were never written; closure feasibility is R016 | `research/README.md` |
| Audit files `A001`–`A005`, `AUDIT_SUMMARY.md` | one report, `audit/V030_VERIFICATION_REPORT.md`, plus dated evidence files | `audit/` |
| Protocol v1 manifest example | protocol v2 (channels) | ADR-014 |
| Section numbers cited by `AGENTS.md` (§51–§53) | do not match the reconstructed plan | note in `MASTER_PLAN.md` |

## 2. Master plan

| § | Objective | Class | Evidence or gap | Tranche |
| --- | --- | --- | --- | --- |
| 1–5 | Vision, problem, principles, scope, success criteria | limited | first success criterion (`DwiTasks.calculatePrimes`) met; second met only for annotated functions via `DwiFunctions`; third is SDK research | F, I |
| 6–7 | Repository and package structure | complete | seven packages; `dwi_flutter` not created | E |
| 8 | Platform architecture | limited | native, JS worker, opt-in Wasm worker | — |
| 9 | API levels A, A1 | complete | ADR-002, ADR-011 | — |
| 9 | Level B function references | limited | annotated top-level, class-static and enum-static functions (ADR-020, 0.9.0) and same-package `DwiFunctions` call sites (ADR-030, 0.11.0); closures are not supported | H, F |
| 9 | Level C closures, Level D `Isolate.run` | SDK | R016, ADR-019 | F, I |
| 10 | Compatibility contract | complete | `docs/compatibility-matrix.md` has the five platform columns for 1.0 (native, Flutter native, Dart Web JS, Flutter Web JS, Dart/Wasm); Flutter native is measured only by the reduced probe on an iPhone 15 and an Android emulator | — |
| 11–17 | Phase 0 research | complete | R001–R010 | — |
| 18–21 | M001 proof of concept | complete | `experiments/dart_worker_poc`, M001 | — |
| 19 | Flutter main-thread vs worker demonstration | complete | `examples/flutter_jank_demo` measured in four engines (`audit/evidence/flutter-jank-demo-four-engines-2026-11-14.json`) | — |
| 22–24 | Protocol, correlation, error propagation | complete | `dwi_protocol`, protocol tests | — |
| 25–26 | Native and browser backends | complete | package tests, browser matrices | — |
| 27 | Worker pools | complete | pool size, queue, limits, replacement, idle retirement (ADR-024, 0.10.0) and draining close; scheduling policies compared (section 3, row 30) | — |
| 28 | Timeouts and cancellation | complete | timeouts, queued cancellation, cooperative cancellation for yielding tasks (ADR-027), termination as the documented fallback | — |
| 29 | Worker lifecycle states | limited | handle states and `stopReason` (ADR-013, ADR-017); pool slots have no public state | G |
| 30 | Port-like messaging | limited | named bounded channels (ADR-014); handle-to-handle links relayed by the host (ADR-023, 0.10.0; native + 16 cells); no `SendPort` objects or direct worker-to-worker path | — |
| 31 | Streaming and progress | limited | `Stream<T>` tasks (ADR-022, 0.9.0): fresh context per listen, credit flow control, cancel terminates | — |
| 32–33 | Serialization contract, typed serializers | limited | primitives, collections, typed data; enums, `DateTime`, `Duration`, `BigInt`, `Uri`, records and `@DwiPayload` classes through generated codecs (ADR-021, 0.9.0; native + 16 cells, `payload-types-acceptance-2026-11-13T012032.json`); payload classes must opt in and be trees | — |
| 34 | Transferable data | complete | `DwiTransferableBytes` (ADR-010) | — |
| 35 | Large-payload benchmarks 1 KB–100 MB | complete | 1 KiB–100 MiB payloads in four engines (`audit/evidence/browser-matrix-extended-four-engines-2026-11-14.json`) | — |
| 36 | Protocol evolution | limited | version check rejects a mismatch; no negotiation | G |
| 37–41 | Annotations, discovery, registry, proxies, entrypoint | complete | `dwi_builder` tests; ADR-020 audit corrections | — |
| 42 | Automatic compilation | limited | Flutter build hook (ADR-009); first build of a fresh typed-proxy app still fails | I |
| 43 | Build caching | complete | `build_test.dart` | — |
| 44 | Development workflow | limited | `dwi watch`; a running worker is not replaced on hot reload (limitation 16) | — |
| 45 | Compiler-assisted APIs | SDK | R016 | F, I |
| 46–47 | Wasm worker backend and architecture decision | limited | ADR-018 (separate instances); no written comparison with shared memory and Wasm threads | G |
| 48 | Backend selection | limited | explicit selection, typed failure, never a silent fallback; no opt-in fallback policy | G |
| 49 | Flutter integration layer, `computeParallel` | complete | `dwi_flutter` 0.10.0 (ADR-025) | — |
| 50 | `flutter run` / `flutter build web` with no manual step | limited | works except the first build of a fresh typed-proxy app | I |
| 51 | Cross-platform test suites | limited | VM, browser JS, browser Wasm, Flutter web measured; CI runs format, analyze, VM tests and a web compile check (dart2js and dart2wasm); Flutter native measured only by the reduced probe (`docs/compatibility-matrix.md`) | — |
| 52 | Browser compatibility | limited | four desktop engines (macOS arm64) for every shipped level and for the benchmark harness; mobile browsers measured only by the reduced probe (iOS Safari, Chrome for Android); other mobile browsers and operating systems not measured (`docs/browser-matrix.md`, section A11) | — |
| 53 | Security | complete | limits implemented and tested; strict CSP in four engines; blob, data and javascript workers refused (ADR-006); review in `docs/FINAL_SECURITY_REVIEW.md` | — |
| 54 | Benchmarks | complete | primes, transfer, startup, dispatch, sorting, JSON, hashing, compression and image blur in four engines (`audit/evidence/browser-matrix-extended-four-engines-2026-11-14.json`) | — |
| 55 | Diagnostics and observability | complete | metrics, public pool state and protocol check (ADR-026; `audit/evidence/metrics-pool-state-four-engines-2026-11-14.json`) | — |
| 56 | Documentation and examples | complete | docs maintained; troubleshooting guide (`docs/troubleshooting.md`); empty directories removed; example coverage is limited (row 54) | — |
| 57–58 | Agent organisation and workflow | complete | `AGENTS.md` | — |
| 59 | Release roadmap to v1.0 | complete | 0.11.0 published 2026-11-15; v1.0 release recorded in `docs/release-notes-1.0.0.md` once published | — |
| 60 | Upstream strategy | limited | two comments posted on dart-lang/sdk#56512 on 2026-11-10 (hook ordering, and the DataAsset follow-up, `docs/upstream/`); the function-lowering proposal is research only and is not posted; no SDK fork; further posting waits for the maintainer after 1.0 | I |
| 61 | Final definition of success | complete | classification in this file; the FINAL_* reports in `docs/` | — |

## 3. Engineering handoff (items not already covered above)

| § | Objective | Class | Evidence or gap | Tranche |
| --- | --- | --- | --- | --- |
| 4–7 | Integrity, package, research and M001 audits as separate reports | superseded | `audit/V030_VERIFICATION_REPORT.md` | — |
| 8 | Protocol audit | limited | malformed messages, unknown types and version mismatch are tested; late replies are measured in four engines (A4); a duplicate reply cannot be produced through the public API on any backend, so it has no test (`docs/browser-matrix.md`, late-reply section) | — |
| 9, 51 | Stress with 1–1,000 tasks, sustained leak testing | limited | 1,000-task burst and a 20×100 leak run pass in four engines (`docs/browser-matrix.md`, burst section); heap growth is measured only where `performance.memory` exists (Chromium), limitation recorded | — |
| 14 | Tree-shaking audit | limited | tested shapes only | A |
| 17 | Clean external consumer | complete | `tooling/hosted_consumer` | — |
| 18 | Continuous integration | complete | `.github/workflows/ci.yml`: format, analyze and VM tests per package; green on `main` (run for `a412266`, 2026-11-15) | — |
| 30 | Scheduling strategies evaluated with benchmarks | complete | FIFO, least-loaded, round-robin and priority compared (`audit/evidence/scheduling-policies-2026-11-13.json`); no policy added | — |
| 31–32 | Backpressure, crash recovery | complete | `browser_lifecycle_test.dart`, heartbeat tests | — |
| 34 | CSP configurations | complete | strict same-origin CSP in four engines, three passes, inline-script control blocked (`audit/evidence/browser-matrix-csp-2026-11-14.json`); `blob:` workers not measured | — |
| 39–40 | `dwi_flutter`, responsiveness demo including `compute()` | complete | `dwi_flutter` 0.10.0 (ADR-025); jank demo in four engines | — |
| 44–47 | Experimental Dart and Flutter SDK forks, `Isolate.run`, `compute()` | SDK | one disposable-SDK hook-ordering prototype; forks need the maintainer's approval | I |
| 48–50 | Benchmark suite, message sizes, worker counts | complete | see `docs/FINAL_BENCHMARK_REPORT.md`; sections 35 and 54 of the master plan are measured in four engines (Wasm vs JS only in Chrome) | — |
| 54 | Examples for transfers, pools, cancellation, streaming, Flutter, Wasm | limited | basic, automatic, stateful, scoped, stop-observer, cooperative cancel, dispatch control, worker link, Wasm and Flutter examples exist; no dedicated example for transfers, pool sizing or streaming (covered by tests) | E |
| 60 | `FINAL_*` reports and `UPSTREAM_PROPOSAL.md` | complete | `docs/FINAL_IMPLEMENTATION_REPORT.md`, `FINAL_ARCHITECTURE.md`, `FINAL_BROWSER_MATRIX.md`, `FINAL_BENCHMARK_REPORT.md`, `FINAL_SECURITY_REVIEW.md`, `FINAL_SDK_FEASIBILITY_REPORT.md`, `UPSTREAM_PROPOSAL.md` | H |

## 4. Zero-boilerplate addendum

| § | Objective | Class | Evidence or gap | Tranche |
| --- | --- | --- | --- | --- |
| 1, 14 | No worker file, registry, JS, manual compile, copy, path or manifest | limited | all true except one pre-build command for a fresh typed-proxy Flutter app | I |
| 2, 3A | Build-time pipeline | complete | ADR-008, ADR-009 | — |
| 3B | Annotation-free function discovery | complete | `DwiFunctions` call sites with a top-level or static target (ADR-030) | — |
| 3C, 15 | Closures, `Isolate.run` | closures: no-go (ADR-030); `Isolate.run`: SDK | R016, ADR-030 | I |
| 4–5 | Runtime compilation decision | complete | R013: rejected | — |
| 6 | Ordinary Flutter commands | limited | as §50 above | I |
| 7 | Generated manifest | complete | `.dwi/worker_manifest.json` | — |
| 8 | Change → regenerate → recompile → restart worker | limited | steps 1–4 (`dwi watch`, hook); steps 5–6 need a page reload (limitation 16) | — |
| 9 | Content-hash caching | complete | `hash_test.dart`, `build_test.dart` | — |
| 10 | Lazy worker startup | complete | pool spawns on first call | — |
| 11 | Universal vs per-task vs chunked workers, measured | complete | measured in four engines (`audit/evidence/worker-strategies-and-protocol-check-2026-11-14.json`) | — |
| 12 | Dependency discovery | complete | import-closure hashing and `DWI002` | — |
| 13 | Build-time diagnostics | complete | DWI001–DWI010 | — |
| 16–17 | Roadmap, "complex internally, simple externally" | complete | through 0.11.0; 1.0 recorded at release | — |

## 5. Defects found while classifying

| Defect | State |
| --- | --- |
| Cancelling a pooled web call while its worker is starting was ignored | fixed 2026-11-11, regression case in `browser_lifecycle_test.dart`; passes in four engines |
| Unsupported `@DwiTask` placements were silently ignored; `external` functions accepted | fixed 2026-11-11 (ADR-020 audit) |
| `docs/README.md` lists `vision.md`, which does not exist | closed 2026-11-15: the row now points to `MASTER_PLAN.md` §1 |
| Five example directories and three benchmark directories are empty | closed 2026-11-15: the empty directories were removed |
| `tooling/README.md` lists three tools as planned with empty directories | closed: the table was corrected in 79c2f0b |

## Verified / not verified / could not determine

- **Verified:** each class above against the cited file or its absence.
- **Not verified:** that the reconstructed master plan contains every
  requirement of the original.
- **Could not determine:** the original §51–§53 text that `AGENTS.md` cites.
