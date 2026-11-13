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
| 9 | Level B function references | limited | annotated top-level, class-static and enum-static functions (ADR-020, unreleased) | H, F |
| 9 | Level C closures, Level D `Isolate.run` | SDK | R016, ADR-019 | F, I |
| 10 | Compatibility contract | limited | `compatibility-matrix.md` has no separate columns for Flutter native, Flutter web and Dart/Wasm | A |
| 11–17 | Phase 0 research | complete | R001–R010 | — |
| 18–21 | M001 proof of concept | complete | `experiments/dart_worker_poc`, M001 | — |
| 19 | Flutter main-thread vs worker demonstration | partial | measured in `integration_tests/`; `examples/flutter_jank_demo` is an empty directory | E |
| 22–24 | Protocol, correlation, error propagation | complete | `dwi_protocol`, protocol tests | — |
| 25–26 | Native and browser backends | complete | package tests, browser matrices | — |
| 27 | Worker pools | partial | pool size, queue, limits, replacement done; idle termination and alternative scheduling policies absent | D |
| 28 | Timeouts and cancellation | partial | timeouts, queued cancellation, termination-based running cancellation; no cooperative cancellation | D |
| 29 | Worker lifecycle states | limited | handle states and `stopReason` (ADR-013, ADR-017); pool slots have no public state | G |
| 30 | Port-like messaging | limited | named bounded channels (ADR-014); no port objects | C |
| 31 | Streaming and progress | open | no `Stream<T>` task results; channels are the only multi-message path | C |
| 32–33 | Serialization contract, typed serializers | partial | primitives, collections, typed data; enums, records, DTOs rejected with `DWI001` | B |
| 34 | Transferable data | complete | `DwiTransferableBytes` (ADR-010) | — |
| 35 | Large-payload benchmarks 1 KB–100 MB | partial | 64 KiB, 1 MiB, 8 MiB in Chrome and Safari only | A |
| 36 | Protocol evolution | limited | version check rejects a mismatch; no negotiation | G |
| 37–41 | Annotations, discovery, registry, proxies, entrypoint | complete | `dwi_builder` tests; ADR-020 audit corrections | — |
| 42 | Automatic compilation | limited | Flutter build hook (ADR-009); first build of a fresh typed-proxy app still fails | I |
| 43 | Build caching | complete | `build_test.dart` | — |
| 44 | Development workflow | partial | `dwi watch`; a running worker is not replaced on hot reload | G |
| 45 | Compiler-assisted APIs | SDK | R016 | F, I |
| 46–47 | Wasm worker backend and architecture decision | limited | ADR-018 (separate instances); no written comparison with shared memory and Wasm threads | G |
| 48 | Backend selection | limited | explicit selection, typed failure, never a silent fallback; no opt-in fallback policy | G |
| 49 | Flutter integration layer, `computeParallel` | open | — | E |
| 50 | `flutter run` / `flutter build web` with no manual step | limited | works except the first build of a fresh typed-proxy app | I |
| 51 | Cross-platform test suites | partial | VM, browser JS, browser Wasm, Flutter web measured; no Flutter native run; **no CI** | A |
| 52 | Browser compatibility | partial | four desktop engines for DWI-2/3/4 and ADR-018/020; DWI-1.6 in Firefox/Edge pending; no mobile browser | A |
| 53 | Security | partial | limits implemented and tested; CSP measured for the Wasm worker; no review since `critical-review.md` (2026-11-03) | A |
| 54 | Benchmarks | partial | primes, transfer, startup, dispatch; no sorting, JSON, hashing, compression or image workloads | A |
| 55 | Diagnostics and observability | open | `Dwi.capabilities()` only | G |
| 56 | Documentation and examples | partial | docs maintained; five listed example directories are empty; no troubleshooting guide | E, H |
| 57–58 | Agent organisation and workflow | complete | `AGENTS.md` | — |
| 59 | Release roadmap to v1.0 | partial | 0.8.1 published | H |
| 60 | Upstream strategy | partial | two proposals written, one follow-up posted, hook-ordering proposal not posted | I |
| 61 | Final definition of success | partial | this file is the required classification | H |

## 3. Engineering handoff (items not already covered above)

| § | Objective | Class | Evidence or gap | Tranche |
| --- | --- | --- | --- | --- |
| 4–7 | Integrity, package, research and M001 audits as separate reports | superseded | `audit/V030_VERIFICATION_REPORT.md` | — |
| 8 | Protocol audit | partial | malformed messages, unknown types and version mismatch are tested; late and duplicate task replies on the host have no dedicated test | A |
| 9, 51 | Stress with 1–1,000 tasks, sustained leak testing | partial | 100 tasks through 4 workers; no 1,000-task or heap-growth run | A |
| 14 | Tree-shaking audit | limited | tested shapes only | A |
| 17 | Clean external consumer | complete | `tooling/hosted_consumer` | — |
| 18 | Continuous integration | open | no `.github/` | A |
| 30 | Scheduling strategies evaluated with benchmarks | open | FIFO only, no comparison | D |
| 31–32 | Backpressure, crash recovery | complete | `browser_lifecycle_test.dart`, heartbeat tests | — |
| 34 | CSP configurations | limited | measured for the Wasm worker; JS worker under a strict CSP not measured per engine | A |
| 39–40 | `dwi_flutter`, responsiveness demo including `compute()` | open | — | E |
| 44–47 | Experimental Dart and Flutter SDK forks, `Isolate.run`, `compute()` | SDK | one disposable-SDK hook-ordering prototype; forks need the maintainer's approval | I |
| 48–50 | Benchmark suite, message sizes, worker counts | partial | see master plan §35, §54 | A |
| 54 | Examples for transfers, pools, cancellation, streaming, Flutter, Wasm | partial | basic, automatic, stateful, scoped, stop-observer, Wasm exist | E |
| 60 | `FINAL_*` reports and `UPSTREAM_PROPOSAL.md` | open | written at v1.0 | H |

## 4. Zero-boilerplate addendum

| § | Objective | Class | Evidence or gap | Tranche |
| --- | --- | --- | --- | --- |
| 1, 14 | No worker file, registry, JS, manual compile, copy, path or manifest | limited | all true except one pre-build command for a fresh typed-proxy Flutter app | I |
| 2, 3A | Build-time pipeline | complete | ADR-008, ADR-009 | — |
| 3B | Annotation-free function discovery | open | analyzer can resolve static targets (R016); nothing generates from a call site | F |
| 3C, 15 | Closures, `Isolate.run` | SDK | R016 | F, I |
| 4–5 | Runtime compilation decision | complete | R013: rejected | — |
| 6 | Ordinary Flutter commands | limited | as §50 above | I |
| 7 | Generated manifest | complete | `.dwi/worker_manifest.json` | — |
| 8 | Change → regenerate → recompile → restart worker | partial | steps 1–4 (`dwi watch`, hook); steps 5–6 need a page reload | G |
| 9 | Content-hash caching | complete | `hash_test.dart`, `build_test.dart` | — |
| 10 | Lazy worker startup | complete | pool spawns on first call | — |
| 11 | Universal vs per-task vs chunked workers, measured | open | universal only, no measurement | G |
| 12 | Dependency discovery | complete | import-closure hashing and `DWI002` | — |
| 13 | Build-time diagnostics | complete | DWI001–DWI010 | — |
| 16–17 | Roadmap, "complex internally, simple externally" | partial | through 0.8.1 | H |

## 5. Defects found while classifying

| Defect | State |
| --- | --- |
| Cancelling a pooled web call while its worker is starting was ignored | fixed 2026-11-11, regression case in `browser_lifecycle_test.dart`; four-engine rerun pending |
| Unsupported `@DwiTask` placements were silently ignored; `external` functions accepted | fixed 2026-11-11 (ADR-020 audit) |
| `docs/README.md` lists `vision.md`, which does not exist | open (H) |
| Five example directories and three benchmark directories are empty | open (E, A) |
| `tooling/README.md` lists three tools as planned with empty directories | open (H) |

## Verified / not verified / could not determine

- **Verified:** each class above against the cited file or its absence.
- **Not verified:** that the reconstructed master plan contains every
  requirement of the original.
- **Could not determine:** the original §51–§53 text that `AGENTS.md` cites.
