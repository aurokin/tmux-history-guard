#!/usr/bin/env bash

TMUX_HISTORY_GUARD_FIELD_SEPARATOR=$'\037'
TMUX_HISTORY_GUARD_DEFAULT_WARN_BYTES=1073741824
TMUX_HISTORY_GUARD_DEFAULT_CRITICAL_BYTES=4294967296
TMUX_HISTORY_GUARD_DEFAULT_INTERVAL_SECONDS=300
TMUX_HISTORY_GUARD_MIN_INTERVAL_SECONDS=30

tmux_guard_socket() {
    if [ -n "${TMUX_HISTORY_GUARD_SOCKET:-}" ]; then
        printf '%s\n' "$TMUX_HISTORY_GUARD_SOCKET"
    elif [ -n "${TMUX:-}" ]; then
        printf '%s\n' "${TMUX%%,*}"
    fi
}

tmux_guard_tmux() {
    local socket
    socket="$(tmux_guard_socket)"
    if [ -n "$socket" ]; then
        "${TMUX_BIN:-tmux}" -S "$socket" "$@"
    else
        "${TMUX_BIN:-tmux}" "$@"
    fi
}

tmux_guard_option() {
    local option="$1"
    local fallback="$2"
    local value
    value="$(tmux_guard_tmux show-option -gqv "$option" 2>/dev/null || true)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$fallback"
    fi
}

tmux_guard_is_on() {
    case "${1:-}" in
        1 | on | true | yes) return 0 ;;
        *) return 1 ;;
    esac
}

tmux_guard_version_at_least() {
    local version="$1"
    local required_major="$2"
    local required_minor="$3"
    local major
    local remainder
    local minor
    major="${version%%.*}"
    remainder="${version#*.}"
    minor="${remainder%%[!0-9]*}"
    major="$(tmux_guard_unsigned_or "$major" 0)"
    minor="$(tmux_guard_unsigned_or "$minor" 0)"
    [ "$major" -gt "$required_major" ] || {
        [ "$major" -eq "$required_major" ] && [ "$minor" -ge "$required_minor" ]
    }
}

tmux_guard_unsigned_or() {
    local value="$1"
    local fallback="$2"
    case "$value" in
        '' | *[!0-9]*) printf '%s\n' "$fallback" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

tmux_guard_warn_bytes() {
    tmux_guard_unsigned_or \
        "$(tmux_guard_option @history-guard-warn-bytes "$TMUX_HISTORY_GUARD_DEFAULT_WARN_BYTES")" \
        "$TMUX_HISTORY_GUARD_DEFAULT_WARN_BYTES"
}

tmux_guard_critical_bytes() {
    tmux_guard_unsigned_or \
        "$(tmux_guard_option @history-guard-critical-bytes "$TMUX_HISTORY_GUARD_DEFAULT_CRITICAL_BYTES")" \
        "$TMUX_HISTORY_GUARD_DEFAULT_CRITICAL_BYTES"
}

tmux_guard_interval_seconds() {
    local interval
    interval="$(tmux_guard_unsigned_or \
        "$(tmux_guard_option @history-guard-interval-seconds "$TMUX_HISTORY_GUARD_DEFAULT_INTERVAL_SECONDS")" \
        "$TMUX_HISTORY_GUARD_DEFAULT_INTERVAL_SECONDS")"
    if [ "$interval" -lt "$TMUX_HISTORY_GUARD_MIN_INTERVAL_SECONDS" ]; then
        interval="$TMUX_HISTORY_GUARD_MIN_INTERVAL_SECONDS"
    fi
    printf '%s\n' "$interval"
}

tmux_guard_history_rows() {
    local separator="$TMUX_HISTORY_GUARD_FIELD_SEPARATOR"
    local format
    local rows
    # Keep the machine record to tmux-generated IDs, integers, and a normalized
    # boolean. User-controlled names and commands cannot corrupt its framing.
    format="#{pane_id}${separator}#{session_id}${separator}#{window_id}${separator}#{pane_index}${separator}#{history_size}${separator}#{history_limit}${separator}#{history_bytes}${separator}#{?#{||:#{==:#{@history-guard-ignore},on},#{==:#{@history-guard-ignore},1}},1,0}"
    rows="$(tmux_guard_tmux list-panes -a -F "$format")" || return 1
    # Linked windows appear once per session in `list-panes -a`; pane IDs are
    # server-unique, so retain one row to avoid double-counting their memory.
    printf '%s\n' "$rows" | awk -F "$separator" '!seen[$1]++'
}

tmux_guard_human_bytes() {
    local bytes
    local unit
    local label
    local whole
    local tenth
    bytes="$(tmux_guard_unsigned_or "${1:-}" 0)"
    unit=1
    label=B
    if [ "$bytes" -ge 1099511627776 ]; then
        unit=1099511627776
        label=TiB
    elif [ "$bytes" -ge 1073741824 ]; then
        unit=1073741824
        label=GiB
    elif [ "$bytes" -ge 1048576 ]; then
        unit=1048576
        label=MiB
    elif [ "$bytes" -ge 1024 ]; then
        unit=1024
        label=KiB
    fi
    if [ "$unit" -eq 1 ]; then
        printf '%d %s' "$bytes" "$label"
        return
    fi
    whole=$((bytes / unit))
    tenth=$(((bytes % unit) * 10 / unit))
    printf '%d.%d %s' "$whole" "$tenth" "$label"
}

tmux_guard_severity() {
    local bytes="$1"
    local warn="$2"
    local critical="$3"
    if [ "$bytes" -ge "$critical" ]; then
        printf 'critical\n'
    elif [ "$bytes" -ge "$warn" ]; then
        printf 'warn\n'
    else
        printf 'ok\n'
    fi
}

tmux_guard_severity_rank() {
    case "${1:-ok}" in
        critical) printf '2\n' ;;
        warn) printf '1\n' ;;
        *) printf '0\n' ;;
    esac
}

tmux_guard_runtime_dir() {
    local runtime_dir
    local runtime_base
    local candidate_dir
    local owner
    local mode
    local old_umask
    runtime_dir="$(tmux_guard_option @history-guard-runtime-dir '')"
    if [ -n "$runtime_dir" ] && [ ! -e "$runtime_dir" ] && [ ! -L "$runtime_dir" ]; then
        old_umask="$(umask)"
        umask 077
        mkdir "$runtime_dir" 2>/dev/null || true
        umask "$old_umask"
    fi
    if [ -z "$runtime_dir" ]; then
        runtime_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
        old_umask="$(umask)"
        umask 077
        candidate_dir="$(mktemp -d "$runtime_base/tmux-history-guard-${UID:-$(id -u)}.XXXXXX")"
        umask "$old_umask"
        tmux_guard_tmux set-option -goq @history-guard-runtime-dir "$candidate_dir" 2>/dev/null || true
        runtime_dir="$(tmux_guard_option @history-guard-runtime-dir '')"
        if [ "$runtime_dir" != "$candidate_dir" ]; then
            rmdir "$candidate_dir" 2>/dev/null || true
        fi
    fi
    if [ -L "$runtime_dir" ] || [ ! -d "$runtime_dir" ]; then
        printf 'tmux-history-guard: insecure runtime path: %s\n' "$runtime_dir" >&2
        return 1
    fi
    if owner="$(stat -c '%u' "$runtime_dir" 2>/dev/null)" &&
        mode="$(stat -c '%a' "$runtime_dir" 2>/dev/null)"; then
        :
    elif owner="$(stat -f '%u' "$runtime_dir" 2>/dev/null)" &&
        mode="$(stat -f '%Lp' "$runtime_dir" 2>/dev/null)"; then
        :
    else
        printf 'tmux-history-guard: cannot inspect runtime path: %s\n' "$runtime_dir" >&2
        return 1
    fi
    if [ "$owner" != "${UID:-$(id -u)}" ]; then
        printf 'tmux-history-guard: runtime path must be owned by the current user: %s\n' \
            "$runtime_dir" >&2
        return 1
    fi
    if [ "$mode" != 700 ]; then
        chmod 700 "$runtime_dir"
    fi
    printf '%s\n' "$runtime_dir"
}

TMUX_HISTORY_GUARD_LOCK_BACKEND=''
TMUX_HISTORY_GUARD_LOCK_FILE=''

tmux_guard_acquire_runtime_lock() {
    local name="$1"
    local runtime_dir
    local lock_file
    local attempt=1
    runtime_dir="$(tmux_guard_runtime_dir)" || return 1
    lock_file="$runtime_dir/${name}.lock"
    if command -v shlock >/dev/null 2>&1; then
        while [ "$attempt" -le 200 ]; do
            if shlock -f "$lock_file" -p "$$" 2>/dev/null; then
                TMUX_HISTORY_GUARD_LOCK_BACKEND=shlock
                TMUX_HISTORY_GUARD_LOCK_FILE="$lock_file"
                return
            fi
            attempt=$((attempt + 1))
            sleep 0.05
        done
    elif command -v flock >/dev/null 2>&1; then
        # Bash 3.2 lacks dynamic file descriptors, so reserve fd 9 while a
        # plugin script holds its single, non-nested policy lock.
        exec 9>"$lock_file"
        if flock -x -w 10 9; then
            TMUX_HISTORY_GUARD_LOCK_BACKEND=flock
            TMUX_HISTORY_GUARD_LOCK_FILE="$lock_file"
            return
        fi
        exec 9>&-
    else
        printf 'tmux-history-guard: shlock or flock is required for safe locking\n' >&2
        return 1
    fi
    printf 'tmux-history-guard: timed out acquiring %s lock\n' "$name" >&2
    return 1
}

tmux_guard_release_runtime_lock() {
    local owner_pid
    case "$TMUX_HISTORY_GUARD_LOCK_BACKEND" in
        shlock)
            owner_pid="$(tmux_guard_unsigned_or \
                "$(sed -n '1p' "$TMUX_HISTORY_GUARD_LOCK_FILE" 2>/dev/null || true)" 0)"
            if [ "$owner_pid" -eq "$$" ]; then
                rm -f "$TMUX_HISTORY_GUARD_LOCK_FILE"
            fi
            ;;
        flock)
            flock -u 9 2>/dev/null || true
            exec 9>&-
            ;;
    esac
    TMUX_HISTORY_GUARD_LOCK_BACKEND=''
    TMUX_HISTORY_GUARD_LOCK_FILE=''
}

tmux_guard_shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}
