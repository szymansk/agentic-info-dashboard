#!/usr/bin/env bash
# Führt alle tests/test-*.sh aus; Exit ≠ 0, wenn einer scheitert.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0
for t in tests/test-*.sh; do
  echo "== $t"; bash "$t" || fail=1
done
[ "$fail" -eq 0 ] && echo "ALLE TESTS OK" || { echo "TESTS FEHLGESCHLAGEN"; exit 1; }
