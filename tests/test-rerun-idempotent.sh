#!/usr/bin/env bash
# Re-running setup is idempotent: same hook count, same alias count, no
# duplicate entries in settings.json, user-edited templates preserved.

source "$(dirname "$0")/lib.sh"

echo "=== test-rerun-idempotent ==="
SANDBOX="$(make_sandbox)"

run_setup "$SANDBOX"

# Modify a template — re-run must not clobber
echo "USER CUSTOMIZATION" >> "$SANDBOX/ai-context/templates/session.md"
session_before=$(cat "$SANDBOX/ai-context/templates/session.md")

run_setup "$SANDBOX"

# Templates preserved
session_after=$(cat "$SANDBOX/ai-context/templates/session.md")
assert_eq "templates/session.md preserved on re-run" "$session_before" "$session_after"

# Stop array still has exactly 2 inner hooks (no duplicates)
stop_inner=$(HOME="$SANDBOX" jq -r '.hooks.Stop[0].hooks | length' "$SANDBOX/.claude/settings.json")
assert_eq "Stop hooks not duplicated" "2" "$stop_inner"

# SessionStart still has exactly 1
sess_inner=$(HOME="$SANDBOX" jq -r '.hooks.SessionStart[0].hooks | length' "$SANDBOX/.claude/settings.json")
assert_eq "SessionStart hooks not duplicated" "1" "$sess_inner"

# Alias not duplicated
alias_count=$(grep -c "^alias cc=" "$SANDBOX/.zshrc" || true)
assert_eq "alias still single" "1" "$alias_count"

finish
