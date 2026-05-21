#!/usr/bin/env bash
# --yes mode must refuse fish/nushell/etc. so users don't get a zsh-syntax
# alias dropped into a file their shell doesn't read.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

echo "=== test-shell-refusal ==="
SANDBOX="$(make_sandbox)"

# Fish + --yes should exit 1 with a clear message
out=$(SHELL=/usr/local/bin/fish HOME="$SANDBOX" bash "$SETUP" --yes --skip-gbrain 2>&1) || rc=$?
rc="${rc:-0}"
assert_eq "fish + --yes exits 1" "1" "$rc"
assert_contains "fish refusal message names the shell" "fish" "$out"
assert_contains "fish refusal points to interactive mode" "interactively" "$out"

# Sanity: zsh + --yes still works
SANDBOX2="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$SANDBOX2"' EXIT
SHELL=/bin/zsh run_setup "$SANDBOX2"
assert_file "zsh + --yes still produces alias" "$SANDBOX2/.zshrc"

finish
