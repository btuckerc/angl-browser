// Snapshot list: open (adds windows), export, delete, import, take.
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

function act(label, cmd, id, cls) {
  return el('button', { class: cls, onclick: async () => {
    if (cmd === 'snapshots.delete' && !confirm('Delete this snapshot?')) return;
    try { await angl.call(cmd, { id }); if (cmd !== 'snapshots.open') load(); } catch (e) { toast(e.message); }
  } }, label);
}

async function load() {
  try {
    const { items } = await angl.call('snapshots.list', {});
    document.querySelector('tbody').replaceChildren(...items.map((s) => el('tr', {},
      el('td', {}, fmtDate(s.date)),
      el('td', {}, `${plural(s.windows, 'window')} · ${plural(s.workspaces, 'Space')} · ${plural(s.tabs, 'tab')}`),
      el('td', { class: 'muted' }, s.auto ? 'auto' : 'manual'),
      el('td', {}, el('div', { class: 'actions end' }, act('Open', 'snapshots.open', s.id), act('Export…', 'snapshots.export', s.id), act('Delete', 'snapshots.delete', s.id, 'danger'))))));
  } catch (e) {
    toast(e.message);
  }
}

document.querySelector('#take').addEventListener('click', () => angl.call('snapshots.take', {}).then(load).catch((e) => toast(e.message)));
document.querySelector('#import').addEventListener('click', () => angl.call('snapshots.import', {}).then(load).catch((e) => toast(e.message)));
load();
