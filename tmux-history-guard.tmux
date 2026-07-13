#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$CURRENT_DIR/scripts/lib.sh"

previous_key="$(tmux_guard_option @history-guard-bound-key '')"
if [ -n "$previous_key" ]; then
    previous_binding="$(tmux_guard_tmux list-keys -T prefix 2>/dev/null | awk \
        -v key="$previous_key" -v command="$CURRENT_DIR/scripts/report.sh" '
            {
                for (field = 1; field <= NF - 2; field++) {
                    if ($field == "-T" && $(field + 1) == "prefix" &&
                        $(field + 2) == key && index($0, command)) {
                        print
                    }
                }
            }
        ' || true)"
    if [ -n "$previous_binding" ]; then
        tmux_guard_tmux unbind-key -T prefix "$previous_key"
    fi
    tmux_guard_tmux set-option -gu @history-guard-bound-key 2>/dev/null || true
fi

enabled="$(tmux_guard_option @history-guard-enabled on)"
if ! tmux_guard_is_on "$enabled"; then
    "$CURRENT_DIR/scripts/watch.sh" stop >/dev/null 2>&1 || true
    exit 0
fi

key="$(tmux_guard_option @history-guard-key H)"
if [ "$key" != none ] && [ -n "$key" ]; then
    report_command="$(tmux_guard_shell_quote "$CURRENT_DIR/scripts/report.sh") --watch"
    tmux_version="$(tmux_guard_tmux display-message -p '#{version}')"
    if tmux_guard_version_at_least "$tmux_version" 3 2; then
        tmux_guard_tmux bind-key "$key" display-popup -E -w '90%' -h '70%' \
            "$report_command"
    else
        tmux_guard_tmux bind-key "$key" new-window "$report_command"
    fi
    tmux_guard_tmux set-option -gq @history-guard-bound-key "$key"
fi

socket="$(tmux_guard_socket)"
watch_command="$(tmux_guard_shell_quote "$CURRENT_DIR/scripts/watch.sh") start"
if [ -n "$socket" ]; then
    watch_command="TMUX_HISTORY_GUARD_SOCKET=$(tmux_guard_shell_quote "$socket") $watch_command"
fi
tmux_guard_tmux run-shell -b "$watch_command"
tmux_guard_tmux set-option -gq @history-guard-loaded on
