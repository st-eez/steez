# agent-events

**Status:** Proposed

**Primary Path:** `shared/steez/bin/agent-eventsd`

**Public Surface:** `shared/steez/bin/agent-watch` (unchanged CLI)

Event-driven watch service for tmux-managed AI agent panes. Fast observers drive the healthy path. `agent-state` remains the bounded fallback when fast observers are missing, silent, or recovering.
`agent-eventsd` is the primary watch engine. Any polling that remains lives inside it as degraded fallback via `agent-state`.

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

`agent-eventsd` is a long-lived per-user service process and the primary watch engine. It is **not** a bash library, **not** a one-shot CLI that exits after each request, and **not** a set of functions that callers source and drive in-process.

Exactly one `agent-eventsd` service instance runs per user at a time. That service owns all in-memory watch state, all timer-driven transitions (pending timeout, silence window, degraded reconciliation, indeterminate timeout, delivery retry), and all writes under `$STEEZ_STATE_DIR/eventsd/`. Clients never mutate that state directly.

Singleton enforcement is kernel-held. `agent-eventsd serve` acquires an advisory `flock(2)` with `LOCK_EX | LOCK_NB` on `$STEEZ_STATE_DIR/eventsd/eventsd.lock`, carries the lock across `execve` (by clearing `FD_CLOEXEC`), and only then enters the service loop. Callers that lose the race exit 0 silently. A cooperative pidfile check is not sufficient — two racing callers can both pass a liveness probe before either writes the pidfile, producing orphan daemons. `eventsd.pid` is retained for observability only (`agent-eventsd status`, `agent-watch daemon-status`). The kernel releases the lock on process exit, so SIGKILL of the holder leaves no stale state and the next caller acquires cleanly. `$STEEZ_STATE_DIR` must live on a local filesystem; NFS `flock` semantics are historically unreliable and the singleton guarantee does not hold over NFS.

The `agent-eventsd` executable has two roles:

1. **Service mode.** Runs the long-lived daemon in the foreground (`agent-eventsd serve`, or the equivalent default when launched by the auto-start path). One per user.
2. **Client mode.** Subcommands `prearm`, `start`, `remove`, `list`, `status`, and `evidence` are thin clients. Each client invocation connects to the running service, submits a request, receives a response, and exits. Client invocations never execute lifecycle logic in-process and never run timers.

The first client invocation that finds no running service **must** start one and then issue its request against that service (auto-start). Subsequent invocations reuse it. Clients never fall back to running watch logic locally when the service is missing — they surface an error or trigger auto-start, they do not simulate the daemon.

Test harnesses may disable detached auto-start with `EVENTSD_REQUIRE_EXPLICIT_SERVICE=1`. In that mode the harness must start `agent-eventsd serve` itself before the first client command, and client calls must not detach-spawn a daemon behind the harness's back.

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
- native-hook CLI injection is a valid fast-evidence producer: agent hooks (Claude `Stop` / `PermissionRequest` / `PreToolUse(AskUserQuestion)`, and Codex equivalents) shell out to `agent-eventsd evidence` on turn boundaries, feeding the canonical resolver before the degraded-fallback silence window engages.
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

If `watch.start` never arrives, the daemon reaps the pending watch on its next tick through a dedicated pending-liveness authority and a hard cap. Age alone is not a close trigger — a live pane with a pending watch must NOT close just because the record is several seconds old, because `agent-send`'s synchronous `prearm -> deliver -> start` sequence can legitimately hold a watch in pending across multi-second work (steez-z6ti).

The pending-liveness authority returns one of four states, evaluated in this order:

- **`dead_pane`**: tmux cannot locate the pane. Close via the pane-close branch with `close_reason=pane_closed`.
- **`agent_gone`**: tmux has the pane but `agent-state` proves no recognized agent runs under it (the dedicated "not a recognized AI agent" signal that only fires after the inspector walks the pane's process tree). Close via the pane-close branch with `close_reason=pane_closed`.
- **`indeterminate`**: tmux has the pane but `agent-state` failed for a reason we cannot attribute to "agent gone" (transient error, missing dependency, timeout). Stay pending — the daemon cannot prove the agent is gone, so closing would silently drop a legitimate live watch.
- **`live`**: tmux has the pane and `agent-state` succeeded. Stay pending.

A hard cap runs independently of the authority. When the pending record's age reaches `PREARM_HARD_CAP_MS` (default 60s) and the authority did not already close the watch, the daemon closes it with `close_reason=pending_timeout`. This is the only path from the tick loop that records `pending_timeout`; it covers clients that called prearm and never followed up with `watch.start`.

The hard-cap age anchor is the `pending_at_ms` field stamped on the record at `watch_create_pending` time from the daemon clock (steez-es21). It must be millisecond-grade — `stat %m * 1000` truncation on the record file's mtime is not acceptable because it silently quantizes the cap boundary to whole seconds. Tests prove the boundary at ms precision by driving `EVENTSD_NOW_MS` at sub-second offsets from the stored `pending_at_ms`. Older records that predate this field may fall back to file mtime for one-off restart recovery only.

The armed-path dead-pane helper (`_eventsd_pane_has_live_agent`) must NOT be reused for pending close decisions. It treats every `agent-state` failure as "dead" and silently conflates inspector flake with agent gone.

Same-watch pending-state transitions must be serialized under a kernel-arbitrated advisory lock, not a shell-level symlink-and-rm or mkdir-and-pid-file scheme (steez-es21). Shell-level schemes cannot be made race-safe without compare-and-swap: a waiter's `readlink → kill -0 → rm` cycle TOCTOU-wipes a freshly-acquired valid lock if the holder released between check and rm, letting two callers both think they hold it. The daemon takes per-key `flock(2)` via `perl -MFcntl=:flock`; holder identity is the open file description, durable from acquisition (the kernel atomically installs the lock on the OFD) and bound to the acquirer's process lifetime (when the last fd to the OFD closes — whether through normal release or SIGKILL — the kernel releases the lock). The lock covers:

- `watch_arm`, `watch_pending_timeout`, `watch_pane_close`'s pending branch, `watch_remove`, and `watch_create_pending`'s supersede-close — all keyed on the target watch id.
- `watch_create_pending`'s full critical section (live-slot read, supersede close, record write, live-slot write) — keyed on the pane. Without the pane lock, two concurrent prearms on the same pane both read an empty live slot, both skip supersede, and both write a pending record; whichever loses the live-slot write is orphaned from the live slot and accumulates on disk.

Each locked body must re-read state inside the lock — whichever transition runs second sees the post-first state and no-ops — so a stale `watch.start` cannot resurrect a concurrently-closed watch regardless of which transition "finished first."

`$STEEZ_STATE_DIR` is required to live on a local filesystem; flock semantics on NFS are historically flaky. This is the same constraint the daemon already imposes for its singleton serve lock.

### `armed`

`watch.start` must match a pending `watch_id` on the same pane. The daemon records `start_seq` and immediately re-evaluates buffered evidence.

`agent-send` uses this order:

1. `turn.prearm` with `baseline_state=working`
2. deliver the prompt to the pane
3. `watch.start`

If step 3 fails, the daemon does not auto-retry it. The watch stays pending and times out.

Manual `agent-watch add` uses the same model, but `watch.start` follows `turn.prearm` immediately.

### `resolved`

A watch resolves when the canonical resolver proves the first live-resolving terminal state for the turn and that state differs from `baseline_state`.

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

All evidence sources feed one resolver. There is no source-specific notification path and no source-specific live-resolution state machine.

Fast-path evidence may come from transcript append, screen refresh, or both. Exact observer plumbing is an implementation detail.

The resolver rules are:

1. Only fresh evidence can affect the active turn.
2. `working` can keep the watch open, but it can never resolve it.
3. The first fresh live-resolving terminal state different from `baseline_state` resolves the watch.
4. After resolution, later evidence is ignored.

Live-resolving terminal states are:

- `idle`
- `blocked:question`
- `blocked:permission`

`blocked:unknown` is a fuzzy inspector state. It must not resolve or self-clear a live watch on its own — not from fast evidence, not from degraded reconciliation, and not from the indeterminate-window diagnostic. It still exists as a canonical pane state for explain/debug surfaces (`agent-state <pane>`, attention records), and it may still appear as the recorded `resolved_state` on pane-close fallback where pane teardown is the terminal event, not `blocked:unknown` itself.

## Degraded fallback

A watch is healthy when at least one fast observer can still produce fresh evidence for the active turn.

A watch becomes degraded when fast observers are unavailable, disconnected, or silent for `SILENCE_WINDOW_MS`.

In degraded mode the daemon must run `agent-state <pane> --detail` every `RECONCILE_INTERVAL_MS`. The `--detail` flag is required because the freshness gate below depends on `detail.transcript_path`.

Deadman reconciliation uses the same canonical states and the same live-resolution rule as fast evidence. It is not a second state machine.

If degraded reconciliation proves `working` or the fuzzy `blocked:unknown`, that is fresh liveness proof for the active watch only when the transcript cursor (byte length of `detail.transcript_path`) strictly advances over both the prearm cursor and the most recent reconcile cursor. A frozen worker returning the same cursor every reconcile is not liveness proof; the daemon must not refresh the deadman in that case. When the cursor does advance, the daemon must keep the watch armed, clear the degraded timer, and start any later timeout window from the next silence episode instead of the old one. Per-tick synthetic screen-hash tokens are not acceptable freshness signals on this branch. The `blocked:unknown` case is load-bearing (steez-ymcx): Claude's "Esc to cancel" working indicator is conservatively classified as `blocked:unknown` by the inspector, so a real working worker with an advancing transcript will reconcile as `blocked:unknown` every tick; without this rule the indeterminate window would spurious-log while the worker was still producing output.

If degraded reconciliation proves a live-resolving terminal state, the watch resolves normally.

If a degraded episode lasts `INDETERMINATE_TIMEOUT_MS` without a live-resolving terminal state and without degraded reconciliation proving `working` or `blocked:unknown` with advancing cursor, the daemon must keep the watch armed and log a single diagnostic line (pane id + watch id + "past indeterminate window, staying armed") per episode to stderr. The indeterminate window is a diagnostic threshold, not a timeout. A live watch must never be matured to terminal `blocked:unknown` by the degraded timer alone — that path was the source of steez-fyjy's false-attention regression, where the worker was still producing output at the inspector's fuzzy-classification threshold and the real Stop-hook idle ping arrived after the watch had already been drained. Only live-resolving terminal evidence (idle / blocked:question / blocked:permission), pane close, supersession, or explicit remove may retire a live watch. Inspector failures (empty agent-state output) must be logged to stderr so the broken inspector is visible.

Returning to healthy clears the degraded timer and the indeterminate-logged flag. A later degraded episode starts a new window and may log its own diagnostic.

## Pane close and restart

Pane close and daemon restart must not silently drop a live watch.

On pane close:

- a `pending` watch closes without delivery
- an `armed` watch gets one final reconciliation from transcript data still newer than the prearm cursor
- if that final reconciliation does not prove a live-resolving terminal state, the watch resolves to `blocked:unknown` — pane close is itself the terminal event here, so this is not the degraded-timer path the steez-fyjy regression banned; the resolved state is recorded as `blocked:unknown` only because the inspector could not classify the pane at teardown, and the attention record exists for spawner inspection via `agent-state <pane> --explain`.
- the armed-branch resolve writes a sticky attention record so the spawner-scoped tmux sink retains its badge after the worker pane disappears (see Recent attention evidence). Pane-close is not a turn boundary and must not unlink attention.
- draining delivery continues against the spawner pane

On daemon restart, the daemon must restore enough watch state to preserve turn freshness and delivery idempotency. At minimum:

- `pending` re-enters the same pending reaper rules: dead pane closes as `pane_closed`; live pane past `PREARM_HARD_CAP_MS` closes as `pending_timeout`; otherwise it stays pending
- `armed` gets one reconciliation pass before fresh fast-path evidence is allowed to resolve it
- a restart-time `blocked:unknown` reconcile sample leaves the watch armed
- `resolved` is re-delivered with the same `watch_id`
- `delivering` becomes `delivery_failed` and retries with the same `watch_id`
- `delivery_failed` keeps its retry budget and retries with the same `watch_id`

## Delivery contract

`watch_id` is the idempotency key.

One watch has exactly one logical notification. Multiple delivery attempts may exist for that notification, but they all use the same `watch_id`.

`agent-deliver` must be idempotent on `watch_id`. Duplicate user-visible delivery for the same `watch_id` is a bug.

A watch may retry delivery only from `delivery_failed`, or from restart recovery of `resolved`, and only until `MAX_DELIVERY_ATTEMPTS` is exhausted.

Delivered notification copy is a single-line pager ping:

```text
[agent-watch] <pane> (<label>) attention
```

The delivery body must not inline `working -> <state>` or blocked detail. Follow-up inspection belongs to `agent-state <pane> --explain`.
Spawner follow-up is exactly two steps: receive `[agent-watch] <pane> (<label>) attention`, then run `agent-state <pane> --explain`.

## Recent attention evidence

When a watch resolves, `agent-eventsd` also persists a short-lived per-pane
attention record under `$STEEZ_STATE_DIR/eventsd/attention/`. That record is
for post-ping inspection, not delivery.

The record carries the resolved terminal state plus the best available pane
identity for freshness checks:

- `pane_id`
- `state`
- `summary`
- optional `detail`
- `source`
- optional `session_id`
- optional `transcript_path`
- optional `transcript_cursor`
- `spawner_pane`
- `observed_at_ms`

`agent-state <pane> --explain` is the reader for this record. A stored record
may answer the pane only while it still matches the pane's current
session/transcript identity and the transcript cursor has not advanced past
the recorded attention point.

Attention records are sticky across worker-pane death. Pane close resolves
the live watch and writes the record; only a new `turn.prearm` on the same
worker pane (or an explicit remove) retires it. This is load-bearing for
the spawner-side TMUX sink below — a watched completion that arrives as
part of pane teardown still has to badge the spawner window.

### TMUX attention sink

The tmux status-bar dot renders off a window-scoped option
`@agent_monitor_attention`. `agent-eventsd` maintains this option as an
aggregate presence bit keyed by **spawner pane**, not by worker pane. The
dot answers "does any watched worker spawned from this window have
unread attention?" — one bit per spawner window.

The aggregate rules are:

- On every attention write or clear, the daemon scans the on-disk
  attention records for entries whose `spawner_pane` matches the affected
  spawner and refreshes that spawner's window option.
- If at least one matching record exists, the window option is set.
  The exact value is a state string; the tmux format only checks for
  presence.
- If no matching record exists, the window option is unset (`-u`).
- `sketchybar --trigger agent_attention_changed` fires on every refresh
  so downstream macOS-bar consumers stay event-driven.

Clearing always runs through the stored record: `_eventsd_clear_attention`
reads `spawner_pane` from disk before unlinking so the refresh pass can
target the correct window even when the caller has no live watch context
(explicit remove, pane already reaped, daemon restart recovery).

### Spawner-scoped ack

`agent-eventsd ack --spawner <pane>` is the first-class read path for
sticky spawner-scoped attention. A single call retires every attention
record whose stored `spawner_pane` matches `<pane>` and then runs one
refresh pass against that spawner's window so the tmux option unsets
and SketchyBar re-reads.

The ack is scoped to the addressed spawner. Attention records
belonging to any other spawner — including records whose
`spawner_pane` is empty or missing — must be left on disk and the
refresh pass must target only the acknowledged window. A single
refresh at the end is load-bearing: per-record clears would fire one
tmux set-option and one SketchyBar trigger per worker, flapping state
for no behavior gain.

Missing `--spawner` is a usage error (exit 2). Ack on a spawner with
no matching records is a no-op for on-disk state but still runs the
refresh pass so the sink stays consistent.

## Default timers

These defaults are part of v1:

- `PREARM_HARD_CAP_MS = 60000` (hard cap that closes a stuck live-pending watch as `pending_timeout`)
- `RECONCILE_INTERVAL_MS = 5000`
- `SILENCE_WINDOW_MS = 30000`
- `INDETERMINATE_TIMEOUT_MS = 120000` (diagnostic threshold, not a resolution timeout — see Degraded fallback)
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
2. **Runtime harnesses own service lifetime in explicit-service mode.** When a harness sets `EVENTSD_REQUIRE_EXPLICIT_SERVICE=1`, it must start the service explicitly, stop it explicitly, and tear it down before deleting the temp state tree or tmux server.
3. **Internal-function tests are kernel coverage, not runtime coverage.** Unit tests that exercise individual functions inside the daemon are useful for kernel correctness but do not prove the runtime works. A suite that passes entirely by calling internal helpers, with no end-to-end coverage against a live service, does not satisfy this spec.
4. **Timers run in the service.** Tests that need to exercise `PREARM_HARD_CAP_MS`, `SILENCE_WINDOW_MS`, `INDETERMINATE_TIMEOUT_MS`, or delivery retry must do so by advancing the service's clock, not by invoking the timeout function directly from the test process.
5. **Fake only the agent process.** End-to-end coverage runs against the zero-token fakes defined in `specs/fake-agent-harness.md`. The test seam is the `claude` / `codex` binary on `$PATH`; `spawn.sh`, `agent-send`, `agent-deliver`, `agent-eventsd`, `agent-watch`, `agent-history`, and `agent-state` stay real.
6. **Assert through the public surface.** Primary-path tests must not prove behavior by reading files under `$STEEZ_STATE_DIR/eventsd/` directly. Use `agent-watch`, spawner-pane output, and other public runtime surfaces.
7. **The primary path routes through `agent-eventsd`.** End-to-end runtime coverage must prove that every primary-path scenario drives the live `agent-eventsd` service: the service pidfile is alive, lifecycle state lands in `$STEEZ_STATE_DIR/eventsd/`, and `agent-watch daemon-status` reports eventsd health.
8. **Runtime tests stay parallel-safe.** Every runtime-suite test must mint its own `$HOME`, `$STEEZ_STATE_DIR`, tmux socket (`tmux -L <unique>`), per-test bin dir on `$PATH`, and per-test eventsd pidfile inside `$STEEZ_STATE_DIR/eventsd/`. No file-scope mutable state may be read or written after the test body starts. `test-agent-eventsd-runtime.sh` drains its queue through a bounded worker pool (default 4, `EVENTSD_TEST_PARALLEL=1` restores serial) and replays results in declaration order; new tests must preserve these isolation properties so the pool stays correct.

Keep the acceptance set short and derived from behavior:

1. Evidence with `seq > prearm_seq` that lands before `watch.start` is buffered and can resolve on start.
2. Evidence at or before the prearm baseline is stale. Manual add on an already-idle or already-blocked pane does not resolve without fresh evidence.
3. A new `turn.prearm` supersedes an unresolved live watch without blocking the new turn.
4. One `watch_id` produces one logical notification across duplicate evidence, retries, and restart recovery.
5. Degraded watches reconcile through `agent-state` and stay armed while reconcile keeps proving `working` (or the fuzzy `blocked:unknown` with an advancing cursor). A degraded episode that runs past `INDETERMINATE_TIMEOUT_MS` without a live-resolving terminal ping must stay armed and log a single diagnostic line per episode — the daemon must not mature the live watch to terminal `blocked:unknown` (steez-fyjy).
6. Restart recovery preserves the same `watch_id` and bounded delivery attempts.
7. `agent-eventsd status` returns `ready` only when the service process is running and responsive; killing the service flips the result to `unavailable`.
8. A live-pending watch whose pane is still up does not close on age alone. A pending watch closes with `close_reason=pane_closed` when the pane is gone OR when the pane is present but the recognized agent is provably gone (`agent-state` emits the dedicated "not a recognized AI agent" signal). A pending watch past `PREARM_HARD_CAP_MS` on a live or indeterminate pane closes with `close_reason=pending_timeout`; the age anchor is the `pending_at_ms` field on the record, not file mtime, so the boundary holds at ms precision (steez-es21). An inspector flake that cannot prove the agent gone keeps the watch pending. Same-watch transitions (`watch_arm`, `watch_pending_timeout`, `watch_pane_close` pending-branch, `watch_remove`, `watch_create_pending` supersede) and same-pane `watch_create_pending` calls are serialized under kernel-arbitrated `flock(2)` locks (steez-es21) — not shell-level symlink/mkdir schemes which are inherently TOCTOU-racy — so a stale `watch.start` cannot resurrect a closed watch and two concurrent prearms cannot leave a pending record orphaned from the pane's live slot (steez-z6ti, steez-es21).

## Verification requirements

These rules apply on top of the TDD relationship above. They exist because steez-401 shipped a fast-evidence harness in which every failure mode below went undetected; each rule is tied to a specific failure mode from that retro. Spec changes that introduce new event producers, new real-time behavior, new harnesses, or new fallback paths MUST satisfy the matching rule below before landing.

1. **Producer presence.** Every event producer named in this spec — including the transcript-append observer, the screen-refresh observer, the `agent-state` degraded reconciler, and the pane-close watcher — MUST have (a) a production invocation site reachable on the primary runtime path of `agent-eventsd` and (b) at least one test that exercises that producer on the real runtime path. A test that substitutes a mock, a test-only shim, or a harness-generated event in place of the real producer does not satisfy this rule. (Failure mode: steez-401 spec used ambient language "events come from transcript append, screen refresh, or both" — never a MUST, never a real production wiring. No producer was ever reachable from production code, and no test caught it because every test injected evidence from the harness.)

2. **Latency bounds.** Every real-time behavior named in this spec — notification dispatch after terminal evidence, fast-evidence ingestion, and degraded reconcile cycle — MUST have at least one red test that asserts a wall-clock latency bound (expressed in milliseconds) between the triggering event and the observed outcome. Tests that assert only a correctness invariant ("exactly one notification", "watch resolves", "state transitions to idle") without also bounding elapsed time do not satisfy this rule. (Failure mode: steez-401's red test accepted a 30s degraded-fallback resolution as satisfying "exactly one notification." No latency assertion meant the slow fallback path was indistinguishable from the fast primary path, and the missing primary looked like success.)

3. **Harness isolation.** The test harness MUST NOT be the origin of the evidence the service under test is meant to observe. Evidence feeding `agent-eventsd` on a primary-path test MUST come from an independent producer — a real agent process invoked via `$PATH`, a standalone fs-event emitter running out-of-process from the test driver, or a fixture process that is not the SUT's runtime and is not the test orchestrator. A single process that both drives the SUT lifecycle and emits the events the SUT is meant to observe does not satisfy this rule. (Failure mode: steez-401's harness was simultaneously the orchestrator that started/stopped the SUT and the producer that emitted the evidence. Nothing structurally distinguished harness-generated events from real production events, so green tests proved nothing about the real runtime path.)

4. **Fallback companion tests.** Every fallback path named in this spec — degraded reconciliation via `agent-state`, `pending_timeout`, pane-close resolution, delivery retry, and restart recovery — MUST ship with a companion test that explicitly disables or blocks that fallback and asserts the healthy primary path resolves the watch on its own within the latency bound required by rule 2. A fallback added to the spec without a matching healthy-path-alone test does not satisfy this rule. (Failure mode: steez-401's degraded reconciliation silently rescued every test because the fallback was always available; no test ever disabled it. The missing primary fast path was hidden for the entire life of the slice.)

## Codex Stop hook

`shared/steez/hooks/codex-stop.sh` is the Codex-side fast-evidence producer for turn-end. It reads the Codex `Stop` payload on stdin, takes the transcript byte-count as the `transcript_cursor`, shells out `agent-eventsd evidence --pane "$TMUX_PANE" --state idle --transcript-cursor <cursor>` fire-and-forget, and returns `{"continue":true}` on stdout so Codex accepts the hook result. The resolver then closes the live watch on the pane through the canonical evidence path.

The installer symlinks the hook into `~/.codex/hooks/codex-stop.sh` and auto-registers the `SessionStart`, `Stop`, and `UserPromptSubmit` groups in `~/.codex/hooks.json` on every `steez install`. Registration is idempotent, preserves any existing user hook groups, and only appends the steez-managed commands when they are missing. `~/.codex/config.toml` is **not** mutated; users must still opt in by setting `[features] codex_hooks = true` there.

Without this hook a watched codex pane falls back to degraded reconciliation via `agent-state`. That path stays armed while reconcile keeps proving `working` (or the fuzzy `blocked:unknown` with an advancing cursor) and only resolves when reconcile proves a live-resolving terminal state, the pane closes, or the watch is explicitly removed — the indeterminate window is a diagnostic log, not a resolution path.

## Runtime pane state producers

Claude and Codex hooks publish canonical runtime state onto the worker pane via tmux pane options in addition to dispatching fast evidence. Consumers (e.g. `agent-state`) read these pane options to observe live state without scraping the transcript or walking Claude's JSONL sidecar. The store is the pane itself — no new filesystem sidecar bus is introduced.

The shape on each worker pane is:

- `@agent_runtime_state` — one of `working`, `blocked:question`, `blocked:permission`, `idle`. Always set when the hook fires on a canonical transition.
- `@agent_runtime_expires_ms` — optional wall-clock epoch in milliseconds. Set only for transient leases (currently `working` on `UserPromptSubmit`); explicitly unset (`tmux set-option -u`) on sticky states (`blocked:*`, `idle`) so a previous turn's lease cannot leak forward.

`Stop` is a turn boundary and MUST unset `@agent_runtime_expires_ms`. Writing `idle` without clearing the lease would leave stale timing data on a pane that is no longer working.

### Claude (permission-state.sh)

Event → runtime state table. Events not listed here produce no pane-option write.

| `hook_event_name`   | `tool_name`       | `@agent_runtime_state` | `@agent_runtime_expires_ms`         |
| ------------------- | ----------------- | ---------------------- | ----------------------------------- |
| `UserPromptSubmit`  | —                 | `working`              | now + `WORKING_LEASE_MS` (10000 ms) |
| `Stop`              | —                 | `idle`                 | unset                               |
| `PreToolUse`        | `AskUserQuestion` | `blocked:question`     | unset                               |
| `PermissionRequest` | `AskUserQuestion` | `blocked:question`     | unset                               |
| `PermissionRequest` | other tools       | `blocked:permission`   | unset                               |

The same hook file must be registered in `~/.claude/settings.json` under `hooks.PreToolUse` (matcher `AskUserQuestion`), `hooks.PermissionRequest` (matcher `*`), `hooks.Stop` (matcher `*`), and `hooks.UserPromptSubmit`. The installer writes these groups automatically during `steez install`, alongside `hooks.PostToolUse` (matcher `Skill`, `steez-skill-analytics.sh`) and `hooks.SessionStart` (matcher `""`, `steez-session-start.sh`). Registration is idempotent and preserves existing user hooks.

Fast-path evidence dispatch (`agent-eventsd evidence`) is unchanged — `UserPromptSubmit` does **not** dispatch evidence because `working` is never a resolution.

### Codex (codex-stop.sh)

The same file handles both events. Codex passes `hook_event_name` in the JSON payload; payloads that omit the field are treated as `Stop` to preserve the pre-branch registration shape.

| `hook_event_name`    | `@agent_runtime_state` | `@agent_runtime_expires_ms`         | Fast evidence                         |
| -------------------- | ---------------------- | ----------------------------------- | ------------------------------------- |
| `UserPromptSubmit`   | `working`              | now + `WORKING_LEASE_MS` (10000 ms) | —                                     |
| `Stop` (or missing)  | `idle`                 | unset                               | `agent-eventsd evidence --state idle` |

The installer registers the same command (`bash $HOME/.codex/hooks/codex-stop.sh`) under both `hooks.Stop` and `hooks.UserPromptSubmit` in `~/.codex/hooks.json`.

### SketchyBar sink

Every runtime-state write also fires `sketchybar --trigger agent_attention_changed` best-effort so the macOS bar's agent cluster refreshes live working/idle/blocked transitions without waiting for its 5s poll. The SketchyBar subscription already exists for attention changes; reusing the same trigger keeps the bar event-driven with no additional subscription.

The trigger fires from both `permission-state.sh` and `codex-stop.sh` on every canonical transition they publish — no trigger fires when the hook skips the runtime-state write (missing `TMUX_PANE`, `PreToolUse` for non-`AskUserQuestion` tools). A missing `sketchybar` binary is not an error and must not hold the hook open past its 5-second timeout.

### Failure handling

Hook scripts swallow tmux errors (no tmux on `PATH`, no server running, unknown pane) silently. A tmux failure must never hold the hook open past its 5-second timeout. When the pane options cannot be written, consumers fall back to their pre-existing transcript / sidecar heuristics; evidence dispatch remains the fast-path for watch resolution. SketchyBar refresh is also best-effort and treated the same way — a missing binary or failing trigger must not block the hook.
