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

report
