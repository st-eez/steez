### Beads Integration (completion)

If the Beads Context preamble showed a bead with label `skill:ceo-review`, hand off the review results:

```bash
# Hand off CEO review results to the bead (non-blocking)
_CEO_BEAD_ID="BEAD_ID_FROM_PREAMBLE"
if [ -n "$_CEO_BEAD_ID" ] && [ "$_CEO_BEAD_ID" != "none" ]; then
  ~/.steez/bin/steez-bd handoff "$_CEO_BEAD_ID" "CEO review complete. Status: STATUS. Mode: MODE. Unresolved: N." --close 2>/dev/null || true
fi
```

Replace `BEAD_ID_FROM_PREAMBLE` with the bead ID shown by the Beads Context preamble.
Replace `STATUS`, `MODE`, and `N` with actual values from the Completion Summary.
Closing the CEO review bead auto-unblocks the eng review bead (via bd dependency).

If no bead was shown in the preamble, skip this step.