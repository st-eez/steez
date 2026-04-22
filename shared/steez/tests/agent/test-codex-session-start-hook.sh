#!/usr/bin/env bash
# Unit tests for shared/steez/hooks/codex-session-start.sh.
set -uo pipefail
source "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/shared/steez/hooks/codex-session-start.sh"

command -v jq >/dev/null 2>&1 || { echo "  skip: jq not installed"; exit 0; }

setup_hook_env() {
  setup_test_env
  TMUX_LOG="$TEST_TMP/tmux-calls.log"
  : > "$TMUX_LOG"

  cat > "$MOCK_BIN/tmux" <<TMUX_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMUX_LOG'
exit 0
TMUX_EOF
  chmod +x "$MOCK_BIN/tmux"
}

cleanup_hook_env() {
  cleanup_test_env
}

run_hook_with() {
  local payload="$1"
  TMUX_PANE="${TMUX_PANE:-}" HOME="$HOME" PATH="$PATH" \
    bash "$HOOK" <<<"$payload"
}

suite "codex-session-start.sh"

test_session_start_writes_payload_session_and_transcript_path() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  local transcript="$HOME/.codex/sessions/2026/04/22/rollout-2026-04-22T10-17-23-sess-payload.jsonl"
  mkdir -p "$(dirname "$transcript")"
  : > "$transcript"

  local payload
  payload=$(jq -cn --arg sid "sess-payload" --arg tp "$transcript" \
    '{session_id:$sid, transcript_path:$tp}')

  TMUX_PANE="%41" run_hook_with "$payload"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %41 @session_id sess-payload"
  assert_contains "$tmux_logged" "set-option -p -t %41 @transcript_path $transcript"
}
run_test "payload transcript_path is written to pane vars" \
  test_session_start_writes_payload_session_and_transcript_path

test_session_start_backfills_transcript_path_from_session_id_when_payload_omits_it() {
  setup_hook_env
  trap cleanup_hook_env EXIT

  local sid="019db5-hook-backfill"
  local transcript="$HOME/.codex/sessions/2026/04/22/rollout-2026-04-22T10-17-23-${sid}.jsonl"
  mkdir -p "$(dirname "$transcript")"
  : > "$transcript"

  local payload
  payload=$(jq -cn --arg sid "$sid" '{session_id:$sid}')

  TMUX_PANE="%42" run_hook_with "$payload"

  local tmux_logged
  tmux_logged=$(cat "$TMUX_LOG")
  assert_contains "$tmux_logged" "set-option -p -t %42 @session_id $sid"
  assert_contains "$tmux_logged" "set-option -p -t %42 @transcript_path $transcript"
}
run_test "session_id backfills transcript_path when payload omits it" \
  test_session_start_backfills_transcript_path_from_session_id_when_payload_omits_it

report
