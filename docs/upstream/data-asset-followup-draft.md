# Draft follow-up for dart-lang/sdk#56512 — DataAsset result

Status: **draft, not posted.** It contains only the new finding; the first-build
matrix already posted in
[issuecomment-6777658158](https://github.com/dart-lang/sdk/issues/56512#issuecomment-6777658158)
is not repeated here.

---

One more result for the ordering question, from the prototype described in
[issuecomment-6777658158](https://github.com/dart-lang/sdk/issues/56512#issuecomment-6777658158):

**Declared data assets survive the ordering change.** A dependency package's
web `hook/build.dart` that calls `output.assets.data.add(DataAsset(...))` — one
declared file and one file the hook generates — still bundles both into
`build/web/assets/packages/<pkg>/data/` when `Dart2WebTarget` waits for
`BuildHooks(platform: web)`.

Measured on Flutter 3.47.9 (framework `c197ca5199e`, engine `89c39edfdfae`,
Dart 3.13.7), unmodified SDK as control:

| Case | Unmodified | Patched |
| --- | --- | --- |
| first build | exit 0, hook runs 1, both assets bundled | same |
| unchanged rebuild | hook skipped, asset retained | same |
| changed asset input | hook reruns, bundled content follows | same |
| asset input removed | exit 1, `Target build_hooks failed`, compiler never starts | same |
| hook throws | exit 1, compiler never starts | same |

So the prototype does not trade asset correctness for ordering. It still says
nothing about a supported generated-source contract, and I am not proposing that
the dependency above is the final design — the question from my earlier comment
stands.

Reproduction (no DWI packages): `tooling/data_asset_gate/run.sh` in
`https://github.com/SoundSliced/dart-web-isolates` (exit 7 tells you Dart data
assets are not enabled for the SDK under test).
