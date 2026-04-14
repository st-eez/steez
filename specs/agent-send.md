# agent-send

**Path:** `shared/steez/bin/agent-send`

High-level message delivery to AI agent panes. Wraps `agent-deliver` and drives the two-step turn (`turn.prearm` → deliver → `watch.start`) through `agent-eventsd` so the spawner gets notified when the agent finishes.

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
| `--no-watch` | false | Skip the whole watch wire-up (no prearm, no start) |
| `--label <str>` | Auto-inferred via `agent-state` | Override the watch label |
| `--spawner <pane>` | `$TMUX_PANE` | Override which pane gets the completion notification |
| `--emit-watch-line` | false | Print `WATCHED=<pane> SPAWNER=<pane> BASELINE=working` on success |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Message submitted |
| 1 | Generic error (bad args, send failed) |
| 2 | Pane is not a recognized AI agent |

## Two-step turn

`agent-send` follows the ordering pinned by `specs/agent-events.md` (Watch lifecycle — armed):

1. `agent-eventsd prearm --baseline-state working …` — creates a pending watch and captures the prearm baseline.
2. `agent-deliver <pane> <message>` — delivers the prompt bytes via the tmux paste-buffer recipe.
3. `agent-eventsd start --watch-id <wid>` — promotes the pending watch to armed.

If step 3 fails, `agent-send` does **not** retry it. The watch stays pending and eventually closes with `pending_timeout`. Delivery is the primary contract: watch-wire-up failures never change the exit code.

Baseline is hardcoded to `working`. The semantic intent of every `agent-send` call is "notify me when the agent finishes THIS message", regardless of the pane's state at send time. Observing post-delivery state races — a fast agent can respond and return to idle before any reasonable sleep finishes. `working` is race-free and always correct.

When `--label` is omitted, `agent-send` calls `agent-state <pane>` and uses the `agent` field, falling back to `agent`.

### `--emit-watch-line` mode

On success (delivery OK and start OK), prints:

```
WATCHED=%5 SPAWNER=%0 BASELINE=working
```

If start failed (watch pending), the line is suppressed — callers that rely on the line for orchestration see only armed watches.

## Dependencies

- `agent-deliver` (prompt delivery)
- `agent-eventsd` (prearm, start)
- `agent-state` (label inference)

## Integration Points

- **spawn.sh** calls `agent-send` with `--emit-watch-line` for prompt delivery after agent boot.
- **spawn-agent SKILL.md** documents `agent-send` as the primary post-spawn messaging tool.
- **agent-eventsd** fires notifications via `agent-deliver` to the spawner recorded at prearm time.

## Behavioral Contracts

1. Fire-and-forget from the caller's perspective. Reading the response is the caller's job.
2. Watch wire-up is best-effort — prearm/start failures never fail the delivery.
3. Escape safety: inherits `agent-deliver`'s tmux paste-buffer path. Backticks, `$vars`, quotes survive.
4. When `$TMUX_PANE` is empty and `--spawner` is omitted, watch wire-up is silently skipped (no error). Delivery still succeeds.
5. Watch baseline is always `working`, regardless of the agent's current state at send time.
6. `--no-watch` skips both prearm and start — no prearm baseline is captured and no pending watch is created.

## Error Handling

- Missing arguments: error to stderr, exit 1.
- Delivery failure: exit code propagated from `agent-deliver`.
- Watch wire-up failure: logged (by agent-eventsd), does not affect exit code.
