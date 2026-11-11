#!/usr/bin/env bash
# Reproduces registered static-function identity on a dart2wasm host in Chrome.
#
# Prerequisites: the repo's .research/flutter-sdk, Node is not used, Chrome and
# python3 (for a loopback static server).
#
# Inputs:
#   DART    dart launcher (default: repo .research/flutter-sdk/bin/cache/dart-sdk/bin/dart)
#   CHROME  Chrome binary (default: the macOS application path)
#   PORT    loopback port (default: 8765)
#
# Exit codes: 0 identity pass; 2 output mismatch; 3 Chrome missing;
#             anything else is an environment/compile failure.
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
dart="${DART:-$repo/.research/flutter-sdk/bin/cache/dart-sdk/bin/dart}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
port="${PORT:-8765}"

[ -x "$chrome" ] || {
  echo "Chrome not found at $chrome; set CHROME." >&2
  exit 3
}

work="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
  rm -rf "$work"
}
trap cleanup EXIT

"$dart" compile wasm -o "$work/identity.wasm" \
  "$here/bin/static_identity_probe.dart" >/dev/null

cat > "$work/identity.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>pending</title>
<pre id="out">pending</pre>
<script type="module">
const lines = [];
console.log = (...args) => { lines.push(args.map(String).join(' ')); };
try {
  const { compileStreaming } = await import('./identity.mjs');
  const compiled = await compileStreaming(fetch('./identity.wasm'));
  const app = await compiled.instantiate({}, {});
  app.invokeMain();
  document.getElementById('out').textContent = lines.join('\n');
  document.title = 'RESULT:' + lines.join('|');
} catch (e) {
  document.getElementById('out').textContent = 'ERROR: ' + (e && e.message ? e.message : e);
  document.title = 'ERROR';
}
</script>
HTML

( cd "$work" && python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
server_pid=$!
sleep 1

dom="$("$chrome" --headless=new --disable-gpu --no-sandbox \
  --user-data-dir="$work/chrome" --virtual-time-budget=5000 \
  --dump-dom "http://127.0.0.1:$port/identity.html" 2>/dev/null)"
title="$(printf '%s' "$dom" | sed -n 's:.*<title>\(.*\)</title>.*:\1:p' | head -1)"

expected="RESULT:addOne:3|twice:4"
if [ "$title" != "$expected" ]; then
  printf 'dart2wasm mismatch: %s\n' "$title" >&2
  printf '%s\n' "$dom" >&2
  exit 2
fi

printf 'dart2wasm (Chrome) registered static identity: pass\n'
