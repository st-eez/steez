# Skillify

You are capturing this session's repeatable process as a reusable skill.

## Your Session Context

Review the conversation above — every user message, every tool call, every correction. This
is your primary source material. In long sessions, earlier messages may have been truncated.
If you notice gaps, recover earlier context using `~/.steez/bin/agent-history`:

```bash
# Get last N human/assistant exchange pairs from the current session
~/.steez/bin/agent-history --history 20
```

This reads the session's transcript file and returns structured JSON with `prompt`/`response`
pairs, including messages evicted from the context window. Increase N if you need more history.

Pay special attention to:
- The sequence of actions that formed the workflow
- Places where the user corrected or redirected you (these reveal hard constraints)
- Which tools were essential to the workflow vs. incidental to exploration

If the user provided a description when invoking this skill (available as `$ARGUMENTS`),
treat it as the framing for what to capture. If they didn't, infer the process from the
conversation.

If no repeatable process is evident — the session was pure exploration or Q&A — tell the
user and ask them to describe what they want to automate instead.

## Your Task

### Step 1: Analyze the Session

Before asking any questions, analyze the session to identify:
- What repeatable process was performed
- What the inputs/parameters were
- The distinct steps (in order)
- The success artifacts/criteria (e.g. not just "writing code," but "an open PR with CI fully passing") for each step
- Where the user corrected or steered you
- What tools the *workflow* requires (not every tool used during exploration — core workflow tools only)
- What agents were used
- What the goals and success artifacts were

### Step 2: Interview the User

You will use AskUserQuestion to understand what the user wants to automate. Important notes:
- Use AskUserQuestion for ALL questions. Never ask questions via plain text.
- For each round, iterate as much as needed until the user is happy.
- The user always has a freeform "Other" option to type edits or feedback — do NOT add your own "Needs tweaking" or "I'll provide edits" option. Just offer the substantive choices.

**Round 1: High-level confirmation**
- Suggest a name and description for the skill based on your analysis. Ask the user to confirm or rename.
- Suggest high-level goal(s) and specific success criteria for the skill.

**Round 2: More details**
- Present the high-level steps you identified as a numbered list. Tell the user you will dig into the detail in the next round.
- If you think the skill will require arguments, suggest arguments based on what you observed. Make sure you understand what someone would need to provide.
- If it's not clear, ask if this skill should run inline (in the current conversation) or forked (as a sub-agent with its own context). Forked is better for self-contained tasks that don't need mid-process user input; inline is better when the user wants to steer mid-process.
- Ask where the skill should be saved. Suggest a default based on context (repo-specific workflows -> repo, cross-repo personal workflows -> user). Options:
  - **This repo** (`.claude/skills/<name>/SKILL.md`) — for workflows specific to this project
  - **Personal** (`~/.claude/skills/<name>/SKILL.md`) — follows you across all repos

**Round 3: Breaking down each step**
For each major step, if it's not glaringly obvious, ask:
- What does this step produce that later steps need? (data, artifacts, IDs)
- What proves that this step succeeded, and that we can move on?
- Should the user be asked to confirm before proceeding? (especially for irreversible actions like merging, sending messages, or destructive operations)
- Are any steps independent and could run in parallel? (e.g., posting to Slack and monitoring CI at the same time)
- How should the skill be executed? (e.g. always use a Task agent to conduct code review, or invoke an agent team for a set of concurrent steps)
- What are the hard constraints or hard preferences? Things that must or must not happen?

You may do multiple rounds of AskUserQuestion here, one round per step, especially if there are more than 3 steps or many clarification questions. Iterate as much as needed.

IMPORTANT: Pay special attention to places where the user corrected you during the session, to help inform your design.

**Round 4: Final questions**
- Confirm when this skill should be invoked, and suggest/confirm trigger phrases too. (e.g. For a cherrypick workflow you could say: Use when the user wants to cherry-pick a PR to a release branch. Examples: 'cherry-pick to release', 'CP this PR', 'hotfix.')
- You can also ask for any other gotchas or things to watch out for, if it's still unclear.

Stop interviewing once you have enough information. IMPORTANT: Don't over-ask for simple processes!

### Step 3: Write the SKILL.md

Create the skill directory and file at the location the user chose in Round 2.

Use this format:

```markdown
---
name: skill-name
description: |
  What this skill does in one sentence. Use when the user wants to [specific trigger].
  Also triggered by: 'phrase 1', 'phrase 2', 'phrase 3'.
  Do NOT use this skill when [disambiguation if needed].
allowed-tools:
  - Tool(pattern:*)
  - AnotherTool
argument-hint: "[arg1] [arg2]"
context: fork
---

# Skill Title

## Goal
Clearly stated goal for this workflow. Define the done state — what artifact exists or
what condition is true when the skill completes successfully.

## Inputs
- `$1`: Description of first argument
- `$2`: Description of second argument (if applicable)

## Steps

### 1. Step Name
What to do in this step. Be specific and actionable. Include commands when appropriate.

**Success criteria**: What proves this step is done and we can move on.

...
```

**Per-step annotations**:
- **Success criteria** is REQUIRED on every step. This helps the model understand what the user expects from their workflow, and when it should have the confidence to move on.
- **Execution**: `Direct` (default), `Task agent` (straightforward subagents), `Teammate` (agent with true parallelism and inter-agent communication), or `[human]` (user does it). Only needs specifying if not Direct.
- **Artifacts**: Data this step produces that later steps need (e.g., PR number, commit SHA). Only include if later steps depend on it.
- **Human checkpoint**: When to pause and ask the user before proceeding. Include for irreversible actions (merging, sending messages), error judgment (merge conflicts), or output review.
- **Rules**: Hard rules for the workflow. User corrections during the reference session can be especially useful here.

**Step structure tips:**
- Steps that can run concurrently use sub-numbers: 3a, 3b
- Steps requiring the user to act get `[human]` in the title
- Keep simple skills simple — a 2-step skill doesn't need annotations on every step

**Frontmatter rules:**
- `name`: Display name. If omitted, uses the directory name.
- `description`: This is the most important field. Claude reads it to decide when to auto-invoke the skill. Write a multi-line description that includes: what the skill does, trigger phrases, example user messages, and disambiguation (when NOT to use it). Start with what the skill does, then "Use when...", then "Also triggered by: ...", then "Do NOT use when..." if ambiguity with other skills exists.
- `allowed-tools`: Minimum permissions needed. Use patterns like `Bash(gh:*)` not bare `Bash`.
- `argument-hint`: Shown during autocomplete. Only include if the skill takes arguments. Example: `"[issue-number]"` or `"[filename] [format]"`.
- `context`: Only set `context: fork` for self-contained tasks that don't need mid-process user input. Omit for inline (the default).
- Arguments are accessed in the skill body via `$ARGUMENTS` (full string) or `$1`, `$2`, etc. (positional). There is no `arguments` frontmatter field — the hint and the body substitutions are all that's needed.

### Step 4: Validate and Save

Before writing the file, output the complete SKILL.md content as a yaml code block in your response so the user can review it with proper syntax highlighting. Then ask for confirmation using AskUserQuestion with a simple question like "Does this SKILL.md look good to save?" — do NOT use the body field, keep the question concise.

After writing the file, validate it:
1. Read the file back and confirm the YAML frontmatter parses correctly (check that `name`, `description`, and `allowed-tools` are present and well-formed).
2. Verify the file is in the correct directory.
3. If the skill was saved to the steez repo's `skills/` directory, update `skills.json` with a new entry (name, category, description max 80 chars).

Then tell the user:
- Where the skill was saved
- How to invoke it: `/<skill-name> [arguments]`
- That they can edit the SKILL.md directly to refine it
