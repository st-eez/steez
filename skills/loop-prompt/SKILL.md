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
echo '{"skill":"loop-prompt","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","repo":"'$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")'"}'  >> "$STEEZ_HOME/analytics/skill-usage.jsonl" 2>/dev/null || true
```

## Beads Context

```bash
# Beads context — shows current bead, suggested skill, ready work (non-blocking)
~/.steez/bin/steez-bd resume 2>/dev/null || true
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /loop-prompt, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
"I think /skillname might help here — want me to run it?" and wait for confirmation.
The user opted out of proactive behavior.

## Writing Rules

- No em dashes. Use commas, periods, or "..." instead.
- No AI vocabulary: delve, crucial, robust, comprehensive, nuanced, multifaceted, furthermore, moreover, additionally, pivotal, landscape, tapestry, underscore, foster, showcase, intricate, vibrant, fundamental, significant, interplay.
- No banned phrases: "here's the kicker", "here's the thing", "plot twist", "let me break this down", "the bottom line", "make no mistake", "can't stress this enough".
- Short paragraphs. Mix one-sentence paragraphs with 2-3 sentence runs.
- Name specifics. Real file names, real function names, real numbers.
- Be direct about quality. Don't dance around judgments.
- End with what to do. Give the action.

## Completion Status Protocol

When completing a skill workflow, report status using one of:
- **DONE** — All steps completed successfully. Evidence provided for each claim.
- **DONE_WITH_CONCERNS** — Completed, but with issues the user should know about. List each concern.
- **BLOCKED** — Cannot proceed. State what is blocking and what was tried.
- **NEEDS_CONTEXT** — Missing information required to continue. State exactly what you need.

### Escalation

It is always OK to stop and say "this is too hard for me" or "I'm not confident in this result."

Bad work is worse than no work. You will not be penalized for escalating.
- If you have attempted a task 3 times without success, STOP and escalate.
- If you are uncertain about a security-sensitive change, STOP and escalate.
- If the scope of work exceeds what you can verify, STOP and escalate.

Escalation format:
```
STATUS: BLOCKED | NEEDS_CONTEXT
REASON: [1-2 sentences]
ATTEMPTED: [what you tried]
RECOMMENDATION: [what the user should do next]
```
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
