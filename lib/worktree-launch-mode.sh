#!/usr/bin/env bash
# Shared helpers for selecting which interactive coding CLI to launch from
# worktree-deck launch-mode helpers.

wtd_default_launch_flag() {
    printf '%s\n' "${WTD_LAUNCH_FLAG:---codex}"
}

wtd_is_launch_selector() {
    case "${1:-}" in
        --codex|--claude|codex|claude)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

wtd_normalize_launch_flag() {
    case "${1:-}" in
        "" )
            wtd_default_launch_flag
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

wtd_launch_cli_from_flag() {
    case "$(wtd_normalize_launch_flag "${1:-}")" in
        --claude)
            printf '%s\n' "claude"
            ;;
        *)
            printf '%s\n' "codex"
            ;;
    esac
}

wtd_launch_label_from_flag() {
    case "$(wtd_normalize_launch_flag "${1:-}")" in
        --claude)
            printf '%s\n' "Claude Code"
            ;;
        *)
            printf '%s\n' "Codex CLI"
            ;;
    esac
}
