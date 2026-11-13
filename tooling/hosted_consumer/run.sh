#!/usr/bin/env bash
# Published-consumer regression fixture.
#
# Builds a throwaway Flutter Web app whose ONLY DWI dependencies are hosted
# packages at `^$DWI_HOSTED_VERSION` from pub.dev (default `0.7.0`; no path
# overrides, isolated PUB_CACHE), then drives Chrome, Safari, Firefox and Edge
# against the site root and a `/sub/app/` mount.
#
# It also records the first-build limitation precisely:
#   * the generated-proxy app must NOT build on the first ordinary Flutter
#     command; it needs `dart run dwi_builder:dwi build` first;
#   * a proxy-free app builds on the first ordinary Flutter command.
# If the generated-proxy first build ever succeeds, this script exits 2 so the
# change is visible instead of being mistaken for a passing first build.
#
# Inputs:
#   FLUTTER     flutter launcher (default: `flutter` from PATH)
#   DART        dart launcher (default: the sibling `dart` of $FLUTTER).
#               This fixture builds a Flutter app, so it stays on the Dart
#               bundled with that Flutter checkout rather than the project
#               toolchain in .research/dart-sdk-dev/dart-sdk; Flutter does not
#               accept an external Dart SDK.
#   WORK_DIR    scratch root (default: a new temp directory)
#   PUB_CACHE   isolated pub cache (default: $WORK_DIR/pub-cache)
#   ENGINES     comma-separated engines (default: chrome,safari,firefox,edge)
#
# Exit codes:
#   0   all checks passed
#   2   the generated-proxy app built on the first command (behaviour changed)
#   3   a later build failed or did not package the worker
#   4   the first build failed for a reason other than the missing proxy
#   5   resolved packages are not all hosted on pub.dev
#   6   an engine result did not match the expected fixture payload
#   *   environment/setup failure (flutter create, pub get, probe launch)
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
flutter="${FLUTTER:-flutter}"
dart="${DART:-$(dirname "$(command -v "$flutter")")/dart}"
work="${WORK_DIR:-$(mktemp -d)}"
export PUB_CACHE="${PUB_CACHE:-$work/pub-cache}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.dev}"
engines="${ENGINES:-chrome,safari,firefox,edge}"
version="${DWI_HOSTED_VERSION:-0.7.0}"

app="$work/app"
proxyfree="$work/app_proxyfree"
serve="$work/serve"
mkdir -p "$work" "$PUB_CACHE" "$serve"

say() { printf '\n== %s ==\n' "$*"; }

write_pubspec() {
  local dir="$1" extra="$2"
  cat > "$dir/pubspec.yaml" <<EOF
name: hosted_consumer
description: "DWI published-consumer fixture"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.13.0

dependencies:
  flutter:
    sdk: flutter
  dwi: ^$version
  dwi_core: ^$version
  dwi_annotations: ^$version
$extra

flutter:
  uses-material-design: true
EOF
}

assert_hosted() {
  local dir="$1"
  python3 - "$dir/pubspec.lock" <<'PY'
import sys, yaml
lock = yaml.safe_load(open(sys.argv[1]))
bad = []
for name, entry in lock['packages'].items():
    if not name.startswith('dwi'):
        continue
    source = entry.get('source')
    url = entry.get('description', {}).get('url') if isinstance(entry.get('description'), dict) else None
    print(f"resolved {name} {entry.get('version')} source={source} url={url}")
    if source != 'hosted' or url != 'https://pub.dev':
        bad.append(name)
if bad:
    print('NOT HOSTED ON PUB.DEV: ' + ', '.join(bad), file=sys.stderr)
    sys.exit(1)
PY
}

say "scratch: $work"
say "target:  ^$version (hosted)"
say "flutter: $flutter"
say "dart:    $dart"
say "pub cache: $PUB_CACHE"

# ---------------------------------------------------------------------------
# Generated-proxy app
# ---------------------------------------------------------------------------
say "flutter create (generated-proxy app)"
(cd "$work" && "$flutter" create --no-pub --platforms=web --project-name hosted_consumer app)
write_pubspec "$app" "  dwi_builder: ^$version"
cp "$here/fixture/lib/tasks.dart" "$app/lib/tasks.dart"
cp "$here/fixture/lib/main.dart" "$app/lib/main.dart"
cat > "$app/web/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <base href="$FLUTTER_BASE_HREF">
  <meta charset="utf-8"><title>pending</title>
</head>
<body><script defer src="main.dart.js"></script></body>
</html>
EOF
rm -f "$app/test/widget_test.dart"
rm -f "$app/lib/dwi_tasks.g.dart"
rm -rf "$app/.dwi" "$app/web/dwi"

test ! -e "$app/lib/dwi_tasks.g.dart"
test ! -e "$app/web/dwi"
test ! -e "$app/pubspec_overrides.yaml"

say "flutter pub get (hosted only)"
(cd "$app" && "$flutter" pub get)

say "resolved package sources"
assert_hosted "$app"

test ! -e "$app/lib/dwi_tasks.g.dart" || {
  echo "UNEXPECTED: pub get already generated lib/dwi_tasks.g.dart; the first-build gate cannot run." >&2
  exit 2
}

say "first build: ordinary 'flutter build web --release' (expected to fail)"
pushd "$app" >/dev/null
set +e
"$flutter" build web --release > "$work/first-build.log" 2>&1
first=$?
set -e
popd >/dev/null
cat "$work/first-build.log"
echo "first build exit=$first"

if [ "$first" -eq 0 ]; then
  echo
  echo "BEHAVIOUR CHANGED: the first ordinary build succeeded for a fresh app that imports the generated proxy."
  echo "Re-measure the Flutter build ordering, then update docs/architecture.md (ADR-009),"
  echo "docs/limitations.md and this fixture. Do not treat a later successful build as the first-build pass." >&2
  exit 2
fi

grep -q "dwi_tasks.g.dart" "$work/first-build.log" || {
  echo "The first build failed, but not on the generated proxy. Inspect $work/first-build.log." >&2
  exit 4
}

say "pre-build: dart run dwi_builder:dwi build"
(cd "$app" && "$dart" run dwi_builder:dwi build)

say "second build: root"
(cd "$app" && "$flutter" build web --release)
test -f "$app/build/web/dwi/worker.dart.js" || {
  echo "The root build did not package build/web/dwi/worker.dart.js." >&2
  exit 3
}
cp -R "$app/build/web/." "$serve/"

say "third build: /sub/app/ base href"
(cd "$app" && "$flutter" build web --release --base-href /sub/app/)
test -f "$app/build/web/dwi/worker.dart.js" || {
  echo "The sub-path build did not package build/web/dwi/worker.dart.js." >&2
  exit 3
}
mkdir -p "$serve/sub/app"
cp -R "$app/build/web/." "$serve/sub/app/"

# ---------------------------------------------------------------------------
# Proxy-free app: must build on the first ordinary command
# ---------------------------------------------------------------------------
say "proxy-free app: first ordinary build"
(cd "$work" && "$flutter" create --no-pub --platforms=web --project-name hosted_consumer_proxyfree app_proxyfree)
cat > "$proxyfree/pubspec.yaml" <<EOF
name: hosted_consumer_proxyfree
description: "DWI hosted fixture with no generated proxy"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.13.0

dependencies:
  flutter:
    sdk: flutter
  dwi: ^$version

flutter:
  uses-material-design: true
EOF
cat > "$proxyfree/lib/main.dart" <<'EOF'
import 'package:dwi/dwi.dart';

// No generated-proxy import: this app must build on the first ordinary
// Flutter command, unlike the generated-proxy app above.
void main() {
  Dwi.capabilities();
}
EOF
rm -f "$proxyfree/test/widget_test.dart"
(cd "$proxyfree" && "$flutter" pub get)
(cd "$proxyfree" && "$flutter" build web --release) || {
  echo "The proxy-free app failed its first ordinary build; the documented first-build rule is wrong." >&2
  exit 3
}
test -f "$proxyfree/build/web/main.dart.js" || {
  echo "The proxy-free app did not produce main.dart.js." >&2
  exit 3
}
echo "proxy-free first build: success (as documented)"

# ---------------------------------------------------------------------------
# Browser matrix: root and /sub/app/
# ---------------------------------------------------------------------------
say "probe package setup"
(cd "$here/probe" && "$dart" pub get)

probe() {
  local mount="$1" out="$2"
  "$dart" "$here/probe/bin/probe.dart" --root "$serve" --mount "$mount" \
    --engines "$engines" | tee "$out"
}

say "browsers: site root"
probe "/" "$work/root.json"
say "browsers: /sub/app/"
# The trailing-slash directory is served as index.html explicitly; the page's
# <base href="/sub/app/"> still resolves every asset and the worker from the
# sub-path mount.
probe "/sub/app/index.html" "$work/sub.json"

say "validate fixture payloads"
python3 - "$work/root.json" "$work/sub.json" <<'PY'
import json, sys
expected = {
    'capabilityBackend': 'worker',
    'typed': 1,
    'fresh': [1, 1],
    'scoped': [1, 2],
    'handle': [1, 2],
    'stopBefore': True,
    'stopReason': 'callerClosed',
    'stopEvents': 'callerClosed',
    'channel': 'echo:ping',
    'remote': 'DwiRemoteException',
    'afterError': 'ok',
}
bad = []
for path in sys.argv[1:]:
    for entry in json.load(open(path)):
        if entry['status'] != 'ok':
            continue
        data = entry['data']
        for key, want in expected.items():
            got = data.get(key)
            if got != want:
                bad.append(f"{path} {entry['engine']}: {key}={got!r}, want {want!r}")
        if not isinstance(data.get('workerAssetBytes'), int) or data['workerAssetBytes'] <= 0:
            bad.append(f"{path} {entry['engine']}: worker asset not fetched ({data.get('workerAssetBytes')!r})")
if bad:
    print('\n'.join(bad), file=sys.stderr)
    sys.exit(6)
print('fixture payloads match on every available engine and mount')
PY

say "PASS"
echo "Scratch app: $app"
echo "Served tree: $serve"
echo "Results: $work/root.json $work/sub.json"
