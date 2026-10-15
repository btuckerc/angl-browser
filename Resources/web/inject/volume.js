// Per-tab media volume, isolated world, every frame. Attenuates HTMLMediaElement volume relative
// to what the page chose (never amplifies). Covers audio/video elements in the document; WebAudio
// and detached `new Audio()` objects are out of this world's reach. Muting is native when WebKit
// allows it, so `muted` here is only the fallback. The app updates it with
// window.__anglVolume.set(factor, muted). At the default (factor 1, unmuted) it watches nothing.
(() => {
  if (window.__anglVolume) return;
  let factor = __ANGL_FACTOR__;
  let muted = __ANGL_MUTED__;
  const base = new WeakMap(); // element -> volume the page asked for
  const ours = new WeakSet(); // elements whose next volumechange we caused

  // Elements held weakly so removed ones can be collected; dead refs are pruned as the set grows.
  const weakElements = () => {
    let refs = new Set();
    let marks = new WeakSet();
    let pruneAt = 64;
    return {
      add(el) {
        if (marks.has(el)) return;
        marks.add(el);
        refs.add(new WeakRef(el));
        if (refs.size > pruneAt) {
          refs = new Set([...refs].filter((ref) => ref.deref()));
          pruneAt = Math.max(64, refs.size * 2);
        }
      },
      *[Symbol.iterator]() {
        for (const ref of refs) {
          const el = ref.deref();
          if (el) yield el;
        }
      },
      clear() {
        refs = new Set();
        marks = new WeakSet();
        pruneAt = 64;
      },
    };
  };
  // Every element seen, so settings reach media that is out of the document when they change.
  const tracked = weakElements();
  // Elements we muted: unmuting restores only these.
  const silenced = weakElements();

  const apply = (el) => {
    if (!base.has(el)) base.set(el, el.volume);
    const volume = Math.max(0, Math.min(1, base.get(el) * factor));
    if (el.volume !== volume) {
      ours.add(el);
      el.volume = volume;
    }
    if (muted && !el.muted) {
      ours.add(el);
      el.muted = true;
      silenced.add(el);
    }
  };

  const track = (el) => {
    if (el.__anglTracked) return;
    el.__anglTracked = true;
    tracked.add(el);
    el.addEventListener("volumechange", () => {
      if (ours.has(el)) {
        ours.delete(el);
        return;
      }
      // The page changed volume itself: that becomes the new baseline. A tab mute stays authoritative.
      base.set(el, factor > 0 ? Math.min(1, el.volume / factor) : el.volume);
      if (factor !== 1 || muted) apply(el);
    });
    if (factor !== 1 || muted) apply(el);
  };

  // Discovery runs only while attenuating or muting. Media in the document announces itself with
  // loadstart before it can play (and play as a backstop), so no subtree observer is needed.
  let watching = false;
  const onMedia = (e) => {
    if (e.target instanceof HTMLMediaElement) track(e.target);
  };
  const scan = () => document.querySelectorAll("audio, video").forEach(track);
  const watch = () => {
    const needed = factor !== 1 || muted;
    if (needed === watching) return;
    watching = needed;
    for (const type of ["loadstart", "play"]) {
      if (needed) document.addEventListener(type, onMedia, true);
      else document.removeEventListener(type, onMedia, true);
    }
    if (!needed) return;
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", scan, { once: true });
    else scan();
  };
  watch();

  window.__anglVolume = {
    set(f, m) {
      factor = f;
      muted = m;
      scan();
      for (const el of tracked) apply(el);
      if (!muted) {
        for (const el of silenced) {
          if (!el.muted) continue;
          ours.add(el);
          el.muted = false;
        }
        silenced.clear();
      }
      watch();
    },
  };
})();
