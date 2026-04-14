/**
 * Shared arg parser for `set`-style NS commands (ns set, ns diff set).
 *
 * Flag vocabulary:
 *   --source, --fire-field-changed → force fire cascading
 *   --no-source                    → force suppress cascading
 *   (omitted)                      → fire by default
 *
 * Positional: <fieldId> <value>
 *
 * Keeping this shared prevents spec drift between ns set and ns diff — a new
 * alias or typo in one and not the other would be silently wrong.
 */

export interface ParsedSetArgs {
  fieldId: string | null;
  value: string | null;
  forceSource: boolean | null;
}

export function parseSetArgs(args: string[]): ParsedSetArgs {
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
