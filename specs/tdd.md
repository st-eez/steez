# tdd

**Paths:**
- `skills/tdd/SKILL.md`

Executes one approved slice from a `/spec` design spec with a strict red → green → refactor loop. `/tdd` is for execution. `/spec` stays the planning source of truth.

## Installation Surface

- Claude installs `/tdd` at `~/.claude/skills/tdd`.
- Codex installs `/tdd` at `~/.codex/skills/tdd`.

## Inputs

- Current bead context
- Design-spec path for the parent planning bead
- One approved slice ID
- Relevant repo files and tests

## Outputs

- Updated parent bead via `bd update --append-notes`
- Production changes scoped to the approved slice
- Green verification evidence for the slice

## Behavioral Contracts

1. `/tdd` takes one approved slice at a time.
2. /tdd does not edit the design spec.
3. Run the slice-contract precheck before any production-code change.
4. Refuse the run when the slice is missing required contract fields, then hand the work back to `/spec`.
5. Produce a named failing test before changing production code.
6. Capture red evidence, ship the minimum green change, and rerun the slice verification command after at most one refactor pass.
7. Stop and hand the work back to `/spec` when execution reveals drift, a new seam, a new fixture model, or a smoke-budget breach.
8. Use the verifier subagent after green when the slice includes non-trivial backend or API behavior.
9. Exercise user-visible UI through `/browse` after green, or record explicitly that browse could not run.
10. Append slice evidence to the parent bead with `bd update --append-notes`.
11. Treat missing slice ID, failed precheck, missing failing-test evidence, or missing verification-command evidence as hard failures.
