# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Agent Subsystem

Six scripts manage AI coding agents across tmux panes: state detection, message delivery, completion watching, and transcript parsing. See `specs/README.md` for contracts, dependency graph, and data flow. Quick reference in CLAUDE.md Commands section.

## Agent and Skill Locations

Do not guess which verifier is in play. Check the actual layer.

- **Codex custom agents** live in `~/.codex/agents/*.toml`
  - Codex verifier: `/Users/stevedimakos/.codex/agents/verifier.toml`
  - Source of truth: `/Users/stevedimakos/Projects/Personal/ren/.codex/agents/verifier.toml`
- **Claude custom agents** live in `~/.claude/agents/*.md`
  - Claude verifier: `/Users/stevedimakos/.claude/agents/verifier.md`
  - Source of truth: `/Users/stevedimakos/Projects/Personal/ren/agents/verifier.md`
- **Claude global skills** live in `~/.claude/skills`
- **Codex global skills** live in `~/.codex/skills`
  - `~/.agents/skills` is legacy. Do not treat it as the Codex skill home.
- **Repo-local skills** live in `/Users/stevedimakos/Projects/Personal/steez/skills`
  - Example: `/Users/stevedimakos/Projects/Personal/steez/skills/spawn-agent`

When verifier behavior looks wrong, inspect the parent spawn call and whether it used `fork_context=true` before blaming the verifier file.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
