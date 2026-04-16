---
name: tdd
description: Execute one approved /spec slice with a strict red → green → refactor loop. Stop on drift.
allowed-tools: Bash, Read, Write
---

# /tdd

`/tdd` executes one approved slice from a `/spec` design spec.

## Outcome

Turn one approved slice green with a named failing test and verification evidence, or stop and hand back to /spec.

## Core flow

1. Anchor to the parent planning bead, resolve the design spec, and pick one approved slice.
2. /tdd does not edit the design spec.
3. Run a slice-contract precheck before any production-code change.
4. Require the slice contract to declare the Behavior under test, Seam under test, Fixture / harness, Isolation rule, Determinism rule, Assertion contract, Smoke budget, Red test name, and Verification command.
5. If the slice-contract precheck fails, stop, record why on the bead, and hand back to /spec.
6. Write or run one named failing test that matches the slice's `Red test name`.
7. Capture red evidence before changing production code.
8. Ship the minimum code needed to satisfy the slice.
9. Run the slice's verification command to turn green.
10. Apply at most one refactor pass inside the slice, then rerun the verification command.
11. Close the slice gates before stopping.
12. Run hard-failure lint before stopping.

## Loop discipline

Use one red → green → refactor loop per slice.
Stay inside one approved slice.
Do not invent scope.
Hand back to /spec when the slice drifts.

## Close gates

If the slice reaches green with non-trivial backend or API behavior, hand it to the verifier subagent and record the verdict.
If the slice reaches green with user-visible UI, exercise it through /browse, or record explicitly that browse could not run.
Append slice evidence to the parent bead with `bd update --append-notes`.
Record the slice ID, red evidence, green evidence, refactor-green evidence, and final status.

## Lint gate

Treat these as hard-failure lint:
- missing approved slice ID
- failed slice-contract precheck
- no captured failing test before green
- slice closed without running its verification command
