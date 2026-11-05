// Instant full screen, page world, main frame. The page's Fullscreen API puts the element in the
// top layer (a manual popover) inside the tab instead of WebKit's full-screen window, so nothing
// waits on a Space animation; angl then fills the screen or window with the tab. fullscreen-gate.js
// (angl's world) checks user activation and asks the app; this side only renders and reports.
(() => {
  if (window.__anglFullscreen || window.top !== window) return;
  const E = Element.prototype, D = Document.prototype;
  const own = (o, k) => Object.getOwnPropertyDescriptor(o, k);
  const native = {
    request: E.requestFullscreen, webkitRequest: E.webkitRequestFullscreen, webkitRequestOld: E.webkitRequestFullScreen,
    exit: D.exitFullscreen, webkitExit: D.webkitExitFullscreen, webkitCancel: D.webkitCancelFullScreen,
    element: own(D, 'fullscreenElement')?.get, webkitElement: own(D, 'webkitFullscreenElement')?.get,
    webkitCurrent: own(D, 'webkitCurrentFullScreenElement')?.get,
    full: own(D, 'fullscreen')?.get, webkitIsFull: own(D, 'webkitIsFullScreen')?.get,
  };
  if (!native.request && !native.webkitRequest) return;
  const ATTR = 'data-angl-fullscreen';
  let current = null, popover = false;
  // Watches for the element leaving the document's own tree (removed, or moved into a shadow
  // tree the observer can't see), only while something is full screen.
  const inDocument = (el) => el.isConnected && el.getRootNode() === document;
  const watcher = new MutationObserver(() => { if (current && !inDocument(current)) leave(true); });

  // The UA :fullscreen sheet, as author rules; :where keeps the page's own rules ahead of ours.
  const css = `
[${ATTR}] { position: fixed !important; inset: 0 !important; box-sizing: border-box !important;
  min-width: 0 !important; max-width: none !important; min-height: 0 !important; max-height: none !important;
  width: 100% !important; height: 100% !important; transform: none !important; margin: 0 !important;
  z-index: 2147483647 !important; }
video[${ATTR}], img[${ATTR}], canvas[${ATTR}] { object-fit: contain !important; }
:where([${ATTR}][popover]) { border: 0; padding: 0; overflow: visible; color: inherit; background-color: black; }
[${ATTR}]::backdrop { background: black !important; }`;
  let sheet = null;
  const putSheet = () => {
    if (sheet?.isConnected) return;
    sheet = document.createElement('style');
    sheet.textContent = css;
    (document.head || document.documentElement).appendChild(sheet);
  };

  const fire = (el) => {
    for (const type of ['fullscreenchange', 'webkitfullscreenchange']) {
      const target = el.isConnected ? el : document;
      target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
    }
  };
  // fullscreen-gate.js answers each request with angl-fullscreen-done ("ok:<id>" or "denied:<id>").
  // The page can see and forge these events; whatever it forges, the paths below end by telling
  // the app to leave whenever this side isn't full screen, so the window can't stay behind.
  let seq = 0;
  const ask = (want) => new Promise((resolve) => {
    const id = String(++seq);
    const done = (e) => {
      const [answer, of] = String(e.detail).split(':');
      if (of !== id) return;
      document.removeEventListener('angl-fullscreen-done', done);
      resolve(answer === 'ok');
    };
    document.addEventListener('angl-fullscreen-done', done);
    document.dispatchEvent(new CustomEvent('angl-fullscreen', { detail: `${want}:${id}` }));
  });

  // Top layer via a manual popover; false when the element won't show (the caller rolls back).
  const style = (el) => {
    putSheet();
    el.setAttribute(ATTR, '');
    try { el.setAttribute('popover', 'manual'); el.showPopover(); popover = true; if (el.matches(':popover-open')) return true; el.hidePopover(); } catch (_) {}
    el.removeAttribute('popover'); el.removeAttribute(ATTR); popover = false; return false;
  };
  const unstyle = (el) => {
    if (popover) { try { el.hidePopover(); } catch (_) {} el.removeAttribute('popover'); }
    popover = false;
    el.removeAttribute(ATTR);
  };

  // What the popover stand-in can't replace keeps WebKit's own full screen: elements in shadow
  // trees (the document's sheet and observer don't reach them), ones that are already popovers or
  // dialogs, and non-HTML elements.
  const instant = (el) => el instanceof HTMLElement && !(el instanceof HTMLDialogElement) && !el.hasAttribute('popover')
    && typeof el.showPopover === 'function' && el.getRootNode() === document;
  const nativeRequest = (el, options) => {
    if (native.request) return native.request.call(el, options);
    (native.webkitRequest || native.webkitRequestOld).call(el);
    return Promise.resolve();
  };
  const disconnected = () => new TypeError('Element is not connected');
  let pending = false;
  const enter = async (el, options) => {
    if (!(el instanceof Element) || !el.isConnected) throw disconnected();
    if (current === el) return;
    if (!instant(el)) {
      if (current) await leave(true);
      return nativeRequest(el, options);
    }
    // One entry at a time: a second request while the app answers the first is refused.
    if (pending) throw new TypeError('Full screen request already pending');
    if (!current) {
      pending = true;
      const ok = await ask('enter').finally(() => { pending = false; });
      if (!ok) { await ask('exit'); throw new TypeError('Full screen request denied'); }
    }
    const previous = current;
    if (previous) unstyle(previous);
    // While the app answered, the page may have removed or moved it (into a shadow tree), or it
    // may refuse the top layer; its popover events run page code that can move it too.
    if (!el.isConnected || !instant(el) || !style(el) || !inDocument(el)) {
      unstyle(el);
      current = null;
      watcher.disconnect();
      await ask('exit');
      if (previous) fire(previous);
      throw el.isConnected ? new TypeError('Full screen request failed') : disconnected();
    }
    current = el;
    watcher.observe(document, { childList: true, subtree: true });
    if (previous) fire(previous);
    fire(el);
  };
  const leave = async (notify) => {
    const el = current;
    if (!el) return;
    current = null;
    watcher.disconnect();
    unstyle(el);
    if (notify) await ask('exit');
    fire(el);
  };

  const request = function (options) {
    return enter(this, options).catch((e) => {
      document.dispatchEvent(new Event('fullscreenerror', { bubbles: true }));
      throw e;
    });
  };
  const exit = function () {
    if (current) return leave(true);
    if (native.exit) return native.exit.call(this);
    native.webkitExit?.call(this);
    return Promise.resolve();
  };
  const legacyRequest = function () { request.call(this).catch(() => {}); };
  const legacyExit = function () { exit.call(this).catch(() => {}); };

  const define = (o, k, value) => { if (k in o) Object.defineProperty(o, k, { value, configurable: true, writable: true }); };
  define(E, 'requestFullscreen', request);
  define(E, 'webkitRequestFullscreen', legacyRequest);
  define(E, 'webkitRequestFullScreen', legacyRequest);
  define(D, 'exitFullscreen', exit);
  define(D, 'webkitExitFullscreen', legacyExit);
  define(D, 'webkitCancelFullScreen', legacyExit);
  const getter = (k, fallback, map = (v) => v) => {
    if (!own(D, k)) return;
    Object.defineProperty(D, k, { configurable: true, enumerable: true, get() { return current && this === document ? map(current) : fallback?.call(this) ?? map(null); } });
  };
  getter('fullscreenElement', native.element);
  getter('webkitFullscreenElement', native.webkitElement);
  getter('webkitCurrentFullScreenElement', native.webkitCurrent);
  getter('fullscreen', native.full, (el) => !!el);
  getter('webkitIsFullScreen', native.webkitIsFull, (el) => !!el);

  // The app ends it (Esc, tab switch, navigation, window full screen) through fullscreen-gate.js.
  document.addEventListener('angl-fullscreen-end', () => { leave(true); });
  window.__anglFullscreen = true;
})();
