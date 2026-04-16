# /spec skill design spec

## Metadata
- Title: `/spec` skill
- Status: Draft
- Owner: steez
- Branch: `main`
- Linked bead: `steez-wn6`
- Blocks: `steez-8e8` (`/tdd`)
- Created: 2026-04-15
- Artifact: `plans/steez-wn6-spec-skill-design-spec.md`

## Context
steez has too many planning front doors for software-change work. `/workshop`, `/office-hours`, three plan-review skills, and `/autoplan` create routing overhead and low-usage surfaces for one real job: turn an idea into an implementation contract.

`/spec` replaces that stack. It becomes the one front door for planned software changes. It accepts fuzzy or well-formed requests, pressure-tests them enough to avoid bad plans, writes a repo-local design-spec artifact, and stops when `/tdd` can implement approved slices without reconstructing the conversation.

`/investigate` stays separate. Bug diagnosis and root-cause work are not planning.

## Goals
- Make `/spec` the default entrypoint for planned software changes.
- Reuse the current bead when one already matches the work.
- Produce a repo-local design spec at `plans/<bead-id>-<topic-slug>-design-spec.md`.
- Use a skeleton-first iterative loop instead of blank-form Q&A.
- Emit implementation slices that `/tdd` can execute one at a time.
- Reduce front-door confusion by deprecating the old planning stack.

## Non-goals
- Implementing the feature.
- Doing bug investigation or root-cause diagnosis.
- Letting `/tdd` rewrite the design spec.
- Treating the design spec as the shipped runtime spec.
- Auto-creating execution beads for every slice during planning.
- Preserving the old planning stack as first-class workflow.

## Constraints & assumptions
- `/investigate` remains the front door for broken behavior or unclear root cause.
- `/tdd` remains blocked on `/spec` and consumes approved slices from the design spec.
- The markdown file is the planning source of truth. The bead is the control plane.
- `/spec` reuses the current bead as the parent whenever the request already maps to one.
- `/spec` asks only questions that code and repo context cannot answer.
- Extra challenge lenses are proportional to fuzziness or blast radius, not mandatory on every run.
- `specs/*.md` stays reserved for shipped runtime behavior after implementation lands.

## Requirements
- **R1.** When a planned software-change request already has a suitable bead, `/spec` shall reuse that bead as the parent planning bead.
- **R2.** When no suitable bead exists, `/spec` shall create a parent planning bead before writing a design spec.
- **R3.** `/spec` shall write or update a design spec at `plans/<bead-id>-<topic-slug>-design-spec.md`.
- **R4.** `/spec` shall start from a skeleton design spec, not a blank questionnaire and not a one-shot full draft.
- **R5.** `/spec` shall run `XY check` and `carry cost` by default.
- **R6.** When fuzziness, novelty, or blast radius warrants it, `/spec` shall also apply `pre-mortem`, `landscape check`, and `smallest disprover`.
- **R7.** `/spec` shall decide one of three outcomes: kill, answer directly, or write a design spec.
- **R8.** When the outcome is kill or direct answer, `/spec` shall record a concise written decision on the bead.
- **R9.** `/spec` shall include the required design-spec sections and include conditional sections only when they carry real content.
- **R10.** `/spec` shall ask only the smallest set of load-bearing questions that code and repo context cannot answer.
- **R11.** `/spec` shall update the design spec after each user answer.
- **R12.** `/spec` shall emit implementation slices with stable `Slice ID`, `Red test name`, `Files likely touched`, and `Verification command` fields.
- **R13.** `/spec` shall fail the run when hard-failure linting finds a missing verification command, missing failing test, unowned open question, missing boundary/interface contract, or bloated spec.
- **R14.** `/spec` shall stop when `/tdd` could implement from the document without reconstructing the conversation.
- **R15.** `/spec` shall not treat the design spec as the final shipped runtime spec; shipped behavior updates belong in `specs/*.md` after implementation lands.

## Proposed design
### Flow
1. Anchor to the current bead.
2. Read bead context, repo context, and relevant code.
3. Run adaptive Phase 0 challenge.
4. Decide: kill, answer directly, or spec.
5. If spec, create a skeleton design spec at `plans/<bead-id>-<topic-slug>-design-spec.md`.
6. Fill what the code and repo already answer.
7. Ask only load-bearing unresolved questions.
8. Rewrite the design spec after each answer.
9. Repeat until the document is executable by `/tdd`.
10. Run hard-failure lint.
11. Record the artifact path on the bead and stop.

### Adaptive Phase 0
- Default lenses:
  - XY check
  - carry cost
- Escalation lenses:
  - pre-mortem
  - landscape check
  - smallest disprover

The point is to keep the challenge logic from `/workshop` without preserving its ceremony.

### Design-spec shape
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

## Interface contracts
### Inputs
- Current bead context.
- User request.
- Relevant repo files and existing code.

### Outputs
- Updated parent bead.
- Design-spec artifact at `plans/<bead-id>-<topic-slug>-design-spec.md`.
- Implementation slices that `/tdd` can execute.

### `/tdd` handoff
- `/tdd` takes one approved slice at a time.
- `/tdd` does not edit the design spec.
- If implementation discovers that slice boundaries, requirements, or acceptance conditions must change, work hands back to `/spec`.
- Child execution beads later depend on the parent planning bead and cite `spec_path` plus `slice_id`.

### Runtime-spec handoff
- The design spec is upstream planning only.
- After implementation ships, changed behavior gets a canonical runtime spec in `specs/*.md`.
- The design spec is not promoted in place.

## Alternatives considered
### Keep the old planning stack
Rejected. It preserves low-usage front doors and forces routing decisions the user should not have to make.

### Blank-form Q&A first
Rejected. It turns `/spec` into a form wizard and asks the user for facts the codebase already knows.

### One-shot full draft first
Rejected. It overcommits too early and leaves less room for iterative tightening.

### Machine-local design specs under `~/.steez/projects/`
Rejected. They are weak for branch diffing, repo review, and cold-start across clones or agents.

## Acceptance criteria
- **AC1.** Given a planned software-change bead, when `/spec` runs, then it reuses that bead when suitable and writes or updates `plans/<bead-id>-<topic-slug>-design-spec.md`.
- **AC2.** Given a clear ask, when `/spec` runs, then it applies `XY check` and `carry cost` by default and only escalates to the other lenses when needed.
- **AC3.** Given a missing decision that code cannot answer, when `/spec` runs, then it asks a sharp load-bearing question and rewrites the design spec after the answer.
- **AC4.** Given a completed `/spec` run, when `/tdd` reads the design spec, then it can choose a slice with a stable slice ID, named failing test, likely files, and verification command.
- **AC5.** Given a kill or direct-answer outcome, when `/spec` finishes, then the bead contains a concise written decision record.
- **AC6.** Given shipped behavior from this feature, when the implementation lands, then the repo gets a canonical runtime spec under `specs/` instead of promoting the design spec in place.

## Verification commands
```bash
REPO_ROOT=$(git rev-parse --show-toplevel) && \
  go test "$REPO_ROOT/internal/installer" -run TestLoadManifestIncludesSpecSkillAndWorkflowCategory

REPO_ROOT=$(git rev-parse --show-toplevel) && \
  cd "$REPO_ROOT/shared/steez" && \
  bun test test/skill-validation.test.ts --grep spec

REPO_ROOT=$(git rev-parse --show-toplevel) && \
  test -f "$REPO_ROOT/skills/spec/SKILL.md" && \
  rg -n 'skeleton-first|design-spec|/tdd does not edit the design spec' "$REPO_ROOT/skills/spec/SKILL.md"

REPO_ROOT=$(git rev-parse --show-toplevel) && \
  test -f "$REPO_ROOT/specs/spec.md"
```

## Implementation slices
### S1 — Add manifest entry for `/spec`
- **Goal:** Make the new skill installable and discoverable.
- **Boundary:** Manifest and installer validation only.
- **Files likely touched:** `skills.json`, `internal/installer/manifest_test.go`
- **Red test name:** `TestLoadManifestIncludesSpecSkillAndWorkflowCategory`
- **Green condition:** Manifest loading proves `/spec` exists and is included in the workflow category.
- **Refactor target:** Keep manifest fixtures readable and minimal.
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && go test "$REPO_ROOT/internal/installer" -run TestLoadManifestIncludesSpecSkillAndWorkflowCategory`

### S2 — Add `/spec` skill definition and validation harness
- **Goal:** Create the skill and make its contract testable.
- **Boundary:** Skill file plus validation test only.
- **Files likely touched:** `skills/spec/SKILL.md`, `shared/steez/test/skill-validation.test.ts`, `shared/steez/package.json`
- **Red test name:** `spec skill contract`
- **Green condition:** Validation fails before the skill exists and passes once the skill file encodes the core contract.
- **Refactor target:** Keep the validation test declarative so future skills can reuse the pattern.
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT/shared/steez" && bun test test/skill-validation.test.ts --grep spec`

### S3 — Encode the skeleton-first iterative flow
- **Goal:** Make `/spec` write a skeleton design spec, fill inferred sections, and tighten iteratively.
- **Boundary:** `/spec` workflow only.
- **Files likely touched:** `skills/spec/SKILL.md`
- **Red test name:** `spec skill skeleton-first loop`
- **Green condition:** The skill explicitly says to read context, write a skeleton, ask only load-bearing questions, and update the design spec after each answer.
- **Refactor target:** Keep the workflow readable enough that `/tdd` can follow the artifact without hidden assumptions.
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && rg -n 'skeleton-first|load-bearing questions|update the design spec after each answer' "$REPO_ROOT/skills/spec/SKILL.md"`

### S4 — Encode `/tdd` handoff and writeback guard
- **Goal:** Lock the planning-to-implementation boundary.
- **Boundary:** Contract language only.
- **Files likely touched:** `skills/spec/SKILL.md`, `specs/spec.md`
- **Red test name:** `spec to tdd handoff contract`
- **Green condition:** `/spec` defines slices for `/tdd`, and the runtime spec documents that `/tdd` cannot rewrite the design spec.
- **Refactor target:** Keep one owner for planning truth and one owner for shipped truth.
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && rg -n '/tdd does not edit the design spec|specs/\*\.md' "$REPO_ROOT/skills/spec/SKILL.md" "$REPO_ROOT/specs/spec.md"`

### S5 — Add canonical runtime spec for shipped `/spec` behavior
- **Goal:** Document the shipped behavior in `specs/` once the skill lands.
- **Boundary:** Runtime spec only.
- **Files likely touched:** `specs/spec.md`, `specs/README.md`
- **Red test name:** `spec runtime spec exists`
- **Green condition:** `specs/spec.md` exists and documents the shipped `/spec` interface and behavior.
- **Refactor target:** Keep runtime truth separate from planning history.
- **Verification command:** `REPO_ROOT=$(git rev-parse --show-toplevel) && test -f "$REPO_ROOT/specs/spec.md"`

## Cross-cutting concerns
- **Cold-start readability:** The design spec must be scannable by a future agent with no chat history.
- **Doc drift:** The bead and design spec must not become competing sources of truth.
- **Planning sprawl:** Conditional sections stay conditional to avoid filler.
- **Deprecation hygiene:** The old planning skills should stop being presented as the primary workflow surface.

## Rollout & rollback
### Rollout
1. Add `/spec` to the manifest and workflow surface.
2. Ship the skill contract and validation.
3. Add the canonical runtime spec at `specs/spec.md`.
4. Leave `/tdd` blocked until `/spec` is shipped.
5. Mark the old planning stack deprecated in the primary surfaces.

### Rollback
- Remove `/spec` from `skills.json`.
- Remove `skills/spec/`.
- Remove `specs/spec.md`.
- Restore the old planning stack as the primary workflow surface if needed.
