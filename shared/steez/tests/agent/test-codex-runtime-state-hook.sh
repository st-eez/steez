#!/usr/bin/env bash
# Unit tests for `shared/steez/hooks/codex-stop.sh` as a dual-event
# (Stop + UserPromptSubmit) runtime-state producer.
#
# Covered here:
#
#   Stop payload              -> evidence idle + runtime idle + lease unset + JSON continue
#   UserPromptSubmit payload  -> no evidence + runtime working + lease set + JSON continue
#   No hook_event_name        -> behaves like Stop (legacy payload shape)
#   No TMUX_PANE              -> no evidence, no tmux writes (early exit)
#
# `$HOME/.steez/bin/agent-eventsd` is the absolute path the hook
# hard-codes for evidence dispatch; a recorder script at that path
# captures every invocation. The tmux binary resolves through
# `$MOCK_BIN` (setup_test_env prepends it to PATH) so we can shadow
# real tmux with a simple argv recorder. Specs: specs/agent-events.md
# (Codex Stop hook, Runtime pane state producers).
set -uo pipefail
source "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/shared/steez/hooks/codex-stop.sh"

command -v jq      >/dev/null 2>&1 || { echo "  skip: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  skip: python3 not installed"; exit 0; }

setup_hook_env() {
  setup_test_env
  RECORDER_LOG="$TEST_TMP/agent-eventsd-calls.log"
  TMUX_LOG="$TEST_TMP/tmux-calls.log"
  : > "$RECORDER_LOG"
  : > "$TMUX_LOG"
  mkdir -p "$HOME/.steez/bin"
  cat > "$HOME/.steez/bin/agent-eventsd" <<RECORDER_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$RECORDER_LOG'
exit 0
RECORDER_EOF
  chmod +x "$HOME/.steez/bin/agent-eventsd"

  cat > "$MOCK_BIN/tmux" <<TMUX_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMUX_LOG'
exit 0
TMUX_EOF
  chmod +x "$MOCK_BIN/tmux"
  export TMUX_LOG
}

cleanup_hook_env() {
  cleanup_test_env
}

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

wait_no_dispatch() { sleep 0.3; }

run_hook_with() {
  local payload="$1"
  TMUX_PANE="${TMUX_PANE:-}" HOME="$HOME" PATH="$PATH" \
    bash "$HOOK" <<<"$payload"
}

suite "codex-stop.sh: Stop event"

test_stop_event_with_hook_event_name_dispatches_evidence_and_writes_idle_runtime_state() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  local transcript="$TEST_TMP/codex-transcript.jsonl"
  printf 'prompt\nresponse\n' > "$transcript"
  local expected_cursor
  expected_cursor=$(wc -c < "$transcript" | tr -d ' ')

  local payload
  payload=$(jq -cn --arg tp "$transcript" \
    '{session_id:"test-session", transcript_path:$tp, hook_event_name:"Stop"}')
  local out
  out=$(TMUX_PANE="%42" run_hook_with "$payload")

  assert_eq '{"continue":true}' "$out"

  wait_recorder_lines 1 || {
    echo "    Stop never dispatched evidence (recorder empty)"
    exit 1
  }
  local ev_logged
  ev_logged=$(cat "$RECORDER_LOG")
  assert_contains "$ev_logged" "evidence"
  assert_contains "$ev_logged" "--pane %42"
  assert_contains "$ev_logged" "--state idle"
  assert_contains "$ev_logged" "--transcript-cursor $expected_cursor"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %42 @agent_runtime_state idle"
  assert_contains "$tmux_logged" "set-option -p -t %42 -u @agent_runtime_expires_ms"
}
run_test "Stop with hook_event_name dispatches idle evidence and writes idle runtime state" \
  test_stop_event_with_hook_event_name_dispatches_evidence_and_writes_idle_runtime_state

test_stop_event_missing_hook_event_name_still_treated_as_stop() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  # Legacy payload shape: no hook_event_name. Previously this hook was
  # registered for Stop only; that registration is still supported and
  # must continue to behave like Stop.
  local transcript="$TEST_TMP/legacy-transcript.jsonl"
  printf 'x\n' > "$transcript"
  local payload
  payload=$(jq -cn --arg tp "$transcript" '{transcript_path:$tp}')
  local out
  out=$(TMUX_PANE="%43" run_hook_with "$payload")

  assert_eq '{"continue":true}' "$out"

  wait_recorder_lines 1 || {
    echo "    legacy Stop payload never dispatched evidence"
    exit 1
  }
  local ev_logged tmux_logged
  ev_logged=$(cat "$RECORDER_LOG")
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$ev_logged" "--pane %43"
  assert_contains "$ev_logged" "--state idle"
  assert_contains "$tmux_logged" "set-option -p -t %43 @agent_runtime_state idle"
  assert_contains "$tmux_logged" "set-option -p -t %43 -u @agent_runtime_expires_ms"
}
run_test "legacy Stop payload without hook_event_name still dispatches idle and writes idle runtime state" \
  test_stop_event_missing_hook_event_name_still_treated_as_stop

test_stop_event_without_tmux_pane_does_not_touch_evidence_or_tmux() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  unset TMUX_PANE
  local payload
  payload=$(jq -cn '{session_id:"x", hook_event_name:"Stop"}')
  run_hook_with "$payload" || true

  wait_no_dispatch
  local ev_logged tmux_logged
  ev_logged=$(cat "$RECORDER_LOG")
  tmux_logged=$(cat "$TMUX_LOG")
  [[ -z "$ev_logged"   ]] || { echo "    Stop w/o TMUX_PANE dispatched evidence: $ev_logged"; exit 1; }
  [[ -z "$tmux_logged" ]] || { echo "    Stop w/o TMUX_PANE touched tmux:  $tmux_logged"; exit 1; }
}
run_test "Stop without TMUX_PANE skips evidence dispatch and tmux writes" \
  test_stop_event_without_tmux_pane_does_not_touch_evidence_or_tmux

suite "codex-stop.sh: UserPromptSubmit event"

test_user_prompt_submit_writes_working_lease_and_does_not_dispatch_evidence() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  local before_ms
  before_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  local payload
  payload=$(jq -cn '{session_id:"test-session", hook_event_name:"UserPromptSubmit"}')
  local out
  out=$(TMUX_PANE="%77" run_hook_with "$payload")

  local after_ms
  after_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  assert_eq '{"continue":true}' "$out"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %77 @agent_runtime_state working"

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

  wait_no_dispatch
  local ev_logged
  ev_logged=$(cat "$RECORDER_LOG")
  [[ -z "$ev_logged" ]] || {
    echo "    UserPromptSubmit must not dispatch evidence, saw:"
    printf '%s\n' "$ev_logged" | sed 's/^/      /'
    exit 1
  }
}
run_test "UserPromptSubmit writes working runtime state with a near-now @agent_runtime_expires_ms lease" \
  test_user_prompt_submit_writes_working_lease_and_does_not_dispatch_evidence

test_user_prompt_submit_without_tmux_pane_does_not_touch_tmux() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  unset TMUX_PANE
  local payload
  payload=$(jq -cn '{hook_event_name:"UserPromptSubmit"}')
  run_hook_with "$payload" || true

  wait_no_dispatch
  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  [[ -z "$tmux_logged" ]] || {
    echo "    UserPromptSubmit w/o TMUX_PANE touched tmux: $tmux_logged"
    exit 1
  }
}
run_test "UserPromptSubmit without TMUX_PANE skips tmux writes" \
  test_user_prompt_submit_without_tmux_pane_does_not_touch_tmux

report
