---
name: handoff
description: "Context-budget session handoff. Creates a structured handoff bead capturing load-bearing session state, spawns a fresh agent in a sibling tmux pane seeded with the bead, and leaves the old session alive for last-resort queries. Use when the user says '/handoff', 'hand off this session', 'let's hand off', 'context is getting big', 'hand off', 'context budget', 'fresh session', 'spawn a replacement', or 'my context is running out'. Also trigger when asked to 'pass the baton', 'start fresh', or 'new session with context'."
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - AskUserQuestion
---

# /handoff -- context-budget session handoff

Hand off load-bearing context to a fresh session before the context window degrades. By the time native compaction triggers, the agent writing the summary is already degraded. /handoff lets the user trigger a clean handoff while the agent is still sharp.

Creates a structured "handoff bead," spawns a new agent in a sibling tmux pane, seeds it with a minimal prompt pointing at the bead, and leaves the old session alive for last-resort queries.

## Step 1: Pre-flight

First, verify you're inside tmux:

```bash
[[ -n "$TMUX_PANE" ]] && echo "tmux: $TMUX_PANE" || echo "ERROR: not in tmux"
```

If `$TMUX_PANE` is empty, tell the user "/handoff requires tmux -- the spawn and old-session query steps depend on it" and stop.

Then run `git status`. If the working tree is dirty, use AskUserQuestion:

**Re-ground:** You're about to hand off this session to a fresh agent. The working tree has uncommitted changes.

**Question:** Handoff requires a clean working tree so the new agent starts from a known state. What do you want to do with the uncommitted changes?

**Options:**
1. **Commit changes (Recommended)** -- stage and commit now, then proceed. Completeness: 9/10.
2. **Abort** -- cancel handoff, keep working in this session. Completeness: N/A.

**RECOMMENDATION:** Choose 1 -- commit preserves the work in history and the new agent can see it in `git log`.

If abort, stop entirely. If commit, execute it, verify the tree is clean, then continue.

**Clean tree is a hard prerequisite.** A handoff that inherits half-finished code lies to the new agent, and the new agent has no conversational backstop to catch it.

## Step 2: Capture state

Gather these values before drafting:

```bash
# Current tmux pane (stable %N format)
OLD_PANE="$TMUX_PANE"

# HEAD commit
HEAD_HASH=$(git rev-parse --short HEAD)
HEAD_SUBJECT=$(git log -1 --format=%s)

# In-flight bead (if any)
IN_FLIGHT_BEAD=$(bd list --status=in_progress 2>/dev/null | awk 'NR==1 {print $2}')

# Working directory
WORK_DIR=$(pwd)
```

### Workshop detection

If you ran `/workshop` during this session (or resumed one via `bd update <id> --claim`), you already know the workshop bead ID from your own conversation context. Use that ID directly -- do not query `bd list` for it.

If you're unsure whether this session had an active workshop, check your own memory first. Only fall back to `bd list --status=in_progress --label=workshop` if you genuinely can't recall. If that query returns multiple results, ask the user which one belongs to this session via AskUserQuestion.

Once you have the workshop bead ID, read it via `bd show` and hold onto its description (framing), design (Q&A log), and notes. You'll use these as primary sources in Step 3 instead of reconstructing from memory.

Before proceeding, do one final Q&A log update on the workshop bead so it reflects the current state of all threads:

```bash
cat > /tmp/workshop-qa-final.md <<'EOF'
<current Q&A log with all OPEN/RESOLVED/KILLED sections up to date>
EOF
bd update $WORKSHOP_BEAD --design-file=/tmp/workshop-qa-final.md
```

## Step 2b: Reconcile before drafting

The handoff is happening because the context window is long enough to degrade. Your top-of-mind recall of the session is the least reliable source available. Before drafting, force yourself to verify against actual artifacts.

**Re-read the conversation.** Scan from the beginning for: user corrections, new requirements, scope changes, and decisions that emerged during discussion. Pay special attention to moments where the user pushed back or corrected you -- those are the highest-signal turns and the easiest to forget.

**Re-read the originating ticket/issue.** If the session started from a Jira ticket, GitHub issue, or bead, re-read it now. Check that you're capturing the full spec (field names, acceptance criteria, explicit requirements), not just your summary of the problem.

**Re-read any beads updated during the session.** `bd show` the in-flight bead if one exists. Check what's already captured vs what's missing.

**Update the in-flight bead.** Reconcile conversation findings into the bead's notes/description -- any decisions, corrections, or research results from the conversation that aren't yet captured. This is your last chance to make the artifact current while you still have the full conversation available. The new agent may read this bead independently of the handoff bead, so it must stand on its own.

```bash
# Example: append session findings to the in-flight bead
bd update <IN_FLIGHT_BEAD> --append-notes "<findings not yet captured>"
```

Only after completing this reconciliation should you proceed to drafting.

## Step 3: Draft the handoff bead

Draft from the artifacts you just reviewed and updated -- not from top-of-mind recall. The originating ticket, the in-flight bead, and the conversation history are your sources. Be specific and concrete -- the new agent has zero context beyond what you write here. If a section is empty, say so explicitly ("None so far.") rather than omitting it.

### Workshop handoff sourcing

If `WORKSHOP_BEAD` is set, the workshop bead's structured fields are your primary source -- they're higher fidelity than your memory of the conversation. Source the handoff schema from them:

- **Decisions Made**: pull from the Q&A log's RESOLVED section (these are decisions with rationale already written in cold-start-complete form)
- **Dead Ends**: pull from the Q&A log's KILLED section (these include reasons)
- **Open Questions**: pull from the Q&A log's OPEN section (these have status lines)
- **Context**: pull from the workshop bead's description (originating framing)

Only supplement from your conversation memory for things not captured in the bead: session calibrations, user preferences, and any context that emerged after the last Q&A log update.

Add a `## Workshop Continuation` section to the description schema (after Session Calibrations, before Old Session):

```
## Workshop Continuation
This session was running /workshop on bead WORKSHOP_BEAD.

To resume:
1. Run /workshop to load the skill.
2. bd update WORKSHOP_BEAD --claim to trigger the workshop resume flow.

The skill handles Q&A log maintenance, lenses, Mode A/B, and disposal
automatically once loaded. The workshop bead is the primary artifact.
This handoff bead is the bridge.
```

**Title:** `handoff: <one-line description of the in-flight work>`

**Type:** `task`

**Priority:** inherit from the in-flight bead if one exists, otherwise P2.

### Description schema

```
## Next Action
- <one imperative sentence: what to do next>
- First command: <literal first tool call or shell command the new agent should run>
- Done when: <success criterion in one line>

## Context
<3-4 sentences. What we were building and why. Include repo, branch, feature area.
Enough for a cold-start session to orient without searching.>

## Decisions Made
- <Decision> -> <one-sentence rationale>
- ...

## Dead Ends
- Tried <X> -> Result: <Y> -> Lesson: <Z>
- ...
(If none: "None so far.")

## Files & State
- Files touched this session: <list of absolute paths>
- HEAD at handoff: <HASH> <SUBJECT>
- Working tree: clean
- Working directory: <WORK_DIR>

## Open Questions
- <Question>. Options discussed: <A, B>. Recommendation: <pick one>.
- ...
(If none: "None.")

## Session Calibrations
- <Actor (User: / Decided:)>: <one-line calibration>
- ...
(User preferences, style decisions, scope adjustments expressed during the session.
If none: "None.")

## Old Session
Old session idle in tmux pane OLD_PANE. You are the agent -- do the
work yourself. Only query the old session for things only it
experienced firsthand: user conversations, decisions not captured
above, context that didn't make it into this bead. Anything about
the work itself, figure out normally or ask the user.

To query (send, poll, read):
  ~/.steez/bin/agent-send OLD_PANE "your question"
  while [[ "$(~/.steez/bin/agent-state OLD_PANE | jq -r .state)" == "working" ]]; do
    sleep 3
  done
  ~/.steez/bin/agent-history OLD_PANE --last
```

Replace `OLD_PANE` with the actual pane target (e.g., `%5`) everywhere in the schema.

### Design field

`Handoff from session in pane <OLD_PANE>.` If there's an in-flight bead, append: `Continuing work from <IN_FLIGHT_BEAD>.`

## Step 4: Show draft and get approval

Print the full drafted bead (title, description, design) to the user. Then use AskUserQuestion:

**Re-ground:** You're handing off this session. Below is the handoff bead draft -- everything the new agent will know about your session.

**Question:** Does this capture everything load-bearing? Anything missing, wrong, or misleading?

**Options:**
1. **Approve and spawn (Recommended)** -- create the bead and launch the new agent as-is. Completeness: 10/10.
2. **Edit first** -- tell me what to change, I'll update and re-show. Completeness: varies.
3. **Abort** -- cancel handoff, keep working in this session. Completeness: N/A.

**RECOMMENDATION:** Choose 1 if the draft looks right. Choose 2 if anything load-bearing is missing -- the new agent can't recover what isn't in the bead.

If the user chooses edit: apply their changes, print the updated draft, and ask again. Loop until approved or aborted.

## Step 5: Create the bead

Create the handoff bead. The description is large and contains special characters, so pipe it via heredoc using `--body-file -` instead of inlining it as a `--description` argument. Same for `--design-file -` if the design field is multi-line.

```bash
bd create \
  --title "handoff: <title>" \
  --body-file - \
  --design "<design field>" \
  --type task \
  --priority <inherited or 2> <<'EOF'
<full description from draft>
EOF
```

Capture the returned bead ID.

If there's an in-flight bead that is **not** the workshop bead, wire the dependency so `bd ready` surfaces the handoff bead first:

```bash
bd dep add <IN_FLIGHT_BEAD> <HANDOFF_BEAD_ID>
```

**Do not dep-add the workshop bead.** It needs to stay independently claimable by the new agent. The spawn prompt already names both beads explicitly.

This is belt-and-suspenders for non-workshop in-flight beads: the spawn prompt also names the handoff bead.

## Step 6: Spawn the new agent

**Standard handoff** (no workshop bead):

```bash
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h \
  --model ren \
  --dir "WORK_DIR" \
  --prompt "You are picking up work from a handoff. The previous session ended because its context window was approaching exhaustion.

Your first two actions:
1. bd show HANDOFF_BEAD_ID -- the handoff bead. Contains session context: next action, decisions made, dead ends, open questions, session calibrations, and how to reach the old session.
2. bd show IN_FLIGHT_BEAD -- the work bead. Contains the task description, research findings, and notes updated through the end of the previous session.

Read both completely before doing anything else. The handoff bead tells you what happened and what to do next. The work bead tells you what the task is and what's been found so far."
```

If there is no in-flight bead, use the single-bead variant instead:

```bash
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h \
  --model ren \
  --dir "WORK_DIR" \
  --prompt "You are picking up work from a handoff. The previous session ended because its context window was approaching exhaustion, and it summarized its state into bead HANDOFF_BEAD_ID.

Your first action: bd show HANDOFF_BEAD_ID

The bead contains the next action, decisions made, dead ends, files touched, open questions, and session calibrations. Read it completely before doing anything else. It also tells you how to reach the previous session if you need to."
```

**Workshop handoff** (workshop bead active):

```bash
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h \
  --model ren \
  --dir "WORK_DIR" \
  --prompt "You are picking up a workshop handoff. The previous session ended because its context window was approaching exhaustion.

Your first two actions:
1. bd show HANDOFF_BEAD_ID -- read the handoff bead for session context, decisions, dead ends, and calibrations.
2. Run /workshop -- this loads the workshop skill. Then claim bead WORKSHOP_BEAD via bd update WORKSHOP_BEAD --claim to trigger the skill's resume flow.

The workshop skill handles everything from there: Q&A log maintenance, lenses, Mode A/B, disposal. You don't need to manually replicate any of that."
```

Replace `HANDOFF_BEAD_ID` and `WORKSHOP_BEAD` with actual bead IDs in the prompt.

Parse `TARGET=%N` from the script output -- this is the new agent's pane ID.

If spawn fails, report the error to the user. The handoff bead is already created and valid -- the user can manually spawn or use spawn-agent to retry.

## Step 7: Report

Print to the user:

> **Handoff complete.** New agent in pane **<TARGET>**. Bead: **<HANDOFF_BEAD_ID>**. This session is staying alive for last-resort queries -- close the pane when you're satisfied the new agent has picked up.

## Step 8: Go idle

Do not auto-terminate. Do not continue working on the in-flight task. Do not offer to help further. The old session's only remaining purpose is answering questions from the new agent or the user about what happened during this session.

## Edge cases

- **No in-flight bead:** The flow works unchanged. Skip the `bd dep add` in step 5. The handoff bead stands alone and the new agent picks it up from `bd ready` or the spawn prompt.
- **Workshop bead active:** The workshop bead is the primary artifact. The handoff bead is a bridge carrying session-specific context (calibrations, the old-session query recipe) that the workshop bead doesn't capture. The new agent reads both: handoff bead for session context, workshop bead for the actual work. The workshop bead stays open (not closed by handoff) -- the new agent claims it and continues.
- **Very early session:** Sections like "Decisions Made" and "Dead Ends" may be thin. That's fine -- write what exists. A thin handoff bead is better than no handoff.
- **Multiple in-flight beads:** Pick the one most relevant to the current work. If genuinely ambiguous, ask the user which one.
- **User edits multiple times:** Loop steps 3-4 without limit. Don't rush the user -- the bead quality determines the new session's effectiveness.
- **Non-ren agent:** The spawn command defaults to `--model ren`. If the user is running a different agent (prometheus, claude, codex), they should say so during the draft review and you should adjust the `--model` flag accordingly.
