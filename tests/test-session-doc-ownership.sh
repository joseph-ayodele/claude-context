#!/usr/bin/env bash
# Verifies session docs are tracked per session, not per date: a doc another
# session wrote today must not satisfy this session, and a read of it must not
# count as this session's write.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-session-doc-ownership ==="
SANDBOX="$(make_sandbox)"
run_setup "$SANDBOX"

TASKS="$SANDBOX/ai-context/sessions/tasks"
TODAY="$(date +%Y-%m-%d)"
HOOKS="$SANDBOX/.claude/hooks"
START_HOOK="$HOOKS/claude-context-check.sh"
UPS_HOOK="$HOOKS/claude-context-session-doc-check.sh"
STALE_HOOK="$HOOKS/claude-context-session-doc-staleness.sh"

OTHER_DOC="$TASKS/other-task/${TODAY}_other.md"
MINE_DOC="$TASKS/parent/child/${TODAY}_mine.md"
mkdir -p "$(dirname "$OTHER_DOC")" "$(dirname "$MINE_DOC")"
echo other > "$OTHER_DOC"
echo mine > "$MINE_DOC"

tool_use() {
  jq -cn --arg n "$1" --arg k "$2" --arg v "$3" \
    '{type:"assistant",message:{content:[{type:"tool_use",name:$n,input:{($k):$v}}]}}'
}
busy_work() { for i in 1 2 3; do tool_use Bash command "ls $i"; done; }
hook_input() {
  jq -cn --arg tp "$1" --arg ev "$2" '{session_id:"sess-own",transcript_path:$tp,hook_event_name:$ev}'
}
context_of() { jq -r '.hookSpecificOutput.additionalContext // ""'; }

T_NONE="$SANDBOX/none.jsonl"
T_READ="$SANDBOX/read.jsonl"
T_WRITE="$SANDBOX/write.jsonl"
T_BASH="$SANDBOX/bash.jsonl"
T_SHORT="$SANDBOX/short.jsonl"
busy_work > "$T_NONE"
{ busy_work; tool_use Bash command "sed -n 1,5p $OTHER_DOC 2>/dev/null"; } > "$T_READ"
{ busy_work; tool_use Write file_path "$MINE_DOC"; } > "$T_WRITE"
{ busy_work; tool_use Bash command "cat >> sessions/tasks/parent/child/${TODAY}_mine.md <<'X'"; } > "$T_BASH"
tool_use Bash command "ls" > "$T_SHORT"

# SessionStart, fresh: no placeholder, lists the other session's docs as candidates.
start_ctx=$(HOME="$SANDBOX" bash "$START_HOOK" <<<"$(hook_input "" SessionStart)" | context_of)
assert_no_file "SessionStart creates no placeholder" "$TASKS/_inbox/${TODAY}_session_pending.md"
assert_contains "fresh session told it has no doc" "this session has none yet" "$start_ctx"
assert_contains "other session's doc listed as candidate" "$OTHER_DOC" "$start_ctx"

# SessionStart, resumed after writing a doc: names it and leaves it out of the candidates.
resume_ctx=$(HOME="$SANDBOX" bash "$START_HOOK" <<<"$(hook_input "$T_WRITE" SessionStart)" | context_of)
assert_contains "resumed session told its own doc" "THIS SESSION'S DOC: $MINE_DOC" "$resume_ctx"
others_section="${resume_ctx#*Docs other sessions wrote today}"
assert_not_contains "own doc not listed among others" "$MINE_DOC" "$others_section"

# UserPromptSubmit.
ups() { HOME="$SANDBOX" bash "$UPS_HOOK" <<<"$(hook_input "$1" UserPromptSubmit)"; }
nudge_none=$(ups "$T_NONE")
assert_contains "nudged when only another session wrote a doc" "SESSION DOC MISSING" "$(context_of <<<"$nudge_none")"
assert_eq "nudge never blocks" "" "$(jq -r '.decision // ""' <<<"$nudge_none")"
assert_contains "reading another session's doc does not count" "SESSION DOC MISSING" "$(ups "$T_READ" | context_of)"
assert_eq "silent after a Write to own doc" "" "$(ups "$T_WRITE")"
assert_eq "silent after a Bash append into a nested task folder" "" "$(ups "$T_BASH")"
assert_eq "silent before the session has done real work" "" "$(ups "$T_SHORT")"
assert_no_file "UserPromptSubmit creates no placeholder" "$TASKS/_inbox/${TODAY}_session_pending.md"

# Staleness tracks this session's doc even when another session's doc is newer.
touch -t 202001010000 "$MINE_DOC"
touch "$OTHER_DOC"
MARKER="$SANDBOX/.claude/claude-context-stale-marker-sess-own"
HOME="$SANDBOX" CLAUDE_CONTEXT_IDLE_SECONDS=60 bash "$STALE_HOOK" <<<"$(hook_input "$T_WRITE" Stop)"
assert_file "idle marker written for own doc" "$MARKER"
assert_eq "marker names own doc, not the newer one" "$MINE_DOC" "$(jq -r '.session_doc' "$MARKER")"
rm -f "$MARKER"
HOME="$SANDBOX" CLAUDE_CONTEXT_IDLE_SECONDS=60 bash "$STALE_HOOK" <<<"$(hook_input "$T_NONE" Stop)"
assert_no_file "no marker when this session owns no doc" "$MARKER"

finish
