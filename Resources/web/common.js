// Shared page bridge and standalone preview data
(() => {
  const defaults = {
    search: { engine: 'https://duckduckgo.com/?q=%s', keywords: { d: 'https://duckduckgo.com/?q=%s', g: 'https://google.com/search?q=%s' } },
    content: { javascript: true, blockRemoteFonts: false, blocker: true, square: true, dark: 'off', zoom: 1, blockAutoplay: true },
    tabs: { unloadAfterMinutes: 0, restoreOnLaunch: true },
    privacy: { cleanURLs: true, safariUserAgent: true },
    blocking: { lists: [{ id: 'easylist', name: 'EasyList', url: 'https://easylist.to/easylist/easylist.txt', enabled: true }], updateEveryDays: 7 },
    engines: { rules: [] }, snapshots: { autoEveryMinutes: 10, keep: 20 }, developer: { inspector: true }
  };
  const clone = (value) => JSON.parse(JSON.stringify(value));
  let settings = clone(defaults);
  let workspaceData = {
    containers: [{ id: 'default', name: 'Default', color: '#55c3e8', proxy: null, clearOnQuit: false }],
    workspaces: [{ id: 'personal', name: 'Personal', color: '#55c3e8', containerID: 'default', rules: [{ kind: 'host', value: 'example.com' }] }],
    palette: ['#55c3e8', '#a6e25f', '#ffdf6b', '#ff8eaf', '#e85b92']
  };
  const mock = {
    'settings.get': () => ({ settings, defaults, files: { settings: '~/config/angl/settings.json', theme: '~/config/angl/theme.json', keys: '~/config/angl/keys.json', css: '~/config/angl/css' } }),
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
    'blocking.update': () => mock['blocking.status'](),
    'engines.list': () => ({ items: [{ id: 'duckduckgo', name: 'DuckDuckGo', family: 'duckduckgo', installed: true }, { id: 'google', name: 'Google', family: 'google', installed: true }] }),
    'keys.list': () => ({ items: [{ command: 'newTab', title: 'New tab', chord: '⌘T' }, { command: 'closeTab', title: 'Close tab', chord: '⌘W' }] }),
    'theme.get': () => ({ theme: {} }),
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
    'config.reveal': () => ({})
  };

  window.angl = {
    call(cmd, args = {}) {
      if (window.webkit?.messageHandlers?.angl) {
        return Promise.resolve(window.webkit.messageHandlers.angl.postMessage({ cmd, args }));
      }
      console.log('[angl mock]', cmd, args);
      try { return Promise.resolve(mock[cmd] ? mock[cmd](args) : {}); }
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
  window.toast = (message) => {
    let element = document.querySelector('.toast');
    if (!element) { element = window.el('div', { class: 'toast' }); document.body.append(element); }
    element.textContent = message;
    element.style.display = 'block';
    setTimeout(() => { element.style.display = 'none'; }, 3000);
  };
  const listeners = {};
  window.onAnglEvent = (name, fn) => { (listeners[name] ||= []).push(fn); };
  window.anglEvent = (name, payload) => (listeners[name] || []).forEach((fn) => fn(payload));
})();
