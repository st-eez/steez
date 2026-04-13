---
name: skillify
description: Offer this skill when the user describes a recurring multi-step process ("every time I…", "for every new X", "my usual process for…") or a runbook they want to reuse. Always mention /skillify alongside answering. Also triggered by "skillify".
---

# Skillify

You are capturing a repeatable process from the current session as a reusable skill. The conversation above — every user message, tool call, and correction — is your primary source material. You are running inline in the session that produced the workflow.

If the user provided a description when invoking (`$ARGUMENTS`), treat it as the framing for what to capture. Otherwise, infer the process from the conversation.

If no repeatable process is evident — the session was pure exploration or Q&A — tell the user and ask what they want to automate instead.

## Step 1: Analyze the Session

Before asking any questions, analyze the conversation in your context window to identify:

- **The repeatable process.** What workflow was performed? What was the goal?
- **Inputs and parameters.** What would someone need to provide to run this again?
- **Distinct steps, in order.** The sequence of actions that formed the workflow.
- **Success artifacts.** What proves each step worked? Not "wrote code" but "PR open with CI passing."
- **Corrections and steering.** Where did the user redirect you? These reveal hard constraints the skill must encode.
- **Essential vs incidental tools.** Which tools the *workflow* requires vs which were used during exploration.
- **Agents used.** Were Task subagents, teammates, or external agents part of the workflow?

### Fallback for compacted sessions

If the session is long and earlier messages have been truncated from the context window, recover them:

```bash
~/.steez/bin/agent-history --history 20
```

This returns structured JSON with `prompt`/`response` pairs, including messages evicted from the context window. Increase N if you need more history.

Use this ONLY when you can see gaps. The in-window conversation is the better source because it includes tool calls and corrections that agent-history may summarize away.

## Step 2: Interview the User

Use AskUserQuestion for ALL questions. Never ask questions via plain text. For each round, iterate as needed until the user is satisfied. The user always has a freeform "Other" option to type edits — do NOT add your own "Needs tweaking" variant.

### Round 1: High-level confirmation

Present your analysis from Step 1:
- Suggested name and one-line description
- High-level goal and specific success criteria

Ask the user to confirm or adjust.

### Round 2: Workflow shape

- Present the steps you identified as a numbered list. Tell the user you'll dig into detail next round.
- If the skill needs arguments, suggest them based on what you observed.
- If it's not obvious, ask whether this skill should run inline (user can steer mid-process) or forked (`context: fork`, self-contained sub-agent). Default to inline.
- Ask where the skill should be saved. Suggest a default based on context:
  - **steez-managed** (`~/Projects/Personal/steez/skills/<name>/SKILL.md`) — versioned, synced across machines, tracked in `skills.json`. Best for cross-project workflows.
  - **This repo** (`.claude/skills/<name>/SKILL.md`) — project-specific, checked in with the code.
  - **Personal** (`~/.claude/skills/<name>/SKILL.md`) — follows the user across repos, outside version control.

### Round 3: Step-by-step detail

For each major step, if it's not obvious, ask:
- What does this step produce that later steps need? (data, artifacts, IDs)
- What proves this step succeeded?
- Should the user confirm before proceeding? (especially for irreversible actions)
- Are any steps independent and could run in parallel?
- How should this step execute? (direct, Task agent, teammate, human action)
- Hard constraints or preferences?

Do multiple rounds here for complex workflows — one round per step if needed. Pay special attention to places where the user corrected you during the session. These corrections are the most valuable design inputs.

Don't over-ask for simple processes. A 2-step skill doesn't need annotations on every step.

### Round 4: Trigger and invocation

- Confirm when this skill should be invoked and suggest trigger phrases for the description field.
- Ask for any remaining gotchas, edge cases, or disambiguation with existing skills.

Stop interviewing once you have enough information.

## Step 3: Synthesize via Task Subagent

You do NOT write the SKILL.md yourself. You assemble a structured spec from the interview, then hand it to a Task subagent in a fresh context window. The subagent has zero access to this conversation — no false starts, no exploration noise. If it can produce a working skill from the spec alone, the spec is provably self-contained.

### 3a. Assemble the spec

Build a single self-contained document covering ALL of the following. The subagent sees nothing else — if it's not in the spec, it doesn't exist:

**Frontmatter fields and their values:**
- `name` — always present
- `description` — always present. Multi-line. Include: what the skill does, trigger phrases, disambiguation. This is the most important field — Claude reads it to decide when to auto-invoke
- `allowed-tools` — only if the skill needs a restricted toolset. List specific tools with patterns like `Bash(gh:*)` not bare `Bash`. Omit entirely to inherit the full default toolset
- `context: fork` — only if the user chose forked execution. Omit for inline
- `argument-hint` — only if the skill takes arguments (e.g., `"[issue-number]"`)

**Skill body specification:**
- Goal statement — what artifact exists or condition is true when the skill completes
- Inputs — arguments and what they mean, with `$1`, `$2`, `$ARGUMENTS` references
- Every step, in full detail:
  - What to do (specific, actionable, include commands where appropriate)
  - Success criteria (REQUIRED on every step)
  - Execution mode if not direct (Task agent, teammate, `[human]`)
  - Artifacts produced that later steps consume
  - Human checkpoints for irreversible actions
  - Hard rules and constraints from user corrections
  - Steps that can run concurrently use sub-numbers: 3a, 3b
  - Steps requiring user action get `[human]` in the title

**Format rules for the subagent to follow:**
- Each bash code block runs in a separate shell — variables don't persist between blocks. Use prose to carry state, not shell variables
- Express conditionals as numbered English steps, not nested if/elif/else
- Don't hardcode branch names — detect dynamically
- Keep simple skills simple — match complexity to the workflow
- Executables use hardcoded paths: `~/.steez/bin/config`, `~/.steez/bin/browse`
- Documents use repo symlink: `~/.steez/repo/ETHOS.md`

**Save path** — the exact file path where the SKILL.md should be written, including directory creation.

### 3b. Spawn the subagent

Spawn a Task subagent with the assembled spec as the entire prompt. The prompt must be fully self-contained — no "based on the conversation above," no "as discussed," no references to anything outside the prompt. The subagent's only job is to create the skill directory and write the SKILL.md file at the specified path.

Wait for the Task to complete before proceeding to Step 4.

## Step 4: Validate and Report

After the Task subagent returns, validate the result in this session:

### 4a. Read back and verify structure

Read the file at the expected path. Confirm it exists and has the expected sections.

### 4b. Check YAML frontmatter

```bash
python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    content = f.read()
fm = content.split('---')[1]
data = yaml.safe_load(fm)
print('Parsed fields:', list(data.keys()))
print('Name:', data.get('name'))
desc = str(data.get('description', ''))
print('Description preview:', desc[:100])
" "<skill-path>"
```

If the YAML fails to parse, fix the frontmatter directly rather than re-running the subagent.

### 4c. Update skills.json (steez-managed only)

If the skill was saved to `~/Projects/Personal/steez/skills/`, update `skills.json`:
- Add to the `skills` object: `"<name>": { "description": "<max 80 chars>" }`
- Add the skill name to the appropriate category's `skills` array in `categories`

### 4d. Report to the user

Tell the user:
- Where the skill was saved (full path)
- How to invoke it: `/<skill-name>` or `/<skill-name> <arguments>`
- That they can edit the SKILL.md directly to refine it
- Suggest `/sharpen-skill` if they want to evaluate and improve it with evals later
