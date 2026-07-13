#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

target=''

usage() {
    printf 'Usage: %s TARGET_PANE\n' "${0##*/}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$target" ]; then
                usage >&2
                exit 2
            fi
            target="$1"
            ;;
    esac
    shift
done

[ -n "$target" ] || { usage >&2; exit 2; }
command -v gzip >/dev/null 2>&1 || { printf 'gzip is required.\n' >&2; exit 1; }

separator="$TMUX_HISTORY_GUARD_FIELD_SEPARATOR"
metadata="$(tmux_guard_tmux display-message -p -t "$target" \
    "#{pane_id}${separator}#{session_id}${separator}#{window_id}${separator}#{pane_index}${separator}#{history_size}${separator}#{history_limit}${separator}#{history_bytes}")"
IFS="$separator" read -r pane_id session_id window_id pane_index history_size history_limit history_bytes <<< "$metadata"
[ -n "$pane_id" ] || { printf 'Pane not found: %s\n' "$target" >&2; exit 1; }

archive_dir="$(tmux_guard_option @history-guard-archive-dir '')"
if [ -z "$archive_dir" ]; then
    archive_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-history-guard/archives"
elif [ "$archive_dir" = '~' ]; then
    archive_dir="$HOME"
elif [ "${archive_dir#\~/}" != "$archive_dir" ]; then
    archive_dir="$HOME/${archive_dir#\~/}"
fi
umask 077
mkdir -p "$archive_dir"

safe_label="$(printf '%s-%s-%s-%s' "${session_id#\$}" "${window_id#@}" "$pane_index" "${pane_id#%}")"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
temporary_path="$(mktemp "$archive_dir/.${timestamp}-${safe_label}.archive.XXXXXX")"
archive_token="${temporary_path##*.}"
archive_path="$archive_dir/${timestamp}-${safe_label}-${archive_token}.txt.gz"
body_path="$(mktemp "$archive_dir/.${timestamp}-${safe_label}.body.XXXXXX")"

cleanup() {
    rm -f "$temporary_path" "$body_path"
}
cancel_archive() {
    cleanup
    trap - INT TERM
    exit 130
}
trap cleanup EXIT
trap cancel_archive INT TERM

tmux_guard_tmux capture-pane -p -S - -t "$pane_id" > "$body_path"
captured_lines="$(wc -l < "$body_path" | tr -d '[:space:]')"

{
    printf '# tmux-history-guard archive\n'
    printf '# created_utc: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# pane_id: %s\n' "$pane_id"
    printf '# location: %s:%s.%s\n' "$session_id" "$window_id" "$pane_index"
    printf '# history_lines: %s/%s\n' "$history_size" "$history_limit"
    printf '# tmux_reported_history_bytes: %s\n' "$history_bytes"
    printf '# rendered_capture_lines: %s\n' "$captured_lines"
    printf '\n'
    command cat "$body_path"
} | gzip -c > "$temporary_path"

gzip -t "$temporary_path"
mv "$temporary_path" "$archive_path"
chmod 600 "$archive_path"
tmux_guard_tmux set-option -gq @history-guard-last-archive "$archive_path"

printf '%s\n' "$archive_path"
