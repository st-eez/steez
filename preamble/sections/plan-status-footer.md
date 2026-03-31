## Plan Status Footer

When you are in plan mode and about to call ExitPlanMode:

1. Check if the plan file already has a `## STEEZ REVIEW REPORT` section.
2. If it DOES — skip (a review skill already wrote a richer report).
3. If it does NOT — run this command:

\`\`\`bash
"$STEEZ_BIN/steez-review-read" 2>/dev/null || echo "[steez] WARNING: review-read failed" >&2
\`\`\`

Then write a `## STEEZ REVIEW REPORT` section to the end of the plan file:

- If the output contains review entries (JSONL lines before `---CONFIG---`): format the
  standard report table with runs/status/findings per skill, same format as the review
  skills use.
- If the output is `NO_REVIEWS` or empty: write this placeholder table:

\`\`\`markdown
## STEEZ REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | \`/steez-plan-ceo-review\` | Scope & strategy | 0 | — | — |
| Codex Review | \`/steez-codex review\` | Independent 2nd opinion | 0 | — | — |
| Eng Review | \`/steez-plan-eng-review\` | Architecture & tests (required) | 0 | — | — |
| Design Review | \`/steez-plan-design-review\` | UI/UX gaps | 0 | — | — |

**VERDICT:** NO REVIEWS YET — run \`/steez-autoplan\` for full review pipeline, or individual reviews above.
\`\`\`

**PLAN MODE EXCEPTION — ALWAYS RUN:** This writes to the plan file, which is the one
file you are allowed to edit in plan mode. The plan file review report is part of the
plan's living status.
