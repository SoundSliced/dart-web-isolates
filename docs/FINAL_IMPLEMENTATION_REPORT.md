# DWI 1.0 implementation report

## What was asked

The master plan (`docs/MASTER_PLAN.md`) and the engineering handoff
(`docs/ENGINEERING_HANDOFF.md`) define the objectives. The completion plan
(`docs/completion-plan.md`) turns them into tranches A to I and sets the 1.0 gates.
This report says what was built, what was measured, and how each objective is
classified.

## Releases

| Version | Date | Main content |
| --- | --- | --- |
| 0.5.0 to 0.5.3 | 2026-11-06 to 2026-11-08 | Long-lived worker handles (ADR-013) and dependency patches |
| 0.6.0 | 2026-11-08 | Scoped helper `DwiWorker.using` (ADR-015) and the published-consumer checks |
| 0.7.0 | 2026-11-09 | Termination observation (ADR-017, DWI-4 increment 2) |
| 0.8.0, 0.8.1 | 2026-11-10 | dart2wasm worker backend, opt-in (ADR-018); wasm generations kept (0.8.1) |
| 0.9.0 | 2026-11-13 | Registered static functions (ADR-020), payload types (ADR-021), streams (ADR-022) |
| 0.10.0 | 2026-11-14 | Links (ADR-023), idle retirement and draining close (ADR-024), cooperative cancellation (ADR-027), pause and ping (ADR-028), `dwi_flutter` (ADR-025), metrics and pool state (ADR-026), protocol check, CI |
| 0.11.0 | 2026-11-15 | Several positional parameters (ADR-029); function references without annotation (ADR-030) |
| 1.0.0 | (this release) | Scope and stability (ADR-031); `dartdoc` on every exported member; blob, data and javascript worker URLs refused; `FINAL_*` reports |

The full entries are in `CHANGELOG.md` and in `docs/release-notes-*.md`.

## Tests

Format, analyze (`--fatal-infos`) and the full test suite pass for all eight
packages on the release commit. Test counts at 0.11.0: `dwi_annotations` 3,
`dwi_protocol` 14, `dwi_core` 41, `dwi_native` 72, `dwi_web` 30, `dwi` 56,
`dwi_flutter` 5, `dwi_builder` 152. Browser tests in `dwi_builder` run serially
(`dart test -j 1`) because Safari accepts one WebDriver session at a time.

Continuous integration (`.github/workflows/ci.yml`) runs format, analyze and the
VM tests for each package. It passed on `main` for the 0.11.0 release commit.

## Classification of the master plan

`docs/IMPLEMENTATION_STATUS.md` classifies every objective. At 1.0 the 74 rows
(including the table headings) split as follows, counting only the classified
objectives:

| Class | Count | Meaning |
| --- | --- | --- |
| complete | 40 | Built and tested, with evidence or a test named in the row |
| complete with limitations | 23 | Built and tested; the limit is in the row and in `docs/limitations.md` |
| SDK-dependent | 3 | Needs a compiler or SDK change (tranche I) |
| closure no-go | 1 | Closures and `Isolate.run` with closures (ADR-030) |
| superseded | 1 | Replaced by a later audit report |

No row is partial or open. Two classes need more than a sentence:

- **Complete with limitations** covers mobile browsers, Flutter native, heap growth
  outside Chromium, duplicate replies (unreachable through the public API), the
  first build of a fresh typed-proxy Flutter app, and hot reload of a running
  worker. Each limit is written down in `docs/limitations.md`.
- **SDK-dependent** covers `Isolate.run` with a closure, closures, and the SDK
  integration. These are deferred to tranche I and recorded in
  `docs/FINAL_SDK_FEASIBILITY_REPORT.md`.

## 1.0 gates (critical review, 2026-11-03)

| Gate | State |
| --- | --- |
| S3, S4, S5: payload, queue and leak limits | closed (`docs/critical-review.md`) |
| Gate 2: browser matrix | closed for four desktop engines; mobile not measured |
| Gate 3: cooperative cancellation | closed (ADR-027) |
| Gate 4: pool-sizing guidance | closed (`docs/browser-matrix.md`, pool sizing) |
| Gate 5: tree shaking | closed by decision: the seven measured shapes; other shapes are limitation 13 |

## Decisions taken for 1.0

- **DWI-4 raised.** Tranches B to D passed, so the completion plan's DWI-4 condition
  is met (ADR-031).
- **DWI-5 and DWI-6 not raised.** They depend on the SDK (ADR-030).
- **Mobile and Flutter native stay unverified** until a device or a machine is
  available. The release says so; it does not claim them.
- **Tranche I deferred** until after 1.0, as the maintainer asked. Two upstream
  comments were posted earlier on dart-lang/sdk#56512 (`docs/UPSTREAM_PROPOSAL.md`).

## What is still not done

- The 1.0 claim is not a security certification. There was no external audit
  (`docs/FINAL_SECURITY_REVIEW.md`).
- The `dwi_builder` command for a fresh typed-proxy Flutter app still needs one
  pre-build step (limitation 7).
- Tranche I (SDK branch, prototypes, further upstream posting).
- Mobile, Windows, Linux and other engines: each needs a machine or device.

## Verified, not verified, could not determine

- **Verified:** the test results, the evidence files named in each report, and the
  classification counts above (counted from `docs/IMPLEMENTATION_STATUS.md`).
- **Not verified:** the release commit's CI result after the documentation changes
  made for 1.0; mobile browsers; Flutter native; any external security review.
- **Could not determine:** how future browser or SDK releases will change the results.
