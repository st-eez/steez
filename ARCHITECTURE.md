# Architecture

This document explains **why** steez is built the way it is. For the skill catalog and usage, see [README.md](README.md). For upstream provenance, see [FORK_MANIFEST.md](FORK_MANIFEST.md).

## The core idea

steez is 23 Markdown files that turn Claude Code into a structured engineering team. No build step for the skills, no runtime dependencies, no server — just SKILL.md files that Claude reads when you invoke a slash command.

The key insight: AI agents don't need frameworks, they need **opinionated instructions**. A well-written SKILL.md with clear phases, explicit voice, and filesystem-based data flow produces better results than a sophisticated template engine. steez adapts gstack's sprint pipeline — Think → Plan → Build → Test → Review — with a Go CLI installer for symlink management and git for version control.

## Where everything lives

steez spans two locations: the source repo (git-backed, wherever you cloned it) and a runtime state directory at `~/.steez/` (installer-managed, never committed).

### Repo

```
steez/                                # repo root
├── cmd/steez/                        # Go CLI entrypoint
├── internal/                         # Go packages
│   ├── installer/                    # symlink management, manifest parsing
│   ├── config/                       # ~/.steez/installed.json loader
│   ├── tui/                          # Bubble Tea setup flow
│   └── updater/                      # git-based update logic
├── skills/                           # 23 skill directories, each {name}/SKILL.md
├── skills.json                       # manifest: skills + categories + profiles
├── shared/steez/                     # shared runtime (deployed via symlinks)
│   ├── bin/                          # 9 bash helper scripts
│   │   ├── config                    # read/write ~/.steez/config
│   │   ├── slug                      # git remote → owner-repo slug
│   │   ├── diff-scope                # categorize diff scopes
│   │   ├── review-log                # append review entries
│   │   ├── review-read               # read review log + config
│   │   ├── steez-bd                  # beads integration
│   │   ├── agent-state               # detect AI agent state in tmux panes
│   │   ├── agent-history             # parse structured transcript from tmux pane
│   │   └── upstream-diff             # diff skill against gstack upstream
│   ├── browse/                       # headless browser (Playwright + Chromium)
│   └── hooks/                        # SessionStart + skill-analytics hooks
├── ETHOS.md                          # builder philosophy
├── ARCHITECTURE.md                   # this file
├── FORK_MANIFEST.md                  # upstream gstack provenance
├── CLAUDE.md                         # repo conventions for Claude Code
└── README.md                         # ecosystem docs
```

The Go CLI under `cmd/steez/` and `internal/` is the install machinery. Skills under `skills/` are pure data — Markdown files Claude reads at runtime. The shared runtime under `shared/steez/` is everything skills depend on at execution time (helper scripts, the browse binary, Claude Code hooks). Keeping these three concerns in distinct top-level directories is intentional: it lets the installer reason about each as a unit and lets contributors find things by role rather than by file type.

### Runtime (`~/.steez/`)

```
~/.steez/
  config                              # key-value config (proactive: true)
  sessions/                           # PID-based session tracking
  analytics/
    skill-usage.jsonl                 # every skill invocation
    eureka.jsonl                      # first-principles insights
  skill-reports/                      # Skill Self-Report bug reports
  projects/{slug}/                    # per-project design docs + review logs
  browse/                             # chromium profile, sidebar sessions
    auth.json                         # NS credentials (chmod 600, slot-keyed)
    locks/                            # account lock files (PID + TTL)
```

### Install model

steez ships as a Go CLI (`cmd/steez/`) that manages a symlink-based install. Each installed skill becomes a per-directory symlink at `~/.claude/skills/{name}` pointing back to `repo/skills/{name}/`. Shared runtime is reached the same way: `~/.steez/repo` symlinks to the user's checkout, and `~/.steez/bin/` holds installer-managed symlinks to each helper script and the `browse` binary. The install registry at `~/.steez/installed.json` is the source of truth for what's currently installed and where it points.

**Why symlinks instead of copies:** updates are live mutation. `git pull` in the source checkout updates every installed skill instantly because the symlinks already point at the live tree. There is no rebuild step, no resync command, no version drift between what's in the repo and what Claude reads at runtime. Edit a SKILL.md in the repo, the next slash-command invocation sees the change.

**Why per-skill symlinks instead of one parent symlink:** users opt into a subset of skills via `skills.json` profiles, and `~/.claude/skills/` may already contain skills installed from other sources. Per-skill symlinks let the installer reconcile only the steez-managed entries without touching anything else in that directory. The Go installer reads `skills.json`, computes the desired set against `installed.json`, and adds/removes symlinks accordingly.

**Why a Go CLI instead of a shell script:** the installer needs to manage state across two locations (the source checkout and `~/.steez/`), parse a manifest, reconcile a registry, and handle the TUI for first-time setup. A few hundred lines of Go is more maintainable than the equivalent bash, and the binary has zero runtime dependencies once compiled.

## Why no templates

gstack generates SKILL.md files from `.tmpl` templates via `gen-skill-docs.ts`. This makes sense for gstack — 29 skills with shared sections and auto-generated command references from source code metadata. Template drift is a real risk at that scale.

steez doesn't use templates. Each SKILL.md is hand-edited directly.

**Why this works:**
- **No build step.** Edit a SKILL.md, it's live immediately. No `bun run gen:skill-docs`, no stale generated output.
- **No template/generated drift.** gstack's template system solves a real problem — but it introduces its own: the generated SKILL.md can be stale if someone forgets to regenerate. steez has no generated files to go stale.
- **Shared behavior lives in the agent definition (ren.md/soul.md), not in skills.** Voice, AskUserQuestion format, completeness principles, and other cross-cutting concerns are defined once in the agent layer rather than duplicated across skills.

## Why local-only telemetry

gstack supports opt-in remote telemetry via Supabase — anonymous usage data (skill name, duration, success/fail) sent to a hosted database. steez strips all remote telemetry.

**Why:** steez is a public repo. Embedding remote endpoints in committed files is a maintenance burden and a trust issue. Local analytics provide the same signal — which skills get used, how long they take, what fails — without any network dependency.

**How it works:** A PostToolUse hook (`shared/steez/hooks/skill-analytics.sh`) appends a JSON line to `~/.steez/analytics/skill-usage.jsonl` on every skill invocation. This is a local file, never synced. The eureka log (`eureka.jsonl`) captures first-principles insights from the Search Before Building pattern.

## Why no onboarding

gstack runs first-time prompts for three features: lake intro (philosophy), telemetry consent, and proactive skill suggestions. Each prompt sets a flag in config so it only fires once. steez strips all three.

**Why:** Single user, config pre-seeded. The onboarding conditionals are dead code — they check flags that are already set. Every line of SKILL.md costs tokens when Claude reads it. Dead conditionals waste tokens and add noise.

**How to apply:** `~/.steez/config` ships with `proactive: true` already set. No first-run detection needed.

## Why Skill Self-Report is always on

gstack has a "Contributor Mode" gated behind a `gstack_contributor` config flag. When enabled, the agent files casual bug reports when gstack itself misbehaves. steez repurposes this as "Skill Self-Report" and makes it unconditional.

**Why:** You're the maintainer. If a skill misbehaves, you want to know. Gating the report behind a flag that you'd always enable adds complexity for zero benefit. Reports go to `~/.steez/skill-reports/{slug}.md`.

## Skill anatomy

Every SKILL.md follows the same structure:

```
┌─ YAML frontmatter ─────────────────────────┐
│ name: {skill}                              │
│ description: ...                           │
│ allowed-tools: [Bash, Read, ...]           │
└────────────────────────────────────────────┘
         │
┌─ Functional phases (skill-specific) ───────┐
│ Phase 1, Phase 2, Phase 3...              │
│ Skill chaining references                  │
└────────────────────────────────────────────┘
```

Skills contain only their functional logic. Cross-cutting concerns (voice, AskUserQuestion format, completeness principles) live in the agent definition (ren.md/soul.md), not in skills.

Skill analytics are tracked via a PostToolUse hook (`shared/steez/hooks/skill-analytics.sh`),
not inline telemetry. The hook fires mechanically on every Skill tool invocation and writes to
`~/.steez/analytics/skill-usage.jsonl`.

## Data flow

Skills communicate through the filesystem, not through shared memory:

```
/office-hours
  writes → ~/.steez/projects/{slug}/{user}-{branch}-design-{ts}.md
           │
/plan-ceo-review
  reads  ← design doc
  writes → review log entry (via review-log)
           │
/plan-design-review
  reads  ← design doc + prior review logs
  writes → review log entry
           │
/plan-eng-review
  reads  ← design doc + prior review logs
  writes → review log entry
```

`/autoplan` runs the three plan reviews sequentially. `/workshop` sits upstream of this chain but communicates through beads (one bead per session, `--label=workshop`) rather than filesystem artifacts.

### Review Readiness Dashboard

`review-read` outputs three sections used by review skills:

```
{branch}-reviews.jsonl entries    ← review history
---CONFIG---
{skip_eng_review value}           ← config overrides
---HEAD---
{short commit hash}               ← current HEAD
```

### Helper script dependencies

```
slug ← review-log (needs SLUG for file path)
     ← review-read (needs SLUG for file path)

config ← review-read (reads skip_eng_review)

diff-scope — standalone, no dependencies
```

## Browse integration

Skills reference the browse binary as `$B`:

```bash
B=~/.steez/bin/browse
```

Single hardcoded path via installer-managed symlink: `~/.steez/bin/browse` → `~/.steez/repo/shared/steez/browse/dist/browse`.

The browse binary is a compiled Bun daemon built on the Playwright npm library (v1.58.2). It provides a long-lived Chromium session with sub-second command latency. See the browse skill for architecture details.

### NetSuite authentication

NS commands (`$B ns login`, `$B ns navigate`, etc.) authenticate via `~/.steez/browse/auth.json` (chmod 600 required). The file uses slot-keyed accounts to support multiple users on the same sandbox:

```json
{
  "accounts": {
    "SANDBOX_ACCT:account2": {
      "email": "user+2@example.com",
      "password": "...",
      "accountId": "SANDBOX_ACCT",
      "securityQuestions": { "keyword": "answer" }
    },
    "SANDBOX_ACCT:account3": {
      "email": "user+3@example.com",
      "password": "...",
      "accountId": "SANDBOX_ACCT",
      "securityQuestions": { "keyword": "answer" }
    }
  }
}
```

**Slot keys** (e.g. `SANDBOX_ACCT:account2`) are the locking unit. The `accountId` field is the real NS account ID used for the login URL. When `accountId` is omitted, the slot key itself is used (backwards compatible with single-user setups where the key is just `SANDBOX_ACCT`).

**Security questions** use case-insensitive substring matching. Store keywords ("city", "nickname"), not full question text.

### Account locking

Parallel agents (e.g. A/B eval via tmux split) must not share the same NS user session. `$B ns login` manages this automatically via lock files at `~/.steez/browse/locks/<slot>.lock`.

```
$B ns login                              → picks first unlocked slot
$B ns login --account SANDBOX_ACCT:account3 → claims specific slot
$B ns login --release                    → releases all locks held by this process
```

Lock lifecycle:
1. **Acquire:** atomic file write (`O_EXCL`) on login. Contains `{ pid, ts }`.
2. **Release:** automatic on browse shutdown (SIGTERM/SIGINT handler).
3. **Stale detection:** before honoring a lock, check if PID is alive (`kill -0`). Dead PID = stale lock, reclaimed immediately. Fallback: locks older than 2h TTL are ignored.

This means crashed sessions don't permanently block accounts. The next agent to check will find the dead PID and reclaim the slot.

## Error philosophy

Skill errors are for the AI agent, not for humans. Every error message should be actionable — tell Claude what went wrong and what to do next. This principle is inherited from gstack's browse server (which rewrites Playwright errors through `wrapError()`) and applied to skill design:

- If a config value is missing, fall back to a sensible default
- If a design doc isn't found, the skill tells the agent to run `/office-hours` first
- If a review log is empty, the Review Readiness Dashboard says "no reviews found" instead of erroring

## What's intentionally not here

- **No template system.** 23 skills is manageable by hand. The build step complexity isn't justified. See "Why no templates" above.
- **No multi-user support.** This is personal tooling. No contributor detection, no collaborative review workflows.
- **No remote telemetry.** All analytics are local JSONL files. No Supabase, no network calls.
- **No onboarding flow.** Config is pre-seeded. No first-run prompts, no opt-in gates.
- **No self-updater.** steez is git-backed. `steez update` (or `git pull` in the source checkout) is the update mechanism — symlinks already point at the live tree.
- **No shared command reference generation.** Unlike gstack's `{{COMMAND_REFERENCE}}` template placeholders, browse command docs are maintained directly in the browse SKILL.md.

## Key differences from gstack

| Aspect | gstack | steez |
|--------|--------|-------|
| Deployment | `git clone` + `./setup` | Go CLI installer (symlinks) |
| Template system | `.tmpl` → `gen-skill-docs.ts` → `SKILL.md` | hand-edited SKILL.md |
| Config file | `~/.gstack/config.yaml` | `~/.steez/config` (no extension) |
| Shared behavior | Per-skill preamble (tiers + managed sections) | Agent definition (ren.md/soul.md) |
| Telemetry | Local JSONL + opt-in Supabase sync | Local JSONL only |
| Onboarding | First-run prompts | None (pre-seeded) |
| Voice | Garry Tan / GStack identity | Agent definition (soul.md) |
| Skill count | 29 skills | 23 skills |
| Update mechanism | `/gstack-upgrade` self-updater | `git pull` in source checkout (live via symlinks) |

## Extending steez

### Adding a new skill

1. Create `skills/{name}/SKILL.md` in the source repo
2. Add an entry to `skills.json` (`name`, `category`, `description` ≤80 chars)
3. Run `steez install {name}` to symlink it into `~/.claude/skills/`

### Porting from gstack

1. `mkdir -p skills/{name}` + `cp` the gstack `SKILL.md` into it
2. Strip the `gstack-` prefix from the YAML frontmatter `name:` field (steez skills use bare names — `cso`, not `steez-cso`). Exception: when the bare name would shadow a built-in slash command via `/x` autocomplete (e.g., `/qa` shadows `/quit`), keep the `steez-` prefix to push it past the collision. `steez-qa` and `steez-qa-only` use this exception.
3. Remove auto-generated comments (template artifact markers)
4. Strip all gstack preamble/behavioral sections (voice, AskUserQuestion, completeness, self-report, completion status, plan status footer) — these live in the agent definition now
5. Strip onboarding conditionals (`LAKE_INTRO`, `TEL_PROMPTED`, `PROACTIVE_PROMPTED`)
6. Strip Repo Ownership section
7. Telemetry → local JSONL only (strip Supabase sync)
8. SETUP browse → steez pattern (`B=~/.steez/bin/browse`)
9. Global replace all gstack paths/refs → steez
14. Verify: `grep -c -i gstack SKILL.md` must return 0

**Gotcha:** bash `||` and `&&` precedence — use curly braces `{ }` for fallback grouping (e.g., `cmd || { fallback; }`).

### Updating from upstream

1. Check what's diverged: `upstream-diff --all` (or `upstream-diff <skill>` for one skill)
2. Cherry-pick functional changes manually from `~/Projects/Personal/gstack/`
3. Skip template, onboarding, and contributor-mode diffs — those are intentional steez removals
4. Update `FORK_MANIFEST.md` with the new upstream commit if doing a major sync
