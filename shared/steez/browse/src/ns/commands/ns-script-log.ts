/**
 * ns script-log — Fetch SuiteScript execution logs via SuiteQL.
 *
 * Usage:
 *   ns script-log custscript_est_gp
 *   ns script-log custscript_est_gp --level ERROR
 *   ns script-log custscript_est_gp --limit 50
 *
 * Queries the scriptexecutionlog table using the authenticated session cookie.
 * Runs in-page via fetch — does not navigate away from the current page.
 */

import type { BrowserManager } from '../../core/browser-manager';
import type { NsCommandOutput } from '../format';
import { formatNsError } from '../format';
import { guardNsApi, validationError } from '../errors';
import { withMutex, nsMutex } from '../mutex';

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 200;

const VALID_LEVELS = new Set(['DEBUG', 'AUDIT', 'ERROR', 'EMERGENCY', 'SYSTEM']);

interface ParsedArgs {
  scriptId: string | null;
  level: string | null;
  limit: number;
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

function buildQuery(scriptId: string, level: string | null, limit: number): string {
  let sql = `SELECT sel.date AS date, sel.type AS level, sel.detail AS detail, sel.title AS title FROM scriptexecutionlog sel JOIN script s ON sel.script = s.id WHERE s.scriptid = '${scriptId}'`;

  if (level) {
    sql += ` AND sel.type = '${level}'`;
  }

  sql += ` ORDER BY sel.date DESC FETCH FIRST ${limit} ROWS ONLY`;
  return sql;
}

interface LogEntry {
  date?: string;
  level?: string;
  detail?: string;
  title?: string;
}

interface SuiteQLResponse {
  error?: string;
  status?: number;
  items?: LogEntry[];
  totalResults?: number;
  hasMore?: boolean;
}

export async function nsScriptLog(args: string[], bm: BrowserManager): Promise<NsCommandOutput> {
  const { scriptId, level, limit } = parseArgs(args);

  if (!scriptId) {
    return {
      display: formatNsError('ns script-log', validationError('Missing script ID. Usage: ns script-log <scriptId> [--level DEBUG|AUDIT|ERROR|EMERGENCY|SYSTEM] [--limit N]')),
      ok: false,
    };
  }

  if (level && !VALID_LEVELS.has(level)) {
    return {
      display: formatNsError('ns script-log', validationError(`Invalid log level: ${level}. Valid: DEBUG, AUDIT, ERROR, EMERGENCY, SYSTEM`)),
      ok: false,
    };
  }

  type QueryResult =
    | { ok: true; entries: LogEntry[]; truncated: boolean }
    | { ok: false; error: string };

  const result = await withMutex(nsMutex, async (): Promise<QueryResult> => {
    const target = bm.getActiveFrameOrPage();
    const apiErr = await guardNsApi(target);
    if (apiErr) {
      return { ok: false, error: formatNsError('ns script-log', apiErr) };
    }

    const page = bm.getPage();
    const sql = buildQuery(scriptId, level, limit + 1);

    const response: SuiteQLResponse = await page.evaluate(
      async ({ sql }: { sql: string }) => {
        try {
          const res = await fetch('/services/rest/query/v1/suiteql', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Prefer': 'transient',
            },
            body: JSON.stringify({ q: sql }),
          });

          if (!res.ok) {
            const text = await res.text().catch(() => `(body unreadable: ${res.statusText})`);
            return { error: text || res.statusText, status: res.status };
          }

          return await res.json();
        } catch (err: any) {
          return { error: err?.message ?? String(err) };
        }
      },
      { sql },
    );

    if (response.error) {
      return { ok: false, error: formatNsError('ns script-log', validationError(`SuiteQL error: ${response.error}`)) };
    }

    const allEntries = (response.items ?? []) as LogEntry[];
    const truncated = allEntries.length > limit;
    const entries = truncated ? allEntries.slice(0, limit) : allEntries;

    return { ok: true, entries, truncated };
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

  const lines = entries.map(e => {
    const cleaned = Object.fromEntries(
      Object.entries(e).filter(([k]) => k !== 'links'),
    );
    return JSON.stringify(cleaned);
  });

  return {
    display: [header, ...lines].join('\n'),
    ok: true,
  };
}
