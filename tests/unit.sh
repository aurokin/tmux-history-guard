#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [ "$expected" = "$actual" ] || fail "$message: expected '$expected', got '$actual'"
}

assert_eq 42 "$(tmux_guard_unsigned_or 42 7)" 'accepts unsigned integers'
assert_eq 7 "$(tmux_guard_unsigned_or nope 7)" 'rejects non-numeric integers'
assert_eq '0 B' "$(tmux_guard_human_bytes 0)" 'formats bytes'
assert_eq '1.0 KiB' "$(tmux_guard_human_bytes 1024)" 'formats KiB'
assert_eq '1.5 GiB' "$(tmux_guard_human_bytes 1610612736)" 'formats fractional GiB'
assert_eq ok "$(tmux_guard_severity 9 10 20)" 'classifies normal usage'
assert_eq warn "$(tmux_guard_severity 10 10 20)" 'classifies warning usage'
assert_eq critical "$(tmux_guard_severity 20 10 20)" 'classifies critical usage'
assert_eq 2 "$(tmux_guard_severity_rank critical)" 'ranks critical severity'
tmux_guard_version_at_least 3.2 3 2 || fail 'accepts the minimum popup version'
tmux_guard_version_at_least 3.10a 3 2 || fail 'compares multi-digit minor versions numerically'
if tmux_guard_version_at_least 3.1c 3 2; then
    fail 'accepts a tmux version below the popup minimum'
fi

printf 'unit tests passed\n'
