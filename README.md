# tmux-history-guard (deprecated)

> [!IMPORTANT]
> This project is deprecated. The incident that motivated it was caused by
> tmux repeatedly allocating extended cells while TUIs such as Codex redrew the
> visible grid. The underlying bug is fixed in tmux 3.7b. Do not install this
> plugin on tmux 3.7b or newer; upgrade tmux instead.

`tmux-history-guard` was built to diagnose a long-running Codex pane that
remained below its configured `history-limit` while `#{history_bytes}` and the
tmux server's resident memory grew rapidly.

## Resolution

The investigation showed that `#{history_bytes}` includes both scrollback and
the visible grid. On tmux 3.6b, repeated RGB clear operations could continually
append unreachable extended-cell entries to the visible rows. Consequently,
`clear-history` removed the scrollback but did not reclaim the allocation that
caused the incident.

The upstream fixes reuse extended-cell entries instead of allocating new ones
on every redraw and are included in tmux 3.7b:

- [Reuse extended entries when clearing RGB cells](https://github.com/tmux/tmux/commit/fedd4440f0760ba55a0aff2f917ccc033b930ade)
- [Reuse extended entries for non-RGB clears](https://github.com/tmux/tmux/commit/0310404155701d9e03b7db166e8f17f180cc09d3)
- [Preserve correctness when cleared cells have moved](https://github.com/tmux/tmux/commit/4b0ff07bcbc86bb0312dfb8c6f82ec55a184476f)

The repository remains available as a historical diagnostic for older tmux
servers, but it is no longer recommended as an always-on plugin.

## Safety model

- Warning only by default.
- No status-line `#(...)` commands.
- One background watcher per tmux server.
- One `list-panes` query per sample, every five minutes by default.
- No age-based process policy.
- No automatic history clearing.
- Archiving is explicit and never clears history.

`history_bytes` is tmux's estimate of history allocation. It is not the tmux server's resident memory (RSS), but it is the only pane-attributable byte metric tmux exposes.

## Historical installation

Installation is not recommended. If an older tmux server cannot yet be
restarted or upgraded, TPM can still load the diagnostic:

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

## Responding to alerts on older servers

The report identifies each flagged pane by pane ID and by its human-readable
`session:window.pane`, window name, and current command.

- **Warning:** identify the pane and verify the tmux server version.
- **Critical:** upgrade to tmux 3.7b or newer and restart the server when the
  running processes can be safely stopped or migrated.

```sh
# Preserve a rendered snapshot first when the scrollback matters.
./scripts/archive.sh '%42'

# This removes scrollback, but it does not repair visible-grid extended-cell
# growth in an already-running tmux 3.6b server.
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

## Why the plugin existed

tmux can report grid allocation and clear an entire pane history, but it cannot
trim an existing pane to a byte target. This plugin provided a diagnostic layer
while the root cause was being established:

1. make abnormal growth attributable;
2. distinguish line-count history from byte growth;
3. preserve a rendered snapshot before destructive experiments;
4. produce evidence for the upstream tmux fix.

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
