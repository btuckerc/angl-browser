// Settings form
const sectionNames = ['General', 'Tabs', 'Pages', 'Privacy', 'Passwords', 'Appearance', 'Advanced'];
const $ = (selector) => document.querySelector(selector);
let currentSettings;

// Field labels by setting path; anything unlisted gets a label from its key.
const labels = {
  'search.engine': 'Default search URL (%s = query)',
  'downloads.folder': 'Downloads folder',
  'tabs.restoreOnLaunch': 'Restore tabs on launch',
  'tabs.unloadAfterMinutes': 'Memory saver: unload tabs idle for (minutes, 0 = off)',
  'tabs.autoArchive': 'Automatically archive inactive tabs',
  'tabs.archiveAfterHours': 'Archive tabs idle for (hours)',
  'tabs.favorites': 'Show Favorites',
  'tabs.splitView': 'Split view (two tabs side by side, ⌥⌘\\)',
  'tabs.routeByURL': 'Move matching tabs to Spaces',
  'tabs.closeWindowWithLastTab': '⌘W on the last tab closes the window',
  'snapshots.autoEveryMinutes': 'Automatic snapshots every (minutes, 0 = off)',
  'snapshots.keep': 'Recent automatic snapshots retained',
  'content.javascript': 'Allow website JavaScript',
  'content.hardening': 'WebKit security mode',
  'content.blocker': 'Content blocker',
  'content.blockRemoteFonts': 'Block remote fonts',
  'content.dark': 'Dark mode',
  'content.square': 'Square page-element corners',
  'content.zoom': 'Page zoom',
  'content.blockAutoplay': 'Block autoplay with sound',
  'content.nightAudio': 'Night audio — reduce loud/quiet swings',
  'twitch.emotes': 'Third-party emotes in chat',
  'twitch.bttv': 'BetterTTV',
  'twitch.ffz': 'FrankerFaceZ',
  'twitch.seventv': '7TV',
  'twitch.animated': 'Animated emotes',
  'privacy.cleanURLs': 'Strip tracking parameters',
  'privacy.safariUserAgent': 'Safari user agent',
  'privacy.forgetOnQuit': 'Forget sites on quit',
  'privacy.keepSignedIn': 'Preserve cookies/site data for these domains (comma-separated)',
  'blocking.updateEveryDays': 'Update lists every (days)',
  'blocking.advanced': 'Scriptlets and advanced cosmetic rules',
  'passwords.provider': 'Password manager',
  'passwords.server': 'Bitwarden server: bitwarden.com, bitwarden.eu or a self-hosted address (vault.example.com)',
  'passwords.applePasswords': 'Apple Passwords in the login picker',
  'passwords.suggestOnFocus': 'Suggest logins when a sign-in field gets focus',
  'passwords.rememberUnlock': 'Remember unlock (Touch ID; key sealed in the Secure Enclave)',
  'passwords.lockAfterMinutes': 'Lock after idle (minutes, 0 = on quit)',
  'passwords.copyTOTP': 'Copy one-time code after filling',
  'developer.inspector': 'Web Inspector',
};
const label = (path) => labels[path] ?? path.replace(/([A-Z])/g, ' $1').replace(/\./, ' › ').replace(/^./, (c) => c.toUpperCase());

// Enum-valued settings render as selects; arrays of strings as comma-separated text.
const enums = {
  'content.dark': [['off', 'Off'], ['auto', 'Auto (light-only sites)'], ['force', 'Force (every page)']],
  'content.hardening': [['off', 'Off'], ['noJIT', 'No JIT (interpreter only, macOS 26.4+)'], ['lockdown', 'Lockdown Mode']],
  'passwords.provider': [['bitwarden', 'Bitwarden'], ['none', 'None']],
};
const kind = (value) => typeof value === 'boolean' ? 'checkbox' : typeof value === 'number' ? 'number' : 'text';

// Shown only while the master setting holds the given value; hiding never changes the hidden setting.
const dependsOn = {
  'tabs.archiveAfterHours': ['tabs.autoArchive', true],
  'privacy.keepSignedIn': ['privacy.forgetOnQuit', true],
  ...Object.fromEntries(['bttv', 'ffz', 'seventv', 'animated'].map((key) => [`twitch.${key}`, ['twitch.emotes', true]])),
  ...Object.fromEntries(['server', 'account', 'rememberUnlock', 'lockAfterMinutes', 'copyTOTP']
    .map((key) => [`passwords.${key}`, ['passwords.provider', 'bitwarden']])),
};
const valueAt = (path) => path.split('.').reduce((object, key) => object?.[key], currentSettings);
function refreshDependents() {
  document.querySelectorAll('[data-path]').forEach((row) => {
    const rule = dependsOn[row.dataset.path];
    if (rule) row.hidden = valueAt(rule[0]) !== rule[1];
  });
}

function field(path) {
  const value = valueAt(path);
  const resetSetting = () => angl.call('settings.reset', { path }).then(load);
  let row;
  if (enums[path]) row = select(path, label(path), value, enums[path], (v) => save(path, v), resetSetting);
  else if (Array.isArray(value)) row = control(path, label(path), value.join(', '), 'text', (v) => save(path, v.split(/[\s,]+/).filter(Boolean)));
  else row = control(path, label(path), value, kind(value));
  row.dataset.path = path;
  return row;
}

function save(path, value) {
  const keys = path.split('.');
  const last = keys.pop();
  const parent = keys.reduce((object, key) => object?.[key], currentSettings);
  if (parent) parent[last] = value;
  refreshDependents();
  return angl.call('settings.set', { path, value }).catch((error) => toast(error.message));
}

// `onReset: null` leaves the Reset button out (rows that are part of a larger setting).
function control(path, label, value, type = 'text', onChange, onReset) {
  const input = el('input', { type, value: value ?? '' });
  if (type === 'checkbox') input.checked = Boolean(value);
  input.addEventListener('change', () => {
    const next = type === 'checkbox' ? input.checked : type === 'number' ? Number(input.value) : input.value;
    (onChange ? onChange(next) : save(path, next));
  });
  const row = el('div', { class: 'row' }, el('label', {}, label), input);
  // A blank placeholder keeps such rows' controls aligned with their neighbours'.
  if (onReset === null) {
    row.append(el('button', { style: 'visibility:hidden', tabindex: '-1', 'aria-hidden': 'true' }, 'Reset'));
    return row;
  }
  const reset = el('button', {}, 'Reset');
  reset.addEventListener('click', () => (onReset ? onReset() : angl.call('settings.reset', { path }).then(load)).catch((error) => toast(error.message)));
  row.append(reset);
  return row;
}

const link = (href, text) => el('p', {}, el('a', { href }, text));
const actions = (...buttons) => el('div', { class: 'actions' }, ...buttons);

async function load() {
  try {
    const result = await angl.call('settings.get', {});
    currentSettings = result.settings;
    const nav = $('#nav');
    const root = $('#content');
    nav.replaceChildren();
    root.replaceChildren();
    sectionNames.forEach((name) => {
      const id = name.toLowerCase();
      nav.append(el('a', { href: `#sec-${id}` }, name));
      root.append(el('section', { id: `sec-${id}` }, el('h2', {}, name)));
    });
    nav.append(el('a', { href: 'angl://spaces' }, 'Spaces ↗'), el('a', { href: 'angl://sites' }, 'Sites ↗'));
    const section = (name) => document.getElementById(`sec-${name}`);
    // Every setting path rendered (or edited by a dedicated widget); the rest land in Advanced.
    const placed = new Set(['search.keywords', 'blocking.lists', 'engines.rules']);
    const put = (name, ...paths) => paths.forEach((path) => { placed.add(path); section(name).append(field(path)); });
    const sub = (name, title) => section(name).append(el('h3', {}, title));
    const s = currentSettings;

    put('general', 'search.engine');
    sub('general', 'Search keywords');
    const keywordRows = el('tbody');
    Object.entries(s.search.keywords).sort(([a], [b]) => a.localeCompare(b)).forEach(([keyword, url]) => {
      const keyInput = el('input', { value: keyword });
      const urlInput = el('input', { value: url });
      const saveKeyword = () => {
        const next = { ...s.search.keywords };
        if (keyword !== keyInput.value) delete next[keyword];
        next[keyInput.value] = urlInput.value;
        s.search.keywords = next;
        save('search.keywords', next);
      };
      keyInput.addEventListener('change', saveKeyword);
      urlInput.addEventListener('change', saveKeyword);
      keywordRows.append(el('tr', {}, el('td', {}, keyInput), el('td', {}, urlInput), el('td', {}, el('button', { onclick: () => { delete s.search.keywords[keyword]; save('search.keywords', s.search.keywords); load(); } }, 'Remove'))));
    });
    section('general').append(el('table', { class: 'grid' }, keywordRows), actions(el('button', { onclick: () => { s.search.keywords[`new${Object.keys(s.search.keywords).length}`] = 'https://example.com/?q=%s'; save('search.keywords', s.search.keywords).then(load); } }, 'Add keyword')));
    sub('general', 'Downloads');
    put('general', 'downloads.folder');

    put('tabs', 'tabs.restoreOnLaunch', 'tabs.closeWindowWithLastTab', 'tabs.unloadAfterMinutes', 'tabs.autoArchive',
      'tabs.archiveAfterHours', 'tabs.favorites', 'tabs.splitView', 'tabs.routeByURL');
    sub('tabs', 'Session recovery');
    put('tabs', 'snapshots.autoEveryMinutes', 'snapshots.keep');
    section('tabs').append(link('angl://snapshots', 'Snapshots ↗'));

    sub('pages', 'Site defaults');
    put('pages', 'content.javascript', 'content.hardening', 'content.blocker', 'content.blockRemoteFonts',
      'content.dark', 'content.square', 'content.zoom');
    section('pages').append(link('angl://sites', 'Per-site overrides: Sites ↗'));
    sub('pages', 'Media — all sites');
    put('pages', 'content.blockAutoplay', 'content.nightAudio');
    sub('pages', 'Twitch chat');
    put('pages', 'twitch.emotes', 'twitch.bttv', 'twitch.ffz', 'twitch.seventv', 'twitch.animated');

    put('privacy', 'privacy.cleanURLs', 'privacy.safariUserAgent', 'privacy.forgetOnQuit', 'privacy.keepSignedIn');
    sub('privacy', 'Content-blocking lists');
    const status = await angl.call('blocking.status', {});
    section('privacy').append(el('p', {}, `${status.rules} rules · Updated ${fmtDate(status.updated)}${status.error ? ` · ${status.error}` : ''}`));
    status.lists.forEach((list) => section('privacy').append(control('blocking.lists', list.name, list.enabled, 'checkbox', (enabled) => {
      status.lists = status.lists.map((item) => item.id === list.id ? { ...item, enabled } : item);
      save('blocking.lists', status.lists);
    }, null)));
    put('privacy', 'blocking.updateEveryDays');
    section('privacy').append(actions(
      el('button', { onclick: () => angl.call('blocking.update', {}).then(load).catch((error) => toast(error.message)) }, 'Update now'),
      el('button', { onclick: () => angl.call('settings.reset', { path: 'blocking.lists' }).then(load).catch((error) => toast(error.message)) }, 'Reset lists')));
    put('privacy', 'blocking.advanced');

    put('passwords', 'passwords.provider', 'passwords.server');
    const account = await angl.call('passwords.status', {});
    const accountCall = (cmd) => () => angl.call(cmd, {}).then(load).catch((error) => toast(error.message));
    section('passwords').append(el('div', { 'data-path': 'passwords.account' },
      el('p', {}, account.state === 'loggedOut' ? 'Not logged in'
        : `${account.email} · ${account.server} · ${account.state === 'unlocked' ? 'Unlocked' : 'Locked'}`),
      actions(account.state === 'loggedOut'
        ? el('button', { onclick: accountCall('passwords.login') }, 'Log in…')
        : el('button', { onclick: accountCall('passwords.logout') }, 'Log out'))));
    put('passwords', 'passwords.rememberUnlock', 'passwords.lockAfterMinutes', 'passwords.copyTOTP',
      'passwords.applePasswords', 'passwords.suggestOnFocus');

    await appearance(section('appearance'));
    section('appearance').append(el('p', {}, 'Everything else lives in theme.json and css/*.css, which live-reload while angl is running.'));
    section('appearance').append(actions(...['theme', 'css'].map((file) => el('button', { onclick: () => angl.call('config.reveal', { file }).catch((error) => toast(error.message)) }, `Show ${file}`))));

    sub('advanced', 'Open matching URLs in another browser');
    const engines = await angl.call('engines.list', {});
    section('advanced').append(el('p', {}, `Installed: ${engines.items.filter((engine) => engine.installed).map((engine) => engine.name).join(', ')}`));
    const rules = el('tbody');
    s.engines.rules.forEach((rule, index) => {
      const kind = el('select', {}, ...['contains', 'host', 'prefix', 'regex'].map((value) => el('option', { value, selected: value === rule.match.kind }, value)));
      const match = el('input', { value: rule.match.value });
      const engine = el('select', {}, ...engines.items.map((item) => el('option', { value: item.id, selected: item.id === rule.engine }, item.name)));
      const persist = () => save('engines.rules', s.engines.rules);
      kind.onchange = () => { rule.match.kind = kind.value; persist(); };
      match.onchange = () => { rule.match.value = match.value; persist(); };
      engine.onchange = () => { rule.engine = engine.value; persist(); };
      rules.append(el('tr', {}, el('td', {}, kind), el('td', {}, match), el('td', {}, engine), el('td', {}, el('button', { onclick: () => { s.engines.rules.splice(index, 1); persist().then(load); } }, 'Remove'))));
    });
    section('advanced').append(el('table', { class: 'grid' }, rules), actions(el('button', { onclick: () => { s.engines.rules.push({ match: { kind: 'host', value: '' }, engine: engines.items[0]?.id || '' }); save('engines.rules', s.engines.rules).then(load); } }, 'Add host rule')));
    sub('advanced', 'Developer');
    put('advanced', 'developer.inspector');
    section('advanced').append(actions(el('button', { onclick: () => angl.call('config.reveal', { file: 'settings' }).catch((error) => toast(error.message)) }, 'Show settings')));
    // Settings added later without a home above still get a control (scalars and string lists only).
    const editable = (value) => typeof value !== 'object' || (Array.isArray(value) && value.every((item) => typeof item === 'string'));
    const unplaced = Object.entries(s).flatMap(([group, values]) => Object.keys(values).map((key) => `${group}.${key}`))
      .filter((path) => !placed.has(path) && editable(valueAt(path)));
    if (unplaced.length) { sub('advanced', 'Other'); put('advanced', ...unplaced); }
    sub('advanced', 'Keyboard shortcuts');
    const keys = await angl.call('keys.list', {});
    section('advanced').append(el('table', { class: 'grid' }, ...keys.items.map((key) => el('tr', {}, el('td', {}, key.title), el('td', { class: 'mono' }, key.chord)))));
    refreshDependents();
    if (location.hash) (document.getElementById(location.hash.slice(1)) ?? section(location.hash.slice(1)))?.scrollIntoView();
  } catch (error) {
    toast(error.message);
  }
}

// Accent presets: the Dictation app's swatches, then any custom colour.
const accents = [
  ['white', '#ffffff'], ['blue', '#55c3e8'], ['yellow', '#f5d90a'], ['pink', '#ff4fa3'],
];

function setTheme(path, value) {
  return angl.call('theme.set', { path, value }).then(load).catch((error) => toast(error.message));
}

function select(path, label, value, options, onChange, onReset) {
  const input = el('select', {}, ...options.map(([v, text]) => el('option', { value: v, selected: v === value }, text)));
  input.addEventListener('change', () => onChange(input.value));
  const reset = el('button', {}, 'Reset');
  reset.addEventListener('click', () => (onReset ? onReset() : angl.call('theme.reset', { path }).then(load)).catch((error) => toast(error.message)));
  return el('div', { class: 'row' }, el('label', {}, label), input, reset);
}

async function appearance(root) {
  const { theme } = await angl.call('theme.get', {});
  if (!theme?.color) return;
  const accent = theme.color.accent.toLowerCase();
  const swatches = el('div', { class: 'swatches' }, ...accents.map(([name, hex]) => el('button', {
    class: `swatch${accent === hex ? ' on' : ''}`, title: name, 'aria-label': name, style: `background:${hex}`,
    onclick: () => setTheme('color.accent', hex),
  })));
  const isCustom = !accents.some(([, hex]) => hex === accent);
  const custom = el('input', { type: 'color', value: accent.slice(0, 7), 'aria-label': 'Custom colour' });
  custom.addEventListener('change', () => setTheme('color.accent', custom.value));
  swatches.append(el('label', { class: `custom-swatch${isCustom ? ' on' : ''}`, title: 'Pick any colour' }, custom, 'Custom…'));
  const reset = el('button', { onclick: () => angl.call('theme.reset', { path: 'color.accent' }).then(load) }, 'Reset');
  root.append(el('div', { class: 'row' }, el('label', {}, 'Accent'), swatches, reset));
  root.append(select('window.address', 'Address', theme.window.address, [
    ['palette', 'Palette (⌘T / ⌘L float over the page)'], ['bar', 'Bar (always-visible URL field)'],
  ], (v) => setTheme('window.address', v)));
  if (theme.window.address === 'palette') {
    root.append(select('window.newTab', 'Empty tab', theme.window.newTab, [
      ['field', 'Address field in the page'], ['mark', 'Wordmark only (⌘T floats the palette)'],
    ], (v) => setTheme('window.newTab', v)));
    if (theme.window.newTab === 'field') {
      root.append(select('window.caret', 'Empty-tab caret', theme.window.caret, [
        ['block', 'Block ▮ (accent)'], ['native', 'System'],
      ], (v) => setTheme('window.caret', v)));
    }
  }
  const outline = theme.window.outline;
  root.append(select('window.outline', 'Window outline', outline, [
    ['none', 'None (system edge only)'], ['seam', 'Sidebar/content seam'], ['content', 'Inset content frame'],
  ], (v) => setTheme('window.outline', v)));
  if (outline !== 'none') {
    root.append(select('window.outlineColor', 'Colour', theme.window.outlineColor, [
      ['accent', 'Accent'], ['border', 'Border'], ['container', 'Active container'], ['custom', 'Custom'],
    ], (v) => setTheme('window.outlineColor', v)));
    if (theme.window.outlineColor === 'custom') {
      const pick = el('input', { type: 'color', value: theme.window.outlineCustomColor });
      pick.addEventListener('change', () => setTheme('window.outlineCustomColor', pick.value));
      root.append(el('div', { class: 'row' }, el('label', {}, 'Custom colour'), pick));
    }
    root.append(control('window.outlineWidth', 'Outline width (pt)', theme.window.outlineWidth, 'number',
      (v) => setTheme('window.outlineWidth', v), () => angl.call('theme.reset', { path: 'window.outlineWidth' }).then(load)));
    root.append(control('window.outlineOpacity', 'Active opacity', theme.window.outlineOpacity, 'number',
      (v) => setTheme('window.outlineOpacity', v), () => angl.call('theme.reset', { path: 'window.outlineOpacity' }).then(load)));
    root.append(control('window.outlineInactiveOpacity', 'Inactive opacity', theme.window.outlineInactiveOpacity, 'number',
      (v) => setTheme('window.outlineInactiveOpacity', v), () => angl.call('theme.reset', { path: 'window.outlineInactiveOpacity' }).then(load)));
  }
  root.append(select('sidebar.mode', 'Sidebar in new windows', theme.sidebar.mode, [
    ['pinned', 'Shown'], ['hidden', 'Hidden (peek from the left edge)'],
  ], (v) => setTheme('sidebar.mode', v)));
  root.append(select('sidebar.spaces', 'Space selector', theme.sidebar.spaces, [
    ['top', 'Top of sidebar'], ['bottom', 'Bottom of sidebar'], ['hidden', 'Hidden'],
  ], (v) => setTheme('sidebar.spaces', v)));
  for (const [key, text] of [
    ['peekWidth', 'Hidden sidebar edge catch (pt, 0 = off)'],
    ['peekDelayMs', 'Peek delay (ms)'],
    ['hideDelayMs', 'Hide delay after leaving (ms)'],
  ]) {
    const path = `sidebar.${key}`;
    root.append(control(path, text, theme.sidebar[key], 'number',
      (v) => setTheme(path, v), () => angl.call('theme.reset', { path }).then(load)));
  }
  refreshThemeCSS();
}

// Re-fetch angl://theme.css so accent-derived colours (borders, outlines) update without a reload.
function refreshThemeCSS() {
  const old = document.querySelector('link[href^="angl://theme.css"]');
  if (!old) return;
  const next = old.cloneNode();
  next.href = `angl://theme.css?${Date.now()}`;
  next.onload = () => old.remove();
  old.after(next);
}

load();
