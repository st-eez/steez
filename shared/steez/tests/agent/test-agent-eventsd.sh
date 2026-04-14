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

EVENTSD="$BIN_DIR/agent-eventsd"
if [[ ! -f "$EVENTSD" ]]; then
  echo "agent-eventsd not found at $EVENTSD"
  exit 1
fi

# Source daemon library. Bead 1 ships no main — the script is a pure
# library of functions that a later bead's transport will wrap.
# shellcheck disable=SC1090
source "$EVENTSD"

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

test_create_pending_errors_when_pane_already_has_live_watch() {
  # Invariant: at most one live watch per pane (spec: Live and
  # draining watches). Bead 1 enforces it by refusing duplicates.
  # Supersession is a later bead's lifecycle transition.
  _require_store_api || return 1
  _mk_pending "%30" >/dev/null || return 1
  local rc=0
  _mk_pending "%30" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "    second create_pending on same pane must fail"; return 1; }
}
run_test "create_pending errors when pane already has a live watch" test_create_pending_errors_when_pane_already_has_live_watch

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
  # Spec (Canonical resolver rule 3): "The first fresh terminal state
  # different from baseline_state resolves the watch."
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

report
