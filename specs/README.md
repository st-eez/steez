# specs/

Root specifications for steez subsystems. Each spec documents what IS — purpose, interface, behavioral contracts, and integration points. Specs are the source of truth that tests and docs reference.

## Agent Subsystem

The agent subsystem manages AI coding agents (ren, ren-codex, claude, codex) across tmux panes. Six scripts handle state detection, message delivery, completion watching, transcript parsing, and orchestrated spawning.

| Spec | Path | Search Terms |
|------|------|-------------|
| [agent-state](./agent-state.md) | `shared/steez/bin/agent-state` | state detection, pane status, agent polling, idle check, working detection, tmux agent status, process tree inspection, transcript parsing |
| [agent-watch](./agent-watch.md) | `shared/steez/bin/agent-watch` | watch registration, completion notification, daemon management, watchlist, background watch, notification subscribe, launchd agent |
| [agent-watch-daemon](./agent-watch-daemon.md) | `shared/steez/bin/agent-watch-daemon` | background daemon, poll loop, state transition, one-shot notification, singleton process, idle notification, completion watcher |
| [agent-send](./agent-send.md) | `shared/steez/bin/agent-send` | send message, prompt delivery, agent messaging, fire-and-forget, auto-watch, tmux send, pane communication |
| [agent-deliver](./agent-deliver.md) | `shared/steez/bin/agent-deliver` | low-level delivery, paste buffer, tmux paste, delayed enter, escape-safe send, raw delivery, binary-safe message |
| [agent-history](./agent-history.md) | `shared/steez/bin/agent-history` | transcript parser, conversation reader, last response, blocked detection, history pairs, JSONL parser, agent output |
| [spawn-agent](./spawn-agent.md) | `skills/spawn-agent/scripts/spawn.sh` + `skills/spawn-agent/SKILL.md` | spawn agent, launch agent, tmux split, new pane, boot wait, directory resolution, multi-agent orchestration, layout |

## Proposed Specs

| Spec | Path | Search Terms |
|------|------|-------------|
| [agent-events](./agent-events.md) | `shared/steez/bin/agent-eventsd` | event-driven notifications, PTY tap, pipe-pane, transcript tail, unix socket, fast agent state, near-instant watch service |

## Data Flow

```
User intent
  -> spawn-agent SKILL.md (parse intent, choose layout)
    -> spawn.sh (create tmux target, launch agent, boot wait)
      -> agent-send (deliver prompt + register watch)
        -> agent-deliver (tmux paste-buffer + delayed Enter)
        -> agent-watch add (register one-shot watch)
          -> agent-watch-daemon (poll loop)
            -> agent-state (detect state per cycle)
            -> agent-deliver (fire notification on transition)
            -> agent-history --blocked (extract blocked detail)
```

## Dependency Graph

```
spawn-agent SKILL.md
  -> spawn.sh
       -> agent-send
            -> agent-deliver -> agent-state (validation)
            -> agent-watch   -> agent-state (label inference)
                             -> agent-watch-daemon
                                  -> agent-state (poll)
                                  -> agent-deliver (notify)
                                  -> agent-history (blocked detail)
  -> agent-state (post-spawn check)
  -> agent-history (post-spawn output reading)
```

## Key Architectural Rules

1. **agent-watch-daemon calls agent-deliver, never agent-send.** agent-send auto-registers watches. If the daemon used agent-send, it would create an infinite notification loop.
2. **Boot readiness is hybrid.** Claude/Ren poll the `@session_id` tmux pane variable (set by SessionStart hook). Codex/Ren-Codex poll the screen for the `›` prompt character (Codex's SessionStart fires on first message, not launch).
3. **State detection is layered.** Sidecar artifact > transcript parsing > screen scraping > title heuristic > prompt detection > default. Higher layers override lower ones.
4. **Watches are one-shot.** Each watch fires at most once, then the entry is removed.
5. **Baseline is hardcoded to `working`.** Observing post-delivery state races with fast agents.
