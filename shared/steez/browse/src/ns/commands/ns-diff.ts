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
import { introspectAllFields, introspectField } from '../utils/introspect-field';
import { createPageGetter, waitForFieldConvergence } from '../convergence';
import { parseSetArgs } from '../utils/parse-set-args';
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

// ─── ns diff ────────────────────────────────────────────────

export async function nsDiff(args: string[], bm: BrowserManager): Promise<NsCommandOutput> {
  const result = await withMutex(nsMutex, async (): Promise<NsResult<NsDiffData>> => {
      const target = bm.getActiveFrameOrPage();

      // ── Guard: must be on a NS page with client API ──────────
      const guardErr = await guardNsApi(target);
      if (guardErr) {
        return { ok: false as const, error: guardErr };
      }

      // ── Parse action args ────────────────────────────────────
      let actionLabel: string | null = null;
      let actionSpec:
        | { fieldId: string; value: string; forceSource: boolean | null; fieldMeta: NsFieldMetadata }
        | null = null;

      if (args.length > 0) {
        const action = args[0];

        if (action !== 'set') {
          return {
            ok: false as const,
            error: validationError(`Unknown diff action: "${action}". Supported actions: set`),
          };
        }

        const { fieldId, value, forceSource } = parseSetArgs(args.slice(1));

        if (!fieldId || value === null) {
          return {
            ok: false as const,
            error: validationError('Missing arguments. Usage: ns diff set <fieldId> <value> [--source|--fire-field-changed|--no-source]'),
          };
        }

        // Resolve the target field using the same single-field API that
        // ns set / ns inspect --field use. The broad discovery path in
        // introspectAllFields is DOM/heuristic-driven and misses body
        // fields like `entity` on transaction forms — keeping ns diff
        // aligned with nlapiGetField avoids that divergence.
        const fieldMeta = await introspectField(target, fieldId);
        if (!fieldMeta) {
          return {
            ok: false as const,
            error: validationError(`Field "${fieldId}" not found on this form`),
          };
        }

        actionLabel = `set ${fieldId} ${value}`;
        actionSpec = { fieldId, value, forceSource, fieldMeta };
      }

      // ── Snapshot "before" ────────────────────────────────────
      const beforeFields = await introspectAllFields(target);
      // Ensure the action's target field is in the snapshot even when
      // broad discovery misses it (see fieldMeta comment above).
      if (actionSpec) {
        const { fieldId, fieldMeta } = actionSpec;
        if (!beforeFields.some(f => f.id === fieldId)) beforeFields.push(fieldMeta);
      }
      const beforeMap = toSnapshotMap(beforeFields);

      if (actionSpec) {
        const { fieldId, value, forceSource, fieldMeta } = actionSpec;

        // ── Execute the set operation ────────────────────────────
        const page = bm.getPage();

        const fireFieldChanged = forceSource !== false;
        const synchronous = true;

        // Convergence wait is a separate axis from fireFieldChanged: only
        // worth polling when sourcing handlers may run (entity-ref) or when
        // --source is forced.
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
      // Mirror the before-snapshot augmentation so the diff can report
      // a change on fields that broad discovery misses.
      if (actionSpec) {
        const { fieldId } = actionSpec;
        if (!afterFields.some(f => f.id === fieldId)) {
          const afterMeta = await introspectField(target, fieldId);
          if (afterMeta) afterFields.push(afterMeta);
        }
      }
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
