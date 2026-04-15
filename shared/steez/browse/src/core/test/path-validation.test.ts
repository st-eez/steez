import { describe, it, expect } from 'bun:test';
import { validateOutputPath } from '../meta-commands';
import { validateReadPath } from '../read-commands';
import { validateSafePath, SAFE_DIRECTORIES } from '../platform';
import { symlinkSync, unlinkSync, writeFileSync } from 'fs';
import { realpathSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

describe('validateOutputPath', () => {
  it('allows paths within /tmp', () => {
    expect(() => validateOutputPath('/tmp/screenshot.png')).not.toThrow();
  });

  it('allows paths in subdirectories of /tmp', () => {
    expect(() => validateOutputPath('/tmp/browse/output.png')).not.toThrow();
  });

  it('allows paths within cwd', () => {
    expect(() => validateOutputPath(`${process.cwd()}/output.png`)).not.toThrow();
  });

  it('blocks paths outside safe directories', () => {
    expect(() => validateOutputPath('/etc/cron.d/backdoor.png')).toThrow(/Path must be within/);
  });

  it('blocks /tmpevil prefix collision', () => {
    expect(() => validateOutputPath('/tmpevil/file.png')).toThrow(/Path must be within/);
  });

  it('blocks home directory paths', () => {
    expect(() => validateOutputPath('/Users/someone/file.png')).toThrow(/Path must be within/);
  });

  it('blocks path traversal via ..', () => {
    expect(() => validateOutputPath('/tmp/../etc/passwd')).toThrow(/Path must be within/);
  });

  it('blocks symlink inside safe dir pointing outside', () => {
    // Screenshot path validation now resolves symlinks too, so an attacker
    // can no longer drop a symlink in /tmp that writes to /etc.
    const linkPath = join(tmpdir(), 'test-output-symlink-bypass-' + Date.now());
    try {
      symlinkSync('/etc/passwd', linkPath);
      expect(() => validateOutputPath(linkPath)).toThrow(/Path must be within/);
    } finally {
      try { unlinkSync(linkPath); } catch {}
    }
  });
});

describe('validateReadPath', () => {
  it('allows absolute paths within /tmp', () => {
    expect(() => validateReadPath('/tmp/script.js')).not.toThrow();
  });

  it('allows absolute paths within cwd', () => {
    expect(() => validateReadPath(`${process.cwd()}/test.js`)).not.toThrow();
  });

  it('allows relative paths without traversal', () => {
    expect(() => validateReadPath('src/index.js')).not.toThrow();
  });

  it('blocks absolute paths outside safe directories', () => {
    expect(() => validateReadPath('/etc/passwd')).toThrow(/Path must be within/);
  });

  it('blocks /tmpevil prefix collision', () => {
    expect(() => validateReadPath('/tmpevil/file.js')).toThrow(/Path must be within/);
  });

  it('blocks path traversal sequences', () => {
    expect(() => validateReadPath('../../../etc/passwd')).toThrow(/Path must be within/);
  });

  it('blocks nested path traversal', () => {
    expect(() => validateReadPath('src/../../etc/passwd')).toThrow(/Path must be within/);
  });

  it('blocks symlink inside safe dir pointing outside', () => {
    const linkPath = join(tmpdir(), 'test-symlink-bypass-' + Date.now());
    try {
      symlinkSync('/etc/passwd', linkPath);
      expect(() => validateReadPath(linkPath)).toThrow(/Path must be within/);
    } finally {
      try { unlinkSync(linkPath); } catch {}
    }
  });

  it('throws clear error on non-ENOENT realpathSync failure', () => {
    // Attempting to resolve a path through a non-directory should throw
    // a descriptive error (ENOTDIR), not silently pass through.
    const filePath = join(tmpdir(), 'test-notdir-' + Date.now());
    try {
      writeFileSync(filePath, 'not a directory');
      const invalidPath = join(filePath, 'subpath');
      expect(() => validateReadPath(invalidPath)).toThrow(/Cannot resolve real path|Path must be within/);
    } finally {
      try { unlinkSync(filePath); } catch {}
    }
  });
});

describe('validateSafePath', () => {
  // SAFE_DIRECTORIES uses /tmp (not os.tmpdir()), so tests must use /tmp
  // directly. On macOS /tmp symlinks to /private/tmp — the validator
  // realpath-resolves both sides, so /tmp paths are accepted.
  const SAFE_TMP = '/tmp';
  const tmpReal = realpathSync(SAFE_TMP);
  const cwdReal = realpathSync(process.cwd());

  it('returns the real path for an existing file', () => {
    const filePath = join(SAFE_TMP, 'test-safepath-real-' + Date.now() + '.txt');
    try {
      writeFileSync(filePath, 'hi');
      const got = validateSafePath(filePath);
      expect(got).toBe(realpathSync(filePath));
    } finally {
      try { unlinkSync(filePath); } catch {}
    }
  });

  it('allows non-existent file inside safe dir (creation flow)', () => {
    const ghost = join(SAFE_TMP, 'does-not-exist-' + Date.now() + '.png');
    expect(() => validateSafePath(ghost)).not.toThrow();
  });

  it('throws File not found when mustExist and path is missing', () => {
    const ghost = join(SAFE_TMP, 'ghost-' + Date.now() + '.txt');
    expect(() => validateSafePath(ghost, SAFE_DIRECTORIES, { mustExist: true })).toThrow(/File not found/);
  });

  it('rejects absolute path outside safe dirs', () => {
    expect(() => validateSafePath('/etc/shadow')).toThrow(/Path must be within/);
  });

  it('rejects .. traversal', () => {
    expect(() => validateSafePath('/tmp/../etc/passwd')).toThrow(/Path must be within/);
  });

  it('rejects symlink inside safe dir pointing outside (mustExist)', () => {
    const linkPath = join(SAFE_TMP, 'test-safepath-symlink-' + Date.now());
    try {
      symlinkSync('/etc/passwd', linkPath);
      expect(() =>
        validateSafePath(linkPath, SAFE_DIRECTORIES, { mustExist: true }),
      ).toThrow(/Path must be within/);
    } finally {
      try { unlinkSync(linkPath); } catch {}
    }
  });

  it('rejects symlink inside safe dir pointing outside (creation mode)', () => {
    // Even without mustExist, a symlink that exists gets resolved. The
    // upload/cookie-import flows both land here.
    const linkPath = join(SAFE_TMP, 'test-safepath-symlink-nomust-' + Date.now());
    try {
      symlinkSync('/etc/passwd', linkPath);
      expect(() => validateSafePath(linkPath)).toThrow(/Path must be within/);
    } finally {
      try { unlinkSync(linkPath); } catch {}
    }
  });

  it('blocks a symlinked parent dir pointing outside (creation flow)', () => {
    // Writing to /tmp/evil-parent/foo.png where evil-parent -> /etc must fail
    // even though the leaf doesn't exist yet.
    const linkPath = join(SAFE_TMP, 'test-safepath-parent-link-' + Date.now());
    try {
      symlinkSync('/etc', linkPath);
      const child = join(linkPath, 'foo.png');
      expect(() => validateSafePath(child)).toThrow(/Path must be within/);
    } finally {
      try { unlinkSync(linkPath); } catch {}
    }
  });

  it('resolves /tmp through /private/tmp on macOS', () => {
    // Sanity check: SAFE_DIRECTORIES realpath-resolves before comparing, so
    // /tmp paths are accepted even when tmpReal is /private/tmp.
    const filePath = join(SAFE_TMP, 'test-safepath-macos-' + Date.now() + '.txt');
    try {
      writeFileSync(filePath, 'ok');
      const got = validateSafePath(filePath);
      expect(got.startsWith(tmpReal) || got.startsWith(cwdReal)).toBe(true);
    } finally {
      try { unlinkSync(filePath); } catch {}
    }
  });

  it('resolves ancestor even when multiple intermediate dirs are missing', () => {
    // /tmp/no-such/no-such-either/foo.png — parent chain doesn't exist, but
    // /tmp does and it symlinks to /private/tmp. Validator must walk up and
    // still classify this as safe.
    const ghost = join(SAFE_TMP, 'no-such-' + Date.now(), 'nested', 'foo.png');
    expect(() => validateSafePath(ghost)).not.toThrow();
  });

  // Adversarial: exactly what the upload command does. Symlink in /tmp →
  // /etc/passwd, pass it through the upload validation path, expect a throw.
  it('blocks upload symlink bypass to /etc/passwd', () => {
    const linkPath = join(SAFE_TMP, 'test-upload-bypass-' + Date.now());
    try {
      symlinkSync('/etc/passwd', linkPath);
      // Mirrors write-commands.ts upload validation exactly.
      expect(() =>
        validateSafePath(linkPath, SAFE_DIRECTORIES, { mustExist: true }),
      ).toThrow(/Path must be within/);
    } finally {
      try { unlinkSync(linkPath); } catch {}
    }
  });
});
