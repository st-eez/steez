#!/usr/bin/env bash
# Tests for spawn.sh: model validation, resolve_dir, arg parsing.
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

setup_test_env
trap cleanup_test_env EXIT

# ----- resolve_dir (sourced function) -----
# Extract resolve_dir from spawn.sh — it's a pure function with no tmux deps.

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
  # Should NOT resolve via local method (fails, falls through)
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

# ----- Model validation (subprocess) -----

suite "spawn.sh model validation"

test_valid_models() {
  for model in ren ren-codex claude codex; do
    local rc=0 out
    # Valid model but no TMUX — should error about TMUX, not model
    out=$(TMUX="" TMUX_PANE="" "$SPAWN_SCRIPT" split-h --model "$model" 2>&1) || rc=$?
    assert_not_contains "$out" "unknown model"
  done
}
run_test "accepts all valid models" test_valid_models

test_invalid_model() {
  local rc=0 out
  out=$(TMUX="" TMUX_PANE="" "$SPAWN_SCRIPT" split-h --model badmodel 2>&1) || rc=$?
  assert_exit_code "1" "$rc"
  assert_contains "$out" "unknown model"
}
run_test "rejects invalid model" test_invalid_model

# ----- Arg parsing (subprocess) -----

suite "spawn.sh arg parsing"

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
  # Invalid model should error before TMUX check
  local rc=0 out
  out=$(TMUX="fake" TMUX_PANE="%0" "$SPAWN_SCRIPT" split-h --model badmodel 2>&1) || rc=$?
  assert_contains "$out" "unknown model"
  assert_not_contains "$out" "not in a tmux"
}
run_test "model validation runs before TMUX check" test_model_before_tmux_check

# ----- Output format contract -----

suite "spawn.sh output format"

test_output_self_target() {
  # This test verifies the contract that spawn.sh outputs SELF= and TARGET=
  # We can't actually create tmux panes in tests, so we verify the format
  # by checking what the script WOULD output. The contract is tested by
  # checking that the echo statement exists.
  local has_output
  has_output=$(grep -c 'echo "SELF=\$SELF_ID TARGET=\$NEW_TARGET"' "$SPAWN_SCRIPT")
  assert_eq "1" "$has_output"
}
run_test "outputs SELF= TARGET= format" test_output_self_target

report
