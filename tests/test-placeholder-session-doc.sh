#!/usr/bin/env bash
# Verifies that SessionStart auto-creates a placeholder session doc under
# sessions/tasks/_inbox/ when no doc for today exists, so UserPromptSubmit
# doesn't block the user's first prompt.
#
# Also verifies:
#   - Placeholder is NOT re-created if any matching doc already exists
#     (in either the new task-folder shape or the legacy flat shape)
#   - UserPromptSubmit hook stays silent once the placeholder is in place
#   - SessionStart's injected context tells Claude what to do with the placeholder
#
# Originally a regression test for "fresh-session UserPromptSubmit block"
# (2026-05-22). Updated 2026-06-15 for the task-folder redesign:
#   sessions/<date>_session_pending.md  →  sessions/tasks/_inbox/<date>_session_pending.md

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-placeholder-session-doc ==="
SANDBOX="$(make_sandbox)"
run_setup "$SANDBOX"

SESSIONS="$SANDBOX/ai-context/sessions"
TASKS="$SESSIONS/tasks"
INBOX="$TASKS/_inbox"
TODAY="$(date +%Y-%m-%d)"
PLACEHOLDER="$INBOX/${TODAY}_session_pending.md"

# Sanity: clean slate
assert_no_file "no doc for today before SessionStart" "$PLACEHOLDER"

# Trigger SessionStart
hook_out=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null)

# Placeholder should now exist under _inbox/
assert_file "placeholder created on fresh session" "$PLACEHOLDER"

# Content should be the template
content="$(cat "$PLACEHOLDER")"
assert_contains "placeholder uses session.md template" "[TASK DESCRIPTION]" "$content"

# Injected context should tell Claude what to do with the inbox file
ctx=$(echo "$hook_out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "context references the inbox placeholder" "_inbox" "$ctx"
assert_contains "context names the placeholder" "${TODAY}_session_pending.md" "$ctx"

# UserPromptSubmit should now be silent (placeholder satisfies its check)
ups_out=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-session-doc-check.sh" <<<'{}' || true)
assert_eq "UserPromptSubmit silent when placeholder exists" "" "$ups_out"

# Re-running SessionStart must NOT create a second placeholder when one exists.
# Portable mtime: GNU stat uses -c %Y; BSD stat uses -f %m. Branch on uname
# to be unambiguous.
file_mtime() {
  if [[ "$(uname)" == "Darwin" ]]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}
mtime_before=$(file_mtime "$PLACEHOLDER")
sleep 1
HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null >/dev/null
mtime_after=$(file_mtime "$PLACEHOLDER")
assert_eq "placeholder not overwritten on re-run" "$mtime_before" "$mtime_after"

# If a real session doc already exists (in a task folder), placeholder must NOT be created
rm -f "$PLACEHOLDER"
TASK_FOLDER="$TASKS/my-real-task"
mkdir -p "$TASK_FOLDER"
REAL_DOC="$TASK_FOLDER/${TODAY}_implementation.md"
cp "$SANDBOX/ai-context/templates/session.md" "$REAL_DOC"
HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null >/dev/null
assert_no_file "placeholder skipped when a real task-folder doc exists" "$PLACEHOLDER"
assert_file "real task-folder doc still in place" "$REAL_DOC"
rm -rf "$TASK_FOLDER"

# Legacy doc shape also satisfies the gate (back-compat for the 34 historical files)
LEGACY_DOC="$SESSIONS/${TODAY}_legacy_my-task.md"
cp "$SANDBOX/ai-context/templates/session.md" "$LEGACY_DOC"
HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null >/dev/null
assert_no_file "placeholder skipped when a legacy daily-shape doc exists" "$PLACEHOLDER"
assert_file "legacy doc still in place" "$LEGACY_DOC"
rm -f "$LEGACY_DOC"

# --- Midnight rollover scenario ---
# A session resumed across midnight: SessionStart doesn't re-fire on resume,
# so the first UserPromptSubmit of the new day finds no doc for today.
# UserPromptSubmit must auto-create the placeholder + inject context, NOT block.
assert_no_file "clean slate for rollover test" "$PLACEHOLDER"

ups_out=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-session-doc-check.sh" <<<'{}')
ups_exit=$?
assert_eq "UserPromptSubmit exits 0 (not blocking)" "0" "$ups_exit"
assert_file "UserPromptSubmit auto-creates placeholder on rollover" "$PLACEHOLDER"

# Output must be valid JSON with hookSpecificOutput, NOT decision:block
ups_decision=$(echo "$ups_out" | jq -r '.decision // ""')
assert_eq "UserPromptSubmit does not return decision=block" "" "$ups_decision"

ups_ctx=$(echo "$ups_out" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "UserPromptSubmit context references _inbox" "_inbox" "$ups_ctx"

# Second UserPromptSubmit on the same turn — placeholder now exists, silent
ups_out2=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-session-doc-check.sh" <<<'{}')
assert_eq "UserPromptSubmit silent on re-run with placeholder present" "" "$ups_out2"

finish
