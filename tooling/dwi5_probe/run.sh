#!/usr/bin/env bash
# Experimental DWI-5 analyzer probe.
#
# Inputs:
#   DART       dart launcher (default: repo .research/flutter-sdk/bin/dart)
#   PUB_CACHE  writable pub cache (default: repo .research/pub-cache)
#
# Exit codes: 0 probe ran; anything else is an environment/resolve failure.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
dart="${DART:-$repo/.research/flutter-sdk/bin/dart}"
export PUB_CACHE="${PUB_CACHE:-$repo/.research/pub-cache}"

cd "$here"
"$dart" pub get --offline >/dev/null
exec "$dart" run bin/analyze_forms.dart "$@"
