# DWI upstream proposal (1.0)

This summarises what DWI asks of the Dart and Flutter teams, what has been posted,
and what has not. Each item links to its draft and its evidence. Posting and SDK
changes need the maintainer's approval at the time (`docs/completion-plan.md`,
section 5).

## Posted

Both comments are on [dart-lang/sdk#56512](https://github.com/dart-lang/sdk/issues/56512):

1. **Web build hook ordering** — comment of 2026-11-10 (`issuecomment-6777658158`).
   Asks how the web build hooks of Flutter can run before Dart compiles the worker,
   and reports measurements from a disposable SDK copy. Draft and evidence:
   [`docs/upstream/flutter-web-hook-ordering.md`](upstream/flutter-web-hook-ordering.md),
   [`docs/upstream/flutter-web-hook-ordering.patch`](upstream/flutter-web-hook-ordering.patch),
   `audit/evidence/flutter-web-hook-ordering-2026-11-10.txt`.
2. **DataAsset follow-up** — comment of 2026-11-10 (`issuecomment-6782064670`).
   Reports one new finding about DataAsset builds. Draft:
   [`docs/upstream/data-asset-followup-draft.md`](upstream/data-asset-followup-draft.md).

No maintainer guidance had been received on either comment at the time of writing.

## Drafted, not posted

- **Function lowering and SDK integration** — research contract only, 2026-11-11
  ([`docs/upstream/dwi-function-lowering.md`](upstream/dwi-function-lowering.md)).
  It records what would have to change in the SDK for compiler-known function
  references and closures. No SDK change, compiler fork or posting is authorised
  by that document.
- **Secondary entrypoint emission** — named in the completion plan (tranche I) but
  not written as a separate proposal.

## Not done, by decision

- No SDK fork. The experimental Dart SDK branch for worker entrypoint emission and
  for compiler-known function references has not started.
- No `Isolate.run` or Flutter `compute()` prototype.
- DWI's closure experiment is a recorded no-go (ADR-030). Closures therefore do not
  appear as a request in this proposal until a compiler change makes them possible.

## What DWI asks for, in order of value

1. Web build hooks that run before the worker is compiled, so a Flutter web build
   can produce a worker without a manual step (posted, comment 1).
2. Clear handling of DataAsset builds for a worker entrypoint (posted, comment 2).
3. Compiler-known function references, so a function can be bound to a worker task
   without an annotation or a registry (drafted; depends on the SDK).
4. A worker entrypoint emission path in the SDK, so the worker and proxies do not
   need a separate compilation step (drafted; not written as a proposal).

## Basis

Every claim above is backed by the evidence named in its draft. DWI measures these
on macOS arm64 in four browser engines only (`docs/FINAL_BROWSER_MATRIX.md`).

## Next step

Further posting, an SDK branch, and any prototype wait for the maintainer's decision
after the 1.0 release. The maintainer intends to submit focused proposals backed by
working prototypes, benchmarks and limits (`docs/MASTER_PLAN.md`, section 60).
