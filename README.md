# steez

Your AI agent is only as good as the instructions you give it. steez turns Claude Code into a 21-specialist engineering team — thinking partners, planners, reviewers, testers, security auditors, and orchestrators — all living in your dotfiles, deployed with a single `steez install` command, zero external dependencies.

Forked from [gstack](https://github.com/garrytan/gstack) (v0.13.0.0), stripped to the studs, and rebuilt for a solo operator who wants the full sprint pipeline without the team overhead.

## See it work

```
You:    I want to add OAuth login to my side project.
You:    /workshop

Claude: Before you build anything — is this actually an auth
        problem, or is it "I have no users and auth feels
        like productive work"? [five lenses fire, carry-cost
        lands hardest] Build it, but keep scope to just login.
        Drops a bead.

You:    /office-hours
        [six forcing questions on the committed product]
        [writes design doc → saved to ~/.steez/projects/]

You:    /autoplan
        [runs /plan-ceo-review, /plan-design-review,
        /plan-eng-review in sequence, surfaces only taste
        decisions for approval]

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

You said "OAuth login." `/workshop` said "is this actually an auth problem, or productive work that feels like progress?" — because it listened to the pain, not the feature request. Seven commands, fuzzy hunch to merge-ready code. Every skill reads what the previous one wrote — the workshop bead, the design doc, the test plan — so nothing falls through the cracks.

## The sprint

steez is a process, not a toolbox. The skills run in the order a sprint runs:

**Think → Plan → Build → Test → Review**

Each skill feeds into the next. `/workshop` sharpens fuzzy ideas before they hit the plan pipeline. `/office-hours` writes a design doc that `/plan-ceo-review` reads. `/plan-eng-review` writes a test plan that `/steez-qa` picks up. `/codex review` and `/cso` catch issues before you merge. Nothing falls through the cracks because every step knows what came before it.

| Skill | Your specialist | What they do |
|-------|----------------|--------------|
| `/workshop` | **Thinking Partner** | Start here for fuzzy ideas. Five lenses (XY check, carry cost, pre-mortem, landscape check, smallest disprover) to chew on half-formed thoughts until they dispose into a bead, a memory entry, a kill, or a graduation to `/office-hours`. |
| `/office-hours` | **Product Strategist** | Six forcing questions that reframe the problem before you write code. Two modes: Startup (diagnostic) and Builder (brainstorm). Writes a design doc that feeds every downstream skill. |
| `/plan-ceo-review` | **CEO / Founder** | Rethink the problem. Find the 10-star product hiding inside the request. Four modes: Expansion, Selective Expansion, Hold Scope, Reduction. |
| `/plan-eng-review` | **Eng Manager** | Lock in architecture, data flow, edge cases, test coverage. ASCII diagrams. Forces hidden assumptions into the open. |
| `/plan-design-review` | **Senior Designer** | Rates each design dimension 0-10, explains what a 10 looks like, then edits the plan to get there. AI slop detection. |
| `/autoplan` | **Review Pipeline** | One command, fully reviewed plan. Runs CEO → design → eng review automatically with encoded decision principles. Surfaces only taste decisions for your approval. |
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
steez install starter # Install the starter kit (7 workflow skills)
steez install all     # Install everything
steez list            # Show installed skills
steez doctor          # Validate install health
steez update          # Pull latest and re-link
```

## Skill Categories

| Category | Skills | Description |
|---|---|---|
| **Workflow** | workshop, office-hours, plan-ceo-review, plan-eng-review, plan-design-review, agenda, jira | Sprint pipeline: Think, Plan, Build |
| **QA & Testing** | browse, steez-qa, steez-qa-only, design-review | Browser-based testing and visual QA |
| **Infrastructure** | investigate, cso, spawn-agent, audit | Debugging, security, and orchestration |
| **Design** | design-consultation | Design system creation |
| **Meta** | codex, autoplan, reminders, loop-prompt, sharpen-skill | Automation, AI consult, and skill improvement |

## Profiles

- **Starter Kit** — 7 workflow skills (the sprint pipeline spine). Recommended for new users.
- **All** — Everything available.

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
      *-design-*.md              # design docs from /office-hours
      *-reviews.jsonl            # review logs from /plan-ceo-review, /plan-eng-review, /plan-design-review
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
