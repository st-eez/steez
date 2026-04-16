# Agent attention simplification design spec

## Metadata
- Title: Simplify spawned-agent attention detection and explanation API
- Status: Draft
- Owner: steez
- Branch: `main`
- Linked bead: `steez-6ep`
- Created: 2026-04-15
- Artifact: `plans/steez-6ep-agent-attention-design-spec.md`

## Context
The current spawned-agent watch flow is overbuilt for its real job.

The real job is simple: when one agent spawns another, the parent needs one ping when the child stops making forward progress, then one canonical command to learn why.

Today that path is split across too many moving parts:
- Claude writes a filesystem sidecar under `~/.steez/agent-state/claude/`.
- Claude state detection relies on seven state-hook registrations plus `SessionStart`.
- Callers leak into `agent-history --blocked` to learn the reason.
- Claude blocked-permission fallback leans on screen scraping through `tmux capture-pane`, which is a weak fit for AI agent panes.

### Phase 0 challenge
- **XY check:** the problem is not “we need richer blocked-state notifications.” The problem is “spawned-agent orchestration needs a smaller contract.”
- **Carry cost:** the Claude sidecar, clear-hook fanout, and caller knowledge of parser flags all create maintenance cost without paying for the spawn-agent workflow.

The change should simplify the orchestration contract without deleting lower-level diagnostics or destabilizing Codex’s existing path.

## Goals
- Give spawners one generic `attention` ping when a child needs inspection or is done.
- Make `agent-state` the only command a spawner needs after that ping.
- Remove the Claude filesystem sidecar from the attention path.
- Reduce Claude state-detection hooks to the minimum reliable set.
- Keep exact terminal states internally so the system still knows `idle` vs `blocked:*`.
- Preserve existing lower-level transcript inspection commands for human debugging.

## Non-goals
- Reworking spawn layout, prompt delivery, or watch registration semantics.
- Replacing Codex transcript parsing or Codex log heuristics.
- Making screen scraping the primary truth source.
- Adding a new top-level follow-up command such as `agent-attention`.
- Perfectly eliminating every fallback heuristic in one slice.
- Broadly redesigning human-facing agent diagnostics beyond this orchestration path.

## Constraints & assumptions
- Scope is the spawned-agent workflow driven by `spawn.sh`, `agent-send`, and `agent-eventsd`.
- Codex and Ren-Codex usually run in bypass/yolo mode, so blocked-permission is rare there.
- Claude permission blocks are not reliably inferable from transcript data alone at the moment the block happens.
- `agent-state` is already the closest thing to the canonical state surface and should stay that way.
- `agent-history --blocked` may remain as a low-level diagnostic, but spawners should not need to know it exists.
- `agent-eventsd` already owns live watch state and is the right place to keep short-lived attention evidence.
- The visible notification should stay a single-line pager, not a transcript dump.
- User-level Claude hook registration guidance is owned in this repo through `internal/installer/hooks.go` and its tests.
- Except for one end-to-end runtime smoke slice, test work should be fixture-driven and deterministic.

## Requirements
- **R1.** When a watched child leaves `working`, the spawner notification shall collapse the outcome to a generic `attention` ping.
- **R2.** The system shall expose one canonical follow-up interface at `agent-state <pane> --explain`.
- **R3.** `agent-state --explain` shall return the current best-known state for the pane and a concise reason payload when the pane is blocked or recently completed.
- **R4.** Spawner logic shall not need to branch between `agent-history --blocked`, `agent-history --last`, or transcript-format-specific logic.
- **R5.** Claude attention detection shall remove the filesystem sidecar at `~/.steez/agent-state/claude/*.json` from the runtime path.
- **R6.** Claude state-detection hook registration shall be reduced to `SessionStart`, `Stop`, `PermissionRequest`, and `PreToolUse` with matcher `AskUserQuestion`.
- **R7.** Codex state-detection hook registration shall remain `SessionStart` and `Stop`.
- **R8.** Exact canonical terminal states shall still exist internally as `idle`, `blocked:question`, `blocked:permission`, and `blocked:unknown`.
- **R9.** `agent-eventsd` shall retain short-lived per-pane attention evidence so `agent-state --explain` can answer without a Claude sidecar.
- **R10.** `agent-state --explain` shall prefer fast-path attention evidence, then transcript artifacts, then bounded runtime-specific fallbacks.
- **R11.** `agent-history --blocked` shall no longer have a Claude sidecar fast path.
- **R12.** The installer hook-check guidance and tests shall match the reduced Claude hook set.
- **R13.** Every implementation slice shall define a deterministic test contract with `Test seam`, `Fixture source`, `Determinism rule`, and `Assertion contract`.
- **R14.** At most one implementation slice shall rely on a live end-to-end runtime smoke test; all other slices shall use unit or fixture-driven tests.
- **R15.** Notification delivery shall remain one-shot and watch self-clear behavior shall not regress.
- **R16.** Live watch resolution shall not notify or self-clear from a fuzzy `blocked:unknown` sample while the pane is still making forward progress.

## Proposed design
### 1. Keep exact internal states. Simplify only the pager contract.
`agent-eventsd` keeps resolving watches against the existing canonical terminal states. The change is at the notification boundary: every resolved watch notification becomes “attention” instead of exposing `working -> idle` or `working -> blocked:*` inline.

That avoids inventing a second state machine. Internally the daemon still knows the exact result. Externally the spawner gets one small signal.

### 2. Move short-lived attention evidence into `agent-eventsd`
Replace the Claude sidecar with a short-lived per-pane attention snapshot owned by `agent-eventsd`.

Each accepted terminal evidence event should be able to persist a compact record keyed by pane, containing at least:
- pane id
- session id or transcript path identity
- resolved terminal state
- tool name and tool input when the hook knows them
- transcript cursor or equivalent freshness marker
- observed timestamp

This record is orchestration state, not a general-purpose transcript cache. It lives next to the existing event daemon state instead of in a separate Claude-only filesystem tree.

### 3. Add `agent-state --explain`
Add a new mode to `agent-state` that returns one structured explanation object for a pane.

Proposed shape:
```json
{
  "pane": "%12",
  "agent": "claude",
  "state": "blocked:permission",
  "summary": "waiting for permission approval",
  "detail": "Bash: {\"command\":\"git push\"}",
  "source": "eventsd"
}
```

Behavior order:
1. resolve pane, agent, session, transcript as today
2. read recent attention evidence from `agent-eventsd`
3. if that evidence is fresh for the pane’s current transcript/session, return it
4. otherwise fall back to transcript parsing
5. for Codex, keep the existing `custom_tool_call` + TUI-log heuristic
6. keep screen scraping only as a bounded fallback when artifacts still say `working`

If the best current truth is `working`, `--explain` may return `working`. It should report truth, not replay the last ping forever.

### 4. Slim the Claude hook path
Keep these Claude hooks for state detection:
- `SessionStart` → pane metadata only
- `Stop` → terminal evidence `idle`
- `PermissionRequest` → terminal evidence `blocked:question` or `blocked:permission`
- `PreToolUse(AskUserQuestion)` → terminal evidence `blocked:question`

Remove the clear-hook fanout from the runtime path:
- `PostToolUse`
- `PostToolUseFailure`
- `UserPromptSubmit`
- `SessionEnd`

Those existed only to invalidate the sidecar. Once the sidecar is gone, that invalidation fanout should disappear too.

### 5. Keep `agent-history --blocked` as a human diagnostic
`agent-history --blocked` remains useful for manual debugging and transcript inspection.

But it becomes an implementation detail for humans, not a required orchestration step. The spawner path should be:
1. receive `attention`
2. run `agent-state %pane --explain`
3. decide whether to answer, approve, or ignore

### 6. Keep fuzzy `blocked:unknown` out of live watch resolution
`blocked:unknown` still has value as an inspector fallback in `agent-state --explain`, especially for humans looking at a pane that is visibly waiting in an unclassified prompt.

But live watch resolution is stricter. A watched pane should resolve and self-clear only from:
- `idle`
- `blocked:question`
- `blocked:permission`
- explicit deadman outcomes such as timeout or pane-close fallback

A transient or heuristic `blocked:unknown` read from reconcile or screen fallback must not fire an `attention` ping for a pane that is still working.

## Interface contracts
### Watch notification contract
- Producer: `agent-eventsd`
- Consumer: spawner pane
- Contract: one single-line `attention` ping per resolved watch
- Non-contract: inline blocked question text, inline permission tool payload, or caller-visible `working -> blocked:*` text

### `agent-state --explain`
- Input: pane id or pane target resolvable by `agent-state`
- Output: JSON object with `pane`, `agent`, `state`, `summary`, optional `detail`, and `source`
- Primary callers: spawned-agent orchestrators and humans following an attention ping
- Failure mode: if the pane cannot be resolved as an agent, exit non-zero with the existing error pattern

### `agent-history --blocked`
- Status: retained low-level diagnostic
- Contract after this change: raw blocked-tool inspection from transcript artifacts only
- Non-contract: being the required next step for spawner logic

### Hook registration contract
- Claude: `SessionStart`, `Stop`, `PermissionRequest`, `PreToolUse(AskUserQuestion)`
- Codex: `SessionStart`, `Stop`
- Installer guidance must print exactly this reduced Claude contract

### Slice test contract
Every implementation slice must tell `/tdd` exactly how to create a non-flaky red test before code changes:
- **Behavior under test:** one user-visible behavior only
- **Seam under test:** the exact public API, CLI mode, or daemon boundary under test
- **Fixture / harness:** the synthetic transcript, hook payload, fake watch record, fake daemon state, or doc/help text used by the test
- **Isolation rule:** what is faked and what real machine state is forbidden
- **Determinism rule:** no wall-clock assertions, no real home-dir state, no network, and no live tmux unless the slice is the single approved smoke slice
- **Assertion contract:** the exact output, state transition, or registration set that proves the slice is done
- **Smoke budget:** `none` or `single allowed smoke`

## Alternatives considered
### Keep the Claude sidecar and add a wrapper command
Rejected. That hides the caller leak without removing the real complexity.

### Collapse everything to only `working` and `idle`
Rejected. The notification can collapse to `attention`, but the follow-up inspector still needs to distinguish done from blocked.

### Remove hooks entirely and rely on transcript plus screen parsing
Rejected. Claude blocked-permission is not reliably encoded in transcript artifacts at block time, and the current screen fallback uses `tmux capture-pane`, which is not strong enough to become primary truth for agent panes.

### Add a new top-level command such as `agent-attention`
Rejected. The better design is to make the existing state authority complete instead of growing another public surface.

## Acceptance criteria
- **AC1.** Given a watched Claude child that finishes, when the watch resolves, then the spawner receives one generic `attention` notification and the watch self-clears.
- **AC2.** Given a watched Claude child blocked on a permission prompt, when the spawner runs `agent-state <pane> --explain`, then it receives `blocked:permission` plus concise detail without consulting a Claude sidecar file.
- **AC3.** Given a watched Claude child blocked on `AskUserQuestion`, when the spawner runs `agent-state <pane> --explain`, then it receives `blocked:question` plus the pending question text.
- **AC4.** Given the reduced Claude hook design, when installer hook guidance runs, then it asks for only `SessionStart`, `Stop`, `PermissionRequest`, and `PreToolUse(AskUserQuestion)` for state detection.
- **AC5.** Given Codex in its current configuration, when a watched child finishes, then `SessionStart`/`Stop` hooks still support the attention flow without adding new Codex hooks.
- **AC6.** Given a human debugging manually, when they run `agent-history --blocked`, then the command still returns raw blocked-tool information without any sidecar dependency.
- **AC7.** Given any implementation slice in this spec, when `/tdd` reads it, then it can name the exact behavior, seam, fixture, isolation rule, determinism rule, assertion contract, and smoke budget before writing production code.
- **AC8.** Given a watched pane that is still working, when reconcile or screen fallback produces a transient `blocked:unknown` sample, then no `attention` ping is delivered and the live watch remains armed.

## Verification commands
```bash
bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-permission-state-hook.sh

bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-state.sh

bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-transcript-parsing.sh

bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd.sh

bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd-runtime.sh

go test /Users/stevedimakos/Projects/Personal/steez/internal/installer -run Hook
```

## Implementation slices
### S1 — Reduce Claude hook registration to the minimal state set
- **Goal:** Remove the sidecar-invalidating hook fanout and shrink installer guidance to the four Claude state hooks.
- **Behavior under test:** Claude state-detection hook guidance requires only the reduced four-hook contract.
- **Seam under test:** installer hook-registration checker and permission-hook guidance output
- **Boundary:** Claude hook guidance, installer checks, and hook tests only.
- **Files likely touched:** `internal/installer/hooks.go`, `internal/installer/hooks_test.go`, `shared/steez/tests/agent/test-permission-state-hook.sh`, `shared/steez/bin/agent-state`
- **Red test name:** `CheckHookRegistration only requires the reduced Claude state hook set`
- **Fixture / harness:** synthetic `~/.claude/settings.json` hook-registration fixtures in `internal/installer/hooks_test.go` plus recorder-backed hook payloads in `test-permission-state-hook.sh`
- **Isolation rule:** synthetic settings fixtures and recorder output only; no live home-dir state, no real Claude session, no tmux
- **Determinism rule:** no live home-dir state, no real Claude session, no tmux
- **Assertion contract:** only `SessionStart`, `Stop`, `PermissionRequest`, and `PreToolUse(AskUserQuestion)` are required for Claude state detection
- **Green condition:** Installer guidance and tests require only `SessionStart`, `Stop`, `PermissionRequest`, and `PreToolUse(AskUserQuestion)` for state detection.
- **Refactor target:** Keep skill analytics and unrelated Ren plan/decompose hooks out of the state-detection contract.
- **Smoke budget:** `none`
- **Verification command:** `go test /Users/stevedimakos/Projects/Personal/steez/internal/installer -run Hook && bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-permission-state-hook.sh`

### S2 — Remove the Claude sidecar from runtime state detection
- **Goal:** Delete the Claude-only sidecar read/write path from runtime state detection and blocked inspection.
- **Behavior under test:** Claude inspection works from transcript artifacts without any sidecar dependency.
- **Seam under test:** `agent-state` artifact resolution and `agent-history --blocked`
- **Boundary:** `agent-state`, `agent-history`, and transcript parsing only.
- **Files likely touched:** `shared/steez/hooks/permission-state.sh`, `shared/steez/bin/agent-state`, `shared/steez/bin/agent-history`, `shared/steez/tests/agent/test-transcript-parsing.sh`, `shared/steez/tests/agent/test-agent-state.sh`
- **Red test name:** `Claude blocked inspection works without sidecar state files`
- **Fixture / harness:** crafted Claude JSONL transcripts and synthetic hook payloads
- **Isolation rule:** transcript fixtures and synthetic hook payloads only; no real tmux pane capture and no writes under a real `~/.steez/agent-state/claude`
- **Determinism rule:** transcript fixtures only; no real tmux pane capture and no writes under a real `~/.steez/agent-state/claude`
- **Assertion contract:** Claude blocked inspection and state detection still work for supported cases after all sidecar reads and writes are removed
- **Green condition:** No runtime path depends on `~/.steez/agent-state/claude/*.json`, and transcript parsing tests still prove the supported blocked cases.
- **Refactor target:** Keep transcript inspection logic runtime-agnostic where possible.
- **Smoke budget:** `none`
- **Verification command:** `bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-transcript-parsing.sh && bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-state.sh`

### S3 — Add recent attention evidence and `agent-state --explain`
- **Goal:** Make one command answer “what happened?” after an attention ping.
- **Behavior under test:** `agent-state --explain` returns the pane’s best current reason from recent attention evidence or clean fallback.
- **Seam under test:** `agent-state --explain` JSON output
- **Boundary:** Event daemon evidence retention and state CLI output only.
- **Files likely touched:** `shared/steez/bin/agent-eventsd`, `shared/steez/bin/agent-state`, `shared/steez/tests/agent/test-agent-eventsd.sh`, `shared/steez/tests/agent/test-agent-state.sh`
- **Red test name:** `agent-state --explain returns recent terminal reason for the pane`
- **Fixture / harness:** synthetic watch records, synthetic evidence records, and transcript fixtures
- **Isolation rule:** persisted fixture records and direct CLI/library seams only; no live daemon service, tmux, or real user state
- **Determinism rule:** no live daemon clock races; use persisted fixture records and direct CLI/library seams
- **Assertion contract:** `--explain` returns structured `{state, summary, detail, source}` from recent evidence when present and falls back cleanly when absent
- **Green condition:** `agent-state --explain` returns structured explanation data from recent event evidence or falls back cleanly when that evidence is absent.
- **Refactor target:** Keep `agent-state` as the only public inspection surface for spawners.
- **Smoke budget:** `none`
- **Verification command:** `bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd.sh && bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-state.sh`

### S4 — Collapse watch delivery copy to `attention`
- **Goal:** Turn watch notifications into a pager signal instead of an inline explanation channel.
- **Behavior under test:** watch delivery emits one generic `attention` ping and self-clears.
- **Seam under test:** real watch resolution and delivery path through `agent-eventsd`
- **Boundary:** Notification body construction and end-to-end watch runtime only.
- **Files likely touched:** `shared/steez/bin/agent-eventsd`, `shared/steez/tests/agent/test-agent-eventsd-runtime.sh`
- **Red test name:** `watch delivery emits one attention ping and self-clears`
- **Fixture / harness:** existing fake-agent runtime harness with temp HOME, temp state dir, and test-owned tmux server
- **Isolation rule:** fake agent process only; temp HOME, temp state dir, and test-owned tmux server isolate the smoke from real user state
- **Determinism rule:** this is the single approved smoke slice; keep exactly one runtime tmux test and assert message shape plus self-clear only
- **Assertion contract:** delivered notification body is generic `attention`, exactly one ping is emitted, and the watch self-clears
- **Green condition:** The delivered notification body is generic `attention`, exactly one ping is sent, and the watch still self-clears.
- **Refactor target:** Keep exact terminal states internal to the daemon and out of caller-specific message formatting.
- **Smoke budget:** `single allowed smoke`
- **Verification command:** `bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd-runtime.sh`

### S5 — Suppress false-positive watch resolution from fuzzy `blocked:unknown`
- **Goal:** Stop live watches from firing `attention` on heuristic `blocked:unknown` reads while the child is still working.
- **Behavior under test:** transient `blocked:unknown` fallback does not resolve or self-clear a live watch.
- **Seam under test:** `agent-eventsd` reconcile and degraded-resolution logic
- **Boundary:** watch resolution rules and fixture-driven daemon tests only.
- **Files likely touched:** `shared/steez/bin/agent-eventsd`, `shared/steez/tests/agent/test-agent-eventsd.sh`, `specs/agent-events.md`
- **Red test name:** `fuzzy blocked unknown does not resolve a live watch`
- **Fixture / harness:** persisted watch fixtures, synthetic reconcile output, and direct `agent-eventsd` command seams
- **Isolation rule:** fixture-driven daemon state only; no live tmux, no real panes, no wall clock sleeps
- **Determinism rule:** direct watch records and synthetic reconcile results only; no runtime smoke and no real screen scraping
- **Assertion contract:** a transient `blocked:unknown` sample leaves the watch armed, emits no notification, and reserves `blocked:unknown` delivery for explicit timeout or pane-close fallback only
- **Green condition:** Live watches ignore fuzzy `blocked:unknown` samples while the pane is still working, but explicit timeout or pane-close fallback still resolves cleanly when required.
- **Refactor target:** Keep `blocked:unknown` available to `agent-state --explain` without letting it act as a one-shot pager trigger.
- **Smoke budget:** `none`
- **Verification command:** `bash /Users/stevedimakos/Projects/Personal/steez/shared/steez/tests/agent/test-agent-eventsd.sh`

### S6 — Document the new orchestration contract
- **Goal:** Make the reduced hook model and one-command follow-up discoverable.
- **Behavior under test:** public docs and help teach the new `attention` → `agent-state --explain` flow.
- **Seam under test:** `agent-state` help text and checked-in docs
- **Boundary:** Runtime docs and help text only.
- **Files likely touched:** `shared/steez/bin/agent-state`, `skills/spawn-agent/SKILL.md`, `specs/agent-state.md`, `specs/agent-events.md`
- **Red test name:** `agent-state help and spawn-agent docs point spawners to --explain`
- **Fixture / harness:** checked-in help output strings and markdown files
- **Isolation rule:** checked-in text only; no runtime daemon, tmux, or real user state
- **Determinism rule:** text grep only; no runtime execution besides help output if needed
- **Assertion contract:** docs tell spawners to follow `attention` with `agent-state <pane> --explain` and stop teaching parser-specific branching
- **Green condition:** Help text and specs tell spawners to follow an `attention` ping with `agent-state <pane> --explain`, not with parser-specific branching.
- **Refactor target:** Keep public docs aligned with the actual narrow contract.
- **Smoke budget:** `none`
- **Verification command:** `rg -n -- '--explain|attention' /Users/stevedimakos/Projects/Personal/steez/shared/steez/bin/agent-state /Users/stevedimakos/Projects/Personal/steez/skills/spawn-agent/SKILL.md /Users/stevedimakos/Projects/Personal/steez/specs/agent-state.md /Users/stevedimakos/Projects/Personal/steez/specs/agent-events.md`

## Cross-cutting concerns
- **Reliability:** fast evidence should stay primary; transcript and screen parsing remain bounded fallback only.
- **Runtime drift:** Claude and Codex keep different evidence sources, but the public inspection contract becomes the same.
- **Operator ergonomics:** notifications get shorter; the follow-up path gets simpler.
- **State ownership:** short-lived orchestration evidence belongs with `agent-eventsd`, not a parallel Claude-only cache.

## Rollout & rollback
### Rollout
- Land the code and tests.
- Update installer guidance and local `~/.claude/settings.json` to the reduced Claude hook set.
- Reinstall or refresh steez hooks.
- Verify the attention flow by spawning a Claude child and confirming the parent can inspect it with `agent-state --explain`.

### Rollback
- Restore the old `agent-eventsd` notification body and the Claude sidecar path.
- Revert installer hook guidance to the current broad Claude registration set.
- Re-run the agent test suite to confirm the old behavior is back.
