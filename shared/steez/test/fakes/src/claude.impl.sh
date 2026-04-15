#!/bin/bash
# Fake claude / ren implementation — runs under the Go wrapper at
# shared/steez/test/fakes/src/fake-agent (built as `claude` in tests). The
# wrapper preserves the "claude" basename in `ps` and the REN_SESSION=1
# env for ren; this script is the behavior. Spec: specs/fake-agent-harness.md.
#
# Current slice (steez-027): boot contract + auto-reply transcript contract.
# Scope outside this slice (control fifo, blocked variants, supersede,
# degraded/pane-close) is intentionally not implemented yet.
set -uo pipefail

# Silently consume the documented permission-bypass flag. Any other
# argument is a test bug — reject it so fidelity issues can't hide.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dangerously-skip-permissions) shift ;;
    *) echo "fake-claude: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# 1. Generate an opaque session_id. Lower-case to match the Claude hook shape.
if command -v uuidgen >/dev/null 2>&1; then
  SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
else
  SESSION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
fi

# 2. Create the JSONL transcript up front. Path shape matches the spec's
# recommendation so agent-state's Claude filesystem-fallback path could
# also find it, though the pane var is the primary signal.
TRANSCRIPT_DIR="${HOME}/.claude/projects/fake"
mkdir -p "$TRANSCRIPT_DIR"
TRANSCRIPT_PATH="${TRANSCRIPT_DIR}/${SESSION_ID}.jsonl"
: > "$TRANSCRIPT_PATH"

# 3. Set the pane vars the real SessionStart hook sets. spawn.sh's boot
# wait polls @session_id; agent-state / agent-history resolve the transcript
# through @transcript_path.
if [[ -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
  tmux set-option -p -t "$TMUX_PANE" @session_id      "$SESSION_ID"      >/dev/null 2>&1 || true
  tmux set-option -p -t "$TMUX_PANE" @transcript_path "$TRANSCRIPT_PATH" >/dev/null 2>&1 || true
fi

# 4. Render a neutral prompt surface. Keeps the pane visibly "ready" without
# triggering any agent-state screen-scrape patterns.
printf 'fake-claude ready (session %s)\n> ' "$SESSION_ID"

# Auto-reply default (no control fifo): each line arriving on the pane tty
# becomes one prompt. Write prompt + idle-terminating entries to the
# transcript and return to the prompt.
msg_counter=0
while IFS= read -r line; do
  if [[ -z "$line" ]]; then
    printf '> '
    continue
  fi
  msg_counter=$((msg_counter + 1))

  python3 - "$TRANSCRIPT_PATH" "$line" "msg_$msg_counter" <<'PYEOF'
import json
import sys

transcript, user_text, msg_id = sys.argv[1:]

prompt_entry = {
    "type": "user",
    "message": {"content": user_text},
    "isMeta": False,
    "isSidechain": False,
}
reply_entry = {
    "type": "assistant",
    "message": {
        "id": msg_id,
        "content": [{"type": "text", "text": "ok"}],
        "stop_reason": "end_turn",
    },
}

with open(transcript, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(prompt_entry) + "\n")
    fh.write(json.dumps(reply_entry) + "\n")
    fh.flush()
PYEOF

  printf '> '
done
