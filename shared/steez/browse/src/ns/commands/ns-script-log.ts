/**
 * ns script-log — Fetch SuiteScript execution logs by scraping the
 * Script record page's Execution Log sublist.
 *
 * Usage:
 *   ns script-log custscript_est_gp
 *   ns script-log custscript_est_gp --level ERROR
 *   ns script-log custscript_est_gp --limit 50
 *
 * The scriptexecutionlog table is not exposed via SuiteQL analytics, so this
 * command:
 *   1. Resolves scriptid → internal id via SuiteQL on the `script` table.
 *   2. Navigates to /app/common/scripting/script.nl?id={internalId}.
 *   3. Activates the Execution Log sublist and waits for rows to populate.
 *   4. Parses rows from the #scriptnote__tab table in the DOM.
 *   5. Applies --level / --limit filters client-side.
 *
 * Side effect: navigates the browser to the script record page. Call sites
 * that need to preserve the current page should capture the URL first.
 */

import type { BrowserManager } from '../../core/browser-manager';
import type { NsCommandOutput } from '../format';
import { formatNsError } from '../format';
import { guardNsApi, validationError, notARecordPage } from '../errors';
import { withMutex, nsMutex } from '../mutex';
import { executeSuiteQL } from '../utils/suiteql';

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 200;
const LOAD_TIMEOUT_MS = 10000;

const VALID_LEVELS = new Set(['DEBUG', 'AUDIT', 'ERROR', 'EMERGENCY', 'SYSTEM']);
const VALID_SCRIPT_ID = /^[a-zA-Z0-9_]+$/;

interface ParsedArgs {
  scriptId: string | null;
  level: string | null;
  limit: number;
}

interface LogEntry {
  date: string;
  level: string;
  title: string;
  detail: string;
  user: string;
}

function parseArgs(args: string[]): ParsedArgs {
  let scriptId: string | null = null;
  let level: string | null = null;
  let limit = DEFAULT_LIMIT;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--level') {
      level = (args[++i] ?? '').toUpperCase();
    } else if (arg === '--limit') {
      const n = parseInt(args[++i], 10);
      if (!isNaN(n) && n > 0) limit = Math.min(n, MAX_LIMIT);
    } else if (!scriptId) {
      scriptId = arg;
    }
  }

  return { scriptId, level, limit };
}

export async function nsScriptLog(args: string[], bm: BrowserManager): Promise<NsCommandOutput> {
  const { scriptId, level, limit } = parseArgs(args);

  if (!scriptId) {
    return {
      display: formatNsError('ns script-log', validationError('Missing script ID. Usage: ns script-log <scriptId> [--level DEBUG|AUDIT|ERROR|EMERGENCY|SYSTEM] [--limit N]')),
      ok: false,
    };
  }

  if (!VALID_SCRIPT_ID.test(scriptId)) {
    return {
      display: formatNsError('ns script-log', validationError(`Invalid script ID: ${scriptId}. Must match [a-zA-Z0-9_]+`)),
      ok: false,
    };
  }

  if (level && !VALID_LEVELS.has(level)) {
    return {
      display: formatNsError('ns script-log', validationError(`Invalid log level: ${level}. Valid: DEBUG, AUDIT, ERROR, EMERGENCY, SYSTEM`)),
      ok: false,
    };
  }

  type LogResult =
    | { ok: true; entries: LogEntry[]; truncated: boolean }
    | { ok: false; error: string };

  const result = await withMutex(nsMutex, async (): Promise<LogResult> => {
    const target = bm.getActiveFrameOrPage();
    const apiErr = await guardNsApi(target);
    if (apiErr) {
      return { ok: false, error: formatNsError('ns script-log', apiErr) };
    }

    const page = bm.getPage();

    // ── 1. Resolve scriptid → internal id ────────────────────
    // Safe: scriptId is regex-validated to [a-zA-Z0-9_]+ above.
    const lookupSql = `SELECT id FROM script WHERE scriptid = '${scriptId}'`;
    const lookup = await executeSuiteQL(page, lookupSql);
    if (lookup.error) {
      return { ok: false, error: formatNsError('ns script-log', validationError(`Failed to resolve script id: ${lookup.error}`)) };
    }
    const rows = lookup.items ?? [];
    if (rows.length === 0) {
      return { ok: false, error: formatNsError('ns script-log', validationError(`Script not found: ${scriptId}`)) };
    }
    const internalId = String(rows[0].id);

    // ── 2. Navigate to script page ───────────────────────────
    const origin = new URL(page.url()).origin;
    const scriptUrl = `${origin}/app/common/scripting/script.nl?id=${internalId}`;
    await page.goto(scriptUrl, { waitUntil: 'domcontentloaded', timeout: 15000 });

    // ── 3. Guard: confirm we're on a script record page ──────
    const hasScriptNote = await page.evaluate(() => {
      return !!document.getElementById('scriptnote_layer');
    });
    if (!hasScriptNote) {
      return { ok: false, error: formatNsError('ns script-log', notARecordPage(`Script page did not render Execution Log sublist for id=${internalId}`)) };
    }

    // ── 4. Activate and load the Execution Log sublist ───────
    // NetSuite lazy-loads sublist data via a machine.buildtable() call.
    // Click the tab link (if present) and then force-build the machine.
    await page.evaluate(() => {
      const tab = document.getElementById('executionlogtxt') as HTMLAnchorElement | null;
      if (tab) tab.click();
      const w = window as unknown as { scriptnote_machine?: { buildtable?: () => void } };
      try { w.scriptnote_machine?.buildtable?.(); } catch { /* build is best-effort */ }
      const loadedFlag = document.getElementById('scriptnoteloaded') as HTMLInputElement | null;
      if (loadedFlag) loadedFlag.value = 'T';
    });

    // ── 5. Wait for terminal state ───────────────────────────
    // Terminal: either at least one data row exists, or the loaded flag
    // flips to 'T' confirming the sublist finished loading (empty result).
    // Fall through on timeout — treat as empty.
    await page.waitForFunction(
      () => {
        const tbl = document.getElementById('scriptnote__tab');
        if (!tbl) return false;
        if (tbl.querySelector('tr[id^="scriptnoterow"]')) return true;
        const loaded = document.getElementById('scriptnoteloaded') as HTMLInputElement | null;
        return loaded?.value === 'T';
      },
      { timeout: LOAD_TIMEOUT_MS },
    ).catch(() => { /* empty is a valid outcome */ });

    // ── 6. Scrape rows ───────────────────────────────────────
    const entries = await page.evaluate((): LogEntry[] => {
      const tbl = document.getElementById('scriptnote__tab');
      if (!tbl) return [];
      const rows = Array.from(tbl.querySelectorAll('tr[id^="scriptnoterow"]')) as HTMLTableRowElement[];
      return rows.map(row => {
        const cells = Array.from(row.cells).map(c => (c.textContent ?? '').trim());
        // Column layout: [#, View, Type, Title, Date, Time, User, Details, Remove]
        const level = cells[2] ?? '';
        const title = cells[3] ?? '';
        const date = cells[4] ?? '';
        const time = cells[5] ?? '';
        const user = cells[6] ?? '';
        const detail = cells[7] ?? '';
        const dateTime = [date, time].filter(Boolean).join(' ').trim();
        return { date: dateTime, level, title, user, detail };
      });
    });

    // ── 7. Apply client-side filters ─────────────────────────
    const filtered = level ? entries.filter(e => e.level.toUpperCase() === level) : entries;
    const truncated = filtered.length > limit;
    const sliced = truncated ? filtered.slice(0, limit) : filtered;

    return { ok: true, entries: sliced, truncated };
  }, { label: 'ns script-log' });

  if (!result.ok) {
    return { display: result.error, ok: false };
  }

  const { entries, truncated } = result;

  if (entries.length === 0) {
    const levelNote = level ? ` (level=${level})` : '';
    return {
      display: `SCRIPT-LOG OK | ${scriptId}${levelNote} | No log entries found`,
      ok: true,
    };
  }

  const header = truncated
    ? `SCRIPT-LOG OK | ${scriptId} | Entries: ${entries.length} shown of ${entries.length}+ total`
    : `SCRIPT-LOG OK | ${scriptId} | Entries: ${entries.length}`;

  const lines = entries.map(e => JSON.stringify(e));

  return {
    display: [header, ...lines].join('\n'),
    ok: true,
  };
}
