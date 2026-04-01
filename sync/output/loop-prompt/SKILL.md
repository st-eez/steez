---
name: loop-prompt
preamble-tier: 1
description: Generate a Ralph-style loop prompt for the current project. Use this skill whenever the user wants to create a loop prompt, a Ralph Wiggum prompt, a prompt.md, or wants to set up an automated coding loop. Also trigger when the user says things like "make me a loop file", "set up a prompt for looping", or "create a prompt.md".
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
echo '{"skill":"steez-loop-prompt","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","repo":"'$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")'"}'  >> "$STEEZ_HOME/analytics/skill-usage.jsonl" 2>/dev/null || true
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

At the end of each major workflow step, rate your /steez-loop-prompt experience 0-10. If not a 10 and there's an actionable bug or improvement, file a field report.

**File only:** steez tooling bugs where the input was reasonable but the skill failed. **Skip:** user app bugs, network errors, auth failures on user's site.

**To file:** write `~/.steez/skill-reports/{slug}.md`:
```
# {Title}
**What I tried:** {action} | **What happened:** {result} | **Rating:** {0-10}
## Repro
1. {step}
## What would make this a 10
{one sentence}
**Date:** {YYYY-MM-DD} | **Skill:** /steez-loop-prompt
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
echo '{"skill":"steez-loop-prompt","duration_s":"'"$_TEL_DUR"'","outcome":"OUTCOME","browse":"USED_BROWSE","session":"'"$_SESSION_ID"'","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' >> ~/.steez/analytics/skill-usage.jsonl 2>/dev/null || echo "[steez] WARNING: telemetry write failed" >&2
```

Replace `OUTCOME` with success/error/abort, and `USED_BROWSE` with true/false based
on whether `$B` was used. If you cannot determine the outcome, use "unknown".
<!-- END MANAGED PREAMBLE -->

## Step 1 — Ask for the specs entry point

IMPORTANT: Do NOT read any files or scan the codebase yet. Ask this question IMMEDIATELY as your very first action.

Use AskUserQuestion to ask the user:
- question: "What file should the loop study at the start of each iteration? (e.g. specs/readme.md, DESIGN.md, a plan file)"
- header: "Specs file"
- options:
  - "specs/readme.md"
  - "DESIGN.md"
  - "README.md"

Do NOT proceed to Step 2 until the user has answered.

## Step 2 — Scan the codebase

After getting the specs answer, quickly investigate:

1. **Language & framework**: Check file extensions, config files (package.json, go.mod, Cargo.toml, pyproject.toml, Makefile, etc.)
2. **Test command**: Find how tests are run (look at package.json scripts, Makefile targets, or standard commands for the detected language)
3. **Pattern anchors**: Look at the project structure and identify the dominant code patterns worth referencing (e.g. "handler patterns in internal/api/", "component patterns in src/components/", "service patterns in lib/services/"). Pick 1-2 concise anchors.

Keep scanning fast — just enough to fill the template, not a deep audit.

## Step 3 — Present the full prompt

Assemble a draft prompt.md following this exact structure (Geoffrey Huntley's Ralph prompt format):

```
Study <specs-entry-point>.

Pick the most important thing to do.

Important:
- Use <pattern-anchors>.
- Build <test-type> tests, whichever is best.

After:
- <test-command>.
- When tests pass, commit and push.
```

Rules for the draft:
- Keep it under 12 lines total
- Pattern anchors should reference actual directories/patterns found in the codebase
- Test type should be "property based tests or unit tests" unless the codebase clearly favors one style
- Test command should be the actual command for this project (e.g. "Run go test ./...", "Run npm test", "Run cargo test")

Present the complete draft to the user and ask if they want to adjust anything before writing it.

## Step 4 — Write prompt.md

Once the user confirms (or after incorporating their tweaks), write the final prompt to `prompt.md` in the current working directory.
