# agent-eventsd test lifecycle design spec

## Metadata
- Title: Make `agent-eventsd` lifecycle explicit in test harnesses
- Status: Draft
- Owner: steez
- Branch: `main`
- Linked bead: `steez-09x`
- Created: 2026-04-16
- Artifact: `plans/steez-09x-eventsd-test-lifecycle-design-spec.md`

## Context
`agent-eventsd` detached autostart is correct for the user-facing runtime. It is wrong for the test harnesses.

Today the first `prearm` or `evidence` call can detach-spawn `agent-eventsd serve`. The runtime harnesses then try to clean that process up with pidfile best-effort logic. That leaks orphan `agent-eventsd serve` processes when the pidfile is deleted, the child survives past cleanup, or the harness exits while the detached daemon keeps polling a temp state tree.

The harness already knows when the runtime starts and stops. That is the right place to own the daemon lifecycle.

### Phase 0 challenge
- **XY check:** the problem is not “cleanup needs a stronger `pkill`.” The problem is “tests let a detached service outlive the harness that created it.”
- **Carry cost:** every best-effort cleanup path is another race. Detached autostart in tests guarantees more of them.

## Goals
- Stop runtime and watch tests from detached-spawning `agent-eventsd` behind the harness's back.
- Make each affected harness start the service explicitly before the first client command.
- Make each affected harness stop the service explicitly before removing temp state.
- Keep production autostart unchanged for normal user runs.

## Non-goals
- Redesigning `agent-eventsd` transport or replacing autostart in production.
- Refactoring unrelated unit tests that source daemon internals.
- Adding a new daemon supervisor or external service manager.

## Constraints & assumptions
- The runtime shape in `specs/agent-events.md` stays true: one long-lived service owns timers and state.
- Primary-path tests must still talk to the real service through public client commands.
- Fake-agent runtime tests may fake only the agent process, not `agent-eventsd` itself.
- The fix must be opt-in for tests. Production CLI behavior stays detached-autostart by default.

## Requirements
- **R1.** `agent-eventsd` shall expose a test-only mode that disables detached autostart.
- **R2.** In that mode, client commands shall not spawn `agent-eventsd serve` when no service is running.
- **R3.** Affected runtime harnesses shall start `agent-eventsd serve` explicitly before issuing `prearm`, `start`, `agent-send`, `agent-watch`, or `evidence` calls that require the service.
- **R4.** Affected runtime harnesses shall stop the tracked service before deleting the temp state tree or killing the temp tmux server.
- **R5.** The fix shall remove reliance on catch-all orphan reaping such as blanket `pkill` by temp-home path.
- **R6.** Production autostart shall remain the default when the test-only mode is not enabled.
- **R7.** The shipped docs in `specs/agent-events.md` shall describe the explicit-lifecycle rule for test mode.

## Proposed design
### 1. Add an explicit-service test gate to `agent-eventsd`
Teach `_eventsd_auto_start_service` to check a test-only env flag before it detached-spawns the service. When the flag is set and no service is running, the helper returns failure instead of spawning.

This keeps the production default unchanged while giving tests a hard wall: no detached daemon unless the harness started it.

### 2. Move runtime ownership into the harness
The affected harnesses will export the test-only flag in `setup_runtime`, start `agent-eventsd serve` explicitly, wait for the pidfile, and store the tracked pid. `cleanup_runtime` will kill that pid, wait for exit, remove the pidfile if needed, then tear down tmux and the temp tree.

### 3. Reuse one test helper shape
Share the explicit start/stop shape across the affected test files instead of open-coding different cleanup races in each file.

## Interface contracts
- **Env flag:** `EVENTSD_REQUIRE_EXPLICIT_SERVICE=1`
  - Default unset.
  - When set and no live pidfile exists, client-side autostart returns failure and does not detach-spawn `serve`.
- **Service lifecycle in tests:**
  - Start: `"$BIN_DIR/agent-eventsd" serve </dev/null >/dev/null 2>&1 &`
  - Ready condition: pidfile exists and points at a live process.
  - Stop: kill tracked pid, wait for exit, remove stale pidfile if the trap did not.

## Acceptance criteria
- A client call made with `EVENTSD_REQUIRE_EXPLICIT_SERVICE=1` and no running service does not create a pidfile or detached `agent-eventsd serve`.
- `test-agent-watch.sh` runs against a real explicitly-started service and exits without orphan cleanup hacks.
- `test-fake-harness-evidence.sh` exits without leaving `agent-eventsd serve` under its temp HOME.
- `test-agent-eventsd-runtime.sh` exits without leaving `agent-eventsd serve` under its temp HOME.
- `specs/agent-events.md` describes the explicit-lifecycle rule for test mode.

## Verification commands
```bash
bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd.sh
bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-watch.sh
bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-fake-harness-evidence.sh
bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd-runtime.sh
```

## Implementation slices
### S1 — Disable detached autostart in test mode and make harness ownership explicit
- **Goal:** Make runtime tests own the `agent-eventsd` lifecycle instead of inheriting a detached daemon.
- **Behavior under test:** test-mode `agent-eventsd` never detached-spawns a service, and affected harnesses pass with explicit start/stop ownership.
- **Seam under test:** `agent-eventsd prearm` client behavior plus the public runtime harness scripts
- **Boundary:** `shared/steez/bin/agent-eventsd`, shared agent test helpers, affected runtime/watch test scripts, and `specs/agent-events.md`
- **Files likely touched:** `shared/steez/bin/agent-eventsd`, `shared/steez/tests/agent/helpers.sh`, `shared/steez/tests/agent/test-agent-eventsd.sh`, `shared/steez/tests/agent/test-agent-watch.sh`, `shared/steez/tests/agent/test-fake-harness-evidence.sh`, `shared/steez/tests/agent/test-agent-eventsd-runtime.sh`, `specs/agent-events.md`
- **Red test name:** `explicit-service mode blocks detached autostart`
- **Fixture / harness:** temp `HOME`, temp `STEEZ_STATE_DIR`, real `agent-eventsd`, and the existing fake-agent runtime harnesses
- **Isolation rule:** temp HOME, temp state dir, and test-owned tmux sockets only; no real user state and no shared daemon
- **Determinism rule:** assert through pidfile/process ownership and harness-local temp roots only; no global `pkill` dependency
- **Assertion contract:** with `EVENTSD_REQUIRE_EXPLICIT_SERVICE=1`, a client call without a running service fails without detached-spawning `serve`; the affected harnesses still pass once they start and stop the service explicitly
- **Green condition:** test-mode autostart is blocked, runtime harnesses explicitly own `agent-eventsd serve`, and the affected suites pass without orphan-reaping hacks
- **Refactor target:** centralize explicit service start/stop helpers instead of duplicating pidfile races
- **Smoke budget:** `single allowed smoke`
- **Verification command:** `bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd.sh && bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-watch.sh && bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-fake-harness-evidence.sh && bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd-runtime.sh`
