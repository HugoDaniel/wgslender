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

const URL_ = process.env.PLAYGROUND_URL ?? 'http://localhost:4324/';
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

  check('the editor mounts', await until(`!!document.querySelector('[data-editor] .cm-editor')`));
  check('the no-JS fallback is replaced', await evaluate(`!document.querySelector('.fallback')`));

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

  // ---- the output panels -------------------------------------------------

  check(
    'three tabs are rendered',
    (await evaluate(`[...document.querySelectorAll('[role=tab]')].map(t => t.textContent.trim())`))
      .join()
      .includes('Minified,Reflection,Diagnostics'),
  );

  // Presence is not visibility. Styling the panels for a fixed-height pane
  // once overrode the `display: none` behind their `hidden` attribute, and
  // all three rendered at once — invisible to any check that only queries by
  // selector, and obvious the moment you look at the page.
  const visiblePanels = () =>
    evaluate(`
      [...document.querySelectorAll('[role=tabpanel]')]
        .filter(p => p.offsetParent !== null && p.getBoundingClientRect().height > 0)
        .length
    `);
  check('exactly one panel is visible at a time', (await visiblePanels()) === 1, `visible=${await visiblePanels()}`);

  // The minified pane is its own editor, so read its document, not the DOM.
  const minifiedText = () =>
    evaluate(`document.querySelector('[data-minify-output] .cm-content')?.textContent ?? ''`);
  check('the minified panel fills in', await until(`
    (document.querySelector('[data-minify-output] .cm-content')?.textContent ?? '').includes('fs_main')
  `));
  check(
    'tree shaking dropped the dead helper',
    !(await minifiedText()).includes('unused_helper'),
  );

  const statLabels = await evaluate(
    `[...document.querySelectorAll('[data-minify-stats] .stat-label')].map(e => e.textContent)`,
  );
  check('the stats bar has a gzip column', statLabels.join() === 'Original,Minified,Saved,Gzip', statLabels.join());

  const statValue = (label) => evaluate(`
    [...document.querySelectorAll('[data-minify-stats] .stat')]
      .find(s => s.querySelector('.stat-label').textContent === ${JSON.stringify(label)})
      ?.querySelector('.stat-value').textContent
  `);
  const savedBefore = await statValue('Saved');
  const gzipBefore = await statValue('Gzip');

  // Toggling a pill has to move the numbers *and* the code.
  const togglePill = async (key) => {
    await evaluate(`document.querySelector('[data-option=${key}]').click()`);
    await sleep(600);
  };
  await togglePill('treeShaking');
  check(
    // The helper survives under a renamed identifier, so match its body —
    // `includes('return')` would be true of almost any shader.
    'turning tree shaking off brings the helper back',
    /return (\w+)\*\1\*\1;/.test(await minifiedText()),
    await statValue('Saved'),
  );
  check('the saved percentage moved', (await statValue('Saved')) !== savedBefore);
  await togglePill('treeShaking');

  await togglePill('sortDeclarations');
  await togglePill('scopeLocalRename');
  check(
    'the gzip number tracks the compression pills',
    (await statValue('Gzip')) !== gzipBefore,
    `${gzipBefore} -> ${await statValue('Gzip')}`,
  );
  await togglePill('sortDeclarations');
  await togglePill('scopeLocalRename');

  // Reflection: the §6.2.10 padding is the panel's reason to exist.
  await evaluate(`document.querySelectorAll('[role=tab]')[1].click()`);
  await sleep(300);
  check(
    'switching tabs shows the reflection panel',
    await evaluate(`document.querySelector('[data-reflect]').getBoundingClientRect().height > 0`),
  );
  const reflectText = await evaluate(`document.querySelector('[data-reflect]').textContent`);
  check('the reflection panel lists the bindings', reflectText.includes('noise_tex'));
  check(
    'the reflection panel shows the vec3 padding',
    /time\s*f32\s*76/.test(reflectText.replace(/\s+/g, ' ')),
  );

  // `textContent` sees rows that render at zero height, which is exactly how
  // a collapsed flex child hides an entire table. Measure instead.
  const laidOutRows = await evaluate(`
    [...document.querySelectorAll('[data-reflect] tbody tr')]
      .filter(row => row.getBoundingClientRect().height > 0)
      .length
  `);
  check('the reflection tables are actually laid out', laidOutRows >= 10, `rows=${laidOutRows}`);

  // Diagnostics: rows, and a click that moves the cursor.
  await evaluate(`document.querySelectorAll('[role=tab]')[2].click()`);
  await sleep(300);
  const rows = await evaluate(`document.querySelectorAll('[data-diagnostics] .diagnostic').length`);
  check('the diagnostics panel lists a row', rows === 1, `rows=${rows}`);
  check(
    'the row names the lint code',
    (await evaluate(`document.querySelector('[data-diagnostics] .diagnostic').textContent`)).includes(
      'W0001',
    ),
  );

  // basicSetup highlights the cursor's line, so the active line is a
  // DOM-visible proxy for the selection — no reaching into CodeMirror's
  // internals from a page that loaded it through Vite.
  await evaluate(`document.querySelector('[data-diagnostics] .diagnostic').click()`);
  await sleep(300);
  const activeLine = await evaluate(
    `document.querySelector('[data-editor] .cm-activeLine')?.textContent ?? ''`,
  );
  check('clicking a diagnostic moves the cursor to it', activeLine.includes('unused_helper'), activeLine);

  // Back to the first tab: the minified editor was laid out while hidden, so
  // this is what the re-measure hook is for.
  await evaluate(`document.querySelectorAll('[role=tab]')[0].click()`);
  await sleep(400);
  const minifiedBox = await evaluate(`(() => {
    const r = document.querySelector('[data-minify-output] .cm-content').getBoundingClientRect();
    return { w: Math.round(r.width), h: Math.round(r.height) };
  })()`);
  check(
    'the minified editor survives a tab round trip',
    minifiedBox.h > 0 && minifiedBox.w > 0,
    `${minifiedBox.w}x${minifiedBox.h}`,
  );

  // ---- minify insights ---------------------------------------------------

  const hintCount = () => evaluate(`document.querySelectorAll('.cm-minify-hint').length`);
  const hasMinifyLint = `[...document.querySelectorAll('[data-diagnostics] .diagnostic')].some(d => d.textContent.includes('M0100'))`;

  // The diagnostic-click check above scrolled the editor to line 28, and
  // CodeMirror only renders lines near the viewport — so get back to the top
  // before asking about a widget that lives above line 1.
  await evaluate(`document.querySelector('[data-editor] .cm-scroller').scrollTop = 0`);
  await sleep(300);

  check(
    'the insights toggle is enabled once the server is up',
    await evaluate(`!document.querySelector('[data-insights]').disabled`),
  );
  check('no size hints before the toggle', (await hintCount()) === 0);

  await evaluate(`document.querySelector('[data-insights]').click()`);
  // Not a fixed count: CodeMirror only renders the lines near the viewport, so
  // how many of the eleven widgets exist in the DOM depends on scroll position
  // and window height. The full set is `tests/insights.test.mjs`'s business;
  // what a browser has to prove is that they reach the page at all.
  check(
    'toggling insights on brings in the size hints',
    await until(`document.querySelectorAll('.cm-minify-hint').length > 3`, 10000),
    `hints=${await hintCount()}`,
  );

  // Rendered, not merely present: a widget decoration that never reaches the
  // DOM still counts in the decoration set.
  const hintBox = await evaluate(`(() => {
    const el = document.querySelector('.cm-minify-hint:not(.cm-minify-total)');
    const r = el.getBoundingClientRect();
    return { w: Math.round(r.width), h: Math.round(r.height), text: el.textContent, title: el.title };
  })()`);
  check(
    'the hints are laid out and labelled',
    hintBox.w > 0 && hintBox.h > 0 && /^-\d/.test(hintBox.text),
    `${hintBox.w}x${hintBox.h} "${hintBox.text}"`,
  );
  check(
    'each hint discloses that it is an estimate',
    hintBox.title.startsWith('approximate'),
    hintBox.title,
  );

  // The module total is a block widget above line 1. Rendered inline it would
  // sit in front of the first character of the file's opening comment.
  const total = await evaluate(`(() => {
    const el = document.querySelector('.cm-minify-total');
    if (!el) return null;
    const line = document.querySelector('[data-editor] .cm-line');
    return {
      text: el.textContent,
      above: el.getBoundingClientRect().bottom <= line.getBoundingClientRect().top + 1,
      firstLine: line.textContent.slice(0, 24),
    };
  })()`);
  check(
    'the module total sits on its own line above the shader',
    total?.above && /^whole file-\d+ B$/.test(total.text) && total.firstLine.startsWith('//'),
    `${JSON.stringify(total)}`,
  );

  // The same command republishes diagnostics, so the minify lints land in the
  // panel at the moment the hints land in the editor.
  check('the minify lints arrive with them', await until(hasMinifyLint, 10000));

  await evaluate(`document.querySelector('[data-insights]').click()`);
  check(
    'toggling insights off removes both',
    (await until(`document.querySelectorAll('.cm-minify-hint').length === 0`, 10000)) &&
      (await until(`!${hasMinifyLint}`, 10000)),
  );

  // ---- rename and format -------------------------------------------------

  // `languageServerExtensions()` binds F2 and Shift-Alt-f. Both are wired to
  // the real server, so both are worth proving in a browser.
  const key = (params) =>
    send('Input.dispatchKeyEvent', { type: 'rawKeyDown', ...params }).then(() =>
      send('Input.dispatchKeyEvent', { type: 'keyUp', ...params }),
    );

  // Click the middle of the `Camera` token on its `struct` line — the same
  // gesture a visitor makes. A DOM range gives the coordinates.
  const spot = await evaluate(`(() => {
    const line = [...document.querySelectorAll('[data-editor] .cm-line')]
      .find(l => l.textContent.startsWith('struct Camera'));
    if (!line) return null;
    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const at = n.data.indexOf('Camera');
      if (at < 0) continue;
      const range = document.createRange();
      range.setStart(n, at + 2);
      range.setEnd(n, at + 3);
      const r = range.getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    }
    return null;
  })()`);
  for (const type of ['mousePressed', 'mouseReleased']) {
    await send('Input.dispatchMouseEvent', { type, ...spot, button: 'left', clickCount: 1 });
  }

  await key({ key: 'F2', code: 'F2', windowsVirtualKeyCode: 113, nativeVirtualKeyCode: 113 });
  await sleep(300);
  check('F2 opens the rename prompt', await evaluate(`!!document.querySelector('.cm-panel input')`));

  await send('Input.insertText', { text: 'Lens' });
  await key({ key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
  await sleep(500);
  const renamed = await evaluate(`document.querySelector('[data-editor] .cm-content').textContent`);
  check(
    'rename rewrites the declaration and its use',
    renamed.includes('struct Lens') && renamed.includes(': Lens;') && !renamed.includes('Camera'),
    renamed.match(/struct \w+ \{/)?.[0] ?? '',
  );

  // Shift-Alt-f runs the server's formatter, which is the whole minifier with
  // whitespace and identifier renaming switched off — so it also strips every
  // comment and tree-shakes dead code. Asserted here because it is surprising,
  // not because it is desirable.
  await evaluate(`document.querySelector('[data-editor] .cm-content').focus()`);
  await key({
    // Lowercase `key`: CodeMirror's keymap matches the unshifted name, so a
    // synthetic event reporting `F` never resolves to the binding.
    key: 'f', code: 'KeyF', windowsVirtualKeyCode: 70, nativeVirtualKeyCode: 70,
    modifiers: 9, // Shift (8) + Alt (1)
  });
  await sleep(600);
  const formatted = await evaluate(`document.querySelector('[data-editor] .cm-content').textContent`);
  check(
    'Shift-Alt-f formats the document',
    formatted.includes('view_proj: mat4x4<f32>'),
    formatted.slice(0, 40),
  );
  check(
    'and, as the formatter does, drops comments and dead code',
    !formatted.includes('//') && !formatted.includes('unused_helper'),
  );

  // The round trip: keystroke -> didChange -> wasm -> publishDiagnostics.
  await evaluate(`document.querySelector('[data-editor] .cm-content').focus()`);
  await send('Input.insertText', { text: 'fn oops(\n' });
  check(
    'typing produces new diagnostics',
    await until(`document.querySelectorAll('.cm-lintRange-error').length > 0`, 10000),
  );
  check(
    'the diagnostics panel picks up the new errors',
    await until(`document.querySelectorAll('[data-diagnostics] .diagnostic.error').length > 0`, 10000),
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
