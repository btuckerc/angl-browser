// Page world, main frame. angl lacks Apple's browser passkey entitlement, so WebAuthn requests
// fail. Watch only publicKey create/get calls and tell angl when one fails, so it can offer to
// open the page in Safari. The page's own promise, result and error are passed through untouched.
(() => {
  const creds = navigator.credentials;
  if (!creds || creds.__angl) return;
  const wrap = (name) => {
    const original = creds[name] && creds[name].bind(creds);
    if (!original) return;
    creds[name] = function (options) {
      const p = original(options);
      if (options && options.publicKey && options.mediation !== "conditional") {
        p.catch((err) => {
          try {
            window.webkit.messageHandlers.anglPasskey.postMessage({ op: name, error: String(err && err.name) });
          } catch (_) {}
        });
      }
      return p;
    };
  };
  wrap("create");
  wrap("get");
  try {
    Object.defineProperty(creds, "__angl", { value: true });
  } catch (_) {}
})();
