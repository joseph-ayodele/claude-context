#!/usr/bin/env bash
# The gbrain hook must silently exit 0 when:
#   - gbrain CLI is missing from PATH, OR
#   - gbrain is on PATH but ~/.gbrain/config.json doesn't exist (sandbox case)
#
# We can't easily remove gbrain from PATH for this process, but we can use
# the second condition: a sandboxed HOME has no ~/.gbrain/config.json, so
# the hook should silently skip even when the real gbrain CLI is installed.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-gbrain-skip ==="
SANDBOX="$(make_sandbox)"

run_setup "$SANDBOX"

# Drop a session doc so there's something to potentially ingest
TODAY=$(date +%Y-%m-%d)
echo "# test session" > "$SANDBOX/ai-context/sessions/${TODAY}_test.md"

# Run the hook with sandboxed HOME — no ~/.gbrain/config.json, must silently skip
out=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-gbrain-sync.sh" 2>&1)
rc=$?

assert_eq "gbrain hook exits 0 with no config" "0" "$rc"
assert_eq "gbrain hook produces no output when skipping" "" "$out"

# State dir is NOT created when the hook hard-skips at the config check
# (the mkdir comes after the config probe)
assert_no_file "state dir not created on skip" "$SANDBOX/.claude/ai-context-state"

finish
