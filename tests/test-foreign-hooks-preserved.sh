#!/usr/bin/env bash
# Verifies foreign hooks (registered by other tools) survive install,
# re-install, and uninstall round-trips. The install merge MUST be surgical
# — filter out our own hooks under each event key, append our new entries,
# but preserve every other inner-hook command unchanged. Symmetric with the
# uninstall filter logic.
#
# Regression guard for the "shallow merge clobbers foreign hooks" bug
# discovered 2026-06-15 in multi-agent installer review.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-foreign-hooks-preserved ==="
SANDBOX="$(make_sandbox)"

# Pre-populate settings.json with hooks from a fictitious other tool. Three
# event keys, one that overlaps with claude-context (Stop) and two that don't
# (SessionEnd is a hypothetical future event we don't use; PreToolUse is real
# but we don't register there).
mkdir -p "$SANDBOX/.claude"
SETTINGS="$SANDBOX/.claude/settings.json"
cat > "$SETTINGS" <<'EOF'
{
  "model": "claude-sonnet-4-5",
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "/usr/bin/afplay /System/Library/Sounds/Glass.aiff", "async": true}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/path/to/some-other-tool/audit.sh"}]}
    ],
    "SessionEnd": [
      {"hooks": [{"type": "command", "command": "bash /opt/another-tool/wrap-up.sh"}]}
    ]
  }
}
EOF

# Step 1: install. Foreign Stop hook should survive AS A SIBLING of our
# claude-context Stop hooks. PreToolUse and SessionEnd should be untouched.
run_setup "$SANDBOX"

# Stop event: must contain BOTH the foreign Glass.aiff hook AND our two
# claude-context hooks.
stop_count=$(jq '[.hooks.Stop[].hooks[]] | length' "$SETTINGS")
if [[ "$stop_count" -ge 3 ]]; then
  _pass "Stop has $stop_count inner hooks (foreign + claude-context)"
else
  _fail "Stop hook count after install" "≥3" "$stop_count"
fi

# Foreign Glass.aiff still present
glass_present=$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("Glass.aiff"))] | length' "$SETTINGS")
assert_eq "foreign Glass.aiff Stop hook preserved on install" "1" "$glass_present"

# Our staleness hook present
ours_present=$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("claude-context-session-doc-staleness"))] | length' "$SETTINGS")
assert_eq "our staleness hook present" "1" "$ours_present"

# PreToolUse foreign hook untouched
pretool_count=$(jq '[.hooks.PreToolUse[].hooks[]] | length' "$SETTINGS")
assert_eq "PreToolUse foreign hook preserved" "1" "$pretool_count"

# SessionEnd foreign hook untouched
sessionend_count=$(jq '[.hooks.SessionEnd[].hooks[]] | length' "$SETTINGS")
assert_eq "SessionEnd foreign hook preserved" "1" "$sessionend_count"

# Step 2: re-install. Should be idempotent — foreign hooks remain, our hooks
# don't duplicate.
run_setup "$SANDBOX"

stop_count_after_rerun=$(jq '[.hooks.Stop[].hooks[]] | length' "$SETTINGS")
assert_eq "Stop count unchanged after re-install (no duplication)" "$stop_count" "$stop_count_after_rerun"

glass_after_rerun=$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("Glass.aiff"))] | length' "$SETTINGS")
assert_eq "Glass.aiff still present after re-install" "1" "$glass_after_rerun"

# Step 3: uninstall. Foreign hooks should remain; ours should be gone.
SHELL=/bin/zsh HOME="$SANDBOX" bash "$REPO_ROOT/setup.sh" --yes --skip-gbrain --uninstall >/dev/null 2>&1

# Glass.aiff foreign hook still present after uninstall
glass_after_uninstall=$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("Glass.aiff"))] | length' "$SETTINGS")
assert_eq "Glass.aiff foreign hook preserved through uninstall" "1" "$glass_after_uninstall"

# PreToolUse foreign hook still present after uninstall
pretool_after_uninstall=$(jq '[.hooks.PreToolUse[]?.hooks[]?] | length' "$SETTINGS")
assert_eq "PreToolUse foreign hook preserved through uninstall" "1" "$pretool_after_uninstall"

# SessionEnd foreign hook still present after uninstall
sessionend_after_uninstall=$(jq '[.hooks.SessionEnd[]?.hooks[]?] | length' "$SETTINGS")
assert_eq "SessionEnd foreign hook preserved through uninstall" "1" "$sessionend_after_uninstall"

# Our claude-context hooks are gone
ours_after_uninstall=$(jq '[.. | objects | select(has("command")) | .command | select(contains("claude-context-"))] | length' "$SETTINGS")
assert_eq "claude-context hooks removed by uninstall" "0" "$ours_after_uninstall"

finish
