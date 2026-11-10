# DataAsset follow-up for dart-lang/sdk#56512 — posted

Status: **posted 2026-11-10T23:22:38Z** as
[issuecomment-6782064670](https://github.com/dart-lang/sdk/issues/56512#issuecomment-6782064670).
No maintainer guidance had been received when it was posted; it contains only
the new DataAsset finding, and the first-build matrix already posted in
[issuecomment-6777658158](https://github.com/dart-lang/sdk/issues/56512#issuecomment-6777658158)
is not repeated.

Committed evidence behind the comment:
- Gate: [`tooling/data_asset_gate`](../../tooling/data_asset_gate)
- Recorded results:
  [`audit/evidence/data-asset-gate-2026-11-10.txt`](../../audit/evidence/data-asset-gate-2026-11-10.txt)
- Proposal context and full matrix:
  [`flutter-web-hook-ordering.md`](flutter-web-hook-ordering.md)

## Exact text as posted

One more result for the ordering question, from the prototype described in [issuecomment-6777658158](https://github.com/dart-lang/sdk/issues/56512#issuecomment-6777658158):

**Declared data assets survive the ordering change.** A dependency package's web `hook/build.dart` that declares its outputs through the hooks API — `output.assets.data.add(DataAsset(...))` for one declared file and one file the hook generates — still bundles both into `build/web/assets/packages/<pkg>/data/` when `Dart2WebTarget` waits for `BuildHooks(platform: web)`. This is a declared-asset test, not a file-writing side effect.

Measured on Flutter 3.47.9 (framework `c197ca5199e`, engine `89c39edfdfae`, Dart 3.13.7), with the same revision patched as the comparison:

| Case | Unmodified | Patched |
| --- | --- | --- |
| first build | exit 0, hook runs 1, both assets bundled | same |
| unchanged rebuild | hook skipped, asset retained | same |
| changed asset input | hook reruns, bundled content follows | same |
| asset input removed | exit 1, `Target build_hooks failed`, compiler never starts | same |
| hook throws | exit 1, compiler never starts | same |

So the prototype does not trade asset correctness for ordering. Two limits: (1) data assets require Flutter's `--enable-dart-data-assets` flag on 3.47.x, so this is a dependency-hook result under that flag, not a change to its default; and (2) it says nothing about a supported generated-source contract — the question from my earlier comment stands, and I am not proposing that the dependency above is the final design.

Reproduction (no DWI packages): [`tooling/data_asset_gate/run.sh`](https://github.com/SoundSliced/dart-web-isolates/tree/main/tooling/data_asset_gate), with results recorded in [evidence](https://github.com/SoundSliced/dart-web-isolates/blob/main/audit/evidence/data-asset-gate-2026-11-10.txt). The gate exits 7 rather than changing your config if Dart data assets are not enabled for the SDK under test.

## Direction after posting

The thread was checked immediately before posting and again after: 31 comments,
ours (`6777658158`) was the newest, then this follow-up. No maintainer reply, no
linked PR, and no equivalent declared-`DataAsset` result were present. Route:
**no response yet** — keep the finding and the rebasable patch available, do
not treat any design as accepted, and do not open a PR that assumes an
unanswered design choice. If maintainers ask for the ordering change, the next
action is to rebase
[`flutter-web-hook-ordering.patch`](flutter-web-hook-ordering.patch) onto the
requested revision and carry the declared-`DataAsset` regression alongside the
generated-source one.

## Consumer gate after posting

Latest released Flutter stable is still **3.47.9** (`c197ca5199e`, 2026-10-29),
the same revision measured earlier the same day. Re-ran the fresh typed-proxy
gate on the **unmodified** 3.47.9 checkout against this repository's working
tree: first ordinary `flutter build web --release` exits 1 on the missing
`lib/dwi_tasks.g.dart` (`Undefined name 'DwiTasks'`), and the second build exits
0 and packages the worker. The patched 3.47.9 checkout succeeds on the first
command (six-row matrix in
[`flutter-web-hook-ordering.md`](flutter-web-hook-ordering.md#3479-measurement-2026-11-10)).

Status: the documented one-time `dart run dwi_builder:dwi build` step and the
**prototype** label stay. Zero-manual-build Flutter integration is not claimed,
and no DWI package release follows from this comment alone.
