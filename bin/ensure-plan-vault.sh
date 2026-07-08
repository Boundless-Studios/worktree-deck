#!/usr/bin/env bash
# ensure-plan-vault.sh — idempotently guarantee the co-planning Obsidian vault is
# ready: exists, is a git repo, is seeded from the template, and is registered with
# Obsidian. Designed to run as a SessionStart hook, so it MUST be fast and MUST NEVER
# fail the session (every path exits 0).
#
# Behavior (per gaia BOU planning-surface integration):
#   - silent-ensure on every session (create/seed/register only if missing);
#   - auto-open Obsidian ONLY on the first session of a brand-new branch.
#
# Env overrides:
#   GAIA_PLANS_VAULT   vault dir (default: ~/code/gaia-plans)
#   GAIA_PLANS_NO_OPEN  set to 1 to suppress the new-branch auto-open
set -uo pipefail

VAULT="${GAIA_PLANS_VAULT:-$HOME/code/gaia-plans}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/gaia-plans"
MARKERS="$STATE_DIR/opened-branches"

# 1. Ensure vault layout + git repo (best-effort; bail quietly if we can't).
mkdir -p "$VAULT/plans" "$MARKERS" 2>/dev/null || exit 0
if [ ! -d "$VAULT/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$VAULT" init -q 2>/dev/null || true
fi

# 2. Seed README + template from the vendored templates, only if absent.
[ -f "$VAULT/_template.md" ] || cp "$TEMPLATE_DIR/plan-template.md" "$VAULT/_template.md" 2>/dev/null || true
[ -f "$VAULT/README.md" ]    || cp "$TEMPLATE_DIR/vault-README.md" "$VAULT/README.md"    2>/dev/null || true

# 3. Register the vault with Obsidian (macOS), only if absent. Atomic + self-healing:
#    if Obsidian later clobbers the entry on quit, the next session re-adds it.
if [ "$(uname)" = "Darwin" ] && command -v python3 >/dev/null 2>&1; then
    OBS_CFG="$HOME/Library/Application Support/obsidian/obsidian.json"
    if [ -f "$OBS_CFG" ]; then
        OBS_CFG="$OBS_CFG" VAULT="$VAULT" \
            python3 "$SCRIPT_DIR/../lib/register_obsidian_vault.py" >/dev/null 2>&1 || true
    fi
fi

# 4. Auto-open Obsidian ONLY on the first session of a brand-new (non-default) branch.
#    The `obsidian://open?path=<dir>` deep link opens the vault that CONTAINS the path
#    (verified against a registered vault dir), but it can only resolve a vault Obsidian
#    already knows. So we open first, then burn the marker — and we only do so once the
#    vault is actually registered in obsidian.json. If it isn't yet (e.g. before Obsidian's
#    first run), we skip WITHOUT marking, so a later session retries instead of the branch
#    being permanently suppressed.
if [ "${GAIA_PLANS_NO_OPEN:-0}" != "1" ] && [ "$(uname)" = "Darwin" ]; then
    BRANCH="$(git -C "$PWD" branch --show-current 2>/dev/null || true)"
    case "$BRANCH" in
        "" | main | master | HEAD) : ;;
        *)
            MARK="$MARKERS/${BRANCH//\//__}"
            OBS_CFG="$HOME/Library/Application Support/obsidian/obsidian.json"
            if [ ! -f "$MARK" ] && [ -f "$OBS_CFG" ] && grep -Fq "\"$VAULT\"" "$OBS_CFG" 2>/dev/null; then
                open -a Obsidian "obsidian://open?path=$VAULT" >/dev/null 2>&1 || true
                : > "$MARK" 2>/dev/null || true
            fi
            ;;
    esac
fi

exit 0
