// Version, paths, profiles, import, key map.
async function load() {
  try {
    const info = await angl.call('about.info', {});
    const rows = [
      ['version', `${info.version} (${info.build})`],
      ['engine', `system WebKit ${info.webkit}`],
      ['profile', info.profile],
      ['config', info.paths.config],
      ['state', info.paths.state],
    ];
    document.querySelector('#info').replaceChildren(...rows.map(([k, v]) => el('tr', {}, el('th', { style: 'width:100px' }, k), el('td', { class: 'mono' }, v))));
    const problems = document.querySelector('#problems');
    problems.hidden = !info.problems.length;
    problems.querySelector('ul').replaceChildren(...info.problems.map((p) => el('li', {}, p)));

    const profiles = await angl.call('profiles.list', {});
    document.querySelector('#profiles').replaceChildren(...profiles.items.map((name) => el('div', { class: 'row' },
      el('label', {}, name),
      name === profiles.current ? el('span', { class: 'muted' }, 'this window') : el('button', { onclick: () => angl.call('profiles.open', { name }).catch((e) => toast(e.message)) }, 'Open'))));

    const keys = await angl.call('keys.list', {});
    document.querySelector('#keys').replaceChildren(...keys.items.map((k) => el('tr', {}, el('td', { class: 'mono', style: 'width:110px' }, k.chord), el('td', {}, k.title), el('td', { class: 'muted mono' }, k.command))));
  } catch (e) {
    toast(e.message);
  }
}

document.querySelector('#createProfile').addEventListener('click', () => {
  const name = document.querySelector('#newProfile').value.trim().toLowerCase();
  angl.call('profiles.open', { name }).then(load).catch((e) => toast(e.message));
});
document.querySelectorAll('[data-import]').forEach((button) => button.addEventListener('click', async () => {
  try {
    const r = await angl.call('import.run', { source: button.dataset.import });
    toast(`imported ${r.imported} into ${r.folder}`);
  } catch (e) {
    toast(e.message);
  }
}));
load();
