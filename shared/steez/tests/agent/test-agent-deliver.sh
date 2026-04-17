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

suite "agent-deliver canonical pane resolution"

mock_pane_alias "mac:0.1" "%5"

test_uses_canonical_pane_downstream() {
  # The alias lives in MOCK_AGENT_PANES too, otherwise the initial
  # agent-state guard would reject the raw argument before resolution runs.
  export MOCK_AGENT_PANES="%5 mac:0.1"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-canonical.log"
  : > "$MOCK_TMUX_LOG"

  "$BIN_DIR/agent-deliver" mac:0.1 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local paste_line
  paste_line=$(grep '^paste-buffer ' "$MOCK_TMUX_LOG") \
    || { echo "paste-buffer never called"; cat "$MOCK_TMUX_LOG"; exit 1; }
  assert_contains "$paste_line" "-t %5"
  assert_not_contains "$paste_line" "mac:0.1"

  local enter_line
  enter_line=$(grep '^send-keys ' "$MOCK_TMUX_LOG" | head -1) \
    || { echo "send-keys never called"; cat "$MOCK_TMUX_LOG"; exit 1; }
  assert_contains "$enter_line" "-t %5 Enter"
  assert_not_contains "$enter_line" "mac:0.1"

  unset MOCK_TMUX_LOG
  export MOCK_AGENT_PANES="%5"
}
run_test "resolves raw pane to canonical %N before paste-buffer and send-keys" \
  test_uses_canonical_pane_downstream

suite "agent-deliver retry-Enter"

test_retries_enter_when_agent_still_idle() {
  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-idle.log"
  : > "$MOCK_TMUX_LOG"

  local deliver_out
  deliver_out=$("$BIN_DIR/agent-deliver" %5 "hello" 2>&1) \
    || { echo "deliver failed: $deliver_out"; exit 1; }

  # Expect two Enters: the mandatory delayed Enter + the idle-detected retry.
  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "2" "$enter_count"

  unset MOCK_TMUX_LOG
}
run_test "sends second Enter when post-delivery state is idle" \
  test_retries_enter_when_agent_still_idle

test_skips_retry_when_first_enter_advanced_transcript_cursor() {
  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-transcript.log"
  : > "$MOCK_TMUX_LOG"

  local transcript="$TEST_TMP/transcript.jsonl"
  : > "$transcript"
  export TEST_TRANSCRIPT_PATH="$transcript"

  create_mock_script "$HOME/.steez/bin/agent-state" \
    '[[ $# -ge 1 && -n "$1" ]] || { echo "error: specify a pane target or use --all" >&2; exit 1; }
     PANE="$1"
     shift
     if [[ " ${MOCK_AGENT_PANES:-} " != *" $PANE "* ]]; then
       echo "error: pane '\''$PANE'\'' is not a recognized AI agent" >&2
       exit 1
     fi
     if [[ "${1:-}" == "--detail" ]]; then
       printf "{\"pane\":\"%s\",\"agent\":\"codex\",\"state\":\"idle\",\"name\":\"test\",\"detail\":{\"session_id\":\"sid\",\"cwd\":\"/tmp\",\"transcript_path\":\"%s\"}}\n" "$PANE" "$TEST_TRANSCRIPT_PATH"
       exit 0
     fi
     printf "{\"pane\":\"%s\",\"agent\":\"codex\",\"state\":\"idle\",\"name\":\"test\"}\n" "$PANE"
     exit 0'

  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
set -euo pipefail

[[ -n "${MOCK_TMUX_LOG:-}" ]] && printf '%s\n' "$*" >> "$MOCK_TMUX_LOG"

case "${1:-}" in
  display-message)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "-p" ]] || exit 1
    printf '%s\n' '%5'
    ;;
  load-buffer)
    [[ "${2:-}" == "-b" && "${4:-}" == "-" ]] || exit 1
    cat > /dev/null
    ;;
  paste-buffer)
    [[ "${2:-}" == "-b" && "${4:-}" == "-t" && "${5:-}" == "%5" && "${6:-}" == "-d" ]] || exit 1
    ;;
  send-keys)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "Enter" ]] || exit 1
    count_file="${TEST_TRANSCRIPT_PATH}.enter-count"
    count=0
    [[ -f "$count_file" ]] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [[ "$count" -eq 1 ]]; then
      printf 'x' >> "$TEST_TRANSCRIPT_PATH"
    fi
    ;;
  show-options)
    [[ "${2:-}" == "-pv" && "${3:-}" == "-t" && "${4:-}" == "%5" && "${5:-}" == "@transcript_path" ]] || exit 1
    printf '%s\n' "$TEST_TRANSCRIPT_PATH"
    ;;
  delete-buffer)
    ;;
  *)
    exit 1
    ;;
esac
TMUX_MOCK
  chmod +x "$MOCK_BIN/tmux"

  "$BIN_DIR/agent-deliver" %5 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "1" "$enter_count"

  unset TEST_TRANSCRIPT_PATH
  unset MOCK_TMUX_LOG
  create_mock_tmux
}
run_test "skips retry Enter when the first Enter already advanced the transcript" \
  test_skips_retry_when_first_enter_advanced_transcript_cursor

test_no_retry_when_agent_already_working() {
  create_mock_tmux
  setup_agent_mocks claude working

  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-working.log"
  : > "$MOCK_TMUX_LOG"

  "$BIN_DIR/agent-deliver" %5 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "1" "$enter_count"

  setup_agent_mocks
  unset MOCK_TMUX_LOG
}
run_test "skips retry Enter when post-delivery state is working" \
  test_no_retry_when_agent_already_working

# ---------------------------------------------------------------------------
# Deadline-polled retry window
# ---------------------------------------------------------------------------
#
# The retry window is now a 25ms-tick, 500ms-deadline poll instead of a fixed
# 0.2s sleep. Each tick re-checks @transcript_path cursor and agent-state; an
# early exit fires on transcript growth (first Enter landed) or a state change
# away from idle (agent is processing). The retry guard after the loop fires
# only when we cannot prove growth. These tests cover the three shapes the
# loop and guard need to get right:
#
#   - BEFORE @transcript_path was unset (no baseline to compare AFTER against)
#   - Deadline expires with no progress (pane truly stuck in composer)
#   - Cursor advances mid-poll (fast turn — early exit, no duplicate Enter)

test_retries_when_before_transcript_path_was_unset() {
  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-before-empty.log"
  : > "$MOCK_TMUX_LOG"

  local transcript="$TEST_TMP/transcript-before-empty.jsonl"
  : > "$transcript"
  export TEST_TRANSCRIPT_PATH="$transcript"
  export SHOW_OPTIONS_COUNTER="$TEST_TMP/show-options-before-empty.count"
  rm -f "$SHOW_OPTIONS_COUNTER"

  create_mock_script "$HOME/.steez/bin/agent-state" \
    '[[ $# -ge 1 && -n "$1" ]] || { echo "error: specify a pane target or use --all" >&2; exit 1; }
     PANE="$1"
     if [[ " ${MOCK_AGENT_PANES:-} " != *" $PANE "* ]]; then
       echo "error: pane '\''$PANE'\'' is not a recognized AI agent" >&2
       exit 1
     fi
     printf "{\"pane\":\"%s\",\"agent\":\"codex\",\"state\":\"idle\",\"name\":\"test\"}\n" "$PANE"
     exit 0'

  # show-options returns empty on the 1st call (BEFORE capture) and a real
  # path on every subsequent call — simulates @transcript_path being unset
  # when delivery starts and appearing mid-delivery (session rotation / late
  # pane var). BEFORE path empty + AFTER populated with no shared baseline
  # means we cannot prove growth and must retry.
  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
set -uo pipefail

[[ -n "${MOCK_TMUX_LOG:-}" ]] && printf '%s\n' "$*" >> "$MOCK_TMUX_LOG"

case "${1:-}" in
  display-message)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "-p" ]] || exit 1
    printf '%s\n' '%5'
    ;;
  load-buffer) cat > /dev/null ;;
  paste-buffer|delete-buffer) ;;
  send-keys)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "Enter" ]] || exit 1
    ;;
  show-options)
    [[ "${2:-}" == "-pv" && "${3:-}" == "-t" && "${4:-}" == "%5" && "${5:-}" == "@transcript_path" ]] || exit 1
    count=0
    [[ -f "$SHOW_OPTIONS_COUNTER" ]] && count=$(cat "$SHOW_OPTIONS_COUNTER")
    count=$((count + 1))
    printf '%s\n' "$count" > "$SHOW_OPTIONS_COUNTER"
    if [[ "$count" -eq 1 ]]; then
      exit 1
    fi
    printf '%s\n' "$TEST_TRANSCRIPT_PATH"
    ;;
  *) exit 1 ;;
esac
TMUX_MOCK
  chmod +x "$MOCK_BIN/tmux"

  "$BIN_DIR/agent-deliver" %5 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "2" "$enter_count"

  unset TEST_TRANSCRIPT_PATH SHOW_OPTIONS_COUNTER MOCK_TMUX_LOG
  create_mock_tmux
}
run_test "retries Enter when @transcript_path was unset at delivery start" \
  test_retries_when_before_transcript_path_was_unset

test_retries_when_deadline_expires_without_progress() {
  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-deadline.log"
  : > "$MOCK_TMUX_LOG"

  local transcript="$TEST_TMP/transcript-deadline.jsonl"
  : > "$transcript"
  export TEST_TRANSCRIPT_PATH="$transcript"

  create_mock_script "$HOME/.steez/bin/agent-state" \
    '[[ $# -ge 1 && -n "$1" ]] || { echo "error: specify a pane target or use --all" >&2; exit 1; }
     PANE="$1"
     if [[ " ${MOCK_AGENT_PANES:-} " != *" $PANE "* ]]; then
       echo "error: pane '\''$PANE'\'' is not a recognized AI agent" >&2
       exit 1
     fi
     printf "{\"pane\":\"%s\",\"agent\":\"codex\",\"state\":\"idle\",\"name\":\"test\"}\n" "$PANE"
     exit 0'

  # Populated transcript path on every call, file never grows, state stays
  # idle — the pane truly did not accept the first Enter. Loop must run to
  # its 500ms deadline and the retry guard must fire.
  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
set -uo pipefail

[[ -n "${MOCK_TMUX_LOG:-}" ]] && printf '%s\n' "$*" >> "$MOCK_TMUX_LOG"

case "${1:-}" in
  display-message)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "-p" ]] || exit 1
    printf '%s\n' '%5'
    ;;
  load-buffer) cat > /dev/null ;;
  paste-buffer|delete-buffer) ;;
  send-keys)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "Enter" ]] || exit 1
    ;;
  show-options)
    [[ "${2:-}" == "-pv" && "${3:-}" == "-t" && "${4:-}" == "%5" && "${5:-}" == "@transcript_path" ]] || exit 1
    printf '%s\n' "$TEST_TRANSCRIPT_PATH"
    ;;
  *) exit 1 ;;
esac
TMUX_MOCK
  chmod +x "$MOCK_BIN/tmux"

  "$BIN_DIR/agent-deliver" %5 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "2" "$enter_count"

  unset TEST_TRANSCRIPT_PATH MOCK_TMUX_LOG
  create_mock_tmux
}
run_test "retries Enter when the retry deadline expires with no progress" \
  test_retries_when_deadline_expires_without_progress

test_exits_retry_window_early_when_transcript_advances_mid_poll() {
  export MOCK_AGENT_PANES="%5"
  export MOCK_TMUX_LOG="$TEST_TMP/tmux-retry-early.log"
  : > "$MOCK_TMUX_LOG"

  local transcript="$TEST_TMP/transcript-early.jsonl"
  : > "$transcript"
  export TEST_TRANSCRIPT_PATH="$transcript"
  export SHOW_OPTIONS_COUNTER="$TEST_TMP/show-options-early.count"
  rm -f "$SHOW_OPTIONS_COUNTER"

  create_mock_script "$HOME/.steez/bin/agent-state" \
    '[[ $# -ge 1 && -n "$1" ]] || { echo "error: specify a pane target or use --all" >&2; exit 1; }
     PANE="$1"
     if [[ " ${MOCK_AGENT_PANES:-} " != *" $PANE "* ]]; then
       echo "error: pane '\''$PANE'\'' is not a recognized AI agent" >&2
       exit 1
     fi
     printf "{\"pane\":\"%s\",\"agent\":\"codex\",\"state\":\"idle\",\"name\":\"test\"}\n" "$PANE"
     exit 0'

  # Transcript stays flat for the first few poll ticks, then gets a byte on
  # the 5th tick (~100ms into the 500ms window). The loop must exit on that
  # tick and the retry guard must skip — no duplicate Enter, and fewer than
  # a full run of show-options calls (1 BEFORE + 20 polls + 1 AFTER = 22).
  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
set -uo pipefail

[[ -n "${MOCK_TMUX_LOG:-}" ]] && printf '%s\n' "$*" >> "$MOCK_TMUX_LOG"

case "${1:-}" in
  display-message)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "-p" ]] || exit 1
    printf '%s\n' '%5'
    ;;
  load-buffer) cat > /dev/null ;;
  paste-buffer|delete-buffer) ;;
  send-keys)
    [[ "${2:-}" == "-t" && "${3:-}" == "%5" && "${4:-}" == "Enter" ]] || exit 1
    ;;
  show-options)
    [[ "${2:-}" == "-pv" && "${3:-}" == "-t" && "${4:-}" == "%5" && "${5:-}" == "@transcript_path" ]] || exit 1
    count=0
    [[ -f "$SHOW_OPTIONS_COUNTER" ]] && count=$(cat "$SHOW_OPTIONS_COUNTER")
    count=$((count + 1))
    printf '%s\n' "$count" > "$SHOW_OPTIONS_COUNTER"
    # Call 1 is the pre-Enter BEFORE capture; calls 2..21 are the poll loop.
    # Append a byte on call 6 (5th poll) so transcript_cursor reads it on
    # the same iteration and the loop breaks.
    if [[ "$count" -eq 6 ]]; then
      printf 'x' >> "$TEST_TRANSCRIPT_PATH"
    fi
    printf '%s\n' "$TEST_TRANSCRIPT_PATH"
    ;;
  *) exit 1 ;;
esac
TMUX_MOCK
  chmod +x "$MOCK_BIN/tmux"

  "$BIN_DIR/agent-deliver" %5 "hello" >/dev/null 2>&1 \
    || { echo "deliver failed"; exit 1; }

  local enter_count
  enter_count=$(grep -c '^send-keys -t %5 Enter$' "$MOCK_TMUX_LOG" || true)
  assert_eq "1" "$enter_count"

  local poll_count
  poll_count=$(cat "$SHOW_OPTIONS_COUNTER" 2>/dev/null || echo 0)
  if [[ "$poll_count" -ge 22 ]]; then
    echo "loop did not exit early: show-options called $poll_count times"
    exit 1
  fi

  unset TEST_TRANSCRIPT_PATH SHOW_OPTIONS_COUNTER MOCK_TMUX_LOG
  create_mock_tmux
}
run_test "exits retry window early when transcript advances mid-poll" \
  test_exits_retry_window_early_when_transcript_advances_mid_poll

report
