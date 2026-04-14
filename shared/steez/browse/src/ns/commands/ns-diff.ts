/**
 * ns diff — Snapshot-and-observe command for field change detection.
 *
 * Usage:
 *   ns diff                                  → baseline snapshot (no action, no changes)
 *   ns diff set salesrep 99                  → set a field and show ALL fields that changed
 *   ns diff set companyname "Foo"            → set a text field and show what changed
 *   ns diff set trandate 2026-04-14 --source → force fire cascading regardless of field type
 *   ns diff set trandate 2026-04-14 --fire-field-changed → alias for --source
 *   ns diff set entity 42 --no-source        → force suppress fieldChanged
 *
 * Unlike ns set (which only tracks changes when cascading is fired), ns diff
 * always captures a full before/after snapshot of every field on the form.
 * This makes it useful for understanding the full impact of any mutation.
 *
 * Cascading strategy (aligned with ns set):
 *   nlapiSetFieldValue(id, val, firefieldchanged=true, synchronous=true)
 *   Always fires fieldChanged by default; --no-source suppresses it.
 *
 * Flow: guardNsApi → snapshot "before" → action (if args) → settle → snapshot "after" → compare
 */

import type { BrowserManager } from '../../core/browser-manager';
import type { NsCommandOutput } from '../format';
import { formatNsError, truncateValue } from '../format';
import type { NsResult } from '../errors';
import type { NsFieldMetadata } from '../utils/introspect-field';
import { guardNsApi, validationError } from '../errors';
import { introspectAllFields } from '../utils/introspect-field';
import { createPageGetter, waitForFieldConvergence } from '../convergence';
import { withMutex, nsMutex } from '../mutex';

// ─── Types ──────────────────────────────────────────────────

interface FieldSnapshot {
  value: string | null;
  displayValue: string | null;
}

interface FieldChange {
  id: string;
  before: FieldSnapshot;
  after: FieldSnapshot;
}

interface NsDiffData {
  action: string | null;
  before: Record<string, FieldSnapshot>;
  after: Record<string, FieldSnapshot>;
  changed: FieldChange[];
  unchanged: number;
}

// ─── Helpers ────────────────────────────────────────────────

/** Convert an array of NsFieldMetadata into a snapshot map. */
function toSnapshotMap(fields: NsFieldMetadata[]): Record<string, FieldSnapshot> {
  const map: Record<string, FieldSnapshot> = {};
  for (const f of fields) {
    map[f.id] = { value: f.value, displayValue: f.displayValue };
  }
  return map;
}

/**
 * Parse `set <fieldId> <value> [--source|--fire-field-changed|--no-source]`.
 * Mirrors ns-set's parseSetArgs so the two commands share a flag vocabulary.
 */
function parseSetActionArgs(args: string[]): {
  fieldId: string | null;
  value: string | null;
  forceSource: boolean | null;
} {
  let forceSource: boolean | null = null;
  const positional: string[] = [];

  for (const arg of args) {
    if (arg === '--source' || arg === '--fire-field-changed') {
      forceSource = true;
    } else if (arg === '--no-source') {
      forceSource = false;
    } else {
      positional.push(arg);
    }
  }

  return {
    fieldId: positional[0] ?? null,
    value: positional[1] ?? null,
    forceSource,
  };
}

// ─── ns diff ────────────────────────────────────────────────

export async function nsDiff(args: string[], bm: BrowserManager): Promise<NsCommandOutput> {
  const result = await withMutex(nsMutex, async (): Promise<NsResult<NsDiffData>> => {
      const target = bm.getActiveFrameOrPage();

      // ── Guard: must be on a NS page with client API ──────────
      const guardErr = await guardNsApi(target);
      if (guardErr) {
        return { ok: false as const, error: guardErr };
      }

      // ── Snapshot "before" ────────────────────────────────────
      const beforeFields = await introspectAllFields(target);
      const beforeMap = toSnapshotMap(beforeFields);

      // ── Parse action args ────────────────────────────────────
      // Format: ns diff [action] [actionArgs...]
      // Currently only "set" is supported as an action.
      let actionLabel: string | null = null;

      if (args.length > 0) {
        const action = args[0];

        if (action !== 'set') {
          return {
            ok: false as const,
            error: validationError(`Unknown diff action: "${action}". Supported actions: set`),
          };
        }

        const { fieldId, value, forceSource } = parseSetActionArgs(args.slice(1));

        if (!fieldId || value === null) {
          return {
            ok: false as const,
            error: validationError('Missing arguments. Usage: ns diff set <fieldId> <value> [--source|--fire-field-changed|--no-source]'),
          };
        }

        actionLabel = `set ${fieldId} ${value}`;

        // ── Execute the set operation ────────────────────────────
        const page = bm.getPage();

        const fieldMeta = beforeFields.find(f => f.id === fieldId);
        if (!fieldMeta) {
          return {
            ok: false as const,
            error: validationError(`Field "${fieldId}" not found on this form`),
          };
        }

        // Cascading strategy (aligned with ns set):
        //   nlapiSetFieldValue(fld, val, firefieldchanged, synchronous)
        //   Always fire by default — --no-source opts out.
        const fireFieldChanged = forceSource !== false;
        const synchronous = true;

        // Convergence wait is a separate axis: only worth polling for
        // entity-ref fields (which have sourcing handlers) or when --source
        // is explicitly requested.
        let trackConvergence: boolean;
        if (forceSource === true) {
          trackConvergence = true;
        } else if (forceSource === false) {
          trackConvergence = false;
        } else {
          trackConvergence = fieldMeta.isEntityRef;
        }

        await page.evaluate(
          ({ fid, val, ffc, sync }: { fid: string; val: string; ffc: boolean; sync: boolean }) => {
            (window as any).nlapiSetFieldValue(fid, val, ffc, sync);
          },
          { fid: fieldId, val: value, ffc: fireFieldChanged, sync: synchronous },
        );

        // ── Wait for convergence if cascading was fired ──────────
        if (trackConvergence) {
          const watchFieldIds = beforeFields
            .filter(f => !f.disabled && f.id !== fieldId)
            .map(f => f.id);

          if (watchFieldIds.length > 0) {
            await waitForFieldConvergence(target, watchFieldIds, {
              stablePolls: 3,
              initialIntervalMs: 50,
              maxIntervalMs: 200,
              timeoutMs: 5000,
            });
          }
        }
      }

      // ── Snapshot "after" ─────────────────────────────────────
      const afterFields = await introspectAllFields(target);
      const afterMap = toSnapshotMap(afterFields);

      // ── Compare ──────────────────────────────────────────────
      const allFieldIds = new Set([
        ...Object.keys(beforeMap),
        ...Object.keys(afterMap),
      ]);

      const changed: FieldChange[] = [];
      let unchanged = 0;

      for (const id of allFieldIds) {
        const before = beforeMap[id] ?? { value: null, displayValue: null };
        const after = afterMap[id] ?? { value: null, displayValue: null };

        if (before.value !== after.value || before.displayValue !== after.displayValue) {
          changed.push({ id, before, after });
        } else {
          unchanged++;
        }
      }

      return {
        ok: true as const,
        data: {
          action: actionLabel,
          before: beforeMap,
          after: afterMap,
          changed,
          unchanged,
        },
      };
    }, { label: 'ns diff' });

  if (!result.ok) {
    return { display: formatNsError('ns diff', result.error!), ok: false };
  }

  const d = result.data!;
  const actionLabel = d.action ? `Action: ${d.action}` : 'Baseline snapshot';
  const lines = [`DIFF OK | ${actionLabel} | ${d.changed.length} changed, ${d.unchanged} unchanged`];
  for (const c of d.changed) {
    lines.push(`Changed: ${c.id} ${truncateValue(c.before.value)} → ${truncateValue(c.after.value)}`);
  }

  return { display: lines.join('\n'), ok: true };
}
