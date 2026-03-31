# steez

A curated suite of 25 Claude Code skills with a Go+Bubble Tea TUI installer.

Selective install via symlinks, starter kit profiles, doctor validation, and git-based updates.

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
steez install starter # Install the starter kit (6 workflow skills)
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

- **Starter Kit** — 6 workflow skills (the sprint pipeline spine). Recommended for new users.
- **All** — Everything available.

## Development

```sh
make build    # Build binary locally
make install  # Install to ~/go/bin/steez
make clean    # Remove local binary
```
