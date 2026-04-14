/**
 * Unit tests for ns script-log command.
 *
 * Command pipeline (scraping strategy):
 *   1. Lookup internal id via SuiteQL on the `script` table.
 *   2. Navigate to /app/common/scripting/script.nl?id={internalId}.
 *   3. Scrape rows from #scriptnote__tab in the DOM.
 *
 * The test server mocks both the SuiteQL endpoint and the script record page
 * fixtures (populated / empty).
 */

import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { BrowserManager } from '../../core/browser-manager';
import { nsScriptLog } from '../commands/ns-script-log';
import * as path from 'path';
import * as fs from 'fs';

const FIXTURES_DIR = path.resolve(import.meta.dir, 'fixtures');

// ─── Test server: SuiteQL mock + fixture routing ──────────────

function startTestServer(port: number = 0) {
  const server = Bun.serve({
    port,
    hostname: '127.0.0.1',
    async fetch(req) {
      const url = new URL(req.url);

      // SuiteQL mock: scriptid → internal id lookup
      if (req.method === 'POST' && url.pathname === '/services/rest/query/v1/suiteql') {
        const body = await req.json() as { q?: string };
        const sql = body.q ?? '';

        const match = sql.match(/scriptid = '([^']+)'/);
        const scriptid = match?.[1];

        if (scriptid === 'custscript_bad_table') {
          return new Response(
            JSON.stringify({ 'o:errorDetails': [{ detail: 'Invalid search' }] }),
            { status: 400, headers: { 'Content-Type': 'application/json' } },
          );
        }

        const idMap: Record<string, string> = {
          custscript_populated: '999',
          custscript_empty: '888',
        };
        const internalId = scriptid ? idMap[scriptid] : undefined;

        if (!internalId) {
          return new Response(JSON.stringify({ items: [] }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          });
        }
        return new Response(JSON.stringify({ items: [{ id: internalId }] }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // Script record page routing
      if (url.pathname === '/app/common/scripting/script.nl') {
        const id = url.searchParams.get('id');
        const fixtureMap: Record<string, string> = {
          '999': 'ns-script-log-populated.html',
          '888': 'ns-script-log-empty.html',
        };
        const fixture = id ? fixtureMap[id] : undefined;
        if (!fixture) {
          return new Response('Script not found', { status: 404 });
        }
        const content = fs.readFileSync(path.join(FIXTURES_DIR, fixture), 'utf-8');
        return new Response(content, { headers: { 'Content-Type': 'text/html' } });
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

// Helper: restore the initial page between tests that leave the browser on
// a script record fixture.
async function resetPage() {
  await bm.getPage().goto(baseUrl + '/ns-form.html');
}

// ─── Argument validation ──────────────────────────────────

describe('ns script-log — validation', () => {
  test('rejects missing script ID', async () => {
    const output = await nsScriptLog([], bm);
    expect(output.ok).toBe(false);
    expect(output.display).toContain('Missing script ID');
  });

  test('rejects invalid script ID format (SQL injection attempt)', async () => {
    const output = await nsScriptLog(["custscript'; DROP TABLE--"], bm);
    expect(output.ok).toBe(false);
    expect(output.display).toContain('Invalid script ID');
  });

  test('rejects invalid log level', async () => {
    const output = await nsScriptLog(['custscript_populated', '--level', 'WARN'], bm);
    expect(output.ok).toBe(false);
    expect(output.display).toContain('Invalid log level');
  });
});

// ─── Scraping behavior ────────────────────────────────────

describe('ns script-log — scraping', () => {
  test('fetches log entries as NDJSON', async () => {
    await resetPage();
    const output = await nsScriptLog(['custscript_populated'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('SCRIPT-LOG OK');
    expect(output.display).toContain('custscript_populated');
    expect(output.display).toContain('Entries: 3');

    const lines = output.display.split('\n');
    expect(lines.length).toBe(4); // header + 3 entries

    const first = JSON.parse(lines[1]);
    expect(first.level).toBe('DEBUG');
    expect(first.title).toBe('pageInit');
    expect(first.detail).toContain('pageInit fired');
    expect(first.date).toContain('4/13/2026');
    expect(first.date).toContain('10:30:00');
    expect(first.user).toBe('Test User');
  });

  test('filters by log level client-side', async () => {
    await resetPage();
    const output = await nsScriptLog(['custscript_populated', '--level', 'ERROR'], bm);

    expect(output.ok).toBe(true);
    const lines = output.display.split('\n');
    expect(lines.length).toBe(2); // header + 1 ERROR entry
    const entry = JSON.parse(lines[1]);
    expect(entry.level).toBe('ERROR');
  });

  test('accepts case-insensitive level flag', async () => {
    await resetPage();
    const output = await nsScriptLog(['custscript_populated', '--level', 'error'], bm);

    expect(output.ok).toBe(true);
    const lines = output.display.split('\n');
    expect(lines.length).toBe(2);
    expect(JSON.parse(lines[1]).level).toBe('ERROR');
  });

  test('respects --limit', async () => {
    await resetPage();
    const output = await nsScriptLog(['custscript_populated', '--limit', '2'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('Entries: 2');
    const lines = output.display.split('\n');
    expect(lines.length).toBe(3); // header + 2 entries
  });

  test('handles empty results', async () => {
    await resetPage();
    const output = await nsScriptLog(['custscript_empty'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('No log entries found');
  });

  test('handles unknown script ID', async () => {
    await resetPage();
    const output = await nsScriptLog(['custscript_nonexistent'], bm);

    expect(output.ok).toBe(false);
    expect(output.display).toContain('Script not found');
  });

  test('surfaces SuiteQL lookup errors', async () => {
    await resetPage();
    const output = await nsScriptLog(['custscript_bad_table'], bm);

    expect(output.ok).toBe(false);
    expect(output.display).toContain('Failed to resolve script id');
  });
});

// ─── guardNsApi gating ───────────────────────────────────

describe('ns script-log — guardNsApi', () => {
  test('fails on a page without NS API', async () => {
    const page = bm.getPage();
    await page.goto('about:blank');

    const output = await nsScriptLog(['custscript_populated'], bm);

    expect(output.ok).toBe(false);
    expect(output.display).toContain('NotARecordPage');

    await page.goto(baseUrl + '/ns-form.html');
  });
});
