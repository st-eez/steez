#!/usr/bin/env bash
# Unit tests for `shared/steez/hooks/permission-state.sh`.
#
# The hook has two responsibilities on each Claude lifecycle event:
#
#   1. Fast-path fire-and-forget dispatch to `agent-eventsd evidence`
#      on the subset of events that carry a canonical turn boundary.
#   2. Synchronous publication of canonical runtime pane state via
#      `tmux set-option -p -t <pane> @agent_runtime_state [...]`. That
#      option is how consumers (agent-state) observe live state
#      without scraping the transcript.
#
# Covered here:
#
#   Stop                               -> evidence idle + runtime idle + lease unset
#   PermissionRequest(AskUserQuestion) -> evidence blocked:question + sticky blocked:question
#   PermissionRequest(other)           -> evidence blocked:permission + sticky blocked:permission
#   PreToolUse(AskUserQuestion)        -> evidence blocked:question + sticky blocked:question
#   UserPromptSubmit                   -> no evidence + working lease with @agent_runtime_expires_ms
#   PreToolUse(other)                  -> no evidence, no runtime state write
#   Stop without TMUX_PANE             -> no evidence, no tmux calls
#
# Each test installs a recorder at `$HOME/.steez/bin/agent-eventsd`
# (the absolute path the hook hard-codes) and a recorder at
# `$MOCK_BIN/tmux` (shadowing the real tmux via PATH). Assertions read
# from those logs. Evidence dispatch is fire-and-forget; runtime-state
# writes are synchronous. Specs: specs/agent-events.md
# (Event surface, Runtime pane state producers).
set -uo pipefail
source "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/shared/steez/hooks/permission-state.sh"

command -v jq      >/dev/null 2>&1 || { echo "  skip: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  skip: python3 not installed"; exit 0; }

setup_hook_env() {
  setup_test_env
  RECORDER_LOG="$TEST_TMP/agent-eventsd-calls.log"
  TMUX_LOG="$TEST_TMP/tmux-calls.log"
  SKETCHYBAR_LOG="$TEST_TMP/sketchybar-calls.log"
  : > "$RECORDER_LOG"
  : > "$TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  mkdir -p "$HOME/.steez/bin" "$HOME/.steez/agent-state/claude"
  cat > "$HOME/.steez/bin/agent-eventsd" <<RECORDER_EOF
#!/usr/bin/env bash
# Recorder: write argv to a log so tests can assert what the hook
# dispatched. Exit 0 so the hook sees a successful fire-and-forget.
printf '%s\n' "\$*" >> '$RECORDER_LOG'
exit 0
RECORDER_EOF
  chmod +x "$HOME/.steez/bin/agent-eventsd"

  # Tmux recorder. Simpler than create_mock_tmux because these tests
  # assert on tmux argv directly and don't need a pane-table mock. The
  # mock is installed in MOCK_BIN, which setup_test_env prepended to
  # PATH, so the hook's `tmux` call resolves here before any real
  # tmux on the host.
  cat > "$MOCK_BIN/tmux" <<TMUX_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMUX_LOG'
exit 0
TMUX_EOF
  chmod +x "$MOCK_BIN/tmux"
  export TMUX_LOG

  # SketchyBar recorder. The runtime-state publisher fires
  # `sketchybar --trigger agent_attention_changed` after it writes
  # pane options so the macOS bar refreshes without waiting for its
  # 5s poll. The mock logs argv and exits 0 so the fire-and-forget
  # call is observable.
  cat > "$MOCK_BIN/sketchybar" <<SKETCHYBAR_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$SKETCHYBAR_LOG'
exit 0
SKETCHYBAR_EOF
  chmod +x "$MOCK_BIN/sketchybar"
  export SKETCHYBAR_LOG
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

  [[ ! -e "$HOME/.steez/agent-state/claude/test-session.json" ]] || {
    echo "    hook should not write Claude sidecar state"
    exit 1
  }
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
  logged=$(cat "$TMUX_LOG")
  [[ -z "$logged" ]] || {
    echo "    Stop without TMUX_PANE should not touch tmux, saw:"
    printf '%s\n' "$logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "Stop without TMUX_PANE does not dispatch evidence or touch tmux" \
  test_stop_without_tmux_pane_does_not_dispatch_evidence

suite "permission-state.sh: @agent_runtime_state pane-option publisher"

test_stop_hook_writes_idle_runtime_state_and_clears_lease() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%42" run_hook_with "$(build_payload Stop)"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %42 @agent_runtime_state idle"
  assert_contains "$tmux_logged" "set-option -p -t %42 -u @agent_runtime_expires_ms"
}
run_test "Stop writes @agent_runtime_state=idle and unsets @agent_runtime_expires_ms" \
  test_stop_hook_writes_idle_runtime_state_and_clears_lease

test_user_prompt_submit_writes_working_lease_with_expires_ms() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  local before_ms
  before_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  TMUX_PANE="%21" run_hook_with "$(build_payload UserPromptSubmit)"

  local after_ms
  after_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %21 @agent_runtime_state working"

  # Lease line: `set-option -p -t %21 @agent_runtime_expires_ms <ms>`
  # The ms value must be (now_ms_at_hook + 10000), bracketed by the
  # before/after wall-clock times we captured.
  local lease_ms
  lease_ms=$(grep -oE '@agent_runtime_expires_ms [0-9]+' "$TMUX_LOG" | head -1 | awk '{print $2}')
  [[ -n "$lease_ms" ]] || {
    echo "    UserPromptSubmit never wrote @agent_runtime_expires_ms, tmux log:"
    printf '%s\n' "$tmux_logged" | sed 's/^/      /'
    exit 1
  }

  local lo=$(( before_ms + 10000 - 500 ))
  local hi=$(( after_ms  + 10000 + 500 ))
  if (( lease_ms < lo )) || (( lease_ms > hi )); then
    echo "    @agent_runtime_expires_ms=$lease_ms outside expected window [$lo,$hi]"
    exit 1
  fi

  # UserPromptSubmit must NOT dispatch evidence; working is not terminal.
  wait_no_dispatch
  local ev_logged
  ev_logged=$(cat "$RECORDER_LOG")
  [[ -z "$ev_logged" ]] || {
    echo "    UserPromptSubmit must not dispatch evidence, saw:"
    printf '%s\n' "$ev_logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "UserPromptSubmit writes @agent_runtime_state=working with a near-now @agent_runtime_expires_ms lease" \
  test_user_prompt_submit_writes_working_lease_with_expires_ms

test_permission_request_ask_user_question_writes_sticky_blocked_question() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%7" run_hook_with "$(build_payload PermissionRequest AskUserQuestion)"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %7 @agent_runtime_state blocked:question"
  assert_contains "$tmux_logged" "set-option -p -t %7 -u @agent_runtime_expires_ms"
}
run_test "PermissionRequest AskUserQuestion writes sticky @agent_runtime_state=blocked:question" \
  test_permission_request_ask_user_question_writes_sticky_blocked_question

test_permission_request_other_tool_writes_sticky_blocked_permission() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%9" run_hook_with "$(build_payload PermissionRequest Bash)"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %9 @agent_runtime_state blocked:permission"
  assert_contains "$tmux_logged" "set-option -p -t %9 -u @agent_runtime_expires_ms"
}
run_test "PermissionRequest non-AskUserQuestion writes sticky @agent_runtime_state=blocked:permission" \
  test_permission_request_other_tool_writes_sticky_blocked_permission

test_pre_tool_use_ask_user_question_writes_sticky_blocked_question() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%11" run_hook_with "$(build_payload PreToolUse AskUserQuestion)"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %11 @agent_runtime_state blocked:question"
  assert_contains "$tmux_logged" "set-option -p -t %11 -u @agent_runtime_expires_ms"
}
run_test "PreToolUse AskUserQuestion writes sticky @agent_runtime_state=blocked:question" \
  test_pre_tool_use_ask_user_question_writes_sticky_blocked_question

test_pre_tool_use_other_tool_does_not_touch_tmux() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%13" run_hook_with "$(build_payload PreToolUse Bash)"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  [[ -z "$tmux_logged" ]] || {
    echo "    PreToolUse(Bash) must not touch tmux pane options, saw:"
    printf '%s\n' "$tmux_logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "PreToolUse non-AskUserQuestion does not touch @agent_runtime_state" \
  test_pre_tool_use_other_tool_does_not_touch_tmux

test_user_prompt_submit_without_tmux_pane_does_not_touch_tmux() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  unset TMUX_PANE
  run_hook_with "$(build_payload UserPromptSubmit)"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  [[ -z "$tmux_logged" ]] || {
    echo "    UserPromptSubmit without TMUX_PANE must not touch tmux, saw:"
    printf '%s\n' "$tmux_logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "UserPromptSubmit without TMUX_PANE does not touch @agent_runtime_state" \
  test_user_prompt_submit_without_tmux_pane_does_not_touch_tmux

suite "permission-state.sh: SketchyBar runtime-state refresh trigger"

# Every canonical runtime-state transition the hook publishes also fires
# `sketchybar --trigger agent_attention_changed` best-effort, so the macOS
# bar's agent cluster refreshes as soon as working/idle/blocked changes
# instead of waiting for its 5s poll. The call must not block the hook's
# 5s timeout. Events that do not publish runtime state (PreToolUse(Bash),
# missing TMUX_PANE) must not fire the trigger either — otherwise SketchyBar
# would refresh on lifecycle events that did not change pane state.
# Spec: specs/agent-events.md (Runtime pane state producers — SketchyBar sink).

test_stop_hook_triggers_sketchybar_runtime_refresh() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%42" run_hook_with "$(build_payload Stop)"

  local sb_logged
  sb_logged=$(cat "$SKETCHYBAR_LOG")
  assert_contains "$sb_logged" "--trigger agent_attention_changed"
}
run_test "Stop triggers sketchybar agent_attention_changed refresh" \
  test_stop_hook_triggers_sketchybar_runtime_refresh

test_user_prompt_submit_triggers_sketchybar_runtime_refresh() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%21" run_hook_with "$(build_payload UserPromptSubmit)"

  local sb_logged
  sb_logged=$(cat "$SKETCHYBAR_LOG")
  assert_contains "$sb_logged" "--trigger agent_attention_changed"
}
run_test "UserPromptSubmit triggers sketchybar agent_attention_changed refresh" \
  test_user_prompt_submit_triggers_sketchybar_runtime_refresh

test_permission_request_ask_user_question_triggers_sketchybar() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%7" run_hook_with "$(build_payload PermissionRequest AskUserQuestion)"

  local sb_logged
  sb_logged=$(cat "$SKETCHYBAR_LOG")
  assert_contains "$sb_logged" "--trigger agent_attention_changed"
}
run_test "PermissionRequest AskUserQuestion triggers sketchybar refresh" \
  test_permission_request_ask_user_question_triggers_sketchybar

test_permission_request_other_tool_triggers_sketchybar() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%9" run_hook_with "$(build_payload PermissionRequest Bash)"

  local sb_logged
  sb_logged=$(cat "$SKETCHYBAR_LOG")
  assert_contains "$sb_logged" "--trigger agent_attention_changed"
}
run_test "PermissionRequest non-AskUserQuestion triggers sketchybar refresh" \
  test_permission_request_other_tool_triggers_sketchybar

test_pre_tool_use_ask_user_question_triggers_sketchybar() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%11" run_hook_with "$(build_payload PreToolUse AskUserQuestion)"

  local sb_logged
  sb_logged=$(cat "$SKETCHYBAR_LOG")
  assert_contains "$sb_logged" "--trigger agent_attention_changed"
}
run_test "PreToolUse AskUserQuestion triggers sketchybar refresh" \
  test_pre_tool_use_ask_user_question_triggers_sketchybar

test_pre_tool_use_other_tool_does_not_trigger_sketchybar() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  TMUX_PANE="%13" run_hook_with "$(build_payload PreToolUse Bash)"

  local sb_logged
  sb_logged=$(cat "$SKETCHYBAR_LOG")
  [[ -z "$sb_logged" ]] || {
    echo "    PreToolUse(Bash) must not trigger sketchybar (no runtime-state write), saw:"
    printf '%s\n' "$sb_logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "PreToolUse non-AskUserQuestion does not trigger sketchybar" \
  test_pre_tool_use_other_tool_does_not_trigger_sketchybar

test_stop_without_tmux_pane_does_not_trigger_sketchybar() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  unset TMUX_PANE
  run_hook_with "$(build_payload Stop)"

  local sb_logged
  sb_logged=$(cat "$SKETCHYBAR_LOG")
  [[ -z "$sb_logged" ]] || {
    echo "    Stop without TMUX_PANE must not trigger sketchybar, saw:"
    printf '%s\n' "$sb_logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "Stop without TMUX_PANE does not trigger sketchybar" \
  test_stop_without_tmux_pane_does_not_trigger_sketchybar

test_sketchybar_missing_does_not_break_hook() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  # Remove the sketchybar mock so `command -v sketchybar` fails. The hook
  # must still publish runtime state without erroring out — macOS-bar
  # refresh is best-effort. A missing binary cannot be allowed to hold
  # the hook open past its 5s timeout or break Claude's own lifecycle.
  rm -f "$MOCK_BIN/sketchybar"

  local rc=0
  TMUX_PANE="%42" run_hook_with "$(build_payload Stop)" || rc=$?
  assert_eq 0 "$rc"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %42 @agent_runtime_state idle"
}
run_test "sketchybar missing from PATH does not break runtime-state publish" \
  test_sketchybar_missing_does_not_break_hook

report
