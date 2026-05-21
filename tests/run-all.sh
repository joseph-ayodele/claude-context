#!/usr/bin/env bash
# Run every tests/test-*.sh sequentially. Exits non-zero on first failure.
#
# Usage:
#   bash tests/run-all.sh

set -uo pipefail

cd "$(dirname "$0")" || exit 1

failed=0
for test in test-*.sh; do
  printf '\n----- %s -----\n' "$test"
  if ! bash "$test"; then
    failed=$((failed + 1))
  fi
done

printf '\n=====\n'
if [[ $failed -gt 0 ]]; then
  printf '%d test file(s) FAILED\n' "$failed" >&2
  exit 1
fi
printf 'All tests passed\n'
