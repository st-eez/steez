#!/usr/bin/env bash
# Tests for agent-watch-daemon: process detection, singleton, empty-cycles exit.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT

# ----- process_line_has_agent (unit tests) -----

suite "process_line_has_agent"

# Extract the function from the daemon script
eval "$(extract_function "$BIN_DIR/agent-watch-daemon" "process_line_has_agent")"

test_matches_claude() {
  process_line_has_agent "1234 5678 /usr/local/bin/claude --api-key xxx"
}
run_test "matches claude binary" test_matches_claude

test_matches_codex() {
  process_line_has_agent "1234 5678 /usr/local/bin/codex --bypass"
}
run_test "matches codex binary" test_matches_codex

test_matches_node_codex() {
  process_line_has_agent "1234 5678 /usr/local/bin/node /path/to/codex"
}
run_test "matches node running codex" test_matches_node_codex

test_matches_node_claude() {
  process_line_has_agent "1234 5678 /usr/local/bin/node /path/to/claude"
}
run_test "matches node running claude" test_matches_node_claude

test_no_match_bash() {
  ! process_line_has_agent "1234 5678 /bin/bash"
}
run_test "rejects bash" test_no_match_bash

test_no_match_vim() {
  ! process_line_has_agent "1234 5678 /usr/bin/vim"
}
run_test "rejects vim" test_no_match_vim

test_no_match_empty() {
  ! process_line_has_agent ""
}
run_test "rejects empty string" test_no_match_empty

test_no_match_node_other() {
  ! process_line_has_agent "1234 5678 /usr/local/bin/node /path/to/server.js"
}
run_test "rejects node running non-agent" test_no_match_node_other

# ----- Singleton enforcement -----

suite "daemon singleton"

test_singleton_exits_silently() {
  local pidfile="$STEEZ_STATE_DIR/agent-watch-daemon.pid"
  echo $$ > "$pidfile"
  local rc=0
  "$BIN_DIR/agent-watch-daemon" 2>/dev/null || rc=$?
  assert_exit_code "0" "$rc"
  # PID file should still have our PID (daemon didn't overwrite)
  local stored_pid
  stored_pid=$(cat "$pidfile")
  assert_eq "$$" "$stored_pid"
}
run_test "second daemon exits silently" test_singleton_exits_silently

test_stale_pid_reclaimed() {
  local pidfile="$STEEZ_STATE_DIR/agent-watch-daemon.pid"
  # Write a PID that doesn't exist (99999999)
  echo "99999999" > "$pidfile"
  # Create empty watchlist so daemon exits via empty cycles
  > "$STEEZ_STATE_DIR/watches.jsonl"
  local rc=0
  AGENT_WATCH_POLL=0 AGENT_WATCH_EMPTY_CYCLES=1 \
    "$BIN_DIR/agent-watch-daemon" 2>/dev/null || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "reclaims stale PID file" test_stale_pid_reclaimed

# ----- Empty cycles exit -----

suite "daemon lifecycle"

test_empty_cycles_exit() {
  rm -f "$STEEZ_STATE_DIR/agent-watch-daemon.pid"
  > "$STEEZ_STATE_DIR/watches.jsonl"
  local rc=0
  AGENT_WATCH_POLL=0 AGENT_WATCH_EMPTY_CYCLES=2 \
    "$BIN_DIR/agent-watch-daemon" 2>/dev/null || rc=$?
  assert_exit_code "0" "$rc"
  # Verify the daemon logged the exit
  local log="$STEEZ_STATE_DIR/agent-watch.log"
  assert_contains "$(cat "$log")" "watchlist empty"
}
run_test "exits after empty cycles" test_empty_cycles_exit

test_daemon_cleans_pidfile() {
  rm -f "$STEEZ_STATE_DIR/agent-watch-daemon.pid"
  > "$STEEZ_STATE_DIR/watches.jsonl"
  AGENT_WATCH_POLL=0 AGENT_WATCH_EMPTY_CYCLES=1 \
    "$BIN_DIR/agent-watch-daemon" 2>/dev/null || true
  # PID file should be cleaned up by EXIT trap
  [[ ! -f "$STEEZ_STATE_DIR/agent-watch-daemon.pid" ]]
}
run_test "cleans PID file on exit" test_daemon_cleans_pidfile

test_daemon_logs_start_stop() {
  rm -f "$STEEZ_STATE_DIR/agent-watch-daemon.pid" "$STEEZ_STATE_DIR/agent-watch.log"
  > "$STEEZ_STATE_DIR/watches.jsonl"
  AGENT_WATCH_POLL=0 AGENT_WATCH_EMPTY_CYCLES=1 \
    "$BIN_DIR/agent-watch-daemon" 2>/dev/null || true
  local log
  log=$(cat "$STEEZ_STATE_DIR/agent-watch.log")
  assert_contains "$log" "started"
  assert_contains "$log" "stopped"
}
run_test "logs start and stop" test_daemon_logs_start_stop

report
