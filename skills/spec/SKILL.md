---
name: spec
description: Turn a planned software change into an execution-ready design spec for /tdd. Reuse the current bead when it fits. Create a parent planning bead only when no suitable bead exists. Use this for planned changes, not bugs or unclear root-cause work.
allowed-tools: Bash, Read, Write
---

# /spec

`/spec` is the front door for planned software changes.

Use `/investigate` instead when behavior is broken or the root cause is still unclear.

## Outcome

Produce a repo-local design spec at `plans/<bead-id>-<topic-slug>-design-spec.md` or stop early with a concise bead note when the right answer is to kill the work or answer directly.

## Core flow

1. Anchor to the current bead. Reuse it when it already matches the work.
2. Read bead context, repo context, and the code that matters.
3. Run Phase 0 challenge with `XY check` and `carry cost` by default.
4. Escalate to `pre-mortem`, `landscape check`, and `smallest disprover` only when the ask is fuzzy, novel, or high blast radius.
5. Decide one of three outcomes: kill, answer directly, or write a design spec.
6. If the outcome is kill or direct answer, record the decision on the bead and stop.
7. If the outcome is spec, use a skeleton-first pass. Create the artifact in `plans/` before asking the user for more.
8. Fill the sections that bead context, repo context, and the code already answer.
9. Ask only load-bearing questions that the code and repo cannot answer.
10. After each answer, update the design spec after each answer.
11. Repeat until the document is executable by `/tdd`.
12. Run hard-failure lint before stopping.
13. Record the artifact path on the bead.

## Design-spec contract

The design spec is the planning source of truth.

Required sections:
- Metadata
- Context
- Goals
- Non-goals
- Constraints & assumptions
- Requirements
- Proposed design
- Interface contracts
- Acceptance criteria
- Verification commands
- Implementation slices

Conditional sections:
- Alternatives considered
- Cross-cutting concerns
- Rollout & rollback
- Open questions


## /tdd handoff

Implementation slices are the contract `/tdd` executes.
Bias toward independent, hermetic, repeatable tests.
Use runtime smoke only for wiring, not state-machine coverage.

Each slice must include:
- Slice ID
- Title
- Goal
- Behavior under test
- Seam under test (public API/CLI first)
- Boundary
- Files likely touched
- Red test name
- Fixture / harness
- Isolation rule
- Determinism rule
- Assertion contract
- Green condition
- Refactor target
- Smoke budget (`none` or `single allowed smoke`)
- Verification command

`/tdd` takes one approved slice at a time.
/tdd does not edit the design spec.
If implementation discovers that slice boundaries, requirements, or acceptance conditions should change, hand the work back to `/spec`.

## Shipped truth

The design spec is planning truth.
Shipped behavior belongs in `specs/*.md`.
Do not promote the design spec in place.

## Lint gate

Treat these as hard failures:
- missing verification command
- missing failing test for any slice
- slice covers more than one behavior
- missing seam, fixture / harness, isolation rule, determinism rule, assertion contract, or smoke budget
- real network, clock, home-dir state, or shared machine state without explicit smoke exemption
- implementation-detail assertions where user-visible behavior should be asserted
- more than one live runtime smoke slice
- unowned open question
- missing boundary or interface contract
- bloated spec
