# fake-agent-harness

**Status:** Proposed · test-only (not installed by the CLI, not on the primary path)

**Primary paths (proposed):**

- `shared/steez/test/fakes/bin/claude`
- `shared/steez/test/fakes/bin/codex`
- `shared/steez/test/fakes/bin/ren`
- `shared/steez/test/fakes/bin/ren-codex`

Zero-token test harness for the agent runtime. Tests prepend a test-only `bin/` dir to `$PATH` so `spawn.sh` launches these fakes in place of the real agent binaries. Every downstream component — `spawn.sh`, `agent-send`, `agent-deliver`, `agent-eventsd`, `agent-watch`, `agent-history`, `agent-state` — runs unmodified against the fake process. Tests exercise the real primary path without paying model tokens.

This spec is the contract the fakes must satisfy. Red integration tests (bead `steez-r65`) are derived from the scenarios listed below.

## Normative scope

Normative. Any new scenario (new blocked flavor, restart recovery variant, delivery-retry scenario, etc.) extends this spec first.

This spec does **not** define: test runner choice, specific assertion syntax, CI wiring, a full fixture catalog, or implementation language for the fakes.

## Goals

1. Drive the entire watch / delivery path with no model calls.
2. Keep the replaceable seam to exactly one process per agent.
3. Give tests deterministic cues for every state transition — no timing roulette inside the fake.
4. Preserve the pane and session metadata shape the real tools already rely on (spec: agent-state, agent-history).

## Non-goals

1. Reproducing Claude / Codex TUI pixel-for-pixel.
2. Emulating internal tool execution beyond what state detection and transcript parsing read.
3. Replacing any real script on the primary path.
4. Covering non-tmux terminals.

## Seam

The only replaced component is the agent process itself.

Tests **must**:

- Prepend a test-only `bin/` containing the four fakes to `$PATH`.
- Set `HOME` to a tmp dir so `~/.claude`, `~/.codex`, and `~/.steez` writes stay isolated.
- Set `STEEZ_STATE_DIR` to a tmp dir so `agent-eventsd` watch state stays isolated.

Tests **must not**:

- Wrap, replace, or stub `agent-send`, `agent-deliver`, `agent-eventsd` (service or clients), `agent-watch`, `agent-history`, `agent-state`, or `spawn.sh`.
- Call daemon internals (`watch_tick`, `watch_pending_timeout`, `watch_arm`, `watch_create_pending`, any `_eventsd_*` helper) directly. Cross-ref: agent-events — TDD relationship.
- Mutate `$STEEZ_STATE_DIR/eventsd/` from the test process.
- Inject synthetic events on the `agent-eventsd` transport.

Tests **may**:

- Drive state transitions through the fake's control fifo (below).
- Read files under `$STEEZ_STATE_DIR/eventsd/` for assertions only.
- Scrape the spawner pane with `tmux capture-pane` to assert delivery landed.

## Process identity

`agent-state` identifies agents by walking the pane PID's process tree with `ps -eo pid,ppid,command`. Each fake must present to `ps` such that the basename of the pane process matches one of the recognized agent names (spec: agent-state — Agent Detection).

| Fake | Process basename | Env |
|---|---|---|
| `claude` | `claude` | — |
| `codex` | `codex` | — |
| `ren` | `claude` | `REN_SESSION=1` |
| `ren-codex` | `codex` | `REN_SESSION=1` |

`ren` and `ren-codex` are thin wrappers that set `REN_SESSION=1` and exec the matching base fake with `argv[0]` set to the base agent name (e.g. via `exec -a claude`). Bash scripts whose parent interpreter shows up in `ps` as `bash` do not satisfy this contract.

Each fake must accept and silently ignore its documented permission-bypass flag:

- `claude` / `ren`: `--dangerously-skip-permissions`
- `codex` / `ren-codex`: `--dangerously-bypass-approvals-and-sandbox`

Unknown flags exit non-zero with an error on stderr — a test that passes unknown flags is a test bug.

## Boot contract

### Claude / Ren

On launch, before the fake reads any prompt bytes, it **must**:

1. Generate an opaque `session_id` (UUID-shaped string is fine).
2. Create a writable JSONL transcript. Recommended path: `$HOME/.claude/projects/fake/<session_id>.jsonl`.
3. Set tmux pane variables on its own pane:
   - `@session_id = <session_id>`
   - `@transcript_path = <absolute path to the transcript>`
4. Render a neutral prompt surface in the pane (see "Screen rendering").

Step 3 is what the real `SessionStart` hook does. The fake may either call the hook (`shared/steez/hooks/session-start.sh` with matching JSON on stdin) or set the pane vars directly. Either path is in contract.

`spawn.sh` completes boot wait when `@session_id` is set.

### Codex / Ren-Codex

The real Codex `SessionStart` hook fires on first message, not launch (upstream bug). `spawn.sh` instead polls the pane screen for `›`.

On launch, the fake **must**:

1. Render a line beginning with `›` (U+203A) on the pane.
2. Defer session-metadata setup until the first prompt arrives.

On the first prompt, the fake **must**:

1. Generate an opaque `session_id`.
2. Create a writable JSONL transcript. Recommended path: `$HOME/.codex/sessions/fake/rollout-<session_id>.jsonl`.
3. Set pane vars `@session_id` and `@transcript_path`.
4. Keep the transcript file open for write for the life of the fake, so `lsof -p <pid>` finds it (preserves the `agent-state` fallback-discovery path).

## Prompt reception

Fakes must read prompt bytes from their controlling tty — the real `agent-deliver` recipe pastes into the tmux buffer and then sends Enter. Each fake **must**:

1. Accept verbatim paste-buffer bytes. Backticks, `$vars`, quotes, and embedded newlines survive unmangled.
2. Treat each Enter keypress as exactly one prompt boundary.
3. On each prompt, append the prompt transcript entry (below) and transition visible state to `working` before yielding control to the control surface.

## Transcript schema

The fakes must emit the minimum JSONL shape `agent-state` and `agent-history` parse (spec: agent-state — State Detection, spec: agent-history). Extra fields are allowed; missing required fields are a contract violation. Each entry is a single line ending with `\n`, written atomically, and flushed before the fake returns control to its control surface.

### Claude / Ren

| Cue | Entry |
|---|---|
| Prompt arrives | `{"type":"user","message":{"content":"<text>"},"isMeta":false,"isSidechain":false}` |
| Working (pending tool) | `{"type":"assistant","message":{"id":"msg_<n>","content":[{"type":"tool_use","id":"<tid>","name":"<Name>","input":{...}}]}}` |
| Tool resolved | `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"<tid>","content":"ok"}]},"isMeta":false,"isSidechain":false}` |
| Idle | `{"type":"assistant","message":{"id":"msg_<n>","content":[{"type":"text","text":"<reply>"}],"stop_reason":"end_turn"}}` |
| `blocked:question` | Unresolved `tool_use` with `name:"AskUserQuestion"`, `input.questions=[{"question":"<text>"}]`. No matching `tool_result`. |
| `blocked:permission` | Write sidecar `$HOME/.steez/agent-state/claude/<session_id>.json` containing `{"blocked_state":"blocked:permission","tool_name":"<Name>","tool_input":{...},"requested_at":<epoch_ms>}`. Also append an unresolved `tool_use` entry for `agent-history --blocked` coverage. |

### Codex / Ren-Codex

| Cue | Entry |
|---|---|
| Prompt arrives | `{"type":"event_msg","payload":{"type":"user_message","message":"<text>"}}` |
| Working (pending tool) | `{"type":"response_item","payload":{"type":"function_call","call_id":"<cid>","name":"<Name>","arguments":"{...}"}}` |
| Tool resolved | `{"type":"response_item","payload":{"type":"function_call_output","call_id":"<cid>","output":"ok"}}` |
| Idle | `{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"<reply>"}}` |
| `blocked:question` | Unresolved `function_call` with `name:"request_user_input"`, `arguments:"{\"questions\":[{\"question\":\"<text>\"}]}"`. |
| `blocked:permission` | Unresolved `function_call` whose `arguments` JSON contains `"sandbox_permissions":"require_escalated"`. |

## Screen rendering

`agent-state` Layer 3 (screen scraping) overrides transcript-reported `working` if visible pane content matches specific patterns. The fakes must keep the default visible surface clean:

- Idle / working default content **must not** contain: `"Tab to amend"`, `"Do you want to proceed?"`, `"Do you want to overwrite"`, `"Enter to select"` together with `"Chat about this"`, `"Esc to cancel"`, or `"esc to cancel"`.
- Codex fakes render `›` as the last non-empty line when idle. Remove / replace it while working.
- Pane title, if set, must not begin with a Braille char (U+2800–U+28FF) while the fake is idle — that would be a false Layer 4 spinner hit.

Rendering `blocked:unknown` via the screen-scrape path only (transcript still says `working`) is done by writing a line containing `"Esc to cancel"`.

## Control surface

Each fake must expose a named fifo for test-driven state transitions, path taken from env:

```
FAKE_AGENT_CTL=<path to named fifo>
```

If `FAKE_AGENT_CTL` is unset, the fake runs an auto-reply default: on each prompt, append the prompt entry, render `working` briefly, append the idle-terminating entry, return to idle.

Commands, one per line (LF terminated):

| Command | Effect |
|---|---|
| `state working` | Append an unresolved `tool_use` / `function_call` entry. |
| `state idle [text]` | Append the idle-terminating entry; reply text defaults to `ok`. |
| `state blocked:question <text>` | Append the unresolved question entry with `<text>`. |
| `state blocked:permission [tool] [input_json]` | Claude: write sidecar + unresolved `tool_use`. Codex: unresolved `function_call` with `require_escalated`. |
| `state blocked:unknown` | Render `"Esc to cancel"` on the pane; transcript unchanged. |
| `render <line>` | Append `<line>` to the visible pane surface. |
| `sleep <ms>` | Delay before reading the next command. |
| `exit` | Flush transcript, close the transcript fd, exit 0. |

Commands are processed one at a time. The fake flushes the transcript before each next fifo read so tests can assert on-disk state between commands without races.

`FAKE_AGENT_SCENARIO=<name>` selects a canned script (`idle`, `blocked_question`, `blocked_permission`, `blocked_unknown`, `slow`) when `FAKE_AGENT_CTL` is unset. Ignored when the fifo is set.

## Environment

| Variable | Required | Purpose |
|---|---|---|
| `PATH` | yes | Must lead with the test `bin/` so fakes shadow real binaries. |
| `HOME` | yes | Isolates `~/.claude`, `~/.codex`, `~/.steez` under a tmp dir. |
| `STEEZ_STATE_DIR` | yes | Isolates `agent-eventsd` watch state under a tmp dir. |
| `FAKE_AGENT_CTL` | optional | Path to this pane's control fifo. |
| `FAKE_AGENT_SCENARIO` | optional | Canned scenario name. Ignored when `FAKE_AGENT_CTL` is set. |
| `REN_SESSION` | required for ren variants | Set by the ren / ren-codex wrappers. |

## Required scenarios

These scenarios must be reproducible end-to-end through the real runtime. They are the minimum set the integration tests in bead `steez-r65` cover; each is driven by the control fifo so no timers inside the fake own correctness.

1. **idle** — prompt arrives, transcript flips to `idle`, the watch resolves, `agent-eventsd` fires `agent-deliver` exactly once against the spawner pane.
2. **no-watch** — `agent-send --no-watch` delivers bytes; no prearm / start; fake still flips to `idle`; no delivery to the spawner.
3. **blocked:question** — transcript ends in an unresolved `AskUserQuestion` / `request_user_input`; watch resolves to `blocked:question`; `agent-history --blocked` returns the question text.
4. **blocked:permission** — Claude sidecar (or Codex `require_escalated` call) appears; watch resolves to `blocked:permission`.
5. **blocked:unknown via screen scrape** — transcript still says `working`, visible pane shows `"Esc to cancel"`; state detection and watch resolution both flip to `blocked:unknown`.
6. **supersede** — second prompt arrives before the first resolves; the prior live watch closes with `superseded`; the new prearm arms cleanly. Cross-ref: agent-events — Live and draining watches.
7. **slow / degraded** — no fast evidence for `SILENCE_WINDOW_MS`; `agent-eventsd` falls back to `agent-state` polling; scenario either resolves via degraded reconcile or times out to `blocked:unknown` per `INDETERMINATE_TIMEOUT_MS`.
8. **pane close** — fake exits cleanly while a watch is live; the watch closes per agent-events — Pane close and restart.
9. **no primary-path spawn of agent-watch-daemon** — across every scenario, no process named `agent-watch-daemon` is started. `agent-eventsd` is the only watcher.

## Acceptance

A fake-agent implementation is acceptable when, across the required scenarios:

1. `agent-state <pane>` returns the correct agent name and expected state.
2. `agent-history <pane> --last | --blocked | --history N` returns the expected fields.
3. `spawn.sh` completes boot wait against the fake inside `BOOT_TIMEOUT` with no adjustment.
4. `agent-send <pane> <msg>` followed by a control-fifo transition causes exactly one delivery against the spawner pane, tagged with the same `watch_id` recorded in `$STEEZ_STATE_DIR/eventsd/`.
5. None of the forbidden actions in "Seam" are needed to hit those assertions.
