(function () {
  'use strict';
  const MTZ = globalThis.MtzLogBridge;
  let generation = 0;
  let current = null;
  let panel, messageNode, retryButton, closeButton;

  async function ensurePanel() {
    if (!document.body) await new Promise(resolve =>
      document.addEventListener('DOMContentLoaded', resolve, {once: true}));
    if (panel && panel.isConnected) return;
    panel = document.createElement('section');
    panel.id = 'mtz-log-handoff-panel';
    panel.setAttribute('aria-label', 'Przekazanie logów Minecrafta MTZ');
    panel.style.cssText = 'position:fixed;left:50%;bottom:18px;transform:translateX(-50%);' +
      'z-index:2147483647;box-sizing:border-box;width:min(580px,calc(100vw - 32px));' +
      'padding:16px;border:1px solid #71717a;border-radius:12px;background:#18181b;' +
      'color:#fafafa;box-shadow:0 8px 32px #0008;font:14px/1.45 system-ui,sans-serif;';
    const title = document.createElement('strong');
    title.textContent = 'Logi Minecrafta — MTZ';
    messageNode = document.createElement('p');
    messageNode.style.margin = '8px 0 12px';
    messageNode.setAttribute('role', 'status');
    messageNode.setAttribute('aria-live', 'polite');
    retryButton = document.createElement('button');
    retryButton.type = 'button';
    retryButton.textContent = 'Ponów dołączenie';
    retryButton.style.cssText = 'border:0;border-radius:7px;background:#2563eb;color:white;' +
      'padding:8px 12px;margin-right:8px;font:inherit;cursor:pointer;';
    retryButton.addEventListener('click', () => { if (current) attach(current); });
    closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.textContent = 'Zamknij';
    closeButton.style.cssText = 'border:1px solid #71717a;border-radius:7px;background:transparent;' +
      'color:inherit;padding:8px 12px;font:inherit;cursor:pointer;';
    closeButton.addEventListener('click', () => {
      generation++;
      current = null;
      panel.remove();
    });
    panel.append(title, messageNode, retryButton, closeButton);
    document.body.appendChild(panel);
  }

  function status(text, busy, success) {
    messageNode.textContent = text;
    retryButton.disabled = Boolean(busy);
    retryButton.style.opacity = busy ? '0.6' : '1';
    retryButton.hidden = Boolean(success);
  }

  function fetchBundle(token) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage({type: 'MTZ_FETCH_BUNDLE', token}, response => {
        if (chrome.runtime.lastError) {
          reject(new Error('Rozszerzenie zostało przeładowane albo połączenie wygasło. Odśwież rozmowę i ponów przekazanie ze zbieracza.'));
          return;
        }
        if (!response || !response.ok) {
          reject(new Error(response && response.error || 'Nie udało się odebrać paczki.'));
          return;
        }
        resolve(response);
      });
    });
  }

  async function waitForPicker(state) {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      if (state.generation !== generation || location.pathname !== state.path) {
        throw new Error('Rozmowa zmieniła się. Wróć do wskazanej rozmowy i ponów przekazanie ze zbieracza.');
      }
      const input = MTZ.selectUniqueFileInput(document);
      if (input) return input;
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    throw new Error('Nie znalazłem jednoznacznego pola załącznika. Interfejs ChatGPT mógł się zmienić. Przeciągnij ZIP ręcznie z folderu otwartego przez zbieracz.');
  }

  async function attach(state) {
    if (state.busy || state.finished || state.generation !== generation) return;
    state.busy = true;
    await ensurePanel();
    if (state.generation !== generation) return;
    status('Odbieram gotową paczkę ze zbieracza na Twoim komputerze…', true, false);
    try {
      if (!state.file) {
        const result = await fetchBundle(state.token);
        if (state.generation !== generation) return;
        if (!MTZ.safeZipName(result.filename)) throw new Error('Nieprawidłowa nazwa paczki.');
        const bytes = MTZ.decodeBase64(result.data);
        state.file = new File([bytes], result.filename, {type: 'application/zip'});
        state.token = null;
      }
      status('Czekam na formularz tej rozmowy…', true, false);
      const input = await waitForPicker(state);
      if (state.generation !== generation || location.pathname !== state.path) return;
      if (input.files && input.files.length) {
        throw new Error('Formularz ma już wybrane pliki. Dokończ ich dodawanie, a potem kliknij „Ponów dołączenie”.');
      }
      const transfer = new DataTransfer();
      transfer.items.add(state.file);
      input.files = transfer.files;
      if (!input.files || input.files.length !== 1 || input.files[0].name !== state.file.name) {
        throw new Error('Przeglądarka nie pozwoliła dołączyć pliku. Przeciągnij ZIP ręcznie z folderu otwartego przez zbieracz.');
      }
      input.dispatchEvent(new Event('input', {bubbles: true}));
      input.dispatchEvent(new Event('change', {bubbles: true}));
      state.finished = true;
      const name = state.file.name;
      state.file = null;
      status('Przekazano „' + name + '” do formularza. Zaczekaj na zakończenie dodawania pliku, sprawdź załącznik i kliknij zwykłe „Wyślij” w ChatGPT. Jeśli załącznik się nie pojawi, przeciągnij ZIP ręcznie. Samo przekazanie do formularza nie potwierdza wysłania.', false, true);
    } catch (error) {
      if (state.generation === generation) {
        status(error && error.message || 'Nie udało się dołączyć paczki. Użyj ręcznego przeciągnięcia ZIP-a.', false, false);
      }
    } finally { state.busy = false; }
  }

  function activateFromHash() {
    const parsed = MTZ.extractHandoffHash(location.hash);
    if (!parsed || !MTZ.isConversationUrl(location.href)) return;
    history.replaceState(history.state, '', location.pathname + location.search + parsed.remainingHash);
    const state = {generation: ++generation, token: parsed.token, path: location.pathname,
      file: null, busy: false, finished: false};
    current = state;
    attach(state);
  }

  addEventListener('hashchange', activateFromHash);
  addEventListener('popstate', activateFromHash);
  activateFromHash();
})();
