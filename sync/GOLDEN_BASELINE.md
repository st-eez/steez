# Golden Baseline: gstack → steez Transform Catalog

> Test oracle for the steez-sync overlay engine.
> Generated from manual diff of gstack-ship vs steez-ship, plus heading census of all 32 gstack skills.
> Bead: steez-arm

## Skill Mapping

### Synced from gstack (25 skills)

All have preambles and are candidates for overlay transforms:

autoplan, benchmark, browse, canary, codex, connect-chrome, cso,
design-consultation, design-html, design-review, design-shotgun,
document-release, investigate, land-and-deploy, office-hours,
plan-ceo-review, plan-design-review, plan-eng-review, qa, qa-only,
retro, review, setup-browser-cookies, setup-deploy, ship

### gstack-only — NOT synced (6 skills, `skip: true`)

| Skill | Reason |
|-------|--------|
| careful | Micro-skill, no preamble, no steez equivalent |
| freeze | Micro-skill, no preamble, no steez equivalent |
| guard | Micro-skill, no preamble, no steez equivalent |
| unfreeze | Micro-skill, no preamble, no steez equivalent |
| gstack-upgrade | gstack-specific update mechanism, no steez equivalent |
| learn | Learnings system not ported to steez (replaced by `bd remember`) |

### steez-only — custom skills (8 skills, `skip: true`)

agenda, audit, claude-spawn, jira, loop-prompt, reminders, sharpen-skill, tmux

---

## 1. Frontmatter Transforms

Applied to every synced skill.

| Field | Transform | Example |
|-------|-----------|---------|
| `name` | Prepend `steez-` | `ship` → `steez-ship` |
| `description` | Remove `(gstack)`, collapse multi-line `\|` to single-line | See ship example below |
| `description` | Reword proactive language | `"Proactively invoke this skill (do NOT push/PR directly)"` → `"Proactively suggest"` |
| `preamble-tier` | Unchanged | — |
| `version` | Unchanged | — |
| `allowed-tools` | Unchanged | — |

### Ship description example

**gstack** (multi-line YAML literal):
```yaml
description: |
  Ship workflow: detect + merge base branch, run tests, review diff, bump VERSION,
  update CHANGELOG, commit, push, create PR. Use when asked to "ship", "deploy",
  "push to main", "create a PR", "merge and push", or "get it deployed".
  Proactively invoke this skill (do NOT push/PR directly) when the user says code
  is ready, asks about deploying, wants to push code up, or asks to create a PR. (gstack)
```

**steez** (single-line):
```yaml
description: Ship workflow: detect + merge base branch, run tests, review diff, bump VERSION, update CHANGELOG, commit, push, create PR. Use when asked to "ship", "deploy", "push to main", "create a PR", or "merge and push". Proactively suggest when the user says code is ready or asks about deploying. (steez)
```

**Note:** Description transforms are per-skill — each skill's description has different wording. The overlay engine should store per-skill description overrides, or use a description overlay file per skill.

---

## 2. Deleted Sections (global)

Sections removed from ALL synced skills. The `optional` column indicates whether the section exists in all 25 synced skills or only some.

| Section Heading | Count in gstack | Optional? | Notes |
|-----------------|-----------------|-----------|-------|
| `<!-- AUTO-GENERATED from SKILL.md.tmpl ... -->` | 27/27 | No | Comment block, not a heading. Replaced by `<!-- BEGIN MANAGED PREAMBLE -->` |
| `## Contributor Mode` | 27/27 | No | Replaced by `## Skill Self-Report` (see section replacements) |
| `## Plan Mode Safe Operations` | 27/27 | No | — |
| `## Repo Ownership -- See Something, Say Something` | 14/27 | **Yes** | T3+ skills only |
| `## Prior Learnings` | 6/27 | **Yes** | investigate, office-hours, plan-ceo-review, plan-eng-review, review, ship |
| `## Capture Learnings` | 4/27 | **Yes** | investigate, retro, review, ship |

### Preamble-internal deletions (inside preamble bash block)

These are not heading-level deletes but content removed from within the preamble:

| Content | Notes |
|---------|-------|
| `gstack-update-check` call | Update check removed entirely |
| `SKILL_PREFIX` handling | Hardcoded in steez |
| `UPGRADE_AVAILABLE / JUST_UPGRADED` flow | No auto-update in steez |
| `LAKE_INTRO` / Completeness Principle intro | Onboarding removed |
| Telemetry opt-in AskUserQuestion flow | steez always logs locally, no opt-in |
| Proactive opt-in AskUserQuestion flow | steez assumes config pre-set |
| Routing rules injection AskUserQuestion flow | Removed entirely |

### Per-skill deletions (ship-specific, verify against other skills)

| Section | Skills | Notes |
|---------|--------|-------|
| `## Step 3.48: Scope Drift Detection` | ship, review (`## Step 1.5: Scope Drift Detection`) | Full section + PR body reference |
| Idempotency checks in Steps 4, 7, 8 | ship | `BASE_VERSION`/`ALREADY_BUMPED`, `LOCAL`/`REMOTE`/`ALREADY_PUSHED`, `gh pr view` update logic |
| `## Scope Drift` in PR body template | ship | Removed since Step 3.48 deleted |
| CHANGELOG Voice sub-bullet | ship | `"**Voice:** Lead with what the user can now **do**..."` |

---

## 3. Replaced Sections (global)

Sections that exist in both gstack and steez but with structurally different content (not just string replacement).

| Section | Replacement Source | Notes |
|---------|-------------------|-------|
| `## Preamble (run first)` (bash block) | `overlays/steez-preamble.md` | 59 lines → 20 lines. Entire bash block replaced. See preamble detail below. |
| `## Contributor Mode` → `## Skill Self-Report` | `overlays/steez-skill-self-report.md` | Heading renamed. Conditional `_CONTRIB` removed. Paths changed. Report template simplified. |
| `## Telemetry (run last)` | `overlays/steez-telemetry.md` | Conditional gate removed. Remote telemetry removed. Hardcoded skill name. Simplified to local-only write. |
| `## Voice` (first paragraph only) | `overlays/steez-voice-intro.md` | `"You are GStack, an open source AI builder framework shaped by Garry Tan's..."` → `"You are a senior engineering partner -- a CTO-level operator..."`. Two paragraphs deleted (User sovereignty moved to Search Before Building; YC pitch removed). |

### Per-skill replaced sections

| Skill | Section | Notes |
|-------|---------|-------|
| ship | `## Step 3.8: Adversarial review` | Complete restructure: "always-on" → "auto-scaled" (tiered by diff size). NOT string replacement — full section replacement with `overlays/steez-adversarial-review.md` |
| ship | `## Plan Status Footer` | Brand replacements + added error handling on `steez-review-read` |
| ship | Proactive behavior paragraph | Brand + skill name replacements |

---

## 4. Injected Sections (global)

New sections added by steez that don't exist in gstack.

| Section | Inject After | Source | Notes |
|---------|-------------|--------|-------|
| `<!-- BEGIN MANAGED PREAMBLE -->` | Frontmatter close `---` | Literal marker | Replaces `<!-- AUTO-GENERATED -->` comment |
| `## Beads Context` | Preamble bash block | `overlays/steez-beads-context.md` | `steez-bd resume` call. All 25 synced skills. |
| `<!-- END MANAGED PREAMBLE -->` | `## Plan Status Footer` | Literal marker | Closing delimiter |

### Per-skill injections

| Skill | Section | Inject After | Source |
|-------|---------|-------------|--------|
| ship | `## Step 8.25: Beads Integration (completion)` | `## Step 8: Create PR/MR` | `overlays/beads-integration-ship.md` |
| office-hours | Beads pipeline creation | `## Phase 5: Design Doc` (TBD) | `overlays/beads-integration-office-hours.md` |
| plan-ceo-review | Beads handoff | `## Completion Status Protocol` (TBD) | `overlays/beads-integration-ceo-review.md` |
| plan-eng-review | Beads handoff | `## Completion Status Protocol` (TBD) | `overlays/beads-integration-eng-review.md` |

---

## 5. String Replacements (global)

Applied to upstream-origin content ONLY (not overlay files). Replace everywhere including inside code fences.

### Path replacements

| From | To |
|------|----|
| `~/.gstack/` | `~/.steez/` |
| `~/.claude/skills/gstack/bin/gstack-` | `~/.steez/bin/steez-` |
| `~/.claude/skills/gstack/` | `~/.steez/repo/` |
| `.gstack/no-test-bootstrap` | `.steez/no-test-bootstrap` |
| `.gstack/plans` | `.steez/plans` |
| `${GSTACK_HOME:-$HOME/.gstack}` | `$STEEZ_HOME` |
| `~/.gstack/contributor-logs/` | `~/.steez/skill-reports/` |
| `~/.gstack-dev/evals/` | `~/.steez-dev/evals/` |

### Binary name replacements

| From | To |
|------|----|
| `gstack-config` | `steez-config` |
| `gstack-review-read` | `steez-review-read` |
| `gstack-review-log` | `steez-review-log` |
| `gstack-diff-scope` | `steez-diff-scope` |
| `gstack-slug` | `steez-slug` |

### Removed binaries (no steez equivalent)

| From | Action |
|------|--------|
| `gstack-update-check` | Removed (in preamble replacement) |
| `gstack-repo-mode` | Removed (REPO_MODE hardcoded to solo) |
| `gstack-telemetry-log` | Removed (no remote telemetry) |
| `gstack-learnings-search` | Removed (in Prior Learnings section delete) |
| `gstack-learnings-log` | Removed (in Capture Learnings section delete) |

### Brand replacements

| From | To |
|------|----|
| `GSTACK REVIEW REPORT` | `STEEZ REVIEW REPORT` |
| `GSTACK_HOME` | `STEEZ_HOME` |
| `gstack_contributor` | (removed with Contributor Mode) |
| `CC+gstack` | `CC+steez` |
| `GStack` (capitalized) | `Steez` |

### Skill name replacements (in prose/JSON)

| From | To |
|------|----|
| `/ship` | `/steez-ship` |
| `/qa` | `/steez-qa` |
| `/qa-only` | `/steez-qa-only` |
| `/investigate` | `/steez-investigate` |
| `/plan-eng-review` | `/steez-plan-eng-review` |
| `/plan-ceo-review` | `/steez-plan-ceo-review` |
| `/plan-design-review` | `/steez-plan-design-review` |
| `/autoplan` | `/steez-autoplan` |
| `/design-review` | `/steez-design-review` |
| `/codex` | `/steez-codex` |
| `/retro` | `/steez-retro` |
| `/document-release` | `/steez-document-release` |
| `"skill":"SKILL_NAME"` | `"skill":"steez-{name}"` (per-skill) |
| `gstack /ship` | `steez /steez-ship` (per-skill) |

### Template variable replacements

| From | To | Notes |
|------|----|-------|
| `SKILL_NAME` (unquoted, in bash) | Hardcoded `steez-{name}` | Per-skill |

---

## 6. Heading Frequency Census

Determines which global deletes need `optional: true`.

### Present in ALL 25 synced skills (mandatory)

- `## Preamble (run first)`
- `## Voice`
- `## Contributor Mode`
- `## Completion Status Protocol`
- `### Escalation`
- `## Telemetry (run last)`
- `## Plan Mode Safe Operations`
- `## Plan Status Footer`
- `## GSTACK REVIEW REPORT`

### Present in MOST synced skills — by preamble tier

| Heading | Count | Present in | Absent from | Tier |
|---------|-------|-----------|-------------|------|
| `## AskUserQuestion Format` | 20/25 | T2+ skills | benchmark, browse, setup-browser-cookies, + 2 | T2 |
| `## Completeness Principle -- Boil the Lake` | 20/25 | T2+ skills | benchmark, browse, setup-browser-cookies, + 2 | T2 |
| `## Search Before Building` | 12/25 | T3+ skills | 13 T1/T2 skills | T3 |
| `## Repo Ownership -- See Something, Say Something` | 12/25 | T3+ skills | 13 T1/T2 skills | T3 |

### Present in FEW synced skills (always optional)

| Heading | Count | Skills |
|---------|-------|--------|
| `## Prior Learnings` | 6 | investigate, office-hours, plan-ceo-review, plan-eng-review, review, ship |
| `## Capture Learnings` | 4 | investigate, retro, review, ship |
| `## Confidence Calibration` | 4 | cso, plan-eng-review, review, ship |
| `## Step 0: Detect platform and base branch` | 11 | Workflow skills only |
| `## Important Rules` | 19 | Most but not all |
| `## SETUP (run this check...)` | 13 | Browse-dependent skills |

---

## 7. Preamble Detail

### gstack preamble (59 lines)

```
- Update check (gstack-update-check)
- Session tracking with count (_SESSIONS)
- Contributor mode config (_CONTRIB)
- Proactive config + proactive-prompted flag
- Branch detection
- Skill prefix config (_SKILL_PREFIX)
- Repo mode via gstack-repo-mode script
- Lake intro seen flag
- Telemetry config + prompted flag
- Conditional telemetry logging (gated by _TEL)
- Pending telemetry finalization loop
- Learnings count
- CLAUDE.md routing rules check
```

### steez preamble (20 lines)

```
- STEEZ_HOME variable set
- Session tracking (no count)
- Branch detection
- Proactive config (with stderr warning fallback)
- Repo mode hardcoded "solo"
- Local usage logging (unconditional, no telemetry gate)
```

steez preamble is ~70% smaller. Removes: update check, contributor mode, skill prefix, repo mode detection, lake intro, telemetry prompting, pending finalization, learnings, routing rules.

---

## 8. Sections Identical After String Replacement

These sections need NO structural changes — only global string replacements:

- `# Ship: Fully Automated Ship Workflow` intro
- `## Step 0: Detect platform and base branch`
- `## Step 1: Pre-flight`
- `## Review Readiness Dashboard` (except adversarial tier description change)
- `## Step 1.5: Distribution Pipeline Check`
- `## Step 2: Merge the base branch`
- `## Step 2.5: Test Framework Bootstrap` + B2-B8
- `## Step 3: Run tests`
- `## Test Failure Ownership Triage` + T1-T4
- `## Step 3.25: Eval Suites`
- `## Step 3.4: Test Coverage Audit` + all sub-sections
- `## Step 3.45: Plan Completion Audit` (minor path simplification)
- `## Step 3.47: Plan Verification`
- `## Confidence Calibration` (except `bd remember` injection)
- `## Step 3.5: Pre-Landing Review`
- `## Design Review (conditional, diff-scoped)`
- `## Step 3.75: Address Greptile review comments`
- `## Step 4: Version bump` (after removing idempotency check)
- `## Step 5: CHANGELOG` (after removing Voice sub-bullet)
- `## Step 5.5: TODOS.md`
- `## Step 6: Commit (bisectable chunks)`
- `## Step 6.5: Verification Gate`
- `## Step 7: Push` (after removing idempotency check)
- `## Step 8: Create PR/MR` (after removing idempotency check + Scope Drift)
- `## Step 8.5: Auto-invoke /document-release`
- `## Step 8.75: Persist ship metrics`
- `## Important Rules`
- `## AskUserQuestion Format`
- `## Completeness Principle -- Boil the Lake`
- `## Completion Status Protocol` + `### Escalation`

---

## 9. Edge Cases & Notes

1. **Typo in steez proactive paragraph** (steez-ship L52): Says `/steez-ship, /steez-ship` — should be `/steez-qa, /steez-ship`. Search-and-replace error where `/qa` became `/steez-ship`.

2. **Plan File Discovery simplified**: steez removes `_PLAN_SLUG` computation and `$HOME/.gstack/projects/$_PLAN_SLUG` from search paths.

3. **Error handling additions**: steez adds stderr warning fallbacks not present in gstack:
   - `steez-config get proactive` has `{ echo "[steez] WARNING:..." >&2; echo "true"; }`
   - `steez-review-read` has `|| echo "[steez] WARNING: review-read failed" >&2`
   - Telemetry write has `|| echo "[steez] WARNING: telemetry write failed" >&2`

4. **Adversarial review is a full section replacement**: Step 3.8 was rewritten from "always-on" to "auto-scaled" (tiered by diff size). Not achievable via string replacement.

5. **Review Readiness Dashboard**: Adversarial tier description diverges to match Step 3.8 restructure.

6. **`bd remember` injection**: In Confidence Calibration, gstack says "Log the corrected pattern as a learning", steez says "Use `bd remember` to log the corrected pattern". Small per-skill string replacement.

7. **Section ordering**: Confidence Calibration moves slightly (after removing Step 3.48 Scope Drift), but its relative position to Step 3.5 is preserved.

8. **CHANGELOG heading rename**: gstack `## CHANGELOG (auto-generate)` → steez `## Step 5: CHANGELOG (auto-generate)`. Heading text change, not just content.

9. **Description transforms are per-skill**: Each skill has unique description wording. The overlay engine needs per-skill description overrides or overlay files, not a global pattern.

10. **`SKILL_NAME` template variable**: gstack uses literal `SKILL_NAME` in several places (telemetry JSON, attribution). steez hardcodes the actual skill name (e.g., `steez-ship`). This is per-skill.

---

## 10. Operation Order

The overlay engine MUST apply transforms in this order:

1. **Frontmatter transforms** — name prefix, description override, field removal
2. **Section deletes** — remove unwanted sections (with optional flag support)
3. **Section replacements** — swap in overlay content (preamble, self-report, telemetry, voice intro, adversarial review)
4. **Section injections** — add new sections (managed preamble markers, beads context, beads integrations)
5. **String replacements** — global find/replace on upstream-origin content ONLY (not overlay files)
6. **Per-skill string replacements** — `SKILL_NAME` → hardcoded name, `bd remember` injection, etc.
7. **Reassemble** — frontmatter + transformed body
