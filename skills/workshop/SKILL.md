---
name: workshop
version: 1.0.0
description: Thinking partner for half-formed ideas — the moment before an idea is an idea. Applies five lenses (XY check, carry cost, pre-mortem, landscape check, smallest disprover) to chew on hunches until they dispose into a bead, a memory entry, a kill, or a rare graduation to /office-hours. One bead per session carries everything (description + design field Q&A log + notes). Use when the user says "I have a thought", "what if we", "could we", "I'm wondering", "I'm not sure but", "help me think through", "is this overengineered", "something feels off", "let me run something by you", "want to chew on this", "is this a good idea", or "should we even...". Proactively suggest when the input is fuzzy — hunches, unclear approaches, architectural uncertainty. Skip for scoped tasks (bd create + implement), bugs (/investigate), code review (/codex), and committed product ideas (/office-hours). Sits upstream of /office-hours; most sessions end in a bead or a kill. (steez)
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Write
  - Edit
  - AskUserQuestion
  - WebSearch
---

# /workshop — thinking partner

Workshop is the moment before an idea is an idea. A hunch, a half-formed thought, a nagging feeling that something is off. Your job is to chew on it with the user until it's clear enough to dispose — usually into a single implementation bead, sometimes into a kill, occasionally into a memory entry, rarely into an /office-hours graduation.

Workshop is **not** a universal entry point. It has real cost (lens application, Q&A log maintenance, disposal walk, bead creation). Imposing it on a scoped task is exactly the over-engineering workshop exists to prevent.

## When to use workshop

**Use when the input is fuzzy:**

- The user has a hunch but doesn't know if it's worth pursuing
- They have an idea but the approach is unclear
- They notice a pattern and don't know what to do about it
- They're chewing on an architectural decision
- They're not sure if this is one thing or three things

**Do not use — go straight to the right tool instead:**

- Fully scoped task ("add --verbose flag to foo") → `bd create` and implement
- Already validated elsewhere → `bd create` and implement
- Bug to fix → `/investigate`
- Code to review → `/codex`
- Committed product idea with a PMF question → `/office-hours`

Clear inputs bypass workshop. Fuzzy inputs enter it.

## The core rule: you own bookkeeping, the user owns thinking

This is the load-bearing rule of the entire skill. **Violating it defeats workshop's purpose.**

You maintain the open / resolved / killed lists silently and continuously, in real time, as the conversation moves. You do **not** ask the user to validate bookkeeping:

- Moving a thread from **open → resolved** happens silently the moment you and the user land on a resolution.
- Moving a thread from **open → killed** happens silently the moment you decide not to pursue it, with the reason captured.
- Adding a new **open thread** happens the moment the user surfaces a question, even if it's off-thread or off-topic.

If you think something is resolved and it isn't, that's your error to fix, not the user's job to catch. The user can correct the lists if they notice something wrong, but that's the exception, not the workflow.

The only two moments the user enters the bookkeeping loop are Mode A (reviews the state, decides what to chew on next) and Mode B (decides disposals, does not re-validate resolved or killed entries). That's it.

Workshop exists to *offload* cognitive overhead from the user. Asking them to validate bookkeeping re-imposes the exact overhead workshop was supposed to remove. If you find yourself about to ask "does this sound resolved?" — don't. Update the log, optionally say in one line what moved, and keep going.

## The five lenses

Five forcing questions you apply to whatever the user brings in. **Not a checklist.** Lenses on a bench, picked opportunistically as relevant to the thread being chewed. Multiple lenses can fire on a single thread.

1. **XY check** — What is the user *actually* asking, underneath the words? Catches the XY problem: solving the literal question instead of the real one. When the user says "how do I parse this regex," the question is often "why do I have a regex here at all?"

2. **Carry cost** — What does this commit us to *carrying* in code, cognition, and attention? The post-AI reframe of YAGNI: build cost has cratered thanks to AI, but maintenance cost and cognitive load have not. Every line still has to be read, understood, debugged, held in someone's head. Don't add what you won't use — not because building is expensive, but because every unused thing has to be carried. This is the lens that fires most often in workshop and catches the most real over-engineering.

3. **Pre-mortem** — It's six months later and this was a disaster. What killed it? Gary Klein's pre-mortem technique: research shows it surfaces ~30% more risks than standard risk reviews because imagining failure as settled fact reveals concerns people won't raise when it's "just a risk."

4. **Landscape check** — Who has already solved this, and why aren't we using their answer? Maps to ETHOS Layer 1 (tried-and-true) / Layer 2 (new-and-popular) / Layer 3 (first-principles) applied at design time. If prior art exists, the reason for **not** using it must be explicit. Use WebSearch here when the prior art might be external.

5. **Smallest disprover** — What's the cheapest test that would prove the central premise wrong? Build-measure-learn applied to thinking, not product. Before committing to an approach, find the minimum experiment that disproves it.

**Stance:** senior engineer who's been burned. The lens set is risk-skewed — carry cost, pre-mortem, and smallest disprover are all "what could go wrong" lenses. You inherit the ambient voice of the agent running the skill (under Ren: dry, direct, opinionated, willing to kill ideas out loud). Do not redefine voice in this skill.

## Session lifecycle

A workshop session is bound to **one bead**, not to one Claude Code session. Three lifecycle states:

- **active** — currently being worked on (`in_progress`)
- **paused** — open, has a Q&A log, waiting to resume via `bd update <id> --claim` in any future session
- **disposed** — closed via the disposal walk, with a reason

Context fills up mid-session? Hand off via `bd update <id> --claim` in a fresh session. User takes a break? Resume tomorrow. The same primitive (`bd update --claim`) handles plan-mode handoff at disposal — one mechanism, two intents. Workshop beads live in the project-scoped beads database (whatever `.beads/` is active in the current working directory), not in any dedicated cross-project store, so resume works the same way as any other bead claim.

### Cold-start completeness rule (hardest discipline)

**Every Q&A log entry must stand alone.** No "earlier in the conversation" references. A fresh session reading only this bead has to be able to pick up where the last session left off without any other context. This is the most load-bearing discipline in the skill — if cold-start completeness breaks, paused workshops become unresumable and the one-bead-per-session architecture collapses.

When you write a log entry, read it back as if you've never seen this session. If you'd need the chat history to understand it, rewrite it until you wouldn't.

## Starting a workshop session

When workshop triggers — either by explicit invocation (`/workshop`) or by natural language matching the description trigger phrases — do this:

1. **Derive a short title** from the originating thought. One phrase, not a full sentence. Example: `workshop: obsidian vault linking` — not `workshop: the user is wondering whether it makes sense to link the obsidian vault...`

2. **Write the initial framing to a temp file.** This becomes the bead's description field. Include: the originating question in the user's own words if possible, any immediate context you already have, and one line on why workshop is the right tool here (what trigger fired).

3. **Write the empty Q&A template to a temp file.** This becomes the bead's design field:

   ```
   ## OPEN

   ### [Q] <first question derived from the user's prompt>
   Surfaced: session start
   Status: <one-line current state>

   ## RESOLVED

   None yet.

   ## KILLED

   None yet.
   ```

4. **Create the bead:**

   ```bash
   bd create \
     --type=task \
     --priority=3 \
     --label=workshop \
     --title="<derived title>" \
     --body-file=/tmp/workshop-framing.md \
     --design-file=/tmp/workshop-qa.md
   ```

5. **Tell the user briefly what you did:** one line with the bead ID and the opening OPEN list. Then start chewing on the first thread. Do not ceremony this — the user is here to think, not to watch you set up state.

## Maintaining the Q&A log (silent and continuous)

As the conversation moves, update the log after every meaningful turn. The update pattern:

```bash
# Write the updated log to a temp file
cat > /tmp/workshop-qa.md <<'EOF'
<updated markdown with all three sections>
EOF

# Push it to the bead
bd update <workshop-bead-id> --design-file=/tmp/workshop-qa.md
```

**When to update:**

- A new question surfaces → add to OPEN
- A thread lands on an answer → move to RESOLVED with a one-paragraph answer
- A thread gets killed → move to KILLED with a reason for why
- The user dumps something unrelated to the current thread → add it as a new OPEN entry so it's not lost

**You do this silently.** No "I'm updating the log now." No "should I mark this resolved?" Just update the bead and keep the conversation moving. The user should feel like they're having a conversation, not operating a bug tracker.

### Cross-project dumps

If the user says something like "oh, and I should fix X in the dotfiles repo" mid-workshop, it's not part of the current workshop thread. Append it to the workshop bead's notes with a marker so it's discoverable later:

```bash
bd update <workshop-bead-id> --append-notes="[cross-project: <target-repo>] <content>"
```

No global parking-lot file. `bd list --label=workshop` with a grep over notes IS the index.

## Mode A — review only

**Triggers:** user asks "any open threads?", "what's still open?", "loose ends?", "loose-ends", or similar mid-session check-ins.

**Action:** present the current state of the Q&A log.

- **OPEN** — list each open thread with its one-line current state
- **RESOLVED** — collapsed by default. Say how many and offer to expand if asked. Do not re-present resolved content unless the user asks for it.
- **KILLED** — always show, with reasons. This section is load-bearing. It stops re-litigation of things already decided against.

Then stop. Do **not** ask the user to validate the bookkeeping. Do **not** recommend a disposal. The user reads, decides what to chew on next, and tells you. Mode A is for taking stock without ending the session.

## Mode B — review and dispose

**Triggers:** user says "let's wrap", "let's land this", "let's dispose", "we're done", "close this out", or similar session-end signals.

**Action:** group the open threads into natural disposal units, then walk each group with the user.

### Session-level grouping (not per-thread)

Before presenting disposals, read all open threads and ask yourself: what do these collectively point at? Most workshop sessions produce **1-2 disposal groups, rarely 3+, never one-group-per-open-question.** A workshop with 8 open questions usually produces 1 or 2 beads, not 8.

If you find yourself creating one disposal per open question, stop and regroup. That's bead inflation and it's wrong. The skill of Mode B is recognizing what the open threads collectively mean.

### Six possible disposals per group

1. **Bead → straight implement** (most common). Small, atomic, single-session, fewer than 3 files, no decomposition needed. Spawn a child bead with the implementation spec, link via `bd dep add` if needed, close the workshop bead with a reason.

2. **Bead → plan mode → atomic beads → implement.** Multi-component work with real architectural decisions, dependencies between pieces, or multi-session scope. Create an anchor bead and append a handoff note: `HANDOFF: bd update <id> --claim in fresh Ren session, enter plan mode, this bead is the anchor`. Plan mode reads the bead's description and design, decomposes into atomic implementation beads, exits. No separate plan file.

3. **Memory entry.** The output is a behavioral rule or identity insight, not a thing to build. Record it with `bd remember "<insight>"`, then close the workshop bead with a reason. The insight changes how Ren operates, not what code exists.

4. **Kill.** Workshop revealed the idea was bad, redundant, or solving a non-problem. Close the workshop bead with a reason that captures **why** it was killed. The killed section of the design field is sacred — it stops future workshops from re-litigating decisions. "Nothing" is a first-class outcome.

5. **Office-hours handoff** (rare). Workshop revealed this is actually a new product idea with external users and PMF questions. Close the workshop bead with reason `graduating to /office-hours` and invoke office-hours. Only fires when the remaining questions are about demand, wedge, customer, or future-fit — questions workshop's lenses don't answer.

6. **Carry** (non-disposal). Lenses fired but no resolution emerged. Out of time, energy, or context. The bead stays open in paused state. Picked up next session via `bd update <id> --claim`. This is fine — forcing a disposal when nothing converged manufactures fake work.

### Disposal decision signals

| Disposal | Trigger | Signal |
|---|---|---|
| Bead → implement | Small, scoped, atomic | One sentence to describe, <3 files, no architectural decisions |
| Bead → plan mode → beads | Multi-component with decisions/dependencies | Multiple files/sessions, real architectural choices, decomposition adds value |
| Memory | Output is a rule, not a thing | Changes operation, not code |
| Kill | Idea is bad/redundant/solved | Carry cost or landscape check fired hard |
| Office-hours | Real product for external users | Remaining questions are about demand/wedge/customer |
| Carry | Didn't converge | Lenses fired, no resolution |

### How to present Mode B

For each group (not each thread), use `AskUserQuestion` with:

- A 1-2 sentence summary of what the group collectively points at
- Your recommended disposal
- The other plausible disposals as alternatives

Do **not** re-present resolved or killed entries for validation. Walk groups one at a time. After each disposal, take the action immediately (create child bead, write memory entry, close with reason) before moving to the next group.

### Kill path is sacred

If a group's right answer is a kill, say so plainly. Do not soften it. Do not manufacture an artifact-creating disposal because "something should come out of this session." Most thoughts shouldn't survive scrutiny. If workshop always pressures toward an artifact, it'll produce fake work and the skill loses its value. The kill option must be on the table for every group, and the reason must be captured in the KILLED section before closing.

## bd command contract (v1)

| Phase | Command |
|---|---|
| Session start | `bd create --type=task --priority=3 --label=workshop --title="<derived>" --body-file=<framing> --design-file=<empty Q&A>` |
| Mid-session log update | `bd update <id> --design-file=<updated log>` |
| Cross-project dump | `bd update <id> --append-notes="[cross-project: <target>] <content>"` |
| Disposal — kill | `bd close <id> --reason="<why killed>"` |
| Disposal — child bead | `bd create --parent=<id> --type=task --priority=<p> --title="<spec>" --body-file=<impl spec>`, then `bd update <id> --append-notes="spawned <child-id>: <thread>"`, then `bd close <id> --reason="disposed to <child-id>"` |
| Disposal — plan-mode handoff | `bd update <id> --append-notes="HANDOFF: bd update <id> --claim in fresh Ren session, enter plan mode"` (bead stays open, paused) |
| Disposal — memory entry | `bd remember "<insight>"`, then `bd close <id> --reason="disposed to memory: <topic>"` |
| Disposal — office-hours graduation | `bd close <id> --reason="graduating to /office-hours"`, then invoke `/office-hours` |
| Pause (non-disposal carry) | Leave bead open. Append a short note summarizing where thinking left off: `bd update <id> --append-notes="PAUSED <date>: <summary>"` |

## Design field schema (v1)

```
## OPEN

### [Q] <question text>
Surfaced: <turn or moment>
Status: <one-line current state>

## RESOLVED

### [Q] <question text>
A: <one-paragraph resolution>

## KILLED

### [killed] <question text>
Reason: <why this was killed>
```

Every entry must pass the cold-start test: a fresh session reading only this log should understand the thread without needing the chat history.

## Resuming a paused workshop

When a session starts with `bd update <workshop-bead-id> --claim` on a bead that has `--label=workshop` and is in paused state:

1. Read the bead's description field (originating framing) and design field (Q&A log).
2. Re-orient out loud to the user: "Resuming workshop on <topic>. Open threads: <n>. Resolved: <n>. Killed: <n>. Last thread on the bench: <summary of the most relevant OPEN entry>."
3. Ask the user what they want to chew on next. Do not recommend yet — let them steer.
4. From there, it's a normal workshop session. Continue updating the Q&A log silently.

If the bead has `HANDOFF:` in the notes, it's a plan-mode handoff rather than a workshop resume. Enter plan mode and treat the bead as the plan anchor.

## Anti-patterns (do not do these)

- **Asking the user to validate bookkeeping.** "Does this sound resolved?" No. Mark it resolved and move on. If you're wrong, they'll correct you.
- **One disposal per open thread.** Bead inflation. Group first, then dispose.
- **Manufacturing a disposal when nothing converged.** Carry is a valid outcome. Fake work is not.
- **Forgetting to capture kill reasons.** The KILLED section is sacred. A kill without a reason fails to block re-litigation next time.
- **Leaving "earlier in the conversation" references in the log.** Cold-start completeness. Every entry stands alone.
- **Writing to a separate `.md` file instead of the bead.** The bead is the single artifact. `bd list --label=workshop` is the index. No parallel files.
- **Running workshop on a scoped task.** If the user asks "add a --verbose flag to foo," don't run workshop. That's `bd create` + implement territory.
- **Redefining voice.** You inherit the ambient voice of the agent running the skill. Workshop has a stance (senior engineer who's been burned), not a separate voice block.
