# agent-events

**Status:** Proposed

**Primary Path:** `shared/steez/bin/agent-eventsd`

**Public Surface:** `shared/steez/bin/agent-watch` (unchanged CLI)

Event-driven state and notification service for tmux-managed AI agent panes. It replaces poll-driven completion watching as the primary transport for near-instant notifications. Polling remains as a recovery path for degraded, silent, or restarting observers.

## Problem

`agent-watch-daemon` currently polls `agent-state` every 10 seconds. That is correct but slow. It also pays the full cost of snapshot state detection on every cycle: tmux capture, transcript parsing, process inspection, and Codex log heuristics. Near-instant notifications need push-style change detection, but the system still needs one canonical state machine and one canonical notifier.

## Goals

1. Sub-second notification latency for `idle`, `blocked:question`, `blocked:permission`, and `blocked:unknown` on healthy watched panes.
2. No application lifecycle hooks in the primary path.
3. One canonical transition engine for Claude, Codex, Ren, and Ren-Codex.
4. Preserve current one-shot watch semantics and `baseline=working` behavior.
5. Preserve the no-recursive-loop rule: only the watch service may notify, and it must use `agent-deliver`, never `agent-send`.
6. Keep the current `agent-watch` CLI stable for callers.
7. Make the spec self-contained enough for TDD. No hidden "same as today" contracts.

## Non-Goals

1. Supporting non-tmux terminals.
2. Replacing `agent-history` transcript reading.
3. Eliminating polling entirely.
4. Building a general terminal event bus beyond agent panes.
5. Supporting fan-out watches from multiple callers on the same pane.

## Core Invariants

1. **One active turn per pane.** A pane has at most one active watch-owned turn.
2. **One active watch per pane.** A second manual `agent-watch add` on the same pane fails with `already watched`. A new `agent-send` on the same pane supersedes the old watch and starts a new turn.
3. **All evidence is turn-scoped.** Evidence that cannot be proven newer than the current turn is ignored.
4. **No silent loss.** A pane close, daemon restart, observer failure, or delivery failure must end in a visible watch outcome, not a dropped watch.
5. **Exactly one logical notification per watch.** The daemon may retry delivery, but retries must carry the same `watch_id` and be idempotent at the delivery boundary.
6. **Fast paths accelerate state.** They do not create alternate state machines.

## Public Interface

The public CLI stays:

```bash
agent-watch add <pane> [--spawner <pane>] [--label <str>] [--baseline <state>]
agent-watch remove <pane>
agent-watch list
agent-watch daemon-status
```

Callers do not learn new state logic. `agent-send` still arms a watch after a successful delivery. The internal implementation changes from file-backed polling to socket-backed event processing.

## Internal RPC Contract

`agent-eventsd` listens on a local Unix socket:

```text
~/.steez/state/agent-events.sock
```

All internal events are JSON lines with this envelope:

```json
{
  "event_id": "uuid",
  "type": "watch.start | watch.remove | pane.output | transcript.append | pane.closed | observer.degraded | deadman.tick | delivery.result",
  "pane_id": "%12",
  "turn_id": "uuid-or-null",
  "seq": 123,
  "observed_at_monotonic_ns": 1234567890,
  "payload": {}
}
```

Rules:

1. `seq` is monotonic per pane and assigned by the daemon.
2. `watch.start` is atomic. There is no separate `turn.started` event.
3. `pane.output` and `transcript.append` are observer facts. They never mutate watch state directly.
4. `delivery.result` records the outcome of `agent-deliver` for a specific `watch_id`.

Minimum payloads:

- `watch.start`
  - `watch_id`
  - `baseline_state`
  - `spawner_pane`
  - `label`
  - `started_at_monotonic_ns`
  - `screen_epoch`
  - `transcript_cursor` per discovered transcript source
- `watch.remove`
  - `watch_id`
  - `reason`
- `pane.output`
  - `capture_started_at_monotonic_ns`
  - `screen_epoch`
- `transcript.append`
  - `source_path`
  - `source_dev`
  - `source_inode`
  - `start_offset`
  - `end_offset`
- `observer.degraded`
  - `reason`
  - `observer_type`
- `deadman.tick`
  - `reason`
- `delivery.result`
  - `watch_id`
  - `attempt`
  - `status`
  - `exit_code`

## Runtime Components

### 1. `agent-eventsd`

Long-lived per-user daemon. Owns:

- active watch registry
- active pane observers
- current pane turn cache
- canonical transition engine
- notification delivery journal
- slow deadman reconciliation

This daemon is the only component allowed to fire notifications.

### 2. PTY output observer

For each watched pane, the daemon attaches a tmux output tap with `pipe-pane -O`. The tap is a wake signal, not a parser. On wake, the daemon performs an on-demand `tmux capture-pane` refresh and runs the screen classifier against the fresh tail content.

The observer must stamp every wake with the current `screen_epoch`. A later capture with a higher `screen_epoch` always beats an older wake.

### 3. Transcript follower

For each watched pane with a discoverable transcript, the daemon tails the transcript file and parses only appended JSONL entries.

Transcript discovery order is part of this spec:

1. explicit tmux pane metadata
2. Claude project transcript lookup by pane cwd
3. Codex process file-handle discovery via `lsof`

A follower is bound to `(path, dev, inode, offset)`. It may only emit `transcript.append` for bytes strictly beyond the `transcript_cursor` captured at `watch.start`. If the file rotates, truncates, or discovery becomes ambiguous, the follower emits `observer.degraded` and stops being authoritative until rediscovery succeeds.

Transcript events are the fast path for:

- Claude/Ren `idle`
- Claude/Ren `blocked:question`
- Codex/Ren-Codex `idle`
- Codex/Ren-Codex `blocked:question`
- Codex/Ren-Codex transcript-backed `blocked:permission`

### 4. Deadman reconciler

A slow fallback timer runs `agent-state <pane>` only when a watch is degraded, silent, or recovering from restart.

Definitions:

- **healthy pane:** at least one fast observer is attached and authoritative for the active watch
- **degraded pane:** no fast observer is currently authoritative for the active watch. Missing one observer does not degrade the pane if another fast observer still covers the remaining state space.
- **silent pane:** a watched pane that was healthy, then produced no accepted fast event for `2000ms` while the watch remains unresolved

Deadman rules:

1. degraded panes reconcile every `5s`
2. silent panes get an immediate reconciliation and then enter degraded mode until a fast observer becomes authoritative again
3. startup recovery runs one reconciliation pass for every persisted unresolved watch before any fast observer can resolve that watch

## Watch and Turn Model

A watch is the delivery contract. A turn is the unit of evidence.

### Watch fields

Each watch persists:

- `watch_id`
- `pane_id`
- `turn_id`
- `baseline_state`
- `spawner_pane`
- `label`
- `watch_state`
- `resolved_state`
- `resolved_reason`
- `started_at_monotonic_ns`
- `start_screen_epoch`
- `start_transcript_cursor`
- `delivery_attempts`

### Watch states

A watch moves through this lifecycle:

1. `armed`
2. `resolved`
3. `delivering`
4. `delivered` or `delivery_failed`
5. `closed`

Rules:

- `resolved` means the canonical state machine proved one terminal state for this `turn_id`.
- `delivering` means `agent-deliver` has been invoked with `--watch-id <watch_id>`.
- `delivery_failed` is durable. It is retried on restart or deadman with the same `watch_id`.
- `closed` means the watch is no longer eligible for state transitions.
- A watch is removed from the live registry only after `delivered`, explicit `watch.remove`, or `superseded` by a newer `agent-send` turn on the same pane.

### Turn start rules

`agent-send` must emit one atomic `watch.start` after successful delivery. That event:

1. creates a new `turn_id`
2. records the current transcript cursor and screen epoch
3. sets the transient pane state to `working`
4. supersedes any older unresolved watch on the same pane

Manual typing in a pane is still supported. In that case, a manual `agent-watch add` creates a watch without forcing `working`. The watch may only resolve from evidence observed after `watch.start`. A pre-existing idle prompt on screen is not enough.

## Canonical States

The canonical pane states remain:

- `working`
- `blocked:question`
- `blocked:permission`
- `blocked:unknown`
- `idle`

The daemon owns the only state machine. Observers contribute evidence.

## Evidence Acceptance

Evidence is accepted only if all of these hold:

1. it belongs to the active `turn_id` for the pane, or it was observed after that turn started and can be bound to it
2. its `observed_at_monotonic_ns` is greater than or equal to `started_at_monotonic_ns`
3. transcript evidence uses `end_offset > start_transcript_cursor`
4. screen evidence uses `screen_epoch > start_screen_epoch`

Rejected evidence is logged as stale and cannot resolve a watch.

## Evidence Ordering and Precedence

The transition engine evaluates evidence in two passes.

### Pass 1: freshness

Newer accepted evidence wins over older accepted evidence.

### Pass 2: tie-break precedence

If two accepted facts describe the same observation window, precedence is:

1. screen-visible `blocked:permission`
2. screen-visible `blocked:unknown`
3. transcript-visible terminal states: `idle`, `blocked:question`, `blocked:permission`
4. screen-visible `idle`
5. explicit `watch.start` / cached `working`
6. deadman snapshot

Interpretation rules:

- screen-visible blocked states override transcript `working`
- transcript terminal states override cached `working`
- deadman snapshot is authoritative only when it is newer than the latest accepted fast evidence or the pane is degraded

## Transition Rules

A watch resolves when:

1. `resolved_state != baseline_state`, and
2. `resolved_state` is terminal:
   - `idle`
   - `blocked:question`
   - `blocked:permission`
   - `blocked:unknown`

Once resolved, the daemon must invoke `agent-deliver` directly. It must never call `agent-send`.

Reason: `agent-send` auto-arms watches. If the notifier called `agent-send`, the spawner pane would be re-watched and the system could recurse forever.

`agent-deliver` gains an internal idempotency input:

```bash
agent-deliver --watch-id <watch_id> ...
```

Retry rule:

- a retry must reuse the same `watch_id`
- delivery may be retried only from `delivery_failed`
- duplicate terminal evidence for the same `watch_id` must not schedule a second logical notification

## Cross-Agent Behavior

### Claude / Ren

Fast path:

- transcript append for `idle` and `blocked:question`
- PTY wake + screen classifier for `blocked:permission` and `blocked:unknown`

Claude permission prompts are not guaranteed to be present in the transcript at the moment the UI blocks. Screen evidence remains necessary.

### Codex / Ren-Codex

Fast path:

- transcript append for `idle`
- transcript append for `request_user_input` -> `blocked:question`
- transcript append for `sandbox_permissions=require_escalated` -> `blocked:permission`
- PTY wake + screen classifier for transcript-invisible or ambiguous blockers

## `pipe-pane` Ownership

`pipe-pane` is a steez-owned resource for managed agent panes.

Rules:

1. `agent-eventsd` attaches and detaches the pipe.
2. A pipe is **steez-owned** only when the tmux pipe command exactly matches the daemon-owned observer command prefix and includes the daemon instance marker.
3. Any other non-empty pipe command is foreign.
4. Foreign ownership does not clear the watch. It marks the pane degraded and activates deadman reconciliation.
5. On restart, the daemon may reclaim only steez-owned pipes from the prior daemon generation. It must never clobber a foreign pipe.

## Persistence and Recovery

The daemon persists enough state to survive restart:

- active and recently resolved watches
- pane observer metadata
- last accepted evidence summary
- degradation reason
- delivery journal

Suggested files:

| Path | Purpose |
|------|---------|
| `~/.steez/state/agent-events.sock` | local RPC socket |
| `~/.steez/state/agent-events.json` | watch + observer snapshot |
| `~/.steez/state/agent-events.log` | structured daemon log |

Startup order is strict:

1. load persisted unresolved watches, `delivery_failed` watches, and the delivery journal
2. run one `agent-state` reconciliation pass for each unresolved watch
3. persist any resulting terminal resolution
4. retry any persisted `delivery_failed` watch with the same `watch_id`
5. attach or reattach fast observers
6. mark the daemon healthy

A restart must not allow an old observer event to beat startup reconciliation.

## Failure Handling

### Output observer failure

If the PTY tap exits, the pane is marked degraded. The watch stays live. Deadman reconciliation takes over until the observer can be reattached.

### Transcript unavailable

The pane stays observable through PTY wakes and screen classification. If the transcript later becomes discoverable and unambiguous, the daemon attaches the follower without dropping the watch.

### Pane closed or agent exited

The daemon must run one final `agent-state` reconciliation.

- If that snapshot proves a terminal state, resolve to it.
- Otherwise resolve to `blocked:unknown` with reason `pane closed before terminal state`.

A live watch must not be dropped silently on pane close.

### Socket unavailable

`agent-watch add` fails fast. It does not silently fall back to a second notification system.

### Delivery failure

A failed `agent-deliver` attempt leaves the watch in `delivery_failed`. The daemon retries with the same `watch_id` during startup recovery or the next deadman cycle.

### Daemon crash or restart

Unresolved and `delivery_failed` watches are reloaded from persisted state. Recovery follows the startup order above.

## Performance Targets

Targets apply to healthy watched panes:

- p50 notification latency: under `250ms` from `observed_at_monotonic_ns` of the first accepted terminal evidence to `agent-deliver` process start
- p95 notification latency: under `1s` on the same clock
- deadman reconciliation: every `5s` for degraded panes only
- zero steady-state `agent-state` polling for healthy panes

## Integration Points

### `agent-watch`

Becomes a thin client that talks to `agent-eventsd` over the Unix socket. `list` and `daemon-status` read daemon state instead of raw JSONL files.

### `agent-send`

After successful delivery, `agent-send` must emit one `watch.start` RPC with `baseline=working`.

If the pane already has an unresolved watch, `agent-send` supersedes it and starts a new turn.

### `agent-state`

Remains the snapshot oracle and debug tool. It serves:

- startup recovery
- degraded-mode reconciliation
- silent-pane reconciliation
- manual inspection

### `agent-history`

No change. It is still used to format blocked detail after the watch resolves.

## Rollout Plan

### Phase 1: Service shell and journal

- add `agent-eventsd`
- move watch registry into daemon state
- persist watch lifecycle and delivery journal
- keep current poll daemon as the notifier of record

### Phase 2: PTY wake shadow mode

- attach `pipe-pane -O` per watched pane
- run targeted capture and screen classification on wake
- compare event-path state against `agent-state`
- do not notify from PTY wake yet

### Phase 3: Transcript shadow mode

- tail transcripts incrementally with cursor tracking
- compare transcript-derived state against `agent-state`
- validate restart recovery and stale-evidence rejection
- do not notify from transcript path yet

### Phase 4: Event path cutover for healthy panes

- enable notifications from the canonical event engine
- require parity with the snapshot oracle for stale evidence, pane close, restart, and duplicate-notification fixtures before rollout
- keep deadman active for degraded and silent panes

### Phase 5: Recovery mode only

- demote `agent-state` polling to degraded, silent, and startup recovery paths
- keep one startup reconciliation pass and degraded-pane sweep

## Required First TDD Slice

The first TDD slice must lock these cases before broader rollout:

1. stale transcript append from the previous turn cannot resolve the current watch
2. PTY wake, transcript append, and deadman proving the same terminal state still produce one logical notification
3. crash before delivery, during delivery, and after delivery does not create duplicate notifications for one `watch_id`
4. startup reconciliation runs before fast observers can resolve a persisted watch
5. pane close yields a visible terminal outcome, not silent watch removal
6. manual `agent-watch add` on an already idle pane does not instantly fire without new evidence
7. foreign `pipe-pane` ownership degrades the pane without clobbering the foreign owner

## Why This Design

This is the smallest architecture that behaves like an agent product instead of a cron job.

- Hooks are app quirks. This design does not depend on them.
- Full polling is simple but too slow and too expensive.
- A raw `pipe-pane` parser alone is brittle. A transcript tail alone misses UI-only blockers.
- Event-driven transport only works if freshness, recovery, and delivery idempotency are explicit.

The result is one notifier, one state machine, one delivery contract, and near-instant behavior without hand-wavy races.
