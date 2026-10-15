// History, archived tabs, and recently closed tabs.
const pageSize = 100;
let offset = 0;
let timer = null;
let kind = 'history';
let loadID = 0;
let resetting = false;
let appending = false;
let lastKey = null;

const filter = document.querySelector('#filter');
const body = document.querySelector('tbody');
const more = document.querySelector('#more');
const empty = document.querySelector('#empty');

// Local calendar day as a UTC midnight timestamp: DST-safe day arithmetic and a stable group key.
const dayKey = (date) => Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
const fmtTime = (date) => date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

// "Today", "Yesterday", a weekday within the last week, else the date.
function dayLabel(key) {
  const now = new Date();
  const age = (dayKey(now) - key) / 864e5;
  const utc = new Date(key);
  const date = new Date(utc.getUTCFullYear(), utc.getUTCMonth(), utc.getUTCDate());
  if (age === 0) return 'Today';
  if (age === 1) return 'Yesterday';
  if (age > 1 && age < 7) return date.toLocaleDateString([], { weekday: 'long' });
  return date.toLocaleDateString([], { weekday: 'short', year: date.getFullYear() === now.getFullYear() ? undefined : 'numeric', month: 'short', day: 'numeric' });
}

function dateCell(date, grouped) {
  const text = grouped || dayKey(date) === dayKey(new Date()) ? fmtTime(date) : `${date.toLocaleDateString([], { month: 'short', day: 'numeric' })} ${fmtTime(date)}`;
  return el('td', { class: 'muted date', title: date.toLocaleString() }, text);
}

function pageCell(title, url) {
  const label = title || url || 'New Tab';
  const link = url ? el('a', { href: url, title: url }, label) : el('span', {}, label);
  // Skip the URL line when the title is the URL: it would repeat.
  return el('td', {}, link, title && url && title !== url ? el('div', { class: 'url' }, url) : '');
}

// Runs one mutation per row at a time and drops the row on success.
function mutate(tr, button, call) {
  return async () => {
    if (tr.busy || !tr.isConnected) return;
    tr.busy = true;
    if (button) button.disabled = true;
    try {
      await call();
      dropRow(tr);
    } catch (e) {
      toast(e.message);
    } finally {
      tr.busy = false;
      if (button) button.disabled = false;
    }
  };
}

function historyRow(item, date, grouped) {
  const forget = el('button', { title: 'Forget this page' }, '×');
  const tr = el('tr', {},
    dateCell(date, grouped),
    pageCell(item.title, item.url),
    el('td', { class: 'muted num' }, item.visits),
    el('td', {}, el('div', { class: 'actions end' }, forget)));
  tr.forget = mutate(tr, null, () => angl.call('history.delete', { url: item.url }));
  forget.addEventListener('click', tr.forget);
  return tr;
}

function recoveryRow(item, date, grouped, reason) {
  const restore = el('button', {}, 'Restore');
  const remove = el('button', { title: 'Delete this record' }, '×');
  const tr = el('tr', {},
    dateCell(date, grouped),
    pageCell(item.saved.title, item.saved.url),
    el('td', {}),
    el('td', {}, el('div', { class: 'actions end' }, restore, remove)));
  tr.forget = mutate(tr, null, () => angl.call('recovery.delete', { id: item.id }));
  restore.addEventListener('click', mutate(tr, restore, () => angl.call('recovery.restore', { id: item.id, reason })));
  remove.addEventListener('click', tr.forget);
  return tr;
}

const focusRow = (tr) => (tr.querySelector('a') ?? tr.querySelector('button')).focus();
const dataRows = () => [...body.querySelectorAll('tr:not(.day)')];
const sibling = (tr, dir) => {
  let node = tr[dir];
  while (node?.matches('.day')) node = node[dir];
  return node;
};

// Removes a row (and a day header left without rows); the page it came from now holds one fewer record.
function dropRow(tr) {
  if (!tr.isConnected) return;
  const hadFocus = tr.contains(document.activeElement);
  const next = sibling(tr, 'nextElementSibling');
  const prev = sibling(tr, 'previousElementSibling');
  const header = tr.previousElementSibling;
  tr.remove();
  if (header?.matches('.day') && !header.nextElementSibling?.matches(':not(.day)')) header.remove();
  offset = Math.max(0, offset - 1);
  // An append already in flight was asked for the old offset; let More ask again.
  if (appending) { loadID++; appending = false; more.hidden = false; }
  lastKey = dataRows().at(-1)?.dayKey ?? null;
  if (hadFocus) { const target = next ?? prev; if (target) focusRow(target); else filter.focus(); }
  if (!body.children.length) { if (more.hidden) showEmpty(); else load(false); }
}

function showEmpty() {
  const noun = { history: 'history', archived: 'archived tabs', closed: 'closed tabs' }[kind];
  empty.textContent = filter.value ? `Nothing in ${noun} matches “${filter.value}”.` : `No ${noun} yet.`;
  empty.hidden = false;
}

async function load(reset) {
  if (reset) {
    offset = 0;
    lastKey = null;
    resetting = true;
    body.replaceChildren();
    more.hidden = true;
    empty.hidden = true;
  } else if (resetting || appending) {
    return;
  } else {
    appending = true;
  }
  const request = ++loadID;
  const selected = kind;
  const text = filter.value;
  try {
    const recovery = selected !== 'history';
    const result = recovery
      ? await angl.call('recovery.query', { reason: selected, text, limit: pageSize, offset })
      : await angl.call('history.query', { text, limit: pageSize, offset, sort: 'recent' });
    if (request !== loadID) return;
    const items = result.items || [];
    // Day headers only make sense for a newest-first list; a ranked list gets plain rows.
    const dates = items.map((item) => new Date(recovery ? item.createdAt : item.lastVisit));
    const grouped = dates.every((date, i) => i === 0 || date <= dates[i - 1]);
    // Relative labels drift once midnight passes between pages.
    body.querySelectorAll('.day').forEach((row) => { row.firstChild.textContent = dayLabel(row.dayKey); });
    items.forEach((item, i) => {
      const key = grouped ? dayKey(dates[i]) : null;
      if (key !== null && key !== lastKey) {
        const header = el('tr', { class: 'day' }, el('td', { colspan: 4 }, dayLabel(key)));
        header.dayKey = key;
        body.append(header);
      }
      const row = recovery ? recoveryRow(item, dates[i], grouped, selected) : historyRow(item, dates[i], grouped);
      row.dayKey = key;
      lastKey = key;
      body.append(row);
    });
    offset += items.length;
    more.hidden = items.length < pageSize;
    if (!body.children.length) showEmpty();
  } catch (e) {
    if (request === loadID) toast(e.message);
  } finally {
    if (reset) { if (request === loadID) resetting = false; } else if (request === loadID) appending = false;
  }
}

// Invalidates in-flight responses right away; the replacement query follows.
function reload() {
  loadID++;
  more.hidden = true;
  clearTimeout(timer);
  return load(true);
}

function selectKind(next) {
  kind = next;
  document.querySelectorAll('[data-kind]').forEach((button) => {
    button.setAttribute('aria-pressed', String(button.dataset.kind === kind));
  });
  const recovery = kind !== 'history';
  document.querySelector('#history-actions').hidden = recovery;
  document.querySelector('#clear-recovery').hidden = !recovery;
  document.querySelector('th.num').textContent = recovery ? '' : 'Visits';
  reload();
}

// Keyboard: ↓/↑ walk the rows from the search box, ⌫ forgets the focused row, ⎋ clears the filter or returns to it.
function step(delta) {
  const rows = dataRows();
  const current = document.activeElement.closest('tr');
  const index = current ? rows.indexOf(current) + delta : delta > 0 ? 0 : rows.length - 1;
  const target = rows[index];
  if (!target) { if (index < 0) filter.focus(); return; }
  focusRow(target);
  target.scrollIntoView({ block: 'nearest' });
}
document.addEventListener('keydown', (event) => {
  if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
  const inFilter = event.target === filter;
  const row = inFilter ? null : event.target.closest('tbody tr');
  if (!inFilter && !row) return;
  switch (event.key) {
    case 'ArrowDown': event.preventDefault(); step(1); break;
    case 'ArrowUp': if (row) { event.preventDefault(); step(-1); } break;
    case 'Escape':
      if (row) { event.preventDefault(); filter.focus(); }
      else if (filter.value) { event.preventDefault(); filter.value = ''; reload(); }
      break;
    case 'Backspace':
    case 'Delete':
      if (row) { event.preventDefault(); row.forget(); }
      break;
  }
});

filter.addEventListener('input', () => {
  loadID++;
  more.hidden = true;
  clearTimeout(timer);
  timer = setTimeout(() => load(true), 150);
});
more.addEventListener('click', () => load(false));
document.querySelectorAll('[data-kind]').forEach((button) =>
  button.addEventListener('click', () => selectKind(button.dataset.kind)));
document.querySelectorAll('[data-range]').forEach((button) => button.addEventListener('click', async () => {
  const range = button.dataset.range;
  if (range === 'all' && !confirm('Clear all history?')) return;
  await angl.call('history.clear', { range }).catch((e) => toast(e.message));
  reload();
}));
document.querySelector('#clear-recovery').addEventListener('click', async () => {
  if (!confirm(`Clear all ${kind} tabs?`)) return;
  try {
    await angl.call('recovery.clear', { reason: kind });
    reload();
  } catch (e) { toast(e.message); }
});
selectKind(kind);
