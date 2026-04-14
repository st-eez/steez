#!/usr/bin/env bash
# Tests for agent-watch: the public CLI cutover to agent-eventsd.
#
# Bead 8 rewires every subcommand (add, remove, list, daemon-status) to
# the event-driven daemon. Manual add uses the same two-step turn as
# agent-send but emits watch.start immediately after turn.prearm (no
# prompt bytes in between). agent-watch-daemon is retired from the
# primary path — these tests also assert its absence.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
create_mock_tmux
setup_agent_mocks

mock_pane "%5" "2001" "claude" "/tmp"
mock_pane "%6" "2002" "codex" "/tmp"
mock_pane "%0" "2000" "" "/tmp"

export MOCK_AGENT_PANES="%5 %6"
export TMUX_PANE="%0"

# Install the real agent-eventsd at $HOME/.steez/bin so add/remove/list
# mutate real state. The mock from setup_agent_mocks would short-circuit
# every subcommand — not useful for end-to-end routing tests.
_install_real_eventsd() {
  rm -f "$HOME/.steez/bin/agent-eventsd"
  cp "$BIN_DIR/agent-eventsd" "$HOME/.steez/bin/agent-eventsd"
  chmod +x "$HOME/.steez/bin/agent-eventsd"
}

# Tripwire for bead 8 acceptance: agent-watch-daemon must be absent from
# the primary path. The mock at $HOME/.steez/bin/agent-watch-daemon writes
# a marker file on invocation — tests assert the marker never appears.
_install_daemon_tripwire() {
  cat > "$HOME/.steez/bin/agent-watch-daemon" <<TRIP
#!/usr/bin/env bash
touch "$TEST_TMP/daemon-spawned"
exit 0
TRIP
  chmod +x "$HOME/.steez/bin/agent-watch-daemon"
  rm -f "$TEST_TMP/daemon-spawned"
}

_live_file_for_pane() {
  local pane="$1" key
  key=$(printf '%s' "$pane" | tr -c 'a-zA-Z0-9' '_')
  printf '%s/eventsd/index/live/%s' "$STEEZ_STATE_DIR" "$key"
}

_watch_state() {
  local wid="$1"
  jq -r .state "$STEEZ_STATE_DIR/eventsd/watches/$wid.json" 2>/dev/null
}

suite "agent-watch add routes to agent-eventsd"

test_add_emits_prearm_and_start_immediately_and_leaves_watch_armed() {
  # Spec (Watch lifecycle — armed): "Manual agent-watch add uses the
  # same model, but watch.start follows turn.prearm immediately."
  _install_real_eventsd
  _install_daemon_tripwire

  local out live_wid state
  out=$("$BIN_DIR/agent-watch" add %5 2>&1)
  assert_contains "$out" "watching %5"

  # Real eventsd has a live armed watch on the pane.
  local live_file
  live_file=$(_live_file_for_pane "%5")
  [[ -s "$live_file" ]] || { echo "    no live watch after add"; return 1; }
  live_wid=$(cat "$live_file")
  state=$(_watch_state "$live_wid")
  assert_eq "armed" "$state" || return 1

  # agent-watch-daemon was never spawned.
  [[ ! -f "$TEST_TMP/daemon-spawned" ]] \
    || { echo "    agent-watch-daemon spawned from primary path"; return 1; }
}
run_test "add_emits_prearm_and_start_immediately_and_leaves_watch_armed" test_add_emits_prearm_and_start_immediately_and_leaves_watch_armed

test_add_records_label_spawner_and_baseline_flags() {
  _install_real_eventsd

  "$BIN_DIR/agent-watch" add %5 --spawner %0 --label "my-agent" \
    --baseline "idle" >/dev/null 2>&1 || {
    echo "    add failed"; return 1
  }
  local live_wid rec
  live_wid=$(cat "$(_live_file_for_pane "%5")")
  rec=$(jq -c . "$STEEZ_STATE_DIR/eventsd/watches/$live_wid.json")
  assert_json_field "$rec" .label "my-agent" || return 1
  assert_json_field "$rec" .spawner_pane "%0" || return 1
  assert_json_field "$rec" .baseline_state "idle" || return 1
}
run_test "add_records_label_spawner_and_baseline_flags" test_add_records_label_spawner_and_baseline_flags

test_add_second_add_supersedes_prior_watch_on_same_pane() {
  # agent-watch add must not leak a "draining old + live new" pair that
  # collides with the at-most-one-live invariant. Spec (Live and draining
  # watches): "A new turn.prearm supersedes any existing live watch on
  # that pane." Manual add goes through prearm, so a second add on the
  # same pane closes the prior with close_reason=superseded.
  _install_real_eventsd

  local wid1 wid2 rec1
  "$BIN_DIR/agent-watch" add %5 --label "first" >/dev/null 2>&1 || return 1
  wid1=$(cat "$(_live_file_for_pane "%5")")
  "$BIN_DIR/agent-watch" add %5 --label "second" >/dev/null 2>&1 || return 1
  wid2=$(cat "$(_live_file_for_pane "%5")")
  [[ "$wid1" != "$wid2" ]] || { echo "    new add reused prior watch_id"; return 1; }
  rec1=$(jq -c . "$STEEZ_STATE_DIR/eventsd/watches/$wid1.json")
  assert_json_field "$rec1" .state closed || return 1
  assert_json_field "$rec1" .close_reason superseded || return 1
}
run_test "add_second_add_supersedes_prior_watch_on_same_pane" test_add_second_add_supersedes_prior_watch_on_same_pane

suite "agent-watch remove routes to agent-eventsd"

test_remove_closes_live_watch_on_pane() {
  _install_real_eventsd
  _install_daemon_tripwire

  "$BIN_DIR/agent-watch" add %5 >/dev/null 2>&1 || return 1
  local wid
  wid=$(cat "$(_live_file_for_pane "%5")")

  "$BIN_DIR/agent-watch" remove %5 >/dev/null 2>&1 || return 1
  # Live slot freed.
  [[ ! -s "$(_live_file_for_pane "%5")" ]] \
    || { echo "    live slot not cleared on remove"; return 1; }
  # Watch record closed with reason=removed.
  local state reason
  state=$(_watch_state "$wid")
  reason=$(jq -r .close_reason "$STEEZ_STATE_DIR/eventsd/watches/$wid.json")
  assert_eq "closed" "$state" || return 1
  assert_eq "removed" "$reason" || return 1
  # Daemon still absent.
  [[ ! -f "$TEST_TMP/daemon-spawned" ]] \
    || { echo "    agent-watch-daemon spawned from remove"; return 1; }
}
run_test "remove_closes_live_watch_on_pane" test_remove_closes_live_watch_on_pane

test_remove_without_existing_watch_is_a_noop() {
  # Spec (agent-watch behavioral contract carried into bead 8):
  # "remove is safe to call on non-existent watches (no error)."
  _install_real_eventsd
  local rc=0
  "$BIN_DIR/agent-watch" remove %6 >/dev/null 2>&1 || rc=$?
  assert_exit_code "0" "$rc"
}
run_test "remove_without_existing_watch_is_a_noop" test_remove_without_existing_watch_is_a_noop

suite "agent-watch list routes to agent-eventsd"

test_list_reflects_live_eventsd_watches() {
  _install_real_eventsd

  # Empty state → informational message.
  rm -rf "$STEEZ_STATE_DIR/eventsd"
  local empty
  empty=$("$BIN_DIR/agent-watch" list 2>&1)
  assert_contains "$empty" "no active watches" || return 1

  # After an add, list prints a line referencing the pane and label.
  "$BIN_DIR/agent-watch" add %5 --label "running-agent" >/dev/null 2>&1 \
    || return 1
  local out
  out=$("$BIN_DIR/agent-watch" list 2>&1)
  assert_contains "$out" "%5" || return 1
  assert_contains "$out" "running-agent" || return 1
}
run_test "list_reflects_live_eventsd_watches" test_list_reflects_live_eventsd_watches

suite "agent-watch daemon-status routes to agent-eventsd"

test_daemon_status_reports_agent_eventsd_health() {
  # Bead 8 acceptance: "daemon-status reports agent-eventsd health."
  _install_real_eventsd
  _install_daemon_tripwire

  local out rc=0
  out=$("$BIN_DIR/agent-watch" daemon-status 2>&1) || rc=$?
  assert_exit_code "0" "$rc"
  # Output must call out agent-eventsd explicitly — the label proves the
  # cutover. "running pid=..." (the old daemon output) is forbidden.
  assert_contains "$out" "agent-eventsd" || return 1
  [[ "$out" != *"running pid="* ]] \
    || { echo "    still reporting old agent-watch-daemon pid: $out"; return 1; }
  # agent-watch-daemon must NOT be spawned by daemon-status.
  [[ ! -f "$TEST_TMP/daemon-spawned" ]] \
    || { echo "    daemon-status spawned agent-watch-daemon"; return 1; }
}
run_test "daemon_status_reports_agent_eventsd_health" test_daemon_status_reports_agent_eventsd_health

suite "agent-watch-daemon absent from primary path"

test_add_remove_list_status_never_spawn_agent_watch_daemon() {
  # Bead 8 acceptance: "agent-watch-daemon absent from primary path."
  # Drives every public subcommand through a tripwired mock and asserts
  # the marker file was never created.
  _install_real_eventsd
  _install_daemon_tripwire

  "$BIN_DIR/agent-watch" add %5 >/dev/null 2>&1 || return 1
  "$BIN_DIR/agent-watch" list >/dev/null 2>&1 || return 1
  "$BIN_DIR/agent-watch" daemon-status >/dev/null 2>&1 || return 1
  "$BIN_DIR/agent-watch" remove %5 >/dev/null 2>&1 || return 1

  [[ ! -f "$TEST_TMP/daemon-spawned" ]] \
    || { echo "    agent-watch-daemon spawned by primary path"; return 1; }
}
run_test "add_remove_list_status_never_spawn_agent_watch_daemon" test_add_remove_list_status_never_spawn_agent_watch_daemon

suite "agent-watch errors"

test_add_without_pane_errors() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" add 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "add without pane errors" test_add_without_pane_errors

test_remove_without_pane_errors() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" remove 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "error"
}
run_test "remove without pane errors" test_remove_without_pane_errors

test_no_command_shows_usage() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" 2>&1) || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "Usage:"
}
run_test "no command shows usage" test_no_command_shows_usage

test_unknown_command_errors() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" frobnicate 2>&1) || rc=$?
  assert_contains "$out" "error"
}
run_test "unknown command errors" test_unknown_command_errors

test_add_with_unknown_arg_errors() {
  local rc=0 out
  out=$("$BIN_DIR/agent-watch" add %5 --bogus 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown"
}
run_test "add with unknown arg errors" test_add_with_unknown_arg_errors

report
