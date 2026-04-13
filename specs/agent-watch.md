# agent-watch

**Path:** `shared/steez/bin/agent-watch`

Manages background watch registrations on AI agent panes. When a watch is registered, the daemon (agent-watch-daemon) polls the target pane and delivers a one-shot notification to the spawner pane when the agent finishes or blocks.

## Interface

```
agent-watch add <pane> [--spawner <pane>] [--label <str>] [--baseline <state>]
agent-watch remove <pane>
agent-watch list
agent-watch daemon-status
```

### Commands

| Command | Description |
|---------|-------------|
| `add <pane>` | Register a watch on `<pane>`. Auto-starts the daemon if not running. |
| `remove <pane>` | Remove the watch on `<pane>`. Also accepts `rm`. |
| `list` | Print the current watchlist. Also accepts `ls`. |
| `daemon-status` | Print whether the daemon is running, its PID, or launchd load state. |

### Options for `add`

| Option | Default | Description |
|--------|---------|-------------|
| `--spawner <pane>` | `$TMUX_PANE` | Pane to notify when the watched pane finishes. |
| `--label <str>` | Auto-inferred via `agent-state` | Short label shown in the notification message. |
| `--baseline <state>` | `working` | Initial state to compare against. Daemon fires when observed state differs from baseline and is terminal. |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (bad args, daemon start failure, missing `$TMUX_PANE`) |

## Output Format

### `add`

```
watching %5 <- %0 (ren, baseline=working)
```

### `remove`

```
removed watch on %5
```

### `list`

One line per active watch:

```
%5  <- %0  [ren]  baseline=working  added=1712984400
```

Or `(no active watches)` if empty.

### `daemon-status`

One of:
- `running pid=12345`
- `loaded stopped` (launchd service loaded but no process)
- `not running`

## Watchlist Format

Each watch is a JSON object appended as a line to `watches.jsonl`:

```json
{
  "pane": "%5",
  "spawner_pane": "%0",
  "baseline_state": "working",
  "label": "ren",
  "added_at": 1712984400
}
```

## Daemon Startup

`ensure_daemon` starts the daemon if not already running, with two strategies:

1. **launchd (macOS):** Writes/updates `~/Library/LaunchAgents/dev.steez.agent-watch-daemon.plist`, bootstraps the service, and kickstarts it. The plist configures `ProcessType: Background`, stdout/stderr logs under `~/.steez/state/`, and a minimal `PATH`.
2. **nohup fallback:** `nohup agent-watch-daemon </dev/null >/dev/null 2>&1 &`.

Both strategies poll `$PIDFILE` up to 20 times at 0.1s intervals to confirm the daemon is ready.

## Idempotent Add

`add` removes any existing watch for the same pane before appending the new entry. This prevents duplicate watches from accumulating. The removal uses `jq` to filter by `.pane`.

## Label Inference

When `--label` is omitted, `infer_label` calls `agent-state <pane>` and extracts the `agent` field. Falls back to the string `"agent"` if detection fails.

## Pane Resolution

All pane arguments are resolved to canonical pane IDs (`%N`) via `tmux display-message -t <raw> -p '#{pane_id}'`. This normalizes `session:window.pane` format to stable IDs.

## State Files

| Path | Purpose |
|------|---------|
| `~/.steez/state/watches.jsonl` | One JSON entry per active watch |
| `~/.steez/state/agent-watch-daemon.pid` | Daemon singleton PID lock |
| `~/.steez/state/agent-watch.log` | Audit trail (written by daemon) |
| `~/Library/LaunchAgents/dev.steez.agent-watch-daemon.plist` | macOS launchd service definition |
| `~/.steez/state/agent-watch-daemon.launchd.out.log` | Daemon stdout (launchd mode) |
| `~/.steez/state/agent-watch-daemon.launchd.err.log` | Daemon stderr (launchd mode) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STEEZ_STATE_DIR` | `~/.steez/state` | State directory for watches, PID file, and logs |

## Dependencies

- `tmux` (pane resolution)
- `jq` (watchlist read/write)
- `agent-state` (label inference)
- `agent-watch-daemon` (started on first `add`)
- `launchctl` (macOS daemon management, optional)

## Integration Points

- **agent-send** calls `agent-watch add` after every successful delivery (unless `--no-watch`).
- **spawn.sh** sends prompts via `agent-send`, which auto-registers watches.
- **agent-watch-daemon** reads `watches.jsonl` and removes entries after firing.

## Behavioral Contracts

1. `add` is idempotent — re-adding the same pane replaces the existing watch entry.
2. `add` auto-starts the daemon. If the daemon fails to start, the watch entry is rolled back (removed).
3. `remove` is safe to call on non-existent watches (no error).
4. `$TMUX_PANE` is required for `add` when `--spawner` is omitted. Exits with error if neither is available.
5. Pane IDs are resolved to canonical `%N` format before storage.
6. The watchlist file is created if absent (`touch`).

## Error Handling

- Daemon start failure: the watch entry is removed and the script exits 1.
- Missing `$TMUX_PANE` without `--spawner`: error to stderr, exit 1.
- `remove` with failed watchlist rewrite: error to stderr, exit 1.
- Pane resolution failure: raw pane string is stored as-is (graceful degradation).
