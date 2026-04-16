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

eventsd_enable_explicit_service_mode() {
  export EVENTSD_REQUIRE_EXPLICIT_SERVICE=1
}

eventsd_service_pidfile() {
  printf '%s/eventsd/eventsd.pid' "${STEEZ_STATE_DIR:-$HOME/.steez/state}"
}

eventsd_harness_pidfile() {
  printf '%s/eventsd-service.pid' "${STEEZ_STATE_DIR:-$HOME/.steez/state}"
}

eventsd_stop_service() {
  local pidf harness_pidf pid
  pidf=$(eventsd_service_pidfile)
  harness_pidf=$(eventsd_harness_pidfile)
  pid="${EVENTSD_SERVICE_PID:-}"
  if [[ -z "$pid" && -f "$harness_pidf" ]]; then
    pid=$(cat "$harness_pidf" 2>/dev/null || true)
  fi
  if [[ -z "$pid" && -f "$pidf" ]]; then
    pid=$(cat "$pidf" 2>/dev/null || true)
  fi
  if [[ -n "$pid" ]]; then
    kill -KILL "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      /bin/sleep 0.05
    done
  fi
  rm -f "$pidf" "$harness_pidf"
  unset EVENTSD_SERVICE_PID
}

eventsd_start_service() {
  local eventsd_bin="$1" pidf harness_pidf pid i
  eventsd_stop_service
  "$eventsd_bin" serve </dev/null >/dev/null 2>&1 &
  pidf=$(eventsd_service_pidfile)
  harness_pidf=$(eventsd_harness_pidfile)
  for i in $(seq 1 60); do
    if [[ -f "$pidf" ]]; then
      pid=$(cat "$pidf" 2>/dev/null || true)
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        EVENTSD_SERVICE_PID="$pid"
        printf '%s\n' "$pid" > "$harness_pidf"
        return 0
      fi
    fi
    /bin/sleep 0.05
  done
  echo "    eventsd service pidfile never appeared at $pidf" >&2
  return 1
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

# Stateful mock tmux. Pane table lives in MOCK_TMUX_PANES_FILE, one row per
# pane, SOH-delimited (\001) across 7 columns: id, pid, title, cwd, session,
# window, canonical_pane_id. SOH survives empty fields; $'\t' would collapse
# runs of tabs and shift columns whenever a title is empty.
#
# The canonical column is empty for regular panes. mock_pane_alias writes a
# row whose id is a session:window.pane string and whose canonical is the
# %N the alias resolves to — display-message returns canonical for
# #{pane_id} so tests can verify downstream calls use the resolved %N.
#
# Unknown subcommands, unknown flags, unknown format strings, and panes
# absent from the table all fail non-zero so tests cannot pass theatrically.
create_mock_tmux() {
  MOCK_TMUX_VARS_FILE="$TEST_TMP/tmux-vars.tsv"
  MOCK_TMUX_LAYOUT_FILE="$TEST_TMP/tmux-layout.tsv"
  MOCK_TMUX_CAPTURE_DIR="$TEST_TMP/tmux-capture"
  mkdir -p "$MOCK_TMUX_CAPTURE_DIR"
  touch "$MOCK_TMUX_VARS_FILE" "$MOCK_TMUX_LAYOUT_FILE"
  export MOCK_TMUX_VARS_FILE MOCK_TMUX_LAYOUT_FILE MOCK_TMUX_CAPTURE_DIR

  cat > "$MOCK_BIN/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
set -uo pipefail

# Optional call log. When MOCK_TMUX_LOG is set, every tmux invocation
# appends a line with its argv so tests can assert *which* pane was used
# for paste-buffer / send-keys downstream of pane resolution.
[[ -n "${MOCK_TMUX_LOG:-}" ]] && printf '%s\n' "$*" >> "$MOCK_TMUX_LOG"

SEP=$'\001'

_emit_row() {
  # Emit one SOH-delimited 7-column pane row to stdout.
  # args: id pid title cwd session window [canonical]
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$1" "$SEP" "$2" "$SEP" "$3" "$SEP" "$4" "$SEP" \
    "$5" "$SEP" "$6" "$SEP" "${7:-}"
}

_normalize() {
  # Fill in defaults so every downstream reader sees a 7-column row.
  local id pid title cwd session window canon
  IFS="$SEP" read -r id pid title cwd session window canon <<< "$1"
  : "${session:=test}"
  : "${window:=0}"
  _emit_row "$id" "$pid" "$title" "$cwd" "$session" "$window" "${canon:-}"
}

_lookup_by_id() {
  [[ -n "$1" && -f "${MOCK_TMUX_PANES_FILE:-}" ]] || return 1
  local row
  row=$(grep -m1 -F "${1}${SEP}" "$MOCK_TMUX_PANES_FILE") || return 1
  _normalize "$row"
}

_filter_target() {
  # Writes normalized rows matching target (pane_id, session, session:window,
  # or session:window.pane). No match → no output.
  local target="$1"
  [[ -f "${MOCK_TMUX_PANES_FILE:-}" ]] || return 0
  local sess window raw norm id _pid _title _cwd rs rw _canon
  if [[ "$target" == %* ]]; then
    while IFS= read -r raw; do
      [[ -z "$raw" ]] && continue
      norm=$(_normalize "$raw")
      IFS="$SEP" read -r id _pid _title _cwd rs rw _canon <<< "$norm"
      [[ "$id" == "$target" ]] && printf '%s\n' "$norm"
    done < "$MOCK_TMUX_PANES_FILE"
    return 0
  fi
  sess="${target%%:*}"
  window=""
  if [[ "$target" == *:* ]]; then
    local rest="${target#*:}"
    window="${rest%%.*}"
  fi
  while IFS= read -r raw; do
    [[ -z "$raw" ]] && continue
    norm=$(_normalize "$raw")
    IFS="$SEP" read -r id _pid _title _cwd rs rw _canon <<< "$norm"
    [[ "$rs" != "$sess" ]] && continue
    [[ -n "$window" && "$rw" != "$window" ]] && continue
    printf '%s\n' "$norm"
  done < "$MOCK_TMUX_PANES_FILE"
}

_next_id() {
  local counter="${MOCK_TMUX_PANES_FILE}.id"
  local n=100
  [[ -f "$counter" ]] && n=$(cat "$counter")
  printf '%%%s' "$n"
  echo $((n + 1)) > "$counter"
}

_append_pane() {
  # id pid title cwd session window [canonical]
  _emit_row "$@" >> "$MOCK_TMUX_PANES_FILE"
}

_emit_fmt() {
  local id pid title cwd session window canon
  IFS="$SEP" read -r id pid title cwd session window canon <<< "$1"
  local resolved="${canon:-$id}"
  case "$2" in
    '#{pane_id}')                                     printf '%s\n' "$resolved" ;;
    '#{pane_pid}')                                    printf '%s\n' "$pid" ;;
    '#{pane_title}')                                  printf '%s\n' "$title" ;;
    '#{pane_current_path}')                           printf '%s\n' "$cwd" ;;
    '#{session_name}:#{window_index}.#{pane_index}')  printf '%s:%s.0\n' "$session" "$window" ;;
    '#{session_name}:#{window_index}')                printf '%s:%s\n' "$session" "$window" ;;
    '#{pane_id} #{session_name}:#{window_index}')     printf '%s %s:%s\n' "$resolved" "$session" "$window" ;;
    '#{pane_id} #{session_name} #{window_index}')     printf '%s %s %s\n' "$resolved" "$session" "$window" ;;
    *) return 1 ;;
  esac
}

cmd="${1:-}"; shift || true
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
    [[ -n "$pane" ]] || pane="${TMUX_PANE:-}"
    if [[ "$pane" == %* ]]; then
      row=$(_lookup_by_id "$pane") || exit 1
    else
      # session or session:window target — active pane is the most recently
      # created pane under that target (matches real tmux after new-window /
      # new-session / split-window, which promote the new pane to active).
      row=$(_filter_target "$pane" | tail -1)
      [[ -n "$row" ]] || exit 1
    fi
    _emit_fmt "$row" "$fmt" || exit 1
    ;;

  list-panes)
    all=false target="" fmt="#{pane_id}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) all=true; shift ;;
        -t) target="$2"; shift 2 ;;
        -F) fmt="$2"; shift 2 ;;
        *) exit 1 ;;
      esac
    done

    # agent-state --layout: dump pre-seeded layout rows from a separate
    # table. The format is a 10-column geometry record assembled by
    # mock_layout_pane; reusing the pane table would require synthesizing
    # geometry tests don't control.
    if [[ "$fmt" == *'#{pane_left}'* ]]; then
      [[ -s "${MOCK_TMUX_LAYOUT_FILE:-}" ]] && cat "$MOCK_TMUX_LAYOUT_FILE"
      exit 0
    fi

    # agent-state compact format: id<TAB>pid<TAB>title<TAB>cwd. Detected by
    # the pane_current_path field combined with a literal tab separator so
    # the single-field display-message format '#{pane_current_path}' still
    # routes to _emit_fmt below.
    if [[ "$fmt" == *'#{pane_current_path}'* && "$fmt" == *$'\t'* ]]; then
      if $all; then
        [[ -f "$MOCK_TMUX_PANES_FILE" ]] || exit 0
        while IFS= read -r raw; do
          [[ -z "$raw" ]] && continue
          IFS="$SEP" read -r id pid title cwd _s _w canon <<< "$(_normalize "$raw")"
          printf '%s\t%s\t%s\t%s\n' "${canon:-$id}" "$pid" "$title" "$cwd"
        done < "$MOCK_TMUX_PANES_FILE"
        exit 0
      else
        exit 1
      fi
    fi

    # Short composite formats via _emit_fmt (used by spawn.sh).
    if $all; then
      [[ -f "$MOCK_TMUX_PANES_FILE" ]] || exit 0
      while IFS= read -r raw; do
        [[ -z "$raw" ]] && continue
        _emit_fmt "$(_normalize "$raw")" "$fmt" || exit 1
      done < "$MOCK_TMUX_PANES_FILE"
    else
      [[ -n "$target" ]] || exit 1
      _filter_target "$target" | while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        _emit_fmt "$row" "$fmt" || exit 1
      done
    fi
    ;;

  split-window)
    target="" dir=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        -h|-v) dir="$1"; shift ;;
        *) exit 1 ;;
      esac
    done
    [[ -n "$target" && -n "$dir" ]] || exit 1
    row=$(_lookup_by_id "$target") || exit 1
    IFS="$SEP" read -r _id _pid _title cwd session window _canon <<< "$row"
    _append_pane "$(_next_id)" "$$" "" "$cwd" "$session" "$window" ""
    ;;

  new-window)
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *) exit 1 ;;
      esac
    done
    [[ -n "$target" ]] || exit 1
    session="${target%%:*}"
    # Next window index = max existing window in session + 1.
    max_w=""
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      IFS="$SEP" read -r _ _ _ _ _ rw _canon <<< "$row"
      if [[ -z "$max_w" || "$rw" -gt "$max_w" ]]; then max_w="$rw"; fi
    done < <(_filter_target "$session")
    [[ -n "$max_w" ]] || { echo "no such session: $session" >&2; exit 1; }
    _append_pane "$(_next_id)" "$$" "" "/tmp" "$session" "$((max_w + 1))" ""
    ;;

  new-session)
    sname=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d) shift ;;
        -s) sname="$2"; shift 2 ;;
        *) exit 1 ;;
      esac
    done
    [[ -n "$sname" ]] || exit 1
    if _filter_target "$sname" | grep -q .; then
      echo "duplicate session: $sname" >&2
      exit 1
    fi
    _append_pane "$(_next_id)" "$$" "" "/tmp" "$sname" "0" ""
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
    _lookup_by_id "$pane" >/dev/null || exit 1
    ;;

  load-buffer)
    # real tmux reads the buffer body from `-` via stdin; drain to avoid SIGPIPE
    cat >/dev/null
    ;;

  delete-buffer)
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

# Append a SOH-delimited 7-column pane row to the pane table. Shared by
# mock_pane and mock_pane_alias so the storage format stays single-sourced.
_append_pane_row() {
  local sep=$'\001'
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$1" "$sep" "$2" "$sep" "$3" "$sep" "$4" "$sep" \
    "$5" "$sep" "$6" "$sep" "${7:-}" \
    >> "$MOCK_TMUX_PANES_FILE"
}

# Register a mock pane. session and window default to test/0 so existing
# tests that don't care about placement keep working.
mock_pane() {
  local pane_id="$1" pane_pid="$2" title="${3:-}" cwd="${4:-/tmp}"
  local session="${5:-test}" window="${6:-0}"
  _append_pane_row "$pane_id" "$pane_pid" "$title" "$cwd" "$session" "$window" ""
}

# Register a pane alias (e.g., "session:0.1") that resolves to a canonical
# %N via `tmux display-message -p '#{pane_id}'`. Used to verify downstream
# tmux calls target the resolved %N, not the raw alias the caller passed.
#
# Session and window are derived from the alias so `display-message -t alias`
# routes through _filter_target to this row. Canonical is stored in the
# 7th column; _emit_fmt returns it for #{pane_id} when present.
mock_pane_alias() {
  local alias="$1" canonical="$2"
  local session="${alias%%:*}" window="0"
  if [[ "$alias" == *:* ]]; then
    local rest="${alias#*:}"
    window="${rest%%.*}"
  fi
  _append_pane_row "$alias" "0" "alias" "/tmp" "$session" "$window" "$canonical"
}

# Read one column (1=id, 2=pid, 3=title, 4=cwd, 5=session, 6=window,
# 7=canonical) from the mock pane-table row for `pane_id`. Exits 1 if no
# such pane. Tests use this instead of grepping the file directly so they
# stay agnostic of the storage format (currently SOH-delimited rows).
pane_attr() {
  local pane_id="$1" col="$2"
  local sep=$'\001'
  local row
  row=$(grep -m1 -F "${pane_id}${sep}" "$MOCK_TMUX_PANES_FILE") || return 1
  awk -F"${sep}" -v n="$col" '{print $n}' <<< "$row"
}

# Does any row in the mock pane table have this session name? Exits 0/1.
pane_has_session() {
  local session="$1"
  local sep=$'\001'
  awk -F"${sep}" -v s="$session" '$5==s {found=1; exit} END{exit !found}' \
    "$MOCK_TMUX_PANES_FILE"
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
