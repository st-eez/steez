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

## Runtime shape

`agent-eventsd` is a long-lived per-user service process. It replaces `agent-watch-daemon` as the primary watch engine. It is **not** a bash library, **not** a one-shot CLI that exits after each request, and **not** a set of functions that callers source and drive in-process.

Exactly one `agent-eventsd` service instance runs per user at a time. That service owns all in-memory watch state, all timer-driven transitions (pending timeout, silence window, degraded reconciliation, indeterminate timeout, delivery retry), and all writes under `$STEEZ_STATE_DIR/eventsd/`. Clients never mutate that state directly.

The `agent-eventsd` executable has two roles:

1. **Service mode.** Runs the long-lived daemon in the foreground (`agent-eventsd serve`, or the equivalent default when launched by the auto-start path). One per user.
2. **Client mode.** Subcommands `prearm`, `start`, `remove`, `list`, and `status` are thin clients. Each client invocation connects to the running service, submits a request, receives a response, and exits. Client invocations never execute lifecycle logic in-process and never run timers.

The first client invocation that finds no running service **must** start one and then issue its request against that service (auto-start). Subsequent invocations reuse it. Clients never fall back to running watch logic locally when the service is missing — they surface an error or trigger auto-start, they do not simulate the daemon.

`agent-send`, `agent-watch`, and every other caller reach `agent-eventsd` only through these client commands. No caller sources the daemon file as a bash library on the primary path. No caller calls internal helpers (`watch_tick`, `watch_pending_timeout`, `watch_arm`, `watch_create_pending`, `_eventsd_*`) to drive behavior.

A shape where `prearm` / `start` / `remove` / `list` / `status` each run standalone against on-disk state, with no long-lived process, does not satisfy this spec. Timer-driven transitions have no owner in that shape.

## Public interface

The public CLI stays:

```bash
agent-watch add <pane> [--spawner <pane>] [--label <str>] [--baseline <state>]
agent-watch remove <pane>
agent-watch list
agent-watch daemon-status
```

Every subcommand routes to the running `agent-eventsd` service (see Runtime shape). `agent-send` still creates watches automatically after it delivers a prompt, but the watch now follows the two-step turn model in this spec.

## Event surface

Events are exchanged between clients and the running service (see Runtime shape). The wire format is not normative here. The v1 behavioral contract depends on these event semantics:

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

## Daemon status

`agent-eventsd status` (and its public equivalent `agent-watch daemon-status`) reports liveness and health of the running service.

A `ready` result requires all of:

1. The service process is running.
2. It is accepting client requests on its transport.
3. Its state directory is writable.

"State directory exists and is writable" alone is not a `ready` result. A status probe that returns `ready` without proving the service is actually running and responsive is a spec violation.

`unavailable` is the result when any of the three conditions fails, including when no service is running.

## TDD relationship

This spec is normative. Tests should prove the rules above. They should not replace them.

### Testing rules

1. **Primary-path tests go through the service.** Tests that exercise watch lifecycle on the primary path must drive behavior through the client commands (`prearm`, `start`, `remove`, `list`, `status`) against a running `agent-eventsd` service. They must not call `watch_tick`, `watch_pending_timeout`, `watch_arm`, `watch_create_pending`, or any `_eventsd_*` helper directly. Those are internal to the daemon; driving them from tests bypasses the runtime under test.
2. **Internal-function tests are kernel coverage, not runtime coverage.** Unit tests that exercise individual functions inside the daemon are useful for kernel correctness but do not prove the runtime works. A suite that passes entirely by calling internal helpers, with no end-to-end coverage against a live service, does not satisfy this spec.
3. **Timers run in the service.** Tests that need to exercise `PREARM_TIMEOUT_MS`, `SILENCE_WINDOW_MS`, `INDETERMINATE_TIMEOUT_MS`, or delivery retry must do so by advancing the service's clock, not by invoking the timeout function directly from the test process.
4. **Fake only the agent process.** End-to-end coverage runs against the zero-token fakes defined in `specs/fake-agent-harness.md`. The test seam is the `claude` / `codex` binary on `$PATH`; `spawn.sh`, `agent-send`, `agent-deliver`, `agent-eventsd`, `agent-watch`, `agent-history`, and `agent-state` stay real.
5. **Assert through the public surface.** Primary-path tests must not prove behavior by reading files under `$STEEZ_STATE_DIR/eventsd/` directly. Use `agent-watch`, spawner-pane output, and other public runtime surfaces.
6. **The primary path never spawns `agent-watch-daemon`.** End-to-end runtime coverage must prove that no primary-path scenario starts `agent-watch-daemon`.

Keep the acceptance set short and derived from behavior:

1. Evidence with `seq > prearm_seq` that lands before `watch.start` is buffered and can resolve on start.
2. Evidence at or before the prearm baseline is stale. Manual add on an already-idle or already-blocked pane does not resolve without fresh evidence.
3. A new `turn.prearm` supersedes an unresolved live watch without blocking the new turn.
4. One `watch_id` produces one logical notification across duplicate evidence, retries, and restart recovery.
5. Degraded watches reconcile through `agent-state` and end in either a terminal state or `blocked:unknown` by timeout.
6. Restart recovery preserves the same `watch_id` and bounded delivery attempts.
7. `agent-eventsd status` returns `ready` only when the service process is running and responsive; killing the service flips the result to `unavailable`.

## Verification requirements

These rules apply on top of the TDD relationship above. They exist because steez-401 shipped a fast-evidence harness in which every failure mode below went undetected; each rule is tied to a specific failure mode from that retro. Spec changes that introduce new event producers, new real-time behavior, new harnesses, or new fallback paths MUST satisfy the matching rule below before landing.

1. **Producer presence.** Every event producer named in this spec — including the transcript-append observer, the screen-refresh observer, the `agent-state` degraded reconciler, and the pane-close watcher — MUST have (a) a production invocation site reachable on the primary runtime path of `agent-eventsd` and (b) at least one test that exercises that producer on the real runtime path. A test that substitutes a mock, a test-only shim, or a harness-generated event in place of the real producer does not satisfy this rule. (Failure mode: steez-401 spec used ambient language "events come from transcript append, screen refresh, or both" — never a MUST, never a real production wiring. No producer was ever reachable from production code, and no test caught it because every test injected evidence from the harness.)

2. **Latency bounds.** Every real-time behavior named in this spec — notification dispatch after terminal evidence, fast-evidence ingestion, and degraded reconcile cycle — MUST have at least one red test that asserts a wall-clock latency bound (expressed in milliseconds) between the triggering event and the observed outcome. Tests that assert only a correctness invariant ("exactly one notification", "watch resolves", "state transitions to idle") without also bounding elapsed time do not satisfy this rule. (Failure mode: steez-401's red test accepted a 30s degraded-fallback resolution as satisfying "exactly one notification." No latency assertion meant the slow fallback path was indistinguishable from the fast primary path, and the missing primary looked like success.)

3. **Harness isolation.** The test harness MUST NOT be the origin of the evidence the service under test is meant to observe. Evidence feeding `agent-eventsd` on a primary-path test MUST come from an independent producer — a real agent process invoked via `$PATH`, a standalone fs-event emitter running out-of-process from the test driver, or a fixture process that is not the SUT's runtime and is not the test orchestrator. A single process that both drives the SUT lifecycle and emits the events the SUT is meant to observe does not satisfy this rule. (Failure mode: steez-401's harness was simultaneously the orchestrator that started/stopped the SUT and the producer that emitted the evidence. Nothing structurally distinguished harness-generated events from real production events, so green tests proved nothing about the real runtime path.)

4. **Fallback companion tests.** Every fallback path named in this spec — degraded reconciliation via `agent-state`, `pending_timeout`, `INDETERMINATE_TIMEOUT_MS` resolution to `blocked:unknown`, delivery retry, and restart recovery — MUST ship with a companion test that explicitly disables or blocks that fallback and asserts the healthy primary path resolves the watch on its own within the latency bound required by rule 2. A fallback added to the spec without a matching healthy-path-alone test does not satisfy this rule. (Failure mode: steez-401's degraded reconciliation silently rescued every test because the fallback was always available; no test ever disabled it. The missing primary fast path was hidden for the entire life of the slice.)
