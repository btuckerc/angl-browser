// Settings. A registry of every setting renders once per load; search and the Modified filter
// show and hide rendered rows, and saves update rows in place, so typing and focus survive.
const $ = (selector) => document.querySelector(selector);

const SECTIONS = [
  ['general', 'General'],
  ['tabs-spaces', 'Tabs & Spaces'],
  ['appearance', 'Appearance'],
  ['pages-media', 'Pages & media'],
  ['privacy-blocking', 'Privacy & blocking'],
  ['passwords', 'Passwords'],
  ['keyboard-shortcuts', 'Keyboard shortcuts'],
  ['advanced', 'Advanced'],
];

const state = { settings: null, defaults: null, theme: null, themeDefaults: null, capabilities: {}, blocking: null, account: null, engines: [], keys: [] };
// What survives a re-render: user-opened disclosures, the deep-linked row, the last focus.
const view = { open: {}, revealed: null, lastFocus: null };
let units = [];
let rows = [];
let filtering = false;
let setting = false; // programmatic <details> changes aren't the user's

// MARK: Values

const get = (object, path) => path.split('.').reduce((o, key) => o?.[key], object);
const valueOf = (ns, path) => get(ns === 'theme' ? state.theme : state.settings, path);
const defaultOf = (ns, path) => get(ns === 'theme' ? state.themeDefaults : state.defaults, path);
const sorted = (_, value) => value && typeof value === 'object' && !Array.isArray(value)
  ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, value[key]])) : value;
const isColor = (value) => typeof value === 'string' && /^#[0-9a-f]{3,8}$/i.test(value);
function same(a, b) {
  if (isColor(a) && isColor(b)) return a.toLowerCase() === b.toLowerCase();
  return JSON.stringify(a, sorted) === JSON.stringify(b, sorted);
}
const differs = (ns, path) => defaultOf(ns, path) !== undefined && !same(valueOf(ns, path), defaultOf(ns, path));

// One write at a time per setting; the reply is the truth.
const queues = {};
// `value` may be a function of the current value, applied when the queued write runs, so edits to a
// collection build on the last saved state instead of the one captured at render time. `saved`
// runs once the reply has landed, before the next queued write for the path.
function write(ns, path, value, saved) {
  const key = `${ns}:${path}`;
  const call = () => {
    const next = typeof value === 'function' ? value(valueOf(ns, path)) : value;
    return angl.call(`${ns}.${next === undefined ? 'reset' : 'set'}`, next === undefined ? { path } : { path, value: next }).then((reply) => {
      if (ns === 'theme') state.theme = reply.theme; else state.settings = reply.settings;
      saved?.();
    });
  };
  queues[key] = (queues[key] ?? Promise.resolve()).catch(() => {}).then(call);
  return queues[key].then(() => { sync(); return true; }, (error) => { toast(error.message); sync(true); return false; });
}

// MARK: Registry

const on = (value) => value === true;
const S = (path, label, desc, extra = {}) => ({ ns: 'settings', path, label, desc, ...extra });
const T = (path, label, desc, extra = {}) => ({ ns: 'theme', path, label, desc, ...extra });
const group = (title, children, extra = {}) => ({ type: 'group', title, children, ...extra });
const more = (id, title, children) => ({ type: 'more', id, title, children });
const action = (label, desc, control, keywords = '') => ({ type: 'action', label, desc, control, keywords });
const custom = (render) => ({ type: 'custom', render });

// `need` completes "Needs …" on a dependent row that search turns up while its parent is off.
const bitwarden = { key: 'settings:passwords.provider', is: (v) => v === 'bitwarden', need: 'Bitwarden as password manager' };
const emotes = { key: 'settings:twitch.emotes', is: on, need: 'Third-party emotes on' };
const outlined = { key: 'theme:window.outline', is: (v) => v !== 'none', need: 'an outline' };
const floating = { key: 'theme:window.address', is: (v) => v === 'palette', need: 'the floating address bar' };
const listNames = (list) => list?.length ? list.join(', ') : 'none';

const link = (href, text) => el('a', { href, class: 'link-action' }, text);
const button = (text, onclick, extra = {}) => el('button', { type: 'button', onclick, ...extra }, text);
const FILE_NAMES = { theme: 'theme.json', css: 'CSS', keys: 'keys.json', settings: 'settings.json' };
const reveal = (file) => button(`Show ${FILE_NAMES[file] ?? file}`, () => angl.call('config.reveal', { file }).catch((error) => toast(error.message)));

function layout() {
  return [
    ['general', [
      group('Search', [
        S('search.engine', 'Search engine', 'URL with %s where the query goes.', { wide: true, keywords: 'default search engine duckduckgo google kagi address omnibox query template' }),
        custom(keywordsTable),
      ], { id: 'search', keywords: 'keywords shortcuts bangs aliases providers site search' }),
      group('Downloads', [
        S('downloads.folder', 'Save to', null, { wide: true, keywords: 'downloads folder save location directory path files home' }),
      ]),
    ]],
    ['tabs-spaces', [
      group('Tabs', [
        S('tabs.restoreOnLaunch', 'Reopen tabs at launch', null, { keywords: 'restore startup session reopen restart previous' }),
        S('tabs.favorites', 'Favorites row', 'Favorite bookmarks above the tab tree.', { keywords: 'bookmarks favourites icons space' }),
        S('tabs.splitView', 'Split view', 'Two tabs side by side with ⌥⌘\\.', { keywords: 'panes split screen two tabs' }),
        S('tabs.closeWindowWithLastTab', 'Close window with last tab', '⌘W on the last tab in every Space.', { keywords: 'quit cmd w last close empty' }),
      ]),
      group('Spaces', [
        S('tabs.routeByURL', 'Route tabs by URL', 'Matching sites open in their Space and container.', { keywords: 'route tabs to spaces workspace routing domain automatic isolation cookies rules' }),
        action('Spaces, containers and URL rules', null, () => link('angl://spaces', 'Open Spaces ↗'), 'manage edit workspaces containers rules'),
      ]),
      group('Inactive tabs', [
        S('tabs.unloadAfterMinutes', 'Unload after', 'Frees memory; pinned and playing tabs stay. 0 = never.', {
          unit: 'min', step: 1, min: 0, keywords: 'unload inactive tabs memory saver sleep suspend ram discard idle',
          warn: (v) => v > 0 ? 'Unsaved form input is lost when a tab unloads.' : null,
        }),
        S('tabs.autoArchive', 'Archive inactive tabs', 'Moves them to History › Archive.', { keywords: 'auto archive close cleanup recovery idle' }),
        S('tabs.archiveAfterHours', 'Archive after', null, {
          unit: 'h', step: 1, min: 1, keywords: 'archive inactive tabs idle age cleanup hours',
          dependsOn: [{ key: 'settings:tabs.autoArchive', is: on, need: 'Archive inactive tabs on' }],
        }),
      ]),
      group('Snapshots', [
        S('snapshots.autoEveryMinutes', 'Save a snapshot every', '0 = never.', { unit: 'min', step: 1, min: 0, keywords: 'automatic session snapshots backup recovery restore interval' }),
        S('snapshots.keep', 'Keep', null, {
          unit: 'snapshots', step: 1, min: 1, keywords: 'snapshots to keep retention backup history count',
          confirm: (from, to) => to < from ? `Keep only ${to} snapshots?\n\nOlder automatic snapshots may be deleted.` : null,
        }),
        action('Restore a snapshot', null, () => link('angl://snapshots', 'Open Snapshots ↗'), 'session recovery import export restore saved'),
      ]),
    ]],
    ['appearance', [
      group('Color', [
        T('color.accent', 'Accent', null, { kind: 'accent', keywords: 'accent interface white blue yellow pink colour tint swatches custom' }),
      ]),
      group('Address bar', [
        T('window.address', 'Style', null, {
          options: [['palette', 'Floating (⌘L)'], ['bar', 'Toolbar']], keywords: 'address control palette bar omnibox url location cmd l cmd t floating always visible',
        }),
        T('window.newTab', 'New tab shows', null, {
          options: [['field', 'Address field'], ['mark', 'Wordmark']], keywords: 'empty new tab blank field mark wordmark', dependsOn: [floating],
        }),
        T('window.caret', 'Caret', null, {
          options: [['block', 'Block'], ['native', 'System']], keywords: 'empty tab caret cursor insertion native block accent',
          dependsOn: [floating, { key: 'theme:window.newTab', is: (v) => v === 'field', need: 'the address field on new tabs' }],
        }),
      ]),
      group('Sidebar', [
        T('sidebar.mode', 'In new windows', null, {
          options: [['pinned', 'Shown'], ['hidden', 'Hidden']], keywords: 'sidebar mode pinned collapsed navigation peek left edge',
        }),
        T('sidebar.spaces', 'Space selector', null, {
          options: [['top', 'Top'], ['bottom', 'Bottom'], ['hidden', 'Hidden']], keywords: 'workspace switcher position spaces',
        }),
        more('sidebar-peek', 'Peek', [
          T('sidebar.peekWidth', 'Edge width', 'Hover strip that reveals a hidden sidebar. 0 = off.', { unit: 'pt', step: 1, min: 0, max: 40, keywords: 'peek edge catch hover reveal hot edge width sidebar' }),
          T('sidebar.peekDelayMs', 'Show after', null, { unit: 'ms', step: 10, min: 0, keywords: 'peek delay hover show timeout sidebar' }),
          T('sidebar.hideDelayMs', 'Hide after', null, { unit: 'ms', step: 10, min: 0, keywords: 'hide delay hover dismiss timeout sidebar' }),
        ]),
      ]),
      group('Window outline', [
        T('window.outline', 'Outline', null, {
          options: [['none', 'None'], ['seam', 'Sidebar seam'], ['content', 'Content frame']], keywords: 'window outline placement border frame seam decoration inset',
        }),
        T('window.outlineColor', 'Color', null, {
          options: [['accent', 'Accent'], ['border', 'Border'], ['container', 'Container'], ['custom', 'Custom']], keywords: 'outline color colour tint container', dependsOn: [outlined],
        }),
        T('window.outlineCustomColor', 'Custom color', null, {
          kind: 'color', keywords: 'outline custom color colour border frame',
          dependsOn: [outlined, { key: 'theme:window.outlineColor', is: (v) => v === 'custom', need: 'Custom outline color' }],
        }),
        T('window.outlineWidth', 'Width', null, { unit: 'pt', step: 0.5, min: 0, keywords: 'outline width border stroke thickness', dependsOn: [outlined] }),
        T('window.outlineOpacity', 'Opacity', null, { step: 0.05, min: 0, max: 1, keywords: 'outline opacity alpha transparency focused active', dependsOn: [outlined] }),
        T('window.outlineInactiveOpacity', 'Inactive opacity', null, { step: 0.05, min: 0, max: 1, keywords: 'outline opacity alpha transparency unfocused background windows', dependsOn: [outlined] }),
      ]),
      group('Theme files', [
        action('Customize', 'Fonts, colors and sizes. Edits apply live.',
          () => [reveal('theme'), reveal('css')], 'theme.json theme css stylesheets fonts colours radius metrics glyphs files live reload'),
      ]),
    ]],
    ['pages-media', [
      group('Site defaults', [
        S('content.zoom', 'Zoom', null, { unit: '×', step: 0.05, min: 0.25, max: 5, keywords: 'page zoom size scale magnification text' }),
        S('content.dark', 'Dark mode', null, {
          options: [['off', 'Off'], ['auto', 'Light-only sites'], ['force', 'All pages']], keywords: 'page dark mode night theme invert automatic force',
        }),
        S('content.javascript', 'JavaScript', null, {
          keywords: 'website scripts execution compatibility', warn: (v) => v ? null : 'Most sites break without it.',
        }),
        S('content.square', 'Square corners', null, { keywords: 'square page corners radius rounding sharp rectangles' }),
        action('Per-site overrides', null, () => link('angl://sites', 'Open Sites ↗'), 'sites exceptions per site settings'),
      ], { desc: 'Sites can override these.' }),
      group('Media', [
        S('content.blockAutoplay', 'Block autoplay with sound', null, { keywords: 'video audio mute playback autoplay' }),
        S('content.nightAudio', 'Night audio', 'Evens out loud and quiet video.', { keywords: 'compressor volume normalize loudness youtube twitch dynamics' }),
        S('content.youtubeFrames', 'YouTube video stills', 'A frame from the video in place of the uploader’s thumbnail.', { keywords: 'youtube thumbnails clickbait frame still dearrow original' }),
        S('content.fullscreen', 'Video full screen', 'How a page’s full-screen button behaves.', {
          options: [['screen', 'Fill the screen at once'], ['window', 'Fill the window'], ['native', 'macOS full screen']],
          keywords: 'fullscreen full screen video youtube twitch player space animation immersive theater',
        }),
        S('content.autoPictureInPicture', 'Picture in Picture on tab switch', 'A playing video follows you when you switch tabs (⌥⌘P any time).', {
          keywords: 'pip picture in picture floating video mini player tab switch',
        }),
        S('content.youtubeQuality', 'YouTube quality', 'Best the video has up to this; picking in the player still works.', {
          options: [['auto', 'Auto'], ['hd720', '720p'], ['hd1080', '1080p'], ['hd1440', '1440p'], ['hd2160', '4K'], ['highres', 'Highest']],
          keywords: 'youtube resolution quality 1080p 4k hd video stream',
        }),
        more('twitch-chat', 'Twitch chat', [
          S('twitch.emotes', 'Third-party emotes', 'BetterTTV, FrankerFaceZ and 7TV.', { keywords: 'twitch extensions chat emoji' }),
          S('twitch.bttv', 'BetterTTV', null, { keywords: 'bttv twitch chat emotes', dependsOn: [emotes] }),
          S('twitch.ffz', 'FrankerFaceZ', null, { keywords: 'ffz twitch chat emotes', dependsOn: [emotes] }),
          S('twitch.seventv', '7TV', null, { keywords: 'seventv twitch chat emotes', dependsOn: [emotes] }),
          S('twitch.animated', 'Animate emotes', 'Off saves CPU in busy chats.', { keywords: 'animated motion cpu first frame twitch', dependsOn: [emotes] }),
        ]),
      ]),
    ]],
    ['privacy-blocking', [
      group('Tracking', [
        S('content.blocker', 'Block ads and trackers', 'Sites can override.', {
          keywords: 'content blocker ads adblock trackers network cosmetic', warn: (v) => v ? null : 'Ads and trackers load on every site.',
        }),
        S('privacy.cleanURLs', 'Strip tracking parameters', 'utm_*, fbclid and the like, from links and copied URLs.', { keywords: 'remove clean links query gclid utm' }),
      ]),
      group('Filter lists', [
        custom(filterLists),
        S('blocking.updateEveryDays', 'Update every', null, { unit: 'days', step: 1, min: 1, keywords: 'update lists refresh schedule subscriptions' }),
        more('blocking-more', 'More', [
          S('blocking.advanced', 'Scriptlets and cosmetic rules', 'Needed on sites like YouTube.', { keywords: 'advanced blocking youtube anti adblock scripts cosmetic scriptlets' }),
          S('content.blockRemoteFonts', 'Block web fonts', 'Some pages look different.', { keywords: 'remote fonts webfonts typefaces privacy requests' }),
          S('privacy.safariUserAgent', 'Identify as Safari', 'Fewest broken sites, smallest fingerprint.', { keywords: 'safari user agent fingerprint spoof browser identity ua compatibility' }),
        ]),
      ], { id: 'filter-lists', keywords: 'subscriptions sources adguard ublock cookies rules blocking lists' }),
      group('Site data', [
        S('privacy.forgetOnQuit', 'Clear site data on quit', 'Cookies, caches and storage.', {
          keywords: 'forget sites on quit clear erase logout history session storage deletion',
          confirm: (from, to) => to && !from ? `Clear site data on quit?\n\nEvery site except ${listNames(valueOf('settings', 'privacy.keepSignedIn'))} loses its cookies and storage when angl quits, so you’ll be signed out. History and snapshots stay.` : null,
        }),
        S('privacy.keepSignedIn', 'Except', 'Domains, comma-separated.', {
          kind: 'list', wide: true, keywords: 'keep site data signed in exceptions allowlist cookies google youtube domains',
          dependsOn: [{ key: 'settings:privacy.forgetOnQuit', is: on, need: 'Clear site data on quit on' }],
          confirm: (from, to) => {
            const dropped = (from ?? []).filter((domain) => !(to ?? []).includes(domain));
            return valueOf('settings', 'privacy.forgetOnQuit') && dropped.length
              ? `Stop keeping ${dropped.join(', ')}?\n\nIts cookies and storage are cleared at the next quit.` : null;
          },
        }),
      ]),
      group('Security', [
        S('content.hardening', 'WebKit restrictions', 'Stricter modes break some sites. Sites can override.', {
          kind: 'hardening', keywords: 'webkit security mode lockdown no jit interpreter exploit hardening attack surface',
          options: [['off', 'Standard'], ['noJIT', 'No JIT'], ['lockdown', 'Lockdown']],
          warn: (v) => v === 'noJIT' && !state.capabilities.noJIT ? 'No JIT needs macOS 26.4; pages run in Standard.' : null,
          confirm: (from, to) => to === 'lockdown' && from !== 'lockdown'
            ? 'Use Lockdown?\n\nTurns off the JavaScript JIT and other web features in angl. Many sites break.' : null,
        }),
      ]),
    ]],
    ['passwords', [
      group('Password manager', [
        S('passwords.provider', 'Provider', null, {
          options: [['bitwarden', 'Bitwarden'], ['none', 'None']], keywords: 'password manager provider vaultwarden none credentials',
          confirm: (from, to) => from === 'bitwarden' && to === 'none'
            ? 'Turn off Bitwarden?\n\nThe vault locks and Touch ID unlock is forgotten. You stay logged in.' : null,
        }),
        S('passwords.server', 'Server', 'bitwarden.com, bitwarden.eu or your own.', { wide: true, keywords: 'bitwarden server cloud region eu us vaultwarden hostname self-hosted', dependsOn: [bitwarden] }),
        custom(accountRow),
      ]),
      group('Vault', [
        S('passwords.lockAfterMinutes', 'Lock when idle for', 'Quit, sleep and screen lock always lock. 0 = never.', {
          unit: 'min', step: 1, min: 0, keywords: 'lock unused vault timeout idle auto lock security', dependsOn: [bitwarden],
          warn: (v) => v === 0 ? 'Stays unlocked until quit, sleep or screen lock.' : null,
        }),
        S('passwords.rememberUnlock', 'Unlock with Touch ID', 'Off asks for the master password after each launch.', {
          keywords: 'biometric secure enclave keychain remember unlock', dependsOn: [bitwarden],
        }),
        S('passwords.copyTOTP', 'Copy one-time code after filling', 'Clears after 30 seconds.', {
          keywords: 'totp otp 2fa verification clipboard paste', dependsOn: [bitwarden],
          warn: (v) => v ? 'Other apps can read the clipboard.' : null,
        }),
      ]),
      group('Filling', [
        S('passwords.suggestOnFocus', 'Suggest logins on focus', '⌘\\ always opens the picker.', { keywords: 'autofill suggestions username credentials sign in field' }),
        S('passwords.applePasswords', 'Offer Apple Passwords', null, { keywords: 'apple passwords picker icloud keychain autofill native' }),
      ]),
    ]],
    ['keyboard-shortcuts', [
      group(null, [custom(shortcutsTable)], { id: 'shortcuts', keywords: 'keys bindings hotkeys chords keys.json' }),
    ]],
    ['advanced', [
      group(null, [
        more('handoff', 'Browser handoff', [custom(handoffRules)]),
        more('developer', 'Developer', [
          S('developer.inspector', 'Inspectable tabs', 'Web Inspector can attach to any tab. ⌥⌘I works either way.', {
            keywords: 'developer debug devtools remote inspect safari web inspector', warn: (v) => v ? 'Every tab is open to Web Inspector.' : null,
          }),
          action('Settings file', 'Everything on this page. Edits apply live.', () => reveal('settings'), 'settings.json file configuration json directory'),
        ]),
      ]),
      custom(otherSettings),
    ]],
  ];
}

// Paths with a dedicated widget (or a row above); anything else lands in Advanced › Other settings.
const COLLECTIONS = ['search.keywords', 'blocking.lists', 'engines.rules'];

// MARK: Rendering

const slug = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const settingID = (ns, path) => `setting-${ns}-${path.replace(/\./g, '-')}`;
const fold = (text) => String(text ?? '').normalize('NFKC').toLowerCase();
const searchable = (...parts) => fold(parts.flat().filter((part) => part != null && part !== '').join(' '));
const hl = (tag, text, attrs = {}) => el(tag, { ...attrs, class: `${attrs.class ?? ''} hl`.trim(), 'data-text': text }, text);

// A unit is what search shows or hides: a setting row, a table row, an action.
function unit(element, { text, scope, modified = () => false, header = false }) {
  element.dataset.unit = '';
  const u = { el: element, text, scope, modified, header };
  units.push(u);
  return u;
}

function render() {
  const active = document.activeElement?.id;
  const scroll = window.scrollY;
  units = [];
  rows = [];
  const placed = new Set(COLLECTIONS);
  const content = $('#content');
  const nav = $('#nav');
  content.replaceChildren();
  nav.replaceChildren();
  for (const [id, name] of SECTIONS) {
    const a = el('a', { href: `#sec-${id}`, 'data-section': id }, el('span', {}, name), el('span', { class: 'count', 'aria-hidden': 'true' }));
    a.addEventListener('click', (event) => { event.preventDefault(); goToSection(id); });
    nav.append(a);
  }
  nav.append(el('a', { href: 'angl://spaces', class: 'external' }, 'Spaces ↗'), el('a', { href: 'angl://sites', class: 'external' }, 'Sites ↗'));

  const sections = layout();
  // Placed paths first, so Other settings can list the rest.
  const walk = (nodes) => nodes.forEach((node) => { if (node.path) placed.add(node.path); if (node.children) walk(node.children); });
  sections.forEach(([, nodes]) => walk(nodes));
  const ctx = { placed };
  for (const [id, nodes] of sections) {
    const name = SECTIONS.find(([key]) => key === id)[1];
    const section = el('section', { id: `sec-${id}`, 'data-section': id }, hl('h2', name, { tabindex: '-1' }));
    const scope = [name];
    for (const node of nodes) section.append(renderNode(node, scope, ctx));
    content.append(section);
  }
  sync();
  const target = active && document.getElementById(active);
  if (target && target !== document.body && !target.closest('[hidden]')) target.focus({ preventScroll: true });
  window.scrollTo(0, scroll);
}

function renderNode(node, scope, ctx) {
  if (node.type === 'group') {
    const words = [node.title, node.desc, node.keywords];
    const box = el('div', { class: 'group', ...(node.id ? { id: `group-${node.id}` } : {}) });
    if (node.title) box.append(hl('h3', node.title));
    if (node.desc) box.append(hl('p', node.desc, { class: 'group-desc' }));
    const rowsBox = el('div', { class: 'group-rows' });
    const inner = [...scope, ...words];
    for (const child of node.children) rowsBox.append(renderNode(child, inner, { ...ctx, group: node }));
    box.append(rowsBox);
    return box;
  }
  if (node.type === 'more') {
    const details = el('details', { class: 'more', id: `more-${node.id}`, 'data-more': node.id },
      el('summary', {}, hl('span', node.title), el('span', { class: 'more-count' })));
    details.open = Boolean(view.open[node.id]);
    details.addEventListener('toggle', () => { if (!setting && !filtering) view.open[node.id] = details.open; markEdges(); });
    const body = el('div', { class: 'more-body' });
    for (const child of node.children) body.append(renderNode(child, [...scope, node.title], ctx));
    details.append(body);
    return details;
  }
  if (node.type === 'action') return renderAction(node, scope);
  if (node.type === 'custom') return node.render(scope, ctx);
  return renderSetting(node, scope);
}

function renderAction(node, scope) {
  const id = `action-${slug(node.label)}`;
  const control = el('div', { class: 'setting-control' }, node.control());
  const row = el('div', { class: 'setting action-row', id },
    el('div', { class: 'setting-text' }, hl('span', node.label, { class: 'setting-label' }), node.desc ? hl('span', node.desc, { class: 'setting-desc' }) : ''),
    control);
  // Button and link text count too: "show css" finds Theme and CSS.
  unit(row, { text: searchable(node.label, node.desc, node.keywords, control.textContent.replace(/↗/g, '')), scope: searchable(scope) });
  return row;
}

const kindOf = (item, value) => item.kind ?? (item.options ? 'select' : typeof value === 'boolean' ? 'switch'
  : typeof value === 'number' ? 'number' : Array.isArray(value) ? 'list' : 'text');

// How a value reads in "Default: …" and in search.
function display(item, value) {
  const kind = kindOf(item, value);
  if (kind === 'switch') return value ? 'On' : 'Off';
  if (item.options) return item.options.find(([v]) => v === value)?.[1] ?? String(value);
  if (kind === 'list') return listNames(value);
  if (kind === 'number' && item.unit) return `${value} ${item.unit}`;
  return value == null ? 'none' : String(value);
}

function renderSetting(item, scope) {
  const value = valueOf(item.ns, item.path);
  const kind = kindOf(item, value);
  const id = settingID(item.ns, item.path);
  const controlID = `${id}-control`;
  const labelID = `${id}-label`;
  const descID = `${id}-desc`;
  const noteID = `${id}-note`;
  const label = hl('span', item.label, { class: 'setting-label', id: labelID });
  const marker = el('span', { class: 'modified-tag', hidden: true }, 'Modified');
  const context = el('span', { class: 'context-tag', hidden: true }, 'Shown for context');
  const desc = item.desc ? hl('span', item.desc, { class: 'setting-desc', id: descID }) : '';
  const note = el('span', { class: 'setting-note', id: noteID, hidden: true });
  const text = el(kind === 'accent' ? 'div' : 'label', { class: 'setting-text', ...(kind === 'accent' ? {} : { for: controlID }) },
    el('span', { class: 'label-line' }, label, marker, context), desc, note);
  const control = makeControl(item, kind, { id: controlID, labelID, describedBy: item.desc ? `${descID} ${noteID}` : noteID });
  const row = el('div', { class: `setting kind-${kind}`, id, 'data-key': `${item.ns}:${item.path}` }, text,
    el('div', { class: 'setting-control' }, control.element));
  const options = rowOptions(item.label, () => resetSetting(item), () => `Default: ${display(item, defaultOf(item.ns, item.path))}`);
  row.append(options.element);
  const u = unit(row, {
    text: searchable(item.label, item.desc, item.keywords, item.path, item.path.replace(/[._-]/g, ' '), item.options?.map(([v, t]) => [v, t]), display(item, valueOf(item.ns, item.path))),
    scope: searchable(scope),
    modified: () => differs(item.ns, item.path),
  });
  const r = {
    item, row, unit: u, control, marker, note, context, options,
    dormant: () => (item.dependsOn ?? []).find((d) => !d.is(valueOf(...d.key.split(/:(.*)/s).slice(0, 2)))),
    update(force) {
      const current = valueOf(item.ns, item.path);
      if (force || !row.contains(document.activeElement) || kind === 'switch' || kind === 'accent') control.set(current);
      const modified = differs(item.ns, item.path);
      marker.hidden = !modified;
      row.classList.toggle('is-modified', modified);
      options.update(modified);
      const blocked = r.dormant();
      const lines = [];
      const warn = item.warn?.(current);
      if (blocked) lines.push(`Needs ${blocked.need}.`);
      if (warn) lines.push(warn);
      note.textContent = lines.join(' ');
      note.hidden = !lines.length;
      note.classList.toggle('warn', Boolean(warn || blocked));
      u.text = searchable(item.label, item.desc, item.keywords, item.path, item.path.replace(/[._-]/g, ' '), item.options?.map(([v, t]) => [v, t]), display(item, current));
    },
  };
  rows.push(r);
  return row;
}

// One "⋯" disclosure per row: Reset to default, and what the default is.
function rowOptions(label, onReset, defaultText, resetLabel = 'Reset to default') {
  // Focus stays in the row (keeping it visible under Modified) until the reset lands.
  const reset = button(resetLabel, () => { details.open = false; details.querySelector('summary').focus(); onReset(); });
  const line = el('p', { class: 'default-line' });
  const details = el('details', { class: 'row-options' },
    el('summary', { 'aria-label': `Options for ${label}`, title: 'Options' }, '⋯'),
    el('div', { class: 'row-menu' }, reset, line));
  details.addEventListener('toggle', () => {
    if (!details.open) return;
    document.querySelectorAll('details.row-options[open]').forEach((other) => { if (other !== details) other.open = false; });
  });
  return {
    element: details,
    update(modified) { reset.disabled = !modified; line.textContent = defaultText(); },
  };
}

function makeControl(item, kind, { id, labelID, describedBy }) {
  const aria = { id, 'aria-labelledby': labelID, 'aria-describedby': describedBy };
  const current = () => valueOf(item.ns, item.path);
  const commit = (next, revert) => {
    const from = current();
    if (same(from, next)) return;
    const message = item.confirm?.(from, next);
    if (message && !window.confirm(message)) return revert();
    write(item.ns, item.path, next);
  };

  if (kind === 'switch') {
    const input = el('input', { type: 'checkbox', role: 'switch', ...aria });
    input.addEventListener('change', () => commit(input.checked, () => { input.checked = !input.checked; }));
    const element = el('span', { class: 'switch' }, input,
      el('span', { class: 'switch-track', 'aria-hidden': 'true' }, el('span', { class: 'switch-thumb' })));
    return { element, set: (v) => { input.checked = Boolean(v); } };
  }
  if (kind === 'select' || kind === 'hardening') {
    const select = el('select', aria, ...item.options.map(([value, text]) => el('option', {
      value, disabled: kind === 'hardening' && value === 'noJIT' && !state.capabilities.noJIT,
    }, kind === 'hardening' && value === 'noJIT' && !state.capabilities.noJIT ? 'No JIT (needs macOS 26.4)' : text)));
    select.addEventListener('change', () => commit(select.value, () => { select.value = current(); }));
    return { element: select, set: (v) => { select.value = v; } };
  }
  if (kind === 'number') {
    const input = el('input', { type: 'number', inputmode: 'decimal', step: item.step ?? 'any', min: item.min, max: item.max, ...aria });
    input.addEventListener('change', () => {
      const raw = input.value.trim();
      const next = Number(raw);
      const bad = raw === '' || !Number.isFinite(next) || (item.min != null && next < item.min) || (item.max != null && next > item.max);
      if (bad) {
        input.value = current();
        toast(item.max != null ? `${item.label}: enter ${item.min} to ${item.max}` : `${item.label}: enter a number of at least ${item.min ?? 0}`);
        return;
      }
      commit(next, () => { input.value = current(); });
    });
    const element = item.unit ? el('span', { class: 'with-unit' }, input, el('span', { class: 'unit', 'aria-hidden': 'true' }, item.unit)) : input;
    return { element, set: (v) => { input.value = v; } };
  }
  if (kind === 'list') {
    const input = el('input', { type: 'text', class: item.wide ? 'wide' : '', spellcheck: 'false', ...aria });
    input.addEventListener('change', () => commit(input.value.split(/[\s,]+/).filter(Boolean), () => { input.value = current().join(', '); }));
    return { element: input, set: (v) => { input.value = (v ?? []).join(', '); } };
  }
  if (kind === 'color') {
    const input = el('input', { type: 'color', ...aria });
    input.addEventListener('change', () => commit(input.value, () => { input.value = current(); }));
    return { element: input, set: (v) => { input.value = String(v).slice(0, 7); } };
  }
  if (kind === 'accent') return accentControl(item, commit, labelID);
  const input = el('input', { type: 'text', class: item.wide ? 'wide' : '', spellcheck: 'false', ...aria });
  input.addEventListener('change', () => commit(input.value, () => { input.value = current(); }));
  return { element: input, set: (v) => { input.value = v ?? ''; } };
}

// Accent presets: the Dictation app's swatches, then any custom colour.
const ACCENTS = [['White', '#ffffff'], ['Blue', '#55c3e8'], ['Yellow', '#f5d90a'], ['Pink', '#ff4fa3']];

function accentControl(item, commit, labelID) {
  const swatches = ACCENTS.map(([name, hex]) => button('', () => commit(hex, () => {}), {
    class: 'swatch-button', 'aria-label': name, title: name,
  }));
  swatches.forEach((swatch, i) => swatch.append(el('span', { class: 'swatch-sample', style: `background:${ACCENTS[i][1]}` }), el('span', { class: 'swatch-check', 'aria-hidden': 'true' }, '✓')));
  const picker = el('input', { type: 'color', 'aria-label': 'Custom accent color' });
  picker.addEventListener('change', () => commit(picker.value, () => {}));
  const customBox = el('label', { class: 'swatch-custom' }, picker, el('span', {}, 'Custom…'), el('span', { class: 'swatch-check', 'aria-hidden': 'true' }, '✓'));
  const chosen = el('span', { class: 'swatch-chosen' });
  const element = el('div', { class: 'swatches', role: 'group', 'aria-labelledby': labelID }, ...swatches, customBox, chosen);
  return {
    element,
    set(value) {
      const accent = String(value).toLowerCase();
      let name = 'Custom';
      swatches.forEach((swatch, i) => {
        const selected = ACCENTS[i][1] === accent;
        swatch.setAttribute('aria-pressed', String(selected));
        if (selected) name = ACCENTS[i][0];
      });
      customBox.classList.toggle('on', name === 'Custom');
      picker.value = accent.slice(0, 7);
      chosen.textContent = `Selected: ${name}${name === 'Custom' ? ` ${accent}` : ''}`;
    },
  };
}

async function resetSetting(item) {
  const from = valueOf(item.ns, item.path);
  const to = defaultOf(item.ns, item.path);
  const message = item.confirm?.(from, to);
  if (message && !window.confirm(message)) return;
  if (await write(item.ns, item.path, undefined)) {
    announce(`${item.label} reset to default`);
    focusRow(document.getElementById(settingID(item.ns, item.path)));
  }
}

// MARK: Collections

// Collection header: a status row with the collection's actions and whole-setting options (reset).
function collectionHeader(scope, { label, path, actions = [], resetLabel, confirmReset, defaultText, info, words = '' }) {
  const options = rowOptions(label, async () => {
    const message = confirmReset();
    if (message && !window.confirm(message)) return;
    if (await write('settings', path, undefined)) { announce(`${label} reset to default`); render(); }
  }, defaultText, resetLabel);
  const marker = el('span', { class: 'modified-tag', hidden: true }, 'Modified');
  const header = el('div', { class: 'setting action-row', id: `collection-${slug(label)}` },
    el('div', { class: 'setting-text' }, ...info), el('div', { class: 'setting-control' }, marker, ...actions), options.element);
  const u = unit(header, { text: searchable(label, path, path.replace(/[._-]/g, ' '), words, actions.map((a) => a.textContent), resetLabel), scope: searchable(scope), modified: () => differs('settings', path), header: true });
  rows.push({ unit: u, update() { const m = differs('settings', path); marker.hidden = !m; header.classList.toggle('is-modified', m); options.update(m); } });
  return header;
}

function keywordsTable(scope) {
  const map = state.settings.search.keywords;
  const defaults = state.defaults.search.keywords;
  const save = async (next, focusID) => {
    if (await write('settings', 'search.keywords', next)) render();
    const id = typeof focusID === 'function' ? focusID() : focusID;
    requestAnimationFrame(() => document.getElementById(id)?.focus());
  };
  const body = el('tbody');
  Object.entries(map).sort(([a], [b]) => a.localeCompare(b)).forEach(([keyword, url]) => {
    const keyID = `keyword-${slug(keyword) || 'blank'}-key`;
    const keyInput = el('input', { id: keyID, value: keyword, spellcheck: 'false', 'aria-label': `Keyword ${keyword}` });
    const urlInput = el('input', { id: `keyword-${slug(keyword) || 'blank'}-url`, value: url, spellcheck: 'false', class: 'wide', 'aria-label': `Search URL for keyword ${keyword}` });
    keyInput.addEventListener('change', () => {
      const next = keyInput.value.trim();
      if (!next || next === keyword) { keyInput.value = keyword; return; }
      if (next in valueOf('settings', 'search.keywords')) { toast(`The keyword “${next}” already exists`); keyInput.value = keyword; return; }
      save((now) => {
        // Checked again when the write runs: an earlier queued rename may have taken the name.
        if (!(keyword in now) || next in now) { if (next in now) toast(`The keyword “${next}” already exists`); return now; }
        return Object.fromEntries(Object.entries(now).map(([k, v]) => k === keyword ? [next, v] : [k, v]));
      }, `keyword-${slug(next)}-url`);
    });
    urlInput.addEventListener('change', () => {
      if (!urlInput.value.includes('%s')) toast('The search URL needs %s where the query goes');
      const value = urlInput.value;
      write('settings', 'search.keywords', (now) => keyword in now ? { ...now, [keyword]: value } : now);
    });
    const remove = button('Remove', () => {
      save(({ [keyword]: _, ...rest }) => rest, 'keyword-add');
    }, { 'aria-label': `Remove keyword ${keyword}` });
    const tr = el('tr', {}, el('td', {}, keyInput), el('td', {}, urlInput), el('td', {}, remove));
    unit(tr, { text: searchable(keyword, url), scope: searchable(scope), modified: () => defaults[keyword] !== url });
    body.append(tr);
  });
  const removed = Object.keys(defaults).filter((k) => !(k in map));
  const add = button('Add keyword', () => {
    let key = 'new';
    save((now) => {
      for (let n = 2; key in now; n += 1) key = `new${n}`;
      return { ...now, [key]: 'https://example.com/?q=%s' };
    }, () => `keyword-${key}-key`);
  }, { id: 'keyword-add' });
  const header = collectionHeader(scope, {
    label: 'Keywords', path: 'search.keywords', actions: [add], resetLabel: 'Restore default keywords…',
    words: 'search keywords shortcuts',
    info: [hl('span', 'Keywords', { class: 'setting-label' }), hl('span', 'Type one before your query.', { class: 'setting-desc' }),
      removed.length ? el('span', { class: 'setting-desc' }, `Removed defaults: ${removed.join(', ')}`) : ''],
    defaultText: () => `Default: ${Object.keys(defaults).sort().join(', ')}`,
    confirmReset: () => `Restore the default keywords?\n\nYours are replaced by ${Object.keys(defaults).sort().join(', ')}.`,
  });
  return el('div', { class: 'collection' }, header,
    el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, el('th', {}, 'Keyword'), el('th', {}, 'Search URL'), el('th', {}, el('span', { class: 'visually-hidden' }, 'Actions')))), body));
}

// Built-in lists: a few words each; a custom list shows its URL.
const LIST_INFO = {
  'adguard-base': ['AdGuard Base', 'Ads.', 'safari advertising base'],
  'adguard-tracking': ['AdGuard Tracking Protection', 'Trackers.', 'privacy analytics tracking'],
  'ubo-filters': ['uBlock filters', 'Extra coverage; overlaps the others.', 'ubo origin assets ads'],
  'annoyances-cookies': ['AdGuard Cookie Notices', 'Hides cookie banners; may click “accept”.', 'annoyances banners gdpr consent'],
};

function filterLists(scope) {
  const lists = state.settings.blocking.lists;
  const defaults = state.defaults.blocking.lists;
  const status = state.blocking ?? {};
  const box = el('div', { class: 'collection' });
  const statusLine = el('span', { class: 'setting-desc' }, status.busy ? 'Updating…' : `${(status.rules ?? 0).toLocaleString()} · updated ${fmtDate(status.updated)}`);
  const update = button(status.busy ? 'Updating…' : 'Update now', updateLists, { disabled: status.busy, id: 'lists-update' });
  box.append(collectionHeader(scope, {
    label: 'Filter lists', path: 'blocking.lists', resetLabel: 'Reset lists…', actions: [update],
    words: 'list status update now rules refresh reset lists',
    info: [hl('span', 'Rules', { class: 'setting-label' }), statusLine,
      status.error ? el('span', { class: 'setting-note warn' }, `Update failed: ${status.error}`) : '',
      valueOf('settings', 'content.blocker') ? '' : el('span', { class: 'setting-note warn' }, 'Not applied while blocking is off.')],
    defaultText: () => `Default: ${defaults.filter((d) => d.enabled).map((d) => LIST_INFO[d.id]?.[0] ?? d.name).join(', ')} on`,
    confirmReset: () => 'Restore the default filter lists?\n\nYour list choices, and any lists added in settings.json, are replaced by the defaults.',
  }));
  lists.forEach((list) => {
    const [name, desc, words] = LIST_INFO[list.id] ?? [list.name, list.url, ''];
    const builtIn = defaults.find((d) => d.id === list.id);
    const id = `list-${slug(list.id)}`;
    const item = { ns: 'settings', path: `blocking.lists.${list.id}`, label: name, desc, kind: 'switch' };
    const save = (enabled) => write('settings', 'blocking.lists', (now) => now.map((l) => l.id === list.id ? { ...l, enabled } : l));
    const input = el('input', { type: 'checkbox', role: 'switch', id: `${id}-control`, 'aria-labelledby': `${id}-label`, 'aria-describedby': `${id}-desc` });
    input.addEventListener('change', () => save(input.checked));
    const marker = el('span', { class: 'modified-tag', hidden: true }, 'Modified');
    const row = el('div', { class: 'setting kind-switch', id },
      el('label', { class: 'setting-text', for: `${id}-control` },
        el('span', { class: 'label-line' }, hl('span', name, { class: 'setting-label', id: `${id}-label` }), marker), hl('span', desc, { class: 'setting-desc', id: `${id}-desc` })),
      el('div', { class: 'setting-control' }, el('span', { class: 'switch' }, input,
        el('span', { class: 'switch-track', 'aria-hidden': 'true' }, el('span', { class: 'switch-thumb' })))));
    const current = () => state.settings.blocking.lists.find((l) => l.id === list.id);
    const modified = () => !builtIn || !same(current(), builtIn);
    const options = builtIn
      ? rowOptions(name, () => save(builtIn.enabled).then((ok) => ok && focusRow(row)), () => `Default: ${builtIn.enabled ? 'On' : 'Off'}`, 'Restore default state')
      : null;
    if (options) row.append(options.element);
    const u = unit(row, { text: searchable(name, desc, words, list.name, list.id, list.url, item.path), scope: searchable(scope), modified });
    rows.push({
      unit: u,
      update() {
        input.checked = Boolean(current()?.enabled);
        const m = modified();
        marker.hidden = !m;
        row.classList.toggle('is-modified', m);
        options?.update(Boolean(builtIn) && !same(current(), builtIn));
      },
    });
    box.append(row);
  });
  return box;
}

let polling = null;
async function updateLists() {
  try {
    state.blocking = await angl.call('blocking.update', {});
    render();
    // The rebuild runs natively; follow it until it's done.
    clearInterval(polling);
    let tries = 0;
    polling = setInterval(async () => {
      tries += 1;
      try {
        state.blocking = await angl.call('blocking.status', {});
        if (!state.blocking.busy || tries > 120) { clearInterval(polling); render(); announce(state.blocking.error ? 'List update failed' : 'Lists updated'); }
      } catch (error) { clearInterval(polling); toast(error.message); }
    }, 1000);
  } catch (error) { toast(error.message); }
}

// Rules have no ids on disk; the page keeps one per saved rule, in order, so a queued edit or
// removal still finds its rule after an earlier queued removal shifted the array. The ids follow
// the saved array only: a write's new ids are committed when its reply lands.
let ruleIDs = [];
let nextRuleID = 1;
function alignRuleIDs(rules) {
  if (ruleIDs.length !== rules.length) ruleIDs = rules.map(() => nextRuleID++);
  return ruleIDs;
}

function handoffRules(scope) {
  const rules = state.settings.engines.rules;
  const ids = [...alignRuleIDs(rules)];
  const engines = state.engines;
  const box = el('div', { class: 'collection' });
  const installed = engines.filter((engine) => engine.installed).map((engine) => engine.name);
  // `update(now, ids)` returns the next rules and their ids.
  const save = (update, focusID) => {
    let pending = null;
    return write('settings', 'engines.rules', (now) => {
      pending = update(now, [...alignRuleIDs(now)]);
      return pending.rules;
    }, () => { ruleIDs = pending.ids; }).then((ok) => {
      if (ok && focusID) { render(); requestAnimationFrame(() => document.getElementById(typeof focusID === 'function' ? focusID() : focusID)?.focus()); }
    });
  };
  const body = el('tbody');
  rules.forEach((rule, index) => {
    const n = index + 1;
    const ruleID = ids[index];
    // Apply `edit` to this rule's current position; a rule already removed is left alone.
    const onRule = (edit) => (now, current) => {
      const at = current.indexOf(ruleID);
      return at < 0 ? { rules: now, ids: current } : edit(now, current, at);
    };
    const kind = el('select', { 'aria-label': `Rule ${n} match` }, ...['contains', 'host', 'prefix', 'regex'].map((value) => el('option', { value, selected: value === rule.match.kind }, value)));
    const match = el('input', { value: rule.match.value, spellcheck: 'false', 'aria-label': `Rule ${n} value`, id: `rule-${n}-value` });
    const known = engines.some((engine) => engine.id === rule.engine);
    const engine = el('select', { 'aria-label': `Rule ${n} browser` },
      ...engines.map((item) => el('option', { value: item.id, selected: item.id === rule.engine }, item.installed ? item.name : `${item.name} (not installed)`)),
      ...(known ? [] : [el('option', { value: rule.engine, selected: true }, `${rule.engine} (unknown)`)]));
    const change = (patch) => save(onRule((now, current, at) => ({ rules: now.map((r, i) => i === at ? patch(r) : r), ids: current })));
    kind.onchange = () => change((r) => ({ ...r, match: { ...r.match, kind: kind.value } }));
    match.onchange = () => change((r) => ({ ...r, match: { ...r.match, value: match.value } }));
    engine.onchange = () => change((r) => ({ ...r, engine: engine.value }));
    const remove = button('Remove', () => save(onRule((now, current, at) => ({
      rules: now.filter((_, i) => i !== at), ids: current.filter((id) => id !== ruleID),
    })), 'rule-add'), { 'aria-label': `Remove rule ${n}` });
    const tr = el('tr', {}, el('td', {}, kind), el('td', {}, match), el('td', {}, engine), el('td', {}, remove));
    const name = engines.find((e) => e.id === rule.engine)?.name;
    unit(tr, { text: searchable(rule.match.kind, rule.match.value, rule.engine, name), scope: searchable(scope), modified: () => true });
    body.append(tr);
  });
  const add = button('Add host rule', () => save((now, current) => ({
    rules: [...now, { match: { kind: 'host', value: '' }, engine: engines[0]?.id ?? '' }], ids: [...current, nextRuleID++],
  }), () => `rule-${valueOf('settings', 'engines.rules').length}-value`), { id: 'rule-add' });
  box.append(collectionHeader(scope, {
    label: 'Handoff rules', path: 'engines.rules', actions: [add], resetLabel: 'Remove all rules…',
    words: ['browser handoff rules external engine redirect installed browsers', installed, engines.map((e) => e.name)].flat().join(' '),
    info: [hl('span', 'Rules', { class: 'setting-label' }),
      hl('span', 'Open matching URLs in another browser. First match wins.', { class: 'setting-desc' }),
      el('span', { class: 'setting-desc' }, `Installed: ${installed.length ? installed.join(', ') : 'none'}`)],
    defaultText: () => 'Default: no rules',
    confirmReset: () => `Remove all ${valueOf('settings', 'engines.rules').length} handoff rules?`,
  }));
  if (rules.length) {
    box.append(el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, el('th', {}, 'Match'), el('th', {}, 'Value'), el('th', {}, 'Browser'), el('th', {}, el('span', { class: 'visually-hidden' }, 'Actions')))), body));
  }
  return box;
}

// ⌘ ⌥ ⇧ ⌃ in shortcut search, by name too.
const CHORD_WORDS = { '⌘': 'cmd command', '⌥': 'opt option alt', '⇧': 'shift', '⌃': 'ctrl control', '↩': 'return enter', '⎋': 'esc escape', '⌫': 'delete backspace', '\\': 'backslash', '/': 'slash', '←': 'left', '→': 'right', '↑': 'up', '↓': 'down', '⇥': 'tab' };
const chordWords = (chord) => [...chord].map((c) => CHORD_WORDS[c] ?? c.toLowerCase()).join(' ');

function shortcutsTable(scope) {
  const body = el('tbody');
  state.keys.forEach((key) => {
    const tr = el('tr', { tabindex: '-1' }, hl('td', key.title), hl('td', key.chord, { class: 'mono' }));
    unit(tr, { text: searchable(key.title, key.command, key.chord, chordWords(key.chord)), scope: searchable(scope) });
    body.append(tr);
  });
  const head = el('div', { class: 'setting action-row', id: 'collection-shortcuts' },
    el('div', { class: 'setting-text' }, hl('span', 'Custom shortcuts', { class: 'setting-label' })),
    el('div', { class: 'setting-control' }, reveal('keys')));
  unit(head, { text: searchable('custom shortcuts show keys keys.json edit bindings file'), scope: searchable(scope), header: true });
  return el('div', { class: 'collection' }, head,
    el('table', { class: 'grid shortcuts' }, el('thead', {}, el('tr', {}, el('th', {}, 'Action'), el('th', {}, 'Shortcut'))), body));
}

function accountRow(scope) {
  const account = state.account ?? {};
  const loggedOut = !account.state || account.state === 'loggedOut';
  const statusText = loggedOut ? 'Not logged in' : `${account.email} · ${account.server} · ${account.state === 'unlocked' ? 'Unlocked' : 'Locked'}`;
  const call = (cmd) => angl.call(cmd, {}).then((reply) => { state.account = reply; render(); }).catch((error) => toast(error.message));
  const control = loggedOut
    ? button('Log in…', () => call('passwords.login'), { id: 'account-action' })
    : button('Log out…', () => {
      if (window.confirm('Log out of Bitwarden here?\n\nangl forgets this account and its Touch ID unlock. Your vault isn’t affected.')) call('passwords.logout');
    }, { id: 'account-action', class: 'danger' });
  const note = el('span', { class: 'setting-note warn', hidden: true });
  const row = el('div', { class: 'setting action-row', id: 'setting-settings-passwords-account' },
    el('div', { class: 'setting-text' }, hl('span', 'Account', { class: 'setting-label' }), el('span', { class: 'setting-desc' }, statusText), note),
    el('div', { class: 'setting-control' }, control));
  const u = unit(row, { text: searchable('Bitwarden account log in log out login logout locked unlocked status session'), scope: searchable(scope) });
  rows.push({ unit: u, dormant: () => valueOf('settings', 'passwords.provider') === 'bitwarden' ? null : bitwarden, update() {} });
  return row;
}

// Settings with no row above (added later, or hand-written) still get a control.
function otherSettings(scope, ctx) {
  const editable = (value) => typeof value !== 'object' || (Array.isArray(value) && value.every((item) => typeof item === 'string'));
  const humanize = (path) => path.replace(/([A-Z])/g, ' $1').replace(/\./, ' › ').replace(/^./, (c) => c.toUpperCase());
  const paths = Object.entries(state.settings).flatMap(([groupKey, values]) => values && typeof values === 'object'
    ? Object.keys(values).map((key) => `${groupKey}.${key}`) : [])
    .filter((path) => !ctx.placed.has(path) && editable(valueOf('settings', path)));
  if (!paths.length) return document.createDocumentFragment();
  return renderNode(group('Other settings', paths.map((path) => S(path, humanize(path), path))), scope, ctx);
}

// MARK: State sync and filtering

function sync(force) {
  for (const r of rows) r.update(force);
  applyFilters();
}

const tokens = () => fold($('#search').value).split(/\s+/).filter(Boolean);
const modifiedOnly = () => $('#modified').getAttribute('aria-pressed') === 'true';

function applyFilters() {
  const words = tokens();
  const modOnly = modifiedOnly();
  filtering = words.length > 0 || modOnly;
  document.body.classList.toggle('filtering', filtering);
  const focused = document.activeElement;
  const matches = (u) => words.every((w) => u.text.includes(w) || u.scope.includes(w)) && (!modOnly || u.modified());
  for (const u of units) {
    // A row being edited stays put until the filters change.
    const keep = u.el.contains(focused);
    u.match = filtering && (matches(u) || keep);
    u.context = false;
  }
  for (const r of rows) {
    const blocked = r.dormant?.();
    const u = r.unit;
    if (!filtering) {
      u.el.hidden = Boolean(blocked) && view.revealed !== u.el.id;
      continue;
    }
    u.el.hidden = !u.match;
    // A matched dormant row brings the settings it waits for, as context.
    if (u.match && blocked) {
      for (const d of r.item?.dependsOn ?? [bitwarden]) {
        const parent = rows.find((p) => p.item && `${p.item.ns}:${p.item.path}` === d.key);
        if (parent && !parent.unit.match) { parent.unit.el.hidden = false; parent.unit.context = true; }
      }
    }
  }
  for (const u of units) {
    if (rows.some((r) => r.unit === u)) continue;
    u.el.hidden = filtering && !u.match;
  }
  // Table headers show while any of their rows do.
  for (const u of units.filter((x) => x.header)) {
    const box = u.el.closest('.collection');
    if (filtering && box?.querySelector('tr[data-unit]:not([hidden]), .setting[data-unit]:not([hidden])')) { u.el.hidden = false; if (!u.match) u.context = true; }
  }
  for (const u of units) {
    u.el.classList.toggle('context', u.context);
    const tag = u.el.querySelector(':scope .context-tag');
    if (tag) tag.hidden = !u.context;
  }
  layoutGroups();
  highlight(words);
  const counted = units.filter((u) => u.match && !u.context && !u.el.hidden);
  updateRail(counted);
  const empty = filtering && !counted.length;
  $('#empty').hidden = !empty;
  $('#empty-text').textContent = words.length
    ? `No settings match “${$('#search').value.trim()}”.${modOnly ? ' Only modified settings are shown.' : ''}` : 'No modified settings.';
  $('#clear').hidden = !filtering;
  announceCount(filtering ? counted.length : null);
}

// Groups, disclosures and sections hide when nothing in them shows; disclosures open while filtering.
function layoutGroups() {
  setting = true;
  const shown = (box) => Boolean(box.querySelector('[data-unit]:not([hidden])'));
  document.querySelectorAll('#content details.more').forEach((details) => {
    const any = shown(details);
    details.hidden = filtering && !any;
    const want = filtering ? any : Boolean(view.open[details.dataset.more]) || details.contains(document.getElementById(view.revealed));
    if (details.open !== want) details.open = want;
    const modified = [...details.querySelectorAll('.is-modified')].length;
    details.querySelector('.more-count').textContent = modified ? `${modified} modified` : '';
  });
  document.querySelectorAll('#content .group').forEach((box) => { box.hidden = !shown(box); });
  document.querySelectorAll('#content section').forEach((section) => { section.hidden = filtering && !shown(section); });
  markEdges();
  setting = false;
}

// A card draws its own edge, so its last visible line drops its separator.
function markEdges() {
  document.querySelectorAll('#content .group-rows').forEach((card) => {
    card.querySelectorAll('.edge-last').forEach((node) => node.classList.remove('edge-last'));
    const lines = [...card.querySelectorAll('.setting, tr, details.more > summary')].filter((node) => node.getClientRects().length);
    lines.at(-1)?.classList.add('edge-last');
  });
}

function highlight(words) {
  document.querySelectorAll('#content .hl').forEach((node) => {
    const text = node.dataset.text;
    if (!words.length || node.closest('[hidden]')) { if (node.textContent !== text || node.childElementCount) node.textContent = text; return; }
    const lower = text.toLowerCase();
    const ranges = [];
    for (const word of words) {
      for (let i = lower.indexOf(word); i !== -1 && word; i = lower.indexOf(word, i + word.length)) ranges.push([i, i + word.length]);
    }
    if (!ranges.length) { node.textContent = text; return; }
    ranges.sort((a, b) => a[0] - b[0]);
    const merged = [];
    for (const r of ranges) { const last = merged.at(-1); if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]); else merged.push([...r]); }
    const parts = [];
    let at = 0;
    for (const [start, end] of merged) {
      if (start > at) parts.push(document.createTextNode(text.slice(at, start)));
      parts.push(el('mark', {}, text.slice(start, end)));
      at = end;
    }
    if (at < text.length) parts.push(document.createTextNode(text.slice(at)));
    node.replaceChildren(...parts);
  });
}

function updateRail(counted) {
  const counts = {};
  for (const u of counted) {
    const id = u.el.closest('section')?.dataset.section;
    counts[id] = (counts[id] ?? 0) + 1;
  }
  document.querySelectorAll('#nav a[data-section]').forEach((a) => {
    const n = filtering ? counts[a.dataset.section] ?? 0 : 0;
    a.querySelector('.count').textContent = n ? String(n) : '';
    a.classList.toggle('dim', filtering && !n);
    const name = a.firstChild.textContent;
    if (filtering) a.setAttribute('aria-label', `${name}, ${n} ${n === 1 ? 'result' : 'results'}; show all settings in this section`);
    else a.removeAttribute('aria-label');
  });
  spy();
}

let countTimer = null;
function announceCount(n) {
  clearTimeout(countTimer);
  countTimer = setTimeout(() => { $('#status').textContent = n == null ? '' : `${n} ${n === 1 ? 'result' : 'results'}`; }, 200);
}
const announce = (message) => { clearTimeout(countTimer); $('#status').textContent = message; };

function clearFilters() {
  $('#search').value = '';
  $('#modified').setAttribute('aria-pressed', 'false');
  applyFilters();
}

// MARK: Navigation and keys

const focusable = 'input, select, textarea, button:not([disabled]), summary, a[href], [tabindex="-1"]';

function focusRow(row) {
  if (!row || row.hidden) return;
  const target = row.querySelector('.setting-control input, .setting-control select, .setting-control button, .setting-control a, input, select') ?? row;
  target.focus({ preventScroll: true });
  target.scrollIntoView({ block: 'nearest' });
}

function goToSection(id) {
  clearFilters();
  view.revealed = null;
  view.section = id;
  history.replaceState(null, '', `#sec-${id}`);
  const section = document.getElementById(`sec-${id}`);
  section?.scrollIntoView({ block: 'start' });
  section?.querySelector('h2')?.focus({ preventScroll: true });
}

// #sec-…, #group-… or #setting-{settings|theme}-{path with -}: scroll there, opening what hides it.
function followHash() {
  const id = decodeURIComponent(location.hash.slice(1));
  if (!id) return;
  const target = document.getElementById(id);
  if (!target || !$('#content').contains(target)) return;
  clearFilters();
  if (target.dataset.unit != null) {
    view.revealed = target.id;
    target.hidden = false;
    for (let d = target.closest('details.more'); d; d = d.parentElement?.closest('details.more')) view.open[d.dataset.more] = true;
    applyFilters();
    target.scrollIntoView({ block: 'center' });
    focusRow(target);
  } else {
    target.scrollIntoView({ block: 'start' });
  }
}

function spy() {
  const head = $('.settings-head').getBoundingClientRect().bottom;
  let current = null;
  document.querySelectorAll('#content section:not([hidden])').forEach((section) => {
    if (section.getBoundingClientRect().top <= head + 24) current = section.dataset.section;
  });
  // At the bottom the last sections can't reach the top: prefer the one just chosen in the rail.
  if (window.scrollY > 0 && window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) {
    const chosen = view.section && document.getElementById(`sec-${view.section}`);
    const top = chosen?.getBoundingClientRect().top;
    current = top != null && top >= head - 4 && top < window.innerHeight ? view.section
      : [...document.querySelectorAll('#content section:not([hidden])')].at(-1)?.dataset.section;
  }
  current ??= document.querySelector('#content section:not([hidden])')?.dataset.section;
  document.querySelectorAll('#nav a[data-section]').forEach((a) => {
    if (a.dataset.section === current) a.setAttribute('aria-current', 'location'); else a.removeAttribute('aria-current');
  });
}

const typing = (node) => node?.matches?.('input, select, textarea, [contenteditable], button, a, summary, dialog *');

function bindChrome() {
  const search = $('#search');
  let frame = 0;
  search.addEventListener('input', () => { view.revealed = null; cancelAnimationFrame(frame); frame = requestAnimationFrame(applyFilters); });
  search.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      const shown = [...document.querySelectorAll('#content [data-unit]:not([hidden])')].filter((node) => !node.closest('[hidden]'));
      const first = units.filter((u) => u.match && !u.context && shown.includes(u.el)).sort((a, b) => shown.indexOf(a.el) - shown.indexOf(b.el))[0];
      if (!first) return;
      const target = first.el.matches('tr') && !first.el.querySelector('input, select, button') ? first.el : first.el.querySelector(focusable) ?? first.el;
      target.focus();
      target.scrollIntoView({ block: 'nearest' });
    }
  });
  $('#modified').addEventListener('click', () => {
    const on = !modifiedOnly();
    $('#modified').setAttribute('aria-pressed', String(on));
    view.revealed = null;
    applyFilters();
  });
  const clear = () => { clearFilters(); search.focus(); };
  $('#clear').addEventListener('click', clear);
  $('#empty-clear').addEventListener('click', clear);
  document.addEventListener('focusin', (event) => { if ($('#content').contains(event.target)) view.lastFocus = event.target; });
  document.addEventListener('click', (event) => {
    document.querySelectorAll('details.row-options[open]').forEach((d) => { if (!d.contains(event.target)) d.open = false; });
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      const menu = document.querySelector('details.row-options[open]');
      if (menu) { menu.open = false; menu.querySelector('summary').focus(); event.preventDefault(); return; }
      if (filtering) { clearFilters(); search.focus(); event.preventDefault(); return; }
      if (document.activeElement === search) {
        const back = view.lastFocus?.isConnected && !view.lastFocus.closest('[hidden]') ? view.lastFocus : $('#title');
        back.focus();
        event.preventDefault();
      }
      return;
    }
    if (event.key === '/' && !event.metaKey && !event.ctrlKey && !event.altKey && !typing(document.activeElement)) {
      event.preventDefault();
      window.anglFocusSearch();
    }
  });
  window.addEventListener('hashchange', followHash);
  let spying = 0;
  window.addEventListener('scroll', () => { cancelAnimationFrame(spying); spying = requestAnimationFrame(spy); }, { passive: true });
  const measure = () => document.documentElement.style.setProperty('--head-h', `${$('.settings-head').offsetHeight}px`);
  new ResizeObserver(measure).observe($('.settings-head'));
}

// ⌘F (native Find on this page) and "/" land here.
window.anglFocusSearch = () => {
  const search = $('#search');
  search.focus();
  search.select();
};

// MARK: Loading

async function load() {
  try {
    const [settings, theme, blocking, account, engines, keys] = await Promise.all([
      angl.call('settings.get', {}), angl.call('theme.get', {}), angl.call('blocking.status', {}),
      angl.call('passwords.status', {}), angl.call('engines.list', {}), angl.call('keys.list', {}),
    ]);
    Object.assign(state, {
      settings: settings.settings, defaults: settings.defaults, capabilities: settings.capabilities ?? {},
      theme: theme.theme, themeDefaults: theme.defaults, blocking, account, engines: engines.items ?? [], keys: keys.items ?? [],
    });
    render();
    followHash();
  } catch (error) {
    toast(error.message);
  }
}

bindChrome();
load();
