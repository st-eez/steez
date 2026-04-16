#!/usr/bin/env bash
# Fake-agent harness: state-transition commands must fire `agent-eventsd
# evidence` so the primary fast path resolves watches sub-second, mirroring
# what production Claude / Codex hooks do on turn-end. Spec:
# specs/fake-agent-harness.md (Control surface).
#
# This test runs with spec-default `SILENCE_WINDOW_MS` (30s). Degraded
# fallback through `agent-state` polling cannot engage inside the 2s
# assertion budget, so the only path to resolution is the fake calling
# `agent-eventsd evidence` from its fifo handler.
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
  eventsd_enable_explicit_service_mode
  mkdir -p "$HOME/.claude" "$HOME/.steez/bin" "$HOME/.steez/agent-state/claude" "$STEEZ_STATE_DIR/eventsd"

  # Real agent-state, agent-deliver, agent-eventsd, agent-history — the
  # evidence CLI must resolve to the real implementation under $HOME so
  # the fake's shell-out reaches it.
  ln -sf "$BIN_DIR/agent-state"    "$HOME/.steez/bin/agent-state"
  ln -sf "$BIN_DIR/agent-deliver"  "$HOME/.steez/bin/agent-deliver"
  ln -sf "$BIN_DIR/agent-eventsd"  "$HOME/.steez/bin/agent-eventsd"
  ln -sf "$BIN_DIR/agent-history"  "$HOME/.steez/bin/agent-history"

  TMUX_SOCK="steez-fake-evid-${RUNTIME_TMP##*/}"
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
  PANE0=$("$REAL_TMUX" -L "$TMUX_SOCK" display-message -t test:0.0 -p '#{pane_id}')
  PATH="$TEST_BIN:$PATH" eventsd_start_service "$BIN_DIR/agent-eventsd" || {
    echo "  eventsd service failed to start"
    exit 1
  }
}

cleanup_runtime() {
  eventsd_stop_service
  "$REAL_TMUX" -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -rf "$RUNTIME_TMP"
}

run_spawn_into() {
  local __var="$1"; local model="$2"
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

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

suite "fake-harness fast-path evidence"

# Drives the fake claude through its control fifo. With default
# SILENCE_WINDOW_MS (30s), degraded fallback cannot engage inside the 2s
# budget — so spawner delivery and live-watch clearance are only reachable
# via the fake shelling out `agent-eventsd evidence` on the state
# transition. This test fails if the fake only appends transcript.
test_fake_idle_fifo_transition_fires_fast_evidence_within_2s() {
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

  # Default SILENCE_WINDOW_MS (30000). The fast path is the only way the
  # watch can resolve inside 2s.
  local send_rc=0 send_out
  send_out=$(PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    EVENTSD_TICK_INTERVAL_SEC=0.1 \
    "$BIN_DIR/agent-send" --spawner "$spawner" "$target" "fifo-idle" 2>&1) || send_rc=$?
  [[ "$send_rc" -eq 0 ]] || {
    echo "    agent-send failed (rc=$send_rc):"
    printf '%s\n' "$send_out" | sed 's/^/      /'
    exit 1
  }

  # t0: wall-clock just before driving the fifo transition. t1 on break.
  local t0 t1 elapsed deadline i sp_lines list
  t0=$(now_ms)
  write_fifo_line "$ctl_path" "state idle ok" || {
    echo "    fake control fifo never accepted state idle"
    exit 1
  }

  # Poll for <=2s. Tick is generous so tool overhead doesn't push us past
  # the deadline on a slow host; the elapsed-ms assertion is what enforces
  # fast path. Deadline budget itself is 4s so the poll loop can observe a
  # slow resolution and report a descriptive failure instead of a timeout.
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
      echo "    fast path never resolved (elapsed=${elapsed}ms sp_lines=$sp_lines)"
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
    echo "    delivery took ${elapsed}ms — exceeds 2000ms fast-path budget"
    echo "    (no-fix path lands on 30s degraded fallback; this means the"
    echo "     fake is not firing agent-eventsd evidence on state transitions)"
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
run_test "fake idle fifo transition fires agent-eventsd evidence on spawner within 2s (fast path only)" \
  test_fake_idle_fifo_transition_fires_fast_evidence_within_2s

report
