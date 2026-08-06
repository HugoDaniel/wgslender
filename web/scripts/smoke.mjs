#!/usr/bin/env node
// A browser smoke check for the playground: launches headless Chrome, drives
// the page over the DevTools protocol, and asserts what only a real browser
// can show — that the island boots, that the editor replaces the fallback,
// that the language server's diagnostics render, and that typing produces new
// ones.
//
// `pnpm test` covers the logic; this covers the wiring. It exists because the
// interesting failures here (a module that resolves in Node but not in Vite,
// a wasm URL that 404s, a CodeMirror extension that silently does nothing)
// all look fine from Node and fine in the build output.
//
// Usage: start the dev server, then `pnpm smoke`. Override the target with
// PLAYGROUND_URL. Requires Google Chrome installed.

import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const URL_ = process.env.PLAYGROUND_URL ?? 'http://localhost:4321/playground/';
const PORT = Number(process.env.CDP_PORT ?? 9333);
const CHROME =
  process.env.CHROME_PATH ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const profile = await mkdtemp(join(tmpdir(), 'wgslender-smoke-'));
const chrome = spawn(
  CHROME,
  [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    'about:blank',
  ],
  { stdio: 'ignore' },
);

let ws;
async function cleanup() {
  ws?.close();
  // Wait for Chrome to actually exit: it keeps writing to the profile as it
  // shuts down, and removing the directory underneath it races.
  const exited = new Promise((res) => chrome.once('exit', res));
  chrome.kill();
  await Promise.race([exited, sleep(5000)]);
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(() => {});
}

async function pageTarget() {
  for (let i = 0; i < 80; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      const page = list.find((t) => t.type === 'page');
      if (page) return page;
    } catch {
      /* Chrome is still starting up. */
    }
    await sleep(250);
  }
  throw new Error(`Chrome never exposed a page target on port ${PORT}`);
}

const target = await pageTarget();
ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => {
  ws.addEventListener('open', res, { once: true });
  ws.addEventListener('error', rej, { once: true });
});

let nextId = 0;
const pending = new Map();
const problems = [];
ws.addEventListener('message', (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    const d = msg.params.exceptionDetails;
    problems.push(`uncaught: ${d.exception?.description ?? d.text}`);
  }
  if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
    problems.push(`console.error: ${msg.params.args.map((a) => a.value ?? a.description).join(' ')}`);
  }
});

function send(method, params = {}) {
  const id = ++nextId;
  return new Promise((res) => {
    pending.set(id, res);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  const details = r.result?.exceptionDetails;
  if (details) throw new Error(details.exception?.description ?? details.text);
  return r.result.result.value;
}

/** Poll `expression` until it is truthy; returns false on timeout. */
async function until(expression, ms = 30000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) return true;
    await sleep(200);
  }
  return false;
}

const checks = [];
const check = (name, ok, detail = '') => checks.push({ name, ok: Boolean(ok), detail: String(detail) });

try {
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Page.navigate', { url: URL_ });

  check('the editor mounts', await until(`!!document.querySelector('.cm-editor')`));
  check('the no-JS fallback is replaced', await evaluate(`!document.querySelector('.fallback')`));

  const status = await evaluate(`document.querySelector('[data-status]')?.textContent ?? ''`);
  check('the status line reports a live server', status.includes('ready'), status);

  // didOpen publishes in the same batch, so the squiggle is there on arrival:
  // exactly one W0001 for the sample's uncalled helper.
  check(
    'diagnostics render on load',
    await until(`document.querySelectorAll('.cm-lintRange-warning').length === 1`),
    `warnings=${await evaluate(`document.querySelectorAll('.cm-lintRange-warning').length`)}`,
  );
  check(
    'the lint gutter is marked',
    await evaluate(`document.querySelectorAll('.cm-lint-marker-warning').length === 1`),
  );

  // Highlighting comes from the stream mode, not the server.
  const classes = await evaluate(
    `new Set([...document.querySelectorAll('.cm-line span')].map(s => s.className)).size`,
  );
  check('the WGSL mode highlights', classes >= 6, `${classes} distinct token classes`);

  const columns = async (width) => {
    await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: false });
    await sleep(300);
    const value = await evaluate(`getComputedStyle(document.querySelector('.playground')).gridTemplateColumns`);
    return value.split(' ').length;
  };
  check('two columns on a wide viewport', (await columns(1280)) === 2);
  check('one column under 768px', (await columns(600)) === 1);
  await columns(1280);

  // The round trip: keystroke -> didChange -> wasm -> publishDiagnostics.
  await evaluate(`document.querySelector('.cm-content').focus()`);
  await send('Input.insertText', { text: 'fn oops(\n' });
  check(
    'typing produces new diagnostics',
    await until(`document.querySelectorAll('.cm-lintRange-error').length > 0`, 10000),
  );

  check('no page errors', problems.length === 0, problems.join(' | '));
} catch (error) {
  // A throw mid-run is itself a failure, but the checks that already ran are
  // the useful part of the report — so record it and fall through to print.
  check('the run completed', false, error?.message ?? String(error));
} finally {
  await cleanup();
}

const failed = checks.filter((c) => !c.ok);
for (const c of checks) {
  console.log(`${c.ok ? 'ok  ' : 'FAIL'} ${c.name}${c.detail ? ` — ${c.detail}` : ''}`);
}
console.log(`\n${checks.length - failed.length}/${checks.length} checks passed`);
process.exit(failed.length ? 1 : 0);
