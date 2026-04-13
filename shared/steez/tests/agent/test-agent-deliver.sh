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

report
