---
name: sharpen-skill
preamble-tier: 3
description: Evaluate and improve skills via multi-agent research, independent critique, and data-grounded debate. Use when asked to sharpen, improve, evaluate, review, or compare a skill, or adopt one from another source.
---

<!-- BEGIN MANAGED PREAMBLE -->
## Preamble (run first)

```bash
STEEZ_HOME="${STEEZ_HOME:-$HOME/.steez}"
# Session tracking
mkdir -p "$STEEZ_HOME/sessions"
touch "$STEEZ_HOME/sessions/$PPID"
find "$STEEZ_HOME/sessions" -mmin +120 -type f -delete 2>/dev/null || true
# Branch detection
_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "BRANCH: $_BRANCH"
# Config
_PROACTIVE=$(~/.steez/bin/steez-config get proactive 2>/dev/null || { echo "[steez] WARNING: steez-config failed, defaulting proactive=true" >&2; echo "true"; })
echo "PROACTIVE: $_PROACTIVE"
# Repo mode (hardcoded — always solo)
REPO_MODE=solo
echo "REPO_MODE: $REPO_MODE"
# Local usage logging (no remote telemetry)
_TEL_START=$(date +%s)
_SESSION_ID="$$-$(date +%s)"
mkdir -p "$STEEZ_HOME/analytics"
echo '{"skill":"steez-sharpen-skill","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","repo":"'$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")'"}'  >> "$STEEZ_HOME/analytics/skill-usage.jsonl" 2>/dev/null || true
```
## Beads Context

```bash
# Beads context — shows current bead, suggested skill, ready work (non-blocking)
~/.steez/bin/steez-bd resume 2>/dev/null || true
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /steez-qa, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
"I think /skillname might help here — want me to run it?" and wait for confirmation.
The user opted out of proactive behavior.
If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /steez-qa, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
"I think /skillname might help here — want me to run it?" and wait for confirmation.
The user opted out of proactive behavior.
You are a senior engineering partner — a CTO-level operator who ships product and owns it in production. You think across engineering, design, product, and operations to get to truth.
## Skill Self-Report

At the end of each major workflow step, rate your /steez-sharpen-skill experience 0-10. If not a 10 and there's an actionable bug or improvement, file a field report.

**File only:** steez tooling bugs where the input was reasonable but the skill failed. **Skip:** user app bugs, network errors, auth failures on user's site.

**To file:** write `~/.steez/skill-reports/{slug}.md`:
```
# {Title}
**What I tried:** {action} | **What happened:** {result} | **Rating:** {0-10}
## Repro
1. {step}
## What would make this a 10
{one sentence}
**Date:** {YYYY-MM-DD} | **Skill:** /steez-sharpen-skill
```
Slug: lowercase hyphens, max 60 chars. Skip if exists. Max 3/session. File inline, don't stop.
## Telemetry (run last)

After the skill workflow completes (success, error, or abort), log the telemetry event.
Determine the outcome from the workflow result (success if completed normally, error
if it failed, abort if the user interrupted).

**PLAN MODE EXCEPTION — ALWAYS RUN:** This command writes telemetry to
`~/.steez/analytics/` (user config directory, not project files). The skill
preamble already writes to the same directory — this is the same pattern.
Skipping this command loses session duration and outcome data.

Run this bash:

```bash
_TEL_END=$(date +%s)
_TEL_DUR=$(( _TEL_END - _TEL_START ))
# Local analytics only (no remote telemetry)
echo '{"skill":"steez-sharpen-skill","duration_s":"'"$_TEL_DUR"'","outcome":"OUTCOME","browse":"USED_BROWSE","session":"'"$_SESSION_ID"'","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' >> ~/.steez/analytics/skill-usage.jsonl 2>/dev/null || echo "[steez] WARNING: telemetry write failed" >&2
```

Replace `OUTCOME` with success/error/abort, and `USED_BROWSE` with true/false based
on whether `$B` was used. If you cannot determine the outcome, use "unknown".
<!-- END MANAGED PREAMBLE -->

# Sharpen Skill

Evaluate and improve a Claude Code skill through multi-agent analysis,
independent critique, and iterative debate.

## Step 1: Identify the target

Determine what's being sharpened:

- **A specific skill the user names** — read its SKILL.md and any references/ directory
- **A skill in the current directory** — look for .claude/skills/ or SKILL.md
- **A comparison** — the user's skill vs an external source (another repo, a skill pack, etc.)
- **A broad audit** — "what should I improve across my skills?"

Read all target skill files before proceeding.

## Step 2: Mine usage data

Gather evidence on how the skill is actually performing. Scale the
research to the question — deploy parallel agents for broad questions,
go inline for narrow ones.

**Session history** (primary source):

- Parse `~/.claude/history.jsonl` for recent invocations of the skill
  (filter by timestamps — last 3 weeks is a good default window)
- Check `~/.claude/projects/*/sessions-index.json` for sessions where
  the skill was used
- Weight recent activity higher (last 7d = 1.0, 8-14d = 0.6, 15-21d = 0.3)

**Git history** (when the skill lives in a repo):

- Post-skill fix commits — things the skill missed that were caught later
- Reverts caused by the skill's own recommendations
- Churn in the skill file itself — sections that keep getting edited indicate instability

**Pain points**:

- Frustration signals in session history ("wtf", "no", "stop", "don't", corrections)
- Repeated workarounds or re-explanations after the skill runs
- Manual steps the user consistently does right after the skill completes

**Missed triggers**:

- Prompts that should have invoked the skill but didn't
- Cases where the user manually did what the skill automates

For broad evaluations with many candidates, add a scoring phase:
deploy parallel scoring agents with different lenses (frequency of use,
impact per use, friction without it) and average scores to rank
candidates before proposing changes.

## Step 3: Propose improvements

Generate proposals based on the evidence from Step 2. The approach
depends on whether there's an external skill to compare against.

### Path A: Comparison mode

When evaluating a skill against an external source (another repo,
a skill pack, a reference implementation):

1. Read both the user's skill and the external skill
2. Identify structural features the external skill has that the user's lacks
3. Filter by relevance to the user's actual workflow and tech stack
4. Proposals = the useful delta, adapted to the user's context

### Path B: Standalone mode

When improving a skill with no external comparison:

1. **Post-skill behavior** — what does the user do immediately after the
   skill runs? If they always do X next, X should probably be part of
   the skill
2. **Pain point patterns** — group frustration signals by theme. Each
   theme is a candidate proposal
3. **Miss analysis** — what did the skill fail to catch or do? Search
   git log for fix commits that came after skill invocations
4. **Trigger gaps** — if the skill isn't firing when it should, propose
   description improvements
5. **Churn analysis** — sections of the skill that keep getting edited
   suggest the instructions aren't landing. Propose rewrites for
   high-churn sections

### For both paths

Each proposal needs:
- **What**: the concrete change
- **Why**: specific evidence from Step 2 (cite commits, sessions, or patterns)
- **Risk**: what could go wrong

Do NOT propose changes without evidence. If the data says the skill
is working fine, say so.

## Step 4: Independent critique

Spawn a separate Claude instance in the repo where the skill lives.
Use /claude-spawn to open an interactive session in a tmux split.

Give the critic the proposals and this directive:

> Evaluate each proposal against actual codebase data — git log,
> session history, real outputs from past invocations. For each:
> search for evidence the problem exists (or doesn't), measure the
> real impact with data not design principles, and APPROVE or DENY
> with specific commits or sessions as evidence.
>
> Do not reason from design principles alone. "It was designed this
> way" is not evidence that the design is working. Search for data.

Report the critic's verdicts to the user.

## Step 5: Debate

Challenge denials that reason from how the skill was designed rather
than whether it's working. Send rebuttals with specific counter-evidence.

If the user reframes the question, relay the reframe to the critic
immediately. The user often sees context neither agent has — their
reframe is typically the highest-leverage moment in the process.

Continue until each proposal has a clear APPROVE or DENY backed by
data. Summarize the final verdicts in a table.

## Step 6: Implement

For approved proposals:
- Have the critic Claude implement the changes (they have repo context)
- Review the implementation yourself (cross-review catches mistakes)
- Report the diffs to the user for final approval

Do not commit without the user's go-ahead.

## Scaling guide

| Question size | Start at | Example |
|--------------|----------|---------|
| "Is this one thing working?" | Step 3 | "Is my adversarial pass helping?" |
| "Improve this skill" | Step 2 | "Sharpen my pr-review skill" |
| "Should I adopt these?" | Step 2 + scoring | "Anything in steez worth adding?" |
| "Audit all my skills" | Step 2 + parallel research | "What should I improve?" |
