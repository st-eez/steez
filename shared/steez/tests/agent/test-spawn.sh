#!/usr/bin/env bash
# Tests for spawn.sh. Exercises real behavior against a stateful tmux mock
# and an agent-send spy: arg parsing, model validation, resolve_dir,
# split/new-window/new-session target creation, --target chaining,
# launch-command shape per model, PROMPT_SENT/WORKING/IDLE/WATCHED output,
# and --no-watch passthrough.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT
create_mock_tmux

# agent-send spy: records every invocation's argv to $AGENT_SEND_LOG (one
# argv list per invocation, separated by a blank line). Replays the real
# --emit-watch-line + --no-watch contract so spawn.sh's output matches
# what agent-send would actually emit in production.
AGENT_SEND_LOG="$TEST_TMP/agent-send.log"
create_mock_script "$HOME/.steez/bin/agent-send" '
{
  for a in "$@"; do printf "%s\n" "$a"; done
  echo "---"
} >> "'"$AGENT_SEND_LOG"'"

skip=false; emit=false; pane=""
for a in "$@"; do
  case "$a" in
    --no-watch)        skip=true ;;
    --emit-watch-line) emit=true ;;
    %*)                pane="$a" ;;  # last %N wins = the target pane
  esac
done
if [[ "$emit" == true && "$skip" == false ]]; then
  echo "WATCHED=$pane SPAWNER=%0 BASELINE=working"
fi
exit 0
'

suite "resolve_dir"

eval "$(extract_function "$SPAWN_SCRIPT" "resolve_dir")"

test_literal_existing() {
  mkdir -p "$TEST_TMP/mydir"
  local out rc=0
  out=$(resolve_dir "$TEST_TMP/mydir") || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "RESOLVED=$TEST_TMP/mydir"
  assert_contains "$out" "METHOD=literal"
}
run_test "literal path resolves existing dir" test_literal_existing

test_literal_nonexistent() {
  local out rc=0
  out=$(resolve_dir "/nonexistent/path/here") || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "NOTFOUND"
}
run_test "literal nonexistent path returns NOTFOUND" test_literal_nonexistent

test_cwd_child() {
  mkdir -p "$TEST_TMP/workspace/project-x"
  local out rc=0
  out=$(cd "$TEST_TMP/workspace" && resolve_dir "project-x") || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "RESOLVED=$TEST_TMP/workspace/project-x"
  assert_contains "$out" "METHOD=local"
}
run_test "cwd child resolves" test_cwd_child

test_cwd_child_nonexistent() {
  local out rc=0
  out=$(cd "$TEST_TMP" && resolve_dir "no-such-child" 2>/dev/null) || rc=$?
  assert_not_contains "$out" "METHOD=local"
}
run_test "cwd child nonexistent falls through" test_cwd_child_nonexistent

test_tilde_expansion() {
  mkdir -p "$HOME/test-resolve-tilde"
  local out rc=0
  out=$(resolve_dir "~/test-resolve-tilde") || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "RESOLVED=$HOME/test-resolve-tilde"
  assert_contains "$out" "METHOD=literal"
}
run_test "tilde expands to HOME" test_tilde_expansion

test_relative_dot() {
  mkdir -p "$TEST_TMP/workspace/sub"
  local out rc=0
  out=$(cd "$TEST_TMP/workspace" && resolve_dir "./sub") || rc=$?
  assert_exit_code "0" "$rc"
  assert_contains "$out" "RESOLVED="
  assert_contains "$out" "METHOD=literal"
}
run_test "./relative path resolves" test_relative_dot

# ----- Arg parsing (no-tmux fast paths) -----

suite "spawn.sh arg validation"

test_invalid_model() {
  local rc=0 out
  out=$(TMUX="" TMUX_PANE="" "$SPAWN_SCRIPT" split-h --model badmodel 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown model"
}
run_test "rejects invalid model" test_invalid_model

test_no_tmux() {
  local rc=0 out
  out=$(TMUX="" TMUX_PANE="" "$SPAWN_SCRIPT" split-h 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "not in a tmux session"
}
run_test "exits 1 without TMUX" test_no_tmux

test_unknown_arg() {
  local rc=0 out
  out=$(TMUX="" TMUX_PANE="" "$SPAWN_SCRIPT" split-h --bogus 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown argument"
}
run_test "unknown arg exits 1" test_unknown_arg

test_no_args() {
  local rc=0 out
  out=$(TMUX="" TMUX_PANE="" "$SPAWN_SCRIPT" 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
}
run_test "no args exits 1" test_no_args

test_model_before_tmux_check() {
  local rc=0 out
  out=$(TMUX="fake" TMUX_PANE="%0" "$SPAWN_SCRIPT" split-h --model badmodel 2>&1) || rc=$?
  assert_contains "$out" "unknown model"
  assert_not_contains "$out" "not in a tmux"
}
run_test "model validation runs before TMUX check" test_model_before_tmux_check

# ----- End-to-end spawn against stateful tmux + agent-send spy -----
#
# Each test resets the pane table and agent-send log so results don't leak
# between cases. spawn.sh runs with TMUX and TMUX_PANE set to the mocked
# "self" pane (%0), so it walks the full flow: list-panes self lookup →
# snapshot → split/new-window/new-session → send-keys launch → sleep (mocked
# instant) → agent-send (spied).

reset_state() {
  : > "$MOCK_TMUX_PANES_FILE"
  rm -f "${MOCK_TMUX_PANES_FILE}.id"
  : > "$AGENT_SEND_LOG"
  mock_pane "%0" "1000" "" "/tmp" "test" "0"
}

run_spawn() {
  # Run spawn.sh as the %0 "self" pane. Suppress the tmux env from our
  # harness's parent shell so only the mock matters; --dir is off by default.
  TMUX="/tmp/fake-tmux" TMUX_PANE="%0" "$SPAWN_SCRIPT" "$@"
}

# Pull the N-th invocation's argv (0-indexed) out of AGENT_SEND_LOG.
agent_send_invocation() {
  local n="$1"
  awk -v want="$n" '
    BEGIN { i = 0 }
    /^---$/ { i++; next }
    { if (i == want) print }
  ' "$AGENT_SEND_LOG"
}

suite "spawn.sh split-h creates pane"

test_split_h_emits_self_and_new_target() {
  reset_state
  local out
  out=$(run_spawn split-h 2>&1)
  # SELF must be the invoking pane; TARGET must be a freshly allocated id.
  assert_contains "$out" "SELF=%0 TARGET=%100"
  assert_contains "$out" "MODEL=ren"
  # Pane table grew by exactly one row (self + new).
  local count
  count=$(wc -l < "$MOCK_TMUX_PANES_FILE" | tr -d ' ')
  assert_eq "2" "$count"
}
run_test "split-h creates new pane and emits SELF/TARGET" test_split_h_emits_self_and_new_target

test_split_v_creates_new_pane() {
  reset_state
  local out
  out=$(run_spawn split-v 2>&1)
  assert_contains "$out" "SELF=%0 TARGET=%100"
  local count
  count=$(wc -l < "$MOCK_TMUX_PANES_FILE" | tr -d ' ')
  assert_eq "2" "$count"
}
run_test "split-v creates new pane" test_split_v_creates_new_pane

test_split_target_chains_to_remote_pane() {
  # Per spec: --target %N makes the split happen in the REMOTE pane's
  # window, not the spawner's. Register a remote pane in a separate window,
  # spawn split-h --target %5, and verify the new pane lands in window 2,
  # not window 0.
  reset_state
  mock_pane "%5" "1500" "" "/tmp" "test" "2"
  local out
  out=$(run_spawn split-h --target %5 2>&1)
  assert_contains "$out" "SELF=%0 TARGET=%100"
  assert_eq "test" "$(pane_attr %100 5)"
  assert_eq "2"    "$(pane_attr %100 6)"
}
run_test "--target splits the remote pane's window, not self's" test_split_target_chains_to_remote_pane

suite "spawn.sh new-window / new-session"

test_new_window_creates_window_in_current_session() {
  reset_state
  local out
  out=$(run_spawn new-window 2>&1)
  assert_contains "$out" "SELF=%0 TARGET=%100"
  local new_session new_window
  new_session=$(pane_attr %100 5)
  new_window=$(pane_attr %100 6)
  assert_eq "test" "$new_session"
  [[ "$new_window" != "0" ]] || {
    echo "    new window should differ from self window (got $new_window)"
    exit 1
  }
}
run_test "new-window creates new window in current session" test_new_window_creates_window_in_current_session

test_new_session_default_name() {
  reset_state
  local out
  out=$(run_spawn new-session 2>&1)
  assert_contains "$out" "SELF=%0 TARGET=%100"
  pane_has_session "agent-1" || {
    echo "    expected session 'agent-1' in pane table"; exit 1;
  }
}
run_test "new-session defaults to agent-1 session" test_new_session_default_name

test_new_session_custom_name() {
  reset_state
  local out
  out=$(run_spawn new-session --session custom-sess 2>&1)
  assert_contains "$out" "SELF=%0 TARGET=%100"
  pane_has_session "custom-sess" || {
    echo "    expected session 'custom-sess' in pane table"; exit 1;
  }
}
run_test "--session names the new session" test_new_session_custom_name

suite "spawn.sh launch command per model"

# Each model has a canonical launch command (contract #7). The spy wraps
# the mock tmux so every send-keys call has its key stream appended to a
# per-test log; the inner mock still runs for pane-table state. After
# wrapping, assert the launch command appeared on its own line, then
# confirm no `dangerously` flag leaked into models that should launch bare.
install_launch_spy_tmux() {
  local launch_log="$1"
  cp "$MOCK_BIN/tmux" "$MOCK_BIN/tmux.inner"
  cat > "$MOCK_BIN/tmux" <<SPY
#!/usr/bin/env bash
if [[ "\${1:-}" == "send-keys" ]]; then
  shift
  keys=()
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -t) shift 2 ;;
      -b|-d) shift ;;
      -*) shift ;;
      *) keys+=("\$1"); shift ;;
    esac
  done
  printf '%s\n' "\${keys[*]}" >> "$launch_log"
fi
exec "$MOCK_BIN/tmux.inner" "\$@"
SPY
  chmod +x "$MOCK_BIN/tmux"
}

# Restore the tmux mock. Fails loudly if the backup is missing — a silent
# skip would leave a corrupted spy in place and cascade failures into the
# next test with no clear root cause.
restore_tmux() {
  [[ -f "$MOCK_BIN/tmux.inner" ]] || {
    echo "    restore_tmux: no backup at $MOCK_BIN/tmux.inner — spy install failed"
    exit 1
  }
  mv "$MOCK_BIN/tmux.inner" "$MOCK_BIN/tmux"
}

# Exercise spawn.sh --model <model> and assert the launch command typed
# into the new pane matches $expected_cmd exactly (one line). When $mode
# is "bare", also assert no `dangerously` flag leaked in.
assert_launch_cmd() {
  local model="$1" expected_cmd="$2" mode="$3"
  reset_state
  local log="$TEST_TMP/launch-$model.log"
  : > "$log"
  install_launch_spy_tmux "$log"
  run_spawn split-h --model "$model" >/dev/null 2>&1
  restore_tmux

  grep -qxF "$expected_cmd" "$log" || {
    echo "    expected exact launch line: $expected_cmd"
    echo "    log contents:"
    sed 's/^/      /' "$log"
    exit 1
  }
  if [[ "$mode" == "bare" ]]; then
    ! grep -q 'dangerously' "$log" || {
      echo "    $model must not launch with a permission-bypass flag"
      sed 's/^/      /' "$log"
      exit 1
    }
  fi
}

test_claude_launches_with_permission_bypass() {
  assert_launch_cmd "claude" "claude --dangerously-skip-permissions" "with-flag"
}
run_test "claude launches with --dangerously-skip-permissions" test_claude_launches_with_permission_bypass

test_codex_launches_with_permission_bypass() {
  assert_launch_cmd "codex" "codex --dangerously-bypass-approvals-and-sandbox" "with-flag"
}
run_test "codex launches with --dangerously-bypass-approvals-and-sandbox" test_codex_launches_with_permission_bypass

test_ren_launches_bare() {
  assert_launch_cmd "ren" "ren" "bare"
}
run_test "ren launches bare (no bypass flag)" test_ren_launches_bare

test_ren_codex_launches_bare() {
  assert_launch_cmd "ren-codex" "ren-codex" "bare"
}
run_test "ren-codex launches bare (no bypass flag)" test_ren_codex_launches_bare

suite "spawn.sh prompt delivery output"

test_idle_when_no_prompt() {
  reset_state
  local out
  out=$(run_spawn split-h 2>&1)
  assert_contains "$out" "IDLE"
  assert_not_contains "$out" "PROMPT_SENT"
  assert_not_contains "$out" "WORKING"
  assert_not_contains "$out" "WATCHED="
  # agent-send must not be called when no prompt is passed.
  [[ ! -s "$AGENT_SEND_LOG" ]] || {
    echo "    agent-send was called without a --prompt"
    cat "$AGENT_SEND_LOG" | sed 's/^/      /'
    exit 1
  }
}
run_test "no prompt → IDLE and no agent-send call" test_idle_when_no_prompt

test_prompt_emits_sent_working_watched() {
  reset_state
  local out
  out=$(run_spawn split-h --prompt "hello world" 2>&1)
  assert_contains "$out" "PROMPT_SENT"
  assert_contains "$out" "WORKING"
  assert_contains "$out" "WATCHED=%100"
  assert_contains "$out" "BASELINE=working"
  assert_not_contains "$out" "IDLE"
}
run_test "--prompt emits PROMPT_SENT / WORKING / WATCHED" test_prompt_emits_sent_working_watched

test_prompt_passes_spawner_label_and_emit_watch_line() {
  reset_state
  run_spawn split-h --prompt "fix the tests" >/dev/null 2>&1
  # agent-send is called exactly once.
  local invocations
  invocations=$(grep -c '^---$' "$AGENT_SEND_LOG")
  assert_eq "1" "$invocations"
  local argv
  argv=$(agent_send_invocation 0)
  assert_contains "$argv" "--spawner"$'\n'"%0"
  assert_contains "$argv" "--emit-watch-line"
  assert_contains "$argv" "--label"$'\n'"ren fix the tests"
  # Target pane and message are the tail positional args.
  assert_contains "$argv" $'\n'"%100"$'\n'"fix the tests"
}
run_test "--prompt passes --spawner / --label / --emit-watch-line to agent-send" test_prompt_passes_spawner_label_and_emit_watch_line

test_prompt_label_truncated_to_40_chars() {
  reset_state
  local long="this prompt body is definitely longer than forty characters and then some tail"
  run_spawn split-h --prompt "$long" >/dev/null 2>&1
  local argv label
  argv=$(agent_send_invocation 0)
  # Extract the --label value (the line immediately after --label).
  label=$(awk '/^--label$/{getline; print; exit}' <<< "$argv")
  # Format is "ren <first-40-chars-of-prompt-with-newlines-stripped>".
  local expected_body="${long:0:40}"
  assert_eq "ren $expected_body" "$label"
}
run_test "--label truncates prompt summary to 40 chars" test_prompt_label_truncated_to_40_chars

test_no_watch_suppresses_watched_and_passes_flag() {
  reset_state
  local out
  out=$(run_spawn split-h --prompt "brief" --no-watch 2>&1)
  assert_contains "$out" "PROMPT_SENT"
  assert_contains "$out" "WORKING"
  assert_not_contains "$out" "WATCHED="
  # agent-send must have received --no-watch, must NOT have received
  # --emit-watch-line or --label (the flags are mutually exclusive in
  # spawn.sh's logic).
  local argv
  argv=$(agent_send_invocation 0)
  assert_contains "$argv" "--no-watch"
  assert_not_contains "$argv" "--emit-watch-line"
  assert_not_contains "$argv" "--label"
}
run_test "--no-watch suppresses WATCHED line and passes --no-watch to agent-send" test_no_watch_suppresses_watched_and_passes_flag

test_model_label_tracks_model_flag() {
  reset_state
  run_spawn split-h --model claude --prompt "check it" >/dev/null 2>&1
  local argv label
  argv=$(agent_send_invocation 0)
  label=$(awk '/^--label$/{getline; print; exit}' <<< "$argv")
  assert_eq "claude check it" "$label"
}
run_test "--label carries the resolved model name" test_model_label_tracks_model_flag

report
