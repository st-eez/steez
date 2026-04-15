/**
 * browse server — persistent Chromium daemon
 *
 * Architecture:
 *   Bun.serve HTTP on localhost → routes commands to Playwright
 *   Console/network/dialog buffers: CircularBuffer in-memory + async disk flush
 *   Chromium crash → server EXITS with clear error (CLI auto-restarts)
 *   Auto-shutdown after BROWSE_IDLE_TIMEOUT (default 30 min)
 *
 * State:
 *   State file: <project-root>/.steez/browse.json (set via BROWSE_STATE_FILE env)
 *   Log files:  <project-root>/.steez/browse-{console,network,dialog}.log
 *   Port:       random 10000-60000 (or BROWSE_PORT env for debug override)
 */

import { BrowserManager } from './browser-manager';
import { handleReadCommand } from './read-commands';
import { handleWriteCommand } from './write-commands';
import { handleMetaCommand } from './meta-commands';
import { COMMAND_DESCRIPTIONS, PAGE_CONTENT_COMMANDS, wrapUntrustedContent } from './commands';
import { handleSnapshot, SNAPSHOT_FLAGS } from './snapshot';
import { resolveConfig, ensureStateDir, readVersionHash } from './config';
import { emitActivity, subscribe, getActivityAfter, getActivityHistory, getSubscriberCount } from './activity';
// Bun.spawn used instead of child_process.spawn (compiled bun binaries
// fail posix_spawn on all executables including /bin/bash)
import * as fs from 'fs';
import * as net from 'net';
import * as path from 'path';
import * as crypto from 'crypto';

// ─── Config ─────────────────────────────────────────────────────
const config = resolveConfig();
ensureStateDir(config);

// ─── Auth ───────────────────────────────────────────────────────
const AUTH_TOKEN = crypto.randomUUID();
const BROWSE_PORT = parseInt(process.env.BROWSE_PORT || '0', 10);
const IDLE_TIMEOUT_MS = parseInt(process.env.BROWSE_IDLE_TIMEOUT || '1800000', 10); // 30 min

function validateAuth(req: Request): boolean {
  const header = req.headers.get('authorization');
  return header === `Bearer ${AUTH_TOKEN}`;
}

// ─── Help text (auto-generated from COMMAND_DESCRIPTIONS) ────────
function generateHelpText(): string {
  // Group commands by category
  const groups = new Map<string, string[]>();
  for (const [cmd, meta] of Object.entries(COMMAND_DESCRIPTIONS)) {
    const display = meta.usage || cmd;
    const list = groups.get(meta.category) || [];
    list.push(display);
    groups.set(meta.category, list);
  }

  const categoryOrder = [
    'Navigation', 'Reading', 'Interaction', 'Inspection',
    'Visual', 'Snapshot', 'Meta', 'Tabs', 'Server',
    'NetSuite', 'Playwright',
  ];

  const lines = ['browse — headless browser for AI agents', '', 'Commands:'];
  for (const cat of categoryOrder) {
    const cmds = groups.get(cat);
    if (!cmds) continue;
    lines.push(`  ${(cat + ':').padEnd(15)}${cmds.join(', ')}`);
  }

  // Snapshot flags from source of truth
  lines.push('');
  lines.push('Snapshot flags:');
  const flagPairs: string[] = [];
  for (const flag of SNAPSHOT_FLAGS) {
    const label = flag.valueHint ? `${flag.short} ${flag.valueHint}` : flag.short;
    flagPairs.push(`${label}  ${flag.long}`);
  }
  // Print two flags per line for compact display
  for (let i = 0; i < flagPairs.length; i += 2) {
    const left = flagPairs[i].padEnd(28);
    const right = flagPairs[i + 1] || '';
    lines.push(`  ${left}${right}`);
  }

  return lines.join('\n');
}

// ─── Buffer (from buffers.ts) ────────────────────────────────────
import { consoleBuffer, networkBuffer, dialogBuffer, addConsoleEntry, addNetworkEntry, addDialogEntry, type LogEntry, type NetworkEntry, type DialogEntry } from './buffers';
export { consoleBuffer, networkBuffer, dialogBuffer, addConsoleEntry, addNetworkEntry, addDialogEntry, type LogEntry, type NetworkEntry, type DialogEntry };

const CONSOLE_LOG_PATH = config.consoleLog;
const NETWORK_LOG_PATH = config.networkLog;
const DIALOG_LOG_PATH = config.dialogLog;

let lastConsoleFlushed = 0;
let lastNetworkFlushed = 0;
let lastDialogFlushed = 0;
let flushInProgress = false;

async function flushBuffers() {
  if (flushInProgress) return; // Guard against concurrent flush
  flushInProgress = true;

  try {
    // Console buffer
    const newConsoleCount = consoleBuffer.totalAdded - lastConsoleFlushed;
    if (newConsoleCount > 0) {
      const entries = consoleBuffer.last(Math.min(newConsoleCount, consoleBuffer.length));
      const lines = entries.map(e =>
        `[${new Date(e.timestamp).toISOString()}] [${e.level}] ${e.text}`
      ).join('\n') + '\n';
      fs.appendFileSync(CONSOLE_LOG_PATH, lines);
      lastConsoleFlushed = consoleBuffer.totalAdded;
    }

    // Network buffer
    const newNetworkCount = networkBuffer.totalAdded - lastNetworkFlushed;
    if (newNetworkCount > 0) {
      const entries = networkBuffer.last(Math.min(newNetworkCount, networkBuffer.length));
      const lines = entries.map(e =>
        `[${new Date(e.timestamp).toISOString()}] ${e.method} ${e.url} → ${e.status || 'pending'} (${e.duration ?? '?'}ms, ${e.size ?? '?'}B)`
      ).join('\n') + '\n';
      fs.appendFileSync(NETWORK_LOG_PATH, lines);
      lastNetworkFlushed = networkBuffer.totalAdded;
    }

    // Dialog buffer
    const newDialogCount = dialogBuffer.totalAdded - lastDialogFlushed;
    if (newDialogCount > 0) {
      const entries = dialogBuffer.last(Math.min(newDialogCount, dialogBuffer.length));
      const lines = entries.map(e =>
        `[${new Date(e.timestamp).toISOString()}] [${e.type}] "${e.message}" → ${e.action}${e.response ? ` "${e.response}"` : ''}`
      ).join('\n') + '\n';
      fs.appendFileSync(DIALOG_LOG_PATH, lines);
      lastDialogFlushed = dialogBuffer.totalAdded;
    }
  } catch {
    // Flush failures are non-fatal — buffers are in memory
  } finally {
    flushInProgress = false;
  }
}

// Flush every 1 second
const flushInterval = setInterval(flushBuffers, 1000);

// ─── Idle Timer ────────────────────────────────────────────────
let lastActivity = Date.now();

function resetIdleTimer() {
  lastActivity = Date.now();
}

const idleCheckInterval = setInterval(() => {
  if (Date.now() - lastActivity > IDLE_TIMEOUT_MS) {
    console.log(`[browse] Idle for ${IDLE_TIMEOUT_MS / 1000}s, shutting down`);
    shutdown();
  }
}, 60_000);

// ─── Command Sets (from commands.ts — single source of truth) ───
import { READ_COMMANDS, WRITE_COMMANDS, META_COMMANDS, NS_COMMANDS, PLAYWRIGHT_COMMANDS } from './commands';
export { READ_COMMANDS, WRITE_COMMANDS, META_COMMANDS, NS_COMMANDS, PLAYWRIGHT_COMMANDS };

// ─── NS + Playwright handlers ───────────────────────────────────
import { handleNsCommand } from '../ns/ns-commands';
import { releaseAllLocks } from '../ns/commands/ns-login';
import { handleTracingCommand } from '../playwright/tracing';
import { handleRoutingCommand } from '../playwright/routing';
import { handleVideoCommand } from '../playwright/video';

// ─── Server ────────────────────────────────────────────────────
const browserManager = new BrowserManager();
// Route browser disconnect through shared shutdown so all cleanup runs
browserManager.onDisconnect = (exitCode) => shutdown(exitCode);
let isShuttingDown = false;

// Test if a port is available by binding and immediately releasing.
// Uses net.createServer instead of Bun.serve to avoid a race condition
// in the Node.js polyfill where listen/close are async but the caller
// expects synchronous bind semantics. See: #486
function isPortAvailable(port: number, hostname: string = '127.0.0.1'): Promise<boolean> {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.once('error', () => resolve(false));
    srv.listen(port, hostname, () => {
      srv.close(() => resolve(true));
    });
  });
}

// Find port: explicit BROWSE_PORT, or random in 10000-60000
async function findPort(): Promise<number> {
  // Explicit port override (for debugging)
  if (BROWSE_PORT) {
    if (await isPortAvailable(BROWSE_PORT)) {
      return BROWSE_PORT;
    }
    throw new Error(`[browse] Port ${BROWSE_PORT} (from BROWSE_PORT env) is in use`);
  }

  // Random port with retry
  const MIN_PORT = 10000;
  const MAX_PORT = 60000;
  const MAX_RETRIES = 5;
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    const port = MIN_PORT + Math.floor(Math.random() * (MAX_PORT - MIN_PORT));
    if (await isPortAvailable(port)) {
      return port;
    }
  }
  throw new Error(`[browse] No available port after ${MAX_RETRIES} attempts in range ${MIN_PORT}-${MAX_PORT}`);
}

/**
 * Translate Playwright errors into actionable messages for AI agents.
 */
function wrapError(err: any): string {
  const msg = err.message || String(err);
  // Timeout errors
  if (err.name === 'TimeoutError' || msg.includes('Timeout') || msg.includes('timeout')) {
    if (msg.includes('locator.click') || msg.includes('locator.fill') || msg.includes('locator.hover')) {
      return `Element not found or not interactable within timeout. Check your selector or run 'snapshot' for fresh refs.`;
    }
    if (msg.includes('page.goto') || msg.includes('Navigation')) {
      return `Page navigation timed out. The URL may be unreachable or the page may be loading slowly.`;
    }
    return `Operation timed out: ${msg.split('\n')[0]}`;
  }
  // Multiple elements matched
  if (msg.includes('resolved to') && msg.includes('elements')) {
    return `Selector matched multiple elements. Be more specific or use @refs from 'snapshot'.`;
  }
  // Pass through other errors
  return msg;
}

async function handleCommand(body: any): Promise<Response> {
  const { command, args = [] } = body;

  if (!command) {
    return new Response(JSON.stringify({ error: 'Missing "command" field' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Block mutation commands while watching (read-only observation mode)
  if (browserManager.isWatching() && WRITE_COMMANDS.has(command)) {
    return new Response(JSON.stringify({
      error: 'Cannot run mutation commands while watching. Run `$B watch stop` first.',
    }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Activity: emit command_start
  const startTime = Date.now();
  emitActivity({
    type: 'command_start',
    command,
    args,
    url: browserManager.getCurrentUrl(),
    tabs: browserManager.getTabCount(),
    mode: browserManager.getConnectionMode(),
  });

  try {
    let result: string;
    let nsMetadata: import('../core/activity').NsMetadata | undefined;

    if (READ_COMMANDS.has(command)) {
      result = await handleReadCommand(command, args, browserManager);
      if (PAGE_CONTENT_COMMANDS.has(command)) {
        result = wrapUntrustedContent(result, browserManager.getCurrentUrl());
      }
    } else if (WRITE_COMMANDS.has(command)) {
      result = await handleWriteCommand(command, args, browserManager);
    } else if (META_COMMANDS.has(command)) {
      result = await handleMetaCommand(command, args, browserManager, shutdown);
      // Start periodic snapshot interval when watch mode begins
      if (command === 'watch' && args[0] !== 'stop' && browserManager.isWatching()) {
        const watchInterval = setInterval(async () => {
          if (!browserManager.isWatching()) {
            clearInterval(watchInterval);
            return;
          }
          try {
            const snapshot = await handleSnapshot(['-i'], browserManager);
            browserManager.addWatchSnapshot(snapshot);
          } catch {
            // Page may be navigating — skip this snapshot
          }
        }, 5000);
        browserManager.watchInterval = watchInterval;
      }
    } else if (command === 'ns' && args.length > 0 && NS_COMMANDS.has(`ns ${args[0]}`)) {
      // NS commands: "ns navigate ..." → handleNsCommand("ns navigate", [...])
      const nsSubCommand = args[0];
      const nsOutput = await handleNsCommand(`ns ${nsSubCommand}`, args.slice(1), browserManager);
      result = nsOutput.display;
      nsMetadata = nsOutput.metadata;
    } else if (PLAYWRIGHT_COMMANDS.has(command)) {
      // Playwright commands: tracing-start, route, video-start, etc.
      if (command.startsWith('tracing')) {
        result = await handleTracingCommand(command, args, browserManager);
      } else if (command === 'route' || command === 'unroute' || command === 'route-list') {
        result = await handleRoutingCommand(command, args, browserManager);
      } else {
        result = await handleVideoCommand(command, args, browserManager);
      }
    } else if (command === 'help') {
      const helpText = generateHelpText();
      return new Response(helpText, {
        status: 200,
        headers: { 'Content-Type': 'text/plain' },
      });
    } else {
      return new Response(JSON.stringify({
        error: `Unknown command: ${command}`,
        hint: `Available commands: ${[...READ_COMMANDS, ...WRITE_COMMANDS, ...META_COMMANDS, ...NS_COMMANDS, ...PLAYWRIGHT_COMMANDS].sort().join(', ')}`,
      }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Activity: emit command_end (success)
    emitActivity({
      type: 'command_end',
      command,
      args,
      url: browserManager.getCurrentUrl(),
      duration: Date.now() - startTime,
      status: 'ok',
      result: result,
      tabs: browserManager.getTabCount(),
      mode: browserManager.getConnectionMode(),
      ...(nsMetadata ? { nsMetadata } : {}),
    });

    browserManager.resetFailures();
    return new Response(result, {
      status: 200,
      headers: { 'Content-Type': 'text/plain' },
    });
  } catch (err: any) {
    // Activity: emit command_end (error)
    emitActivity({
      type: 'command_end',
      command,
      args,
      url: browserManager.getCurrentUrl(),
      duration: Date.now() - startTime,
      status: 'error',
      error: err.message,
      tabs: browserManager.getTabCount(),
      mode: browserManager.getConnectionMode(),
    });

    browserManager.incrementFailures();
    let errorMsg = wrapError(err);
    const hint = browserManager.getFailureHint();
    if (hint) errorMsg += '\n' + hint;
    return new Response(JSON.stringify({ error: errorMsg }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}

async function shutdown(exitCode: number = 0) {
  if (isShuttingDown) return;
  isShuttingDown = true;

  console.log('[browse] Shutting down...');
  try {
    // Stop watch mode if active
    if (browserManager.isWatching()) browserManager.stopWatch();
    clearInterval(flushInterval);
    clearInterval(idleCheckInterval);
    await flushBuffers(); // Final flush (async now)
  } catch (err) {
    console.error('[browse] Error during shutdown cleanup:', (err as Error).message);
  }

  // If the browser already disconnected (crash/user closed), close() can't
  // talk to it, so kill the child process directly. On graceful shutdown
  // (stop/SIGTERM), skip the kill so close() can flush profile state cleanly.
  if (!browserManager.isConnected()) {
    try { browserManager.killProcess(); } catch {}
  }
  await browserManager.close();

  // Clean up Chromium profile locks (prevent SingletonLock on next launch)
  const profileDir = path.join(process.env.HOME || '/tmp', '.steez', 'browse', 'chromium-profile');
  for (const lockFile of ['SingletonLock', 'SingletonSocket', 'SingletonCookie']) {
    try { fs.unlinkSync(path.join(profileDir, lockFile)); } catch {}
  }

  // Clean up state file
  try { fs.unlinkSync(config.stateFile); } catch {}

  // Release NS account locks held by this process
  releaseAllLocks();

  process.exit(exitCode);
}

// Handle signals — wrap to avoid passing signal name as exitCode
process.on('SIGTERM', () => { void shutdown(0); });
process.on('SIGINT', () => { void shutdown(0); });
// Windows: taskkill /F bypasses SIGTERM, but 'exit' fires for some shutdown paths.
// Defense-in-depth — primary cleanup is the CLI's stale-state detection via health check.
if (process.platform === 'win32') {
  process.on('exit', () => {
    try { fs.unlinkSync(config.stateFile); } catch {}
  });
}

// Emergency cleanup for crashes (OOM, uncaught exceptions, browser disconnect)
// This is synchronous — called right before process.exit(), so no await.
// Kill the Chrome child process directly via SIGKILL to prevent orphans.
function emergencyCleanup() {
  if (isShuttingDown) return;
  isShuttingDown = true;
  // Kill the browser's child process to prevent orphaned Chrome
  try { browserManager.killProcess(); } catch {}
  // Clean Chromium profile locks
  const profileDir = path.join(process.env.HOME || '/tmp', '.steez', 'browse', 'chromium-profile');
  for (const lockFile of ['SingletonLock', 'SingletonSocket', 'SingletonCookie']) {
    try { fs.unlinkSync(path.join(profileDir, lockFile)); } catch {}
  }
  try { fs.unlinkSync(config.stateFile); } catch {}
}
process.on('uncaughtException', (err) => {
  console.error('[browse] FATAL uncaught exception:', err.message);
  emergencyCleanup();
  process.exit(1);
});
process.on('unhandledRejection', (err: any) => {
  const msg: string = err?.message || String(err);
  // Navigation timeouts and Playwright frame lifecycle errors produce secondary
  // unhandled rejections that are non-fatal — the primary error is already caught
  // by ns-navigate / handleCommand. Don't crash the server for these.
  const isNavRelated = /timeout|navigation|frame was detached|target closed|context was destroyed/i.test(msg);
  if (isNavRelated) {
    console.error('[browse] Non-fatal unhandled rejection (navigation):', msg);
    return;
  }
  console.error('[browse] FATAL unhandled rejection:', msg);
  emergencyCleanup();
  process.exit(1);
});

// ─── Start ─────────────────────────────────────────────────────
async function start() {
  // Clear old log files
  try { fs.unlinkSync(CONSOLE_LOG_PATH); } catch {}
  try { fs.unlinkSync(NETWORK_LOG_PATH); } catch {}
  try { fs.unlinkSync(DIALOG_LOG_PATH); } catch {}

  const port = await findPort();

  // Launch browser (headless)
  // BROWSE_HEADLESS_SKIP=1 skips browser launch entirely (for HTTP-only testing)
  const skipBrowser = process.env.BROWSE_HEADLESS_SKIP === '1';
  if (!skipBrowser) {
    await browserManager.launch();
  }

  const startTime = Date.now();
  const server = Bun.serve({
    port,
    hostname: '127.0.0.1',
    fetch: async (req) => {
      const url = new URL(req.url);

      // Health check — no auth required, does NOT reset idle timer
      if (url.pathname === '/health') {
        const healthy = await browserManager.isHealthy();
        return new Response(JSON.stringify({
          status: healthy ? 'healthy' : 'unhealthy',
          mode: browserManager.getConnectionMode(),
          uptime: Math.floor((Date.now() - startTime) / 1000),
          tabs: browserManager.getTabCount(),
          currentUrl: browserManager.getCurrentUrl(),
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // Refs endpoint — auth required, does NOT reset idle timer
      if (url.pathname === '/refs') {
        if (!validateAuth(req)) {
          return new Response(JSON.stringify({ error: 'Unauthorized' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' },
          });
        }
        const refs = browserManager.getRefMap();
        return new Response(JSON.stringify({
          refs,
          url: browserManager.getCurrentUrl(),
          mode: browserManager.getConnectionMode(),
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // Activity stream — SSE, auth required, does NOT reset idle timer
      if (url.pathname === '/activity/stream') {
        // Inline auth: accept Bearer header OR ?token= query param (EventSource can't send headers)
        const streamToken = url.searchParams.get('token');
        if (!validateAuth(req) && streamToken !== AUTH_TOKEN) {
          return new Response(JSON.stringify({ error: 'Unauthorized' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' },
          });
        }
        const afterId = parseInt(url.searchParams.get('after') || '0', 10);
        const encoder = new TextEncoder();

        const stream = new ReadableStream({
          start(controller) {
            // 1. Gap detection + replay
            const { entries, gap, gapFrom, availableFrom } = getActivityAfter(afterId);
            if (gap) {
              controller.enqueue(encoder.encode(`event: gap\ndata: ${JSON.stringify({ gapFrom, availableFrom })}\n\n`));
            }
            for (const entry of entries) {
              controller.enqueue(encoder.encode(`event: activity\ndata: ${JSON.stringify(entry)}\n\n`));
            }

            // 2. Subscribe for live events
            const unsubscribe = subscribe((entry) => {
              try {
                controller.enqueue(encoder.encode(`event: activity\ndata: ${JSON.stringify(entry)}\n\n`));
              } catch {
                unsubscribe();
              }
            });

            // 3. Heartbeat every 15s
            const heartbeat = setInterval(() => {
              try {
                controller.enqueue(encoder.encode(`: heartbeat\n\n`));
              } catch {
                clearInterval(heartbeat);
                unsubscribe();
              }
            }, 15000);

            // 4. Cleanup on disconnect
            req.signal.addEventListener('abort', () => {
              clearInterval(heartbeat);
              unsubscribe();
              try { controller.close(); } catch {}
            });
          },
        });

        return new Response(stream, {
          headers: {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
          },
        });
      }

      // Activity history — REST, auth required, does NOT reset idle timer
      if (url.pathname === '/activity/history') {
        if (!validateAuth(req)) {
          return new Response(JSON.stringify({ error: 'Unauthorized' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' },
          });
        }
        const limit = parseInt(url.searchParams.get('limit') || '50', 10);
        const { entries, totalAdded } = getActivityHistory(limit);
        return new Response(JSON.stringify({ entries, totalAdded, subscribers: getSubscriberCount() }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // ─── Auth-required endpoints ──────────────────────────────────

      if (!validateAuth(req)) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      if (url.pathname === '/command' && req.method === 'POST') {
        resetIdleTimer();  // Only commands reset idle timer
        const body = await req.json();
        return handleCommand(body);
      }

      return new Response('Not found', { status: 404 });
    },
  });

  // Write state file (atomic: write .tmp then rename)
  const state: Record<string, unknown> = {
    pid: process.pid,
    port,
    token: AUTH_TOKEN,
    startedAt: new Date().toISOString(),
    serverPath: path.resolve(import.meta.dir, 'server.ts'),
    binaryVersion: readVersionHash() || undefined,
    mode: browserManager.getConnectionMode(),
  };
  const tmpFile = config.stateFile + '.tmp';
  fs.writeFileSync(tmpFile, JSON.stringify(state, null, 2), { mode: 0o600 });
  fs.renameSync(tmpFile, config.stateFile);

  browserManager.serverPort = port;

  // Clean up stale state files (older than 7 days)
  try {
    const stateDir = path.join(config.stateDir, 'browse-states');
    if (fs.existsSync(stateDir)) {
      const SEVEN_DAYS = 7 * 24 * 60 * 60 * 1000;
      for (const file of fs.readdirSync(stateDir)) {
        const filePath = path.join(stateDir, file);
        const stat = fs.statSync(filePath);
        if (Date.now() - stat.mtimeMs > SEVEN_DAYS) {
          fs.unlinkSync(filePath);
          console.log(`[browse] Deleted stale state file: ${file}`);
        }
      }
    }
  } catch {}

  console.log(`[browse] Server running on http://127.0.0.1:${port} (PID: ${process.pid})`);
  console.log(`[browse] State file: ${config.stateFile}`);
  console.log(`[browse] Idle timeout: ${IDLE_TIMEOUT_MS / 1000}s`);
}

start().catch((err) => {
  console.error(`[browse] Failed to start: ${err.message}`);
  // Write error to disk for the CLI to read — on Windows, the CLI can't capture
  // stderr because the server is launched with detached: true, stdio: 'ignore'.
  try {
    const errorLogPath = path.join(config.stateDir, 'browse-startup-error.log');
    fs.mkdirSync(config.stateDir, { recursive: true });
    fs.writeFileSync(errorLogPath, `${new Date().toISOString()} ${err.message}\n${err.stack || ''}\n`);
  } catch {
    // stateDir may not exist — nothing more we can do
  }
  process.exit(1);
});
