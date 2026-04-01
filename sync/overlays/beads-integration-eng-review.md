### Beads Integration (completion)

If the Beads Context preamble showed a bead with label `skill:eng-review`, hand off the review results:

```bash
# Hand off eng review results to the bead (non-blocking)
_ENG_BEAD_ID="BEAD_ID_FROM_PREAMBLE"
if [ -n "$_ENG_BEAD_ID" ] && [ "$_ENG_BEAD_ID" != "none" ]; then
  ~/.steez/bin/steez-bd handoff "$_ENG_BEAD_ID" "Eng review complete. Status: STATUS. Issues: N. Test gaps: N." --close 2>/dev/null || true
fi
```

Replace `BEAD_ID_FROM_PREAMBLE` with the bead ID shown by the Beads Context preamble.
Replace `STATUS` and `N` values from the Completion Summary.
Closing the eng review bead auto-unblocks the implement bead (via bd dependency).

If no bead was shown in the preamble, skip this step.