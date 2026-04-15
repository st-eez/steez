#!/usr/bin/env bash
# Unit tests for `shared/steez/hooks/permission-state.sh`.
#
# Scope: the hook MUST shell out to `agent-eventsd evidence` on the hook
# events that carry canonical turn-end / blocked information. Covered here:
#
#   Stop                            -> evidence --state idle
#   PermissionRequest (AskUserQuestion) -> evidence --state blocked:question
#   PermissionRequest (other tool)  -> evidence --state blocked:permission
#   PreToolUse (AskUserQuestion)    -> evidence --state blocked:question
#   PreToolUse (other tool)         -> no evidence call
#   PostToolUse / UserPromptSubmit  -> no evidence call
#   Stop without TMUX_PANE          -> no evidence call
#
# A recorder script at `$HOME/.steez/bin/agent-eventsd` (the absolute path
# the hook hard-codes) captures every invocation's argv. Assertions read
# from that log. All dispatches are fire-and-forget in the hook, so each
# test waits briefly for the background CLI call to flush before
# asserting. Specs: specs/agent-events.md (Event surface).
set -uo pipefail
source "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/shared/steez/hooks/permission-state.sh"

command -v jq      >/dev/null 2>&1 || { echo "  skip: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  skip: python3 not installed"; exit 0; }

setup_hook_env() {
  setup_test_env
  RECORDER_LOG="$TEST_TMP/agent-eventsd-calls.log"
  : > "$RECORDER_LOG"
  mkdir -p "$HOME/.steez/bin" "$HOME/.steez/agent-state/claude"
  cat > "$HOME/.steez/bin/agent-eventsd" <<RECORDER_EOF
#!/usr/bin/env bash
# Recorder: write argv to a log so tests can assert what the hook
# dispatched. Exit 0 so the hook sees a successful fire-and-forget.
printf '%s\n' "\$*" >> '$RECORDER_LOG'
exit 0
RECORDER_EOF
  chmod +x "$HOME/.steez/bin/agent-eventsd"
}

cleanup_hook_env() {
  cleanup_test_env
}

# Wait for the backgrounded dispatch (& disown) to flush at least N lines
# to the recorder log, or return non-zero on timeout.
wait_recorder_lines() {
  local want="$1" timeout_ms="${2:-1000}"
  local deadline i have
  deadline=$(python3 -c "import time; print(int(time.time()*1000))")
  deadline=$(( deadline + timeout_ms ))
  while :; do
    have=$(wc -l < "$RECORDER_LOG" 2>/dev/null | tr -d ' ')
    [[ "${have:-0}" -ge "$want" ]] && return 0
    i=$(python3 -c "import time; print(int(time.time()*1000))")
    (( i >= deadline )) && return 1
    sleep 0.05
  done
}

# Settle wait for the "no dispatch" tests: there is no signal to wait on,
# so we just let any stray background CLI run to completion.
wait_no_dispatch() { sleep 0.3; }

run_hook_with() {
  local payload="$1"
  local extra_env="${2:-}"
  # shellcheck disable=SC2086
  TMUX_PANE="${TMUX_PANE:-}" HOME="$HOME" PATH="$PATH" $extra_env \
    bash "$HOOK" <<<"$payload"
}

build_payload() {
  local hook_event="$1" tool_name="${2:-}" transcript_path="${3:-}" session_id="${4:-test-session}"
  jq -n \
    --arg sid "$session_id" \
    --arg hen "$hook_event" \
    --arg tn  "$tool_name" \
    --arg tp  "$transcript_path" \
    '{session_id:$sid, hook_event_name:$hen}
     + (if $tn != "" then {tool_name:$tn} else {} end)
     + (if $tp != "" then {transcript_path:$tp} else {} end)'
}

suite "permission-state.sh: agent-eventsd evidence dispatch"

test_stop_hook_dispatches_idle_evidence_with_pane_and_transcript_cursor() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  local transcript="$TEST_TMP/target-transcript.jsonl"
  printf '%s\n' '{"type":"user"}' > "$transcript"
  printf '%s\n' '{"type":"assistant","stop_reason":"end_turn"}' >> "$transcript"
  local expected_cursor
  expected_cursor=$(wc -c < "$transcript" | tr -d ' ')

  TMUX_PANE="%42" run_hook_with "$(build_payload Stop "" "$transcript")"

  wait_recorder_lines 1 || {
    echo "    Stop hook never dispatched evidence (recorder log empty)"
    exit 1
  }

  local logged
  logged=$(cat "$RECORDER_LOG")
  assert_contains "$logged" "evidence"
  assert_contains "$logged" "--pane %42"
  assert_contains "$logged" "--state idle"
  assert_contains "$logged" "--transcript-cursor $expected_cursor"
}
run_test "Stop dispatches idle evidence with --pane, --state idle, and --transcript-cursor" \
  test_stop_hook_dispatches_idle_evidence_with_pane_and_transcript_cursor

test_permission_request_with_ask_user_question_dispatches_blocked_question() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%7" run_hook_with "$(build_payload PermissionRequest AskUserQuestion)"

  wait_recorder_lines 1 || {
    echo "    PermissionRequest(AskUserQuestion) never dispatched evidence"
    exit 1
  }
  local logged
  logged=$(cat "$RECORDER_LOG")
  assert_contains "$logged" "--pane %7"
  assert_contains "$logged" "--state blocked:question"
}
run_test "PermissionRequest AskUserQuestion dispatches blocked:question evidence" \
  test_permission_request_with_ask_user_question_dispatches_blocked_question

test_permission_request_with_other_tool_dispatches_blocked_permission() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%9" run_hook_with "$(build_payload PermissionRequest Bash)"

  wait_recorder_lines 1 || {
    echo "    PermissionRequest(Bash) never dispatched evidence"
    exit 1
  }
  local logged
  logged=$(cat "$RECORDER_LOG")
  assert_contains "$logged" "--pane %9"
  assert_contains "$logged" "--state blocked:permission"
}
run_test "PermissionRequest non-AskUserQuestion dispatches blocked:permission evidence" \
  test_permission_request_with_other_tool_dispatches_blocked_permission

test_pre_tool_use_ask_user_question_dispatches_blocked_question() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%11" run_hook_with "$(build_payload PreToolUse AskUserQuestion)"

  wait_recorder_lines 1 || {
    echo "    PreToolUse(AskUserQuestion) never dispatched evidence"
    exit 1
  }
  local logged
  logged=$(cat "$RECORDER_LOG")
  assert_contains "$logged" "--pane %11"
  assert_contains "$logged" "--state blocked:question"
}
run_test "PreToolUse AskUserQuestion dispatches blocked:question evidence" \
  test_pre_tool_use_ask_user_question_dispatches_blocked_question

test_pre_tool_use_other_tool_does_not_dispatch_evidence() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%13" run_hook_with "$(build_payload PreToolUse Bash)"

  wait_no_dispatch
  local logged
  logged=$(cat "$RECORDER_LOG")
  [[ -z "$logged" ]] || {
    echo "    PreToolUse(Bash) should not dispatch evidence, saw:"
    printf '%s\n' "$logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "PreToolUse non-AskUserQuestion does not dispatch evidence" \
  test_pre_tool_use_other_tool_does_not_dispatch_evidence

test_post_tool_use_does_not_dispatch_evidence() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%15" run_hook_with "$(build_payload PostToolUse Bash)"

  wait_no_dispatch
  local logged
  logged=$(cat "$RECORDER_LOG")
  [[ -z "$logged" ]] || {
    echo "    PostToolUse should not dispatch evidence (sidecar-clear only), saw:"
    printf '%s\n' "$logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "PostToolUse does not dispatch evidence (sidecar-clear only)" \
  test_post_tool_use_does_not_dispatch_evidence

test_user_prompt_submit_does_not_dispatch_evidence() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%17" run_hook_with "$(build_payload UserPromptSubmit)"

  wait_no_dispatch
  local logged
  logged=$(cat "$RECORDER_LOG")
  [[ -z "$logged" ]] || {
    echo "    UserPromptSubmit should not dispatch evidence, saw:"
    printf '%s\n' "$logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "UserPromptSubmit does not dispatch evidence" \
  test_user_prompt_submit_does_not_dispatch_evidence

test_stop_without_tmux_pane_does_not_dispatch_evidence() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  unset TMUX_PANE
  run_hook_with "$(build_payload Stop)"

  wait_no_dispatch
  local logged
  logged=$(cat "$RECORDER_LOG")
  [[ -z "$logged" ]] || {
    echo "    Stop without TMUX_PANE should not dispatch evidence, saw:"
    printf '%s\n' "$logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "Stop without TMUX_PANE does not dispatch evidence" \
  test_stop_without_tmux_pane_does_not_dispatch_evidence

report
