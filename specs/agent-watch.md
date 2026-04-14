# agent-watch

**Path:** `shared/steez/bin/agent-watch`

Public CLI for the event-driven watch service (`agent-eventsd`). Registers, lists, and removes background watches on AI agent panes. Every subcommand routes to the running `agent-eventsd` service (spec: agent-events — Runtime shape); `agent-watch-daemon` is no longer part of the primary path.

The first `agent-watch` invocation that finds no running `agent-eventsd` service triggers auto-start through the client command it issues. `agent-watch` itself never runs watch logic in-process and never mutates state under `$STEEZ_STATE_DIR/eventsd/` directly.

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
| `add <pane>` | Emit `turn.prearm` then `watch.start` immediately, leaving the pane with one armed watch. Also accepts the manual-add form of the two-step turn. |
| `remove <pane>` | Close the live watch on `<pane>`. Also accepts `rm`. No-op when no watch exists. |
| `list` | Print the current live watchlist. Also accepts `ls`. |
| `daemon-status` | Report agent-eventsd health. |

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
| 1 | Error (bad args, prearm/start failure, missing `$TMUX_PANE`) |

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

One line per live (pending or armed) watch:

```
%5  <- %0  [ren]  baseline=working  state=armed
```

Or `(no active watches)` if empty. Draining watches (resolved/delivering/delivery_failed) are not printed — they are transient and not user-actionable.

### `daemon-status`

Prints `agent-eventsd: <status>` where `<status>` reflects liveness and health of the `agent-eventsd` service (spec: agent-events — Daemon status):

- `ready` — the service process is running, accepting client requests, and its state directory is writable.
- `unavailable` — any of those conditions fails, including when no service is running.

"State directory exists and is writable" alone is not `ready`. The probe must prove the service itself is alive.

## Manual-Add Ordering

`add` uses the same two-step turn as `agent-send`, but `watch.start` follows `turn.prearm` immediately — no prompt bytes land in between. Both calls run synchronously so the caller's exit code reflects wire-up success. If `watch.start` fails, the watch stays pending and is closed by the pending-timeout path downstream.

A second `add` on the same pane supersedes any live watch: the prior watch closes with `close_reason=superseded` without delivery (spec: Live and draining watches).

## Label Inference

When `--label` is omitted, `infer_label` calls `agent-state <pane>` and extracts the `agent` field. Falls back to the string `agent` if detection fails.

## Pane Resolution

Pane arguments are resolved to canonical pane IDs (`%N`) via `tmux display-message -t <raw> -p '#{pane_id}'`. This normalizes `session:window.pane` format to stable IDs. Resolution failure degrades gracefully — the raw string is forwarded as-is.

## State

All watch state lives under `$STEEZ_STATE_DIR/eventsd/` and is owned by `agent-eventsd`. `agent-watch` itself persists nothing.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STEEZ_STATE_DIR` | `~/.steez/state` | State directory (passed through to agent-eventsd). |

## Dependencies

- `tmux` (pane resolution)
- `jq` (list formatting)
- `agent-state` (label inference)
- `agent-eventsd` (prearm, start, remove, list, status)

## Integration Points

- **agent-send** calls `agent-eventsd` directly for the two-step turn. It does not shell out to `agent-watch`.
- **spawn.sh** sends prompts via `agent-send`; manual `agent-watch add` remains available for ad-hoc watches.
- **agent-eventsd** is the only component allowed to notify — it calls `agent-deliver`, never `agent-send`.

## Behavioral Contracts

1. `add` is idempotent via supersession — re-adding the same pane closes the prior watch and installs a new one.
2. `add` requires either `$TMUX_PANE` or `--spawner`; errors out otherwise.
3. `remove` is safe to call on non-existent watches (no error, exit 0).
4. Pane IDs are resolved to canonical `%N` format before events are emitted.
5. `agent-watch-daemon` is never spawned by any subcommand.

## Error Handling

- `prearm` or `start` failure in `add`: error to stderr, exit 1. No on-disk rollback needed — failed `start` leaves the pending watch to time out.
- Missing `$TMUX_PANE` without `--spawner`: error to stderr, exit 1.
- Unknown subcommand or flag: error to stderr, exit 1.
