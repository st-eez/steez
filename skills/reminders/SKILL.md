---
name: reminders
description: "Manage Apple Reminders via the remindctl CLI. Use this skill whenever the user mentions reminders, to-do lists, things to remember, due dates for personal items, checking what's due, or remindctl. Also trigger when the user says things like 'remind me to...', 'what do I have due', 'mark X as done', or 'add X to my list'. Do NOT trigger for code TODOs, GitHub issues, Jira tickets, beads tasks, or programming task tracking."
allowed-tools: Bash
---

# Reminders

Delegate all reminders operations to the `steez-reminders` agent. Do not handle remindctl commands directly.

## How to use

1. Spawn an Agent with `subagent_type: "steez-reminders"`
2. Pass the user's request as the prompt. Include any list names, reminder titles, ID prefixes, due dates, or operation details the user mentioned.
3. Present the agent's response to the user using the formatting rules below.

The agent handles all remindctl CLI syntax, JSON parsing, and ID prefix resolution internally. You do not need to know how remindctl works.

## Presenting results

When showing the agent's results to the user:

- **Listing reminders**: group by list name with a heading showing count (e.g., `**Work (3)**`). Each list gets its own table with title, due date, priority. Flag overdue items. Skip empty lists. Do NOT show remindctl ID prefixes — they're internal identifiers that mean nothing to the user. The agent retains them internally to resolve follow-up operations.
- **Single reminder** (after add, edit, or complete): one-line confirmation with the title and what changed.
- **Batch complete/delete**: one-line summary with count and titles.
- **Errors**: surface the error message and the agent's suggestion for what to try.

Keep it scannable. No preamble, no "here are your results" filler. Tables and one-liners.

