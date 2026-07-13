#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

watch_mode=0
watch_seconds=5

usage() {
    printf 'Usage: %s [--watch] [--watch-seconds N]\n' "${0##*/}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --watch) watch_mode=1 ;;
        --watch-seconds)
            shift
            [ "$#" -gt 0 ] || { usage >&2; exit 2; }
            watch_seconds="$(tmux_guard_unsigned_or "$1" 5)"
            [ "$watch_seconds" -gt 0 ] || watch_seconds=5
            ;;
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

render_report() {
    local rows
    local sorted_rows
    local warn
    local critical
    local monitored_total=0
    local ignored_total=0
    local monitored=0
    local ignored=0
    local pane_id session_id window_id pane_index history_size history_limit history_bytes ignore
    local severity display_severity location

    warn="$(tmux_guard_warn_bytes)"
    critical="$(tmux_guard_critical_bytes)"
    rows="$(tmux_guard_history_rows)"
    sorted_rows="$(printf '%s\n' "$rows" | sort -t "$TMUX_HISTORY_GUARD_FIELD_SEPARATOR" -k7,7nr)"

    printf 'tmux history guard\n'
    printf 'warn: %s   critical: %s   sampled: %s\n\n' \
        "$(tmux_guard_human_bytes "$warn")" \
        "$(tmux_guard_human_bytes "$critical")" \
        "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf '%-8s %12s %13s %-7s %s\n' STATUS BYTES HISTORY PANE LOCATION

    while IFS="$TMUX_HISTORY_GUARD_FIELD_SEPARATOR" read -r \
        pane_id session_id window_id pane_index history_size history_limit history_bytes ignore; do
        [ -n "$pane_id" ] || continue
        history_bytes="$(tmux_guard_unsigned_or "$history_bytes" 0)"
        history_size="$(tmux_guard_unsigned_or "$history_size" 0)"
        history_limit="$(tmux_guard_unsigned_or "$history_limit" 0)"
        severity="$(tmux_guard_severity "$history_bytes" "$warn" "$critical")"
        if tmux_guard_is_on "$ignore"; then
            display_severity=ignored
            ignored=$((ignored + 1))
            ignored_total=$((ignored_total + history_bytes))
        else
            display_severity="$severity"
            monitored=$((monitored + 1))
            monitored_total=$((monitored_total + history_bytes))
        fi
        location="${session_id}:${window_id}.${pane_index}"
        printf '%-8s %12s %6d/%-6d %-7s %s\n' \
            "$display_severity" \
            "$(tmux_guard_human_bytes "$history_bytes")" \
            "$history_size" \
            "$history_limit" \
            "$pane_id" \
            "$location"
    done <<< "$sorted_rows"

    printf '\nTotal tmux-reported history: %s across %d monitored pane(s)' \
        "$(tmux_guard_human_bytes "$monitored_total")" "$monitored"
    if [ "$ignored" -gt 0 ]; then
        printf ' (%s across %d ignored)' "$(tmux_guard_human_bytes "$ignored_total")" "$ignored"
    fi
    printf '.\n'
    printf 'This metric is pane history allocation, not tmux server RSS.\n'
}

if [ "$watch_mode" -eq 1 ]; then
    trap 'exit 0' INT TERM
    while true; do
        printf '\033[H\033[2J'
        render_report
        printf '\nRefreshing every %ss. Press Ctrl-C or Escape to close.\n' "$watch_seconds"
        sleep "$watch_seconds"
    done
else
    render_report
fi
