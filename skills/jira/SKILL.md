---
name: jira
preamble-tier: 1
description: "Manage Jira tickets using the acli CLI and Jira REST API. Use this skill whenever the user mentions Jira, tickets, work items, sprints, backlogs, or asks to search, create, update, transition, comment on, assign, or log time on any ticket. Also trigger when the user says things like 'what's assigned to me', 'create a ticket for X', 'move that to done', 'log 2 hours on NS-123', or references ticket keys like XX-nnn."
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
echo '{"skill":"jira","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","repo":"'$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")'"}'  >> "$STEEZ_HOME/analytics/skill-usage.jsonl" 2>/dev/null || true
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /jira, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
"I think /skillname might help here — want me to run it?" and wait for confirmation.
The user opted out of proactive behavior.
<!-- END MANAGED PREAMBLE -->

# Jira

Delegate all Jira operations to the `steez-jira` agent. Do not handle Jira commands directly.

## How to use

1. Spawn an Agent with `subagent_type: "steez-jira"`
2. Pass the user's request as the prompt. Include any ticket keys, search terms, project names, or operation details the user mentioned.
3. Present the agent's response to the user using the formatting rules below.

The agent handles all acli CLI syntax, Atlassian Document Format, JQL queries, and Jira API gotchas internally. You do not need to know how acli works.

## Presenting results

When showing the agent's results to the user:

- **Multi-project searches**: group by project with a heading showing count (`**NS (5)**`). Each project gets its own table with key, summary, status. Skip projects with zero results.
- **Single-project searches**: one table with key, summary, status, priority.
- **Single ticket view**: structured summary with the fields the user asked about.
- **Mutations** (create, edit, transition, assign, comment): one-line confirmation with the ticket key and what changed.
- **Time logs**: one-line confirmation with ticket key and hours logged.
- **Errors**: surface the error message and the agent's suggestion for what to try.

Keep it scannable. No preamble, no "here are your results" filler. Tables and one-liners.

## Telemetry (run last)

```bash
_TEL_END=$(date +%s)
_TEL_DUR=$(( _TEL_END - _TEL_START ))
echo '{"skill":"jira","duration_s":"'"$_TEL_DUR"'","outcome":"OUTCOME","browse":"false","session":"'"$_SESSION_ID"'","ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' >> ~/.steez/analytics/skill-usage.jsonl 2>/dev/null || echo "[steez] WARNING: telemetry write failed" >&2
```

Replace `OUTCOME` with success/error/abort based on the agent's result.
