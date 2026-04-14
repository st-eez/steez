# agent-events

**Status:** Proposed

**Primary Path:** `shared/steez/bin/agent-eventsd`

**Public Surface:** `shared/steez/bin/agent-watch` (unchanged CLI)

Event-driven state and notification service for tmux-managed AI agent panes. Replaces poll-driven completion watching as the primary transport for near-instant notifications. Polling remains only as a deadman recovery path.

## Problem

`agent-watch-daemon` currently polls `agent-state` every 10 seconds. That is correct but slow. It also pays the full cost of snapshot state detection on every cycle: tmux capture, transcript parsing, process inspection, and Codex log heuristics. Near-instant notifications need push-style change detection, but the system still needs one canonical state machine and one canonical notifier.

## Goals

1. Sub-second notification latency for `idle`, `blocked:question`, `blocked:permission`, and `blocked:unknown`.
2. No application lifecycle hooks in the primary path.
3. One canonical transition engine for Claude, Codex, Ren, and Ren-Codex.
4. Preserve current one-shot watch semantics and `baseline=working` behavior.
5. Preserve the no-recursive-loop rule: only the watch service may notify, and it must use `agent-deliver`, never `agent-send`.
6. Keep the current `agent-watch` CLI stable for callers.

## Non-Goals

1. Supporting non-tmux terminals.
2. Replacing `agent-history` transcript reading.
3. Eliminating polling entirely.
4. Building a general terminal event bus beyond agent panes.

## Public Interface

The public CLI stays:

```bash
agent-watch add <pane> [--spawner <pane>] [--label <str>] [--baseline <state>]
agent-watch remove <pane>
agent-watch list
agent-watch daemon-status
```

Callers do not learn new state logic. `agent-send` still registers a watch after a successful delivery. The internal implementation changes from file-backed polling to socket-backed event processing.

## Runtime Components

### 1. `agent-eventsd`

Long-lived per-user daemon. Owns:

- active watch registry
- active pane observers
- current pane state cache
- transition engine
- notification delivery
- slow deadman reconciliation

This daemon is the only component allowed to fire notifications.

### 2. PTY output observer

For each watched pane, the daemon attaches a tmux output tap with `pipe-pane -O`. The tap is not the state engine. It is a wake signal that says, “this pane rendered new output.”

The observer sends a small local event to `agent-eventsd` over a Unix domain socket. The daemon then performs an on-demand `tmux capture-pane` refresh for that pane and runs the screen classifier against the fresh tail content.

This avoids a 10-second blind window without requiring a full terminal emulator in-process.

### 3. Transcript follower

For each watched pane with a discoverable transcript, the daemon tails the transcript file and parses only appended JSONL entries. Transcript events are semantic evidence. They are the fast path for:

- Claude/Ren `idle`
- Claude/Ren `blocked:question`
- Codex/Ren-Codex `idle`
- Codex/Ren-Codex `blocked:question`
- Codex/Ren-Codex transcript-backed `blocked:permission`

Transcript discovery uses the same sources as `agent-state` today:

1. tmux pane metadata when available
2. Claude project transcript lookup by cwd
3. Codex process handle discovery via `lsof`

Transcript discovery is best-effort. Missing transcripts degrade to screen-driven observation plus deadman reconciliation.

### 4. Deadman reconciler

A slow fallback timer runs `agent-state <pane>` only when the event path is degraded or silent too long. It is not the primary notifier.

The deadman path handles:

- observer startup races
- missing transcript discovery
- `pipe-pane` attach failures
- panes that stop emitting output unexpectedly
- daemon restarts that need state rehydration
- foreign `pipe-pane` ownership or observer crashes

Target interval: 5 seconds. Faster than today, but only as backup.

## Event Transport

`agent-eventsd` listens on a local Unix socket:

```text
~/.steez/state/agent-events.sock
```

All internal events are JSON lines. Minimum event types:

- `watch.add`
- `watch.remove`
- `turn.started`
- `pane.output`
- `transcript.append`
- `pane.closed`
- `observer.degraded`
- `deadman.tick`

Observers publish facts. They do not publish notifications.

## State Model

Canonical states remain:

- `working`
- `blocked:question`
- `blocked:permission`
- `blocked:unknown`
- `idle`

The daemon owns the only state machine. Observers contribute evidence.

## Evidence Sources and Precedence

The service merges evidence in this order:

1. **Transcript terminal evidence**
   - authoritative for transcript-visible `idle` and tool-driven blocked states
2. **Screen blocked evidence**
   - authoritative for `blocked:unknown`
   - overrides transcript `working` when the UI is visibly blocked
3. **Screen idle / prompt evidence**
   - used when the transcript lags or is unavailable
4. **Cached state + explicit turn start**
   - preserves `working` between a sent prompt and the next terminal observation
5. **Deadman snapshot**
   - last-resort reconciliation via `agent-state`

This preserves the current layered approach but only runs expensive snapshot reads when the event path cannot prove state on its own.

## Transition Rules

The current transition contract stays unchanged.

A notification fires when:

- `current_state != baseline_state`, and
- `current_state` is terminal:
  - `idle`
  - `blocked:question`
  - `blocked:permission`
  - `blocked:unknown`

After a successful or failed notification attempt, the watch is removed. Watches remain one-shot.

## Notification Delivery Rule

The daemon must call `agent-deliver` directly. It must never call `agent-send`.

Reason: `agent-send` auto-registers watches. If the notifier called `agent-send`, the spawner pane would be re-watched and the system could recurse forever.

This rule applies to the new service exactly as it applies to `agent-watch-daemon` today.

## Turn Start

`pipe-pane -O` only sees pane output. It does not see input.

The service therefore treats turn start as an explicit local event from `agent-send` after a successful delivery:

```text
agent-send -> watch.add + turn.started
```

That event sets the pane's transient state to `working` immediately and removes the race between message submission and the first rendered output.

Manual typing in a pane is still supported. In that case, the pane transitions to `working` on the first transcript append or output wake.

## Cross-Agent Behavior

### Claude / Ren

Primary fast path:

- transcript append for `idle` and `blocked:question`
- PTY wake + screen classifier for `blocked:permission` and `blocked:unknown`

Claude permission prompts are not guaranteed to be present in the transcript at the moment the UI blocks, so screen evidence remains necessary even in the event-driven architecture.

### Codex / Ren-Codex

Primary fast path:

- transcript append for `idle`
- transcript append for `request_user_input` -> `blocked:question`
- transcript append for `sandbox_permissions=require_escalated` -> `blocked:permission`
- PTY wake + screen classifier for anything transcript-invisible or ambiguous

Codex keeps the same semantic parser shape as `agent-state` today. The event-driven system changes when parsing runs, not what parsing means.

## `pipe-pane` Ownership

`pipe-pane` becomes a steez-owned resource for managed agent panes.

Rules:

1. `agent-eventsd` attaches and detaches the pipe.
2. Only one steez observer may own a pane pipe.
3. If a pane already has a non-steez pipe, the daemon marks the pane `degraded` and falls back to deadman reconciliation.
4. A foreign pipe collision never drops the watch. It only drops the fast path.

## Persistence

The daemon persists enough state to survive restart:

- active watches
- pane observer metadata
- last known pane state
- degradation reason

Suggested files:

| Path | Purpose |
|------|---------|
| `~/.steez/state/agent-events.sock` | local RPC socket |
| `~/.steez/state/agent-events.json` | watch + observer snapshot |
| `~/.steez/state/agent-events.log` | structured daemon log |

On startup, the daemon reloads persisted watches, reattaches observers, and runs one reconciliation pass before declaring itself healthy.

## Failure Handling

### Output observer failure

If the PTY tap exits, the pane is marked degraded. The watch stays live. Deadman reconciliation takes over until the observer can be reattached.

### Transcript unavailable

The pane stays observable through PTY wakes and screen classification. If the transcript later becomes discoverable, the daemon attaches the follower without dropping the watch.

### Pane closed or agent exited

The daemon removes the observer, drops any live watches for that pane, and logs the reason.

### Socket unavailable

`agent-watch add` fails fast. It does not silently fall back to a second notification system.

### Daemon crash or restart

Watches are reloaded from persisted state. The daemon runs one `agent-state` reconciliation pass to recover canonical state before rearming fast observers.

## Performance Targets

- p50 notification latency: under 250ms from the first relevant pane output or transcript append
- p95 notification latency: under 1 second
- deadman reconciliation: every 5 seconds for degraded panes only
- zero steady-state `agent-state` polling for healthy panes

## Integration Points

### `agent-watch`

Becomes a thin client that talks to `agent-eventsd` over the Unix socket. `list` and `daemon-status` read daemon state instead of raw JSONL files.

### `agent-send`

After successful delivery:

1. register watch
2. emit `turn.started`

`baseline=working` remains hardcoded.

### `agent-state`

Remains the snapshot oracle and debug tool. It is no longer the primary notification transport. It continues to serve:

- manual inspection
- degraded-mode reconciliation
- startup recovery
- transcript discovery fallback

### `agent-history`

No change. Still used to format blocked detail when the notifier fires.

## Rollout Plan

### Phase 1: Service shell

- add `agent-eventsd`
- move watch registry from JSONL polling into socket-backed daemon state
- keep current poll daemon behavior internally for recovery

### Phase 2: PTY wake path

- attach `pipe-pane -O` per watched pane
- on output wake, run targeted `capture-pane` refresh and screen classification
- notify from event path

### Phase 3: Transcript followers

- tail transcripts incrementally
- update semantic state on append
- eliminate healthy-pane polling

### Phase 4: Recovery mode only

- demote `agent-state` polling to deadman path
- keep one startup reconciliation pass and degraded-pane sweep

## Why This Design

This is the smallest architecture that behaves like an agent product instead of a cron job.

- Hooks are app quirks. This design does not depend on them.
- Full polling is simple but too slow and too expensive.
- A raw `pipe-pane` parser alone is brittle. A transcript tail alone misses UI-only blockers.
- Combining PTY wake signals with transcript semantics gives fast detection without duplicating the notification engine across multiple code paths.

The result is one notifier, one state machine, one delivery rule, and near-instant behavior.
