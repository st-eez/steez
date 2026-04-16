#!/usr/bin/env bash
set -euo pipefail

input=$(cat)

# Fast-path evidence dispatch. Real Claude calls this hook with
# `hook_event_name` set for every lifecycle event; when the event maps to
# a canonical terminal / blocked state, forward it to `agent-eventsd
# evidence` so the armed watch on this pane resolves via the fast path
# instead of the 30s degraded fallback. Fire-and-forget: the hook's
# 5s timeout in settings.json must never be held open by this call.
# Spec: specs/agent-events.md (Event surface — native-hook CLI injection
# as a valid fast-evidence producer).
dispatch_evidence() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  local ev_cli="$HOME/.steez/bin/agent-eventsd"
  [[ -x "$ev_cli" ]] || return 0

  local hook_event tool_name transcript_path state cursor
  hook_event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null || printf '')
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || printf '')
  transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || printf '')

  case "$hook_event" in
    Stop) state="idle" ;;
    PermissionRequest)
      if [[ "$tool_name" == "AskUserQuestion" ]]; then
        state="blocked:question"
      else
        state="blocked:permission"
      fi
      ;;
    PreToolUse)
      [[ "$tool_name" == "AskUserQuestion" ]] || return 0
      state="blocked:question"
      ;;
    *) return 0 ;;
  esac

  cursor=0
  if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    cursor=$(wc -c < "$transcript_path" 2>/dev/null | tr -d ' ')
    cursor="${cursor:-0}"
  fi

  "$ev_cli" evidence \
    --pane "$TMUX_PANE" --state "$state" \
    --transcript-cursor "$cursor" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
dispatch_evidence
