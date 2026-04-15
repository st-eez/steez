# spec

**Paths:**
- `skills/spec/SKILL.md`

Turns a planned software change into a repo-local design spec that `/tdd` can execute slice by slice. `/spec` is for planning. `/investigate` stays the front door for broken behavior and unclear root cause work.

## Installation Surface

- Claude installs `/spec` at `~/.claude/skills/spec`.
- Codex installs `/spec` at `~/.codex/skills/spec`.

## Inputs

- Current bead context
- User request
- Relevant repo files and code

## Outputs

- Updated parent bead
- Design-spec artifact at `plans/<bead-id>-<topic-slug>-design-spec.md`
- Implementation slices that `/tdd` can execute

## Behavioral Contracts

1. Reuse the current bead when it already matches the work. Create a parent planning bead only when no suitable bead exists.
2. Run `XY check` and `carry cost` by default. Escalate to `pre-mortem`, `landscape check`, and `smallest disprover` only when the ask warrants it.
3. Decide one of three outcomes: kill, answer directly, or write a design spec.
4. When the outcome is kill or direct answer, record a concise written decision on the bead.
5. When the outcome is spec, write or update `plans/<bead-id>-<topic-slug>-design-spec.md`.
6. The design spec uses required sections for metadata, context, goals, non-goals, constraints, requirements, proposed design, interface contracts, acceptance criteria, verification commands, and implementation slices.
7. Ask only the smallest set of unresolved questions the code cannot answer.
8. Run hard-failure lint before stopping.

## /tdd Handoff

- `/tdd` takes one approved slice at a time.
- /tdd does not edit the design spec.
- If execution reveals that the planning contract should change, the work hands back to `/spec`.

## Runtime-spec Handoff

- The design spec is upstream planning only.
- Shipped behavior belongs in `specs/*.md`.
- The design spec is not promoted in place.
