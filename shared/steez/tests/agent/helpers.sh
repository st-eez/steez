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

  export MOCK_BIN="$TEST_TMP/mock-bin"
  export MOCK_TMUX_PANES_FILE="$TEST_TMP/tmux-panes.tsv"

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
#
# Assertions exit the current subshell on failure. Tests run inside a `$()`
# subshell (see run_test), so `exit 1` kills only the test body, not the
# whole file. This is the only reliable way to make a failed assertion
# unmaskable — bash's errexit is silently disabled when a function is called
# via `if`, `||`, or command substitution that ends up in such a context, so
# `return 1` can be swallowed by any trailing command that succeeds.

assert_eq() {
  local expected="$1" actual="$2"
  [[ "$expected" == "$actual" ]] && return 0
  echo "    expected: $(printf '%q' "$expected")"
  echo "    actual:   $(printf '%q' "$actual")"
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] && return 0
  echo "    expected to contain: $needle"
  echo "    in: ${haystack:0:200}"
  exit 1
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] && return 0
  echo "    should NOT contain: $needle"
  echo "    in: ${haystack:0:200}"
  exit 1
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
  exit 1
}

# --- Test runner ---

run_test() {
  local name="$1" func="$2"
  local output rc=0
  output=$("$func" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
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

# Mock tmux. Handles only the subcommands the test suite exercises
# (display-message, load-buffer, paste-buffer, send-keys, delete-buffer).
# Unknown subcommands, unknown flags, unknown format strings, and panes
# absent from MOCK_TMUX_PANES_FILE all fail non-zero, so tests cannot pass
# theatrically on a tmux call that real tmux would reject.
create_mock_tmux() {
  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
_lookup_pane() {
  # stdout: tab-separated pane row, exit 1 if absent
  [[ -n "$1" && -f "${MOCK_TMUX_PANES_FILE:-}" ]] || return 1
  local line
  line=$(grep -m1 -F "${1}"$'\t' "$MOCK_TMUX_PANES_FILE") || return 1
  printf '%s' "$line"
}

cmd="$1"; shift
case "$cmd" in
  display-message)
    pane="" fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) pane="$2"; shift 2 ;;
        -p) fmt="$2"; shift 2 ;;
        *) exit 1 ;;
      esac
    done
    line=$(_lookup_pane "$pane") || exit 1
    IFS=$'\t' read -r _id _pid _title _cwd <<< "$line"
    case "$fmt" in
      '#{pane_id}') echo "$_id" ;;
      '#{pane_pid}') echo "$_pid" ;;
      '#{pane_title}') echo "$_title" ;;
      '#{pane_current_path}') echo "$_cwd" ;;
      '#{session_name}:#{window_index}.#{pane_index}') echo "test:0.0" ;;
      '#{session_name}:#{window_index}') echo "test:0" ;;
      *) exit 1 ;;
    esac
    ;;
  send-keys|paste-buffer)
    # Every known flag to send-keys / paste-buffer the tests use takes an
    # argument; the positional tail is the key stream. We only validate the
    # pane target — extra flags would just shift, but an explicit unknown
    # short flag is rejected to stay consistent with display-message strictness.
    pane=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) pane="$2"; shift 2 ;;
        -b|-d) shift ;;
        -*) exit 1 ;;
        *) shift ;;
      esac
    done
    _lookup_pane "$pane" >/dev/null || exit 1
    ;;
  load-buffer)
    # real tmux reads the buffer body from `-` via stdin; drain to avoid SIGPIPE
    cat >/dev/null
    ;;
  delete-buffer)
    ;;
  *)
    exit 1
    ;;
esac
TMUX_MOCK
  chmod +x "$MOCK_BIN/tmux"
}

mock_pane() {
  local pane_id="$1" pane_pid="$2" title="${3:-}" cwd="${4:-/tmp}"
  printf '%s\t%s\t%s\t%s\n' "$pane_id" "$pane_pid" "$title" "$cwd" >> "$MOCK_TMUX_PANES_FILE"
}

# Install mock agent scripts at $HOME/.steez/bin/ paths where real scripts
# expect them. Only the scripts actually invoked during the test suite
# (agent-state, agent-deliver) are stubbed. Each mock rejects inputs the
# real script rejects, so fidelity bugs cannot hide behind unconditional
# success.
setup_agent_mocks() {
  # MOCK_AGENT_PANES is a whitespace-separated allow-list. Pad-then-match so
  # `%1` doesn't substring-match inside `%10` and so empty PANE can't match
  # anywhere.

  # Matches real agent-state: missing pane → exit 1 with error on stderr.
  create_mock_script "$HOME/.steez/bin/agent-state" \
    '[[ $# -ge 1 && -n "$1" ]] || { echo "error: specify a pane target or use --all" >&2; exit 1; }
     PANE="$1"
     if [[ " ${MOCK_AGENT_PANES:-} " == *" $PANE "* ]]; then
       printf "{\"pane\":\"%s\",\"agent\":\"claude\",\"state\":\"idle\",\"name\":\"test\"}\n" "$PANE"
       exit 0
     fi
     echo "error: pane '\''$PANE'\'' is not a recognized AI agent" >&2
     exit 1'

  # Matches real agent-deliver: wrong arg count → 1; empty message → 1; non-agent pane → 2.
  create_mock_script "$HOME/.steez/bin/agent-deliver" \
    '[[ $# -eq 2 ]] || { echo "error: usage: agent-deliver <pane> \"message\"" >&2; exit 1; }
     PANE="$1" MSG="$2"
     [[ -n "$MSG" ]] || { echo "error: message body is empty" >&2; exit 1; }
     if [[ " ${MOCK_AGENT_PANES:-} " == *" $PANE "* ]]; then exit 0; fi
     echo "error: pane '\''$PANE'\'' is not a recognized AI agent" >&2
     exit 2'

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
