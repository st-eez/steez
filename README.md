# steez

Your AI agent is only as good as the instructions you give it. steez turns Claude Code into a 21-specialist engineering team — thinking partners, planners, reviewers, testers, security auditors, and orchestrators — all living in your dotfiles, deployed with a single `steez install` command, zero external dependencies.

Forked from [gstack](https://github.com/garrytan/gstack) (v0.13.0.0), stripped to the studs, and rebuilt for a solo operator who wants the full sprint pipeline without the team overhead.

## See it work

```
You:    I want to add OAuth login to my side project.
You:    /spec

Claude: Before you build anything — is this actually the
        right problem, what does the carry cost look like,
        and what is the smallest useful slice? [writes
        plans/<bead>-oauth-login-design-spec.md]
        [asks one load-bearing question]
        [locks the implementation slices]

You:    Approve plan. Build it.
        [writes 1,800 lines across 9 files]

You:    /steez-qa https://localhost:3000
        [opens real browser, tests login flow, finds
        redirect bug, fixes it, re-verifies]

You:    /cso
        [OWASP Top 10 + STRIDE threat model. Catches JWT
        token storage in localStorage → moves to httpOnly cookie]

You:    /codex review
        [OpenAI Codex second opinion. Flags one edge case
        in token refresh, fixed.]

        All green. Ready to merge.
```

You said "OAuth login." `/spec` turned that into an execution contract before code existed. The plan got pressure-tested, sliced, and written down in-repo. Then the rest of the sprint could execute against something concrete.

## The sprint

steez is a process, not a toolbox. The skills run in the order a sprint runs:

**Think → Plan → Build → Test → Review**

`/spec` is the planning front door for software changes. It writes the design spec the build step executes against. `/steez-qa`, `/codex review`, and `/cso` are still the downstream safety net before merge.

The old planning stack still ships in the repo for explicit install by name, but it is deprecated and no longer part of the built-in install profiles.

| Skill | Your specialist | What they do |
|-------|----------------|--------------|
| `/spec` | **Planner** | The front door for planned software changes. Pressure-tests the ask, writes a repo-local design spec, and stops when implementation can run slice by slice without reconstructing the conversation. |
| `/agenda` | **Morning Planner** | Structured morning triage. Overdue tasks, inbox, daily slate — the ritual that turns a pile of open loops into a day's work. |
| `/jira` | **Jira Operator** | Manage Jira tickets — search, create, update, transition, log time. |
| `/browse` | **Browser Operator** | Headless browser (Playwright + Chromium). Real clicks, real screenshots, ~100ms per command. Persistent sessions — log in once, stay logged in. |
| `/steez-qa` | **QA Lead** | Test your app in a real browser, find bugs, fix them with atomic commits, re-verify. Generates regression tests for every fix. |
| `/steez-qa-only` | **QA Reporter** | Same methodology as `/steez-qa` but report only. Pure bug report, no code changes. |
| `/design-review` | **Designer Who Codes** | Visual audit — spacing, hierarchy, AI slop patterns — then fixes what it finds. Atomic commits, before/after screenshots. |
| `/investigate` | **Debugger** | Systematic root-cause debugging. Iron Law: no fixes without root cause. Traces data flow, tests hypotheses, stops after 3 failed fixes. |
| `/cso` | **Chief Security Officer** | OWASP Top 10 + STRIDE threat model. Zero-noise: confidence gate, independent verification. Concrete exploit scenarios. |
| `/audit` | **Code Auditor** | Deep codebase audit — security, quality, architecture, error handling. Pre-release sweep for the whole repo, not just the diff. |
| `/spawn-agent` | **Orchestrator** | Spawn and orchestrate AI agents (Ren, Ren-Codex, Claude, Codex) across tmux panes. Parallel work, without the step on each other's toes problem. |
| `/design-consultation` | **Design Partner** | Build a complete design system from scratch. Researches the landscape, proposes creative risks, generates realistic mockups. Writes `DESIGN.md`. |
| `/codex` | **Second Opinion** | Independent review from OpenAI Codex CLI. Three modes: code review (pass/fail gate), adversarial challenge, and open consultation. Cross-model analysis when both `/codex` and a steez review have run. |
| `/reminders` | **Reminder Manager** | Manage Apple Reminders via `remindctl` — create, complete, reschedule. Native macOS integration, no third-party app. |
| `/loop-prompt` | **Loop Generator** | Generate Ralph-style loop prompts for automated coding sessions. For when you want an agent to iterate on its own output without your attention. |
| `/sharpen-skill` | **Skill Improver** | Evaluate and improve skills via multi-agent research and critique. The meta-skill that sharpens the rest of the team. |

### Helper scripts

Bash scripts in `shared/steez/bin/` that skills call at runtime via `~/.steez/bin/`:

| Script | Purpose |
|--------|---------|
| `config` | Read/write `~/.steez/config` (YAML key-value) |
| `slug` | Extract `owner-repo` slug from git remote (with non-git fallback) |
| `review-log` | Append JSON review entries to `~/.steez/projects/$SLUG/` |
| `review-read` | Read review log + config for Review Readiness Dashboard |
| `diff-scope` | Categorize diff as frontend/backend/prompts/tests/docs/config |
| `steez-bd` | Beads integration (session brief, claim work, emit findings, handoff) |
| `agent-state` | Detect AI agent state in tmux panes |
| `agent-history` | Parse structured transcript from tmux pane |

## Install

```sh
git clone git@github.com:st-eez/steez.git ~/Projects/Personal/steez
cd ~/Projects/Personal/steez
make install    # requires Go: brew install go
steez setup     # interactive TUI
# or: steez install starter
```

## Usage

```sh
steez setup           # Interactive TUI — pick skills to install
steez install starter # Install the starter kit (3 workflow skills)
steez install all     # Install all active skills
steez list            # Show installed skills
steez doctor          # Validate install health
steez update          # Pull latest and re-link
```

## Skill Categories

| Category | Skills | Description |
|---|---|---|
| **Workflow** | spec, agenda, jira | Active planning and daily workflow surface |
| **QA & Testing** | browse, steez-qa, steez-qa-only, design-review | Browser-based testing and visual QA |
| **Infrastructure** | investigate, cso, spawn-agent, audit | Debugging, security, and orchestration |
| **Design** | design-consultation | Design system creation |
| **Meta** | codex, reminders, loop-prompt, sharpen-skill | Automation, AI consult, and skill improvement |

## Profiles

- **Starter Kit** — 3 workflow skills on the active planning surface. Recommended for new users.
- **All** — All active skills.

## Development

```sh
make build    # Build binary locally
make install  # Install to ~/go/bin/steez
make clean    # Remove local binary
```

## Runtime state

Skills write session data and analytics to `~/.steez/` (not in the repo):

```
~/.steez/
  repo -> <user's checkout>       # installer-managed symlink
  bin/                            # installer-managed symlinks to shared/steez/bin/
  config                          # proactive: true
  sessions/                       # active session tracking (auto-cleaned after 2h)
  analytics/
    skill-usage.jsonl             # local usage log (every skill invocation)
    eureka.jsonl                  # first-principles insights (Search Before Building)
  skill-reports/                  # Skill Self-Report bug reports (always on)
    {slug}.md
  projects/
    {slug}/
      *-design-*.md              # legacy planning artifacts from deprecated front doors
      *-reviews.jsonl            # legacy review logs from deprecated planning skills
  browse/                        # browse daemon state
    auth.json                    # NS credentials (chmod 600, slot-keyed for multi-agent)
    locks/                       # account lock files (auto-managed, PID + 2h TTL)
    chromium-profile/            # persistent browser profile
```

## Philosophy

See [ETHOS.md](ETHOS.md) — two principles shape every skill:

1. **Boil the Lake** — always do the complete thing when AI makes the marginal cost near-zero
2. **Search Before Building** — three layers of knowledge (tried-and-true, new-and-popular, first-principles)

## Provenance

Forked from [gstack](https://github.com/garrytan/gstack) v0.13.0.0 on 2026-03-29. See [FORK_MANIFEST.md](FORK_MANIFEST.md) for per-file upstream mapping.

### What was stripped

~117 lines per skill (~8.4% average reduction):
- Onboarding conditionals — dead code for a single user
- Remote telemetry (Supabase sync) — no phone-home
- Contributor Mode → Skill Self-Report (always on, `~/.steez/skill-reports/`)
- Repo Ownership guidance — hardcoded solo mode
- Version update checks — steez is git-backed, not self-updating

### What was kept

All behavioral sections: Voice, AskUserQuestion format, Completeness Principle, Search Before Building, Completion Status Protocol, Eureka logging, all functional phases. Full workflow parity with gstack originals.

### What was changed

- Voice: "senior engineering partner — CTO-level operator" (not Garry Tan / GStack identity)
- Data: `~/.steez/` (not `~/.gstack/`)
- Binaries: `~/.steez/bin/` (not `~/.claude/skills/gstack/bin/gstack-*`)
- Chaining: all skills under `~/.claude/skills/` (not `/gstack-*`)
- Config: `~/.steez/config` (not `~/.gstack/config.yaml`)

## Docs

| Doc | What it covers |
|-----|---------------|
| [Architecture](ARCHITECTURE.md) | Design decisions, "why" for every major choice, system internals |
| [Builder Ethos](ETHOS.md) | Boil the Lake, Search Before Building, three layers of knowledge |
| [Fork Manifest](FORK_MANIFEST.md) | Per-file upstream mapping, patches applied |
