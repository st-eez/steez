#!/usr/bin/env bash
# Tests for agent-send: arg parsing, delivery forwarding, watch registration.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
create_mock_tmux
setup_agent_mocks

mock_pane "%5" "2001" "claude" "/tmp"
mock_pane "%0" "2000" "" "/tmp"

export MOCK_AGENT_PANES="%5"
export TMUX_PANE="%0"

suite "agent-send arg parsing"

test_no_args_error() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "no args exits 1" test_no_args_error

test_help_exits_0() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" --help 2>&1) || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "Usage:"
}
run_test "--help exits 0" test_help_exits_0

test_missing_message() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" %5 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "missing message exits 1" test_missing_message

test_too_many_args() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" %5 "hello" "extra" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
}
run_test "too many positional args exits 1" test_too_many_args

test_unknown_flag() {
  local rc=0 out
  out=$("$BIN_DIR/agent-send" --bogus %5 "hello" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown"
}
run_test "unknown flag exits 1" test_unknown_flag

suite "agent-send delivery"

test_successful_send() {
  local rc=0
  "$BIN_DIR/agent-send" %5 "hello world" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "successful send exits 0" test_successful_send

test_non_agent_pane() {
  export MOCK_AGENT_PANES=""
  local rc=0
  "$BIN_DIR/agent-send" %5 "hello" >/dev/null 2>&1 || rc=$?
  assert_exit_code "2" "$rc"
  export MOCK_AGENT_PANES="%5"  # restore
}
run_test "non-agent pane exits 2" test_non_agent_pane

test_no_watch_flag() {
  # Spec (agent-send): --no-watch skips watch registration entirely. Under
  # the two-step-turn cutover this means neither prearm nor start emits,
  # and legacy agent-watch is also never called. Write mock bodies to
  # disk directly so the mock shells can reference $1 at run time without
  # fighting quote-escaping in create_mock_script's unquoted heredoc.
  cat > "$HOME/.steez/bin/agent-eventsd" <<EVENTSD_MOCK
#!/usr/bin/env bash
touch "$TEST_TMP/eventsd-called"
case "\$1" in prearm) echo mock-wid ;; esac
exit 0
EVENTSD_MOCK
  chmod +x "$HOME/.steez/bin/agent-eventsd"
  create_mock_script "$HOME/.steez/bin/agent-watch" \
    'touch "'"$TEST_TMP"'/watch-called"; exit 0'
  rm -f "$TEST_TMP/eventsd-called" "$TEST_TMP/watch-called"

  "$BIN_DIR/agent-send" --no-watch %5 "hello" >/dev/null 2>&1 || true
  [[ ! -f "$TEST_TMP/eventsd-called" ]] \
    || { echo "    agent-eventsd fired despite --no-watch"; return 1; }
  [[ ! -f "$TEST_TMP/watch-called" ]] \
    || { echo "    legacy agent-watch called despite --no-watch"; return 1; }

  # Restore the default mock so subsequent tests keep the happy-path
  # prearm echo that agent-send depends on for --emit-watch-line.
  create_mock_script "$HOME/.steez/bin/agent-eventsd" \
    'case "${1:-}" in prearm) echo "mock-watch-id" ;; *) : ;; esac; exit 0'
}
run_test "--no-watch skips watch registration" test_no_watch_flag

test_emit_watch_line() {
  # Restore normal agent-watch mock
  create_mock_script "$HOME/.steez/bin/agent-watch" 'exit 0'
  local out
  out=$("$BIN_DIR/agent-send" --emit-watch-line %5 "hello" 2>&1)
  assert_contains "$out" "WATCHED=%5"
  assert_contains "$out" "BASELINE=working"
}
run_test "--emit-watch-line prints watch info" test_emit_watch_line

test_custom_spawner() {
  create_mock_script "$HOME/.steez/bin/agent-watch" 'exit 0'
  local rc=0
  "$BIN_DIR/agent-send" --spawner %0 %5 "hello" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "--spawner flag accepted" test_custom_spawner

test_custom_label() {
  create_mock_script "$HOME/.steez/bin/agent-watch" 'exit 0'
  local rc=0
  "$BIN_DIR/agent-send" --label "my-task" %5 "hello" >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "--label flag accepted" test_custom_label

# ----- two-step turn (bead 8) -----
#
# Spec (Watch lifecycle — armed): "agent-send uses this order:
#   1. turn.prearm with baseline_state=working
#   2. deliver the prompt to the pane
#   3. watch.start
# If step 3 fails, the daemon does not auto-retry it. The watch stays
# pending and times out."
#
# The tests below drive the full two-step turn against the real
# agent-eventsd so on-disk transitions (pending → armed → closed) are
# visible. agent-deliver is wrapped to snapshot the live-watch record at
# the moment the prompt bytes would hit the pane — proving prearm fired
# first — and agent-eventsd is wrapped to inject a `start` failure
# without auto-retry.

suite "agent-send two-step turn"

# Install the real agent-eventsd at $HOME/.steez/bin so agent-send can
# route events to it. Backs the test with real watch-record persistence
# under STEEZ_STATE_DIR/eventsd.
#
# Copy, not symlink: later in this test a wrapper overwrites
# $HOME/.steez/bin/agent-eventsd to inject a start-failure, and writing
# through a symlink would clobber the real binary in $BIN_DIR.
_two_step_install_eventsd() {
  rm -f "$HOME/.steez/bin/agent-eventsd"
  cp "$BIN_DIR/agent-eventsd" "$HOME/.steez/bin/agent-eventsd"
  chmod +x "$HOME/.steez/bin/agent-eventsd"
}

# Snapshotting agent-deliver mock. Reads the live-watch pointer and the
# backing record at invocation time so the test can assert the watch was
# already on disk in state=pending when delivery ran.
_two_step_install_deliver_mock() {
  local ledger="$1"
  : > "$ledger"
  cat > "$HOME/.steez/bin/agent-deliver" <<DELIVER
#!/usr/bin/env bash
pane="\$1"
key=\$(printf '%s' "\$pane" | tr -c 'a-zA-Z0-9' '_')
live_file="\${STEEZ_STATE_DIR:-\$HOME/.steez/state}/eventsd/index/live/\$key"
wid=""; state=""
if [[ -s "\$live_file" ]]; then
  wid=\$(cat "\$live_file")
  rec_file="\${STEEZ_STATE_DIR:-\$HOME/.steez/state}/eventsd/watches/\$wid.json"
  [[ -f "\$rec_file" ]] && state=\$(jq -r .state "\$rec_file")
fi
printf 'DELIVER pane=%s wid=%s state=%s\n' "\$pane" "\${wid:-none}" "\${state:-none}" >> "$ledger"
exit 0
DELIVER
  chmod +x "$HOME/.steez/bin/agent-deliver"
}

# Look up the live watch_id for a pane in the real eventsd state dir.
_two_step_live_wid() {
  local pane="$1" key file
  key=$(printf '%s' "$pane" | tr -c 'a-zA-Z0-9' '_')
  file="$STEEZ_STATE_DIR/eventsd/index/live/$key"
  [[ -s "$file" ]] && cat "$file"
}

# Read watch state field off disk.
_two_step_watch_field() {
  local wid="$1" field="$2"
  jq -r ".$field" "$STEEZ_STATE_DIR/eventsd/watches/$wid.json" 2>/dev/null
}

test_agent_send_emits_prearm_before_prompt_bytes_and_watch_start_after_and_start_failure_leaves_pending_until_timeout() {
  _two_step_install_eventsd

  local ledger="$TEST_TMP/turn-order.log"
  _two_step_install_deliver_mock "$ledger"

  # Happy path: prearm → deliver (sees pending watch on disk) → start (arms).
  local pane="%77"
  mock_pane "$pane" "2077" "claude" "/tmp"
  export MOCK_AGENT_PANES="$MOCK_AGENT_PANES $pane"

  "$BIN_DIR/agent-send" "$pane" "hello-two-step" >/dev/null 2>&1 || {
    echo "    agent-send failed on happy path"; return 1
  }

  # Ordering proof #1: deliver mock observed a pending watch — prearm
  # fired BEFORE the prompt bytes hit the pane.
  local ledger_line
  ledger_line=$(cat "$ledger")
  [[ "$ledger_line" == *"pane=$pane"* ]] \
    || { echo "    deliver not invoked for $pane: $ledger_line"; return 1; }
  [[ "$ledger_line" == *"state=pending"* ]] \
    || { echo "    pending watch not on disk at deliver time: $ledger_line"; return 1; }

  # Ordering proof #2: watch is armed after agent-send — watch.start
  # fired AFTER deliver.
  local wid state
  wid=$(_two_step_live_wid "$pane")
  [[ -n "$wid" ]] \
    || { echo "    no live watch after agent-send"; return 1; }
  state=$(_two_step_watch_field "$wid" state)
  assert_eq "armed" "$state" || return 1
  # Baseline is hardcoded to working regardless of current pane state.
  assert_eq "working" "$(_two_step_watch_field "$wid" baseline_state)" || return 1

  # Start-failure path: a wrapper proxies prearm/list/etc to the real
  # eventsd but fails `start`. Spec: "If step 3 fails, the daemon does
  # not auto-retry it. The watch stays pending and times out."
  # Replace the mock binary — rm first so we overwrite the file itself
  # rather than writing through a symlink.
  rm -f "$HOME/.steez/bin/agent-eventsd"
  local real_eventsd="$BIN_DIR/agent-eventsd"
  cat > "$HOME/.steez/bin/agent-eventsd" <<WRAPPER
#!/usr/bin/env bash
if [[ "\${1:-}" == "start" ]]; then
  exit 7
fi
exec "$real_eventsd" "\$@"
WRAPPER
  chmod +x "$HOME/.steez/bin/agent-eventsd"

  local pane2="%78"
  mock_pane "$pane2" "2078" "claude" "/tmp"
  export MOCK_AGENT_PANES="$MOCK_AGENT_PANES $pane2"
  _two_step_install_deliver_mock "$ledger"

  # agent-send must still exit 0 — delivery is the primary contract
  # (spec Non-goals + existing agent-send behavior: "Watch failures are
  # swallowed — delivery is the primary contract").
  "$BIN_DIR/agent-send" "$pane2" "hello-start-fail" >/dev/null 2>&1 || {
    echo "    agent-send failed when start failed"; return 1
  }

  # Deliver still observed a pending watch — prearm still fired.
  [[ "$(cat "$ledger")" == *"state=pending"* ]] \
    || { echo "    failed path: pending state not on disk at deliver"; return 1; }

  # No auto-retry — watch stays pending.
  local wid2 state2
  wid2=$(_two_step_live_wid "$pane2")
  [[ -n "$wid2" ]] \
    || { echo "    no live watch after failed start"; return 1; }
  state2=$(_two_step_watch_field "$wid2" state)
  assert_eq "pending" "$state2" || return 1

  # Timeout path: source the daemon lib and fire watch_pending_timeout.
  # Spec: "If watch.start never arrives, the watch closes with
  # pending_timeout." Covers both the never-arrived case and the
  # failed-and-not-retried case — both leave the watch pending past the
  # deadline, and the deadline expires the same way.
  # shellcheck disable=SC1090
  ( source "$BIN_DIR/agent-eventsd"
    watch_pending_timeout "$wid2" ) || {
    echo "    watch_pending_timeout failed"; return 1
  }

  local final_state final_reason
  final_state=$(_two_step_watch_field "$wid2" state)
  final_reason=$(_two_step_watch_field "$wid2" close_reason)
  assert_eq "closed" "$final_state" || return 1
  assert_eq "pending_timeout" "$final_reason" || return 1

  # Pane's live slot is freed — next prearm can occupy it.
  local live_file2
  live_file2="$STEEZ_STATE_DIR/eventsd/index/live/$(printf '%s' "$pane2" | tr -c 'a-zA-Z0-9' '_')"
  [[ ! -s "$live_file2" ]] \
    || { echo "    live slot not cleared on pending_timeout"; return 1; }
}
run_test "agent_send_emits_prearm_before_prompt_bytes_and_watch_start_after_and_start_failure_leaves_pending_until_timeout" test_agent_send_emits_prearm_before_prompt_bytes_and_watch_start_after_and_start_failure_leaves_pending_until_timeout

# ----- watch forwarding survivors (retargeted for agent-eventsd cutover) -----
#
# The pre-cutover suite had three argv-level tests against agent-watch:
#
#   1. agent-send always forwards --baseline working
#   2. agent-send forwards a custom --label when the caller passes one
#   3. agent-send omits --label when the caller does not pass one
#
# Under agent-eventsd:
#
#   1. Covered above — the two-step turn test asserts `baseline_state=working`
#      on the live watch record, which is a stronger check than argv grep
#      (it proves the value survived the prearm call into persisted state).
#
#   2. NOT covered anywhere else — a mutant that drops --label, hard-codes
#      a fallback, or swaps in the inferred label when a custom one is
#      passed would survive. The test below kills those by driving the
#      real agent-eventsd and reading `.label` off the watch record on disk.
#
#   3. Obsolete: label inference moved from agent-watch into agent-send
#      (infer_label in shared/steez/bin/agent-send). agent-send now always
#      passes --label to prearm. The original mutant it killed — a
#      hardcoded fallback in agent-send that masked downstream inference —
#      cannot exist in the new design. Dropped, not retargeted.

suite "agent-send custom label"

test_custom_label_reaches_watch_record() {
  _two_step_install_eventsd

  local pane="%79"
  mock_pane "$pane" "2079" "claude" "/tmp"
  export MOCK_AGENT_PANES="$MOCK_AGENT_PANES $pane"

  "$BIN_DIR/agent-send" --label "my-task" "$pane" "hello" >/dev/null 2>&1 \
    || { echo "    agent-send failed"; return 1; }

  local wid label
  wid=$(_two_step_live_wid "$pane")
  [[ -n "$wid" ]] || { echo "    no live watch after send"; return 1; }
  label=$(_two_step_watch_field "$wid" label)
  assert_eq "my-task" "$label"
}
run_test "custom --label propagates through prearm to watch record" \
  test_custom_label_reaches_watch_record

report
