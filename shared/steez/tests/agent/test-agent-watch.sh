#!/usr/bin/env bash
# Tests for agent-watch: watchlist JSONL management, dedup, arg validation.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
create_mock_tmux
setup_agent_mocks

# Register mock panes
mock_pane "%5" "2001" "claude" "/tmp"
mock_pane "%6" "2002" "codex" "/tmp"
mock_pane "%0" "2000" "" "/tmp"

# Pre-create daemon PID file with our PID so ensure_daemon returns immediately
echo $$ > "$STEEZ_STATE_DIR/agent-watch-daemon.pid"

WATCHES="$STEEZ_STATE_DIR/watches.jsonl"
export MOCK_AGENT_PANES="%5 %6"
export TMUX_PANE="%0"

suite "agent-watch add"

test_add_creates_entry() {
  > "$WATCHES"  # clear
  local out
  out=$("$BIN_DIR/agent-watch" add %5 2>&1)
  assert_contains "$out" "watching %5"
  # Verify JSONL entry was written
  local count
  count=$(wc -l < "$WATCHES" | tr -d ' ')
  assert_eq "1" "$count"
  # Verify pane field
  local pane
  pane=$(jq -r '.pane' "$WATCHES")
  assert_eq "%5" "$pane"
}
run_test "add creates watchlist entry" test_add_creates_entry

test_add_with_options() {
  > "$WATCHES"
  local out
  out=$("$BIN_DIR/agent-watch" add %5 --spawner %0 --label "my-agent" --baseline "idle" 2>&1)
  assert_contains "$out" "watching %5"
  assert_contains "$out" "my-agent"
  assert_contains "$out" "baseline=idle"
  local label baseline
  label=$(jq -r '.label' "$WATCHES")
  baseline=$(jq -r '.baseline_state' "$WATCHES")
  assert_eq "my-agent" "$label"
  assert_eq "idle" "$baseline"
}
run_test "add respects --label and --baseline" test_add_with_options

test_add_dedup() {
  > "$WATCHES"
  "$BIN_DIR/agent-watch" add %5 --label "first" >/dev/null 2>&1
  "$BIN_DIR/agent-watch" add %5 --label "second" >/dev/null 2>&1
  local count label
  count=$(wc -l < "$WATCHES" | tr -d ' ')
  assert_eq "1" "$count"
  label=$(jq -r '.label' "$WATCHES")
  assert_eq "second" "$label"
}
run_test "add deduplicates by pane" test_add_dedup

test_add_multiple_panes() {
  > "$WATCHES"
  "$BIN_DIR/agent-watch" add %5 >/dev/null 2>&1
  "$BIN_DIR/agent-watch" add %6 >/dev/null 2>&1
  local count
  count=$(wc -l < "$WATCHES" | tr -d ' ')
  assert_eq "2" "$count"
}
run_test "add allows different panes" test_add_multiple_panes

suite "agent-watch remove"

test_remove_entry() {
  > "$WATCHES"
  "$BIN_DIR/agent-watch" add %5 >/dev/null 2>&1
  "$BIN_DIR/agent-watch" remove %5 >/dev/null 2>&1
  local size
  size=$(wc -c < "$WATCHES" | tr -d ' ')
  # File should be empty or contain only whitespace
  [[ "$size" -le 1 ]]
}
run_test "remove deletes entry" test_remove_entry

test_remove_preserves_others() {
  > "$WATCHES"
  "$BIN_DIR/agent-watch" add %5 >/dev/null 2>&1
  "$BIN_DIR/agent-watch" add %6 >/dev/null 2>&1
  "$BIN_DIR/agent-watch" remove %5 >/dev/null 2>&1
  local count pane
  count=$(wc -l < "$WATCHES" | tr -d ' ')
  assert_eq "1" "$count"
  pane=$(jq -r '.pane' "$WATCHES")
  assert_eq "%6" "$pane"
}
run_test "remove preserves other entries" test_remove_preserves_others

suite "agent-watch list"

test_list_empty() {
  > "$WATCHES"
  local out
  out=$("$BIN_DIR/agent-watch" list 2>&1)
  assert_contains "$out" "no active watches"
}
run_test "list shows empty message" test_list_empty

test_list_with_entries() {
  > "$WATCHES"
  "$BIN_DIR/agent-watch" add %5 --label "test-agent" >/dev/null 2>&1
  local out
  out=$("$BIN_DIR/agent-watch" list 2>&1)
  assert_contains "$out" "%5"
  assert_contains "$out" "test-agent"
}
run_test "list shows entries" test_list_with_entries

suite "agent-watch errors"

test_error_add_no_pane() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" add 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "add without pane errors" test_error_add_no_pane

test_error_remove_no_pane() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" remove 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "remove without pane errors" test_error_remove_no_pane

test_error_no_command() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" 2>&1) || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "Usage:"
}
run_test "no command shows usage" test_error_no_command

test_error_unknown_command() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" frobnicate 2>&1) || rc=$?
  assert_contains "$out" "error"
}
run_test "unknown command errors" test_error_unknown_command

test_error_add_unknown_arg() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" add %5 --bogus 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown arg"
}
run_test "add with unknown arg errors" test_error_add_unknown_arg

report
