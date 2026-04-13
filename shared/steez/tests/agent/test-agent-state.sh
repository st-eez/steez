#!/usr/bin/env bash
# Tests for agent-state: detect_agent, detect_state (screen patterns), emit_json, arg parsing.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
source_agent_state

# ----- detect_agent -----

suite "detect_agent"

# Set mock process table (overrides the empty _PS from sourcing)
_PS="  PID  PPID COMMAND
1001 1000 /usr/local/bin/claude --api-key xxx
1002 1000 /usr/local/bin/codex --bypass
1003 1000 /usr/local/bin/node /home/user/.nvm/v20/bin/codex
1004 1000 /usr/local/bin/node /home/user/.nvm/v20/bin/claude
1005 1000 /bin/bash
1006 1005 /usr/local/bin/claude --flag
1007 1000 /bin/zsh"

test_detect_claude() {
  local agent
  agent=$(detect_agent "1001")
  assert_eq "claude" "$agent"
}
run_test "detects claude binary" test_detect_claude

test_detect_codex() {
  local agent
  agent=$(detect_agent "1002")
  assert_eq "codex" "$agent"
}
run_test "detects codex binary" test_detect_codex

test_detect_node_codex() {
  local agent
  agent=$(detect_agent "1003")
  assert_eq "codex" "$agent"
}
run_test "detects node running codex" test_detect_node_codex

test_detect_node_claude() {
  local agent
  agent=$(detect_agent "1004")
  assert_eq "claude" "$agent"
}
run_test "detects node running claude" test_detect_node_claude

test_detect_child_claude() {
  local agent
  agent=$(detect_agent "1005")
  assert_eq "claude" "$agent"
}
run_test "detects claude as child process" test_detect_child_claude

test_detect_unknown() {
  local agent
  agent=$(detect_agent "1007")
  assert_eq "unknown" "$agent"
}
run_test "returns unknown for non-agent" test_detect_unknown

test_detect_missing_pid() {
  local agent
  agent=$(detect_agent "9999")
  assert_eq "unknown" "$agent"
}
run_test "returns unknown for missing PID" test_detect_missing_pid

# ----- detect_state (screen-based patterns) -----
# Pass empty transcript so artifact_state fails and screen detection runs.

suite "detect_state (screen patterns)"

test_screen_blocked_permission_tab() {
  local result
  result=$(detect_state "" "some output
Tab to amend the command" "claude" "" "")
  assert_eq "blocked:permission" "${result%%|*}"
}
run_test "blocked:permission on 'Tab to amend'" test_screen_blocked_permission_tab

test_screen_blocked_permission_proceed() {
  local result
  result=$(detect_state "" "Do you want to proceed?" "claude" "" "")
  assert_eq "blocked:permission" "${result%%|*}"
}
run_test "blocked:permission on 'Do you want to proceed?'" test_screen_blocked_permission_proceed

test_screen_blocked_permission_overwrite() {
  local result
  result=$(detect_state "" "Do you want to overwrite this file?" "claude" "" "")
  assert_eq "blocked:permission" "${result%%|*}"
}
run_test "blocked:permission on 'Do you want to overwrite'" test_screen_blocked_permission_overwrite

test_screen_blocked_question() {
  local result
  result=$(detect_state "" "Enter to select the option
Chat about this choice" "claude" "" "")
  assert_eq "blocked:question" "${result%%|*}"
}
run_test "blocked:question on Enter+Chat pattern" test_screen_blocked_question

test_screen_blocked_unknown() {
  local result
  result=$(detect_state "" "Press Esc to cancel" "claude" "" "")
  assert_eq "blocked:unknown" "${result%%|*}"
}
run_test "blocked:unknown on 'Esc to cancel'" test_screen_blocked_unknown

test_screen_blocked_unknown_lowercase() {
  local result
  result=$(detect_state "" "press esc to cancel" "claude" "" "")
  assert_eq "blocked:unknown" "${result%%|*}"
}
run_test "blocked:unknown on lowercase 'esc to cancel'" test_screen_blocked_unknown_lowercase

test_screen_braille_working() {
  # Braille spinner character U+2807 in title
  local result
  result=$(detect_state $'\xe2\xa0\x87 Building' "" "claude" "" "")
  assert_eq "working" "${result%%|*}"
}
run_test "working on braille spinner in title" test_screen_braille_working

test_screen_braille_name_extraction() {
  local result
  result=$(detect_state $'\xe2\xa0\x87 Building tests' "" "claude" "" "")
  assert_eq "Building tests" "${result#*|}"
}
run_test "extracts name from braille title" test_screen_braille_name_extraction

test_codex_idle_prompt() {
  local result
  # U+203A right-pointing angle quotation mark
  result=$(detect_state "" $'\xe2\x80\xba ' "codex" "" "")
  assert_eq "idle" "${result%%|*}"
}
run_test "codex idle on prompt character" test_codex_idle_prompt

test_codex_working_default() {
  local result
  result=$(detect_state "" "Running tool..." "codex" "" "")
  assert_eq "working" "${result%%|*}"
}
run_test "codex working by default" test_codex_working_default

test_claude_default_idle() {
  local result
  result=$(detect_state "" "" "claude" "" "")
  assert_eq "idle" "${result%%|*}"
}
run_test "claude defaults to idle" test_claude_default_idle

test_name_from_empty_title() {
  local result
  result=$(detect_state "" "" "claude" "" "")
  assert_eq "unknown" "${result#*|}"
}
run_test "name is 'unknown' when title empty" test_name_from_empty_title

# ----- detect_state integration: artifact + screen -----

suite "detect_state (artifact + screen integration)"

test_artifact_working_screen_blocked() {
  # Create a transcript that returns "working" (user message sent)
  local f="$TEST_TMP/integration.jsonl"
  cat > "$f" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}}
{"type":"user","message":{"role":"user","content":"build it"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"rm -rf /"}}]}}
JSONL
  local result
  result=$(detect_state "" "Tab to amend the command" "claude" "$f" "")
  assert_eq "blocked:permission" "${result%%|*}"
}
run_test "screen blocked overrides artifact working" test_artifact_working_screen_blocked

# ----- emit_json -----

suite "emit_json"

test_emit_json_basic() {
  local json
  json=$(emit_json "%5" "claude" "idle" "Test name")
  assert_json_field "$json" ".pane" "%5"
  assert_json_field "$json" ".agent" "claude"
  assert_json_field "$json" ".state" "idle"
  assert_json_field "$json" ".name" "Test name"
}
run_test "basic JSON output" test_emit_json_basic

test_emit_json_detail() {
  local json
  json=$(emit_json "%5" "claude" "idle" "Test" "" "sess-123" "/tmp/proj" "/path/t.jsonl")
  assert_json_field "$json" ".detail.session_id" "sess-123"
  assert_json_field "$json" ".detail.cwd" "/tmp/proj"
  assert_json_field "$json" ".detail.transcript_path" "/path/t.jsonl"
}
run_test "JSON with detail fields" test_emit_json_detail

test_emit_json_no_detail() {
  local json
  json=$(emit_json "%5" "claude" "idle" "Test" "" "" "" "")
  assert_json_field "$json" ".detail" "null"
}
run_test "JSON omits detail when empty" test_emit_json_no_detail

# ----- arg parsing (subprocess) -----

suite "agent-state arg parsing"

test_args_no_pane() {
  local rc=0 out
  out=$("$BIN_DIR/agent-state" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "no args exits 1 with error" test_args_no_pane

test_args_help() {
  local rc=0 out
  out=$("$BIN_DIR/agent-state" --help 2>&1) || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "Usage:"
}
run_test "--help exits 0 with usage" test_args_help

test_args_unknown_option() {
  local rc=0 out
  out=$("$BIN_DIR/agent-state" --bogus 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown option"
}
run_test "unknown option exits 1" test_args_unknown_option

report
