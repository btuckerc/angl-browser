// YouTube thumbnails show a frame from the video instead of the uploader's image.
// YouTube renders three stills per video (hq1/hq2/hq3, mq2, sd2, hq720_2); they are its
// own picks (measured at 25–39 %, not 50 %), not the midpoint. We use the middle one, the
// same files Clickbait Remover and DeArrow's fallback use. A hover button swaps back.
// Main frame only, like angl's "angl-youtube-frames" rule list (top-frame loads).
(() => {
  // angl also runs this in an open page when the setting turns on, and stops it when it turns off.
  if (window.top !== window || !/^(www\.|m\.)?youtube\.com$/.test(location.hostname) || window.anglYouTubeFrames) return;

  // Uploader thumbnails, with A/B-test variants (_custom_N). Live (_live), Shorts (oar*) and
  // stills already in use (hq1…) don't match, so they stay as they are.
  const THUMB = /^https?:\/\/i\d?\.ytimg\.com\/vi(?:_webp)?\/([^/]+)\/(hq720|maxresdefault|sddefault|hqdefault|mqdefault)(?:_custom_\d+)?\.[a-z]+(?:[?#]|$)/i;
  // WebKit starts fetching an img's first source before this script sees it, so the rule list
  // blocks the resized card thumbnails (?sqp=) THUMB matches. The query marker exempts the
  // originals put back here; every THUMB match is either swapped or marked.
  const MARK = 'angl-original';
  const MARKED = /[?&]angl-original(?:[=&]|$)/;
  const split = url => { const h = url.indexOf('#'); return h < 0 ? [url, ''] : [url.slice(0, h), url.slice(h)]; };
  const isMarked = url => MARKED.test(split(url)[0]);
  const marked = url => { const [base, fragment] = split(url); return `${base}${base.includes('?') ? '&' : '?'}${MARK}${fragment}`; };
  const LARGE = new Set(['hq720', 'maxresdefault', 'sddefault']);
  // [file, width of the video picture, letterboxed 4:3]. YouTube asks for 720 px cards (hq720)
  // and 336 px sidebar ones (hqdefault) on a 2× screen, half that at 1×; the first still tried
  // is the smallest within 85 % of that. sd2 scaled to 720 px scores a median 38.8 dB PSNR
  // against hq720_2 at half its bytes and a third of its decoded memory, so hq720_2 isn't used.
  // Of 570 videos, all stills were there (507), none (28), all but hq720_2 (20), or all but
  // hq720_2 and sd2 (15): mq2 and hq2 come together, so only a missing sd2 is worth a second
  // request (a 404) before the original.
  const MQ2 = ['mq2', 320, false], HQ2 = ['hq2', 480, true], SD2 = ['sd2', 640, true];
  const ladders = [[MQ2], [HQ2], [SD2, HQ2]];
  const firstStill = large => {
    const need = (large ? 720 : 336) * Math.min(devicePixelRatio || 1, 2) / 2 * 0.85;
    const i = ladders.findIndex(([[, width]]) => width >= need);
    return i < 0 ? ladders.length - 1 : i;
  };
  const frameURL = (id, file) => `https://i.ytimg.com/vi_webp/${id}/${file}.webp`;

  const state = new WeakMap(); // img → { source, original (marked), id, steps, key, step, frame, showing, fit }
  const known = new Map();   // `${id}|${first still}` → working step, or -1 when none loads
  const listening = new WeakSet();
  let host = null, button = null, hovered = null, rect = null, moved = 0; // the hover button

  // Every URL the img may load: srcset and a <picture>'s sources win over src, and the browser
  // picks among their candidates by density, so a thumbnail anywhere there counts. Taking the
  // img over drops the responsive sources.
  const sourcesOf = img => img.parentElement?.tagName === 'PICTURE' ? img.parentElement.querySelectorAll(':scope > source[srcset]') : [];
  const candidates = img => {
    const urls = [];
    const add = set => {
      for (const part of set.split(',')) {
        const url = part.trim().split(/\s+/)[0];
        if (url) try { urls.push(new URL(url, document.baseURI).href); } catch (_) {}
      }
    };
    for (const source of sourcesOf(img)) add(source.getAttribute('srcset'));
    if (img.hasAttribute('srcset')) add(img.getAttribute('srcset'));
    if (img.hasAttribute('src')) urls.push(img.src);
    return urls;
  };
  const show = (img, url) => {
    for (const source of sourcesOf(img)) source.removeAttribute('srcset');
    if (img.hasAttribute('srcset')) img.removeAttribute('srcset');
    img.src = url;
  };
  const setFrame = (img, s) => {
    const [file, , boxed] = s.steps[s.step];
    s.frame = frameURL(s.id, file);
    s.showing = 'frame';
    // A 4:3 still holds 16:9 video between bars; cover in a 16:9 box crops exactly the bars.
    img.style.objectFit = boxed ? 'cover' : s.fit;
    show(img, s.frame);
  };
  const setOriginal = (img, s) => {
    s.showing = 'original';
    img.style.objectFit = s.fit;
    show(img, s.original);
  };
  // Setting turned off: the uploader's image, unmarked so a later start takes it over again.
  let stopped = false;
  const restore = (img, s) => {
    state.delete(img);
    img.style.objectFit = s.fit;
    show(img, s.source);
  };

  const failed = img => {
    const s = state.get(img);
    if (!s || s.showing !== 'frame') return;
    if (stopped) { restore(img, s); return; }
    if (++s.step < s.steps.length) { setFrame(img, s); return; }
    known.set(s.key, -1);
    setOriginal(img, s);
    state.delete(img);
    if (hovered === img) hide();
  };
  // On the img itself: events of detached imgs don't reach the document.
  const onLoad = e => {
    const img = e.currentTarget;
    const s = state.get(img);
    if (!s || s.showing !== 'frame' || s.frame !== img.src) return;
    if (stopped) restore(img, s);
    else if (img.naturalWidth <= 120) failed(img);
    else known.set(s.key, s.step);
  };
  const onError = e => {
    const img = e.currentTarget;
    if (state.get(img)?.frame === img.src) failed(img);
  };

  const check = img => {
    const urls = candidates(img);
    if (!urls.length) return;
    const s = state.get(img);
    if (s && urls.length === 1 && urls[0] === s.frame) {
      // Its load may have failed while detached and unobserved.
      if (img.complete && img.naturalWidth <= 120) failed(img);
      return;
    }
    if (urls.length === 1 && isMarked(urls[0])) return;
    if (s) { img.style.objectFit = s.fit; state.delete(img); }
    let m = null, src = '';
    for (const url of urls) if (!isMarked(url) && (m = THUMB.exec(url))) { src = url; break; }
    if (!m) return;
    const first = firstStill(LARGE.has(m[2].toLowerCase()));
    const key = `${m[1]}|${first}`;
    const step = known.get(key);
    if (step === -1) { show(img, marked(src)); return; }
    if (!listening.has(img)) {
      listening.add(img);
      img.addEventListener('load', onLoad);
      img.addEventListener('error', onError);
    }
    const next = { source: src, original: marked(src), id: m[1], steps: ladders[first], key, step: step ?? 0, frame: '', showing: 'frame', fit: img.style.objectFit };
    state.set(img, next);
    setFrame(img, next);
  };

  const scan = node => {
    if (node.nodeType !== 1) return;
    if (node.tagName === 'IMG') { check(node); return; }
    if (node.firstElementChild) for (const img of node.getElementsByTagName('img')) check(img);
  };
  const observer = new MutationObserver(records => {
    for (const r of records) {
      if (r.type === 'attributes') {
        const t = r.target;
        if (t.tagName === 'IMG') check(t);
        else if (t.tagName === 'SOURCE' && t.parentElement?.tagName === 'PICTURE') for (const img of t.parentElement.getElementsByTagName('img')) check(img);
      }
      else for (const n of r.addedNodes) scan(n);
    }
  });
  observer.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'srcset'] });
  if (document.documentElement) scan(document.documentElement);

  // One floating button, outside YouTube's components, over the hovered thumbnail.
  const BOX = 'yt-thumbnail-view-model, ytd-thumbnail, ytd-playlist-thumbnail, ytm-thumbnail-cover, a';
  const build = () => {
    host = document.createElement('angl-youtube-frame');
    const root = host.attachShadow({ mode: 'closed' });
    // Built node by node: assigning innerHTML on YouTube pages throws.
    const style = document.createElement('style');
    style.textContent = `
      button { position: fixed; z-index: 2147483647; display: none; margin: 0; padding: 3px 7px;
        font: 500 12px/16px Roboto, system-ui, sans-serif; color: #fff; background: rgba(0,0,0,.72);
        border: 0; border-radius: 4px; cursor: pointer; }
      button:hover { background: rgba(0,0,0,.88); }`;
    button = document.createElement('button');
    button.type = 'button';
    root.append(style, button);
    button.addEventListener('click', e => {
      e.preventDefault(); e.stopPropagation();
      const s = hovered && state.get(hovered);
      if (!s) { hide(); return; }
      if (s.showing === 'frame') setOriginal(hovered, s); else setFrame(hovered, s);
      button.textContent = s.showing === 'frame' ? 'Original' : 'Frame';
    });
    document.documentElement.append(host);
  };
  const hide = () => { hovered = null; rect = null; if (button) button.style.display = 'none'; };
  const place = (img, box) => {
    if (!host || !host.isConnected) build();
    hovered = img;
    rect = box.getBoundingClientRect();
    button.textContent = state.get(img).showing === 'frame' ? 'Original' : 'Frame';
    button.style.left = `${rect.left + 6}px`;
    button.style.top = `${rect.top + 6}px`;
    button.style.display = 'block';
  };
  const over = e => {
    if (e.target === host) return;
    const box = e.target.closest?.(BOX);
    const img = box && (box.tagName === 'IMG' ? box : box.querySelector('img'));
    if (img && state.has(img) && img !== hovered) place(img, box);
  };
  // YouTube's hover preview covers the thumbnail, so leaving is judged by position, not target.
  const move = e => {
    if (!rect || moved) return;
    const { clientX: x, clientY: y } = e;
    moved = requestAnimationFrame(() => {
      moved = 0;
      if (rect && (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom)) hide();
    });
  };
  const scrolled = () => { if (rect) hide(); };
  const passive = { capture: true, passive: true };
  addEventListener('pointerover', over, passive);
  addEventListener('pointermove', move, passive);
  addEventListener('scroll', scrolled, passive);
  addEventListener('blur', hide);

  window.anglYouTubeFrames = {
    // Setting turned off (the rule list is already gone): put the originals back and let go.
    // Detached imgs keep their state, so their own load/error listeners restore them.
    stop() {
      stopped = true;
      observer.disconnect();
      removeEventListener('pointerover', over, passive);
      removeEventListener('pointermove', move, passive);
      removeEventListener('scroll', scrolled, passive);
      removeEventListener('blur', hide);
      host?.remove();
      for (const img of [...document.getElementsByTagName('img')]) {
        const s = state.get(img);
        if (s) restore(img, s);
      }
      window.anglYouTubeFrames = undefined;
    },
  };
})();
