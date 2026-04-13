/**
 * Unit tests for ns script-log command.
 *
 * Spins up a test server that serves both the NS form fixture and a mock
 * SuiteQL REST endpoint returning script execution log entries.
 */

import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { BrowserManager } from '../../core/browser-manager';
import { nsScriptLog } from '../commands/ns-script-log';
import * as path from 'path';
import * as fs from 'fs';

// ─── Mock data ────────────────────────────────────────────

const FIXTURES_DIR = path.resolve(import.meta.dir, 'fixtures');

const MOCK_LOG_ENTRIES = [
  { date: '2026-04-13 10:30:00', level: 'DEBUG', detail: 'pageInit fired for custform_123', title: 'pageInit' },
  { date: '2026-04-13 10:29:55', level: 'ERROR', detail: 'fieldChanged: Cannot read property x of null', title: 'fieldChanged' },
  { date: '2026-04-13 10:29:50', level: 'AUDIT', detail: 'Script loaded successfully', title: 'init' },
];

// ─── Test server with SuiteQL mock ────────────────────────

function startTestServer(port: number = 0) {
  const server = Bun.serve({
    port,
    hostname: '127.0.0.1',
    async fetch(req) {
      const url = new URL(req.url);

      if (req.method === 'POST' && url.pathname === '/services/rest/query/v1/suiteql') {
        const body = await req.json() as { q?: string };
        const sql = body.q ?? '';

        // Script with no logs
        if (sql.includes("'custscript_empty'")) {
          return new Response(JSON.stringify({ items: [], totalResults: 0, hasMore: false }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          });
        }

        // SuiteQL error
        if (sql.includes("'custscript_bad_table'")) {
          return new Response(
            JSON.stringify({
              'o:errorCode': 'INVALID_SEARCH',
              'o:errorDetails': [{ detail: 'Invalid search: record not found' }],
            }),
            { status: 400, headers: { 'Content-Type': 'application/json' } },
          );
        }

        // Level filter: return only matching entries
        const levelMatch = sql.match(/sel\.type = '(\w+)'/);
        if (levelMatch) {
          const filtered = MOCK_LOG_ENTRIES.filter(e => e.level === levelMatch[1]);
          return new Response(JSON.stringify({ items: filtered, totalResults: filtered.length, hasMore: false }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          });
        }

        // Default: return all mock entries
        return new Response(JSON.stringify({ items: MOCK_LOG_ENTRIES, totalResults: 3, hasMore: false }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // Static fixture files
      let filePath = url.pathname === '/' ? '/ns-form.html' : url.pathname;
      filePath = filePath.replace(/^\//, '');
      const fullPath = path.join(FIXTURES_DIR, filePath);

      if (!fs.existsSync(fullPath)) {
        return new Response('Not Found', { status: 404 });
      }

      const content = fs.readFileSync(fullPath, 'utf-8');
      return new Response(content, { headers: { 'Content-Type': 'text/html' } });
    },
  });
  return { server, url: `http://127.0.0.1:${server.port}` };
}

let testServer: ReturnType<typeof startTestServer>;
let bm: BrowserManager;
let baseUrl: string;

beforeAll(async () => {
  testServer = startTestServer(0);
  baseUrl = testServer.url;
  bm = new BrowserManager();
  await bm.launch();
  await bm.getPage().goto(baseUrl + '/ns-form.html');
});

afterAll(() => {
  try { testServer.server.stop(); } catch {}
  setTimeout(() => process.exit(0), 500);
});

// ─── Argument validation ──────────────────────────────────

describe('ns script-log — validation', () => {
  test('rejects missing script ID', async () => {
    const output = await nsScriptLog([], bm);
    expect(output.ok).toBe(false);
    expect(output.display).toContain('Missing script ID');
  });

  test('rejects invalid log level', async () => {
    const output = await nsScriptLog(['custscript_test', '--level', 'WARN'], bm);
    expect(output.ok).toBe(false);
    expect(output.display).toContain('Invalid log level');
  });
});

// ─── Successful execution ─────────────────────────────────

describe('ns script-log — execution', () => {
  test('fetches log entries as NDJSON', async () => {
    const output = await nsScriptLog(['custscript_est_gp'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('SCRIPT-LOG OK');
    expect(output.display).toContain('custscript_est_gp');
    expect(output.display).toContain('Entries: 3');

    const lines = output.display.split('\n');
    expect(lines.length).toBe(4); // header + 3 entries
    const first = JSON.parse(lines[1]);
    expect(first.level).toBe('DEBUG');
    expect(first.detail).toContain('pageInit');
  });

  test('filters by log level', async () => {
    const output = await nsScriptLog(['custscript_est_gp', '--level', 'ERROR'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('SCRIPT-LOG OK');

    const lines = output.display.split('\n');
    expect(lines.length).toBe(2); // header + 1 ERROR entry
    const entry = JSON.parse(lines[1]);
    expect(entry.level).toBe('ERROR');
  });

  test('handles empty results', async () => {
    const output = await nsScriptLog(['custscript_empty'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('No log entries found');
  });

  test('handles SuiteQL error', async () => {
    const output = await nsScriptLog(['custscript_bad_table'], bm);

    expect(output.ok).toBe(false);
    expect(output.display).toContain('SuiteQL error');
  });

  test('accepts case-insensitive level flag', async () => {
    const output = await nsScriptLog(['custscript_est_gp', '--level', 'error'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('SCRIPT-LOG OK');
  });
});

// ─── guardNsApi gating ───────────────────────────────────

describe('ns script-log — guardNsApi', () => {
  test('fails on a page without NS API', async () => {
    const page = bm.getPage();
    await page.goto('about:blank');

    const output = await nsScriptLog(['custscript_test'], bm);

    expect(output.ok).toBe(false);
    expect(output.display).toContain('NotARecordPage');

    await page.goto(baseUrl + '/ns-form.html');
  });
});
