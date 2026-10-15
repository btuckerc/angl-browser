// Downloads log; refreshes while anything is running.
const size = (n) => n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : n < 1073741824 ? `${(n / 1048576).toFixed(1)} MB` : `${(n / 1073741824).toFixed(2)} GB`;
let timer = null;

function state(item) {
  if (item.state === 'running') return item.total > 0 ? `${Math.floor(100 * item.received / item.total)}% of ${size(item.total)}` : size(item.received);
  if (item.state === 'done') return size(item.received || item.total);
  return item.state;
}

function action(label, cmd, id, cls) {
  return el('button', { class: cls, onclick: () => angl.call(cmd, { id }).then(load).catch((e) => toast(e.message)) }, label);
}

async function load() {
  try {
    const { items } = await angl.call('downloads.list', {});
    const body = document.querySelector('tbody');
    body.replaceChildren(...items.map((item) => el('tr', {},
      el('td', {}, el('div', {}, item.filename), el('div', { class: 'url' }, item.url)),
      el('td', { class: item.state === 'failed' ? 'danger' : 'muted' }, state(item)),
      el('td', { class: 'muted' }, fmtDate(item.date)),
      el('td', {}, el('div', { class: 'actions end' },
        item.state === 'done' ? action('Open', 'downloads.open', item.id) : '',
        item.state !== 'running' ? action('Show in Finder', 'downloads.reveal', item.id) : '',
        item.state === 'running' ? action('Cancel', 'downloads.cancel', item.id, 'danger') : '')))));
    document.querySelector('#empty').hidden = items.length > 0;
    clearTimeout(timer);
    if (items.some((item) => item.state === 'running')) timer = setTimeout(load, 1000);
  } catch (e) {
    toast(e.message);
  }
}

document.querySelector('#clear').addEventListener('click', () => angl.call('downloads.clear', {}).then(load));
load();
