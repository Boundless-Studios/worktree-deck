#!/usr/bin/env bash
# Versioned worktree-placement and execution-target compatibility contract.

if [[ -z "${WTD_SYNC_VISIBLE_ROOTS+x}" ]]; then
    WTD_SYNC_VISIBLE_ROOTS=()
fi
if [[ -z "${WTD_SYNC_IGNORED_ROOTS+x}" ]]; then
    WTD_SYNC_IGNORED_ROOTS=()
fi

_wtd_json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

# Resolve symlinks in the existing prefix and normalize future path components.
wtd_canonical_path() {
    local input="${1:-}" cursor parent component resolved
    local -a missing=()

    [[ -n "$input" ]] || return 1
    if [[ "$input" != /* ]]; then
        input="$PWD/$input"
    fi
    cursor="${input%/}"
    [[ -n "$cursor" ]] || cursor="/"

    while [[ ! -d "$cursor" ]]; do
        component="${cursor##*/}"
        [[ -n "$component" ]] || return 1
        missing=("$component" ${missing[@]+"${missing[@]}"})
        parent="${cursor%/*}"
        [[ -n "$parent" ]] || parent="/"
        [[ "$parent" != "$cursor" ]] || return 1
        cursor="$parent"
    done

    resolved="$(cd "$cursor" && pwd -P)" || return 1
    for component in ${missing[@]+"${missing[@]}"}; do
        case "$component" in
            ""|".")
                ;;
            "..")
                if [[ "$resolved" != "/" ]]; then
                    resolved="${resolved%/*}"
                    [[ -n "$resolved" ]] || resolved="/"
                fi
                ;;
            *)
                resolved="${resolved%/}/$component"
                ;;
        esac
    done
    printf '%s\n' "$resolved"
}

_wtd_path_is_within() {
    local path="$1" root="$2"
    if [[ "$root" == "/" ]]; then
        [[ "$path" == /* ]]
        return
    fi
    [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

# Downstream configuration may override this function for another visibility
# source while preserving the visible|ignored|unknown return contract.
wtd_sync_visibility() {
    local path root canonical_root
    path="$(wtd_canonical_path "${1:-}")" || {
        printf 'unknown\n'
        return
    }

    for root in ${WTD_SYNC_IGNORED_ROOTS[@]+"${WTD_SYNC_IGNORED_ROOTS[@]}"}; do
        [[ -n "$root" ]] || continue
        canonical_root="$(wtd_canonical_path "$root")" || continue
        if _wtd_path_is_within "$path" "$canonical_root"; then
            printf 'ignored\n'
            return
        fi
    done
    for root in ${WTD_SYNC_VISIBLE_ROOTS[@]+"${WTD_SYNC_VISIBLE_ROOTS[@]}"}; do
        [[ -n "$root" ]] || continue
        canonical_root="$(wtd_canonical_path "$root")" || continue
        if _wtd_path_is_within "$path" "$canonical_root"; then
            printf 'visible\n'
            return
        fi
    done
    printf 'unknown\n'
}

_wtd_normalize_boolean() {
    case "${1:-}" in
        true|1|yes|on) printf 'true\n' ;;
        false|0|no|off) printf 'false\n' ;;
        *) return 1 ;;
    esac
}

_wtd_emit_placement_decision() {
    local identity="$1" placement_class="$2" path="$3" visibility="$4"
    local target_kind="$5" requires_sync="$6" compatible="$7"
    local reason_code="$8" remediation="$9"

    printf '{"schema_version":"1.0","contract":"worktree-placement-compatibility/v1",'
    printf '"placement":{"schema_version":"1.0","identity":"%s","class":"%s","path":"%s","sync_visibility":"%s"},' \
        "$(_wtd_json_escape "$identity")" \
        "$(_wtd_json_escape "$placement_class")" \
        "$(_wtd_json_escape "$path")" \
        "$(_wtd_json_escape "$visibility")"
    printf '"execution_target":{"kind":"%s","requires_sync":%s},' \
        "$(_wtd_json_escape "$target_kind")" "$requires_sync"
    printf '"decision":{"compatible":%s,"reason_code":"%s","remediation":"%s"}}\n' \
        "$compatible" \
        "$(_wtd_json_escape "$reason_code")" \
        "$(_wtd_json_escape "$remediation")"
}

# Exit 0 for compatible, 1 for a valid but incompatible decision, and 2 for an
# invalid contract. Every outcome emits the same versioned JSON envelope.
wtd_evaluate_placement() {
    local identity="${1:-}" placement_class="${2:-}" input_path="${3:-}"
    local visibility="${4:-}" target_kind="${5:-}" raw_requires_sync="${6:-}"
    local path="$input_path" requires_sync="false"

    path="$(wtd_canonical_path "$input_path")" || true
    if [[ -z "$identity" || -z "$placement_class" || -z "$path" ]] \
        || [[ "$visibility" != "visible" \
            && "$visibility" != "ignored" \
            && "$visibility" != "unknown" ]] \
        || [[ "$target_kind" != "local" && "$target_kind" != "remote" ]] \
        || ! requires_sync="$(_wtd_normalize_boolean "$raw_requires_sync")"; then
        _wtd_emit_placement_decision \
            "$identity" "$placement_class" "$path" "$visibility" \
            "$target_kind" "$requires_sync" "false" "invalid_contract" \
            "Provide a valid placement, target kind, synchronization boolean, and visibility."
        return 2
    fi

    if [[ "$requires_sync" == "false" ]]; then
        _wtd_emit_placement_decision \
            "$identity" "$placement_class" "$path" "$visibility" \
            "$target_kind" "$requires_sync" "true" "sync_not_required" ""
        return 0
    fi

    case "$visibility" in
        visible)
            _wtd_emit_placement_decision \
                "$identity" "$placement_class" "$path" "$visibility" \
                "$target_kind" "$requires_sync" "true" \
                "sync_visibility_confirmed" ""
            return 0
            ;;
        ignored)
            _wtd_emit_placement_decision \
                "$identity" "$placement_class" "$path" "$visibility" \
                "$target_kind" "$requires_sync" "false" \
                "sync_visibility_ignored" \
                "Choose a synchronized worktree root or change the configured placement."
            return 1
            ;;
        unknown)
            _wtd_emit_placement_decision \
                "$identity" "$placement_class" "$path" "$visibility" \
                "$target_kind" "$requires_sync" "false" \
                "sync_visibility_unknown" \
                "Declare this path visible or choose an execution target that does not require synchronization."
            return 1
            ;;
    esac
}

wtd_execution_target_configured() {
    [[ -n "${WTD_EXECUTION_TARGET_KIND:-}" ]]
}

wtd_evaluate_configured_placement() {
    local identity="${1:-}" placement_class="${2:-}" path="${3:-}"
    local visibility

    if ! wtd_execution_target_configured; then
        wtd_evaluate_placement \
            "$identity" "$placement_class" "$path" "unknown" "" \
            "${WTD_EXECUTION_TARGET_REQUIRES_SYNC:-false}"
        return $?
    fi

    visibility="$(wtd_sync_visibility "$path")"
    wtd_evaluate_placement \
        "$identity" "$placement_class" "$path" "$visibility" \
        "$WTD_EXECUTION_TARGET_KIND" \
        "${WTD_EXECUTION_TARGET_REQUIRES_SYNC:-false}"
}
