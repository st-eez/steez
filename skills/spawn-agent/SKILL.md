---
name: spawn-agent
description: "REQUIRED for spawning, prompting, reading from, and communicating with AI coding agents (ren, claude, codex, prometheus) across tmux panes. Use this skill whenever the user wants to spawn, launch, start, orchestrate, message, query, or check on an agent. Spawn triggers: spawn an agent, launch ren, launch prometheus, spin up a claude, fire up codex, start an agent in a new pane, put an agent in a worktree. Post-spawn triggers: send the agent a message, ask the other agent, query the previous session, check what that agent is doing, read the agent's response, wait for the agent to finish. If the operation involves an AI agent in a pane, use this skill."
---

# Agent Spawn: Tmux-based AI Agent Orchestrator

Spawn an AI coding agent (Ren, Prometheus, Claude, or Codex) in a tmux target. This skill is project-agnostic.

## Step 1: Parse user intent

Extract everything from what the user already said. The user's request IS the configuration. Do not ask questions the user already answered or that have obvious defaults.

Parse these four fields **independently**, then combine into script args:

### 1. Model (which agent to launch)

- "spawn ren", "launch ren", "fire up ren", "spawn an agent", "launch an agent", "fire up an agent" → `ren`
- "spawn prometheus", "launch prometheus", "fire up prometheus" → `prometheus`
- "spawn claude", "spawn vanilla claude", "launch a claude" → `claude`
- "spawn codex", "launch codex", "fire up codex" → `codex`
- **Default** (no model mentioned) → `ren`

Ren is the default agent. "Spawn an agent" without qualification means ren. Only explicit "prometheus", "claude", or "codex" gets those models.

### 2. Topology (how to create the pane)

- Explicit "new window" or "new tab" → `new-window`
- Explicit "new session" → `new-session` (ask for session name only if not provided)
- "beside", "next to", "side by side", "split" → `split-h`
- "in this window", "in this pane", "here" → `split-h`
- "below", "above", "stacked" → `split-v`
- **Default** (no locality or split cue at all) → **dynamic layout** (see Layout Orchestration below)

**Precedence rule:** If the user said ANY locality word ("this", "here", "beside", "in window"), that is a split cue. Explicit "new window" or "new session" overrides. The dynamic default ONLY applies when there is zero locality language. Never let the default override an explicit cue.

### 3. Anchor (where to create it)

- "this pane", "beside me", "here" (no window number) → current pane (no `--target` needed)
- "this window", "in this window" (no number) → current pane (no `--target` needed)
- "window N", "this window (N)", "in tmux window (N)", "in window N" → target window N
  - If N is the caller's current window → no `--target` needed
  - If N is a different window → use `--target <session>:N.1` (first pane in that window)
- "pane N.M", explicit `session:window.pane` → use `--target` with exact address
- Chaining from a previous spawn's output → use `--target %N` (the pane_id from `TARGET=...`)
- Parenthetical numbers like `(2)` are **identifiers**, the user naming which window they mean. They are NOT requests to create a new window.

### 4. Combine into script args

| Topology | Anchor | Script call |
|----------|--------|-------------|
| `split-h` | current pane | `scripts/spawn.sh split-h` |
| `split-h` | window N (same as current) | `scripts/spawn.sh split-h` |
| `split-h` | window N (different) | `scripts/spawn.sh split-h --target <session>:N.1` |
| `split-h` | exact pane or chained | `scripts/spawn.sh split-h --target <pane-addr or %N>` |
| `split-v` | (same patterns) | `scripts/spawn.sh split-v [--target ...]` |
| `new-window` | — | `scripts/spawn.sh new-window` |
| `new-session` | — | `scripts/spawn.sh new-session [--session <name>]` |

**Examples of correct parsing:**

| User says | Model | Topology | Anchor | Result |
|-----------|-------|----------|--------|--------|
| "spawn an agent beside me" | `ren` | `split-h` | current pane | `split-h` |
| "spawn codex in this window (2)" | `codex` | `split-h` | window 2 | `split-h --model codex` (if already in 2) |
| "put claude in window 3" | `claude` | `split-h` | window 3 | `split-h --target mac:3.1 --model claude` |
| "new window with an agent" | `ren` | `new-window` | — | `new-window` |
| "spawn an agent" (no locality) | `ren` | dynamic | current window | layout-aware (see below) |
| "start codex below" | `codex` | `split-v` | current pane | `split-v --model codex` |
| "spawn prometheus beside me" | `prometheus` | `split-h` | current pane | `split-h --model prometheus` |

**Working directory.** tmux inherits the cwd of the source pane on split/new-window, so skip this entirely unless the user explicitly mentions a different path or worktree. Rules:
- User mentions a specific path → cd to that path after creating the pane
- User mentions a worktree → ask for the worktree name only if not provided
- User says nothing about directory → **do nothing** (tmux handles it)

**Initial prompt.** Infer from the user's task description:
- User says "to fix the tests", "to work on X", "have it do Y" → that's the prompt
- User says nothing about a task → no prompt, just open the agent

**Only use AskUserQuestion for things you genuinely cannot infer.** If the user said "spawn an agent beside me", proceed directly with zero questions.

## Layout Orchestration

When topology is **dynamic** (no explicit layout cue), spawn agents in the current window using predefined recipes. The orchestrator stays leftmost. Pick the recipe matching the total number of agents requested, not the current count.

Columns must be created before stacking. tmux splits are per-pane, so splitting a pane vertically then splitting one of those horizontally only affects that cell, not the whole column.

**Equalize after stacking:** Repeated vertical splits produce uneven heights. After stacking N agents in a column, resize all but the last pane to `window_height / N`. The last pane absorbs the remainder from border lines.

**Recipe 1 (1 agent):** `split-h` from self. Self keeps 50%.

**Recipe 2 (2 agents):** `split-h` from self → A1. `split-v --target A1` → A2. Self keeps 50%.

**Recipe 3 (3 agents):** `split-h` from self → A1. `split-v --target A1` → A2. `split-v --target A2` → A3. Equalize column. Self keeps 50%.

**Recipe 4-6 (4-6 agents):** Two full-height columns, then stack within each.
1. `split-h` from self → COL1
2. `split-h --target COL1` → COL2 (pushes COL1 to middle)
3. `tmux resize-pane -t $TMUX_PANE -x 33%`
4. Equalize column widths: `COL_W = (window_width - self_width) / 2`, resize COL1 to COL_W
5. Stack agents vertically in each column (left column fills first)
6. Equalize each column's heights independently

Distribution: 4 agents = 2+2, 5 agents = 3+2, 6 agents = 3+3.

**7+ agents:** Window is full. Ask the user: "6 agents fills this window. Want the next ones in a new window or a new session?"

## Step 2: Spawn via helper script

Run the `scripts/spawn.sh` script in a **single Bash call**. The script handles everything: tmux validation, pane ID detection, directory resolution (zoxide-backed), agent launch, and readiness polling.

```bash
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh <target-type> [--dir <name-or-path>] [--session <name>] [--prompt <text>] [--target <pane>] [--model <name>]
```

**Target types:** `split-h`, `split-v`, `new-window`, `new-session`

**Flags:**
- `--model <name>`: which agent to launch. `ren` (default), `prometheus`, `claude`, or `codex`
- `--dir <name-or-path>`: working directory (resolved via zoxide cascade)
- `--session <name>`: session name (for `new-session` only)
- `--prompt <text>`: initial prompt to send after the agent starts
- `--no-watch`: skip auto-registering a daemon watch on the spawned pane. Use when the spawner is retiring (e.g., handoff) and should not receive notifications.
- `--target <pane>`: for `split-h`/`split-v`, split this pane instead of self. Use pane_id (`%N`, e.g., `%5`) or `session:window.pane` (e.g., `mac:5.1`). **Critical for multi-agent spawns.** Without this, splits always happen in the caller's window. When chaining spawns, always use the pane_id from the previous spawn's `TARGET=` output.

**Examples:**
```bash
# Spawn ren beside current pane (default model)
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h

# Spawn codex in a specific directory with a task
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh new-window --model codex --dir scratchpad --prompt "fix the failing tests"

# Spawn claude in a new session
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh new-session --model claude --session agent-1 --prompt "run the test suite"

# Split a REMOTE pane (not self), using TARGET from a previous spawn
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h --target %5 --dir other-project --prompt "run linter"
```

**Multi-agent pattern** (2+ agents in a new window):

When spawning multiple agents side-by-side in a new window, you MUST use `--target` on the second spawn. Otherwise the split happens in YOUR window, not the new one.

```bash
# Step 1: Create new window with first agent → returns TARGET=%5
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh new-window --dir project-a --prompt "task A"

# Step 2: Split THAT pane with a codex agent → returns TARGET=%7
~/.steez/repo/skills/spawn-agent/scripts/spawn.sh split-h --target %5 --model codex --dir project-b --prompt "task B"
```

Parse the `TARGET=...` pane_id from step 1's output and pass it as `--target` in step 2. Pane IDs (`%N`) are stable, so they stay valid even if other panes are killed or moved.

**Reading the output:**

The script outputs structured key=value lines:
- `RESOLVED=/full/path METHOD=zoxide`: directory was resolved (method: literal, local, zoxide, or find)
- `SELF=%0 TARGET=%5`: stable pane IDs (never shift when panes are killed or moved)
- `MODEL=ren`: which agent was launched
- `PROMPT_SENT`: prompt was passed as a CLI argument at launch
- `WORKING`: agent launched and is actively processing the prompt
- `IDLE`: agent launched and is waiting for input (no prompt was sent, or it finished fast)
- `WATCHED=%5 SPAWNER=%0 BASELINE=working`: a background watch was registered so the spawner pane gets a notification when the agent finishes the initial prompt (only emitted when `--prompt` was passed)

**Error handling:**

- `ERROR: ...` + exit 1. Something failed (not in tmux, split failed, directory not found, unknown model). No orphan panes are created if directory resolution fails.
- `AMBIGUOUS=N` + `CANDIDATE=...` lines + exit 2. Multiple directory matches. Present the candidates to the user and re-run with the full path via `--dir /full/path/here`.
- No `WORKING` or `IDLE` after 15 seconds. Agent failed to start or is stuck. Check the target pane manually with `agent-state`.

**Directory resolution** uses a tiered cascade:
1. Literal paths (`/foo`, `~/foo`, `./foo`) → used directly
2. `$PWD/$name` child check → one stat call, catches "this project's tests/"
3. Zoxide query → frecency-ranked, handles partial matches ("scratch" → "scratchpad")
4. `find $HOME -maxdepth 4` exact name → depth-ranked, picks shallowest
5. `find $HOME -maxdepth 4` glob → never auto-resolves, always returns candidates

## Step 3: Report

After spawning, report:
- The model launched (ren, prometheus, claude, or codex)
- The tmux pane_id (e.g., `%5`)
- The working directory
- Whether an initial prompt was sent
- How to check on it: `~/.steez/bin/agent-state <pane_id> --detail`
- How to switch to it: `tmux select-window -t <target>` or `tmux switch-client -t <target>`

The `agent-state` command returns structured JSON with the agent's current state (idle, working, blocked:question, blocked:permission). For a visual overview of all agents across windows, use `~/.steez/bin/agent-state --layout`.

In the report, mention that `/loop` is available if they want periodic monitoring of the spawned agent. Don't use AskUserQuestion. Just include it as a one-liner like "Let me know if you want to set up a /loop to monitor it."

## Post-Spawn Operations

Once an agent is running in a pane, you interact with it through three helper scripts: `agent-send` to push input, `agent-state` to check what it is doing, and `agent-history` to read what it produced. Use these instead of raw tmux primitives. The scripts encapsulate the recipes; this section teaches when and why to reach for each one.

### Sending Input to a Running Agent

Use `~/.steez/bin/agent-send <pane> "message"` to deliver a message to a running agent.

```bash
~/.steez/bin/agent-send %5 "what's blocking the test suite?"
```

The script wraps the chat-pane footgun (Enter must arrive as a separate keystroke after a brief pause, otherwise the message sits in the composer unsubmitted), so callers do not need to know the underlying tmux primitives. It also uses tmux paste-buffers for verbatim byte delivery, so backticks, dollar signs, and quotes survive unmangled.

This is pure fire-and-forget. The script returns as soon as the message is submitted. It does not wait, does not poll, does not read the response. If you want to know what the agent did, read separately on your own clock using the sections below.

The pane argument accepts a pane id (`%N`, preferred) or `session:window.pane`. The pane must be a recognized AI agent (claude or codex); otherwise the script exits with code 2.

**Auto-watch on delivery.** Every successful `agent-send` call also registers a background watch via `agent-watch add` with `baseline=working`. When the watched pane finishes the turn — idle, blocked on a question, blocked on a permission prompt — a notification is delivered back into your pane by the `agent-watch-daemon` so the orchestrator learns about the transition without polling.

You do not need to call `agent-watch` yourself for messages sent via `agent-send`. You also do not need to call it for the initial prompt passed to `scripts/spawn.sh --prompt` — that is wired into the script directly and emits a `WATCHED=...` line on success. The two entry points exist because they cover different delivery paths: `spawn.sh --prompt` launches the agent with the prompt as a CLI argument (bypassing `agent-send`), while `agent-send` is used for every subsequent message.

**Do not** call `agent-watch add` from code that also calls `agent-send` — that would double-register and fire two notifications. The auto-registration inside `agent-send` is the single source of truth for message-driven watches.

### Waiting For An Agent To Finish

`pane_current_command` does NOT work for agent panes. The process name stays `claude` or `node` whether the agent is thinking, blocked, or idle. Use `~/.steez/bin/agent-state <pane>` instead, which parses agent-specific signals (title prefixes, prompt patterns) to distinguish the real states.

State enum:

- `working` ... agent is thinking, streaming, or executing tools
- `idle` ... turn complete, ready for input
- `blocked:question` ... waiting on a user-facing question
- `blocked:permission` ... waiting on permission approval
- `blocked:unknown` ... blocked on an unrecognized prompt type (fallback)

The canonical (and only) wait pattern is a polling loop on `agent-state`:

```bash
~/.steez/bin/agent-send %5 "run the test suite"
while true; do
  STATE=$(~/.steez/bin/agent-state %5 | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('state',''))")
  [[ "$STATE" == "working" ]] || break
  sleep 3
done
echo "Agent finished (state: $STATE)"
```

**Warning: this blocks the parent agent.** While the loop runs, the parent cannot do anything else. Use it sparingly. The default usage model is async, like email: send the message, walk away, read the response when convenient. Only block when the next step genuinely depends on the result.

If the loop exits with `STATE` set to `blocked:question` or `blocked:permission`, the agent will not finish on its own. Use `agent-history --blocked` to see what it needs before deciding how to respond.

### Reading Agent Output

`~/.steez/bin/agent-history` is the canonical reader for agent panes. It parses the structured JSONL transcript and returns turn-aware data, so you get the actual prompt and response rather than whatever happens to be on screen.

**Last prompt and response:**

```bash
~/.steez/bin/agent-history %5 --last
```

```json
{"agent":"claude","prompt":"fix the login bug","response":"I found the issue in auth.ts..."}
```

**What is blocking the agent:**

```bash
~/.steez/bin/agent-history %5 --blocked
```

Returns the pending tool call that has no result yet. For `AskUserQuestion`, the top-level `question` field extracts the first question text for convenience.

**Recent conversation history:**

```bash
~/.steez/bin/agent-history %5 --history 3
```

Returns the last N prompt/response pairs in chronological order.

**Scan every agent pane at once:**

```bash
~/.steez/bin/agent-history --all --last
```

Returns a JSON array with one entry per agent pane, each tagged with `pane` and `name` so you can tell sessions apart. Works with any mode (`--all --last`, `--all --blocked`, `--all --history N`). Useful for orchestrator panes that need to check what every child is currently working on, find agents blocked on a question, or pull the last few turns from all sessions in one call. Incompatible with a pane target or `--agent` override — per-pane detection is authoritative.

**Fallback: raw scrollback when the structured reader cannot resolve the transcript.**

`agent-history` needs the agent's `@session_id` pane variable and a readable transcript file. If the pane variable is missing, the transcript file has rotated or moved, or the pane is not recognized as a known agent, fall back to raw scrollback:

```bash
tmux capture-pane -t %5 -p -S -
```

The structured reader is preferred because it gives you turn-aware data instead of whatever happens to be visible. The raw capture always works. Reach for it when the structured reader returns nothing.

### Multi-Agent Overview

Scan all panes for running agents:

```bash
~/.steez/bin/agent-state --all
```

```
PANE  AGENT       STATE    NAME
%2    prometheus  working  steez
%5    codex       idle     api-server
```

The default output is a column-aligned table so you can pipe directly into
`grep`, `awk`, or `wc` without a JSON parser. Add `--json` if you need the
raw array, or `--detail`/`--read` to include session metadata or visible
pane content (both force JSON since the extra fields don't fit in a table).

Only agent panes are included. Non-agent panes are filtered out.

Useful flag combinations:

- `--detail` adds session id, working directory, and transcript path. Useful for routing decisions or for passing a transcript path to `agent-history`.
- `--read` adds visible pane content (equivalent to `capture-pane -p -S -`). Combine with `--detail` for content and metadata in one call.
- `--layout` renders a proportionally-scaled ASCII box diagram of each window's pane layout with state colors. Only windows containing at least one agent are shown.
