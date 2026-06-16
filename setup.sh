#!/usr/bin/env bash
# setup.sh — portable setup for the "cc" Claude Code workflow.
#
# Replicates this setup on a new machine for a personal project:
#   - A context directory with templates/, sessions/, ideas/, and CLAUDE.md
#   - Four hook scripts in ~/.claude/hooks/ (SessionStart checklist,
#     UserPromptSubmit session-doc gate, Stop+PreCompact staleness check,
#     Stop gbrain ingest bridge)
#   - Hook entries merged into ~/.claude/settings.json
#   - A shell alias (default: `cc`) that runs `claude --add-dir <context-dir>`
#   - Global ~/.claude/CLAUDE.md with role + handshake (only if missing)
#   - Optional gbrain integration: if gbrain CLI is installed and initialized,
#     session docs flow into it as pages (best-effort; gracefully skipped if
#     gbrain is missing).
#
# Idempotent — safe to re-run. Won't overwrite anything without prompting.
#
# Usage:
#   bash setup.sh                  # interactive
#   bash setup.sh --yes            # accept all defaults
#   bash setup.sh --skip-gbrain    # don't prompt about gbrain at all
#   bash setup.sh --uninstall      # reverse the install (asks before deleting user data)
#
# Requires: bash, jq (script will tell you if it's missing).

set -euo pipefail

# -------------------------------------------------------------------
# 0. Defaults & flags
# -------------------------------------------------------------------

DEFAULT_CONTEXT_DIR="$HOME/ai-context"
DEFAULT_ALIAS="cc"
ASSUME_YES=0
SKIP_GBRAIN=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --skip-gbrain) SKIP_GBRAIN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,23p' "$0"
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

# write_or_sidecar TARGET TMPFILE
#
# If TARGET doesn't exist: move TMPFILE into place.
# If TARGET exists and is identical to TMPFILE: drop TMPFILE silently (no-op).
# If TARGET exists and differs: move TMPFILE to TARGET.ai-context-proposed
#   so the SessionStart hook can surface a merge prompt to Claude.
#
# This is how "smart integration with existing context" lands without setup
# itself making LLM calls — claude does the merge in-conversation when the
# user runs the alias for the first time after setup.
write_or_sidecar() {
  local target="$1" tmp="$2"
  if [[ ! -f "$target" ]]; then
    mv "$tmp" "$target"
    ok "Wrote $target"
  elif cmp -s "$target" "$tmp"; then
    rm -f "$tmp"
    ok "$target already up to date — left as is"
  else
    local sidecar="$target.ai-context-proposed"
    mv "$tmp" "$sidecar"
    warn "$target already exists with different content"
    say  "  Wrote proposed version to $sidecar"
    say  "  Run '$ALIAS_NAME' once after setup — Claude will offer to merge."
  fi
}

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
# 2.5. Uninstall mode (handled here, before any setup work)
# -------------------------------------------------------------------

if [[ $UNINSTALL -eq 1 ]]; then
  info "Uninstall mode"

  HOOKS_DIR="$HOME/.claude/hooks"
  SETTINGS="$HOME/.claude/settings.json"

  # Remove our four hook entries from settings.json. Top-level keys we own:
  # SessionStart, UserPromptSubmit, Stop, PreCompact. We DON'T blindly delete
  # those keys (other tools may have hooks there) — instead we filter out
  # any inner hooks whose `command` starts with one of our hook script paths.
  if [[ -f "$SETTINGS" ]]; then
    BACKUP="$SETTINGS.bak.$(date +%s)"
    cp "$SETTINGS" "$BACKUP"
    TMP="$(mktemp)"
    jq --arg prefix "bash $HOOKS_DIR/ai-context-" '
      if .hooks then
        .hooks |= with_entries(
          .value |= map(
            .hooks |= map(select(.command | startswith($prefix) | not))
          ) | .value |= map(select(.hooks | length > 0))
        ) | .hooks |= with_entries(select(.value | length > 0))
      else . end
    ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
    ok "Removed ai-context hook entries from $SETTINGS (backup at $BACKUP)"
  fi

  # Remove the hook scripts
  if [[ -d "$HOOKS_DIR" ]]; then
    rm -f "$HOOKS_DIR"/ai-context-*.sh
    ok "Removed hook scripts from $HOOKS_DIR"
  fi

  # Remove our state dir (gbrain-last-run, gbrain-errors.log, etc.)
  if [[ -d "$HOME/.claude/ai-context-state" ]]; then
    rm -rf "$HOME/.claude/ai-context-state"
    ok "Removed $HOME/.claude/ai-context-state"
  fi

  # Remove the alias from common rc files. We match the marker comment we
  # wrote during install so we don't touch user-edited aliases.
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc" ]] || continue
    if grep -q "Added by ai-context installer" "$rc"; then
      TMP_RC="$(mktemp)"
      # Drop the marker comment line and the alias line that follows it.
      awk '
        /# Added by ai-context installer/ { skip = 2; next }
        skip > 0 { skip--; next }
        { print }
      ' "$rc" > "$TMP_RC" && mv "$TMP_RC" "$rc"
      ok "Removed alias from $rc"
    fi
  done

  # User data — confirm before deletion. Two prompts: context dir, global CLAUDE.md.
  for context_candidate in "$DEFAULT_CONTEXT_DIR" "$HOME/.config/ai-context"; do
    if [[ -d "$context_candidate" ]]; then
      if confirm "Delete context dir $context_candidate (contains your session docs and ideas)?"; then
        rm -rf "$context_candidate"
        ok "Removed $context_candidate"
      else
        say "  Kept $context_candidate"
      fi
      break
    fi
  done

  if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    if confirm "Delete global $HOME/.claude/CLAUDE.md (may contain your customizations)?"; then
      rm -f "$HOME/.claude/CLAUDE.md"
      ok "Removed $HOME/.claude/CLAUDE.md"
    else
      say "  Kept $HOME/.claude/CLAUDE.md"
    fi
  fi

  # Sidecars — clean up if any are still pending
  rm -f "$HOME/.claude/CLAUDE.md.ai-context-proposed" 2>/dev/null
  rm -f "$DEFAULT_CONTEXT_DIR/CLAUDE.md.ai-context-proposed" 2>/dev/null

  printf '\n%sUninstall complete.%s\n' "$C_BOLD" "$C_RESET"
  exit 0
fi

# -------------------------------------------------------------------
# 3. Gather inputs
# -------------------------------------------------------------------

info "Configuration"

CONTEXT_DIR="$(ask "Path for your ai-context directory" "$DEFAULT_CONTEXT_DIR")"
CONTEXT_DIR="${CONTEXT_DIR/#\~/$HOME}"   # expand ~

if [[ -d "$CONTEXT_DIR" ]]; then
  ok "Using existing directory: $CONTEXT_DIR"
elif confirm "Directory does not exist. Create it?"; then
  mkdir -p "$CONTEXT_DIR"
  ok "Created $CONTEXT_DIR"
else
  err "Aborted — context directory is required."
  exit 1
fi

ALIAS_NAME="$(ask "Shell alias to launch claude with this context" "$DEFAULT_ALIAS")"

# Detect shell rc file. Only zsh/bash get a usable default in --yes mode —
# fish/nushell/etc. use different syntax and write to different files, so we
# refuse --yes there and force the user to specify the path interactively.
SHELL_BASENAME="$(basename "${SHELL:-}")"
case "$SHELL_BASENAME" in
  zsh)  DEFAULT_RC="$HOME/.zshrc" ;;
  bash) DEFAULT_RC="$HOME/.bashrc" ;;
  *)
    if [[ $ASSUME_YES -eq 1 ]]; then
      err "Detected shell '$SHELL_BASENAME' is not zsh or bash."
      err "  --yes mode would write a zsh-syntax alias to ~/.zshrc, which"
      err "  '$SHELL_BASENAME' won't read. Re-run interactively to choose"
      err "  the right rc file (e.g. ~/.config/fish/config.fish for fish),"
      err "  or pre-set SHELL=/bin/zsh if you want zsh defaults."
      exit 1
    fi
    DEFAULT_RC="$HOME/.zshrc"
    ;;
esac
SHELL_RC="$(ask "Shell rc file to add the alias to" "$DEFAULT_RC")"
SHELL_RC="${SHELL_RC/#\~/$HOME}"

# -------------------------------------------------------------------
# 4. Layout the context directory
# -------------------------------------------------------------------

info "Setting up context directory at $CONTEXT_DIR"

mkdir -p "$CONTEXT_DIR/sessions" "$CONTEXT_DIR/sessions/tasks" "$CONTEXT_DIR/sessions/tasks/_inbox" "$CONTEXT_DIR/sessions/tasks/_misc" "$CONTEXT_DIR/templates" "$CONTEXT_DIR/ideas"

# templates/session.md — task-folder shape, with Where we are + Graduated
SESSION_TPL="$CONTEXT_DIR/templates/session.md"
if [[ ! -f "$SESSION_TPL" ]]; then
  cat > "$SESSION_TPL" <<'EOF'
# Session: [TASK DESCRIPTION]

## Where we are

[State at session start — what was done previously on this task, what's open. If continuing, paste from the prior session's Open Threads + add any morning context. If new task, the session's first goal.]

## Decisions

- [Decision 1: what was decided and why]

## Files Modified

- [path/to/file: what changed]

## Graduated

[Filled in at session end via the graduate flow. One line per item that flowed into the knowledge core. Format: `- <target-file>: <one-sentence what landed>`. Leave empty if nothing graduated.]

## Open Threads

- [Unresolved question or next step]
EOF
  ok "Wrote templates/session.md"
else
  ok "templates/session.md already exists — left as is"
fi

# templates/task-index.md — INDEX.md template for task folders
TASK_INDEX_TPL="$CONTEXT_DIR/templates/task-index.md"
if [[ ! -f "$TASK_INDEX_TPL" ]]; then
  cat > "$TASK_INDEX_TPL" <<'EOF'
# Task: [HUMAN-READABLE TITLE]

Slug: [slug-matching-folder-name]
Started: [YYYY-MM-DD]
Status: active
JIRA: [IED-XXXXX or "(none)"]

## Sessions

- [YYYY-MM-DD_note.md] — [one-line recap]

<!--
INDEX.md is a session listing for this task folder.
- Append a line under "## Sessions" each time a new dated session file is created.
- Status values: active | paused | done.
- Done tasks stay in place — no archival.
- INDEX.md does NOT duplicate the graduated list. Each session file's
  `## Graduated` section is the source of truth for what flowed into the
  knowledge core.
-->
EOF
  ok "Wrote templates/task-index.md"
else
  ok "templates/task-index.md already exists — left as is"
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

# Project-level CLAUDE.md (the one loaded by `--add-dir`).
# Use write_or_sidecar so an existing customized CLAUDE.md gets merged in a
# subsequent cc session instead of silently skipped.
PROJECT_CLAUDE="$CONTEXT_DIR/CLAUDE.md"
PROJECT_CLAUDE_TMP="$(mktemp)"
cat > "$PROJECT_CLAUDE_TMP" <<EOF
# AI Context — Personal Project Navigation

This file is loaded when you launch Claude with the \`$ALIAS_NAME\` alias
(\`claude --add-dir $CONTEXT_DIR\`). It complements the universal rules in
\`~/.claude/CLAUDE.md\`.

## Session Management — task-folder shape

Sessions are organized by **task**, not by date. Each session doc lives at
\`$CONTEXT_DIR/sessions/tasks/<task-slug>/<YYYY-MM-DD>_<note>.md\` and uses
\`templates/session.md\`. Each task folder has an \`INDEX.md\` matching
\`templates/task-index.md\` (slug, started date, \`Status: active|paused|done\`,
and a list of session files).

**Slug rules:**
- Human-readable, kebab-case (\`auth-bug-fix\`, \`docs-refresh\`, \`migrate-to-postgres\`).
- Must be unique within \`sessions/tasks/\`. On collision, append \`-2\`, \`-3\`, etc.
- If the task tracks an external ticket, the ticket key may appear as a suffix (\`auth-bug-fix-acme-123\`), never a prefix.

**Continuing vs. starting:**
- The SessionStart hook surfaces active task slugs. After the user's first message, decide if it's continuing one of those tasks (matches a slug, references the same ticket, talks about the same artifact). If yes, drop the new file under that slug's folder and read the most recent session file there before responding. If new and the slug is clear, confirm once before creating the folder. If unclear, drop into \`sessions/tasks/_inbox/<YYYY-MM-DD>_<temporary-slug>.md\` and \`mv\` later when the slug crystallizes.

**File-creation rule:**
- Default: one new dated file per day per task folder. Within the same day, append to the existing file rather than create a second.

**INDEX.md per task folder** is a session listing — append a one-liner under \`## Sessions\` whenever a new dated session file is created. INDEX.md does NOT duplicate what graduated; that lives in each session file's \`## Graduated\` section.

**Miscellaneous work — \`_misc/\` daily log:** for one-off work that won't ever become a task (Slack pings, quick CLI checks, ad-hoc PR reviews), append to \`sessions/tasks/_misc/<YYYY-MM-DD>_misc.md\`. One file per day, multiple short entries (\`## heading\` + 1-3 lines each). No INDEX.md, no folder-per-entry. The \`_misc\` filename suffix is required so hooks find it via the \`<date>_*.md\` glob. Use \`_inbox/\` instead for exploratory work that might become a real task — \`_misc\` is for things that resolve same-session.

Update each session doc as decisions are made and significant work lands. Before ending the session, fill: decisions, files modified, what graduated to the knowledge core, open threads for next time.

## Session-end graduate flow

Sessions feed; the knowledge core (\`repos/*.md\`, \`Notes/*.md\`, \`ideas/*.md\`, \`MEMORY.md\`) is the destination. The graduate flow is where compounding happens — without it, sessions are write-only and the knowledge core stagnates.

**Trigger:** ONE of these explicit cues from the user — "we're done", "wrap this up", "wrap up", "/graduate". Do NOT trigger on ambient "great" / "thanks" / "that's it" / "let's stop".

**Heuristic — only propose graduation if the session contains at least one of:**
- (a) a surprise / mistake / root-cause discovery
- (b) a command sequence the user is likely to need again
- (c) a fact about an environment / repo / system not currently documented (verify via grep)
- (d) a "we should fix this someday" idea bigger than the current task
- (e) a clarification of how the user wants Claude to work going forward

**Hard cap:** maximum 4 candidates per prompt. If more pass, model self-selects by confidence; the rest go to \`sessions/tasks/<slug>/_overflow-graduates.md\`.

**Anti-noise rule:** if zero candidates pass the heuristic, skip the prompt entirely.

**Intensity dial:** track consecutive zero-approval sessions in \`~/.claude/.graduate-decline-streak\`. Streak 0–2: full prompt. Streak 3+: terse one-liner ("0 candidates today — say /graduate full if I missed something"). Never goes silent. Reset to 0 on first approval.

**Apply phase:** for each approved item, edit the named knowledge-core file. After all edits, fill the session file's \`## Graduated\` section with one line per approved item.

## Ideas Backlog

\`ideas/\` holds architectural problems, refactors, tooling/process improvements,
and product ideas — anything bigger than a ticket. One file per idea, using
\`templates/idea.md\`. When the user mentions a "big picture" pain point or
"we should fix this someday" thought that doesn't fit the current task, capture
it here rather than letting it die in chat.

When kicking off a new project or feature, the \`/office-hours\` skill is a
great starting point — it walks through the design questions before code is
written and saves a design doc.

## Retrieval (optional)

If \`gbrain\` is installed and initialized, every session doc you save is
automatically ingested as a page on Stop. Search across all your sessions:

  \`\`\`
  gbrain search "<phrase>"
  \`\`\`

If gbrain isn't installed, the rest of this setup works fine — you just
won't have cross-session retrieval.

## Templates

- \`templates/session.md\` — session doc (task-folder shape)
- \`templates/task-index.md\` — INDEX.md template for task folders
- \`templates/idea.md\` — backlog idea
EOF
write_or_sidecar "$PROJECT_CLAUDE" "$PROJECT_CLAUDE_TMP"

# -------------------------------------------------------------------
# 5. Global ~/.claude/CLAUDE.md (only if missing — never clobber)
# -------------------------------------------------------------------

mkdir -p "$HOME/.claude/hooks"

GLOBAL_CLAUDE="$HOME/.claude/CLAUDE.md"
GLOBAL_CLAUDE_TMP="$(mktemp)"
cat > "$GLOBAL_CLAUDE_TMP" <<'EOF'
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
write_or_sidecar "$GLOBAL_CLAUDE" "$GLOBAL_CLAUDE_TMP"

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
TASKS_DIR="\$SESSIONS_DIR/tasks"
INBOX_DIR="\$TASKS_DIR/_inbox"
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

# Detect .ai-context-proposed sidecars left by setup when CLAUDE.md files
# already existed. If any are found, ask Claude (in-conversation) to merge
# them with the existing files. Setup never touches existing files itself —
# this is the seam where claude does the merge.
sidecars=""
for candidate in "\$CONTEXT_DIR/CLAUDE.md.ai-context-proposed" "\$HOME/.claude/CLAUDE.md.ai-context-proposed"; do
  [[ -f "\$candidate" ]] && sidecars="\${sidecars}\${candidate}\\n"
done

# Remove status file if empty
[[ ! -s "\$STATUS_FILE" ]] && rm -f "\$STATUS_FILE"

# Build the additionalContext payload
today_iso="\$(date +%Y-%m-%d)"
status_body=""
[[ -f "\$STATUS_FILE" ]] && status_body="\$(cat "\$STATUS_FILE")"

existing_today=""
placeholder_created=""
if [[ -d "\$SESSIONS_DIR" ]]; then
  # New shape: sessions/tasks/<slug>/<date>_<note>.md
  if [[ -d "\$TASKS_DIR" ]]; then
    existing_today="\$(find "\$TASKS_DIR" -mindepth 2 -type f -name "\${today_iso}_*.md" 2>/dev/null | head -1)"
  fi

  # Legacy fallback: sessions/<date>_*.md
  if [[ -z "\$existing_today" ]]; then
    existing_today="\$(find "\$SESSIONS_DIR" -maxdepth 1 -type f -name "\${today_iso}_*.md" 2>/dev/null | head -1)"
  fi

  # If still no doc for today, write a placeholder under _inbox so the
  # UserPromptSubmit gate is satisfied. Claude moves it to a proper task
  # folder on its first substantive turn.
  if [[ -z "\$existing_today" ]]; then
    mkdir -p "\$INBOX_DIR" 2>/dev/null || true
    placeholder_path="\$INBOX_DIR/\${today_iso}_session_pending.md"
    template_path="$CONTEXT_DIR/templates/session.md"
    if [[ -f "\$template_path" && ! -e "\$placeholder_path" ]]; then
      cp "\$template_path" "\$placeholder_path"
      placeholder_created="\$placeholder_path"
      existing_today="\$placeholder_path"
    fi
  fi
fi

# List active task folders (Status: active in INDEX.md)
if [[ -d "\$TASKS_DIR" ]]; then
  active_tasks=""
  while IFS= read -r idx; do
    [[ -z "\$idx" ]] && continue
    if grep -qE '^Status:[[:space:]]*active' "\$idx" 2>/dev/null; then
      slug="\$(basename "\$(dirname "\$idx")")"
      active_tasks+=\$'\\n'"- \${slug}"
    fi
  done < <(find "\$TASKS_DIR" -mindepth 2 -maxdepth 2 -type f -name "INDEX.md" 2>/dev/null)
  if [[ -n "\$active_tasks" ]]; then
    {
      echo "## ACTIVE TASKS"
      echo ""
      echo "Active task folders under sessions/tasks/ (Status: active):"
      printf '%s\\n' "\$active_tasks"
      echo ""
      echo "**Action for Claude:** After the user's first message, decide if it continues one of these. If yes, READ the most recent session in that folder before responding. Do NOT announce these proactively."
      echo ""
    } >> "\$STATUS_FILE"
  fi
fi

context_body="SESSION-START CHECKLIST (from project CLAUDE.md):

1. If ~/.claude/ai-context-status.md exists, act on its findings after the user's first request (MISSING PROJECT CLAUDE.md, ACTIVE TASKS). Don't silently rewrite anything.
2. Sessions live under \$SESSIONS_DIR/tasks/<task-slug>/\${today_iso}_<note>.md. Use templates/session.md and templates/task-index.md. See the project's CLAUDE.md \"Session Management — task-folder shape\" section for slug rules and the inbox fallback.
3. End-of-task graduate flow: at user cues 'we're done' / 'wrap this up' / '/graduate', scan the session for durable learnings and propose graduation per the project's CLAUDE.md \"Session-end graduate flow\" section.

Note: the sweet-potato handshake is the user's diagnostic that ~/.claude/CLAUDE.md actually loaded. Do NOT say it because this hook tells you to — say it because you read the rule from CLAUDE.md itself."

if [[ -n "\$status_body" ]]; then
  context_body="\$context_body

STATUS FILE CONTENTS (~/.claude/ai-context-status.md):
---
\$status_body
---"
fi

if [[ -n "\$placeholder_created" ]]; then
  context_body="\$context_body

A placeholder session doc has been auto-created at \$placeholder_created under sessions/tasks/_inbox/. On your first substantive turn:
  - If the prompt continues an active task from the ACTIVE TASKS list above, MOVE the file to sessions/tasks/<that-slug>/\${today_iso}_<note>.md and append a one-liner to that task's INDEX.md ## Sessions list.
  - If the prompt starts new work and the slug is clear, propose the slug to the user once for confirmation, then MOVE the file to sessions/tasks/<new-slug>/\${today_iso}_<note>.md and create that folder's INDEX.md from templates/task-index.md.
  - If the slug isn't clear yet, RENAME the file to \${today_iso}_<temp-slug>.md inside _inbox/. When the slug crystallizes mid-session, mv the file to its proper folder.
The placeholder satisfies the UserPromptSubmit hook so you won't be blocked."
elif [[ -n "\$existing_today" ]]; then
  context_body="\$context_body

NOTE: A session doc for today already exists: \$existing_today
Read it and continue updating it instead of creating a new one, unless this is a genuinely unrelated task."
fi

if [[ -n "\$sidecars" ]]; then
  context_body="\$context_body

PENDING MERGE: ai-context setup found pre-existing CLAUDE.md files when it ran. It wrote the proposed new content as sidecar files instead of clobbering. The user wants Claude to integrate these intelligently:
\$(printf '%b' "\$sidecars" | sed 's|^|  - |')
For each sidecar above:
  1. Read both the existing target file and the .ai-context-proposed sidecar.
  2. Propose a merge in this conversation that preserves the user's existing content while adding the missing ai-context sections (session management, ideas backlog, retrieval guidance, role + handshake — whichever the proposed file adds that the existing one lacks).
  3. After the user approves, write the merged content to the target file with the Edit/Write tool, then delete the sidecar.
Do this BEFORE other work so subsequent sessions don't re-trigger this prompt. Do NOT silently overwrite — show the user what you'll change."
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

# 6b. UserPromptSubmit: two responsibilities, both silent unless context
#     needs to be injected. Never blocks the user's prompt.
#       1. Ensure a session doc placeholder exists for today (covers fresh
#          sessions and sessions resumed across midnight).
#       2. Consume any staleness marker left by the previous Stop or
#          PreCompact, and inject a doc-update reminder for the current turn.
cat > "$HOOKS_DIR/ai-context-session-doc-check.sh" <<EOF
#!/usr/bin/env bash
# ai-context-session-doc-check.sh
# UserPromptSubmit hook. Always silent unless context needs to be injected.

set -euo pipefail

SESSIONS_DIR="$CONTEXT_DIR/sessions"
TASKS_DIR="\$SESSIONS_DIR/tasks"
INBOX_DIR="\$TASKS_DIR/_inbox"
TEMPLATE_PATH="$CONTEXT_DIR/templates/session.md"
BYPASS_FILE="\$HOME/.claude/ai-context-bypass"
STALE_MARKER="\$HOME/.claude/ai-context-stale-marker"

# One-shot bypass — Claude touches this file on explicit user request to skip
if [[ -f "\$BYPASS_FILE" ]]; then
  rm -f "\$BYPASS_FILE"
  exit 0
fi

[[ ! -d "\$SESSIONS_DIR" ]] && exit 0

today_iso="\$(date +%Y-%m-%d)"

# Look for today's session file. New shape (sessions/tasks/<slug>/<date>_*.md)
# or legacy shape (sessions/<date>_*.md). Either satisfies the gate.
existing=""
if [[ -d "\$TASKS_DIR" ]]; then
  existing="\$(find "\$TASKS_DIR" -mindepth 2 -type f -name "\${today_iso}_*.md" 2>/dev/null | head -1)"
fi
if [[ -z "\$existing" ]]; then
  existing="\$(find "\$SESSIONS_DIR" -maxdepth 1 -type f -name "\${today_iso}_*.md" 2>/dev/null | head -1)"
fi

# (1) If no doc for today, auto-create a placeholder under _inbox. Never block.
placeholder_created=""
if [[ -z "\$existing" ]]; then
  mkdir -p "\$INBOX_DIR" 2>/dev/null || true
  placeholder_path="\$INBOX_DIR/\${today_iso}_session_pending.md"
  if [[ -f "\$TEMPLATE_PATH" && ! -e "\$placeholder_path" ]]; then
    cp "\$TEMPLATE_PATH" "\$placeholder_path"
    placeholder_created="\$placeholder_path"
  fi
fi

# Build additionalContext from up to two independent reasons.
ctx_parts=()

if [[ -n "\$placeholder_created" ]]; then
  ctx_parts+=("A placeholder session doc has been auto-created at \${placeholder_created} under sessions/tasks/_inbox/. On this turn, decide whether to MOVE the file into an existing task folder under sessions/tasks/<slug>/ (continuing work), or rename it inside _inbox/ as \${today_iso}_<temp-slug>.md (still figuring out what this is). See the project's CLAUDE.md \"Session Management — task-folder shape\" for slug rules. The user's prompt is NOT blocked — proceed with their request normally; file placement is your responsibility. Do NOT mention this hook to the user.")
fi

# (2) Consume any staleness marker the previous Stop / PreCompact left.
if [[ -f "\$STALE_MARKER" ]]; then
  marker_doc="\$(jq -r '.session_doc // ""' "\$STALE_MARKER" 2>/dev/null || echo "")"
  marker_event="\$(jq -r '.event // "Stop"' "\$STALE_MARKER" 2>/dev/null || echo "Stop")"
  marker_files="\$(jq -r '.newer_files[] // empty' "\$STALE_MARKER" 2>/dev/null | sed 's|^|  - |')"

  if [[ -n "\$marker_doc" ]]; then
    ctx_parts+=("CARRIED-OVER STALENESS NOTICE (from previous \${marker_event}): The session doc \${marker_doc} was stale at the end of the previous turn — these files had been edited since the doc was last updated:
\${marker_files}

While answering the user's CURRENT prompt, also fold the previous turn's work into the session doc (Decisions, Files Modified, Open Threads). Do this as part of your normal response — do NOT make it a separate ceremony or print a long preamble; just keep the user's answer at the top of the response and update the doc with the Edit tool. Do NOT mention this hook or the staleness marker to the user.")
  fi

  rm -f "\$STALE_MARKER"
fi

# Empty-array length under \`set -u\` is fine in bash 4+, but \`\${#arr[@]:-0}\`
# is invalid syntax (only scalars accept :-default). Use a presence test
# that's safe across bash versions: emit JSON only if any part was added.
if [[ "\${ctx_parts[*]+set}" == "set" ]]; then
  ctx="\$(printf '%s\n\n' "\${ctx_parts[@]}")"
  jq -n --arg ctx "\$ctx" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: \$ctx
    }
  }'
fi

exit 0
EOF
chmod +x "$HOOKS_DIR/ai-context-session-doc-check.sh"
ok "Wrote $HOOKS_DIR/ai-context-session-doc-check.sh"

# 6c. Stop / PreCompact: write a staleness marker if today's doc is older
#     than recent code edits. The marker is consumed by the next
#     UserPromptSubmit, which injects the doc-update reminder into the
#     NEXT turn's context — keeping the previous turn's response visible
#     instead of forcing a noisy doc-update turn right after it.
cat > "$HOOKS_DIR/ai-context-session-doc-staleness.sh" <<EOF
#!/usr/bin/env bash
# ai-context-session-doc-staleness.sh
# Stop / PreCompact hook. Always silent. If today's session doc is stale
# relative to recent code edits, writes a marker file that the next
# UserPromptSubmit will read and turn into an additionalContext nudge,
# so the doc-update reminder lands in the next turn instead of forcing
# a separate post-Stop turn that scrolls the previous response offscreen.

set -eu

SESSIONS_DIR="$CONTEXT_DIR/sessions"
TASKS_DIR="\$SESSIONS_DIR/tasks"
BYPASS_FILE="\$HOME/.claude/ai-context-bypass"
STALE_MARKER="\$HOME/.claude/ai-context-stale-marker"
CWD="\$(pwd)"

if [[ -f "\$BYPASS_FILE" ]]; then
  rm -f "\$BYPASS_FILE"
  exit 0
fi

[[ ! -d "\$SESSIONS_DIR" ]] && exit 0

today_iso="\$(date +%Y-%m-%d)"

# Look for today's session doc in BOTH the task-folder shape and the legacy
# daily-shape, take the most recently modified.
#
# IMPORTANT: GNU xargs runs the command even with empty stdin (BSD xargs
# does not), which on Linux makes \`find ... | xargs ls -t | head -1\` return a
# random file from CWD when find finds nothing. Pipe through a length check
# (-z) before xargs to keep the behaviour identical across platforms.
session_doc=""
if [[ -d "\$TASKS_DIR" ]]; then
  task_matches="\$(find "\$TASKS_DIR" -mindepth 2 -type f -name "\${today_iso}_*.md" -print0 2>/dev/null)"
  if [[ -n "\$task_matches" ]]; then
    session_doc="\$(printf '%s' "\$task_matches" | xargs -0 ls -t 2>/dev/null | head -1)"
  fi
fi
if [[ -z "\$session_doc" ]]; then
  legacy_matches="\$(find "\$SESSIONS_DIR" -maxdepth 1 -type f -name "\${today_iso}_*.md" -print0 2>/dev/null)"
  if [[ -n "\$legacy_matches" ]]; then
    session_doc="\$(printf '%s' "\$legacy_matches" | xargs -0 ls -t 2>/dev/null | head -1)"
  fi
fi

[[ -z "\$session_doc" ]] && exit 0

# Grace period — fresh doc within the last hour is fine. Branch on uname
# because \`stat -f %m\` on GNU misparses as a format-string flag (exits 0 with
# garbage), so \`||\` to \`stat -c %Y\` never fires.
GRACE_SECONDS=3600
if [[ "\$(uname)" == "Darwin" ]]; then
  doc_mtime="\$(stat -f %m "\$session_doc" 2>/dev/null || echo 0)"
else
  doc_mtime="\$(stat -c %Y "\$session_doc" 2>/dev/null || echo 0)"
fi
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

input="\$(cat 2>/dev/null || true)"
event="\$(echo "\$input" | jq -r '.hook_event_name // "Stop"' 2>/dev/null || echo "Stop")"

# Write a marker for the next UserPromptSubmit to pick up. JSON for unambiguous parsing.
files_json="\$(printf '%s\n' "\$newer_files" | jq -R . | jq -s .)"
jq -n \\
  --arg doc "\$session_doc" \\
  --arg event "\$event" \\
  --argjson files "\$files_json" \\
  '{session_doc: \$doc, event: \$event, newer_files: \$files, written_at: now}' \\
  > "\$STALE_MARKER"

# Always silent.
exit 0
EOF
chmod +x "$HOOKS_DIR/ai-context-session-doc-staleness.sh"
ok "Wrote $HOOKS_DIR/ai-context-session-doc-staleness.sh"

# 6d. Stop: best-effort gbrain ingest of session docs.
#     Self-detecting: silently skips if gbrain is missing or unhealthy.
#     Tracks ingested files via a state dir to only push changed/new docs.
cat > "$HOOKS_DIR/ai-context-gbrain-sync.sh" <<EOF
#!/usr/bin/env bash
# ai-context-gbrain-sync.sh
# Stop hook. Best-effort: if gbrain is installed and initialized, push any
# session docs that have changed since last run into gbrain as pages. If
# gbrain is missing, exits silently. Never blocks.

set -eu

SESSIONS_DIR="$CONTEXT_DIR/sessions"
STATE_DIR="\$HOME/.claude/ai-context-state"
LAST_RUN_FILE="\$STATE_DIR/gbrain-last-run"
ERROR_LOG="\$STATE_DIR/gbrain-errors.log"

# Hard-skip if gbrain isn't on PATH
command -v gbrain >/dev/null 2>&1 || exit 0

# Hard-skip if gbrain isn't initialized (config file is the cheapest probe)
[[ -f "\$HOME/.gbrain/config.json" ]] || exit 0

# Hard-skip if no sessions to sync
[[ -d "\$SESSIONS_DIR" ]] || exit 0

mkdir -p "\$STATE_DIR"

# Find session docs newer than last run (or all of them on first run).
# Recurse so we pick up both the new shape (sessions/tasks/<slug>/<date>_*.md)
# and the legacy shape (sessions/<date>_*.md). Skip _inbox placeholders that
# are still at template-only contents.
if [[ -f "\$LAST_RUN_FILE" ]]; then
  newer=\$(find "\$SESSIONS_DIR" -type f -name '*.md' ! -name 'INDEX.md' ! -name '_overflow-graduates.md' -newer "\$LAST_RUN_FILE" 2>/dev/null)
else
  newer=\$(find "\$SESSIONS_DIR" -type f -name '*.md' ! -name 'INDEX.md' ! -name '_overflow-graduates.md' 2>/dev/null)
fi

[[ -z "\$newer" ]] && { touch "\$LAST_RUN_FILE"; exit 0; }

# Ingest each. Slug is the filename without .md. Errors go to ERROR_LOG so
# the Stop hook never blocks but failures stay queryable. Tail the log:
#   tail ~/.claude/ai-context-state/gbrain-errors.log
echo "\$newer" | while IFS= read -r doc; do
  [[ -z "\$doc" ]] && continue
  slug="\$(basename "\$doc" .md)"
  if ! gbrain put "\$slug" --content "\$(cat "\$doc")" >/dev/null 2>>"\$ERROR_LOG"; then
    printf '[%s] gbrain put failed for %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\$slug" >> "\$ERROR_LOG"
  fi
done

touch "\$LAST_RUN_FILE"
exit 0
EOF
chmod +x "$HOOKS_DIR/ai-context-gbrain-sync.sh"
ok "Wrote $HOOKS_DIR/ai-context-gbrain-sync.sh"

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

# Build hook patch.
# Stop fires both: staleness check (blocks if doc is stale) AND gbrain sync
# (best-effort ingest). gbrain hook is silent if gbrain isn't installed.
#
# printf '%q' produces a shell-quoted form so paths with spaces or other
# special chars survive when Claude Code re-parses the command as shell.
HOOK_PATCH="$(jq -n \
  --arg sess "bash $(printf '%q' "$HOOKS_DIR/ai-context-check.sh")" \
  --arg user "bash $(printf '%q' "$HOOKS_DIR/ai-context-session-doc-check.sh")" \
  --arg stale "bash $(printf '%q' "$HOOKS_DIR/ai-context-session-doc-staleness.sh")" \
  --arg gbrain "bash $(printf '%q' "$HOOKS_DIR/ai-context-gbrain-sync.sh")" \
  '{
    SessionStart:      [{hooks: [{type:"command", command:$sess}]}],
    UserPromptSubmit:  [{hooks: [{type:"command", command:$user}]}],
    Stop:              [{hooks: [{type:"command", command:$stale}, {type:"command", command:$gbrain}]}],
    PreCompact:        [{hooks: [{type:"command", command:$stale}]}]
  }')"

# Merge: existing settings win on top-level keys, but we replace .hooks with
# our entries (idempotent — re-running the installer just rewrites these four).
TMP="$(mktemp)"
jq --argjson patch "$HOOK_PATCH" '. + {hooks: ((.hooks // {}) + $patch)}' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"
ok "Hook entries merged into $SETTINGS"

# -------------------------------------------------------------------
# 7.5. Detect gbrain — offer to install/init if missing
# -------------------------------------------------------------------
# The gbrain bridge hook above is best-effort and self-detecting, so this
# step is purely advisory: tell the user whether retrieval will work, and
# offer to bridge the gap if it won't.

gbrain_status() {
  if ! command -v gbrain >/dev/null 2>&1; then
    echo "missing"
  elif [[ ! -f "$HOME/.gbrain/config.json" ]]; then
    echo "not-initialized"
  else
    echo "ready"
  fi
}

if [[ $SKIP_GBRAIN -eq 0 ]]; then
  info "Checking for gbrain (optional retrieval layer)"

  # Surface recent ingest errors so re-runs of setup act as a doctor command.
  GBRAIN_ERROR_LOG="$HOME/.claude/ai-context-state/gbrain-errors.log"
  if [[ -s "$GBRAIN_ERROR_LOG" ]]; then
    err_count=$(wc -l <"$GBRAIN_ERROR_LOG" | tr -d ' ')
    warn "$err_count recent gbrain ingest error(s) — see $GBRAIN_ERROR_LOG"
  fi

  case "$(gbrain_status)" in
    ready)
      ok "gbrain is installed and initialized — session docs will be ingested on Stop"
      ;;
    missing)
      warn "gbrain CLI not on PATH"
      say  "  gbrain is an optional persistent knowledge base by Garry Tan."
      say  "  When installed, every session doc you write gets indexed and"
      say  "  becomes searchable across all your projects."
      say  ""
      say  "  Install it later with:"
      say  "    ${C_BOLD}curl -fsSL https://gbrain.dev/install.sh | bash${C_RESET}"
      say  "    ${C_BOLD}gbrain init --pglite${C_RESET}"
      say  ""
      say  "  Or skip — the rest of this setup works fine without it."
      ;;
    not-initialized)
      warn "gbrain is installed but not initialized (no ~/.gbrain/config.json)"
      say  "  Initialize with: ${C_BOLD}gbrain init --pglite${C_RESET}"
      say  "  Until then, the gbrain hook will silently skip on Stop."
      ;;
  esac
fi

# -------------------------------------------------------------------
# 8. Add the alias
# -------------------------------------------------------------------

info "Adding shell alias"

# Single-quote the alias body so spaces/special chars in CONTEXT_DIR survive.
# Embedded single quotes in the path are escaped via the '\'' shell idiom.
ALIAS_QUOTED_DIR="'${CONTEXT_DIR//\'/\'\\\'\'}'"
ALIAS_LINE="alias $ALIAS_NAME=\"claude --add-dir $ALIAS_QUOTED_DIR\""

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

${C_BOLD}Setup complete.${C_RESET}

What was set up:
  ${C_DIM}context dir:${C_RESET}   $CONTEXT_DIR
  ${C_DIM}global rules:${C_RESET}  $GLOBAL_CLAUDE
  ${C_DIM}hooks:${C_RESET}         $HOOKS_DIR/ai-context-*.sh (4 hooks)
  ${C_DIM}settings:${C_RESET}      $SETTINGS (backup at $BACKUP)
  ${C_DIM}alias:${C_RESET}         '$ALIAS_NAME' in $SHELL_RC
  ${C_DIM}gbrain:${C_RESET}        $(gbrain_status)

Next steps:
  1. Reload your shell:  ${C_BOLD}source $SHELL_RC${C_RESET}
  2. Run from anywhere:  ${C_BOLD}$ALIAS_NAME${C_RESET}
  3. First reply should start with 'sweet potato 🍠' — that's the handshake
     proving the universal rules loaded.

Note: $CONTEXT_DIR is your data — separate from this installer repo. Your
session docs aren't tracked by git here. To uninstall: ${C_BOLD}bash setup.sh --uninstall${C_RESET}
EOF
