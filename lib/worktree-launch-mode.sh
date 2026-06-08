#!/usr/bin/env bash
# Shared helpers for selecting which interactive coding CLI to launch from
# Gaia worktree utilities.

gaia_default_launch_flag() {
    printf '%s\n' "${GAIA_WORKTREE_LAUNCH_FLAG:---codex}"
}

gaia_is_launch_selector() {
    case "${1:-}" in
        --codex|--claude|codex|claude)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

gaia_normalize_launch_flag() {
    case "${1:-}" in
        "" )
            gaia_default_launch_flag
            ;;
        --codex|codex)
            printf '%s\n' "--codex"
            ;;
        --claude|claude)
            printf '%s\n' "--claude"
            ;;
        *)
            return 1
            ;;
    esac
}

gaia_launch_cli_from_flag() {
    case "$(gaia_normalize_launch_flag "${1:-}")" in
        --claude)
            printf '%s\n' "claude"
            ;;
        *)
            printf '%s\n' "codex"
            ;;
    esac
}

gaia_launch_label_from_flag() {
    case "$(gaia_normalize_launch_flag "${1:-}")" in
        --claude)
            printf '%s\n' "Claude Code"
            ;;
        *)
            printf '%s\n' "Codex CLI"
            ;;
    esac
}
