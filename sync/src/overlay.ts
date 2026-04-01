import { readFileSync } from "fs";
import { join } from "path";
import type {
  ParsedDoc,
  OverlayConfig,
  SkillConfig,
  DriftError,
  Section,
} from "./types.js";
import { parseDocument, findSection, findAllSections } from "./parser.js";

const PREAMBLE_BEGIN = "<!-- BEGIN MANAGED PREAMBLE -->";
const PREAMBLE_END = "<!-- END MANAGED PREAMBLE -->";

/**
 * Read an overlay file relative to the overlays directory.
 * Replaces {{SKILL_NAME}} with the actual steez skill name (e.g., "steez-ship").
 */
function readOverlay(config: OverlayConfig, filename: string, skillName?: string): string {
  const overlayDir = join(config.upstream, "..", "overlays");
  let content = readFileSync(join(overlayDir, filename), "utf-8").trimEnd();
  if (skillName) {
    const steezName = skillName.startsWith(config.frontmatter.namePrefix)
      ? skillName
      : `${config.frontmatter.namePrefix}${skillName}`;
    content = content.replaceAll("{{SKILL_NAME}}", steezName);
  }
  return content;
}

/**
 * Apply the full overlay pipeline to a gstack-derived skill.
 *
 * Operation order (from GOLDEN_BASELINE.md):
 * 1. Frontmatter transforms
 * 2. Section deletes
 * 3. Section replacements
 * 4. Section injections
 * 5. Global string replacements (on upstream-origin content only, NOT overlay files)
 * 6. Per-skill string replacements
 * 7. Reassemble
 */
export function applyOverlay(
  doc: ParsedDoc,
  config: OverlayConfig,
  skillName: string,
  skillConfig?: SkillConfig
): string {
  // Work on mutable copies of sections
  let sections = doc.sections.map((s) => ({ ...s }));
  let frontmatter = doc.frontmatter;
  let preambleContent = doc.preambleContent;

  // --- 1. Frontmatter transforms ---
  frontmatter = transformFrontmatter(frontmatter, config, skillName);

  // --- 2. Section deletes (global + per-skill) ---
  const allDeletes = [
    ...config.global.deleteSection,
    ...(skillConfig?.deleteSection ?? []),
  ];
  for (const op of allDeletes) {
    const idx = sections.findIndex(
      (s) => s.heading === op.path || s.fullPath === op.path
    );
    if (idx === -1) {
      if (!op.optional) {
        throw new Error(
          `[${skillName}] Section not found for delete: "${op.path}" (add optional: true if expected)`
        );
      }
      continue;
    }
    // Delete this section and all child sections (lower-level headings until next same/higher level)
    const level = sections[idx].level;
    let end = idx + 1;
    while (end < sections.length && sections[end].level > level) {
      end++;
    }
    sections.splice(idx, end - idx);
  }

  // --- 3. Section replacements (global + per-skill) ---
  const allReplacements = [
    ...config.global.replaceSection,
    ...(skillConfig?.replaceSection ?? []),
  ];
  for (const op of allReplacements) {
    const idx = sections.findIndex(
      (s) => s.heading === op.path || s.fullPath === op.path
    );
    if (idx === -1) {
      if (!op.optional) {
        throw new Error(
          `[${skillName}] Section not found for replace: "${op.path}"`
        );
      }
      continue;
    }
    if (!op.file) {
      throw new Error(
        `[${skillName}] Replace op for "${op.path}" missing file path`
      );
    }
    const overlayContent = readOverlay(config, op.file, skillName);
    // Replace content but keep the section entry for ordering
    // The overlay file includes its own heading
    const level = sections[idx].level;
    let end = idx + 1;
    while (end < sections.length && sections[end].level > level) {
      end++;
    }
    // Replace the section range with a single section containing the overlay content
    const replacement: Section = {
      heading: sections[idx].heading,
      level: sections[idx].level,
      fullPath: sections[idx].fullPath,
      content: overlayContent,
      lineStart: sections[idx].lineStart,
    };
    sections.splice(idx, end - idx, replacement);
  }

  // --- 4. Section injections (global + per-skill) ---
  const allInjections = [
    ...config.global.injectAfter,
    ...(skillConfig?.injectAfter ?? []),
  ];
  for (const op of allInjections) {
    const idx = sections.findIndex(
      (s) => s.heading === op.path || s.fullPath === op.path
    );
    if (idx === -1) {
      if (!op.optional) {
        throw new Error(
          `[${skillName}] Section not found for inject: "${op.path}"`
        );
      }
      continue;
    }
    if (!op.file) {
      throw new Error(
        `[${skillName}] Inject op for "${op.path}" missing file path`
      );
    }
    const overlayContent = readOverlay(config, op.file, skillName);
    // Parse the overlay to determine its heading level
    const overlayHeadingMatch = overlayContent.match(/^(#{1,6})\s+(.+)$/m);
    const injected: Section = {
      heading: overlayHeadingMatch
        ? `${"#".repeat(overlayHeadingMatch[1].length)} ${overlayHeadingMatch[2]}`
        : "## Injected",
      level: overlayHeadingMatch ? overlayHeadingMatch[1].length : 2,
      fullPath: "",
      content: overlayContent,
      lineStart: -1,
    };
    // Find the end of the target section's subtree, then inject after
    const level = sections[idx].level;
    let insertAt = idx + 1;
    while (insertAt < sections.length && sections[insertAt].level > level) {
      insertAt++;
    }
    sections.splice(insertAt, 0, injected);
  }

  // --- 5. Global string replacements (upstream content only) ---
  // Mark which sections are overlay-injected/replaced so we skip them
  const overlayIndices = new Set<number>();
  for (const op of [...allReplacements, ...allInjections]) {
    const idx = sections.findIndex(
      (s) => s.heading === op.path || s.fullPath === op.path || s.content === readOverlay(config, op.file!, skillName).trimEnd()
    );
    if (idx !== -1) overlayIndices.add(idx);
  }

  for (const rep of config.global.replace) {
    // Apply to frontmatter
    frontmatter = replaceAll(frontmatter, rep.from, rep.to);
    // Apply to preamble content
    preambleContent = replaceAll(preambleContent, rep.from, rep.to);
    // Apply to non-overlay sections only
    for (let i = 0; i < sections.length; i++) {
      if (!overlayIndices.has(i)) {
        sections[i].content = replaceAll(sections[i].content, rep.from, rep.to);
      }
    }
  }

  // --- 6. Per-skill string replacements ---
  if (skillConfig?.replace) {
    for (const rep of skillConfig.replace) {
      frontmatter = replaceAll(frontmatter, rep.from, rep.to);
      preambleContent = replaceAll(preambleContent, rep.from, rep.to);
      for (let i = 0; i < sections.length; i++) {
        if (!overlayIndices.has(i)) {
          sections[i].content = replaceAll(sections[i].content, rep.from, rep.to);
        }
      }
    }
  }

  // --- 7. Reassemble ---
  const parts: string[] = [];
  if (frontmatter) {
    parts.push(`---\n${frontmatter}\n---`);
  }
  if (preambleContent.trim()) {
    parts.push(preambleContent);
  }
  for (const section of sections) {
    parts.push(section.content);
  }

  return parts.join("\n") + "\n";
}

/**
 * Apply preamble-only transforms to a custom skill.
 *
 * Custom skills don't have an upstream — they're steez-originals.
 * This mode only replaces content between <!-- BEGIN/END MANAGED PREAMBLE --> markers,
 * ensuring custom skills get the same preamble injection as gstack-derived skills.
 */
export function applyPreambleOnly(
  content: string,
  config: OverlayConfig,
  skillName: string
): string {
  const beginIdx = content.indexOf(PREAMBLE_BEGIN);
  const endIdx = content.indexOf(PREAMBLE_END);

  if (beginIdx === -1 || endIdx === -1) {
    throw new Error(
      `[${skillName}] Custom skill missing managed preamble markers. ` +
      `Expected "${PREAMBLE_BEGIN}" and "${PREAMBLE_END}".`
    );
  }

  // Build the new preamble block from config
  const preambleParts = [PREAMBLE_BEGIN];
  for (const section of config.preamble.sections) {
    const overlayContent = readOverlay(config, section.file, skillName);
    preambleParts.push(overlayContent);
  }
  preambleParts.push(PREAMBLE_END);

  const newPreamble = preambleParts.join("\n");

  // Replace everything between (and including) the markers
  const before = content.slice(0, beginIdx);
  const after = content.slice(endIdx + PREAMBLE_END.length);

  return before + newPreamble + after;
}

/**
 * Detect heading drift between upstream and config expectations.
 * Returns errors for missing required headings, duplicates, and unclassified new headings.
 */
export function detectDrift(
  doc: ParsedDoc,
  config: OverlayConfig,
  skillName: string,
  skillConfig?: SkillConfig
): DriftError[] {
  const errors: DriftError[] = [];

  // Check all configured heading paths exist in the document
  const allOps = [
    ...config.global.deleteSection,
    ...config.global.replaceSection,
    ...config.global.injectAfter,
    ...(skillConfig?.deleteSection ?? []),
    ...(skillConfig?.replaceSection ?? []),
    ...(skillConfig?.injectAfter ?? []),
  ];

  for (const op of allOps) {
    const matches = findAllSections(doc.sections, op.path);
    if (matches.length === 0 && !op.optional) {
      errors.push({
        skill: skillName,
        headingPath: op.path,
        reason: "missing",
        message: `Required heading "${op.path}" not found in upstream ${skillName}`,
      });
    }
    if (matches.length > 1) {
      errors.push({
        skill: skillName,
        headingPath: op.path,
        reason: "duplicate",
        message: `Heading "${op.path}" appears ${matches.length} times in ${skillName}`,
      });
    }
  }

  return errors;
}

/**
 * Transform frontmatter YAML according to config rules.
 */
function transformFrontmatter(
  frontmatter: string,
  config: OverlayConfig,
  skillName: string
): string {
  let fm = frontmatter;
  const fmConfig = config.frontmatter;

  // Prefix the name field
  if (fmConfig.namePrefix) {
    fm = fm.replace(
      /^(name:\s*)(.+)$/m,
      `$1${fmConfig.namePrefix}$2`
    );
  }

  // Remove specified fields
  for (const field of fmConfig.removeFields) {
    // Handle both single-line and multi-line YAML values
    fm = fm.replace(new RegExp(`^${field}:.*(?:\\n(?=\\s).*)*\\n?`, "m"), "");
  }

  // Remove substrings from description
  for (const sub of fmConfig.descriptionRemove) {
    fm = fm.replace(sub, "");
  }

  // Per-skill description override
  if (fmConfig.descriptionOverrides[skillName]) {
    // Replace entire description field (handles multi-line | style)
    fm = fm.replace(
      /^description:[\s\S]*?(?=\n\w|\n---|\n$)/m,
      `description: ${fmConfig.descriptionOverrides[skillName]}`
    );
  }

  return fm;
}

/** Simple global string replacement (not regex). */
function replaceAll(text: string, from: string, to: string): string {
  if (!from) return text;
  let result = text;
  let idx = result.indexOf(from);
  while (idx !== -1) {
    result = result.slice(0, idx) + to + result.slice(idx + from.length);
    idx = result.indexOf(from, idx + to.length);
  }
  return result;
}
