# Personal `cc` setup

Portable replication of a "cc"-style Claude Code workflow. One script, one
command, runs on any new machine. Bring-your-own-`gbrain` for cross-session
retrieval.

## What it sets up

- A context directory (default `~/ai-context/`) with `templates/`, `sessions/`, `ideas/`, and a navigation `CLAUDE.md`
- Four hook scripts in `~/.claude/hooks/`:
  - `ai-context-check.sh` — `SessionStart` — injects the handshake checklist + flags missing project `CLAUDE.md`
  - `ai-context-session-doc-check.sh` — `UserPromptSubmit` — blocks until today's session doc exists
  - `ai-context-session-doc-staleness.sh` — `Stop` and `PreCompact` — blocks if the doc is older than recent code edits
  - `ai-context-gbrain-sync.sh` — `Stop` — best-effort: pushes new/changed session docs into `gbrain` if it's installed; silently skipped otherwise
- Hook entries merged into `~/.claude/settings.json` (existing settings preserved; one-time backup written)
- Global `~/.claude/CLAUDE.md` with the senior-engineer role, validation principle, coding/testing principles, and the **sweet potato 🍠** handshake (only created if missing — never overwrites yours)
- A shell alias (default `cc`) added to your shell rc: `alias cc="claude --add-dir <context-dir>"`

## Optional: gbrain integration

If [`gbrain`](https://gbrain.dev) is installed on your machine, every session
doc you save is automatically ingested as a searchable page. After a few
sessions, `gbrain search "<phrase>"` finds the relevant past session docs.

The setup script tells you whether gbrain is detected and how to install it
if you want it. The hook is best-effort: if gbrain is missing or unhealthy,
nothing breaks — you just don't get retrieval.

```bash
# After setup, install gbrain if you want retrieval:
curl -fsSL https://gbrain.dev/install.sh | bash
gbrain init --pglite
```

## Requirements

- `bash` and `jq` (the script tells you if `jq` is missing)
- The `claude` CLI installed (https://docs.claude.com/en/docs/claude-code/setup)
- `gbrain` is **optional** — not required, but unlocks cross-session retrieval

## Use

```bash
bash setup.sh                  # interactive prompts
bash setup.sh --yes            # accept all defaults
bash setup.sh --skip-gbrain    # skip the gbrain detection prompt entirely
```

The interactive prompts ask for:
1. **Context dir path** — default `~/ai-context/`. If it exists, it's reused; if not, you confirm before it's created.
2. **Alias name** — default `cc`.
3. **Shell rc file** — auto-detects zsh vs bash.

## Idempotent

Re-running the script is safe. It will:
- Reuse an existing context dir.
- Leave existing template files untouched.
- Leave an existing global `~/.claude/CLAUDE.md` untouched (warns instead).
- Re-merge hook entries into `settings.json` (overwriting just the four hook keys, preserving everything else).
- Skip adding an already-present alias.

## After setup

```bash
source ~/.zshrc   # or ~/.bashrc
cc                # launches claude with the context dir attached
```

Your first response in any Claude session should start with `sweet potato 🍠` — that's the diagnostic confirming the universal rules loaded.

## Personal-project flavor

The setup is **agnostic of any specific employer or codebase**. The navigation `CLAUDE.md` doesn't ship a multi-repo ecosystem map (single-repo personal projects don't need it). For new feature ideation, lean on the `/office-hours` skill from gstack — it walks through the design questions before code is written and saves a design doc to your context dir.

## Removal

```bash
# 1. Drop the hook entries from settings.json (or restore the .bak.<ts> backup)
# 2. Remove the alias line from your shell rc
# 3. rm ~/.claude/hooks/ai-context-*.sh
# 4. Optionally: rm -rf <your-context-dir>
```
