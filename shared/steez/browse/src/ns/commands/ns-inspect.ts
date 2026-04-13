/**
 * ns inspect — Full form graph inspection.
 *
 * Usage:
 *   ns inspect                    → inspect all fields + form mode
 *   ns inspect --field companyname → inspect single field
 *   ns inspect --sublists         → include sublist discovery from DOM
 *
 * Introspects fields via nlapiGetField / nlapiGetFieldValue / nlapiGetFieldText,
 * detects form mode from URL, and optionally discovers sublists from the DOM
 * (table headers, line counts, line values).
 */

import type { BrowserManager } from '../../core/browser-manager';
import type { NsCommandOutput } from '../format';
import { formatNsError, truncateValue } from '../format';
import type { NsResult } from '../errors';
import type { NsFieldMetadata, NsFormMode } from '../utils/introspect-field';
import { guardNsApi } from '../errors';
import { introspectField, introspectAllFields, detectFormMode } from '../utils/introspect-field';
import { withMutex, nsMutex } from '../mutex';

// ─── Types ──────────────────────────────────────────────────

export interface NsSublistColumn {
  id: string;
  label: string;
  type: string;
  mandatory: boolean;
}

export interface NsSublistLine {
  line: number;
  values: Record<string, string>;
}

export interface NsSublistData {
  id: string;
  columns: NsSublistColumn[];
  lineCount: number;
  lines: NsSublistLine[];
}

export interface NsInspectData {
  mode: NsFormMode;
  fields: NsFieldMetadata[];
  sublists?: NsSublistData[];
}

// ─── Field Filtering ───────────────────────────────────────

/** Prefix patterns — always internal NetSuite plumbing */
const FILTERED_PREFIXES = [
  'hddn_', 'indx_', 'inpt_', 'custpage_',
  // payment/CC processor internals (gateway handshake, not settable record fields)
  'payment', 'cc',
  // shipping rate engine coefficients (you set shipmethod/shippingcost, not these)
  'byweight', 'handling',
];

/** Exact IDs — UI state, session context, navigation, internal scaffolding */
const FILTERED_IDS = new Set([
  // search widget
  'quickfind-field',
  // button container (individual buttons are tagged, not filtered)
  'multibuttonsubmit',
  // UI state
  'selectedtab', 'nsbrowserenv', 'formdisplayview',
  'activitiesloaded', 'activitiesdotted', 'clickedback', 'submitted', 'bulk',
  // session context
  'nluser', 'nlrole', 'nldept', 'nlloc', 'nlsub',
  // navigation plumbing
  'whence', 'customwhence', 'entryformquerystring',
  'extraurlparams', 'wfinstances', 'dbstrantype',
  // address subrecord scaffolding
  'previous_billaddresslist', 'previous_shipaddresslist',
  'billingaddress2_set', 'billingaddress_key', 'billingaddress_type', 'billingaddress_defaultvalue',
  'shippingaddress2_set', 'shippingaddress_key', 'shippingaddress_type', 'shippingaddress_defaultvalue',
  // payment/CC (non-prefix catches)
  'cardswipe', 'maskedcard', 'customercode', 'ispurchasecard',
  'ispaymethundepfunds', 'paymethacct', 'paymethtype',
  'allowemptycards', 'profilesupportslineleveldata', 'methodrequireslineleveldata',
  'ignoreavs', 'ignoreavsvis', 'ignorecsc', 'ignorecscvis',
  'carddataprovided', 'signaturerequired', 'isrecurringpayment',
  'authorizedamount', 'collectedamount', 'reimbursedamount',
  'inputpnrefnum', 'overridehold', 'overrideholdchecked',
  'debitpinblock', 'debitksn',
  'request', 'response', 'redirecturl', 'returnurl', 'datafromredirect',
  'shopperprintblock', 'merchantprintblock',
  // shipping calc engine
  'doshippingrecalc', 'fedexservicename', 'hasfedexfreightservice',
  'shipping_rate', 'shipping_cost_function', 'flatrateamt',
  'peritemdefaultprice', 'percentoftotalamt', 'shippingerrormsg',
  'shipping_btaxable', 'handling_btaxable',
  'shandlingcostfunction', 'shandlingaccount',
  'bfreeifoveractive', 'rfreeifoveramt',
  'bminshipcostactive', 'rminshipamt', 'bmaxshipcostactive', 'rmaxshipcost',
  'shipitemhasfreeshippingitems', 'binclallitemsforfreeshipping',
  'itemshippingcostfxrate', 'shippingcostoverridden', 'overrideshippingcost',
  // discount/tax internals
  'disctax1', 'disctax2', 'disctax1amt', 'disctax2amt',
  'discountistaxable', 'discountastotal',
  'tax_affecting_address_fields_before_recalc',
  'taxamountoverride', 'taxamount2override',
  'shippingtax1amt', 'shippingtax2amt', 'handlingtax1amt', 'handlingtax2amt',
  // boolean state flags (read-only form scaffolding)
  'templatestored', 'isonlinetransaction', 'oldrevenuecommitment', 'iseitf81on',
  'checkcommitted', 'haslines', 'canbeunapproved', 'canhavestackable',
  'suppressusereventsandemails', 'updatedropshiporderqty', 'isdefaultshippingrequest',
  'locationusesbins', 'inventorydetailuitype',
  'shadow_shipaddress', 'address_country_state_map', 'bnopostmain',
]);

/** Button IDs — tagged [button] instead of filtered */
const BUTTON_IDS = new Set([
  'btn_multibutton_submitter', 'submitter', 'submitfulfill', 'submitnew',
  'saveprint', 'saveemail', 'memorize', 'gotoregister',
]);

function isFiltered(id: string): boolean {
  if (FILTERED_IDS.has(id)) return true;
  for (const prefix of FILTERED_PREFIXES) {
    if (id.startsWith(prefix)) return true;
  }
  return false;
}

/** Bucket labels shown as section headers in output */
const BUCKET_LABELS: Record<number, string> = {
  1: 'Must fill',
  2: 'Can fill',
  3: 'Buttons',
  4: 'Read-only',
  5: 'Other',
  6: 'Other',
};

function fieldBucket(f: NsFieldMetadata): number {
  const isButton = BUTTON_IDS.has(f.id);
  const hasLabel = !!f.label;
  const editable = !f.disabled;
  if (isButton) return 3;
  if (hasLabel && editable && f.mandatory) return 1;
  if (hasLabel && editable) return 2;
  if (hasLabel && !editable) return 4;
  if (!hasLabel && editable) return 5;
  return 6;
}

/**
 * Group fields by actionability bucket, preserving DOM order within each bucket.
 * Returns groups in bucket order, each with a label and field list.
 */
function groupByBucket(fields: NsFieldMetadata[]): Array<{ label: string; fields: NsFieldMetadata[] }> {
  const buckets = new Map<number, NsFieldMetadata[]>();
  for (const f of fields) {
    const b = fieldBucket(f);
    if (!buckets.has(b)) buckets.set(b, []);
    buckets.get(b)!.push(f);
  }
  // Merge buckets 5+6 into a single "Other" group
  const b5 = buckets.get(5) ?? [];
  const b6 = buckets.get(6) ?? [];
  const merged = [...b5, ...b6];
  buckets.delete(5);
  buckets.delete(6);
  if (merged.length > 0) buckets.set(5, merged);

  const groups: Array<{ label: string; fields: NsFieldMetadata[] }> = [];
  for (const key of [1, 2, 3, 4, 5]) {
    const items = buckets.get(key);
    if (items && items.length > 0) {
      groups.push({ label: BUCKET_LABELS[key], fields: items });
    }
  }
  return groups;
}

// ─── Arg Parsing ────────────────────────────────────────────

function parseInspectArgs(args: string[]): { fieldId: string | null; sublists: boolean; all: boolean } {
  let fieldId: string | null = null;
  let sublists = false;
  let all = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--field') {
      fieldId = args[++i] ?? null;
    } else if (arg === '--sublists') {
      sublists = true;
    } else if (arg === '--all') {
      all = true;
    }
  }

  return { fieldId, sublists, all };
}

// ─── ns inspect ─────────────────────────────────────────────

export async function nsInspect(args: string[], bm: BrowserManager): Promise<NsCommandOutput> {
  const result = await withMutex(nsMutex, async (): Promise<NsResult<NsInspectData>> => {
    const target = bm.getActiveFrameOrPage();

    // Guard: must be on a NS page with client API
    const guardErr = await guardNsApi(target);
    if (guardErr) {
      return { ok: false as const, error: guardErr };
    }

    const { fieldId, sublists: includeSublists, all: showAll } = parseInspectArgs(args);

    // Detect form mode
    const mode = await detectFormMode(target);

    // Introspect fields
    let fields: NsFieldMetadata[];
    if (fieldId) {
      const single = await introspectField(target, fieldId);
      fields = single ? [single] : [];
    } else {
      fields = await introspectAllFields(target);
    }

    // Optionally discover sublists from DOM
    let sublists: NsSublistData[] | undefined;
    if (includeSublists) {
      sublists = await discoverSublists(bm);
    }

    const data: NsInspectData = {
      mode,
      fields,
      ...(sublists ? { sublists } : {}),
    };

    return { ok: true as const, data };
  }, { label: 'ns inspect', operationTimeoutMs: 10000 });

  if (!result.ok) {
    return { display: formatNsError('ns inspect', result.error!), ok: false };
  }

  const d = result.data!;
  const { all: showAll } = parseInspectArgs(args);

  // Filter plumbing fields unless --all or --field (single-field lookup is never filtered)
  const visible = (showAll || parseInspectArgs(args).fieldId)
    ? d.fields
    : d.fields.filter(f => !isFiltered(f.id));
  const filtered = d.fields.length - visible.length;

  // Group by actionability bucket, preserve DOM order within each bucket
  const groups = groupByBucket(visible);

  const header = filtered > 0
    ? `INSPECT OK | Mode: ${d.mode} | ${visible.length} fields (${filtered} internal hidden, use --all to show)`
    : `INSPECT OK | Mode: ${d.mode} | ${visible.length} fields`;
  const lines = [header];

  for (const group of groups) {
    lines.push('');
    lines.push(`── ${group.label} (${group.fields.length}) ──`);
    for (const f of group.fields) {
      const flags: string[] = [];
      if (f.mandatory) flags.push('mandatory');
      if (f.disabled) flags.push('disabled');
      if (f.isEntityRef) flags.push('entityRef');
      const prefix = BUTTON_IDS.has(f.id) ? '[button] ' : '';
      lines.push(`${prefix}${f.id} | ${f.label || '-'} | ${truncateValue(f.value)} | ${f.type} | ${flags.join(',') || '-'}`);
    }
  }

  if (d.sublists) {
    for (const sub of d.sublists) {
      lines.push('');
      lines.push(`Sublist: ${sub.id} (${sub.lineCount} lines, ${sub.columns.length} columns)`);

      // Group columns by mandatory — same shape as header fields
      const mustFill = sub.columns.filter(c => c.mandatory);
      const canFill = sub.columns.filter(c => !c.mandatory);

      if (mustFill.length > 0) {
        lines.push(`  ── Must fill (${mustFill.length}) ──`);
        for (const c of mustFill) {
          lines.push(`  ${c.id} | ${c.label} | ${c.type} | mandatory`);
        }
      }
      if (canFill.length > 0) {
        lines.push(`  ── Can fill (${canFill.length}) ──`);
        for (const c of canFill) {
          lines.push(`  ${c.id} | ${c.label} | ${c.type} | -`);
        }
      }

      for (const line of sub.lines) {
        const vals = sub.columns.map(c => `${c.id}=${truncateValue(line.values[c.id])}`).join(', ');
        lines.push(`  ${line.line}: ${vals}`);
      }
    }
  }

  return { display: lines.join('\n'), ok: true };
}

// ─── Sublist Discovery ──────────────────────────────────────

/**
 * Discover sublists from the DOM by finding sublist containers
 * (div[id$="_splits"], table.uir-machine-table), extract column
 * headers, then read line values via nlapi sublist APIs.
 *
 * Three-phase column resolution per sublist:
 * 1. Parse header cells for labels, mandatory flags, and tentative IDs
 * 2. Scan first data row to override tentative IDs with real field scriptids
 * 3. Scan container for hidden field elements not visible in the table
 */
async function discoverSublists(bm: BrowserManager): Promise<NsSublistData[]> {
  const page = bm.getPage();

  const discovered = await page.evaluate(() => {
    /* eslint-disable @typescript-eslint/no-explicit-any */
    const w = window as any;
    const results: Array<{
      id: string;
      columns: Array<{ id: string; label: string; mandatory: boolean }>;
    }> = [];

    const seen = new Set<string>();

    /** Extract base field ID from a DOM element ID by stripping NS display suffixes */
    function extractFieldId(elementId: string): string {
      return elementId
        .replace(/(?:val|text)\d+$/, '')         // itemval1 → item
        .replace(/_(?:val|display|text)\d*$/, ''); // item_display → item
    }

    /** Check if an element ID is NS internal plumbing */
    function isInternalId(id: string): boolean {
      return !id || id.startsWith('inpt_') || id.startsWith('hddn_') ||
        id.startsWith('custpage_') || id.includes('_fs_');
    }

    /** Parse a header cell: strip trailing *, detect mandatory flag */
    function parseHeader(cell: Element): { id: string; label: string; mandatory: boolean } | null {
      const headerDiv = cell.querySelector('.listheadertextb, .listheadertext');
      const rawLabel = headerDiv?.textContent?.trim() ?? (cell as HTMLElement).textContent?.trim() ?? '';
      if (!rawLabel) return null;

      const mandatory = /\s*\*\s*$/.test(rawLabel);
      const label = rawLabel.replace(/\s*\*\s*$/, '').trim();

      const dataField = cell.getAttribute('data-ns-tooltip')
        || cell.querySelector('[data-field]')?.getAttribute('data-field')
        || null;
      const id = dataField || label.toLowerCase().replace(/[^a-z0-9_]/g, '');
      return { id, label, mandatory };
    }

    /**
     * Resolve columns for a sublist via three-phase discovery:
     * 1. Header cells → labels, mandatory flags, tentative IDs (may be display aliases)
     * 2. Data row elements → real field scriptids, matched by column position
     * 3. Container scan → hidden fields not visible in the table
     */
    function resolveColumns(
      container: Element,
      sublistId: string,
    ): Array<{ id: string; label: string; mandatory: boolean }> {
      // Phase 1: Parse header cells with column-index tracking
      const headerEntries: Array<{ cellIndex: number; id: string; label: string; mandatory: boolean }> = [];
      const headerCells = container.querySelectorAll('td.listheadertd, th.listheadertd');
      headerCells.forEach((cell, idx) => {
        const parsed = parseHeader(cell);
        if (parsed) headerEntries.push({ cellIndex: idx, ...parsed });
      });

      // Phase 2: Scan first data row to resolve real field scriptids
      const table = container.querySelector('table') || container;
      const rows = table.querySelectorAll('tr');
      for (const row of rows) {
        if (row.querySelector('.listheadertd, .listheadertextb')) continue;
        const dataCells = row.querySelectorAll('td');
        if (dataCells.length === 0) continue;

        // Override header-derived IDs with real IDs from data row elements
        for (const entry of headerEntries) {
          const dataCell = dataCells[entry.cellIndex];
          if (!dataCell) continue;
          const el = dataCell.querySelector('[id]');
          if (!el) continue;
          const realId = extractFieldId(el.id);
          if (realId && !isInternalId(realId)) {
            entry.id = realId;
          }
        }

        // Discover extra columns in data cells with no corresponding header
        const headerPositions = new Set(headerEntries.map(h => h.cellIndex));
        dataCells.forEach((cell, idx) => {
          if (headerPositions.has(idx)) return;
          const el = cell.querySelector('[id]');
          if (!el) return;
          const fieldId = extractFieldId(el.id);
          if (isInternalId(fieldId)) return;
          try {
            const field = w.nlapiGetLineItemField?.(sublistId, fieldId, 1);
            if (field) {
              headerEntries.push({
                cellIndex: idx,
                id: fieldId,
                label: field.getLabel?.() || fieldId,
                mandatory: !!field.isMandatory?.(),
              });
            }
          } catch {}
        });

        break; // first data row only
      }

      // Phase 3: Scan container for hidden field elements (custom columns not in the table)
      const knownIds = new Set(headerEntries.map(e => e.id));
      const allInputs = container.querySelectorAll('input[id], select[id], textarea[id]');
      for (const el of allInputs) {
        const fieldId = extractFieldId(el.id);
        if (isInternalId(fieldId) || knownIds.has(fieldId)) continue;
        try {
          const field = w.nlapiGetLineItemField?.(sublistId, fieldId, 1);
          if (field) {
            knownIds.add(fieldId);
            headerEntries.push({
              cellIndex: -1,
              id: fieldId,
              label: field.getLabel?.() || fieldId,
              mandatory: !!field.isMandatory?.(),
            });
          }
        } catch {}
      }

      // Fallback: if 0 columns and no data rows, try input scan from first row
      if (headerEntries.length === 0) {
        const fallbackTable = container.querySelector('table');
        if (fallbackTable) {
          const dataRows = fallbackTable.querySelectorAll('tr:not(:has(.listheadertd))');
          const firstRow = dataRows[0];
          if (firstRow) {
            const inputs = firstRow.querySelectorAll('input[id], select[id], textarea[id]');
            for (const inp of inputs) {
              const inputId = inp.id;
              if (isInternalId(inputId)) continue;
              headerEntries.push({ cellIndex: -1, id: inputId, label: inputId, mandatory: false });
            }
          }
        }
      }

      return headerEntries.map(e => ({ id: e.id, label: e.label, mandatory: e.mandatory }));
    }

    // Strategy A: div[id$="_splits"] containers (e.g. "item_splits" → sublist "item")
    const splitDivs = document.querySelectorAll('div[id$="_splits"]');
    for (const div of splitDivs) {
      const sublistId = div.id.replace(/_splits$/, '');
      if (seen.has(sublistId)) continue;
      seen.add(sublistId);
      results.push({ id: sublistId, columns: resolveColumns(div, sublistId) });
    }

    // Strategy B: table.uir-machine-table not inside a _splits div
    const machineTables = document.querySelectorAll('table.uir-machine-table');
    for (const table of machineTables) {
      const parentSplits = table.closest('div[id$="_splits"]');
      if (parentSplits) continue;

      const tableId = table.id || table.closest('[id]')?.id || '';
      const sublistId = tableId.replace(/_[a-z]+$/, '') || `unknown_${seen.size}`;
      if (seen.has(sublistId)) continue;
      seen.add(sublistId);
      results.push({ id: sublistId, columns: resolveColumns(table, sublistId) });
    }

    /* eslint-enable @typescript-eslint/no-explicit-any */
    return results;
  });

  const sublists: NsSublistData[] = [];

  for (const sub of discovered) {
    const { lineCount, lines, columnTypes } = await page.evaluate(
      ({ sublistId, columnIds }: { sublistId: string; columnIds: string[] }) => {
        /* eslint-disable @typescript-eslint/no-explicit-any */
        const w = window as any;
        const count: number = typeof w.nlapiGetLineItemCount === 'function'
          ? (w.nlapiGetLineItemCount(sublistId) ?? 0)
          : 0;

        // Get column types via nlapiGetLineItemField on first existing line
        const columnTypes: Record<string, string> = {};
        if (count > 0 && typeof w.nlapiGetLineItemField === 'function') {
          for (const colId of columnIds) {
            try {
              const f = w.nlapiGetLineItemField(sublistId, colId, 1);
              columnTypes[colId] = f?.getType?.() ?? 'text';
            } catch { columnTypes[colId] = 'text'; }
          }
        }

        const lines: Array<{ line: number; values: Record<string, string> }> = [];
        if (typeof w.nlapiGetLineItemValue === 'function' && count > 0) {
          for (let i = 1; i <= count; i++) {
            const values: Record<string, string> = {};
            for (const colId of columnIds) {
              values[colId] = w.nlapiGetLineItemValue(sublistId, colId, i) ?? '';
            }
            lines.push({ line: i, values });
          }
        }

        return { lineCount: count, lines, columnTypes };
        /* eslint-enable @typescript-eslint/no-explicit-any */
      },
      { sublistId: sub.id, columnIds: sub.columns.map(c => c.id) },
    );

    // Enrich columns with types from nlapi
    const enrichedColumns: NsSublistColumn[] = sub.columns.map(c => ({
      id: c.id,
      label: c.label,
      mandatory: c.mandatory,
      type: columnTypes[c.id] || 'text',
    }));

    sublists.push({
      id: sub.id,
      columns: enrichedColumns,
      lineCount,
      lines,
    });
  }

  return sublists;
}
