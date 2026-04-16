# agent-history

**Path:** `shared/steez/bin/agent-history`

Structured transcript parser for AI agent panes. Reads JSONL transcripts from Claude Code or Codex CLI and extracts conversation data in three modes.

## Interface

```
agent-history [<pane|path>] <mode>
agent-history --all <mode>
```

### Input Resolution

| Input | Behavior |
|-------|----------|
| `%42` | Pane ID — resolves transcript via `agent-state --detail` |
| `/path/to.jsonl` | Direct transcript path (format inferred from path) |
| (none) | Uses `$TMUX_PANE` if set |

### Modes

| Mode | Description |
|------|-------------|
| `--last` | Last human prompt + assistant response |
| `--blocked` | Pending tool_use awaiting approval or answer |
| `--history N` | Last N human/assistant pairs (chronological) |

### Options

| Option | Description |
|--------|-------------|
| `--all` | Scan every tmux agent pane, return JSON array |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (JSON output) |
| 1 | Error (bad args, no target, agent-state failure) |

## Output Format

### `--last`

```json
{
  "agent": "ren",
  "prompt": "the last human message",
  "response": "the last assistant response"
}
```

### `--history N`

```json
{
  "agent": "ren",
  "pairs": [
    {"prompt": "first message", "response": "first response"},
    {"prompt": "second message", "response": "second response"}
  ]
}
```

### `--blocked`

```json
{
  "agent": "ren",
  "tool": "AskUserQuestion",
  "input": {"questions": [{"question": "Which approach?"}]},
  "question": "Which approach?"
}
```

The `question` field is a convenience extraction for `AskUserQuestion` (Claude) or `request_user_input` (Codex). For other tools, `tool` and `input` are provided.

### `--all`

JSON array of per-pane results, each tagged with `pane` and `name`:

```json
[
  {"pane": "%5", "name": "JWT migration", "agent": "ren", "prompt": "...", "response": "..."},
  {"pane": "%7", "name": "Test runner", "agent": "codex", "prompt": "...", "response": "..."}
]
```

Errors per-pane appear as `{"pane": "%5", "error": "no output"}`.

## Transcript Format Detection

Dispatch is keyed on transcript path, not agent name:
- Path contains `/.claude/` -> Claude format
- Path contains `/.codex/` -> Codex format

This is O(2) formats rather than O(N) agent names (ren, ren-codex, etc. share the same JSONL schema as their base).

## Claude Transcript Parsing

### Tail strategy

Reads the last 500 lines of the transcript. If no human prompt is found in that window, expands to 2000 lines.

### Prompt extraction

JSONL entries where `type=user`, `message.content` is a string (not array), and neither `isMeta` nor `isSidechain` is true.

### Response extraction

Assistant messages are grouped by `message.id` (the delta pattern — multiple JSONL lines share the same message ID with different content blocks). Text blocks are joined with `\n\n`.

### Blocked detection

Single backward pass through the transcript:
1. Collect resolved `tool_use_id`s from `tool_result` blocks in `user` messages encountered during the backward walk.
2. Stop at the first `user` message with string content (marks the boundary of the current turn).
3. Find the last `tool_use` block in an `assistant` message whose ID is not in the resolved set.
- `AskUserQuestion` -> extract `questions[0].question`
- Other tools -> return `tool` and `input`

### History pairing

Walks JSONL in order, tracking prompt/response alternation. Each `user` message starts a new pair; each `assistant` message (first occurrence of each `message.id`) closes it.

## Codex Transcript Parsing

### Prompt extraction

`event_msg` entries with `payload.type=user_message` -> `payload.message`.

### Response extraction (`--last`)

Backward scan for `event_msg` with `payload.type=task_complete` -> `payload.last_agent_message`.

### Blocked detection

Forward pass: collect `call_id`s from `function_call_output` response items.
Backward pass: find the last `function_call` or `custom_tool_call` whose `call_id` is not resolved.
- `request_user_input` -> extract `questions[0].question` from parsed arguments
- `custom_tool_call` -> return `name` and `input`
- Other function calls -> parse `arguments` (JSON string) and return

### History pairing

Each `user_message` starts a turn; each `task_complete` ends it.

## `--all` Mode

1. Calls `agent-state --all --json` to list all agent panes (excludes `shell`/`unknown`).
2. Self-invokes per pane with the requested mode.
3. Tags each result with `pane` and `name`.
4. Returns a JSON array.

## Dependencies

- `agent-state` (pane -> transcript resolution via `--detail`, `--all` pane listing)
- `python3` (all transcript parsing)
- `tmux` (implicit via agent-state)

## Integration Points

- **agent-watch-daemon** calls `agent-history <pane> --blocked` to extract detail for blocked notifications.
- **spawn-agent SKILL.md** documents all three modes as post-spawn output reading tools.

## Behavioral Contracts

1. Errors from pane/transcript resolution are returned as JSON: `{"error": "description"}` to stdout. Argument parsing errors (missing mode, bad flags, `--all` with target) go to stderr as plain text and exit 1.
2. `--all` cannot be combined with a target argument.
3. Format dispatch is path-based, not agent-name-based. A `ren` agent with a `.claude/` transcript uses the Claude parser.
4. `--blocked` for Claude is transcript-driven. Pending `tool_use` blocks are read from the JSONL transcript with no sidecar dependency.
5. Tail strategy starts narrow (500 lines) and expands only if needed (2000 lines).
6. `isMeta` and `isSidechain` messages are excluded from prompt extraction.

## Error Handling

- No target and no `$TMUX_PANE`: error to stderr, exit 1.
- Target is not a recognized agent: JSON error output, exit 1.
- Transcript not found: JSON error output.
- Parse failures: individual entries are skipped (`try/except`), never crash the parser.
- `--all` per-pane failures: captured as `{"error": "..."}` in the array.
