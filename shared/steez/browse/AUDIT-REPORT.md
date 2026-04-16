# Browse Audit — Post-Restructure Drift + Standard Passes

**Audit bead:** steez-ltc
**Scope:** `shared/steez/browse/` + `skills/browse/SKILL.md`
**Date:** 2026-04-15
**Motivation:** steez-rmb just closed after fixing 5 test files with stale `../src/X` paths that had been silently broken for months post gstack→steez restructure. Check for remaining drift and other quality issues missed by the absent safety net.

---

## Executive Summary

**Overall health: mixed.** The architecture core (BrowserManager as the sole Playwright seam; `src/ns/**` depends on `src/core/**` only via type imports) is healthy. The `src/core/commands.ts` registry is clean. But the restructure left behind more drift than steez-rmb caught, the test harness itself is broken in a way that masks all of it, and the local server has real CSRF-class gaps behind the bearer token.

**Top 5 issues (fix immediately):**

1. **[CRITICAL]** 3 more stale `../src/X` test paths beyond what steez-rmb fixed (`sidebar-integration.test.ts:40`, `sidebar-agent-roundtrip.test.ts:76`, `sidebar-agent-roundtrip.test.ts:107`). Verified failing in live run. **Bead: steez-4ix**
2. **[CRITICAL]** All three `package.json` `bun test` scripts silently match zero files and exit 0 on bun 1.3.5. This — not "non-TTY output suppression" — is the actual invisibility mechanism that hid steez-rmb for months. **Bead: steez-i3k**
3. **[HIGH]** `/cookie-picker` GET serves the bearer token in the page source with no auth check. Combined with the hardcoded `BROWSE_PORT=34567` in headed mode, a page the user visits has a plausible path to read the token and drive `/sidebar-command` (which spawns Claude with Bash,Write,Read,Glob,Grep in the git worktree). **Bead: steez-07p**
4. **[HIGH]** `cookie-import` + `upload` + `meta-commands` all take user file paths with path validation that is either missing, weaker than `read-commands`, or lacks `realpathSync`. Symlink bypass is live. **Bead: steez-8jv**
5. **[HIGH]** Three `__dirname`-based runtime lookups still use gstack-era path math. All work only because a fallback rescues them — the drift itself is invisible to tests. **Bead: steez-a04**

**Corrections to the audit brief:**

- **"bun non-TTY suppresses output" was wrong.** Single explicit file args produce full failure output and exit 1. The real bug is that `bun test src/core/test/` (the form used in every `package.json` script) treats the path as a filter pattern that matches zero files, then exits 0 with one line of output. Running from inside the test dir works.
- **"CI was blind" is slightly wrong.** There is no CI. No `.github/workflows/`, no husky, no pre-commit hook, no `settings.json` hook running `bun test`. The CLAUDE.md claim "`bun test` runs before every commit to browse source" is a documentation-only convention with no mechanical enforcement. The only visibility layer that exists is "someone remembers to run it" — and if they did, it would return green anyway because of finding #2.

---

## Findings by category

### A — Post-restructure drift (the audit brief's headline concern)

#### A1 — [CRITICAL | confirmed] 3 stale test paths beyond steez-rmb's fix
- `src/core/test/sidebar-integration.test.ts:40` → `path.resolve(__dirname, '..', 'src', 'server.ts')` resolves to `src/core/src/server.ts` (doesn't exist). `beforeAll` throws "Server did not start in time" after 15s. Reproduced in this audit.
- `src/core/test/sidebar-agent-roundtrip.test.ts:76` — same pattern, same failure.
- `src/core/test/sidebar-agent-roundtrip.test.ts:107` → `src/core/src/sidebar-agent.ts` (doesn't exist).
- **Fix:** drop the `'src'` segment. Correct path from `src/core/test/` is `path.resolve(__dirname, '..', 'server.ts')`.
- **Bead:** steez-4ix

#### A2 — [HIGH | confirmed] Dev-mode `__dirname` path math broken by restructure
- `src/core/server.ts:138` `findBrowseBin()` first candidate: `path.resolve(__dirname, '..', 'dist', 'browse')` → `src/dist/browse` (dev) / `$bunfs/.../dist/browse` (compiled). Neither exists; function works via `~/.steez/bin/browse` + `PATH` fallbacks.
- `src/core/cli.ts:605` — same pattern, same drift. Saved by `process.execPath` fallback in compiled mode; dev-mode invocation would miss.
- `src/core/browser-manager.ts:195` `findExtensionPath()`: `path.resolve(__dirname, '..', '..', '..', 'extension')` → `steez/extension` (nonexistent; was valid under the gstack layout `browse/src/core → gstack/extension`). Saved by `~/.claude/skills/gstack/extension` fallback.
- **Fix:** mirror the `resolveServerScript` pattern — check for `$bunfs` marker and branch on dev-vs-compiled. Or remove the drifted candidates.
- **Bead:** steez-a04

#### A3 — [LOW | confirmed] Orphan binary from gstack era
- `dist/find-browse` — 60MB Mach-O binary dated Mar 31. No source reference (`grep find-browse` across repo returns empty). `dist/` is gitignored so nothing ships, but it wastes disk and confuses new contributors.
- **Fix:** `rm dist/find-browse`.

#### A4 — [LOW | confirmed] Cosmetic: comment at `src/core/cli.ts:39` accurately describes the live code. No action needed.

---

### B — Test-harness visibility (the CI-blindness root cause)

#### B1 — [CRITICAL | confirmed] `bun test` with directory arg silently matches nothing on bun 1.3.5
- `bun test src/core/test/` from repo root → exit 0, only "bun test v1.3.5 (1e86cebd)" printed.
- `bun test` (no args) from repo root → exit 0, same behavior.
- `bun test src/core/test/*.test.ts` (shell-expanded) → exit 0, silent.
- `bun test 'src/core/test/*.test.ts'` (quoted) → exit 1 with "did not match any test files" (visible!).
- `cd src/core/test && bun test` → works, proper output and exit code.
- **All three `package.json` scripts use the broken form:**
  ```
  "test":      "bun test src/core/test/ src/ns/test/ --ignore '**/*e2e*'"
  "test:core": "bun test src/core/test/"
  "test:ns":   "bun test src/ns/test/"
  ```
- **Fix options:** rewrite scripts to explicit file globs that actually fail visibly when empty, or `cd` into the test dir, or configure `bunfig.toml` with `test.root`, or upgrade bun.
- **Acceptance gate:** after fix, running `npm test` must (a) discover every non-e2e `*.test.ts` under both dirs, (b) print failure details, (c) exit non-zero on any failure.
- **Bead:** steez-i3k — fixing the test paths (A1) WITHOUT fixing this does nothing; wrapper script still masks all failures.

#### B2 — [MEDIUM | confirmed] `config.test.ts` compiled-binary branch silently skips when `dist/` isn't built
- `src/core/test/config.test.ts:200-228` wraps `resolveNodeServerScript` compiled-path tests in `if (fs.existsSync(distFile))`. On fresh checkout, no `bun run build` = tests become no-ops with no `test.skip` / no warning.
- `src/core/test/config.test.ts:183-197` — the `resolveServerScript` compiled-binary success path has no test at all (throw path is tested, success path is not).
- **Fix:** stage temp files in the test so the compiled path is always exercised. Unconditional coverage of the Windows hard-fail.

#### B3 — [MEDIUM | confirmed] No CI exists
- No `.github/workflows/`, no `.husky/`, no pre-commit hook, no `settings.json` hook wiring `bun test`.
- CLAUDE.md says "`bun test` runs before every commit to browse source" but nothing enforces it.
- **Fix:** add a `pre-commit` hook (or a SessionEnd/PostCommit Claude hook) that runs a working test invocation — after B1 is fixed, this is a cheap durable safety net.

---

### C — Security

#### C1 — [HIGH | confirmed] Bearer token leaked to browser DOM via `/cookie-picker`
- `src/core/cookie-picker-routes.ts:75-81` GET is unauthenticated by design (the picker page needs to render before the user authenticates).
- `src/core/cookie-picker-ui.ts:333` inlines the real bearer token as `const AUTH_TOKEN = '${authToken}'` inside the served HTML.
- `src/core/cli.ts:572` hardcodes `BROWSE_PORT=34567` in headed mode — well-known, predictable.
- Exploit chain: malicious page → `fetch('http://127.0.0.1:34567/cookie-picker')` → parse HTML → extract token → POST `/sidebar-command` → arbitrary `claude -p … --allowedTools Bash,Read,Glob,Grep,Write` in user's worktree.
- **Fix:** require bearer auth on GET `/cookie-picker`, or issue a short-lived scoped token for picker-only routes, or randomize the headed port, or add `Origin`/`Referer` check on POST endpoints.
- **Bead:** steez-07p

#### C2 — [HIGH | confirmed] Path validation asymmetry and missing realpath
- `src/core/read-commands.ts:68-92` `validateReadPath` — uses `realpathSync` (symlink-safe, correct).
- `src/core/meta-commands.ts:18` `SAFE_DIRECTORIES` — duplicate copy WITHOUT `realpathSync`. Symlink inside `/tmp/safe` pointing to `/etc/shadow` passes here.
- `src/core/write-commands.ts:290-299` (cookie-import) — `path.normalize + isPathWithin`, no `realpath`.
- `src/core/write-commands.ts:248-269` (upload) — **no safe-dir check at all**. Playwright's `setInputFiles` happily reads `/etc/shadow` and uploads it to whatever the page is.
- **Fix:** extract one `validateSafePath` helper in `src/core/platform.ts` using `realpathSync + isPathWithin`. Wire every file-reading command through it. Make an explicit decision on `upload` policy.
- **Bead:** steez-8jv

#### C3 — [HIGH | confirmed] Timing-unsafe token comparison
- `src/core/server.ts:43-46` `header === \`Bearer ${AUTH_TOKEN}\``. String `===` short-circuits on first differing byte.
- Academic risk on a 122-bit UUID over loopback, but cheap to fix.
- **Fix:** `crypto.timingSafeEqual` with length-prefix guard.

#### C4 — [HIGH | confirmed] `/health` leaks session state without auth
- `src/core/server.ts:904-926` — response includes `currentUrl`, `tabs`, session IDs, `mode`, agent status, subprocess status, queue length. Any page user visits can read `currentUrl` (which admin page the browser is on).
- **Fix:** reduce unauth response to `{status, uptime}` only. Token-gate everything else.

#### C5 — [MEDIUM | confirmed] No POST body size limit
- `src/core/server.ts:1048, 1123, 1174, 1211` — `await req.json()` on POST endpoints with no cap. OOM from a large body.
- **Fix:** read `req.arrayBuffer()` with a content-length cap or reject early.

#### C6 — [MEDIUM | confirmed] Session state in `/tmp` if `HOME` is unset
- `src/core/server.ts:121, 259` — fallback `process.env.HOME || '/tmp'`. If `HOME` is missing, chat history + git worktree land in world-readable `/tmp`. Fallback is a security downgrade, not a courtesy.
- **Fix:** refuse to start with `HOME` unset; no silent fallback.

#### C7 — [MEDIUM | confirmed] Subprocess `cwd` from state file with only `fs.accessSync` gate
- `src/core/sidebar-agent.ts:173-177` — `spawn('claude', claudeArgs, { cwd: queueEntry.cwd })`. `queueEntry.cwd` comes from the queue file. `fs.accessSync(effectiveCwd)` is the only guard and accepts any readable dir.
- **Fix:** require `cwd` to be inside `$HOME` or an explicit allowlist.

#### C8 — [LOW | confirmed] ReDoS on `frame --url <pattern>`
- `src/core/meta-commands.ts:528` — `new RegExp(args[1])` without flags, no length cap. User-supplied regex can backtrack indefinitely.
- **Fix:** length cap or safe-regex library.

#### C9 — **No hardcoded secrets** — searched every common pattern (`sk-`, `ghp_`, `xox[abp]-`, `AKIA`, `-----BEGIN`, `API_KEY=`, `TOKEN=`). Fixtures clean. `dist/.version` is a git SHA.

#### C10 — Dependencies clean. `playwright: ^1.58.2`, `diff: ^7.0.0` — no currently-known advisories. (No specific CVEs/GHSAs identified.)

---

### D — Architecture + code quality

#### D1 — [HIGH | confirmed] `src/core/server.ts` is 1271 lines with 387-line `start()`
- Five concerns fused: HTTP routing, sidebar session lifecycle, Claude subprocess queuing, buffer flushing, command dispatch. 16 inline route handlers with 14 copies of the Unauthorized Response literal.
- Suggested split: `sidebar-session.ts` (~380 LOC), `buffer-flush.ts` (~50), `dispatch.ts` (~195), `routes.ts` (~325), `lifecycle.ts` (~90), `server.ts` entry (~60).
- **Bead:** steez-e30

#### D2 — [HIGH | confirmed] Reverse-dependency through ns barrel
- `src/core/server.ts:571` imports `releaseAllLocks` from `../ns/commands/ns-login` — bypasses the `ns-commands.ts` barrel contract.
- `src/core/server.ts:570` imports `handleNsCommand` from `../ns/ns-commands` — correct.
- **Fix:** re-export `releaseAllLocks` via `ns-commands.ts`, OR introduce a lifecycle-hook registry in core (`onShutdown(() => releaseAllLocks())`) so ns self-registers. Covered in bead steez-e30.

#### D3 — [MEDIUM | confirmed] Dead `agentProcess: ChildProcess` state
- `src/core/server.ts:126, 467-476` — `agentProcess` is declared `ChildProcess | null`, only ever assigned `null` (queue-file architecture replaced direct spawning). `if (agentProcess) { … }` body is unreachable. Type `ChildProcess` is referenced at line 126 but `child_process` is never imported — compiles only because Bun doesn't typecheck during build.
- **Fix:** delete the state, the branch, and the dangling type reference. Covered in bead steez-e30.

#### D4 — [MEDIUM | confirmed] Path strings hardcoded in many places
- `~/.steez/browse/chromium-profile` — 5 occurrences (`server.ts:806,844`; `cli.ts:541,677`; `browser-manager.ts:324,942`).
- `sidebar-agent-queue.jsonl` — 3 occurrences (`server.ts:440`, `cli.ts:601`, `sidebar-agent.ts:16`).
- 13 direct `process.env.*` reads across 5 production files.
- **Fix:** extend `resolveConfig()` in `src/core/config.ts` to own every derived path + env var. Every module imports config instead of reading env.

#### D5 — [MEDIUM | confirmed] Response boilerplate duplication
- `src/core/server.ts` — 14 copies of the `Response(JSON.stringify({error: 'Unauthorized'}), {status: 401, …})` literal; 34 copies of the `Content-Type: application/json` header literal.
- **Fix:** helpers `jsonResponse(body, status=200)` + `unauthorized()`. Cuts ~100 LOC, eliminates drift.

#### D6 — [MEDIUM | confirmed] `handleCommand` responsibility violation
- `src/core/server.ts:642` `handleCommand()` is 134 lines, acceptable. But the watch-mode branch at lines 687-701 creates an interval and stashes it on `browserManager.watchInterval` — side-effect from inside a command dispatcher.
- **Fix:** move watch interval lifecycle into `meta-commands.ts` or `browser-manager.ts`.

#### D7 — [MEDIUM | confirmed] Platform-specific `open` in write-commands
- `src/core/write-commands.ts:353` — `Bun.spawn(['open', pickerUrl])`. Silently fails on Linux (no `open` on many distros) and Windows. Swallowed in try/catch.
- **Fix:** platform branch: `darwin`→`open`, `linux`→`xdg-open`, `win32`→`start` with `shell: true`.

#### D8 — [LOW | confirmed] Minor duplication — `gracefulKill`, `cleanupChromiumLocks` copy-pasted
- `src/core/cli.ts:529-536, 669-675` — identical SIGTERM→wait→SIGKILL pattern. Extract `gracefulKill(pid)`.
- Singleton{Lock,Socket,Cookie} cleanup loop copy-pasted 4×: `cli.ts:543-556, 677-680`; `server.ts:806, 844`. Extract `cleanupChromiumLocks(profileDir)`.

---

### E — Windows fallback (concern called out explicitly)

**Verdict: works end-to-end on macOS; real hard-fail at `cli.ts:80` fires at module init, which is slightly hostile to `--help`.**

#### E1 — [HIGH | suspected] `cli.ts:80-84` Windows hard-fail fires before `--help` handling
- Module-level `if (IS_WINDOWS && !NODE_SERVER_SCRIPT) throw …` at load time. On Windows without `bun run build`, even `browse --help` dies with the build error — no usage printout.
- **Fix:** move the check into `main()` guarded by the command not being `--help`/`-h`/`--version`.

#### E2 — [HIGH | suspected] `SERVER_SCRIPT = resolveServerScript()` runs on Windows too
- `src/core/cli.ts:52` runs unconditionally. On Windows the spawn uses `NODE_SERVER_SCRIPT`, never `SERVER_SCRIPT`. If the binary ever ships without the `src/` tree (release tarball of just `dist/`), this throws on Windows even when the Node fallback is present.
- **Fix:** `const SERVER_SCRIPT = IS_WINDOWS ? '' : resolveServerScript();`.

#### E3 — [HIGH | suspected] `bun:sqlite` Windows stub produces cryptic error
- `scripts/build-node-server.sh:29` replaces the import with `const Database = null`. If a Windows user has a migrated Chrome profile at `%USERPROFILE%\.config\google-chrome\`, `cookie-import-browser.ts` falls through to `openDb` and hits `TypeError: Database is not a constructor`.
- `cookie-import-browser.ts:312-314` returns `null` for Windows in `getHostPlatform()`, but `getSearchPlatforms()` still probes `darwin`/`linux` paths.
- **Fix:** stub with a class that throws "cookie import not supported on Windows", or add explicit Windows guard at `importCookies`.

#### E4 — [MEDIUM | confirmed] `bun-polyfill.cjs` polyfills have shape drift
- `src/core/bun-polyfill.cjs:67-85` `Bun.spawnSync` polyfill returns `{exitCode, stdout, stderr}` — real Bun returns `{exitCode, stdout, stderr, success, signalCode, resourceUsage, pid}`. No current caller breaks; any future `success`/`pid`/`signalCode` access on Windows gets `undefined`.
- `src/core/bun-polyfill.cjs:16-65` `Bun.serve` doesn't support `port: 0` (ephemeral) — uses literal `0` in the returned object instead of `server.address().port`. Dormant today (`findPort` pre-binds); breaks if anyone calls `Bun.serve({port: 0})` directly.
- **Fix:** `success: result.status === 0` in spawnSync; ephemeral port from `listening` event in serve.

#### E5 — Symlink resolution verified
- `~/.steez/bin/browse → dist/browse` is resolved by `process.execPath` on macOS (compiled Bun binary behavior). Verified: state file records `serverPath: .../browse/src/core/server.ts` after symlink invocation.

---

### F — SKILL.md vs binary behavior

**Skill file at `~/.steez/repo/skills/browse/SKILL.md` appears to match current binary behavior.** Spot checks:
- Snapshot flags (`-i -c -d N -s sel -D -a -o -C`) match the documented CLI surface.
- All listed commands (`goto`, `click`, `fill`, `snapshot`, `cookie-import-browser`, `handoff`, `resume`, etc.) exist in `read-commands.ts` / `write-commands.ts` / `meta-commands.ts` / `commands.ts`.
- Prompt-injection block ("untrusted external content markers") matches the wrapping in activity outputs.

**Minor observations (no bead):**
- `SKILL.md:246` — `state save|load <name>` documented; note the skill doesn't describe the security implication that saved state can contain auth cookies (out of scope for SKILL.md, but worth a security doc).
- `SKILL.md:125` — "always use the Read tool on the output PNG(s)" is a critical behavioral instruction; verify Claude actually follows it in practice.

---

## Prioritized action plan

### Fix immediately (blocks regression visibility + real attack surface)

1. **steez-i3k** — fix `package.json` test scripts to actually run tests. Without this, everything below is checked by a blind eye.
2. **steez-4ix** — fix the 3 stale `../src/X` test paths (depends on steez-i3k being done first, otherwise the fix is invisible).
3. **steez-07p** — auth-gate `/cookie-picker` or randomize the headed port. Realistic local-CSRF chain.
4. **steez-8jv** — unify path validation on `realpathSync`. Symlink bypass is live.

### Fix this sprint (drift + high-impact quality)

5. **steez-a04** — remove/fix the 3 gstack-era dist path lookups.
6. Add a pre-commit or session hook that runs `bun test` after steez-i3k — durable visibility.
7. Token timing-safe comparison (C3), `/health` leak (C4), POST body size cap (C5).
8. Delete `dist/find-browse` orphan.

### Plan for (architecture debt)

9. **steez-e30** — split `server.ts` into focused modules; fix the ns-barrel reverse-import; delete dead `agentProcess` state.
10. Extend `resolveConfig()` to own all env vars + derived paths.
11. Unify response helpers in `server.ts`.
12. Platform-branch the `open` call in `write-commands.ts`.

---

## What's working well

- **BrowserManager is the sole Playwright seam.** Every other file that touches Playwright types imports them as `import type`. That's real contractual separation.
- **`src/ns/**` → `src/core/**` is type-only coupling.** Clean architectural layering.
- **`commands.ts` registry** is a zero-side-effect single source of truth with runtime validation.
- **Atomic state-file writes** via `.tmp` + `rename` (`server.ts:1219-1231`).
- **Mutex-protected NS commands** (`src/ns/mutex.ts`) plus `fs.openSync(lockPath, 'wx')` for server lock — proper atomic lock primitives.
- **URL validation** with DNS-rebinding + cloud-metadata blocking (with minor gaps for decimal/hex IP forms — low severity).
- **Activity-stream redaction** for cookies, auth headers, secret patterns in storage reads.
- **No hardcoded secrets.** No SQL injection surface (parameterized queries in the cookie import). No command injection via shell strings (every `Bun.spawn` uses array form).

---

## Cross-cutting insight (durable)

Stored via `bd remember` as `bun-test-in-browse-bun-1-3-5`:

> bun test in browse (bun 1.3.5): passing a DIRECTORY arg silently matches zero files and exits 0. All three package.json scripts (test, test:core, test:ns) are broken this way — 'bun test v1.3.5' is the ONLY output. Use explicit file args OR cd into the test dir. This was the real invisibility mechanism behind the steez-rmb test-path drift sitting broken for months — not non-TTY output suppression. Single explicit file args work correctly (exit 1 on fail, full error trace).

---

## Emitted finding beads

| Bead | Severity | Title |
|---|---|---|
| steez-4ix | P1 | fix: 3 stale `../src/` paths in sidebar tests |
| steez-i3k | P1 | fix: `package.json` test scripts silently match zero files |
| steez-07p | P1 | security: `/cookie-picker` GET serves bearer token without auth |
| steez-8jv | P2 | security: `cookie-import` + `upload` lack realpath check |
| steez-a04 | P2 | refactor: dist/ path drift in 3 runtime lookups |
| steez-e30 | P3 | refactor: split server.ts + fix ns barrel + delete dead state |

All beads depend on steez-ltc (this audit).
