// Shared page bridge and standalone preview data
(() => {
  // Mirrors AnglCore's Settings() so standalone previews render every control.
  const defaults = {
    search: { engine: 'https://duckduckgo.com/?q=%s', keywords: { d: 'https://duckduckgo.com/?q=%s', g: 'https://www.google.com/search?q=%s', w: 'https://en.wikipedia.org/wiki/Special:Search?search=%s', yt: 'https://www.youtube.com/results?search_query=%s', gh: 'https://github.com/search?q=%s', k: 'https://kagi.com/search?q=%s' } },
    content: { javascript: true, blockRemoteFonts: false, blocker: true, square: true, dark: 'off', zoom: 1, nightAudio: false, blockAutoplay: true, youtubeFrames: true, fullscreen: 'screen', autoPictureInPicture: false, youtubeQuality: 'auto', hardening: 'off' },
    tabs: { unloadAfterMinutes: 0, autoArchive: false, archiveAfterHours: 24, restoreOnLaunch: true, routeByURL: true, favorites: false, splitView: false, closeWindowWithLastTab: true },
    downloads: { folder: '~/Downloads' },
    privacy: { cleanURLs: true, safariUserAgent: true, forgetOnQuit: false, keepSignedIn: ['google.com', 'youtube.com'] },
    blocking: { lists: [
      { id: 'adguard-base', name: 'AdGuard Base (Safari optimized)', url: 'https://filters.adtidy.org/extension/safari/filters/2_optimized.txt', enabled: true },
      { id: 'adguard-tracking', name: 'AdGuard Tracking Protection (Safari optimized)', url: 'https://filters.adtidy.org/extension/safari/filters/3_optimized.txt', enabled: true },
      { id: 'ubo-filters', name: 'uBlock filters', url: 'https://ublockorigin.github.io/uAssets/filters/filters.txt', enabled: false },
      { id: 'annoyances-cookies', name: 'AdGuard Cookie Notices (Safari optimized)', url: 'https://filters.adtidy.org/extension/safari/filters/18_optimized.txt', enabled: false }
    ], updateEveryDays: 7, advanced: true },
    engines: { rules: [] }, snapshots: { autoEveryMinutes: 10, keep: 20 }, developer: { inspector: false },
    passwords: { provider: 'bitwarden', server: 'bitwarden.com', applePasswords: true, suggestOnFocus: true, lockAfterMinutes: 15, copyTOTP: false, rememberUnlock: false },
    twitch: { emotes: true, bttv: true, ffz: true, seventv: true, animated: true }
  };
  const clone = (value) => JSON.parse(JSON.stringify(value));
  let settings = clone(defaults);
  const themeDefaults = {
    color: { accent: '#55c3e8' },
    window: { address: 'palette', newTab: 'field', caret: 'block', outline: 'none', outlineColor: 'accent', outlineCustomColor: '#55c3e8', outlineWidth: 0.5, outlineOpacity: 0.55, outlineInactiveOpacity: 0.15 },
    sidebar: { mode: 'pinned', spaces: 'top', peekWidth: 10, peekDelayMs: 120, hideDelayMs: 400 }
  };
  const theme = clone(themeDefaults);
  let workspaceData = {
    containers: [{ id: 'default', name: 'Default', color: '#55c3e8', proxy: null, clearOnQuit: false }],
    workspaces: [{ id: 'personal', name: 'Personal', color: '#55c3e8', containerID: 'default', rules: [{ kind: 'host', value: 'example.com' }] }],
    palette: ['#55c3e8', '#a6e25f', '#ffdf6b', '#ff8eaf', '#e85b92']
  };
  let mockAccount = { state: 'locked', email: 'you@example.com', server: 'bitwarden.com' };
  const mock = {
    'settings.get': () => ({ settings, defaults, capabilities: { noJIT: true }, files: { settings: '~/config/angl/settings.json', theme: '~/config/angl/theme.json', keys: '~/config/angl/keys.json', css: '~/config/angl/css' } }),
    'settings.set': ({ path, value }) => {
      const parts = path.split('.');
      let target = settings;
      parts.slice(0, -1).forEach((part) => { target = target[part]; });
      target[parts.at(-1)] = value;
      return { settings };
    },
    'settings.reset': ({ path }) => {
      const parts = path.split('.');
      let target = settings;
      let source = defaults;
      parts.slice(0, -1).forEach((part) => { target = target[part]; source = source[part]; });
      target[parts.at(-1)] = clone(source[parts.at(-1)]);
      return { settings };
    },
    'workspaces.get': () => workspaceData,
    'workspaces.set': (data) => { workspaceData = data; return workspaceData; },
    'sites.list': () => ({ items: [{ host: 'example.com', overrides: { javascript: true, dark: 'auto', zoom: 1, volumeDB: 0 } }] }),
    'sites.set': () => ({}),
    'sites.reset': () => ({}),
    'blocking.status': () => ({ lists: settings.blocking.lists, rules: 125000, updated: new Date().toISOString(), busy: false, error: null }),
    'blocking.update': () => ({ ...mock['blocking.status'](), busy: false }),
    'engines.list': () => ({ items: [{ id: 'safari', name: 'Safari', family: 'webkit', installed: true }, { id: 'chrome', name: 'Google Chrome', family: 'chromium', installed: true }, { id: 'firefox', name: 'Firefox', family: 'gecko', installed: false }] }),
    'keys.list': () => ({ items: [
      { command: 'tab.new', title: 'New Tab', chord: '⌘T' }, { command: 'tab.close', title: 'Close Tab', chord: '⌘W' },
      { command: 'app.settings', title: 'Settings…', chord: '⌘,' }, { command: 'find', title: 'Find', chord: '⌘F' },
      { command: 'dev.inspector', title: 'Web Inspector', chord: '⌥⌘I' }, { command: 'passwords.fill', title: 'Fill Password', chord: '⌘\\' }
    ] }),
    'theme.get': () => ({ theme, defaults: themeDefaults }),
    'passwords.login': () => { mockAccount = { state: 'unlocked', email: 'you@example.com', server: settings.passwords.server }; return mockAccount; },
    'passwords.logout': () => { mockAccount = { state: 'loggedOut', email: null, server: settings.passwords.server }; return mockAccount; },
    'theme.set': ({ path, value }) => { const [group, key] = path.split('.'); theme[group][key] = value; return { theme }; },
    'theme.reset': ({ path }) => { const [group, key] = path.split('.'); theme[group][key] = themeDefaults[group][key]; return { theme }; },
    'snapshots.list': () => ({ items: [{ id: 's1', date: new Date().toISOString(), auto: true, windows: 1, workspaces: 1, tabs: 3 }] }),
    'containers.clearData': () => ({}),
    'history.query': ({ text = '', offset = 0, sort }) => {
      const h = 36e5;
      const items = [
        { url: 'https://news.ycombinator.com/item?id=41234567', title: 'Show HN: A keyboard-first browser for macOS', lastVisit: new Date(Date.now() - 6e5).toISOString(), visits: 4 },
        { url: 'https://developer.apple.com/documentation/webkit/wkwebview', title: 'WKWebView | Apple Developer Documentation', lastVisit: new Date(Date.now() - h).toISOString(), visits: 12 },
        { url: 'https://github.com/btuckerc', title: '', lastVisit: new Date(Date.now() - 26 * h).toISOString(), visits: 1 },
        { url: 'https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_table/table-layout_and_long_identifiers_that_go_on_and_on_and_on/overflow-wrap', title: 'table-layout - CSS: Cascading Style Sheets | MDN', lastVisit: new Date(Date.now() - 30 * h).toISOString(), visits: 2 },
        { url: 'https://forums.swift.org/t/se-0466-control-default-actor-isolation-inference/78321', title: 'SE-0466: Control default actor isolation inference - Swift Forums', lastVisit: new Date(Date.now() - 4 * 24 * h).toISOString(), visits: 3 },
        { url: 'https://sqlite.org/lang_select.html', title: 'SELECT', lastVisit: new Date(Date.now() - 40 * 24 * h).toISOString(), visits: 7 }
      ].filter((item) => (item.title + item.url).toLowerCase().includes(text.toLowerCase()));
      if (sort !== 'recent') items.sort((a, b) => b.visits - a.visits);
      return { items: offset ? [] : items };
    },
    'recovery.query': ({ text = '', offset = 0 }) => ({ items: offset ? [] : [
      { id: 'r1', createdAt: new Date(Date.now() - 9e5).toISOString(), saved: { title: 'Swift Forums', url: 'https://forums.swift.org' } },
      { id: 'r2', createdAt: new Date(Date.now() - 72e5).toISOString(), saved: {} },
      { id: 'r3', createdAt: new Date(Date.now() - 3 * 864e5).toISOString(), saved: { title: 'angl', url: 'https://github.com/btuckerc/angl' } }
    ].filter((item) => ((item.saved.title || '') + (item.saved.url || '')).toLowerCase().includes(text.toLowerCase())) }),
    'config.reveal': () => ({}),
    'passwords.status': () => mockAccount
  };

  window.angl = {
    call(cmd, args = {}) {
      if (window.webkit?.messageHandlers?.angl) {
        return Promise.resolve(window.webkit.messageHandlers.angl.postMessage({ cmd, args }));
      }
      console.log('[angl mock]', cmd, args);
      // Copies, like the native bridge's JSON replies: pages never share objects with the mock.
      try { return Promise.resolve(clone(mock[cmd] ? mock[cmd](clone(args)) ?? {} : {})); }
      catch (error) { return Promise.reject(error); }
    }
  };
  window.el = (tag, attrs = {}, ...children) => {
    const element = document.createElement(tag);
    Object.entries(attrs || {}).forEach(([key, value]) => {
      if (key === 'class') element.className = value;
      else if (key === 'checked' || key === 'disabled' || key === 'selected' || key === 'hidden') element[key] = Boolean(value);
      else if (key.startsWith('on') && typeof value === 'function') element.addEventListener(key.slice(2), value);
      else if (value != null) element.setAttribute(key, value);
    });
    children.flat().forEach((child) => element.append(child instanceof Node ? child : document.createTextNode(String(child))));
    return element;
  };
  window.fmtDate = (value) => value ? new Date(value).toLocaleString() : '—';
  window.fmtBytes = (value) => value < 1024 ? `${value} B` : `${(value / 1024).toFixed(1)} KB`;
  // The visible toast toggles display:none, which drops it from the accessibility tree; announce through a
  // live region that exists before its text changes.
  const announcer = window.el('div', { class: 'visually-hidden', role: 'status', 'aria-live': 'polite' });
  document.body.append(announcer);
  window.toast = (message) => {
    let element = document.querySelector('.toast');
    if (!element) { element = window.el('div', { class: 'toast', 'aria-hidden': 'true' }); document.body.append(element); }
    element.setAttribute('aria-hidden', 'true');
    element.textContent = message;
    element.style.display = 'block';
    announcer.textContent = message;
    setTimeout(() => { element.style.display = 'none'; announcer.textContent = ''; }, 3000);
  };
  const listeners = {};
  window.onAnglEvent = (name, fn) => { (listeners[name] ||= []).push(fn); };
  window.anglEvent = (name, payload) => (listeners[name] || []).forEach((fn) => fn(payload));
})();
