#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    printf 'Usage: %s {start|run|stop|status}\n' "${0##*/}"
}

watcher_matches() {
    local pid="$1"
    local server_pid="$2"
    kill -0 "$pid" 2>/dev/null || return 1
    ps -ww -p "$pid" -o command= 2>/dev/null | \
        grep -F -- "$SCRIPT_DIR/watch.sh run $server_pid" >/dev/null
}

runtime_dir=''
pid_file=''
log_file=''

initialize_runtime() {
    runtime_dir="$(tmux_guard_runtime_dir)"
    pid_file="$runtime_dir/watcher.pid"
    log_file="$runtime_dir/watcher.log"
}

tracked_watcher_pid() {
    local pid
    local server_pid
    server_pid="$(tmux_guard_unsigned_or \
        "$(tmux_guard_tmux display-message -p '#{pid}' 2>/dev/null || true)" 0)"
    [ "$server_pid" -gt 0 ] || return 1
    pid="$(tmux_guard_unsigned_or "$(tmux_guard_option @history-guard-watcher-pid '')" 0)"
    if [ "$pid" -gt 0 ] && watcher_matches "$pid" "$server_pid"; then
        printf '%s\n' "$pid"
        return
    fi
    if [ -n "$pid_file" ] && [ -r "$pid_file" ]; then
        pid="$(tmux_guard_unsigned_or "$(sed -n '1p' "$pid_file")" 0)"
        if [ "$pid" -gt 0 ] && watcher_matches "$pid" "$server_pid"; then
            printf '%s\n' "$pid"
            return
        fi
    fi
    return 1
}

start_watcher() {
    local existing_pid
    local server_pid
    local socket
    local watcher_pid
    mkdir -p "$runtime_dir"
    chmod 700 "$runtime_dir"
    trap tmux_guard_release_runtime_lock EXIT
    trap 'tmux_guard_release_runtime_lock; trap - INT TERM; exit 130' INT TERM
    tmux_guard_acquire_runtime_lock watcher-start
    if ! tmux_guard_is_on "$(tmux_guard_option @history-guard-enabled on)"; then
        tmux_guard_release_runtime_lock
        trap - EXIT INT TERM
        printf 'tmux-history-guard watcher is disabled\n'
        return
    fi
    existing_pid="$(tracked_watcher_pid || true)"
    if [ -n "$existing_pid" ]; then
        tmux_guard_release_runtime_lock
        trap - EXIT INT TERM
        printf 'tmux-history-guard watcher already running (pid %s)\n' "$existing_pid"
        return
    fi
    rm -f "$pid_file"
    tmux_guard_tmux set-option -gu @history-guard-watcher-pid 2>/dev/null || true
    socket="$(tmux_guard_socket)"
    if [ -n "$socket" ]; then
        export TMUX_HISTORY_GUARD_SOCKET="$socket"
    fi
    server_pid="$(tmux_guard_unsigned_or \
        "$(tmux_guard_tmux display-message -p '#{pid}' 2>/dev/null || true)" 0)"
    if [ "$server_pid" -eq 0 ]; then
        tmux_guard_release_runtime_lock
        trap - EXIT INT TERM
        printf 'tmux-history-guard: cannot identify tmux server\n' >&2
        return 1
    fi
    export TMUX_HISTORY_GUARD_SERVER_PID="$server_pid"
    nohup "$SCRIPT_DIR/watch.sh" run "$server_pid" </dev/null >>"$log_file" 2>&1 &
    watcher_pid=$!
    printf '%s\n' "$watcher_pid" > "$pid_file"
    tmux_guard_tmux set-option -gq @history-guard-watcher-pid "$watcher_pid"
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        watcher_matches "$watcher_pid" "$server_pid" && break
        sleep 0.02
    done
    if ! watcher_matches "$watcher_pid" "$server_pid"; then
        tmux_guard_release_runtime_lock
        trap - EXIT INT TERM
        printf 'tmux-history-guard watcher failed to start\n' >&2
        return 1
    fi
    tmux_guard_release_runtime_lock
    trap - EXIT INT TERM
    printf 'tmux-history-guard watcher started (pid %s)\n' "$watcher_pid"
}

server_matches() {
    local expected_pid="$1"
    local actual_pid
    kill -0 "$expected_pid" 2>/dev/null || return 1
    actual_pid="$(tmux_guard_unsigned_or \
        "$(tmux_guard_tmux display-message -p '#{pid}' 2>/dev/null || true)" 0)"
    [ "$actual_pid" -eq "$expected_pid" ]
}

wait_interval() {
    local expected_pid="$1"
    local remaining="$2"
    local chunk
    while [ "$remaining" -gt 0 ]; do
        kill -0 "$expected_pid" 2>/dev/null || return 1
        chunk=5
        if [ "$remaining" -lt "$chunk" ]; then
            chunk="$remaining"
        fi
        sleep "$chunk" &
        sleep_pid=$!
        wait "$sleep_pid" || true
        sleep_pid=''
        remaining=$((remaining - chunk))
    done
}

run_watcher() {
    local server_pid
    local sleep_pid=''
    cleanup() {
        local recorded_pid
        if [ -n "${sleep_pid:-}" ]; then
            kill "$sleep_pid" 2>/dev/null || true
        fi
        if [ -n "$pid_file" ] && [ -r "$pid_file" ]; then
            recorded_pid="$(tmux_guard_unsigned_or "$(sed -n '1p' "$pid_file")" 0)"
            if [ "$recorded_pid" -eq "$$" ]; then
                rm -f "$pid_file"
            fi
        fi
        recorded_pid="$(tmux_guard_unsigned_or "$(tmux_guard_option @history-guard-watcher-pid '')" 0)"
        if [ "$recorded_pid" -eq "$$" ]; then
            tmux_guard_tmux set-option -gu @history-guard-watcher-pid 2>/dev/null || true
        fi
    }
    trap cleanup EXIT
    trap 'exit 0' INT TERM
    server_pid="$(tmux_guard_unsigned_or "${TMUX_HISTORY_GUARD_SERVER_PID:-}" 0)"
    if [ "$server_pid" -eq 0 ]; then
        server_pid="$(tmux_guard_unsigned_or \
            "$(tmux_guard_tmux display-message -p '#{pid}' 2>/dev/null || true)" 0)"
    fi
    [ "$server_pid" -gt 0 ] || return 1
    printf '%s\n' "$$" > "$pid_file"
    while server_matches "$server_pid"; do
        if [ ! -d "$runtime_dir" ]; then
            initialize_runtime
            printf '%s\n' "$$" > "$pid_file"
            tmux_guard_tmux set-option -gq @history-guard-watcher-pid "$$"
        fi
        "$SCRIPT_DIR/check.sh" --notify || true
        wait_interval "$server_pid" "$(tmux_guard_interval_seconds)" || break
    done
    cleanup
    trap - EXIT
}

stop_watcher() {
    local pid
    local server_pid
    server_pid="$(tmux_guard_unsigned_or \
        "$(tmux_guard_tmux display-message -p '#{pid}' 2>/dev/null || true)" 0)"
    pid="$(tracked_watcher_pid || true)"
    if [ -z "$pid" ]; then
        if [ -n "$pid_file" ]; then
            rm -f "$pid_file"
        fi
        tmux_guard_tmux set-option -gu @history-guard-watcher-pid 2>/dev/null || true
        printf 'tmux-history-guard watcher is not running\n'
        return
    fi
    kill "$pid"
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        watcher_matches "$pid" "$server_pid" || break
        sleep 0.05
    done
    if watcher_matches "$pid" "$server_pid"; then
        printf 'tmux-history-guard watcher did not stop (pid %s)\n' "$pid" >&2
        return 1
    fi
    if [ -n "$pid_file" ]; then
        rm -f "$pid_file"
    fi
    tmux_guard_tmux set-option -gu @history-guard-watcher-pid 2>/dev/null || true
    printf 'tmux-history-guard watcher stopped (pid %s)\n' "$pid"
}

watcher_status() {
    local pid
    pid="$(tracked_watcher_pid || true)"
    if [ -n "$pid" ]; then
        printf 'running pid=%s interval=%ss\n' "$pid" "$(tmux_guard_interval_seconds)"
        return
    fi
    printf 'stopped\n'
    return 1
}

case "${1:-}" in
    start)
        initialize_runtime
        start_watcher
        ;;
    run)
        initialize_runtime
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        TMUX_HISTORY_GUARD_SERVER_PID="$2"
        run_watcher
        ;;
    stop)
        initialize_runtime >/dev/null 2>&1 || true
        stop_watcher
        ;;
    status)
        initialize_runtime >/dev/null 2>&1 || true
        watcher_status
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
