# Demonstration

This demo shows why a line-count limit is not a memory policy.

## 1. Show the current server

```sh
~/code/tmux-history-guard/scripts/report.sh
```

The table compares `history_size`, `history_limit`, and `history_bytes` for every pane. A TUI pane can have fewer history lines than a shell pane while consuming much more tmux-reported history memory.

## 2. Open the tmux-native view

After loading the plugin, press `prefix + H`. The popup refreshes every five seconds while open. Closing it stops the extra sampling; the background guard remains on its five-minute interval.

## 3. Demonstrate threshold escalation safely

Temporarily set the warning threshold below an existing pane:

```sh
tmux set-option -g @history-guard-warn-bytes 1
~/code/tmux-history-guard/scripts/check.sh --notify
```

The guard records and displays the pane responsible, its `session:window.pane`,
window name, current command, and how to respond. Repeating the command does not
spam another warning until severity increases or returns to normal first.

Restore the default:

```sh
tmux set-option -gu @history-guard-warn-bytes
```

## 4. Demonstrate preservation before reclamation

Use a disposable pane for this step:

```sh
~/code/tmux-history-guard/scripts/archive.sh '%42'
```

The command is non-destructive. Inspect the resulting archive before making a separate reclamation decision:

```sh
tmux clear-history -t '%42'
```

The plugin deliberately does not run that command. tmux exposes neither a history version nor an atomic archive-and-clear operation, so a plugin cannot prove that a capture still matches a busy pane when clearing begins.

## Incident that motivated the project

A legitimate agent process ran for approximately 65 hours. Its pane remained below a 10,000-line history limit, but tmux reported roughly 29.7 GB of pane history allocation while the server reached approximately 6.3 GB RSS and eventually crashed under memory pressure. The process lifetime was expected; the missing control was byte-aware scrollback observability.
