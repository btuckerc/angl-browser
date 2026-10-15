// Night audio, page world, every frame; installed only while Settings › Pages › Night audio is on.
// FrankerFaceZ's player compressor (Web Audio DynamicsCompressorNode: threshold −50 dB, knee 40,
// ratio 12, attack 0, release 0.25 s) without capturing system audio. WebKit gives Media Source
// playback no Web Audio source, so each audio SourceBuffer's appends are mirrored here, decoded with
// WebCodecs and played through the compressor in step with the video; the element's own audio track
// is switched off only while that copy is playing. Anything this can't follow (encrypted media,
// unknown containers or codecs, rates other than 1×, MediaSource in a worker, missing data) keeps
// the element's native, uncompressed audio.
(() => {
  if (window.__anglNightAudio || !window.AudioDecoder || !window.AudioContext) return;
  const sourceClasses = [window.MediaSource, window.ManagedMediaSource].filter(Boolean);
  if (!sourceClasses.length) return;
  Object.defineProperty(window, "__anglNightAudio", { value: true });

  const AHEAD = 2; // seconds decoded and scheduled ahead of the playhead
  const SPAN = 300; // seconds of mirrored packets kept per SourceBuffer
  const PREROLL = 0.1; // decoder warm-up before a (re)start point
  const LATE = 0.045; // shadow/video drift that forces a resync
  const PAUSE_GRACE = 10000; // ms a paused element stays on the copy before native audio returns
  const LOOKAHEAD = 0.006; // DynamicsCompressorNode's fixed pre-delay
  const AUDIO = /\b(mp4a|opus|vorbis|flac|mp3|ac-3|ec-3)\b/i;

  // ---- byte helpers ----
  const u16 = (b, i) => (b[i] << 8) | b[i + 1];
  const u32 = (b, i) => ((b[i] << 24) >>> 0) + ((b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]);
  const tag = (b, i) => String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);
  const join = (a, b) => {
    if (!a.length) return b;
    const out = new Uint8Array(a.length + b.length);
    out.set(a);
    out.set(b, a.length);
    return out;
  };

  // ---- fragmented MP4 (Twitch, YouTube AAC) ----
  function* boxes(b, i = 0, end = b.length) {
    while (i + 8 <= end) {
      let size = u32(b, i), head = 8;
      if (size === 1) { size = u32(b, i + 8) * 2 ** 32 + u32(b, i + 12); head = 16; }
      if (size < head || i + size > end) return;
      yield [tag(b, i + 4), b.subarray(i + head, i + size), i];
      i += size;
    }
  }
  const child = (b, type) => { for (const [t, d] of boxes(b)) if (t === type) return d; return null; };
  const path = (b, ...types) => types.reduce((d, t) => d && child(d, t), b);

  class Mp4 {
    constructor() { this.rest = new Uint8Array(0); this.track = null; }
    reset() { this.rest = new Uint8Array(0); }
    push(bytes, offset, out) {
      const b = join(this.rest, bytes);
      let i = 0, moof = -1;
      while (i + 8 <= b.length) {
        let size = u32(b, i);
        if (size === 1) size = i + 16 <= b.length ? u32(b, i + 8) * 2 ** 32 + u32(b, i + 12) : Infinity;
        if (size < 8) { this.bad = true; break; }
        if (i + size > b.length) break;
        const type = tag(b, i + 4), head = u32(b, i) === 1 ? 16 : 8;
        if (type === "moov") this.moov(b.subarray(i + head, i + size));
        else if (type === "moof") moof = i;
        else if (type === "mdat" && moof >= 0) { this.fragment(b, moof, i + size, offset, out); moof = -1; }
        i += size;
      }
      this.rest = b.slice(moof >= 0 ? moof : i);
    }
    moov(m) {
      this.track = null;
      const defaults = new Map();
      for (const [t, d] of boxes(m)) {
        if (t === "mvex") for (const [x, e] of boxes(d)) if (x === "trex") defaults.set(u32(e, 4), { dur: u32(e, 12), size: u32(e, 16) });
        if (t !== "trak" || this.track) continue;
        const tkhd = child(d, "tkhd"), mdia = child(d, "mdia"), hdlr = mdia && child(mdia, "hdlr"), mdhd = mdia && child(mdia, "mdhd");
        if (!tkhd || !hdlr || !mdhd || tag(hdlr, 8) !== "soun") continue;
        const stsd = path(mdia, "minf", "stbl", "stsd");
        const config = stsd && this.entry(stsd.subarray(8));
        if (!config) { this.bad = true; continue; }
        let shift = 0;
        const elst = path(d, "edts", "elst");
        if (elst && u32(elst, 4) > 0) shift = elst[0] === 1 ? u32(elst, 16) * 2 ** 32 + u32(elst, 20) : u32(elst, 12);
        if (shift === 0xffffffff || shift > 2 ** 52) shift = 0;
        this.track = { id: u32(tkhd, tkhd[0] === 1 ? 20 : 12), scale: u32(mdhd, mdhd[0] === 1 ? 20 : 12), shift, config };
      }
      if (this.track) Object.assign(this.track, defaults.get(this.track.id) || { dur: 0, size: 0 });
      this.config = this.track && this.track.config;
    }
    entry(stsd) {
      for (const [type, e] of boxes(stsd)) {
        const version = u16(e, 8), channels = u16(e, 16), rate = u16(e, 24);
        const body = e.subarray(28 + (version === 1 ? 16 : version === 2 ? 36 : 0));
        if (type === "mp4a") {
          const esds = child(body, "esds");
          const asc = esds && this.decoderInfo(esds.subarray(4));
          if (!asc || !asc.length) return null;
          return { codec: "mp4a.40." + (asc[0] >> 3), sampleRate: rate || 48000, numberOfChannels: channels || 2, description: asc };
        }
        if (type === "Opus") {
          const d = child(body, "dOps");
          if (!d) return null;
          const head = new Uint8Array(19 + (d[10] ? 2 + d[1] : 0));
          head.set([0x4f, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, 1, d[1], d[3], d[2], d[7], d[6], d[5], d[4], d[9], d[8], d[10]]);
          if (d[10]) head.set(d.subarray(11, 13 + d[1]), 19);
          return { codec: "opus", sampleRate: 48000, numberOfChannels: d[1], description: head };
        }
        return null;
      }
      return null;
    }
    // ES_Descriptor → DecoderConfigDescriptor → DecoderSpecificInfo (the AudioSpecificConfig).
    decoderInfo(b) {
      let i = 0;
      const read = () => {
        const t = b[i++];
        let n = 0, k = 0, x;
        do { x = b[i++]; n = (n << 7) | (x & 0x7f); } while (x & 0x80 && ++k < 4);
        return [t, n];
      };
      let [t] = read();
      if (t !== 3) return null;
      const flags = b[i + 2]; // after the 16-bit ES_ID
      i += 3;
      if (flags & 0x80) i += 2;
      if (flags & 0x40) i += 1 + b[i];
      if (flags & 0x20) i += 2;
      [t] = read();
      if (t !== 4 || b[i] !== 0x40) return null; // MPEG-4 audio only
      i += 13;
      const [t5, n] = read();
      return t5 === 5 ? b.slice(i, i + n) : null;
    }
    fragment(b, moof, end, offset, out) {
      const tr = this.track;
      if (!tr) return;
      for (const [t, traf] of boxes(b, moof + 8, moof + u32(b, moof))) {
        if (t !== "traf") continue;
        const tfhd = child(traf, "tfhd");
        if (!tfhd || u32(tfhd, 4) !== tr.id) continue;
        const f = u32(tfhd, 0) & 0xffffff;
        if (f & 1) { this.bad = true; return; } // absolute base offsets aren't followed
        let k = 8 + (f & 2 ? 4 : 0);
        const dDur = f & 8 ? u32(tfhd, k) : tr.dur;
        k += f & 8 ? 4 : 0;
        const dSize = f & 0x10 ? u32(tfhd, k) : tr.size;
        const tfdt = child(traf, "tfdt");
        if (!tfdt) { this.bad = true; return; }
        let time = tfdt[0] === 1 ? u32(tfdt, 4) * 2 ** 32 + u32(tfdt, 8) : u32(tfdt, 4);
        let pos = moof;
        for (const [x, run] of boxes(traf)) {
          if (x !== "trun") continue;
          const rf = u32(run, 0) & 0xffffff, count = u32(run, 4);
          let j = 8;
          if (rf & 1) { pos = moof + (u32(run, j) | 0); j += 4; }
          if (rf & 4) j += 4;
          for (let s = 0; s < count; s++) {
            const dur = rf & 0x100 ? u32(run, j) : dDur; j += rf & 0x100 ? 4 : 0;
            const size = rf & 0x200 ? u32(run, j) : dSize; j += rf & 0x200 ? 4 : 0;
            j += (rf & 0x400 ? 4 : 0) + (rf & 0x800 ? 4 : 0);
            if (pos + size > end) { this.bad = true; return; }
            out.push({ t: (time - tr.shift) / tr.scale + offset, data: b.slice(pos, pos + size) });
            pos += size;
            time += dur;
          }
        }
      }
    }
  }

  // ---- WebM / Matroska (YouTube Opus) ----
  const W = { Segment: 0x18538067, Cluster: 0x1f43b675, Tracks: 0x1654ae6b, TrackEntry: 0xae, Info: 0x1549a966, Audio: 0xe1,
    BlockGroup: 0xa0, Scale: 0x2ad7b1, Number: 0xd7, Type: 0x83, Codec: 0x86, Private: 0x63a2, Rate: 0xb5,
    Channels: 0x9f, Timecode: 0xe7, SimpleBlock: 0xa3, Block: 0xa1 };
  const MASTERS = new Set([W.Segment, W.Cluster, W.Tracks, W.TrackEntry, W.Info, W.Audio, W.BlockGroup]);
  const LEAVES = new Set([W.Scale, W.Number, W.Type, W.Codec, W.Private, W.Rate, W.Channels, W.Timecode, W.SimpleBlock, W.Block]);
  const vint = (b, i, raw) => {
    const first = b[i];
    if (first === undefined || first === 0) return null;
    const len = Math.clz32(first) - 23;
    if (i + len > b.length) return null;
    let v = raw ? first : first & (0xff >> len), ones = v === 0xff >> len;
    for (let k = 1; k < len; k++) { v = v * 256 + b[i + k]; ones = ones && b[i + k] === 0xff; }
    return { v, len, unknown: !raw && ones };
  };
  const uint = (d) => d.reduce((v, x) => v * 256 + x, 0);

  class Webm {
    constructor() { this.rest = new Uint8Array(0); this.skip = 0; this.scale = 1e6; this.tracks = []; this.cluster = 0; }
    reset() { this.rest = new Uint8Array(0); this.skip = 0; }
    push(bytes, offset, out) {
      const b = join(this.rest, bytes);
      let i = Math.min(this.skip, b.length);
      this.skip -= i;
      while (i < b.length) {
        const id = vint(b, i, true), size = id && vint(b, i + id.len, false);
        if (!size) break;
        const start = i + id.len + size.len;
        if (MASTERS.has(id.v)) {
          if (id.v === W.Tracks) this.tracks = [];
          if (id.v === W.TrackEntry) this.tracks.push({});
          i = start;
          continue;
        }
        if (size.unknown) { this.bad = true; break; }
        const end = start + size.v;
        if (!LEAVES.has(id.v)) {
          if (end > b.length) { this.skip = end - b.length; i = b.length; break; }
          i = end;
          continue;
        }
        if (end > b.length) break;
        this.leaf(id.v, b.subarray(start, end), offset, out);
        i = end;
      }
      this.rest = b.slice(i);
    }
    leaf(id, d, offset, out) {
      const t = this.tracks[this.tracks.length - 1] || {};
      if (id === W.Scale) this.scale = uint(d);
      else if (id === W.Number) t.number = uint(d);
      else if (id === W.Type) t.type = uint(d);
      else if (id === W.Codec) t.codec = String.fromCharCode(...d);
      else if (id === W.Private) t.private = d.slice();
      else if (id === W.Rate) t.rate = d.length === 4 ? new DataView(d.buffer, d.byteOffset, 4).getFloat32(0) : new DataView(d.buffer, d.byteOffset, 8).getFloat64(0);
      else if (id === W.Channels) t.channels = uint(d);
      else if (id === W.Timecode) this.cluster = uint(d);
      else this.block(d, offset, out);
    }
    get audio() { return this.tracks.find((t) => t.type === 2); }
    get config() {
      const a = this.audio;
      if (!a || !a.private) return null;
      if (a.codec === "A_OPUS") return { codec: "opus", sampleRate: a.rate || 48000, numberOfChannels: a.channels || 2, description: a.private };
      if (a.codec && a.codec.startsWith("A_AAC")) return { codec: "mp4a.40." + (a.private[0] >> 3), sampleRate: a.rate || 48000, numberOfChannels: a.channels || 2, description: a.private };
      return null;
    }
    block(d, offset, out) {
      const a = this.audio, n = vint(d, 0, false);
      if (!a || !n || n.v !== a.number) return;
      if (d[n.len + 2] & 0x06) { this.bad = true; return; } // laced blocks aren't split
      const rel = (u16(d, n.len) << 16) >> 16;
      out.push({ t: ((this.cluster + rel) * this.scale) / 1e9 + offset, data: d.slice(n.len + 3) });
    }
  }

  // ---- mirrored SourceBuffers ----
  const feeds = new WeakMap(); // MediaSource -> Set<Feed>
  const lowerBound = (a, t) => {
    let lo = 0, hi = a.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (a[mid].t < t) lo = mid + 1; else hi = mid; }
    return lo;
  };

  const sameBytes = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
  const sameConfig = (a, b) => !!a && !!b && a.codec === b.codec && a.sampleRate === b.sampleRate &&
    a.numberOfChannels === b.numberOfChannels && sameBytes(a.description, b.description);

  // One audio SourceBuffer's packets, [{t, data, config}] in presentation order. An append's packets
  // join once the SourceBuffer has accepted it, clipped to its append window.
  class Feed {
    constructor(type) { this.frames = []; this.pending = null; this.current = null; this.changed = Infinity; this.retype(type); }
    retype(type) { this.reader = /webm|matroska/i.test(type) ? new Webm() : /mp4/i.test(type) ? new Mp4() : null; }
    get config() { return this.reader && !this.reader.bad ? this.current : null; }
    parse(bytes, offset, start, end) {
      this.pending = null;
      if (!this.reader || this.reader.bad) return;
      const batch = [];
      this.reader.push(bytes, offset, batch);
      const config = this.reader.config;
      if (!sameConfig(config, this.current)) this.current = config;
      for (const f of batch) f.config = this.current;
      this.pending = batch.filter((f) => f.t >= start && f.t < end);
    }
    commit() {
      const batch = this.pending;
      this.pending = null;
      if (!batch || !batch.length) return;
      const a = this.frames, first = batch[0].t;
      if (!a.length || a[a.length - 1].t < first - 1e-4) for (const f of batch) a.push(f);
      else {
        const lo = lowerBound(a, first - 1e-4), hi = lowerBound(a, batch[batch.length - 1].t + 1e-4);
        this.frames = a.slice(0, lo).concat(batch, a.slice(hi));
        this.changed = Math.min(this.changed, first);
      }
      const newest = this.frames[this.frames.length - 1].t;
      if (newest - this.frames[0].t > SPAN) this.frames = this.frames.slice(lowerBound(this.frames, newest - SPAN));
    }
    remove(start, end) {
      this.frames = this.frames.filter((f) => f.t < start || f.t >= end);
      this.changed = Math.min(this.changed, start);
    }
  }

  const wrap = (proto, name, make) => {
    const original = proto[name];
    if (typeof original === "function") proto[name] = make(original);
  };
  const S = SourceBuffer.prototype; // ManagedSourceBuffer inherits these
  const getter = (name) => Object.getOwnPropertyDescriptor(S, name).get;
  const timestampOffset = getter("timestampOffset"), sbMode = getter("mode");
  const windowStart = getter("appendWindowStart"), windowEnd = getter("appendWindowEnd");
  const mirrors = new WeakMap(); // SourceBuffer -> Feed

  for (const C of sourceClasses) {
    wrap(C.prototype, "addSourceBuffer", (add) => function (type) {
      const sb = add.call(this, type);
      const codecs = (/codecs\s*=\s*"?([^";]*)/i.exec(type) || [])[1] || "";
      if (/^audio\//i.test(type) || AUDIO.test(codecs)) {
        const feed = new Feed(type);
        mirrors.set(sb, feed);
        if (!feeds.has(this)) feeds.set(this, new Set());
        feeds.get(this).add(feed);
        // Registered before the page's own listeners, so packets are in place when it reacts.
        sb.addEventListener("updateend", () => feed.commit());
        sb.addEventListener("error", () => { feed.pending = null; feed.reader?.reset(); }); // WebKit resets its parser too
      }
      return sb;
    });
    wrap(C.prototype, "removeSourceBuffer", (remove) => function (sb) {
      const feed = mirrors.get(sb);
      remove.call(this, sb);
      if (feed) { feeds.get(this)?.delete(feed); feed.dead = true; }
    });
  }
  wrap(S, "appendBuffer", (append) => function (data) {
    const result = append.call(this, data);
    const feed = mirrors.get(this);
    if (feed && !off) {
      try {
        if (sbMode.call(this) !== "segments") feed.reader = null; // sequence mode rewrites timestamps
        else feed.parse(data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength),
          timestampOffset.call(this), windowStart.call(this), windowEnd.call(this));
      } catch (e) { feed.reader = null; }
    }
    return result;
  });
  wrap(S, "abort", (abort) => function () {
    abort.call(this);
    const feed = mirrors.get(this);
    if (feed) { feed.pending = null; feed.reader?.reset(); }
  });
  wrap(S, "remove", (remove) => function (start, end) {
    remove.call(this, start, end);
    mirrors.get(this)?.remove(start, end);
  });
  wrap(S, "changeType", (change) => function (type) {
    change.call(this, type);
    mirrors.get(this)?.retype(type);
  });
  // Pages revoke the object URL as soon as the element has it, so the mapping outlives revocation.
  const urls = new Map(); // object URL -> WeakRef<MediaSource>
  wrap(URL, "createObjectURL", (create) => function (obj) {
    const url = create.call(this, obj);
    if (sourceClasses.some((C) => obj instanceof C)) {
      if (urls.size > 32) for (const [k, ref] of urls) if (!ref.deref()) urls.delete(k);
      urls.set(url, new WeakRef(obj));
    }
    return url;
  });
  const sourceFor = (el) => (el.srcObject && feeds.has(el.srcObject) ? el.srcObject : urls.get(el.currentSrc)?.deref());

  // ---- playback ----
  let ctx = null;
  let off = false; // turned off in settings while the page is open
  let timer = 0;
  const players = new Set(); // elements playing, or handing back to native audio
  const byElement = new WeakMap();
  const support = new Map(); // decoder config key -> supported

  class Player {
    constructor(el) {
      this.el = el;
      this.feed = null;
      this.sources = new Set();
      this.live = false; // this player owns the element's audio: its track is off, or about to be
      this.owned = []; // tracks switched off here
      this.takeover = 0;
      this.handoff = 0;
      this.reset();
      this.gain = ctx.createGain();
      this.compressor = new DynamicsCompressorNode(ctx, { threshold: -50, knee: 40, ratio: 12, attack: 0, release: 0.25 });
      this.gain.connect(this.compressor);
      this.volume();
      const tracks = el.audioTracks;
      if (tracks) {
        // The page re-enabling or switching a track takes the audio back; a track appearing for the
        // same stream (new init segment) stays with the copy.
        tracks.addEventListener("change", () => {
          if (this.live && !this.takeover && Array.from(tracks).some((t) => t.enabled)) { this.owned = []; this.native(); }
        });
        tracks.addEventListener("addtrack", (e) => {
          if (this.live && !this.takeover && e.track.enabled) { e.track.enabled = false; this.owned.push(e.track); }
        });
      }
    }
    volume() {
      if (this.handoff) return;
      const g = this.gain.gain;
      g.cancelScheduledValues(0);
      g.value = this.el.muted ? 0 : this.el.volume;
    }
    reset() {
      this.gen = (this.gen || 0) + 1;
      for (const s of this.sources) { s.onended = null; s.stop(); s.disconnect(); }
      this.sources.clear();
      for (const p of this.parts || []) p.close();
      this.parts = [];
      this.queue = []; // scheduled spans {c: context time, m: media time, rate, d: duration}
      this.next = null;
      this.cursor = null;
      this.config = null;
      this.trimRate = 1;
      this.dryAt = 0;
    }
    usable() {
      const el = this.el;
      if (!this.feed || this.feed.dead) {
        const set = feeds.get(sourceFor(el));
        this.feed = set && set.size === 1 ? [...set][0] : null; // one audio SourceBuffer only
      }
      const config = this.feed && this.feed.config;
      return !!config && this.supported(config) && !this.failed && !el.mediaKeys && !el.webkitKeys &&
        el.playbackRate === 1 && ctx.state === "running" && !!el.audioTracks &&
        (this.live || Array.from(el.audioTracks).filter((t) => t.enabled).length === 1) && !off;
    }
    supported(config) {
      const key = config.codec + "/" + config.sampleRate + "/" + config.numberOfChannels;
      if (!support.has(key)) {
        support.set(key, false);
        AudioDecoder.isConfigSupported(config).then((r) => support.set(key, !!r.supported), () => {});
      }
      return support.get(key);
    }
    // Context time currently leaving the speakers.
    heard() {
      const ts = ctx.getOutputTimestamp ? ctx.getOutputTimestamp() : {};
      if (!ts.contextTime) return ctx.currentTime - (ctx.baseLatency || 0) - (ctx.outputLatency || 0);
      return ts.contextTime + (performance.now() - ts.performanceTime) / 1000;
    }
    tick() {
      const el = this.el;
      if (this.handoff) return;
      // Short pauses keep the element's track off so playback resumes straight into the copy.
      if (el.paused && !el.ended && this.live && performance.now() - this.pausedAt < PAUSE_GRACE) return;
      if (el.paused || el.ended || !this.usable()) return this.native();
      if (el.seeking || el.readyState < 3) { this.reset(); return; }
      // Live but nothing scheduled for a second (decoder stalled, data missing): give the audio back.
      if (this.live && this.next === null) {
        if (!this.dryAt) this.dryAt = performance.now();
        else if (performance.now() - this.dryAt > 1000) return this.native();
      }
      const now = el.currentTime;
      // Packets already handed to the decoder were replaced or removed: start over from the playhead.
      if (this.feed.changed !== Infinity) {
        if (this.cursor !== null && this.feed.changed <= this.cursor) this.reset();
        this.feed.changed = Infinity;
      }
      if (this.next !== null) {
        const heard = this.heard() - LOOKAHEAD;
        while (this.queue.length > 1 && this.queue[0].c + this.queue[0].d <= heard) this.queue.shift();
        const span = this.queue[0];
        if (span && heard >= span.c && heard < span.c + span.d) {
          const err = span.m + (heard - span.c) * span.rate - now; // > 0: the copy runs ahead of the video
          this.err = err;
          if (Math.abs(err) > LATE) this.reset();
          else this.trimRate = Math.abs(err) < 0.004 ? 1 : 1 - Math.max(-0.002, Math.min(0.002, err / 4));
        } else if (this.live && this.next < heard) { this.native(); return; } // the copy ran dry
      }
      this.decode(now);
      this.flush();
    }
    decode(now) {
      const frames = this.feed.frames;
      if (this.cursor === null) {
        const start = lowerBound(frames, now - PREROLL);
        if (start >= frames.length || frames[start].t > now + 0.05) { if (this.live) this.native(); return; }
        this.cursor = frames[start].t - 1e-6;
      }
      for (let k = lowerBound(frames, this.cursor + 1e-6); k < frames.length && frames[k].t < now + AHEAD; k++) {
        const f = frames[k];
        if (f.config !== this.config || !this.decoder) this.open(f.config);
        this.decoder.decode(new EncodedAudioChunk({ type: "key", timestamp: Math.round(f.t * 1e6), data: f.data }));
        this.cursor = f.t;
      }
    }
    open(config) {
      if (!this.decoder || this.decoder.state === "closed") {
        this.decoder = new AudioDecoder({
          output: (data) => {
            if (this.decodeGen !== this.gen) { data.close(); return; }
            this.parts.push(data);
            if (this.parts.length >= 8) this.flush();
          },
          error: () => { this.failed = true; this.native(); },
        });
      } else if (this.decoder.state === "configured") this.decoder.reset();
      this.decodeGen = this.gen;
      this.config = config;
      this.decoder.configure(config);
    }
    flush() {
      const parts = this.parts;
      if (!parts.length) return;
      this.parts = [];
      const media = parts[0].timestamp / 1e6, channels = parts[0].numberOfChannels;
      const buffer = ctx.createBuffer(channels, parts.reduce((n, p) => n + p.numberOfFrames, 0), parts[0].sampleRate);
      let at = 0;
      for (const p of parts) {
        for (let c = 0; c < channels; c++) {
          p.copyTo(buffer.getChannelData(c).subarray(at, at + p.numberOfFrames), { planeIndex: Math.min(c, p.numberOfChannels - 1), format: "f32-planar" });
        }
        at += p.numberOfFrames;
        p.close();
      }
      this.place(buffer, media);
    }
    place(buffer, media) {
      const soonest = ctx.currentTime + 0.02;
      let when = this.next === null
        ? this.heard() + (media - this.el.currentTime) - LOOKAHEAD
        : this.next + (media - this.nextMedia) / this.trimRate;
      let offset = 0;
      if (when < soonest) { offset = (soonest - when) * this.trimRate; when = soonest; }
      if (offset >= buffer.duration) return;
      const src = ctx.createBufferSource();
      src.buffer = buffer;
      src.playbackRate.value = this.trimRate;
      src.connect(this.gain);
      src.onended = () => { this.sources.delete(src); src.disconnect(); };
      src.start(when, offset);
      this.sources.add(src);
      const d = (buffer.duration - offset) / this.trimRate;
      this.queue.push({ c: when, m: media + offset, rate: this.trimRate, d });
      this.next = when + d;
      this.nextMedia = media + buffer.duration;
      if (!this.live) this.silence(when);
    }
    // Switch the element's (single enabled) audio track off as the copy becomes audible.
    silence(when) {
      this.live = true;
      this.takeover = setTimeout(() => {
        this.takeover = 0;
        const on = Array.from(this.el.audioTracks).filter((t) => t.enabled);
        if (on.length !== 1) { this.native(); return; }
        this.owned = on;
        on[0].enabled = false;
      }, Math.max(0, (when - ctx.currentTime) * 1000));
    }
    // Native audio back. While its renderer restarts (~0.4 s) the copy fades out underneath.
    native() {
      if (!this.live) { if (!this.handoff) this.reset(); return; }
      this.live = false;
      clearTimeout(this.takeover);
      this.takeover = 0;
      for (const t of this.owned) t.enabled = true;
      this.owned = [];
      this.gen++; // late decoder output must not schedule (and take the track) again
      if (this.el.paused || !this.sources.size) { this.reset(); return; }
      this.gain.gain.setTargetAtTime(0, ctx.currentTime, 0.15);
      this.handoff = setTimeout(() => { this.handoff = 0; this.reset(); this.volume(); }, 500);
    }
  }

  const tickAll = () => {
    for (const p of players) {
      try { p.tick(); } catch (e) { p.failed = true; p.native(); }
      if ((p.el.paused || off) && !p.live && !p.handoff) { players.delete(p); p.compressor.disconnect(); }
    }
    if (!players.size) { clearInterval(timer); timer = 0; if (ctx.state === "running") ctx.suspend(); }
  };
  const attach = (el) => {
    if (off || !feeds.has(sourceFor(el))) return;
    if (!ctx) ctx = new AudioContext({ latencyHint: "playback" });
    if (ctx.state !== "running") ctx.resume().catch(() => {});
    let p = byElement.get(el);
    if (!p) byElement.set(el, (p = new Player(el)));
    if (!players.has(p)) { players.add(p); p.compressor.connect(ctx.destination); }
    if (!timer) timer = setInterval(tickAll, 250);
  };
  const onMedia = (e) => {
    const el = e.target;
    if (!(el instanceof HTMLMediaElement)) return;
    if (e.type === "playing") attach(el);
    const p = byElement.get(el);
    if (!p) return;
    if (e.type === "volumechange") p.volume();
    else if (e.type === "emptied") { p.native(); p.feed = null; p.failed = false; }
    else if (e.type === "pause") { if (p.live) { p.reset(); p.pausedAt = performance.now(); } else p.native(); }
    else if (e.type === "ratechange" && el.playbackRate !== 1) p.native();
    else if (e.type === "seeking" || e.type === "waiting") { if (p.live) p.reset(); }
    else if (players.has(p)) p.tick();
  };
  for (const type of ["playing", "pause", "seeking", "seeked", "waiting", "volumechange", "ratechange", "emptied"]) {
    window.addEventListener(type, onMedia, true);
  }
  // With autoplay blocked, WebKit starts an AudioContext only within a user activation.
  const activate = () => { if (ctx && ctx.state === "suspended" && players.size) ctx.resume().catch(() => {}); };
  for (const type of ["pointerdown", "keydown"]) window.addEventListener(type, activate, true);
  // Sent by angl when Night audio is switched off: native audio returns without a reload.
  window.addEventListener("anglnightaudiooff", () => { off = true; for (const p of players) p.native(); }, { once: true });
})();
