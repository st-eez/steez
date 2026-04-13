# agent-watch-daemon

**Path:** `shared/steez/bin/agent-watch-daemon`

Background singleton daemon that polls watched agent panes and delivers one-shot notifications to spawner panes when agents finish or block.

## Interface

```
agent-watch-daemon
```

No arguments. Launched by `agent-watch add` (via launchd or nohup). Not intended for direct invocation.

## Architectural Rule: No agent-send

The daemon MUST call `agent-deliver` directly. It MUST NOT call `agent-send`. `agent-send` auto-registers a watch after every delivery. If the daemon used `agent-send` to notify a spawner, it would register a watch on the spawner, causing an infinite notification loop. `agent-deliver` exists specifically to break this loop — it has no side effects beyond tmux.

## Singleton Enforcement

On startup, checks `$PIDFILE`. If another daemon's PID is alive (`kill -0`), exits silently (exit 0). If the PID file is stale (process dead), removes the file and claims the role. Writes `$$` to `$PIDFILE` immediately. Cleanup trap removes the PID file on exit.

## Poll Loop

Every `$POLL_INTERVAL` seconds (default 10, configurable via `AGENT_WATCH_POLL`):

1. Read `watches.jsonl`. If empty, increment `empty_cycles`. After `EMPTY_CYCLES_EXIT` consecutive empty cycles (default 3), exit cleanly.
2. Deduplicate snapshot by pane (keep latest entry per pane via `jq group_by`).
3. For each watch entry, call `agent-state <pane>` to read the current state.
4. Apply transition rules.
5. Sleep `$POLL_INTERVAL`.

## Transition Rules

A notification fires when:
- `current_state != baseline_state`, AND
- `current_state` is one of the terminal states: `idle`, `blocked:question`, `blocked:permission`, `blocked:unknown`

The baseline defaults to `working`. A `working -> working` observation is stable (no fire). A `working -> idle` observation fires. Non-working baselines (e.g., `idle -> blocked:question`) also fire.

After firing, the watch entry is removed regardless of delivery success. This is one-shot behavior — a failed delivery (dead spawner pane) is logged and the watch is dropped to prevent looping on a permanently broken target.

## Notification Message Format

```
[agent-watch] %5 @ session:window.pane "Turn Title" (ren) working -> idle
```

Components:
- `%5 @ session:window.pane` — stable pane ID + human-readable address
- `"Turn Title"` — the agent's auto-generated pane title (headline), read at fire time via `agent-state`
- `(ren)` — agent type
- `working -> idle` — state transition

For blocked transitions, a detail suffix is appended:
- `blocked:question` / `blocked:permission` — uses `agent-history --blocked` to extract the pending question or tool call (truncated to 200 chars).
- `blocked:unknown` — static `"unknown blocker"`.

Idle transitions use the pane title as the headline instead of dumping response content.

Headline fallback chain: pane title -> registration label (if not a bare agent name) -> empty.

Messages are prefixed with two newlines for visual separation in the spawner's composer.

## Transient Failure Handling

When `agent-state` returns empty (parse error, window resize race, etc.):

1. **Pane exists + agent process confirmed (rc=0):** Retain the watch. Log a warning every `MAX_STATE_FAILURES` (default 10) consecutive failures.
2. **Pane exists + agent definitively absent (rc=1):** Drop the watch immediately. The agent exited but the shell remains.
3. **Pane exists + agent presence indeterminate (rc=2):** Retain the watch (can't read pane PID or ps snapshot). Log a warning every `MAX_STATE_FAILURES` consecutive failures.
4. **Pane gone:** Drop the watch immediately.

Agent presence is checked via `pane_has_known_agent`, which inspects the pane's process tree (pane PID + first-level children) for `claude`, `codex`, or `node` processes with agent-related command lines.

The failure counter resets to 0 on any successful state read.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_WATCH_POLL` | `10` | Poll interval in seconds |
| `AGENT_WATCH_EMPTY_CYCLES` | `3` | Empty watchlist cycles before auto-exit |
| `AGENT_WATCH_MAX_STATE_FAILURES` | `10` | Log a warning every N consecutive failures (at 10, 20, 30, etc.) |
| `STEEZ_STATE_DIR` | `~/.steez/state` | State directory override |

## State Files

| Path | Purpose |
|------|---------|
| `~/.steez/state/watches.jsonl` | Watchlist (read each cycle, mutated on fire/drop) |
| `~/.steez/state/agent-watch-daemon.pid` | Singleton PID lock |
| `~/.steez/state/agent-watch.log` | Structured log: `timestamp level component event` |

## Watchlist Mutation

`remove_watch` uses atomic write: `jq` filters to a temp file, then `mv` (atomic `rename(2)` on same filesystem). Concurrent readers never see a partially written file.

## Logging

All log entries go to `agent-watch.log` in the format:

```
2026-04-13T12:00:00Z INFO daemon started pid=12345 poll=10s
2026-04-13T12:00:10Z INFO daemon fired spawner=%0 pane=%5 addr=mac:0.1 title="Test done" agent=ren transition=working->idle
2026-04-13T12:00:10Z WARN daemon delivery failed spawner=%0 pane=%5 rc=1 (dropping watch)
```

Key events: `started`, `fired`, `delivery failed`, `exiting`, `stopped`, state-read failures, watch drops.

## Dependencies

- `agent-state` (state reads per pane per cycle)
- `agent-deliver` (notification delivery)
- `agent-history` (blocked detail extraction)
- `tmux` (pane existence check, address resolution, PID lookup)
- `jq` (watchlist parsing, dedup, filtering)
- `python3` (state parsing, title extraction, blocked detail)
- `ps` (agent process detection)

## Integration Points

- **agent-watch** starts this daemon on `add` and checks its status on `daemon-status`.
- **agent-state** is called once per pane per poll cycle.
- **agent-deliver** is called for each notification (never agent-send).
- **agent-history** is called for `blocked:*` detail extraction.

## Behavioral Contracts

1. Singleton: only one instance runs at a time. Second invocations exit silently.
2. One-shot watches: each watch fires at most once, then is removed.
3. Auto-exit: the daemon shuts down after 3 consecutive cycles with an empty watchlist.
4. Delivery failure does not retry — the watch is dropped.
5. The daemon never calls `agent-send`. Violation of this rule causes infinite loops.
6. Watchlist dedup runs every cycle — duplicate entries for the same pane are collapsed.
7. `set -uo pipefail` (not `-e`) — the main loop must not exit on transient subcommand failures.

## Error Handling

- State read failure: tracked per-pane with exponential awareness (log every N failures). Watch retained while pane and agent process exist.
- Pane gone: watch dropped, logged.
- Agent process gone (pane alive): watch dropped, logged.
- Delivery failure: logged as WARN, watch dropped.
- Signal (INT/TERM): clean exit, PID file removed, reason logged.
