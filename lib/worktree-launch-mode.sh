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

# Resume arguments for an agent CLI: the flags that continue that CLI's most
# recent session in the current directory. Consumed by the console's resume
# action (`<n>r`). Empty output means "no known way to resume this CLI" — the
# caller then launches it fresh. Override in worktree-deck.conf to support other
# launchers or custom resume flags.
wtd_resume_args_from_cli() {
    case "${1:-}" in
        claude)
            printf '%s\n' "--continue"
            ;;
        codex)
            printf '%s\n' "resume --last"
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}
