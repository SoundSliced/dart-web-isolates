#!/usr/bin/env bash
# DataAsset gate: does a dependency package's web build hook keep its declared
# data assets bundled for `flutter build web`, on the SDK under test?
#
# The point of the gate is the ordering question: the hook must run before the
# compiler, and the hooks-API assets it declares must still reach build/web with
# the right content. A file written directly by a hook does not satisfy it.
#
# Inputs:
#   FLUTTER    flutter launcher (default: `flutter` from PATH)
#   WORK_DIR   scratch directory (default: a new temp directory)
#   PUB_CACHE  respected as-is; must be writable
#
# Exit codes:
#   0  every case behaved as the gate requires
#   2  the declared asset is missing from build/web or has the wrong content
#   3  an unchanged rebuild reran the hook or lost the asset
#   4  a changed asset input was not reflected in the output
#   5  removing the asset input did not fail the build
#   6  a throwing hook did not fail the build, or the compiler still started
#   7  environment: Dart data assets are not enabled for this SDK
#   *  any other failure came from flutter create, pub or the environment
set -u

here="$(cd "$(dirname "$0")" && pwd -P)"
flutter="${FLUTTER:-flutter}"
work="${WORK_DIR:-$(mktemp -d)}"
pkg="$work/data_asset_gate_package"
app="$work/app"
asset_rel="assets/packages/data_asset_gate_package/data"

mkdir -p "$pkg" "$app"

# Data assets are behind a feature flag on 3.47.x. Enabling it writes the user
# config, so the gate reports it instead of doing it silently.
if ! "$flutter" config --list 2>/dev/null | grep -q 'enable-dart-data-assets: true'; then
  echo "Dart data assets are not enabled for this SDK." >&2
  echo "Run: $flutter config --enable-dart-data-assets --enable-native-assets" >&2
  exit 7
fi

cp -R "$here/fixture/." "$pkg/"
rm -f "$pkg/.hook_runs"

cd "$app" || exit 1
"$flutter" create --no-pub --platforms=web --project-name data_asset_gate . >/dev/null 2>&1 || exit 1
rm -f test/widget_test.dart
cat > pubspec.yaml <<EOF
name: data_asset_gate
description: "Dependency-hook DataAsset gate"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.13.0

dependencies:
  flutter:
    sdk: flutter
  data_asset_gate_package:
    path: $pkg

flutter:
  uses-material-design: true
EOF
printf 'import "package:flutter/material.dart";\nvoid main() => runApp(const MaterialApp(home: Text("data asset gate")));\n' > lib/main.dart
"$flutter" pub get >/dev/null 2>&1 || exit 1

runs() { cat "$pkg/.hook_runs" 2>/dev/null || echo 0; }
build() { "$flutter" build web --release --verbose >"$work/$1.log" 2>&1; echo $?; }

echo "== first build: declared DataAsset must be bundled =="
first=$(build first)
echo "exit=$first hook_runs=$(runs)"
[ "$first" -eq 0 ] || { echo "first build failed; see $work/first.log" >&2; exit 1; }
id1="$app/build/web/$asset_rel/id1.txt"
gen="$app/build/web/$asset_rel/generated.txt"
[ -f "$id1" ] || { echo "missing $id1" >&2; exit 2; }
[ "$(tr -d '\n' < "$id1")" = "package_content1" ] || { echo "wrong content in $id1" >&2; exit 2; }
[ -f "$gen" ] || { echo "missing hook-generated $gen" >&2; exit 2; }

echo "== unchanged rebuild: hook skipped, asset retained =="
before=$(runs)
second=$(build second)
echo "exit=$second hook_runs_before=$before hook_runs_after=$(runs)"
[ "$second" -eq 0 ] || exit 3
[ "$(runs)" = "$before" ] || { echo "the hook reran without an input change" >&2; exit 3; }
[ -f "$id1" ] || { echo "the asset disappeared on an unchanged rebuild" >&2; exit 3; }

echo "== changed asset input: output must follow =="
printf 'package_content2\n' > "$pkg/data/id1.txt"
third=$(build third)
echo "exit=$third hook_runs=$(runs) content=$(tr -d '\n' < "$id1" 2>/dev/null)"
[ "$third" -eq 0 ] || exit 4
[ "$(tr -d '\n' < "$id1")" = "package_content2" ] || { echo "output is stale after an input change" >&2; exit 4; }

echo "== removed asset input: the build must fail =="
mv "$pkg/data/id1.txt" "$pkg/data/id1.txt.bak"
fourth=$(build fourth)
mv "$pkg/data/id1.txt.bak" "$pkg/data/id1.txt"
echo "exit=$fourth"
[ "$fourth" -ne 0 ] || { echo "the build succeeded with a missing asset input" >&2; exit 5; }

echo "== throwing hook: build fails, compiler never starts =="
cp "$pkg/hook/build.dart" "$work/build.dart.orig"
cat > "$pkg/hook/build.dart" <<'EOF'
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    throw StateError('data asset hook boom');
  });
}
EOF
fifth=$(build fifth)
cp "$work/build.dart.orig" "$pkg/hook/build.dart"
echo "exit=$fifth dart2js_started=$(grep -c 'dart2js: Starting' "$work/fifth.log")"
[ "$fifth" -ne 0 ] || { echo "a throwing hook did not fail the build" >&2; exit 6; }
[ "$(grep -c 'dart2js: Starting' "$work/fifth.log")" -eq 0 ] || {
  echo "the compiler started although the hook failed" >&2
  exit 6
}

echo
echo "PASS: declared DataAsset bundled and tracked; failures are not silent."
echo "Scratch app: $app"
