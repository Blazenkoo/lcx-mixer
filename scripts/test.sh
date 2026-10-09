#!/bin/bash
# Runs every test: the Swift tests (swift test) and the extension's page-script tests (Node).
# Usage: ./scripts/test.sh
set -uo pipefail

cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

status=0
echo "==> Swift tests"
swift test || status=1

echo "==> Extension tests"
if command -v node >/dev/null 2>&1; then
  node --test Tests/extension/*.test.mjs || status=1
else
  echo "    Node isn't installed on this Mac, so these were skipped. CI runs them on every push."
fi

if [ "$status" = 0 ]; then echo "==> All tests passed"; else echo "==> Some tests failed"; fi
exit "$status"
