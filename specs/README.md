# specs/

Root specifications for steez subsystems. Each spec documents what IS — purpose, interface, behavioral contracts, and integration points. Specs are the source of truth that tests and docs reference.

## Workflow Specs

| Spec | Path | Search Terms |
|------|------|-------------|
| [spec](./spec.md) | `skills/spec/SKILL.md` | planning front door, design spec, software change planning, implementation slices, tdd handoff |
| [tdd](./tdd.md) | `skills/tdd/SKILL.md` | one approved slice, red green refactor loop, verifier, browse, bead evidence |

## Agent Subsystem

The agent subsystem manages AI coding agents (ren, ren-codex, claude, codex) across tmux panes. A long-lived per-user service (`agent-eventsd`) owns watch state; surrounding scripts handle state detection, message delivery, transcript parsing, and orchestrated spawning.

| Spec | Path | Search Terms |
|------|------|-------------|
| [agent-events](./agent-events.md) | `shared/steez/bin/agent-eventsd` | watch service, long-lived daemon, event-driven notifications, PTY tap, pipe-pane, transcript tail, unix socket, fast agent state, primary watch engine |
| [agent-state](./agent-state.md) | `shared/steez/bin/agent-state` | state detection, pane status, agent polling, idle check, working detection, tmux agent status, process tree inspection, transcript parsing |
| [agent-watch](./agent-watch.md) | `shared/steez/bin/agent-watch` | watch registration, completion notification, watchlist, background watch, notification subscribe, eventsd client |
| [agent-send](./agent-send.md) | `shared/steez/bin/agent-send` | send message, prompt delivery, agent messaging, fire-and-forget, auto-watch, tmux send, pane communication |
| [agent-deliver](./agent-deliver.md) | `shared/steez/bin/agent-deliver` | low-level delivery, paste buffer, tmux paste, delayed enter, escape-safe send, raw delivery, binary-safe message |
| [agent-history](./agent-history.md) | `shared/steez/bin/agent-history` | transcript parser, conversation reader, last response, blocked detection, history pairs, JSONL parser, agent output |
| [spawn-agent](./spawn-agent.md) | `skills/spawn-agent/scripts/spawn.sh` + `skills/spawn-agent/SKILL.md` | spawn agent, launch agent, tmux split, new pane, boot wait, directory resolution, multi-agent orchestration, layout |

## Test Specs

| Spec | Path | Search Terms |
|------|------|-------------|
| [fake-agent-harness](./fake-agent-harness.md) | `shared/steez/test/fakes/bin/{claude,codex,ren,ren-codex}` | zero-token fakes, end-to-end runtime tests, fake claude, fake codex, PATH shadow, control fifo, seam, transcript fixture |

## Deprecated Specs

| Spec | Status |
|------|--------|
| [agent-watch-daemon](./agent-watch-daemon.md) | Superseded by `agent-eventsd`. Not on the primary path. |

## Data Flow

```
User intent
  -> spawn-agent SKILL.md (parse intent, choose layout)
    -> spawn.sh (create tmux target, launch agent, boot wait)
      -> agent-send (deliver prompt + wire up watch)
        -> agent-deliver (tmux paste-buffer + delayed Enter)
        -> agent-eventsd prearm / start (client commands into the running service)
              -> agent-eventsd service (long-lived per-user daemon)
                   -> resolves watch from fast evidence or degraded reconciliation
                   -> agent-state (degraded reconciliation only)
                   -> agent-deliver (fire notification on resolved watch)
                   -> agent-history --blocked (extract blocked detail)
```

## Dependency Graph

```
spawn-agent SKILL.md
  -> spawn.sh
       -> agent-send
            -> agent-deliver -> agent-state (validation)
            -> agent-eventsd (client: prearm, start)
                              -> agent-eventsd service (long-lived)
                                   -> agent-state (degraded reconcile)
                                   -> agent-deliver (notify)
                                   -> agent-history (blocked detail)
       -> agent-watch -> agent-state (label inference)
                      -> agent-eventsd (client: prearm, start, remove, list, status)
  -> agent-state (post-spawn check)
  -> agent-history (post-spawn output reading)
```

## Key Architectural Rules

1. **agent-eventsd is a long-lived per-user service.** One process per user owns all watch state and timers. Clients (`agent-send`, `agent-watch`) issue commands against it; they never run watch logic in-process (spec: agent-events — Runtime shape).
2. **agent-eventsd calls agent-deliver, never agent-send.** agent-send auto-registers watches. If the service used agent-send, it would create an infinite notification loop.
3. **Boot readiness is hybrid.** Claude/Ren poll the `@session_id` tmux pane variable (set by SessionStart hook). Codex/Ren-Codex poll the screen for the `›` prompt character (Codex's SessionStart fires on first message, not launch).
4. **State detection is layered.** Sidecar artifact > transcript parsing > screen scraping > title heuristic > prompt detection > default. Higher layers override lower ones.
5. **Watches are one-shot.** Each watch fires at most once, then the entry is removed.
6. **Baseline is hardcoded to `working`.** Observing post-delivery state races with fast agents.
7. **Agent-events verification rules.** New event producers, real-time behaviors, test harnesses, and fallback paths must satisfy the four MUST rules in [agent-events — Verification requirements](./agent-events.md#verification-requirements) (producer presence, latency bounds, harness isolation, fallback companion tests).
