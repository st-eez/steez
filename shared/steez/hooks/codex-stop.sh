#!/bin/bash
# Codex UserPromptSubmit + Stop hook.
#
# Stop:
#   - Dispatches `agent-eventsd evidence --state idle` so a live watch
#     on this pane resolves sub-second instead of waiting 30s for the
#     degraded fallback. Transcript byte-count is the monotonic
#     `transcript_cursor`; the daemon treats that as post-prearm.
#   - Writes @agent_runtime_state=idle onto the pane and unsets
#     @agent_runtime_expires_ms so a stale working lease from the
#     previous turn cannot leak.
#
# UserPromptSubmit:
#   - Writes @agent_runtime_state=working onto the pane with a short
#     @agent_runtime_expires_ms lease, bridging the gap between the
#     user hitting Enter and the first assistant turn appearing in the
#     transcript. No evidence dispatch — working is not terminal.
#
# User-side registration (NOT installer-mutated):
#   1. Enable the Codex hooks feature in ~/.codex/config.toml:
#        [features]
#        codex_hooks = true
#   2. Register this hook for Stop AND UserPromptSubmit in
#      ~/.codex/hooks.json:
#        { "Stop":             [ { "hooks": [ { "command": "bash $HOME/.codex/hooks/codex-stop.sh" } ] } ],
#          "UserPromptSubmit": [ { "hooks": [ { "command": "bash $HOME/.codex/hooks/codex-stop.sh" } ] } ] }
# The installer symlinks this file into ~/.codex/hooks/codex-stop.sh
# but does NOT mutate config.toml or hooks.json. Spec:
# specs/agent-events.md.
set -u
input=$(cat)
[ -n "${TMUX_PANE:-}" ] || exit 0

hook_event=$(printf '%s' "$input" | jq -r '.hook_event_name // "Stop"' 2>/dev/null || printf 'Stop')

WORKING_LEASE_MS=10000

now_ms() {
  local v
  v=$(date +%s%3N 2>/dev/null || true)
  case "$v" in
    ''|*[!0-9]*) python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

publish_runtime_state() {
  command -v tmux >/dev/null 2>&1 || return 0
  local state="$1" lease_ms="${2:-}"
  tmux set-option -p -t "$TMUX_PANE" @agent_runtime_state "$state" >/dev/null 2>&1 || true
  if [ -n "$lease_ms" ]; then
    tmux set-option -p -t "$TMUX_PANE" @agent_runtime_expires_ms "$lease_ms" >/dev/null 2>&1 || true
  else
    tmux set-option -p -t "$TMUX_PANE" -u @agent_runtime_expires_ms >/dev/null 2>&1 || true
  fi

  trigger_sketchybar_refresh
}

# Fire the SketchyBar `agent_attention_changed` trigger after every runtime
# pane-state write so the macOS bar refreshes working/idle transitions in
# real time rather than waiting on its 5s poll. Best-effort: a missing
# `sketchybar` binary is not an error and must not hold the hook open past
# Codex's 5s timeout. Spec: specs/agent-events.md (Runtime pane state
# producers — SketchyBar sink).
trigger_sketchybar_refresh() {
  command -v sketchybar >/dev/null 2>&1 || return 0
  sketchybar --trigger agent_attention_changed >/dev/null 2>&1 || true
}

case "$hook_event" in
  UserPromptSubmit)
    publish_runtime_state working "$(( $(now_ms) + WORKING_LEASE_MS ))"
    ;;
  *)
    # Stop — explicit event name, or legacy payloads that omit
    # hook_event_name entirely and only reach this hook via a Stop
    # registration.
    if [ -x "$HOME/.steez/bin/agent-eventsd" ]; then
      transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
      cursor=0
      if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        cursor=$(wc -c < "$transcript" 2>/dev/null | tr -d ' ')
        cursor="${cursor:-0}"
      fi
      "$HOME/.steez/bin/agent-eventsd" evidence \
        --pane "$TMUX_PANE" --state idle \
        --transcript-cursor "$cursor" >/dev/null 2>&1 &
    fi
    publish_runtime_state idle ""
    ;;
esac

printf '%s\n' '{"continue":true}'
