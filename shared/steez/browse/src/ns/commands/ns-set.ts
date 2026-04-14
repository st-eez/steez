/**
 * ns set — Set a field value with auto-detect cascading behavior.
 *
 * Usage:
 *   ns set entity 42                    → auto-detect: entity-ref → fire cascading
 *   ns set memo "Purchase for Q1"       → auto-detect: text → suppress cascading
 *   ns set trandate 2026-04-14 --source → force fire cascading regardless of field type
 *   ns set trandate 2026-04-14 --fire-field-changed → alias for --source
 *   ns set entity 42 --no-source        → force suppress cascading
 *
 * Cascading strategy:
 *   nlapiSetFieldValue(id, val, firefieldchanged=true, synchronous=true)
 *   Always fires fieldChanged (sourcing is a no-op for non-entity-ref fields).
 *   --no-source suppresses fieldChanged for fields where sourcing causes issues.
 *
 * When cascading is fired, polls all non-disabled fields for convergence
 * (dependent fields may be asynchronously updated by NetSuite sourcing).
 */

import type { BrowserManager } from '../../core/browser-manager';
import type { NsCommandOutput } from '../format';
import { formatNsError, truncateValue } from '../format';
import type { NsResult } from '../errors';
import type { CapturedDialog } from '../utils/with-dialog-handler';
import { guardNsApi, validationError, isNavigationDestroyedError } from '../errors';
import { introspectField, introspectAllFields } from '../utils/introspect-field';
import { createPageGetter, waitForFieldConvergence } from '../convergence';
import { withDialogHandler } from '../utils/with-dialog-handler';
import { waitForSettle } from '../utils/with-retry';
import { parseSetArgs } from '../utils/parse-set-args';
import { withMutex, nsMutex } from '../mutex';

// ─── Types ──────────────────────────────────────────────────

interface FieldChange {
  id: string;
  before: string | null;
  after: string | null;
}

interface NsSetData {
  fieldId: string;
  value: string;
  cascading: 'fired' | 'suppressed';
  settled: boolean;
  reloaded: boolean;
  elapsedMs: number;
  diff: { changed: FieldChange[] };
  dialogs: CapturedDialog[];
  hint: string | null;
}

interface SubsidiarySnapshot {
  value: string | null;
  text: string | null;
}

// OneWorld redirect uses this field ID on every transaction form.
const SUBSIDIARY_FIELD_ID = 'subsidiary';

// ─── ns set ─────────────────────────────────────────────────

export async function nsSet(args: string[], bm: BrowserManager): Promise<NsCommandOutput> {
  const result = await withMutex(nsMutex, async (): Promise<NsResult<NsSetData>> => {
      const start = Date.now();
      let target = bm.getActiveFrameOrPage();

      // ── Validate args ────────────────────────────────────────
      const { fieldId, value, forceSource } = parseSetArgs(args);

      if (!fieldId || value === null) {
        return {
          ok: false as const,
          error: validationError('Missing arguments. Usage: ns set <fieldId> <value> [--source|--fire-field-changed|--no-source]'),
        };
      }

      // ── Guard: must be on a NS page with client API ──────────
      const guardErr = await guardNsApi(target);
      if (guardErr) {
        return { ok: false as const, error: guardErr };
      }

      // ── Introspect the target field ──────────────────────────
      const fieldMeta = await introspectField(target, fieldId);
      if (!fieldMeta) {
        return {
          ok: false as const,
          error: validationError(`Field "${fieldId}" not found on this form`),
        };
      }

      // ── Decide cascading strategy ────────────────────────────
      // nlapiSetFieldValue(fld, val, firefieldchanged, synchronous)
      //   firefieldchanged=true  → fires fieldChanged event (triggers sourcing)
      //   firefieldchanged=false → suppresses fieldChanged event
      //
      // Always fire by default: sourcing is a no-op for fields without
      // handlers, but required for entity-ref fields (entity→subsidiary→
      // location cascade chain). Only suppress when --no-source is explicit.
      const fireFieldChanged = forceSource !== false;
      const synchronous = true;

      // Convergence tracking: snapshot + poll dependent fields after set.
      // Only worth the cost for entity-ref fields (which have sourcing
      // handlers) or when --source is explicitly requested.
      let trackConvergence: boolean;
      if (forceSource === true) {
        trackConvergence = true;
      } else if (forceSource === false) {
        trackConvergence = false;
      } else {
        trackConvergence = fieldMeta.isEntityRef;
      }

      const cascadingLabel: 'fired' | 'suppressed' = fireFieldChanged ? 'fired' : 'suppressed';

      // ── Snapshot field values before set (for diff) ──────────
      let watchFieldIds: string[] = [];
      let beforeValues: Record<string, string | null> = {};

      if (trackConvergence) {
        // Read all non-disabled fields for convergence tracking
        const allFields = await introspectAllFields(target);
        watchFieldIds = allFields
          .filter(f => !f.disabled && f.id !== fieldId)
          .map(f => f.id);

        const getter = createPageGetter(target);
        beforeValues = await getter(watchFieldIds);
      }

      // ── Snapshot subsidiary (OneWorld redirect detection) ────
      // Only entity-ref sets can trigger a server-side form reload (when the
      // entity's subsidiary differs from the form's current one), so skip the
      // extra roundtrip for text/select/etc. sets.
      const canRedirect = fieldMeta.isEntityRef;
      const preSubsidiary = canRedirect ? await readSubsidiarySnapshot(target) : null;

      // ── Set the field value with dialog capture ──────────────
      let setResult: { settled: boolean };
      let dialogs: CapturedDialog[];
      let reloaded = false;

      try {
        const handled = await withDialogHandler(
          bm,
          async () => {
            const page = bm.getPage();

            await page.evaluate(
              ({ fid, val, ffc, sync }: { fid: string; val: string; ffc: boolean; sync: boolean }) => {
                (window as any).nlapiSetFieldValue(fid, val, ffc, sync);
              },
              { fid: fieldId, val: value, ffc: fireFieldChanged, sync: synchronous },
            );

            // Verify value was set — custom forms with indexed widgets (hddn_{field}_{N})
            // can silently fail. If the value didn't stick, try syncing the indexed DOM element directly.
            const verifiedValue = await page.evaluate(
              (fid: string) => (window as any).nlapiGetFieldValue?.(fid) ?? null,
              fieldId,
            );
            // Compare trimmed values — NS sometimes returns padded strings
            const valueMatches = verifiedValue !== null && String(verifiedValue).trim() === String(value).trim();
            if (!valueMatches && fieldMeta.type === 'select') {
              // Fallback: directly sync indexed hidden/select elements on custom forms
              await page.evaluate(
                ({ fid, val }: { fid: string; val: string }) => {
                  const w = window as any;
                  // Retry the API call once
                  try { w.nlapiSetFieldValue?.(fid, val); } catch {}
                  // Direct DOM fallback: find indexed hidden elements and sync them
                  const form = document.getElementById('main_form');
                  if (!form) return;
                  const hddn = form.querySelector(`[id^="hddn_${fid}_"]`) as HTMLInputElement | null;
                  if (hddn) {
                    hddn.value = val;
                    // Also sync the visible select widget (must be an actual <select>)
                    const inpt = form.querySelector(`select[id^="inpt_${fid}_"]`) as HTMLSelectElement | null;
                    if (inpt && inpt.options) {
                      for (let i = 0; i < inpt.options.length; i++) {
                        if (inpt.options[i].value === val) {
                          inpt.selectedIndex = i;
                          break;
                        }
                      }
                    }
                  }
                },
                { fid: fieldId, val: value },
              );
            }

            // If cascading was fired, wait for convergence
            // Re-acquire target — sourcing may have reloaded the NS iframe
            target = bm.getActiveFrameOrPage();
            let settled = true;
            if (trackConvergence && watchFieldIds.length > 0) {
              const convergence = await waitForFieldConvergence(target, watchFieldIds, {
                stablePolls: 3,
                initialIntervalMs: 50,
                maxIntervalMs: 200,
                timeoutMs: 5000,
              });
              settled = convergence.converged;
            }

            return { settled };
          },
          { accept: true },
        );
        setResult = handled.result;
        dialogs = handled.dialogs;
      } catch (err) {
        if (!isNavigationDestroyedError(err)) throw err;
        // OneWorld subsidiary redirect: NS reloaded the form server-side.
        // Wait for the new page to settle, then re-acquire the NS API.
        // Dialogs captured before the throw are lost — withDialogHandler
        // doesn't expose them on error; acceptable because redirects
        // preempt any alert UX.
        reloaded = true;
        dialogs = [];
        await recoverFromRedirect(bm.getPage());
        target = bm.getActiveFrameOrPage();
        setResult = { settled: true };
      }

      // ── Compute diff ─────────────────────────────────────────
      // Re-acquire target — frame may have shifted during dialog handling
      target = bm.getActiveFrameOrPage();
      const changed: FieldChange[] = [];
      if (trackConvergence && watchFieldIds.length > 0) {
        // When reloaded, subsidiary is reported separately with display text —
        // drop it from the raw-value diff to avoid a duplicate entry.
        const diffFieldIds = reloaded
          ? watchFieldIds.filter(id => id !== SUBSIDIARY_FIELD_ID)
          : watchFieldIds;
        // After a redirect the page evaluated a fresh form — fields may 404
        // on read. Wrap in try so a partial read still produces a diff.
        try {
          const getter = createPageGetter(target);
          const afterValues = await getter(diffFieldIds);

          for (const fid of diffFieldIds) {
            const before = beforeValues[fid] ?? null;
            const after = afterValues[fid] ?? null;
            if (before !== after) {
              changed.push({ id: fid, before, after });
            }
          }
        } catch {
          // Post-redirect read failed — diff is best-effort
        }
      }

      // Subsidiary diff is the human-readable signal that the redirect fired —
      // prefer display text over raw IDs so the hint surfaces "Parent Co." not "1".
      if (reloaded) {
        const postSubsidiary = await readSubsidiarySnapshot(target);
        if (subsidiaryChanged(preSubsidiary, postSubsidiary)) {
          changed.push({
            id: SUBSIDIARY_FIELD_ID,
            before: preSubsidiary?.text ?? preSubsidiary?.value ?? null,
            after: postSubsidiary?.text ?? postSubsidiary?.value ?? null,
          });
        }
      }

      const elapsed = Date.now() - start;

      let hint: string | null = null;
      if (reloaded) {
        const postSub = changed.find(c => c.id === SUBSIDIARY_FIELD_ID);
        hint = postSub
          ? `form reloaded — subsidiary changed from ${truncateValue(postSub.before)} to ${truncateValue(postSub.after)}`
          : 'form reloaded — subsidiary shift triggered server-side redirect';
      } else if (cascadingLabel === 'suppressed' && !fieldMeta.isEntityRef && forceSource === null) {
        // Cascading suppressed on a non-entity field: caller may be testing
        // a client script handler that needs fieldChanged to fire.
        hint = `HINT: fieldChanged not fired for '${fieldId}'. If testing a client script handler, retry with --fire-field-changed (or --source).`;
      }

      return {
        ok: true as const,
        data: {
          fieldId,
          value,
          cascading: cascadingLabel,
          settled: setResult.settled,
          reloaded,
          elapsedMs: elapsed,
          diff: { changed },
          dialogs,
          hint,
        },
        dialogs,
      };
    }, { label: 'ns set' });

  if (!result.ok) {
    return { display: formatNsError('ns set', result.error!), ok: false };
  }

  const d = result.data!;
  const headerParts = [
    `SET OK`,
    `Field: ${d.fieldId} = ${truncateValue(d.value)}`,
    `Cascading: ${d.cascading}`,
    `Settled: ${d.settled ? 'yes' : 'no'}`,
  ];
  if (d.reloaded) headerParts.push('Reloaded: yes');
  const lines = [headerParts.join(' | ')];
  for (const c of d.diff.changed) {
    lines.push(`Changed: ${c.id} ${truncateValue(c.before)} → ${truncateValue(c.after)}`);
  }
  if (d.dialogs.length > 0) {
    for (const dl of d.dialogs) {
      lines.push(`Dialog (${dl.type}): ${truncateValue(dl.message)}`);
    }
  }
  if (d.hint) {
    lines.push(d.hint);
  }

  return { display: lines.join('\n'), ok: true };
}

// ─── Helpers ────────────────────────────────────────────────

/**
 * Read subsidiary value + display text. Returns null when the field isn't
 * present (non-OneWorld accounts or forms without a subsidiary field).
 */
async function readSubsidiarySnapshot(
  target: import('playwright').Page | import('playwright').Frame,
): Promise<SubsidiarySnapshot | null> {
  try {
    const meta = await introspectField(target, SUBSIDIARY_FIELD_ID);
    if (!meta) return null;
    return { value: meta.value, text: meta.displayValue };
  } catch {
    return null;
  }
}

function subsidiaryChanged(
  before: SubsidiarySnapshot | null,
  after: SubsidiarySnapshot | null,
): boolean {
  if (!before && !after) return false;
  if (!before || !after) return true;
  return (before.value ?? null) !== (after.value ?? null);
}

/**
 * Wait for the page to finish loading after an NS server-side redirect,
 * then wait for the NS client API to be available again. `load` fires after
 * `domcontentloaded` and after subresources, so it covers both.
 *
 * Total ceiling: ~10s. Each step soft-fails because the NS-API waitForFunction
 * is the real readiness signal — the earlier waits just amortize load time.
 */
async function recoverFromRedirect(page: import('playwright').Page): Promise<void> {
  await page.waitForLoadState('load', { timeout: 6_000 }).catch(() => {});
  await waitForSettle(page, { timeoutMs: 3_000, stableMs: 500 });
  await page.waitForFunction(
    () => typeof (window as any).nlapiGetField === 'function',
    { timeout: 6_000 },
  ).catch(() => {});
}
