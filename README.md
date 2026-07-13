# tmux-history-guard

`tmux-history-guard` makes tmux scrollback memory visible before it destabilizes a long-running server.

tmux's `history-limit` is a line limit. A styled TUI can attach far more memory to a history line than a plain shell, so a pane can stay below its configured line limit while `#{history_bytes}` grows into gigabytes. This plugin samples tmux's own byte metric, identifies the panes responsible, and warns without shortening scrollback or interrupting the process.

## Safety model

- Warning only by default.
- No status-line `#(...)` commands.
- One background watcher per tmux server.
- One `list-panes` query per sample, every five minutes by default.
- No age-based process policy.
- No automatic history clearing.
- Archiving is explicit and never clears history.

`history_bytes` is tmux's estimate of history allocation. It is not the tmux server's resident memory (RSS), but it is the only pane-attributable byte metric tmux exposes.

## Install

With TPM, add the repository to `.tmux.conf`:

```tmux
set -g @plugin 'aurokin/tmux-history-guard'
```

For local development:

```tmux
run-shell '~/code/tmux-history-guard/tmux-history-guard.tmux'
```

Reload tmux, then press `prefix + H` for the live report. tmux 3.2 and newer
opens it in a popup; older versions use a temporary window.

## Configuration

All sizes are bytes.

```tmux
# Defaults shown.
set -g @history-guard-enabled 'on'
set -g @history-guard-interval-seconds '300'
set -g @history-guard-warn-bytes '1073741824'      # 1 GiB
set -g @history-guard-critical-bytes '4294967296'  # 4 GiB
set -g @history-guard-notify 'on'
set -g @history-guard-notify-duration-ms '10000'
set -g @history-guard-key 'H'                      # 'none' disables the binding
```

Ignore a pane without disabling the server-wide monitor:

```sh
tmux set-option -pt '%42' @history-guard-ignore on
```

## Responding to alerts

The report identifies each flagged pane by pane ID and by its human-readable
`session:window.pane`, window name, and current command.

- **Warning:** inspect the pane and plan reclamation before it reaches critical.
- **Critical:** archive important scrollback now, then clear it manually when safe.

```sh
# Preserve a rendered snapshot first when the scrollback matters.
./scripts/archive.sh '%42'

# Reclaim that pane's history only after deciding the scrollback can be discarded.
tmux clear-history -t '%42'
```

Clearing permanently discards the pane's current scrollback. The plugin displays
the command but never runs it automatically.

## Commands

```sh
# One report, sorted by tmux-reported history bytes.
./scripts/report.sh

# Continuously refresh a terminal report. The tmux binding uses this mode.
./scripts/report.sh --watch

# Run one policy check; notifications occur only on threshold escalation.
./scripts/check.sh --notify

# Inspect the watcher.
./scripts/watch.sh status

# Archive rendered scrollback with mode 0600.
./scripts/archive.sh '%42'
```

Archives default to `${XDG_STATE_HOME:-~/.local/state}/tmux-history-guard/archives`. They contain terminal contents and may include secrets, so the directory is mode 0700 and files are mode 0600.

Archives are rendered text snapshots, not raw terminal byte streams. The plugin never clears history: tmux exposes no history version or atomic archive-and-clear operation, so it cannot prove that a capture still matches a busy pane at the destructive boundary. After inspecting an archive, reclamation remains a separate manual `tmux clear-history -t PANE` decision.

## Why a plugin?

tmux can report history bytes and clear an entire pane history, but it cannot enforce a byte ceiling or trim an existing pane to a byte target through its public commands. This plugin is deliberately a mitigation and diagnostic layer:

1. make abnormal growth attributable;
2. warn before the server reaches memory pressure;
3. preserve a rendered snapshot before the user chooses whether to clear;
4. produce evidence for an upstream tmux fix.

See [docs/demo.md](docs/demo.md) for a short demonstration.

## Requirements

- tmux with `#{history_bytes}` support
- Bash 3.2 or newer
- `shlock` (BSD/macOS) or `flock` (Linux) for crash-recoverable locks
- `gzip` for archive creation
- `shellcheck` for development

## Development

```sh
make check
```

Integration tests create an isolated tmux server and never inspect or mutate the user's normal server.
