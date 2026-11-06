#!/usr/bin/env bash
# Reproduces the fresh typed-proxy ordering case measured on Flutter 3.47.6.
#
# Inputs:
#   FLUTTER    flutter launcher to use (default: `flutter` from PATH)
#   WORK_DIR   where to create the scratch app (default: a new temp directory)
#   PUB_CACHE  respected as-is; point it at a writable cache if the default is
#              read-only in your environment
#
# Outputs:
#   A scratch Flutter app under $WORK_DIR/app and both build logs on stdout.
#
# Exit codes:
#   0  reproduced: the first build fails on the missing proxy, the second
#      succeeds and packages web/dwi/worker.dart.js
#   2  the first build unexpectedly succeeded (Flutter's ordering changed;
#      update docs/architecture.md ADR-009 and docs/limitations.md)
#   3  the second build failed or did not package the worker
#   4  the first build failed for a different reason
#   *  any other failure came from flutter/create or the environment
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
flutter="${FLUTTER:-flutter}"
work="${WORK_DIR:-$(mktemp -d)}"
app="$work/app"

mkdir -p "$app"
cd "$app"

echo "== flutter create ($app) =="
"$flutter" create --no-pub --platforms=web --project-name proxy_gate . >/dev/null
cp "$here/fixture/lib/tasks.dart" lib/tasks.dart
cp "$here/fixture/lib/main.dart" lib/main.dart
rm -f test/widget_test.dart

cat > pubspec.yaml <<EOF
name: proxy_gate
description: "DWI fresh typed-proxy build gate"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.13.0

dependencies:
  flutter:
    sdk: flutter
  dwi:
    path: $repo/packages/dwi
  dwi_annotations:
    path: $repo/packages/dwi_annotations
  dwi_builder:
    path: $repo/packages/dwi_builder

flutter:
  uses-material-design: true
EOF

test ! -e lib/dwi_tasks.g.dart
test ! -e web/dwi
test ! -e .dwi

# Dependency resolution is setup, not part of the gate, and it never generates
# proxies. Resolve offline so a read-only hosted cache (restricted sandbox) is
# not required to accept writes; with a normal writable cache, `flutter build`
# would resolve the same lockfile.
echo "== resolve dependencies =="
"$flutter" pub get --offline

echo "== first build: ordinary 'flutter build web --release' =="
set +e
"$flutter" build web --release 2>&1 | tee "$work/first-build.log"
first="${PIPESTATUS[0]}"
set -e
echo "first build exit=$first"

if [ "$first" -eq 0 ]; then
  echo "UNEXPECTED: the first build succeeded; Flutter may now order build hooks before dart2js." >&2
  echo "Re-measure and update docs/architecture.md (ADR-009) and docs/limitations.md." >&2
  exit 2
fi

grep -q "dwi_tasks.g.dart" "$work/first-build.log" || {
  echo "The first build failed, but not on the generated proxy. Inspect $work/first-build.log." >&2
  exit 4
}

echo "== second build: same command, generated proxy now present =="
set +e
"$flutter" build web --release 2>&1 | tee "$work/second-build.log"
second="${PIPESTATUS[0]}"
set -e
if [ "$second" -ne 0 ]; then
  echo "The second build failed; inspect $work/second-build.log." >&2
  exit 3
fi

test -f build/web/dwi/worker.dart.js || {
  echo "The second build did not package build/web/dwi/worker.dart.js." >&2
  exit 3
}

echo
echo "REPRODUCED: first build failed (exit $first), second build packaged the worker."
echo "Scratch app: $app"
