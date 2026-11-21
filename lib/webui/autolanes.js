// StudioSync's automation lanes: the shared DAW view, stage 3 (docs/realtime-roadmap.md). A tap on a track's name (an "A" there: it has
// envelopes) opens its envelopes as lanes under it on the Project page's arrange view (daw.js draws them where X.extra makes room). Drawn
// from the dawenv topic lib/dawmidi.lua publishes while this page says which tracks are open (every 10 s); point edits (add, move, delete)
// go to Live sync as actions, which checks them as REAPER's own edits to that track's automation are (the track's claim, Driver only, a
// bandmate's hold) and applies them there in one undo point; the normal sync sends them on. Times snap as REAPER's do (only while its
// snapping is on). A refusal snaps the point back with the reason (stage 2's dawedit topic). Mouse: drag a point, double-click to add one,
// Delete removes the selected one, right-click for a menu. Phones: tap a point to select it, then drag it (anything else pans), double-tap
// to add one, long press for a menu. Text goes in as text, never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const ssDaw = window.ssDaw;
  if (!ssDaw) return;
  const X = ssDaw.X;
  const arr = (x) => (Array.isArray(x) ? x : []);
  const clamp = (v, a, z) => Math.max(a, Math.min(z, v));
  const MAX = 8;   // tracks with their automation open at once (lib/dawmidi.lua's LANES_MAX)
  const open = []; // the open tracks' places, oldest first
  const envs = {}; // a track's place -> its envelopes as last published: { i (REAPER's index), n, k (kind), f (value labels), p (t, v 0..1, shape) }
  let sel = null;  // the selected point: { i (track), e (envelope), t }
  let ovr = null;  // a point drawn where it's going: { i, e, n (-1: a new one), t, v, sh, gone }
  let pend = null; // the edit sent and not back yet: { id, until, ok }
  let grab = null, seq = 0;
  const coarse = () => matchMedia('(pointer: coarse)').matches;
  const EH = () => (coarse() ? 44 : 34);

  // ---- talking to Live sync ----------------------------------------------------------------------------------------------------------
  function look() { if (ssDaw.onSong() && !document.hidden) ssDaw.act({ look: { env: open.slice() } }).catch(() => {}); }
  setInterval(() => { if (open.length) look(); }, 10000);
  document.addEventListener('visibilitychange', () => { if (open.length) look(); });
  function edit(o) {
    const id = 'a' + Date.now().toString(36) + (seq++);
    pend = { id, until: performance.now() + 4000 };
    ssDaw.act({ auto: Object.assign({ id }, o) }).catch(() => snapBack('couldn’t reach Live sync'));
  }
  function snapBack(why) {
    pend = null; ovr = null;
    if (why) ssDaw.say('Not changed: ' + why + '.');
    ssDaw.redraw();
  }
  setInterval(() => { if (pend && performance.now() > pend.until) { pend = null; ovr = null; ssDaw.redraw(); } }, 1000);
  function take(t, seed) {
    if (!seed && t.dawedit && pend && t.dawedit.id === pend.id) { if (t.dawedit.why) { snapBack(t.dawedit.why); return; } pend.ok = true; }
    if (t.dawenv) {
      for (const l of arr(t.dawenv.lanes)) envs[l.lane] = arr(l.env); // (kept for closed tracks too: reopening an unchanged one brings nothing new)
      if (pend && pend.ok) { pend = null; ovr = null; } // (the change is back)
      if (open.length) ssDaw.redraw();
    }
  }
  addEventListener('ss-state', (e) => take((e.detail || {}).topics || {}, false));
  fetch('api/state').then((r) => r.json()).then((s) => take(s.topics || {}, true)).catch(() => {});

  // ---- daw.js's hooks: room under each open track, opening and closing, drawing ----------------------------------------------------------
  X.isOpen = (i) => open.includes(i);
  X.autoClear = () => { if (sel) { sel = null; ssDaw.redraw(); } }; // (daw.js: an item or marker was selected, so Delete is its)
  X.extra = (i) => (open.includes(i) ? Math.max(1, arr(envs[i]).length) * EH() : 0);
  X.header = (i) => {
    const tr = ssDaw.head && ssDaw.head.tracks[i], j = open.indexOf(i);
    if (j >= 0) open.splice(j, 1);
    else if (tr && tr.e) { open.push(i); if (open.length > MAX) open.shift(); }
    else { ssDaw.say((tr && tr.n ? tr.n : 'That track') + ' has no automation yet: add an envelope in REAPER first.'); return; }
    if (sel && !open.includes(sel.i)) sel = null;
    look();
    ssDaw.redraw();
  };
  function pointsOf(i, e) { // as published: { n, t, v, sh }
    const env = arr(envs[i])[e], p = arr(env && env.p), out = [];
    for (let j = 0, n = 0; j + 2 < p.length; j += 3, n++) out.push({ n, t: p[j], v: p[j + 1], sh: p[j + 2] });
    return out;
  }
  function shown(i, e) { // with one being dragged or just sent where it's going
    let ps = pointsOf(i, e);
    if (ovr && ovr.i === i && ovr.e === e) {
      ps = ps.filter((x) => x.n !== ovr.n);
      if (!ovr.gone) ps.push({ n: ovr.n, t: ovr.t, v: ovr.v, sh: ovr.sh || 0, ovr: true });
      ps.sort((a, z) => a.t - z.t);
    }
    return ps;
  }
  function label(env, v) { const f = arr(env.f); return f.length ? f[Math.round(clamp(v, 0, 1) * (f.length - 1))] || '' : ''; }
  const isSel = (i, e, p) => !!(sel && sel.i === i && sel.e === e && Math.abs(sel.t - p.t) < 0.002);
  X.drawAuto = (g, i, y, part) => {
    const v = ssDaw.view(), C = ssDaw.colours(), list = arr(envs[i]), eh = EH(), tr = (ssDaw.head && ssDaw.head.tracks[i]) || {};
    const col = tr.c || C.accent;
    g.font = '11px system-ui, sans-serif';
    if (!list.length) {
      if (part === 'body') { g.fillStyle = C.dim; g.fillText('Loading automation…', v.HEAD + 8, y + eh / 2 + 4); }
      return;
    }
    list.forEach((env, e) => {
      const top = y + e * eh;
      if (top > v.H || top + eh < v.TOP) return;
      const yv = (val) => top + 3 + (1 - val) * (eh - 6), ps = shown(i, e);
      if (part === 'head') {
        g.fillStyle = col; g.globalAlpha = 0.4; g.fillRect(0, top + 1, 4, eh - 2); g.globalAlpha = 1;
        g.save(); g.beginPath(); g.rect(8, top, v.HEAD - 12, eh); g.clip();
        g.fillStyle = C.dim; g.fillText(env.n || 'Envelope', 10, top + 13);
        const s = ps.find((p) => isSel(i, e, p));
        if (s && eh >= 30) { g.fillStyle = C.text; g.fillText(label(env, s.v), 10, top + 27); }
        g.restore();
        g.fillStyle = C.line; g.fillRect(0, top + eh - 1, v.HEAD, 1);
        return;
      }
      g.fillStyle = C.panel; g.globalAlpha = 0.35; g.fillRect(v.HEAD, top, v.W - v.HEAD, eh); g.globalAlpha = 1;
      g.fillStyle = C.line; g.fillRect(v.HEAD, top + eh - 1, v.W - v.HEAD, 1);
      if (!ps.length) {
        g.fillStyle = C.dim;
        g.fillText('No points: ' + (coarse() ? 'double-tap' : 'double-click') + ' to add one', v.HEAD + 8, top + eh / 2 + 4);
        return;
      }
      // the line: flat before the first point and after the last; a square point holds until the next (other shapes drawn straight)
      g.strokeStyle = col; g.lineWidth = 1.5; g.beginPath();
      g.moveTo(v.HEAD, yv(ps[0].v));
      ps.forEach((p, j) => {
        const x = ssDaw.xOf(p.t);
        if (j > 0 && ps[j - 1].sh === 1) g.lineTo(x, yv(ps[j - 1].v));
        g.lineTo(x, yv(p.v));
      });
      g.lineTo(v.W, yv(ps[ps.length - 1].v));
      g.stroke(); g.lineWidth = 1;
      for (const p of ps) {
        const x = ssDaw.xOf(p.t);
        if (x < v.HEAD - 6 || x > v.W + 6) continue;
        const on = isSel(i, e, p) || p.ovr;
        g.fillStyle = on ? C.accent : col;
        g.beginPath(); g.arc(x, yv(p.v), on ? 5 : coarse() ? 4 : 3, 0, Math.PI * 2); g.fill();
        if (on) { g.strokeStyle = C.text; g.stroke(); }
      }
    });
  };

  // ---- what's under a point ----------------------------------------------------------------------------------------------------------
  function laneAt(x, y) {
    const v = ssDaw.view(), h = ssDaw.head;
    if (!h || y < v.TOP || x < v.HEAD) return null;
    const i = ssDaw.trackAt(y);
    if (i < 0 || i >= h.tracks.length || !open.includes(i)) return null;
    const y0 = ssDaw.laneY(i) + v.LANE, list = arr(envs[i]), e = Math.floor((y - y0) / EH());
    if (y < y0 || e < 0 || e >= list.length) return null;
    return { i, e, env: list[e], top: y0 + e * EH() };
  }
  const valY = (L, val) => L.top + 3 + (1 - val) * (EH() - 6);
  function valAt(L, y) {
    const v = clamp(1 - (y - L.top - 3) / (EH() - 6), 0, 1);
    return L.env.k === 'mute' ? (v >= 0.5 ? 1 : 0) : Math.round(v * 10000) / 10000;
  }
  function pointAt(L, x, y, touch) {
    let best = null, bd = touch ? 16 : 8;
    for (const p of shown(L.i, L.e)) {
      if (p.ovr) continue;
      const d = Math.hypot(ssDaw.xOf(p.t) - x, valY(L, p.v) - y);
      if (d < bd) { bd = d; best = p; }
    }
    return best;
  }

  // ---- edits ---------------------------------------------------------------------------------------------------------------------------
  const named = (L) => ({ lane: L.i, e: L.env.i, name: L.env.n });
  function addPoint(L, t, v) {
    ovr = { i: L.i, e: L.e, n: -1, t, v, sh: L.env.k === 'mute' ? 1 : 0 };
    sel = { i: L.i, e: L.e, t };
    edit(Object.assign({ op: 'add', t, v }, named(L)));
    ssDaw.redraw();
  }
  function delPoint(L, p) {
    ovr = { i: L.i, e: L.e, n: p.n, gone: true };
    sel = null;
    edit(Object.assign({ op: 'delete', n: p.n, t: p.t }, named(L)));
    ssDaw.redraw();
  }

  // ---- the pointer, from daw.js's own handlers -------------------------------------------------------------------------------------------
  X.autoDown = (e, touch) => {
    const L = laneAt(e.offsetX, e.offsetY);
    const p = L && pointAt(L, e.offsetX, e.offsetY, touch);
    if (!p || (touch && !isSel(L.i, L.e, p))) return false; // (a phone: only the selected point moves; anything else pans)
    sel = { i: L.i, e: L.e, t: p.t };
    grab = { L, p };
    ssDaw.redraw();
    return true;
  };
  X.autoMove = (e) => {
    if (!grab) return;
    const { L, p } = grab;
    ovr = { i: L.i, e: L.e, n: p.n, t: ssDaw.snapT(ssDaw.timeAt(e.offsetX)), v: valAt(L, e.offsetY), sh: p.sh };
    ssDaw.redraw();
  };
  X.autoUp = (e, ok) => {
    const g = grab;
    grab = null;
    if (!g || !ok || !ovr || (Math.abs(ovr.t - g.p.t) < 1e-4 && Math.abs(ovr.v - g.p.v) < 1e-4)) { ovr = null; ssDaw.redraw(); return; }
    sel = { i: g.L.i, e: g.L.e, t: ovr.t };
    edit(Object.assign({ op: 'move', n: g.p.n, t: g.p.t, to: ovr.t, v: ovr.v }, named(g.L)));
    ssDaw.redraw();
  };
  X.autoTap = (x, y, touch) => {
    grab = null;
    const L = laneAt(x, y);
    if (!L) return false;
    const p = pointAt(L, x, y, touch);
    sel = p ? { i: L.i, e: L.e, t: p.t } : null;
    if (p) ssDaw.say(L.env.n + ': ' + label(L.env, p.v) + ' at ' + ssDaw.where(p.t));
    ssDaw.redraw();
    return true;
  };
  X.autoAdd = (x, y) => {
    const L = laneAt(x, y);
    if (!L) return false;
    if (!pointAt(L, x, y, coarse())) addPoint(L, ssDaw.snapT(ssDaw.timeAt(x)), valAt(L, y));
    return true;
  };
  X.autoMenu = (x, y, add) => {
    const L = laneAt(x, y);
    if (!L) return false;
    const p = pointAt(L, x, y, true);
    if (p) {
      sel = { i: L.i, e: L.e, t: p.t };
      add('Delete point (' + label(L.env, p.v) + ')', () => delPoint(L, p));
    } else {
      const t = ssDaw.snapT(ssDaw.timeAt(x)), v = valAt(L, y);
      add('Add a point here (' + label(L.env, v) + ')', () => addPoint(L, t, v));
    }
    ssDaw.redraw();
    return true;
  };
  // Delete removes the selected point (not while the piano roll is open: it has the keys then)
  document.addEventListener('keydown', (e) => {
    if (!sel || pend || !ssDaw.onSong() || (e.key !== 'Delete' && e.key !== 'Backspace')) return;
    if (/^(INPUT|SELECT|TEXTAREA)$/.test((e.target && e.target.tagName) || '')) return;
    const pr = document.querySelector('.proll');
    if (pr && !pr.hidden) return;
    const env = arr(envs[sel.i])[sel.e], p = env && pointsOf(sel.i, sel.e).find((x) => Math.abs(x.t - sel.t) < 0.002);
    if (!p) return;
    e.preventDefault();
    delPoint({ i: sel.i, e: sel.e, env }, p);
  });
  ssDaw.redraw();
})();
