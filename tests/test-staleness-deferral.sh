#!/usr/bin/env bash
# Verifies that the staleness check defers its reminder to the next
# UserPromptSubmit instead of blocking at Stop / PreCompact.
#
# Flow under test:
#   1. Doc for today is older than the 1hr grace AND there are newer code edits
#      → staleness hook (Stop) writes a marker, exits silent.
#   2. UserPromptSubmit reads the marker, returns hookSpecificOutput
#      (NOT decision: block), and consumes the marker.
#   3. A second UserPromptSubmit on the same doc state stays silent.
#
# Regression guard for the 2026-05-29 visual-disruption fix.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-staleness-deferral ==="
SANDBOX="$(make_sandbox)"
run_setup "$SANDBOX"

SESSIONS="$SANDBOX/ai-context/sessions"
TODAY="$(date +%Y-%m-%d)"
DOC="$SESSIONS/${TODAY}_myrepo_my-task.md"
MARKER="$SANDBOX/.claude/ai-context-stale-marker"
STALE_HOOK="$SANDBOX/.claude/hooks/ai-context-session-doc-staleness.sh"
UPS_HOOK="$SANDBOX/.claude/hooks/ai-context-session-doc-check.sh"

# Set up a stale doc + a newer file to make staleness fire.
cp "$SANDBOX/ai-context/templates/session.md" "$DOC"
# Age the doc past the 1hr grace window
if [[ "$(uname)" == "Darwin" ]]; then
  touch -t "$(date -v-2H +%Y%m%d%H%M)" "$DOC"
else
  touch -d "2 hours ago" "$DOC"
fi
# Newer code file in the working dir (cwd at hook invocation)
mkdir -p "$SANDBOX/proj"
echo "newer" > "$SANDBOX/proj/some-edit.txt"

# Step 1: Stop hook should be silent and write the marker.
out=$(cd "$SANDBOX/proj" && HOME="$SANDBOX" bash "$STALE_HOOK" <<<'{"hook_event_name":"Stop"}')
assert_eq "Stop hook is silent" "" "$out"
assert_file "Stop hook wrote staleness marker" "$MARKER"

# Marker should be valid JSON pointing at the right doc
marker_doc=$(jq -r '.session_doc' "$MARKER")
assert_eq "marker points at today's doc" "$DOC" "$marker_doc"
marker_event=$(jq -r '.event' "$MARKER")
assert_eq "marker records originating event" "Stop" "$marker_event"
marker_count=$(jq -r '.newer_files | length' "$MARKER")
if [[ "$marker_count" -gt 0 ]]; then _pass "marker has newer_files"; else _fail "marker has newer_files" "≥1" "0"; fi

# Step 2: UserPromptSubmit consumes the marker, injects context, exits silent.
ups_out=$(cd "$SANDBOX/proj" && HOME="$SANDBOX" bash "$UPS_HOOK" <<<'{}')

# Must NOT be a block decision
ups_decision=$(echo "$ups_out" | jq -r '.decision // ""')
assert_eq "UserPromptSubmit does not block" "" "$ups_decision"

# Must inject the carry-over staleness reminder
ups_ctx=$(echo "$ups_out" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "context mentions CARRIED-OVER STALENESS" "CARRIED-OVER STALENESS" "$ups_ctx"
assert_contains "context names the doc" "$DOC" "$ups_ctx"
assert_contains "context tells Claude to fold work in" "fold the previous turn" "$ups_ctx"

# Marker must be consumed
assert_no_file "marker consumed after UserPromptSubmit" "$MARKER"

# Step 3: Second UserPromptSubmit on the same state must be silent
ups_out2=$(cd "$SANDBOX/proj" && HOME="$SANDBOX" bash "$UPS_HOOK" <<<'{}')
assert_eq "second UserPromptSubmit silent (marker gone, doc fresh)" "" "$ups_out2"

# --- PreCompact variant: marker should record event="PreCompact" ---
echo "newer2" > "$SANDBOX/proj/some-edit-2.txt"
out=$(cd "$SANDBOX/proj" && HOME="$SANDBOX" bash "$STALE_HOOK" <<<'{"hook_event_name":"PreCompact"}')
assert_eq "PreCompact hook is silent" "" "$out"
assert_file "PreCompact hook wrote staleness marker" "$MARKER"
marker_event=$(jq -r '.event' "$MARKER")
assert_eq "marker records PreCompact event" "PreCompact" "$marker_event"

# Cleanup
rm -f "$MARKER"

finish
