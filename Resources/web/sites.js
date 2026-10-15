// Per-site override table
let sites = [];

function triState(value, change) {
  const selected = value == null ? 'default' : value ? 'on' : 'off';
  const select = el('select', {}, ...['default', 'on', 'off'].map((option) => el('option', { value: option, selected: option === selected }, option)));
  select.addEventListener('change', () => change(select.value === 'default' ? undefined : select.value === 'on'));
  return select;
}

function render() {
  const body = document.querySelector('tbody');
  const query = document.querySelector('#filter').value.toLowerCase();
  body.replaceChildren();
  sites.filter((site) => site.host.toLowerCase().includes(query)).forEach((site) => {
    const row = el('tr', {}, el('td', { class: 'mono' }, site.host));
    ['javascript', 'blocker', 'blockRemoteFonts', 'square'].forEach((key) => {
      const cell = el('td');
      cell.append(triState(site.overrides[key], (value) => {
        if (value === undefined) delete site.overrides[key];
        else site.overrides[key] = value;
        save(site);
      }));
      row.append(cell);
    });
    [['dark', ['off', 'auto', 'force']], ['hardening', ['off', 'noJIT', 'lockdown']]].forEach(([key, values]) => {
      const choice = el('select', {}, ...['default', ...values].map((value) => el('option', { value, selected: (site.overrides[key] || 'default') === value }, value)));
      choice.addEventListener('change', () => {
        if (choice.value === 'default') delete site.overrides[key];
        else site.overrides[key] = choice.value;
        save(site);
      });
      row.append(el('td', {}, choice));
    });
    ['zoom', 'volumeDB'].forEach((key) => {
      const input = el('input', { type: 'number', step: key === 'zoom' ? '0.1' : '1', value: site.overrides[key] ?? '' });
      input.placeholder = 'default';
      input.addEventListener('change', () => {
        if (input.value === '') delete site.overrides[key];
        else site.overrides[key] = Number(input.value);
        save(site);
      });
      row.append(el('td', {}, input));
    });
    row.append(el('td', {}, el('button', { onclick: () => angl.call('sites.reset', { host: site.host }).then(load).catch((error) => toast(error.message)) }, 'Reset')));
    body.append(row);
  });
}

function save(site) {
  angl.call('sites.set', { host: site.host, overrides: site.overrides }).catch((error) => toast(error.message));
}

async function load() {
  try {
    sites = (await angl.call('sites.list', {})).items;
    render();
  } catch (error) {
    toast(error.message);
  }
}

document.querySelector('#filter').addEventListener('input', render);
load();
