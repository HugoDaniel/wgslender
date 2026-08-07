#!/usr/bin/env node
// A browser check for the *web* extension host — vscode.dev, github.dev.
//
// `npm test` runs the desktop host under @vscode/test-electron, which loads
// dist/extension.js and never touches dist/server.js. This covers the other
// half: the Worker bundle, driven exactly as the browser host drives it —
// constructed from a URL, fed already-parsed JSON-RPC objects over
// postMessage (what BrowserMessageReader/Writer do), resolving its own WASM
// relative to its script location.
//
// Everything here is a real browser: a real Worker, a real fetch of a real
// .wasm, real WebAssembly.compileStreaming. That is deliberate. The failures
// this guards against — a bundle that throws on load, a wasmURL that 404s, an
// advertised command list that drifted — all look fine from Node. The desktop
// bundle shipped broken for exactly that reason: esbuild emptied
// `import.meta.url` in a cjs build and the extension threw before `activate`.
//
// Usage: `npm run test:web-host`, after `npm run build` and
// `zig build vscode-assets` have populated dist/. Requires Google Chrome;
// override with CHROME_PATH.

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DIST = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const CDP_PORT = Number(process.env.CDP_PORT ?? 9334);
const CHROME =
  process.env.CHROME_PATH ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The ids the server advertises. Spelled out rather than imported, because
// the point is to catch a change to them — including one made in Zig and
// carried here inside a rebuilt .wasm.
const EXPECTED_COMMANDS = [
  'wgslender.server.setMinifyMode',
  'wgslender.server.toggleMinifyMode',
  'wgslender.server.recomputeMinifyInsights',
  'wgslender.server.showMinifiedOutput',
];

for (const required of ['server.js', 'wgslender-lsp.wasm']) {
  const path = join(DIST, required);
  const present = await stat(path).then(
    () => true,
    () => false,
  );
  if (!present) {
    console.error(
      `missing dist/${required} — run \`zig build vscode-assets\` from the repo root and \`npm run build\` here first`,
    );
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// A static server over dist/, plus the harness page.
//
// The page is served rather than written into dist/ so a failed run leaves no
// artefact behind, and it has to be same-origin with server.js for the Worker
// to be constructible at all.
// ---------------------------------------------------------------------------

const HARNESS = `<!doctype html>
<meta charset="utf-8" />
<title>web extension host probe</title>
<script>
  window.__result = { errors: [] };
  const done = (patch) => Object.assign(window.__result, patch);

  const worker = new Worker('./server.js');
  worker.addEventListener('error', (e) => {
    window.__result.errors.push('worker: ' + (e.message || 'error'));
    window.__done = true;
  });

  const pending = new Map();
  let nextId = 0;
  const diagnosticCodes = [];

  worker.addEventListener('message', (e) => {
    const msg = e.data;
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (msg.method === 'textDocument/publishDiagnostics') {
      for (const d of msg.params.diagnostics) diagnosticCodes.push(d.code);
    }
  });

  const request = (method, params) =>
    new Promise((resolve) => {
      const id = ++nextId;
      pending.set(id, resolve);
      worker.postMessage({ jsonrpc: '2.0', id, method, params });
    });
  const notify = (method, params) => worker.postMessage({ jsonrpc: '2.0', method, params });

  // A URI in the scheme github.dev actually uses, so nothing here depends on
  // the server accepting file:// paths.
  const uri = 'vscode-vfs://github/owner/repo/shader.wgsl';
  const text = 'fn f(x: f32) -> f32 { return sin(x); }\\nfn dead(y: f32) -> f32 { return y; }\\n';

  (async () => {
    try {
      const init = await request('initialize', {
        processId: null,
        rootUri: null,
        capabilities: {},
      });
      done({ commands: init.result.capabilities.executeCommandProvider.commands });
      notify('initialized', {});
      notify('textDocument/didOpen', {
        textDocument: { uri, languageId: 'wgsl', version: 1, text },
      });
      done({ diagnosticCodes });

      // Hover the \`sin\` call: its type constraint is the one that used to
      // lose its brackets to the markdown renderer.
      const hover = await request('textDocument/hover', {
        textDocument: { uri },
        position: { line: 0, character: text.indexOf('sin(') },
      });
      const value = hover.result?.contents?.value ?? hover.result?.contents ?? '';
      done({ hover: String(value) });

      // Go-to navigation through the worker pump: from the \`y\` usage in
      // \`return y\` back to the parameter. Declaration must agree with
      // definition — WGSL has no forward declarations.
      const navPos = { line: 1, character: text.split('\\n')[1].indexOf('y; }') };
      const definition = await request('textDocument/definition', {
        textDocument: { uri },
        position: navPos,
      });
      const declaration = await request('textDocument/declaration', {
        textDocument: { uri },
        position: navPos,
      });
      done({
        definition: definition.result ?? null,
        declarationMatchesDefinition:
          definition.result != null &&
          JSON.stringify(declaration.result) === JSON.stringify(definition.result),
      });

      const shown = await request('workspace/executeCommand', {
        command: 'wgslender.server.showMinifiedOutput',
        arguments: [uri],
      });
      done({ minified: shown.error ? null : shown.result });

      // The pre-namespace id must be gone, not quietly still working.
      const stale = await request('workspace/executeCommand', {
        command: 'wgslender.showMinifiedOutput',
        arguments: [uri],
      });
      done({ staleRejected: Boolean(stale.error), staleMessage: stale.error?.message ?? '' });
    } catch (err) {
      window.__result.errors.push(String(err && err.message ? err.message : err));
    } finally {
      window.__done = true;
    }
  })();
</script>
`;

const CONTENT_TYPE = {
  '.js': 'text/javascript',
  '.wasm': 'application/wasm',
  '.html': 'text/html',
  '.json': 'application/json',
};

const server = createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  if (path === '/' || path === '/index.html') {
    res.writeHead(200, { 'content-type': 'text/html' }).end(HARNESS);
    return;
  }
  try {
    // Serve dist/ only — `join` collapses any `..` before the prefix check.
    const file = join(DIST, path);
    if (!file.startsWith(DIST)) throw new Error('outside dist');
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': CONTENT_TYPE[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;

// ---------------------------------------------------------------------------
// Headless Chrome over CDP. Same shape as web/scripts/smoke.mjs.
// ---------------------------------------------------------------------------

const profile = await mkdtemp(join(tmpdir(), 'wgslender-webhost-'));
const chrome = spawn(
  CHROME,
  [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    `--remote-debugging-port=${CDP_PORT}`,
    `--user-data-dir=${profile}`,
    'about:blank',
  ],
  { stdio: 'ignore' },
);

let ws;
async function cleanup() {
  ws?.close();
  server.close();
  const exited = new Promise((res) => chrome.once('exit', res));
  chrome.kill();
  await Promise.race([exited, sleep(5000)]);
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(() => {});
}

async function pageTarget() {
  for (let i = 0; i < 80; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`)).json();
      const page = list.find((t) => t.type === 'page');
      if (page) return page;
    } catch {
      /* Chrome is still starting up. */
    }
    await sleep(250);
  }
  throw new Error(`Chrome never exposed a page target on port ${CDP_PORT}`);
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
const requested = [];
ws.addEventListener('message', (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  }
  // A Worker is its own CDP target: its fetches are invisible on the page's
  // session, so we attach to it and enable Network there. Without this the
  // WASM request — the one thing that proves the worker resolved its own URL
  // rather than being handed a module — never appears.
  if (msg.method === 'Target.attachedToTarget') {
    send('Network.enable', {}, msg.params.sessionId);
  }
  if (msg.method === 'Network.requestWillBeSent') requested.push(msg.params.request.url);
  if (msg.method === 'Runtime.exceptionThrown') {
    const d = msg.params.exceptionDetails;
    problems.push(`uncaught: ${d.exception?.description ?? d.text}`);
  }
  if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
    problems.push(`console.error: ${msg.params.args.map((a) => a.value ?? a.description).join(' ')}`);
  }
});

function send(method, params = {}, sessionId) {
  const id = ++nextId;
  return new Promise((res) => {
    pending.set(id, res);
    ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
  });
}

async function evaluate(expression) {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  const details = r.result?.exceptionDetails;
  if (details) throw new Error(details.exception?.description ?? details.text);
  return r.result.result.value;
}

const checks = [];
const check = (name, ok, detail = '') => checks.push({ name, ok: Boolean(ok), detail: String(detail) });

try {
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Network.enable');
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
  await send('Page.navigate', { url: origin });

  let result = null;
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await evaluate('window.__done === true')) {
      result = await evaluate('window.__result');
      break;
    }
    await sleep(200);
  }

  if (result === null) {
    check('the worker answers within 30s', false, 'timed out');
  } else {
    check('the worker boots and answers initialize', Array.isArray(result.commands), JSON.stringify(result.commands));
    check(
      'it advertises the namespaced command ids',
      JSON.stringify(result.commands) === JSON.stringify(EXPECTED_COMMANDS),
      JSON.stringify(result.commands),
    );
    check(
      'it fetched its own wasm, relative to the worker script',
      requested.some((u) => u.endsWith('/wgslender-lsp.wasm')),
      requested.filter((u) => u.includes('wasm')).join(' ') || '(none requested)',
    );
    check(
      'didOpen pushes diagnostics through the worker pump',
      (result.diagnosticCodes ?? []).length > 0,
      (result.diagnosticCodes ?? []).join(','),
    );
    check('hover opens with a wgsl fence', (result.hover ?? '').startsWith('```wgsl'), (result.hover ?? '').slice(0, 40));
    check('hover keeps its type parameters', (result.hover ?? '').includes('vecN<f32>'));
    check(
      'go-to-definition answers over the worker',
      result.definition &&
        result.definition.range.start.line === 1 &&
        result.definition.range.start.character === 8,
      JSON.stringify(result.definition),
    );
    check('go-to-declaration answers like definition', result.declarationMatchesDefinition);
    check(
      'showMinifiedOutput answers over the worker',
      result.minified && result.minified.byte_count > 0,
      result.minified ? `${result.minified.byte_count} B` : 'no result',
    );
    check('the pre-namespace command id is rejected', result.staleRejected, result.staleMessage);
    check('the worker reported no errors', (result.errors ?? []).length === 0, (result.errors ?? []).join('; '));
  }

  check('no page errors', problems.length === 0, problems.join('; '));
} finally {
  await cleanup();
}

for (const c of checks) {
  console.log(`${c.ok ? 'ok  ' : 'FAIL'} ${c.name}${c.detail ? ` — ${c.detail}` : ''}`);
}
const failed = checks.filter((c) => !c.ok);
console.log(`\n${checks.length - failed.length}/${checks.length} checks passed`);
process.exit(failed.length === 0 ? 0 : 1);
