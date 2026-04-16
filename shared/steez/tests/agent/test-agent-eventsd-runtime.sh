#!/usr/bin/env bash
# End-to-end runtime tests for agent-eventsd against the zero-token fake
# claude harness.
#
# This file drives the real watch service — no stubs, no in-process library
# sourcing. A watched prompt from agent-send against a fake claude pane must
# produce exactly one attention notification on the spawner pane and the watch
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
cp "$FAKES_BUILD/claude"          "$FAKES_BUILD/codex"
cp "$FAKES_SRC_DIR/claude.impl.sh" "$FAKES_BUILD/impl.sh"
cp "$FAKES_SRC_DIR/ren"            "$FAKES_BUILD/ren"
cp "$FAKES_SRC_DIR/ren-codex"      "$FAKES_BUILD/ren-codex"
chmod +x "$FAKES_BUILD/claude" "$FAKES_BUILD/codex" "$FAKES_BUILD/impl.sh" "$FAKES_BUILD/ren" "$FAKES_BUILD/ren-codex"

setup_runtime() {
  RUNTIME_TMP=$(mktemp -d)
  export HOME="$RUNTIME_TMP/home"
  export STEEZ_STATE_DIR="$RUNTIME_TMP/state"
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.steez/bin" "$HOME/.steez/agent-state/claude" "$STEEZ_STATE_DIR/eventsd"

  # Real agent-eventsd, agent-state, agent-deliver, agent-send, agent-watch,
  # agent-history — the service must drive real binaries end-to-end. The
  # only replaced component is the agent process itself (fake agent).
  ln -sf "$BIN_DIR/agent-state"    "$HOME/.steez/bin/agent-state"
  ln -sf "$BIN_DIR/agent-deliver"  "$HOME/.steez/bin/agent-deliver"
  ln -sf "$BIN_DIR/agent-eventsd"  "$HOME/.steez/bin/agent-eventsd"
  ln -sf "$BIN_DIR/agent-history"  "$HOME/.steez/bin/agent-history"

  TMUX_SOCK="steez-eventsd-${RUNTIME_TMP##*/}"
  TEST_BIN="$RUNTIME_TMP/bin"
  mkdir -p "$TEST_BIN"
  cp "$FAKES_BUILD/claude"  "$TEST_BIN/claude"
  cp "$FAKES_BUILD/codex"   "$TEST_BIN/codex"
  cp "$FAKES_BUILD/impl.sh" "$TEST_BIN/impl.sh"
  cp "$FAKES_BUILD/ren"     "$TEST_BIN/ren"
  cp "$FAKES_BUILD/ren-codex" "$TEST_BIN/ren-codex"
  chmod +x "$TEST_BIN/claude" "$TEST_BIN/codex" "$TEST_BIN/impl.sh" "$TEST_BIN/ren" "$TEST_BIN/ren-codex"

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
# attention delivery against the spawner pane, and the watch self-clears.
# Tests assert this through the public surface (agent-watch list,
# spawner-pane output, or both), not by reading files under
# $STEEZ_STATE_DIR/eventsd/."
#
# The fake claude's auto-reply path flips the transcript to idle on the
# first line it reads, so no fifo is needed for this slice.
test_watched_prompt_against_fake_claude_fires_exactly_one_attention_notification_and_watch_self_clears() {
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
    echo "    spawner never received an attention ping (grep user=$sp_lines):"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }

  grep -F "[agent-watch] $target (claude) attention" "$spawner_transcript" >/dev/null 2>&1 || {
    echo "    spawner notification was not generic attention:"
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
run_test "watched prompt against fake claude fires exactly one attention notification and watch self-clears" \
  test_watched_prompt_against_fake_claude_fires_exactly_one_attention_notification_and_watch_self_clears

run_watched_idle_turn_for_model() (
  local model="$1"
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner
  run_spawn_into target "$model"
  run_spawn_into spawner "$model"
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  local state_json
  state_json=$(run_bin agent-state "$target" 2>/dev/null || true)
  printf '%s' "$state_json" | jq -e --arg agent "$model" '.agent == $agent and .state == "idle"' >/dev/null || {
    echo "    target did not boot as idle $model:"
    printf '%s\n' "$state_json" | sed 's/^/      /'
    exit 1
  }
  state_json=$(run_bin agent-state "$spawner" 2>/dev/null || true)
  printf '%s' "$state_json" | jq -e --arg agent "$model" '.agent == $agent and .state == "idle"' >/dev/null || {
    echo "    spawner did not boot as idle $model:"
    printf '%s\n' "$state_json" | sed 's/^/      /'
    exit 1
  }

  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR"     SILENCE_WINDOW_MS=0 RECONCILE_INTERVAL_MS=100 EVENTSD_TICK_INTERVAL_SEC=0.1     "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "hello-$model" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed for $model (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  local i target_last spawner_history list
  target_last=""
  for ((i=0; i<200; i++)); do
    target_last=$(run_bin agent-history "$target" --last 2>/dev/null || true)
    if printf '%s' "$target_last" | jq -e --arg agent "$model" --arg prompt "hello-$model" '.agent == $agent and .prompt == $prompt and .response == "ok"' >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  printf '%s' "$target_last" | jq -e --arg agent "$model" --arg prompt "hello-$model" '.agent == $agent and .prompt == $prompt and .response == "ok"' >/dev/null || {
    echo "    target never completed an idle turn for $model:"
    printf '%s\n' "$target_last" | sed 's/^/      /'
    exit 1
  }

  spawner_history=""
  for ((i=0; i<200; i++)); do
    spawner_history=$(run_bin agent-history "$spawner" --history 10 2>/dev/null || true)
    if printf '%s' "$spawner_history" | jq -e --arg agent "$model" --arg target "$target" '.agent == $agent and (.pairs | length) >= 1 and .pairs[-1].prompt == ("[agent-watch] " + $target + " (" + $agent + ") attention") and .pairs[-1].response == "ok"' >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  printf '%s' "$spawner_history" | jq -e --arg agent "$model" --arg target "$target" '.agent == $agent and (.pairs | length) >= 1 and .pairs[-1].prompt == ("[agent-watch] " + $target + " (" + $agent + ") attention") and .pairs[-1].response == "ok"' >/dev/null || {
    echo "    spawner never received the watched attention ping for $model:"
    printf '%s\n' "$spawner_history" | sed 's/^/      /'
    exit 1
  }

  list=""
  for ((i=0; i<200; i++)); do
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "$list" == "(no active watches)" ]] && break
    sleep 0.1
  done
  [[ "$list" == "(no active watches)" ]] || {
    echo "    watch did not self-clear for $model:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }

  sleep 1
  spawner_history=$(run_bin agent-history "$spawner" --history 10 2>/dev/null || true)
  printf '%s' "$spawner_history" | jq -e --arg agent "$model" --arg target "$target" '.agent == $agent and (.pairs | length) == 1 and .pairs[0].prompt == ("[agent-watch] " + $target + " (" + $agent + ") attention") and .pairs[0].response == "ok"' >/dev/null || {
    echo "    expected exactly one watched attention ping for $model:"
    printf '%s\n' "$spawner_history" | sed 's/^/      /'
    exit 1
  }
)

test_watched_prompt_against_fake_codex_and_ren_variants_fires_exactly_one_attention_notification_and_watch_self_clears() {
  local model
  for model in codex ren-codex ren; do
    run_watched_idle_turn_for_model "$model" || exit 1
  done
}
run_test "watched prompt against fake codex, ren-codex, and ren fires exactly one attention notification and watch self-clears" \
  test_watched_prompt_against_fake_codex_and_ren_variants_fires_exactly_one_attention_notification_and_watch_self_clears

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

write_fifo_line() {
  local fifo="$1" line="$2"
  python3 - "$fifo" "$line" <<'PYEOF'
import errno
import os
import sys
import time

fifo, line = sys.argv[1:]
deadline = time.time() + 3.0
while time.time() < deadline:
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        if exc.errno in (errno.ENXIO, errno.ENOENT):
            time.sleep(0.05)
            continue
        raise
    with os.fdopen(fd, "w", encoding="utf-8", buffering=1) as fh:
        fh.write(line + "\n")
    raise SystemExit(0)
raise SystemExit(1)
PYEOF
}

test_blocked_question_against_fake_claude_resolves_and_agent_history_returns_prompt_text() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner ctl_dir ctl_path
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  ctl_dir="$STEEZ_STATE_DIR/fakes/ctl"
  ctl_path="$ctl_dir/$target"
  mkdir -p "$ctl_dir"
  mkfifo "$ctl_path"

  local target_transcript spawner_transcript
  target_transcript=$(wait_pane_var "$target"  @transcript_path 25) || { echo "    target @transcript_path never set"; exit 1; }
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }

  local send_rc=0 send_out question
  question="Which repo should I use?"
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    SILENCE_WINDOW_MS=0 RECONCILE_INTERVAL_MS=100 EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "help me choose" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  write_fifo_line "$ctl_path" "state blocked:question $question" || {
    echo "    fake control fifo never accepted blocked:question"
    exit 1
  }

  local i hist_json state_json list sp_lines
  hist_json=""
  for ((i=0; i<100; i++)); do
    hist_json=$(run_bin agent-history "$target" --blocked 2>/dev/null || true)
    if printf '%s' "$hist_json" | jq -e --arg q "$question" '.tool == "AskUserQuestion" and .question == $q' >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  printf '%s' "$hist_json" | jq -e --arg q "$question" '.tool == "AskUserQuestion" and .question == $q' >/dev/null || {
    echo "    agent-history --blocked never returned the question text:"
    printf '%s\n' "$hist_json" | sed 's/^/      /'
    exit 1
  }

  state_json=""
  for ((i=0; i<100; i++)); do
    state_json=$(run_bin agent-state "$target" 2>/dev/null || true)
    if printf '%s' "$state_json" | jq -e '.state == "blocked:question"' >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  printf '%s' "$state_json" | jq -e '.state == "blocked:question"' >/dev/null || {
    echo "    agent-state never reported blocked:question:"
    printf '%s\n' "$state_json" | sed 's/^/      /'
    exit 1
  }

  list=""
  for ((i=0; i<200; i++)); do
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "$list" == "(no active watches)" ]] && break
    sleep 0.1
  done
  [[ "$list" == "(no active watches)" ]] || {
    echo "    watch did not self-clear after blocked:question:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }

  for ((i=0; i<200; i++)); do
    sp_lines=$({ grep -Ec "\\[agent-watch\\] $target \\(claude\\) attention" "$spawner_transcript" 2>/dev/null; } || true)
    [[ "${sp_lines:-0}" -ge 1 ]] && break
    sleep 0.1
  done
  sp_lines=$({ grep -Ec "\\[agent-watch\\] $target \\(claude\\) attention" "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${sp_lines:-0}" -eq 1 ]] || {
    echo "    expected exactly one attention ping, saw $sp_lines:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
}
run_test "blocked:question against fake claude resolves and agent-history returns the question text" \
  test_blocked_question_against_fake_claude_resolves_and_agent_history_returns_prompt_text

test_second_prompt_supersedes_first_unresolved_live_watch_without_duplicate_delivery() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner ctl_dir ctl_path
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  ctl_dir="$STEEZ_STATE_DIR/fakes/ctl"
  ctl_path="$ctl_dir/$target"
  mkdir -p "$ctl_dir"
  mkfifo "$ctl_path"

  local target_transcript spawner_transcript
  target_transcript=$(wait_pane_var "$target"  @transcript_path 25) || { echo "    target @transcript_path never set"; exit 1; }
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }

  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    SILENCE_WINDOW_MS=0 RECONCILE_INTERVAL_MS=100 EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "first-live" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    first agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  write_fifo_line "$ctl_path" "state working" || {
    echo "    fake control fifo never accepted state working"
    exit 1
  }

  local i records first_watch second_watch first_state list sp_lines
  for ((i=0; i<100; i++)); do
    grep -F '"tool_use"' "$target_transcript" >/dev/null 2>&1 && break
    sleep 0.1
  done
  grep -F '"tool_use"' "$target_transcript" >/dev/null 2>&1 || {
    echo "    first turn never entered unresolved working state:"
    sed 's/^/      /' "$target_transcript"
    exit 1
  }

  records=""
  first_watch=""
  for ((i=0; i<100; i++)); do
    records=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
      "$HOME/.steez/bin/agent-eventsd" list 2>/dev/null || true)
    first_watch=$(printf '%s\n' "$records" | jq -r --arg pane "$target" '
      select(.pane_id == $pane and .state == "armed") | .watch_id
    ' | head -1)
    [[ -n "$first_watch" ]] && break
    sleep 0.1
  done
  [[ -n "$first_watch" ]] || {
    echo "    never found the first live watch:"
    printf '%s\n' "$records" | sed 's/^/      /'
    exit 1
  }

  send_rc=0
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    SILENCE_WINDOW_MS=0 RECONCILE_INTERVAL_MS=100 EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "second-wins" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    second agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  records=""
  first_state=""
  second_watch=""
  for ((i=0; i<100; i++)); do
    records=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
      "$HOME/.steez/bin/agent-eventsd" list 2>/dev/null || true)
    first_state=$(printf '%s\n' "$records" | jq -r --arg wid "$first_watch" '
      select(.watch_id == $wid) | "\(.state):\(.close_reason // "")"
    ' | head -1)
    second_watch=$(printf '%s\n' "$records" | jq -r --arg pane "$target" --arg first "$first_watch" '
      select(.pane_id == $pane and .watch_id != $first and .state == "armed") | .watch_id
    ' | head -1)
    [[ "$first_state" == "closed:superseded" && -n "$second_watch" ]] && break
    sleep 0.1
  done
  [[ "$first_state" == "closed:superseded" ]] || {
    echo "    first live watch was not superseded:"
    printf '%s\n' "$records" | sed 's/^/      /'
    exit 1
  }
  [[ -n "$second_watch" ]] || {
    echo "    second watch never armed cleanly:"
    printf '%s\n' "$records" | sed 's/^/      /'
    exit 1
  }

  for ((i=0; i<100; i++)); do
    grep -F 'second-wins' "$target_transcript" >/dev/null 2>&1 && break
    sleep 0.1
  done
  grep -F 'second-wins' "$target_transcript" >/dev/null 2>&1 || {
    echo "    second prompt never reached the target transcript:"
    sed 's/^/      /' "$target_transcript"
    exit 1
  }

  write_fifo_line "$ctl_path" "state idle second-ok" || {
    echo "    fake control fifo never accepted second state idle"
    exit 1
  }

  list=""
  sp_lines=0
  for ((i=0; i<200; i++)); do
    sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "${sp_lines:-0}" -ge 1 && "$list" == "(no active watches)" ]] && break
    sleep 0.1
  done

  sleep 1
  sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${sp_lines:-0}" -eq 1 ]] || {
    echo "    expected exactly 1 spawner delivery after supersede, saw $sp_lines:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
  grep -F "[agent-watch] $target (claude) attention" "$spawner_transcript" >/dev/null 2>&1 || {
    echo "    spawner notification was not generic attention:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
  [[ "$list" == "(no active watches)" ]] || {
    echo "    watch did not self-clear after the second prompt:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }
}
run_test "second prompt supersedes the first live watch without duplicate delivery" \
  test_second_prompt_supersedes_first_unresolved_live_watch_without_duplicate_delivery

test_loss_of_fast_evidence_degrades_through_agent_state_and_times_out_to_blocked_unknown() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner ctl_dir ctl_path
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  ctl_dir="$STEEZ_STATE_DIR/fakes/ctl"
  ctl_path="$ctl_dir/$target"
  mkdir -p "$ctl_dir"
  mkfifo "$ctl_path"

  local target_transcript spawner_transcript
  target_transcript=$(wait_pane_var "$target"  @transcript_path 25) || { echo "    target @transcript_path never set"; exit 1; }
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }

  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    SILENCE_WINDOW_MS=150 RECONCILE_INTERVAL_MS=100 INDETERMINATE_TIMEOUT_MS=350 EVENTSD_TICK_INTERVAL_SEC=0.05 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "degrade-me" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  write_fifo_line "$ctl_path" "state working" || {
    echo "    fake control fifo never accepted state working"
    exit 1
  }

  local i state_json records wid watch_path degraded_since last_reconcile list blocked_lines
  for ((i=0; i<100; i++)); do
    state_json=$(run_bin agent-state "$target" 2>/dev/null || true)
    if printf '%s' "$state_json" | jq -e '.state == "working"' >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  printf '%s' "$state_json" | jq -e '.state == "working"' >/dev/null || {
    echo "    agent-state never reported working for the live turn:"
    printf '%s\n' "$state_json" | sed 's/^/      /'
    exit 1
  }

  wid=""
  for ((i=0; i<100; i++)); do
    records=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
      "$HOME/.steez/bin/agent-eventsd" list 2>/dev/null || true)
    wid=$(printf '%s\n' "$records" | jq -r --arg pane "$target" '
      select(.pane_id == $pane and .state == "armed") | .watch_id
    ' | head -1)
    [[ -n "$wid" ]] && break
    sleep 0.1
  done
  [[ -n "$wid" ]] || {
    echo "    never found the live watch for the degraded test:"
    printf '%s\n' "$records" | sed 's/^/      /'
    exit 1
  }

  watch_path="$STEEZ_STATE_DIR/eventsd/watches/$wid.json"
  for ((i=0; i<100; i++)); do
    [[ -f "$watch_path" ]] || { sleep 0.1; continue; }
    degraded_since=$(jq -r '.degraded_since_ms // 0' "$watch_path" 2>/dev/null || echo 0)
    last_reconcile=$(jq -r '.last_reconcile_ms // 0' "$watch_path" 2>/dev/null || echo 0)
    if [[ "${degraded_since:-0}" != "0" && "${last_reconcile:-0}" != "0" ]]; then
      break
    fi
    sleep 0.1
  done
  [[ -f "$watch_path" ]] || { echo "    watch record missing: $watch_path"; exit 1; }
  degraded_since=$(jq -r '.degraded_since_ms // 0' "$watch_path" 2>/dev/null || echo 0)
  last_reconcile=$(jq -r '.last_reconcile_ms // 0' "$watch_path" 2>/dev/null || echo 0)
  [[ "${degraded_since:-0}" != "0" ]] || {
    echo "    watch never entered degraded mode:"
    sed 's/^/      /' "$watch_path"
    exit 1
  }
  [[ "${last_reconcile:-0}" != "0" ]] || {
    echo "    degraded watch never reconciled through agent-state:"
    sed 's/^/      /' "$watch_path"
    exit 1
  }

  list=""
  blocked_lines=0
  for ((i=0; i<200; i++)); do
    blocked_lines=$({ grep -Ec "\\[agent-watch\\] $target \\(claude\\) attention" "$spawner_transcript" 2>/dev/null; } || true)
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "${blocked_lines:-0}" -ge 1 && "$list" == "(no active watches)" ]] && break
    sleep 0.1
  done

  sleep 1
  blocked_lines=$({ grep -Ec "\\[agent-watch\\] $target \\(claude\\) attention" "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${blocked_lines:-0}" -eq 1 ]] || {
    echo "    expected exactly 1 attention ping, saw $blocked_lines:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
  [[ "$list" == "(no active watches)" ]] || {
    echo "    degraded watch did not self-clear after blocked:unknown timeout:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }

  if grep -F '"stop_reason":"end_turn"' "$target_transcript" >/dev/null 2>&1; then
    echo "    target reached idle instead of timing out through degraded reconcile:"
    sed 's/^/      /' "$target_transcript"
    exit 1
  fi
}
run_test "loss of fast evidence degrades through agent-state and times out to blocked:unknown" \
  test_loss_of_fast_evidence_degrades_through_agent_state_and_times_out_to_blocked_unknown


# Acceptance #9 (fake-agent-harness spec): "In the pane close scenario,
# exiting the fake while a watch is live causes the watch to close per the
# pane-close rules, and agent-watch list no longer shows it as live."
# This slice pins the armed-watch path: the fake agent exits mid-turn, the
# daemon treats the watched pane like a pane-close event, falls back to
# blocked:unknown, notifies the spawner once, and frees the live slot.
test_fake_claude_exit_while_watched_resolves_blocked_unknown_and_clears_live_watch() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner ctl_dir ctl_path
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  ctl_dir="$STEEZ_STATE_DIR/fakes/ctl"
  ctl_path="$ctl_dir/$target"
  mkdir -p "$ctl_dir"
  mkfifo "$ctl_path"

  local spawner_transcript
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }
  [[ -f "$spawner_transcript" ]] || { echo "    spawner transcript missing: $spawner_transcript"; exit 1; }

  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    EVENTSD_TICK_INTERVAL_SEC=0.05 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "exit-mid-turn" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  local i list agent_gone blocked_lines
  list=""
  for ((i=0; i<100; i++)); do
    list=$(run_bin agent-watch list 2>/dev/null || true)
    printf '%s\n' "$list" | grep -F "$target" >/dev/null 2>&1 && break
    sleep 0.1
  done
  printf '%s\n' "$list" | grep -F "$target" >/dev/null 2>&1 || {
    echo "    target never appeared as a live watch before exit:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }

  write_fifo_line "$ctl_path" "exit" || {
    echo "    fake control fifo never accepted exit"
    exit 1
  }

  agent_gone=0
  for ((i=0; i<100; i++)); do
    if ! run_bin agent-state "$target" >/dev/null 2>&1; then
      agent_gone=1
      break
    fi
    sleep 0.1
  done
  [[ "$agent_gone" -eq 1 ]] || {
    echo "    fake target never stopped being a recognized agent after control fifo exit"
    exit 1
  }

  list=""
  blocked_lines=0
  for ((i=0; i<200; i++)); do
    blocked_lines=$({ grep -Ec "\\[agent-watch\\] $target \\(claude\\) attention" "$spawner_transcript" 2>/dev/null; } || true)
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "${blocked_lines:-0}" -ge 1 && "$list" == "(no active watches)" ]] && break
    sleep 0.1
  done

  sleep 1
  blocked_lines=$({ grep -Ec "\\[agent-watch\\] $target \\(claude\\) attention" "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${blocked_lines:-0}" -eq 1 ]] || {
    echo "    expected exactly 1 attention ping after pane close, saw $blocked_lines:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
  [[ "$list" == "(no active watches)" ]] || {
    echo "    pane-close left a stray live watch:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }
}
run_test "fake claude exit while watched resolves blocked:unknown and clears the live watch" \
  test_fake_claude_exit_while_watched_resolves_blocked_unknown_and_clears_live_watch

# Fast-path external evidence: hooks (and other external callers) feed
# fresh evidence into a live watch via `agent-eventsd evidence`. The CLI
# must look up the pane's live watch, assign a monotonic seq, route through
# the canonical resolver, and exit fire-and-forget. End-to-end, a fresh
# terminal state shelled through this command must resolve the armed watch
# and fire exactly one delivery on the spawner — without touching the
# degraded fallback timers.
test_evidence_cli_on_armed_watch_fires_delivery_on_spawner_and_clears_live_watch() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  local spawner_transcript
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }
  [[ -f "$spawner_transcript" ]] || { echo "    spawner transcript missing: $spawner_transcript"; exit 1; }

  # Drive the two-step turn directly through the agent-eventsd CLI. The
  # default SILENCE_WINDOW_MS (30s) keeps the degraded path from engaging
  # during the test — only the evidence CLI can resolve this watch.
  local wid
  wid=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-eventsd" prearm --pane "$target" --spawner "$spawner" \
      --label test --baseline-state working \
      --prearm-screen-hash baseline-hash --prearm-transcript-cursor 0 2>/dev/null) || {
    echo "    agent-eventsd prearm failed"
    exit 1
  }
  [[ -n "$wid" ]] || { echo "    prearm did not return watch_id"; exit 1; }

  PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    "$BIN_DIR/agent-eventsd" start --pane "$target" --watch-id "$wid" || {
    echo "    agent-eventsd start failed"
    exit 1
  }

  # Capture the prearm cursor from the public `list` surface — not from a
  # direct read under $STEEZ_STATE_DIR/eventsd/.
  local records prearm_cursor
  records=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    "$BIN_DIR/agent-eventsd" list 2>/dev/null || true)
  prearm_cursor=$(printf '%s\n' "$records" | jq -r --arg wid "$wid" \
    'select(.watch_id == $wid) | .prearm_transcript_cursor' | head -1)
  [[ -n "$prearm_cursor" && "$prearm_cursor" != "null" ]] || {
    echo "    agent-eventsd list never returned prearm_transcript_cursor for $wid:"
    printf '%s\n' "$records" | sed 's/^/      /'
    exit 1
  }

  # Shell fresh evidence: cursor advances past prearm, state idle differs
  # from baseline working → resolver fires → delivery lands on spawner.
  local ev_rc=0 ev_out
  ev_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    "$BIN_DIR/agent-eventsd" evidence --pane "$target" --state idle \
      --transcript-cursor $((prearm_cursor + 100)) 2>&1) || ev_rc=$?
  [[ "$ev_rc" -eq 0 ]] || {
    echo "    agent-eventsd evidence failed (rc=$ev_rc):"
    printf '%s\n' "$ev_out" | sed 's/^/      /'
    exit 1
  }

  # Poll spawner-pane output (public surface) for the delivery.
  local i sp_lines list
  sp_lines=0
  for ((i=0; i<200; i++)); do
    sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
    [[ "${sp_lines:-0}" -ge 1 ]] && break
    sleep 0.1
  done
  [[ "${sp_lines:-0}" -ge 1 ]] || {
    echo "    evidence CLI never fired a delivery on spawner:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }

  # Live watch must self-clear once delivery completes.
  list=""
  for ((i=0; i<200; i++)); do
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "$list" == "(no active watches)" ]] && break
    sleep 0.1
  done
  [[ "$list" == "(no active watches)" ]] || {
    echo "    watch did not self-clear after evidence CLI:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }

  # Settle and confirm no second tick or retry duplicated the delivery, and
  # that the notification stayed collapsed to generic attention.
  sleep 1
  sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
  [[ "${sp_lines:-0}" -eq 1 ]] || {
    echo "    expected exactly 1 evidence-triggered delivery, saw $sp_lines:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
  grep -F "[agent-watch] $target (test) attention" "$spawner_transcript" >/dev/null 2>&1 || {
    echo "    spawner notification was not generic attention:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
}
run_test "evidence CLI on armed watch fires delivery on spawner and clears the live watch" \
  test_evidence_cli_on_armed_watch_fires_delivery_on_spawner_and_clears_live_watch

# Production hook path: real Claude invokes `permission-state.sh` as a
# `Stop` hook at turn-end. The hook must translate that into
# `agent-eventsd evidence --state idle` so the armed watch resolves via
# the fast path, not the 30s degraded fallback.
#
# This test rides on top of the fake-harness evidence path shipped in
# steez-s4t: steez-s4t proves the fake can fire evidence via its fifo
# handler. This test proves the PRODUCTION hook path is what real Claude
# would call. Default `SILENCE_WINDOW_MS` (30000) keeps degraded fallback
# outside the 2s budget — so fast delivery requires the hook calling the
# evidence CLI. No fifo is created, so the fake auto-replies silently
# (transcript append only, no fire_evidence). Only the hook can drive
# resolution inside the budget.
now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

test_claude_stop_hook_fires_evidence_and_notification_arrives_within_2s() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner
  run_spawn_into target  claude
  run_spawn_into spawner claude
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  local target_transcript spawner_transcript target_session_id
  target_transcript=$(wait_pane_var "$target"  @transcript_path 25) || { echo "    target @transcript_path never set"; exit 1; }
  spawner_transcript=$(wait_pane_var "$spawner" @transcript_path 25) || { echo "    spawner @transcript_path never set"; exit 1; }
  target_session_id=$(wait_pane_var "$target"  @session_id 25)       || { echo "    target @session_id never set"; exit 1; }
  [[ -f "$target_transcript"  ]] || { echo "    target transcript missing: $target_transcript"; exit 1; }
  [[ -f "$spawner_transcript" ]] || { echo "    spawner transcript missing: $spawner_transcript"; exit 1; }

  # Default SILENCE_WINDOW_MS (30000), default RECONCILE_INTERVAL_MS
  # (5000). Degraded fallback cannot rescue this watch inside the 2s
  # budget — only the hook can.
  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "hook-me" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  # Wait for the fake's auto-reply to append the idle line. Without this
  # the hook's cursor might still equal prearm and fail freshness.
  local i lines
  for ((i=0; i<100; i++)); do
    lines=$(wc -l < "$target_transcript" 2>/dev/null | tr -d ' ')
    [[ "${lines:-0}" -ge 2 ]] && break
    sleep 0.1
  done
  lines=$(wc -l < "$target_transcript" 2>/dev/null | tr -d ' ')
  [[ "${lines:-0}" -ge 2 ]] || {
    echo "    fake target never auto-replied (transcript lines=$lines):"
    sed 's/^/      /' "$target_transcript"
    exit 1
  }

  # Fire the Stop hook exactly as real Claude would: pipe the payload on
  # stdin, with TMUX_PANE pointing at the target pane. The hook uses
  # $HOME/.steez/bin/agent-eventsd which setup_runtime already symlinks
  # to the real binary. t0 is wall-clock just before dispatch.
  local hook_payload t0 t1 elapsed deadline sp_lines list
  hook_payload=$(jq -n \
    --arg sid "$target_session_id" \
    --arg tp "$target_transcript" \
    '{session_id:$sid,transcript_path:$tp,hook_event_name:"Stop",cwd:"/tmp"}')

  t0=$(now_ms)
  TMUX_PANE="$target" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    PATH="$TEST_BIN:$PATH" \
    bash "$REPO_ROOT/shared/steez/hooks/permission-state.sh" <<<"$hook_payload" || {
      echo "    permission-state.sh hook invocation failed"
      exit 1
    }

  # Poll <= 2s for delivery. Deadline budget is 4s so a slow-but-present
  # resolution still reports elapsed-ms rather than a silent timeout.
  deadline=$(( t0 + 4000 ))
  sp_lines=0
  list=""
  while :; do
    sp_lines=$({ grep -Ec '"type":\s*"user"' "$spawner_transcript" 2>/dev/null; } || true)
    list=$(run_bin agent-watch list 2>/dev/null || true)
    if [[ "${sp_lines:-0}" -ge 1 && "$list" == "(no active watches)" ]]; then
      t1=$(now_ms)
      break
    fi
    if (( $(now_ms) >= deadline )); then
      t1=$(now_ms)
      elapsed=$(( t1 - t0 ))
      echo "    Stop hook never resolved the watch (elapsed=${elapsed}ms sp_lines=$sp_lines)"
      echo "    agent-watch list:"
      printf '%s\n' "$list" | sed 's/^/      /'
      echo "    spawner transcript:"
      sed 's/^/      /' "$spawner_transcript"
      exit 1
    fi
    sleep 0.05
  done

  elapsed=$(( t1 - t0 ))
  (( elapsed < 2000 )) || {
    echo "    Stop hook delivery took ${elapsed}ms — exceeds 2000ms fast-path budget"
    echo "    (no-fix path lands on 30s degraded fallback; this means the"
    echo "     permission-state.sh hook is not firing agent-eventsd evidence)"
    exit 1
  }

  # Tie the delivery to generic attention so a stale write can't sneak
  # past the budget check.
  grep -F "[agent-watch] $target (claude) attention" "$spawner_transcript" >/dev/null 2>&1 || {
    echo "    spawner delivery was not generic attention:"
    sed 's/^/      /' "$spawner_transcript"
    exit 1
  }
}
run_test "claude Stop hook fires evidence and notification arrives on spawner within 2s" \
  test_claude_stop_hook_fires_evidence_and_notification_arrives_within_2s

# Codex Stop hook fast-evidence path. The Codex runtime invokes
# `shared/steez/hooks/codex-stop.sh` on turn-end (via the user's
# `codex_hooks=true` opt-in). The hook must shell out
# `agent-eventsd evidence --state idle` so a live watch on the pane
# resolves sub-second instead of waiting for 30s degraded fallback.
#
# This test invokes the hook the way Codex does — TMUX_PANE set, Stop
# JSON on stdin — against a live watch armed by agent-send against a
# fake codex pane. Default SILENCE_WINDOW_MS (30s) keeps degraded
# reconcile out of the 2s budget, so the only path to resolution is
# the hook firing evidence. Fails on HEAD (hook file does not exist).
test_codex_stop_hook_fires_evidence_and_notification_arrives_within_2s() {
  setup_runtime
  trap cleanup_runtime EXIT

  local target spawner
  run_spawn_into target  codex
  run_spawn_into spawner codex
  [[ "$target" != "$spawner" ]] || { echo "    target and spawner are the same pane ($target)"; exit 1; }

  local hook="$REPO_ROOT/shared/steez/hooks/codex-stop.sh"
  [[ -x "$hook" ]] || {
    echo "    codex-stop.sh not installed or not executable: $hook"
    exit 1
  }

  # Fake codex sets @transcript_path lazily, on the first prompt. Kick
  # the turn first, then read the pane vars for both panes. Default
  # SILENCE_WINDOW_MS (30000) keeps degraded fallback out of the 2s
  # budget — only fast evidence from the Stop hook can resolve in time.
  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "stop-hook-evidence" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  # Only the target has a @transcript_path at this point — the fake codex
  # spawner sets it lazily on its first prompt, which only arrives when
  # the Stop hook resolves the watch and agent-deliver fires the
  # notification onto the spawner. Fall back to agent-history for the
  # spawner-side assertion.
  local target_transcript
  target_transcript=$(wait_pane_var "$target"  @transcript_path 50) || { echo "    target @transcript_path never set"; exit 1; }
  [[ -f "$target_transcript"  ]] || { echo "    target transcript missing: $target_transcript"; exit 1; }

  # Wait for the fake to write the prompt entry so the hook's cursor
  # is past the prearm baseline.
  local i
  for ((i=0; i<100; i++)); do
    grep -F 'stop-hook-evidence' "$target_transcript" >/dev/null 2>&1 && break
    sleep 0.05
  done
  grep -F 'stop-hook-evidence' "$target_transcript" >/dev/null 2>&1 || {
    echo "    target transcript never received the prompt:"
    sed 's/^/      /' "$target_transcript"
    exit 1
  }

  local payload t0 t1 elapsed deadline list hook_rc=0 spawner_transcript sp_lines
  payload=$(jq -cn --arg tp "$target_transcript" \
    '{session_id: "fake-session", transcript_path: $tp, hook_event_name: "Stop"}')
  t0=$(now_ms)
  TMUX_PANE="$target" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    PATH="$TEST_BIN:$PATH" \
    "$hook" <<<"$payload" || hook_rc=$?
  [[ "$hook_rc" -eq 0 ]] || {
    echo "    codex-stop.sh exited non-zero (rc=$hook_rc)"
    exit 1
  }

  # The spawner sets @transcript_path lazily once it processes the
  # delivered notification. Poll that pane var + the transcript directly;
  # both agent-watch list and agent-history shell calls add enough
  # latency to blow the 2s budget on cold starts.
  deadline=$(( t0 + 4000 ))
  list=""
  spawner_transcript=""
  sp_lines=0
  t1=0
  while :; do
    if [[ -z "$spawner_transcript" ]]; then
      spawner_transcript=$("$REAL_TMUX" -L "$TMUX_SOCK" show-options -pv -t "$spawner" @transcript_path 2>/dev/null) || spawner_transcript=""
    fi
    if [[ -n "$spawner_transcript" && -f "$spawner_transcript" ]]; then
      sp_lines=$({ grep -Ec "\\[agent-watch\\] $target \\(codex\\) attention" "$spawner_transcript" 2>/dev/null; } || true)
      if [[ "${sp_lines:-0}" -ge 1 ]]; then
        t1=$(now_ms)
        break
      fi
    fi
    if (( $(now_ms) >= deadline )); then
      t1=$(now_ms)
      elapsed=$(( t1 - t0 ))
      echo "    codex Stop hook path never resolved (elapsed=${elapsed}ms)"
      echo "    spawner @transcript_path: ${spawner_transcript:-<unset>}"
      [[ -f "$spawner_transcript" ]] && { echo "    spawner transcript:"; sed 's/^/      /' "$spawner_transcript"; }
      exit 1
    fi
    sleep 0.05
  done

  elapsed=$(( t1 - t0 ))
  (( elapsed < 2000 )) || {
    echo "    codex Stop hook delivery took ${elapsed}ms — exceeds 2000ms fast-path budget"
    echo "    (no-fix path lands on 30s degraded fallback; this means the"
    echo "     Stop hook did not fire agent-eventsd evidence)"
    exit 1
  }

  # Final: watch must self-clear. Polled outside the latency budget —
  # the evidence -> delivery hop is what we bound; slot cleanup happens
  # right after and is incidental.
  list=""
  for ((i=0; i<200; i++)); do
    list=$(run_bin agent-watch list 2>/dev/null || true)
    [[ "$list" == "(no active watches)" ]] && break
    sleep 0.05
  done
  [[ "$list" == "(no active watches)" ]] || {
    echo "    watch did not self-clear after Stop hook resolution:"
    printf '%s\n' "$list" | sed 's/^/      /'
    exit 1
  }
}
run_test "codex Stop hook fires agent-eventsd evidence and notification arrives within 2s" \
  test_codex_stop_hook_fires_evidence_and_notification_arrives_within_2s

report
