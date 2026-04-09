#!/usr/bin/env bash
# spawn.sh — Create a tmux target and launch an AI agent in it.
#
# Usage:
#   spawn.sh <target-type> [--dir <name-or-path>] [--session <name>] [--prompt <text>] [--target <pane>] [--model <name>]
#
# Target types: split-h, split-v, new-window, new-session
# Models: ren (default), prometheus, claude, codex
#
# --target <pane>  For split-h/split-v: split this pane instead of self.
#                  Use pane_id format (%N, e.g., %5) or session:window.pane (e.g., mac:5.1).
#                  Enables multi-agent patterns: new-window first, then
#                  split-h --target <returned-pane-id> to add agents in that window.
#
# Output (structured, for model consumption):
#   SELF=%0 TARGET=%5                  (on success — stable pane_ids)
#   RESOLVED=/full/path METHOD=local   (if dir was resolved)
#   AMBIGUOUS=3 CANDIDATE=...          (if dir has multiple matches)
#   ERROR: <message>                   (on failure)

set -euo pipefail

# --- Argument parsing ---
TARGET_TYPE="${1:?Usage: spawn.sh <split-h|split-v|new-window|new-session> [--dir <name>] [--session <name>] [--prompt <text>]}"
shift

DIR_NAME=""
SESSION_NAME=""
PROMPT_TEXT=""
SPLIT_TARGET=""
MODEL="ren"
NO_WATCH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     DIR_NAME="$2"; shift 2 ;;
    --session) SESSION_NAME="$2"; shift 2 ;;
    --prompt)  PROMPT_TEXT="$2"; shift 2 ;;
    --target)  SPLIT_TARGET="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --no-watch) NO_WATCH=true; shift ;;
    *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
  esac
done

# Validate model
case "$MODEL" in
  prometheus|claude|codex|ren) ;;
  *) echo "ERROR: unknown model '$MODEL' (use: prometheus, claude, codex, ren)"; exit 1 ;;
esac

# --- Directory resolution ---
resolve_dir() {
  local name="$1"

  # Tier 0 — literal path
  if [[ "$name" == /* || "$name" == ~* || "$name" == ./* || "$name" == ../* ]]; then
    local expanded="${name/#\~/$HOME}"
    if [ -d "$expanded" ]; then
      echo "RESOLVED=$(cd "$expanded" && pwd)"
      echo "METHOD=literal"
      return 0
    fi
    echo "NOTFOUND=$name"
    return 1
  fi

  # Tier 1 — cwd child (one stat call)
  if [ -d "$PWD/$name" ]; then
    echo "RESOLVED=$(cd "$PWD/$name" && pwd)"
    echo "METHOD=local"
    return 0
  fi

  # Tier 2 — zoxide (frecency)
  if command -v zoxide >/dev/null 2>&1; then
    local zresult
    zresult=$(zoxide query --list "$name" 2>/dev/null | head -1)
    if [ -n "$zresult" ] && [ -d "$zresult" ]; then
      echo "RESOLVED=$zresult"
      echo "METHOD=zoxide"
      return 0
    fi
  fi

  # Tier 3 — exact name via find, ranked by depth
  local results
  results=$(find "$HOME" -maxdepth 4 -type d -name "$name" 2>/dev/null |
    awk -F/ '{print NF, $0}' | sort -n | cut -d' ' -f2-)
  local count
  count=$(echo "$results" | grep -c . || true)

  if [ "$count" -eq 1 ]; then
    echo "RESOLVED=$results"
    echo "METHOD=find"
    return 0
  elif [ "$count" -gt 1 ]; then
    echo "AMBIGUOUS=$count"
    echo "$results" | while IFS= read -r r; do echo "CANDIDATE=$r"; done
    return 2
  fi

  # Tier 4 — partial match (never auto-resolves)
  results=$(find "$HOME" -maxdepth 4 -type d -iname "*${name}*" 2>/dev/null |
    awk -F/ '{print NF, $0}' | sort -n | cut -d' ' -f2- | head -10)
  count=$(echo "$results" | grep -c . || true)

  if [ "$count" -ge 1 ]; then
    echo "AMBIGUOUS=$count"
    echo "$results" | while IFS= read -r r; do echo "CANDIDATE=$r"; done
    return 2
  fi

  echo "NOTFOUND=$name"
  return 1
}

# --- Validate tmux ---
[ -z "${TMUX:-}" ] && echo "ERROR: not in a tmux session" && exit 1

# --- Identify self ---
SELF_ID="$TMUX_PANE"  # pane_id (%N) — stable, never changes
_SELF_ADDR=$(tmux list-panes -a -F "#{pane_id} #{session_name}:#{window_index}" | grep "^$TMUX_PANE " | awk '{print $2}')
CURRENT_SESSION=$(echo "$_SELF_ADDR" | cut -d: -f1)
CURRENT_WINDOW=$(echo "$_SELF_ADDR" | cut -d: -f2)

# --- Resolve directory (if requested) ---
TARGET_DIR=""
if [ -n "$DIR_NAME" ]; then
  resolve_output=$(resolve_dir "$DIR_NAME")
  resolve_rc=$?

  if [ "$resolve_rc" -eq 0 ]; then
    TARGET_DIR=$(echo "$resolve_output" | grep "^RESOLVED=" | cut -d= -f2-)
    echo "$resolve_output"
  else
    # Ambiguous or not found — print output for model and exit
    echo "$resolve_output"
    exit "$resolve_rc"
  fi
fi

# --- Resolve split target ---
# For split-h/split-v: --target overrides which pane to split (default: self)
# Accepts both pane_id (%N) and session:window.pane formats
if [ -n "$SPLIT_TARGET" ]; then
  SPLIT_PANE="$SPLIT_TARGET"
  if [[ "$SPLIT_TARGET" == %* ]]; then
    # pane_id format — resolve session:window for snapshot
    _taddr=$(tmux list-panes -a -F "#{pane_id} #{session_name} #{window_index}" | grep "^$SPLIT_TARGET ")
    SPLIT_SESSION=$(echo "$_taddr" | awk '{print $2}')
    SPLIT_WINDOW=$(echo "$_taddr" | awk '{print $3}')
  else
    # legacy session:window.pane format
    SPLIT_SESSION=$(echo "$SPLIT_TARGET" | cut -d: -f1)
    SPLIT_WINDOW=$(echo "$SPLIT_TARGET" | cut -d: -f2 | cut -d. -f1)
  fi
else
  SPLIT_PANE="$SELF_ID"
  SPLIT_SESSION="$CURRENT_SESSION"
  SPLIT_WINDOW="$CURRENT_WINDOW"
fi

# --- Snapshot pane IDs (for split detection) ---
BEFORE=$(tmux list-panes -t "$SPLIT_SESSION:$SPLIT_WINDOW" -F "#{pane_id}" | sort)

# --- Create tmux target ---
case "$TARGET_TYPE" in
  split-h)
    tmux split-window -t "$SPLIT_PANE" -h
    NEW_TARGET=$(comm -13 <(echo "$BEFORE") <(tmux list-panes -t "$SPLIT_SESSION:$SPLIT_WINDOW" -F "#{pane_id}" | sort))
    ;;
  split-v)
    tmux split-window -t "$SPLIT_PANE" -v
    NEW_TARGET=$(comm -13 <(echo "$BEFORE") <(tmux list-panes -t "$SPLIT_SESSION:$SPLIT_WINDOW" -F "#{pane_id}" | sort))
    ;;
  new-window)
    tmux new-window -t "$CURRENT_SESSION"
    NEW_TARGET=$(tmux display-message -t "$CURRENT_SESSION" -p "#{pane_id}")
    ;;
  new-session)
    sname="${SESSION_NAME:-agent-1}"
    tmux new-session -d -s "$sname"
    NEW_TARGET=$(tmux list-panes -t "$sname" -F "#{pane_id}")
    ;;
  *)
    echo "ERROR: unknown target type '$TARGET_TYPE' (use: split-h, split-v, new-window, new-session)"
    exit 1
    ;;
esac

# --- Safety check ---
[ "$NEW_TARGET" = "$SELF_ID" ] && echo "ERROR: target equals self — split may have failed" && exit 1

echo "SELF=$SELF_ID TARGET=$NEW_TARGET"

# --- cd to directory (if resolved) ---
if [ -n "$TARGET_DIR" ]; then
  tmux send-keys -t "$NEW_TARGET" "cd '$TARGET_DIR'"
  sleep 0.3
  tmux send-keys -t "$NEW_TARGET" Enter
  sleep 0.5
fi

# --- Launch agent ---
AGENT_STATE="$HOME/.steez/bin/agent-state"

case "$MODEL" in
  prometheus) LAUNCH_CMD="prometheus" ;;
  ren)        LAUNCH_CMD="ren" ;;
  claude)     LAUNCH_CMD="claude --dangerously-skip-permissions" ;;
  codex)      LAUNCH_CMD="codex --dangerously-bypass-approvals-and-sandbox" ;;
esac

echo "MODEL=$MODEL"

# --- Launch agent ---
if [ -n "$PROMPT_TEXT" ]; then
  # Pass prompt as CLI argument — agent starts working immediately
  tmux send-keys -t "$NEW_TARGET" "$LAUNCH_CMD \"$PROMPT_TEXT\""
else
  tmux send-keys -t "$NEW_TARGET" "$LAUNCH_CMD"
fi
sleep 0.3
tmux send-keys -t "$NEW_TARGET" Enter
[ -n "$PROMPT_TEXT" ] && echo "PROMPT_SENT"

# --- Poll for agent state ---
# Wait for agent to boot, load hooks, and begin processing before first poll
sleep 5
for i in $(seq 1 10); do
  sleep 1
  state_out=$("$AGENT_STATE" "$NEW_TARGET" 2>/dev/null) || continue
  state=$(echo "$state_out" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['state'])" 2>/dev/null) || continue
  if [[ "$state" == "working" ]]; then
    echo "WORKING"
    break
  elif [[ "$state" == "idle" ]]; then
    echo "IDLE"
    break
  fi
done

# --- Register watch for the initial prompt ---
# If a prompt was passed via --prompt, the agent is (or will be) working
# on it right now. Register a background watch so the spawner pane gets
# a notification when the agent finishes. This is the auto-registration
# equivalent of what agent-send does for subsequent messages; without it,
# the very first turn of every prompted spawn would be unwatched.
#
# Baseline is hardcoded to "working". Why not the observed state from the
# polling loop above? The polling loop races with agent boot — a fast
# agent may already be back to idle, a slow agent may not have loaded yet
# and still show the shell prompt. Either way, we know semantically that
# the agent is (or will be) processing the prompt, so baseline=working is
# the correct intent. The daemon's transition rule handles both races:
# - agent still booting:  shell idle -> working -> idle triggers fire
#     on the final working -> idle transition.
# - agent already done:   current=idle on first daemon poll, baseline=
#     working != idle, fire immediately.
#
# Why this lives in spawn.sh and not in the skill prose: the script is
# the single canonical entry point for all /spawn-agent calls, so wiring
# the watch here covers every invocation deterministically rather than
# relying on Claude to remember to run `agent-watch add` after every spawn.
if [ -n "$PROMPT_TEXT" ] && [ "$NO_WATCH" = "false" ]; then
  PROMPT_SUMMARY=$(printf '%s' "$PROMPT_TEXT" | tr -d '\n\r' | cut -c1-40)
  if "$HOME/.steez/bin/agent-watch" add "$NEW_TARGET" \
      --spawner "$SELF_ID" \
      --baseline "working" \
      --label "$MODEL $PROMPT_SUMMARY" >/dev/null 2>&1; then
    echo "WATCHED=$NEW_TARGET SPAWNER=$SELF_ID BASELINE=working"
  fi
fi
