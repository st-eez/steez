---
name: ren-update
description: |
  Enforce eval-gated workflow for any edit to ren.md, soul.md, or hooks/*.md in the ren repo. Every prompt change is paired with a baseline + patched eval run, judge calibration where applicable, and hard anti-patterns that catch the failure modes documented in ren-h7q. One candidate at a time, three-run repeatability, train + holdout gate, commit with evidence.
  Use when editing ren.md, soul.md, or hooks/*.md. Use when changing a behavior Ren is supposed to exhibit (voice, refusal, tool use, plan-mode entry, verdict-first, skill suggestion, etc.). Use when responding to a user report "Ren is doing X wrong" — the fix goes through this workflow.
  Do NOT use for pure doc edits (CLAUDE.md, AGENTS.md, notes.md, bead descriptions). Do NOT use for harness code changes (runner.py, judge.py, parser.py — those land via normal bead workflow). Do NOT use for adding eval cases alone when no prompt change is paired — that's a dataset task, not a prompt-tuning task.
argument-hint: "[category or case-id being changed]"
---

# /ren-update

You are applying an eval-gated change to Ren's prompt stack. Every edit to `ren.md`, `soul.md`, or `hooks/*.md` must be paired with an eval run that proves the change does what you intend AND does not regress other behaviors. No exceptions. No vibes.

If `$ARGUMENTS` is given, treat it as the category or case-id being changed (e.g. `voice`, `voice.no_filler`, `skill_suggestion`, `diagnosis`). Otherwise, ask the user which behavior they are changing before touching any file.

## Step 0: Locate and enter the ren repo

Every bash block below assumes cwd is the ren repo root. If you are not there, enter it first:

```bash
cd "${REN_REPO:-$HOME/Projects/Personal/ren}"
ls ren.md soul.md evals/run.py
```

If the `ls` fails, stop and ask the user for the repo path. Do not proceed without the correct cwd.

Confirm the override flag exists on the runner — it is a prerequisite for step 4:

```bash
python3 evals/run.py --help | grep -- --system-prompt
```

If the flag is missing, stop. The baseline mechanism does not work without it. Tell the user to ship ren-fyr (or its equivalent) first.

## Step 1: State the change in one sentence

Before touching any file, say out loud: "I am changing `<file>:<section>` so that Ren <does X instead of Y>." If you cannot compress the change to one sentence, it is too big — decompose into separate beads and run this workflow once per bead.

## Step 2: Find or design the eval cases

Check `evals/cases/<category>/` for existing cases measuring this behavior. Categories currently include: `conciseness`, `diagnosis`, `judgment`, `planning`, `scope_discipline`, `skill_suggestion`, `tool_selection`, `verdict_first`, `voice`.

```bash
ls evals/cases/<category>/
```

**If cases exist:** read them. Confirm they actually measure the behavior you are changing. If they do not, flag the mismatch and either add new cases or fix the existing ones before proceeding. Bad cases are worse than no cases — they create false confidence.

**If no cases exist:** design a labeled dataset using the pattern from ren-289:

- Compact, hand-crafted cases — one TOML file per case under `evals/cases/<category>/`
- Each case has a human label (`label = "positive"` / `"negative"` / `"ambiguous"`) and a one-line `rationale`
- Each case has a `split` field: `"train"` (tuning) or `"holdout"` (final gate)
- Target 12-20 cases total, roughly 70/30 train/holdout
- Cover: obvious positives, obvious negatives, tempting negatives (edge cases that look like positives but are not), atomic negatives (one-line lookups, factual questions)
- Use `required_patterns` / `banned_patterns` as the primary lexical signal; `llm_judge` as a secondary narrow check
- Zero contamination: no references to prompt tuning, ren internals, eval infra, or the feature being tested inside the case prompts or transcripts

See `evals/cases/voice/no_filler.toml` for a minimal lexical example and `evals/cases/skill_suggestion/` for the structured-transcript pattern (post ren-289).

## Step 3: Calibrate the judge (only if using llm_judge)

If any case uses `[[assertions.llm_judge]]`:

1. Run the train split against the current prompt stack.
2. Compare judge verdicts against your human labels for every non-ambiguous case.
3. Target agreement: **>80% on non-ambiguous cases** before trusting the judge for scoring.
4. If the judge disagrees on obvious cases, either switch judge model (`evals/config.toml`, `[judge].model`) or tighten the `criteria` string on the failing case. Iterate until agreement clears the bar.
5. Ambiguous cases do not count toward agreement — they exist for calibration review only, never for pass/fail scoring.

If all your cases use lexical patterns (`required_patterns`, `banned_patterns`) or tool assertions (`must_use_tools`), skip this step — those assertions are deterministic and need no calibration.

## Step 4: Baseline run — current prompt stack WITHOUT the change

This is the control. Snapshot the files **before** you edit anything:

```bash
cp ren.md ren.md.baseline
cp soul.md soul.md.baseline
```

Run the eval against the snapshot:

```bash
python3 evals/run.py \
  --system-prompt ren.md.baseline \
  --append-system-prompt soul.md.baseline \
  --category <category>
```

Record the result JSON path printed at the end — you will compare against it in step 8.

Confirm the expected pattern:

- **Feature gap change** (the edit ADDS behavior): positives should FAIL, negatives should PASS. This proves the behavior does not exist today.
- **Wording fix** (the edit REFINES existing behavior): the baseline pass rate is your regression floor. Patched runs must meet or exceed it on every case.

If the baseline does not match your expectations, STOP. The cases are measuring the wrong thing. Fix them before writing a single word of the change. Skipping this step is how you tune wording against a broken scorer and ship garbage — the exact failure mode in ren-h7q.

## Step 5: Apply the change

Edit the actual file (`ren.md`, `soul.md`, or `hooks/<name>.md`). **One candidate at a time.** Do not prepare multiple candidate wordings for side-by-side comparison — see anti-pattern §A1 below.

## Step 6: Patched run with repeatability (3 runs)

Run the eval three times against the edited file. The harness auto-reads the edited `ren.md` / `soul.md` now — no override flag needed:

```bash
python3 evals/run.py --category <category>   # run 1
python3 evals/run.py --category <category>   # run 2
python3 evals/run.py --category <category>   # run 3
```

Report **median pass rate + range** across the three runs. A single run is noise — three tells you whether the signal is stable. If run 1 is 10/12 and run 2 is 7/12, that is a 25-point swing on sampling variance alone. Never promote a candidate on one run.

## Step 7: Compare baseline vs patched

```bash
python3 evals/compare.py evals/results/<baseline>.json evals/results/<best-of-three>.json
```

Look at:

- **Pass rate delta in the target category** — must improve.
- **Regressions in OTHER categories** — must be zero.
- **Must-pass regressions** — must be zero. Must-pass patterns are configured in `evals/config.toml` under `[compare].must_pass`. These are hard blockers.

`compare.py` exits `1` on must-pass regressions, `2` on other regressions, `0` on clean. Treat non-zero as "do not promote."

## Step 8: Promote conservatively — train AND holdout AND zero regressions

Only promote if ALL of these are true:

- Median pass rate **improves** on the train split in the target category
- Median pass rate **improves or holds** on the holdout split
- Zero regressions in must-pass cases
- Zero regressions in any other category

If it passes on train but fails on holdout, the change overfit the train set. Revert the file, tune, try again.

If it passes on train but regresses another category, the change has collateral damage. Usually the wording is too broad or too imperative. Tighten and retry.

## Step 9: Commit with evidence

Stage and commit:

- The prompt file change (`ren.md` / `soul.md` / `hooks/*.md`)
- The baseline result JSON under `evals/results/`
- The best-of-three patched result JSON under `evals/results/`

Do NOT stage the `.baseline` snapshot files. Delete them:

```bash
rm ren.md.baseline soul.md.baseline
```

Commit message convention — use `feat:` for new behaviors, `fix:` for regressions:

```
feat|fix: <one-line change summary>

<why — 1-2 sentences>

Baseline: evals/results/<baseline>.json (X/N pass)
Patched:  evals/results/<patched>.json  (Y/N pass, median of 3 runs)
Delta:    +Z on <category>, 0 regressions elsewhere

Closes <bead-id>.
```

## Step 10: Anti-overfit — add new holdout cases after promotion

After the commit lands, add 2-3 **new** cases that were NOT visible during tuning. These are the anti-overfit check. Write them as TOML under `evals/cases/<category>/`, label them honestly (`positive` / `negative`), and put them in the `holdout` split.

Re-run:

```bash
python3 evals/run.py --category <category> --split holdout
```

If the new holdout cases fail, the winning wording overfit the train set. Revert the promotion commit (`git revert <hash>`), add the new cases to the dataset, and restart from step 4. Ship nothing until the new holdout passes.

If they pass, commit the new holdout cases as a follow-up. You are done.

## Step 11: Close the bead

```bash
bd close <bead-id> --reason "Shipped <change>. Baseline X/N → patched Y/N (median of 3). Holdout +K new cases added post-promotion, all pass. Zero regressions elsewhere. Commits: <hash1>, <hash2>."
```

---

## Hard rules (anti-patterns that WILL cause failure)

Each rule maps to a documented failure in ren-h7q. They are not suggestions.

### §A1 — No N-candidate side-by-side comparison at small N

With 12-20 cases, one-case swings move the pass rate by 5-10 points. Binomial 95% CI at p=0.5 with n=15 is roughly ±25 points before judge variance. Side-by-side across 2-3 candidate wordings at this sample size measures sampling noise, not signal. Pick one candidate, measure, iterate. If you catch yourself writing "let me try three wordings and see which wins," stop — you are measuring a random variable.

### §A2 — No `--baseline` flag as your control

The `--baseline` flag strips `ren.md` and `soul.md` entirely (see `evals/lib/runner.py:70`) and compares to vanilla Claude. That is a different experiment — "how much does the Ren stack help at all" — and it is useless as a change-vs-current control. Use `--system-prompt ren.md.baseline --append-system-prompt soul.md.baseline` against snapshots you copied in step 4.

### §A3 — No live `~/.claude/projects/` sessions as fixtures

Two dealbreakers:

- Fork-resume depends on private Claude on-disk storage layout and path canonicalization — fragile API, breaks without warning across Claude updates.
- ren-dev sessions are contaminated with meta-discussion of whatever feature you are testing. That is direct label leakage into the training signal.

Hand-craft compact transcript excerpts under `evals/cases/<category>/`. The `prior_turns` field on `EvalCase` (see `evals/lib/parser.py` and `evals/lib/runner.py:_compose_prompt`) is the supported path for structured multi-turn fixtures.

### §A4 — No uncalibrated llm_judge

An `llm_judge` assertion that has not been measured against human labels on the train split is not a scorer — it is a random variable dressed up in confident prose. Your pass/fail signal is noise. Calibrate (step 3) before trusting any judge verdict for promotion decisions.

### §A5 — No wording tuned by intuition

The entire point of this workflow is to let evals decide. If the evals do not support a judgment call, the cases are wrong — fix the cases, not the wording. "It reads better to me" is not evidence. If your gut says the new wording is better but the numbers say otherwise, trust the numbers or fix the dataset. Do not ship on feel.

### §A6 — No commits without before/after result JSONs

Regression history depends on having the historical data. A commit without a paired baseline + patched result JSON is unverifiable — a future reviewer cannot tell why the wording landed, cannot reproduce the decision, and cannot catch a later regression by bisecting against the stored evidence. No evidence means no commit.

---

## Fast-path summary (for returning users)

```bash
cd "${REN_REPO:-$HOME/Projects/Personal/ren}"

# 1. Snapshot baseline
cp ren.md ren.md.baseline && cp soul.md soul.md.baseline

# 2. Baseline run — record the result JSON path
python3 evals/run.py \
  --system-prompt ren.md.baseline \
  --append-system-prompt soul.md.baseline \
  --category <category>

# 3. Edit ren.md / soul.md / hooks — one candidate only

# 4. Patched runs (3x for repeatability)
python3 evals/run.py --category <category>
python3 evals/run.py --category <category>
python3 evals/run.py --category <category>

# 5. Compare
python3 evals/compare.py \
  evals/results/<baseline>.json \
  evals/results/<best-of-three>.json

# 6. Promote only if train + holdout both improve with zero regressions

# 7. Commit prompt change + both result JSONs
rm ren.md.baseline soul.md.baseline
git add ren.md soul.md hooks/*.md evals/results/<baseline>.json evals/results/<patched>.json
git commit   # use the template in step 9

# 8. Anti-overfit: add 2-3 new holdout cases, re-run holdout, revert if regress
python3 evals/run.py --category <category> --split holdout

# 9. bd close <bead-id> --reason "..."
```

---

## Source material (read when you need deeper context)

- **ren-h7q** — the failed first attempt at `skill_suggestion`. Every anti-pattern above maps to a specific failure in this bead. Read first when a step feels arbitrary.
- **ren-289** — the gold-dataset pattern: compact hand-crafted cases, human labels, judge calibration, proper baseline control. Read when designing a new dataset.
- **ren-td9** — the canonical feature-tune loop: one candidate, three repeats, train + holdout gate, commit with evidence. Read when you want the lived-experience version of this workflow.
- **`evals/lib/runner.py`**, **`evals/lib/judge.py`**, **`evals/lib/assertions.py`**, **`evals/config.toml`** — the harness itself. Read when you need to know what assertions exist, what models the runner/judge use, or what knobs are available.
