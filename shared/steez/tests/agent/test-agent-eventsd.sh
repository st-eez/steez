#!/usr/bin/env bash
# Tests for agent-eventsd: seq assigner, watch record, in-memory store.
#
# Bead 1 scope: per-pane monotonic seq, watch record struct, and store API
# (create_pending, get_live, get_draining, list). No lifecycle transitions,
# no resolver, no transport.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
create_mock_tmux

# Permanent no-op sketchybar. The U2 attention-sink publication fires
# `sketchybar --trigger agent_attention_changed` best-effort from every
# attention set/clear; without a mock on $PATH, a developer machine with
# real sketchybar installed would receive real triggers during tests.
# U2 tests that assert on the trigger argv override this with a logging
# mock locally.
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sketchybar"
chmod +x "$MOCK_BIN/sketchybar"

EVENTSD="$BIN_DIR/agent-eventsd"
if [[ ! -f "$EVENTSD" ]]; then
  echo "agent-eventsd not found at $EVENTSD"
  exit 1
fi

# Source daemon library. Bead 1 ships no main — the script is a pure
# library of functions that a later bead's transport will wrap.
# shellcheck disable=SC1090
source "$EVENTSD"

# ----- service lifecycle -----

suite "service lifecycle"

_eventsd_pidfile() {
  printf '%s/eventsd/eventsd.pid' "$STEEZ_STATE_DIR"
}

_eventsd_reap_service() {
  local pidf pid
  pidf=$(_eventsd_pidfile)
  [[ -f "$pidf" ]] || return 0
  pid=$(cat "$pidf" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    kill -KILL "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      /bin/sleep 0.05
    done
  fi
  rm -f "$pidf"
}

test_explicit_service_mode_blocks_detached_autostart() {
  local pidf rc=0 out spawned=0
  pidf=$(_eventsd_pidfile)
  _eventsd_reap_service
  out=$(EVENTSD_REQUIRE_EXPLICIT_SERVICE=1 "$EVENTSD" prearm \
    --pane "%1" \
    --spawner "%0" \
    --label "claude" \
    --baseline-state "working" 2>&1) || rc=$?
  [[ -f "$pidf" ]] && spawned=1
  _eventsd_reap_service
  [[ "$rc" -ne 0 ]] || {
    echo "    prearm unexpectedly succeeded in explicit-service mode:"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
  }
  [[ "$spawned" -eq 0 ]] || {
    echo "    explicit-service mode detached-spawned agent-eventsd"
    return 1
  }
}
run_test "explicit-service mode blocks detached autostart" test_explicit_service_mode_blocks_detached_autostart

# ----- singleton kernel lock (steez-lmqx) -----
#
# The service singleton must be held by a kernel flock(2), not by
# cooperative pidfile checks. The cooperative check in `_cmd_serve`
# has two TOCTOU windows (rm -f before spawn in _eventsd_auto_start_service;
# check-then-write in _cmd_serve itself) and the user observed 200+
# concurrent agent-eventsd daemons in production because of it.
#
# Count orphans by live PIDs tracked at spawn time, NOT via the pidfile —
# the pidfile only ever holds the last winner and so would hide every
# orphan this test exists to surface.
#
# Red-test reliability harness (manual reviewer check). On the pre-fix
# tree this suite must exit non-zero in at least 8 of 10 consecutive
# runs. On the post-fix tree it must pass 10 of 10:
#
#   for i in 1 2 3 4 5 6 7 8 9 10; do
#     bash shared/steez/tests/agent/test-agent-eventsd.sh \
#       >/tmp/eventsd-lock-run-$i.log 2>&1 \
#       && echo "run $i: PASS" || echo "run $i: FAIL"
#   done

suite "singleton kernel lock"

# `$!` is the perl-parent wrapper that holds the lock; it waitpid()s on
# the bash service child. `kill -0 $!` faithfully tracks whether this
# serve pipeline is still alive. Teardown uses SIGTERM so perl's signal
# handler propagates to the bash child and both exit cleanly — SIGKILL
# on perl would orphan the bash child, which would keep spinning its
# tick loop and corrupt later tests that share $STEEZ_STATE_DIR.
test_concurrent_serve_spawns_exactly_one_live_process() {
  _eventsd_reap_service
  local pids=() p i alive=0 first second
  for i in $(seq 1 20); do
    "$EVENTSD" serve </dev/null >/dev/null 2>&1 &
    pids+=($!)
  done
  /bin/sleep 0.5
  for p in "${pids[@]}"; do
    if kill -0 "$p" 2>/dev/null; then alive=$((alive + 1)); fi
  done
  first="$alive"
  /bin/sleep 0.5
  alive=0
  for p in "${pids[@]}"; do
    if kill -0 "$p" 2>/dev/null; then alive=$((alive + 1)); fi
  done
  second="$alive"
  for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  for p in "${pids[@]}"; do
    for i in $(seq 1 60); do
      kill -0 "$p" 2>/dev/null || break
      /bin/sleep 0.05
    done
    kill -KILL "$p" 2>/dev/null || true
  done
  _eventsd_reap_service
  # Belt-and-suspenders. If any orphan bash service slipped through,
  # pkill it by the internal _serve_locked subcommand so it cannot
  # pollute later tests that share $STEEZ_STATE_DIR.
  pkill -KILL -f 'agent-eventsd _serve_locked' 2>/dev/null || true
  assert_eq 1 "$first" || return 1
  assert_eq 1 "$second" || return 1
}
run_test "concurrent serve spawns exactly one live process" test_concurrent_serve_spawns_exactly_one_live_process

# `$!` is perl-parent; the bash service child is what writes the
# pidfile. SIGTERM to perl-parent propagates; SIGKILL the bash service
# directly through the pidfile simulates a crash. Either way, the lock
# must release so a fresh serve can start.
test_lock_holder_death_releases_lock() {
  _eventsd_reap_service
  local pidf perl_a perl_b bash_a bash_b i
  pidf=$(_eventsd_pidfile)
  "$EVENTSD" serve </dev/null >/dev/null 2>&1 &
  perl_a=$!
  bash_a=""
  for i in $(seq 1 60); do
    if [[ -f "$pidf" ]]; then
      bash_a=$(cat "$pidf" 2>/dev/null || true)
      [[ -n "$bash_a" ]] && kill -0 "$bash_a" 2>/dev/null && break
    fi
    /bin/sleep 0.05
  done
  [[ -n "$bash_a" ]] && kill -0 "$bash_a" 2>/dev/null || {
    echo "    serve A never wrote a live pidfile"
    kill -KILL "$perl_a" 2>/dev/null || true
    pkill -KILL -f 'agent-eventsd _serve_locked' 2>/dev/null || true
    return 1
  }
  kill -KILL "$bash_a" 2>/dev/null || true
  for i in $(seq 1 60); do
    kill -0 "$perl_a" 2>/dev/null || break
    /bin/sleep 0.05
  done
  kill -KILL "$perl_a" 2>/dev/null || true
  rm -f "$pidf"
  "$EVENTSD" serve </dev/null >/dev/null 2>&1 &
  perl_b=$!
  bash_b=""
  for i in $(seq 1 60); do
    if [[ -f "$pidf" ]]; then
      bash_b=$(cat "$pidf" 2>/dev/null || true)
      [[ -n "$bash_b" && "$bash_b" != "$bash_a" ]] && kill -0 "$bash_b" 2>/dev/null && break
    fi
    /bin/sleep 0.05
  done
  kill -TERM "$perl_b" 2>/dev/null || true
  for i in $(seq 1 60); do
    kill -0 "$perl_b" 2>/dev/null || break
    /bin/sleep 0.05
  done
  kill -KILL "$perl_b" 2>/dev/null || true
  _eventsd_reap_service
  pkill -KILL -f 'agent-eventsd _serve_locked' 2>/dev/null || true
  [[ -n "$bash_b" && "$bash_b" != "$bash_a" ]] || {
    echo "    serve B never acquired lock after A's bash was SIGKILL'd (bash_a=$bash_a bash_b=$bash_b)"
    return 1
  }
}
run_test "lock holder death releases lock" test_lock_holder_death_releases_lock

test_serve_locked_refuses_without_lock_guard() {
  local out rc=0
  out=$("$EVENTSD" _serve_locked 2>&1) || rc=$?
  assert_exit_code 2 "$rc" || return 1
  assert_contains "$out" "internal subcommand" || return 1
}
run_test "_serve_locked refuses without lock guard" test_serve_locked_refuses_without_lock_guard

# ----- seq assigner -----

suite "seq assigner"

test_seq_is_monotonic_per_pane_and_independent_across_panes() {
  local a1 a2 a3 b1 b2
  a1=$(seq_next "%1")
  a2=$(seq_next "%1")
  b1=$(seq_next "%2")
  a3=$(seq_next "%1")
  b2=$(seq_next "%2")
  assert_eq 1 "$a1" || return 1
  assert_eq 2 "$a2" || return 1
  assert_eq 1 "$b1" || return 1
  assert_eq 3 "$a3" || return 1
  assert_eq 2 "$b2" || return 1
}
run_test "seq_is_monotonic_per_pane_and_independent_across_panes" test_seq_is_monotonic_per_pane_and_independent_across_panes

# ----- watch record + store API -----

suite "watch store"

# Guard: every store test below depends on the full API surface being
# defined. If any piece is missing, fail the test explicitly instead
# of accidentally passing because an empty output matched an empty
# expectation.
_require_store_api() {
  local fn
  for fn in watch_create_pending watch_get_live watch_get_draining watch_list; do
    if ! declare -F "$fn" >/dev/null; then
      echo "    missing required function: $fn"
      return 1
    fi
  done
}

# Canonical args for a pending watch. Each test uses fresh prearm_seq
# and distinct panes to avoid cross-test coupling.
_mk_pending() {
  local pane="$1" spawner="${2:-%0}" label="${3:-codex}"
  watch_create_pending \
    --pane "$pane" \
    --spawner "$spawner" \
    --label "$label" \
    --baseline-state working \
    --prearm-screen-hash "hash-$pane" \
    --prearm-transcript-cursor 4096 \
    --prearm-seq 7
}

test_create_pending_returns_watch_id_and_records_all_required_fields() {
  _require_store_api || return 1
  local wid rec
  wid=$(_mk_pending "%10" "%9" "codex")
  [[ -n "$wid" ]] || { echo "    empty watch_id"; return 1; }
  rec=$(watch_get_live "%10")
  assert_json_field "$rec" .watch_id "$wid" || return 1
  assert_json_field "$rec" .pane_id "%10" || return 1
  assert_json_field "$rec" .spawner_pane "%9" || return 1
  assert_json_field "$rec" .label "codex" || return 1
  assert_json_field "$rec" .baseline_state working || return 1
  assert_json_field "$rec" .prearm_screen_hash "hash-%10" || return 1
  assert_json_field "$rec" .prearm_transcript_cursor 4096 || return 1
  assert_json_field "$rec" .prearm_seq 7 || return 1
  assert_json_field "$rec" .state pending || return 1
  # turn_id must be present (auto-generated if not supplied)
  local turn_id
  turn_id=$(printf '%s' "$rec" | jq -r .turn_id)
  [[ -n "$turn_id" && "$turn_id" != null ]] || { echo "    missing turn_id"; return 1; }
  # start_seq is only set on watch.start (later bead); must be null here.
  assert_json_field "$rec" .start_seq null || return 1
}
run_test "create_pending returns watch_id and records all required fields" test_create_pending_returns_watch_id_and_records_all_required_fields

test_get_live_is_empty_when_no_live_watch_exists() {
  _require_store_api || return 1
  local rec
  rec=$(watch_get_live "%999")
  assert_eq "" "$rec" || return 1
}
run_test "get_live is empty when no live watch exists" test_get_live_is_empty_when_no_live_watch_exists

test_get_draining_is_empty_in_bead_1() {
  # Bead 1 has no lifecycle transitions — pending never moves to
  # draining, so the draining partition is always empty.
  _require_store_api || return 1
  _mk_pending "%11" >/dev/null || return 1
  local out
  out=$(watch_get_draining "%11")
  assert_eq "" "$out" || return 1
}
run_test "get_draining is empty in bead 1 (no lifecycle transitions yet)" test_get_draining_is_empty_in_bead_1

test_list_returns_all_created_watches() {
  _require_store_api || return 1
  local w1 w2 w3 count
  w1=$(_mk_pending "%20" "%0" "a")
  w2=$(_mk_pending "%21" "%0" "b")
  w3=$(_mk_pending "%22" "%0" "c")
  local out
  out=$(watch_list)
  # Every created watch must appear in list output, one JSON per line.
  count=$(printf '%s\n' "$out" | jq -r '.watch_id' 2>/dev/null | grep -Fxc "$w1" || true)
  assert_eq 1 "$count" || return 1
  count=$(printf '%s\n' "$out" | jq -r '.watch_id' 2>/dev/null | grep -Fxc "$w2" || true)
  assert_eq 1 "$count" || return 1
  count=$(printf '%s\n' "$out" | jq -r '.watch_id' 2>/dev/null | grep -Fxc "$w3" || true)
  assert_eq 1 "$count" || return 1
}
run_test "list returns all created watches" test_list_returns_all_created_watches

# Bead 1 shipped a stricter duplicate-prevention form of the live-per-pane
# invariant. Bead 4 replaces that with supersession (see the
# "live-watch supersession" suite below): a second create_pending on a
# pane with an unresolved live watch closes the prior and installs the
# new one instead of erroring. The invariant itself ("<=1 live watch per
# pane") is preserved; the enforcement mechanism changed.

# ----- lifecycle FSM (bead 2) -----
#
# Fake deliver: tests install a stub at $MOCK_BIN/agent-deliver that logs
# every invocation and returns an exit code controlled by MOCK_DELIVER_EXIT.
# The daemon resolves the deliver command via AGENT_DELIVER_CMD (default
# `agent-deliver` on PATH). Fake clock: timeouts are fired by calling
# watch_pending_timeout directly — no real timers in bead 2.

suite "lifecycle"

_deliver_log_path() { printf '%s' "$TEST_TMP/deliver.log"; }

_install_deliver_mock() {
  export DELIVER_LOG
  DELIVER_LOG=$(_deliver_log_path)
  : > "$DELIVER_LOG"
  cat > "$MOCK_BIN/agent-deliver" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DELIVER_LOG:-/dev/null}"
exit "${MOCK_DELIVER_EXIT:-0}"
MOCK
  chmod +x "$MOCK_BIN/agent-deliver"
  export AGENT_DELIVER_CMD="$MOCK_BIN/agent-deliver"
  export MOCK_DELIVER_EXIT=0
}

_deliver_call_count() {
  [[ -s "${DELIVER_LOG:-/dev/null}" ]] || { echo 0; return; }
  wc -l < "$DELIVER_LOG" | tr -d ' '
}

test_pending_watch_never_notifies_and_armed_promotion_records_start_seq() {
  # Spec: pending never notifies; watch.start must match the pending
  # watch_id on the same pane and records start_seq.
  _install_deliver_mock
  declare -F watch_arm >/dev/null || { echo "    missing function: watch_arm"; return 1; }
  local wid rec
  wid=$(_mk_pending "%40" "%0" "codex")
  # While pending, no deliver call may be issued.
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver called while pending"; return 1; }
  # watch.start — match watch_id on same pane, record start_seq.
  watch_arm --pane "%40" --watch-id "$wid" --start-seq 12 || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .start_seq 12 || return 1
  # Arming alone does not notify (no evidence yet).
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver called after arm"; return 1; }
}
run_test "pending_watch_never_notifies_and_armed_promotion_records_start_seq" test_pending_watch_never_notifies_and_armed_promotion_records_start_seq

test_watch_arm_rejects_mismatched_watch_id_on_same_pane() {
  # Spec: watch.start must match a pending watch_id on the same pane.
  _install_deliver_mock
  local wid rc=0
  wid=$(_mk_pending "%41")
  watch_arm --pane "%41" --watch-id "not-$wid" --start-seq 3 >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "    mismatched watch_id must be rejected"; return 1; }
  # Original watch remains pending, untouched.
  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state pending || return 1
  assert_json_field "$rec" .start_seq null || return 1
}
run_test "watch_arm rejects mismatched watch_id on same pane" test_watch_arm_rejects_mismatched_watch_id_on_same_pane

test_watch_arm_rejects_when_pane_has_no_live_watch() {
  _install_deliver_mock
  local rc=0
  watch_arm --pane "%42" --watch-id "no-such" --start-seq 1 >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "    arm on empty pane must be rejected"; return 1; }
}
run_test "watch_arm rejects when pane has no live watch" test_watch_arm_rejects_when_pane_has_no_live_watch

test_pending_timeout_closes_pending_without_delivery() {
  # Spec: "If watch.start never arrives, the watch closes with
  # pending_timeout." No delivery ever occurs for such a watch.
  _install_deliver_mock
  declare -F watch_pending_timeout >/dev/null || { echo "    missing: watch_pending_timeout"; return 1; }
  local wid
  wid=$(_mk_pending "%43")
  watch_pending_timeout "$wid" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$wid")" || return 1
  # Pane's live slot must be freed (next prearm can occupy it).
  assert_eq "" "$(watch_get_live "%43")" || return 1
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver called on pending_timeout"; return 1; }
}
run_test "pending_timeout closes pending without delivery" test_pending_timeout_closes_pending_without_delivery

test_pending_timeout_refuses_to_close_armed_watch() {
  # Guard: pending_timeout only applies to pending. Once armed, the
  # daemon is past the watch.start deadline.
  _install_deliver_mock
  declare -F watch_pending_timeout >/dev/null || { echo "    missing: watch_pending_timeout"; return 1; }
  local wid rc=0
  wid=$(_mk_pending "%44")
  watch_arm --pane "%44" --watch-id "$wid" --start-seq 5 >/dev/null || return 1
  watch_pending_timeout "$wid" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "    pending_timeout must reject armed watch"; return 1; }
  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
}
run_test "pending_timeout refuses to close armed watch" test_pending_timeout_refuses_to_close_armed_watch

test_watch_remove_closes_pending_without_delivery() {
  # Spec: "Explicit removal ... closes an unresolved watch without delivery."
  _install_deliver_mock
  declare -F watch_remove >/dev/null || { echo "    missing: watch_remove"; return 1; }
  local wid
  wid=$(_mk_pending "%45")
  watch_remove "%45" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "%45")" || return 1
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver called on remove"; return 1; }
}
run_test "watch_remove closes pending without delivery" test_watch_remove_closes_pending_without_delivery

test_watch_remove_closes_armed_without_delivery() {
  _install_deliver_mock
  local wid
  wid=$(_mk_pending "%46")
  watch_arm --pane "%46" --watch-id "$wid" --start-seq 9 >/dev/null || return 1
  watch_remove "%46" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "%46")" || return 1
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver called on remove"; return 1; }
}
run_test "watch_remove closes armed without delivery" test_watch_remove_closes_armed_without_delivery

# Helper: arm the watch on <pane> (and return the watch_id). All resolve
# and deliver tests start from an armed watch.
_arm_on() {
  local pane="$1" wid
  wid=$(_mk_pending "$pane")
  watch_arm --pane "$pane" --watch-id "$wid" --start-seq 1 >/dev/null || return 1
  printf '%s' "$wid"
}

test_resolve_promotes_armed_to_resolved_and_records_terminal_state() {
  _install_deliver_mock
  declare -F watch_resolve >/dev/null || { echo "    missing: watch_resolve"; return 1; }
  local wid rec
  wid=$(_arm_on "%50") || return 1
  watch_resolve "$wid" idle || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
  # Resolve alone does not notify; delivery is a separate transition.
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver called on resolve"; return 1; }
}
run_test "resolve promotes armed to resolved and records terminal state" test_resolve_promotes_armed_to_resolved_and_records_terminal_state

test_resolve_refuses_to_act_on_pending_watch() {
  _install_deliver_mock
  declare -F watch_resolve >/dev/null || { echo "    missing: watch_resolve"; return 1; }
  local wid rc=0
  wid=$(_mk_pending "%51")
  watch_resolve "$wid" idle >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "    resolve on pending must be rejected"; return 1; }
  assert_json_field "$(watch_get "$wid")" .state pending || return 1
}
run_test "resolve refuses to act on pending watch" test_resolve_refuses_to_act_on_pending_watch

test_resolve_is_one_shot_later_calls_for_same_watch_id_are_ignored() {
  # Spec: "Once resolved, the watch is one-shot. Later evidence for
  # that watch_id is ignored."
  _install_deliver_mock
  declare -F watch_resolve >/dev/null || { echo "    missing: watch_resolve"; return 1; }
  local wid rec
  wid=$(_arm_on "%52") || return 1
  watch_resolve "$wid" idle || return 1
  # Second resolve with a different terminal state must not overwrite.
  watch_resolve "$wid" "blocked:question" >/dev/null 2>&1 || true
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
}
run_test "resolve is one-shot — later calls for same watch_id are ignored" test_resolve_is_one_shot_later_calls_for_same_watch_id_are_ignored

test_deliver_after_resolve_transitions_to_delivered_on_success() {
  _install_deliver_mock
  declare -F watch_deliver_attempt >/dev/null || { echo "    missing: watch_deliver_attempt"; return 1; }
  local wid rec
  wid=$(_arm_on "%53") || return 1
  watch_resolve "$wid" idle || return 1
  MOCK_DELIVER_EXIT=0 watch_deliver_attempt "$wid" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$wid")" || return 1
  # Pane's live slot is freed — the watch is terminal.
  assert_eq "" "$(watch_get_live "%53")" || return 1
  # Exactly one deliver call; first arg is the watch_id.
  assert_eq 1 "$(_deliver_call_count)" || return 1
  local first
  first=$(head -1 "$DELIVER_LOG" | awk '{print $1}')
  assert_eq "$wid" "$first" || return 1
}
run_test "deliver after resolve transitions to delivered on success" test_deliver_after_resolve_transitions_to_delivered_on_success

test_deliver_failure_moves_to_delivery_failed_and_retry_uses_same_watch_id() {
  # Spec: "A failed or timed-out delivery attempt moves the watch to
  # delivery_failed. The daemon may retry only with the same watch_id."
  _install_deliver_mock
  declare -F watch_resolve watch_deliver_attempt >/dev/null || { echo "    missing lifecycle fn"; return 1; }
  local wid rec
  wid=$(_arm_on "%54") || return 1
  watch_resolve "$wid" idle || return 1
  # First attempt fails.
  MOCK_DELIVER_EXIT=7 watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 1 || return 1
  # Retry from delivery_failed; succeeds. Must reuse the same watch_id.
  MOCK_DELIVER_EXIT=0 watch_deliver_attempt "$wid" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1); the
  # retry budget becomes unobservable on disk. The deliver argv log below
  # proves the retry reused the original watch_id and fired exactly twice.
  assert_eq "" "$(watch_get "$wid")" || return 1
  # Two calls, same watch_id on both.
  assert_eq 2 "$(_deliver_call_count)" || return 1
  local ids
  ids=$(awk '{print $1}' "$DELIVER_LOG" | sort -u)
  assert_eq "$wid" "$ids" || return 1
}
run_test "delivery failure moves to delivery_failed and retry uses same watch_id" test_deliver_failure_moves_to_delivery_failed_and_retry_uses_same_watch_id

test_delivery_exhausted_closes_with_reason_after_MAX_DELIVERY_ATTEMPTS() {
  # Spec: "Retries are bounded by MAX_DELIVERY_ATTEMPTS. Exhaustion
  # closes the watch with delivery_exhausted."
  _install_deliver_mock
  declare -F watch_resolve watch_deliver_attempt >/dev/null || { echo "    missing lifecycle fn"; return 1; }
  [[ -n "${MAX_DELIVERY_ATTEMPTS:-}" ]] || { echo "    MAX_DELIVERY_ATTEMPTS unset"; return 1; }
  local wid rec rc=0 i
  wid=$(_arm_on "%55") || return 1
  watch_resolve "$wid" idle || return 1
  # Drive MAX_DELIVERY_ATTEMPTS failures. The last one exhausts.
  for ((i=1; i<=MAX_DELIVERY_ATTEMPTS; i++)); do
    MOCK_DELIVER_EXIT=9 watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  done
  # Terminal state disposes the record on transition (steez-u7o7.1). The
  # post-exhaustion retry refusal below (watch_deliver_attempt returning
  # non-zero with no extra deliver call) is the external signature of
  # close_reason=delivery_exhausted.
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "%55")" || return 1
  # Further retries after exhaustion are refused (no extra deliver call).
  watch_deliver_attempt "$wid" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "    retry after exhaustion must be refused"; return 1; }
  assert_eq "$MAX_DELIVERY_ATTEMPTS" "$(_deliver_call_count)" || return 1
}
run_test "delivery exhausted closes with delivery_exhausted after MAX_DELIVERY_ATTEMPTS" test_delivery_exhausted_closes_with_reason_after_MAX_DELIVERY_ATTEMPTS

# ----- canonical resolver (bead 3) -----
#
# Pure resolver over (watch, evidence) -> {resolve(state), keep_open, ignore}.
# Fresh iff seq > prearm_seq AND (transcript cursor advanced OR screen hash
# differs). `working` keeps open, never resolves. First fresh terminal state
# != baseline_state resolves. Post-resolution evidence is ignored. Baseline
# is never evidence. Pre-watch.start fresh evidence is buffered and
# re-evaluated on arm. See specs/agent-events.md.

suite "canonical resolver"

# Create a pending watch with explicit baseline; overrides _mk_pending's
# hard-coded working baseline so resolver tests can exercise baseline rules
# on already-terminal panes.
_mk_pending_baseline() {
  local pane="$1" baseline="$2"
  watch_create_pending \
    --pane "$pane" \
    --spawner "%0" \
    --label "codex" \
    --baseline-state "$baseline" \
    --prearm-screen-hash "hash-$pane" \
    --prearm-transcript-cursor 4096 \
    --prearm-seq 7
}

test_manual_add_on_already_idle_pane_does_not_resolve_without_fresh_post_prearm_evidence() {
  # Spec (Baseline rules): "a pane already showing idle at prearm does not
  # resolve immediately ... Those watches require fresh post-prearm
  # evidence to resolve." Manual add on an idle pane sets baseline=idle.
  # Evidence that is not fresh (seq <= prearm_seq, or no progress since
  # prearm) must leave the watch armed, never resolved.
  _install_deliver_mock
  declare -F watch_feed_evidence >/dev/null || { echo "    missing: watch_feed_evidence"; return 1; }
  local wid rec
  wid=$(_mk_pending_baseline "%60" idle) || return 1
  watch_arm --pane "%60" --watch-id "$wid" --start-seq 8 >/dev/null || return 1
  # Stale seq (seq <= prearm_seq): not fresh.
  watch_feed_evidence --watch-id "$wid" --seq 5 --candidate-state idle \
    --transcript-cursor 4096 --screen-hash "hash-%60" >/dev/null || true
  # seq advances but transcript cursor unchanged AND screen hash identical:
  # still not fresh, because "transcript evidence comes from bytes appended
  # after the prearm transcript cursor" and "screen evidence ... differs
  # from the prearm capture".
  watch_feed_evidence --watch-id "$wid" --seq 12 --candidate-state idle \
    --transcript-cursor 4096 --screen-hash "hash-%60" >/dev/null || true
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver fired without fresh evidence"; return 1; }
}
run_test "manual_add_on_already_idle_pane_does_not_resolve_without_fresh_post_prearm_evidence" test_manual_add_on_already_idle_pane_does_not_resolve_without_fresh_post_prearm_evidence

test_fresh_terminal_state_different_from_baseline_resolves_watch() {
  # Spec (Canonical resolver rule 3): "The first fresh live-resolving
  # terminal state different from baseline_state resolves the watch."
  _install_deliver_mock
  local wid rec
  wid=$(_mk_pending_baseline "%61" working) || return 1
  watch_arm --pane "%61" --watch-id "$wid" --start-seq 8 >/dev/null || return 1
  # Fresh (seq advanced, cursor advanced) terminal != baseline.
  watch_feed_evidence --watch-id "$wid" --seq 9 --candidate-state idle \
    --transcript-cursor 8192 --screen-hash "hash-%61-new" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
}
run_test "fresh terminal state different from baseline resolves watch" test_fresh_terminal_state_different_from_baseline_resolves_watch

test_working_evidence_keeps_watch_open_and_never_resolves() {
  # Spec (Canonical resolver rule 2): "working can keep the watch open,
  # but it can never resolve it."
  _install_deliver_mock
  local wid rec
  wid=$(_mk_pending_baseline "%62" working) || return 1
  watch_arm --pane "%62" --watch-id "$wid" --start-seq 8 >/dev/null || return 1
  # Fresh working evidence — progress visible, but state is non-terminal.
  watch_feed_evidence --watch-id "$wid" --seq 9 --candidate-state working \
    --transcript-cursor 8192 --screen-hash "hash-%62-step1" >/dev/null || return 1
  watch_feed_evidence --watch-id "$wid" --seq 10 --candidate-state working \
    --transcript-cursor 9000 --screen-hash "hash-%62-step2" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  [[ "$(_deliver_call_count)" == "0" ]] || { echo "    deliver called on working"; return 1; }
}
run_test "working evidence keeps watch open and never resolves" test_working_evidence_keeps_watch_open_and_never_resolves

test_fresh_terminal_state_matching_baseline_does_not_resolve() {
  # Spec (Baseline rules): "The prearm baseline itself is never resolution
  # evidence." A manual add with baseline=blocked:question must not resolve
  # on fresh evidence that reports the same blocked:question state.
  _install_deliver_mock
  local wid rec
  wid=$(_mk_pending_baseline "%63" "blocked:question") || return 1
  watch_arm --pane "%63" --watch-id "$wid" --start-seq 8 >/dev/null || return 1
  watch_feed_evidence --watch-id "$wid" --seq 11 \
    --candidate-state "blocked:question" \
    --transcript-cursor 8192 --screen-hash "hash-%63-new" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
}
run_test "fresh terminal state matching baseline does not resolve" test_fresh_terminal_state_matching_baseline_does_not_resolve

test_resolver_is_one_shot_later_evidence_is_ignored() {
  # Spec (Canonical resolver rule 4): "After resolution, later evidence is
  # ignored." Feeding a different terminal state after resolve must not
  # overwrite the resolved_state.
  _install_deliver_mock
  local wid rec
  wid=$(_mk_pending_baseline "%64" working) || return 1
  watch_arm --pane "%64" --watch-id "$wid" --start-seq 8 >/dev/null || return 1
  watch_feed_evidence --watch-id "$wid" --seq 9 --candidate-state idle \
    --transcript-cursor 8192 --screen-hash "hash-%64-a" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
  # Later fresh evidence with a different terminal state: must be ignored.
  watch_feed_evidence --watch-id "$wid" --seq 10 \
    --candidate-state "blocked:question" \
    --transcript-cursor 9000 --screen-hash "hash-%64-b" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
}
run_test "resolver is one-shot — later evidence is ignored" test_resolver_is_one_shot_later_evidence_is_ignored

test_pre_arm_fresh_evidence_is_buffered_and_resolves_on_arm() {
  # Spec (Ordering and freshness): "Evidence that arrives after turn.prearm
  # and before watch.start is buffered. It becomes eligible when the watch
  # moves to armed." Acceptance #1: "Evidence with seq > prearm_seq that
  # lands before watch.start is buffered and can resolve on start."
  _install_deliver_mock
  local wid rec
  wid=$(_mk_pending_baseline "%65" working) || return 1
  # Feed fresh terminal evidence while still pending — must not resolve
  # (pending never notifies), but must be buffered for re-evaluation on arm.
  watch_feed_evidence --watch-id "$wid" --seq 9 --candidate-state idle \
    --transcript-cursor 8192 --screen-hash "hash-%65-new" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state pending || return 1
  # Arm the watch — buffered fresh terminal != baseline must now resolve.
  watch_arm --pane "%65" --watch-id "$wid" --start-seq 10 >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
}
run_test "pre-arm fresh evidence is buffered and resolves on arm" test_pre_arm_fresh_evidence_is_buffered_and_resolves_on_arm

# ----- live-watch supersession (bead 4) -----
#
# Acceptance #3 (spec: TDD relationship): "A new turn.prearm supersedes an
# unresolved live watch without blocking the new turn." Spec language
# anchors: "Live and draining watches" (live = pending|armed, draining =
# resolved|delivering|delivery_failed, <=1 live per pane, supersession
# does not wait for draining) and "delivered, delivery_failed, closed"
# ("Explicit removal or live-watch supersession closes an unresolved
# watch without delivery").

suite "live-watch supersession"

test_new_prearm_supersedes_live_watch_without_blocking_draining_delivery() {
  # Red test for bead 4. Drives the whole contract end to end:
  #
  #   (a) prearm on a pane with a pending live watch supersedes it —
  #       prior closes with close_reason=superseded, no delivery fires,
  #       pane's live slot now points at the new watch.
  #   (b) a watch that has moved to a draining state (delivery_failed
  #       after a first failed attempt) is NOT live — it leaves the
  #       live slot empty and occupies the draining ledger instead.
  #   (c) a new prearm on a pane whose only prior watch is draining
  #       creates a new live watch WITHOUT touching the draining one.
  #   (d) the draining watch can complete its delivery independently
  #       of the new live watch, and removes itself from the draining
  #       ledger on success. Invariant "<=1 live watch per pane" holds
  #       throughout.
  _install_deliver_mock
  declare -F watch_create_pending watch_arm watch_resolve \
    watch_deliver_attempt watch_get_live watch_get_draining >/dev/null \
    || { echo "    missing required fn"; return 1; }

  local pane="%80" rec drain live_rec

  # (a) Pending watch on %80 gets superseded by a new prearm.
  local w_prior w_live
  w_prior=$(_mk_pending "$pane") || return 1
  w_live=$(watch_create_pending \
    --pane "$pane" \
    --spawner "%0" \
    --label "codex" \
    --baseline-state working \
    --prearm-screen-hash "hash-$pane-new" \
    --prearm-transcript-cursor 8192 \
    --prearm-seq 20) || return 1
  [[ "$w_live" != "$w_prior" ]] \
    || { echo "    new prearm reused prior watch_id"; return 1; }
  # Terminal state disposes the record on transition (steez-u7o7.1).
  # Supersede is a close, so the prior record vanishes.
  assert_eq "" "$(watch_get "$w_prior")" || return 1
  [[ "$(_deliver_call_count)" == "0" ]] \
    || { echo "    deliver fired on supersede"; return 1; }
  live_rec=$(watch_get_live "$pane")
  assert_json_field "$live_rec" .watch_id "$w_live" || return 1
  assert_json_field "$live_rec" .state pending || return 1

  # (b) Advance the new live watch to delivery_failed so it becomes draining.
  watch_arm --pane "$pane" --watch-id "$w_live" --start-seq 21 >/dev/null \
    || return 1
  watch_resolve "$w_live" idle || return 1
  MOCK_DELIVER_EXIT=7 watch_deliver_attempt "$w_live" >/dev/null 2>&1 || true
  rec=$(watch_get "$w_live")
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 1 || return 1
  # Draining now owns the watch; live slot is empty (spec: resolved/
  # delivering/delivery_failed are draining, not live).
  assert_eq "" "$(watch_get_live "$pane")" || return 1
  drain=$(watch_get_draining "$pane")
  assert_eq 1 "$(printf '%s\n' "$drain" | jq -s 'length')" || return 1
  assert_json_field "$(printf '%s' "$drain" | jq -sc '.[0]')" \
    .watch_id "$w_live" || return 1

  # (c) New prearm on the same pane must not block on the draining watch.
  local w_next
  w_next=$(watch_create_pending \
    --pane "$pane" \
    --spawner "%0" \
    --label "codex" \
    --baseline-state working \
    --prearm-screen-hash "hash-$pane-next" \
    --prearm-transcript-cursor 9000 \
    --prearm-seq 40) || return 1
  # Draining record untouched — same state, same retry budget.
  rec=$(watch_get "$w_live")
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 1 || return 1
  # New live watch is the only live watch on the pane.
  live_rec=$(watch_get_live "$pane")
  assert_json_field "$live_rec" .watch_id "$w_next" || return 1
  assert_json_field "$live_rec" .state pending || return 1
  # Draining ledger still holds exactly the prior watch.
  drain=$(watch_get_draining "$pane")
  assert_eq 1 "$(printf '%s\n' "$drain" | jq -s 'length')" || return 1
  assert_json_field "$(printf '%s' "$drain" | jq -sc '.[0]')" \
    .watch_id "$w_live" || return 1

  # (d) Draining delivery completes independently and exits the ledger.
  MOCK_DELIVER_EXIT=0 watch_deliver_attempt "$w_live" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$w_live")" || return 1
  assert_eq "" "$(watch_get_draining "$pane")" || return 1
  # New live watch still untouched throughout.
  live_rec=$(watch_get_live "$pane")
  assert_json_field "$live_rec" .watch_id "$w_next" || return 1
  assert_json_field "$live_rec" .state pending || return 1
}
run_test "new_prearm_supersedes_live_watch_without_blocking_draining_delivery" test_new_prearm_supersedes_live_watch_without_blocking_draining_delivery

# _assert_live_count <pane> <0|1>
# Invariant probe: watch_get_live returns either an empty string or one
# JSON record. Counts records in a way that catches either a bad
# multi-record store layout (shouldn't happen) or a missed clear after
# transition.
_assert_live_count() {
  local pane="$1" expected="$2" live n
  live=$(watch_get_live "$pane")
  if [[ "$expected" == "0" ]]; then
    [[ -z "$live" ]] || { echo "    expected 0 live, got: $live"; return 1; }
    return 0
  fi
  [[ -n "$live" ]] || { echo "    expected 1 live, got empty"; return 1; }
  n=$(printf '%s\n' "$live" | jq -s 'length')
  assert_eq 1 "$n" || return 1
}

test_at_most_one_live_watch_per_pane_under_concurrent_turn_sequences() {
  # Spec invariant (Live and draining watches): "At most one live watch
  # may exist per pane." Every transition below is followed by a live
  # count check. Exercises the three concurrent sequences the spec must
  # survive:
  #
  #   (1) rapid prearm -> prearm -> prearm, superseding while pending;
  #   (2) prearm over an armed live watch (supersede a live that has
  #       already received watch.start);
  #   (3) multiple draining watches coexisting on the same pane while a
  #       fresh live turn runs ahead of them.
  _install_deliver_mock
  local pane="%81"

  # (1) pending-phase rapid supersession.
  local w1 w2 w3
  w1=$(_mk_pending "$pane") || return 1
  _assert_live_count "$pane" 1 || return 1
  w2=$(watch_create_pending --pane "$pane" --spawner "%0" --label codex \
    --baseline-state working --prearm-screen-hash "h-a" \
    --prearm-transcript-cursor 100 --prearm-seq 10) || return 1
  _assert_live_count "$pane" 1 || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$w1")" || return 1
  w3=$(watch_create_pending --pane "$pane" --spawner "%0" --label codex \
    --baseline-state working --prearm-screen-hash "h-b" \
    --prearm-transcript-cursor 200 --prearm-seq 20) || return 1
  _assert_live_count "$pane" 1 || return 1
  assert_eq "" "$(watch_get "$w2")" || return 1
  assert_json_field "$(watch_get_live "$pane")" .watch_id "$w3" || return 1

  # (2) armed-phase supersession. Arm w3, then prearm w4.
  watch_arm --pane "$pane" --watch-id "$w3" --start-seq 21 >/dev/null \
    || return 1
  _assert_live_count "$pane" 1 || return 1
  local w4
  w4=$(watch_create_pending --pane "$pane" --spawner "%0" --label codex \
    --baseline-state working --prearm-screen-hash "h-c" \
    --prearm-transcript-cursor 300 --prearm-seq 30) || return 1
  _assert_live_count "$pane" 1 || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$w3")" || return 1
  [[ "$(_deliver_call_count)" == "0" ]] \
    || { echo "    supersede fired a delivery"; return 1; }

  # (3) pile up two draining watches on the pane and start a new live
  # turn ahead of them.
  watch_arm --pane "$pane" --watch-id "$w4" --start-seq 31 >/dev/null \
    || return 1
  watch_resolve "$w4" idle || return 1
  _assert_live_count "$pane" 0 || return 1
  MOCK_DELIVER_EXIT=7 watch_deliver_attempt "$w4" >/dev/null 2>&1 || true
  assert_json_field "$(watch_get "$w4")" .state delivery_failed || return 1
  _assert_live_count "$pane" 0 || return 1

  local w5 w6
  w5=$(watch_create_pending --pane "$pane" --spawner "%0" --label codex \
    --baseline-state working --prearm-screen-hash "h-d" \
    --prearm-transcript-cursor 400 --prearm-seq 40) || return 1
  _assert_live_count "$pane" 1 || return 1
  watch_arm --pane "$pane" --watch-id "$w5" --start-seq 41 >/dev/null \
    || return 1
  watch_resolve "$w5" "blocked:question" || return 1
  MOCK_DELIVER_EXIT=7 watch_deliver_attempt "$w5" >/dev/null 2>&1 || true
  assert_json_field "$(watch_get "$w5")" .state delivery_failed || return 1
  _assert_live_count "$pane" 0 || return 1

  w6=$(watch_create_pending --pane "$pane" --spawner "%0" --label codex \
    --baseline-state working --prearm-screen-hash "h-e" \
    --prearm-transcript-cursor 500 --prearm-seq 50) || return 1
  _assert_live_count "$pane" 1 || return 1

  # Two draining watches share the pane with one live watch.
  local drain ids
  drain=$(watch_get_draining "$pane")
  assert_eq 2 "$(printf '%s\n' "$drain" | jq -s 'length')" || return 1
  ids=$(printf '%s\n' "$drain" | jq -r .watch_id | sort)
  assert_eq "$(printf '%s\n%s' "$w4" "$w5" | sort)" "$ids" || return 1

  # Drain both to completion via retry; live stays on w6 throughout.
  MOCK_DELIVER_EXIT=0 watch_deliver_attempt "$w4" || return 1
  _assert_live_count "$pane" 1 || return 1
  MOCK_DELIVER_EXIT=0 watch_deliver_attempt "$w5" || return 1
  _assert_live_count "$pane" 1 || return 1
  # Terminal state disposes the records on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$w4")" || return 1
  assert_eq "" "$(watch_get "$w5")" || return 1
  assert_eq "" "$(watch_get_draining "$pane")" || return 1
  assert_json_field "$(watch_get_live "$pane")" .watch_id "$w6" || return 1
  assert_json_field "$(watch_get_live "$pane")" .state pending || return 1
}
run_test "at_most_one_live_watch_per_pane_under_concurrent_turn_sequences" test_at_most_one_live_watch_per_pane_under_concurrent_turn_sequences

# ----- delivery idempotency and bounded retries (bead 5) -----
#
# Acceptance #4 (spec: TDD relationship): one watch_id produces one
# logical notification across duplicate evidence and bounded retries.
# Every assertion below is grounded in spec language — see
# "Delivery contract", "resolved" lifecycle, and "delivering" lifecycle
# sections of specs/agent-events.md. This test exists to guard the
# woven contract, not to introduce new behavior.

suite "delivery idempotency"

# Deliver mock variant used by bead-5 tests:
#
# - Logs every invocation's argv to $DELIVER_LOG so the test can count
#   attempts and assert all attempts share the same watch_id.
# - Captures the on-disk record state at the moment agent-deliver is
#   invoked to $DELIVER_STATE_LOG so the test can assert the spec's
#   "daemon must persist resolved before it invokes agent-deliver"
#   gate — i.e. disk state is `delivering` (the persistence checkpoint
#   following `resolved`) every time the external command runs, never
#   `armed` or `pending`.
# - Honors ATTEMPT_EXIT_SEQ, a whitespace-separated list of exit codes
#   indexed by the 1-based attempt number, so one test can stage a
#   mixed failure/success sequence without re-exporting MOCK_DELIVER_EXIT
#   between calls.
_install_bead5_deliver_mock() {
  export DELIVER_LOG="$TEST_TMP/deliver.log"
  export DELIVER_STATE_LOG="$TEST_TMP/deliver-state.log"
  export DELIVER_STATE_DIR_AT_CALL="$_EVENTSD_STATE_DIR"
  : > "$DELIVER_LOG"
  : > "$DELIVER_STATE_LOG"
  cat > "$MOCK_BIN/agent-deliver" <<'MOCK'
#!/usr/bin/env bash
wid="$1"
printf '%s\n' "$*" >> "${DELIVER_LOG:-/dev/null}"
if [[ -f "$DELIVER_STATE_DIR_AT_CALL/watches/$wid.json" ]]; then
  jq -r .state "$DELIVER_STATE_DIR_AT_CALL/watches/$wid.json" \
    >> "${DELIVER_STATE_LOG:-/dev/null}"
else
  echo "NOREC" >> "${DELIVER_STATE_LOG:-/dev/null}"
fi
n=$(wc -l < "$DELIVER_LOG" | tr -d ' ')
val=$(awk -v n="$n" 'BEGIN{split(ENVIRON["ATTEMPT_EXIT_SEQ"],a," "); print a[n]}')
exit "${val:-0}"
MOCK
  chmod +x "$MOCK_BIN/agent-deliver"
  export AGENT_DELIVER_CMD="$MOCK_BIN/agent-deliver"

  # Spec: "It must call agent-deliver. It must never call agent-send."
  # Tripwire — if anything in the daemon shells out to agent-send, the
  # file appears and the sole-notifier assertion fires.
  export AGENT_SEND_TRIPWIRE="$TEST_TMP/agent-send-tripwire"
  rm -f "$AGENT_SEND_TRIPWIRE"
  cat > "$MOCK_BIN/agent-send" <<'SEND'
#!/usr/bin/env bash
touch "${AGENT_SEND_TRIPWIRE:-/dev/null}"
exit 99
SEND
  chmod +x "$MOCK_BIN/agent-send"
}

test_one_watch_id_produces_one_logical_notification_across_duplicate_evidence_and_bounded_retries() {
  # Required first red test for bead 5. Every assertion ties back to
  # specs/agent-events.md:
  #
  #   (a) One-shot resolve — "Once resolved, the watch is one-shot.
  #       Later evidence for that watch_id is ignored."
  #   (b) Retries reuse watch_id — "The daemon may retry only with the
  #       same watch_id."
  #   (c) Persist-before-deliver — "The daemon must persist `resolved`
  #       before it invokes `agent-deliver`." Observed by the mock
  #       reading on-disk state at call time; must be `delivering` (the
  #       persistence checkpoint the daemon writes after reading the
  #       persisted `resolved` record and before invoking the cmd).
  #   (d) Sole notifier — "It must never call agent-send."
  #   (e) Bounded retries — "Retries are bounded by
  #       MAX_DELIVERY_ATTEMPTS."
  #   (f) One logical notification — "One watch has exactly one logical
  #       notification."
  _install_bead5_deliver_mock
  declare -F watch_resolve watch_deliver_attempt >/dev/null \
    || { echo "    missing lifecycle fn"; return 1; }
  [[ "${MAX_DELIVERY_ATTEMPTS:-0}" == "5" ]] \
    || { echo "    MAX_DELIVERY_ATTEMPTS must default to 5"; return 1; }

  local wid rec
  wid=$(_arm_on "%70") || return 1

  # (a) Duplicate evidence across the resolve window — only the first
  # terminal state sticks.
  watch_resolve "$wid" idle || return 1
  watch_resolve "$wid" "blocked:question" >/dev/null 2>&1 || true
  watch_resolve "$wid" idle >/dev/null 2>&1 || true
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .resolved_state idle || return 1

  # (e) Drive four failures and one success — total 5 attempts, the
  # upper edge of the retry budget. Proves the boundary is usable
  # rather than off-by-one, and lets (f) distinguish "delivered once"
  # from "delivered multiple times" across the retry stream.
  export ATTEMPT_EXIT_SEQ="7 7 7 7 0"
  local i
  for ((i=1; i<=4; i++)); do
    watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
    # Duplicate mid-retry evidence must remain a no-op (a).
    watch_resolve "$wid" idle >/dev/null 2>&1 || true
  done
  watch_deliver_attempt "$wid" || return 1

  # Terminal state disposes the record on transition (steez-u7o7.1). The
  # retry budget becomes unobservable on disk; the deliver log below
  # proves exactly 5 attempts, all against the original watch_id.
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "%70")" || return 1

  # (b) Every deliver call carried the same watch_id.
  local ids
  ids=$(awk '{print $1}' "$DELIVER_LOG" | sort -u)
  assert_eq "$wid" "$ids" || return 1
  assert_eq 5 "$(_deliver_call_count)" || return 1

  # (c) Persist-before-deliver gate.
  local bad
  bad=$(grep -vFx delivering "$DELIVER_STATE_LOG" || true)
  [[ -z "$bad" ]] || { echo "    non-delivering at-call states: $bad"; return 1; }

  # (d) Sole notifier.
  [[ ! -e "$AGENT_SEND_TRIPWIRE" ]] || { echo "    daemon called agent-send"; return 1; }

  # (f) One logical notification — post-delivered duplicate evidence
  # and rogue retry attempts must neither resurrect the record nor
  # trigger another agent-deliver invocation.
  watch_resolve "$wid" "blocked:permission" >/dev/null 2>&1 || true
  watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  assert_eq 5 "$(_deliver_call_count)" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1);
  # post-terminal evidence does not re-create it.
  assert_eq "" "$(watch_get "$wid")" || return 1
}
run_test "one_watch_id_produces_one_logical_notification_across_duplicate_evidence_and_bounded_retries" test_one_watch_id_produces_one_logical_notification_across_duplicate_evidence_and_bounded_retries

# ----- degraded fallback (bead 6) -----
#
# Spec (Degraded fallback + acceptance #5):
#   - healthy while at least one fast observer produces fresh evidence
#   - silence past SILENCE_WINDOW_MS => degraded
#   - in degraded, run agent-state <pane> every RECONCILE_INTERVAL_MS
#   - deadman reconciliation feeds the same canonical resolver
#   - if a degraded episode lasts INDETERMINATE_TIMEOUT_MS without a terminal
#     state, the watch resolves to blocked:unknown
#   - returning to healthy clears the degraded timer; a later degraded episode
#     starts a new window
#
# Tests use a fake clock (EVENTSD_NOW_MS) and a fake agent-state so the whole
# degraded machinery can be exercised without real timers.

suite "degraded fallback"

_set_now() { export EVENTSD_NOW_MS="$1"; }

# Install a fake agent-state at $MOCK_BIN/agent-state. Logs argv per call to
# AGENT_STATE_LOG and emits AGENT_STATE_RESPONSE (default: state=working, so
# reconciles never resolve on their own and the indeterminate-timeout path is
# the only resolution route).
_install_agent_state_mock() {
  export AGENT_STATE_LOG="$TEST_TMP/agent-state.log"
  : > "$AGENT_STATE_LOG"
  if [[ -z "${AGENT_STATE_RESPONSE:-}" ]]; then
    AGENT_STATE_RESPONSE='{"pane":"%0","agent":"codex","state":"working","name":"t"}'
  fi
  export AGENT_STATE_RESPONSE
  cat > "$MOCK_BIN/agent-state" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AGENT_STATE_LOG:-/dev/null}"
printf '%s\n' "${AGENT_STATE_RESPONSE:-{\"state\":\"working\"}}"
exit 0
MOCK
  chmod +x "$MOCK_BIN/agent-state"
  export AGENT_STATE_CMD="$MOCK_BIN/agent-state"
}

_agent_state_call_count() {
  [[ -s "${AGENT_STATE_LOG:-/dev/null}" ]] || { echo 0; return; }
  wc -l < "$AGENT_STATE_LOG" | tr -d ' '
}

# Seed the pane's seq counter so prearm_seq / start_seq / reconcile seqs stay
# monotonic across the whole bead-6 fixture. Without this, the shared _arm_on
# helper hard-codes prearm_seq=7 while seq_next starts at 1, which would make
# every reconcile seq stale by the freshness rule (seq > prearm_seq).
_arm_on_bead6() {
  local pane="$1" wid prearm_seq start_seq
  prearm_seq=$(seq_next "$pane")
  wid=$(watch_create_pending \
    --pane "$pane" \
    --spawner "%0" \
    --label "codex" \
    --baseline-state working \
    --prearm-screen-hash "hash-$pane" \
    --prearm-transcript-cursor 4096 \
    --prearm-seq "$prearm_seq") || return 1
  start_seq=$(seq_next "$pane")
  watch_arm --pane "$pane" --watch-id "$wid" --start-seq "$start_seq" \
    >/dev/null || return 1
  printf '%s' "$wid"
}

test_fresh_fast_evidence_after_degraded_returns_to_healthy_and_clears_degraded_timer() {
  # Spec (Degraded fallback): "Returning to healthy clears the degraded
  # timer." Proves the marker fields are actually cleared on fresh
  # fast-path evidence — not just that the resolver keeps the watch armed.
  _install_deliver_mock
  AGENT_STATE_RESPONSE='{"state":"blocked:unknown"}'
  export AGENT_STATE_RESPONSE
  _install_agent_state_mock

  local pane="%91" wid rec ds t0=2000000
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # Cross silence window: the next tick degrades the watch and runs a
  # first reconcile.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  ds=$(printf '%s' "$rec" | jq -r '.degraded_since_ms // null')
  [[ "$ds" != null && -n "$ds" ]] \
    || { echo "    degraded_since_ms not recorded"; return 1; }
  local lr
  lr=$(printf '%s' "$rec" | jq -r '.last_reconcile_ms // null')
  [[ "$lr" != null && -n "$lr" ]] \
    || { echo "    last_reconcile_ms not recorded"; return 1; }

  # Fresh fast-path evidence arrives — `working` keeps the watch open but
  # must return it to healthy: last_evidence_ms refreshed, degraded_since
  # and last_reconcile cleared.
  _set_now $((t0 + 40000))
  watch_feed_evidence --watch-id "$wid" --seq 50 \
    --candidate-state working --transcript-cursor 5000 \
    --screen-hash "fast-recover" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .degraded_since_ms null || return 1
  assert_json_field "$rec" .last_reconcile_ms null || return 1
  assert_json_field "$rec" .last_evidence_ms $((t0 + 40000)) || return 1
}
run_test "fresh_fast_evidence_after_degraded_returns_to_healthy_and_clears_degraded_timer" test_fresh_fast_evidence_after_degraded_returns_to_healthy_and_clears_degraded_timer

test_second_degraded_episode_starts_a_new_indeterminate_timeout_window() {
  # Spec (Degraded fallback): "A later degraded episode starts a new
  # timeout window." A first episode that returns to healthy must not
  # leak its elapsed time into the next one. Proves the window is timed
  # from the most recent degraded_since_ms, not from arm.
  #
  # Post-steez-fyjy: the indeterminate window no longer matures to
  # blocked:unknown. The window survives as a diagnostic — `degraded_since_ms`
  # still restarts cleanly per episode, the watch stays armed past it.
  _install_deliver_mock
  AGENT_STATE_RESPONSE='{"state":"blocked:unknown"}'
  export AGENT_STATE_RESPONSE
  _install_agent_state_mock

  local pane="%92" wid rec t0=3000000
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # First degraded episode — cross silence, then return to healthy after
  # 30s of degraded time.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1

  local healthy_at=$((t0 + 60000))
  _set_now "$healthy_at"
  watch_feed_evidence --watch-id "$wid" --seq 50 \
    --candidate-state working --transcript-cursor 5000 \
    --screen-hash "fast-recover-1" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .degraded_since_ms null || return 1

  # Second degraded episode starts SILENCE_WINDOW_MS after the last fast
  # evidence. The first episode's elapsed time must not carry over.
  local second_degraded_at=$((healthy_at + 30000))
  _set_now "$second_degraded_at"
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .degraded_since_ms "$second_degraded_at" || return 1

  # Drive past the full indeterminate window from the new
  # degraded_since_ms. Under the steez-fyjy contract the watch stays
  # armed — blocked:unknown is no longer a terminal degraded-timeout
  # outcome; a real terminal ping is the only thing that can resolve.
  _set_now $((second_degraded_at + 120000 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_eq 0 "$(_deliver_call_count)" || return 1
}
run_test "second_degraded_episode_starts_a_new_indeterminate_timeout_window" test_second_degraded_episode_starts_a_new_indeterminate_timeout_window

test_fuzzy_blocked_unknown_does_not_resolve_a_live_watch() {
  # Spec (live watch resolution): a fuzzy blocked:unknown sample from
  # degraded reconciliation must not resolve or self-clear a live watch.
  # Post-steez-fyjy: blocked:unknown is no longer a terminal watch
  # outcome at all — the degraded-window diagnostic logs past the
  # indeterminate threshold but keeps the watch armed. Only a real
  # live-resolving terminal ping (idle / blocked:question /
  # blocked:permission), pane close, or explicit remove retires it.
  _install_deliver_mock
  export AGENT_STATE_LOG="$TEST_TMP/agent-state.log"
  : > "$AGENT_STATE_LOG"
  cat > "$MOCK_BIN/agent-state" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${AGENT_STATE_LOG:-/dev/null}"
echo '{"state":"blocked:unknown"}'
MOCK
  chmod +x "$MOCK_BIN/agent-state"
  export AGENT_STATE_CMD="$MOCK_BIN/agent-state"

  local pane="%93" wid rec t0=4000000 live
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # First degraded reconcile sees fuzzy blocked:unknown. The watch must
  # stay armed and keep the live slot.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .degraded_since_ms $((t0 + 30000)) || return 1
  live=$(watch_get_live "$pane")
  assert_json_field "$live" .watch_id "$wid" || return 1
  assert_eq 1 "$(_agent_state_call_count)" || return 1

  # Later fuzzy samples are still non-resolving.
  _set_now $((t0 + 35000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  live=$(watch_get_live "$pane")
  assert_json_field "$live" .watch_id "$wid" || return 1
  assert_eq 2 "$(_agent_state_call_count)" || return 1

  # Past the old indeterminate window the watch still stays armed — no
  # terminal blocked:unknown resolution fires from the degraded timer.
  _set_now $((t0 + 30000 + 120000 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  live=$(watch_get_live "$pane")
  assert_json_field "$live" .watch_id "$wid" || return 1
  assert_eq 0 "$(_deliver_call_count)" || return 1
}
run_test "fuzzy_blocked_unknown_does_not_resolve_a_live_watch" test_fuzzy_blocked_unknown_does_not_resolve_a_live_watch

# ----- bead steez-j815: real-cursor freshness in degraded reconcile -----
#
# The degraded-fallback reconcile used to synthesize a per-tick screen hash
# (`hash="degraded-$now"`) which trivially differed from the prearm hash, so
# every reconcile passed the freshness gate regardless of actual liveness.
# That produced two opposite failure modes:
#
#   A. Inspector silent (agent-state non-zero) — no evidence fed, no fresh
#      signal, deadman matured, watch resolved to a fake blocked:unknown and
#      delivered. Spawner saw a spurious notif and the real completion was
#      silent.
#
#   B. Stale `working` (hung Claude) — reconcile returned working with the
#      same transcript cursor every tick. Synthetic hash made every reconcile
#      "fresh", deadman reset forever, watch never timed out.
#
# The fix replaces the synthetic hash with a real transcript-cursor signal
# and requires advance for reconcile+working. A belt-and-suspenders gate on
# the indeterminate timeout keeps the watch armed when the inspector has
# never returned output at all (case A safety).

# _install_transcript_agent_state_mock <transcript_path>
# Install an agent-state mock that emits state=$AGENT_STATE_RESPONSE_STATE
# (default "working") with detail.transcript_path pointed at <transcript_path>.
# Tests grow/shrink that file between ticks to simulate cursor advance or
# freeze.
_install_transcript_agent_state_mock() {
  local tpath="$1"
  export AGENT_STATE_LOG="$TEST_TMP/agent-state.log"
  export AGENT_STATE_TPATH="$tpath"
  : > "$AGENT_STATE_LOG"
  cat > "$MOCK_BIN/agent-state" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AGENT_STATE_LOG:-/dev/null}"
state="${AGENT_STATE_RESPONSE_STATE:-working}"
printf '{"pane":"%s","agent":"codex","state":"%s","name":"t","detail":{"transcript_path":"%s"}}\n' \
  "$1" "$state" "${AGENT_STATE_TPATH:-}"
MOCK
  chmod +x "$MOCK_BIN/agent-state"
  export AGENT_STATE_CMD="$MOCK_BIN/agent-state"
}

# Install an agent-state mock that always exits non-zero with no output,
# simulating an inspector that is broken / the pane not discoverable / the
# worker process gone.
_install_failing_agent_state_mock() {
  export AGENT_STATE_LOG="$TEST_TMP/agent-state.log"
  : > "$AGENT_STATE_LOG"
  cat > "$MOCK_BIN/agent-state" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AGENT_STATE_LOG:-/dev/null}"
exit 1
MOCK
  chmod +x "$MOCK_BIN/agent-state"
  export AGENT_STATE_CMD="$MOCK_BIN/agent-state"
}

test_inspector_silent_throughout_degraded_window_keeps_watch_armed() {
  # Acceptance A (steez-j815): when agent-state exits non-zero for the full
  # indeterminate window, no evidence is fed, the watch must NOT mature to
  # blocked:unknown. `last_reconcile_ms` is the safety gate — it must stay
  # 0 while the inspector is silent, blocking the timeout path. Stderr must
  # carry at least one inspector-failure line per reconcile so operators
  # can see the broken inspector.
  _install_deliver_mock
  _install_failing_agent_state_mock

  local pane="%94" wid rec stderr_file t0=5000000 t
  stderr_file="$TEST_TMP/eventsd.stderr.94"
  : > "$stderr_file"
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # Cross silence. Reconcile call happens but returns empty output.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >>"$stderr_file" 2>&1 || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_eq 1 "$(_agent_state_call_count)" || return 1
  # Safety-gate marker: last_reconcile_ms must remain unset while the
  # inspector is broken — otherwise the indeterminate timeout would mature.
  assert_json_field "$rec" '.last_reconcile_ms // 0' 0 || return 1

  # Drive well past the indeterminate timeout. Watch must stay armed on
  # every tick; resolving to blocked:unknown here is the bug being fixed.
  for (( t = t0 + 35000; t <= t0 + 30000 + 120000 + 10000; t += 5000 )); do
    _set_now "$t"
    watch_tick "$wid" >>"$stderr_file" 2>&1 || return 1
    rec=$(watch_get "$wid")
    assert_json_field "$rec" .state armed || return 1
  done

  # Pane slot still owned by the same watch.
  local live
  live=$(watch_get_live "$pane")
  assert_json_field "$live" .watch_id "$wid" || return 1
  assert_json_field "$live" .state armed || return 1

  # Each reconcile must log an inspector-failure line to stderr so silent
  # inspector drift is visible in production.
  local fail_lines
  fail_lines=$(grep -c 'reconcile inspector returned empty output' "$stderr_file" || true)
  local call_count
  call_count=$(_agent_state_call_count)
  [[ "$fail_lines" -ge "$call_count" ]] \
    || { echo "    expected >= $call_count stderr lines, got $fail_lines"; return 1; }
}
run_test "inspector_silent_throughout_degraded_window_keeps_watch_armed" test_inspector_silent_throughout_degraded_window_keeps_watch_armed

test_stale_working_with_unchanged_cursor_stays_armed_past_indeterminate_window() {
  # Acceptance B (steez-j815 + steez-fyjy): a frozen Claude returns
  # state=working with the same transcript cursor every reconcile. Under
  # real-cursor freshness the reconcile is not fresh, so the deadman does
  # not reset. Pre-steez-fyjy, the indeterminate timeout matured to
  # blocked:unknown and delivered — producing false attention on a worker
  # that was still running. The post-steez-fyjy contract: the watch stays
  # armed and waits for a real terminal ping. No spurious delivery.
  _install_deliver_mock

  # Transcript file pinned at exactly prearm_transcript_cursor (4096) so
  # the frozen-worker cursor fails `cursor > prearm_cursor` on every
  # reconcile. `_arm_on_bead6` sets prearm_transcript_cursor to 4096.
  local tpath="$TEST_TMP/transcript-95.jsonl"
  : > "$tpath"
  head -c 4096 < /dev/zero > "$tpath"
  _install_transcript_agent_state_mock "$tpath"
  export AGENT_STATE_RESPONSE_STATE="working"

  local pane="%95" wid rec t0=6000000
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # Cross silence. First reconcile: cursor frozen at prearm value → not
  # fresh, degraded_since stays stamped, last_reconcile_ms stamped.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .degraded_since_ms $((t0 + 30000)) || return 1
  assert_json_field "$rec" .last_reconcile_ms $((t0 + 30000)) || return 1

  # Drive well past the indeterminate window. Under the steez-fyjy
  # contract the watch remains armed on every tick.
  local t
  for (( t = t0 + 30000 + 120000 - 1; t <= t0 + 30000 + 120000 + 60000; t += 5000 )); do
    _set_now "$t"
    watch_tick "$wid" >/dev/null || return 1
    rec=$(watch_get "$wid")
    assert_json_field "$rec" .state armed \
      || { echo "    watch unexpectedly resolved at t+$((t - t0))"; return 1; }
  done

  # No delivery ever fired from the degraded timer — spurious
  # blocked:unknown is the bug this test locks out.
  assert_eq 0 "$(_deliver_call_count)" || return 1
}
run_test "stale_working_with_unchanged_cursor_stays_armed_past_indeterminate_window" test_stale_working_with_unchanged_cursor_stays_armed_past_indeterminate_window

test_working_with_cursor_advance_keeps_watch_armed_indefinitely() {
  # Acceptance C (steez-j815): when reconcile+working carries a strictly
  # advancing transcript cursor, that IS fresh liveness proof for the
  # active watch. The daemon must keep the watch armed, push
  # last_evidence_ms forward, and never mature the indeterminate timeout.
  _install_deliver_mock

  local tpath="$TEST_TMP/transcript-96.jsonl"
  head -c 5000 < /dev/zero > "$tpath"  # starts > prearm_cursor (4096)
  _install_transcript_agent_state_mock "$tpath"
  export AGENT_STATE_RESPONSE_STATE="working"

  local pane="%96" wid rec t0=7000000 t last_ev prev_ev
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # Cross silence. First reconcile: cursor=5000 > prearm=4096 and >
  # last_reconcile_cursor=0 → fresh. Watch returns to healthy.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  last_ev=$(printf '%s' "$rec" | jq -r '.last_evidence_ms')
  assert_eq $((t0 + 30000)) "$last_ev" || return 1

  # Drive far past the old timeout boundary. Between ticks, grow the
  # transcript so each reconcile observes a strictly larger cursor.
  prev_ev="$last_ev"
  for (( t = t0 + 60000; t <= t0 + 30000 + 120000 + 30000; t += 30000 )); do
    # Silence → degraded → one reconcile tick with fresh cursor.
    head -c 200 < /dev/zero >> "$tpath"
    _set_now "$t"
    watch_tick "$wid" >/dev/null || return 1
    rec=$(watch_get "$wid")
    assert_json_field "$rec" .state armed || return 1
    last_ev=$(printf '%s' "$rec" | jq -r '.last_evidence_ms')
    [[ "$last_ev" -gt "$prev_ev" ]] \
      || { echo "    last_evidence_ms did not advance: $prev_ev -> $last_ev"; return 1; }
    prev_ev="$last_ev"
  done

  # Pane slot still owned by the same watch.
  local live
  live=$(watch_get_live "$pane")
  assert_json_field "$live" .watch_id "$wid" || return 1
}
run_test "working_with_cursor_advance_keeps_watch_armed_indefinitely" test_working_with_cursor_advance_keeps_watch_armed_indefinitely

test_idle_reconcile_resolves_cleanly_via_fast_path_semantics_not_blocked_unknown() {
  # Acceptance D (steez-j815): a reconcile that proves idle (live-resolving
  # terminal, != baseline) must resolve the watch to idle via the normal
  # fast-path semantics, not blocked:unknown. Baseline is `working` via
  # `_arm_on_bead6`; the cursor is advanced beyond prearm so freshness
  # passes for the else-branch (non-working reconcile) path.
  _install_deliver_mock

  local tpath="$TEST_TMP/transcript-97.jsonl"
  head -c 5000 < /dev/zero > "$tpath"
  _install_transcript_agent_state_mock "$tpath"
  export AGENT_STATE_RESPONSE_STATE="idle"

  local pane="%97" wid rec t0=8000000
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # Cross silence. Reconcile returns idle with cursor=5000 > prearm=4096,
  # which is the freshness rule for non-working reconciles. idle is a
  # live-resolving terminal state and differs from baseline=working, so
  # the watch resolves cleanly to idle.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
}
run_test "idle_reconcile_resolves_cleanly_via_fast_path_semantics_not_blocked_unknown" test_idle_reconcile_resolves_cleanly_via_fast_path_semantics_not_blocked_unknown

# ----- bead steez-ymcx: fuzzy reconcile state with advancing cursor -----
#
# Live repro on worker panes %65 and %66 (watches 3e46f1e7 / b4656a23):
# both workers wrote ~460KB of transcript over their watch lifetime, but
# agent-state kept returning `blocked:unknown` because Claude's "Esc to
# cancel" screen tail is a working indicator that `screen_blocked_state`
# conservatively classifies as blocked:unknown. Reconcile evidence was
# accepted as "fresh" on the prearm-cursor gate, but the reset-to-healthy
# branch only fired for state=working — so the watch stayed degraded,
# the indeterminate timeout matured to a spurious blocked:unknown, and
# the watch was marked delivered while the worker kept running. When
# the worker's real Stop hook fired later, the watch was already
# terminal and the completion was silently dropped.
#
# Ground truth: a transcript cursor that strictly advances over both
# the prearm baseline and the most recent reconcile IS liveness proof.
# A growing transcript is worker output; the inspector's best guess at
# categorization cannot overrule it. The deadman must reset on
# advancing cursor regardless of whether the observed state is
# `working` or the fuzzy `blocked:unknown`.

_arm_on_prearm_cursor() {
  local pane="$1" prearm_cursor="$2" wid prearm_seq start_seq
  prearm_seq=$(seq_next "$pane")
  wid=$(watch_create_pending \
    --pane "$pane" \
    --spawner "%0" \
    --label "codex" \
    --baseline-state working \
    --prearm-screen-hash "hash-$pane" \
    --prearm-transcript-cursor "$prearm_cursor" \
    --prearm-seq "$prearm_seq") || return 1
  start_seq=$(seq_next "$pane")
  watch_arm --pane "$pane" --watch-id "$wid" --start-seq "$start_seq" \
    >/dev/null || return 1
  printf '%s' "$wid"
}

test_fuzzy_blocked_unknown_with_advancing_cursor_is_liveness_proof() {
  # Bead steez-ymcx: agent-state may return blocked:unknown for a worker
  # that is actually working. When the transcript cursor is advancing,
  # the worker is demonstrably not frozen — reset the deadman instead
  # of maturing the indeterminate timeout.
  _install_deliver_mock

  local tpath="$TEST_TMP/transcript-ymcx.jsonl"
  : > "$tpath"
  _install_transcript_agent_state_mock "$tpath"
  export AGENT_STATE_RESPONSE_STATE="blocked:unknown"

  local pane="%165" wid rec t0=10000000 t last_ev prev_ev
  _set_now "$t0"
  wid=$(_arm_on_prearm_cursor "$pane" 0) || return 1

  # Cross silence with an advancing transcript. The first reconcile
  # sees state=blocked:unknown with a cursor that strictly exceeds
  # prearm (0). That MUST reset the deadman.
  head -c 10000 < /dev/zero > "$tpath"
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .degraded_since_ms null || return 1
  assert_json_field "$rec" .last_evidence_ms $((t0 + 30000)) || return 1

  # Drive past the old indeterminate-timeout boundary. Each 30s silence
  # re-enters degraded; each reconcile sees an advancing cursor. Watch
  # must stay armed and last_evidence_ms must advance on every tick.
  prev_ev=$((t0 + 30000))
  for (( t = t0 + 60000; t <= t0 + 30000 + 120000 + 60000; t += 30000 )); do
    head -c 5000 < /dev/zero >> "$tpath"
    _set_now "$t"
    watch_tick "$wid" >/dev/null || return 1
    rec=$(watch_get "$wid")
    assert_json_field "$rec" .state armed \
      || { echo "    watch unexpectedly left armed at t+$((t - t0))"; return 1; }
    last_ev=$(printf '%s' "$rec" | jq -r '.last_evidence_ms')
    [[ "$last_ev" -gt "$prev_ev" ]] \
      || { echo "    last_evidence_ms did not advance across fuzzy reconcile: $prev_ev -> $last_ev"; return 1; }
    prev_ev="$last_ev"
  done

  # Pane slot still owned by the same watch. No premature delivery.
  local live
  live=$(watch_get_live "$pane")
  assert_json_field "$live" .watch_id "$wid" || return 1
  assert_eq 0 "$(_deliver_call_count)" || return 1

  # Worker's real Stop hook fires after the long task. Fast-path idle
  # evidence must still resolve cleanly and deliver exactly once — on
  # the pre-fix tree this ping was dropped because the watch had
  # already been marked delivered by the spurious blocked:unknown.
  local resolve_seq cursor
  resolve_seq=$(seq_next "$pane")
  cursor=$(wc -c < "$tpath" | tr -d ' ')
  _set_now $((t0 + 30000 + 120000 + 90000))
  watch_feed_evidence --watch-id "$wid" --seq "$resolve_seq" \
    --candidate-state idle --transcript-cursor "$cursor" \
    --source fast >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1

  watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  assert_eq 1 "$(_deliver_call_count)" || return 1
}
run_test "fuzzy_blocked_unknown_with_advancing_cursor_is_liveness_proof" test_fuzzy_blocked_unknown_with_advancing_cursor_is_liveness_proof

# ----- pane close and restart recovery via service iterate (steez-si3.1) -----
#
# Acceptance #6 (spec: TDD relationship): "Restart recovery preserves the
# same watch_id and bounded delivery attempts." The on-disk store is the
# source of truth across crashes, and the daemon's ongoing tick loop
# (`_eventsd_service_iterate`) is also the restart-recovery path: on the
# first iteration after the daemon comes back up, any persisted draining
# record (resolved / delivering / delivery_failed) gets its scheduled
# transition and one delivery attempt on the same watch_id.
#
# Pending-on-restart and armed-one-pass recovery are out of scope here —
# they are covered by separate mechanisms (explicit `timeout-pending` for
# pending; degraded reconciliation in `watch_tick` for armed).

# Shared deliver mock: exit code is keyed on watch_id via EXIT_<key> env
# vars so tests do not depend on the order the iterator walks the
# on-disk store. One log line per invocation lets tests count attempts
# per watch.
_install_bead7_deliver_mock() {
  export DELIVER_LOG="$TEST_TMP/deliver.log"
  : > "$DELIVER_LOG"
  cat > "$MOCK_BIN/agent-deliver" <<'MOCK'
#!/usr/bin/env bash
wid="$1"
printf '%s\n' "$*" >> "${DELIVER_LOG:-/dev/null}"
key=$(printf '%s' "$wid" | tr -c 'a-zA-Z0-9' '_')
var="EXIT_${key}"
exit "${!var:-0}"
MOCK
  chmod +x "$MOCK_BIN/agent-deliver"
  export AGENT_DELIVER_CMD="$MOCK_BIN/agent-deliver"
}

# _stage_delivering <pane> <attempts_so_far>
# Arm a watch, resolve it, then overwrite the on-disk record to simulate
# the daemon crashing mid-delivery: state=delivering with a non-zero
# delivery_attempts count persisted. Prints the watch_id.
_stage_delivering() {
  local pane="$1" attempts="$2" wid rec
  wid=$(_arm_on "$pane") || return 1
  watch_resolve "$wid" "blocked:question" || return 1
  rec=$(watch_get "$wid" | jq -c \
    --argjson a "$attempts" \
    '.state = "delivering" | .delivery_attempts = $a')
  _eventsd_write_record "$wid" "$rec"
  printf '%s' "$wid"
}

# _stage_delivery_failed <pane> <attempts_so_far>
# Arm, resolve, then overwrite to delivery_failed with the given attempt
# count — simulates a watch that already burned <attempts> retries and
# sits in the retry-eligible state across a restart.
_stage_delivery_failed() {
  local pane="$1" attempts="$2" wid rec
  wid=$(_arm_on "$pane") || return 1
  watch_resolve "$wid" idle || return 1
  rec=$(watch_get "$wid" | jq -c \
    --argjson a "$attempts" \
    '.state = "delivery_failed" | .delivery_attempts = $a')
  _eventsd_write_record "$wid" "$rec"
  printf '%s' "$wid"
}

_exit_var_name() {
  local wid="$1" key
  key=$(printf '%s' "$wid" | tr -c 'a-zA-Z0-9' '_')
  printf 'EXIT_%s' "$key"
}

# _install_reconcile_mock "<pane>:<state>" ... installs an agent-state
# mock on PATH that returns the given state for each listed pane and
# exits 1 for every other pane. Used by pane-close tests that need to
# drive reconciliation to a chosen outcome without touching real
# tmux/transcript plumbing.
#
# When the env var RECONCILE_TPATH is set at call time, the mock emits
# `detail.transcript_path` alongside the state so pane-close freshness
# checks (real-cursor > prearm_cursor) can pass. Without the var, the
# mock only emits state — suitable for tests that want to exercise the
# stale-transcript fallback path.
_install_reconcile_mock() {
  local file="$MOCK_BIN/agent-state"
  local tpath="${RECONCILE_TPATH:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'pane="$1"\n'
    printf 'case "$pane" in\n'
    local arg p s body
    for arg in "$@"; do
      p="${arg%%:*}"; s="${arg#*:}"
      if [[ -n "$tpath" ]]; then
        body="{\"state\":\"$s\",\"detail\":{\"transcript_path\":\"$tpath\"}}"
      else
        body="{\"state\":\"$s\"}"
      fi
      printf '  %q) echo %q ; exit 0 ;;\n' "$p" "$body"
    done
    printf '  *) exit 1 ;;\n'
    printf 'esac\n'
  } > "$file"
  chmod +x "$file"
}

suite "service iterate restart recovery"

test_service_iterate_restart_replays_resolved_demotes_delivering_and_retries_delivery_failed_preserving_attempts() {
  # Spec (Pane close and restart):
  #   - "resolved is re-delivered with the same watch_id"
  #   - "delivering becomes delivery_failed and retries with the same watch_id"
  #   - "delivery_failed keeps its retry budget and retries with the same watch_id"
  # Spec (Delivery contract): "A watch may retry delivery only from
  # delivery_failed, or from restart recovery of resolved, and only until
  # MAX_DELIVERY_ATTEMPTS is exhausted."
  #
  # The daemon's ongoing tick (`_eventsd_service_iterate`) is also the
  # restart-recovery path for draining watches. Each of the three
  # draining states must transition and retry exactly once on the same
  # iteration, preserving the pre-crash retry budget.
  _install_bead7_deliver_mock

  # (1) resolved with zero prior attempts.
  local w_resolved w_delivering w_failed rec
  w_resolved=$(_arm_on "%90") || return 1
  watch_resolve "$w_resolved" idle || return 1

  # (2) delivering with 2 prior attempts already on disk — simulates the
  # daemon crashing after persisting delivering and before the cmd returned.
  w_delivering=$(_stage_delivering "%91" 2) || return 1

  # (3) delivery_failed with 3 prior attempts — a watch that was already
  # between retries when the daemon went down.
  w_failed=$(_stage_delivery_failed "%92" 3) || return 1

  # Per-watch exit codes:
  #   resolved   -> succeeds on its retry.
  #   delivering -> demoted to delivery_failed, retry fails.
  #   failed     -> succeeds on its retry.
  export "$(_exit_var_name "$w_resolved")=0"
  export "$(_exit_var_name "$w_delivering")=7"
  export "$(_exit_var_name "$w_failed")=0"

  # One iteration drives the full draining-recovery matrix.
  _eventsd_service_iterate || return 1

  # resolved: same watch_id, one new attempt, delivered.
  # Terminal state disposes the record on transition (steez-u7o7.1); the
  # deliver-log check below proves one call against the original watch_id,
  # which is the external signature of a successful delivered transition.
  assert_eq "" "$(watch_get "$w_resolved")" || return 1

  # delivering: demoted to delivery_failed, SAME watch_id, retry budget
  # preserved. The 2 pre-crash attempts + the 1 retry on this iteration = 3.
  rec=$(watch_get "$w_delivering")
  assert_json_field "$rec" .watch_id "$w_delivering" || return 1
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 3 || return 1

  # delivery_failed: retried with SAME watch_id, budget preserved.
  # 3 pre-crash + 1 retry (succeeded) = 4, within MAX_DELIVERY_ATTEMPTS=5.
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$w_failed")" || return 1

  # Exactly one attempt per staged watch_id on this iteration — no
  # cross-wiring, no duplicate retries. The test fixture accumulates
  # resolved watches from prior suites in the shared state dir, so
  # counting total deliver calls is meaningless; per-watch counts are
  # what the spec pins.
  local c
  c=$(grep -c "^$w_resolved " "$DELIVER_LOG" || true)
  assert_eq 1 "$c" || return 1
  c=$(grep -c "^$w_delivering " "$DELIVER_LOG" || true)
  assert_eq 1 "$c" || return 1
  c=$(grep -c "^$w_failed " "$DELIVER_LOG" || true)
  assert_eq 1 "$c" || return 1
}
run_test "service_iterate_restart_replays_resolved_demotes_delivering_and_retries_delivery_failed_preserving_attempts" test_service_iterate_restart_replays_resolved_demotes_delivering_and_retries_delivery_failed_preserving_attempts

suite "pane close recovery"

test_pane_close_on_pending_watch_closes_without_delivery() {
  # Spec (Pane close and restart): "a pending watch closes without
  # delivery." Pending never notifies regardless; pane close just ends
  # the turn early.
  _install_bead7_deliver_mock
  declare -F watch_pane_close >/dev/null \
    || { echo "    missing: watch_pane_close"; return 1; }
  local wid
  wid=$(_mk_pending "%130") || return 1
  watch_pane_close "%130" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1).
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "%130")" || return 1
  local c
  c=$(grep -c "^$wid " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 0 "${c:-0}" || return 1
}
run_test "pane_close_on_pending_watch_closes_without_delivery" test_pane_close_on_pending_watch_closes_without_delivery

test_pane_close_on_armed_watch_reconciles_once_and_falls_back_to_blocked_unknown() {
  # Spec (Pane close and restart): "an armed watch gets one final
  # reconciliation from transcript data still newer than the prearm
  # cursor ... if that final reconciliation does not prove a terminal
  # state, the watch resolves to blocked:unknown."
  #
  # Two armed watches are closed:
  #   (a) %140 reconciles to idle (terminal, != baseline=working) →
  #       resolves to idle, delivery drives with the same watch_id.
  #   (b) %141 reconciles to working (non-terminal) → resolves to
  #       blocked:unknown, delivery drives with the same watch_id.
  # Both deliver attempts go against spawner_pane (=%0), which is what
  # "draining delivery continues against the spawner pane" enforces:
  # even with the pane gone, the notification still routes to the
  # spawner.
  _install_bead7_deliver_mock
  # Stage a transcript newer than prearm_cursor (4096) so the pane-close
  # freshness gate accepts the reconciled terminal state. Without this,
  # cursor=0 (no transcript) fails `cursor > prearm_cursor` and the
  # terminal reconcile would be dropped — the test exercises the spec's
  # "terminal != baseline" path, which requires fresh transcript data.
  local tpath="$TEST_TMP/pane-close-armed.jsonl"
  head -c 5000 < /dev/zero > "$tpath"
  RECONCILE_TPATH="$tpath" _install_reconcile_mock "%140:idle" "%141:working"
  local w_term w_indef rec
  w_term=$(_arm_on "%140") || return 1
  w_indef=$(_arm_on "%141") || return 1
  export "$(_exit_var_name "$w_term")=0"
  export "$(_exit_var_name "$w_indef")=0"

  watch_pane_close "%140" || return 1
  watch_pane_close "%141" || return 1

  # Terminal state disposes the record on transition (steez-u7o7.1).
  # The resolved terminal flowed into the sticky attention record
  # written by watch_pane_close; observe it there instead of on the
  # vanished watch file.
  assert_eq "" "$(watch_get "$w_term")" || return 1
  assert_eq "" "$(watch_get "$w_indef")" || return 1
  local attn_term attn_indef
  attn_term=$(attention_get_recent "%140")
  assert_json_field "$attn_term" .state idle || return 1
  attn_indef=$(attention_get_recent "%141")
  assert_json_field "$attn_indef" .state "blocked:unknown" || return 1

  # Both delivery calls carried the second arg = spawner_pane (%0),
  # not the closed pane. "Draining delivery continues against the
  # spawner pane."
  local spawner_calls
  spawner_calls=$(awk '$2=="%0" {print $1}' "$DELIVER_LOG" | sort -u)
  assert_contains "$spawner_calls" "$w_term" || return 1
  assert_contains "$spawner_calls" "$w_indef" || return 1
  # Both panes' live slots are freed.
  assert_eq "" "$(watch_get_live "%140")" || return 1
  assert_eq "" "$(watch_get_live "%141")" || return 1
}
run_test "pane_close_on_armed_watch_reconciles_once_and_falls_back_to_blocked_unknown" test_pane_close_on_armed_watch_reconciles_once_and_falls_back_to_blocked_unknown

test_pane_close_leaves_draining_watches_untouched_and_delivery_continues_to_spawner() {
  # Spec (Pane close and restart): "draining delivery continues against
  # the spawner pane." A watch in delivery_failed must keep its state
  # and retry budget across the pane close, and a subsequent retry must
  # succeed against spawner_pane (agent-deliver arg 2).
  _install_bead7_deliver_mock
  local pane="%150" wid
  # Arm, resolve, fail one delivery → delivery_failed with attempts=1.
  wid=$(_arm_on "$pane") || return 1
  watch_resolve "$wid" idle || return 1
  export "$(_exit_var_name "$wid")=7"
  watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 1 || return 1
  assert_json_field "$rec" .spawner_pane "%0" || return 1

  # Pane close must not mutate the draining watch.
  watch_pane_close "$pane" || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 1 || return 1

  # Retry after pane close succeeds; delivery is routed to spawner.
  export "$(_exit_var_name "$wid")=0"
  watch_deliver_attempt "$wid" || return 1
  # Terminal state disposes the record on transition (steez-u7o7.1). The
  # deliver log below proves the retry used the same watch_id and the
  # call was routed to spawner_pane.
  assert_eq "" "$(watch_get "$wid")" || return 1
  # The final call's second arg = spawner_pane.
  local last_target
  last_target=$(awk -v w="$wid" '$1==w {target=$2} END{print target}' "$DELIVER_LOG")
  assert_eq "%0" "$last_target" || return 1
  # Exactly two deliver calls for this watch_id (one pre-close failure +
  # one post-close retry). Pins budget preservation observably.
  local attempts
  attempts=$(grep -c "^$wid " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 2 "${attempts:-0}" || return 1
}
run_test "pane_close_leaves_draining_watches_untouched_and_delivery_continues_to_spawner" test_pane_close_leaves_draining_watches_untouched_and_delivery_continues_to_spawner

# _install_detail_gated_agent_state_mock <transcript_path>
# Installs an agent-state mock that only emits `.detail.transcript_path`
# when `--detail` is on the argv. Without --detail the response omits
# the detail block entirely — the same contract agent-state has in
# production. Used by the prearm-cursor capture tests to prove the
# caller actually passes the flag.
_install_detail_gated_agent_state_mock() {
  local tpath="$1"
  export AGENT_STATE_LOG="$TEST_TMP/agent-state.log"
  export AGENT_STATE_TPATH="$tpath"
  : > "$AGENT_STATE_LOG"
  cat > "$MOCK_BIN/agent-state" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AGENT_STATE_LOG:-/dev/null}"
pane="$1"
detail_on=0
for arg in "$@"; do
  [[ "$arg" == "--detail" ]] && detail_on=1
done
if (( detail_on )) && [[ -n "${AGENT_STATE_TPATH:-}" ]]; then
  printf '{"pane":"%s","agent":"codex","state":"working","name":"t","detail":{"transcript_path":"%s"}}\n' \
    "$pane" "$AGENT_STATE_TPATH"
else
  printf '{"pane":"%s","agent":"codex","state":"working","name":"t"}\n' "$pane"
fi
MOCK
  chmod +x "$MOCK_BIN/agent-state"
  export AGENT_STATE_CMD="$MOCK_BIN/agent-state"
}

test_capture_transcript_cursor_passes_detail_flag_to_agent_state() {
  # Spec (steez-j815 + steez-si3.1): agent-state only emits
  # `.detail.transcript_path` when `--detail` is set. Omitting the flag
  # leaves the prearm cursor pinned at 0, which forever fails the
  # freshness gate `cursor > prearm_cursor` and renders every reconcile
  # on that pane stale. The prearm-time capture must pass `--detail`
  # for the same reason the reconcile path does.
  local pane="%180" tpath="$TEST_TMP/prearm-cursor.jsonl"
  head -c 2500 < /dev/zero > "$tpath"
  _install_detail_gated_agent_state_mock "$tpath"

  local sz
  sz=$(_eventsd_capture_transcript_cursor "$pane") || return 1
  assert_eq "2500" "$sz" || return 1
  # Prove the flag was on the wire — defence in depth against a future
  # caller that shadows the result through a different code path.
  grep -q -- '--detail' "$AGENT_STATE_LOG" \
    || { echo "    agent-state call missing --detail"; return 1; }
}
run_test "capture_transcript_cursor_passes_detail_flag_to_agent_state" test_capture_transcript_cursor_passes_detail_flag_to_agent_state

test_pane_close_rejects_stale_transcript_reconciliation_and_falls_back_to_blocked_unknown() {
  # Spec (Pane close and restart): "an armed watch gets one final
  # reconciliation from transcript data still newer than the prearm
  # cursor." A reconcile that reports a terminal state but whose
  # transcript has not advanced past prearm_cursor is stale (pre-turn
  # evidence) and must not carry its state into the resolution — the
  # watch falls back to blocked:unknown.
  _install_bead7_deliver_mock
  # Transcript pinned at exactly prearm_transcript_cursor (4096). The
  # freshness rule `cursor > prearm_cursor` must fail, so the reported
  # `idle` (terminal != baseline=working) is dropped on the floor.
  local tpath="$TEST_TMP/pane-close-stale.jsonl"
  head -c 4096 < /dev/zero > "$tpath"
  RECONCILE_TPATH="$tpath" _install_reconcile_mock "%145:idle"

  local wid rec
  wid=$(_arm_on "%145") || return 1
  export "$(_exit_var_name "$wid")=0"

  watch_pane_close "%145" || return 1

  # Terminal state disposes the record on transition (steez-u7o7.1).
  # The attention record captures the resolved state for inspection.
  assert_eq "" "$(watch_get "$wid")" || return 1
  local attn
  attn=$(attention_get_recent "%145")
  assert_json_field "$attn" .state "blocked:unknown" || return 1
  assert_eq "" "$(watch_get_live "%145")" || return 1
  # Delivery actually fired with this watch_id — pane-close on an armed
  # watch must drive delivery once the resolution lands.
  local calls
  calls=$(grep -c "^$wid " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 1 "${calls:-0}" || return 1
}
run_test "pane_close_rejects_stale_transcript_reconciliation_and_falls_back_to_blocked_unknown" test_pane_close_rejects_stale_transcript_reconciliation_and_falls_back_to_blocked_unknown

# ----- service iterate recovery (steez-si3.1) -----
#
# _eventsd_service_iterate is the ongoing daemon tick. It is also the
# restart-recovery path: on first iteration after a crash the on-disk
# records carry whatever state the crash left them in. A record in
# `delivering` means the daemon persisted the pre-invoke state but did
# not observe the reply — the retry budget was already incremented on
# disk. The iterator must demote to `delivery_failed` (same watch_id,
# attempts preserved) and retry on the same pass, not wait for manual
# intervention.
suite "service iterate recovery"

test_service_iterate_demotes_persisted_delivering_to_delivery_failed_and_retries_preserving_attempts() {
  # Spec (Pane close and restart): "delivering becomes delivery_failed
  # and retries with the same watch_id."
  # Spec (Delivery contract): "A watch may retry delivery only from
  # delivery_failed, or from restart recovery of resolved, and only
  # until MAX_DELIVERY_ATTEMPTS is exhausted."
  _install_bead7_deliver_mock

  local wid
  wid=$(_stage_delivering "%170" 2) || return 1
  # The retry fails (exit=7) so the watch is observably in
  # delivery_failed after the iteration, not `delivered` — proof that
  # the demotion was persisted before the retry ran.
  export "$(_exit_var_name "$wid")=7"

  _eventsd_service_iterate || return 1

  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .watch_id "$wid" || return 1
  assert_json_field "$rec" .state delivery_failed || return 1
  # 2 pre-crash attempts + 1 retry on this iteration = 3. Budget
  # preserved (MAX_DELIVERY_ATTEMPTS=5 in default config).
  assert_json_field "$rec" .delivery_attempts 3 || return 1

  # Exactly one retry for this watch_id — demotion must not fan out.
  local c
  c=$(grep -c "^$wid " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 1 "${c:-0}" || return 1
}
run_test "service_iterate_demotes_persisted_delivering_to_delivery_failed_and_retries_preserving_attempts" test_service_iterate_demotes_persisted_delivering_to_delivery_failed_and_retries_preserving_attempts

# ----- service iterate state routing under collapsed jq (steez-u7o7.2) -----
#
# The hot path used to fork three jq processes per record per tick (6N
# forks/sec at 2Hz, N=files). steez-u7o7.2 collapses that to one jq pass
# over the whole watch dir per tick. The collapse must preserve every
# observable behaviour the old per-file loop had: pending stays
# untouched (no case in the switch), delivering is demoted to
# delivery_failed and retried on the same iteration, resolved and
# delivery_failed each drive one delivery attempt, and a malformed
# record file in the watch dir is skipped without aborting the rest of
# the pass. A naive `jq -rs '.[]'` collapse would slurp every record
# into one array and a single parse error would short-circuit the whole
# tick — that is the specific regression this test guards against.

suite "service iterate state routing (steez-u7o7.2)"

test_service_iterate_routes_all_lifecycle_states_and_tolerates_corrupt_files() {
  _install_bead7_deliver_mock

  # pending — must look live so the dead-pane sweep (steez-z6ti) does
  # not route the watch through watch_pane_close before the tick reaches
  # the switch. With the pane registered and agent-state stubbed, the
  # pending branch falls through the hard-cap check (age 0 under the
  # 60s default) and the watch must still be pending after the iter.
  mock_pane "%180" "11080" "pending agent" "/tmp"
  local prior_agent_state_cmd="${AGENT_STATE_CMD:-}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/stub-agent-state-ok"
  chmod +x "$MOCK_BIN/stub-agent-state-ok"
  export AGENT_STATE_CMD="$MOCK_BIN/stub-agent-state-ok"
  local w_pending
  w_pending=$(_mk_pending "%180") || return 1

  # armed — needs to look live so the pane_has_live_agent gate does not
  # close the watch before reaching the case statement. mock_pane makes
  # `tmux display-message -t %181` succeed; the agent-state stub above
  # covers the inspector probe. With fresh last_evidence_ms seeded at
  # arm, watch_tick exits early under the silence-window check and the
  # watch must still be armed after the iter.
  mock_pane "%181" "11081" "armed agent" "/tmp"
  local w_armed
  w_armed=$(_arm_on "%181") || return 1

  # delivering with one prior attempt — must be demoted to
  # delivery_failed in place and retried; the retry fails so the
  # observable state is delivery_failed afterward.
  local w_delivering
  w_delivering=$(_stage_delivering "%182" 1) || return 1

  # resolved with zero prior attempts — must be delivered.
  local w_resolved
  w_resolved=$(_arm_on "%183") || return 1
  watch_resolve "$w_resolved" idle || return 1

  # delivery_failed with two prior attempts — must be retried, budget
  # preserved (2 + 1 = 3, under MAX_DELIVERY_ATTEMPTS=5).
  local w_failed
  w_failed=$(_stage_delivery_failed "%184" 2) || return 1

  export "$(_exit_var_name "$w_delivering")=7"
  export "$(_exit_var_name "$w_resolved")=0"
  export "$(_exit_var_name "$w_failed")=0"

  # Plant two corrupt artefacts in the watch dir alongside the real
  # records: a half-written record (parse error) and an empty file
  # (no JSON value). The per-file loop tolerated both via `|| continue`
  # on each per-record jq; the collapsed jq must too.
  local watch_dir="$_EVENTSD_STATE_DIR/watches"
  printf '{ "watch_id": "truncated' > "$watch_dir/zz_corrupt_truncated.json"
  : > "$watch_dir/zz_corrupt_empty.json"

  _eventsd_service_iterate || return 1

  local rec c

  # pending: untouched.
  rec=$(watch_get "$w_pending")
  assert_json_field "$rec" .state pending || return 1
  c=$(grep -c "^$w_pending " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 0 "${c:-0}" || return 1

  # armed: untouched (fresh evidence keeps watch_tick a no-op).
  rec=$(watch_get "$w_armed")
  assert_json_field "$rec" .state armed || return 1
  c=$(grep -c "^$w_armed " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 0 "${c:-0}" || return 1

  # delivering: demoted, one retry, attempts = 1 + 1 = 2.
  rec=$(watch_get "$w_delivering")
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 2 || return 1
  c=$(grep -c "^$w_delivering " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 1 "${c:-0}" || return 1

  # resolved: delivered (terminal — record disposed per steez-u7o7.1).
  # Observable: deliver fired exactly once for this watch_id.
  assert_eq "" "$(watch_get "$w_resolved")" || return 1
  c=$(grep -c "^$w_resolved " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 1 "${c:-0}" || return 1

  # delivery_failed: delivered (terminal — record disposed per steez-u7o7.1).
  # Observable: deliver fired exactly once on this iter (the retry).
  assert_eq "" "$(watch_get "$w_failed")" || return 1
  c=$(grep -c "^$w_failed " "$DELIVER_LOG" 2>/dev/null || true)
  assert_eq 1 "${c:-0}" || return 1

  rm -f "$watch_dir/zz_corrupt_truncated.json" "$watch_dir/zz_corrupt_empty.json"
  if [[ -n "$prior_agent_state_cmd" ]]; then
    export AGENT_STATE_CMD="$prior_agent_state_cmd"
  else
    unset AGENT_STATE_CMD
  fi
}
run_test "service_iterate_routes_all_lifecycle_states_and_tolerates_corrupt_files" \
  test_service_iterate_routes_all_lifecycle_states_and_tolerates_corrupt_files

# ----- pending-watch reaper (steez-z6ti) -----
#
# Spec (agent-events.md): the pending reaper splits on a dedicated
# liveness authority that distinguishes pane missing, recognized agent
# provably gone, and inspector flake. Age alone never closes a live
# pending — the only age-based close path is PREARM_HARD_CAP_MS, and
# it only fires while the pane is present and not provably dead.
#
# Contract covered below:
#   1. live pending below the hard cap stays pending (fresh record).
#   2. live pending well past the OLD 5s window stays pending AND
#      watch_arm still succeeds after.
#   3. pane gone before start closes pane_closed.
#   4. pane present + recognized agent provably gone closes pane_closed.
#   5. pane present + inspector flake stays pending AND arms later.
#   6. live pending past hard cap closes pending_timeout.
#   7. restart re-enters the same rules (multi-iterate equivalence):
#      live-pane pending stays pending, dead-pane pending closes
#      pane_closed, no pending_timeout for restart itself.
#   8. real concurrent close vs arm cannot resurrect the watch —
#      the per-watch lock serializes both and whichever runs second
#      re-reads state and bails.
#
# Tests observe the close reason by wrapping _eventsd_close so terminal
# disposal (steez-u7o7.1) does not erase the signal.

suite "pending-watch reaper (steez-z6ti)"

# _install_close_log snapshots _eventsd_close and wraps it so every call
# appends "<wid> <pane> <reason>" to $CLOSE_LOG. Tests run inside a
# command-substitution subshell (see run_test), so the override is
# scoped to the test body.
_install_close_log() {
  export CLOSE_LOG="$TEST_TMP/close-z6ti.log"
  : > "$CLOSE_LOG"
  if ! declare -F _eventsd_close_orig >/dev/null 2>&1; then
    eval "$(declare -f _eventsd_close | sed '1 s/^_eventsd_close/_eventsd_close_orig/')"
  fi
  _eventsd_close() {
    printf '%s %s %s\n' "$1" "$2" "$3" >> "${CLOSE_LOG:-/dev/null}"
    _eventsd_close_orig "$@"
  }
}

# _register_live_pane <pane> — pane is in mock tmux AND agent-state
# reports success. _eventsd_pending_pane_status returns "live".
_register_live_pane() {
  local pane="$1"
  mock_pane "$pane" "9999" "live pane" "/tmp"
  cat > "$MOCK_BIN/z6ti-agent-state-ok" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/z6ti-agent-state-ok"
  export AGENT_STATE_CMD="$MOCK_BIN/z6ti-agent-state-ok"
}

# _register_pane_with_agent_gone <pane> — pane is in mock tmux but
# agent-state emits the canonical "not a recognized AI agent" error.
# _eventsd_pending_pane_status returns "agent_gone" and the reaper
# must close the watch via pane_close semantics.
_register_pane_with_agent_gone() {
  local pane="$1"
  mock_pane "$pane" "9999" "agent-gone pane" "/tmp"
  cat > "$MOCK_BIN/z6ti-agent-state-gone" <<MOCK
#!/usr/bin/env bash
printf 'error: pane %s is not a recognized AI agent\n' "\${1:-}" >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/z6ti-agent-state-gone"
  export AGENT_STATE_CMD="$MOCK_BIN/z6ti-agent-state-gone"
}

# _register_pane_with_flaky_agent_state <pane> — pane is in mock tmux
# but agent-state fails with a transient error NOT matching the
# "not a recognized AI agent" signal. _eventsd_pending_pane_status
# must return "indeterminate" so the reaper keeps the watch pending.
_register_pane_with_flaky_agent_state() {
  local pane="$1"
  mock_pane "$pane" "9999" "flaky pane" "/tmp"
  cat > "$MOCK_BIN/z6ti-agent-state-flake" <<'MOCK'
#!/usr/bin/env bash
printf 'error: transient inspector failure\n' >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/z6ti-agent-state-flake"
  export AGENT_STATE_CMD="$MOCK_BIN/z6ti-agent-state-flake"
}

# _swap_agent_state_to_ok <pane> — flip a previously-flaky mock into
# healthy so a later watch_arm can complete once the inspector
# recovers. The pane must already be registered via mock_pane.
_swap_agent_state_to_ok() {
  cat > "$MOCK_BIN/z6ti-agent-state-ok" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/z6ti-agent-state-ok"
  export AGENT_STATE_CMD="$MOCK_BIN/z6ti-agent-state-ok"
}

test_service_iterate_leaves_live_pending_below_prearm_timeout_untouched() {
  # A freshly-created pending watch on a live pane stays pending — no
  # timer has tripped yet.
  _install_deliver_mock
  _register_live_pane "%z6ti-a"
  local wid file mtime_sec
  wid=$(_mk_pending "%z6ti-a") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 1000 ))
  _eventsd_service_iterate || return 1
  assert_json_field "$(watch_get "$wid")" .state pending || return 1
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_leaves_live_pending_below_prearm_timeout_untouched" \
  test_service_iterate_leaves_live_pending_below_prearm_timeout_untouched

test_service_iterate_leaves_live_pending_past_prearm_timeout_and_later_arms() {
  # Root regression (steez-z6ti): agent-send's prearm -> deliver -> start
  # sequence can hold a watch in pending across multi-second sync work.
  # The 5s age check alone must NOT reap a live-pending watch — the pane
  # is alive, watch.start is coming. Verifies both that the reaper
  # leaves the record alone AND that watch_arm still succeeds after the
  # long delay (the real-world path agent-send follows).
  _install_deliver_mock
  _install_close_log
  _register_live_pane "%z6ti-b"
  local wid file mtime_sec hits rec
  wid=$(_mk_pending "%z6ti-b") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  # 10s past mtime — long enough to reproduce the old age-only reap,
  # still far below PREARM_HARD_CAP_MS (60000).
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 10000 ))
  _eventsd_service_iterate || return 1
  assert_json_field "$(watch_get "$wid")" .state pending || return 1
  hits=$(grep -Fc "$wid" "$CLOSE_LOG" 2>/dev/null || true)
  assert_eq 0 "${hits:-0}" || return 1
  # Real-world path: after the gap, watch.start arrives and arms.
  watch_arm --pane "%z6ti-b" --watch-id "$wid" --start-seq 11 >/dev/null \
    || { echo "    watch_arm failed after long pending gap"; return 1; }
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .start_seq 11 || return 1
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_leaves_live_pending_past_prearm_timeout_and_later_arms" \
  test_service_iterate_leaves_live_pending_past_prearm_timeout_and_later_arms

test_service_iterate_closes_dead_pane_pending_via_pane_close() {
  # A pending watch whose pane has vanished must close via pane_close
  # semantics (close_reason=pane_closed), NOT pending_timeout.
  _install_deliver_mock
  _install_close_log
  # No pane registration — tmux display-message fails.
  local wid pane="%z6ti-c" file mtime_sec
  wid=$(_mk_pending "$pane") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 10000 ))
  _eventsd_service_iterate || return 1
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "$pane")" || return 1
  grep -Fq "$wid $pane pane_closed" "$CLOSE_LOG" || {
    echo "    expected pane_closed on dead-pane pending; close log:"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  if grep -Fq "$wid $pane pending_timeout" "$CLOSE_LOG"; then
    echo "    dead-pane pending closed as pending_timeout; must be pane_closed"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  fi
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_closes_dead_pane_pending_via_pane_close" \
  test_service_iterate_closes_dead_pane_pending_via_pane_close

test_service_iterate_closes_pane_present_agent_gone_via_pane_close() {
  # Pane still exists but the recognized agent is provably gone
  # (agent-state emits "not a recognized AI agent"). Closes via
  # pane_close — NOT pending_timeout — because age is not the signal
  # (steez-z6ti). This is the "live pane, dead worker" case.
  _install_deliver_mock
  _install_close_log
  _register_pane_with_agent_gone "%z6ti-f"
  local wid pane="%z6ti-f" file mtime_sec
  wid=$(_mk_pending "$pane") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  # 3s of age — well below the hard cap. The close must still fire via
  # the liveness authority, proving the path is not age-gated.
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 3000 ))
  _eventsd_service_iterate || return 1
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "$pane")" || return 1
  grep -Fq "$wid $pane pane_closed" "$CLOSE_LOG" || {
    echo "    expected pane_closed when agent provably gone; close log:"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  if grep -Fq "$wid $pane pending_timeout" "$CLOSE_LOG"; then
    echo "    agent-gone pending closed as pending_timeout; must be pane_closed"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  fi
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_closes_pane_present_agent_gone_via_pane_close" \
  test_service_iterate_closes_pane_present_agent_gone_via_pane_close

test_service_iterate_keeps_flaky_pending_alive_and_later_arms() {
  # Pane exists and agent-state is flaking (transient error that does
  # NOT match the "not a recognized AI agent" signal). The pending
  # reaper must stay hands-off: it cannot prove the agent gone, so the
  # watch stays pending. After the inspector recovers and watch.start
  # arrives, arming must succeed. This is the "stay pending when
  # indeterminate" contract from the bead.
  _install_deliver_mock
  _install_close_log
  _register_pane_with_flaky_agent_state "%z6ti-g"
  local wid pane="%z6ti-g" file mtime_sec hits rec
  wid=$(_mk_pending "$pane") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  # 10s of age — past the OLD 5s reaper but well below hard cap.
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 10000 ))
  _eventsd_service_iterate || return 1
  assert_json_field "$(watch_get "$wid")" .state pending || return 1
  hits=$(grep -Fc "$wid" "$CLOSE_LOG" 2>/dev/null || true)
  assert_eq 0 "${hits:-0}" || {
    echo "    close fired on flaky (indeterminate) pending; log:"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  # Inspector recovers; the real watch.start arrives and arms.
  _swap_agent_state_to_ok
  watch_arm --pane "$pane" --watch-id "$wid" --start-seq 17 >/dev/null \
    || { echo "    watch_arm failed after flaky inspector recovered"; return 1; }
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .start_seq 17 || return 1
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_keeps_flaky_pending_alive_and_later_arms" \
  test_service_iterate_keeps_flaky_pending_alive_and_later_arms

test_service_iterate_closes_live_pending_past_hard_cap_via_pending_timeout() {
  # A live pane past PREARM_HARD_CAP_MS is the only path that still
  # closes a pending watch as pending_timeout. Guards against a client
  # that called prearm but never followed up with watch.start.
  _install_deliver_mock
  _install_close_log
  _register_live_pane "%z6ti-d"
  local wid pane="%z6ti-d" file mtime_sec
  wid=$(_mk_pending "$pane") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  # 1s past default PREARM_HARD_CAP_MS (60000).
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 61000 ))
  _eventsd_service_iterate || return 1
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "$pane")" || return 1
  grep -Fq "$wid $pane pending_timeout" "$CLOSE_LOG" || {
    echo "    expected pending_timeout at hard cap; close log:"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_closes_live_pending_past_hard_cap_via_pending_timeout" \
  test_service_iterate_closes_live_pending_past_hard_cap_via_pending_timeout

test_service_iterate_hard_cap_boundary_holds_at_one_ms_before_and_fires_at_cap() {
  # Boundary: age < hard_cap stays pending; age == hard_cap closes.
  # Proves the comparison is >= and not > (or vice versa) so a future
  # off-by-one cannot quietly drift the timing.
  #
  # The anchor is the record's `pending_at_ms` (stamped at creation
  # from `_eventsd_now_ms`, which is ms-grade under real wall time).
  # We pin creation time via `EVENTSD_NOW_MS` so the boundary maths
  # is deterministic — the older `stat %m * 1000` anchor quantized
  # the real clock to whole seconds and masked any sub-second drift.
  _install_deliver_mock
  _install_close_log
  _register_live_pane "%z6ti-boundary"
  local wid pane="%z6ti-boundary" anchor_ms hits
  anchor_ms=1700000000500
  export EVENTSD_NOW_MS="$anchor_ms"
  wid=$(_mk_pending "$pane") || return 1
  # 1ms below cap — must stay pending.
  export EVENTSD_NOW_MS=$(( anchor_ms + 60000 - 1 ))
  _eventsd_service_iterate || return 1
  assert_json_field "$(watch_get "$wid")" .state pending || {
    echo "    watch closed 1ms below hard cap"
    return 1
  }
  hits=$(grep -Fc "$wid" "$CLOSE_LOG" 2>/dev/null || true)
  assert_eq 0 "${hits:-0}" || return 1
  # Exactly at cap — must close with pending_timeout.
  export EVENTSD_NOW_MS=$(( anchor_ms + 60000 ))
  _eventsd_service_iterate || return 1
  assert_eq "" "$(watch_get "$wid")" || return 1
  grep -Fq "$wid $pane pending_timeout" "$CLOSE_LOG" || {
    echo "    expected pending_timeout at exact cap; close log:"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_hard_cap_boundary_holds_at_one_ms_before_and_fires_at_cap" \
  test_service_iterate_hard_cap_boundary_holds_at_one_ms_before_and_fires_at_cap

test_restart_with_live_pending_below_hard_cap_keeps_watch_pending() {
  # Restart recovery contract (steez-z6ti): the daemon re-enters the
  # same pending rules on a restart tick; it does not invent a new
  # pending_timeout just because the service bounced. A live pane
  # with an unresolved pending watch below the hard cap must stay
  # pending across repeated iterations, and a following watch_arm
  # must still succeed.
  _install_deliver_mock
  _install_close_log
  _register_live_pane "%z6ti-restart-live"
  local wid pane="%z6ti-restart-live" file mtime_sec hits rec i
  wid=$(_mk_pending "$pane") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 7000 ))
  # Three iterate passes stand in for "daemon booted into a state
  # snapshot and ticked repeatedly after restart".
  for i in 1 2 3; do
    _eventsd_service_iterate || return 1
  done
  assert_json_field "$(watch_get "$wid")" .state pending || return 1
  hits=$(grep -Fc "$wid" "$CLOSE_LOG" 2>/dev/null || true)
  assert_eq 0 "${hits:-0}" || {
    echo "    close fired on live-pane pending across restart ticks"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  watch_arm --pane "$pane" --watch-id "$wid" --start-seq 21 >/dev/null \
    || { echo "    watch_arm failed after restart-style ticks"; return 1; }
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .start_seq 21 || return 1
  unset EVENTSD_NOW_MS
}
run_test "restart_with_live_pending_below_hard_cap_keeps_watch_pending" \
  test_restart_with_live_pending_below_hard_cap_keeps_watch_pending

test_restart_with_dead_pane_pending_closes_pane_closed_not_pending_timeout() {
  # Restart recovery contract (steez-z6ti): a dead pane at restart
  # must close the watch via pane_close, not as pending_timeout. Same
  # authority the live-path uses applies to restart-time — "restart
  # does not invent a new pending resolution rule."
  _install_deliver_mock
  _install_close_log
  # No pane registered — dead at restart.
  local wid pane="%z6ti-restart-dead" file mtime_sec
  wid=$(_mk_pending "$pane") || return 1
  file=$(_eventsd_watch_file "$wid")
  mtime_sec=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file")
  export EVENTSD_NOW_MS=$(( mtime_sec * 1000 + 2000 ))
  _eventsd_service_iterate || return 1
  assert_eq "" "$(watch_get "$wid")" || return 1
  grep -Fq "$wid $pane pane_closed" "$CLOSE_LOG" || {
    echo "    dead-pane restart did not close as pane_closed; log:"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  if grep -Fq "$wid $pane pending_timeout" "$CLOSE_LOG"; then
    echo "    restart invented a pending_timeout close for a dead pane"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  fi
  unset EVENTSD_NOW_MS
}
run_test "restart_with_dead_pane_pending_closes_pane_closed_not_pending_timeout" \
  test_restart_with_dead_pane_pending_closes_pane_closed_not_pending_timeout

test_concurrent_close_vs_arm_cannot_resurrect_watch_via_lock() {
  # Lock-protected race (steez-z6ti). The primary synchronization
  # primitive is a real per-watch advisory lock, not a CAS-like
  # existence check on the atomic rename. The test drives two
  # processes through the lock:
  #
  #   1. A background subshell acquires the per-watch lock,
  #      signals the foreground via a sync fifo, then blocks in
  #      the lock on a second fifo read. That simulates an
  #      in-flight pane_close / pending_timeout mid-critical-section.
  #   2. The foreground races with a watch_arm call in yet another
  #      subshell, which must block on the per-watch lock until the
  #      background releases.
  #   3. The background writes "release", then closes the record via
  #      _eventsd_close and releases the lock.
  #   4. The foreground's watch_arm then acquires the lock, re-reads
  #      state, sees the record is gone, and fails.
  #
  # End-state invariants: the record must be gone (close won), the
  # pane's live slot must be empty, and watch_arm must have exited
  # non-zero. If any of those are false, a stale arm resurrected a
  # closed watch.
  _install_deliver_mock
  _register_live_pane "%z6ti-race"
  local pane="%z6ti-race" wid
  wid=$(_mk_pending "$pane") || return 1

  local sync_fifo="$TEST_TMP/z6ti-race.sync"
  local release_fifo="$TEST_TMP/z6ti-race.release"
  local arm_rc_file="$TEST_TMP/z6ti-race.arm"
  local holder_rc_file="$TEST_TMP/z6ti-race.holder"
  rm -f "$sync_fifo" "$release_fifo" "$arm_rc_file" "$holder_rc_file"
  mkfifo "$sync_fifo"
  mkfifo "$release_fifo"

  # Helper: take the lock, signal "locked", wait for "release", then
  # close the record. Runs inside the locked critical section, so a
  # concurrent watch_arm attempt on the same wid must block on the
  # lock rather than racing us.
  _z6ti_race_holder() {
    local wid="$1" pane="$2" sync="$3" release="$4"
    _eventsd_with_watch_lock "$wid" \
      _z6ti_race_holder_body "$wid" "$pane" "$sync" "$release"
  }
  _z6ti_race_holder_body() {
    local wid="$1" pane="$2" sync="$3" release="$4"
    printf 'locked\n' > "$sync"
    local _msg
    read -r _msg < "$release"
    _eventsd_close "$wid" "$pane" "pane_closed" >/dev/null 2>&1 || true
  }

  (
    _z6ti_race_holder "$wid" "$pane" "$sync_fifo" "$release_fifo"
    printf '%s' "$?" > "$holder_rc_file"
  ) &
  local holder_pid=$!

  local msg=""
  read -r msg < "$sync_fifo"
  [[ "$msg" == "locked" ]] || {
    echo "    background holder failed to take the lock (msg='$msg')"
    kill -KILL "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    return 1
  }

  (
    watch_arm --pane "$pane" --watch-id "$wid" --start-seq 99 >/dev/null 2>&1
    printf '%s' "$?" > "$arm_rc_file"
  ) &
  local arm_pid=$!

  # Give the arm subshell time to enter _eventsd_with_watch_lock and
  # block. If the lock were not serializing us, arm would complete
  # first and arm_rc_file would show up.
  local i
  for i in $(seq 1 20); do
    [[ -f "$arm_rc_file" ]] && break
    /bin/sleep 0.05 2>/dev/null || sleep 1
  done
  [[ ! -f "$arm_rc_file" ]] || {
    echo "    watch_arm completed while background holder held the lock"
    printf 'release\n' > "$release_fifo"
    wait "$holder_pid" 2>/dev/null || true
    wait "$arm_pid" 2>/dev/null || true
    return 1
  }

  # Release the holder: it will close the record, release the lock,
  # then the blocked arm wakes, re-reads, and fails.
  printf 'release\n' > "$release_fifo"
  wait "$holder_pid" 2>/dev/null || true
  wait "$arm_pid" 2>/dev/null || true

  local arm_rc holder_rc
  arm_rc=$(cat "$arm_rc_file" 2>/dev/null || echo "missing")
  holder_rc=$(cat "$holder_rc_file" 2>/dev/null || echo "missing")
  [[ "$arm_rc" != "0" ]] || {
    echo "    watch_arm returned rc=0 after the record was closed (arm_rc=$arm_rc)"
    printf '    record=%s\n' "$(watch_get "$wid")"
    return 1
  }
  [[ "$holder_rc" == "0" ]] || {
    echo "    background holder exited non-zero (holder_rc=$holder_rc)"
    return 1
  }
  [[ -z "$(watch_get "$wid")" ]] || {
    echo "    stale arm resurrected a closed watch"
    printf '    record=%s\n' "$(watch_get "$wid")"
    return 1
  }
  assert_eq "" "$(watch_get_live "$pane")" || return 1
  [[ ! -e "$(_eventsd_buffer_file "$wid")" ]] || {
    echo "    pre-arm buffer lingered after race"
    return 1
  }
}
run_test "concurrent_close_vs_arm_cannot_resurrect_watch_via_lock" \
  test_concurrent_close_vs_arm_cannot_resurrect_watch_via_lock

test_concurrent_arm_vs_close_when_arm_wins_leaves_watch_armed() {
  # Symmetric case: when the arm wins the lock first, the armed
  # record lands, the live slot stays populated, and a following
  # same-wid close attempt no-ops (armed is not pending — the
  # locked body re-reads state and bails). This proves the lock
  # plus in-lock state-check is a true bidirectional serializer,
  # not a one-sided guard.
  _install_deliver_mock
  _register_live_pane "%z6ti-race-arm"
  local pane="%z6ti-race-arm" wid
  wid=$(_mk_pending "$pane") || return 1

  local sync_fifo="$TEST_TMP/z6ti-race-arm.sync"
  local release_fifo="$TEST_TMP/z6ti-race-arm.release"
  local close_rc_file="$TEST_TMP/z6ti-race-arm.close"
  rm -f "$sync_fifo" "$release_fifo" "$close_rc_file"
  mkfifo "$sync_fifo"
  mkfifo "$release_fifo"

  _z6ti_race_arm_holder() {
    local wid="$1" pane="$2" sync="$3" release="$4" start_seq="$5"
    _eventsd_with_watch_lock "$wid" \
      _z6ti_race_arm_holder_body "$wid" "$pane" "$sync" "$release" "$start_seq"
  }
  _z6ti_race_arm_holder_body() {
    local wid="$1" pane="$2" sync="$3" release="$4" start_seq="$5"
    # Inline the locked body — we already hold the lock and want to
    # hold it through the sync point before writing. This mirrors
    # what _eventsd_watch_arm_locked does but with the fifo rendez-vous
    # between state-read and state-write.
    printf 'locked\n' > "$sync"
    local _msg
    read -r _msg < "$release"
    _eventsd_watch_arm_locked "$pane" "$wid" "$start_seq"
  }

  (
    _z6ti_race_arm_holder "$wid" "$pane" "$sync_fifo" "$release_fifo" 42
  ) &
  local arm_pid=$!

  local msg=""
  read -r msg < "$sync_fifo"
  [[ "$msg" == "locked" ]] || {
    echo "    arm holder failed to take the lock (msg='$msg')"
    kill -KILL "$arm_pid" 2>/dev/null || true
    wait "$arm_pid" 2>/dev/null || true
    return 1
  }

  (
    watch_pending_timeout "$wid" >/dev/null 2>&1
    printf '%s' "$?" > "$close_rc_file"
  ) &
  local close_pid=$!

  # Confirm the close is blocked.
  local i
  for i in $(seq 1 20); do
    [[ -f "$close_rc_file" ]] && break
    /bin/sleep 0.05 2>/dev/null || sleep 1
  done
  [[ ! -f "$close_rc_file" ]] || {
    echo "    watch_pending_timeout ran while arm holder held the lock"
    printf 'release\n' > "$release_fifo"
    wait "$arm_pid" 2>/dev/null || true
    wait "$close_pid" 2>/dev/null || true
    return 1
  }

  printf 'release\n' > "$release_fifo"
  wait "$arm_pid" 2>/dev/null || true
  wait "$close_pid" 2>/dev/null || true

  local close_rc rec
  close_rc=$(cat "$close_rc_file" 2>/dev/null || echo "missing")
  [[ "$close_rc" != "0" ]] || {
    echo "    watch_pending_timeout succeeded on an already-armed watch"
    return 1
  }
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || {
    echo "    arm holder lost the race — record is not armed: $rec"
    return 1
  }
  assert_json_field "$rec" .start_seq 42 || return 1
  # Live slot must still point at this armed watch.
  local live_wid
  live_wid=$(printf '%s' "$(watch_get_live "$pane")" | jq -r .watch_id)
  assert_eq "$wid" "$live_wid" || return 1
}
run_test "concurrent_arm_vs_close_when_arm_wins_leaves_watch_armed" \
  test_concurrent_arm_vs_close_when_arm_wins_leaves_watch_armed

# ----- watch-lock hardening (steez-es21) -----
#
# The per-watch lock used by steez-z6ti needs four things proven:
#   1. Holder identity is durable from the moment the lock is held —
#      there is no observable state where "someone has the lock" but
#      "no one owns it", which is what pre-es21 shell-level check-rm
#      schemes could reach if a holder crashed mid-pid-write or if a
#      waiter TOCTOU-rm'd a freshly-acquired valid entry. The lock is
#      kernel-arbitrated via flock(2): the OFD's existence IS the
#      holder identity, atomic with acquisition and bound to the
#      acquirer's process lifetime.
#   2. The lock identity is per-subshell, not per-parent-shell $$.
#      The subshell-$$ ambiguity the verifier called out in the z6ti
#      tests is gone because the OFD is per-process; every bash
#      context that acquires gets its own kernel-tracked identity.
#      The test proves this functionally: a holder subshell killed
#      mid-critical-section must release the lock to the next caller,
#      which only works when identity dies with the acquirer.
#   3. A stale lock file left behind from an earlier run (file exists,
#      no one currently flock-holds it) is reclaimable immediately.
#      Under the pre-es21 mkdir+pid-file scheme, a leftover bare
#      lockdir trapped waiters for the full deadline.
#   4. Pending hard-cap decisions are anchored at ms precision (the
#      `pending_at_ms` field on the record, sampled from the daemon
#      clock at creation), not `stat %m * 1000` second truncation.
#   5. Concurrent `watch_create_pending` on the same pane is serialized
#      so two callers cannot both write a pending record and leave one
#      record orphaned from the pane's live slot.

suite "watch-lock hardening (steez-es21)"

# _es21_epoch_ms — wall-clock ms for deadline budgeting in tests.
# perl(1) is already an agent-eventsd dep (service flock supervisor).
_es21_epoch_ms() {
  perl -MTime::HiRes=time -e 'printf "%d", int(time() * 1000)'
}

test_lock_acquires_immediately_over_stale_pre_es21_artifact() {
  # Red against the pre-es21 impl: a lock entry left behind from an
  # earlier invocation (bare directory at the lockdir path, no live
  # holder) trapped waiters until EVENTSD_WATCH_LOCK_TIMEOUT_MS. The
  # pre-pid-write crash window in the mkdir + pid-file scheme could
  # publish exactly this state — `cat $lockdir/pid` returned empty,
  # `[[ -n "$owner" ]]` was false, the stale branch was skipped, and
  # the loop stalled for the full deadline.
  #
  # Green contract: a leftover artifact at the lock path is cleaned
  # up on first acquire and the lock is granted well inside a short
  # deadline. The flock-backed impl acquires on an unheld lock file
  # instantly; the only legacy cleanup required is dropping any
  # pre-es21 symlink/dir at the un-suffixed path.
  local wid="es21-stale-$BASHPID-$RANDOM"
  local legacy_path="$_EVENTSD_STATE_DIR/locks/w-$wid"
  mkdir -p "$_EVENTSD_STATE_DIR/locks"
  mkdir "$legacy_path" || return 1

  local t0 t1 elapsed_ms rc=0
  t0=$(_es21_epoch_ms)
  EVENTSD_WATCH_LOCK_TIMEOUT_MS=500 \
    _eventsd_with_watch_lock "$wid" true || rc=$?
  t1=$(_es21_epoch_ms)
  elapsed_ms=$(( t1 - t0 ))
  [[ "$rc" -eq 0 ]] || {
    echo "    _eventsd_with_watch_lock could not acquire over a stale artifact (rc=$rc, elapsed=${elapsed_ms}ms)"
    return 1
  }
  (( elapsed_ms < 400 )) || {
    echo "    acquisition took ${elapsed_ms}ms, expected well under the 500ms deadline"
    return 1
  }
  [[ ! -e "$legacy_path" ]] || {
    echo "    legacy artifact lingered at $legacy_path after acquire/release"
    return 1
  }
}
run_test "lock_acquires_immediately_over_stale_pre_es21_artifact" \
  test_lock_acquires_immediately_over_stale_pre_es21_artifact

test_lock_serializes_concurrent_callers_with_kernel_arbitration() {
  # Caveat 1 and 2 combined: while a holder subshell is alive, no
  # other caller can acquire. Unlike the pre-es21 check-then-rm
  # scheme — where a waiter's `readlink → kill -0 → rm` cycle could
  # TOCTOU-wipe a freshly-acquired valid lock and let two callers
  # both think they hold it — flock(2) acquisition is atomic under
  # the kernel's OFD table. Two callers cannot simultaneously hold
  # the same flock lock; the second blocks until the first releases.
  # No string "holder identity" is inspected by the waiter, so the
  # subshell-$$ ambiguity is structurally eliminated.
  local wid="es21-serialize-$BASHPID-$RANDOM"
  local sync_fifo="$TEST_TMP/es21-serialize-$BASHPID.sync"
  local release_fifo="$TEST_TMP/es21-serialize-$BASHPID.release"
  mkdir -p "$_EVENTSD_STATE_DIR/locks"
  rm -f "$sync_fifo" "$release_fifo"
  mkfifo "$sync_fifo"
  mkfifo "$release_fifo"

  (
    _eventsd_with_watch_lock "$wid" _es21_signal_and_wait "$sync_fifo" "$release_fifo"
  ) &
  local holder_pid=$!

  local msg=""
  read -r msg < "$sync_fifo"
  [[ "$msg" == "locked" ]] || {
    echo "    holder never signalled locked"
    kill -KILL "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    return 1
  }

  # Concurrent acquire must block until the short deadline.
  local t0 t1 elapsed_ms rc=0
  t0=$(_es21_epoch_ms)
  EVENTSD_WATCH_LOCK_TIMEOUT_MS=200 \
    _eventsd_with_watch_lock "$wid" true || rc=$?
  t1=$(_es21_epoch_ms)
  elapsed_ms=$(( t1 - t0 ))
  [[ "$rc" -ne 0 ]] || {
    echo "    concurrent acquire succeeded while holder was alive — lock did not serialize"
    printf 'release\n' > "$release_fifo"
    wait "$holder_pid" 2>/dev/null || true
    return 1
  }
  (( elapsed_ms >= 150 )) || {
    echo "    concurrent acquire returned in ${elapsed_ms}ms — expected to block through the 200ms deadline"
    printf 'release\n' > "$release_fifo"
    wait "$holder_pid" 2>/dev/null || true
    return 1
  }

  # Release holder; next acquire must succeed quickly.
  printf 'release\n' > "$release_fifo"
  wait "$holder_pid" 2>/dev/null || true

  t0=$(_es21_epoch_ms)
  EVENTSD_WATCH_LOCK_TIMEOUT_MS=500 \
    _eventsd_with_watch_lock "$wid" true || {
      echo "    acquire after normal release failed"
      return 1
    }
  t1=$(_es21_epoch_ms)
  elapsed_ms=$(( t1 - t0 ))
  (( elapsed_ms < 200 )) || {
    echo "    post-release acquire took ${elapsed_ms}ms — expected instant acquisition"
    return 1
  }
}
# Signal "locked" to the sync fifo, block on the release fifo. Called
# under the lock so the sync point happens after acquisition.
_es21_signal_and_wait() {
  local sync="$1" release="$2"
  printf 'locked\n' > "$sync"
  local _msg
  read -r _msg < "$release"
}
run_test "lock_serializes_concurrent_callers_with_kernel_arbitration" \
  test_lock_serializes_concurrent_callers_with_kernel_arbitration

test_lock_holder_killed_mid_section_is_reclaimed_by_new_caller() {
  # Caveat 2 from the acquirer side: a holder that dies mid-critical-
  # section must release the lock to the next caller. Under flock(2)
  # this is automatic — the kernel drops the OFD refcount when the
  # last referencing process exits, which releases the lock. Under
  # the pre-es21 impl, the lock stored $$ (the parent shell's PID)
  # and the parent stayed alive, so `kill -0 $$` succeeded on every
  # waiter's stale check and the next caller stalled for the full
  # deadline.
  #
  # Scenic-regression trap 1: helpers.sh installs a mocked `sleep` on
  # $PATH that exits instantly. A previous revision held the lock via
  # `exec sleep 30`, which picked up the mock, exited on its own, and
  # released the lock through normal OFD close — not SIGKILL. Fix:
  # `_es21_hold_exec_sleep` invokes `/bin/sleep 30` by absolute path.
  #
  # Scenic-regression trap 2: the PID of the lock-holding process is
  # NOT $! of the outer `(...) &` wrapper. `_eventsd_with_watch_lock`
  # opens fd 9 inside its own inner subshell; when that inner subshell
  # execs `/bin/sleep`, sleep inherits fd 9 and becomes the OFD holder,
  # and its PID is the inner subshell's BASHPID — which the outer
  # wrapper never sees. Killing only the outer wrapper leaves sleep
  # alive and the lock held. Fix: the holder prints its BASHPID over
  # the sync fifo before it execs; the test targets that PID for
  # SIGKILL. A pre-SIGKILL sanity probe then proves the holder really
  # was holding the lock; a post-SIGKILL sanity probe proves sleep is
  # actually dead (kills were delivered to the right PID).
  local wid="es21-kill-$BASHPID-$RANDOM"
  local sync_fifo="$TEST_TMP/es21-kill-$BASHPID.sync"
  mkdir -p "$_EVENTSD_STATE_DIR/locks"
  rm -f "$sync_fifo"
  mkfifo "$sync_fifo"

  (
    _eventsd_with_watch_lock "$wid" _es21_hold_exec_sleep "$sync_fifo"
  ) &
  local wrapper_pid=$!

  local msg="" reported_pid=""
  read -r msg reported_pid < "$sync_fifo" || true
  [[ "$msg" == "locked" ]] || {
    echo "    holder never signalled locked (msg='$msg')"
    kill -KILL "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
    return 1
  }
  [[ "$reported_pid" =~ ^[0-9]+$ ]] || {
    echo "    holder did not report a numeric BASHPID over the fifo: '$reported_pid'"
    kill -KILL "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
    return 1
  }
  local holder_pid="$reported_pid"

  # Sanity probe: the holder must truly be holding the lock. A short
  # deadline must expire without acquisition. If this probe succeeds,
  # the blocker exited normally (e.g. PATH-mocked `sleep`) and any
  # subsequent SIGKILL result is meaningless.
  local probe_t0 probe_t1 probe_elapsed_ms probe_rc=0
  probe_t0=$(_es21_epoch_ms)
  EVENTSD_WATCH_LOCK_TIMEOUT_MS=200 \
    _eventsd_with_watch_lock "$wid" true 2>/dev/null || probe_rc=$?
  probe_t1=$(_es21_epoch_ms)
  probe_elapsed_ms=$(( probe_t1 - probe_t0 ))
  [[ "$probe_rc" -ne 0 ]] || {
    echo "    pre-SIGKILL probe acquired lock in ${probe_elapsed_ms}ms — holder never actually blocked."
    echo "    the SIGKILL reclamation claim is scenic; the blocker in _es21_hold_exec_sleep"
    echo "    must be a non-mocked blocking primitive (e.g. /bin/sleep)."
    kill -KILL "$holder_pid" "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
    return 1
  }
  (( probe_elapsed_ms >= 150 )) || {
    echo "    pre-SIGKILL probe returned rc=$probe_rc in ${probe_elapsed_ms}ms — expected to block through the 200ms deadline"
    kill -KILL "$holder_pid" "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
    return 1
  }

  # Confirm the holder we targeted is actually `/bin/sleep` (not the
  # outer `(...)&` wrapper whose $! the test might have mistakenly
  # targeted). If this check is wrong, SIGKILL below may leave sleep
  # running and the lock held — and the scenic win would look like a
  # green test again.
  local holder_cmd
  holder_cmd=$(ps -p "$holder_pid" -o comm= 2>/dev/null | tr -d ' ')
  [[ "$holder_cmd" == *sleep* ]] || {
    echo "    holder pid $holder_pid is not sleep (comm='$holder_cmd') — kill target drifted"
    kill -KILL "$holder_pid" "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
    return 1
  }

  # SIGKILL the sleep process (the OFD holder). The kernel drops the
  # last fd reference to the flock OFD, and the lock releases — no
  # shell-level release path runs. The outer `(...)&` wrapper noticed
  # its child exit status and returns too; wait on it to reap.
  kill -KILL "$holder_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true

  # Prove sleep is dead — otherwise a subsequent acquire success could
  # be a false positive from a different release path.
  kill -0 "$holder_pid" 2>/dev/null && {
    echo "    holder pid $holder_pid still alive after SIGKILL+wait"
    kill -KILL "$holder_pid" 2>/dev/null || true
    return 1
  }

  local t0 t1 elapsed_ms rc=0
  t0=$(_es21_epoch_ms)
  EVENTSD_WATCH_LOCK_TIMEOUT_MS=500 \
    _eventsd_with_watch_lock "$wid" true || rc=$?
  t1=$(_es21_epoch_ms)
  elapsed_ms=$(( t1 - t0 ))
  [[ "$rc" -eq 0 ]] || {
    echo "    lock not released after holder SIGKILL (rc=$rc, elapsed=${elapsed_ms}ms)"
    return 1
  }
  (( elapsed_ms < 400 )) || {
    echo "    lock release after holder SIGKILL took ${elapsed_ms}ms — expected instant release from OFD close"
    return 1
  }
}
# Report BASHPID (this function's calling shell — i.e. `_eventsd_with_
# watch_lock`'s inner subshell that opened fd 9) over the sync fifo,
# then exec /bin/sleep. /bin/sleep (absolute path) bypasses the PATH
# sleep mock installed by helpers.sh. After exec, sleep owns that
# subshell's PID AND inherits fd 9 — so sleep is the real OFD holder
# of the flock, and SIGKILL on the BASHPID reported here is the only
# path that drops the last OFD reference.
_es21_hold_exec_sleep() {
  local sync="$1"
  printf 'locked %s\n' "$BASHPID" > "$sync"
  exec /bin/sleep 30
}
run_test "lock_holder_killed_mid_section_is_reclaimed_by_new_caller" \
  test_lock_holder_killed_mid_section_is_reclaimed_by_new_caller

# ----- pending hard-cap ms precision (steez-es21) -----

suite "pending hard-cap ms precision (steez-es21)"

test_eventsd_now_ms_real_clock_is_millisecond_grade() {
  # Production `_eventsd_now_ms` must return a millisecond-grade wall
  # clock when EVENTSD_NOW_MS is unset. A prior impl returned
  # `$(date +%s) * 1000`, which is second-quantized — every reading
  # ends in `000`. The spec declares the pending_at_ms anchor must be
  # ms-grade; a second-quantized clock silently narrows that contract.
  #
  # Probe: 40 rapid reads with a ~2ms perl sleep between. If the impl
  # is second-quantized, every reading's `mod 1000` is 0. Even one
  # non-zero mod proves ms precision.
  unset EVENTSD_NOW_MS
  local i reading suffix seen_nonzero_suffix=0
  for i in $(seq 1 40); do
    reading=$(_eventsd_now_ms)
    [[ "$reading" =~ ^[0-9]+$ ]] || {
      echo "    _eventsd_now_ms did not return an integer: '$reading'"
      return 1
    }
    suffix=$(( reading % 1000 ))
    if (( suffix != 0 )); then
      seen_nonzero_suffix=1
      break
    fi
    perl -MTime::HiRes=sleep -e 'sleep(0.002)' 2>/dev/null || true
  done
  (( seen_nonzero_suffix == 1 )) || {
    echo "    _eventsd_now_ms produced only second-quantized readings over 40 probes"
    echo "    impl is not ms-grade — pending_at_ms spec claim is drifted"
    return 1
  }
}
run_test "eventsd_now_ms real-clock path is millisecond-grade" \
  test_eventsd_now_ms_real_clock_is_millisecond_grade

test_create_pending_records_sub_second_pending_at_ms_from_clock() {
  # The pending reaper needs a millisecond-grade age anchor. The old
  # anchor was `stat %m * 1000` on the record file — seconds-only,
  # which made a sub-second boundary test impossible to distinguish
  # from noise. The es21 impl stamps `pending_at_ms` on the record at
  # creation time, sourced from `_eventsd_now_ms` (which honors the
  # `EVENTSD_NOW_MS` test override). This test asserts the field
  # captures the sub-second digits from the override exactly.
  local sentinel_ms=1234567890123
  local wid rec stored_ms
  export EVENTSD_NOW_MS="$sentinel_ms"
  wid=$(_mk_pending "%es21-hardcap-anchor") || return 1
  unset EVENTSD_NOW_MS
  rec=$(watch_get "$wid")
  [[ -n "$rec" ]] || { echo "    pending record missing"; return 1; }
  stored_ms=$(printf '%s' "$rec" | jq -r '.pending_at_ms // empty')
  [[ "$stored_ms" == "$sentinel_ms" ]] || {
    echo "    pending_at_ms was $stored_ms, expected $sentinel_ms (sub-second digits must round-trip)"
    return 1
  }
}
run_test "create_pending_records_sub_second_pending_at_ms_from_clock" \
  test_create_pending_records_sub_second_pending_at_ms_from_clock

test_service_iterate_hard_cap_boundary_at_single_ms_precision() {
  # Proves the hard cap fires at ms precision by pinning the pending
  # record's creation clock to a sub-second-odd value, then advancing
  # EVENTSD_NOW_MS by (cap-1) and cap ms. The 60000 - 1 ms offset
  # is literally unrepresentable with a `stat %m * 1000` anchor, so
  # this test red-fails the pre-es21 impl no matter which direction
  # truncation drifts.
  _install_deliver_mock
  _install_close_log
  # Register the pane as live so the liveness authority does not
  # short-circuit on dead_pane / agent_gone. The hard cap is the only
  # path we care about here.
  _register_live_pane "%es21-hardcap-boundary"
  local wid pane="%es21-hardcap-boundary" stored_ms hits
  export EVENTSD_NOW_MS=1700000000999
  wid=$(_mk_pending "$pane") || return 1
  stored_ms=$(watch_get "$wid" | jq -r '.pending_at_ms // empty')
  [[ "$stored_ms" == "1700000000999" ]] || {
    echo "    pending_at_ms did not capture sub-second ms anchor: $stored_ms"
    return 1
  }

  # 1ms under hard cap — watch stays pending, no close log entry.
  export EVENTSD_NOW_MS=$(( 1700000000999 + 60000 - 1 ))
  _eventsd_service_iterate || return 1
  assert_json_field "$(watch_get "$wid")" .state pending || {
    echo "    watch closed 1ms below the hard cap — sub-ms anchor not honored"
    return 1
  }
  hits=$(grep -Fc "$wid" "$CLOSE_LOG" 2>/dev/null || true)
  assert_eq 0 "${hits:-0}" || return 1

  # Exactly at cap — watch closes with pending_timeout.
  export EVENTSD_NOW_MS=$(( 1700000000999 + 60000 ))
  _eventsd_service_iterate || return 1
  assert_eq "" "$(watch_get "$wid")" || return 1
  grep -Fq "$wid $pane pending_timeout" "$CLOSE_LOG" || {
    echo "    expected pending_timeout at exact ms cap; close log:"
    sed 's/^/      /' "$CLOSE_LOG"
    return 1
  }
  unset EVENTSD_NOW_MS
}
run_test "service_iterate_hard_cap_boundary_at_single_ms_precision" \
  test_service_iterate_hard_cap_boundary_at_single_ms_precision

# ----- concurrent prearm serialization (steez-es21) -----

suite "concurrent prearm serialization (steez-es21)"

test_concurrent_watch_create_pending_on_same_pane_leaves_one_live_no_orphans() {
  # Two concurrent watch_create_pending calls on the same pane must not
  # orphan a record. Under the pre-es21 impl, both callers read the
  # empty live_file before either wrote it, both skipped the supersede
  # close, both wrote their record, and both wrote to live_file (last
  # writer wins). That left one pending record not reachable from the
  # pane's live slot — the orphan.
  #
  # The es21 impl serializes the supersede-read + record-write + live-
  # file-write critical section under a per-pane lock, so whichever
  # caller wins the lock runs its full prearm before the next one
  # enters. The next caller sees the winner's live slot and supersedes
  # it normally — no orphan.
  _install_deliver_mock
  local pane="%es21-prearm-race"
  local N=10
  local release="$TEST_TMP/es21-prearm.release"
  local out_dir="$TEST_TMP/es21-prearm-out"
  rm -rf "$release" "$out_dir"
  mkdir -p "$out_dir"

  local i
  local pids=()
  for i in $(seq 1 "$N"); do
    (
      # Spin-wait with a short sleep so the workers all release near-
      # simultaneously. Each iteration of the wait is ~5ms, which
      # compresses the race window to within a few ms of each other.
      while [[ ! -e "$release" ]]; do
        /bin/sleep 0.005 2>/dev/null || sleep 1
      done
      watch_create_pending \
        --pane "$pane" \
        --spawner "%0" \
        --label codex \
        --baseline-state working \
        --prearm-screen-hash "hash-$i" \
        --prearm-transcript-cursor "$i" \
        --prearm-seq "$i" > "$out_dir/$i.wid" 2>&1
    ) &
    pids+=($!)
  done
  # Release all workers at once.
  : > "$release"
  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  # Invariant 1: at most one pending record survives on this pane.
  local pending_count
  pending_count=$(find "$_EVENTSD_STATE_DIR/watches" -name '*.json' -print 2>/dev/null \
    | while read -r f; do cat "$f"; done \
    | jq -r --arg p "$pane" 'select(.pane_id == $p and .state == "pending") | .watch_id' \
    | wc -l | tr -d ' ')
  [[ "$pending_count" -le 1 ]] || {
    echo "    $pending_count pending records on $pane after $N concurrent prearms — prearm orphaned records"
    find "$_EVENTSD_STATE_DIR/watches" -name '*.json' -print 2>/dev/null \
      | while read -r f; do
        printf '    %s\n' "$f"
        cat "$f" | jq -c '.' 2>/dev/null | sed 's/^/      /' || true
      done
    return 1
  }

  # Invariant 2: the pane's live slot points at the surviving pending
  # record — no orphan detached from live.
  local live_wid live_rec live_state
  live_wid=$(cat "$(_eventsd_live_file "$pane")" 2>/dev/null || true)
  [[ -n "$live_wid" ]] || {
    echo "    pane live slot empty after $N concurrent prearms"
    return 1
  }
  live_rec=$(watch_get "$live_wid")
  [[ -n "$live_rec" ]] || {
    echo "    pane live_file points at $live_wid but no record exists"
    return 1
  }
  live_state=$(printf '%s' "$live_rec" | jq -r '.state // empty')
  [[ "$live_state" == "pending" ]] || {
    echo "    live slot points at non-pending record (state=$live_state)"
    return 1
  }

  # Invariant 3: every other wid that the workers produced must be
  # terminally disposed (closed via supersede, unlinked by steez-u7o7.1).
  # Any wid that is still on disk that is not the live one is an
  # orphan.
  local wid_file produced
  for wid_file in "$out_dir"/*.wid; do
    [[ -s "$wid_file" ]] || continue
    produced=$(cat "$wid_file" | tr -d '[:space:]')
    [[ -n "$produced" ]] || continue
    [[ "$produced" == "$live_wid" ]] && continue
    if [[ -f "$(_eventsd_watch_file "$produced")" ]]; then
      echo "    wid $produced still on disk but detached from live slot ($live_wid) — orphan"
      cat "$(_eventsd_watch_file "$produced")" | sed 's/^/      /'
      return 1
    fi
  done
}
run_test "concurrent_watch_create_pending_on_same_pane_leaves_one_live_no_orphans" \
  test_concurrent_watch_create_pending_on_same_pane_leaves_one_live_no_orphans

# ----- recent attention evidence (S3) -----

suite "recent attention evidence"

test_resolve_persists_recent_attention_evidence() {
  local pane="%160" transcript="$TEST_TMP/attention.jsonl"
  mock_pane "$pane" "1601" "Attention test" "/tmp/attention"
  set_mock_tmux_var "$pane" "@session_id" "sess-attn"
  set_mock_tmux_var "$pane" "@transcript_path" "$transcript"
  cat > "$transcript" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"git push"}}]}}
JSONL

  export EVENTSD_NOW_MS=4242
  local wid rec attn
  wid=$(_arm_on "$pane") || return 1
  watch_feed_evidence \
    --watch-id "$wid" \
    --seq 8 \
    --candidate-state "blocked:permission" \
    --transcript-cursor 5000 \
    --screen-hash "fresh-$pane" >/dev/null || return 1

  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  attn=$(attention_get_recent "$pane") || return 1
  assert_json_field "$attn" .pane_id "$pane" || return 1
  assert_json_field "$attn" .state "blocked:permission" || return 1
  assert_json_field "$attn" .summary "waiting for permission approval" || return 1
  assert_json_field "$attn" .source "eventsd" || return 1
  assert_json_field "$attn" .session_id "sess-attn" || return 1
  assert_json_field "$attn" .transcript_path "$transcript" || return 1
  assert_json_field "$attn" .transcript_cursor 5000 || return 1
  assert_json_field "$attn" .observed_at_ms 4242 || return 1
}
run_test "resolve persists recent terminal reason for the pane" test_resolve_persists_recent_attention_evidence

# ----- atomic writes (U1) -----
#
# seq, attention, and watch record writes must be temp+rename so a
# racing reader never sees a truncated/empty file and a crash between
# stage and rename leaves the prior value intact. Evidence buffer and
# draining-ledger writes stay append-only.

suite "atomic writes (U1)"

_u1_inode() {
  # macOS stat vs Linux stat.
  stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1" 2>/dev/null
}

test_atomic_writer_never_yields_partial() {
  # 200 rewrites on the same watch_id: every read parses cleanly and
  # every write produces a fresh inode (temp+rename). Direct truncate
  # fails the inode check on iteration 2.
  declare -F _eventsd_write_record _eventsd_watch_file >/dev/null \
    || { echo "    missing atomic-writer surface"; return 1; }
  local wid="u1-write-record" file i prev_inode="" cur_inode rec parsed
  mkdir -p "$_EVENTSD_STATE_DIR/watches"
  file=$(_eventsd_watch_file "$wid")
  for i in $(seq 1 200); do
    rec=$(jq -cn --argjson i "$i" '{watch_id:"u1-write-record",state:"pending",seq:$i}')
    _eventsd_write_record "$wid" "$rec" || { echo "    write $i failed"; return 1; }
    parsed=$(jq -r .seq < "$file" 2>/dev/null) || { echo "    parse failed at iter $i"; return 1; }
    assert_eq "$i" "$parsed" || return 1
    cur_inode=$(_u1_inode "$file")
    [[ -n "$cur_inode" ]] || { echo "    could not stat $file at iter $i"; return 1; }
    if [[ -n "$prev_inode" ]]; then
      [[ "$prev_inode" != "$cur_inode" ]] || {
        echo "    inode unchanged between writes (iter $i): $cur_inode"
        echo "    _eventsd_write_record must use temp+rename (U1)"
        return 1
      }
    fi
    prev_inode="$cur_inode"
  done
}
run_test "atomic writer never yields partial and rotates inode per write" test_atomic_writer_never_yields_partial

test_attention_record_uses_rename() {
  # 50× rapid _eventsd_record_attention: each call must replace the
  # file via rename (distinct inode) and yield parseable JSON.
  declare -F _eventsd_record_attention _eventsd_attention_file >/dev/null \
    || { echo "    missing attention-writer surface"; return 1; }
  local pane="%u1att" file i prev_inode="" cur_inode parsed
  file=$(_eventsd_attention_file "$pane")
  for i in $(seq 1 50); do
    EVENTSD_NOW_MS=$((1000 + i)) _eventsd_record_attention "$pane" "blocked:permission" \
      || { echo "    record $i failed"; return 1; }
    parsed=$(jq -r .observed_at_ms < "$file" 2>/dev/null) \
      || { echo "    parse failed at iter $i"; return 1; }
    assert_eq "$((1000 + i))" "$parsed" || return 1
    cur_inode=$(_u1_inode "$file")
    [[ -n "$cur_inode" ]] || { echo "    could not stat $file at iter $i"; return 1; }
    if [[ -n "$prev_inode" ]]; then
      [[ "$prev_inode" != "$cur_inode" ]] || {
        echo "    inode unchanged between writes (iter $i): $cur_inode"
        echo "    _eventsd_record_attention must use temp+rename (U1)"
        return 1
      }
    fi
    prev_inode="$cur_inode"
  done
}
run_test "attention record uses rename (inode rotates per write)" test_attention_record_uses_rename

test_seq_next_atomic_under_sigkill() {
  # Simulate SIGKILL between stage and rename: the seq file must still
  # read the previous value, never empty/corrupt. The test drives this
  # through a post-stage hook function that self-kills the subshell
  # before the rename can run. Direct printf > file has no stage step,
  # so the file writes "2" directly and the assertion fails.
  declare -F seq_next _eventsd_pane_key >/dev/null \
    || { echo "    missing seq surface"; return 1; }
  local pane="%u1sig" file first killed_val
  mkdir -p "$_EVENTSD_STATE_DIR/seq"
  first=$(seq_next "$pane") || return 1
  assert_eq 1 "$first" || return 1
  file="$_EVENTSD_STATE_DIR/seq/$(_eventsd_pane_key "$pane")"
  [[ -f "$file" ]] || { echo "    seq file missing after first write"; return 1; }
  (
    _eventsd_test_hook_post_stage() { kill -KILL "$BASHPID"; }
    seq_next "$pane" >/dev/null 2>&1
  ) &
  wait "$!" 2>/dev/null || true
  killed_val=$(cat "$file" 2>/dev/null || true)
  assert_eq 1 "$killed_val" || return 1
}
run_test "seq_next atomic under SIGKILL between stage and rename" test_seq_next_atomic_under_sigkill

test_append_callsites_still_append() {
  # Guard against accidental conversion of append-only writers to
  # truncate+rename during U1. Two calls must leave two lines.
  declare -F _eventsd_buffer_evidence _eventsd_add_draining \
    _eventsd_buffer_file _eventsd_draining_file >/dev/null \
    || { echo "    missing append surface"; return 1; }
  local wid="u1-append-wid" pane="%u1append" buf_file drain_file lines
  _eventsd_buffer_evidence "$wid" 1 "working" 0 "" 0 "" || return 1
  _eventsd_buffer_evidence "$wid" 2 "working" 0 "" 0 "" || return 1
  buf_file=$(_eventsd_buffer_file "$wid")
  lines=$(wc -l < "$buf_file" | tr -d ' ')
  assert_eq 2 "$lines" || return 1
  _eventsd_add_draining "$pane" "wid-a" || return 1
  _eventsd_add_draining "$pane" "wid-b" || return 1
  drain_file=$(_eventsd_draining_file "$pane")
  lines=$(wc -l < "$drain_file" | tr -d ' ')
  assert_eq 2 "$lines" || return 1
}
run_test "append callsites still append (buffer, draining)" test_append_callsites_still_append

# ----- explicit attention semantics and inline sink publication (U2) -----
#
# watch_resolve is a pure state transition. Attention writes belong to
# the canonical producer — the fast-evidence terminal branch — and carry
# a transcript_cursor for freshness inspection. Attention records are
# one-shot: turn.prearm, pane-close, and working evidence all unlink the
# per-pane attention file. Every set/clear also publishes to two inline
# sinks so downstream consumers stay event-driven:
#   - tmux window option @agent_monitor_attention (set to state, -u to clear)
#   - sketchybar --trigger agent_attention_changed
# Both sinks are best-effort; missing tools must not block the producer.

suite "explicit attention semantics (U2)"

# Swap the no-op sketchybar for a logging one and expose a fresh tmux log.
# Each test that asserts on the wire re-calls this to clear prior entries.
_u2_install_sink_mocks() {
  export MOCK_TMUX_LOG="$TEST_TMP/u2-tmux.log"
  : > "$MOCK_TMUX_LOG"
  export SKETCHYBAR_LOG="$TEST_TMP/u2-sketchybar.log"
  : > "$SKETCHYBAR_LOG"
  cat > "$MOCK_BIN/sketchybar" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SKETCHYBAR_LOG:-/dev/null}"
exit 0
MOCK
  chmod +x "$MOCK_BIN/sketchybar"
}

test_watch_resolve_does_not_write_attention_implicitly() {
  # watch_resolve is a state transition. The attention record is owned
  # by the canonical fast-evidence terminal branch (the caller that knows
  # the transcript cursor). A direct watch_resolve with no surrounding
  # evidence must leave the attention file absent.
  _install_deliver_mock
  local pane="%210" wid file
  wid=$(_arm_on "$pane") || return 1
  file=$(_eventsd_attention_file "$pane")
  rm -f "$file"
  watch_resolve "$wid" idle || return 1
  if [[ -e "$file" ]]; then
    echo "    watch_resolve wrote attention implicitly: $file"
    return 1
  fi
}
run_test "watch_resolve does not write attention implicitly" test_watch_resolve_does_not_write_attention_implicitly

test_prearm_clears_stale_attention_via_unlink() {
  # A new turn.prearm is a turn boundary: the prior terminal state no
  # longer applies to the new turn, so the stale record is cleared.
  # Clearing must unlink — a zero-byte file would still be read as
  # "needs attention" by attention_get_recent's `[[ -f ... ]]` guard.
  _install_deliver_mock
  local pane="%211" file
  file=$(_eventsd_attention_file "$pane")
  mkdir -p "$(dirname "$file")"
  _eventsd_record_attention "$pane" "blocked:permission" >/dev/null
  [[ -e "$file" ]] || { echo "    stale attention seed failed"; return 1; }
  watch_create_pending \
    --pane "$pane" --spawner "%0" --label "codex" \
    --baseline-state working \
    --prearm-screen-hash "hash-$pane" \
    --prearm-transcript-cursor 4096 \
    --prearm-seq 7 >/dev/null || return 1
  if [[ -e "$file" ]]; then
    echo "    prearm did not unlink stale attention: $file"
    return 1
  fi
}
run_test "prearm clears stale attention via unlink" test_prearm_clears_stale_attention_via_unlink

test_working_evidence_does_not_create_attention_file() {
  # Fresh fast evidence with state=working keeps the watch armed (working
  # can never resolve) and must not materialize an attention record: the
  # turn has not reached a terminal state yet, so the inspector must not
  # surface a "needs attention" signal.
  _install_deliver_mock
  local pane="%213" wid file
  wid=$(_arm_on "$pane") || return 1
  file=$(_eventsd_attention_file "$pane")
  rm -f "$file"
  watch_feed_evidence --watch-id "$wid" --seq 100 --candidate-state working \
    --transcript-cursor 5000 --screen-hash "fresh-$pane" >/dev/null || return 1
  if [[ -e "$file" ]]; then
    echo "    working evidence materialized attention file: $file"
    return 1
  fi
}
run_test "working evidence does not create attention file" test_working_evidence_does_not_create_attention_file

# ----- sticky + spawner-visible attention (U3) -----
#
# The tmux attention dot represents "unread watched-turn attention" on
# the spawner's window. It survives worker-pane closure (sticky) and is
# an aggregate across every attention record that shares the same
# spawner_pane, so a spawner with multiple workers keeps the dot until
# every worker's record has been retired by a new turn.prearm.
#
# Per-pane attention records remain worker-keyed on disk — `agent-state
# <pane> --explain` still answers per-pane while the pane lives — but
# the tmux sink is spawner-scoped. Pane-close writes the record (does
# NOT unlink it) so the spawner-side signal persists after the worker
# pane goes away.

suite "sticky + spawner-visible attention (U3)"

_u3_install_sink_mocks() {
  export MOCK_TMUX_LOG="$TEST_TMP/u3-tmux.log"
  : > "$MOCK_TMUX_LOG"
  export SKETCHYBAR_LOG="$TEST_TMP/u3-sketchybar.log"
  : > "$SKETCHYBAR_LOG"
  cat > "$MOCK_BIN/sketchybar" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SKETCHYBAR_LOG:-/dev/null}"
exit 0
MOCK
  chmod +x "$MOCK_BIN/sketchybar"
}

# Clear any attention records seeded by earlier tests so the U3 aggregate
# scan starts from a known-empty state. Worker-pane keys in other suites
# (%214, %215, etc.) with empty spawner_pane fields would otherwise leak
# into the spawner-scoped aggregate below.
_u3_reset_attention_dir() {
  rm -rf "$_EVENTSD_STATE_DIR/attention"
}

test_record_attention_publishes_to_spawner_window_not_worker() {
  # Attention is for the spawner, not the worker. The tmux window option
  # must land on the spawner's window — the side that spawned the watch
  # and needs the visible signal — not the worker's window (where the
  # user may never look, or where the pane may have already closed).
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local worker="%320" spawner="%321"
  _eventsd_record_attention "$worker" "blocked:question" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  grep -Fq "set-option -w -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    spawner set-option missing:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
  if grep -Fq "set-option -w -t $worker @agent_monitor_attention" "$MOCK_TMUX_LOG"; then
    echo "    tmux option was set on worker window (should be spawner-scoped):"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  fi
  grep -Fq -- "--trigger agent_attention_changed" "$SKETCHYBAR_LOG" || {
    echo "    sketchybar trigger missing on record:"
    sed 's/^/      /' "$SKETCHYBAR_LOG"
    return 1
  }
}
run_test "record_attention publishes to spawner window not worker" \
  test_record_attention_publishes_to_spawner_window_not_worker

test_attention_record_persists_spawner_pane() {
  # The JSON record persists spawner_pane so downstream refresh passes
  # and clear paths can recover the target sink without re-reading the
  # (possibly drained) watch record.
  _u3_reset_attention_dir
  local worker="%322" spawner="%323" rec sp
  _eventsd_record_attention "$worker" "blocked:permission" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  rec=$(attention_get_recent "$worker") || return 1
  sp=$(printf '%s' "$rec" | jq -r '.spawner_pane // empty')
  [[ "$sp" == "$spawner" ]] || {
    echo "    spawner_pane missing or wrong: got '$sp', want '$spawner'"
    printf '    rec=%s\n' "$rec"
    return 1
  }
}
run_test "attention record persists spawner_pane" \
  test_attention_record_persists_spawner_pane

test_pane_close_preserves_attention_record() {
  # Sticky attention: pane-close must NOT unlink the attention record.
  # The spawner still needs the signal even after the worker pane dies;
  # unlinking it here would make the dot vanish the instant the worker
  # exits — exactly the bug steez-80p4.2 exists to fix.
  _u3_reset_attention_dir
  _install_bead7_deliver_mock
  RECONCILE_TPATH="" _install_reconcile_mock "%324:working"
  local pane="%324" wid file
  wid=$(_arm_on "$pane") || return 1
  file=$(_eventsd_attention_file "$pane")
  rm -f "$file"
  export "$(_exit_var_name "$wid")=0"
  watch_pane_close "$pane" || return 1
  [[ -e "$file" ]] || {
    echo "    pane-close did not leave a sticky attention record: $file"
    return 1
  }
}
run_test "pane-close preserves attention record (sticky)" \
  test_pane_close_preserves_attention_record

test_pane_close_publishes_attention_on_spawner_window() {
  # Pane-close writes a sticky record AND drives the spawner sink.
  # Worker %326 is gone by the time the dot fires; the set-option must
  # target the spawner's window so the badge is visible on the side
  # the user is actually looking at.
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  _install_bead7_deliver_mock
  RECONCILE_TPATH="" _install_reconcile_mock "%326:blocked:question"
  local worker="%326" spawner="%327" wid
  wid=$(watch_create_pending \
    --pane "$worker" --spawner "$spawner" --label "codex" \
    --baseline-state working \
    --prearm-screen-hash "hash-$worker" \
    --prearm-transcript-cursor 0 \
    --prearm-seq 100) || return 1
  watch_arm --pane "$worker" --watch-id "$wid" --start-seq 101 >/dev/null || return 1
  export "$(_exit_var_name "$wid")=0"
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  watch_pane_close "$worker" || return 1
  grep -Fq "set-option -w -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    spawner set-option missing after pane-close:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
  if grep -Fq "set-option -w -t $worker @agent_monitor_attention" "$MOCK_TMUX_LOG"; then
    echo "    tmux option landed on the (closed) worker window:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  fi
  grep -Fq -- "--trigger agent_attention_changed" "$SKETCHYBAR_LOG" || {
    echo "    sketchybar trigger missing after pane-close:"
    sed 's/^/      /' "$SKETCHYBAR_LOG"
    return 1
  }
}
run_test "pane-close publishes attention on spawner window" \
  test_pane_close_publishes_attention_on_spawner_window

test_clear_attention_targets_spawner_window_from_stored_record() {
  # Clearing reads the spawner from the stored record, so the unset
  # lands on the spawner's window even if the caller has no live watch
  # context to re-derive it (e.g., explicit removal after the worker
  # pane has already been reaped).
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local worker="%328" spawner="%329" file
  file=$(_eventsd_attention_file "$worker")
  mkdir -p "$(dirname "$file")"
  _eventsd_record_attention "$worker" "blocked:question" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  _eventsd_clear_attention "$worker" || return 1
  [[ -e "$file" ]] && { echo "    clear did not unlink file"; return 1; }
  grep -Fq "set-option -w -u -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    spawner unset missing from clear call:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
  if grep -Fq "set-option -w -u -t $worker @agent_monitor_attention" "$MOCK_TMUX_LOG"; then
    echo "    clear unset on worker window (should be spawner-scoped):"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  fi
  grep -Fq -- "--trigger agent_attention_changed" "$SKETCHYBAR_LOG" || {
    echo "    sketchybar trigger missing on clear:"
    sed 's/^/      /' "$SKETCHYBAR_LOG"
    return 1
  }
}
run_test "clear_attention targets spawner window from stored record" \
  test_clear_attention_targets_spawner_window_from_stored_record

test_prearm_refreshes_spawner_sink_keeping_sibling_attention() {
  # Two workers share a spawner. Worker A has a terminal attention
  # record; worker B does too. A new turn.prearm on worker A clears
  # A's record but must NOT wipe B's — the spawner still has unread
  # attention, so the dot stays set. Only when no worker for that
  # spawner has a record does the sink clear.
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local wa="%330" wb="%331" spawner="%332" fa fb
  fa=$(_eventsd_attention_file "$wa")
  fb=$(_eventsd_attention_file "$wb")
  mkdir -p "$(dirname "$fa")"
  _eventsd_record_attention "$wa" "blocked:question" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  _eventsd_record_attention "$wb" "idle"             "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  watch_create_pending \
    --pane "$wa" --spawner "$spawner" --label codex \
    --baseline-state working \
    --prearm-screen-hash "hash" \
    --prearm-transcript-cursor 1000 \
    --prearm-seq 50 >/dev/null || return 1
  [[ -e "$fa" ]] && { echo "    prearm did not unlink worker A's attention: $fa"; return 1; }
  [[ -e "$fb" ]] || { echo "    prearm wrongly unlinked worker B's attention: $fb"; return 1; }
  # Spawner still has an unread worker (B) — the sink must be SET,
  # not UNSET. An unset line here would be the bug this test catches.
  if grep -Fq "set-option -w -u -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG"; then
    echo "    prearm wiped the spawner sink while worker B still has attention:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  fi
  grep -Fq "set-option -w -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    prearm did not refresh the spawner sink after clearing worker A:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
}
run_test "prearm refreshes spawner sink keeping sibling attention" \
  test_prearm_refreshes_spawner_sink_keeping_sibling_attention

test_spawner_sink_unsets_when_last_attention_record_cleared() {
  # Single worker per spawner. Clearing the only attention record must
  # unset the spawner sink — otherwise the dot never retires.
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local worker="%333" spawner="%334" file
  file=$(_eventsd_attention_file "$worker")
  mkdir -p "$(dirname "$file")"
  _eventsd_record_attention "$worker" "blocked:question" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  _eventsd_clear_attention "$worker" || return 1
  grep -Fq "set-option -w -u -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    spawner sink did not unset after last attention cleared:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
}
run_test "spawner sink unsets when last attention record cleared" \
  test_spawner_sink_unsets_when_last_attention_record_cleared

# ----- spawner-scoped ack (steez-ht6x) -----
#
# Acknowledging attention on a spawner window is a first-class operation:
# a single call retires every sticky attention record whose
# `spawner_pane` matches the focused window and refreshes the tmux +
# SketchyBar sink so the dot clears. Crucially, the ack must stay
# confined to the addressed spawner — attention records belonging to any
# other spawner survive untouched.

suite "spawner-scoped attention ack (steez-ht6x)"

test_ack_retires_all_records_for_spawner_and_unsets_sink() {
  # Two workers share a spawner. An ack for that spawner must unlink
  # both records and then unset the aggregate tmux option once (only one
  # set-option -u call against the spawner's window). SketchyBar must
  # still fire so the macOS bar refreshes immediately.
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local wa="%340" wb="%341" spawner="%342" fa fb
  fa=$(_eventsd_attention_file "$wa")
  fb=$(_eventsd_attention_file "$wb")
  mkdir -p "$(dirname "$fa")"
  _eventsd_record_attention "$wa" "blocked:question" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  _eventsd_record_attention "$wb" "idle" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  declare -F _eventsd_ack_spawner_attention >/dev/null \
    || { echo "    missing _eventsd_ack_spawner_attention surface"; return 1; }
  _eventsd_ack_spawner_attention "$spawner" || return 1
  [[ -e "$fa" ]] && { echo "    ack did not unlink worker A: $fa"; return 1; }
  [[ -e "$fb" ]] && { echo "    ack did not unlink worker B: $fb"; return 1; }
  grep -Fq "set-option -w -u -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    ack did not unset the spawner sink:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
  grep -Fq -- "--trigger agent_attention_changed" "$SKETCHYBAR_LOG" || {
    echo "    ack did not trigger sketchybar refresh:"
    sed 's/^/      /' "$SKETCHYBAR_LOG"
    return 1
  }
}
run_test "ack retires all records for spawner and unsets sink" \
  test_ack_retires_all_records_for_spawner_and_unsets_sink

test_ack_leaves_other_spawners_records_untouched() {
  # The ack is spawner-scoped. An attention record for a DIFFERENT
  # spawner must not be unlinked, and the unrelated spawner's tmux
  # window option must not be touched by this call.
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local wa="%343" wb="%344" sa="%345" sb="%346" fa fb
  fa=$(_eventsd_attention_file "$wa")
  fb=$(_eventsd_attention_file "$wb")
  mkdir -p "$(dirname "$fa")"
  _eventsd_record_attention "$wa" "blocked:question" "eventsd" "" "" "" "$sa" \
    >/dev/null || return 1
  _eventsd_record_attention "$wb" "blocked:permission" "eventsd" "" "" "" "$sb" \
    >/dev/null || return 1
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  _eventsd_ack_spawner_attention "$sa" || return 1
  [[ -e "$fa" ]] && { echo "    ack did not unlink worker A under $sa: $fa"; return 1; }
  [[ -e "$fb" ]] || { echo "    ack wrongly unlinked worker B under $sb: $fb"; return 1; }
  if grep -Fq "@agent_monitor_attention" "$MOCK_TMUX_LOG" \
     | grep -Fv -- "-t $sa "; then
    :
  fi
  if grep -E -- "-t $sb([[:space:]]|$)" "$MOCK_TMUX_LOG" >/dev/null; then
    echo "    ack touched the sibling spawner's tmux option:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  fi
}
run_test "ack leaves other spawners' records untouched" \
  test_ack_leaves_other_spawners_records_untouched

test_ack_with_no_matching_records_still_refreshes_sink() {
  # An ack on a spawner that has no attention records is a harmless
  # no-op for on-disk state, but it must still refresh the sink so the
  # tmux option clears (idempotent) and SketchyBar fires.
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local spawner="%347"
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  _eventsd_ack_spawner_attention "$spawner" || return 1
  grep -Fq "set-option -w -u -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    empty ack did not unset the spawner sink:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
  grep -Fq -- "--trigger agent_attention_changed" "$SKETCHYBAR_LOG" || {
    echo "    empty ack did not trigger sketchybar refresh:"
    sed 's/^/      /' "$SKETCHYBAR_LOG"
    return 1
  }
}
run_test "ack with no matching records still refreshes sink" \
  test_ack_with_no_matching_records_still_refreshes_sink

test_ack_cli_drives_ack_end_to_end() {
  # The CLI entrypoint `agent-eventsd ack --spawner <pane>` must drive
  # the same behavior end-to-end: unlink matching records and refresh
  # the spawner sink. Proves there is a callable command (not only an
  # internal helper) for the focus-ack path.
  _u3_install_sink_mocks
  _u3_reset_attention_dir
  local worker="%348" spawner="%349" file rc=0 out
  file=$(_eventsd_attention_file "$worker")
  mkdir -p "$(dirname "$file")"
  _eventsd_record_attention "$worker" "blocked:question" "eventsd" "" "" "" "$spawner" \
    >/dev/null || return 1
  : > "$MOCK_TMUX_LOG"
  : > "$SKETCHYBAR_LOG"
  out=$(EVENTSD_REQUIRE_EXPLICIT_SERVICE=1 "$EVENTSD" ack --spawner "$spawner" 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || {
    echo "    ack CLI exited $rc:"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
  }
  [[ -e "$file" ]] && { echo "    ack CLI did not unlink record: $file"; return 1; }
  grep -Fq "set-option -w -u -t $spawner @agent_monitor_attention" "$MOCK_TMUX_LOG" || {
    echo "    ack CLI did not unset the spawner sink:"
    sed 's/^/      /' "$MOCK_TMUX_LOG"
    return 1
  }
  grep -Fq -- "--trigger agent_attention_changed" "$SKETCHYBAR_LOG" || {
    echo "    ack CLI did not trigger sketchybar refresh:"
    sed 's/^/      /' "$SKETCHYBAR_LOG"
    return 1
  }
}
run_test "ack CLI drives ack end-to-end" test_ack_cli_drives_ack_end_to_end

test_ack_cli_rejects_missing_spawner_flag() {
  # Missing --spawner is a usage error. Exit code 2 matches every other
  # flag-validation path in the daemon (prearm/start/evidence).
  local rc=0 out
  out=$(EVENTSD_REQUIRE_EXPLICIT_SERVICE=1 "$EVENTSD" ack 2>&1) || rc=$?
  assert_exit_code 2 "$rc" || { printf '%s\n' "$out" | sed 's/^/      /'; return 1; }
  assert_contains "$out" "--spawner" || return 1
}
run_test "ack CLI rejects missing --spawner flag" \
  test_ack_cli_rejects_missing_spawner_flag

# ----- bead steez-fyjy: blocked:unknown is not a terminal watch outcome -----
#
# Regression: the degraded-fallback indeterminate timeout used to mature a
# live watch to a terminal `blocked:unknown` and deliver. In production
# that produced false attention (the worker was still producing output,
# just under the inspector's fuzziness threshold) and then dropped the
# real Stop-hook idle ping because `watch_resolve` had already cleared
# the live slot. The spec no longer supports terminal `blocked:unknown`
# as a live-watch resolution — the indeterminate window must keep the
# watch armed, and the real terminal ping (idle / blocked:permission /
# blocked:question) is the only evidence that can resolve it. Fuzzy
# `blocked:unknown` observations remain available for the explain/debug
# surfaces, just not as a delivery trigger.

suite "blocked:unknown demotion (steez-fyjy)"

test_indeterminate_timeout_does_not_mature_live_watch_to_blocked_unknown() {
  # A stuck worker returns state=working with a transcript cursor frozen
  # at the prearm baseline. Under the old spec the degraded window would
  # mature to blocked:unknown and deliver. The new contract: stay armed,
  # never deliver, wait for fresh terminal evidence.
  _install_deliver_mock

  local tpath="$TEST_TMP/transcript-fyjy-1.jsonl"
  : > "$tpath"
  head -c 4096 < /dev/zero > "$tpath"
  _install_transcript_agent_state_mock "$tpath"
  export AGENT_STATE_RESPONSE_STATE="working"

  local pane="%500" wid rec t0=20000000 t
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # Cross silence: first reconcile sees frozen cursor, so degraded stays
  # stamped and last_reconcile_ms is set.
  _set_now $((t0 + 30000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1
  assert_json_field "$rec" .degraded_since_ms $((t0 + 30000)) || return 1

  # Drive well past the old indeterminate timeout (120s). Watch must stay
  # armed on every tick — no blocked:unknown resolution is permitted from
  # the degraded window alone.
  for (( t = t0 + 35000; t <= t0 + 30000 + 120000 + 60000; t += 5000 )); do
    _set_now "$t"
    watch_tick "$wid" >/dev/null || return 1
    rec=$(watch_get "$wid")
    assert_json_field "$rec" .state armed \
      || { echo "    watch unexpectedly resolved at t+$((t - t0))"; return 1; }
  done

  # Pane slot still owned by the same watch, no delivery has fired.
  local live
  live=$(watch_get_live "$pane")
  assert_json_field "$live" .watch_id "$wid" || return 1
  assert_eq 0 "$(_deliver_call_count)" || return 1
}
run_test "indeterminate_timeout_does_not_mature_live_watch_to_blocked_unknown" \
  test_indeterminate_timeout_does_not_mature_live_watch_to_blocked_unknown

test_idle_evidence_after_indeterminate_window_still_resolves_and_delivers() {
  # The concrete user bug: a long working turn lives past the old
  # indeterminate window, the inspector keeps reporting fuzzy
  # `blocked:unknown`, and the real Stop hook eventually dispatches
  # fast-path idle evidence. The idle ping must still resolve the
  # original watch_id and deliver exactly once.
  _install_deliver_mock

  local tpath="$TEST_TMP/transcript-fyjy-2.jsonl"
  : > "$tpath"
  _install_transcript_agent_state_mock "$tpath"
  export AGENT_STATE_RESPONSE_STATE="blocked:unknown"

  local pane="%501" wid rec t0=21000000 cursor seq
  _set_now "$t0"
  wid=$(_arm_on_prearm_cursor "$pane" 0) || return 1

  # Drive past the old indeterminate timeout with the cursor frozen so
  # reconciles do not reset the deadman. Every tick must leave the watch
  # armed under the new contract.
  local t
  for (( t = t0 + 30000; t <= t0 + 30000 + 120000 + 60000; t += 5000 )); do
    _set_now "$t"
    watch_tick "$wid" >/dev/null || return 1
    rec=$(watch_get "$wid")
    assert_json_field "$rec" .state armed \
      || { echo "    watch unexpectedly resolved at t+$((t - t0))"; return 1; }
  done
  assert_eq 0 "$(_deliver_call_count)" || return 1

  # Stop hook fires — fast-path idle evidence arrives with a strictly
  # advancing cursor. Original watch_id must resolve to idle and deliver.
  head -c 5000 < /dev/zero > "$tpath"
  cursor=$(wc -c < "$tpath" | tr -d ' ')
  seq=$(seq_next "$pane")
  _set_now $((t0 + 30000 + 120000 + 90000))
  watch_feed_evidence --watch-id "$wid" --seq "$seq" \
    --candidate-state idle --transcript-cursor "$cursor" \
    --source fast >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state idle || return 1

  watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  assert_eq 1 "$(_deliver_call_count)" || return 1
}
run_test "idle_evidence_after_indeterminate_window_still_resolves_and_delivers" \
  test_idle_evidence_after_indeterminate_window_still_resolves_and_delivers

# ----- terminal disposal (steez-u7o7.1) -----
#
# Terminal watch records (delivered, closed) have no runtime consumers —
# retry paths read `delivery_failed`, and resolve / feed_evidence / tick /
# deliver_attempt are one-shot against terminal state. The daemon
# accumulated 148+ stale files in production because nothing unlinked them
# on transition. Dispose of the record the moment the state becomes
# terminal so the hot watches/ directory cannot leak.

suite "terminal disposal (steez-u7o7.1)"

test_delivered_watch_record_is_unlinked_on_transition() {
  _install_deliver_mock
  local wid
  wid=$(_arm_on "%u7o7a") || return 1
  watch_resolve "$wid" idle || return 1
  MOCK_DELIVER_EXIT=0 watch_deliver_attempt "$wid" || return 1
  [[ ! -e "$(_eventsd_watch_file "$wid")" ]] \
    || { echo "    delivered record still on disk: $(_eventsd_watch_file "$wid")"; return 1; }
  assert_eq "" "$(watch_get "$wid")" || return 1
  assert_eq "" "$(watch_get_live "%u7o7a")" || return 1
}
run_test "delivered_watch_record_is_unlinked_on_transition" test_delivered_watch_record_is_unlinked_on_transition

test_closed_watch_record_is_unlinked_on_watch_remove() {
  _install_deliver_mock
  local wid
  wid=$(_mk_pending "%u7o7b") || return 1
  watch_remove "%u7o7b" || return 1
  [[ ! -e "$(_eventsd_watch_file "$wid")" ]] \
    || { echo "    removed record still on disk: $(_eventsd_watch_file "$wid")"; return 1; }
  assert_eq "" "$(watch_get "$wid")" || return 1
}
run_test "closed_watch_record_is_unlinked_on_watch_remove" test_closed_watch_record_is_unlinked_on_watch_remove

test_closed_watch_record_is_unlinked_on_supersede() {
  _install_deliver_mock
  local pane="%u7o7c" w_prior w_live
  w_prior=$(_mk_pending "$pane") || return 1
  w_live=$(watch_create_pending \
    --pane "$pane" --spawner "%0" --label codex \
    --baseline-state working \
    --prearm-screen-hash "h-u7o7c" \
    --prearm-transcript-cursor 8192 \
    --prearm-seq 20) || return 1
  [[ "$w_prior" != "$w_live" ]] || return 1
  [[ ! -e "$(_eventsd_watch_file "$w_prior")" ]] \
    || { echo "    superseded record still on disk: $(_eventsd_watch_file "$w_prior")"; return 1; }
  assert_eq "" "$(watch_get "$w_prior")" || return 1
}
run_test "closed_watch_record_is_unlinked_on_supersede" test_closed_watch_record_is_unlinked_on_supersede

test_closed_watch_record_is_unlinked_on_pending_timeout() {
  _install_deliver_mock
  local wid
  wid=$(_mk_pending "%u7o7d") || return 1
  watch_pending_timeout "$wid" || return 1
  [[ ! -e "$(_eventsd_watch_file "$wid")" ]] \
    || { echo "    pending_timeout record still on disk"; return 1; }
}
run_test "closed_watch_record_is_unlinked_on_pending_timeout" test_closed_watch_record_is_unlinked_on_pending_timeout

test_closed_watch_record_is_unlinked_on_delivery_exhaustion() {
  _install_deliver_mock
  local wid i
  wid=$(_arm_on "%u7o7e") || return 1
  watch_resolve "$wid" idle || return 1
  for ((i=1; i<=MAX_DELIVERY_ATTEMPTS; i++)); do
    MOCK_DELIVER_EXIT=9 watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  done
  [[ ! -e "$(_eventsd_watch_file "$wid")" ]] \
    || { echo "    delivery-exhausted record still on disk"; return 1; }
}
run_test "closed_watch_record_is_unlinked_on_delivery_exhaustion" test_closed_watch_record_is_unlinked_on_delivery_exhaustion

test_watch_list_omits_terminal_records() {
  # watch_list walks the on-disk watches/ dir. With terminal records
  # unlinked, list must only reflect active (pending/armed/resolved/
  # delivering/delivery_failed) watches.
  _install_deliver_mock
  local w_active w_delivered out ids
  w_active=$(_mk_pending "%u7o7f") || return 1
  w_delivered=$(_arm_on "%u7o7g") || return 1
  watch_resolve "$w_delivered" idle || return 1
  MOCK_DELIVER_EXIT=0 watch_deliver_attempt "$w_delivered" || return 1

  out=$(watch_list)
  ids=$(printf '%s\n' "$out" | jq -r '.watch_id' 2>/dev/null | sort -u)
  printf '%s\n' "$ids" | grep -Fxq "$w_active" \
    || { echo "    active watch missing from list"; return 1; }
  if printf '%s\n' "$ids" | grep -Fxq "$w_delivered"; then
    echo "    delivered watch leaked into list"
    return 1
  fi
}
run_test "watch_list_omits_terminal_records" test_watch_list_omits_terminal_records

report
