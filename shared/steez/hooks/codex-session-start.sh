#!/bin/bash
# Expose Codex session metadata to tmux pane variables for steez-agent-state --detail
input=$(cat)
if [ -n "$TMUX_PANE" ]; then
  sid=$(echo "$input" | jq -r '.session_id // empty')
  if [ -n "$sid" ]; then
    tmux set-option -p -t "$TMUX_PANE" @session_id "$sid" 2>/dev/null
    tmux set-option -p -t "$TMUX_PANE" @transcript_path \
      "$(echo "$input" | jq -r '.transcript_path // empty')" 2>/dev/null
  fi
fi
