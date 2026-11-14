#!/usr/bin/env bash
# Strict-CSP run of the browser matrix page (tranche A7).
#
# Builds two served roots in a temp directory:
#   csp/      the matrix page under a strict meta CSP (no inline script, no
#             eval, no blob: workers; same-origin scripts and workers only)
#   control/  a page whose inline script must be blocked by the same CSP; if
#             an engine runs it, that engine is not enforcing the policy and
#             its csp result cannot be trusted
# Then runs tooling/hosted_consumer/probe on both, for every engine.
#
# Prerequisites: benchmarks/browser_matrix/web/main.dart.js and web/dwi/ exist
# (built by `dart run run.dart --engine=chrome --runs=1`), and Dart on PATH.
#
# Usage: benchmarks/browser_matrix/run_csp.sh [engines]   (default: all four)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
engines="${1:-chrome,safari,firefox,edge}"
csp="default-src 'none'; script-src 'self'; worker-src 'self'; connect-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; object-src 'none'; form-action 'none'"

work="$(mktemp -d "${TMPDIR:-/tmp}/dwi_csp.XXXXXX")"
mkdir -p "$work/csp" "$work/control"

cp "$here/web/main.dart.js" "$work/csp/"
cp -R "$here/web/dwi" "$work/csp/"
cat > "$work/csp/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="$csp">
<title>pending</title>
</head>
<body>
<script defer src="main.dart.js"></script>
</body>
</html>
EOF

# Control: an external script runs first and writes "inline:false"; the inline
# script must be blocked, so the title keeps "inline:false". If the inline
# script runs, the engine did not enforce the policy.
cat > "$work/control/ctl.js" <<'EOF'
document.title = btoa(JSON.stringify({ inlineRan: false }));
EOF
cat > "$work/control/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="$csp">
<title>pending</title>
</head>
<body>
<script src="ctl.js"></script>
<script>document.title = btoa(JSON.stringify({ inlineRan: true }));</script>
</body>
</html>
EOF

cd "$repo/tooling/hosted_consumer/probe"
dart pub get >/dev/null
echo "== csp page ($work/csp)"
dart run bin/probe.dart --root "$work/csp" --engines "$engines"
echo "== control page ($work/control)"
dart run bin/probe.dart --root "$work/control" --engines "$engines"
