// Page world, main frame. angl lacks Apple's browser passkey entitlement, so WebAuthn requests
// fail. Watch only publicKey create/get calls and tell angl when one fails, so it can offer to
// open the page in Safari. The page's own promise, result and error are passed through untouched.
// Patch the prototype, not navigator.credentials: WebKit can collect that wrapper object and hand
// the page a fresh one, dropping any properties set on it.
(() => {
  const proto = window.CredentialsContainer && CredentialsContainer.prototype;
  if (!proto || Object.prototype.hasOwnProperty.call(proto, "__angl")) return;
  const wrap = (name) => {
    const original = proto[name];
    if (typeof original !== "function") return;
    Object.defineProperty(proto, name, {
      configurable: true,
      writable: true,
      value: function (options) {
        const p = original.call(this, options);
        if (options && options.publicKey && options.mediation !== "conditional") {
          p.catch((err) => {
            try {
              window.webkit.messageHandlers.anglPasskey.postMessage({ op: name, error: String(err && err.name) });
            } catch (_) {}
          });
        }
        return p;
      },
    });
  };
  wrap("create");
  wrap("get");
  Object.defineProperty(proto, "__angl", { value: true });
})();
