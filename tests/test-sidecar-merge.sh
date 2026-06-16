#!/usr/bin/env bash
# When CLAUDE.md files already exist with custom content, setup must:
#   - leave the existing files untouched
#   - write its proposed content to .claude-context-proposed sidecars
#   - have the SessionStart hook surface a merge prompt naming both sidecars

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-sidecar-merge ==="
SANDBOX="$(make_sandbox)"

# Pre-populate both CLAUDE.md files with custom content
mkdir -p "$SANDBOX/.claude" "$SANDBOX/ai-context"
custom_proj="# My pre-existing nav

Custom user nav content."
custom_global="# My pre-existing global rules

Always speak like a pirate."
echo "$custom_proj" > "$SANDBOX/ai-context/CLAUDE.md"
echo "$custom_global" > "$SANDBOX/.claude/CLAUDE.md"

run_setup "$SANDBOX"

# Existing files untouched
assert_eq "project CLAUDE.md preserved" "$custom_proj" "$(cat "$SANDBOX/ai-context/CLAUDE.md")"
assert_eq "global CLAUDE.md preserved"  "$custom_global" "$(cat "$SANDBOX/.claude/CLAUDE.md")"

# Sidecars created
assert_file "project sidecar"           "$SANDBOX/ai-context/CLAUDE.md.claude-context-proposed"
assert_file "global sidecar"            "$SANDBOX/.claude/CLAUDE.md.claude-context-proposed"

# SessionStart hook surfaces both sidecars in additionalContext
ctx=$(HOME="$SANDBOX" bash "$SANDBOX/.claude/hooks/claude-context-check.sh" </dev/null \
  | jq -r '.hookSpecificOutput.additionalContext')

assert_contains "hook mentions PENDING MERGE"             "PENDING MERGE" "$ctx"
assert_contains "hook references project sidecar path"    "ai-context/CLAUDE.md.claude-context-proposed" "$ctx"
assert_contains "hook references global sidecar path"     ".claude/CLAUDE.md.claude-context-proposed" "$ctx"
assert_contains "hook tells Claude to read both files"    "Read both" "$ctx"

# Re-running setup is safe: the user's existing files stay untouched.
# (We don't compare sidecar mtimes — setup may legitimately re-write the
# sidecar if the proposed content drifts between runs.)
run_setup "$SANDBOX"
assert_eq "project CLAUDE.md still preserved on re-run" "$custom_proj" "$(cat "$SANDBOX/ai-context/CLAUDE.md")"

finish
