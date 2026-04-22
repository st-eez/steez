#!/bin/bash
# Expose Codex session metadata to tmux pane variables for agent-state --detail
resolve_transcript_from_session_id() {
  local sid="$1"
  [[ -n "$sid" ]] || return 1
  find "$HOME/.codex/sessions" -type f -name "*${sid}*.jsonl" 2>/dev/null | head -1
}

input=$(cat)
if [ -n "$TMUX_PANE" ]; then
  sid=$(echo "$input" | jq -r '.session_id // empty')
  if [ -n "$sid" ]; then
    transcript=$(echo "$input" | jq -r '.transcript_path // empty')
    if [ -z "$transcript" ]; then
      transcript=$(resolve_transcript_from_session_id "$sid")
    fi
    tmux set-option -p -t "$TMUX_PANE" @session_id "$sid" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @transcript_path "$transcript" 2>/dev/null
  fi
fi
