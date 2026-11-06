'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const MTZ = require('../common.js');
const tests = [];
const test = (name, run) => tests.push({name, run});
const token = 'a1'.repeat(32);
const sender = {id: 'extension-id', tab: {id: 12}, frameId: 0,
  url: 'https://chatgpt.com/c/00000000-0000-4000-8000-000000000001'};
const sample = new Uint8Array([80, 75, 3, 4, 1, 2, 3, 4]);

function fakeInput(accept = '') {
  return {isConnected: true, disabled: false, matches: () => false,
    getAttribute: name => name === 'accept' ? accept : null};
}
function fakeDocument(local, global = local, editorCount = 1) {
  const form = {querySelectorAll: () => local};
  const editors = Array.from({length: editorCount}, () => ({isConnected: true,
    getClientRects: () => [{}], closest: () => form}));
  return {querySelectorAll: selector => selector === '#prompt-textarea' ? editors : global};
}
async function invokeWorker({message = {type: 'MTZ_FETCH_BUNDLE', token}, from = sender,
    response, fetchError, chunks, contentLength, name = 'MTZ-Logi-20261030-190000.zip',
    contentType = 'application/zip', status = 200} = {}) {
  let listener, calls = 0, fetchOptions, cancelled = false;
  const headers = new Headers({'Content-Type': contentType, 'X-MTZ-Filename': name});
  if (contentLength !== undefined) headers.set('Content-Length', contentLength);
  const streamChunks = chunks || [sample];
  let index = 0;
  const context = vm.createContext({
    URL, Uint8Array, AbortController, TypeError, Error, Promise, Number,
    setTimeout, clearTimeout, btoa, atob,
    chrome: {runtime: {id: 'extension-id', onMessage: {addListener: fn => { listener = fn; }}}},
    fetch: async (url, options) => {
      calls++; fetchOptions = {url, ...options};
      if (fetchError) throw fetchError;
      if (response) return response;
      return {status, ok: status >= 200 && status < 300, headers,
        body: {getReader: () => ({read: async () => index < streamChunks.length ?
          {done: false, value: streamChunks[index++]} : {done: true},
        cancel: async () => { cancelled = true; }})}};
    }
  });
  context.importScripts = filename => vm.runInContext(
    fs.readFileSync(path.join(__dirname, '..', filename), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'service-worker.js'), 'utf8'), context);
  const result = await new Promise(resolve => {
    const retained = listener(message, from, resolve);
    if (!retained && message.type !== 'MTZ_FETCH_BUNDLE') resolve(null);
  });
  return {result, calls, fetchOptions, cancelled};
}

test('manifest: only ChatGPT content script and loopback network permission', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'manifest.json')));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.host_permissions, ['http://127.0.0.1:17643/*']);
  assert.deepEqual(manifest.content_scripts[0].matches, ['https://chatgpt.com/*']);
  assert.equal(manifest.content_scripts[0].all_frames, false);
  assert.equal(manifest.permissions, undefined);
  assert.equal(manifest.externally_connectable, undefined);
});
test('tokens: exact 64 hexadecimal characters only', () => {
  assert.equal(MTZ.validToken(token), true);
  assert.equal(MTZ.validToken(token.toUpperCase()), true);
  for (const bad of [null, 42, '', token.slice(1), token + 'a', 'g'.repeat(64), token + '\n']) {
    assert.equal(MTZ.validToken(bad), false);
  }
});
test('conversation URLs: normal and custom GPT paths; reject other origins and credentials', () => {
  assert.equal(MTZ.isConversationUrl(sender.url), true);
  assert.equal(MTZ.isConversationUrl('https://chatgpt.com/g/g-abc_123/c/abc-123'), true);
  for (const bad of ['https://chatgpt.com/', 'http://chatgpt.com/c/abc',
    'https://chatgpt.com.evil.example/c/abc', 'https://user@chatgpt.com/c/abc',
    'https://chatgpt.com/c/a/b', 'https://chatgpt.com/c/a%2Fb', 'file:///c/abc']) {
    assert.equal(MTZ.isConversationUrl(bad), false, bad);
  }
});
test('sender: top-level own extension and real conversation required', () => {
  assert.equal(MTZ.validSender(sender, 'extension-id'), true);
  for (const bad of [null, {...sender, frameId: 1}, {...sender, id: 'other-id'},
    {...sender, tab: null}, {...sender, url: 'https://evil.example/c/abc'}]) {
    assert.equal(MTZ.validSender(bad, 'extension-id'), false);
  }
});
test('names: ASCII ZIP basename; no traversal, control characters or excessive length', () => {
  assert.equal(MTZ.safeZipName('MTZ-Logi-20261030-190000.zip'), true);
  for (const bad of ['../logs.zip', 'x..zip', 'C:\\logs.zip', '/logs.zip', '.zip',
    'logs.txt', 'logs.zip\r\nX-Hdr: bad', 'ą.zip', 'a'.repeat(121) + '.zip']) {
    assert.equal(MTZ.safeZipName(bad), false, bad);
  }
});
test('handoff hash: extract and remove only one valid marker, retain unrelated parts', () => {
  assert.deepEqual(MTZ.extractHandoffHash('#anchor&mtz-logs=' + token + '&other=x'),
    {token, remainingHash: '#anchor&other=x'});
  assert.deepEqual(MTZ.extractHandoffHash('#mtz-logs=' + token), {token, remainingHash: ''});
  for (const bad of ['', '#normal', '#mtz-logs=' + token.slice(1),
    '#mtz-logs=' + token + '&mtz-logs=' + token, '#mtz-logs=' + token + '%20']) {
    assert.equal(MTZ.extractHandoffHash(bad), null);
  }
});
test('base64: chunked encoding/decoding preserves binary ZIP bytes', () => {
  const bytes = new Uint8Array(100003);
  for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251;
  bytes.set(sample.subarray(0, 4));
  assert.deepEqual(MTZ.decodeBase64(MTZ.encodeBase64(bytes)), bytes);
});
test('base64: reject bad alphabet, invalid sizes and non-ZIP payloads', () => {
  for (const bad of [null, '%xyz', '====', 'AA', btoa('not a zip')]) {
    assert.throws(() => MTZ.decodeBase64(bad));
  }
  assert.throws(() => MTZ.decodeBase64('A'.repeat(Math.ceil(MTZ.MAX_ZIP_BYTES / 3) * 4 + 4)));
});
test('ZIP signature: file and empty-archive signatures accepted; other content rejected', () => {
  assert.equal(MTZ.hasZipSignature(sample), true);
  assert.equal(MTZ.hasZipSignature(new Uint8Array([80, 75, 5, 6])), true);
  assert.equal(MTZ.hasZipSignature(new Uint8Array([80, 75])), false);
  assert.equal(MTZ.hasZipSignature(new Uint8Array([80, 75, 7, 8])), false);
});
test('picker: choose unique ZIP input in visible composer, filter image picker', () => {
  const zip = fakeInput('.txt,.zip');
  const image = fakeInput('image/*');
  assert.equal(MTZ.selectUniqueFileInput(fakeDocument([image, zip])), zip);
});
test('picker: ambiguity fails closed, missing or duplicate composers fail closed', () => {
  const zip1 = fakeInput(), zip2 = fakeInput('.zip');
  assert.equal(MTZ.selectUniqueFileInput(fakeDocument([zip1, zip2])), null);
  assert.equal(MTZ.selectUniqueFileInput(fakeDocument([zip1], [zip1], 0)), null);
  assert.equal(MTZ.selectUniqueFileInput(fakeDocument([zip1], [zip1], 2)), null);
});
test('picker: unrelated global input never selected, even if it is the only picker', () => {
  const zip = fakeInput('application/zip');
  assert.equal(MTZ.selectUniqueFileInput(fakeDocument([], [zip])), null);
  assert.equal(MTZ.selectUniqueFileInput(fakeDocument([], [fakeInput()])), null);
  assert.equal(MTZ.selectUniqueFileInput(fakeDocument([], [fakeInput('image/*')])), null);
});
test('worker: loopback only, bearer token only, no cookies, no redirects, valid bytes returned', async () => {
  const {result, calls, fetchOptions} = await invokeWorker();
  assert.equal(calls, 1);
  assert.equal(result.ok, true);
  assert.deepEqual(MTZ.decodeBase64(result.data), sample);
  assert.equal(fetchOptions.url, 'http://127.0.0.1:17643/v1/bundle');
  assert.equal(fetchOptions.headers.Authorization, 'Bearer ' + token);
  assert.equal(fetchOptions.credentials, 'omit');
  assert.equal(fetchOptions.redirect, 'error');
  assert.equal(fetchOptions.cache, 'no-store');
});
test('worker: wrong sender and invalid token do not touch network', async () => {
  for (const options of [{from: {...sender, url: 'https://evil.example/c/abc'}},
    {message: {type: 'MTZ_FETCH_BUNDLE', token: 'invalid'}}]) {
    const actual = await invokeWorker(options);
    assert.equal(actual.calls, 0); assert.equal(actual.result.ok, false);
  }
});
test('worker: accepted uppercase token is normalized for the loopback protocol', async () => {
  const actual = await invokeWorker({message: {type: 'MTZ_FETCH_BUNDLE', token: token.toUpperCase()}});
  assert.equal(actual.result.ok, true);
  assert.equal(actual.fetchOptions.headers.Authorization, 'Bearer ' + token);
});
test('worker: expired/unauthorized handoff gives actionable failure', async () => {
  for (const status of [401, 403]) {
    const actual = await invokeWorker({status});
    assert.equal(actual.result.ok, false);
    assert.match(actual.result.error, /wygasło/);
  }
});
test('worker: reject invalid filename, wrong MIME type and invalid ZIP content', async () => {
  for (const options of [{name: '../bad.zip'}, {contentType: 'text/html'},
    {chunks: [new Uint8Array([1, 2, 3, 4])]}, {chunks: []}]) {
    const actual = await invokeWorker(options); assert.equal(actual.result.ok, false);
  }
});
test('worker: declared oversize rejected before reading', async () => {
  const actual = await invokeWorker({contentLength: String(MTZ.MAX_ZIP_BYTES + 1)});
  assert.equal(actual.result.ok, false); assert.match(actual.result.error, /30 MiB/);
});
test('worker: declared ZIP length must match the complete streamed response', async () => {
  for (const contentLength of ['0', '3', '9', '7', '', 'invalid']) {
    const actual = await invokeWorker({contentLength});
    assert.equal(actual.result.ok, false, 'Content-Length=' + contentLength);
  }
  const complete = await invokeWorker({contentLength: String(sample.length)});
  assert.equal(complete.result.ok, true);
});
test('worker: streamed oversize cancelled even without Content-Length', async () => {
  const actual = await invokeWorker({chunks: [new Uint8Array(MTZ.MAX_ZIP_BYTES), new Uint8Array(1)]});
  assert.equal(actual.result.ok, false); assert.equal(actual.cancelled, true);
});
test('worker: timeout and connection errors do not claim successful upload', async () => {
  const timeout = new Error('time'); timeout.name = 'AbortError';
  const actual = await invokeWorker({fetchError: timeout});
  assert.equal(actual.result.ok, false); assert.match(actual.result.error, /20 sekund/);
  const network = await invokeWorker({fetchError: new TypeError('fetch failed')});
  assert.equal(network.result.ok, false); assert.match(network.result.error, /połączyć/);
});
test('content script: never clicks native Send and never changes message text', () => {
  const content = fs.readFileSync(path.join(__dirname, '..', 'content.js'), 'utf8');
  assert.equal(/\.click\(/.test(content), false);
  assert.equal(/requestSubmit|submit\(|send-button|sendButton/.test(content), false);
  assert.equal(/document\.cookie|localStorage|sessionStorage|fetch\(/.test(content), false);
});

(async () => {
  let passed = 0;
  for (const {name, run} of tests) {
    try { await run(); passed++; console.log('PASS ' + name); }
    catch (error) { console.error('FAIL ' + name); console.error(error); process.exitCode = 1; }
  }
  console.log(`${passed}/${tests.length} tests passed`);
})();
