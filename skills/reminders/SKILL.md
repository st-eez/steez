---
name: reminders
preamble-tier: 1
description: "Manage Apple Reminders via the remindctl CLI. Use this skill whenever the user mentions reminders, to-do lists, things to remember, due dates for personal items, checking what's due, or remindctl. Also trigger when the user says things like 'remind me to...', 'what do I have due', 'mark X as done', or 'add X to my list'. Do NOT trigger for code TODOs, GitHub issues, Jira tickets, beads tasks, or programming task tracking."
allowed-tools: Bash
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
echo '{"skill":"reminders","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","repo":"'$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")'"}'  >> "$STEEZ_HOME/analytics/skill-usage.jsonl" 2>/dev/null || true
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /reminders, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
"I think /skillname might help here — want me to run it?" and wait for confirmation.
The user opted out of proactive behavior.
<!-- END MANAGED PREAMBLE -->

# Reminders

Delegate all reminders operations to the `steez-reminders` agent. Do not handle remindctl commands directly.

## How to use

1. Spawn an Agent with `subagent_type: "steez-reminders"`
2. Pass the user's request as the prompt. Include any list names, reminder titles, ID prefixes, due dates, or operation details the user mentioned.
3. Present the agent's response to the user using the formatting rules below.

The agent handles all remindctl CLI syntax, JSON parsing, and ID prefix resolution internally. You do not need to know how remindctl works.

## Presenting results

When showing the agent's results to the user:

- **Listing reminders**: group by list name with a heading showing count (e.g., `**Work (3)**`). Each list gets its own table with ID prefix, title, due date, priority. Flag overdue items. Skip empty lists.
- **Single reminder** (after add, edit, or complete): one-line confirmation with the ID prefix, title, and what changed.
- **Batch complete/delete**: one-line summary with count and affected IDs.
- **Errors**: surface the error message and the agent's suggestion for what to try.

Keep it scannable. No preamble, no "here are your results" filler. Tables and one-liners.

## Telemetry (run last)

```bash
_TEL_END=$(date +%s)
_TEL_DUR=$(( _TEL_END - _TEL_START ))
echo '{"skill":"reminders","duration_s":"'"$_TEL_DUR"'","outcome":"OUTCOME","browse":"false","session":"'"$_SESSION_ID"'","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' >> ~/.steez/analytics/skill-usage.jsonl 2>/dev/null || echo "[steez] WARNING: telemetry write failed" >&2
```

Replace `OUTCOME` with success/error/abort based on the agent's result.
