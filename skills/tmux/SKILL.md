---
name: tmux
preamble-tier: 1
description: "REQUIRED when running any tmux command — contains critical safety rules and correct syntax that prevent common mistakes like sending commands to the wrong pane. Use this skill whenever the user mentions tmux, panes, windows, sessions, or asks to read/send to another pane. Also trigger when the user says things like 'read the other pane', 'what's running in my other window', 'send this to the other pane', 'split the window', 'check that pane', or any variation of interacting with tmux. Even if you think you know tmux, this skill contains project-specific guardrails you must follow. EXCEPTION: Do NOT use this skill when the user wants to spawn, launch, or start an AI coding agent or instance — use the spawn-agent skill instead, even if tmux panes or windows are mentioned."
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
_PROACTIVE=$(~/.steez/bin/config get proactive 2>/dev/null || { echo "[steez] WARNING: config failed, defaulting proactive=true" >&2; echo "true"; })
echo "PROACTIVE: $_PROACTIVE"
# Repo mode (hardcoded — always solo)
REPO_MODE=solo
echo "REPO_MODE: $REPO_MODE"
# Analytics tracked via PostToolUse hook (skill-analytics.sh) — no in-skill telemetry needed.
```

If `PROACTIVE` is `"false"`, do not proactively suggest steez skills AND do not
auto-invoke skills based on conversation context. Only run skills the user explicitly
types (e.g., /tmux, /ship). If you would have auto-invoked a skill, instead briefly say:
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

# Tmux Operations

Use tmux from the command line to inspect panes, send input, and capture output. Prefer explicit pane targets and verify the target before sending text.

## Rules

1. Identify the pane running your shell by matching `$TMUX_PANE` against `tmux list-panes -a -F ...`. Do not use `tmux display-message -p` to identify yourself because it reports the focused pane, not necessarily the pane running your process.
2. Before `send-keys`, inspect `#{pane_current_command}` for the target pane. A shell such as `zsh` or `bash` accepts commands; a TUI such as `vim`, `node`, or `python` may treat the text as raw keystrokes.
3. For chat-like panes, use the delayed one-command submission pattern shown below. Do not use a single `send-keys` invocation that includes both the text and `Enter`.
4. Use `capture-pane -p` when reading output. Without `-p`, tmux writes to an internal paste buffer instead of stdout.
5. Prefer explicit pane targets for any operation that affects another pane or window. Use pane_id (`%N`) when the target was dynamically created. Use `session:window.pane` when targeting by position.
6. Never put literal `\n` sequences inside the `send-keys` text payload. tmux sends them as the characters `\` and `n`, not as real line breaks.
7. If the target pane is an interactive app or chat-like composer rather than a shell prompt, verify after every send that the text was submitted and is not still sitting in the input box.
8. After `split-window`, capture the new pane's `pane_id` (`%N`) for future targeting. Do not rely on `pane_index` as indices renumber when panes are added, removed, or moved.

## Target Format

tmux accepts two target formats:

- **Pane ID** (`%N`, e.g., `%0`, `%5`) — assigned at creation, never changes even when panes are moved or killed. **Preferred for dynamically created panes.**
- **Address** (`session:window.pane`, e.g., `work:1.2`) — positional. Pane indices shift when panes are added, removed, or moved. Use only for ad-hoc targeting by position.

Examples:

```bash
tmux capture-pane -t %5 -p         # by pane_id (stable)
tmux capture-pane -t work:1.2 -p   # by address (positional)
```

## Discovering Layout

Start by finding your own pane_id:

```bash
SELF="$TMUX_PANE"  # e.g., %0 — stable, never changes
echo "I am running in: $SELF"
```

Then inspect the tmux layout:

```bash
tmux list-sessions
tmux list-windows -a
tmux list-panes -a -F "#{pane_id}  #{session_name}:#{window_index}.#{pane_index}  #{pane_current_command}  #{pane_width}x#{pane_height}"
```

**Before any `send-keys`, verify your target is correct:**

1. Your own pane_id is `$TMUX_PANE`
2. Confirm the target pane_id differs from your own
3. Check `#{pane_current_command}` on the target to verify it is the pane you expect

Do not skip this. Sending text to your own pane or the wrong agent session is the most common tmux failure mode.

## Sending Input

Check what is running in the target pane first:

```bash
tmux display-message -t work:1.2 -p '#{pane_current_command}'
```

Safe shells usually report `zsh` or `bash`. Interactive programs or chat-like agent UIs require extra caution.

When the target pane is a chat/composer UI, use this as the default submission pattern:

```bash
tmux send-keys -t work:1.2 "your message here" \; run-shell -d 0.3 'tmux send-keys -t work:1.2 Enter'
sleep 1
tmux capture-pane -t work:1.2 -p | tail -10
```

Assume these failure modes unless you verify otherwise:

- literal `\n` is inserted as backslash + n
- sending text plus `Enter` in one `send-keys` invocation leaves the prompt sitting in the input box
- submission is not complete until a second tmux action sends `Enter`

Do not rely on combining the command text and `Enter` in a single `send-keys` call. During testing, `Enter`, `C-m`, `KPEnter`, and `C-j` in the same `send-keys` invocation all left the prompt in the composer.

If the prompt is still visible in the composer after the delayed command, send `Enter` again and re-check.

For multiline text, send actual newlines rather than escaped `\n` sequences. For chat-like panes, keep using the delayed one-command pattern:

```bash
tmux send-keys -t work:1.2 "$(cat <<'EOF'
first line
second line
EOF
)" \; run-shell -d 0.3 'tmux send-keys -t work:1.2 Enter'
```

This does **not** work:

```bash
tmux send-keys -t work:1.2 "first line\nsecond line"
```

For chat-like panes, prefer a short message or a file reference over a large multiline paste unless you have already verified that the target UI handles pasted newlines correctly.

## Reading Scrollback

```bash
tmux capture-pane -t work:1.2 -p -S -200
tmux capture-pane -t work:1.2 -p -S -200 | tail -30
```

For long-running commands or evaluations, increase `-S` and `tail` values as needed.

## Waiting For A Command To Finish

tmux has no built-in wait. Poll the pane command until it returns to the shell:

```bash
while [ "$(tmux display-message -t work:1.2 -p '#{pane_current_command}')" != "zsh" ]; do
  sleep 2
done
echo "Command finished"
```

Adjust the shell name if the pane uses `bash` or another shell.

For panes running AI agents (Claude Code, Codex), this pattern does not work because the process name stays `claude` or `node` regardless of whether the agent is working or idle. Use `agent-state` instead. See "Agent Panes" below.

## Creating Panes And Windows

```bash
tmux split-window -t work:1 -v
tmux split-window -t work:1 -h
tmux new-window -t work
tmux new-window -t work -n "servers"
```

After splitting, the new pane becomes active. Capture its `pane_id` for stable targeting:

```bash
# Snapshot before split
BEFORE=$(tmux list-panes -t work:1 -F "#{pane_id}" | sort)
tmux split-window -t work:1 -v
# The new pane_id is the one that wasn't there before
NEW_PANE=$(comm -13 <(echo "$BEFORE") <(tmux list-panes -t work:1 -F "#{pane_id}" | sort))
echo "New pane: $NEW_PANE"  # e.g., %7
```

## Resizing Panes

```bash
tmux resize-pane -t work:1.2 -D 10
tmux resize-pane -t work:1.2 -R 20
```

Available directions: `-U`, `-D`, `-L`, `-R`.

## Common Patterns

Run a command in a new pane and capture its output later:

```bash
BEFORE=$(tmux list-panes -t work:1 -F "#{pane_id}" | sort)
tmux split-window -t work:1 -v
NEW_PANE=$(comm -13 <(echo "$BEFORE") <(tmux list-panes -t work:1 -F "#{pane_id}" | sort))
tmux send-keys -t "$NEW_PANE" "pytest tests/" \; run-shell -d 0.3 "tmux send-keys -t $NEW_PANE Enter"
tmux capture-pane -t "$NEW_PANE" -p -S -200
```

Stop a process, then start a replacement command:

```bash
tmux send-keys -t work:1.2 C-c
sleep 1
tmux send-keys -t work:1.2 "npm run dev" \; run-shell -d 0.3 'tmux send-keys -t work:1.2 Enter'
```

## Agent Panes

When a pane runs an AI agent (Claude Code, Codex CLI), use `agent-state` and `agent-history` instead of raw tmux primitives. These tools parse agent-specific signals (title prefixes, prompt patterns, JSONL transcripts) that `capture-pane` and `pane_current_command` cannot interpret meaningfully.

Non-agent panes (shells, servers, test runners) still use the raw tmux patterns above.

### Checking Agent State

```bash
~/.steez/bin/agent-state %5
```

Returns JSON with the agent type and current state:

```json
{"pane":"%5","agent":"claude","state":"working","name":"steez"}
```

Possible states:

- `working` ... agent is thinking, streaming, or executing tools
- `idle` ... turn complete, ready for the next task
- `blocked:question` ... waiting for the user to answer a question
- `blocked:permission` ... waiting for permission approval
- `blocked:unknown` ... blocked on an unrecognized prompt type (fallback)

### Waiting For An Agent To Finish

Poll `agent-state` instead of `pane_current_command`. This distinguishes working from blocked from idle, so you know whether the agent needs input or is still running.

```bash
while true; do
  STATE=$(~/.steez/bin/agent-state %5 | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('state',''))")
  [[ "$STATE" == "working" ]] || break
  sleep 3
done
echo "Agent finished (state: $STATE)"
```

If the state is `blocked:question` or `blocked:permission`, the agent will not finish on its own. Use `agent-history --blocked` to see what it needs before deciding how to respond.

### Reading Agent Conversation

Use `agent-history` to read structured conversation data from the agent's JSONL transcript. It accepts a pane ID or a direct path to a transcript file.

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

```json
{"agent":"claude","tool":"AskUserQuestion","input":{"questions":[{"question":"Should I use OAuth or API keys?"}]},"question":"Should I use OAuth or API keys?"}
```

Returns the pending tool call that has no result yet. For `AskUserQuestion`, the top-level `question` field extracts the first question text for convenience.

**Recent conversation history:**

```bash
~/.steez/bin/agent-history %5 --history 3
```

```json
{"agent":"claude","pairs":[{"prompt":"...","response":"..."},{"prompt":"...","response":"..."},{"prompt":"...","response":"..."}]}
```

Returns the last N prompt/response pairs in chronological order.

### Multi-Agent Overview

Scan all panes for running agents:

```bash
~/.steez/bin/agent-state --all
```

```json
[
  {"pane":"%2","agent":"claude","state":"working","name":"steez"},
  {"pane":"%5","agent":"codex","state":"idle","name":"api-server"}
]
```

Only agent panes are included. Non-agent panes are filtered out.

**Add `--detail` for session metadata** (session ID, working directory, transcript path). Useful for routing decisions or passing a transcript path to `agent-history`:

```bash
~/.steez/bin/agent-state %5 --detail
```

```json
{"pane":"%5","agent":"claude","state":"idle","name":"steez","detail":{"session_id":"abc123","cwd":"/Users/steez/project","transcript_path":"/Users/steez/.claude/projects/-Users-steez-project/abc123.jsonl"}}
```

**Add `--read` to include visible pane content** (equivalent to `capture-pane -p -S -`):

```bash
~/.steez/bin/agent-state %5 --read
```

The output includes a `"content"` field with the full visible pane text. Combine with `--detail` for both content and metadata in one call.

**Add `--layout` for a visual box diagram** showing pane splits and agent states:

```bash
~/.steez/bin/agent-state --layout
```

Renders proportionally-scaled ASCII art of each window's pane layout with box-drawing characters. Merged cells (panes spanning multiple splits) render correctly. Only windows containing at least one agent are shown; non-agent panes appear within those windows for spatial context. ANSI colors indicate state (green for working, yellow for blocked, dim for idle) when outputting to a terminal.

