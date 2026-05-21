#!/usr/bin/env bash
# Fresh install on an empty HOME. Verifies the happy path:
#   - context dir + templates created
#   - 4 hooks written + executable
#   - settings.json has SessionStart/UserPromptSubmit/Stop/PreCompact
#   - alias added to ~/.zshrc
#   - global ~/.claude/CLAUDE.md written

source "$(dirname "$0")/lib.sh"

echo "=== test-fresh-install ==="
SANDBOX="$(make_sandbox)"

run_setup "$SANDBOX"

# Context dir layout
assert_file "context dir created"        "$SANDBOX/ai-context/CLAUDE.md"
assert_file "templates/session.md"       "$SANDBOX/ai-context/templates/session.md"
assert_file "templates/idea.md"          "$SANDBOX/ai-context/templates/idea.md"
[[ -d "$SANDBOX/ai-context/sessions" ]] && _pass "sessions/ dir" || _fail "sessions/ dir" "exists" "missing"
[[ -d "$SANDBOX/ai-context/ideas" ]] && _pass "ideas/ dir" || _fail "ideas/ dir" "exists" "missing"

# Hooks
for hook in ai-context-check ai-context-session-doc-check ai-context-session-doc-staleness ai-context-gbrain-sync; do
  assert_file "hook: $hook"              "$SANDBOX/.claude/hooks/$hook.sh"
  [[ -x "$SANDBOX/.claude/hooks/$hook.sh" ]] && _pass "hook executable: $hook" || _fail "hook executable: $hook" "yes" "no"
done

# settings.json hook keys
keys=$(HOME="$SANDBOX" jq -r '.hooks | keys | sort | join(",")' "$SANDBOX/.claude/settings.json")
assert_eq "settings hook keys" "PreCompact,SessionStart,Stop,UserPromptSubmit" "$keys"

stop_inner=$(HOME="$SANDBOX" jq -r '.hooks.Stop[0].hooks | length' "$SANDBOX/.claude/settings.json")
assert_eq "Stop has 2 inner hooks (staleness + gbrain)" "2" "$stop_inner"

# Alias
assert_file "shell rc"                   "$SANDBOX/.zshrc"
alias_count=$(grep -c "^alias cc=" "$SANDBOX/.zshrc" || true)
assert_eq "alias added once" "1" "$alias_count"

# Global CLAUDE.md
assert_file "global CLAUDE.md"           "$SANDBOX/.claude/CLAUDE.md"
content="$(cat "$SANDBOX/.claude/CLAUDE.md")"
assert_contains "global has handshake" "sweet potato" "$content"

# SessionStart hook produces valid JSON with the checklist
hook_out=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/ai-context-check.sh" </dev/null)
ctx=$(echo "$hook_out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "SessionStart injects sweet potato" "sweet potato" "$ctx"
assert_contains "SessionStart names sessions dir" "$SANDBOX/ai-context/sessions" "$ctx"

finish
