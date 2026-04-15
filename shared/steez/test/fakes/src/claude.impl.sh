#!/bin/bash
# Fake claude / ren implementation — runs under the Go wrapper at
# shared/steez/test/fakes/src/fake-agent (built as `claude` in tests). The
# wrapper preserves the "claude" basename in `ps` and the REN_SESSION=1
# env for ren; this script is the behavior. Spec: specs/fake-agent-harness.md.
#
# Current slice: boot contract + auto-reply + blocked:question and
# working-state control via the fifo. Later slices still own permission,
# degraded, and pane-close behavior.
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

transcript_append() {
  local mode="$1"; shift
  python3 - "$TRANSCRIPT_PATH" "$mode" "$@" <<'PYEOF'
import json
import os
import sys

transcript = sys.argv[1]
mode = sys.argv[2]

if mode == "prompt":
    user_text, = sys.argv[3:]
    entry = {
        "type": "user",
        "message": {"content": user_text},
        "isMeta": False,
        "isSidechain": False,
    }
elif mode == "idle":
    msg_id, reply_text = sys.argv[3:]
    entry = {
        "type": "assistant",
        "message": {
            "id": msg_id,
            "content": [{"type": "text", "text": reply_text}],
            "stop_reason": "end_turn",
        },
    }
elif mode == "working":
    msg_id, tool_id = sys.argv[3:]
    entry = {
        "type": "assistant",
        "message": {
            "id": msg_id,
            "content": [{
                "type": "tool_use",
                "id": tool_id,
                "name": "ReadFile",
                "input": {"path": "/tmp/fake-working"},
            }],
        },
    }
elif mode == "blocked-question":
    msg_id, tool_id, question = sys.argv[3:]
    entry = {
        "type": "assistant",
        "message": {
            "id": msg_id,
            "content": [{
                "type": "tool_use",
                "id": tool_id,
                "name": "AskUserQuestion",
                "input": {"questions": [{"question": question}]},
            }],
        },
    }
else:
    raise SystemExit(f"unknown transcript append mode: {mode}")

with open(transcript, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry) + "\n")
    fh.flush()
    os.fsync(fh.fileno())
PYEOF
}

control_fifo_path() {
  if [[ -n "${FAKE_AGENT_CTL:-}" ]]; then
    printf '%s\n' "$FAKE_AGENT_CTL"
    return 0
  fi
  [[ -n "${TMUX_PANE:-}" && -n "${STEEZ_STATE_DIR:-}" ]] || return 1
  printf '%s\n' "$STEEZ_STATE_DIR/fakes/ctl/$TMUX_PANE"
}

drive_turn_from_fifo() {
  local msg_id="$1" ctl="$2"
  local tool_counter=0 cmd question reply_text

  while true; do
    if ! IFS= read -r cmd < "$ctl"; then
      sleep 0.05
      continue
    fi

    case "$cmd" in
      "exit")
        exit 0
        ;;
      "state working")
        tool_counter=$((tool_counter + 1))
        transcript_append "working" "$msg_id" "tool_$tool_counter"
        return 0
        ;;
      "state blocked:question "*)
        question="${cmd#state blocked:question }"
        tool_counter=$((tool_counter + 1))
        transcript_append "blocked-question" "$msg_id" "tool_$tool_counter" "$question"
        return 0
        ;;
      "state idle")
        transcript_append "idle" "$msg_id" "ok"
        printf '> '
        return 0
        ;;
      "state idle "*)
        reply_text="${cmd#state idle }"
        transcript_append "idle" "$msg_id" "$reply_text"
        printf '> '
        return 0
        ;;
      *)
        echo "fake-claude: unsupported control command: $cmd" >&2
        return 1
        ;;
    esac
  done
}

# Auto-reply default (no control fifo): each line arriving on the pane tty
# becomes one prompt. If the per-pane fifo exists when the prompt lands,
# block on the control command instead.
msg_counter=0
while IFS= read -r line; do
  if [[ -z "$line" ]]; then
    printf '> '
    continue
  fi
  msg_counter=$((msg_counter + 1))
  msg_id="msg_$msg_counter"
  transcript_append "prompt" "$line"

  ctl_path=""
  if ctl_path=$(control_fifo_path 2>/dev/null) && [[ -p "$ctl_path" ]]; then
    drive_turn_from_fifo "$msg_id" "$ctl_path"
    continue
  fi

  transcript_append "idle" "$msg_id" "ok"
  printf '> '
done
