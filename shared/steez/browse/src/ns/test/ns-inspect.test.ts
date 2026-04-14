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
    expect(output.display).toContain('6 columns');

    // Line values include custom columns resolved by real scriptid
    expect(output.display).toContain('1:');
    expect(output.display).toContain('item=100');
    expect(output.display).toContain('custcol_est_gp_pct=45');
    expect(output.display).toContain('custcol_margin=40.00');
    expect(output.display).toContain('2:');
    expect(output.display).toContain('item=200');
    expect(output.display).toContain('custcol_est_gp_pct=30');
    expect(output.display).toContain('custcol_margin=48.00');
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
    // Can fill group with non-mandatory columns (4 visible + 1 hidden custom)
    expect(output.display).toContain('Can fill (5)');
    expect(output.display).toContain('quantity | Quantity');
    expect(output.display).toContain('rate | Rate');
    expect(output.display).toContain('amount | Amount');
    // Custom column resolved to real scriptid, not display alias
    expect(output.display).toContain('custcol_est_gp_pct | Est. GP %');
    // Hidden custom column discovered from container scan
    expect(output.display).toContain('custcol_margin | Margin');
    // Column types from nlapiGetLineItemField
    expect(output.display).toContain('integer');
    expect(output.display).toContain('currency');
    expect(output.display).toContain('percent');
  });

  test('inspect --sublists resolves real scriptids from nlapi bridge', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect(['--sublists'], bm);

    expect(output.ok).toBe(true);
    // nlapiGetLineItemFields returns real scriptids from the record schema,
    // not DOM display aliases like "estgp" derived from header text.
    expect(output.display).toContain('custcol_est_gp_pct');
    expect(output.display).not.toContain('estgp');
    // Bridge returns the full field set including hidden custom columns
    expect(output.display).toContain('custcol_margin');
  });

  test('inspect --sublists filters DOM artifacts like qsTarget_* when falling back to DOM', async () => {
    const page = bm.getPage();
    // Stub page with a table but no nlapi bridges — forces DOM fallback path.
    await page.setContent(`
      <html><body>
        <div id="main_form"></div>
        <div id="custom_splits">
          <table class="uir-machine-table">
            <thead>
              <tr>
                <td class="listheadertd"><div class="listheadertextb">Vendor Name</div></td>
                <td class="listheadertd"><div class="listheadertextb">Quantity</div></td>
              </tr>
            </thead>
            <tbody>
              <tr class="uir-machine-row">
                <td><span id="qsTarget_12345">ACME</span></td>
                <td><span id="quantityval1">5</span></td>
              </tr>
            </tbody>
          </table>
        </div>
        <script>
          window.nlapiGetFieldIds = function() { return []; };
          window.nlapiGetField = function() { return null; };
          window.nlapiGetFieldValue = function() { return null; };
          window.nlapiGetFieldText = function() { return null; };
          window.nlapiGetLineItemCount = function() { return 0; };
        </script>
      </body></html>
    `);

    const output = await nsInspect(['--sublists'], bm);

    expect(output.ok).toBe(true);
    // DOM artifact must never leak through as a column id
    expect(output.display).not.toContain('qsTarget_');

    await page.goto(baseUrl + '/ns-form.html');
  });

  test('inspect without --sublists does not include Sublist lines', async () => {
    const page = bm.getPage();
    await page.goto(baseUrl + '/ns-form.html');

    const output = await nsInspect([], bm);

    expect(output.ok).toBe(true);
    expect(output.display).not.toContain('Sublist:');
  });
});
