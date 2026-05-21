#!/usr/bin/env bash
# tests/lib.sh — shared helpers for the setup.sh test suite.
#
# Sourced by every test file. Provides:
#   - sandbox HOME setup/teardown
#   - assert_eq / assert_contains / assert_file / assert_no_file
#   - run_setup wrapper that always uses --skip-gbrain to keep tests offline
#
# Test discipline: each tests/test-*.sh sets up its own sandbox and
# tears it down at the end (via trap). No state crosses between tests.

set -euo pipefail

# Resolve the repo root from any test file location.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

# ----- Sandbox -----

# Each test calls `make_sandbox` once, gets back a path, and a trap
# is registered to clean it up on exit.
make_sandbox() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "'"$dir"'"' EXIT
  printf '%s\n' "$dir"
}

# Run setup with sandbox HOME. Always passes --skip-gbrain so tests don't
# touch the real ~/.gbrain. Forwards extra flags. Suppresses stdout/stderr
# unless the test explicitly wants them (use `run_setup_verbose` then).
run_setup() {
  local home="$1"; shift
  HOME="$home" bash "$SETUP" --yes --skip-gbrain "$@" >/dev/null 2>&1
}

run_setup_verbose() {
  local home="$1"; shift
  HOME="$home" bash "$SETUP" --yes --skip-gbrain "$@" 2>&1
}

# ----- Assertions -----
# Each prints PASS/FAIL with the test name and the expected/actual on failure.
# A FAIL increments _FAIL_COUNT; the test runner checks it at the end.

_FAIL_COUNT=0
_TEST_NAME="${0##*/}"

_pass() { printf '  ✓ %s\n' "$1"; }
_fail() { printf '  ✗ %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3" >&2; _FAIL_COUNT=$((_FAIL_COUNT+1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$label"
  else
    _fail "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$label"
  else
    _fail "$label" "(contains) $needle" "$haystack"
  fi
}

assert_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    _pass "$label"
  else
    _fail "$label" "file exists: $path" "missing"
  fi
}

assert_no_file() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    _pass "$label"
  else
    _fail "$label" "no file at: $path" "still exists"
  fi
}

# Call at the end of a test file. Exits non-zero if any assertion failed.
finish() {
  if [[ $_FAIL_COUNT -gt 0 ]]; then
    printf '\n%s: %d assertion(s) failed\n' "$_TEST_NAME" "$_FAIL_COUNT" >&2
    exit 1
  fi
  printf '\n%s: all assertions passed\n' "$_TEST_NAME"
}
