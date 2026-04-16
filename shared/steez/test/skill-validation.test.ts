import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const repoRoot = resolve(import.meta.dir, "..", "..", "..");

function readRepoFile(relativePath: string): string {
  return readFileSync(resolve(repoRoot, relativePath), "utf8");
}

function expectContract(relativePath: string, patterns: RegExp[]): void {
  const absolutePath = resolve(repoRoot, relativePath);
  expect(existsSync(absolutePath)).toBe(true);

  const text = readRepoFile(relativePath);
  for (const pattern of patterns) {
    expect(text).toMatch(pattern);
  }
}

test("spec skill contract", () => {
  expectContract("skills/spec/SKILL.md", [
    /^---\nname:\s*spec/m,
    /plans\/<bead-id>-<topic-slug>-design-spec\.md/,
    /XY check/,
    /carry cost/,
    /kill, answer directly, or write a design spec/,
    /hard-failure lint/,
  ]);
});

test("spec skill skeleton-first loop", () => {
  expectContract("skills/spec/SKILL.md", [
    /skeleton-first/,
    /load-bearing questions/,
    /update the design spec after each answer/,
  ]);
});

test("tdd skill contract", () => {
  expectContract("skills/tdd/SKILL.md", [
    /^---\nname:\s*tdd/m,
    /slice-contract precheck/i,
    /red\s*→\s*green\s*→\s*refactor/i,
    /Red test name/,
    /hand back to \/spec/i,
    /hard-failure lint/i,
  ]);
});

test("tdd skill finalization contract", () => {
  expectContract("skills/tdd/SKILL.md", [
    /one approved slice/i,
    /drift/i,
    /verifier/i,
    /browse/i,
    /bd update --append-notes/,
  ]);

  expectContract("specs/tdd.md", [
    /^# tdd$/m,
    /one approved slice/i,
    /\/tdd does not edit the design spec/i,
    /verifier/i,
    /browse/i,
    /bd update --append-notes/,
  ]);

  expectContract("specs/README.md", [
    /\[tdd\]\(\.\/tdd\.md\)/,
  ]);
});

test("spec to tdd handoff contract", () => {
  expectContract("skills/spec/SKILL.md", [
    /\/tdd/,
    /Implementation slices/,
  ]);

  expectContract("specs/spec.md", [
    /\/tdd does not edit the design spec/,
    /specs\/\*\.md/,
  ]);
});

test("spec runtime spec exists", () => {
  expectContract("specs/spec.md", [
    /^# spec$/m,
    /## Inputs/,
    /## Outputs/,
    /## Behavioral Contracts/,
  ]);

  expectContract("specs/README.md", [
    /\[spec\]\(\.\/spec\.md\)/,
  ]);
});
