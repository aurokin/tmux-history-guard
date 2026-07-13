# Agent Instructions

## Commands

- Format: `shfmt -w -i 4 -ci scripts tests tmux-history-guard.tmux` when `shfmt` is available.
- Lint: `shellcheck tmux-history-guard.tmux scripts/*.sh tests/*.sh`.
- Test: `make test`.
- Full check: `make check`.

## Conventions

- Keep the plugin independent of status-line `#(...)` commands.
- Query all pane history metrics in one `tmux list-panes` call per sample.
- Default to notification only. Never clear history, archive terminal contents, or kill a pane without an explicit user command.
- Treat `#{history_bytes}` as tmux-reported history allocation, not process RSS.
- Support the Bash 3.2 shipped by macOS; do not use associative arrays or newer Bash-only syntax.
- Tests that create tmux servers must use an isolated `-L` socket and clean it up.
