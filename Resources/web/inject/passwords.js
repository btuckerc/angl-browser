// angl passwords: sign-in field detector (isolated world "angl.passwords", every frame).
// Reports fields to native; native shows the login picker and calls __anglPasswordsFill.
(() => {
  const post = (m) => window.webkit?.messageHandlers?.anglPasswords?.postMessage({ ...m, origin: location.origin, document: doc });
  if (location.protocol !== 'https:') return;
  const doc = `${Date.now().toString(36)}${Math.random().toString(36).slice(2)}`;
  const byToken = new Map();   // token → WeakRef<input>
  const tokens = new WeakMap(); // input → token
  const announced = new WeakSet();
  // `armed`: the picker has a row selected, so ↩ picks it; otherwise ↩ is the page's.
  let next = 0, shown = false, armed = false, current = null, filling = false;
  // The element that had focus when the window lost it (a picker search, another app): its
  // focus coming back isn't the user arriving at the field.
  let refocus = null;

  const token = (el) => {
    let t = tokens.get(el);
    if (!t) { t = String(++next); tokens.set(el, t); byToken.set(t, new WeakRef(el)); }
    return t;
  };
  const visible = (el) => {
    if (!el.isConnected || el.disabled || el.readOnly) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0.05;
  };
  const USER = /user|login|email|e-mail|account|identifier|username|signin/i;
  const isPassword = (el) => el instanceof HTMLInputElement && el.type === 'password' && !/new-password/.test(el.autocomplete);
  const isUser = (el) => {
    if (!(el instanceof HTMLInputElement)) return false;
    const type = (el.type || 'text').toLowerCase();
    if (!['text', 'email', 'tel', ''].includes(type)) return false;
    const ac = (el.autocomplete || '').toLowerCase();
    if (/username|email/.test(ac) && !/new-password/.test(ac)) return true;
    return type === 'email' || USER.test(`${el.name} ${el.id} ${el.getAttribute('aria-label') || ''} ${el.placeholder || ''}`);
  };
  const scope = (el) => el.form || el.closest('form, [role="form"], dialog, main') || document;
  const inputs = (root) => [...root.querySelectorAll('input')].filter(visible);
  // First visible input matching `test`; cheap field checks run before visible()'s layout/style reads.
  const firstVisible = (root, test) => [...root.querySelectorAll('input')].find((el) => test(el) && visible(el));
  const passwordIn = (root) => firstVisible(root, isPassword);
  // The username field that belongs with `pass`: the last plausible text input before it.
  const userFor = (pass) => {
    const all = inputs(scope(pass));
    const before = all.slice(0, all.indexOf(pass)).filter((el) => el.type !== 'password' && el.type !== 'hidden' && el.type !== 'checkbox');
    return before.reverse().find(isUser) || before[0] || null;
  };
  const loginField = (el) => isPassword(el) || (isUser(el) && (!!passwordIn(scope(el)) || /username|email|webauthn/.test(el.autocomplete || '')));

  // One-time code fields (an authenticator app's code): autocomplete="one-time-code", a field
  // named or labelled for a code, one-digit boxes for a code, or a short numeric field in a form
  // that asks for one ("Enter the code from your authenticator app"). Codes sent by text or
  // email aren't ours.
  const words = (s) => s.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().replace(/[^a-z0-9]+/g, ' ');
  // Names for the code itself; words about two-step sign-in only without account words
  // (`authentication[username]` is a username).
  const CODE = /\bt?otp|otp\b|\b(code|pin|otc|passcode)\b/;
  const ABOUT = /2fa|mfa|two ?factor|two ?step|2 ?step|one ?time|authenticat|verif/;
  const ACCOUNT = /\b(user ?name|user|login|email|e mail|account|identifier|password)\b/;
  const NOT_CODE = /\b(zip|postal|post code|promo|coupon|discount|gift|voucher|referral|invite|invitation|card|cvc|cvv|csc|captcha|country|area|phone|tracking|search|reference|sms|email|e mail)\b/;
  const ASKS = /authenticator|verification code|one-time|one time|two-factor|two factor|2fa|two-step|2-step|security code|\d-digit|enter (the |your )?code/i;
  const codeType = (el) => el instanceof HTMLInputElement && ['text', 'tel', 'number', ''].includes((el.type || 'text').toLowerCase());
  const hinted = (el) => /(^|\s)one-time-code(\s|$)/i.test(el.getAttribute('autocomplete') || '');
  const numeric = (el) => el.inputMode === 'numeric' || el.type === 'tel' || el.type === 'number' || /\\d|0-9/.test(el.pattern);
  const describe = (el) => {
    const labels = el.labels ? [...el.labels].map((l) => l.textContent).join(' ') : '';
    const by = (el.getAttribute('aria-labelledby') || '').split(/\s+/).map((id) => (id && document.getElementById(id)?.textContent) || '').join(' ');
    return words(`${el.name} ${el.id} ${el.getAttribute('aria-label') || ''} ${el.placeholder || ''} ${el.title || ''} ${labels} ${by}`);
  };
  const named = (d) => CODE.test(d) || (ABOUT.test(d) && !ACCOUNT.test(d));
  // The form (or dialog, section…) around `el`, and whether it asks for a code.
  const askRoot = (el) => el.form || el.closest('[role="dialog"], dialog, main, section, article') || el.parentElement?.parentElement?.parentElement;
  const asks = (el) => ASKS.test((askRoot(el)?.textContent || '').slice(0, 4000));
  // The one-digit boxes `el` is one of, in order, among the 4–8 in its nearest ancestor (up to
  // four up): all of them when one is marked one-time-code (some sites mark only the first);
  // else those that are numeric or named for a code, when there are 4 or more; else unmarked
  // boxes that are the only text entry in a form asking for a code.
  const boxes = (el) => {
    if (el.maxLength !== 1 || !codeType(el)) return null;
    let all = null;
    for (let node = el.parentElement, up = 0; node && up < 4 && !all; node = node.parentElement, up++) {
      const found = [...node.querySelectorAll('input')].filter((i) => codeType(i) && i.maxLength === 1 && visible(i));
      if (found.length >= 4) all = found;
    }
    if (!all || all.length > 8 || !all.includes(el)) return null;
    const names = all.map(describe);
    if (names.some((d) => NOT_CODE.test(d))) return null;
    if (all.some(hinted)) return all;
    const digits = all.filter((b, i) => numeric(b) || named(names[i]));
    if (digits.length) return digits.length >= 4 && digits.includes(el) ? digits : null;
    const root = askRoot(el);
    return root && asks(el) && inputs(root).every((i) => !codeType(i) || all.includes(i)) ? all : null;
  };
  const isCode = (el) => {
    if (!codeType(el)) return false;
    if (hinted(el)) return true;
    if (/username|email|tel|postal|cc-|address|name|new-password|current-password/.test((el.getAttribute('autocomplete') || '').toLowerCase())) return false;
    if (el.maxLength === 1) return !!boxes(el);
    const d = describe(el);
    if (NOT_CODE.test(d)) return false;
    if (named(d)) return true;
    if (isUser(el)) return false;
    return ((el.maxLength >= 4 && el.maxLength <= 10) || numeric(el)) && asks(el);
  };
  // What the picker offers for a field: logins for a sign-in field, codes for a code field.
  const kindOf = (el) => (isPassword(el) ? 'password' : isCode(el) ? 'code' : loginField(el) ? 'user' : null);

  // Rect relative to the top viewport when every ancestor frame is same-origin.
  const rectOf = (el) => {
    const r = el.getBoundingClientRect();
    let x = r.x, y = r.y, exact = true;
    try {
      for (let w = window; w !== w.top; w = w.parent) {
        const fe = w.frameElement;
        if (!fe) { exact = false; break; }
        const fr = fe.getBoundingClientRect();
        x += fr.x + fe.clientLeft; y += fr.y + fe.clientTop;
      }
    } catch { exact = false; }
    return { rect: { x, y, width: r.width, height: r.height }, exact };
  };
  // A username field's text narrows the picker; a password field's text is never sent, but the
  // username shown with it is (a password step ranks that account first). A code field sends neither.
  let currentKind = null;
  const report = (el, how, kind) => {
    current = el;
    currentKind = kind;
    announced.add(el);
    post({
      type: 'field', field: token(el), ...rectOf(el), focused: how === 'focus', explicit: how === 'explicit', kind,
      query: kind === 'user' ? el.value : '', username: kind === 'password' ? (userFor(el)?.value || '') : '',
      webauthn: /(^|\s)webauthn(\s|$)/i.test(el.getAttribute('autocomplete') || ''), hinted: kind === 'code' && hinted(el),
    });
  };

  // Page loads / SPA steps: offer logins for a sign-in field the page focused before this script
  // saw it (once per field). Unfocused fields wait for focus or ⌘\.
  const scan = () => {
    if (document.visibilityState !== 'visible') return;
    const el = document.activeElement;
    const kind = el && !el.value && !announced.has(el) ? kindOf(el) : null;
    if (kind && visible(el)) report(el, 'auto', kind);
  };
  let timer = 0;
  const soon = () => { clearTimeout(timer); timer = setTimeout(scan, 350); };
  document.addEventListener('DOMContentLoaded', soon);
  addEventListener('load', soon);
  addEventListener('pageshow', soon);
  document.addEventListener('visibilitychange', soon);
  // Hidden pages scan on reveal (visibilitychange), not on every mutation.
  new MutationObserver(() => { if (!shown && document.visibilityState === 'visible') soon(); }).observe(document, { childList: true, subtree: true });

  // Focus offers logins only for empty fields (not after a fill, not over the page's own autofill).
  addEventListener('blur', (e) => { if (e.target === window) refocus = document.activeElement; }, true);
  document.addEventListener('focusin', (e) => {
    const back = e.target === refocus;
    refocus = null;
    if (back || filling || e.target.value) return;
    const kind = kindOf(e.target);
    if (kind) report(e.target, 'focus', kind);
  }, true);

  // While the picker is up: ↑ ↓ esc drive it and ↩ picks the selected row; typing in its
  // username field narrows it; scrolling, clicking away, Tab or typing anywhere else closes it.
  const dismiss = (remember) => { if (shown) { shown = false; armed = false; post({ type: 'dismiss', remember }); } };
  const narrows = (e) => e.composedPath()[0] === current && current && currentKind === 'user';
  document.addEventListener('keydown', (e) => {
    if (!shown || !e.isTrusted || e.isComposing) return;
    if (e.key === 'Enter' && !armed) { dismiss(false); return; }
    if (['ArrowDown', 'ArrowUp', 'Enter', 'Escape'].includes(e.key)) {
      e.preventDefault(); e.stopImmediatePropagation();
      post({ type: 'key', key: e.key });
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') armed = true;
      if (e.key === 'Escape') { shown = false; armed = false; }
    } else if (e.key === 'Tab' || ((e.key.length === 1 || e.key === 'Backspace' || e.key === 'Delete') && !narrows(e))) {
      dismiss(false);
    } else if (e.key.length === 1 || e.key === 'Backspace' || e.key === 'Delete') {
      armed = false;
    }
  }, true);
  document.addEventListener('input', (e) => {
    if (shown && !filling && e.isTrusted && narrows(e)) { armed = false; post({ type: 'query', field: token(current), query: current.value }); }
  }, true);
  document.addEventListener('pointerdown', (e) => { if (e.target !== current) dismiss(false); }, true);
  addEventListener('scroll', () => dismiss(false), true);
  addEventListener('resize', () => dismiss(false));
  addEventListener('pagehide', () => dismiss(false));

  // Native → page.
  Object.defineProperty(window, '__anglPasswordsShown', { value: (on, isArmed) => { shown = !!on; armed = shown && !!isArmed; } });
  Object.defineProperty(window, '__anglPasswordsFind', {
    value: () => {
      const active = document.activeElement;
      const kind = active && kindOf(active);
      if (kind) { report(active, 'explicit', kind); return true; }
      // A password field means a sign-in form; otherwise a code field before a lone username one.
      const pass = passwordIn(document);
      const el = pass ? userFor(pass) || pass : firstVisible(document, isCode) || firstVisible(document, isUser);
      if (!el) return false;
      report(el, 'explicit', kindOf(el) || 'user');
      return true;
    },
  });
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  const set = (input, value) => {
    if (!input || !value) return false;
    input.focus();
    setter.call(input, value);
    input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: value }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };
  // → {username, password}: which of the two it wrote; false = the field is gone.
  Object.defineProperty(window, '__anglPasswordsFill', {
    value: (field, documentToken, origin, username, password) => {
      if (documentToken !== doc || origin !== location.origin) return false;
      const el = byToken.get(field)?.deref();
      if (!el || !visible(el) || (!isPassword(el) && !isUser(el))) return false;
      // The paired field is optional (identifier-first sign-ins have no password field yet);
      // a hidden or retyped one is skipped, not filled.
      const usable = (input, test) => (input && visible(input) && test(input) ? input : null);
      const passwordTarget = isPassword(el);
      const pass = passwordTarget ? el : usable(passwordIn(scope(el)), isPassword);
      const user = passwordTarget ? usable(userFor(el), isUser) : el;
      filling = true;
      try {
        const filled = { username: set(user, username), password: set(pass, password) };
        (pass && pass.value ? pass : user)?.focus();
        return filled;
      } finally { filling = false; }
    },
  });
  // A one-time code, one digit per box for split fields; false = the field is gone, its boxes
  // don't fit the code, or the field is too short for it.
  Object.defineProperty(window, '__anglPasswordsFillCode', {
    value: (field, documentToken, origin, code) => {
      if (documentToken !== doc || origin !== location.origin) return false;
      const el = byToken.get(field)?.deref();
      if (!el || !visible(el) || !isCode(el)) return false;
      const split = boxes(el);
      if (split ? split.length !== code.length : el.maxLength > 0 && el.maxLength < code.length) return false;
      const into = split ? split.map((box, i) => [box, code[i]]) : [[el, code]];
      filling = true;
      try {
        for (const [input, digit] of into) set(input, digit);
        into[into.length - 1][0].focus();
        return true;
      } finally { filling = false; }
    },
  });
})();
