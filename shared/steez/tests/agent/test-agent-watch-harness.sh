#!/usr/bin/env bash
# Regression for steez-715: the agent-watch suite must not leak a real
# agent-eventsd service after the file exits.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WATCH_TEST="$REPO_ROOT/shared/steez/tests/agent/test-agent-watch.sh"
EVENTSD_BIN="$REPO_ROOT/shared/steez/bin/agent-eventsd"
LEAKED_PIDS=()

cleanup_leaked_eventsd() {
  local pid
  for pid in "${LEAKED_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
}
trap cleanup_leaked_eventsd EXIT

capture_eventsd_service_pids() {
  ps -eo pid=,command= | awk -v bin="$EVENTSD_BIN" 'index($0, bin " serve") { print $1 }' | sort -n
}

new_eventsd_service_pids() {
  local before_file="$1" after_file="$2"
  comm -13 "$before_file" "$after_file"
}

suite "agent-watch harness lifecycle"

test_agent_watch_suite_exits_without_leaking_eventsd_service() {
  local before_file after_file output_file rc=0 extras i
  before_file=$(mktemp)
  after_file=$(mktemp)
  output_file=$(mktemp)
  capture_eventsd_service_pids > "$before_file"

  bash "$WATCH_TEST" >"$output_file" 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "    test-agent-watch.sh failed (rc=$rc)"
    sed 's/^/      /' "$output_file"
    rm -f "$before_file" "$after_file" "$output_file"
    exit 1
  fi

  for i in $(seq 1 40); do
    capture_eventsd_service_pids > "$after_file"
    extras=$(new_eventsd_service_pids "$before_file" "$after_file")
    [[ -z "$extras" ]] && break
    /bin/sleep 0.05
  done

  if [[ -n "$extras" ]]; then
    mapfile -t LEAKED_PIDS < <(printf '%s\n' "$extras" | sed '/^$/d')
    echo "    leaked agent-eventsd serve pid(s): $(printf '%s ' "${LEAKED_PIDS[@]}")"
    ps -o pid=,ppid=,command= -p "${LEAKED_PIDS[@]}" | sed 's/^/      /'
    echo "    child test output:"
    sed 's/^/      /' "$output_file"
    rm -f "$before_file" "$after_file" "$output_file"
    exit 1
  fi

  rm -f "$before_file" "$after_file" "$output_file"
}
run_test "agent-watch suite exits without leaking eventsd service" \
  test_agent_watch_suite_exits_without_leaking_eventsd_service

report
