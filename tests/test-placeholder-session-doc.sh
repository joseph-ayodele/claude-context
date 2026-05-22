#!/usr/bin/env bash
# Verifies that SessionStart auto-creates a placeholder session doc
# (YYYY-MM-DD_session_pending.md) when no doc for today exists,
# so UserPromptSubmit doesn't block the user's first prompt.
#
# Also verifies:
#   - Placeholder is NOT re-created if any YYYY-MM-DD_*.md already exists
#   - UserPromptSubmit hook stays silent once the placeholder is in place
#   - SessionStart's injected context tells Claude to rename + fill
#
# This is the regression test for the "fresh-session UserPromptSubmit block"
# reported in 2026-05-22_claude-context_fix-userpromptsubmit-block-on-fresh-session.md.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-placeholder-session-doc ==="
SANDBOX="$(make_sandbox)"
run_setup "$SANDBOX"

SESSIONS="$SANDBOX/ai-context/sessions"
TODAY="$(date +%Y-%m-%d)"
PLACEHOLDER="$SESSIONS/${TODAY}_session_pending.md"

# Sanity: clean slate
assert_no_file "no doc for today before SessionStart" "$PLACEHOLDER"

# Trigger SessionStart
hook_out=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null)

# Placeholder should now exist
assert_file "placeholder created on fresh session" "$PLACEHOLDER"

# Content should be the template
content="$(cat "$PLACEHOLDER")"
assert_contains "placeholder uses session.md template" "[TASK DESCRIPTION]" "$content"

# Injected context should tell Claude to rename + fill
ctx=$(echo "$hook_out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "context mentions rename" "RENAME" "$ctx"
assert_contains "context names the placeholder" "${TODAY}_session_pending.md" "$ctx"

# UserPromptSubmit should now be silent (placeholder satisfies its check)
ups_out=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-session-doc-check.sh" <<<'{}' || true)
assert_eq "UserPromptSubmit silent when placeholder exists" "" "$ups_out"

# Re-running SessionStart must NOT create a second placeholder when one exists
mtime_before=$(stat -f %m "$PLACEHOLDER" 2>/dev/null || stat -c %Y "$PLACEHOLDER" 2>/dev/null)
sleep 1
HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null >/dev/null
mtime_after=$(stat -f %m "$PLACEHOLDER" 2>/dev/null || stat -c %Y "$PLACEHOLDER" 2>/dev/null)
assert_eq "placeholder not overwritten on re-run" "$mtime_before" "$mtime_after"

# If a real (renamed) doc already exists, placeholder must NOT be created
rm -f "$PLACEHOLDER"
RENAMED="$SESSIONS/${TODAY}_myrepo_my-task.md"
cp "$SANDBOX/ai-context/templates/session.md" "$RENAMED"
HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null >/dev/null
assert_no_file "placeholder skipped when a real doc exists" "$PLACEHOLDER"
assert_file "real doc still in place" "$RENAMED"

finish
