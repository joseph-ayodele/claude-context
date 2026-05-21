#!/usr/bin/env bash
# install → uninstall → final state should be clean.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-uninstall ==="
SANDBOX="$(make_sandbox)"

run_setup "$SANDBOX"

# Confirm install state
hook_count=0
if [[ -d "$SANDBOX/.claude/hooks" ]]; then
  hook_count=$(find "$SANDBOX/.claude/hooks" -maxdepth 1 -type f -name 'ai-context-*.sh' | wc -l | tr -d ' ')
fi
assert_eq "4 hooks installed" "4" "$hook_count"

# Run uninstall (--yes accepts confirms for deleting context dir + global CLAUDE.md)
HOME="$SANDBOX" bash "$SETUP" --uninstall --yes >/dev/null 2>&1

# Hook scripts gone
assert_no_file "hook script removed: ai-context-check"            "$SANDBOX/.claude/hooks/ai-context-check.sh"
assert_no_file "hook script removed: ai-context-gbrain-sync"      "$SANDBOX/.claude/hooks/ai-context-gbrain-sync.sh"
assert_no_file "hook script removed: ai-context-session-doc-check" "$SANDBOX/.claude/hooks/ai-context-session-doc-check.sh"
assert_no_file "hook script removed: ai-context-session-doc-staleness" "$SANDBOX/.claude/hooks/ai-context-session-doc-staleness.sh"

# Settings.json hook keys all empty/removed
remaining_keys=$(HOME="$SANDBOX" jq -r '.hooks // {} | keys | length' "$SANDBOX/.claude/settings.json")
assert_eq "no hook keys left in settings.json" "0" "$remaining_keys"

# Alias removed. grep -c returns 1 when no match, which fights `set -e`,
# so route through `|| true`.
alias_remaining=0
if [[ -f "$SANDBOX/.zshrc" ]]; then
  alias_remaining=$(grep -c "^alias cc=" "$SANDBOX/.zshrc" 2>/dev/null || true)
fi
assert_eq "alias removed" "0" "$alias_remaining"

# State dir removed
assert_no_file "state dir removed" "$SANDBOX/.claude/ai-context-state"

# With --yes confirms, both context dir and global CLAUDE.md are deleted
assert_no_file "context dir deleted (yes confirmed)" "$SANDBOX/ai-context"
assert_no_file "global CLAUDE.md deleted (yes confirmed)" "$SANDBOX/.claude/CLAUDE.md"

finish
