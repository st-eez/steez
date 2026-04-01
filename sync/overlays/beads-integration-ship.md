## Step 8.25: Beads Integration (completion)

If the Beads Context preamble showed a bead with label `skill:implement`, hand off the ship results:

```bash
# Hand off ship results to the implement bead (non-blocking)
_IMPL_BEAD_ID="BEAD_ID_FROM_PREAMBLE"
if [ -n "$_IMPL_BEAD_ID" ] && [ "$_IMPL_BEAD_ID" != "none" ]; then
  ~/.steez/bin/steez-bd handoff "$_IMPL_BEAD_ID" "Shipped. PR: PR_URL. Branch: BRANCH." --close 2>/dev/null || true
fi
```

Replace `BEAD_ID_FROM_PREAMBLE` with the bead ID shown by the Beads Context preamble.
Replace `PR_URL` and `BRANCH` with actual values from Step 8.
Closing the implement bead completes the full pipeline (design -> CEO -> eng -> implement).

Use `steez-bd emit-finding` for any issues discovered during ship that need follow-up:
```bash
# Example: test failure that was skipped needs follow-up
~/.steez/bin/steez-bd emit-finding "$_IMPL_BEAD_ID" "Flaky test in auth.test.ts needs investigation" --type task --priority 2 2>/dev/null || true
```

If no bead was shown in the preamble, skip this step.