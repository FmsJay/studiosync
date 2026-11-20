// Video and picture items drawn as a strip of frames on the Project page (daw.js) and the phone's Project view (phonedaw.js). Live sync names
// each such item's file by an id the web server hands out (lib/video.lua: only the studio's shared media), with where in the file the item
// starts (o, seconds) and how fast it plays (r). The frames are read here: one hidden <video> per file seeks to each wanted moment (the server
// answers byte ranges, so only what's needed comes, extension 1.0.25) and the frame is kept as a small canvas; a picture is one <img>.
// Thumbnails sit on a grid of whole steps in the file (a power of two seconds), so zooming and scrolling reuse the frames already read.
// A file the browser can't play (an .mkv in Safari, say) simply shows no frames. GPL-3.0-or-later. (James, rt-video2)
'use strict';
(() => {
  const FH = 54;            // a kept frame's height in pixels (drawn smaller or larger as the lane is)
  const MAX_FRAMES = 400;   // frames kept in all, the least recently drawn let go
  const MAX_QUEUE = 48;     // moments waiting per file (the ones drawn last win)
  const srcs = new Map();   // id -> { kind, el, ready, failed, ar, dur, queue: [], busy }
  const frames = new Map(); // id@t -> canvas (Map order: least recently drawn first)
  const hooks = new Set();
  let poked = false;
  function poke() {
    if (poked) return;
    poked = true;
    requestAnimationFrame(() => { poked = false; for (const f of hooks) f(); });
  }
  function keep(key, c) {
    frames.delete(key); frames.set(key, c);
    while (frames.size > MAX_FRAMES) frames.delete(frames.keys().next().value);
  }
  function grab(s, el) {
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(FH * s.ar)); c.height = FH;
    try { c.getContext('2d').drawImage(el, 0, 0, c.width, c.height); } catch (e) { return null; }
    return c;
  }
  function pump(id, s) {
    if (s.busy != null || !s.ready || s.failed || !s.queue.length) return;
    s.busy = s.queue.shift();
    let t = Math.max(0, Math.min(s.busy, (s.dur || s.busy) - 0.05));
    // (always a real seek: at the time it's at already, just after its metadata, there's no frame decoded yet and a blank one was kept)
    if (Math.abs(s.el.currentTime - t) < 1e-3) t += 0.002;
    s.el.currentTime = t;
  }
  function source(id, kind) {
    let s = srcs.get(id);
    if (s) return s;
    s = { kind, ready: false, failed: false, ar: 16 / 9, dur: 0, queue: [], busy: null };
    const url = 'api/file?id=' + encodeURIComponent(id);
    if (kind === 'i') {
      s.el = new Image();
      s.el.decoding = 'async';
      s.el.onload = () => { s.ready = true; s.ar = s.el.naturalWidth / Math.max(1, s.el.naturalHeight) || s.ar; const c = grab(s, s.el); if (c) keep(id + '@i', c); poke(); };
      s.el.onerror = () => { s.failed = true; };
      s.el.src = url;
    } else {
      const v = document.createElement('video');
      v.muted = true; v.playsInline = true; v.preload = 'metadata';
      v.addEventListener('loadedmetadata', () => {
        s.ar = v.videoWidth / Math.max(1, v.videoHeight) || s.ar; s.dur = isFinite(v.duration) ? v.duration : 0; s.ready = true; pump(id, s);
      });
      v.addEventListener('seeked', () => {
        const t = s.busy;
        s.busy = null;
        if (t != null) { const c = grab(s, v); if (c) { keep(id + '@' + t, c); poke(); } }
        pump(id, s);
      });
      v.addEventListener('error', () => { s.failed = true; s.busy = null; });
      v.src = url;
      s.el = v;
    }
    srcs.set(id, s);
    return s;
  }
  // The step between frames, in seconds of the file: the smallest power of two whose frame is at least `px` wide on screen.
  function stepFor(secPerPx, px, rate) {
    const want = secPerPx * px * Math.abs(rate || 1);
    let st = 1 / 8;
    while (st < want && st < 4096) st *= 2;
    return st;
  }
  // Draw an item's frames into the box x..x+w (the whole item at this zoom), y..y+h, only between xa and xz (what's on screen).
  // -> true when it drew (or will, once frames arrive): the caller draws its waveform fainter on top.
  function draw(g, it, x, y, w, h, xa, xz) {
    const v = it && it.v;
    if (!v || typeof v.id !== 'string' || !/^[0-9a-f]{1,32}$/.test(v.id) || !(it.l > 0) || w < 2 || h < 6) return false;
    const s = source(v.id, v.k === 'i' ? 'i' : 'v');
    if (s.failed) return false;
    const fw = Math.max(8, h * s.ar);
    g.save();
    g.beginPath(); g.rect(xa, y, Math.max(0, xz - xa), h); g.clip();
    g.globalAlpha = 0.85;
    if (s.kind === 'i') {
      const c = frames.get(v.id + '@i');
      if (c) { keep(v.id + '@i', c); for (let px = x; px < Math.min(x + w, xz); px += fw) if (px + fw >= xa) g.drawImage(c, px, y, fw, h); }
    } else {
      const pps = w / it.l, rate = v.r > 0 ? v.r : 1, o = +v.o || 0;
      const st = stepFor(1 / pps, fw, rate);
      const t0 = o + Math.max(0, (xa - x) / pps) * rate, t1 = o + Math.min(it.l, (xz - x) / pps) * rate;
      const want = [];
      for (let t = Math.floor(t0 / st) * st; t <= t1; t += st) {
        const key = v.id + '@' + t, c = frames.get(key);
        const px = x + (t - o) / rate * pps;
        if (c) { keep(key, c); g.drawImage(c, px, y, st / rate * pps, h); }
        else want.push(t);
      }
      if (want.length) {
        s.queue = want.concat(s.queue.filter((t) => !want.includes(t))).slice(0, MAX_QUEUE);
        pump(v.id, s);
      }
    }
    g.restore();
    return true;
  }
  // onFrame: called (once a frame) when new frames have come, so the page draws again.
  window.ssVideo = { draw, onFrame: (f) => hooks.add(f), _state: () => ({ files: srcs.size, frames: frames.size }) };
})();
