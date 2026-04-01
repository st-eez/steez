#!/usr/bin/env bun
import { resolve, dirname } from "path";
import {
  loadConfig,
  syncSkills,
  syncCustomSkills,
  checkDrift,
  dumpAllHeadings,
  diffSkills,
} from "./commands.js";

const CONFIG_DIR = dirname(new URL(import.meta.url).pathname).replace("/src", "");
const SKILLS_DIR = resolve(CONFIG_DIR, "..", "skills");

const command = process.argv[2];

function usage(): void {
  console.log(`steez-sync — vendor-and-compose compiler for upstream skill sync

Usage: bun run sync -- <command>

Commands:
  skills      Sync all gstack-derived skills (upstream → overlay → output)
  custom      Sync custom steez-only skills (preamble-only mode)
  all         Sync both gstack-derived and custom skills
  check       Check for upstream heading drift (dry run, no writes)
  headings    Dump all heading paths for upstream skills
  diff        Show what would change vs current skills
  help        Show this help message`);
}

try {
  const config = loadConfig(CONFIG_DIR);

  switch (command) {
    case "skills": {
      const result = syncSkills(CONFIG_DIR, config);
      console.log(`Synced: ${result.synced.length} skills`);
      if (result.skipped.length > 0) {
        console.log(`Skipped: ${result.skipped.join(", ")}`);
      }
      if (result.errors.length > 0) {
        console.error("\nErrors:");
        for (const e of result.errors) {
          console.error(`  ${e.skill}: ${e.error}`);
        }
        process.exit(1);
      }
      break;
    }

    case "custom": {
      const result = syncCustomSkills(CONFIG_DIR, config, SKILLS_DIR);
      console.log(`Synced: ${result.synced.length} custom skills`);
      if (result.errors.length > 0) {
        console.error("\nErrors:");
        for (const e of result.errors) {
          console.error(`  ${e.skill}: ${e.error}`);
        }
        process.exit(1);
      }
      break;
    }

    case "all": {
      const gstack = syncSkills(CONFIG_DIR, config);
      const custom = syncCustomSkills(CONFIG_DIR, config, SKILLS_DIR);
      console.log(`Synced: ${gstack.synced.length} gstack + ${custom.synced.length} custom skills`);
      if (gstack.skipped.length > 0) {
        console.log(`Skipped: ${gstack.skipped.join(", ")}`);
      }
      const allErrors = [...gstack.errors, ...custom.errors];
      if (allErrors.length > 0) {
        console.error("\nErrors:");
        for (const e of allErrors) {
          console.error(`  ${e.skill}: ${e.error}`);
        }
        process.exit(1);
      }
      break;
    }

    case "check": {
      const errors = checkDrift(CONFIG_DIR, config);
      if (errors.length === 0) {
        console.log("No drift detected.");
      } else {
        console.error(`${errors.length} drift error(s):`);
        for (const e of errors) {
          console.error(`  ${e.skill}: ${e.reason} — ${e.message}`);
        }
        process.exit(1);
      }
      break;
    }

    case "headings": {
      console.log(dumpAllHeadings(CONFIG_DIR, config));
      break;
    }

    case "diff": {
      console.log(diffSkills(CONFIG_DIR, config, SKILLS_DIR));
      break;
    }

    case "help":
    case "--help":
    case "-h":
    case undefined: {
      usage();
      break;
    }

    default: {
      console.error(`Unknown command: ${command}`);
      usage();
      process.exit(1);
    }
  }
} catch (err) {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
}
