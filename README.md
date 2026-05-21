# Personal `cc` setup

Portable replication of a "cc"-style Claude Code workflow. One script, one
command, runs on any new machine. Bring-your-own-`gbrain` for cross-session
retrieval.

## How this is structured

This repo is the **bootstrapper**, not your data. After running `setup.sh`,
two things exist on your disk and they are deliberately separate:

```
~/code/claude-context-installer/    ← this repo (the bootstrapper)
   ├── setup.sh                       writes the things below
   ├── README.md                      what you're reading
   └── tests/                         test harness for setup.sh

~/ai-context/                       ← your context dir (the data)
   ├── CLAUDE.md                      navigation Claude reads on every cc session
   ├── sessions/                      one .md per work session — your narrative
   ├── ideas/                         architectural / product backlog
   └── templates/                     blanks for new sessions and ideas
```

**Implications:**

- Your session docs in `~/ai-context/sessions/` are **yours**. Setup never
  reads or pushes them anywhere. You can put `~/ai-context/` under git yourself
  if you want cross-machine sync, but the installer doesn't manage that.
- `git pull`ing this installer repo does **NOT** update `~/ai-context/`.
  Re-running `bash setup.sh` rewrites the **hook scripts** (so bug fixes in
  hooks propagate) but leaves your `CLAUDE.md` files alone — instead it writes
  a `.ai-context-proposed` sidecar that the next `cc` session offers to merge.
- Uninstall is reversible: `bash setup.sh --uninstall` removes everything the
  installer wrote and asks before deleting anything that contains user data.

## What it sets up

- A context directory (default `~/ai-context/`) with `templates/`, `sessions/`, `ideas/`, and a navigation `CLAUDE.md`
- Four hook scripts in `~/.claude/hooks/`:
  - `ai-context-check.sh` — `SessionStart` — injects the handshake checklist, flags missing project `CLAUDE.md`, and surfaces any pending `.ai-context-proposed` merges
  - `ai-context-session-doc-check.sh` — `UserPromptSubmit` — blocks until today's session doc exists
  - `ai-context-session-doc-staleness.sh` — `Stop` and `PreCompact` — blocks if the doc is older than recent code edits
  - `ai-context-gbrain-sync.sh` — `Stop` — best-effort: pushes new/changed session docs into `gbrain` if it's installed; silently skipped otherwise
- Hook entries merged into `~/.claude/settings.json` (existing settings preserved; one-time backup written)
- Global `~/.claude/CLAUDE.md` with the senior-engineer role, validation principle, coding/testing principles, and the **sweet potato 🍠** handshake
- A shell alias (default `cc`) added to your shell rc: `alias cc="claude --add-dir '<context-dir>'"`

## Smart merge for existing setups

If you already have a populated `~/ai-context/` (e.g. you're installing on a
second machine that you've been using for a while), setup detects the existing
`CLAUDE.md` files and writes its proposed content to a `.ai-context-proposed`
sidecar instead of overwriting. The next time you run `cc`, the SessionStart
hook surfaces a merge prompt and Claude offers to integrate the two — you see
the diff, approve, and the sidecar is consumed.

This applies to:
- `~/ai-context/CLAUDE.md` (navigation file)
- `~/.claude/CLAUDE.md` (global rules)

Other content (your `sessions/*.md`, `ideas/*.md`, `templates/*.md`) is never
modified by setup.

## Optional: gbrain integration

If [`gbrain`](https://gbrain.dev) is installed on your machine, every session
doc you save is automatically ingested as a searchable page. After a few
sessions, `gbrain search "<phrase>"` finds the relevant past session docs.

The setup script reports whether gbrain is detected. The hook is best-effort:
if gbrain is missing or unhealthy, nothing breaks. Failures are logged to
`~/.claude/ai-context-state/gbrain-errors.log` so you can `tail` it if
retrieval seems off; re-running setup surfaces the recent error count.

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
bash setup.sh --yes            # accept all defaults (zsh/bash only)
bash setup.sh --skip-gbrain    # skip the gbrain detection prompt entirely
bash setup.sh --uninstall      # reverse the install
```

`--yes` is rejected for fish/nushell/etc. shells because the alias would land
in the wrong file. Run interactively from those shells and choose your rc path.

The interactive prompts ask for:
1. **Context dir path** — default `~/ai-context/`. If it exists, it's reused; new content goes to a sidecar.
2. **Alias name** — default `cc`.
3. **Shell rc file** — auto-detects zsh vs bash.

## Idempotent

Re-running the script is safe:

- Reuses existing context dir; never touches `sessions/` or `ideas/`.
- Leaves existing template files untouched.
- For both `CLAUDE.md` files: writes the up-to-date content to a sidecar if
  the existing file differs (next `cc` session merges); silently does nothing
  if the existing file already matches.
- Re-merges hook entries into `settings.json` (overwrites just the four hook
  keys, preserving everything else).
- Skips adding an already-present alias.

## After setup

```bash
source ~/.zshrc   # or ~/.bashrc
cc                # launches claude with the context dir attached
```

Your first response in any Claude session should start with `sweet potato 🍠` — that's the diagnostic confirming the universal rules loaded.

If you had pre-existing `CLAUDE.md` files, the first `cc` session prompts
Claude to merge the sidecars before doing other work.

## Personal-project flavor

The setup is **agnostic of any specific employer or codebase**. The navigation `CLAUDE.md` doesn't ship a multi-repo ecosystem map (single-repo personal projects don't need it). For new feature ideation, lean on the `/office-hours` skill from gstack — it walks through the design questions before code is written and saves a design doc to your context dir.

## Removal

```bash
bash setup.sh --uninstall
```

Reverses the install: removes hook entries from settings.json, removes the
alias from your shell rc, deletes the hook scripts and the state dir, asks
before deleting your context dir and global `CLAUDE.md`. Backups are written
to `settings.json.bak.<timestamp>`.
