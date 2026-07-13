#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

notify=0
fail_on_critical=0

usage() {
    printf 'Usage: %s [--notify] [--fail-on-critical]\n' "${0##*/}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --notify) notify=1 ;;
        --fail-on-critical) fail_on_critical=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

cancel_check() {
    tmux_guard_release_runtime_lock
    trap - INT TERM
    exit 130
}

trap tmux_guard_release_runtime_lock EXIT
trap cancel_check INT TERM
tmux_guard_acquire_runtime_lock policy-check

notify_clients() {
    local message="$1"
    local escaped_message
    local duration
    local client
    local delivered=0
    duration="$(tmux_guard_unsigned_or \
        "$(tmux_guard_option @history-guard-notify-duration-ms 10000)" 10000)"
    escaped_message="$(tmux_guard_escape_tmux_format "$message")"
    while IFS= read -r client; do
        [ -n "$client" ] || continue
        if tmux_guard_tmux display-message -d "$duration" -c "$client" "$escaped_message"; then
            delivered=1
        fi
    done < <(tmux_guard_tmux list-clients \
        -F '#{?client_tty,#{client_tty},#{client_name}}' 2>/dev/null || true)
    [ "$delivered" -eq 1 ]
}

report_hint() {
    local key
    key="$(tmux_guard_option @history-guard-key H)"
    if [ -n "$key" ] && [ "$key" != none ]; then
        printf 'Press prefix+%s for next steps.' "$key"
    else
        printf 'Run %s for next steps.' "$SCRIPT_DIR/report.sh"
    fi
}

alert_message() {
    local severity="$1"
    local pane_id="$2"
    local history_bytes="$3"
    printf 'tmux history %s: %s (%s) uses %s. %s' \
        "$severity" \
        "$pane_id" \
        "$(tmux_guard_pane_description "$pane_id")" \
        "$(tmux_guard_human_bytes "$history_bytes")" \
        "$(report_hint)"
}

warn="$(tmux_guard_warn_bytes)"
critical="$(tmux_guard_critical_bytes)"
runtime_dir="$(tmux_guard_runtime_dir)"
mkdir -p "$runtime_dir/panes"
chmod 700 "$runtime_dir" "$runtime_dir/panes"
rows="$(tmux_guard_history_rows)"
total=0
alert_count=0
critical_count=0
active_state_names=''

while IFS="$TMUX_HISTORY_GUARD_FIELD_SEPARATOR" read -r \
    pane_id _session_id _window_id _pane_index _history_size _history_limit history_bytes ignore; do
    [ -n "$pane_id" ] || continue
    history_bytes="$(tmux_guard_unsigned_or "$history_bytes" 0)"
    total=$((total + history_bytes))
    if tmux_guard_is_on "$ignore"; then
        rm -f "$runtime_dir/panes/${pane_id#%}.severity"
        continue
    fi
    active_state_names="${active_state_names}${pane_id#%}"$'\n'
    severity="$(tmux_guard_severity "$history_bytes" "$warn" "$critical")"
    [ "$severity" != critical ] || critical_count=$((critical_count + 1))
    state_file="$runtime_dir/panes/${pane_id#%}.severity"
    previous=ok
    previous_notified=0
    if [ -r "$state_file" ]; then
        IFS=' ' read -r previous _previous_bytes previous_notified < "$state_file" || previous=ok
    fi
    if [ "$(tmux_guard_severity_rank "$severity")" -gt "$(tmux_guard_severity_rank "$previous")" ]; then
        previous_notified=0
        alert_count=$((alert_count + 1))
        message="$(alert_message "$severity" "$pane_id" "$history_bytes")"
        printf '%s\n' "$message"
        tmux_guard_tmux set-option -gq @history-guard-last-alert "$message"
    elif [ "$severity" != ok ] && [ "$previous_notified" != 1 ]; then
        message="$(alert_message "$severity" "$pane_id" "$history_bytes")"
    else
        message=''
    fi
    if [ "$severity" = ok ]; then
        previous_notified=0
    elif [ -n "$message" ] && [ "$notify" -eq 1 ] && \
        tmux_guard_is_on "$(tmux_guard_option @history-guard-notify on)" && \
        notify_clients "$message"; then
        previous_notified=1
    fi
    printf '%s %s %s\n' "$severity" "$history_bytes" "$previous_notified" > "$state_file"
done <<< "$rows"

for state_file in "$runtime_dir"/panes/*.severity; do
    [ -e "$state_file" ] || continue
    state_name="${state_file##*/}"
    state_name="${state_name%.severity}"
    case $'\n'"$active_state_names" in
        *$'\n'"$state_name"$'\n'*) ;;
        *) rm -f "$state_file" ;;
    esac
done

tmux_guard_tmux set-option -gq @history-guard-last-total-bytes "$total"
tmux_guard_tmux set-option -gq @history-guard-last-check "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
tmux_guard_tmux set-option -gq @history-guard-last-alert-count "$alert_count"

if [ "$fail_on_critical" -eq 1 ] && [ "$critical_count" -gt 0 ]; then
    tmux_guard_release_runtime_lock
    trap - EXIT INT TERM
    exit 1
fi
tmux_guard_release_runtime_lock
trap - EXIT INT TERM
