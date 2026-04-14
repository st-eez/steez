#!/usr/bin/env bash
# Tests for agent-deliver: arg parsing, validation, delivery exit codes.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
create_mock_tmux
setup_agent_mocks

mock_pane "%5" "2001" "claude" "/tmp"
mock_pane "%0" "2000" "" "/tmp"

export MOCK_AGENT_PANES="%5"

suite "agent-deliver arg parsing"

test_no_args() {
  local rc=0 out
  out=$("$BIN_DIR/agent-deliver" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "no args exits 1" test_no_args

test_help() {
  local rc=0 out
  out=$("$BIN_DIR/agent-deliver" --help 2>&1) || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "Usage:"
}
run_test "--help exits 0" test_help

test_one_arg() {
  local rc=0 out
  out=$("$BIN_DIR/agent-deliver" %5 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "one arg exits 1" test_one_arg

test_three_args() {
  local rc=0 out
  out=$("$BIN_DIR/agent-deliver" %5 "msg" "extra" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
}
run_test "three args exits 1" test_three_args

test_empty_message() {
  local rc=0 out
  out=$("$BIN_DIR/agent-deliver" %5 "" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "empty"
}
run_test "empty message exits 1" test_empty_message

suite "agent-deliver validation"

test_non_agent_pane() {
  export MOCK_AGENT_PANES=""
  local rc=0 out
  out=$("$BIN_DIR/agent-deliver" %5 "hello" 2>&1) || rc=$?
  assert_exit_code "2" "$rc"
  assert_contains "$out" "not a recognized AI agent"
  export MOCK_AGENT_PANES="%5"
}
run_test "non-agent pane exits 2" test_non_agent_pane

test_successful_delivery() {
  local rc=0
  "$BIN_DIR/agent-deliver" %5 "hello world" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "successful delivery exits 0" test_successful_delivery

test_multiline_message() {
  local rc=0
  "$BIN_DIR/agent-deliver" %5 "line 1
line 2
line 3" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "multiline message accepted" test_multiline_message

test_special_chars_message() {
  local rc=0
  "$BIN_DIR/agent-deliver" %5 'hello $WORLD `backtick` "quotes"' >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "special characters in message accepted" test_special_chars_message

suite "agent-deliver canonical pane resolution"

mock_pane_alias "mac:0.1" "%5"

test_uses_canonical_pane_downstream() {
  # The alias lives in MOCK_AGENT_PANES too, otherwise the initial
  # agent-state guard would reject the raw argument before resolution runs.
  export MOCK_AGENT_PANES="%5 mac:0.1"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-canonical.log"
  : > "$MOCK_TMUX_LOG"

  "$BIN_DIR/agent-deliver" mac:0.1 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local paste_line
  paste_line=$(grep '^paste-buffer ' "$MOCK_TMUX_LOG") \
    || { echo "paste-buffer never called"; cat "$MOCK_TMUX_LOG"; exit 1; }
  assert_contains "$paste_line" "-t %5"
  assert_not_contains "$paste_line" "mac:0.1"

  local enter_line
  enter_line=$(grep '^send-keys ' "$MOCK_TMUX_LOG" | head -1) \
    || { echo "send-keys never called"; cat "$MOCK_TMUX_LOG"; exit 1; }
  assert_contains "$enter_line" "-t %5 Enter"
  assert_not_contains "$enter_line" "mac:0.1"

  unset MOCK_TMUX_LOG
  export MOCK_AGENT_PANES="%5"
}
run_test "resolves raw pane to canonical %N before paste-buffer and send-keys" \
  test_uses_canonical_pane_downstream

suite "agent-deliver retry-Enter"

test_retries_enter_when_agent_still_idle() {
  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-idle.log"
  : > "$MOCK_TMUX_LOG"

  "$BIN_DIR/agent-deliver" %5 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  # Expect two Enters: the mandatory delayed Enter + the idle-detected retry.
  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "2" "$enter_count"

  unset MOCK_TMUX_LOG
}
run_test "sends second Enter when post-delivery state is idle" \
  test_retries_enter_when_agent_still_idle

test_no_retry_when_agent_already_working() {
  setup_agent_mocks claude working

  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-working.log"
  : > "$MOCK_TMUX_LOG"

  "$BIN_DIR/agent-deliver" %5 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "1" "$enter_count"

  setup_agent_mocks
  unset MOCK_TMUX_LOG
}
run_test "skips retry Enter when post-delivery state is working" \
  test_no_retry_when_agent_already_working

report
