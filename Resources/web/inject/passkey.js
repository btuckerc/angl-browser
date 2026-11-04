// Page world, main frame. WebAuthn publicKey requests go to angl, which serves them from the
// Bitwarden vault (Passkeys.swift): the user picks and verifies there, and Bitwarden's SDK signs
// for the frame's real origin. Conditional (autofill-UI) requests, and any angl hands back, go to
// WebKit unchanged. Patch the prototype, not navigator.credentials: WebKit can collect that
// wrapper object and hand the page a fresh one, dropping any properties set on it.
(() => {
  const proto = window.CredentialsContainer && CredentialsContainer.prototype;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.anglPasskey;
  if (!proto || !handler || Object.prototype.hasOwnProperty.call(proto, "__angl")) return;

  const b64 = (source) => {
    const u = ArrayBuffer.isView(source) ? new Uint8Array(source.buffer, source.byteOffset, source.byteLength) : new Uint8Array(source);
    let s = "";
    for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const bytes = (s) => {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
    const u = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    return u.buffer;
  };
  // Drops undefined members, so angl sees only what the page set.
  const plain = (o) => JSON.parse(JSON.stringify(o));
  const descriptors = (list) => Array.from(list || [], (d) => ({ type: d.type, id: b64(d.id), transports: d.transports }));
  // credProps is the one extension the SDK reports; others would be silently unmet.
  const extensions = (e) => (e && e.credProps ? { credProps: true } : undefined);

  const createRequest = (pk) => plain({
    publicKey: {
      rp: { id: pk.rp.id, name: pk.rp.name },
      user: { id: b64(pk.user.id), name: pk.user.name, displayName: pk.user.displayName },
      challenge: b64(pk.challenge),
      pubKeyCredParams: Array.from(pk.pubKeyCredParams || [], (p) => ({ type: p.type, alg: p.alg })),
      timeout: pk.timeout,
      excludeCredentials: descriptors(pk.excludeCredentials),
      authenticatorSelection: pk.authenticatorSelection,
      attestation: pk.attestation,
      extensions: extensions(pk.extensions),
    },
  });
  const getRequest = (pk) => plain({
    publicKey: {
      rpId: pk.rpId,
      challenge: b64(pk.challenge),
      timeout: pk.timeout,
      allowCredentials: descriptors(pk.allowCredentials),
      userVerification: pk.userVerification,
      extensions: extensions(pk.extensions),
    },
  });

  // A PublicKeyCredential-shaped object: own members shadow the prototype's native getters, and
  // the prototypes keep instanceof checks working.
  const credential = (c, create) => {
    const r = c.response;
    const response = create
      ? {
          clientDataJSON: bytes(r.clientDataJSON),
          attestationObject: bytes(r.attestationObject),
          getAuthenticatorData: () => bytes(r.authenticatorData),
          getPublicKey: () => (r.publicKey ? bytes(r.publicKey) : null),
          getPublicKeyAlgorithm: () => r.publicKeyAlgorithm,
          getTransports: () => (r.transports || []).slice(),
        }
      : {
          clientDataJSON: bytes(r.clientDataJSON),
          authenticatorData: bytes(r.authenticatorData),
          signature: bytes(r.signature),
          userHandle: r.userHandle ? bytes(r.userHandle) : null,
        };
    const responseType = create ? window.AuthenticatorAttestationResponse : window.AuthenticatorAssertionResponse;
    if (responseType) Object.setPrototypeOf(response, responseType.prototype);
    const extensionResults = c.clientExtensionResults || {};
    const out = {
      id: c.id,
      rawId: bytes(c.rawId),
      type: c.type,
      authenticatorAttachment: c.authenticatorAttachment || null,
      response,
      getClientExtensionResults: () => plain(extensionResults),
      toJSON: () => ({
        id: c.id,
        rawId: c.rawId,
        type: c.type,
        authenticatorAttachment: c.authenticatorAttachment || undefined,
        clientExtensionResults: plain(extensionResults),
        response: plain(r),
      }),
    };
    if (window.PublicKeyCredential) Object.setPrototypeOf(out, PublicKeyCredential.prototype);
    return out;
  };

  const aborted = (signal) => signal.reason !== undefined ? signal.reason : new DOMException("The operation was aborted.", "AbortError");

  const wrap = (name) => {
    const original = proto[name];
    if (typeof original !== "function") return;
    Object.defineProperty(proto, name, {
      configurable: true,
      writable: true,
      value: function (options) {
        const pk = options && options.publicKey;
        if (!pk || options.mediation === "conditional") return original.call(this, options);
        let request;
        try {
          request = name === "create" ? createRequest(pk) : getRequest(pk);
        } catch (_) {
          // Malformed options: WebKit raises the error the spec asks for.
          return original.call(this, options);
        }
        const signal = options.signal;
        if (signal && signal.aborted) return Promise.reject(aborted(signal));
        const answer = handler.postMessage({ op: name, request }).then((reply) => {
          if (!reply || reply.kind === "webkit") return original.call(this, options);
          if (reply.kind !== "credential") throw new DOMException(reply.message || "The operation either timed out or was not allowed.", reply.name || "NotAllowedError");
          return credential(reply.credential, name === "create");
        });
        if (!signal) return answer;
        return new Promise((resolve, reject) => {
          signal.addEventListener("abort", () => reject(aborted(signal)), { once: true });
          answer.then(resolve, reject);
        });
      },
    });
  };
  wrap("create");
  wrap("get");
  Object.defineProperty(proto, "__angl", { value: true });

  // Sites offer passkeys only when a platform authenticator answers yes; with Bitwarden on, angl is one.
  const PKC = window.PublicKeyCredential;
  const available = PKC && PKC.isUserVerifyingPlatformAuthenticatorAvailable;
  if (typeof available === "function") {
    Object.defineProperty(PKC, "isUserVerifyingPlatformAuthenticatorAvailable", {
      configurable: true,
      writable: true,
      value: function () {
        return handler.postMessage({ op: "available" })
          .then((reply) => (reply && reply.available === true) || available.call(PKC))
          .catch(() => available.call(PKC));
      },
    });
  }
})();
