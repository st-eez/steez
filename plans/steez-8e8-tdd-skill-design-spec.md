# /tdd skill design spec

## Metadata
- Title: `/tdd` skill
- Status: Draft
- Owner: steez
- Branch: `main`
- Linked bead: `steez-8e8`
- Depends on: `steez-wn6` (`/spec`)
- Created: 2026-04-16
- Artifact: `plans/steez-8e8-tdd-skill-design-spec.md`

## Context
`/spec` now produces design specs whose `Implementation slices` section is the contract `/tdd` is meant to execute. There is no companion skill yet, so the slice contract has no consumer and `/spec` runs land in `plans/` without a disciplined implementation loop.

`/tdd` closes that gap. It takes one approved slice at a time, validates the slice contract is complete, drives a strict red → green → refactor loop bound by the slice's seam and assertion contract, and produces evidence that a named failing test became green from a minimum implementation. When the slice is underspecified or drifts during execution, `/tdd` stops and hands the work back to `/spec` instead of inventing scope.

This split keeps planning truth in the design spec and execution truth in the run log. `/tdd` does not edit the design spec.

## Goals
- Make `/tdd` the one skill that executes an approved slice from a `/spec` design spec.
- Force a strict slice-contract precheck before any production code change.
- Encode the red → green → refactor loop, including named failing test, minimum green, and refactor target, as the only loop `/tdd` runs.
- Reject underspecified slices and hand them back to `/spec` instead of patching gaps.
- Stop and hand back to `/spec` when execution reveals slice drift, a new seam, a new fixture model, or a smoke-budget breach.
- Run the slice's verification command, plus verifier and browser QA where the slice warrants it, before declaring a slice done.
- Record evidence on the bead so the next agent can cold-start the next slice.

## Non-goals
- Replacing `/investigate` for bug diagnosis or root-cause work.
- Letting `/tdd` write or edit the design spec at `plans/<bead-id>-<topic-slug>-design-spec.md`.
- Choosing test category, fixture model, or smoke budget outside the slice contract.
- Running multiple slices in one invocation.
- Auto-creating execution beads for slices during the run (the parent planning bead is the control plane).
- Promoting the design spec to `specs/*.md` (that handoff is owned by `/spec` after shipped behavior lands).

## Constraints & assumptions
- `/spec` is the only producer of slice contracts that `/tdd` consumes.
- A slice contract is the block in `Implementation slices` for one `Slice ID`.
- The user signals "this slice is approved" by invoking `/tdd` with the slice ID (or by pointing at the design spec when only one slice is unclaimed).
- `/tdd` runs against the parent planning bead; child execution beads are not required at execution time.
- In code with existing tests, test-first is strict: a named failing test must exist before any production-code change.
- For a slice with no usable existing test bed, `/tdd` may add the smallest reproducible test scaffold inside the same slice before turning red, but it must still produce a named failing test and never assert against placeholder behavior.
- Verifier handoff and browser QA are not optional for slices whose green condition includes user-visible UI or non-trivial backend behavior; they are gated by slice content, not by skill mode.
- Evidence is recorded on the parent bead via `bd update --append-notes`, not in a new file under `plans/` or `specs/`.
- `/tdd` reuses existing repo conventions for tests; it does not invent a test runner, fixture loader, or harness.

## Requirements
- **R1.** `/tdd` shall accept one approved slice ID from a `/spec` design spec and act on exactly one slice per invocation.
- **R2.** `/tdd` shall run a slice-contract precheck that proves the slice declares `Behavior under test`, `Seam under test`, `Fixture / harness`, `Isolation rule`, `Determinism rule`, `Assertion contract`, `Smoke budget`, `Red test name`, and `Verification command` before touching production code.
- **R3.** When the precheck fails, `/tdd` shall stop, record a concise reason on the bead, and direct the user back to `/spec` for that slice.
- **R4.** `/tdd` shall produce a named failing test (matching the slice's `Red test name`) and capture observable red evidence before any production-code change.
- **R5.** `/tdd` shall change only the minimum production code required to satisfy the slice's `Assertion contract` and `Green condition`.
- **R6.** `/tdd` shall run the slice's `Verification command` to confirm green and capture the result as evidence.
- **R7.** `/tdd` shall apply at most one refactor pass inside the slice, scoped to the slice's `Refactor target`, and rerun the verification command after refactoring to confirm still-green.
- **R8.** `/tdd` shall not introduce a second behavior, a new seam, a new fixture model, or smoke beyond the slice's `Smoke budget` during the loop.
- **R9.** When execution reveals slice drift, a new seam, a new fixture model, or a smoke-budget breach, `/tdd` shall stop, record the drift on the bead, and hand the work back to `/spec` without finishing the slice.
- **R10.** For slices whose green condition includes non-trivial backend or API behavior, `/tdd` shall hand the change to the `verifier` subagent and record `PASS`, `FAIL`, or `PARTIAL` evidence on the bead before declaring the slice done.
- **R11.** For slices whose green condition includes user-visible UI, `/tdd` shall exercise the change through `/browse` (or report explicitly that the UI cannot be exercised) before declaring the slice done.
- **R12.** `/tdd` shall append slice-execution evidence (red, green, refactor-green, verifier verdict, browser evidence, slice ID) to the parent planning bead via `bd update --append-notes`.
- **R13.** `/tdd` shall never edit the design spec at `plans/<bead-id>-<topic-slug>-design-spec.md`.
- **R14.** `/tdd` shall fail the run when its hard-failure lint finds a missing slice ID, a failed slice-contract precheck, a green claim without a captured failing test, or a slice closed without running its verification command.
- **R15.** `/tdd` shall be installable through the existing manifest, validated by the existing skill-validation harness, and documented by a canonical runtime spec at `specs/tdd.md`.

## Proposed design
### Flow
1. Resolve the parent planning bead and the design spec path from the bead.
2. Resolve the target slice from the user-supplied slice ID (or single unclaimed slice).
3. Run the slice-contract precheck. Stop on failure.
4. Choose the smallest concrete first red test that fits the slice's `Behavior under test`, `Seam under test`, and `Assertion contract`.
5. Add or run that one failing test. Capture observable red evidence.
6. Implement the minimum code that satisfies the `Green condition`.
7. Run the slice's `Verification command`. Capture green evidence.
8. Apply at most one refactor pass scoped to the `Refactor target`. Rerun the verification command. Capture still-green evidence.
9. If the slice's green condition includes non-trivial backend or API behavior, hand off to the `verifier` subagent and capture verdict.
10. If the slice's green condition includes user-visible UI, exercise the change through `/browse` and capture evidence (or report inability explicitly).
11. Append the full evidence trail to the parent planning bead via `bd update --append-notes`. Record the slice ID and the verification command that closed it.
12. Run hard-failure lint. Stop.

### Slice-contract precheck
A slice is executable only if its block declares all of:
- `Slice ID`, `Title`, `Goal`
- `Behavior under test`, `Seam under test`, `Boundary`, `Files likely touched`
- `Red test name`, `Fixture / harness`, `Isolation rule`, `Determinism rule`, `Assertion contract`
- `Green condition`, `Refactor target`, `Smoke budget`, `Verification command`

If any field is missing or contradictory, `/tdd` stops and points the user back to `/spec`.

### Loop discipline
- One behavior, one seam, one fixture model per slice.
- One named failing test before any production-code change.
- Minimum green, then at most one refactor pass.
- No second slice, no scope creep, no opportunistic refactors outside the slice's `Refactor target`.
- Smoke is allowed only when the slice's `Smoke budget` says so.

### Drift detection
During the loop, `/tdd` stops and hands back to `/spec` if any of these become true:
- The slice needs a second behavior to turn green.
- The slice needs a new seam, a new public API, or a new fixture model.
- The slice cannot be made green without exceeding its `Smoke budget`.
- The slice's `Assertion contract` no longer matches the proven user-visible behavior.

### Evidence
For each invocation, `/tdd` records on the parent bead:
- Slice ID and design-spec path
- Red test name and red evidence (failing output)
- Minimum green diff summary and green evidence (verification command output)
- Refactor summary and still-green evidence
- Verifier verdict (when applicable)
- Browser evidence (when applicable)
- Final slice status (`done`, `handed back to /spec`, or `blocked`)

## Interface contracts
### Inputs
- Parent planning bead (resolved from current bead context).
- Design-spec path stored on the bead (or inferred from `plans/<bead-id>-<topic-slug>-design-spec.md`).
- Slice ID (user-supplied, or the single unclaimed slice).

### Outputs
- Updated parent bead with appended evidence notes.
- Production-code changes scoped to the slice's `Files likely touched` and `Boundary`.
- A green run of the slice's `Verification command`.
- Optional verifier verdict and browser evidence.

### `/spec` handoff (drift case)
- `/tdd` does not patch the design spec to make a slice work.
- On drift, `/tdd` records a concise drift note on the bead and stops.
- `/spec` is responsible for rewriting the slice and re-approving it.

### Verifier handoff
- Slices with non-trivial backend or API behavior trigger a verifier handoff after green.
- The verifier brief includes the slice ID, files changed, the slice's `Assertion contract`, and the slice's `Verification command`.
- A `FAIL` verdict reopens the slice. A `PARTIAL` verdict is recorded on the bead with what remains unverified.

### Browser-QA handoff
- Slices with user-visible UI trigger a `/browse` exercise after green.
- If the UI cannot be exercised in the current environment, `/tdd` records that explicitly and does not claim done silently.

### Runtime-spec handoff
- The design spec is planning truth.
- Shipped behavior of `/tdd` belongs in `specs/tdd.md` after the skill lands.
- The design spec is not promoted in place.

## Alternatives considered
### Let `/tdd` patch the design spec when a slice is underspecified
Rejected. It collapses the planning/execution boundary `/spec` was created to enforce and lets execution invent scope.

### Run all approved slices in one `/tdd` invocation
Rejected. It hides drift and turns evidence into a single opaque blob. One slice per invocation keeps the loop tight and the evidence reviewable.

### Make verifier and browser QA optional flags
Rejected. The slice content already says whether the change is non-trivial backend or user-visible UI. Gating by slice content avoids skill-mode toggles.

### Auto-create a child execution bead per slice
Rejected for now. The parent planning bead is the simplest control plane, and slice evidence on the parent already supports cold-start.

### Use a separate evidence file under `plans/`
Rejected. The bead is the control plane and already supports `--append-notes`. A second artifact creates two sources of truth for execution evidence.

## Acceptance criteria
- **AC1.** Given an approved slice with a complete contract, when `/tdd` runs against it, then it produces a named failing test, a minimum green change, a refactor-green run, and the slice's `Verification command` passing, with evidence appended to the parent bead.
- **AC2.** Given a slice missing any required contract field, when `/tdd` runs against it, then `/tdd` stops, records a precheck-fail note on the bead, and directs the user back to `/spec`.
- **AC3.** Given a slice whose green path requires a second behavior or a new seam, when `/tdd` discovers that mid-loop, then `/tdd` stops, records a drift note on the bead, and hands the work back to `/spec` without finishing the slice.
- **AC4.** Given a slice with non-trivial backend or API behavior, when `/tdd` reaches green, then `/tdd` hands the change to the `verifier` subagent and records the verdict on the bead before declaring the slice done.
- **AC5.** Given a slice with user-visible UI, when `/tdd` reaches green, then `/tdd` exercises the change through `/browse` and records evidence (or records an explicit inability to exercise) before declaring the slice done.
- **AC6.** Given any `/tdd` run, when the run finishes, then the design spec at `plans/<bead-id>-<topic-slug>-design-spec.md` is unchanged.
- **AC7.** Given the shipped `/tdd` skill, when the manifest loader and skill-validation harness run, then `/tdd` is present in the workflow category, the SKILL.md encodes the slice-contract precheck and red → green → refactor loop, and `specs/tdd.md` documents the runtime contract.

## Verification commands
```bash
REPO_ROOT=$(git rev-parse --show-toplevel) && \
  go test "$REPO_ROOT/internal/installer" -run TestLoadManifestIncludesTddSkillAndWorkflowCategory

REPO_ROOT=$(git rev-parse --show-toplevel) && \
  cd "$REPO_ROOT/shared/steez" && \
  bun test test/skill-validation.test.ts --grep tdd

REPO_ROOT=$(git rev-parse --show-toplevel) && \
  test -f "$REPO_ROOT/skills/tdd/SKILL.md" && \
  rg -n 'slice-contract precheck|red.*green.*refactor|Red test name|hand back to /spec|hard-failure lint' "$REPO_ROOT/skills/tdd/SKILL.md"

REPO_ROOT=$(git rev-parse --show-toplevel) && \
  test -f "$REPO_ROOT/specs/tdd.md" && \
  rg -n '/tdd does not edit the design spec|one approved slice|verifier|browse' "$REPO_ROOT/specs/tdd.md"
```

## Implementation slices
### S1 — Add manifest entry for `/tdd`
- **Goal:** Make `/tdd` installable and discoverable as a workflow skill.
- **Behavior under test:** Manifest loader exposes `/tdd` in the `workflow` category alongside `/spec`.
- **Seam under test:** `internal/installer` manifest loader and category resolution.
- **Boundary:** Manifest entry and installer validation only.
- **Files likely touched:** `skills.json`, `internal/installer/manifest_test.go`
- **Red test name:** `TestLoadManifestIncludesTddSkillAndWorkflowCategory`
- **Fixture / harness:** Synthetic manifest fixture inside `manifest_test.go` plus the real `skills.json`.
- **Isolation rule:** Manifest fixtures and the checked-in `skills.json` only; no live install, no symlink mutation, no real `~/.steez` writes.
- **Determinism rule:** Pure JSON parse and category lookup; no clock, no network, no home-dir state.
- **Assertion contract:** Loading the manifest proves `/tdd` is registered and listed under the `workflow` category.
- **Green condition:** Manifest loading proves `/tdd` exists with a description and is included in the workflow category alongside `/spec`.
- **Refactor target:** Keep manifest fixtures readable and minimal; do not duplicate skill metadata.
- **Smoke budget:** `none`
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && go test "$REPO_ROOT/internal/installer" -run TestLoadManifestIncludesTddSkillAndWorkflowCategory`

### S2 — Add `/tdd` skill definition and validation harness
- **Goal:** Create `skills/tdd/SKILL.md` and prove its contract through `skill-validation.test.ts`.
- **Behavior under test:** `skills/tdd/SKILL.md` exists and encodes the slice-contract precheck plus the red → green → refactor loop.
- **Seam under test:** `shared/steez/test/skill-validation.test.ts` contract checker against `skills/tdd/SKILL.md`.
- **Boundary:** Skill file plus its validation test only.
- **Files likely touched:** `skills/tdd/SKILL.md`, `shared/steez/test/skill-validation.test.ts`
- **Red test name:** `tdd skill contract`
- **Fixture / harness:** The same `expectContract` helper used for `/spec`; file-system reads against the checked-in skill file.
- **Isolation rule:** Read-only file checks against the repo; no shell execution, no symlink, no `~/.claude` mutation.
- **Determinism rule:** Pure regex/text checks; no clock, no network.
- **Assertion contract:** Validation fails before the skill exists and passes once the skill encodes its required contract phrases (frontmatter `name: tdd`, slice-contract precheck, red → green → refactor, hand back to `/spec`, hard-failure lint).
- **Green condition:** `bun test test/skill-validation.test.ts --grep tdd` passes against the new skill file.
- **Refactor target:** Keep the validation pattern declarative so future workflow skills reuse it.
- **Smoke budget:** `none`
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT/shared/steez" && bun test test/skill-validation.test.ts --grep tdd`

### S3 — Finalize `/tdd` contract, close gates, and runtime spec
- **Goal:** Finish the remaining `/tdd` skill policy and shipped docs in one pass.
- **Behavior under test:** The shipped `/tdd` skill encodes the slice-contract precheck, red → green → refactor loop, drift handback, verifier/browser-QA/bead-evidence close gates, and canonical runtime spec.
- **Seam under test:** `skills/tdd/SKILL.md`, `shared/steez/test/skill-validation.test.ts`, `specs/tdd.md`, and `specs/README.md`
- **Boundary:** Skill contract text, validation harness, and runtime docs only.
- **Files likely touched:** `skills/tdd/SKILL.md`, `shared/steez/test/skill-validation.test.ts`, `specs/tdd.md`, `specs/README.md`
- **Red test name:** `tdd skill finalization contract`
- **Fixture / harness:** `expectContract` against `skills/tdd/SKILL.md`, `specs/tdd.md`, and `specs/README.md`, plus the existing `bun test ... --grep tdd` validation seam.
- **Isolation rule:** Read-only file checks and checked-in docs only; no live installs, no browser run, no real agent invocation, no home-dir mutation.
- **Determinism rule:** Pure regex/text checks and existing validation harness only; no clock, no network.
- **Assertion contract:** Validation proves SKILL.md contains the slice-contract precheck, red → green → refactor loop, drift handback, verifier/browser-QA/bead-evidence gates, and that `specs/tdd.md` plus `specs/README.md` document the shipped runtime contract.
- **Green condition:** `bun test test/skill-validation.test.ts --grep tdd` passes, `specs/tdd.md` exists with the required contract phrases, and `specs/README.md` links to it.
- **Refactor target:** Keep the policy text compact and avoid duplicating the design spec inside the skill or runtime spec.
- **Smoke budget:** `none`
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT/shared/steez" && bun test test/skill-validation.test.ts --grep tdd && test -f "$REPO_ROOT/specs/tdd.md" && rg -n '/tdd does not edit the design spec|one approved slice|verifier|browse' "$REPO_ROOT/specs/tdd.md" && rg -n '\[tdd\]\(\./tdd\.md\)' "$REPO_ROOT/specs/README.md"`

## Cross-cutting concerns
- **Cold-start readability:** Slice evidence on the bead must be scannable by a future agent with no chat history.
- **Doc drift:** The bead carries evidence; the design spec carries plan; the runtime spec carries shipped behavior. Three roles, three owners.
- **Loop discipline:** Drift handback only works if `/tdd` actually stops; the skill must phrase the stop as non-negotiable.
- **Evidence noise:** Bead notes should record outcomes and commands, not full transcripts.

## Rollout & rollback
### Rollout
1. Add `/tdd` to `skills.json` under the `workflow` category.
2. Ship `skills/tdd/SKILL.md` with the slice-contract precheck, red → green → refactor loop, drift handback, and close-gate language.
3. Extend `shared/steez/test/skill-validation.test.ts` with the new `tdd` contract tests.
4. Add `specs/tdd.md` and link it from `specs/README.md` under Workflow Specs.
5. Verify the full chain by running `/spec` then `/tdd` against a small follow-up bead and confirming bead evidence lands.

### Rollback
- Remove `/tdd` from `skills.json`.
- Remove `skills/tdd/`.
- Remove `specs/tdd.md` and the README link.
- Drop the `tdd` cases from `skill-validation.test.ts`.

## Open questions
None. The bead's two original opens are answered by repo context: test-first is strict in code with tests (per `ren.md`), and verifier and browser QA are slice-content-gated close steps that run after green inside the same `/tdd` invocation.
