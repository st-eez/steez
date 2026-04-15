#!/bin/bash
# Fake agent implementation for the zero-token harness.
#
# The compiled wrapper preserves the process basename (`claude` or `codex`).
# `ren` and `ren-codex` are thin wrappers that only set REN_SESSION=1.
set -uo pipefail

FAKE_AGENT_NAME="${FAKE_AGENT_NAME:-claude}"

case "$FAKE_AGENT_NAME" in
  claude|codex) ;;
  *) echo "fake-agent: unsupported fake agent '$FAKE_AGENT_NAME'" >&2; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$FAKE_AGENT_NAME:$1" in
    claude:--dangerously-skip-permissions) shift ;;
    codex:--dangerously-bypass-approvals-and-sandbox) shift ;;
    *) echo "fake-$FAKE_AGENT_NAME: unknown argument: $1" >&2; exit 1 ;;
  esac
done

SESSION_ID=""
TRANSCRIPT_PATH=""
msg_counter=0

new_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

set_tmux_metadata() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  tmux set-option -p -t "$TMUX_PANE" @session_id      "$SESSION_ID"      >/dev/null 2>&1 || true
  tmux set-option -p -t "$TMUX_PANE" @transcript_path "$TRANSCRIPT_PATH" >/dev/null 2>&1 || true
}

ensure_session_metadata() {
  [[ -n "$SESSION_ID" && -n "$TRANSCRIPT_PATH" ]] && return 0

  SESSION_ID=$(new_session_id)
  if [[ "$FAKE_AGENT_NAME" == "codex" ]]; then
    local transcript_dir="${HOME}/.codex/sessions/fake"
    mkdir -p "$transcript_dir"
    TRANSCRIPT_PATH="${transcript_dir}/rollout-${SESSION_ID}.jsonl"
  else
    local transcript_dir="${HOME}/.claude/projects/fake"
    mkdir -p "$transcript_dir"
    TRANSCRIPT_PATH="${transcript_dir}/${SESSION_ID}.jsonl"
  fi

  : > "$TRANSCRIPT_PATH"
  set_tmux_metadata
}

render_idle_prompt() {
  if [[ "$FAKE_AGENT_NAME" == "codex" ]]; then
    printf '\033[999;1H\033[2K› '
  else
    printf '> '
  fi
}

transcript_append() {
  local mode="$1"; shift
  python3 - "$TRANSCRIPT_PATH" "$FAKE_AGENT_NAME" "$mode" "$@" <<'PYEOF'
import json
import os
import sys

transcript = sys.argv[1]
agent = sys.argv[2]
mode = sys.argv[3]
args = sys.argv[4:]

if agent == "claude":
    if mode == "prompt":
        (user_text,) = args
        entry = {
            "type": "user",
            "message": {"content": user_text},
            "isMeta": False,
            "isSidechain": False,
        }
    elif mode == "idle":
        msg_id, reply_text = args
        entry = {
            "type": "assistant",
            "message": {
                "id": msg_id,
                "content": [{"type": "text", "text": reply_text}],
                "stop_reason": "end_turn",
            },
        }
    elif mode == "working":
        msg_id, tool_id = args
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
        msg_id, tool_id, question = args
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
else:
    if mode == "prompt":
        (user_text,) = args
        entry = {
            "type": "event_msg",
            "payload": {"type": "user_message", "message": user_text},
        }
    elif mode == "idle":
        _msg_id, reply_text = args
        entry = {
            "type": "event_msg",
            "payload": {"type": "task_complete", "last_agent_message": reply_text},
        }
    elif mode == "working":
        _msg_id, tool_id = args
        entry = {
            "type": "response_item",
            "payload": {
                "type": "function_call",
                "call_id": tool_id,
                "name": "read_file",
                "arguments": "{\"path\":\"/tmp/fake-working\"}",
            },
        }
    elif mode == "blocked-question":
        _msg_id, tool_id, question = args
        entry = {
            "type": "response_item",
            "payload": {
                "type": "function_call",
                "call_id": tool_id,
                "name": "request_user_input",
                "arguments": json.dumps({"questions": [{"question": question}]}),
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

# fire_evidence — shell out `agent-eventsd evidence` so the resolver can
# fire before the degraded-fallback silence window engages. Mirrors what
# production Claude Stop / PermissionRequest hooks do on turn-end. Spec:
# specs/fake-agent-harness.md (Control surface). Fire-and-forget: the
# evidence CLI tolerates stale / missing watches and must not stall the
# fake's control loop.
fire_evidence() {
  local state="$1"
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  [[ -x "$HOME/.steez/bin/agent-eventsd" ]] || return 0
  local cursor=0
  if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    cursor=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
    cursor="${cursor:-0}"
  fi
  "$HOME/.steez/bin/agent-eventsd" evidence \
    --pane "$TMUX_PANE" --state "$state" \
    --transcript-cursor "$cursor" >/dev/null 2>&1 &
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
        fire_evidence "blocked:question"
        return 0
        ;;
      "state idle")
        transcript_append "idle" "$msg_id" "ok"
        render_idle_prompt
        fire_evidence "idle"
        return 0
        ;;
      "state idle "*)
        reply_text="${cmd#state idle }"
        transcript_append "idle" "$msg_id" "$reply_text"
        render_idle_prompt
        fire_evidence "idle"
        return 0
        ;;
      *)
        echo "fake-$FAKE_AGENT_NAME: unsupported control command: $cmd" >&2
        return 1
        ;;
    esac
  done
}

if [[ "$FAKE_AGENT_NAME" == "claude" ]]; then
  ensure_session_metadata
  printf 'fake-claude ready (session %s)\n' "$SESSION_ID"
fi
render_idle_prompt

while IFS= read -r line; do
  if [[ -z "$line" ]]; then
    if [[ "$FAKE_AGENT_NAME" == "claude" ]]; then
      render_idle_prompt
    fi
    continue
  fi

  msg_counter=$((msg_counter + 1))
  msg_id="msg_$msg_counter"

  ensure_session_metadata
  transcript_append "prompt" "$line"

  ctl_path=""
  if ctl_path=$(control_fifo_path 2>/dev/null) && [[ -p "$ctl_path" ]]; then
    drive_turn_from_fifo "$msg_id" "$ctl_path"
    continue
  fi

  transcript_append "idle" "$msg_id" "ok"
  render_idle_prompt
done
