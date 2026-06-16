#!/usr/bin/env bash
# Verifies the context-pressure hook + UserPromptSubmit nudge.
#
# Flow under test:
#   1. PreCompact / transcript-size / idle signal at Stop → per-session
#      marker written silently at ~/.claude/claude-context-stale-marker-<session_id>.
#   2. UserPromptSubmit reads the marker for ITS session_id and injects a
#      SOFT NUDGE (no specific files prescribed). Marker is consumed.
#   3. A different session_id does NOT see the marker (per-session keying).
#   4. After consumption, a follow-up UserPromptSubmit for the same session
#      is silent.
#
# Updated 2026-06-15 for the conversational staleness redesign:
#   - file-mtime "newer code edits" check replaced with PreCompact /
#     transcript-size / idle-90min signals
#   - global marker replaced with per-session_id marker
#   - UserPromptSubmit nudge no longer lists specific files (passive)

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-staleness-deferral ==="
SANDBOX="$(make_sandbox)"
run_setup "$SANDBOX"

SESSIONS="$SANDBOX/ai-context/sessions"
TASKS="$SESSIONS/tasks"
TODAY="$(date +%Y-%m-%d)"
SESSION_ID="test-$$-$(date +%s)"
DOC="$TASKS/my-task/${TODAY}_implementation.md"
mkdir -p "$TASKS/my-task"
cp "$SANDBOX/ai-context/templates/session.md" "$DOC"
MARKER="$SANDBOX/.claude/claude-context-stale-marker-${SESSION_ID}"
STALE_HOOK="$SANDBOX/.claude/hooks/claude-context-session-doc-staleness.sh"
UPS_HOOK="$SANDBOX/.claude/hooks/claude-context-session-doc-check.sh"

# Set up working dir under ~/code so the cwd guard passes
mkdir -p "$SANDBOX/code/proj"

# Step 1a: PreCompact event fires the marker even with a small transcript.
TRANSCRIPT="$SANDBOX/.claude/transcript.jsonl"
echo "tiny transcript" > "$TRANSCRIPT"
input=$(jq -n \
  --arg sid "$SESSION_ID" \
  --arg tp "$TRANSCRIPT" \
  '{hook_event_name: "PreCompact", session_id: $sid, transcript_path: $tp}')
out=$(cd "$SANDBOX/code/proj" && HOME="$SANDBOX" bash "$STALE_HOOK" <<<"$input")
assert_eq "PreCompact hook is silent" "" "$out"
assert_file "PreCompact wrote per-session marker" "$MARKER"

# Marker should record reasons array containing "precompact"
marker_reasons=$(jq -r '.reasons | join(",")' "$MARKER")
assert_contains "marker reasons include precompact" "precompact" "$marker_reasons"
marker_session=$(jq -r '.session_id' "$MARKER")
assert_eq "marker records session_id" "$SESSION_ID" "$marker_session"

# Step 2: UserPromptSubmit injects a soft nudge for THIS session.
ups_input=$(jq -n --arg sid "$SESSION_ID" '{session_id: $sid}')
ups_out=$(cd "$SANDBOX/code/proj" && HOME="$SANDBOX" bash "$UPS_HOOK" <<<"$ups_input")

# Must not be a block decision
ups_decision=$(echo "$ups_out" | jq -r '.decision // ""')
assert_eq "UserPromptSubmit does not block" "" "$ups_decision"

# Must inject the CONTEXT-PRESSURE notice
ups_ctx=$(echo "$ups_out" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "context mentions CONTEXT-PRESSURE" "CONTEXT-PRESSURE" "$ups_ctx"
assert_contains "context names the doc" "$DOC" "$ups_ctx"
# Soft-nudge wording: must allow "ignore if not relevant"
assert_contains "context tells Claude it can ignore the nudge" "ignore this nudge" "$ups_ctx"
# Must NOT prescribe specific files (the old "fold these files in" behavior)
ups_lower=$(echo "$ups_ctx" | tr '[:upper:]' '[:lower:]')
assert_not_contains "context does NOT list specific newer_files" "newer_files" "$ups_lower"

# Marker consumed
assert_no_file "marker consumed by UserPromptSubmit" "$MARKER"

# Step 3: Same prompt again, no marker, silent.
ups_out2=$(cd "$SANDBOX/code/proj" && HOME="$SANDBOX" bash "$UPS_HOOK" <<<"$ups_input")
assert_eq "second UserPromptSubmit silent (marker gone)" "" "$ups_out2"

# Step 4: Per-session keying — sessionA's marker is not consumed by sessionB.
SESSION_A="sessA-$$"
SESSION_B="sessB-$$"
MARKER_A="$SANDBOX/.claude/claude-context-stale-marker-${SESSION_A}"
MARKER_B="$SANDBOX/.claude/claude-context-stale-marker-${SESSION_B}"
input_a=$(jq -n --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT" \
  '{hook_event_name: "PreCompact", session_id: $sid, transcript_path: $tp}')
out=$(cd "$SANDBOX/code/proj" && HOME="$SANDBOX" bash "$STALE_HOOK" <<<"$input_a")
assert_file "session A marker exists" "$MARKER_A"
assert_no_file "session B marker absent" "$MARKER_B"

# B's UserPromptSubmit must be silent — it doesn't see A's marker
ups_input_b=$(jq -n --arg sid "$SESSION_B" '{session_id: $sid}')
ups_b=$(cd "$SANDBOX/code/proj" && HOME="$SANDBOX" bash "$UPS_HOOK" <<<"$ups_input_b")
assert_eq "session B UserPromptSubmit silent (no marker for B)" "" "$ups_b"
assert_file "session A marker still present after B's prompt" "$MARKER_A"

# A's UserPromptSubmit consumes its own marker
ups_input_a=$(jq -n --arg sid "$SESSION_A" '{session_id: $sid}')
ups_a=$(cd "$SANDBOX/code/proj" && HOME="$SANDBOX" bash "$UPS_HOOK" <<<"$ups_input_a")
assert_no_file "session A marker consumed by A's UserPromptSubmit" "$MARKER_A"
ups_a_ctx=$(echo "$ups_a" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "session A receives CONTEXT-PRESSURE nudge" "CONTEXT-PRESSURE" "$ups_a_ctx"

# Step 5: Without session_id (e.g. test harness or older agent), staleness
# hook silently skips without writing any marker.
input_no_sid=$(jq -n '{hook_event_name: "Stop"}')
out=$(cd "$SANDBOX/code/proj" && HOME="$SANDBOX" bash "$STALE_HOOK" <<<"$input_no_sid")
assert_eq "no-session_id Stop hook is silent" "" "$out"
# No global stale-marker (legacy file) should have been written either
assert_no_file "no global stale-marker created" "$SANDBOX/.claude/claude-context-stale-marker"

finish
