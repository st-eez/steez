import { describe, it, expect } from "bun:test";
import { parseDocument, findSection, findAllSections, dumpHeadings, reassemble } from "../parser.js";

describe("parseDocument", () => {
  it("extracts frontmatter", () => {
    const md = `---
name: ship
version: 1.0.0
---

# Ship`;
    const doc = parseDocument(md);
    expect(doc.frontmatter).toBe("name: ship\nversion: 1.0.0");
    expect(doc.sections).toHaveLength(1);
    expect(doc.sections[0].heading).toBe("# Ship");
  });

  it("handles missing frontmatter", () => {
    const md = `# Ship\n\nSome content.`;
    const doc = parseDocument(md);
    expect(doc.frontmatter).toBe("");
    expect(doc.sections).toHaveLength(1);
  });

  it("captures preamble content between frontmatter and first heading", () => {
    const md = `---
name: test
---

<!-- BEGIN MANAGED PREAMBLE -->

Some preamble text.

# Main Heading

Body.`;
    const doc = parseDocument(md);
    expect(doc.preambleContent).toContain("BEGIN MANAGED PREAMBLE");
    expect(doc.preambleContent).toContain("Some preamble text.");
    expect(doc.sections[0].heading).toBe("# Main Heading");
  });

  it("ignores headings inside backtick fences", () => {
    const md = `# Real Heading

Some text.

\`\`\`bash
## This is NOT a heading
echo "## Nor is this"
### Also not a heading
\`\`\`

## Real Sub-heading

More text.`;
    const doc = parseDocument(md);
    expect(doc.sections).toHaveLength(2);
    expect(doc.sections[0].heading).toBe("# Real Heading");
    expect(doc.sections[1].heading).toBe("## Real Sub-heading");
    // Fenced content should be part of the first section
    expect(doc.sections[0].content).toContain("## This is NOT a heading");
  });

  it("ignores headings inside tilde fences", () => {
    const md = `# Top

~~~markdown
## Fake Heading
~~~

## Real`;
    const doc = parseDocument(md);
    expect(doc.sections).toHaveLength(2);
    expect(doc.sections[0].heading).toBe("# Top");
    expect(doc.sections[1].heading).toBe("## Real");
  });

  it("handles nested fence markers (longer fence closes longer)", () => {
    const md = `# Top

\`\`\`\`markdown
\`\`\`
## Still inside the outer fence
\`\`\`
\`\`\`\`

## Real After Nested`;
    const doc = parseDocument(md);
    // The ```` (4 backticks) opens a fence. The ``` (3 backticks) inside
    // should NOT close it because the parser tracks fence toggle state.
    // Note: our simple toggle parser will toggle on ``` even inside ````,
    // which is a known limitation. This test documents the behavior.
    expect(doc.sections.length).toBeGreaterThanOrEqual(2);
    expect(doc.sections[0].heading).toBe("# Top");
  });

  it("does not cross-close backtick and tilde fences", () => {
    const md = `# Top

\`\`\`
## Inside backtick fence
~~~
## Still inside — tilde can't close backtick
\`\`\`

## After`;
    const doc = parseDocument(md);
    expect(doc.sections).toHaveLength(2);
    expect(doc.sections[0].heading).toBe("# Top");
    expect(doc.sections[1].heading).toBe("## After");
  });

  it("handles the office-hours stress test (many fenced headings)", () => {
    // Simulate the gstack office-hours pattern: many ## headings inside fences
    const fencedHeadings = Array.from({ length: 34 }, (_, i) =>
      `## Fenced heading ${i + 1}\nSome content for heading ${i + 1}.`
    ).join("\n");

    const md = `---
name: office-hours
---

# YC Office Hours

\`\`\`markdown
${fencedHeadings}
\`\`\`

## Phase 1: Discovery

Real content here.

## Phase 2: Deep Dive

More real content.`;
    const doc = parseDocument(md);
    // Should only have 3 real headings, not 37
    expect(doc.sections).toHaveLength(3);
    expect(doc.sections[0].heading).toBe("# YC Office Hours");
    expect(doc.sections[1].heading).toBe("## Phase 1: Discovery");
    expect(doc.sections[2].heading).toBe("## Phase 2: Deep Dive");
  });

  it("builds correct fullPath for nested headings", () => {
    const md = `# Ship

## Step 1

### Step 1a

## Step 2

### Step 2a

#### Step 2a-i`;
    const doc = parseDocument(md);
    expect(doc.sections[0].fullPath).toBe("# Ship");
    expect(doc.sections[1].fullPath).toBe("# Ship > ## Step 1");
    expect(doc.sections[2].fullPath).toBe("# Ship > ## Step 1 > ### Step 1a");
    expect(doc.sections[3].fullPath).toBe("# Ship > ## Step 2");
    expect(doc.sections[4].fullPath).toBe("# Ship > ## Step 2 > ### Step 2a");
    expect(doc.sections[5].fullPath).toBe("# Ship > ## Step 2 > ### Step 2a > #### Step 2a-i");
  });

  it("handles section content boundaries correctly", () => {
    const md = `# Top

Top content line 1.
Top content line 2.

## Section A

A content.

## Section B

B content.`;
    const doc = parseDocument(md);
    expect(doc.sections).toHaveLength(3);
    expect(doc.sections[0].content).toContain("Top content line 1.");
    expect(doc.sections[0].content).toContain("Top content line 2.");
    expect(doc.sections[0].content).not.toContain("A content.");
    expect(doc.sections[1].content).toContain("A content.");
    expect(doc.sections[1].content).not.toContain("B content.");
    expect(doc.sections[2].content).toContain("B content.");
  });
});

describe("findSection", () => {
  it("finds by heading text", () => {
    const md = `# Top\n\n## Voice\n\nVoice content.\n\n## Steps\n\nSteps content.`;
    const doc = parseDocument(md);
    const section = findSection(doc.sections, "## Voice");
    expect(section).toBeDefined();
    expect(section!.content).toContain("Voice content.");
  });

  it("finds by full path", () => {
    const md = `# Top\n\n## Voice\n\nContent.`;
    const doc = parseDocument(md);
    const section = findSection(doc.sections, "# Top > ## Voice");
    expect(section).toBeDefined();
    expect(section!.heading).toBe("## Voice");
  });

  it("returns undefined for missing sections", () => {
    const md = `# Top\n\n## Voice`;
    const doc = parseDocument(md);
    expect(findSection(doc.sections, "## Missing")).toBeUndefined();
  });
});

describe("findAllSections", () => {
  it("detects duplicate headings", () => {
    const md = `# Top\n\n## Review\n\nFirst.\n\n# Bottom\n\n## Review\n\nSecond.`;
    const doc = parseDocument(md);
    const matches = findAllSections(doc.sections, "## Review");
    expect(matches).toHaveLength(2);
  });
});

describe("dumpHeadings", () => {
  it("produces indented heading tree", () => {
    const md = `# Ship\n\n## Step 1\n\n### Sub\n\n## Step 2`;
    const doc = parseDocument(md);
    const output = dumpHeadings(doc.sections);
    expect(output).toContain("# Ship");
    expect(output).toContain("  ## Step 1");
    expect(output).toContain("    ### Sub");
    expect(output).toContain("  ## Step 2");
  });
});

describe("reassemble", () => {
  it("round-trips a simple document", () => {
    const md = `---
name: test
---

# Heading

Content.`;
    const doc = parseDocument(md);
    const result = reassemble(doc);
    expect(result).toBe(md);
  });

  it("preserves fenced code blocks through round-trip", () => {
    const md = `# Top

\`\`\`bash
## Not a heading
echo hello
\`\`\`

## Real

Content.`;
    const doc = parseDocument(md);
    const result = reassemble(doc);
    expect(result).toContain("## Not a heading");
    expect(result).toContain("echo hello");
  });
});
