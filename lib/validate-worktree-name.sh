#!/usr/bin/env bash
# Validate a proposed worktree / branch name before any git invocation.
#
# Centralizes the guard so new-wt (Makefile), the worktree console, and
# continue-worktree all reject the same bad inputs with a clear message
# instead of git's cryptic "error: unknown switch o": a name
# that starts with '-' is read by git's internal `git branch` as a bundle
# of command-line flags.
#
# Usage: validate-worktree-name.sh <name>
# Exits 0 if usable, non-zero with an explanation on stderr otherwise.
set -euo pipefail

name="${1-}"

if [ -z "$name" ]; then
  echo "❌ Worktree name is empty." >&2
  exit 1
fi

case "$name" in
  -*)
    echo "❌ Invalid worktree name '$name': names can't start with '-'." >&2
    echo "   Git reads a leading dash as a command-line flag (the cryptic" >&2
    echo "   'error: unknown switch' you'd otherwise hit). Drop the dash:" >&2
    echo "       wn ${name#-}" >&2
    exit 1
    ;;
esac

# Defer everything else (spaces, '..', '~', control chars, etc.) to git's
# own ref-format rules. Safe to pass directly here since the leading-dash
# case is already handled above.
if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
  echo "❌ Invalid worktree name '$name': not a valid git branch name." >&2
  echo "   Use letters, digits, '-', '_', or '/' (no spaces, '..', or '~')." >&2
  exit 1
fi
