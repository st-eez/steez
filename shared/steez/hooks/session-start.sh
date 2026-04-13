#!/bin/bash
# Expose Claude session metadata to tmux pane variables for agent-state --detail
# Hook: SessionStart (settings.json)
read -r -t 5 INPUT || true
if [ -n "$TMUX_PANE" ]; then
  SID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | cut -d'"' -f4)
  if [ -n "$SID" ]; then
    tmux set-option -p -t "$TMUX_PANE" @session_id "$SID" 2>/dev/null
    TRANSCRIPT=$(printf '%s' "$INPUT" | grep -o '"transcript_path":"[^"]*"' | cut -d'"' -f4)
    tmux set-option -p -t "$TMUX_PANE" @transcript_path "$TRANSCRIPT" 2>/dev/null
    rm -f "$HOME/.steez/agent-state/claude/$SID.json"
  fi
fi
