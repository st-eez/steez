#!/usr/bin/env bash
# Tests for transcript-based state detection (claude_state, codex_state).
# Exercises the Python logic inside agent-state's artifact_state function
# with crafted JSONL fixtures.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
source_agent_state

# Helper: write JSONL fixture and call artifact_state
run_artifact() {
  local agent="$1" fixture_name="$2"
  local f="$TEST_TMP/${fixture_name}.jsonl"
  cat > "$f"  # reads from stdin (heredoc)
  artifact_state "$agent" "$f" "" 2>/dev/null
}

# ----- Claude transcript tests -----

suite "claude_state"

test_claude_idle_turn_duration() {
  local state
  state=$(run_artifact claude idle_td <<'JSONL'
{"type":"user","message":{"role":"user","content":"hello"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}
{"type":"system","subtype":"turn_duration","duration_ms":1234}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "idle on system turn_duration" test_claude_idle_turn_duration

test_claude_idle_stop_hook() {
  local state
  state=$(run_artifact claude idle_sh <<'JSONL'
{"type":"user","message":{"role":"user","content":"hello"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}
{"type":"system","subtype":"stop_hook_summary"}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "idle on system stop_hook_summary" test_claude_idle_stop_hook

test_claude_idle_end_turn() {
  local state
  state=$(run_artifact claude idle_et <<'JSONL'
{"type":"user","message":{"role":"user","content":"hello"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "idle on stop_reason end_turn" test_claude_idle_end_turn

test_claude_working_user() {
  local state
  state=$(run_artifact claude working_user <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
{"type":"user","message":{"role":"user","content":"do something"}}
JSONL
  )
  assert_eq "working" "$state"
}
run_test "working on user message" test_claude_working_user

test_claude_blocked_question() {
  local state
  state=$(run_artifact claude blocked_q <<'JSONL'
{"type":"user","message":{"role":"user","content":"do something"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"AskUserQuestion","input":{"question":"which one?"}}]}}
JSONL
  )
  assert_eq "blocked:question" "$state"
}
run_test "blocked:question on AskUserQuestion" test_claude_blocked_question

test_claude_working_tool_use() {
  local state
  state=$(run_artifact claude working_tu <<'JSONL'
{"type":"user","message":{"role":"user","content":"do something"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]}}
JSONL
  )
  assert_eq "working" "$state"
}
run_test "working on unresolved tool_use" test_claude_working_tool_use

test_claude_resolved_tool_idle() {
  local state
  state=$(run_artifact claude resolved <<'JSONL'
{"type":"user","message":{"role":"user","content":"do something"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file1"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "idle after resolved tool_use + end_turn" test_claude_resolved_tool_idle

test_claude_skip_meta_user() {
  local state
  state=$(run_artifact claude meta <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "skips isMeta user message" test_claude_skip_meta_user

test_claude_skip_sidechain() {
  local state
  state=$(run_artifact claude sidechain <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"side"}]}}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "skips isSidechain assistant message" test_claude_skip_sidechain

test_claude_skips_attachment() {
  local state
  state=$(run_artifact claude attach <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
{"type":"attachment","name":"file.txt"}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "skips attachment type" test_claude_skips_attachment

# ----- Codex transcript tests -----

suite "codex_state"

test_codex_idle_task_complete() {
  local state
  state=$(run_artifact codex idle_tc <<'JSONL'
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "idle on task_complete" test_codex_idle_task_complete

test_codex_working_user_message() {
  local state
  state=$(run_artifact codex working_um <<'JSONL'
{"type":"event_msg","payload":{"type":"task_complete"}}
{"type":"event_msg","payload":{"type":"user_message"}}
JSONL
  )
  assert_eq "working" "$state"
}
run_test "working on user_message" test_codex_working_user_message

test_codex_blocked_question() {
  local state
  state=$(run_artifact codex blocked_q <<'JSONL'
{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"fc_1","arguments":"{}"}}
JSONL
  )
  assert_eq "blocked:question" "$state"
}
run_test "blocked:question on request_user_input" test_codex_blocked_question

test_codex_blocked_permission() {
  local state
  state=$(run_artifact codex blocked_p <<'JSONL'
{"type":"response_item","payload":{"type":"function_call","name":"exec","call_id":"fc_1","arguments":"{\"sandbox_permissions\":\"require_escalated\"}"}}
JSONL
  )
  assert_eq "blocked:permission" "$state"
}
run_test "blocked:permission on require_escalated" test_codex_blocked_permission

test_codex_working_function_call() {
  local state
  state=$(run_artifact codex working_fc <<'JSONL'
{"type":"response_item","payload":{"type":"function_call","name":"exec_code","call_id":"fc_1","arguments":"{}"}}
JSONL
  )
  assert_eq "working" "$state"
}
run_test "working on regular function_call" test_codex_working_function_call

test_codex_resolved_idle() {
  local state
  state=$(run_artifact codex resolved <<'JSONL'
{"type":"response_item","payload":{"type":"function_call","name":"exec_code","call_id":"fc_1","arguments":"{}"}}
{"type":"response_item","payload":{"type":"function_call_output","call_id":"fc_1"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
  )
  assert_eq "idle" "$state"
}
run_test "idle after resolved call + task_complete" test_codex_resolved_idle

test_codex_unresolved_skips_resolved() {
  local state
  state=$(run_artifact codex partial <<'JSONL'
{"type":"response_item","payload":{"type":"function_call","name":"exec_code","call_id":"fc_1","arguments":"{}"}}
{"type":"response_item","payload":{"type":"function_call_output","call_id":"fc_1"}}
{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"fc_2","arguments":"{}"}}
JSONL
  )
  assert_eq "blocked:question" "$state"
}
run_test "unresolved call found after skipping resolved" test_codex_unresolved_skips_resolved

# ----- Edge cases -----

suite "edge cases"

test_empty_transcript_fails() {
  local f="$TEST_TMP/empty.jsonl"
  touch "$f"
  local rc=0
  artifact_state "claude" "$f" "" 2>/dev/null || rc=$?
  assert_exit_code "1" "$rc"
}
run_test "empty transcript exits 1" test_empty_transcript_fails

test_missing_transcript_fails() {
  local rc=0
  artifact_state "claude" "/nonexistent/file.jsonl" "" 2>/dev/null || rc=$?
  assert_exit_code "1" "$rc"
}
run_test "missing transcript exits 1" test_missing_transcript_fails

test_sidecar_does_not_override_transcript() {
  # Create a transcript that should stay idle even if an old sidecar exists.
  local f="$TEST_TMP/sidecar_test.jsonl"
  cat > "$f" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
JSONL

  # Create a sidecar state file that claims blocked:question.
  local sid="test-session-id"
  local sidecar_dir="$HOME/.steez/agent-state/claude"
  mkdir -p "$sidecar_dir"
  cat > "$sidecar_dir/${sid}.json" <<JSON
{"blocked_state":"blocked:question","transcript_path":"$f","requested_at":$(date +%s)9999999999}
JSON

  local state
  state=$(artifact_state "claude" "$f" "$sid" 2>/dev/null)
  assert_eq "idle" "$state"
}
run_test "sidecar state does not override transcript" test_sidecar_does_not_override_transcript

report
