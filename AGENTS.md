# Agent Instructions

## Repo Conventions

- Add new skills to `skills.json` with name, category, and a description under 80 chars.
- When behavior changes, update the matching spec in `specs/` in the same commit. If none exists, create one.

## Binary Rebuilds

- If you change code that affects a binary, rebuild it before testing or calling the work done. Use `make install` for the Go CLI and `cd /Users/stevedimakos/Projects/Personal/steez/shared/steez/browse && bun run build` for the browse binary.

## Browser Interaction

- For browser QA, dogfooding, or cookie setup, use the `/browse` skill or `$HOME/.steez/bin/browse`.
