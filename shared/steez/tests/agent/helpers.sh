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
  MOCK_TMUX_VARS_FILE="$TEST_TMP/tmux-vars.tsv"
  MOCK_TMUX_LAYOUT_FILE="$TEST_TMP/tmux-layout.tsv"
  MOCK_TMUX_CAPTURE_DIR="$TEST_TMP/tmux-capture"
  mkdir -p "$MOCK_TMUX_CAPTURE_DIR"
  touch "$MOCK_TMUX_VARS_FILE" "$MOCK_TMUX_LAYOUT_FILE"
  export MOCK_TMUX_VARS_FILE MOCK_TMUX_LAYOUT_FILE MOCK_TMUX_CAPTURE_DIR

  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
# Optional call log. When MOCK_TMUX_LOG is set, every tmux invocation
# appends a line with its argv so tests can assert *which* pane was used
# for paste-buffer / send-keys downstream of pane resolution.
[[ -n "${MOCK_TMUX_LOG:-}" ]] && printf '%s\n' "$*" >> "$MOCK_TMUX_LOG"

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
    # Rows written by mock_pane_alias carry a 5th field: the canonical
    # pane id that the alias resolves to. When present, '#{pane_id}'
    # returns it so callers get a stable %N downstream of resolution.
    IFS=$'\t' read -r _id _pid _title _cwd _canon <<< "$line"
    case "$fmt" in
      '#{pane_id}') echo "${_canon:-$_id}" ;;
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
  list-panes)
    # Supports `-a -F <fmt>`. Format selection by substring — agent-state calls
    # this with two distinct formats (geometry-bearing for --layout, compact
    # for --all). Unknown formats are rejected so drift surfaces.
    all=false fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) all=true; shift ;;
        -F) fmt="$2"; shift 2 ;;
        *) exit 1 ;;
      esac
    done
    [[ "$all" == "true" ]] || exit 1
    case "$fmt" in
      *'#{pane_left}'*)
        [[ -s "${MOCK_TMUX_LAYOUT_FILE:-}" ]] && cat "$MOCK_TMUX_LAYOUT_FILE"
        ;;
      *'#{pane_current_path}'*)
        cat "${MOCK_TMUX_PANES_FILE:-/dev/null}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  show-options)
    # Usage: show-options -pv -t <pane> <var>. -pv or split -p -v both work.
    # Missing option returns exit 1 with empty stdout (real tmux behavior).
    pane="" var=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p|-v|-pv|-vp) shift ;;
        -t) pane="$2"; shift 2 ;;
        *) var="$1"; shift ;;
      esac
    done
    [[ -n "$pane" && -n "$var" ]] || exit 1
    awk -v p="$pane" -v v="$var" -F $'\t' \
      '$1==p && $2==v { print $3; found=1; exit } END { exit (found ? 0 : 1) }' \
      "${MOCK_TMUX_VARS_FILE:-/dev/null}"
    ;;
  capture-pane)
    # Usage: capture-pane -t <pane> -p [-S -]. Returns content from
    # $MOCK_TMUX_CAPTURE_DIR/<pane> or empty if unset.
    pane=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) pane="$2"; shift 2 ;;
        -p) shift ;;
        -S) shift 2 ;;
        *) exit 1 ;;
      esac
    done
    [[ -n "$pane" ]] || exit 1
    if [[ -f "${MOCK_TMUX_CAPTURE_DIR:-}/$pane" ]]; then
      cat "${MOCK_TMUX_CAPTURE_DIR}/$pane"
    fi
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

# Register a pane alias (e.g., "session:0.0") that resolves to a canonical
# %N via `tmux display-message -p '#{pane_id}'`. Used to verify downstream
# tmux calls target the resolved %N, not the raw alias the caller passed.
#
# Fields must all be non-empty: IFS=$'\t' in the mock's `read` treats tab
# as IFS whitespace and collapses runs of tabs into a single delimiter, so
# empty middle fields would shift _canon into an earlier slot.
mock_pane_alias() {
  local alias="$1" canonical="$2"
  printf '%s\t0\talias\t/tmp\t%s\n' "$alias" "$canonical" >> "$MOCK_TMUX_PANES_FILE"
}

# Append a row to the 10-field pane layout table consumed by `agent-state --layout`.
mock_layout_pane() {
  local session="$1" win_idx="$2" win_name="$3" pane_id="$4"
  local left="$5" top="$6" width="$7" height="$8"
  local pane_pid="$9" pane_title="${10}"
  : "${MOCK_TMUX_LAYOUT_FILE:?call create_mock_tmux before mock_layout_pane}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session" "$win_idx" "$win_name" "$pane_id" \
    "$left" "$top" "$width" "$height" "$pane_pid" "$pane_title" \
    >> "$MOCK_TMUX_LAYOUT_FILE"
}

# Register a tmux pane variable readable via `tmux show-options -pv -t <pane> <var>`.
set_mock_tmux_var() {
  local pane="$1" var="$2" value="$3"
  : "${MOCK_TMUX_VARS_FILE:?call create_mock_tmux before set_mock_tmux_var}"
  printf '%s\t%s\t%s\n' "$pane" "$var" "$value" >> "$MOCK_TMUX_VARS_FILE"
}

# Register pane scrollback content returned by `tmux capture-pane -t <pane>`.
set_mock_tmux_capture() {
  local pane="$1" content="$2"
  : "${MOCK_TMUX_CAPTURE_DIR:?call create_mock_tmux before set_mock_tmux_capture}"
  printf '%s\n' "$content" > "$MOCK_TMUX_CAPTURE_DIR/$pane"
}

# Mock `ps` for agent-state's process-tree walking. MOCK_PS_OUTPUT supplies the
# process table for `-eo pid,ppid,command`. MOCK_PS_REN_PIDS (space-separated)
# marks pids that should be reported with REN_SESSION=1 under `-E -p <pid>`.
create_mock_ps() {
  cat > "$MOCK_BIN/ps" <<'PS_MOCK'
#!/usr/bin/env bash
mode="" pid=""
for a in "$@"; do
  case "$a" in
    -eo) mode="eo" ;;
    -E) mode="E" ;;
    -p) [[ "$mode" == "E" ]] && mode="Ep" ;;
    pid,ppid,command) ;;
    [0-9]*) pid="$a" ;;
    *) echo "mock ps: unsupported arg: $a" >&2; exit 1 ;;
  esac
done
case "$mode" in
  eo) printf '%s\n' "${MOCK_PS_OUTPUT:-}" ;;
  Ep)
    if [[ " ${MOCK_PS_REN_PIDS:-} " == *" $pid "* ]]; then
      echo "REN_SESSION=1"
    fi
    ;;
  *) echo "mock ps: unsupported invocation" >&2; exit 1 ;;
esac
PS_MOCK
  chmod +x "$MOCK_BIN/ps"
}

# Install mock agent scripts at $HOME/.steez/bin/ paths where real scripts
# expect them. Only the scripts actually invoked during the test suite
# (agent-state, agent-deliver) are stubbed. Each mock rejects inputs the
# real script rejects, so fidelity bugs cannot hide behind unconditional
# success.
#
# Optional args let callers reconfigure the agent-state response without
# hand-rolling a duplicate mock. The error-handling gate (missing pane,
# not-in-allowlist) stays intact so fidelity drifts don't sneak in.
setup_agent_mocks() {
  local agent="${1:-claude}" state="${2:-idle}"

  # MOCK_AGENT_PANES is a whitespace-separated allow-list. Pad-then-match so
  # `%1` doesn't substring-match inside `%10` and so empty PANE can't match
  # anywhere.
  create_mock_script "$HOME/.steez/bin/agent-state" \
    '[[ $# -ge 1 && -n "$1" ]] || { echo "error: specify a pane target or use --all" >&2; exit 1; }
     PANE="$1"
     if [[ " ${MOCK_AGENT_PANES:-} " == *" $PANE "* ]]; then
       printf "{\"pane\":\"%s\",\"agent\":\"'"$agent"'\",\"state\":\"'"$state"'\",\"name\":\"test\"}\n" "$PANE"
       exit 0
     fi
     echo "error: pane '\''$PANE'\'' is not a recognized AI agent" >&2
     exit 1'

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

# Install a mock that records every invocation's argv to a log file, one
# line per call. Used by tests that need to assert on forwarded arguments
# without caring about the callee's return behavior.
record_mock_script() {
  local path="$1" logfile="$2"
  create_mock_script "$path" "printf '%s\n' \"\$*\" >> '$logfile'; exit 0"
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
