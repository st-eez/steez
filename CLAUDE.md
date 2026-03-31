# steez — Claude Code Skill Installer

## Conventions

- When adding a new skill, also add its entry to `skills.json` (name, category, description max 80 chars)
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

## Install Model

Skills are installed as symlinks: `~/.claude/skills/steez-{name}` -> `repo/skills/{name}/`
Install registry lives at `~/.steez/installed.json`.
Updates are live mutation: `git pull` in-place, symlinks already point at checkout.

## Design References

- Design doc: `~/.steez/projects/st-eez-dotfiles/stevedimakos-main-design-20260330-204342.md`
- Plan file: `~/.claude/plans/nifty-puzzling-pancake.md`
- Test plan: `~/.steez/projects/st-eez-dotfiles/stevedimakos-main-eng-review-test-plan-20260330-222500.md`
