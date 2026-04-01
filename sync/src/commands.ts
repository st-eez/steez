import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from "fs";
import { join, basename } from "path";
import { parseDocument, dumpHeadings } from "./parser.js";
import { applyOverlay, applyPreambleOnly, detectDrift } from "./overlay.js";
import type { OverlayConfig, SkillConfig, DriftError } from "./types.js";

/** Resolve a path relative to the config file's directory. */
function resolve(configDir: string, relPath: string): string {
  return join(configDir, relPath);
}

/** Load config.json from a directory. */
export function loadConfig(configDir: string): OverlayConfig {
  const raw = readFileSync(join(configDir, "config.json"), "utf-8");
  return JSON.parse(raw) as OverlayConfig;
}

/** Get the list of upstream SKILL.md files. */
function getUpstreamSkills(config: OverlayConfig, configDir: string): string[] {
  const upstreamDir = resolve(configDir, config.upstream);
  if (!existsSync(upstreamDir)) return [];
  return readdirSync(upstreamDir)
    .filter((f) => f.endsWith(".md"))
    .map((f) => f.replace(/\.md$/, ""))
    .sort();
}

/** Get the list of custom (steez-only) skills from the skills directory. */
function getCustomSkills(config: OverlayConfig): string[] {
  return Object.entries(config.skills)
    .filter(([_, sc]) => sc.custom)
    .map(([name]) => name)
    .sort();
}

/**
 * Sync all gstack-derived skills: read upstream, apply overlay, write output.
 */
export function syncSkills(configDir: string, config: OverlayConfig): {
  synced: string[];
  skipped: string[];
  errors: Array<{ skill: string; error: string }>;
} {
  const upstreamDir = resolve(configDir, config.upstream);
  const outputDir = resolve(configDir, config.output);
  mkdirSync(outputDir, { recursive: true });

  const upstreamSkills = getUpstreamSkills(config, configDir);
  const synced: string[] = [];
  const skipped: string[] = [];
  const errors: Array<{ skill: string; error: string }> = [];

  for (const skill of upstreamSkills) {
    const skillConfig = config.skills[skill];

    // Handle skip
    if (skillConfig?.skip) {
      skipped.push(skill);
      continue;
    }

    // Handle unconfigured skills
    if (!skillConfig && config.newSkillPolicy !== "ignore") {
      const msg = `New upstream skill "${skill}" not configured in config.json`;
      if (config.newSkillPolicy === "error") {
        errors.push({ skill, error: msg });
      } else {
        console.warn(`WARN: ${msg}`);
      }
      continue;
    }

    try {
      const md = readFileSync(join(upstreamDir, `${skill}.md`), "utf-8");
      const doc = parseDocument(md);

      // Drift detection
      const driftErrors = detectDrift(doc, config, skill, skillConfig);
      if (driftErrors.length > 0) {
        for (const de of driftErrors) {
          errors.push({ skill: de.skill, error: de.message });
        }
        continue;
      }

      // Apply overlay
      const result = applyOverlay(doc, config, skill, skillConfig);

      // Write output
      const skillDir = join(outputDir, skill);
      mkdirSync(skillDir, { recursive: true });
      writeFileSync(join(skillDir, "SKILL.md"), result);
      synced.push(skill);
    } catch (err) {
      errors.push({
        skill,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return { synced, skipped, errors };
}

/**
 * Sync custom (steez-only) skills: apply preamble-only transforms.
 */
export function syncCustomSkills(
  configDir: string,
  config: OverlayConfig,
  skillsDir: string
): {
  synced: string[];
  errors: Array<{ skill: string; error: string }>;
} {
  const outputDir = resolve(configDir, config.output);
  mkdirSync(outputDir, { recursive: true });

  const customSkills = getCustomSkills(config);
  const synced: string[] = [];
  const errors: Array<{ skill: string; error: string }> = [];

  for (const skill of customSkills) {
    try {
      const skillMd = join(skillsDir, skill, "SKILL.md");
      if (!existsSync(skillMd)) {
        errors.push({ skill, error: `Custom skill file not found: ${skillMd}` });
        continue;
      }

      const content = readFileSync(skillMd, "utf-8");
      const result = applyPreambleOnly(content, config, skill);

      const skillDir = join(outputDir, skill);
      mkdirSync(skillDir, { recursive: true });
      writeFileSync(join(skillDir, "SKILL.md"), result);
      synced.push(skill);
    } catch (err) {
      errors.push({
        skill,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return { synced, errors };
}

/**
 * Check for drift without writing any files.
 */
export function checkDrift(configDir: string, config: OverlayConfig): DriftError[] {
  const upstreamDir = resolve(configDir, config.upstream);
  const allErrors: DriftError[] = [];

  const upstreamSkills = getUpstreamSkills(config, configDir);
  for (const skill of upstreamSkills) {
    const skillConfig = config.skills[skill];
    if (skillConfig?.skip || skillConfig?.custom) continue;

    try {
      const md = readFileSync(join(upstreamDir, `${skill}.md`), "utf-8");
      const doc = parseDocument(md);
      allErrors.push(...detectDrift(doc, config, skill, skillConfig));
    } catch {
      // Skip files that can't be read
    }
  }

  return allErrors;
}

/**
 * Dump all headings for all upstream skills.
 */
export function dumpAllHeadings(configDir: string, config: OverlayConfig): string {
  const upstreamDir = resolve(configDir, config.upstream);
  const upstreamSkills = getUpstreamSkills(config, configDir);
  const parts: string[] = [];

  for (const skill of upstreamSkills) {
    const skillConfig = config.skills[skill];
    if (skillConfig?.skip) continue;

    try {
      const md = readFileSync(join(upstreamDir, `${skill}.md`), "utf-8");
      const doc = parseDocument(md);
      parts.push(`=== ${skill} (${doc.sections.length} headings) ===`);
      parts.push(dumpHeadings(doc.sections));
      parts.push("");
    } catch {
      parts.push(`=== ${skill} (error reading) ===`);
    }
  }

  return parts.join("\n");
}

/**
 * Show what would change (diff command output).
 */
export function diffSkills(
  configDir: string,
  config: OverlayConfig,
  currentSkillsDir: string
): string {
  const outputDir = resolve(configDir, config.output);
  const lines: string[] = [];

  const upstreamSkills = getUpstreamSkills(config, configDir);
  for (const skill of upstreamSkills) {
    const skillConfig = config.skills[skill];
    if (skillConfig?.skip) continue;

    const generatedPath = join(outputDir, skill, "SKILL.md");
    const currentPath = join(currentSkillsDir, skill, "SKILL.md");

    if (!existsSync(generatedPath)) {
      lines.push(`${skill}: not yet generated (run 'skills' first)`);
      continue;
    }
    if (!existsSync(currentPath)) {
      lines.push(`${skill}: NEW (no current version)`);
      continue;
    }

    const generated = readFileSync(generatedPath, "utf-8");
    const current = readFileSync(currentPath, "utf-8");

    if (generated === current) {
      lines.push(`${skill}: identical`);
    } else {
      // Count differing lines
      const genLines = generated.split("\n");
      const curLines = current.split("\n");
      let diffs = 0;
      const maxLen = Math.max(genLines.length, curLines.length);
      for (let i = 0; i < maxLen; i++) {
        if (genLines[i] !== curLines[i]) diffs++;
      }
      lines.push(`${skill}: ${diffs} lines differ (generated: ${genLines.length}, current: ${curLines.length})`);
    }
  }

  return lines.join("\n");
}
