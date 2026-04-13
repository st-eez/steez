/**
 * Shared SuiteQL execution helper.
 *
 * Runs a SuiteQL query via the authenticated session cookie using
 * page.evaluate(fetch(...)). Does not navigate away from the current page.
 */

import type { Page } from 'playwright';

export interface SuiteQLResponse {
  error?: string;
  status?: number;
  items?: Record<string, unknown>[];
  totalResults?: number;
  hasMore?: boolean;
}

/**
 * Execute a SuiteQL query on the given page. Returns raw response
 * with `links` noise stripped from each item.
 */
export async function executeSuiteQL(page: Page, sql: string): Promise<SuiteQLResponse> {
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

  // Strip SuiteQL `links` noise from every item
  if (response.items) {
    response.items = response.items.map(row =>
      Object.fromEntries(Object.entries(row).filter(([k]) => k !== 'links')),
    );
  }

  return response;
}
