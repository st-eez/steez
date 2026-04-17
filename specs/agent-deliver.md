# agent-deliver

**Path:** `shared/steez/bin/agent-deliver`

Low-level delivery primitive for AI agent chat panes. Sends a message via tmux paste-buffer with a delayed Enter. No side effects beyond tmux — no watch registration, no state tracking.

## Interface

```
agent-deliver <pane> "message"
```

### Arguments

| Arg | Description |
|-----|-------------|
| `<pane>` | Target pane (`%N` preferred, also `session:window.pane`) |
| `<message>` | Message body. Must be non-empty. Multi-line: embed real newlines. |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Message submitted |
| 1 | Generic error (bad args, send failed) |
| 2 | Pane is not a recognized AI agent |

## Delivery Mechanism

1. **Agent validation:** Calls `agent-state <pane>` to verify the target is a recognized AI agent. Exits 2 if not.
2. **Pane resolution:** Resolves to canonical `%N` pane ID via `tmux display-message`.
3. **Buffer load:** Creates a named tmux buffer (`agent-deliver-$$`), loads the message via `tmux load-buffer -b <buf> -` from stdin. This is verbatim byte delivery — backticks, dollar signs, quotes survive unmangled (no shell parsing).
4. **Paste:** `tmux paste-buffer -b <buf> -t <pane> -d` (-d deletes the buffer after paste).
5. **Delayed Enter:** `sleep 0.3`, then `tmux send-keys -t <pane> Enter`. The delay is critical — the agent's composer needs Enter as a separate keystroke after the paste; bundling them causes the message to sit unsubmitted.
6. **Retry Enter:** Open a deadline-polled retry window — 25ms ticks for up to 20 iterations (500ms total). Each tick re-reads `@transcript_path` and `agent-state`; the loop exits early on the first signal the Enter landed (transcript cursor advanced at the same path) or that the agent is processing (state left `idle`). After the loop, send a second `Enter` only when the pane is still `idle` AND we cannot prove growth — `@transcript_path` was unset before delivery, is unset after delivery, or matches BEFORE with no cursor advance. A fixed sleep here was the original race: fast turns could round-trip to `idle` inside the window and the retry would resubmit the same prompt to a pre-armed composer.

## Cleanup

A trap removes the tmux buffer on exit: `tmux delete-buffer -b "$BUF"`.

## Dependencies

- `agent-state` (agent validation, idle check for retry)
- `tmux` (pane resolution, buffer load, paste, send-keys)

## Integration Points

- **agent-send** calls `agent-deliver` for all message delivery.
- **agent-eventsd** calls `agent-deliver` directly for notifications (never `agent-send`, to prevent recursive loops).

## Behavioral Contracts

1. Zero side effects beyond tmux. No watches, no state files, no logging.
2. Agent validation gate: rejects non-agent panes before touching tmux buffers.
3. Escape-safe: message bytes are never interpreted by a shell. The load-buffer/paste-buffer path is fully binary-safe.
4. Delayed Enter is mandatory. The 300ms gap between paste and Enter is the core reason this script exists.
5. Retry Enter is guarded by transcript growth. Idle alone is not enough to prove the first Enter failed.

## Error Handling

- Empty message: error to stderr, exit 1.
- Non-agent pane: error to stderr, exit 2.
- Pane not found: error to stderr, exit 1.
- Buffer load or paste failure: tmux error propagates, exit 1.
