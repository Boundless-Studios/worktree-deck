#!/usr/bin/env bash
# Source me — helpers for detecting worktree host-port conflicts across
# Docker daemons. This catches cases where a remote DOCKER_HOST is healthy but
# localhost traffic is actually served by a stale local daemon such as Colima.

if [[ -n "${_GAIA_WORKTREE_PORT_CONFLICTS_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_GAIA_WORKTREE_PORT_CONFLICTS_LOADED=1

_gaia_worktree_known_docker_hosts() {
    local candidates=()
    local home="${HOME:-}"

    if [[ -n "${GAIA_WORKTREE_EXTRA_DOCKER_HOSTS:-}" ]]; then
        # shellcheck disable=SC2206
        candidates+=(${GAIA_WORKTREE_EXTRA_DOCKER_HOSTS})
    fi

    if [[ -n "$home" ]]; then
        candidates+=(
            "unix://${home}/.colima/default/docker.sock"
            "unix://${home}/.docker/run/docker.sock"
            "unix://${home}/.rd/docker.sock"
        )
    fi
    candidates+=("unix:///var/run/docker.sock")

    local active="${DOCKER_HOST:-}"
    local seen=" "
    local host path
    for host in "${candidates[@]}"; do
        [[ -n "$host" ]] || continue
        [[ "$host" != "$active" ]] || continue
        [[ "$seen" != *" $host "* ]] || continue
        if [[ "$host" == unix://* ]]; then
            path="${host#unix://}"
            [[ -e "$path" || -S "$path" ]] || continue
        fi
        seen+="$host "
        printf '%s\n' "$host"
    done
}

_gaia_worktree_daemon_label() {
    local host="$1"
    case "$host" in
        unix://*/.colima/default/docker.sock|unix://*/colima/default/docker.sock)
            printf 'Colima default (%s)' "$host"
            ;;
        unix://*)
            printf 'local Docker socket (%s)' "$host"
            ;;
        *)
            printf 'Docker daemon (%s)' "$host"
            ;;
    esac
}

_gaia_worktree_ports_match() {
    local ports="$1"
    local port="$2"
    printf '%s\n' "$ports" | grep -Eq "(^|, )[][[:alnum:].:*_-]*:${port}->"
}

_gaia_worktree_scan_daemon_for_ports() {
    local host="$1"
    shift
    DOCKER_HOST="$host" docker ps --format '{{.Names}}	{{.Ports}}' 2>/dev/null | while IFS=$'\t' read -r name ports; do
        [[ -n "$name" ]] || continue
        local port
        for port in "$@"; do
            [[ -n "$port" && "$port" != "0" ]] || continue
            if _gaia_worktree_ports_match "$ports" "$port"; then
                printf '%s\t%s\t%s\t%s\n' "$host" "$name" "$port" "$ports"
            fi
        done
    done
}

_gaia_worktree_daemon_id() {
    local host="$1"
    if [[ -n "$host" ]]; then
        DOCKER_HOST="$host" docker info --format '{{.ID}}' 2>/dev/null || true
    else
        docker info --format '{{.ID}}' 2>/dev/null || true
    fi
}

gaia_worktree_port_conflicts_report() {
    local conflicts=0
    local active_id host label name port ports daemon_id
    case "${DOCKER_HOST:-}" in
        ""|unix://*) active_id="$(_gaia_worktree_daemon_id "${DOCKER_HOST:-}")" ;;
        *) active_id="" ;;
    esac
    while IFS= read -r host; do
        [[ -n "$host" ]] || continue
        daemon_id="$(_gaia_worktree_daemon_id "$host")"
        if [[ -n "$active_id" && -n "$daemon_id" && "$active_id" == "$daemon_id" ]]; then
            continue
        fi
        while IFS=$'\t' read -r host name port ports; do
            [[ -n "$name" ]] || continue
            label="$(_gaia_worktree_daemon_label "$host")"
            echo "⚠ Cross-daemon port conflict: ${label} publishes host port ${port} via container ${name}."
            echo "  Ports: ${ports}"
            echo "  Stop it: DOCKER_HOST=${host} docker stop ${name}"
            conflicts=1
        done < <(_gaia_worktree_scan_daemon_for_ports "$host" "$@")
    done < <(_gaia_worktree_known_docker_hosts)

    [[ "$conflicts" -eq 0 ]]
}

gaia_worktree_port_conflicts_guard_localhost() {
    if ! report="$(gaia_worktree_port_conflicts_report "$@" 2>&1)"; then
        echo "❌ localhost may resolve to another Docker daemon for one of these ports: $*"
        printf '%s\n' "$report"
        return 1
    fi
    return 0
}
