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
  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state closed || return 1
  assert_json_field "$rec" .close_reason pending_timeout || return 1
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
  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state closed || return 1
  assert_json_field "$rec" .close_reason removed || return 1
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
  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state closed || return 1
  assert_json_field "$rec" .close_reason removed || return 1
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
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state delivered || return 1
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
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .delivery_attempts 2 || return 1
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
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state closed || return 1
  assert_json_field "$rec" .close_reason delivery_exhausted || return 1
  assert_json_field "$rec" .delivery_attempts "$MAX_DELIVERY_ATTEMPTS" || return 1
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
  rec=$(watch_get "$w_prior")
  assert_json_field "$rec" .state closed || return 1
  assert_json_field "$rec" .close_reason superseded || return 1
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
  rec=$(watch_get "$w_live")
  assert_json_field "$rec" .state delivered || return 1
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
  assert_json_field "$(watch_get "$w1")" .state closed || return 1
  assert_json_field "$(watch_get "$w1")" .close_reason superseded || return 1
  w3=$(watch_create_pending --pane "$pane" --spawner "%0" --label codex \
    --baseline-state working --prearm-screen-hash "h-b" \
    --prearm-transcript-cursor 200 --prearm-seq 20) || return 1
  _assert_live_count "$pane" 1 || return 1
  assert_json_field "$(watch_get "$w2")" .state closed || return 1
  assert_json_field "$(watch_get "$w2")" .close_reason superseded || return 1
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
  assert_json_field "$(watch_get "$w3")" .state closed || return 1
  assert_json_field "$(watch_get "$w3")" .close_reason superseded || return 1
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
  assert_json_field "$(watch_get "$w4")" .state delivered || return 1
  assert_json_field "$(watch_get "$w5")" .state delivered || return 1
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

  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .delivery_attempts 5 || return 1
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
  # and rogue retry attempts must neither mutate state nor trigger
  # another agent-deliver invocation.
  watch_resolve "$wid" "blocked:permission" >/dev/null 2>&1 || true
  watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  assert_eq 5 "$(_deliver_call_count)" || return 1
  assert_json_field "$(watch_get "$wid")" .state delivered || return 1
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
  _install_deliver_mock
  AGENT_STATE_RESPONSE='{"state":"blocked:unknown"}'
  export AGENT_STATE_RESPONSE
  _install_agent_state_mock

  local pane="%92" wid rec t0=3000000
  _set_now "$t0"
  wid=$(_arm_on_bead6 "$pane") || return 1

  # First degraded episode — cross silence, then return to healthy after
  # 30s of degraded time (well under INDETERMINATE_TIMEOUT_MS).
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

  # One tick just before the new indeterminate window closes — still armed.
  _set_now $((second_degraded_at + 120000 - 1))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1

  # Crossing the full window from the new degraded_since_ms resolves
  # blocked:unknown.
  _set_now $((second_degraded_at + 120000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state "blocked:unknown" || return 1
}
run_test "second_degraded_episode_starts_a_new_indeterminate_timeout_window" test_second_degraded_episode_starts_a_new_indeterminate_timeout_window

test_fuzzy_blocked_unknown_does_not_resolve_a_live_watch() {
  # Spec (live watch resolution): a fuzzy blocked:unknown sample from
  # degraded reconciliation must not resolve or self-clear a live watch.
  # blocked:unknown is reserved for explicit timeout and pane-close
  # fallback only.
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

  # The explicit degraded timeout still resolves to blocked:unknown.
  _set_now $((t0 + 30000 + 120000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state "blocked:unknown" || return 1
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

test_stale_working_with_unchanged_cursor_times_out_to_blocked_unknown() {
  # Acceptance B (steez-j815): a frozen Claude returns state=working with
  # the same transcript cursor every reconcile. The old synthetic-hash
  # regime kept the watch armed forever; with real-cursor freshness, a
  # reconcile whose cursor has not advanced past both prearm and the last
  # reconcile cursor is NOT fresh, the deadman does not reset, and the
  # indeterminate timeout matures normally to blocked:unknown.
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

  # One tick just before the indeterminate window closes — still armed.
  _set_now $((t0 + 30000 + 120000 - 1))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state armed || return 1

  # Crossing the full window resolves to blocked:unknown. The safety gate
  # on `last_reconcile_ms != 0` is satisfied because reconciles succeeded
  # (they just returned a frozen cursor), so the timeout matures normally.
  _set_now $((t0 + 30000 + 120000))
  watch_tick "$wid" >/dev/null || return 1
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state resolved || return 1
  assert_json_field "$rec" .resolved_state "blocked:unknown" || return 1

  # Delivery fires for the resolved watch (exactly once — the canonical
  # notifier path is already covered elsewhere; here we just confirm the
  # timeout path still reaches delivery under the safety gate).
  watch_deliver_attempt "$wid" >/dev/null 2>&1 || true
  [[ "$(_deliver_call_count)" -ge 1 ]] \
    || { echo "    delivery never fired after indeterminate timeout"; return 1; }
}
run_test "stale_working_with_unchanged_cursor_times_out_to_blocked_unknown" test_stale_working_with_unchanged_cursor_times_out_to_blocked_unknown

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
  rec=$(watch_get "$w_resolved")
  assert_json_field "$rec" .watch_id "$w_resolved" || return 1
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .delivery_attempts 1 || return 1

  # delivering: demoted to delivery_failed, SAME watch_id, retry budget
  # preserved. The 2 pre-crash attempts + the 1 retry on this iteration = 3.
  rec=$(watch_get "$w_delivering")
  assert_json_field "$rec" .watch_id "$w_delivering" || return 1
  assert_json_field "$rec" .state delivery_failed || return 1
  assert_json_field "$rec" .delivery_attempts 3 || return 1

  # delivery_failed: retried with SAME watch_id, budget preserved.
  # 3 pre-crash + 1 retry (succeeded) = 4, within MAX_DELIVERY_ATTEMPTS=5.
  rec=$(watch_get "$w_failed")
  assert_json_field "$rec" .watch_id "$w_failed" || return 1
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .delivery_attempts 4 || return 1

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
  local rec
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state closed || return 1
  assert_json_field "$rec" .close_reason pane_closed || return 1
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

  # Terminal reconciliation produced the reconciled state.
  rec=$(watch_get "$w_term")
  assert_json_field "$rec" .watch_id "$w_term" || return 1
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .resolved_state idle || return 1
  # Non-terminal reconciliation fell back to blocked:unknown.
  rec=$(watch_get "$w_indef")
  assert_json_field "$rec" .watch_id "$w_indef" || return 1
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .resolved_state "blocked:unknown" || return 1

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
  rec=$(watch_get "$wid")
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .delivery_attempts 2 || return 1
  # The final call's second arg = spawner_pane.
  local last_target
  last_target=$(awk -v w="$wid" '$1==w {target=$2} END{print target}' "$DELIVER_LOG")
  assert_eq "%0" "$last_target" || return 1
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

  rec=$(watch_get "$wid")
  assert_json_field "$rec" .watch_id "$wid" || return 1
  assert_json_field "$rec" .state delivered || return 1
  assert_json_field "$rec" .resolved_state "blocked:unknown" || return 1
  assert_eq "" "$(watch_get_live "%145")" || return 1
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

report
