#!/usr/bin/env bash
# Tests for agent-send: arg parsing, delivery forwarding, watch registration.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
create_mock_tmux
setup_agent_mocks

mock_pane "%5" "2001" "claude" "/tmp"
mock_pane "%0" "2000" "" "/tmp"

export MOCK_AGENT_PANES="%5"
export TMUX_PANE="%0"

suite "agent-send arg parsing"

test_no_args_error() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "no args exits 1" test_no_args_error

test_help_exits_0() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" --help 2>&1) || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "Usage:"
}
run_test "--help exits 0" test_help_exits_0

test_missing_message() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" %5 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "missing message exits 1" test_missing_message

test_too_many_args() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" %5 "hello" "extra" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
}
run_test "too many positional args exits 1" test_too_many_args

test_unknown_flag() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" --bogus %5 "hello" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown"
}
run_test "unknown flag exits 1" test_unknown_flag

suite "agent-send delivery"

test_successful_send() {
  local rc=0
  "$BIN_DIR/agent-send" %5 "hello world" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "successful send exits 0" test_successful_send

test_non_agent_pane() {
  export MOCK_AGENT_PANES=""
  local rc=0
  "$BIN_DIR/agent-send" %5 "hello" >/dev/null 2>&1 || rc=$?
  assert_exit_code "2" "$rc"
  export MOCK_AGENT_PANES="%5"  # restore
}
run_test "non-agent pane exits 2" test_non_agent_pane

test_no_watch_flag() {
  # Create a marker-file-writing agent-watch mock
  create_mock_script "$HOME/.steez/bin/agent-watch" \
    'touch "'"$TEST_TMP"'/watch-called"; exit 0'
  rm -f "$TEST_TMP/watch-called"

  "$BIN_DIR/agent-send" --no-watch %5 "hello" >/dev/null 2>&1 || true
  # With --no-watch, agent-watch should not be called
  [[ ! -f "$TEST_TMP/watch-called" ]]
}
run_test "--no-watch skips watch registration" test_no_watch_flag

test_emit_watch_line() {
  # Restore normal agent-watch mock
  create_mock_script "$HOME/.steez/bin/agent-watch" 'exit 0'
  local out
  out=$("$BIN_DIR/agent-send" --emit-watch-line %5 "hello" 2>&1)
  assert_contains "$out" "WATCHED=%5"
  assert_contains "$out" "BASELINE=working"
}
run_test "--emit-watch-line prints watch info" test_emit_watch_line

test_custom_spawner() {
  create_mock_script "$HOME/.steez/bin/agent-watch" 'exit 0'
  local rc=0
  "$BIN_DIR/agent-send" --spawner %0 %5 "hello" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "--spawner flag accepted" test_custom_spawner

test_custom_label() {
  create_mock_script "$HOME/.steez/bin/agent-watch" 'exit 0'
  local rc=0
  "$BIN_DIR/agent-send" --label "my-task" %5 "hello" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "--label flag accepted" test_custom_label

report
