// Instant full screen, angl's world, main frame: the gate between fullscreen.js (page world) and
// the app. Entering needs a real user gesture (navigator.userActivation, which the page can't
// fake) and spends it: one entry per trusted click or key press, so a page can't come straight
// back after Esc on the same gesture. The app takes Esc itself, before the page sees it.
(() => {
  if (window.__anglFullscreenGate || window.top !== window) return;
  let active = false, grant = false;
  // Esc isn't a gesture (as for user activation). Pointer events cover mouse, pen and touch once
  // per press (mousedown would grant the same click twice). Window capture: this listener runs
  // before any the page adds, and isTrusted can't be forged.
  const input = (e) => { if (e.isTrusted && e.key !== 'Escape') grant = true; };
  for (const type of ['pointerdown', 'keydown']) addEventListener(type, input, true);
  const post = (on) => window.webkit.messageHandlers.anglFullscreen.postMessage({ on });
  document.addEventListener('angl-fullscreen', async (e) => {
    const [want, id] = String(e.detail).split(':');
    const answer = (ok) => document.dispatchEvent(new CustomEvent('angl-fullscreen-done', { detail: `${ok ? 'ok' : 'denied'}:${id}` }));
    const enter = want === 'enter';
    // Every request spends the grant, leaving too: the next entry needs a new press.
    const granted = grant && navigator.userActivation?.isActive !== false;
    grant = false;
    if (enter && !granted) return answer(false);
    try {
      const ok = (await post(enter)) === true;
      active = enter && ok;
      answer(ok);
    } catch (_) { active = false; answer(!enter); }
  });
  // The app ended it (Esc, tab switch, window full screen, the window closing).
  const end = () => {
    if (!active) return;
    active = false;
    grant = false;
    document.dispatchEvent(new Event('angl-fullscreen-end'));
  };
  window.__anglFullscreenGate = { end };
})();
