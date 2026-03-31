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

## Beads Context

```bash
# Beads context — shows current bead, suggested skill, ready work (non-blocking)
~/.steez/bin/steez-bd resume 2>/dev/null || true
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /jira, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
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

# Jira (acli)

You manage Jira Cloud via the `acli` CLI tool. Site and user info are resolved automatically from `~/.config/acli/jira_config.yaml` — never hardcode them.

## Discovery

On first use in a conversation, discover the user's projects and issue types:

```sh
acli jira project list
```

Then use the project keys in JQL queries. To discover valid issue types for a project, search for a recent ticket and check its `issuetype` field.

## Critical Rules

These exist because of real shell and API gotchas — ignoring them causes silent failures:

- **Always use `workitem`, not `issue`** — acli uses `workitem` as the subcommand name
- **Exclude terminal statuses** in searches by default: `status NOT IN ("Done","Closed","Canceled")`
- **Use `NOT IN`, never `!=`** — the `!` character causes shell escaping issues
- **JQL only** — use `--jql` for searches, not shorthand flags
- **Use `--yes`** on edit/transition/assign commands to avoid interactive prompts that hang Claude

## Common Operations

### Search tickets

```sh
# My open tickets
acli jira workitem search --jql 'project = XX AND assignee = currentUser() AND status NOT IN ("Done","Closed","Canceled")' --fields "key,summary,status,priority" --csv

# Search by text
acli jira workitem search --jql 'project = XX AND text ~ "search term" AND status NOT IN ("Done","Closed","Canceled")' --csv

# Count results
acli jira workitem search --jql 'project = XX AND status = "In Progress"' --count

# Get all results (paginate)
acli jira workitem search --jql 'project = XX AND assignee = currentUser()' --paginate --csv
```

### View a ticket

```sh
acli jira workitem view XX-123
acli jira workitem view XX-123 --fields '*navigable'
acli jira workitem view XX-123 --fields 'summary,status,comment,timetracking'
acli jira workitem view XX-123 --json
acli jira workitem view XX-123 --web
```

### Create a ticket

```sh
acli jira workitem create \
  --project "XX" \
  --type "Task" \
  --summary "Brief description" \
  --description "Detailed explanation" \
  --assignee "@me"
```

Some Jira Service Management projects require custom fields (like Urgency) that have no CLI flag. When `acli` returns an error like `Urgency is required`, use `--from-json` with `additionalAttributes` to pass the custom field. To discover the field ID, use the REST API's createmeta endpoint or check an existing ticket with `acli jira workitem view XX-123 --fields '*navigable' --json`.

Example — creating in a project that requires Urgency:

```sh
cat > /tmp/jira_ticket.json << 'EOF'
{
  "projectKey": "XX",
  "type": "Get IT help",
  "summary": "Brief description",
  "description": {
    "type": "doc", "version": 1,
    "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Details here"}]}]
  },
  "additionalAttributes": {
    "customfield_10043": { "value": "Medium" }
  }
}
EOF
acli jira workitem create --from-json /tmp/jira_ticket.json
```

Note: `--assignee "@me"` may fail on service desk projects — if it does, create the ticket unassigned.

For rich descriptions, use `--description-file` with Atlassian Document Format (ADF):

```sh
cat > /tmp/jira_desc.json << 'EOF'
{
  "type": "doc",
  "version": 1,
  "content": [
    {
      "type": "paragraph",
      "content": [{"type": "text", "text": "Description here"}]
    }
  ]
}
EOF
acli jira workitem create --project "XX" --type "Task" \
  --summary "Title" --description-file /tmp/jira_desc.json --assignee "@me"
```

### Edit a ticket

```sh
acli jira workitem edit --key "XX-123" --summary "Updated title" --yes

# Complex edits via JSON
acli jira workitem edit --from-json /tmp/edit.json --yes
```

JSON edit template:
```json
{
  "issues": ["XX-123"],
  "summary": "New title",
  "assignee": "user@email.com",
  "labelsToAdd": ["label1"],
  "labelsToRemove": ["old-label"],
  "type": "Task"
}
```

### Transition a ticket

```sh
acli jira workitem transition --key "XX-123" --status "In Progress" --yes
acli jira workitem transition --key "XX-123" --status "Done" --yes
```

### Assign a ticket

```sh
acli jira workitem assign --key "XX-123" --assignee "@me" --yes
acli jira workitem assign --key "XX-123" --assignee "user@email.com" --yes
acli jira workitem assign --key "XX-123" --remove-assignee --yes
```

### Comment on a ticket

**Simple comments** (plain text — no formatting):

```sh
acli jira workitem comment create --key "XX-123" --body "Comment text here"
acli jira workitem comment list --key "XX-123"
```

**Rich comments** (tables, headings, mentions, panels) — use `--body-file` with ADF JSON. `--body` sends plain text only; Jira does not render markdown, so tables and lists show up as raw characters. Use ADF whenever the comment has structure.

```sh
cat > /tmp/jira_comment.json << 'EOF'
{
  "type": "doc",
  "version": 1,
  "content": [
    {
      "type": "heading",
      "attrs": {"level": 3},
      "content": [{"type": "text", "text": "Section Title"}]
    },
    {
      "type": "bulletList",
      "content": [
        {"type": "listItem", "content": [{"type": "paragraph", "content": [
          {"type": "text", "text": "Bold label: ", "marks": [{"type": "strong"}]},
          {"type": "text", "text": "Normal text"}
        ]}]}
      ]
    },
    {
      "type": "table",
      "attrs": {"isNumberColumnEnabled": false, "layout": "default"},
      "content": [
        {
          "type": "tableRow",
          "content": [
            {"type": "tableHeader", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Column A", "marks": [{"type": "strong"}]}]}]},
            {"type": "tableHeader", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Column B", "marks": [{"type": "strong"}]}]}]}
          ]
        },
        {
          "type": "tableRow",
          "content": [
            {"type": "tableCell", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Cell 1"}]}]},
            {"type": "tableCell", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Cell 2"}]}]}
          ]
        }
      ]
    },
    {
      "type": "panel",
      "attrs": {"panelType": "warning"},
      "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "Warning callout text here."}]}
      ]
    },
    {
      "type": "orderedList",
      "content": [
        {"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Step one"}]}]},
        {"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Step two"}]}]}
      ]
    }
  ]
}
EOF
acli jira workitem comment create --key "XX-123" --body-file /tmp/jira_comment.json
```

ADF panel types: `info`, `note`, `warning`, `error`, `success`. The same ADF format works for `--description-file` on ticket creation.

### Link tickets

```sh
acli jira workitem link type                    # list available link types
acli jira workitem link create --inward-key "XX-123" --outward-key "YY-456" --type "Relates"
```

### Sprint operations

```sh
acli jira sprint view --id 123
acli jira sprint list-workitems --id 123
```

## Time Tracking / Work Logging

`acli` does not support worklog operations. Use the bundled helper script which reads auth from acli's config and calls the Jira REST API directly.

```sh
# Log time
python3 $HOME/.claude/skills/jira/scripts/jira_worklog.py add XX-123 2h --comment "Description of work"
python3 $HOME/.claude/skills/jira/scripts/jira_worklog.py add XX-123 30m
python3 $HOME/.claude/skills/jira/scripts/jira_worklog.py add XX-123 1h --started "2026-03-15T09:00:00.000-0400"

# View worklogs
python3 $HOME/.claude/skills/jira/scripts/jira_worklog.py list XX-123

# Delete a worklog
python3 $HOME/.claude/skills/jira/scripts/jira_worklog.py delete XX-123 <worklog-id>
```

Time format accepts Jira shorthand: `1h`, `30m`, `1h 30m`, `2d`, etc.

## Output Formatting

- Use `--csv` for readable tabular output
- Use `--json` when you need to parse data programmatically
- For `view`, default output is human-readable; use `--json` for structured data
- Always include `key` and `summary` fields in search output for context
