#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
socket_name="history-guard-test-$$"
archive_root="$(mktemp -d "${TMPDIR:-/tmp}/tmux-history-guard-archive.XXXXXX")"
TMUX_HISTORY_GUARD_SOCKET=''
control_client_pid=''
export TMPDIR="$archive_root/runtime"
mkdir -p "$TMPDIR"

cleanup() {
    if [ -n "$control_client_pid" ]; then
        kill "$control_client_pid" 2>/dev/null || true
    fi
    if [ -n "$TMUX_HISTORY_GUARD_SOCKET" ]; then
        TMUX='' TMUX_HISTORY_GUARD_SOCKET="$TMUX_HISTORY_GUARD_SOCKET" \
            "$ROOT_DIR/scripts/watch.sh" stop >/dev/null 2>&1 || true
    fi
    tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
    rm -rf "$archive_root"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

tmux -L "$socket_name" -f /dev/null new-session -d -s guard -x 80 -y 24
export TMUX_HISTORY_GUARD_SOCKET
TMUX_HISTORY_GUARD_SOCKET="$(tmux -L "$socket_name" display-message -p '#{socket_path}')"
pane_id="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" display-message -p '#{pane_id}')"

tmux -S "$TMUX_HISTORY_GUARD_SOCKET" send-keys -t "$pane_id" -l -- 'seq 1 200'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" send-keys -t "$pane_id" Enter
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    history_size="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" display-message -p -t "$pane_id" '#{history_size}')"
    [ "$history_size" -gt 0 ] && break
    sleep 0.1
done
[ "${history_size:-0}" -gt 0 ] || fail 'fixture did not produce tmux history'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" new-session -d -t guard -s linked

report="$("$ROOT_DIR/scripts/report.sh")"
printf '%s\n' "$report" | grep -F "$pane_id" >/dev/null || fail 'report omitted fixture pane'
pane_row_count="$(printf '%s\n' "$report" | grep -c "[[:space:]]${pane_id}[[:space:]]")"
[ "$pane_row_count" -eq 1 ] || fail 'report double-counted a pane linked into two sessions'
printf '%s\n' "$report" | grep -F 'not tmux server RSS' >/dev/null || fail 'report omitted metric caveat'

tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -pt "$pane_id" @history-guard-ignore on
ignored_report="$("$ROOT_DIR/scripts/report.sh")"
printf '%s\n' "$ignored_report" | grep -F '0 B across 0 monitored pane(s)' >/dev/null || \
    fail 'report attributed ignored bytes to monitored panes'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -pu -t "$pane_id" @history-guard-ignore

tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -g @history-guard-warn-bytes 1
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -g @history-guard-critical-bytes 999999999999
check_output="$("$ROOT_DIR/scripts/check.sh")"
printf '%s\n' "$check_output" | grep -F 'tmux history warn:' >/dev/null || fail 'check omitted threshold escalation'
printf '%s\n' "$check_output" | grep -F 'Press prefix+H for next steps.' >/dev/null || \
    fail 'check warning omitted report guidance'
printf '%s\n' "$check_output" | grep -E ':0\.0 window=.* command=' >/dev/null || \
    fail 'check warning omitted the human-readable pane target'
warning_report="$("$ROOT_DIR/scripts/report.sh")"
printf '%s\n' "$warning_report" | grep -F 'Next steps:' >/dev/null || \
    fail 'warning report omitted next-step guidance'
printf '%s\n' "$warning_report" | grep -F 'archive:' >/dev/null || \
    fail 'warning report omitted archive guidance'
printf '%s\n' "$warning_report" | grep -F 'tmux clear-history -t PANE' >/dev/null || \
    fail 'warning report omitted manual reclamation guidance'
second_check="$("$ROOT_DIR/scripts/check.sh")"
[ -z "$second_check" ] || fail 'check repeated an unchanged warning'
runtime_dir="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-runtime-dir)"
runtime_mode="$(file_mode "$runtime_dir")"
[ "$runtime_mode" = 700 ] || fail 'runtime directory permissions are not 0700'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -pt "$pane_id" @history-guard-ignore on
"$ROOT_DIR/scripts/check.sh" >/dev/null
[ ! -e "$runtime_dir/panes/${pane_id#%}.severity" ] || fail 'ignored pane retained alert state'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -pu -t "$pane_id" @history-guard-ignore
unignored_check="$("$ROOT_DIR/scripts/check.sh")"
printf '%s\n' "$unignored_check" | grep -F 'tmux history warn:' >/dev/null || \
    fail 'unignored pane did not produce a fresh warning'
rm -f "$runtime_dir/panes/${pane_id#%}.severity"
"$ROOT_DIR/scripts/check.sh" > "$TMPDIR/concurrent-check-1.out" &
"$ROOT_DIR/scripts/check.sh" > "$TMPDIR/concurrent-check-2.out" &
"$ROOT_DIR/scripts/check.sh" > "$TMPDIR/concurrent-check-3.out" &
"$ROOT_DIR/scripts/check.sh" > "$TMPDIR/concurrent-check-4.out" &
wait
concurrent_alerts="$(awk '/tmux history warn:/{ count++ } END { print count + 0 }' \
    "$TMPDIR"/concurrent-check-*.out)"
[ "$concurrent_alerts" -eq 1 ] || fail 'concurrent checks emitted duplicate escalation alerts'
rm -rf "$runtime_dir"
"$ROOT_DIR/scripts/check.sh" >/dev/null
recovered_runtime_dir="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-runtime-dir)"
[ -d "$recovered_runtime_dir" ] || fail 'replacement runtime directory was not created'

printf '99999999\n' > "$recovered_runtime_dir/policy-check.lock"
"$ROOT_DIR/scripts/check.sh" >/dev/null

sleep 10 | tmux -S "$TMUX_HISTORY_GUARD_SOCKET" -C attach-session -f no-output -t guard \
    >/dev/null 2>&1 &
control_client_pid=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    client_count="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" list-clients -F '#{client_name}' | wc -l | tr -d '[:space:]')"
    [ "$client_count" -gt 0 ] && break
    sleep 0.1
done
[ "${client_count:-0}" -gt 0 ] || fail 'control client did not attach for notification test'
"$ROOT_DIR/scripts/check.sh" --notify >/dev/null
IFS=' ' read -r _severity _bytes notified < "$recovered_runtime_dir/panes/${pane_id#%}.severity"
[ "$notified" = 1 ] || fail 'detached threshold alert was not delivered after a client attached'
kill "$control_client_pid" 2>/dev/null || true
control_client_pid=''

chmod 755 "$archive_root"
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -g @history-guard-archive-dir "$archive_root"
archive_path="$("$ROOT_DIR/scripts/archive.sh" "$pane_id")"
[ -f "$archive_path" ] || fail 'archive file was not created'
gzip -t "$archive_path" || fail 'archive is not valid gzip data'
archive_mode="$(file_mode "$archive_path")"
[ "$archive_mode" = 600 ] || fail 'archive permissions are not 0600'
archive_dir_mode="$(file_mode "$archive_root")"
[ "$archive_dir_mode" = 755 ] || fail 'archive changed permissions on an existing directory'
lines_before_clear="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" display-message -p -t "$pane_id" '#{history_size}')"
[ "$lines_before_clear" -gt 0 ] || fail 'non-destructive archive cleared history'

second_archive="$("$ROOT_DIR/scripts/archive.sh" "$pane_id")"
[ -f "$second_archive" ] || fail 'second archive file was not created'
[ "$second_archive" != "$archive_path" ] || fail 'concurrent-safe archive naming reused a path'
[ -f "$archive_path" ] || fail 'second archive overwrote the earlier archive'
if "$ROOT_DIR/scripts/archive.sh" --clear "$pane_id" >/dev/null 2>&1; then
    fail 'archive script exposed a destructive clear flag'
fi
lines_after_archives="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" display-message -p -t "$pane_id" '#{history_size}')"
[ "$lines_after_archives" -gt 0 ] || fail 'archive command cleared history'

watcher_process_count() {
    pgrep -f "$ROOT_DIR/scripts/watch.sh run" 2>/dev/null | awk 'END { print NR }' || true
}
watchers_before="$(watcher_process_count)"
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -g @history-guard-enabled off
"$ROOT_DIR/scripts/watch.sh" start >/dev/null
watchers_while_disabled="$(watcher_process_count)"
[ "$watchers_while_disabled" -eq "$watchers_before" ] || fail 'disabled plugin started a watcher'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -g @history-guard-enabled on
active_runtime_dir="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-runtime-dir)"
printf '99999999\n' > "$active_runtime_dir/watcher-start.lock"
"$ROOT_DIR/scripts/watch.sh" start >/dev/null &
"$ROOT_DIR/scripts/watch.sh" start >/dev/null &
"$ROOT_DIR/scripts/watch.sh" start >/dev/null &
"$ROOT_DIR/scripts/watch.sh" start >/dev/null &
wait
watchers_after="$(watcher_process_count)"
[ "$((watchers_after - watchers_before))" -eq 1 ] || \
    fail "concurrent starts launched multiple watchers (before=$watchers_before after=$watchers_after)"
concurrent_watcher_pid="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-watcher-pid)"
active_runtime_dir="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-runtime-dir)"
chmod 755 "$active_runtime_dir"
"$ROOT_DIR/scripts/watch.sh" status | grep -F "running pid=$concurrent_watcher_pid" >/dev/null || \
    fail 'status could not manage the watcher after runtime mode drift'
healed_runtime_mode="$(file_mode "$active_runtime_dir")"
[ "$healed_runtime_mode" = 700 ] || fail 'runtime mode drift was not repaired'
rm -rf "$active_runtime_dir"
"$ROOT_DIR/scripts/watch.sh" status | grep -F "running pid=$concurrent_watcher_pid" >/dev/null || \
    fail 'status lost the live watcher after runtime directory removal'
"$ROOT_DIR/scripts/watch.sh" stop >/dev/null
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$concurrent_watcher_pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$concurrent_watcher_pid" 2>/dev/null && fail 'stop lost the live watcher after runtime directory removal'

TMUX="$TMUX_HISTORY_GUARD_SOCKET,$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" display-message -p '#{pid}'),0" \
    "$ROOT_DIR/tmux-history-guard.tmux"
sleep 0.2
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-loaded | grep -Fx on >/dev/null || fail 'plugin did not mark itself loaded'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" list-keys -T prefix | grep -F "$ROOT_DIR/scripts/report.sh" >/dev/null || \
    fail 'plugin did not install its configured key binding'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" bind-key -T prefix H display-message 'user replacement'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" bind-key -T prefix J run-shell "$ROOT_DIR/scripts/report.sh"
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" set-option -g @history-guard-key none
TMUX="$TMUX_HISTORY_GUARD_SOCKET,$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" display-message -p '#{pid}'),0" \
    "$ROOT_DIR/tmux-history-guard.tmux"
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" list-keys -T prefix | grep -F 'user replacement' >/dev/null || \
    fail 'plugin removed a user replacement on its previously bound key'
tmux -S "$TMUX_HISTORY_GUARD_SOCKET" unbind-key -T prefix J
"$ROOT_DIR/scripts/watch.sh" status | grep -F 'running pid=' >/dev/null || fail 'watcher did not start'
watcher_pid="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-watcher-pid)"
"$ROOT_DIR/scripts/watch.sh" stop >/dev/null
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$watcher_pid" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$watcher_pid" 2>/dev/null && fail 'watcher remained alive after stop'

"$ROOT_DIR/scripts/watch.sh" start >/dev/null
replacement_test_pid="$(tmux -S "$TMUX_HISTORY_GUARD_SOCKET" show-option -gqv @history-guard-watcher-pid)"
tmux -L "$socket_name" kill-server
tmux -L "$socket_name" -f /dev/null new-session -d -s replacement -x 80 -y 24
TMUX_HISTORY_GUARD_SOCKET="$(tmux -L "$socket_name" display-message -p '#{socket_path}')"
for _attempt in 1 2 3 4 5 6 7; do
    kill -0 "$replacement_test_pid" 2>/dev/null || break
    sleep 1
done
kill -0 "$replacement_test_pid" 2>/dev/null && fail 'watcher survived replacement of its tmux server'

printf 'integration tests passed\n'
