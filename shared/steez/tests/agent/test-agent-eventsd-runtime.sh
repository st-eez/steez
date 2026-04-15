#!/usr/bin/env bash
# End-to-end runtime tests for agent-eventsd against the zero-token fake
# claude harness.
#
# This file drives the real watch service — no stubs, no in-process library
# sourcing. A watched prompt from agent-send against a fake claude pane must
# produce exactly one idle notification on the spawner pane and the watch
# must self-clear through agent-watch list. Specs: agent-events,
# fake-agent-harness, agent-watch, agent-send.
set -uo pipefail
source "$(dirname "$0")/helpers.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SPAWN_SCRIPT="$REPO_ROOT/skills/spawn-agent/scripts/spawn.sh"
BIN_DIR="$REPO_ROOT/shared/steez/bin"
FAKES_SRC_DIR="$REPO_ROOT/shared/steez/test/fakes/src"

command -v tmux >/dev/null 2>&1 || { echo "  skip: tmux not installed"; exit 0; }
command -v go   >/dev/null 2>&1 || { echo "  skip: go not installed";   exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "  skip: jq not installed";   exit 0; }

REAL_TMUX="$(command -v tmux)"

HARNESS_TMP=$(mktemp -d)
trap 'rm -rf "$HARNESS_TMP"' EXIT
FAKES_BUILD="$HARNESS_TMP/build"
mkdir -p "$FAKES_BUILD"
go build -o "$FAKES_BUILD/claude" "$FAKES_SRC_DIR/fake-agent" || {
  echo "  fake-agent build failed"
  exit 1
}
cp "$FAKES_SRC_DIR/claude.impl.sh" "$FAKES_BUILD/impl.sh"
cp "$FAKES_SRC_DIR/ren"            "$FAKES_BUILD/ren"
chmod +x "$FAKES_BUILD/claude" "$FAKES_BUILD/impl.sh" "$FAKES_BUILD/ren"

setup_runtime() {
  RUNTIME_TMP=$(mktemp -d)
  export HOME="$RUNTIME_TMP/home"
  export STEEZ_STATE_DIR="$RUNTIME_TMP/state"
  mkdir -p "$HOME/.claude" "$HOME/.steez/bin" "$HOME/.steez/agent-state/claude" "$STEEZ_STATE_DIR/eventsd"

  # Real agent-eventsd, agent-state, agent-deliver, agent-send, agent-watch,
  # agent-history — the service must drive real binaries end-to-end. The
  # only replaced component is the agent process itself (fake claude).
  ln -sf "$BIN_DIR/agent-state"    "$HOME/.steez/bin/agent-state"
  ln -sf "$BIN_DIR/agent-deliver"  "$HOME/.steez/bin/agent-deliver"
  ln -sf "$BIN_DIR/agent-eventsd"  "$HOME/.steez/bin/agent-eventsd"
  ln -sf "$BIN_DIR/agent-history"  "$HOME/.steez/bin/agent-history"

  TMUX_SOCK="steez-eventsd-${RUNTIME_TMP##*/}"
  TEST_BIN="$RUNTIME_TMP/bin"
  mkdir -p "$TEST_BIN"
  cp "$FAKES_BUILD/claude"  "$TEST_BIN/claude"
  cp "$FAKES_BUILD/impl.sh" "$TEST_BIN/impl.sh"
  cp "$FAKES_BUILD/ren"     "$TEST_BIN/ren"
  chmod +x "$TEST_BIN/claude" "$TEST_BIN/impl.sh" "$TEST_BIN/ren"

  cat > "$TEST_BIN/tmux" <<EOF
#!/bin/bash
exec "$REAL_TMUX" -L "$TMUX_SOCK" "\$@"
EOF
  chmod +x "$TEST_BIN/tmux"

  unset REN_SESSION
  SHELL=/bin/bash PATH="$TEST_BIN:$PATH" \
    "$REAL_TMUX" -L "$TMUX_SOCK" -f /dev/null \
    new-session -d -s test -x 200 -y 50
  # Capture pane 0's canonical %N. `test:0` resolves to the active pane,
  # which flips to %1 after the first split — every subsequent send-keys
  # target would land in the fake instead of the test shell.
  PANE0=$("$REAL_TMUX" -L "$TMUX_SOCK" display-message -t test:0.0 -p '#{pane_id}')
}

cleanup_runtime() {
  # Kill the long-lived agent-eventsd service (if any) before the state
  # dir is scrubbed so it cannot keep polling a disappearing tree.
  local pidf="$STEEZ_STATE_DIR/eventsd/eventsd.pid"
  if [[ -f "$pidf" ]]; then
    local pid
    pid=$(cat "$pidf" 2>/dev/null || true)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  fi
  "$REAL_TMUX" -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -rf "$RUNTIME_TMP"
}

# Run spawn.sh inside pane 0 and capture TARGET=%N to $1.
run_spawn_into() {
  local __var="$1"; local model="$2"
  # Do NOT shadow the caller's output variable name with a local of the
  # same name — printf -v would write to the local, not the caller.
  local out done_file cmd _pane
  out="$RUNTIME_TMP/spawn-${__var}.out"
  done_file="$RUNTIME_TMP/spawn-${__var}.done"
  : > "$out"
  rm -f "$done_file"
  cmd="PATH='$TEST_BIN':\$PATH HOME='$HOME' STEEZ_STATE_DIR='$STEEZ_STATE_DIR' '$SPAWN_SCRIPT' split-h --target $PANE0 --model $model > '$out' 2>&1; touch '$done_file'"
  "$REAL_TMUX" -L "$TMUX_SOCK" send-keys -t "$PANE0" "$cmd" Enter
  local i
  for i in $(seq 1 120); do
    [[ -f "$done_file" ]] && break
    sleep 0.5
  done
  [[ -f "$done_file" ]] || {
    echo "    spawn.sh never finished; output so far:"
    sed 's/^/      /' "$out"
    exit 1
  }
  _pane=$(grep -o 'TARGET=%[0-9]*' "$out" | head -1 | cut -d= -f2)
  [[ -n "$_pane" ]] || {
    echo "    no TARGET line in spawn output:"
    sed 's/^/      /' "$out"
    exit 1
  }
  printf -v "$__var" '%s' "$_pane"
}

wait_pane_var() {
  local pane="$1" var="$2" timeout_ticks="${3:-25}"
  local i val
  for ((i=0; i<timeout_ticks; i++)); do
    val=$("$REAL_TMUX" -L "$TMUX_SOCK" show-options -pv -t "$pane" "$var" 2>/dev/null) || val=""
    [[ -n "$val" ]] && { printf '%s' "$val"; return 0; }
    sleep 0.2
  done
  return 1
}

run_bin() {
  PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    "$BIN_DIR/$1" "${@:2}"
}

suite "agent-eventsd runtime: watched prompt end-to-end"

# Acceptance #4 (fake-agent-harness spec): "In the idle scenario,
# agent-send <pane> <msg> followed by a fifo transition causes exactly one
# delivery against the spawner pane, and the watch self-clears. Tests
# assert this through the public surface (agent-watch list, spawner-pane
# output, or both), not by reading files under $STEEZ_STATE_DIR/eventsd/."
#
# The fake claude's auto-reply path flips the transcript to idle on the
# first line it reads, so no fifo is needed for this slice.
test_watched_prompt_against_fake_claude_fires_exactly_one_idle_notification_and_watch_self_clears() {
  setup_runtime
  trap cleanup_runtime EXIT

  # Two fake claude panes: target is the watched pane, spawner receives
  # the notification. agent-deliver rejects non-agent panes with exit 2,
  # so the spawner must be a recognized AI agent pane.
  local target spawner
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  local target_transcript spawner_transcript
  target_transcript=$(wait_pane_var "$target"  @transcript_path 25) || { echo "    target @transcript_path never set"; exit 1; }
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }
  [[ -f "$target_transcript"  ]] || { echo "    target transcript missing: $target_transcript"; exit 1; }
  [[ -f "$spawner_transcript" ]] || { echo "    spawner transcript missing: $spawner_transcript"; exit 1; }

  # Drive the real two-step turn via agent-send with an explicit spawner.
  # The test runs outside tmux, so TMUX_PANE is empty and --spawner is
  # required. Tight silence/reconcile windows make the service pick up
  # the idle transition within the test timeout without touching the
  # production defaults.
  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    SILENCE_WINDOW_MS=0 RECONCILE_INTERVAL_MS=100 EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "hello" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  # The fake auto-reply writes a user prompt entry and an idle-terminating
  # assistant entry to the target transcript (two JSONL lines). Poll the
  # transcript directly — do not wait on watch notifications here, because
  # the whole point of this test is whether they fire at all.
  local i lines
  for ((i=0; i<100; i++)); do
    lines=$(wc -l < "$target_transcript" 2>/dev/null | tr -d ' ')
    [[ "${lines:-0}" -ge 2 ]] && break
    sleep 0.1
  done
  lines=$(wc -l < "$target_transcript" 2>/dev/null | tr -d ' ')
  [[ "${lines:-0}" -ge 2 ]] || {
    echo "    fake target never flipped to idle (transcript lines=$lines):"
    sed 's/^/      /' "$target_transcript"
    exit 1
  }

  # Poll the spawner transcript for exactly one delivered prompt entry.
  # Each fake-claude prompt append writes one {"type":"user",...} line.
  local sp_lines=0
  for ((i=0; i<200; i++)); do
    sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
    [[ "${sp_lines:-0}" -ge 1 ]] && break
    sleep 0.1
  done
  sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${sp_lines:-0}" -ge 1 ]] || {
    echo "    spawner never received a notification (grep user=$sp_lines):"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }

  # Poll agent-watch list until the live slot is freed. The watch must
  # self-clear once the daemon delivers the notification.
  local list=""
  for ((i=0; i<200; i++)); do
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "$list" == "(no active watches)" ]] && break
    sleep 0.1
  done
  [[ "$list" == "(no active watches)" ]] || {
    echo "    watch did not self-clear (agent-watch list output):"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }

  # Settle and confirm the notification was delivered exactly once —
  # no duplicate fires from retries, buffered evidence, or a second tick.
  sleep 1
  sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${sp_lines:-0}" -eq 1 ]] || {
    echo "    expected exactly 1 delivery to spawner, saw $sp_lines:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
}
run_test "watched prompt against fake claude fires exactly one idle notification and watch self-clears" \
  test_watched_prompt_against_fake_claude_fires_exactly_one_idle_notification_and_watch_self_clears

# Acceptance #5 (fake-agent-harness spec): "In the no-watch scenario,
# agent-send --no-watch delivers bytes to the fake, creates no watch
# visible via agent-watch list, and produces no delivery against the
# spawner pane."
test_no_watch_against_fake_claude_delivers_to_target_without_live_watch_or_spawner_notification() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  local target_transcript spawner_transcript
  target_transcript=$(wait_pane_var "$target"  @transcript_path 25) || { echo "    target @transcript_path never set"; exit 1; }
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }
  [[ -f "$target_transcript"  ]] || { echo "    target transcript missing: $target_transcript"; exit 1; }
  [[ -f "$spawner_transcript" ]] || { echo "    spawner transcript missing: $spawner_transcript"; exit 1; }

  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    SILENCE_WINDOW_MS=0 RECONCILE_INTERVAL_MS=100 EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --no-watch --spawner "$spawner" "$target" "hello-no-watch" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send --no-watch failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  local i lines
  for ((i=0; i<100; i++)); do
    lines=$(wc -l < "$target_transcript" 2>/dev/null | tr -d ' ')
    [[ "${lines:-0}" -ge 2 ]] && break
    sleep 0.1
  done
  lines=$(wc -l < "$target_transcript" 2>/dev/null | tr -d ' ')
  [[ "${lines:-0}" -ge 2 ]] || {
    echo "    fake target never handled --no-watch delivery (transcript lines=$lines):"
    sed 's/^/      /' "$target_transcript"
    exit 1
  }

  grep -F 'hello-no-watch' "$target_transcript" >/dev/null 2>&1 || {
    echo "    target transcript never received the delivered bytes:"
    sed 's/^/      /' "$target_transcript"
    exit 1
  }

  local list
  list=$(run_bin agent-watch list 2>/dev/null || true)
  [[ "$list" == "(no active watches)" ]] || {
    echo "    expected no live watch after --no-watch, saw:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }

  sleep 1
  local sp_lines
  sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${sp_lines:-0}" -eq 0 ]] || {
    echo "    expected no spawner notification after --no-watch, saw $sp_lines:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
}
run_test "--no-watch against fake claude delivers to target without live watch or spawner notification" \
  test_no_watch_against_fake_claude_delivers_to_target_without_live_watch_or_spawner_notification

report
