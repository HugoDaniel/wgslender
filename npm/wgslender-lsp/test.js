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

  // ---- go-to navigation over the wire ----
  console.log('  definition / declaration / typeDefinition...');
  assert(initResult.result.capabilities.definitionProvider === true, 'definitionProvider advertised');
  assert(initResult.result.capabilities.declarationProvider === true, 'declarationProvider advertised');
  assert(initResult.result.capabilities.typeDefinitionProvider === true, 'typeDefinitionProvider advertised');

  // One line so positions are simple: struct at 7, var 'u' at 46, usage of 'u' at 76.
  const navText = 'struct S { v: vec4f } @group(0) @binding(0) var<uniform> u: S; fn f() -> S { return u; }';
  sendMessage(JSON.stringify({
    jsonrpc: '2.0', method: 'textDocument/didOpen',
    params: {
      textDocument: { uri: 'file:///nav.wgsl', languageId: 'wgsl', version: 1, text: navText }
    }
  }));

  const defResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', id: 10, method: 'textDocument/definition',
    params: {
      textDocument: { uri: 'file:///nav.wgsl' },
      position: { line: 0, character: navText.lastIndexOf('u;') }
    }
  }));
  assert(defResponses.length === 1, 'definition returns one response');
  const defResult = JSON.parse(defResponses[0]).result;
  assert(defResult !== null, 'definition resolves the var usage');
  assert(defResult.range.start.character === navText.indexOf('u:'), 'definition points at the var declaration');

  const declResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', id: 11, method: 'textDocument/declaration',
    params: {
      textDocument: { uri: 'file:///nav.wgsl' },
      position: { line: 0, character: navText.lastIndexOf('u;') }
    }
  }));
  assert(declResponses.length === 1, 'declaration returns one response');
  const declResult = JSON.parse(declResponses[0]).result;
  assert(declResult !== null, 'declaration resolves the var usage');
  assert(JSON.stringify(declResult) === JSON.stringify(defResult), 'declaration answers exactly like definition');

  const typeDefResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', id: 12, method: 'textDocument/typeDefinition',
    params: {
      textDocument: { uri: 'file:///nav.wgsl' },
      position: { line: 0, character: navText.lastIndexOf('u;') }
    }
  }));
  const typeDefResult = JSON.parse(typeDefResponses[0]).result;
  assert(typeDefResult !== null, 'typeDefinition resolves the var usage');
  assert(typeDefResult.range.start.character === navText.indexOf('S {'), 'typeDefinition points at the struct');

  // ---- workspace/symbol ----
  console.log('  workspace/symbol...');
  assert(initResult.result.capabilities.workspaceSymbolProvider === true, 'workspaceSymbolProvider advertised');

  const wsResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', id: 13, method: 'workspace/symbol',
    params: { query: 'f' }
  }));
  const wsResult = JSON.parse(wsResponses[0]).result;
  assert(Array.isArray(wsResult), 'workspace/symbol returns an array');
  assert(wsResult.length === 1, 'query "f" matches exactly the function');
  assert(wsResult[0].name === 'f', 'symbol name is f');
  assert(wsResult[0].kind === 12, 'symbol kind is Function');
  assert(wsResult[0].location.uri === 'file:///nav.wgsl', 'symbol location uri');

  const wsAllResponses = sendMessage(JSON.stringify({
    jsonrpc: '2.0', id: 14, method: 'workspace/symbol',
    params: { query: '' }
  }));
  const wsAll = JSON.parse(wsAllResponses[0]).result;
  // nav.wgsl: S, v (field of S), u, f — test.wgsl: main
  assert(wsAll.length === 5, `empty query returns every open document's symbols (got ${wsAll.length})`);
  const field = wsAll.find(s => s.name === 'v');
  assert(field && field.containerName === 'S', 'field carries its container name');

  sendMessage(JSON.stringify({
    jsonrpc: '2.0', method: 'textDocument/didClose',
    params: { textDocument: { uri: 'file:///nav.wgsl' } }
  }));

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
