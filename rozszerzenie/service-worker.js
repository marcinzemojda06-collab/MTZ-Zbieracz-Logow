'use strict';
importScripts('common.js');

const MTZ = globalThis.MtzLogBridge;
const BUNDLE_URL = 'http://127.0.0.1:17643/v1/bundle';

async function readBundle(token) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(BUNDLE_URL, {
      method: 'GET',
      headers: {Authorization: 'Bearer ' + token.toLowerCase(), Accept: 'application/zip'},
      credentials: 'omit', cache: 'no-store', redirect: 'error', signal: controller.signal
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error('Przekazanie wygasło. Kliknij ponownie „Przekaż do ChatGPT” w zbieraczu.');
    }
    if (!response.ok) throw new Error('Zbieracz nie udostępnił gotowej paczki.');
    const filename = response.headers.get('X-MTZ-Filename');
    if (!MTZ.safeZipName(filename)) throw new Error('Nieprawidłowa nazwa paczki.');
    const mediaType = (response.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
    if (!['application/zip', 'application/x-zip-compressed'].includes(mediaType)) {
      throw new Error('Zbieracz nie przekazał paczki ZIP.');
    }
    const length = response.headers.get('Content-Length');
    const declaredLength = length === null ? null : Number(length);
    if (length !== null && (!/^\d+$/.test(length) || declaredLength < 4)) {
      throw new Error('Zbieracz podał nieprawidłowy rozmiar paczki. Przekaż ją ponownie.');
    }
    if (declaredLength !== null && declaredLength > MTZ.MAX_ZIP_BYTES) {
      throw new Error('Paczka przekracza limit 30 MiB.');
    }
    const chunks = [];
    let size = 0;
    if (response.body && response.body.getReader) {
      const reader = response.body.getReader();
      while (true) {
        const item = await reader.read();
        if (item.done) break;
        size += item.value.byteLength;
        if (size > MTZ.MAX_ZIP_BYTES) {
          await reader.cancel();
          throw new Error('Paczka przekracza limit 30 MiB.');
        }
        chunks.push(item.value);
      }
    } else {
      throw new Error('Przeglądarka nie obsługuje bezpiecznego odbioru paczki.');
    }
    if (declaredLength !== null && declaredLength !== size) {
      throw new Error('Rozmiar odebranej paczki nie zgadza się z zapowiedzianym. Przekaż ją ponownie ze zbieracza.');
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    if (!MTZ.hasZipSignature(bytes)) throw new Error('Odebrane dane nie są plikiem ZIP.');
    return {ok: true, filename, data: MTZ.encodeBase64(bytes)};
  } catch (error) {
    if (error && error.name === 'AbortError') {
      return {ok: false, error: 'Zbieracz nie odpowiedział w ciągu 20 sekund. Pozostaw jego okno otwarte i ponów.'};
    }
    if (error instanceof TypeError) {
      return {ok: false, error: 'Nie mogę połączyć się ze zbieraczem. Pozostaw go otwartego; sprawdź też zgodę przeglądarki na połączenie lokalne.'};
    }
    return {ok: false, error: error && error.message || 'Nie udało się odebrać paczki.'};
  } finally { clearTimeout(timeout); }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== 'MTZ_FETCH_BUNDLE') return false;
  if (!MTZ.validSender(sender, chrome.runtime.id) || !MTZ.validToken(message.token)) {
    sendResponse({ok: false, error: 'Nieprawidłowe żądanie przekazania paczki.'});
    return false;
  }
  readBundle(message.token).then(sendResponse, () =>
    sendResponse({ok: false, error: 'Nie udało się odebrać paczki.'}));
  return true;
});
