# spawn-agent

**Paths:**
- `skills/spawn-agent/scripts/spawn.sh` (spawn orchestrator)
- `skills/spawn-agent/SKILL.md` (skill definition)

Spawns an AI coding agent in a tmux target. The skill definition (SKILL.md) handles intent parsing and layout orchestration. The script (spawn.sh) handles tmux creation, directory resolution, agent launch, boot wait, and prompt delivery.

## spawn.sh Interface

```
spawn.sh <target-type> [--dir <name-or-path>] [--session <name>] [--prompt <text>] [--target <pane>] [--model <name>] [--no-watch]
```

### Arguments

| Arg | Description |
|-----|-------------|
| `<target-type>` | `split-h`, `split-v`, `new-window`, `new-session` |

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--dir <name-or-path>` | (none) | Working directory for the agent (resolved via tiered strategy) |
| `--session <name>` | `agent-1` | Session name for `new-session` type |
| `--prompt <text>` | (none) | Initial prompt delivered after agent boots |
| `--target <pane>` | `$TMUX_PANE` | For split types: split this pane instead of self |
| `--model <name>` | `ren` | Agent model: `ren`, `ren-codex`, `claude`, `codex` |
| `--no-watch` | false | Skip watch registration on prompt delivery |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (bad args, tmux failure, unknown model) |
| 2 | Ambiguous directory resolution |

## Output Format

Structured key=value lines for model consumption:

```
RESOLVED=/full/path                    # if --dir was resolved (separate line)
METHOD=local                           # resolution method (separate line)
SELF=%0 TARGET=%5                      # stable pane IDs
MODEL=ren                              # agent model
PROMPT_SENT                            # if prompt was delivered
WORKING                                # agent is processing the prompt
IDLE                                   # no prompt provided, agent awaiting input
WATCHED=%5 SPAWNER=%0 BASELINE=working # watch registered (if --emit-watch-line)
```

Error variants:
```
AMBIGUOUS=3 CANDIDATE=/path/one CANDIDATE=/path/two CANDIDATE=/path/three
NOTFOUND=mydir
ERROR: <message>
```

## Directory Resolution

Tiered strategy in `resolve_dir` (tier numbers match code comments):

0. **Literal path:** Starts with `/`, `~`, `./`, `../`. Expand `~` and check existence.
1. **CWD child:** `$PWD/$name` exists as a directory.
2. **Zoxide:** `zoxide query --list "$name"` (frecency-ranked). Takes the first result.
3. **Exact find:** `find $HOME -maxdepth 4 -type d -name "$name"`, ranked by depth. Auto-resolves if exactly 1 match. Reports `AMBIGUOUS` if multiple.
4. **Partial find:** `find $HOME -maxdepth 4 -type d -iname "*${name}*"`, ranked by depth, max 10. Always reports `AMBIGUOUS` (never auto-resolves).

## Tmux Target Creation

| Type | Behavior |
|------|----------|
| `split-h` | Horizontal split of `--target` pane (or self). New pane detected via `comm -13` against pre-split pane list. |
| `split-v` | Vertical split, same detection. |
| `new-window` | Creates a new window in the current session. Target is `tmux display-message -p '#{pane_id}'`. |
| `new-session` | Creates a detached session (`-d`). Pane is the only pane in the session. |

Safety check: if `NEW_TARGET == SELF_ID`, the split failed — exits with error.

## Agent Launch

1. Resolve launch command from model: `ren` -> `ren`, `claude` -> `claude --dangerously-skip-permissions`, `codex` -> `codex --dangerously-bypass-approvals-and-sandbox`.
2. Type the command into the target pane via `tmux send-keys`, then Enter after 300ms.
3. **Boot wait:** Fixed 5-second sleep. Long enough for every supported agent to finish its SessionStart hook in practice; short enough that a dead launch surfaces quickly. Polling `@session_id` or the Codex `›` prompt was considered but adds tmux-version coupling for no real win at the cadence `spawn.sh` actually runs at.
4. If prompt is provided, deliver via `agent-send` with `--spawner $SELF_ID`, `--label "$MODEL <first-40-chars>"`, and `--emit-watch-line` (or `--no-watch` when `--no-watch` was passed to spawn.sh). Without a prompt, emit `IDLE` and return.

## SKILL.md Intent Parsing

The skill definition handles:

### Model selection

- Default: `ren`
- User says "spawn codex" -> `codex`
- User says "spawn claude" -> `claude`
- User says "spawn ren-codex" -> `ren-codex`

### Topology selection

- "beside", "split", "here" -> `split-h`
- "below", "stacked" -> `split-v`
- "new window", "new tab" -> `new-window`
- "new session" -> `new-session`
- No cue -> dynamic layout rules

### Dynamic layout rules (no explicit cue)

- 1 agent: `split-h` from self (50% width)
- 2 agents: `split-h` then `split-v --target A1`
- 3 agents: Add `split-v --target A2` to the 2-agent layout
- 4-6 agents: Two-column layout. `split-h` -> COL1, `split-h --target COL1` -> COL2. Self resized to 33%. Vertical stacking within columns.
- 7+: Ask the user

### Multi-agent chaining

Parse `TARGET=%N` from the previous spawn's output and pass as `--target` in the next call. Without this, splits happen in the spawner's window instead of the new one.

### Prompt format

Heredoc form for complex prompts (backticks, `$vars`, quotes, newlines):

```bash
spawn.sh split-h --prompt "$(cat <<'REN_PROMPT'
Complex prompt content here
REN_PROMPT
)"
```

## Post-Spawn Operations (from SKILL.md)

| Operation | Command |
|-----------|---------|
| Send message | `agent-send %5 "message"` |
| Check state | `agent-state %5` / `agent-state --all` / `agent-state --layout` |
| Read output | `agent-history %5 --last` / `--blocked` / `--history N` |
| Fallback read | `tmux capture-pane -t %5 -p -S -` |

## Dependencies

- `tmux` (pane creation, send-keys, variable polling)
- `agent-send` (prompt delivery + watch registration)
- `agent-state` (post-boot state check)
- `zoxide` (optional, directory resolution tier 3)
- `find` (directory resolution tiers 4-5)

## Integration Points

- **agent-send** is called for prompt delivery (unless `--no-watch`).
- **agent-watch** is auto-registered via `agent-send` after prompt delivery.
- **agent-state** is used for boot-wait and post-spawn state checking.
- **agent-history** is used for post-spawn output reading.
- **SessionStart hook** sets `@session_id` and `@transcript_path` pane variables, which downstream helpers (`agent-state`, `agent-history`) read. `spawn.sh` itself does not poll these — it hands off to `agent-send` after the fixed 5-second boot wait.

## Behavioral Contracts

1. The agent is always launched bare (no inline prompt). Prompts go through `agent-send` after boot wait.
2. Boot readiness is a fixed 5-second sleep between launch and prompt delivery — no per-agent polling.
3. Pane IDs in output are stable `%N` format.
4. `SELF` in output is always the spawner's pane ID, `TARGET` is the new pane.
5. Directory resolution never auto-resolves ambiguous matches — reports candidates for user selection.
6. `--no-watch` suppresses both the watch registration and the `WATCHED=` output line.
7. `claude` and `codex` models launch with permission-bypass flags (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`).
8. Prompt label is explicitly set to `"<model> <first-40-chars-of-prompt>"`, not auto-inferred.

## Error Handling

- Not in tmux: `ERROR: not in a tmux session`, exit 1.
- Unknown model: `ERROR: unknown model`, exit 1.
- Unknown target type: `ERROR: unknown target type`, exit 1.
- Split detection failure (target == self): `ERROR: target equals self`, exit 1.
- Directory not found: `NOTFOUND=<name>`, exit 1.
- Ambiguous directory: `AMBIGUOUS=N` + `CANDIDATE=` lines, exit 2.
- Boot timeout: `WARN:` message (non-fatal, continues).
