#!/usr/bin/env bash
# Reproduces registered static-function identity on the VM and dart2js.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
dart="${DART:-$repo/.research/dart-sdk-dev/dart-sdk/bin/dart}"
source="$here/bin/static_identity_probe.dart"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expected="$(printf 'addOne:3\ntwice:4')"
vm="$("$dart" run "$source")"
test "$vm" = "$expected" || {
  printf 'VM mismatch: %s\n' "$vm" >&2
  exit 1
}

"$dart" compile js -O1 -o "$work/probe.js" "$source" >/dev/null
js="$(node "$work/probe.js")"
test "$js" = "$expected" || {
  printf 'dart2js mismatch: %s\n' "$js" >&2
  exit 1
}

printf 'VM and dart2js registered static identity: pass\n'
