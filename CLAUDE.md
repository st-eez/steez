# steez — Claude Code Skill Installer

## Conventions

- When adding a new skill, also add its entry to `skills.json` (name, category, description max 80 chars)
- When behavior changes, update the matching spec in `specs/` in the same commit. If no spec exists for the thing you are changing, create one — specs are the source of truth and cannot drift.
- Use conventional commits: `feat:` | `fix:` | `refactor:` | `docs:` | `chore:`
- Use absolute paths (`$HOME`, `__dirname`, `__file__`) — never relative
- Never hardcode PII or env-specific values — resolve from config at runtime

## Architecture

- `cmd/steez/` — CLI entrypoint
- `internal/tui/` — Bubble Tea TUI setup flow
- `internal/installer/` — Symlink management, manifest parsing
- `internal/updater/` — Git-based update logic
- `internal/config/` — Config loading (`~/.steez/installed.json`)
- `skills/` — Skill directories (each contains SKILL.md + skill files)
- `skills.json` — Manifest of all skills, categories, and profiles
- `shared/steez/` — Shared runtime (bin scripts, browse binary)

## Commands

```bash
# Browse binary
cd shared/steez/browse
bun install                # install dependencies (playwright, diff)
bun run build              # compile browse binary + node server
bun run test               # run all tests except e2e
bun run test:core          # run core browser tests only
bun run test:ns            # run NetSuite automation tests only
bun run dev <cmd>          # run CLI in dev mode (no compile step)

# Go CLI
make build                 # build binary locally
make install               # install to ~/go/bin/steez
make clean                 # remove local binary

# Helper scripts (shared/steez/bin/)
config get <key>                 # read config value
config set <key> <value>         # write config value
slug                             # git remote → owner-repo slug
diff-scope                       # categorize diff as frontend/backend/prompts/tests/docs/config
review-log                       # append JSON review entry to project log
review-read                      # read review log + config for Review Readiness Dashboard
steez-bd resume                  # session brief: current bead, suggested skill, ready work
steez-bd start <id> [skill]      # claim bead + optional skill tag
steez-bd emit-finding <id> "t"   # create linked finding bead
steez-bd handoff <id> "s" [--close]  # append note + optional close
# Agent subsystem: agent-state, agent-send, agent-history, agent-watch, agent-watch-daemon, agent-deliver — see specs/README.md
upstream-diff <skill>            # diff a steez skill against gstack upstream
upstream-diff --all              # show divergence summary for all skills
```

`bun run test` runs before every commit to browse source. Both core and NS tests
start local HTTP servers with fixture HTML — no external dependencies, no
network calls, no credentials.

## Project Structure

```
steez/                                    # repo root
├── shared/steez/                         # shared runtime
│   ├── bin/                              # 13 bash helper scripts
│   │   ├── config                        # read/write ~/.steez/config
│   │   ├── slug                          # git remote → owner-repo slug
│   │   ├── diff-scope                    # categorize diff scopes
│   │   ├── review-log                    # append review entries
│   │   ├── review-read                   # read review log + config
│   │   ├── steez-bd                      # beads integration (keeps prefix)
│   │   ├── agent-*                       # agent subsystem (6 scripts, see specs/README.md)
│   │   └── upstream-diff                 # diff skill against gstack upstream
│   ├── browse/                           # headless browser (Playwright + Chromium)
│   │   ├── src/
│   │   │   ├── core/                     # CLI + server + commands (~3,800 lines)
│   │   │   ├── ns/                       # NetSuite ERP automation (~2,100 lines)
│   │   │   └── playwright/               # extensions (routing, tracing, video)
│   │   ├── bin/                          # remote-slug helper
│   │   ├── scripts/                      # build-node-server.sh (Windows compat layer)
│   │   ├── dist/                         # compiled binaries (gitignored)
│   │   └── package.json                  # scripts: build, test, dev
│   ├── hooks/                             # Claude Code + Codex hooks (symlinked by installer)
│   │   ├── skill-analytics.sh            # PostToolUse hook for skill usage tracking
│   │   ├── session-start.sh              # Claude SessionStart hook (tmux pane vars)
│   │   └── codex-session-start.sh        # Codex SessionStart hook (tmux pane vars)
│   └── package.json                      # ecosystem tests
├── skills/                               # skill directories
│   ├── browse/SKILL.md                   # browse skill definition
│   └── {name}/SKILL.md                   # 22 workflow skills
├── cmd/steez/                            # Go CLI entrypoint
├── internal/                             # Go packages
├── specs/                                # subsystem contracts (source of truth)
├── ETHOS.md                              # builder philosophy
├── ARCHITECTURE.md                       # design decisions + data flow
├── FORK_MANIFEST.md                      # upstream gstack provenance
└── CLAUDE.md                             # this file
```

### Runtime (`~/.steez/`)

```
~/.steez/
├── repo -> <user's checkout>             # installer-managed symlink
├── bin/                                  # installer-managed symlinks
│   ├── config -> ~/.steez/repo/shared/steez/bin/config
│   ├── slug -> ~/.steez/repo/shared/steez/bin/slug
│   ├── diff-scope -> ~/.steez/repo/shared/steez/bin/diff-scope
│   ├── review-log -> ~/.steez/repo/shared/steez/bin/review-log
│   ├── review-read -> ~/.steez/repo/shared/steez/bin/review-read
│   ├── steez-bd -> ~/.steez/repo/shared/steez/bin/steez-bd
│   ├── agent-state -> ~/.steez/repo/shared/steez/bin/agent-state
│   ├── agent-send -> ~/.steez/repo/shared/steez/bin/agent-send
│   ├── agent-deliver -> ~/.steez/repo/shared/steez/bin/agent-deliver
│   ├── agent-watch -> ~/.steez/repo/shared/steez/bin/agent-watch
│   ├── agent-watch-daemon -> ~/.steez/repo/shared/steez/bin/agent-watch-daemon
│   ├── agent-history -> ~/.steez/repo/shared/steez/bin/agent-history
│   └── browse -> ~/.steez/repo/shared/steez/browse/dist/browse
├── config                                # key-value config (proactive: true)
├── analytics/
│   ├── skill-usage.jsonl                 # skill invocations (written by PostToolUse hook)
│   └── spec-review.jsonl                 # spec/review analytics
├── projects/{slug}/
│   ├── {branch}-reviews.jsonl            # review logs per branch
│   └── *-design-*.md                     # design docs from /office-hours
└── browse/
    ├── chromium-profile/                 # persistent Chromium state (login sessions, cache)
    └── sidebar-sessions/                 # sidebar daemon sessions
```

## Upstream Relationship

steez is a fork of gstack. Skills are owned directly in `skills/`. To check what
gstack has changed upstream: `upstream-diff <skill>` or `--all` for a summary.
The gstack repo is at `~/Projects/Personal/gstack`. Cherry-pick improvements manually.

## Install Model

Skills are installed as symlinks: `~/.claude/skills/{name}` -> `repo/skills/{name}/`
Shared runtime is accessed via installer-managed symlinks under `~/.steez/bin/` and `~/.steez/repo`.
Install registry lives at `~/.steez/installed.json`.
Updates are live mutation: `git pull` in-place, symlinks already point at checkout.

## SKILL.md Workflow

Each bash code block in a SKILL.md runs in a separate shell — variables don't
persist between blocks. Use prose to carry state ("the base branch detected
in Step 0"), not shell variables. Express conditionals as numbered English
steps, not nested `if/elif/else`. Don't hardcode branch names — detect
dynamically via `gh pr view` or `gh repo view`.

Skill analytics are tracked via a PostToolUse hook (`shared/steez/hooks/skill-analytics.sh`),
not inline telemetry. The hook fires mechanically on every Skill tool invocation and writes to
`~/.steez/analytics/skill-usage.jsonl`.

Executables use hardcoded paths: `~/.steez/bin/config`, `~/.steez/bin/browse`.
Documents use repo symlink: `~/.steez/repo/ETHOS.md`.

## Compiled Binaries

`shared/steez/browse/dist/` contains compiled Bun binaries (~57MB each, Mach-O arm64).
These are gitignored but present on disk after `bun run build`.

**Rebuild after changing browse source:**
```bash
cd shared/steez/browse && bun run build
```

The binaries only work on macOS arm64. The `server-node.mjs` fallback
provides Windows/Node.js compatibility.

## Browser Interaction

When you need to interact with a browser (QA, dogfooding, cookie setup), use
the `/browse` skill or run the browse binary directly via `$B <command>`.

Skills resolve `$B` with:
```bash
B=~/.steez/bin/browse
```

## Editing Skills

Each bash code block in a SKILL.md runs in a separate shell — variables don't
persist between blocks. Use prose to carry state, not shell variables.

## Helper Script Dependencies

```
slug ← review-log (needs SLUG for file path)
     ← review-read (needs SLUG for file path)

config ← review-read (reads skip_eng_review)

diff-scope — standalone, no dependencies

steez-bd ← office-hours (chain creation after design doc approved)
         ← plan-ceo-review (handoff at completion)
         ← plan-eng-review (handoff at completion)
         ← ship (handoff at completion, emit-finding for issues)
  Depends on: bd CLI (beads), jq (macOS system binary)

```

## Search Before Building

Before designing any solution that involves concurrency, unfamiliar patterns,
infrastructure, or anything where the runtime/framework might have a built-in:

1. Search for "{runtime} {thing} built-in"
2. Search for "{thing} best practice {current year}"
3. Check official runtime/framework docs

Three layers of knowledge: tried-and-true (Layer 1), new-and-popular (Layer 2),
first-principles (Layer 3). Prize Layer 3 above all. See ETHOS.md for the full
builder philosophy.

## Commit Style

Use conventional commits: `feat:` | `fix:` | `refactor:` | `docs:` | `chore:`

Prefer one commit per logical change. When you've made multiple changes
(e.g., a bug fix + a branding removal + a new skill), split them into
separate commits. Each commit should be independently understandable.

## Design References

- Design doc: `~/.steez/projects/st-eez-dotfiles/stevedimakos-main-design-20260330-204342.md`
- Plan file: `~/.claude/plans/nifty-puzzling-pancake.md`
- Test plan: `~/.steez/projects/st-eez-dotfiles/stevedimakos-main-eng-review-test-plan-20260330-222500.md`
