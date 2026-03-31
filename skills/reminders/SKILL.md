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

## Beads Context

```bash
# Beads context — shows current bead, suggested skill, ready work (non-blocking)
~/.steez/bin/steez-bd resume 2>/dev/null || true
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /reminders, /steez-ship). If you would have auto-invoked a skill, instead briefly say:
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

## Why these rules matter

The `remindctl` CLI outputs colored human-formatted text by default, which is hard to parse and wastes tokens. Passing `--json` on every command gives you structured data you can reliably work with. Similarly, numeric indexes from `show` output shift between calls as reminders are added or completed, so always reference reminders by their stable ID prefix.

## Rules

1. **Always pass `--json`** on every `remindctl` command.
2. **Use `remindctl show open --json`** to list incomplete reminders — not `show all`, which dumps completed items and is rarely what the user wants.
3. **Use ID prefixes** (e.g., `4A83`) when targeting reminders with `edit`, `complete`, or `delete`. Never use numeric indexes — they shift between calls.

## Command Reference

### Viewing reminders
```sh
remindctl show open --json                         # All incomplete
remindctl show open --list "Work" --json            # Incomplete in a specific list
remindctl show today --json                         # Due today
remindctl show overdue --json                       # Past due
remindctl show tomorrow --json                      # Due tomorrow
remindctl show week --json                          # Due this week
remindctl show upcoming --json                      # Upcoming
remindctl show 2026-03-18 --json                    # Due on specific date
```

### List management
```sh
remindctl list --json                               # Show all lists
remindctl list "Work" --json                        # Reminders in a list
remindctl list "Projects" --create --json           # Create a list
remindctl list "Work" --rename "Office" --json      # Rename
remindctl list "Old" --delete --force --json        # Delete
```

### Adding reminders
```sh
remindctl add "Buy milk" --json
remindctl add "Call mom" --list "Personal" --due tomorrow --json
remindctl add "Review docs" --priority high --json
# Priority values: none, low, medium, high
```

### Editing reminders
```sh
remindctl edit <ID> --title "New title" --json
remindctl edit <ID> --due tomorrow --json
remindctl edit <ID> --priority high --notes "Before noon" --json
remindctl edit <ID> --clear-due --json
remindctl edit <ID> --list "Work" --json            # Move to different list
remindctl edit <ID> --complete --json               # Mark complete
remindctl edit <ID> --incomplete --json             # Undo completion
```

### Completing reminders
```sh
remindctl complete <ID> --json                      # Single
remindctl complete <ID1> <ID2> <ID3> --json         # Multiple
```

### Deleting reminders
```sh
remindctl delete <ID> --force --json
```

## Output Formatting

When displaying reminders, **always pipe the JSON through the bundled formatting script** rather than drawing tables yourself. The script handles alignment, wrapping, and borders deterministically.

```sh
remindctl show open --json | python3 ~/.claude/skills/reminders/scripts/format_table.py
```

Combine the remindctl command and the formatter into a single piped command. The script outputs rounded-corner Unicode tables grouped by list, with sequential row numbers, separator lines between rows, and long titles wrapped across multiple lines.

After the table output, add a brief summary noting overdue items or high-priority ones. You have the JSON data in context so you can map row numbers back to IDs for follow-up operations (complete, edit, delete).

When there's only a single reminder (e.g., after an add or edit), show it inline instead of piping through the script:

```
✓ Added to Personal: "Buy milk" (due 2026-03-18)
```

## Workflow

When the user asks about their reminders:
1. Start by running `remindctl show open --json` (or a more specific filter if they indicated one)
2. Present results using the table format above
3. For mutations, run the command and confirm the result with a brief inline summary
