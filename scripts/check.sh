#!/bin/bash
# Everything CI runs, plus qmllint when a local Omarchy install is present.
#   scripts/check.sh            unit tests, script tests, manifest validation, lint
#   scripts/check.sh --quick    unit tests only

set -uo pipefail
cd "$(dirname "$0")/.."
status=0

echo "== lib unit tests"
node tests/lib.test.js || status=1
echo
echo "== boot-time profiles (real Lua)"
node tests/lua-profiles.test.js || status=1
[[ ${1:-} == --quick ]] && exit $status

echo
echo "== control script tests"
bash tests/ctl.test.sh || status=1

echo
echo "== shell syntax"
for f in bin/*; do bash -n "$f" || status=1; done

echo
echo "== manifest"
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate . || status=1
else
  jq -e '.schemaVersion == 1 and .id == "omnidisplay" and (.entryPoints | length) == 2' manifest.json >/dev/null || status=1
  echo "manifest.json parses (omarchy not installed: full validation skipped)"
fi

if [[ -x /usr/lib/qt6/bin/qmllint && -d ${OMARCHY_PATH:-/usr/share/omarchy}/shell ]]; then
  echo
  echo "== qmllint (syntax errors only)"
  lint_dir=$(mktemp -d)
  ln -s "${OMARCHY_PATH:-/usr/share/omarchy}/shell" "$lint_dir/qs"
  for f in Service.qml Panel.qml components/*.qml views/*.qml; do
    if /usr/lib/qt6/bin/qmllint -I "$lint_dir" -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" "$f" 2>&1 | grep -qE "SyntaxError|Expected token|duplicated-name|property-override"; then
      echo "lint: $f"
      /usr/lib/qt6/bin/qmllint -I "$lint_dir" "$f" 2>&1 | grep -E "SyntaxError|Expected token|duplicated-name|property-override"
      status=1
    fi
  done
  rm -rf "$lint_dir"
fi

echo
(( status == 0 )) && echo "all checks passed" || echo "CHECKS FAILED"
exit $status
