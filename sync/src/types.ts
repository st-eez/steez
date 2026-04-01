/** A markdown section parsed by the fence-aware heading scanner. */
export interface Section {
  /** Raw heading text, e.g. "## Voice" */
  heading: string;
  /** Heading depth: 1 for #, 2 for ##, etc. */
  level: number;
  /** Ancestor-qualified path, e.g. "# Ship > ## Voice" */
  fullPath: string;
  /** Everything between this heading and the next heading at same/higher level (including the heading line itself) */
  content: string;
  /** 0-based line index where the heading appears in the original document */
  lineStart: number;
}

/** Result of parsing a SKILL.md file. */
export interface ParsedDoc {
  /** Raw YAML between the opening and closing --- markers (without the markers themselves) */
  frontmatter: string;
  /** Content before the first heading (after frontmatter). Includes comments, blank lines, etc. */
  preambleContent: string;
  /** Fence-aware parsed sections */
  sections: Section[];
  /** Raw source text, preserved for reassembly */
  raw: string;
}

/** A single overlay operation in config.json. */
export interface SectionOp {
  /** Heading path to match, e.g. "## Contributor Mode" or "# Ship > ## Step 3.8" */
  path: string;
  /** If true, don't error when the heading is missing (for sections that only exist in some skills) */
  optional?: boolean;
  /** For replace/inject: path to overlay .md file (relative to overlays/) */
  file?: string;
}

/** Frontmatter transform rules. */
export interface FrontmatterConfig {
  /** Prefix to add to the name field, e.g. "steez-" */
  namePrefix: string;
  /** Fields to remove entirely from frontmatter */
  removeFields: string[];
  /** Substrings to remove from the description field */
  descriptionRemove: string[];
  /** Per-skill description overrides (skill name → full description string) */
  descriptionOverrides: Record<string, string>;
}

/** Per-skill overlay configuration. */
export interface SkillConfig {
  /** Skip this skill entirely (gstack-only skills) */
  skip?: boolean;
  /** Custom skill — preamble-only mode (no upstream, no string replacements) */
  custom?: boolean;
  /** Per-skill section injections */
  injectAfter?: SectionOp[];
  /** Per-skill section replacements */
  replaceSection?: SectionOp[];
  /** Per-skill section deletes */
  deleteSection?: SectionOp[];
  /** Per-skill string replacements (applied after global replacements) */
  replace?: Array<{ from: string; to: string }>;
}

/** Top-level overlay configuration. */
export interface OverlayConfig {
  /** Path to upstream pinned SKILL.md files */
  upstream: string;
  /** Path to write generated output */
  output: string;
  /** Pinning manifest */
  pin: {
    source: string;
    tag: string;
    sha: string;
    timestamp: string;
  };
  /** Global transforms applied to all gstack-derived skills */
  global: {
    replace: Array<{ from: string; to: string }>;
    deleteSection: SectionOp[];
    replaceSection: SectionOp[];
    injectAfter: SectionOp[];
  };
  /** Frontmatter transform rules */
  frontmatter: FrontmatterConfig;
  /** Managed preamble markers and content (shared by all 33 skills) */
  preamble: {
    beginMarker: string;
    endMarker: string;
    /** Sections that compose the managed preamble block, in order */
    sections: Array<{ name: string; file: string }>;
  };
  /** Per-skill configuration */
  skills: Record<string, SkillConfig>;
  /** What to do when upstream has a skill not listed in config */
  newSkillPolicy: "warn" | "error" | "ignore";
}

/** Drift detection error. */
export interface DriftError {
  skill: string;
  headingPath: string;
  reason: "missing" | "duplicate" | "new_unclassified";
  message: string;
}
