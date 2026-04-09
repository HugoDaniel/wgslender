// Basic tests for wgslender-lsp npm package.

'use strict';

const { initialize, isInitialized, sendMessage, createTransport } = require('./index.js');

let passed = 0;
let failed = 0;

function assert(condition, msg) {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error('  FAIL:', msg);
  }
}

async function run() {
  console.log('wgslender-lsp tests\n');

  // ---- Initialization ----
  assert(!isInitialized(), 'not initialized before init');
  await initialize();
  assert(isInitialized(), 'initialized after init');

  // ---- Initialize request ----
  console.log('  initialize...');
  const initResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'initialize', params: { capabilities: {} }
  }));
  assert(initResponses.length === 1, 'initialize returns one response');
  const initResult = JSON.parse(initResponses[0]);
  assert(initResult.id === 1, 'response id matches');
  assert(initResult.result.serverInfo.name === 'wgslender-lsp', 'server name');
  assert(initResult.result.capabilities.textDocumentSync.openClose === true, 'openClose capability');

  // ---- didOpen with valid shader ----
  console.log('  didOpen (valid shader)...');
  sendMessage(JSON.stringify({
    jsonrpc: '2.0', method: 'initialized', params: {}
  }));
  const openResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', method: 'textDocument/didOpen',
    params: {
      textDocument: {
        uri: 'file:///test.wgsl', languageId: 'wgsl', version: 1,
        text: '@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.0); }'
      }
    }
  }));
  assert(openResponses.length === 1, 'didOpen produces one notification');
  const diag1 = JSON.parse(openResponses[0]);
  assert(diag1.method === 'textDocument/publishDiagnostics', 'publishDiagnostics method');
  assert(diag1.params.uri === 'file:///test.wgsl', 'correct uri');
  assert(diag1.params.diagnostics.length === 0, 'no diagnostics for valid shader');

  // ---- didChange with invalid shader ----
  console.log('  didChange (invalid shader)...');
  const changeResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', method: 'textDocument/didChange',
    params: {
      textDocument: { uri: 'file:///test.wgsl', version: 2 },
      contentChanges: [{ text: 'fn main() { let x: f32 = true; }' }]
    }
  }));
  assert(changeResponses.length === 1, 'didChange produces one notification');
  const diag2 = JSON.parse(changeResponses[0]);
  assert(diag2.params.diagnostics.length > 0, 'diagnostics for invalid shader');
  assert(diag2.params.diagnostics[0].severity === 1, 'severity is error');
  assert(diag2.params.diagnostics[0].source === 'wgslender', 'source is wgslender');
  assert(diag2.params.diagnostics[0].message.includes('bool'), 'error mentions bool');

  // ---- didClose ----
  console.log('  didClose...');
  const closeResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', method: 'textDocument/didClose',
    params: { textDocument: { uri: 'file:///test.wgsl' } }
  }));
  assert(closeResponses.length === 1, 'didClose produces one notification');
  const diag3 = JSON.parse(closeResponses[0]);
  assert(diag3.params.diagnostics.length === 0, 'empty diagnostics on close');

  // ---- createTransport ----
  console.log('  createTransport...');
  const transport = createTransport();
  assert(typeof transport.send === 'function', 'transport.send is a function');
  assert(typeof transport.subscribe === 'function', 'transport.subscribe is a function');
  assert(typeof transport.unsubscribe === 'function', 'transport.unsubscribe is a function');

  let received = [];
  transport.subscribe(msg => received.push(msg));
  transport.send(JSON.stringify({
    jsonrpc: '2.0', id: 99, method: 'shutdown', params: null
  }));
  assert(received.length === 1, 'transport delivers response via subscribe');
  const shutdownResult = JSON.parse(received[0]);
  assert(shutdownResult.id === 99, 'shutdown response id');
  assert(shutdownResult.result === null, 'shutdown result is null');

  // ---- Summary ----
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

run().catch(err => {
  console.error(err);
  process.exit(1);
});
