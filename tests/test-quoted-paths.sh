#!/usr/bin/env bash
# Regression test for the T1 P0 bug: HOME with spaces in the path must
# produce hooks and an alias that actually work.

source "$(dirname "$0")/lib.sh"

echo "=== test-quoted-paths ==="

# Build a sandbox with a deliberately spaced path
PARENT="$(mktemp -d)"
SANDBOX="$PARENT/path with spaces/home"
mkdir -p "$SANDBOX"
trap 'rm -rf "$PARENT"' EXIT

run_setup "$SANDBOX"

# Pull the SessionStart hook command and execute it the way Claude Code would
cmd=$(HOME="$SANDBOX" jq -r '.hooks.SessionStart[0].hooks[0].command' "$SANDBOX/.claude/settings.json")

# Run via sh -c, which is how Claude Code invokes it
out=$(HOME="$SANDBOX" sh -c "$cmd" </dev/null 2>&1)
rc=$?

assert_eq "hook command exits 0 with spaced HOME" "0" "$rc"
assert_contains "hook output is valid JSON with the checklist" "SESSION-START CHECKLIST" "$out"

# Alias line should single-quote the path so it survives re-parsing
alias_line=$(grep "^alias cc=" "$SANDBOX/.zshrc")
assert_contains "alias single-quotes the spaced path" "'$SANDBOX/ai-context'" "$alias_line"

finish
