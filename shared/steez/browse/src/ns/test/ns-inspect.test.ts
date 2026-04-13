/**
 * Tests for ns inspect command.
 */

import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { BrowserManager } from '../../core/browser-manager';
import { nsInspect } from '../commands/ns-inspect';
import * as path from 'path';
import * as fs from 'fs';

// ─── Test server ────────────────────────────────────────────

const FIXTURES_DIR = path.resolve(import.meta.dir, 'fixtures');

function startTestServer(port: number = 0) {
  const server = Bun.serve({
    port,
    hostname: '127.0.0.1',
    fetch(req) {
      const url = new URL(req.url);
      let filePath = url.pathname === '/' ? '/ns-form.html' : url.pathname;
      filePath = filePath.replace(/^\//, '');
      const fullPath = path.join(FIXTURES_DIR, filePath);

      if (!fs.existsSync(fullPath)) {
        return new Response('Not Found', { status: 404 });
      }

      const content = fs.readFileSync(fullPath, 'utf-8');
      return new Response(content, {
        headers: { 'Content-Type': 'text/html' },
      });
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
});

afterAll(() => {
  try { testServer.server.stop(); } catch {}
  setTimeout(() => process.exit(0), 500);
});

// ─── ns inspect ───────────────────────────────────────────

describe('ns inspect', () => {
  test('inspect all fields returns compact table with 5 fields', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect([], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('INSPECT OK');
    expect(output.display).toContain('5 fields');
    expect(output.display).toContain('Mode: create');

    // Check field lines: id | value | type | flags
    expect(output.display).toContain('companyname');
    expect(output.display).toContain('Acme Corp');
    expect(output.display).toContain('text');
  });

  test('inspect with --field returns single field line', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect(['--field', 'companyname'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('1 fields');
    expect(output.display).toContain('companyname');
    expect(output.display).toContain('Acme Corp');
    expect(output.display).toContain('text');
  });

  test('inspect with --field for nonexistent field returns 0 fields', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect(['--field', 'nonexistent_field_xyz'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('0 fields');
  });

  test('inspect returns form mode', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect([], bm);
    expect(output.display).toContain('Mode: create');

    // Edit mode
    await page.goto(baseUrl + '/ns-form.html?id=123&e=T');
    const outputEdit = await nsInspect([], bm);
    expect(outputEdit.display).toContain('Mode: edit');

    await page.goto(baseUrl + '/ns-form.html');
  });

  test('inspect with --sublists discovers sublists from DOM', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect(['--sublists'], bm);

    expect(output.ok).toBe(true);
    expect(output.display).toContain('Sublist: item');
    expect(output.display).toContain('2 lines');
    expect(output.display).toContain('5 columns');

    // Line values
    expect(output.display).toContain('1:');
    expect(output.display).toContain('item=100');
    expect(output.display).toContain('2:');
    expect(output.display).toContain('item=200');
  });

  test('inspect on non-NS page returns error', async () => {
    const page = bm.getPage();
    await page.goto('about:blank');

    const output = await nsInspect([], bm);

    expect(output.ok).toBe(false);
    expect(output.display).toContain('NotARecordPage');

    await page.goto(baseUrl + '/ns-form.html');
  });

  test('inspect --sublists groups columns into Must fill and Can fill', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect(['--sublists'], bm);

    expect(output.ok).toBe(true);
    // Must fill group with mandatory column
    expect(output.display).toContain('Must fill (1)');
    expect(output.display).toContain('item | Item | select | mandatory');
    // Can fill group with non-mandatory columns
    expect(output.display).toContain('Can fill (4)');
    expect(output.display).toContain('quantity | Quantity');
    expect(output.display).toContain('rate | Rate');
    expect(output.display).toContain('amount | Amount');
    // Column types from nlapiGetLineItemField
    expect(output.display).toContain('integer');
    expect(output.display).toContain('currency');
  });

  test('inspect without --sublists does not include Sublist lines', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect([], bm);

    expect(output.ok).toBe(true);
    expect(output.display).not.toContain('Sublist:');
  });
});
