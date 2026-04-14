#!/usr/bin/env bash
# Test harness for agent subsystem tests.
# Source from test files: source "$(dirname "$0")/helpers.sh"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BIN_DIR="$REPO_ROOT/shared/steez/bin"
SPAWN_SCRIPT="$REPO_ROOT/skills/spawn-agent/scripts/spawn.sh"

_PASS=0
_FAIL=0

_GREEN=$'\033[32m'
_RED=$'\033[31m'
_DIM=$'\033[2m'
_RESET=$'\033[0m'

TEST_TMP=""

setup_test_env() {
  TEST_TMP=$(mktemp -d)
  export REAL_HOME="$HOME"
  export HOME="$TEST_TMP/home"
  export STEEZ_STATE_DIR="$TEST_TMP/state"

  mkdir -p "$HOME/.steez/bin" "$HOME/.steez/state" "$HOME/.steez/agent-state"
  mkdir -p "$HOME/.codex/log"
  mkdir -p "$STEEZ_STATE_DIR"
  mkdir -p "$TEST_TMP/mock-bin"
  mkdir -p "$TEST_TMP/tmux-captures"
  mkdir -p "$TEST_TMP/tmux-pane-vars"

  export MOCK_BIN="$TEST_TMP/mock-bin"
  export MOCK_TMUX_PANES_FILE="$TEST_TMP/tmux-panes.tsv"
  export MOCK_TMUX_CAPTURE_DIR="$TEST_TMP/tmux-captures"
  export MOCK_TMUX_PANE_VARS_DIR="$TEST_TMP/tmux-pane-vars"

  touch "$MOCK_TMUX_PANES_FILE"

  # Mock sleep for speed (all timing is irrelevant with mock tmux)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"

  export PATH="$MOCK_BIN:$PATH"
}

cleanup_test_env() {
  [[ -n "${TEST_TMP:-}" ]] && rm -rf "$TEST_TMP"
}

suite() {
  echo ""
  echo "${_DIM}--- $1 ---${_RESET}"
}

# --- Assertions ---

assert_eq() {
  local expected="$1" actual="$2"
  [[ "$expected" == "$actual" ]] && return 0
  echo "    expected: $(printf '%q' "$expected")"
  echo "    actual:   $(printf '%q' "$actual")"
  return 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] && return 0
  echo "    expected to contain: $needle"
  echo "    in: ${haystack:0:200}"
  return 1
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] && return 0
  echo "    should NOT contain: $needle"
  echo "    in: ${haystack:0:200}"
  return 1
}

assert_json_field() {
  local json="$1" field="$2" expected="$3"
  local actual
  actual=$(printf '%s' "$json" | jq -r "$field" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "$expected" "$actual"
}

assert_exit_code() {
  local expected="$1" actual="$2"
  [[ "$expected" == "$actual" ]] && return 0
  echo "    expected exit: $expected"
  echo "    actual exit:   $actual"
  return 1
}

# --- Test runner ---

run_test() {
  local name="$1" func="$2"
  local output
  if output=$("$func" 2>&1); then
    _PASS=$((_PASS + 1))
    printf '  %s✓%s %s\n' "$_GREEN" "$_RESET" "$name"
  else
    _FAIL=$((_FAIL + 1))
    printf '  %s✗%s %s\n' "$_RED" "$_RESET" "$name"
    [[ -n "$output" ]] && printf '%s\n' "$output" | sed 's/^/    /'
  fi
}

report() {
  echo ""
  local total=$((_PASS + _FAIL))
  if [[ $_FAIL -eq 0 ]]; then
    printf '%s%d/%d passed%s\n' "$_GREEN" "$_PASS" "$total" "$_RESET"
  else
    printf '%s%d/%d passed (%d failed)%s\n' "$_RED" "$_PASS" "$total" "$_FAIL" "$_RESET"
  fi
  return $_FAIL
}

# --- Mock helpers ---

create_mock_script() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
$body
MOCK
  chmod +x "$path"
}

create_mock_tmux() {
  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
cmd="$1"; shift
case "$cmd" in
  display-message)
    pane="" fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -t) pane="$2"; shift 2 ;; -p) fmt="$2"; shift 2 ;; *) shift ;; esac
    done
    [[ -z "$pane" || -z "${MOCK_TMUX_PANES_FILE:-}" ]] && exit 1
    line=$(grep -F "${pane}	" "$MOCK_TMUX_PANES_FILE" 2>/dev/null | head -1 || true)
    [[ -z "$line" ]] && exit 1
    IFS=$'\t' read -r _id _pid _title _cwd <<< "$line"
    case "$fmt" in
      '#{pane_id}') echo "$_id" ;;
      '#{pane_pid}') echo "$_pid" ;;
      '#{pane_title}') echo "$_title" ;;
      '#{pane_current_path}') echo "$_cwd" ;;
      '#{session_name}:#{window_index}.#{pane_index}') echo "test:0.0" ;;
      '#{session_name}:#{window_index}') echo "test:0" ;;
      *) echo "" ;;
    esac
    ;;
  list-panes)
    [[ -f "${MOCK_TMUX_PANES_FILE:-}" ]] && cat "$MOCK_TMUX_PANES_FILE"
    ;;
  capture-pane)
    pane=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -t) pane="$2"; shift 2 ;; *) shift ;; esac
    done
    [[ -n "$pane" && -d "${MOCK_TMUX_CAPTURE_DIR:-}" ]] && cat "${MOCK_TMUX_CAPTURE_DIR}/${pane}.txt" 2>/dev/null || true
    ;;
  show-options)
    pane="" var=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -pv) shift ;; -t) pane="$2"; shift 2 ;; @*) var="${1#@}"; shift ;; *) shift ;; esac
    done
    [[ -n "$pane" && -n "$var" && -d "${MOCK_TMUX_PANE_VARS_DIR:-}" ]] || exit 1
    cat "${MOCK_TMUX_PANE_VARS_DIR}/${pane}/${var}.txt" 2>/dev/null || exit 1
    ;;
  send-keys|paste-buffer|delete-buffer|split-window|new-window|new-session)
    ;;
  load-buffer)
    cat > /dev/null 2>/dev/null || true
    ;;
  *)
    ;;
esac
TMUX_MOCK
  chmod +x "$MOCK_BIN/tmux"
}

mock_pane() {
  local pane_id="$1" pane_pid="$2" title="${3:-}" cwd="${4:-/tmp}"
  printf '%s\t%s\t%s\t%s\n' "$pane_id" "$pane_pid" "$title" "$cwd" >> "$MOCK_TMUX_PANES_FILE"
}

mock_pane_content() {
  local pane_id="$1" content="$2"
  printf '%s' "$content" > "$MOCK_TMUX_CAPTURE_DIR/${pane_id}.txt"
}

mock_pane_var() {
  local pane_id="$1" var="$2" value="$3"
  mkdir -p "$MOCK_TMUX_PANE_VARS_DIR/${pane_id}"
  printf '%s' "$value" > "$MOCK_TMUX_PANE_VARS_DIR/${pane_id}/${var}.txt"
}

# Install mock agent scripts at $HOME/.steez/bin/ paths where real scripts expect them
setup_agent_mocks() {
  # Mock agent-state: succeeds for panes in MOCK_AGENT_PANES env
  create_mock_script "$HOME/.steez/bin/agent-state" \
    'PANE="${1:-}"; if [[ "${MOCK_AGENT_PANES:-}" == *"$PANE"* ]] && [[ -n "$PANE" ]]; then echo "{\"pane\":\"$PANE\",\"agent\":\"claude\",\"state\":\"idle\",\"name\":\"test\"}"; exit 0; fi; exit 1'

  # Mock agent-deliver: succeeds for panes in MOCK_AGENT_PANES
  create_mock_script "$HOME/.steez/bin/agent-deliver" \
    '[[ $# -eq 2 ]] || exit 1; PANE="$1"; if [[ "${MOCK_AGENT_PANES:-}" == *"$PANE"* ]] && [[ -n "$PANE" ]]; then exit 0; fi; exit 2'

  # Mock agent-watch: always succeeds
  create_mock_script "$HOME/.steez/bin/agent-watch" \
    'echo "mock-watch-ok"; exit 0'

  # Mock agent-watch-daemon: writes PID and exits
  create_mock_script "$HOME/.steez/bin/agent-watch-daemon" \
    'echo $$ > "${STEEZ_STATE_DIR:-$HOME/.steez/state}/agent-watch-daemon.pid"; sleep 999 &'

  # Mock agent-history: returns empty JSON
  create_mock_script "$HOME/.steez/bin/agent-history" \
    'echo "{}"; exit 0'

  # Mock agent-send: passes through to agent-deliver mock
  create_mock_script "$HOME/.steez/bin/agent-send" \
    'exit 0'

  # Mock agent-eventsd: minimal primary-path stand-in for tests that do
  # not inspect real watch state. `prearm` prints a deterministic fake
  # watch_id so agent-send's --emit-watch-line path and agent-watch add
  # path succeed; every other subcommand exits 0. Tests that need real
  # eventsd semantics install the real binary on top of this mock.
  create_mock_script "$HOME/.steez/bin/agent-eventsd" \
    'case "${1:-}" in prearm) echo "mock-watch-id" ;; *) : ;; esac; exit 0'
}

# Source agent-state functions without running main
source_agent_state() {
  eval "$(grep -vF 'main "$@"' "$BIN_DIR/agent-state")"
}

# Extract a bash function from a script file by name
extract_function() {
  local script="$1" func_name="$2"
  awk "/^${func_name}\\(\\) *\\{/,/^}/" "$script"
}
