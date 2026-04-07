# steez

Your AI agent is only as good as the instructions you give it. steez turns Claude Code into a 21-specialist engineering team — planners, reviewers, testers, security auditors, and a release engineer — all living in your dotfiles, deployed with a single `steez install` command, zero external dependencies.

Forked from [gstack](https://github.com/garrytan/gstack) (v0.13.0.0), stripped to the studs, and rebuilt for a solo operator who wants the full sprint pipeline without the team overhead.

## See it work

```
You:    I want to add OAuth login to my side project.
You:    /office-hours

Claude: Before we build anything — who is logging in, and what
        are they protecting? You said "OAuth" but let me push
        back on the framing...
        [six forcing questions about the real problem]
        [writes design doc → saved to ~/.steez/projects/]

You:    /plan-ceo-review
        [reads design doc, challenges scope, rates 10 dimensions]
        "Hold scope. OAuth is the right call, but drop the admin
        dashboard from v1 — ship login first, learn from usage."

You:    /plan-eng-review
        [ASCII diagrams for auth flow, token refresh, error paths]
        [test matrix, security concerns, edge cases]

You:    Approve plan. Build it.
        [writes 1,800 lines across 9 files]

You:    /review
        [AUTO-FIXED] 1 issue. [ASK] Token expiry edge case → you approve fix.

You:    /qa https://localhost:3000
        [opens real browser, tests login flow, finds redirect bug, fixes it]

You:    /ship
        Tests: 28 → 34 (+6 new). PR: github.com/you/app/pull/17
```

You said "OAuth login." The agent said "who is logging in and what are they protecting?" — because it listened to the pain, not the feature request. Six commands, design doc to merged PR. Every skill reads what the previous one wrote — the design doc, the test plan, the review log — so nothing falls through the cracks.

## The sprint

steez is a process, not a toolbox. The skills run in the order a sprint runs:

**Think → Plan → Build → Review → Test → Ship → Reflect**

Each skill feeds into the next. `/office-hours` writes a design doc that `/plan-ceo-review` reads. `/plan-eng-review` writes a test plan that `/qa` picks up. `/review` catches bugs that `/ship` verifies are fixed. Nothing falls through the cracks because every step knows what came before it.

| Skill | Your specialist | What they do |
|-------|----------------|--------------|
| `/office-hours` | **Product Strategist** | Start here. Six forcing questions that reframe the problem before you write code. Two modes: Startup (diagnostic) and Builder (brainstorm). Writes a design doc that feeds every downstream skill. |
| `/plan-ceo-review` | **CEO / Founder** | Rethink the problem. Find the 10-star product hiding inside the request. Four modes: Expansion, Selective Expansion, Hold Scope, Reduction. |
| `/plan-eng-review` | **Eng Manager** | Lock in architecture, data flow, edge cases, test coverage. ASCII diagrams. Forces hidden assumptions into the open. |
| `/plan-design-review` | **Senior Designer** | Rates each design dimension 0-10, explains what a 10 looks like, then edits the plan to get there. AI slop detection. |
| `/design-consultation` | **Design Partner** | Build a complete design system from scratch. Researches the landscape, proposes creative risks, generates realistic mockups. Writes `DESIGN.md`. |
| `/design-shotgun` | **Design Explorer** | Generate multiple AI design variants, open a comparison board, iterate until you approve a direction. Taste memory biases toward your preferences. |
| `/review` | **Staff Engineer** | Pre-landing PR review. SQL safety, LLM trust boundaries, conditional side effects, completeness gaps. Auto-fixes the obvious ones. |
| `/investigate` | **Debugger** | Systematic root-cause debugging. Iron Law: no fixes without investigation. Traces data flow, tests hypotheses, stops after 3 failed fixes. |
| `/design-review` | **Designer Who Codes** | Visual audit — spacing, hierarchy, AI slop patterns — then fixes what it finds. Atomic commits, before/after screenshots. |
| `/qa` | **QA Lead** | Test your app in a real browser, find bugs, fix them with atomic commits, re-verify. Generates regression tests for every fix. |
| `/qa-only` | **QA Reporter** | Same methodology as `/qa` but report only. Pure bug report, no code changes. |
| `/cso` | **Chief Security Officer** | OWASP Top 10 + STRIDE threat model. Zero-noise: confidence gate, independent verification. Concrete exploit scenarios. |
| `/ship` | **Release Engineer** | Sync base branch, run tests, audit coverage, push, open PR. Review Readiness Dashboard shows which reviews have run. |
| `/land-and-deploy` | **Release Engineer** | Merge the PR, wait for CI and deploy, verify production health via canary checks. One command from "approved" to "verified in production." |
| `/canary` | **SRE** | Post-deploy monitoring. Watches for console errors, performance regressions, and page failures using the browse daemon. |
| `/document-release` | **Technical Writer** | Update all project docs to match what shipped. Reads every doc, cross-references the diff, catches stale READMEs automatically. |
| `/retro` | **Eng Manager** | Weekly retro. Per-person breakdowns, shipping streaks, test health trends, growth opportunities. |
| `/browse` | **QA Engineer** | Headless browser (Playwright + Chromium). Real clicks, real screenshots, ~100ms per command. Persistent sessions — log in once, stay logged in. |
| `/autoplan` | **Review Pipeline** | One command, fully reviewed plan. Runs CEO → design → eng review automatically with encoded decision principles. Surfaces only taste decisions for your approval. |
| `/codex` | **Second Opinion** | Independent review from OpenAI Codex CLI. Three modes: code review (pass/fail gate), adversarial challenge, and open consultation. Cross-model analysis when both `/review` and `/codex` have run. |
| `/setup-deploy` | **Deploy Configurator** | One-time setup for `/land-and-deploy`. Detects your platform, production URL, and deploy commands. |

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
| **Workflow** | office-hours, plan-ceo-review, plan-eng-review, plan-design-review, review, ship | Sprint pipeline: Think, Plan, Build, Review, Ship |
| **QA & Testing** | browse, qa, qa-only, design-review, canary, benchmark | Browser-based testing, visual QA, canary monitoring |
| **Infrastructure** | investigate, cso, connect-chrome, setup-browser-cookies | Debugging, security, and browser connectivity |
| **Design** | design-consultation, design-shotgun, design-html | Design system creation, variants, HTML generation |
| **Meta** | codex, autoplan, document-release, land-and-deploy, setup-deploy, retro | Automation, docs, deployment, retrospectives |

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
      *-reviews.jsonl            # review logs from /review, /ship
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
