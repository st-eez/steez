# agent-send

**Path:** `shared/steez/bin/agent-send`

High-level message delivery to AI agent panes. Wraps `agent-deliver` and auto-registers a completion watch so the spawner gets notified when the agent finishes.

## Interface

```
agent-send [--no-watch] [--label <str>] [--spawner <pane>] [--emit-watch-line] <pane> "message"
```

### Arguments

| Arg | Description |
|-----|-------------|
| `<pane>` | Target pane (`%N` preferred, also `session:window.pane`) |
| `<message>` | Message body. Multi-line: embed real newlines in a quoted string or heredoc. |

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--no-watch` | false | Skip auto-registering a completion watch |
| `--label <str>` | Auto-inferred | Override the watch label |
| `--spawner <pane>` | `$TMUX_PANE` | Override which pane gets the completion notification |
| `--emit-watch-line` | false | Print `WATCHED=<pane> SPAWNER=<pane> BASELINE=working` on success |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Message submitted |
| 1 | Generic error (bad args, send failed) |
| 2 | Pane is not a recognized AI agent |

## Delivery

Delegates to `agent-deliver` for the actual tmux send. The exit code is `agent-deliver`'s exit code.

## Watch Registration

After successful delivery (exit 0), unless `--no-watch`:

1. Calls `agent-watch add <pane> --spawner <spawner> --baseline working`.
2. Baseline is hardcoded to `working` (not observed post-delivery state). This avoids a race: a fast agent can respond and return to idle before any reasonable sleep, making an observed baseline stale.
3. Label is inferred by `agent-watch` via `agent-state` when `--label` is omitted.

### `--emit-watch-line` mode

Watch registration runs synchronously. On success, prints:

```
WATCHED=%5 SPAWNER=%0 BASELINE=working
```

### Default mode

Watch registration runs in a fully detached background subshell (`& disown`). The caller is not blocked. Watch failures are swallowed — delivery is the primary contract.

## Dependencies

- `agent-deliver` (message delivery)
- `agent-watch` (completion watch registration)

## Integration Points

- **spawn.sh** calls `agent-send` with `--emit-watch-line` for prompt delivery after agent boot.
- **spawn-agent SKILL.md** documents `agent-send` as the primary post-spawn messaging tool.
- **agent-watch-daemon** fires notifications to the spawner registered by this script.

## Behavioral Contracts

1. Fire-and-forget from the caller's perspective. Reading the response is the caller's job.
2. Watch registration is best-effort — a failure never fails the delivery.
3. Escape safety: inherits `agent-deliver`'s tmux paste-buffer path. Backticks, `$vars`, quotes survive.
4. When `$TMUX_PANE` is empty and `--spawner` is omitted, watch registration is silently skipped (no error). Delivery still succeeds.
5. Watch baseline is always `working`, regardless of the agent's current state at send time.

## Error Handling

- Missing arguments: error to stderr, exit 1.
- Delivery failure: exit code propagated from `agent-deliver`.
- Watch registration failure: logged (by agent-watch), does not affect exit code.
