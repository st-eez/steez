#!/usr/bin/env bash
# Tests for agent-state: detect_agent, detect_state (screen patterns), emit_json, arg parsing.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
source_agent_state
# find_transcript + the --layout/--all paths call real tmux; install the mock
# once so later suites can register pane vars/captures without reinitialising.
create_mock_tmux

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

test_codex_artifact_idle_title_spinner_overrides_to_working() {
  # Real-world bug: Codex can leave the transcript on the prior turn's
  # task_complete while the next turn is already rendering and the pane title
  # spinner is live. SketchyBar should show working, not stale idle.
  local f="$TEST_TMP/codex-idle-spinner.jsonl"
  cat > "$f" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_complete"}}
JSONL
  local result
  result=$(detect_state $'\xe2\xa0\xb8 steez' "" "codex" "$f" "")
  assert_eq "working" "${result%%|*}"
}
run_test "codex title spinner overrides stale artifact idle" \
  test_codex_artifact_idle_title_spinner_overrides_to_working

# ----- codex live-state classification (steez-80p4.1) -----
#
# Codex writes `event_msg.task_started` when a new turn begins, then
# `event_msg.user_message` a few ms later. Between those two writes (or if
# write buffering delays user_message), the backward walk must not skip over
# task_started and fall through to the previous turn's task_complete — that
# would classify an actively working pane as idle.

suite "codex live-state classification"

test_codex_task_started_after_complete_is_working() {
  # Prior turn completed, new turn just started but user_message has not been
  # flushed yet. The pane is live-working; must NOT report idle.
  local f="$TEST_TMP/codex-task-started.jsonl"
  cat > "$f" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"user_message"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
{"type":"event_msg","payload":{"type":"task_started"}}
JSONL
  local result
  result=$(detect_state "" "" "codex" "$f" "")
  assert_eq "working" "${result%%|*}"
}
run_test "codex task_started after task_complete reports working" test_codex_task_started_after_complete_is_working

test_codex_task_started_with_response_items_is_working() {
  # New turn started, bootstrap response_items written, but user_message not
  # yet flushed. This is the real-world interleaving observed in Codex
  # rollouts: task_started, then a handful of response_item.message entries
  # for system/turn-context boilerplate, then user_message.
  local f="$TEST_TMP/codex-bootstrap.jsonl"
  cat > "$f" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_complete"}}
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"message","role":"system","content":[]}}
{"type":"response_item","payload":{"type":"message","role":"system","content":[]}}
JSONL
  local result
  result=$(detect_state "" "" "codex" "$f" "")
  assert_eq "working" "${result%%|*}"
}
run_test "codex task_started with bootstrap response_items reports working" \
  test_codex_task_started_with_response_items_is_working

test_codex_only_task_started_is_working() {
  # Brand-new session: the very first event_msg is task_started and nothing
  # else has landed yet. Classification must be working, not unknown-
  # fallback-through-screen.
  local f="$TEST_TMP/codex-fresh.jsonl"
  cat > "$f" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_started"}}
JSONL
  local result
  result=$(detect_state "" "" "codex" "$f" "")
  assert_eq "working" "${result%%|*}"
}
run_test "codex fresh session with only task_started reports working" \
  test_codex_only_task_started_is_working

test_codex_explain_reports_working_for_task_started() {
  # --explain surfaces feed SketchyBar and other live-status consumers.
  # They must also see working, not idle, when the transcript ends on
  # task_started.
  local f="$TEST_TMP/codex-explain-started.jsonl"
  cat > "$f" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_complete"}}
{"type":"event_msg","payload":{"type":"task_started"}}
JSONL
  local out
  out=$(artifact_explanation "codex" "$f" "")
  assert_json_field "$out" ".state" "working"
  assert_json_field "$out" ".summary" "working"
  assert_json_field "$out" ".source" "artifacts"
}
run_test "artifact_explanation reports working for codex task_started" \
  test_codex_explain_reports_working_for_task_started

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

# ----- find_transcript (claude-only filesystem fallback) -----
#
# The spec states that `ren` relies on the SessionStart hook's pane variable
# and must NOT fall back to `~/.claude/projects/{cwd-key}/`. A mutant that
# folds `ren` into the claude filesystem branch must fail here.

suite "find_transcript"

test_find_transcript_ren_no_filesystem_fallback() {
  local cwd="/tmp/fakeproj-ren"
  local path_key="-tmp-fakeproj-ren"
  mkdir -p "$HOME/.claude/projects/$path_key"
  : > "$HOME/.claude/projects/$path_key/ren-session.jsonl"

  local out
  out=$(find_transcript "ren" "%1" 1234 "$cwd")
  assert_eq "" "$out"
}
run_test "ren does not use claude filesystem fallback" test_find_transcript_ren_no_filesystem_fallback

test_find_transcript_claude_filesystem_fallback() {
  # Positive control: identical setup resolves for agent=claude.
  local cwd="/tmp/fakeproj-claude"
  local path_key="-tmp-fakeproj-claude"
  mkdir -p "$HOME/.claude/projects/$path_key"
  : > "$HOME/.claude/projects/$path_key/claude-session.jsonl"

  local out
  out=$(find_transcript "claude" "%1" 1234 "$cwd")
  assert_eq "$HOME/.claude/projects/$path_key/claude-session.jsonl" "$out"
}
run_test "claude uses claude filesystem fallback" test_find_transcript_claude_filesystem_fallback

test_find_transcript_pane_variable_priority() {
  # Pane variable (written by the SessionStart hook) wins regardless of agent.
  set_mock_tmux_var "%7" "@transcript_path" "/tmp/from-hook.jsonl"
  local out
  out=$(find_transcript "ren" "%7" 9999 "/tmp/anywhere")
  assert_eq "/tmp/from-hook.jsonl" "$out"
}
run_test "pane variable wins for ren" test_find_transcript_pane_variable_priority

# ----- Public modes end-to-end -----
#
# Exercise the executable surface the spec claims: single-pane default,
# --detail, --read, --all (table + --json), and --layout. Each test runs
# the real agent-state binary against mocked tmux + ps, so the contract
# can't drift without failing.

suite "public modes (--all, --json, --layout, --read, --detail)"

create_mock_ps
export MOCK_PS_OUTPUT="  PID  PPID COMMAND
1001 1000 /usr/local/bin/claude --flag"

# Braille spinner in title (U+2807) — exercises the name-extraction path.
_E2E_TITLE=$'\xe2\xa0\x87 Doing work'
_E2E_TRANSCRIPT="$TEST_TMP/e2e.jsonl"
_E2E_CONTENT="visible scrollback line"

mock_pane "%9" "1001" "$_E2E_TITLE" "/tmp/e2eproj"
set_mock_tmux_capture "%9" "$_E2E_CONTENT"
set_mock_tmux_var "%9" "@session_id" "sess-e2e"
set_mock_tmux_var "%9" "@transcript_path" "$_E2E_TRANSCRIPT"
# Non-empty window name — `read -r` with IFS=$'\t' collapses adjacent tabs
# for whitespace IFS chars, so an empty middle field shifts every column
# one slot left (this is also how real tmux sessions behave — windows
# always have a name).
mock_layout_pane "test" 0 "win" "%9" 0 0 80 24 1001 "$_E2E_TITLE"

# Transcript with stop_reason=end_turn → artifact layer reports idle.
cat > "$_E2E_TRANSCRIPT" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}}
JSONL

test_single_pane_default_json() {
  local out
  out=$("$BIN_DIR/agent-state" "%9")
  assert_json_field "$out" ".pane" "%9"
  assert_json_field "$out" ".agent" "claude"
  assert_json_field "$out" ".state" "idle"
  assert_json_field "$out" ".name" "Doing work"
}
run_test "single pane emits JSON object" test_single_pane_default_json

test_single_pane_detail() {
  local out
  out=$("$BIN_DIR/agent-state" "%9" --detail)
  assert_json_field "$out" ".detail.session_id" "sess-e2e"
  assert_json_field "$out" ".detail.cwd" "/tmp/e2eproj"
  assert_json_field "$out" ".detail.transcript_path" "$_E2E_TRANSCRIPT"
}
run_test "--detail adds detail block" test_single_pane_detail

test_single_pane_read() {
  local out
  out=$("$BIN_DIR/agent-state" "%9" --read)
  assert_json_field "$out" ".content" "$_E2E_CONTENT"
}
run_test "--read adds content field" test_single_pane_read

test_all_table() {
  local out
  out=$("$BIN_DIR/agent-state" --all)
  assert_contains "$out" "PANE"
  assert_contains "$out" "AGENT"
  assert_contains "$out" "STATE"
  assert_contains "$out" "NAME"
  assert_contains "$out" "%9"
  assert_contains "$out" "claude"
  assert_contains "$out" "idle"
}
run_test "--all emits header + row" test_all_table

test_all_json_array() {
  local out
  out=$("$BIN_DIR/agent-state" --all --json)
  assert_json_field "$out" ".[0].pane" "%9"
  assert_json_field "$out" ".[0].agent" "claude"
}
run_test "--all --json emits JSON array" test_all_json_array

test_all_read_forces_json() {
  local out
  out=$("$BIN_DIR/agent-state" --all --read)
  assert_json_field "$out" ".[0].content" "$_E2E_CONTENT"
}
run_test "--all --read forces JSON with content" test_all_read_forces_json

test_all_detail_forces_json() {
  local out
  out=$("$BIN_DIR/agent-state" --all --detail)
  assert_json_field "$out" ".[0].detail.session_id" "sess-e2e"
}
run_test "--all --detail forces JSON with detail" test_all_detail_forces_json

test_layout_renders() {
  local out
  out=$("$BIN_DIR/agent-state" --layout)
  assert_contains "$out" "%9"
  assert_contains "$out" "claude"
}
run_test "--layout renders pane id + agent" test_layout_renders

# ----- agent-state --explain (S3) -----

suite "agent-state --explain"

export MOCK_PS_OUTPUT="  PID  PPID COMMAND
1001 1000 /usr/local/bin/claude --flag
1010 1000 /usr/local/bin/claude --flag
1011 1000 /usr/local/bin/claude --flag
1012 1000 /usr/local/bin/claude --flag"

_EXPLAIN_EVENTSD_TRANSCRIPT="$TEST_TMP/explain-eventsd.jsonl"
cat > "$_EXPLAIN_EVENTSD_TRANSCRIPT" <<'JSONL'
{"type":"user","message":{"role":"user","content":"run it"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"git push"}}]}}
JSONL
_EXPLAIN_EVENTSD_CURSOR=$(wc -c < "$_EXPLAIN_EVENTSD_TRANSCRIPT" | tr -d ' ')
mock_pane "%10" "1010" "Explain evidence" "/tmp/explain-evidence"
set_mock_tmux_capture "%10" ""
set_mock_tmux_var "%10" "@session_id" "sess-explain-evidence"
set_mock_tmux_var "%10" "@transcript_path" "$_EXPLAIN_EVENTSD_TRANSCRIPT"
mkdir -p "$STEEZ_STATE_DIR/eventsd/attention"
cat > "$STEEZ_STATE_DIR/eventsd/attention/_10.json" <<JSON
{"pane_id":"%10","state":"blocked:permission","summary":"waiting for permission approval","detail":"Bash: {\"command\":\"git push\"}","source":"eventsd","session_id":"sess-explain-evidence","transcript_path":"$_EXPLAIN_EVENTSD_TRANSCRIPT","transcript_cursor":$_EXPLAIN_EVENTSD_CURSOR,"observed_at_ms":4242}
JSON

_EXPLAIN_FALLBACK_TRANSCRIPT="$TEST_TMP/explain-fallback.jsonl"
cat > "$_EXPLAIN_FALLBACK_TRANSCRIPT" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_2","name":"AskUserQuestion","input":{"questions":[{"question":"Which environment should I use?"}]}}]}}
JSONL
mock_pane "%11" "1011" "Explain fallback" "/tmp/explain-fallback"
set_mock_tmux_capture "%11" ""
set_mock_tmux_var "%11" "@session_id" "sess-explain-fallback"
set_mock_tmux_var "%11" "@transcript_path" "$_EXPLAIN_FALLBACK_TRANSCRIPT"

_EXPLAIN_STALE_TRANSCRIPT="$TEST_TMP/explain-stale.jsonl"
cat > "$_EXPLAIN_STALE_TRANSCRIPT" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}
JSONL
mock_pane "%12" "1012" "Explain stale" "/tmp/explain-stale"
set_mock_tmux_capture "%12" ""
set_mock_tmux_var "%12" "@session_id" "sess-explain-stale"
set_mock_tmux_var "%12" "@transcript_path" "$_EXPLAIN_STALE_TRANSCRIPT"
cat > "$STEEZ_STATE_DIR/eventsd/attention/_12.json" <<JSON
{"pane_id":"%12","state":"blocked:permission","summary":"waiting for permission approval","detail":"Bash: {\"command\":\"git push\"}","source":"eventsd","session_id":"sess-explain-stale","transcript_path":"$_EXPLAIN_STALE_TRANSCRIPT","transcript_cursor":1,"observed_at_ms":1111}
JSON

test_explain_uses_recent_eventsd_evidence() {
  local out
  out=$("$BIN_DIR/agent-state" "%10" --explain)
  assert_json_field "$out" ".pane" "%10"
  assert_json_field "$out" ".agent" "claude"
  assert_json_field "$out" ".state" "blocked:permission"
  assert_json_field "$out" ".summary" "waiting for permission approval"
  assert_json_field "$out" ".detail" "Bash: {\"command\":\"git push\"}"
  assert_json_field "$out" ".source" "eventsd"
}
run_test "agent-state --explain returns recent terminal reason for the pane" test_explain_uses_recent_eventsd_evidence

test_explain_falls_back_to_artifacts_when_recent_evidence_is_absent() {
  local out
  out=$("$BIN_DIR/agent-state" "%11" --explain)
  assert_json_field "$out" ".pane" "%11"
  assert_json_field "$out" ".agent" "claude"
  assert_json_field "$out" ".state" "blocked:question"
  assert_json_field "$out" ".summary" "waiting for question answer"
  assert_json_field "$out" ".detail" "Which environment should I use?"
  assert_json_field "$out" ".source" "artifacts"
}
run_test "agent-state --explain falls back cleanly when recent evidence is absent" test_explain_falls_back_to_artifacts_when_recent_evidence_is_absent

test_explain_ignores_stale_recent_evidence() {
  local out
  out=$("$BIN_DIR/agent-state" "%12" --explain)
  assert_json_field "$out" ".pane" "%12"
  assert_json_field "$out" ".agent" "claude"
  assert_json_field "$out" ".state" "idle"
  assert_json_field "$out" ".summary" "turn complete"
  assert_json_field "$out" ".source" "artifacts"
}
run_test "agent-state --explain ignores stale recent evidence" test_explain_ignores_stale_recent_evidence

# ----- agent-history blocked inspection -----
#
# Keep Claude blocked inspection transcript-driven. A stale sidecar file must
# not hijack the answer.

suite "agent-history --blocked"

test_agent_history_blocked_uses_transcript_without_sidecar() {
  local transcript_dir="$HOME/.claude/projects/-tmp-blocked-history"
  local transcript="$transcript_dir/blocked-history.jsonl"
  mkdir -p "$transcript_dir"
  cat > "$transcript" <<'JSONL'
{"type":"user","message":{"role":"user","content":"run it"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"git push"}}]}}
JSONL

  local sid="blocked-history"
  local sidecar_dir="$HOME/.steez/agent-state/claude"
  mkdir -p "$sidecar_dir"
  cat > "$sidecar_dir/${sid}.json" <<JSON
{"blocked_state":"blocked:question","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"wrong question"}]},"transcript_path":"$transcript","requested_at":$(date +%s)9999999999}
JSON

  local out
  out=$("$BIN_DIR/agent-history" "$transcript" --blocked)
  assert_json_field "$out" ".agent" "claude"
  assert_json_field "$out" ".tool" "Bash"
  assert_json_field "$out" ".input.command" "git push"
}
run_test "agent-history --blocked ignores Claude sidecar files" \
  test_agent_history_blocked_uses_transcript_without_sidecar

report
