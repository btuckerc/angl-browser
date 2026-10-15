// Spaces and containers editor
let data;
let saveTimer;
const palette = ['#55c3e8', '#a6e25f', '#ffdf6b', '#ff8eaf', '#e85b92', '#deddda', '#39545b'];

function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    angl.call('workspaces.set', data).then((reply) => { data = reply; render(); }).catch((error) => toast(error.message));
  }, 300);
}

function textInput(value, onChange, type = 'text') {
  const input = el('input', { type, value: value ?? '' });
  input.addEventListener('change', () => {
    onChange(type === 'checkbox' ? input.checked : type === 'number' ? Number(input.value) : input.value);
    save();
  });
  return input;
}
// Preset swatches plus a custom picker; a colour outside the palette shows as the selected custom swatch.
function colorPicker(value, colors, onChange) {
  const current = (value || '').toLowerCase();
  const row = el('div', { class: 'swatches' });
  const pick = (hex) => { onChange(hex); render(); };
  colors.forEach((hex) => {
    row.append(el('button', {
      class: `swatch${hex.toLowerCase() === current ? ' on' : ''}`, title: hex, 'aria-label': hex,
      style: `background:${hex}`, onclick: () => pick(hex),
    }));
  });
  const isCustom = !colors.some((hex) => hex.toLowerCase() === current);
  const custom = el('input', { type: 'color', value: /^#[0-9a-f]{6}$/.test(current) ? current : '#55c3e8' });
  custom.addEventListener('change', () => pick(custom.value));
  row.append(el('label', { class: `custom-swatch${isCustom ? ' on' : ''}`, title: 'Pick any colour' }, custom, 'Custom…'));
  return row;
}

function line(label, ...controls) {
  return el('div', { class: 'row' }, el('label', {}, label), ...controls);
}

function render() {
  const workspaceRoot = document.querySelector('#ws');
  const containerRoot = document.querySelector('#cs');
  workspaceRoot.replaceChildren();
  containerRoot.replaceChildren();
  const colors = data.palette?.length ? data.palette : palette;
  data.workspaces.forEach((workspace) => {
    const panel = el('div', { class: 'panel' });
    const container = el('select', {}, ...data.containers.map((item) => el('option', { value: item.id, selected: item.id === workspace.containerID }, item.name)));
    container.addEventListener('change', () => { workspace.containerID = container.value; save(); });
    panel.append(
      line('Name', textInput(workspace.name, (value) => { workspace.name = value; })),
      line('Colour', colorPicker(workspace.color, colors, (value) => { workspace.color = value; save(); })),
      line('Container', container),
    );
    workspace.rules.forEach((rule, index) => {
      const kind = el('select', {}, ...['contains', 'host', 'prefix', 'regex'].map((value) => el('option', { value, selected: value === rule.kind }, value)));
      kind.addEventListener('change', () => { rule.kind = kind.value; save(); });
      panel.append(line('Open here when URL', kind, textInput(rule.value, (value) => { rule.value = value; }),
        el('button', { onclick: () => { workspace.rules.splice(index, 1); render(); save(); } }, 'Remove')));
    });
    panel.append(line('', el('button', { onclick: () => { workspace.rules.push({ kind: 'host', value: '' }); render(); save(); } }, 'Add URL rule')));
    panel.append(line('', el('button', { class: 'danger', disabled: data.workspaces.length < 2, onclick: () => {
      const others = data.workspaces.filter((item) => item !== workspace);
      if (!confirm(`Delete ${workspace.name}? Its tabs move to ${others[0].name}.`)) return;
      data.workspaces = others;
      render();
      save();
    } }, 'Delete space')));
    workspaceRoot.append(panel);
  });
  data.containers.forEach((container) => {
    const panel = el('div', { class: 'panel' });
    const proxyKind = el('select', {}, ...['none', 'http', 'socks5'].map((kind) => el('option', { value: kind, selected: (container.proxy?.kind || 'none') === kind }, kind)));
    proxyKind.addEventListener('change', () => {
      container.proxy = proxyKind.value === 'none' ? null : { kind: proxyKind.value, host: '', port: 0 };
      save();
      render();
    });
    const proxy = [proxyKind];
    if (container.proxy) {
      const host = textInput(container.proxy.host, (value) => { container.proxy.host = value; });
      host.placeholder = 'host';
      const port = textInput(container.proxy.port, (value) => { container.proxy.port = value; }, 'number');
      port.placeholder = 'port';
      proxy.push(host, port);
    }
    panel.append(
      line('Name', textInput(container.name, (value) => { container.name = value; })),
      line('Colour', colorPicker(container.color, colors, (value) => { container.color = value; save(); })),
      line('Proxy', ...proxy),
      line('Clear cookies and storage on quit', textInput(container.clearOnQuit, (value) => { container.clearOnQuit = value; }, 'checkbox')),
      line('', el('button', { class: 'danger', onclick: () => {
        if (confirm(`Clear data for ${container.name}?`)) angl.call('containers.clearData', { id: container.id }).catch((error) => toast(error.message));
      } }, 'Clear data now'), el('button', { class: 'danger', disabled: data.containers.length < 2, onclick: () => {
        const others = data.containers.filter((item) => item !== container);
        if (!confirm(`Delete ${container.name}? Its cookies and site data are erased; Spaces and tabs using it switch to ${others[0].name}.`)) return;
        data.containers = others;
        data.workspaces.forEach((item) => { if (item.containerID === container.id) item.containerID = others[0].id; });
        render();
        save();
      } }, 'Delete container')),
    );
    containerRoot.append(panel);
  });
}

angl.call('workspaces.get', {}).then((reply) => { data = reply; render(); }).catch((error) => toast(error.message));
document.querySelector('#addws').addEventListener('click', () => {
  const colors = data.palette?.length ? data.palette : palette;
  const index = data.workspaces.length;
  data.workspaces.push({ id: crypto.randomUUID(), name: `Space ${index + 1}`, color: colors[index % colors.length], containerID: data.containers[0]?.id || '', rules: [] });
  render();
  save();
});
document.querySelector('#addc').addEventListener('click', () => {
  data.containers.push({ id: crypto.randomUUID(), name: 'New container', color: palette[0], proxy: null, clearOnQuit: false });
  render();
  save();
});
