/**
 * ns add-row — Add a sublist row with field values and commit.
 *
 * Usage:
 *   ns add-row item item=100 quantity=5 rate=10.00
 *   ns add-row expense account=6000 amount=500 memo="Office supplies"
 *
 * Lifecycle:
 *   1. nlapiSelectNewLineItem(sublistId) — open a new blank row
 *   2. For each key=value pair: nlapiSetCurrentLineItemValue(sub, col, val, true, true)
 *      - firefieldchanged=true fires sourcing for entity-ref columns (item → rate/taxcode/units)
 *      - No-op for scalar columns (quantity, rate, memo, etc.)
 *      - After each set, poll other columns for convergence
 *   3. nlapiCommitLineItem(sublistId) — commit the row
 *   4. Return line number, final values, convergence result
 */

import type { BrowserManager } from '../../core/browser-manager';
import type { NsCommandOutput } from '../format';
import { formatNsError, truncateValue } from '../format';
import type { NsResult } from '../errors';
import type { CapturedDialog } from '../utils/with-dialog-handler';
import { guardNsApi, validationError } from '../errors';
import { pollUntilConverged, type FieldValueGetter } from '../convergence';
import { withDialogHandler } from '../utils/with-dialog-handler';
import { withMutex, nsMutex } from '../mutex';

// ─── Types ──────────────────────────────────────────────────

interface RejectedColumn {
  column: string;
  requested: string;
  actual: string | null;
}

function formatRejection(rc: RejectedColumn, prefix: string): string {
  return `${prefix}: ${rc.column}=${rc.requested} — value cleared by NetSuite (likely subsidiary mismatch)`;
}

interface NsAddRowData {
  sublist: string;
  lineNumber: number;
  values: Record<string, string | null>;
  settled: boolean;
  commitFailed: boolean;
  rejectedColumns: RejectedColumn[];
  elapsedMs: number;
  dialogs: CapturedDialog[];
}

// ─── Arg Parsing ────────────────────────────────────────────

function parseAddRowArgs(args: string[]): {
  sublistId: string | null;
  fieldValues: Array<{ column: string; value: string }>;
} {
  if (args.length === 0) return { sublistId: null, fieldValues: [] };

  const sublistId = args[0];
  const fieldValues: Array<{ column: string; value: string }> = [];

  for (let i = 1; i < args.length; i++) {
    const eqIdx = args[i].indexOf('=');
    if (eqIdx > 0) {
      fieldValues.push({
        column: args[i].slice(0, eqIdx),
        value: args[i].slice(eqIdx + 1),
      });
    }
  }

  return { sublistId, fieldValues };
}

// ─── Sublist line item getter (for convergence polling) ─────

function createLineItemGetter(
  target: import('playwright').Page | import('playwright').Frame,
  sublistId: string,
): FieldValueGetter {
  return async (columnIds: string[]) => {
    return target.evaluate(
      ({ sub, cols }: { sub: string; cols: string[] }) => {
        const result: Record<string, string | null> = {};
        for (const col of cols) {
          result[col] = (window as any).nlapiGetCurrentLineItemValue?.(sub, col) ?? null;
        }
        return result;
      },
      { sub: sublistId, cols: columnIds },
    );
  };
}

// ─── Mandatory Column Detection ────────────────────────────

/**
 * Detect mandatory sublist columns from DOM * markers in header cells.
 * Mirrors the same parsing logic used by ns inspect --sublists.
 */
async function detectMandatoryColumns(
  target: import('playwright').Page | import('playwright').Frame,
  sublistId: string,
): Promise<string[]> {
  return target.evaluate((sub: string) => {
    // Strategy A: div[id$="_splits"] (most common)
    let container: Element | null = document.querySelector(`div[id="${sub}_splits"]`);

    // Strategy B fallback: table.uir-machine-table
    if (!container) {
      const tables = document.querySelectorAll('table.uir-machine-table');
      for (const table of tables) {
        const parent = table.closest('[id]');
        if (parent && parent.id.startsWith(sub)) {
          container = table;
          break;
        }
      }
    }

    if (!container) return [];

    const mandatoryCols: string[] = [];
    const headerCells = container.querySelectorAll('td.listheadertd, th.listheadertd');
    for (const cell of headerCells) {
      const headerDiv = cell.querySelector('.listheadertextb, .listheadertext');
      const rawLabel = headerDiv?.textContent?.trim() ?? (cell as HTMLElement).textContent?.trim() ?? '';
      if (!/\s*\*\s*$/.test(rawLabel)) continue;

      const label = rawLabel.replace(/\s*\*\s*$/, '').trim();
      const dataField = cell.getAttribute('data-ns-tooltip')
        || cell.querySelector('[data-field]')?.getAttribute('data-field')
        || null;
      const id = dataField || label.toLowerCase().replace(/[^a-z0-9_]/g, '');
      mandatoryCols.push(id);
    }
    return mandatoryCols;
  }, sublistId);
}

// ─── ns add-row ─────────────────────────────────────────────

export async function nsAddRow(args: string[], bm: BrowserManager): Promise<NsCommandOutput> {
  const result = await withMutex(nsMutex, async (): Promise<NsResult<NsAddRowData>> => {
      const start = Date.now();
      let target = bm.getActiveFrameOrPage();

      // ── Parse args ───────────────────────────────────────────
      const { sublistId, fieldValues } = parseAddRowArgs(args);

      if (!sublistId) {
        return { ok: false as const, error: validationError('Missing sublist ID. Usage: ns add-row <sublistId> col1=val1 col2=val2 ...') };
      }

      if (fieldValues.length === 0) {
        return { ok: false as const, error: validationError('No field values provided. Usage: ns add-row <sublistId> col1=val1 col2=val2 ...') };
      }

      // ── Guard ────────────────────────────────────────────────
      const guardErr = await guardNsApi(target);
      if (guardErr) return { ok: false as const, error: guardErr };

      // ── Pre-commit mandatory check ───────────────────────────
      // Read DOM * markers to detect mandatory columns BEFORE touching the form.
      const mandatoryCols = await detectMandatoryColumns(target, sublistId);
      const providedCols = new Set(fieldValues.map(fv => fv.column));
      const missingCols = mandatoryCols.filter(col => !providedCols.has(col));

      if (missingCols.length > 0) {
        return {
          ok: false as const,
          error: validationError(
            `Missing mandatory columns: ${missingCols.join(', ')}\n` +
            `Provided: ${fieldValues.map(fv => fv.column).join(', ')}\n` +
            `Required: ${mandatoryCols.join(', ')}`,
          ),
        };
      }

      // ── Idempotency guard: capture line count before ─────────
      const lineCountBefore = await target.evaluate(
        (sub: string) => (window as any).nlapiGetLineItemCount?.(sub) ?? 0,
        sublistId,
      );

      // ── Execute with dialog capture ──────────────────────────
      const { result: addResult, dialogs } = await withDialogHandler(
        bm,
        async () => {
          // 1. Select new line
          await target.evaluate(
            (sub: string) => (window as any).nlapiSelectNewLineItem?.(sub),
            sublistId,
          );

          // 2. Set each column value
          const allColumns = fieldValues.map(fv => fv.column);
          let overallSettled = true;
          const rejectedColumns: RejectedColumn[] = [];

          for (const { column, value } of fieldValues) {
            // Set column value with firefieldchanged=true, synchronous=true.
            // This fires the sourcing chain for entity-ref columns (item →
            // rate/taxcode/units) and is a no-op for scalar columns.
            await target.evaluate(
              ({ sub, col, val }: { sub: string; col: string; val: string }) => {
                (window as any).nlapiSetCurrentLineItemValue?.(sub, col, val, true, true);
              },
              { sub: sublistId, col: column, val: value },
            );

            // Re-acquire target — sourcing may have reloaded the NS iframe
            target = bm.getActiveFrameOrPage();

            // Read back the value to detect silent rejection (e.g. subsidiary mismatch
            // causes NS to clear entity-ref columns like location/department/class)
            const readBack = await createLineItemGetter(target, sublistId)([column]);
            const actual = readBack[column];
            if (actual !== value && !actual) {
              rejectedColumns.push({ column, requested: value, actual });
            }

            // Poll other columns for convergence — sourcing may update
            // dependent columns asynchronously
            const otherColumns = allColumns.filter(c => c !== column);
            if (otherColumns.length > 0) {
              const getter = createLineItemGetter(target, sublistId);
              const convergence = await pollUntilConverged(getter, {
                fieldIds: otherColumns,
                stablePolls: 3,
                initialIntervalMs: 50,
                maxIntervalMs: 200,
                timeoutMs: 5000,
              });
              if (!convergence.converged) overallSettled = false;
            }
          }

          // 3. Commit the line — re-acquire in case sourcing shifted the frame
          target = bm.getActiveFrameOrPage();
          await target.evaluate(
            (sub: string) => (window as any).nlapiCommitLineItem?.(sub),
            sublistId,
          );

          // 4. Get final line number and verify commit succeeded
          target = bm.getActiveFrameOrPage();
          const lineNumber = await target.evaluate(
            (sub: string) => (window as any).nlapiGetLineItemCount?.(sub) ?? 0,
            sublistId,
          );

          // Verify commit: line count must have increased
          if (lineNumber <= lineCountBefore) {
            // Commit failed silently — values were set on the edit line but not persisted
            // Read back current line values for diagnostic output
            target = bm.getActiveFrameOrPage();
            const editLineValues = await target.evaluate(
              ({ sub, cols }: { sub: string; cols: string[] }) => {
                const result: Record<string, string | null> = {};
                for (const col of cols) {
                  result[col] = (window as any).nlapiGetCurrentLineItemValue?.(sub, col) ?? null;
                }
                return result;
              },
              { sub: sublistId, cols: allColumns },
            );
            return {
              lineNumber: lineCountBefore,
              values: editLineValues,
              settled: false,
              commitFailed: true,
              rejectedColumns,
            };
          }

          // Read committed values
          target = bm.getActiveFrameOrPage();
          const finalValues = await target.evaluate(
            ({ sub, cols, line }: { sub: string; cols: string[]; line: number }) => {
              const result: Record<string, string | null> = {};
              for (const col of cols) {
                result[col] = (window as any).nlapiGetLineItemValue?.(sub, col, line) ?? null;
              }
              return result;
            },
            { sub: sublistId, cols: allColumns, line: lineNumber },
          );

          return { lineNumber, values: finalValues, settled: overallSettled, commitFailed: false, rejectedColumns };
        },
        { accept: true },
      );

      const elapsed = Date.now() - start;

      return {
        ok: true as const,
        data: {
          sublist: sublistId,
          lineNumber: addResult.lineNumber,
          values: addResult.values,
          settled: addResult.settled,
          commitFailed: addResult.commitFailed,
          rejectedColumns: addResult.rejectedColumns,
          elapsedMs: elapsed,
          dialogs,
        },
        dialogs,
      };
    }, { label: 'ns add-row' });

  if (!result.ok) {
    // Distinct format for mandatory-blocked (fail-fast, form not touched)
    if (result.error?.message.startsWith('Missing mandatory columns')) {
      const msgLines = result.error.message.split('\n');
      return {
        display: [`ADD-ROW BLOCKED | ${msgLines[0]}`, ...msgLines.slice(1)].join('\n'),
        ok: false,
      };
    }
    return { display: formatNsError('ns add-row', result.error!), ok: false };
  }

  const d = result.data!;
  if (d.commitFailed) {
    const lines: string[] = [];
    if (d.rejectedColumns.length > 0) {
      for (const rc of d.rejectedColumns) lines.push(formatRejection(rc, 'REJECTED'));
    }
    lines.push(`ADD-ROW FAILED | Sublist: ${d.sublist} | Commit did not add a new line (validation error or missing required column)`);
    const vals = Object.entries(d.values).map(([k, v]) => `${k}=${truncateValue(v)}`).join(', ');
    if (vals) lines.push(`Edit line values: ${vals}`);
    return { display: lines.join('\n'), ok: false };
  }
  const lines = [`ADD-ROW OK | Sublist: ${d.sublist} | Line: ${d.lineNumber} | Settled: ${d.settled ? 'yes' : 'no'}`];
  if (d.rejectedColumns.length > 0) {
    for (const rc of d.rejectedColumns) lines.push(formatRejection(rc, 'WARNING'));
  }
  const vals = Object.entries(d.values).map(([k, v]) => `${k}=${truncateValue(v)}`).join(', ');
  if (vals) lines.push(`Values: ${vals}`);
  if (d.dialogs.length > 0) {
    for (const dl of d.dialogs) {
      lines.push(`Dialog (${dl.type}): ${truncateValue(dl.message)}`);
    }
  }

  return { display: lines.join('\n'), ok: true };
}
