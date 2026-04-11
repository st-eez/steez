---
name: ren-update
description: |
  Eval-gated prompt edit for `ren.md` or `soul.md`. Invoke when the user (or you, self-invoking) flags a specific behavior in Ren's prompt stack to change. Phase 1 isolates the target file, locates or creates a stable failing TRAIN reproducer, and freezes the corpus. Phase 2 pre-registers a causal claim, makes the smallest edit, and compares pair-by-pair 3x runs. The eval falsifies a named claim or it isn't proof.

  Do NOT use for `CLAUDE.md`, `AGENTS.md`, `notes.md`, bead descriptions, or harness code. Do NOT use for hook edits — the harness runs each case in a temp cwd (`evals/lib/runner.py:23`) and cannot see `hooks/*.md`.
argument-hint: "[failing behavior in plain words]"
---

# /ren-update

No edit to `ren.md` or `soul.md` before Phase 1 produces a stable failing train case AND Phase 2 produces a pre-registered causal claim naming exactly one target file. Prefix every bash block with `cd "${REN_REPO:-$HOME/Projects/Personal/ren}"`.

## Phase 1 — Isolate & reproduce

### 1.1 Locate the target file
```bash
grep -nF "<keyword naming the behavior>" ren.md soul.md
```
- Only one file has existing material → that file.
- Both → the file whose rule is more imperative on the topic.
- Neither → structure / tools / refusal / verdict → `ren.md`; tone / filler / word choice / formality → `soul.md`.
- Behavior traces to hooks, native runtime, or this repo's `CLAUDE.md` → **abort**. This loop cannot prove those layers.

You may only edit the chosen file in Phase 2.

### 1.2 Locate or create a stable TRAIN reproducer
`<category>` is a real directory under `evals/cases/`, not a free-text behavior. `ls evals/cases/` to pick the category that already holds (or will hold) this case. A case qualifies as a reproducer iff ALL true:
- `split = "train"` (a mandatory field, [parser.py:71](evals/lib/parser.py)).
- Fails today on the exact behavior, not adjacent ground.
- Has `required_patterns` / `banned_patterns` only, OR has `llm_judge` **and** no `prior_turns`. `llm_judge` is blind to prior turns ([assertions.py:177](evals/lib/assertions.py) passes only `case.prompt`); multi-turn + `llm_judge` cases are invalid reproducers.
- `required_patterns` is OR-matched ([assertions.py:121](evals/lib/assertions.py)). A case that passes on one incidental token is too loose — rewrite or reject.

No case qualifies → create **1–3 new TOML cases** under `evals/cases/<category>/`, `split = "train"`. Full train+holdout gold datasets are ren-289's job, not this skill's.

### 1.3 Freeze the corpus
```bash
git rev-parse HEAD > /tmp/ren-update.head
git status --porcelain evals/ ren.md soul.md > /tmp/ren-update.frozen
python3 -c "import hashlib, pathlib; h=hashlib.sha256(); [h.update(p.read_bytes()) for p in sorted(pathlib.Path('evals').rglob('*')) if p.is_file() and not str(p).startswith('evals/results') and not str(p).startswith('evals/traces')]; print(h.hexdigest())" > /tmp/ren-update.corpus
```
Before commit, rerun all three and diff — if anything outside `ren.md` / `soul.md` / `evals/results/` / `evals/traces/` changed, abort and restart Phase 1.

### 1.4 Baseline stability — 3x, train only
```bash
cp ren.md ren.md.baseline && cp soul.md soul.md.baseline
for i in 1 2 3; do
  python3 evals/run.py --split train \
    --system-prompt ren.md.baseline \
    --append-system-prompt soul.md.baseline
done
```
Every target case must fail in **all three** runs. Fails 2/3 → flaky, rewrite or reject. Passes in any run → Phase 1 is broken, fix the case before Phase 2.

## Phase 2 — Pre-register & tune

### 2.1 Pre-register the causal claim
Paste into the bead and the manifest BEFORE touching a byte:

- **Target file** — exactly one of `ren.md` / `soul.md`.
- **Target section** — heading path plus the quoted current wording being replaced.
- **Target case IDs** — copied from 1.4, exact.
- **Current failure reason per case** — from each baseline JSON's `assertions[].reason`. Not a guess.
- **Causal claim** — one sentence: "Changing §X from `<current>` to `<new>` will make the model do Y, which flips cases [...] because Z."
- **Must-hold** — named categories / case IDs that cannot regress in any patched run.
- **Deletion check** — which existing rule does this replace, shrink, or subsume? If nothing, reconsider.

No pre-registration → no edit.

### 2.2 Smallest edit
Edit only the target file. Minimum wording that could plausibly move the target cases. Prefer deletion or replacement over addition.

### 2.3 Paired 3x runs — train only
```bash
for i in 1 2 3; do
  python3 evals/run.py --split train
done
```
Compare **pair-by-pair** (baseline run *i* vs patched run *i*):
```bash
python3 evals/compare.py <baseline_i>.json <patched_i>.json
```
Promote iff ALL true for EVERY pair (3/3):
- Each target case flips fail→pass.
- Zero `must_pass_regressions` ([config.toml:11](evals/config.toml)).
- Zero other regressions.
- `missing_from_a` and `missing_from_b` are both empty (identical case set).
- `judge_prompt_hash` identical across the pair — any drift means `lib/judge.py` moved and comparison is invalid ([run.py:247](evals/run.py)).
- `system_prompt_hash` differs only if you edited `ren.md`; `append_system_prompt_hash` differs only if you edited `soul.md`. The untouched file's hash must be identical.

Not all three pairs satisfy this → do NOT cherry-pick, do NOT rerun hoping for noise — revert the edit or shrink the hypothesis and restart 2.1.

### 2.4 Holdout — final gate, ONCE
```bash
python3 evals/run.py --split holdout
```
All holdout cases, no category filter. Compare against the most recent clean holdout run on `main`:
```bash
python3 evals/compare.py <prior_holdout>.json <new_holdout>.json
```
Any regression → revert the prompt edit, no retries. If no prior holdout run exists to compare against, note that in the manifest; the promoted state becomes the new holdout baseline.

### 2.5 Manifest + commit
Write `evals/results/<timestamp>.manifest.json` containing: `complaint`, `causal_claim`, `target_file`, `target_section`, `target_case_ids`, `baseline_results` (list of 3 paths), `patched_results` (list of 3 paths), `holdout_result` (path), `pair_verdicts` (3 entries with target_flips + regressions + hash checks), `corpus_frozen_head` (from 1.3), `harness_hash` (sha256 of `run.py` + `lib/runner.py` + `lib/assertions.py` + `lib/judge.py` + `config.toml`), `corpus_hash` (the hash from 1.3), `dirty_tree` (bool from `git status --porcelain`).

Stage: prompt file diff, all 6 train result JSONs, the holdout result JSON, manifest. Delete `.baseline` snapshots. Commit with `feat:` for new behavior or `fix:` for a regression fix, one-line complaint on the subject line. Close the bead with `bd close <id> --reason "..."`.

## Hard rules

- **One file, one section, one candidate per run.** Editing both files or two candidates at once pretends to test one hypothesis and tests none.
- **Never `--baseline`.** That flag strips the stack entirely and tests vanilla Claude — wrong experiment. Control is always snapshot files via `--system-prompt` / `--append-system-prompt`.
- **No `~/.claude/projects/` session dumps** as fixtures. Fragile path layout + label contamination.
- **No `llm_judge` on multi-turn cases. Ever.** The judge does not see `prior_turns`.
- **No uncalibrated `llm_judge`** on single-turn cases — >80% agreement with human labels on non-ambiguous examples before trusting a judge verdict for promotion.
- **No holdout run during iteration.** One invocation, at 2.4.
- **No cherry-picking across the 3x pairs.** All three pairs must satisfy the hypothesis or no promotion.
- **No edits outside `ren.md` / `soul.md` during Phase 2.** Any diff under `evals/cases/`, `evals/fixtures/`, `evals/lib/`, `evals/config.toml`, `evals/run.py`, or `evals/compare.py` = Phase 1 reset.
- **No commit without the full manifest + all 7 result JSONs** (6 train + 1 holdout). Unverifiable history is worse than none.
- **No rule added without naming the rule it replaces, shrinks, or subsumes.** Prompts only grow otherwise.
- **No intuition tuning.** If the numbers disagree with your taste, the reproducer or the hypothesis is wrong — fix those, not the wording.
