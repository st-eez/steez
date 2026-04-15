/**
 * Cross-platform constants and shared filesystem guards for browse.
 *
 * On macOS/Linux: TEMP_DIR = '/tmp', path.sep = '/'  — identical to hardcoded values.
 * On Windows: TEMP_DIR = os.tmpdir(), path.sep = '\\' — correct Windows behavior.
 */

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

export const IS_WINDOWS = process.platform === 'win32';
export const TEMP_DIR = IS_WINDOWS ? os.tmpdir() : '/tmp';

/**
 * Filesystem roots that browse file I/O is restricted to.
 *
 * Raw form — callers go through {@link validateSafePath}, which resolves
 * symlinks on both the user path and these roots before comparing.
 */
export const SAFE_DIRECTORIES: string[] = [TEMP_DIR, process.cwd()];

/** Check if resolvedPath is within dir, using platform-aware separators. */
export function isPathWithin(resolvedPath: string, dir: string): boolean {
  return resolvedPath === dir || resolvedPath.startsWith(dir + path.sep);
}

function resolveRealRoots(roots: string[]): string[] {
  return roots.map(d => {
    try { return fs.realpathSync(d); } catch { return d; }
  });
}

function resolveThroughExistingAncestor(resolved: string): string {
  let current = resolved;
  const tail: string[] = [];
  while (true) {
    try {
      const real = fs.realpathSync(current);
      return tail.length === 0 ? real : path.join(real, ...tail.reverse());
    } catch {
      const parent = path.dirname(current);
      if (parent === current) return resolved; // hit root without resolving
      tail.push(path.basename(current));
      current = parent;
    }
  }
}

export interface ValidateSafePathOptions {
  /**
   * When true, the path must already exist. realpathSync resolves the full
   * chain, so any symlink escape is caught. When false (default), the path
   * may not exist yet (for creation flows like screenshot output); the
   * parent dir is realpath-resolved so symlink-redirected parents still fail.
   */
  mustExist?: boolean;
}

/**
 * Validate that `userPath` resolves to a location within `allowedRoots` after
 * resolving all symlinks on both sides. Returns the resolved real path.
 *
 * Throws when:
 * - The resolved path escapes every allowed root (symlink bypass, traversal).
 * - `mustExist` is true and the path does not exist.
 * - realpathSync fails for a reason other than ENOENT (e.g., ENOTDIR).
 */
export function validateSafePath(
  userPath: string,
  allowedRoots: string[] = SAFE_DIRECTORIES,
  options: ValidateSafePathOptions = {},
): string {
  const resolved = path.resolve(userPath);
  const realRoots = resolveRealRoots(allowedRoots);

  let exists = true;
  let realPath: string;
  try {
    realPath = fs.realpathSync(resolved);
  } catch (err: any) {
    if (err.code !== 'ENOENT') {
      throw new Error(`Cannot resolve real path: ${userPath} (${err.code})`);
    }
    exists = false;
    // Path doesn't exist yet. Walk up to the deepest ancestor that does,
    // realpath-resolve it, and reattach the missing tail. Handles both
    // symlinked parents (/tmp/link -> /etc, writing /tmp/link/foo) and
    // platform symlinks like macOS /tmp -> /private/tmp when neither the
    // leaf nor any intermediate dir exists yet.
    realPath = resolveThroughExistingAncestor(resolved);
  }

  // Safety check first — an attacker-controlled traversal that lands on a
  // nonexistent path is still a rejection reason, not a "file not found".
  const isSafe = realRoots.some(dir => isPathWithin(realPath, dir));
  if (!isSafe) {
    throw new Error(`Path must be within: ${realRoots.join(', ')}`);
  }
  if (!exists && options.mustExist) {
    throw new Error(`File not found: ${userPath}`);
  }
  return realPath;
}
