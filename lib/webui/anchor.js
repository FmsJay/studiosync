// Where a mark drawn over a view of the song sits, so it stays put however the view scrolls or zooms: screen share's notes (call.js, rt-share)
// and the drawing layer over the Project, Mixer and History pages and the phone's Project view (draw.js, rt-draw) share this one piece.
// A view, in the share's form: { t0, t1 (seconds at its left and right edges), aw, ah (its size in its own pixels), crop ({ x, y, w, h } of
// the picture, 0-1, where the timeline is: null when it isn't known), tracks ([[id, y, h, name]]: y and h in the view's own pixels, from its
// top, scrolled as shown) }. A place in the picture is 0-1 across and down. Pure. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const okNum = (x, lim) => Number.isFinite(x) && Math.abs(x) <= lim;
  // An anchor: { t, k, d } (time in s, track id, place down that track 0-1) where the timeline is known, else { fx, fy } of the picture.
  // (k up to 80 characters: the drawings' tracks go by mirror sync's own oids, "T-JAMES-20261120...")
  function anchorOk(a) {
    if (!a || typeof a !== 'object') return false;
    if ('t' in a) return okNum(a.t, 1e7) && typeof a.k === 'string' && a.k.length <= 80 && okNum(a.d, 1000);
    return Number.isFinite(a.fx) && Number.isFinite(a.fy) && a.fx >= 0 && a.fx <= 1 && a.fy >= 0 && a.fy <= 1;
  }
  // anchor -> place in the picture (0-1), or null (its track isn't in the view, or the timeline isn't known).
  function toPic(v, a) {
    if (!a) return null;
    if (!('t' in a)) return { x: a.fx, y: a.fy };
    if (!v || !v.crop) return null;
    const tr = v.tracks.find((t) => t[0] === a.k);
    if (!tr) return null;
    const ax = (a.t - v.t0) / (v.t1 - v.t0) * v.aw, ay = tr[1] + a.d * tr[2];
    return { x: v.crop.x + ax / v.aw * v.crop.w, y: v.crop.y + ay / v.ah * v.crop.h };
  }
  // place in the picture (0-1) -> anchor: time + track inside the arrange view (the track at that height, or the nearest), else the picture.
  function fromPic(v, x, y) {
    if (v && v.crop && v.tracks.length) {
      const ax = (x - v.crop.x) / v.crop.w * v.aw, ay = (y - v.crop.y) / v.crop.h * v.ah;
      if (ax >= 0 && ax <= v.aw && ay >= 0 && ay <= v.ah) {
        let tr = v.tracks[0];
        for (const t of v.tracks) if (t[1] <= ay) tr = t;
        return { t: v.t0 + ax / v.aw * (v.t1 - v.t0), k: tr[0], d: Math.max(-1000, Math.min(1000, (ay - tr[1]) / tr[2])) };
      }
    }
    return { fx: Math.max(0, Math.min(1, x)), fy: Math.max(0, Math.min(1, y)) };
  }
  globalThis.ssAnchor = { okNum, anchorOk, toPic, fromPic };
})();
