## Beads Integration

After the design doc is APPROVED (and spec review loop completes), create the bead pipeline chain.
This makes the downstream workflow (CEO review -> eng review -> implement) visible in `bd graph`
and enables cross-session continuity via `steez-bd resume`.

**All commands must be in a single bash block** (variables don't persist between blocks):

```bash
# Create bead pipeline chain (in steez global database, not project-local)
export BEADS_DIR="$HOME/.steez/.beads"
_DESIGN_TITLE="$(head -1 "$DESIGN" 2>/dev/null | sed 's/^# //' || echo 'Untitled design')"
_PROJECT_SLUG="$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo 'unknown')"
_BRANCH=$(git branch --show-current 2>/dev/null || echo 'unknown')
# Context note for cross-session pickup — each child bead carries enough info
# for a fresh Claude session to find the design doc and resume work
_BEAD_CONTEXT="Design doc: $DESIGN
Branch: $_BRANCH
Project: $_PROJECT_SLUG"
PARENT=$(bd create --title="Design: $_DESIGN_TITLE" --type=feature --priority=2 --silent 2>/dev/null) || true
if [ -n "$PARENT" ]; then
  CEO=$(bd create --title="CEO review: $_DESIGN_TITLE" --type=task --priority=2 --parent="$PARENT" --notes="$_BEAD_CONTEXT" --silent 2>/dev/null) || true
  ENG=$(bd create --title="Eng review: $_DESIGN_TITLE" --type=task --priority=2 --parent="$PARENT" --notes="$_BEAD_CONTEXT" --silent 2>/dev/null) || true
  IMPL=$(bd create --title="Implement: $_DESIGN_TITLE" --type=task --priority=2 --parent="$PARENT" --notes="$_BEAD_CONTEXT" --silent 2>/dev/null) || true
  [ -n "$CEO" ] && [ -n "$ENG" ] && bd dep add "$ENG" "$CEO" >/dev/null 2>&1 || true
  [ -n "$ENG" ] && [ -n "$IMPL" ] && bd dep add "$IMPL" "$ENG" >/dev/null 2>&1 || true
  # Skill tags (autoplan matches on these) + project labels
  [ -n "$CEO" ] && bd update "$CEO" --add-label skill:ceo-review --add-label "project:$_PROJECT_SLUG" >/dev/null 2>&1 || true
  [ -n "$ENG" ] && bd update "$ENG" --add-label skill:eng-review --add-label "project:$_PROJECT_SLUG" >/dev/null 2>&1 || true
  [ -n "$IMPL" ] && bd update "$IMPL" --add-label skill:implement --add-label "project:$_PROJECT_SLUG" >/dev/null 2>&1 || true
  [ -n "$PARENT" ] && bd update "$PARENT" --add-label "project:$_PROJECT_SLUG" >/dev/null 2>&1 || true
  echo "Bead chain: $PARENT -> $CEO -> $ENG -> $IMPL (project: $_PROJECT_SLUG)"
  ~/.steez/bin/steez-bd handoff "$PARENT" "Design doc approved. Path: $DESIGN" --close 2>/dev/null || true
else
  echo "steez-bd: could not create bead chain (bd unavailable or not in beads project)"
fi
```

Tell the user: "Created bead pipeline: [PARENT] -> [CEO] -> [ENG] -> [IMPL]. Run `bd ready` to see next available work, or `bd graph [PARENT]` to visualize the chain."

If chain creation fails (bd not available, not in a beads project), proceed normally. The chain is a bonus, not a gate.