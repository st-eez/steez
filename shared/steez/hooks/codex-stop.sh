#!/bin/bash
# Codex Stop hook: fire `agent-eventsd evidence --state idle` so a live
# watch on this pane resolves sub-second instead of waiting for the 30s
# degraded fallback. Spec: specs/agent-events.md (Codex Stop hook).
#
# Codex invokes this hook on turn-end, with the Stop event payload on
# stdin. The payload carries `session_id` and `transcript_path`; we use
# the transcript size as the monotonic `transcript_cursor` so the daemon
# treats the event as post-prearm.
#
# User-side registration (NOT installer-mutated):
#   1. Enable the Codex hooks feature in ~/.codex/config.toml:
#        [features]
#        codex_hooks = true
#   2. Register this hook for the Stop event in ~/.codex/hooks.json:
#        { "Stop": [ { "command": "$HOME/.codex/hooks/codex-stop.sh",
#                      "async": true } ] }
# The installer symlinks this file into ~/.codex/hooks/codex-stop.sh
# but does NOT mutate config.toml or hooks.json.
set -u
input=$(cat)
[ -n "${TMUX_PANE:-}" ] || exit 0
[ -x "$HOME/.steez/bin/agent-eventsd" ] || exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
cursor=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  cursor=$(wc -c < "$transcript" 2>/dev/null | tr -d ' ')
  cursor="${cursor:-0}"
fi
"$HOME/.steez/bin/agent-eventsd" evidence \
  --pane "$TMUX_PANE" --state idle \
  --transcript-cursor "$cursor" >/dev/null 2>&1 &
exit 0
