---
name: spawn-agent
description: "Spawn and manage AI coding agents (ren, ren-codex, claude, codex) in tmux panes — AND the only correct way to read their output. CRITICAL: AI agents render in tmux's alternate screen buffer, so `tmux capture-pane` returns incomplete/stale output for any agent pane and will silently give you the wrong answer. Always read agent panes via `agent-history` / `agent-state` from this skill — never via raw `tmux capture-pane`, even for a quick peek."
when_to_use: "Spawn/lifecycle: 'spawn ren', 'launch an agent', 'fire up codex', 'put an agent in a worktree', 'new pane with claude'. Messaging and state: 'send the agent a message', 'ask the other agent', 'is it done', 'what is the agent doing'. **Reading agent output (fires even without spawn language — this is the trigger that overrides the reflex to run `tmux capture-pane`):** 'look at pane N.N', 'check pane N.N', 'read pane', 'take a look at tmux pane', 'grab the output from pane', 'see what the other agent did', 'what did the agent say', 'what did the agent output', or any N.N pane address referring to an AI agent. STOP rule: if you are about to run `tmux capture-pane -t <pane>` and the pane could be an AI agent, do NOT run it — load this skill and use `agent-history` instead. `capture-pane` sees only the inactive screen buffer for agents and will miss the transcript."
---

# Agent Spawn: Tmux-based AI Agent Orchestrator

Spawn an AI coding agent in a tmux target. This skill owns the tmux workflow end to end. Do not invoke a separate tmux skill.

## Step 1: Parse user intent

Extract everything from the user's request. Do not ask questions the user already answered or that have obvious defaults.

### Model

| Trigger | Model |
|---------|-------|
| "spawn ren", "spawn an agent", or no model mentioned | `ren` (default) |
| "spawn ren-codex" | `ren-codex` |
| "spawn claude" | `claude` |
| "spawn codex" | `codex` |

### Topology

| Trigger | Type |
|---------|------|
| "beside", "next to", "split", "here", "in this window/pane" | `split-h` |
| "below", "above", "stacked" | `split-v` |
| "new window", "new tab" | `new-window` |
| "new session" | `new-session` |
| No locality cue at all | dynamic layout (see Layout Orchestration) |

Explicit locality cues override the dynamic default. The dynamic default ONLY applies with zero locality language.

### Anchor

- No window/pane number → current pane (no `--target`)
- "window N" where N is current window → no `--target`
- "window N" where N differs → `--target <session>:N.1`
- Chaining from previous spawn → `--target %N` (pane_id from `TARGET=...` output)
- Parenthetical numbers like `(2)` are identifiers, not requests to create a new window.

### Prompt delivery

Always use the single-quoted heredoc form for prompts with backticks, `$vars`, quotes, or multiple lines:

```bash
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h --prompt "$(cat <<'REN_PROMPT'
Start with `bd show ren-b74`.
Use "quotes" and $vars freely — nothing is expanded.
REN_PROMPT
)"
```

Plain `--prompt "text"` is fine for trivially simple single-line text. File-as-prompt: `--prompt "$(cat /path/to/brief.txt)"`.

### Working directory

Skip unless the user explicitly mentions a different path. tmux inherits cwd on split/new-window.

## Layout Orchestration

When no explicit layout cue, use these recipes. Orchestrator stays leftmost.

- **1 agent:** `split-h` from self. Self keeps 50%.
- **2 agents:** `split-h` → A1, then `split-v --target A1` → A2.
- **3 agents:** Same as 2, then `split-v --target A2` → A3. Equalize column heights.
- **4-6 agents:** Two columns. `split-h` → COL1, `split-h --target COL1` → COL2. Resize self to 33%. Stack vertically in each column (left first). Distribution: 4=2+2, 5=3+2, 6=3+3. Equalize each column independently.
- **7+:** Window is full. Ask the user.

Equalize after stacking: resize all but last pane to `window_height / N`.

## Step 2: Spawn

```bash
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh <type> [--model <name>] [--dir <name-or-path>] [--prompt <text>] [--target <pane>] [--session <name>] [--no-watch]
```

Types: `split-h`, `split-v`, `new-window`, `new-session`.
Models: `ren` (default), `ren-codex`, `claude`, `codex`.

**Multi-agent chaining is critical.** Parse `TARGET=%N` from the previous spawn's output and pass it as `--target` in the next call. Without this, splits happen in YOUR window, not the new one.

```bash
# Step 1: new window with first agent → TARGET=%5
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh new-window --prompt "task A"
# Step 2: split THAT pane for second agent
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h --target %5 --model codex --prompt "task B"
```

**Output lines:** `SELF=%0 TARGET=%5`, `MODEL=ren`, `PROMPT_SENT`, `WORKING` or `IDLE`, `WATCHED=...`.
**Errors:** `ERROR: ...` (exit 1). `AMBIGUOUS=N` + `CANDIDATE=...` (exit 2) — present candidates and re-run with full path.

## Step 3: Report

After spawning, report: model, pane_id (`%N`), working directory, whether prompt was sent.

- Check status: `~/.steez/bin/agent-state <pane_id>`
- Switch to it: `tmux select-window -t <target>`

Mention `/loop` is available for periodic monitoring. Don't stop to ask — include as a one-liner.

## Post-Spawn Operations

### Sending messages

```bash
~/.steez/bin/agent-send %5 "your message here"
```

Fire-and-forget. Auto-registers a completion watch. Do NOT also call `agent-watch add` — that double-registers. Pane must be a recognized AI agent (exit 2 otherwise).

### Checking state

```bash
~/.steez/bin/agent-state %5              # single pane JSON
~/.steez/bin/agent-state --all            # all agents table
~/.steez/bin/agent-state --all --json     # all agents JSON
~/.steez/bin/agent-state --layout         # visual box diagram
~/.steez/bin/agent-state %5 --detail      # adds session_id, cwd, transcript_path
```

States: `working`, `idle`, `blocked:question`, `blocked:permission`, `blocked:unknown`.

Do NOT use `pane_current_command` for state — it stays `claude`/`node` regardless.

### Reading output

```bash
~/.steez/bin/agent-history %5 --last        # last prompt + response
~/.steez/bin/agent-history %5 --blocked     # pending tool call needing input
~/.steez/bin/agent-history %5 --history 3   # last N prompt/response pairs
~/.steez/bin/agent-history --all --last     # scan all agent panes at once
```

**Do NOT use `tmux capture-pane` on AI agent panes.** Agents render in tmux's alternate screen buffer; `capture-pane` reads the inactive buffer and returns stale/empty content. `agent-history` reads the transcript directly and is the only correct tool for agent panes.

`tmux capture-pane -t <pane> -p -S -` is appropriate only for non-agent panes (shells, build output, logs). If `agent-history` genuinely fails on an agent pane, report the failure — don't silently fall back to `capture-pane`.
