import { describe, it, expect, beforeAll } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { parseDocument } from "../parser.js";
import { applyOverlay, applyPreambleOnly, detectDrift } from "../overlay.js";
import type { OverlayConfig, SkillConfig } from "../types.js";

/** Create a minimal config pointing at a temp directory with overlay files. */
function makeTestConfig(
  overlays: Record<string, string>,
  overrides?: Partial<OverlayConfig>
): { config: OverlayConfig; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), "steez-sync-test-"));
  const upstreamDir = join(dir, "upstream");
  const overlaysDir = join(dir, "overlays");
  mkdirSync(upstreamDir, { recursive: true });
  mkdirSync(overlaysDir, { recursive: true });

  for (const [name, content] of Object.entries(overlays)) {
    writeFileSync(join(overlaysDir, name), content);
  }

  const config: OverlayConfig = {
    upstream: upstreamDir,
    output: join(dir, "output"),
    pin: { source: "test", tag: "v0", sha: "abc", timestamp: "now" },
    global: {
      replace: [],
      deleteSection: [],
      replaceSection: [],
      injectAfter: [],
    },
    frontmatter: {
      namePrefix: "steez-",
      removeFields: [],
      descriptionRemove: [],
      descriptionOverrides: {},
    },
    preamble: {
      beginMarker: "<!-- BEGIN MANAGED PREAMBLE -->",
      endMarker: "<!-- END MANAGED PREAMBLE -->",
      sections: [],
    },
    skills: {},
    newSkillPolicy: "warn",
    ...overrides,
  };

  return { config, dir };
}

describe("applyOverlay", () => {
  it("prefixes the name in frontmatter", () => {
    const md = `---\nname: ship\nversion: 1.0.0\n---\n\n# Ship`;
    const { config } = makeTestConfig({});
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    expect(result).toContain("name: steez-ship");
  });

  it("removes specified frontmatter fields", () => {
    const md = `---\nname: ship\nsensitive: true\nversion: 1.0.0\n---\n\n# Ship`;
    const { config } = makeTestConfig({});
    config.frontmatter.removeFields = ["sensitive"];
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    expect(result).not.toContain("sensitive");
    expect(result).toContain("name: steez-ship");
    expect(result).toContain("version: 1.0.0");
  });

  it("removes substrings from description", () => {
    const md = `---\nname: ship\ndescription: Ship workflow (gstack)\n---\n\n# Ship`;
    const { config } = makeTestConfig({});
    config.frontmatter.descriptionRemove = [" (gstack)"];
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    expect(result).toContain("description: Ship workflow");
    expect(result).not.toContain("(gstack)");
  });

  it("deletes sections", () => {
    const md = `# Ship\n\n## Voice\n\nKeep this.\n\n## Contributor Mode\n\nDelete this.\n\n## Steps\n\nKeep this too.`;
    const { config } = makeTestConfig({});
    config.global.deleteSection = [{ path: "## Contributor Mode" }];
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    expect(result).not.toContain("## Contributor Mode");
    expect(result).not.toContain("Delete this.");
    expect(result).toContain("## Voice");
    expect(result).toContain("## Steps");
  });

  it("deletes sections with children", () => {
    const md = `# Ship\n\n## Parent\n\n### Child 1\n\nChild content.\n\n### Child 2\n\nMore child.\n\n## Next\n\nKept.`;
    const { config } = makeTestConfig({});
    config.global.deleteSection = [{ path: "## Parent" }];
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    expect(result).not.toContain("## Parent");
    expect(result).not.toContain("### Child 1");
    expect(result).not.toContain("### Child 2");
    expect(result).toContain("## Next");
  });

  it("handles optional deletes gracefully", () => {
    const md = `# Ship\n\n## Voice\n\nContent.`;
    const { config } = makeTestConfig({});
    config.global.deleteSection = [
      { path: "## Missing Section", optional: true },
    ];
    const doc = parseDocument(md);
    // Should not throw
    const result = applyOverlay(doc, config, "ship");
    expect(result).toContain("## Voice");
  });

  it("throws on non-optional missing section", () => {
    const md = `# Ship\n\n## Voice\n\nContent.`;
    const { config } = makeTestConfig({});
    config.global.deleteSection = [{ path: "## Missing Section" }];
    const doc = parseDocument(md);
    expect(() => applyOverlay(doc, config, "ship")).toThrow(
      'Section not found for delete: "## Missing Section"'
    );
  });

  it("replaces sections with overlay content", () => {
    const md = `# Ship\n\n## Preamble (run first)\n\nOld preamble.\n\n## Voice\n\nKeep.`;
    const { config } = makeTestConfig({
      "steez-preamble.md": "## Preamble (run first)\n\nNew steez preamble.",
    });
    config.global.replaceSection = [
      { path: "## Preamble (run first)", file: "steez-preamble.md" },
    ];
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    expect(result).toContain("New steez preamble.");
    expect(result).not.toContain("Old preamble.");
    expect(result).toContain("## Voice");
  });

  it("injects sections after a target", () => {
    const md = `# Ship\n\n## Preamble (run first)\n\nPreamble content.\n\n## Voice\n\nVoice content.`;
    const { config } = makeTestConfig({
      "steez-beads-context.md":
        "## Beads Context\n\n```bash\nsteez-bd resume\n```",
    });
    config.global.injectAfter = [
      { path: "## Preamble (run first)", file: "steez-beads-context.md" },
    ];
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    // Beads Context should appear between Preamble and Voice
    const preambleIdx = result.indexOf("## Preamble");
    const beadsIdx = result.indexOf("## Beads Context");
    const voiceIdx = result.indexOf("## Voice");
    expect(beadsIdx).toBeGreaterThan(preambleIdx);
    expect(beadsIdx).toBeLessThan(voiceIdx);
  });

  it("applies global string replacements to upstream content only", () => {
    const md = `# Ship\n\n## Config\n\nRun gstack-config to set ~/.gstack/config.\n\n## Voice\n\nKeep gstack here too.`;
    const { config } = makeTestConfig({
      "steez-voice.md": "## Voice\n\nThis mentions gstack and should NOT be replaced.",
    });
    config.global.replace = [
      { from: "gstack-config", to: "steez-config" },
      { from: "~/.gstack/", to: "~/.steez/" },
    ];
    config.global.replaceSection = [
      { path: "## Voice", file: "steez-voice.md" },
    ];
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship");
    // Upstream content should be replaced
    expect(result).toContain("steez-config");
    expect(result).toContain("~/.steez/config");
    // Overlay content should NOT be replaced
    expect(result).toContain("This mentions gstack and should NOT be replaced.");
  });

  it("applies per-skill string replacements", () => {
    const md = `# Ship\n\n## Telemetry\n\n"skill":"SKILL_NAME"`;
    const { config } = makeTestConfig({});
    const skillConfig: SkillConfig = {
      replace: [{ from: "SKILL_NAME", to: "steez-ship" }],
    };
    const doc = parseDocument(md);
    const result = applyOverlay(doc, config, "ship", skillConfig);
    expect(result).toContain('"skill":"steez-ship"');
  });
});

describe("applyPreambleOnly", () => {
  it("replaces content between managed preamble markers", () => {
    const content = `---
name: steez-agenda
---

<!-- BEGIN MANAGED PREAMBLE -->

Old preamble content here.

## Old Section

Old stuff.

<!-- END MANAGED PREAMBLE -->

# Agenda

Real skill content stays.`;

    const { config } = makeTestConfig({
      "preamble-session.md": "## Session Tracking\n\n```bash\nmkdir -p $STEEZ_HOME/sessions\n```",
      "preamble-analytics.md": "## Analytics\n\n```bash\necho 'log' >> analytics.jsonl\n```",
    });
    config.preamble.sections = [
      { name: "session", file: "preamble-session.md" },
      { name: "analytics", file: "preamble-analytics.md" },
    ];

    const result = applyPreambleOnly(content, config, "agenda");
    expect(result).toContain("<!-- BEGIN MANAGED PREAMBLE -->");
    expect(result).toContain("## Session Tracking");
    expect(result).toContain("## Analytics");
    expect(result).toContain("<!-- END MANAGED PREAMBLE -->");
    expect(result).not.toContain("Old preamble content");
    expect(result).not.toContain("Old stuff.");
    expect(result).toContain("# Agenda");
    expect(result).toContain("Real skill content stays.");
  });

  it("throws when markers are missing", () => {
    const content = `---\nname: steez-agenda\n---\n\n# Agenda\n\nNo markers here.`;
    const { config } = makeTestConfig({});
    expect(() => applyPreambleOnly(content, config, "agenda")).toThrow(
      "Custom skill missing managed preamble markers"
    );
  });
});

describe("detectDrift", () => {
  it("reports missing required headings", () => {
    const md = `# Ship\n\n## Voice\n\nContent.`;
    const { config } = makeTestConfig({});
    config.global.deleteSection = [{ path: "## Contributor Mode" }];
    const doc = parseDocument(md);
    const errors = detectDrift(doc, config, "ship");
    expect(errors).toHaveLength(1);
    expect(errors[0].reason).toBe("missing");
    expect(errors[0].headingPath).toBe("## Contributor Mode");
  });

  it("skips optional headings without error", () => {
    const md = `# Ship\n\n## Voice\n\nContent.`;
    const { config } = makeTestConfig({});
    config.global.deleteSection = [
      { path: "## Repo Ownership", optional: true },
    ];
    const doc = parseDocument(md);
    const errors = detectDrift(doc, config, "ship");
    expect(errors).toHaveLength(0);
  });

  it("detects duplicate headings", () => {
    const md = `# Top\n\n## Review\n\nFirst.\n\n# Bottom\n\n## Review\n\nSecond.`;
    const { config } = makeTestConfig({});
    config.global.deleteSection = [{ path: "## Review" }];
    const doc = parseDocument(md);
    const errors = detectDrift(doc, config, "ship");
    expect(errors.some((e) => e.reason === "duplicate")).toBe(true);
  });
});
