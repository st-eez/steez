#!/bin/bash
# Track steez skill invocations to local analytics.
# Source: ~/Projects/Personal/steez/shared/steez/hooks/skill-analytics.sh
# Symlinked to: ~/.claude/hooks/steez-skill-analytics.sh
# Hook: PostToolUse (settings.json) — matcher: Skill
# Fires for ALL agents — steez skills are agent-agnostic.

read -r -t 5 INPUT || true

SKILL=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
[ -z "$SKILL" ] && exit 0

SID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | cut -d'"' -f4)
AGENT=$(printf '%s' "$INPUT" | grep -o '"agent_type":"[^"]*"' | cut -d'"' -f4)
ARGS=$(printf '%s' "$INPUT" | jq -r '.tool_input.args // empty' 2>/dev/null)

REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EPOCH=$(date +%s)

ANALYTICS_DIR="${STEEZ_HOME:-$HOME/.steez}/analytics"
mkdir -p "$ANALYTICS_DIR"

# Build JSON — include args only when non-empty to keep lines compact.
if [ -n "$ARGS" ]; then
  ESCAPED_ARGS=$(printf '%s' "$ARGS" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"skill":"%s","ts":"%s","epoch":%s,"sid":"%s","repo":"%s","branch":"%s","agent":"%s","args":"%s"}\n' \
    "$SKILL" "$TS" "$EPOCH" "$SID" "$REPO" "$BRANCH" "$AGENT" "$ESCAPED_ARGS"
else
  printf '{"skill":"%s","ts":"%s","epoch":%s,"sid":"%s","repo":"%s","branch":"%s","agent":"%s"}\n' \
    "$SKILL" "$TS" "$EPOCH" "$SID" "$REPO" "$BRANCH" "$AGENT"
fi >> "$ANALYTICS_DIR/skill-usage.jsonl"

exit 0
