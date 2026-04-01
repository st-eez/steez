import type { Section, ParsedDoc } from "./types.js";

const HEADING_RE = /^(#{1,6})\s+(.+)$/;
const FENCE_RE = /^(`{3,}|~{3,})/;
const FRONTMATTER_DELIM = "---";

/**
 * Parse a SKILL.md file into structured sections with fence-aware heading detection.
 *
 * Key invariant: lines inside fenced code blocks (``` or ~~~) are NEVER treated as
 * headings. gstack's office-hours SKILL.md has 34 ## headings inside code fences —
 * a naive regex would break catastrophically.
 */
export function parseDocument(markdown: string): ParsedDoc {
  const lines = markdown.split("\n");
  let cursor = 0;

  // --- Extract frontmatter ---
  let frontmatter = "";
  if (lines[cursor]?.trim() === FRONTMATTER_DELIM) {
    cursor++; // skip opening ---
    const fmStart = cursor;
    while (cursor < lines.length && lines[cursor]?.trim() !== FRONTMATTER_DELIM) {
      cursor++;
    }
    frontmatter = lines.slice(fmStart, cursor).join("\n");
    cursor++; // skip closing ---
  }

  // --- Scan for headings (fence-aware) ---
  let insideFence = false;
  let fenceMarker = ""; // track which marker opened the fence for proper nesting
  const headingIndices: Array<{ line: number; level: number; text: string }> = [];

  // Content between frontmatter and first heading
  let preambleContentEnd = lines.length;

  for (let i = cursor; i < lines.length; i++) {
    const line = lines[i];

    // Toggle fence state
    const fenceMatch = line.match(FENCE_RE);
    if (fenceMatch) {
      if (!insideFence) {
        insideFence = true;
        fenceMarker = fenceMatch[1][0]; // ` or ~
      } else if (line.startsWith(fenceMarker[0].repeat(3))) {
        // Only close if same marker type (``` closes ```, ~~~ closes ~~~)
        insideFence = false;
        fenceMarker = "";
      }
      continue;
    }

    // Only detect headings outside fences
    if (!insideFence) {
      const headingMatch = line.match(HEADING_RE);
      if (headingMatch) {
        if (headingIndices.length === 0) {
          preambleContentEnd = i;
        }
        headingIndices.push({
          line: i,
          level: headingMatch[1].length,
          text: `${"#".repeat(headingMatch[1].length)} ${headingMatch[2]}`,
        });
      }
    }
  }

  // --- Build preamble content (between frontmatter and first heading) ---
  const preambleContent = lines.slice(cursor, preambleContentEnd).join("\n");

  // --- Build sections with ancestor-qualified paths ---
  const sections: Section[] = [];
  const ancestorStack: Array<{ level: number; heading: string }> = [];

  for (let idx = 0; idx < headingIndices.length; idx++) {
    const { line: lineStart, level, text: heading } = headingIndices[idx];
    const nextStart = idx + 1 < headingIndices.length ? headingIndices[idx + 1].line : lines.length;
    const content = lines.slice(lineStart, nextStart).join("\n");

    // Maintain ancestor stack for fullPath computation
    while (ancestorStack.length > 0 && ancestorStack[ancestorStack.length - 1].level >= level) {
      ancestorStack.pop();
    }

    const fullPath = ancestorStack.length > 0
      ? [...ancestorStack.map((a) => a.heading), heading].join(" > ")
      : heading;

    ancestorStack.push({ level, heading });

    sections.push({ heading, level, fullPath, content, lineStart });
  }

  return { frontmatter, preambleContent, sections, raw: markdown };
}

/**
 * Find a section by heading text match.
 * Matches against both the heading field and the fullPath field.
 * Returns the first match.
 */
export function findSection(sections: Section[], headingPath: string): Section | undefined {
  return sections.find(
    (s) => s.heading === headingPath || s.fullPath === headingPath
  );
}

/**
 * Find all sections matching a heading text.
 * Used for duplicate detection.
 */
export function findAllSections(sections: Section[], headingPath: string): Section[] {
  return sections.filter(
    (s) => s.heading === headingPath || s.fullPath === headingPath
  );
}

/**
 * Pretty-print all heading paths for debugging.
 */
export function dumpHeadings(sections: Section[]): string {
  return sections
    .map((s) => `${"  ".repeat(s.level - 1)}${s.heading} (L${s.lineStart + 1})`)
    .join("\n");
}

/**
 * Reassemble a document from its parsed parts.
 * This is the inverse of parseDocument — used after overlay transforms.
 */
export function reassemble(doc: ParsedDoc): string {
  const parts: string[] = [];

  // Frontmatter
  if (doc.frontmatter) {
    parts.push(`---\n${doc.frontmatter}\n---`);
  }

  // Pre-heading content (always include — preserves blank line between frontmatter and first heading)
  parts.push(doc.preambleContent);

  // Sections
  for (const section of doc.sections) {
    parts.push(section.content);
  }

  return parts.join("\n");
}
