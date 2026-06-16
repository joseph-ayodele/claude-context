#!/usr/bin/env bash
# install → uninstall → final state should be clean.
#
# Verifies:
#   - 4 hook scripts removed
#   - Settings.json hook entries removed
#   - Alias removed from shell rc
#   - State dir removed
#   - Sidecars cleaned up
#   - Runtime files (status, markers, bypass, decline-streak) removed
#   - Under --uninstall --yes, user data (context dir, global CLAUDE.md) is
#     PRESERVED — --yes does NOT auto-confirm destructive prompts.
#   - When the user explicitly answers "y" to those prompts, data IS deleted.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-uninstall ==="
SANDBOX="$(make_sandbox)"

run_setup "$SANDBOX"

# Confirm install state
hook_count=0
if [[ -d "$SANDBOX/.claude/hooks" ]]; then
  hook_count=$(find "$SANDBOX/.claude/hooks" -maxdepth 1 -type f -name 'claude-context-*.sh' | wc -l | tr -d ' ')
fi
assert_eq "4 hooks installed" "4" "$hook_count"

# Pre-create runtime files that uninstall should remove. The hooks would
# normally write these during use; we simulate that by placing them now.
echo "test status" > "$SANDBOX/.claude/claude-context-status.md"
echo '{}'         > "$SANDBOX/.claude/claude-context-stale-marker"
echo '{}'         > "$SANDBOX/.claude/claude-context-stale-marker-sessA"
echo '{}'         > "$SANDBOX/.claude/claude-context-stale-marker-sessB"
echo "1"          > "$SANDBOX/.claude/.graduate-decline-streak"
touch "$SANDBOX/.claude/claude-context-bypass"

# First uninstall: --yes alone, no extra confirms. Data-deletion prompts ask
# and default-no, so context dir + global CLAUDE.md SHOULD survive.
HOME="$SANDBOX" bash "$SETUP" --uninstall --yes </dev/null >/dev/null 2>&1

# Hook scripts gone
assert_no_file "hook script removed: claude-context-check"            "$SANDBOX/.claude/hooks/claude-context-check.sh"
assert_no_file "hook script removed: claude-context-gbrain-sync"      "$SANDBOX/.claude/hooks/claude-context-gbrain-sync.sh"
assert_no_file "hook script removed: claude-context-session-doc-check" "$SANDBOX/.claude/hooks/claude-context-session-doc-check.sh"
assert_no_file "hook script removed: claude-context-session-doc-staleness" "$SANDBOX/.claude/hooks/claude-context-session-doc-staleness.sh"

# Settings.json hook keys all empty/removed
remaining_keys=$(HOME="$SANDBOX" jq -r '.hooks // {} | keys | length' "$SANDBOX/.claude/settings.json")
assert_eq "no hook keys left in settings.json" "0" "$remaining_keys"

# Alias removed.
alias_remaining=0
if [[ -f "$SANDBOX/.zshrc" ]]; then
  alias_remaining=$(grep -c "^alias cc=" "$SANDBOX/.zshrc" 2>/dev/null || true)
fi
assert_eq "alias removed" "0" "$alias_remaining"

# State dir removed
assert_no_file "state dir removed" "$SANDBOX/.claude/claude-context-state"

# Runtime files removed (the new uninstall cleanup)
assert_no_file "status file removed" "$SANDBOX/.claude/claude-context-status.md"
assert_no_file "legacy global stale marker removed" "$SANDBOX/.claude/claude-context-stale-marker"
assert_no_file "per-session marker A removed" "$SANDBOX/.claude/claude-context-stale-marker-sessA"
assert_no_file "per-session marker B removed" "$SANDBOX/.claude/claude-context-stale-marker-sessB"
assert_no_file "bypass file removed" "$SANDBOX/.claude/claude-context-bypass"
assert_no_file "decline-streak counter removed" "$SANDBOX/.claude/.graduate-decline-streak"

# User data SURVIVES under --yes alone (--yes does NOT auto-confirm data
# deletion). Use -e for the context dir (it's a directory; assert_file's -f
# would false-fail on directories).
if [[ -e "$SANDBOX/ai-context" ]]; then
  _pass "context dir preserved under --uninstall --yes"
else
  _fail "context dir preserved under --uninstall --yes" "exists" "missing"
fi
assert_file "global CLAUDE.md preserved under --uninstall --yes" "$SANDBOX/.claude/CLAUDE.md"

# Now: a second uninstall where the user explicitly answers "y" to both
# data-deletion prompts. Reinstall first (fresh state for this branch).
run_setup "$SANDBOX"

# Pipe "y\ny\n" so confirm() sees yes for both prompts.
HOME="$SANDBOX" bash "$SETUP" --uninstall --yes <<<$'y\ny\n' >/dev/null 2>&1

assert_no_file "context dir deleted when explicitly confirmed" "$SANDBOX/ai-context"
assert_no_file "global CLAUDE.md deleted when explicitly confirmed" "$SANDBOX/.claude/CLAUDE.md"

finish
