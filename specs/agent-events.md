# agent-events

**Status:** Proposed

**Primary Path:** `shared/steez/bin/agent-eventsd`

**Public Surface:** `shared/steez/bin/agent-watch` (unchanged CLI)

Event-driven watch service for tmux-managed AI agent panes. Fast observers drive the healthy path. `agent-state` remains the bounded fallback when fast observers are missing, silent, or recovering.
It replaces `agent-watch-daemon` as the primary watch engine. Any polling that remains lives inside `agent-eventsd` as degraded fallback via `agent-state`.

## Normative scope

This document is the v1 source of truth. Normative behavior lives here. Tests are derived from this behavior.

This spec does **not** define rollout gates, shadow-mode metrics, socket framing, peer-auth mechanisms, helper topology, or a fixture catalog. Those are implementation details or separate validation work.

## Goals

1. Keep the watch system event-driven.
2. Keep one canonical resolver and one canonical notifier.
3. Close the turn-birth race with `turn.prearm`, `watch.start`, and `prearm_seq`.
4. Make delivery idempotent on `watch_id`.
5. Bound degraded behavior. No watch may wait forever.

## Non-goals

1. Non-tmux terminals.
2. A general event bus beyond agent panes.
3. Full polling on healthy panes.
4. Exhaustive transport and security detail in v1.

## Public interface

The public CLI stays:

```bash
agent-watch add <pane> [--spawner <pane>] [--label <str>] [--baseline <state>]
agent-watch remove <pane>
agent-watch list
agent-watch daemon-status
```

`agent-send` still creates watches automatically after it delivers a prompt, but the watch now follows the two-step turn model in this spec.

## Event surface

The daemon is a local per-user service. The wire format is not normative here. The v1 behavioral contract depends on these event semantics:

- `turn.prearm` creates a pending watch and captures the baseline.
- `watch.start` promotes a pending watch to armed.
- `watch.remove` closes an unresolved watch.
- fast evidence events come from transcript append, screen refresh, or both.
- degraded reconciliation comes from `agent-state`.
- pane closure is a terminal watcher event.

How those events cross process boundaries is an implementation detail as long as they preserve the rules below.

## Canonical states

The canonical pane states are:

- `working`
- `blocked:question`
- `blocked:permission`
- `blocked:unknown`
- `idle`

Only these are terminal:

- `idle`
- `blocked:question`
- `blocked:permission`
- `blocked:unknown`

## Core model

### Watch

A watch is the delivery contract for one pane turn.

### Turn

A turn is the evidence window for one watch. Evidence is valid only for the active turn.

### Live and draining watches

A `pending` or `armed` watch is live. A `resolved`, `delivering`, or `delivery_failed` watch is draining.

At most one live watch may exist per pane. A new `turn.prearm` supersedes any existing live watch on that pane without waiting for draining delivery to finish.

## Ordering and freshness

The daemon assigns a monotonic `seq` per pane when it ingests an event. `seq` is the only ordering input. Timestamps are diagnostic only.

`turn.prearm` records `prearm_seq`. `watch.start` records `start_seq`. Freshness is based on `prearm_seq`, not `start_seq`.

Evidence is fresh only if all of these hold:

1. It lands on the pane after `turn.prearm` and before the next turn boundary, so the daemon can bind it to the active turn.
2. `event.seq > prearm_seq`.
3. Transcript evidence comes from bytes appended after the prearm transcript cursor.
4. Screen evidence comes from a post-prearm capture whose content differs from the prearm capture.

Evidence that arrives after `turn.prearm` and before `watch.start` is buffered. It becomes eligible when the watch moves to `armed`.

The prearm baseline itself is never resolution evidence.

## Watch lifecycle

### `pending`

`turn.prearm` creates a pending watch and records at least:

- `watch_id`
- `turn_id`
- `pane_id`
- `spawner_pane`
- `label`
- `baseline_state`
- prearm screen hash
- prearm transcript cursor
- `prearm_seq`

The daemon must capture the baseline before the turn becomes live.

A pending watch never notifies. It only buffers fresh evidence.

If `watch.start` never arrives, the watch closes with `pending_timeout`.

### `armed`

`watch.start` must match a pending `watch_id` on the same pane. The daemon records `start_seq` and immediately re-evaluates buffered evidence.

`agent-send` uses this order:

1. `turn.prearm` with `baseline_state=working`
2. deliver the prompt to the pane
3. `watch.start`

If step 3 fails, the daemon does not auto-retry it. The watch stays pending and times out.

Manual `agent-watch add` uses the same model, but `watch.start` follows `turn.prearm` immediately.

### `resolved`

A watch resolves when the canonical resolver proves the first terminal state for the turn and that state differs from `baseline_state`.

Once resolved, the watch is one-shot. Later evidence for that `watch_id` is ignored.

### `delivering`

The daemon must persist `resolved` before it invokes `agent-deliver`.

The daemon is the only component allowed to notify. It must call `agent-deliver`. It must never call `agent-send`.

### `delivered`, `delivery_failed`, `closed`

A successful delivery ends the watch.

A failed or timed-out delivery attempt moves the watch to `delivery_failed`. The daemon may retry only with the same `watch_id`.

Retries are bounded by `MAX_DELIVERY_ATTEMPTS`. Exhaustion closes the watch with `delivery_exhausted`.

Explicit removal or live-watch supersession closes an unresolved watch without delivery.

## Baseline rules

The prearm baseline is a reference point, not evidence.

This is load-bearing for manual adds on already-terminal panes:

- a pane already showing `idle` at prearm does not resolve immediately
- a pane already showing `blocked:*` at prearm does not resolve immediately

Those watches require fresh post-prearm evidence to resolve.

## Canonical resolver

All evidence sources feed one resolver. There is no source-specific notification path and no source-specific terminal state machine.

Fast-path evidence may come from transcript append, screen refresh, or both. Exact observer plumbing is an implementation detail.

The resolver rules are:

1. Only fresh evidence can affect the active turn.
2. `working` can keep the watch open, but it can never resolve it.
3. The first fresh terminal state different from `baseline_state` resolves the watch.
4. After resolution, later evidence is ignored.

## Degraded fallback

A watch is healthy when at least one fast observer can still produce fresh evidence for the active turn.

A watch becomes degraded when fast observers are unavailable, disconnected, or silent for `SILENCE_WINDOW_MS`.

In degraded mode the daemon must run `agent-state <pane>` every `RECONCILE_INTERVAL_MS`.

Deadman reconciliation uses the same canonical states and the same terminal rule as fast evidence. It is not a second state machine.

If degraded reconciliation proves a terminal state, the watch resolves normally.

If a degraded episode lasts `INDETERMINATE_TIMEOUT_MS` without a terminal state, the watch must resolve to `blocked:unknown`.

Returning to healthy clears the degraded timer. A later degraded episode starts a new timeout window.

## Pane close and restart

Pane close and daemon restart must not silently drop a live watch.

On pane close:

- a `pending` watch closes without delivery
- an `armed` watch gets one final reconciliation from transcript data still newer than the prearm cursor
- if that final reconciliation does not prove a terminal state, the watch resolves to `blocked:unknown`
- draining delivery continues against the spawner pane

On daemon restart, the daemon must restore enough watch state to preserve turn freshness and delivery idempotency. At minimum:

- `pending` closes as `pending_timeout`
- `armed` gets one reconciliation pass before fresh fast-path evidence is allowed to resolve it
- `resolved` is re-delivered with the same `watch_id`
- `delivering` becomes `delivery_failed` and retries with the same `watch_id`
- `delivery_failed` keeps its retry budget and retries with the same `watch_id`

## Delivery contract

`watch_id` is the idempotency key.

One watch has exactly one logical notification. Multiple delivery attempts may exist for that notification, but they all use the same `watch_id`.

`agent-deliver` must be idempotent on `watch_id`. Duplicate user-visible delivery for the same `watch_id` is a bug.

A watch may retry delivery only from `delivery_failed`, or from restart recovery of `resolved`, and only until `MAX_DELIVERY_ATTEMPTS` is exhausted.

## Default timers

These defaults are part of v1:

- `PREARM_TIMEOUT_MS = 5000`
- `RECONCILE_INTERVAL_MS = 5000`
- `SILENCE_WINDOW_MS = 30000`
- `INDETERMINATE_TIMEOUT_MS = 120000`
- `MAX_DELIVERY_ATTEMPTS = 5`

## TDD relationship

This spec is normative. Tests should prove the rules above. They should not replace them.

Keep the acceptance set short and derived from behavior:

1. Evidence with `seq > prearm_seq` that lands before `watch.start` is buffered and can resolve on start.
2. Evidence at or before the prearm baseline is stale. Manual add on an already-idle or already-blocked pane does not resolve without fresh evidence.
3. A new `turn.prearm` supersedes an unresolved live watch without blocking the new turn.
4. One `watch_id` produces one logical notification across duplicate evidence, retries, and restart recovery.
5. Degraded watches reconcile through `agent-state` and end in either a terminal state or `blocked:unknown` by timeout.
6. Restart recovery preserves the same `watch_id` and bounded delivery attempts.
