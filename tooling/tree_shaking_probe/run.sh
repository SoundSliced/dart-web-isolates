#!/usr/bin/env bash
# Tree-shaking probe for generated DWI registries (tranche A8).
#
# Builds the fixture with the real generator, compiles the generated worker
# entrypoint with dart2js at -O1, -O2 and -O4, and checks that each annotated
# shape's sentinel string survives while the unreferenced control's does not.
# Sentinels are unique string literals, so grepping the output is a direct
# check that the function body was kept.
#
# This measures dart2js only. dart2wasm is a separate backend and is not
# measured here (AGENTS.md rule 7).
#
# Usage: tooling/tree_shaking_probe/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
out="$(mktemp -d "${TMPDIR:-/tmp}/dwi_tsp.XXXXXX")"

dart pub get >/dev/null
dart run dwi_builder:dwi build >"$out/build.log" 2>&1
cp web/dwi/worker.dart.js "$out/builder_artifact.js"

for level in O1 O2 O4; do
  dart compile js "-$level" -o "$out/worker_$level.js" .dwi/generated_worker.dart >/dev/null
done

kept=(SENT_EXPORT_3b9 SENT_PART_7d1 SENT_CONST_a1 SENT_CONST_b2 SENT_FUTURE_5c2 SENT_LOCAL_8e1 SENT_TRANSITIVE_c4a)
dropped=(SENT_UNUSED_0d4)

fail=0
for artifact in builder_artifact worker_O1 worker_O2 worker_O4; do
  file="$out/$artifact.js"
  for s in "${kept[@]}"; do
    if ! grep -q "$s" "$file"; then echo "MISSING  $artifact $s"; fail=1; fi
  done
  for s in "${dropped[@]}"; do
    if grep -q "$s" "$file"; then echo "NOT DROPPED  $artifact $s"; fail=1; fi
  done
  echo "checked  $artifact  bytes=$(wc -c < "$file")"
done

echo "output: $out"
exit "$fail"
