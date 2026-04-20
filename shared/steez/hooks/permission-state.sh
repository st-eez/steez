#!/usr/bin/env bash
set -euo pipefail

input=$(cat)

hook_event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null || printf '')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || printf '')
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || printf '')

# Working lease TTL. Bridges the gap between the user hitting Enter and
# the first assistant turn landing in the transcript — short enough that
# a stale lease never survives a real turn boundary (Stop clears it).
WORKING_LEASE_MS=10000

now_ms() {
  local v
  v=$(date +%s%3N 2>/dev/null || true)
  case "$v" in
    ''|*[!0-9]*) python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

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

  local state cursor
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

# Runtime pane state publisher. Writes canonical pane state onto the
# worker pane via tmux pane options so consumers (agent-state) can
# observe live state without scraping the transcript. Sticky states
# (blocked:*, idle) unset the lease; transient states (working on
# UserPromptSubmit) write @agent_runtime_expires_ms = now + TTL. Spec:
# specs/agent-events.md (Runtime pane state producers).
publish_runtime_state() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  command -v tmux >/dev/null 2>&1 || return 0

  local state lease_ms=""
  case "$hook_event" in
    Stop)
      state="idle"
      ;;
    UserPromptSubmit)
      state="working"
      lease_ms=$(( $(now_ms) + WORKING_LEASE_MS ))
      ;;
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

  tmux set-option -p -t "$TMUX_PANE" @agent_runtime_state "$state" >/dev/null 2>&1 || true
  if [[ -n "$lease_ms" ]]; then
    tmux set-option -p -t "$TMUX_PANE" @agent_runtime_expires_ms "$lease_ms" >/dev/null 2>&1 || true
  else
    tmux set-option -p -t "$TMUX_PANE" -u @agent_runtime_expires_ms >/dev/null 2>&1 || true
  fi
}

dispatch_evidence
publish_runtime_state
