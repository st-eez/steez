#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

suite "agent docs"

test_agent_state_help_points_to_explain() {
  local help
  help=$("$BIN_DIR/agent-state" -h)
  assert_contains "$help" 'After `[agent-watch] <pane> (<label>) attention`, run `agent-state <pane> --explain`.'
  assert_contains "$help" "SessionStart, Stop, PermissionRequest, and"
  assert_contains "$help" "PreToolUse (AskUserQuestion)."
}
run_test "agent-state help teaches the attention follow-up contract" test_agent_state_help_points_to_explain

test_spawn_agent_skill_uses_explain_not_blocked_branching() {
  local doc
  doc=$(cat "$REPO_ROOT/skills/spawn-agent/SKILL.md")
  assert_contains "$doc" '`[agent-watch] <pane> (<label>) attention`'
  assert_contains "$doc" '~/.steez/bin/agent-state %5 --explain'
  assert_not_contains "$doc" "pending tool call needing input"
}
run_test "spawn-agent skill points spawners to --explain" test_spawn_agent_skill_uses_explain_not_blocked_branching

test_agent_state_spec_documents_attention_contract() {
  local spec
  spec=$(cat "$REPO_ROOT/specs/agent-state.md")
  assert_contains "$spec" '`[agent-watch] <pane> (<label>) attention`'
  assert_contains "$spec" '`agent-state <pane> --explain`'
  assert_contains "$spec" "SessionStart, Stop, PermissionRequest, and PreToolUse(AskUserQuestion)"
}
run_test "agent-state spec documents the reduced orchestration contract" test_agent_state_spec_documents_attention_contract

report
