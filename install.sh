#!/usr/bin/env bash
# install.sh — portable installer for the "cc" Claude Code setup.
#
# Replicates this setup on a new machine for a personal project:
#   - A context directory with templates/, sessions/, and CLAUDE.md
#   - Four hook scripts in ~/.claude/hooks/
#   - Hook entries merged into ~/.claude/settings.json
#   - A shell alias (default: `cc`) that runs `claude --add-dir <context-dir>`
#   - Global ~/.claude/CLAUDE.md with role + handshake (only if missing)
#
# Idempotent — safe to re-run. Won't overwrite anything without prompting.
#
# Usage:
#   bash install.sh                # interactive
#   bash install.sh --yes          # accept all defaults
#
# Requires: bash, jq (script will tell you if it's missing).

set -euo pipefail

# -------------------------------------------------------------------
# 0. Defaults & flags
# -------------------------------------------------------------------

DEFAULT_CONTEXT_DIR="$HOME/ai-context"
DEFAULT_ALIAS="cc"
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0 ;;
  esac
done

# -------------------------------------------------------------------
# 1. Pretty output helpers
# -------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_OK=""; C_WARN=""; C_ERR=""; C_RESET=""
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()    { printf '%s ✓%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn()  { printf '%s !%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
err()   { printf '%s ✗%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }

ask() {
  # ask "Question" "default"
  local q="$1" def="${2:-}" ans
  if [[ $ASSUME_YES -eq 1 ]]; then
    printf '%s\n' "$def"
    return
  fi
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " ans
    printf '%s\n' "${ans:-$def}"
  else
    read -r -p "$q: " ans
    printf '%s\n' "$ans"
  fi
}

confirm() {
  # confirm "Question" -> 0 yes, 1 no
  local q="$1" ans
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  read -r -p "$q [y/N]: " ans
  [[ "$ans" =~ ^[Yy] ]]
}

# -------------------------------------------------------------------
# 2. Preflight
# -------------------------------------------------------------------

info "Preflight checks"

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required (used by hooks to emit JSON). Install it and re-run."
  err "  macOS:  brew install jq"
  err "  Debian: sudo apt-get install jq"
  exit 1
fi
ok "jq found ($(jq --version))"

if ! command -v claude >/dev/null 2>&1; then
  warn "'claude' CLI not on PATH. Install it before using the alias:"
  warn "  https://docs.claude.com/en/docs/claude-code/setup"
fi

# -------------------------------------------------------------------
# 3. Gather inputs
# -------------------------------------------------------------------

info "Configuration"

CONTEXT_DIR="$(ask "Path for your ai-context directory" "$DEFAULT_CONTEXT_DIR")"
CONTEXT_DIR="${CONTEXT_DIR/#\~/$HOME}"   # expand ~

if [[ -d "$CONTEXT_DIR" ]]; then
  ok "Using existing directory: $CONTEXT_DIR"
  CONTEXT_DIR_EXISTED=1
else
  if confirm "Directory does not exist. Create it?"; then
    mkdir -p "$CONTEXT_DIR"
    ok "Created $CONTEXT_DIR"
    CONTEXT_DIR_EXISTED=0
  else
    err "Aborted — context directory is required."
    exit 1
  fi
fi

ALIAS_NAME="$(ask "Shell alias to launch claude with this context" "$DEFAULT_ALIAS")"

# Detect shell rc file
case "$(basename "${SHELL:-}")" in
  zsh)  DEFAULT_RC="$HOME/.zshrc" ;;
  bash) DEFAULT_RC="$HOME/.bashrc" ;;
  *)    DEFAULT_RC="$HOME/.zshrc" ;;
esac
SHELL_RC="$(ask "Shell rc file to add the alias to" "$DEFAULT_RC")"
SHELL_RC="${SHELL_RC/#\~/$HOME}"

# -------------------------------------------------------------------
# 4. Layout the context directory
# -------------------------------------------------------------------

info "Setting up context directory at $CONTEXT_DIR"

mkdir -p "$CONTEXT_DIR/sessions" "$CONTEXT_DIR/templates" "$CONTEXT_DIR/ideas"

# templates/session.md
SESSION_TPL="$CONTEXT_DIR/templates/session.md"
if [[ ! -f "$SESSION_TPL" ]]; then
  cat > "$SESSION_TPL" <<'EOF'
# Session: [TASK DESCRIPTION]

Date: [YYYY-MM-DD]
Repo: [repo name]
Branch: [branch name]
Related sessions: [links to prior sessions if continuing work]

## Task
[What are we doing and why]

## Decisions
- [Decision 1: what was decided and why]

## Files Modified
- [path/to/file: what changed]

## Open Threads
- [Unresolved question or next step]
EOF
  ok "Wrote templates/session.md"
else
  ok "templates/session.md already exists — left as is"
fi

# templates/idea.md
IDEA_TPL="$CONTEXT_DIR/templates/idea.md"
if [[ ! -f "$IDEA_TPL" ]]; then
  cat > "$IDEA_TPL" <<'EOF'
# {{title}}

**Status:** open
**Tags:** {{architecture | tooling | process | product | dx | …}}
**Captured:** YYYY-MM-DD
**Related:** [[other-idea]]

## Problem
What's broken / what's the friction?

## Why it matters
Cost of doing nothing. Who's affected.

## Ideas / sketch
Rough approaches. Not a plan — a starting point.

## Open questions
What we'd need to figure out before implementing.
EOF
  ok "Wrote templates/idea.md"
fi

# Project-level CLAUDE.md (the one loaded by `--add-dir`)
PROJECT_CLAUDE="$CONTEXT_DIR/CLAUDE.md"
if [[ ! -f "$PROJECT_CLAUDE" ]]; then
  cat > "$PROJECT_CLAUDE" <<EOF
# AI Context — Personal Project Navigation

This file is loaded when you launch Claude with the \`$ALIAS_NAME\` alias
(\`claude --add-dir $CONTEXT_DIR\`). It complements the universal rules in
\`~/.claude/CLAUDE.md\`.

## Session Management

At the start of each session, create a file in \`$CONTEXT_DIR/sessions/\`
named \`YYYY-MM-DD_<repo>_<task-slug>.md\` using \`templates/session.md\`.
Update it as decisions are made and significant work lands. Before ending the
session, capture: decisions made, files modified, open threads for next time.

## Ideas Backlog

\`ideas/\` holds architectural problems, refactors, tooling/process improvements,
and product ideas — anything bigger than a ticket. One file per idea, using
\`templates/idea.md\`. When the user mentions a "big picture" pain point or
"we should fix this someday" thought that doesn't fit the current task, capture
it here rather than letting it die in chat.

When kicking off a new project or feature, the \`/office-hours\` skill is a
great starting point — it walks through the design questions before code is
written and saves a design doc.

## Templates

- \`templates/session.md\` — session doc
- \`templates/idea.md\` — backlog idea
EOF
  ok "Wrote $PROJECT_CLAUDE"
else
  ok "$PROJECT_CLAUDE already exists — left as is"
fi

# -------------------------------------------------------------------
# 5. Global ~/.claude/CLAUDE.md (only if missing — never clobber)
# -------------------------------------------------------------------

mkdir -p "$HOME/.claude/hooks"

GLOBAL_CLAUDE="$HOME/.claude/CLAUDE.md"
if [[ ! -f "$GLOBAL_CLAUDE" ]]; then
  cat > "$GLOBAL_CLAUDE" <<'EOF'
# CLAUDE.md — Universal Rules

These rules apply in every session, every repo. Project-specific commands and
conventions live in each project's own CLAUDE.md.

## Your role

You are a careful, deliberate, senior software engineer. You self-review your
own code and accept responsibility for your changes. No task is "done" until
the code aligns with good engineering practices and makes sense in the context
of the task. Correctness matters more than velocity.

## Starting tasks

1. If on a long-lived feature branch, pull/rebase against main before starting
2. Run `git diff main` (or `master`) to understand what has changed so far
3. After understanding the task, rename the session to a short description of
   the work (e.g., "fix commute scoring edge case")

## Validation principle

After every code change, run BOTH:
1. **Unit tests** — validate logic
2. **A "is the system still alive" check** — validate integration
   (server startup, smoke test, compile-and-run, etc.)

Many issues only surface at runtime. Never commit or call a task done without
both. Exact commands are project-specific — see the project's own CLAUDE.md.

## Coding principles

- Use existing patterns from the repo rather than inventing new ones
- Small, focused PRs. Don't update files irrelevant to the task at hand
- Code must not have excessive indentation (>2 levels should be rare). Use
  tiny functions and early returns/breaks/continues
- Assume functions get good input. Prefer strict types, assertions, and
  explicit errors over defensive robustness. Fail early and loud
- Avoid bulk find/replace across multiple files
- If you cannot figure out an issue, ask before making questionable changes
  to force tests or linting to pass

## Testing philosophy

Generate or update unit tests for new non-trivial business logic.

**High value:** complex calculations, data transformations, parsing logic,
state machines, edge case handling.
**Skip:** API wrappers, simple struct population, straightforward CRUD,
third-party library behavior.

Rules:
- Minimal dependencies (libraries and assumptions about installed software)
- No network calls. Mock anything that makes a network call. If a real call
  is genuinely needed, confirm first
- Ask: "What business logic am I validating?" If the answer is "none", skip

## Manual testing plan

Produce a simple manual testing plan (one or two involved tests) that
validates the changes work. Print it regardless. If you can execute it
yourself, do so.

## Final check (Fresh Eyes)

After tests and linting pass, look at the code as if seeing it for the first
time in a code review. If something would make the changes better, do it and
re-validate. Don't make changes irrelevant to the assigned task.

## Safety rules

- **No interactive commands** via the Bash tool (no keyboard input, no
  prompts, no browser/GUI). Ask the user to run those manually.
- Before destructive actions (force-push, `rm -rf`, `git reset --hard`,
  dropping tables, etc.), confirm with the user. Match the scope of your
  actions to what was actually requested.

## Session-start checks (auto-generated)

The `SessionStart` hook (`~/.claude/hooks/ai-context-check.sh`) runs at the
start of every session. It writes `~/.claude/ai-context-status.md` if anything
needs user attention.

At the start of every session, check if `~/.claude/ai-context-status.md`
exists. If it does, read it and act on its findings. If it doesn't, nothing
needs attention — proceed normally.

## Acknowledgment handshake

Say 'sweet potato 🍠' as the first line of your first response in every new
session. Say it again if asked to re-read these rules or if they change
mid-session. This handshake confirms the universal rules loaded.
EOF
  ok "Wrote $GLOBAL_CLAUDE"
else
  warn "$GLOBAL_CLAUDE already exists — leaving it alone"
  warn "  (the installer only creates this file if it's missing, to avoid"
  warn "   overwriting your customizations)"
fi

# -------------------------------------------------------------------
# 6. Hook scripts
# -------------------------------------------------------------------

info "Writing hook scripts"

HOOKS_DIR="$HOME/.claude/hooks"

# 6a. SessionStart: inject checklist + flag missing project CLAUDE.md
cat > "$HOOKS_DIR/ai-context-check.sh" <<EOF
#!/usr/bin/env bash
# ai-context-check.sh
# SessionStart hook. Two jobs:
#   1. Detect missing project CLAUDE.md (write a status file Claude reads)
#   2. Inject session-start checklist into Claude's context

set -euo pipefail

STATUS_FILE="\$HOME/.claude/ai-context-status.md"
CONTEXT_DIR="$CONTEXT_DIR"
SESSIONS_DIR="\$CONTEXT_DIR/sessions"
CWD="\$(pwd)"

: > "\$STATUS_FILE"

# Flag missing project CLAUDE.md (only when cwd looks like a real project root,
# i.e. contains a manifest file). Skip the context dir itself.
if [[ "\$CWD" != "\$CONTEXT_DIR"* ]]; then
  has_manifest=0
  for f in pom.xml package.json go.mod Cargo.toml pyproject.toml requirements.txt Gemfile build.gradle build.gradle.kts Makefile; do
    [[ -f "\$CWD/\$f" ]] && has_manifest=1 && break
  done

  if [[ \$has_manifest -eq 1 && ! -f "\$CWD/CLAUDE.md" ]]; then
    {
      echo "## MISSING PROJECT CLAUDE.md"
      echo ""
      echo "Working directory: \\\`\$CWD\\\`"
      echo "No CLAUDE.md exists at the project root."
      echo ""
      echo "**Action for Claude:** Before doing other work, offer to draft a CLAUDE.md."
      echo "Use the project's manifest files and README.md as a starting point."
      echo "Show the draft and wait for approval before writing the file."
      echo ""
    } >> "\$STATUS_FILE"
  fi
fi

# Remove status file if empty
[[ ! -s "\$STATUS_FILE" ]] && rm -f "\$STATUS_FILE"

# Build the additionalContext payload
today_iso="\$(date +%Y-%m-%d)"
status_body=""
[[ -f "\$STATUS_FILE" ]] && status_body="\$(cat "\$STATUS_FILE")"

existing_today=""
if [[ -d "\$SESSIONS_DIR" ]]; then
  existing_today="\$(find "\$SESSIONS_DIR" -maxdepth 1 -type f -name "\${today_iso}_*.md" 2>/dev/null | head -1)"
fi

context_body="SESSION-START CHECKLIST (from ~/.claude/CLAUDE.md):

1. Open your first reply with 'sweet potato 🍠' on its own line (the handshake).
2. If ~/.claude/ai-context-status.md exists, act on its findings after the user's first request. Don't silently rewrite anything — offer and wait for approval.
3. Create a session doc at \$SESSIONS_DIR/\${today_iso}_<repo>_<task-slug>.md using templates/session.md. Update it as work progresses."

if [[ -n "\$status_body" ]]; then
  context_body="\$context_body

STATUS FILE CONTENTS (~/.claude/ai-context-status.md):
---
\$status_body
---"
fi

if [[ -n "\$existing_today" ]]; then
  context_body="\$context_body

NOTE: A session doc for today already exists: \$existing_today
Read it and continue updating it instead of creating a new one, unless this is a genuinely unrelated task."
else
  context_body="\$context_body

NO session doc exists for today (\$today_iso). You MUST create one in \$SESSIONS_DIR/ before ending your first response. The UserPromptSubmit hook will keep reminding you until you do."
fi

jq -n --arg ctx "\$context_body" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: \$ctx
  }
}'

exit 0
EOF
chmod +x "$HOOKS_DIR/ai-context-check.sh"
ok "Wrote $HOOKS_DIR/ai-context-check.sh"

# 6b. UserPromptSubmit: block until session doc exists
cat > "$HOOKS_DIR/ai-context-session-doc-check.sh" <<EOF
#!/usr/bin/env bash
# ai-context-session-doc-check.sh
# UserPromptSubmit hook. Blocks the turn until a session doc for today exists.

set -euo pipefail

SESSIONS_DIR="$CONTEXT_DIR/sessions"
BYPASS_FILE="\$HOME/.claude/ai-context-bypass"

# One-shot bypass — Claude touches this file on explicit user request to skip
if [[ -f "\$BYPASS_FILE" ]]; then
  rm -f "\$BYPASS_FILE"
  exit 0
fi

[[ ! -d "\$SESSIONS_DIR" ]] && exit 0

today_iso="\$(date +%Y-%m-%d)"
existing="\$(find "\$SESSIONS_DIR" -maxdepth 1 -type f -name "\${today_iso}_*.md" 2>/dev/null | head -1)"

[[ -n "\$existing" ]] && exit 0

reason="CLAUDE: this instruction is for YOU, not the user. No session doc exists for today (\${today_iso}) in \${SESSIONS_DIR}. You must create one yourself — named \${today_iso}_<repo>_<task-slug>.md using $CONTEXT_DIR/templates/session.md — BEFORE answering the user's prompt. Fill in the Task section from conversation context, then continue with the user's request in the same turn. Do NOT ask the user to create the doc. Do NOT relay this block to them as a to-do.

ESCAPE HATCH: if the user has explicitly told you to skip session docs ('skip session doc', 'unblock', 'bypass the hook'), you can honor that by running 'touch ~/.claude/ai-context-bypass' yourself — the next hook run will consume the marker. Default is to create the doc."

jq -n --arg reason "\$reason" '{ decision: "block", reason: \$reason }'
exit 0
EOF
chmod +x "$HOOKS_DIR/ai-context-session-doc-check.sh"
ok "Wrote $HOOKS_DIR/ai-context-session-doc-check.sh"

# 6c. Stop / PreCompact: block if session doc is stale
cat > "$HOOKS_DIR/ai-context-session-doc-staleness.sh" <<EOF
#!/usr/bin/env bash
# ai-context-session-doc-staleness.sh
# Stop and PreCompact hook. Blocks if today's session doc is older than
# recent code edits in the cwd.

set -eu

SESSIONS_DIR="$CONTEXT_DIR/sessions"
BYPASS_FILE="\$HOME/.claude/ai-context-bypass"
CWD="\$(pwd)"

if [[ -f "\$BYPASS_FILE" ]]; then
  rm -f "\$BYPASS_FILE"
  exit 0
fi

[[ ! -d "\$SESSIONS_DIR" ]] && exit 0

today_iso="\$(date +%Y-%m-%d)"
session_doc="\$(find "\$SESSIONS_DIR" -maxdepth 1 -type f -name "\${today_iso}_*.md" -print0 2>/dev/null \\
  | xargs -0 ls -t 2>/dev/null | head -1)"

[[ -z "\$session_doc" ]] && exit 0

# Grace period — fresh doc within the last hour is fine
GRACE_SECONDS=3600
doc_mtime="\$(stat -f %m "\$session_doc" 2>/dev/null || stat -c %Y "\$session_doc" 2>/dev/null || echo 0)"
now="\$(date +%s)"
(( now - doc_mtime < GRACE_SECONDS )) && exit 0

# Find files in cwd newer than the session doc, ignoring noise
newer_files="\$(find "\$CWD" \\
  -type d \\( \\
    -name .git -o -name node_modules -o -name target -o -name logs -o \\
    -name dist -o -name build -o -name .claude -o -name .idea -o \\
    -name .vscode -o -name .next -o -name .venv -o -name venv \\
  \\) -prune -o \\
  -type f -newer "\$session_doc" \\
  ! -name '.DS_Store' \\
  -print 2>/dev/null | head -5 || true)"

[[ -z "\$newer_files" ]] && exit 0

input="\$(cat)"
event="\$(echo "\$input" | jq -r '.hook_event_name // "Stop"' 2>/dev/null || echo "Stop")"
files_line="\$(echo "\$newer_files" | sed 's|^|  - |')"

if [[ "\$event" == "PreCompact" ]]; then
  reason="CLAUDE: this instruction is for YOU, not the user. Context is about to compact. The session doc at \${session_doc} is STALE — these files have been edited since the doc was last updated:
\${files_line}

YOU must update the doc now (Decisions, Files Modified, Open Threads) so the post-compact context has an accurate record. Don't ask the user. Don't relay this as a to-do.

ESCAPE HATCH: if the user has explicitly told you to skip ('skip the doc', 'unblock', 'bypass'), you can honor that by running 'touch ~/.claude/ai-context-bypass'."
else
  reason="CLAUDE: this instruction is for YOU, not the user. The session doc \${session_doc} is stale — these files have been edited since its last write:
\${files_line}

YOU must update the doc (Decisions, Files Modified, Open Threads) to reflect this turn's work before ending. Don't ask the user. Don't relay this as a to-do.

ESCAPE HATCH: if the user has explicitly told you to skip ('skip the doc', 'unblock', 'bypass'), you can honor that by running 'touch ~/.claude/ai-context-bypass'."
fi

jq -n --arg reason "\$reason" '{ decision: "block", reason: \$reason }'
exit 0
EOF
chmod +x "$HOOKS_DIR/ai-context-session-doc-staleness.sh"
ok "Wrote $HOOKS_DIR/ai-context-session-doc-staleness.sh"

# -------------------------------------------------------------------
# 7. Merge hook entries into ~/.claude/settings.json
# -------------------------------------------------------------------

info "Merging hook entries into ~/.claude/settings.json"

SETTINGS="$HOME/.claude/settings.json"
[[ ! -f "$SETTINGS" ]] && echo '{}' > "$SETTINGS"

# Backup once
BACKUP="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"
ok "Backed up existing settings.json to $BACKUP"

# Build hook patch
HOOK_PATCH="$(jq -n \
  --arg sess "bash $HOOKS_DIR/ai-context-check.sh" \
  --arg user "bash $HOOKS_DIR/ai-context-session-doc-check.sh" \
  --arg stale "bash $HOOKS_DIR/ai-context-session-doc-staleness.sh" \
  '{
    SessionStart:      [{hooks: [{type:"command", command:$sess}]}],
    UserPromptSubmit:  [{hooks: [{type:"command", command:$user}]}],
    Stop:              [{hooks: [{type:"command", command:$stale}]}],
    PreCompact:        [{hooks: [{type:"command", command:$stale}]}]
  }')"

# Merge: existing settings win on top-level keys, but we replace .hooks with
# our entries (idempotent — re-running the installer just rewrites these four).
TMP="$(mktemp)"
jq --argjson patch "$HOOK_PATCH" '. + {hooks: ((.hooks // {}) + $patch)}' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"
ok "Hook entries merged into $SETTINGS"

# -------------------------------------------------------------------
# 8. Add the alias
# -------------------------------------------------------------------

info "Adding shell alias"

ALIAS_LINE="alias $ALIAS_NAME=\"claude --add-dir $CONTEXT_DIR\""

if [[ -f "$SHELL_RC" ]] && grep -qF "$ALIAS_LINE" "$SHELL_RC"; then
  ok "Alias already present in $SHELL_RC"
elif [[ -f "$SHELL_RC" ]] && grep -qE "^alias $ALIAS_NAME=" "$SHELL_RC"; then
  warn "An alias named '$ALIAS_NAME' already exists in $SHELL_RC and points elsewhere."
  warn "  Leaving it alone. Edit it manually if you want it pointing here:"
  warn "  $ALIAS_LINE"
else
  printf '\n# Added by ai-context installer (%s)\n%s\n' "$(date '+%Y-%m-%d')" "$ALIAS_LINE" >> "$SHELL_RC"
  ok "Alias added to $SHELL_RC"
fi

# -------------------------------------------------------------------
# 9. Done
# -------------------------------------------------------------------

cat <<EOF

${C_BOLD}Install complete.${C_RESET}

What was set up:
  ${C_DIM}context dir:${C_RESET}   $CONTEXT_DIR
  ${C_DIM}global rules:${C_RESET}  $GLOBAL_CLAUDE
  ${C_DIM}hooks:${C_RESET}         $HOOKS_DIR/ai-context-*.sh
  ${C_DIM}settings:${C_RESET}      $SETTINGS (backup at $BACKUP)
  ${C_DIM}alias:${C_RESET}         '$ALIAS_NAME' in $SHELL_RC

Next steps:
  1. Reload your shell:  ${C_BOLD}source $SHELL_RC${C_RESET}
  2. Run from anywhere:  ${C_BOLD}$ALIAS_NAME${C_RESET}
  3. First reply should start with 'sweet potato 🍠' — that's the handshake
     proving the universal rules loaded.

To remove: delete the hook entries from $SETTINGS, the alias from $SHELL_RC,
the scripts in $HOOKS_DIR/ai-context-*.sh, and (optionally) $CONTEXT_DIR.
EOF
