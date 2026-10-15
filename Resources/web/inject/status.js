// Runs in angl's isolated content world in every frame. Reports the link under the pointer
// (status line) and the link a context menu opened on (for "Open in …" menu items).
(() => {
  if (window.__anglStatus) return;
  window.__anglStatus = true;
  const post = (type, href) => {
    try {
      window.webkit.messageHandlers.anglStatus.postMessage({ type, href });
    } catch (_) {}
  };
  const linkOf = (target) => {
    const a = target && target.closest ? target.closest("a[href]") : null;
    return a ? a.href : null;
  };
  let current = null;
  document.addEventListener("mouseover", (e) => {
    const href = linkOf(e.target);
    if (href !== current) {
      current = href;
      post("hover", href);
    }
  }, true);
  document.addEventListener("mouseout", (e) => {
    if (current && !linkOf(e.relatedTarget)) {
      current = null;
      post("hover", null);
    }
  }, true);
  document.addEventListener("contextmenu", (e) => post("context", linkOf(e.target)), true);
  // Playing media keeps a tab from being unloaded or archived. Each frame reports under its own id;
  // the app keeps one record per reporting frame and drops it when the frame goes away.
  const frame = Math.random().toString(36).slice(2);
  let playing = false;
  let reported = false;
  const sendMedia = (extra) => {
    try {
      window.webkit.messageHandlers.anglStatus.postMessage({ type: "media", frame, playing, ...extra });
    } catch (_) {}
  };
  const check = () => {
    const now = Array.from(document.querySelectorAll("audio, video")).some((m) => !m.paused && !m.ended);
    if (now === playing) return;
    playing = now;
    reported = true;
    sendMedia();
  };
  // emptied: load() or a new src resets a playing element without a pause event.
  ["play", "pause", "ended", "emptied"].forEach((event) => document.addEventListener(event, check, true));
  // Going away (or into the back/forward cache): drop the record. A cached page can come back with
  // its media already playing and no play event, so pageshow re-checks.
  addEventListener("pagehide", () => {
    if (!reported) return;
    playing = false;
    reported = false;
    sendMedia({ gone: true });
  });
  addEventListener("pageshow", check);
})();
