/* MTZ: no remote code, account credentials, cookies or private ChatGPT APIs. */
(function (root) {
  'use strict';

  const MAX_ZIP_BYTES = 30 * 1024 * 1024;
  const TOKEN_RE = /^[0-9a-f]{64}$/i;

  function validToken(value) {
    return typeof value === 'string' && TOKEN_RE.test(value);
  }

  function isConversationUrl(value) {
    try {
      const url = new URL(value);
      return url.origin === 'https://chatgpt.com' && !url.username && !url.password &&
        /^(?:\/c\/[A-Za-z0-9-]+|\/g\/[A-Za-z0-9_-]+\/c\/[A-Za-z0-9-]+)\/?$/.test(url.pathname);
    } catch (_) { return false; }
  }

  function validSender(sender, extensionId) {
    return Boolean(sender && sender.id === extensionId && sender.tab &&
      Number.isInteger(sender.tab.id) && sender.frameId === 0 &&
      isConversationUrl(sender.url || sender.tab.url));
  }

  function safeZipName(value) {
    return typeof value === 'string' && value.length <= 124 &&
      /^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$/i.test(value) && !value.includes('..');
  }

  function extractHandoffHash(hash) {
    if (typeof hash !== 'string') return null;
    const parts = hash.replace(/^#/, '').split('&');
    const markers = parts.filter(part => part.startsWith('mtz-logs='));
    if (markers.length !== 1) return null;
    const token = markers[0].slice('mtz-logs='.length);
    if (!validToken(token)) return null;
    const remaining = parts.filter(part => !part.startsWith('mtz-logs=')).join('&');
    return {token: token.toLowerCase(), remainingHash: remaining ? '#' + remaining : ''};
  }

  function hasZipSignature(bytes) {
    return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b &&
      ((bytes[2] === 3 && bytes[3] === 4) || (bytes[2] === 5 && bytes[3] === 6));
  }

  function encodeBase64(bytes) {
    let binary = '';
    for (let offset = 0; offset < bytes.length; offset += 32768) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
    }
    return btoa(binary);
  }

  function decodeBase64(value) {
    if (typeof value !== 'string' || value.length > Math.ceil(MAX_ZIP_BYTES / 3) * 4 ||
        value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
      throw new Error('Nieprawidłowy rozmiar lub format paczki.');
    }
    const binary = atob(value);
    if (binary.length > MAX_ZIP_BYTES) throw new Error('Paczka przekracza 30 MiB.');
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    if (!hasZipSignature(bytes)) throw new Error('Zbieracz nie przekazał pliku ZIP.');
    return bytes;
  }

  function acceptsZip(input) {
    const accept = (input.getAttribute('accept') || '').trim().toLowerCase();
    if (!accept) return true;
    return accept.split(',').map(value => value.trim()).some(value =>
      ['*', '*/*', '.zip', 'application/zip', 'application/x-zip-compressed',
        'application/octet-stream'].includes(value));
  }

  function selectUniqueFileInput(document) {
    const editors = [...document.querySelectorAll('#prompt-textarea')].filter(editor =>
      editor.isConnected && editor.getClientRects().length > 0);
    if (editors.length !== 1) return null;
    const form = editors[0].closest('form');
    if (!form) return null;
    const eligible = root => [...root.querySelectorAll('input[type="file"]')]
      .filter(input => !input.disabled && !input.matches(':disabled') &&
        input.isConnected && acceptsZip(input));
    const local = eligible(form);
    if (local.length === 1) return local[0];
    // Do not guess an unrelated global picker (for example an avatar upload
    // in an open settings panel). A changed ChatGPT layout uses manual fallback.
    return null;
  }

  const api = Object.freeze({MAX_ZIP_BYTES, validToken, isConversationUrl, validSender,
    safeZipName, extractHandoffHash, hasZipSignature, encodeBase64, decodeBase64,
    acceptsZip, selectUniqueFileInput});
  root.MtzLogBridge = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(globalThis);
