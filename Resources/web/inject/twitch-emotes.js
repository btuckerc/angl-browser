(() => {
  if (!/^(www\.|m\.)?twitch\.tv$/.test(location.hostname)) return;
  const channelFromURL = () => {
    const p = location.pathname.split('/').filter(Boolean);
    return p[0] === 'popout' ? p[1] : p[0];
  };
  let channel = '', map = {}, list = null, observer = null, queued = new Set(), frame = 0;
  const nativeHeight = () => {
    const img = document.querySelector('[data-a-target="emote-name"] img, [data-a-target="chat-line-message"] img');
    return img ? (img.getBoundingClientRect().height || img.height || 28) : 28;
  };
  const fetchMap = async () => {
    const next = channelFromURL();
    if (!next || next === channel) return;
    channel = next; map = {};
    try {
      const node = document.querySelector('[data-a-target="chat-room-header-label"], [data-a-target="chat-room-header"]');
      const id = node?.getAttribute('data-channel-id') || node?.getAttribute('data-a-channel-id') || null;
      const result = await window.webkit.messageHandlers.anglTwitchEmotes.postMessage({channel, id});
      if (channel === next && result && typeof result === 'object') map = result;
    } catch (_) {}
    if (list) enqueue(list);
  };
  const makeImg = (code, emote) => {
    const img = document.createElement('img');
    img.alt = code; img.title = code; img.src = emote.url1x; img.srcset = `${emote.url1x} 1x, ${emote.url2x} 2x`;
    img.loading = 'lazy'; img.decoding = 'async'; img.referrerPolicy = 'no-referrer';
    img.dataset.anglEmote = code; img.style.height = `${nativeHeight()}px`; img.style.width = 'auto'; img.style.verticalAlign = 'middle';
    return img;
  };
  const process = root => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {acceptNode(n) {
      if (!n.nodeValue || !n.nodeValue.trim() || n.parentElement?.closest('a,button,input,textarea,[contenteditable="true"],img,[data-a-target="chat-message-username"],[data-a-target="chat-message-mention"],[data-a-target="emote-name"]')) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }});
    const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const text of nodes) {
      const parts = text.nodeValue.split(/(\s+)/); if (!parts.some(x => map[x])) continue;
      const frag = document.createDocumentFragment(); let previous = null;
      for (const part of parts) {
        const e = map[part];
        if (!e) { frag.append(document.createTextNode(part)); previous = null; continue; }
        const img = makeImg(part, e);
        if (e.zeroWidth && previous) {
          const wrap = document.createElement('span'); wrap.className = 'angl-zero-emote';
          wrap.style.cssText = 'display:inline-block;position:relative;vertical-align:middle';
          previous.style.visibility = 'hidden'; wrap.append(previous);
          img.style.cssText += ';position:absolute;left:0;top:0'; wrap.append(img); frag.append(wrap); previous = wrap;
        } else { frag.append(img); previous = img; }
      }
      text.replaceWith(frag);
    }
  };
  const enqueue = node => { if (!node) return; queued.add(node); if (!frame) frame = requestAnimationFrame(() => { frame = 0; const batch = [...queued]; queued.clear(); if (!document.hidden) for (const n of batch) if (n.isConnected) process(n); }); };
  const locate = () => {
    const next = document.querySelector('[data-a-target="chat-scrollable-area__message-container"], [data-test-selector="chat-scrollable-area__message-container"]');
    if (!next || next === list) return;
    observer?.disconnect(); list = next;
    observer = new MutationObserver(records => { for (const r of records) for (const n of r.addedNodes) if (n.nodeType === 1) enqueue(n); });
    observer.observe(list, {childList: true, subtree: true});
  };
  const start = () => {
    if (document.hidden) return;
    locate(); fetchMap();
  };
  document.addEventListener('visibilitychange', start);
  const css = document.createElement('style'); css.textContent = '.angl-zero-emote{line-height:1}'; (document.head || document.documentElement).append(css);
  start();
  // SPA navigation and chat re-mounts are polled once a second, only while the tab is visible.
  let href = location.href, poll = 0;
  const tick = () => { if (location.href !== href) { href = location.href; channel = ''; map = {}; queued.clear(); start(); } else if (!list?.isConnected) locate(); };
  const watch = () => { clearInterval(poll); poll = 0; if (!document.hidden) { tick(); poll = setInterval(tick, 1000); } };
  document.addEventListener('visibilitychange', watch);
  watch();
})();
