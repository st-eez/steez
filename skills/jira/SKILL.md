---
name: jira
description: "Manage Jira tickets using the acli CLI and Jira REST API. Use this skill whenever the user mentions Jira, tickets, work items, sprints, backlogs, or asks to search, create, update, transition, comment on, assign, or log time on any ticket. Also trigger when the user says things like 'what's assigned to me', 'create a ticket for X', 'move that to done', 'log 2 hours on NS-123', or references ticket keys like XX-nnn."
---

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

