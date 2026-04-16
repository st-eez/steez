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
_cleanup_agent_watch() {
  _stop_real_eventsd_service >/dev/null 2>&1 || true
  cleanup_test_env
}
trap _cleanup_agent_watch EXIT
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
  eventsd_enable_explicit_service_mode
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

# Liveness of the long-lived agent-eventsd service. daemon-status now
# reflects this PID file — not just state-dir writability — so tests that
# want a clean "no service running" baseline must kill any leftover
# service spawned by a prior test's auto-start.
_eventsd_service_pidfile() {
  eventsd_service_pidfile
}

_stop_real_eventsd_service() {
  eventsd_stop_service
}

_start_real_eventsd_service() {
  eventsd_start_service "$BIN_DIR/agent-eventsd"
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
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

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
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

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
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

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
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

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
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }
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
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }
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
  # Bead 401 extension: health means the long-lived service is alive —
  # not just a writable state dir. Start a real serve process first.
  _install_real_eventsd
  _install_daemon_tripwire
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

  local out rc=0
  out=$("$BIN_DIR/agent-watch" daemon-status 2>&1) || rc=$?
  _stop_real_eventsd_service
  assert_exit_code "0" "$rc"
  # Output must call out agent-eventsd explicitly — the label proves the
  # cutover. "running pid=..." (the old daemon output) is forbidden.
  assert_contains "$out" "agent-eventsd" || return 1
  assert_contains "$out" "ready" || return 1
  [[ "$out" != *"running pid="* ]] \
    || { echo "    still reporting old agent-watch-daemon pid: $out"; return 1; }
  # agent-watch-daemon must NOT be spawned by daemon-status.
  [[ ! -f "$TEST_TMP/daemon-spawned" ]] \
    || { echo "    daemon-status spawned agent-watch-daemon"; return 1; }
}
run_test "daemon_status_reports_agent_eventsd_health" test_daemon_status_reports_agent_eventsd_health

test_daemon_status_is_unavailable_when_service_state_dir_is_not_writable() {
  # Spec (agent-watch daemon-status): ready requires both a live
  # long-lived service and a writable eventsd state dir.
  _install_real_eventsd
  _install_daemon_tripwire
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

  local eventsd_dir="$STEEZ_STATE_DIR/eventsd"
  chmod 0555 "$eventsd_dir" || {
    _stop_real_eventsd_service >/dev/null 2>&1 || true
    echo "    failed to make eventsd state dir read-only"
    return 1
  }

  local out rc=0
  out=$("$BIN_DIR/agent-watch" daemon-status 2>&1) || rc=$?

  chmod 0755 "$eventsd_dir" || true
  _stop_real_eventsd_service >/dev/null 2>&1 || true

  assert_exit_code "1" "$rc"
  assert_contains "$out" "agent-eventsd" || return 1
  assert_contains "$out" "unavailable" || return 1
  [[ ! -f "$TEST_TMP/daemon-spawned" ]] \
    || { echo "    daemon-status spawned agent-watch-daemon"; return 1; }
}
run_test "daemon_status_is_unavailable_when_service_state_dir_is_not_writable" \
  test_daemon_status_is_unavailable_when_service_state_dir_is_not_writable

test_daemon_status_is_unavailable_when_no_long_lived_service_running() {
  # A writable state dir is not enough — without the long-lived service,
  # armed watches never tick and notifications never fire. daemon-status
  # must surface that as "unavailable" so operators aren't told the
  # primary path is healthy when it is silently dead.
  _install_real_eventsd
  _install_daemon_tripwire
  _stop_real_eventsd_service
  [[ ! -f "$(_eventsd_service_pidfile)" ]] \
    || { echo "    pidfile still present after stop"; return 1; }

  local out rc=0
  out=$("$BIN_DIR/agent-watch" daemon-status 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "agent-eventsd" || return 1
  assert_contains "$out" "unavailable" || return 1
  # No fallback to the retired daemon either.
  [[ ! -f "$TEST_TMP/daemon-spawned" ]] \
    || { echo "    daemon-status spawned agent-watch-daemon"; return 1; }
}
run_test "daemon_status_is_unavailable_when_no_long_lived_service_running" test_daemon_status_is_unavailable_when_no_long_lived_service_running

suite "agent-watch-daemon absent from primary path"

test_add_remove_list_status_never_spawn_agent_watch_daemon() {
  # Bead 8 acceptance: "agent-watch-daemon absent from primary path."
  # Drives every public subcommand through a tripwired mock and asserts
  # the marker file was never created.
  _install_real_eventsd
  _install_daemon_tripwire
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

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

suite "agent-watch default baseline"

# Pre-cutover this read baseline_state off a jsonl watchlist. Under the
# agent-eventsd cutover the watch record lives in eventsd/watches/<wid>.json
# — retargeted to read from there. Mutant killed: agent-watch defaults
# --baseline to something other than "working" (or drops it entirely,
# letting the daemon pick a different default).
test_default_baseline_is_working() {
  _install_real_eventsd
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

  "$BIN_DIR/agent-watch" add %5 >/dev/null 2>&1 \
    || { echo "add failed"; exit 1; }
  local wid baseline
  wid=$(cat "$(_live_file_for_pane "%5")")
  baseline=$(jq -r '.baseline_state' "$STEEZ_STATE_DIR/eventsd/watches/$wid.json")
  assert_eq "working" "$baseline"
}
run_test "add writes baseline_state=working when --baseline is omitted" \
  test_default_baseline_is_working

suite "agent-watch label inference"

# Pre-cutover, infer_label lived in agent-watch-daemon. Bead 8 kept the
# infer_label hook but moved the call site into agent-watch itself, so
# the contract is the same from a caller's perspective: omit --label and
# the agent-state agent type shows up on the record. Retargeted to read
# `.label` off the eventsd watch record.
test_inferred_label_matches_agent_type() {
  # Reconfigure agent-state FIRST, then reinstall the real eventsd on top
  # — setup_agent_mocks clobbers $HOME/.steez/bin/agent-eventsd back to
  # the stand-in mock, which would skip the on-disk record we read below.
  setup_agent_mocks ren idle
  _install_real_eventsd
  _start_real_eventsd_service || { echo "    service failed to start"; return 1; }

  "$BIN_DIR/agent-watch" add %5 >/dev/null 2>&1 \
    || { echo "add failed"; exit 1; }
  local wid label
  wid=$(cat "$(_live_file_for_pane "%5")")
  label=$(jq -r '.label' "$STEEZ_STATE_DIR/eventsd/watches/$wid.json")
  assert_eq "ren" "$label"

  setup_agent_mocks
}
run_test "omitted --label falls back to agent-state agent type" \
  test_inferred_label_matches_agent_type

# Pre-cutover test "rolls back watchlist entry when daemon fails to start"
# is dropped, not retargeted. The rollback it verified guarded a failure
# mode — ensure_daemon fails to spawn agent-watch-daemon — that no longer
# exists in the primary path. agent-watch now routes every subcommand
# through agent-eventsd (a long-running daemon launched out-of-band), so
# agent-watch itself neither starts a daemon nor maintains a local
# watchlist to roll back. The "daemon absent from primary path" test
# upthread already pins that agent-watch-daemon is never spawned.

report
