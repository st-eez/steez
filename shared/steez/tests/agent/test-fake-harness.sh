#!/usr/bin/env bash
# End-to-end runtime tests for the zero-token fake agent harness.
#
# This file does NOT use the mock tmux / mock ps helpers. It exercises the
# real runtime: real tmux (per-test isolated socket), real spawn.sh, real
# agent-state, real agent-history. The only replaced component is the
# agent binary itself — the fake claude / ren live under
# shared/steez/test/fakes/. Spec: specs/fake-agent-harness.md.
set -uo pipefail
source "$(dirname "$0")/helpers.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SPAWN_SCRIPT="$REPO_ROOT/skills/spawn-agent/scripts/spawn.sh"
BIN_DIR="$REPO_ROOT/shared/steez/bin"
FAKES_SRC_DIR="$REPO_ROOT/shared/steez/test/fakes/src"

# Skip the suite if either tmux or go is missing — both are required to
# exercise the real runtime against a compiled fake binary.
command -v tmux >/dev/null 2>&1 || { echo "  skip: tmux not installed"; exit 0; }
command -v go   >/dev/null 2>&1 || { echo "  skip: go not installed";   exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "  skip: jq not installed";   exit 0; }

REAL_TMUX="$(command -v tmux)"

# Build the fakes once at file scope. Per-test setup just copies them into
# a per-test bin dir alongside a tmux shim that pins the socket.
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

# Per-test runtime: fresh HOME, fresh STEEZ_STATE_DIR, fresh tmux server on
# its own socket, fresh per-test bin (fakes + tmux shim that pins the socket
# so subsequent bare `tmux ...` calls reach the right server).
setup_runtime() {
  RUNTIME_TMP=$(mktemp -d)
  export HOME="$RUNTIME_TMP/home"
  export STEEZ_STATE_DIR="$RUNTIME_TMP/state"
  mkdir -p "$HOME/.claude" "$HOME/.steez/bin" "$HOME/.steez/agent-state/claude" "$STEEZ_STATE_DIR/eventsd"

  # agent-history (and agent-deliver) hard-code $HOME/.steez/bin/agent-state.
  # Symlink to the real binary so the runtime path resolves under the test HOME.
  ln -sf "$BIN_DIR/agent-state" "$HOME/.steez/bin/agent-state"

  TMUX_SOCK="steez-fake-${RUNTIME_TMP##*/}"
  TEST_BIN="$RUNTIME_TMP/bin"
  mkdir -p "$TEST_BIN"
  cp "$FAKES_BUILD/claude" "$TEST_BIN/claude"
  cp "$FAKES_BUILD/impl.sh" "$TEST_BIN/impl.sh"
  cp "$FAKES_BUILD/ren"     "$TEST_BIN/ren"
  chmod +x "$TEST_BIN/claude" "$TEST_BIN/impl.sh" "$TEST_BIN/ren"

  # tmux shim — every bare `tmux ...` call (in spawn.sh, in agent-state,
  # in the fake) routes to this test's server socket. tmux's -L overrides
  # the TMUX env var, so this is safe both inside and outside panes.
  cat > "$TEST_BIN/tmux" <<EOF
#!/bin/bash
exec "$REAL_TMUX" -L "$TMUX_SOCK" "\$@"
EOF
  chmod +x "$TEST_BIN/tmux"

  # Boot the test server with a clean PATH and a non-interactive bash
  # default-shell. SHELL=/bin/bash + clean HOME means new panes don't
  # source the user's rc files. Strip REN_SESSION so the calling shell's
  # ambient `ren` env doesn't bleed into a `claude` test pane and force
  # is_ren to true.
  unset REN_SESSION
  SHELL=/bin/bash PATH="$TEST_BIN:$PATH" \
    "$REAL_TMUX" -L "$TMUX_SOCK" -f /dev/null \
    new-session -d -s test -x 200 -y 50
}

cleanup_runtime() {
  "$REAL_TMUX" -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -rf "$RUNTIME_TMP"
}

# Run spawn.sh inside pane 0 of the test session and wait for it to finish.
# Captures stdout/stderr to $SPAWN_OUT and parses TARGET pane id into
# $TARGET_PANE.
run_spawn() {
  local model="$1"
  SPAWN_OUT="$RUNTIME_TMP/spawn.out"
  SPAWN_DONE="$RUNTIME_TMP/spawn.done"
  : > "$SPAWN_OUT"
  rm -f "$SPAWN_DONE"

  local cmd="PATH='$TEST_BIN':\$PATH HOME='$HOME' STEEZ_STATE_DIR='$STEEZ_STATE_DIR' '$SPAWN_SCRIPT' split-h --model $model > '$SPAWN_OUT' 2>&1; touch '$SPAWN_DONE'"
  "$REAL_TMUX" -L "$TMUX_SOCK" send-keys -t test:0 "$cmd" Enter

  local i
  for i in $(seq 1 120); do
    [[ -f "$SPAWN_DONE" ]] && break
    sleep 0.5
  done
  [[ -f "$SPAWN_DONE" ]] || {
    echo "    spawn.sh never completed; output so far:"
    sed 's/^/      /' "$SPAWN_OUT"
    exit 1
  }

  TARGET_PANE=$(grep -o 'TARGET=%[0-9]*' "$SPAWN_OUT" | head -1 | cut -d= -f2)
  [[ -n "$TARGET_PANE" ]] || {
    echo "    no TARGET line in spawn output:"
    sed 's/^/      /' "$SPAWN_OUT"
    exit 1
  }
}

# Poll a pane variable until non-empty or timeout (in 0.2s ticks).
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

# Run a real bin (agent-state, agent-history) with the test PATH so its
# bare `tmux` calls hit the per-test shim.
run_bin() {
  PATH="$TEST_BIN:$PATH" HOME="$HOME" STEEZ_STATE_DIR="$STEEZ_STATE_DIR" \
    "$BIN_DIR/$1" "${@:2}"
}

suite "fake claude / ren end-to-end runtime"

# This is the smallest test that exercises the three pieces together:
#   1. spawn.sh boot wait completes against the fake (proves @session_id
#      gets set in time).
#   2. agent-state reports the correct agent + state through the real
#      runtime (proves transcript discovery via pane vars + claude default).
#   3. agent-history reads the prompt+reply round-trip from the fake's
#      transcript (proves transcript schema matches Claude JSONL).
test_claude_boot_state_and_history() {
  setup_runtime
  trap cleanup_runtime EXIT
  run_spawn claude

  grep -q '^IDLE$' "$SPAWN_OUT" || {
    echo "    expected IDLE in spawn output:"
    sed 's/^/      /' "$SPAWN_OUT"
    exit 1
  }

  # Boot-wait proof: spawn.sh emits "WARN: agent not ready after 15s" when
  # its own poll loop blows BOOT_TIMEOUT. IDLE alone is not proof — spawn.sh
  # prints IDLE unconditionally after the warn. Asserting the WARN is absent
  # is what proves @session_id landed inside BOOT_TIMEOUT against the fake.
  if grep -q 'WARN: agent not ready' "$SPAWN_OUT"; then
    echo "    spawn.sh boot wait timed out (the fake didn't set @session_id in time):"
    sed 's/^/      /' "$SPAWN_OUT"
    exit 1
  fi

  local sid
  sid=$(wait_pane_var "$TARGET_PANE" @session_id 5) || {
    echo "    @session_id missing on $TARGET_PANE after spawn.sh exited"
    exit 1
  }
  [[ -n "$sid" ]] || { echo "    @session_id is empty"; exit 1; }

  local transcript
  transcript=$(wait_pane_var "$TARGET_PANE" @transcript_path 5) || {
    echo "    @transcript_path missing on $TARGET_PANE"
    exit 1
  }
  [[ -f "$transcript" ]] || { echo "    transcript file missing: $transcript"; exit 1; }

  local state_json
  state_json=$(run_bin agent-state "$TARGET_PANE")
  printf '%s' "$state_json" | jq -e '.agent == "claude" and .state == "idle"' >/dev/null || {
    echo "    wrong agent-state output: $state_json"
    exit 1
  }

  # Send a literal prompt; auto-reply path writes prompt + idle transcript entries.
  "$REAL_TMUX" -L "$TMUX_SOCK" send-keys -t "$TARGET_PANE" "hello" Enter

  local i
  for ((i=0; i<60; i++)); do
    [[ "$(wc -l < "$transcript" 2>/dev/null | tr -d ' ')" -ge 2 ]] && break
    sleep 0.1
  done
  [[ "$(wc -l < "$transcript" 2>/dev/null | tr -d ' ')" -ge 2 ]] || {
    echo "    fake never wrote the auto-reply pair to transcript:"
    sed 's/^/      /' "$transcript"
    exit 1
  }

  local hist
  hist=$(run_bin agent-history "$TARGET_PANE" --last)
  printf '%s' "$hist" | jq -e '.agent == "claude" and .prompt == "hello" and .response == "ok"' >/dev/null || {
    echo "    wrong agent-history output: $hist"
    exit 1
  }
}
run_test "claude fake: boot wait, agent-state, agent-history end-to-end" test_claude_boot_state_and_history

# ren has the same boot + transcript surface as claude. The added contract
# is process identity: the basename in `ps -eo command` must be `claude`
# AND `ps -E -p <pid>` must show REN_SESSION=1, so detect_agent's is_ren
# check resolves to "ren".
test_ren_detected_via_env() {
  setup_runtime
  trap cleanup_runtime EXIT
  run_spawn ren

  if grep -q 'WARN: agent not ready' "$SPAWN_OUT"; then
    echo "    spawn.sh boot wait timed out for ren:"
    sed 's/^/      /' "$SPAWN_OUT"
    exit 1
  fi

  wait_pane_var "$TARGET_PANE" @session_id 5 >/dev/null || {
    echo "    ren never set @session_id"
    exit 1
  }

  local state_json
  state_json=$(run_bin agent-state "$TARGET_PANE")
  printf '%s' "$state_json" | jq -e '.agent == "ren" and .state == "idle"' >/dev/null || {
    echo "    ren not detected: $state_json"
    exit 1
  }
}
run_test "ren fake: detected via REN_SESSION env on a claude-named process" test_ren_detected_via_env

report
