# agent-state

**Path:** `shared/steez/bin/agent-state`

Detects the type and current state of AI coding agents running in tmux panes. The primary state oracle for the entire agent subsystem — every other agent tool depends on it.

## Interface

```
agent-state <pane> [--read] [--detail] [--explain]
agent-state --all [--read] [--detail] [--json]
agent-state --layout
```

### Arguments

| Arg | Description |
|-----|-------------|
| `<pane>` | Pane identifier (`%N` preferred, also `session:window.pane`) |

### Flags

| Flag | Description |
|------|-------------|
| `--all` | Scan all tmux panes, emit table (default) or JSON array |
| `--json` | With `--all`: JSON array output instead of table |
| `--layout` | Visual box diagram showing pane splits and agent states |
| `--read` | Include full scrollback content in output (forces JSON with `--all`) |
| `--detail` | Include session metadata: `session_id`, `cwd`, `transcript_path` (forces JSON with `--all`) |
| `--explain` | Return `{pane, agent, state, summary, detail?, source}` for one pane |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Pane not found or not a recognized AI agent |

## Output Format

### Single pane (default)

JSON object:

```json
{
  "pane": "%5",
  "agent": "ren",
  "state": "working",
  "name": "JWT migration"
}
```

With `--detail`, adds a `detail` object:

```json
{
  "detail": {
    "session_id": "abc123",
    "cwd": "/Users/steve/project",
    "transcript_path": "/Users/steve/.claude/projects/..."
  }
}
```

With `--read`, adds `content` (full scrollback text).

With `--explain`, single-pane mode returns:

```json
{
  "pane": "%5",
  "agent": "claude",
  "state": "blocked:permission",
  "summary": "waiting for permission approval",
  "detail": "Bash: {\"command\":\"git push\"}",
  "source": "eventsd"
}
```

`--explain` is the post-attention inspection surface. It prefers fresh
attention records written by `agent-eventsd`, then the runtime pane state
published by hooks, then falls back to transcript artifacts, then to the
existing screen/title/default heuristics. Fresh attention records are keyed
by pane and accepted only when their session/transcript identity still
matches the pane and the transcript cursor has not advanced past the
recorded attention point. Runtime pane state has no per-tool detail —
attention records remain the source for that.

Post-attention flow is narrow on purpose:

1. Receive `[agent-watch] <pane> (<label>) attention`.
2. Run `agent-state <pane> --explain`.
3. Use `agent-history` only for transcript context, not to branch between blocked parsers.

Claude fast-path hooks are SessionStart, Stop, PermissionRequest, and PreToolUse(AskUserQuestion).
SessionStart writes pane metadata. `steez-permission-state.sh` handles Stop, PermissionRequest, and PreToolUse(AskUserQuestion).

### `--all` table (default)

Tab-aligned columns: `PANE`, `AGENT`, `STATE`, `NAME`. Piped through `column -t`.

### `--all --json`

JSON array of the single-pane objects above.

### `--layout`

Unicode box-drawing diagram with pane positions, agents, and color-coded states. Green = working, yellow = blocked, dim = idle. Filters to windows containing at least one agent pane.

## Agent Detection

`detect_agent` identifies which agent runs in a pane by inspecting the process tree rooted at the pane's shell PID:

1. Read the pane PID's command from a single `ps -eo pid,ppid,command` snapshot (captured once per invocation).
2. Match the base command name: `claude` or `codex`.
3. For `node` processes, check if the command line contains `codex` or `claude`.
4. If the direct process is unrecognized, check the first child process with the same rules.
5. Distinguish `ren` / `ren-codex` from plain `claude` / `codex` by checking `REN_SESSION=1` in the process environment (`ps -E`).

Recognized agents: `ren`, `ren-codex`, `claude`, `codex`. Anything else returns `unknown` and is excluded from output.

## State Detection

`detect_state` determines the agent's current state using a layered strategy, from highest to lowest confidence:

### Layer 0: Runtime pane state

`read_runtime_state` reads the worker pane's tmux options before any other layer runs. Hooks publish canonical state on every lifecycle event (Claude `permission-state.sh`, Codex `codex-stop.sh`); see `specs/agent-events.md` §Runtime pane state producers for the full event → state table.

- `@agent_runtime_state` — one of `working`, `blocked:question`, `blocked:permission`, `idle`. When set and fresh, returned as the pane state directly. No transcript / screen scan runs.
- `@agent_runtime_expires_ms` — optional wall-clock epoch (ms). Set only for transient `working` leases written on `UserPromptSubmit`. Sticky states (`blocked:*`, `idle`) explicitly unset this option so previous-turn lease data cannot leak forward.

Freshness:

- Sticky states (no `@agent_runtime_expires_ms`) are always fresh — they persist until the next hook overwrites them.
- Working leases are fresh while `now_ms <= @agent_runtime_expires_ms`. Past expiry, the layer is treated as missing and the artifact / screen / heuristic layers run.
- Hook failures (no tmux on PATH, server down, unknown pane) leave the option absent, which is also "missing" and falls through.

This layer is the primary live-status oracle. Sticky blocked states win while present (the hook is the canonical signal even if a transcript tool_use looks "working"). The transient working lease bridges the gap between the user pressing Enter and the first transcript write — without it, callers like SketchyBar see stale `idle` for the lease window.

### Layer 1: Transcript parsing

`artifact_state` reads the JSONL transcript and walks it backward:

**Claude/Ren:** Forward pass collects resolved `tool_use_id`s from `tool_result` blocks. Backward pass checks:
- `system` with subtype `turn_duration` or `stop_hook_summary` -> `idle`
- `user` (non-meta, non-sidechain) -> `working`
- `assistant` with `stop_reason: end_turn` -> `idle`
- Unresolved `tool_use` named `AskUserQuestion` -> `blocked:question`
- Any other unresolved `tool_use` -> `working`

**Codex/Ren-Codex:** Forward pass collects resolved `call_id`s from `function_call_output` entries. Backward pass checks:
- `event_msg` with `task_complete` -> `idle`
- `event_msg` with `task_started` or `user_message` -> `working`
- Unresolved `function_call` named `request_user_input` -> `blocked:question`
- Unresolved `function_call` with `sandbox_permissions: require_escalated` -> `blocked:permission`
- `custom_tool_call` + TUI log confirmation -> `blocked:permission`

Codex emits `task_started` at the start of every turn and `user_message` a
few milliseconds later. Recognising both as working prevents the brief
buffering window — where only `task_started` has been flushed — from
classifying a live turn as idle and lying to live-status consumers.

Codex has an additional `codex_waiting_for_approval` heuristic that tail-reads `~/.codex/log/codex-tui.log` looking for `ToolCall:` entries for the same `thread_id` followed by a `client: close` event (close is the most recent entry), with a 3-second age gate.

### Layer 2: Screen scraping

When the transcript is unavailable or returns `working`, the visible pane content (last 10 lines) is checked for UI-specific patterns:

- `"Tab to amend"` / `"Do you want to proceed?"` / `"Do you want to overwrite"` -> `blocked:permission`
- `"Enter to select"` + `"Chat about this"` -> `blocked:question`
- `"Esc to cancel"` / `"esc to cancel"` -> `blocked:unknown`

Screen-detected blocked states override transcript-reported `working` when the UI is ahead of the transcript. This refinement only fires when no runtime pane state was published — Layer 0 already handled the case when the hook is wired up.

The Codex-specific spinner-over-idle override has been removed. The runtime-pane-state layer (`UserPromptSubmit` working lease, `Stop` idle write) is now the primary live oracle for Codex panes. Codex panes without the hook installed report whatever the transcript says.

### Layer 3: Title character heuristic

The tmux pane title's first character is checked: Unicode Braille range (U+2800-U+28FF) indicates a spinner -> `working`.

### Layer 4: Codex prompt detection

For Codex agents, a leading `›` (U+203A, single right-pointing angle quotation mark) character in the pane content indicates the idle prompt -> `idle`. Otherwise -> `working`.

### Layer 5: Default

Claude/Ren default to `idle`. Codex/Ren-Codex default to `working`.

## Pane Name

The `name` field is extracted from the tmux pane title. If the title contains a space, everything after the first space is the name (the first character/word is a spinner or prefix). If no space, the full title is used. This is the agent's auto-generated turn summary.

## Transcript Discovery

`find_transcript` locates the JSONL transcript for a pane through a priority chain:

1. **Pane variable:** `tmux show-options -pv @transcript_path` (set by SessionStart hook).
2. **Claude filesystem match (agent type `claude` only, not `ren`):** `~/.claude/projects/{cwd-key}/` — most recently modified `.jsonl`. `ren` agents rely on the pane variable set by the SessionStart hook; the filesystem fallback does not fire for them.
3. **Codex process handle:** Walk `shell -> node -> codex` in the process tree, then `lsof -p` to find the open `.jsonl` write handle.

## Dependencies

- `tmux` (pane inspection, capture, title, pid)
- `ps` (process tree, environment)
- `python3` (transcript parsing, layout rendering)
- `jq` (JSON output assembly)
- `lsof` (Codex transcript discovery)
- `column` (table formatting)

## Integration Points

- **agent-deliver** calls `agent-state <pane>` to validate the target is a recognized agent before delivery.
- **agent-send** inherits agent-deliver's validation.
- **agent-history** calls `agent-state <pane> --detail` to resolve transcript paths.
- **agent-watch** calls `agent-state <pane>` to infer the label for new watch registrations.
- **agent-eventsd** expects `agent-state <pane> --explain` to answer "what happened?" after an attention ping.
- **spawn.sh** uses `agent-state` for post-boot state checks.
- **spawn-agent SKILL.md** teaches spawners to follow an attention ping with `agent-state <pane> --explain`.

## Behavioral Contracts

1. A single `ps` snapshot is taken per invocation and reused for all panes (`_init` / `_PS`). No TOCTOU between agent detection and state detection within a single call.
2. `--all` excludes `unknown` agents — only recognized AI agents appear.
3. `--layout` filters to windows containing at least one agent pane.
4. A fresh runtime pane state (Layer 0) is the primary live oracle — when present it wins over every other layer. Sticky `blocked:*` / `idle` states have no expiry and persist until the next hook fires; working leases honor `@agent_runtime_expires_ms` and are ignored past expiry.
5. Screen-detected blocked states override transcript-reported `working` only on the fallback path (no runtime pane state). They never override transcript-reported terminal states (`idle`, `blocked:*`).
6. Single-pane mode exits non-zero if the pane is not a recognized agent. `--all` mode silently skips non-agent panes.
7. `--explain` returns the pane's current best-known reason with a concise `summary`, optional `detail`, and a `source` of `eventsd`, `runtime`, `artifacts`, `screen`, `title`, or `default`. Eventsd attention records still beat runtime when fresh because they carry per-tool detail.

## Error Handling

- Missing pane: `error: pane '<pane>' not found` to stderr, exit 1.
- Non-agent pane: `error: pane '<pane>' is not a recognized AI agent` to stderr, exit 1.
- Transcript not found: state detection falls back to screen scraping and heuristics.
- Python parse failures: caught with `2>/dev/null`, falls back to next detection layer.
