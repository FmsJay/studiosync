// StudioSync's History page: the song's life as a time lapse, like the map replay at the end of a game of Civ. Tracks appear, items land, get
// moved and trimmed, regions form; each change lights up in the colour of who made it, or of its kind (takes, edits, mix moves, MIDI, tempo
// and markers), with filters; Play, speed and a scrubber over the song's working time, its sessions as a strip; then a summary: who did what,
// takes per person, the busiest days, how the song's length and track count grew. Reads the "hist" topic (lib/webhistory.lua: at most a few
// hundred frames, each only what changed in it, built only while a page shows this, which it says every 10 s). Read only: the page sends
// nothing but "I'm looking", and nothing here changes the project. Names go in as text, never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const arr = (x) => (Array.isArray(x) ? x : []);
  const SVG = 'http://www.w3.org/2000/svg';
  const svg = (tag, attrs) => { const e = document.createElementNS(SVG, tag); for (const k in attrs || {}) e.setAttribute(k, attrs[k]); return e; };
  const KINDS = ['Takes', 'Edits', 'Mix moves', 'MIDI', 'Tempo and markers'];
  const KIND_ONE = ['take', 'edit', 'mix move', 'MIDI edit', 'tempo or marker change'];
  const SPEEDS = [0.5, 1, 2, 4, 8, 16];
  const FPS = 8;        // frames a second at 1x (a few hundred frames: under a minute)
  const GLOW = 4;       // frames a change stays lit
  const FADE = 4;       // frames a deleted item's ghost lasts
  // (people without a picked colour: the categorical order after the five kinds' hues, in a fixed order, never cycled into a kind's)
  const SPARE = ['#008300', '#8e5bd6', '#7a7a80', '#b0412e', '#2a9cb0', '#a8781a'];
  const mmss = (s) => { s = Math.max(0, Math.round(s)); const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60; return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(r).padStart(2, '0'); };
  const dayOf = (t) => { const d = new Date(t * 1000); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); };
  const when = (t) => new Date(t * 1000).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  const dateShort = (t) => new Date(t * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' });
  const plural = (n, one, many) => n + ' ' + (n === 1 ? one : (many || one + 's'));

  // ---- the page -------------------------------------------------------------------------------------------------------------------------
  const page = mk('section', 'history');
  page.setAttribute('aria-label', 'History');
  const said = mk('p', 'hssaid');
  said.setAttribute('role', 'status');
  const play = mk('button', 'hsplay', 'Play');
  play.type = 'button';
  play.setAttribute('aria-pressed', 'false');
  const speedSel = mk('select');
  speedSel.setAttribute('aria-label', 'Speed');
  for (const s of SPEEDS) { const o = mk('option', '', s + '×'); o.value = String(s); if (s === 2) o.selected = true; speedSel.append(o); }
  const whenL = mk('span', 'hswhen');
  const ctl = mk('div', 'hsctl');
  ctl.append(play, speedSel, whenL);
  const byBox = mk('span', 'hsby');
  byBox.setAttribute('role', 'group');
  byBox.setAttribute('aria-label', 'Colour by');
  const byWho = mk('button', '', 'By person'), byKind = mk('button', '', 'By kind');
  for (const b of [byWho, byKind]) { b.type = 'button'; byBox.append(b); }
  const chips = mk('span', 'hslegend');
  const legend = mk('div', 'hslegend');
  legend.append(byBox, chips);
  const stage = mk('div', 'hsstage');
  const cv = mk('canvas', 'hscanvas');
  cv.setAttribute('role', 'img');
  stage.append(cv);
  const count = mk('div', 'hscount');
  count.setAttribute('aria-live', 'off');
  const strip = mk('canvas', 'hsstrip');
  strip.setAttribute('aria-hidden', 'true');
  const range = mk('input', 'hsrange');
  range.type = 'range';
  range.min = '0';
  range.setAttribute('aria-label', 'Point in the song’s history');
  const sessH = mk('h3', '', 'Sessions');
  const sess = mk('div', 'hssess');
  const sumH = mk('h2', '', 'Summary');
  const sum = mk('div', 'hssum');
  page.append(mk('h2', '', 'History'),
    mk('p', 'dim hsnote', 'The song’s life as a time lapse: every track, take and edit as it happened. Read only: nothing here changes the project.'),
    said, ctl, legend, stage, count, strip, range, sessH, sess, sumH, sum);

  // ---- state ------------------------------------------------------------------------------------------------------------------------------
  let H = null, F = [], stats = [], cols = [], places = [];
  let by = 'who';
  try { if (localStorage.getItem('ss-hist-by') === 'kind') by = 'kind'; } catch (e) {}
  const hideU = new Set(), hideK = new Set();
  let st;
  function reset() { st = { f: -1, tracks: new Map(), items: new Map(), gone: new Map(), mix: new Map(), plays: new Map(), regions: [] }; }
  reset();
  function apply(i) {
    const fr = F[i];
    for (const x of arr(fr.ta)) st.tracks.set(x, i);
    for (const x of arr(fr.tg)) st.tracks.delete(x);
    for (const x of arr(fr.g)) { const it = st.items.get(x); if (it) { st.gone.set(x, { a: it.a, f: i }); st.items.delete(x); } }
    for (const x of arr(fr.i)) { st.items.set(x[0], { a: x, f: i }); st.gone.delete(x[0]); }
    for (const x of arr(fr.m)) st.mix.set(x[0], { u: x[1], k: x[2], f: i });
    for (const x of arr(fr.p)) { if (x[1]) st.plays.set(x[0], String(x[1]).split(',')); else st.plays.delete(x[0]); }
    if (fr.r) st.regions = arr(fr.r);
    st.f = i;
  }
  function seek(i) {
    i = Math.max(-1, Math.min(F.length - 1, Math.floor(i)));
    if (i < st.f) reset();
    while (st.f < i) apply(st.f + 1);
  }
  // (an item in a fixed lane that doesn't play is hidden, as REAPER and the Song page show it: a comp's other takes)
  const plays = (a) => { const p = st.plays.get(a[1]); return !p || !(a[6] >= 0) || p[a[6]] !== '0'; };
  const songLen = () => { let m = 0; for (const it of st.items.values()) if (plays(it.a)) m = Math.max(m, it.a[2] + it.a[3]); return m; };
  const itemsNow = () => { let n = 0; for (const it of st.items.values()) if (plays(it.a) && st.tracks.has(it.a[1])) n++; return n; };
  const colourOf = (u, k) => (by === 'kind' ? kindCols[k] : cols[u]) || '#888';
  const shows = (u, k) => !hideU.has(u) && !hideK.has(k);
  let kindCols = [];
  function themeCols() {
    const cs = getComputedStyle(document.documentElement);
    kindCols = [0, 1, 2, 3, 4].map((k) => cs.getPropertyValue('--hk' + k).trim() || SPARE[k]);
    return { panel: cs.getPropertyValue('--panel').trim(), line: cs.getPropertyValue('--line').trim(), text: cs.getPropertyValue('--text').trim(),
      dim: cs.getPropertyValue('--dim').trim(), accent: cs.getPropertyValue('--accent').trim(), bg: cs.getPropertyValue('--bg').trim() };
  }

  // ---- drawing: the arrange view as it stood --------------------------------------------------------------------------------------------
  function fit(c) {
    const r = c.getBoundingClientRect(), d = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(r.width * d)), h = Math.max(1, Math.round(r.height * d));
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    const g = c.getContext('2d');
    g.setTransform(d, 0, 0, d, 0, 0);
    return { g, w: r.width, h: r.height };
  }
  function draw(frac) {
    if (!shown) return;
    const C = themeCols();
    const { g, w, h } = fit(cv);
    g.clearRect(0, 0, w, h);
    if (!H || !F.length) {
      g.fillStyle = C.dim; g.font = '14px system-ui, sans-serif'; g.textAlign = 'center';
      g.fillText(H ? 'No changes recorded in this room yet.' : 'Asking Live sync…', w / 2, h / 2);
      return;
    }
    const age = (f) => st.f - f + (frac || 0);
    const LW = Math.min(130, Math.max(64, w * 0.2)), RH = 20, R = w - 8;
    const maxLen = Math.max(30, ...stats.map((s) => s.len));
    const X = (p) => LW + (p / maxLen) * (R - LW);
    // lanes: the tracks alive now, in the song's order today (deleted ones where they first came)
    const lanes = [...st.tracks.keys()].sort((a, z) => (places[a] ?? 1e9 + a) - (places[z] ?? 1e9 + z));
    const row = new Map(lanes.map((t, i) => [t, i]));
    const lh = Math.max(4, Math.min(28, (h - RH - 6) / Math.max(1, lanes.length)));
    const Y = (i) => RH + 3 + i * lh;
    // a grid line every so many seconds, the ruler's times
    const step = [5, 10, 15, 30, 60, 120, 300, 600].find((s) => (s / maxLen) * (R - LW) >= 60) || 600;
    g.font = '11px system-ui, sans-serif'; g.textAlign = 'left'; g.textBaseline = 'middle';
    for (let s = 0; s <= maxLen; s += step) {
      const x = X(s);
      g.fillStyle = C.line; g.fillRect(Math.round(x), RH, 1, h - RH);
      g.fillStyle = C.dim; g.fillText(mmss(s), x + 3, 7);
    }
    // regions, as they stood
    for (const r of st.regions) {
      const x = X(r[0]), x2 = X(r[1]);
      g.fillStyle = C.accent; g.globalAlpha = 0.18; g.fillRect(x, 13, Math.max(2, x2 - x), RH - 13);
      g.globalAlpha = 0.06; g.fillRect(x, RH, Math.max(2, x2 - x), h - RH);
      g.globalAlpha = 1; g.fillStyle = C.text;
      g.save(); g.beginPath(); g.rect(x, 12, Math.max(2, x2 - x), RH - 12); g.clip(); g.fillText(r[2] || '', x + 3, 16.5); g.restore();
    }
    // lane names; a new track and a mix move light up its name
    g.textBaseline = 'middle';
    g.font = (lh >= 14 ? 12 : Math.max(8, lh - 2)) + 'px system-ui, sans-serif';
    for (const [t, i] of row) {
      const y = Y(i);
      if (i % 2) { g.fillStyle = C.line; g.globalAlpha = 0.35; g.fillRect(0, y, w, lh); g.globalAlpha = 1; }
      const born = age(st.tracks.get(t)), mx = st.mix.get(t);
      if (born < GLOW && born >= 0) { g.fillStyle = C.accent; g.globalAlpha = 0.5 * (1 - born / GLOW); g.fillRect(0, y, LW - 4, lh); g.globalAlpha = 1; }
      if (mx && age(mx.f) < GLOW && shows(mx.u, mx.k)) {
        g.fillStyle = colourOf(mx.u, mx.k); g.globalAlpha = 1 - age(mx.f) / GLOW; g.fillRect(0, y + 1, 4, lh - 2); g.globalAlpha = 1;
      }
      if (lh >= 8) { g.fillStyle = C.text; g.save(); g.beginPath(); g.rect(6, y, LW - 12, lh); g.clip(); g.fillText(H.tracks[t] ? H.tracks[t][0] || '(unnamed)' : '?', 7, y + lh / 2); g.restore(); }
    }
    g.fillStyle = C.line; g.fillRect(LW - 2, RH, 1, h - RH);
    // items: settled ones in their colour, those just touched lit, deleted ones fading out
    const pad = lh > 8 ? 2 : 1;
    const lit = [];
    for (const it of st.items.values()) {
      const a = it.a, i = row.get(a[1]);
      if (i == null || !plays(a)) continue;
      const on = shows(a[4], a[5]);
      const x = X(a[2]), wd = Math.max(2, X(a[2] + a[3]) - x), y = Y(i) + pad, ht = lh - pad * 2;
      g.fillStyle = on ? colourOf(a[4], a[5]) : C.dim;
      g.globalAlpha = on ? 0.78 : 0.14;
      g.fillRect(x, y, wd, ht);
      if (on && age(it.f) < GLOW) lit.push([x, y, wd, ht, 1 - age(it.f) / GLOW]);
    }
    g.globalAlpha = 1;
    g.strokeStyle = C.text;
    for (const [x, y, wd, ht, p] of lit) { g.globalAlpha = p; g.lineWidth = 1 + 2 * p; g.strokeRect(x - 1, y - 1, wd + 2, ht + 2); }
    g.setLineDash([3, 3]); g.lineWidth = 1;
    for (const [iid, it] of st.gone) {
      const a = it.a, i = row.get(a[1]), p = age(it.f);
      if (p >= FADE) { st.gone.delete(iid); continue; }
      if (i == null || !shows(a[4], a[5]) || !plays(a)) continue;
      g.globalAlpha = 1 - p / FADE; g.strokeStyle = C.dim;
      g.strokeRect(X(a[2]), Y(i) + pad, Math.max(2, X(a[2] + a[3]) - X(a[2])), lh - pad * 2);
    }
    g.setLineDash([]); g.globalAlpha = 1;
    if (!lanes.length) { g.fillStyle = C.dim; g.textAlign = 'center'; g.fillText('Before the first track', (LW + R) / 2, h / 2); }
    drawStrip(C);
  }
  // the strip under it: how busy each frame was, sessions shaded in turn, saved versions as ticks, where the lapse is now
  function drawStrip(C) {
    const { g, w, h } = fit(strip);
    g.clearRect(0, 0, w, h);
    if (!F.length) return;
    const bw = w / F.length;
    const maxN = Math.max(1, ...F.map((f) => f.n));
    for (let i = 0; i < F.length; i++) {
      const bh = Math.max(1, (F[i].n / maxN) * (h - 10));
      g.fillStyle = (F[i].s % 2) ? C.dim : C.accent;
      g.globalAlpha = i <= st.f ? 0.85 : 0.3;
      g.fillRect(i * bw, h - bh, Math.max(1, bw - (bw > 3 ? 1 : 0)), bh);
    }
    g.globalAlpha = 1; g.fillStyle = C.text;
    for (const v of arr(H.versions)) {
      const i = frameAt(v[0]);
      const x = (i + 0.5) * bw;
      g.beginPath(); g.moveTo(x - 4, 0); g.lineTo(x + 4, 0); g.lineTo(x, 6); g.fill();
    }
    if (st.f >= 0) { g.fillStyle = C.text; g.fillRect(Math.min(w - 2, (st.f + 1) * bw - 1), 0, 2, h); }
  }
  const frameAt = (t) => { let lo = 0, hi = F.length - 1; while (lo < hi) { const m = (lo + hi) >> 1; if (F[m].t < t) lo = m + 1; else hi = m; } return lo; };

  function label() {
    const s = stats[st.f];
    range.value = String(Math.max(0, st.f));
    count.replaceChildren();
    const add = (k, v) => { const x = mk('span', '', k + ' '); x.append(mk('b', '', v)); count.append(x); };
    if (!s) { whenL.textContent = F.length ? 'Before it began' : ''; return; }
    const fr = F[st.f], S = arr(H.sessions);
    whenL.textContent = when(fr.t) + ' · session ' + (fr.s + 1) + ' of ' + S.length;
    add('Tracks', String(s.nt)); add('Items', String(s.ni)); add('Song', mmss(s.len)); add('Changes', s.done + ' of ' + H.changes);
    cv.setAttribute('aria-label', 'The arrangement on ' + when(fr.t) + ': ' + plural(s.nt, 'track') + ', ' + plural(s.ni, 'item') + ', ' + mmss(s.len) + ' long');
    for (const b of sess.children) {
      const cur = Number(b.dataset.s) === fr.s;
      if (cur && b.getAttribute('aria-current') !== 'true') sess.scrollLeft = b.offsetLeft - sess.offsetLeft - 8; // (the strip follows the lapse, the page doesn't jump)
      b.setAttribute('aria-current', String(cur));
    }
  }

  // ---- playback --------------------------------------------------------------------------------------------------------------------------
  let playing = false, acc = 0, lastTs = 0;
  function setPlaying(on) {
    playing = on && F.length > 0;
    play.textContent = playing ? 'Pause' : 'Play';
    play.setAttribute('aria-pressed', String(playing));
    if (playing) { lastTs = 0; acc = 0; requestAnimationFrame(loop); }
    else draw(0);
  }
  function loop(ts) {
    if (!playing) return;
    const dt = lastTs ? Math.min(0.25, (ts - lastTs) / 1000) : 0;
    lastTs = ts;
    acc += dt * FPS * Number(speedSel.value);
    let moved = false;
    while (acc >= 1 && st.f < F.length - 1) { apply(st.f + 1); acc -= 1; moved = true; }
    if (moved) label();
    if (st.f >= F.length - 1) { draw(0); setPlaying(false); return; }
    draw(Math.min(acc, 1));
    if (shown && !document.hidden) requestAnimationFrame(loop); else setPlaying(false);
  }
  play.addEventListener('click', () => {
    if (!playing && st.f >= F.length - 1) { reset(); label(); } // (from the start again)
    setPlaying(!playing);
  });
  function jump(i) { setPlaying(false); seek(i); label(); draw(0); }
  range.addEventListener('input', () => jump(Number(range.value)));
  let dragging = false;
  const stripSeek = (e) => { const r = strip.getBoundingClientRect(); jump(((e.clientX - r.left) / r.width) * F.length); };
  strip.addEventListener('pointerdown', (e) => { if (!F.length) return; dragging = true; strip.setPointerCapture(e.pointerId); stripSeek(e); });
  strip.addEventListener('pointermove', (e) => { if (dragging) stripSeek(e); });
  strip.addEventListener('pointerup', () => { dragging = false; });
  cv.addEventListener('keydown', (e) => {
    if (e.key === ' ') { e.preventDefault(); play.click(); }
    else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); jump(st.f + (e.key === 'ArrowRight' ? 1 : -1) * (e.shiftKey ? 10 : 1)); }
  });
  cv.tabIndex = 0;

  // ---- colour by, filters ----------------------------------------------------------------------------------------------------------------
  function setBy(b) {
    by = b;
    try { localStorage.setItem('ss-hist-by', b); } catch (e) {}
    byWho.setAttribute('aria-pressed', String(b === 'who'));
    byKind.setAttribute('aria-pressed', String(b === 'kind'));
    buildChips();
    draw(0);
  }
  byWho.addEventListener('click', () => setBy('who'));
  byKind.addEventListener('click', () => setBy('kind'));
  // (the legend is the filter: a chip per person or kind, press to hide or show; the other set's filters stay as they were)
  function buildChips() {
    chips.replaceChildren();
    if (!H) return;
    themeCols();
    const list = by === 'kind' ? KINDS.map((n, k) => [n, kindCols[k], hideK, k]) : arr(H.users).map((n, u) => [n, cols[u], hideU, u]);
    for (const [name, c, set, id] of list) {
      const b = mk('button', 'hschip');
      b.type = 'button';
      b.style.setProperty('--c', c);
      b.append(mk('i'), document.createTextNode(name));
      b.setAttribute('aria-pressed', String(!set.has(id)));
      b.title = (set.has(id) ? 'Show ' : 'Hide ') + name;
      b.addEventListener('click', () => { if (set.has(id)) set.delete(id); else set.add(id); buildChips(); draw(0); });
      chips.append(b);
    }
    const hidden = by === 'kind' ? hideU.size : hideK.size;
    if (hidden) chips.append(mk('span', 'dim', '(' + plural(hidden, by === 'kind' ? 'person' : 'kind', by === 'kind' ? 'people' : 'kinds') + ' hidden)'));
  }

  // ---- sessions ----------------------------------------------------------------------------------------------------------------------------
  function buildSessions() {
    sess.replaceChildren();
    const S = arr(H.sessions);
    sessH.hidden = !S.length;
    S.forEach((s, i) => {
      const b = mk('button', '', dateShort(s.a) + ' · ' + mmss(Math.max(60, s.z - s.a)).replace(/:\d\d$/, '') + (s.z - s.a >= 3600 ? ' h' : ' min'));
      b.type = 'button';
      b.dataset.s = String(i);
      b.append(mk('span', '', plural(s.n, 'change') + ' · ' + arr(s.u).map((u) => H.users[u]).join(', ')));
      b.title = when(s.a) + ' to ' + when(s.z);
      b.addEventListener('click', () => { jump(Math.min(F.length - 1, s.f)); if (!playing) setPlaying(true); });
      sess.append(b);
    });
  }

  // ---- the summary --------------------------------------------------------------------------------------------------------------------------
  function bars(title, note, rows, total) {
    const fig = mk('figure', 'hschart');
    fig.append(mk('h3', '', title));
    if (note) fig.append(mk('p', 'dim', note));
    for (const r of rows) {
      const line = mk('div', 'hsrow');
      const nm = mk('span', 'hsname');
      nm.style.setProperty('--c', r.c);
      nm.append(mk('i'), mk('span', '', r.name));
      const bar = mk('span', 'hsbar');
      for (const seg of r.segs) {
        if (!seg.v) continue;
        const i = mk('i');
        i.style.setProperty('--c', seg.c);
        i.style.width = (seg.v / Math.max(1, total)) * 100 + '%';
        i.title = r.name + ': ' + seg.t;
        bar.append(i);
      }
      line.append(nm, bar, mk('span', 'hsval', String(r.total)));
      fig.append(line);
    }
    return fig;
  }
  function lineChart(title, ys, fmt) {
    const fig = mk('figure', 'hschart');
    fig.append(mk('h3', '', title));
    const W = 600, Hh = 120, n = ys.length, max = Math.max(1, ...ys);
    const s = svg('svg', { viewBox: '0 0 ' + W + ' ' + Hh, preserveAspectRatio: 'none', role: 'img',
      'aria-label': title + ': from ' + fmt(ys[0] || 0) + ' to ' + fmt(ys[n - 1] || 0) + ', at most ' + fmt(max) });
    const px = (i) => (n > 1 ? (i / (n - 1)) * W : 0), py = (v) => Hh - 4 - (v / max) * (Hh - 8);
    for (const q of [0.5, 1]) s.append(svg('line', { class: 'gr', x1: 0, x2: W, y1: py(max * q), y2: py(max * q) }));
    let d = '';
    ys.forEach((v, i) => { d += (i ? 'L' : 'M') + px(i).toFixed(1) + ' ' + py(v).toFixed(1); });
    s.append(svg('path', { class: 'ar', d: d + 'L' + W + ' ' + Hh + 'L0 ' + Hh + 'Z' }), svg('path', { class: 'ln', d }));
    const xh = svg('line', { class: 'xh', y1: 0, y2: Hh, x1: 0, x2: 0, visibility: 'hidden' });
    s.append(xh);
    const tip = mk('div', 'hstip');
    tip.hidden = true;
    const top = mk('div', 'hsaxis');
    top.append(mk('span', '', fmt(max) + ' at most'));
    const axis = mk('div', 'hsaxis');
    axis.append(mk('span', '', F.length ? dateShort(F[0].t) : ''), mk('span', '', F.length ? dateShort(F[F.length - 1].t) : ''));
    fig.append(top, s, axis, tip);
    const at = (e) => { const r = s.getBoundingClientRect(); return Math.max(0, Math.min(n - 1, Math.round(((e.clientX - r.left) / r.width) * (n - 1)))); };
    s.addEventListener('pointermove', (e) => {
      if (!n) return;
      const i = at(e), r = s.getBoundingClientRect(), fr = fig.getBoundingClientRect();
      xh.setAttribute('x1', px(i)); xh.setAttribute('x2', px(i)); xh.setAttribute('visibility', 'visible');
      tip.hidden = false;
      tip.textContent = fmt(ys[i]) + ' · ' + when(F[i].t);
      tip.style.left = (r.left - fr.left + (px(i) / W) * r.width) + 'px';
      tip.style.top = (r.top - fr.top + (py(ys[i]) / Hh) * r.height) + 'px';
    });
    s.addEventListener('pointerleave', () => { tip.hidden = true; xh.setAttribute('visibility', 'hidden'); });
    s.addEventListener('click', (e) => { if (n) jump(at(e)); });
    return fig;
  }
  function buildSummary() {
    sum.replaceChildren();
    if (!H || !F.length) { sumH.hidden = true; return; }
    sumH.hidden = false;
    themeCols();
    const who = arr(H.who), users = arr(H.users), S = arr(H.sessions), days = arr(H.days), last = stats[stats.length - 1];
    const takes = who.reduce((a, w) => a + (w[0] || 0), 0);
    const tiles = mk('div', 'hstiles');
    const tile = (v, k) => { const t = mk('div', 'hstile'); t.append(mk('b', '', v), mk('span', '', k)); tiles.append(t); };
    tile(String(S.length), S.length === 1 ? 'session' : 'sessions');
    tile(String(days.length), days.length === 1 ? 'day worked on' : 'days worked on');
    tile(String(H.changes), 'changes');
    tile(String(takes), takes === 1 ? 'take' : 'takes');
    tile(String(last.nt), last.nt === 1 ? 'track now' : 'tracks now');
    tile(String(last.ni), last.ni === 1 ? 'item now' : 'items now');
    tile(mmss(last.len), 'long now');
    sum.append(tiles);
    const grid = mk('div', 'hsgrid');
    // who did what: each person's changes by kind
    const totals = who.map((w) => w.slice(0, 5).reduce((a, x) => a + x, 0));
    const order = users.map((_, u) => u).filter((u) => totals[u] > 0).sort((a, z) => totals[z] - totals[a]);
    grid.append(bars('Who did what', 'Changes by kind: takes, edits, mix moves, MIDI, tempo and markers.',
      order.map((u) => ({ name: users[u], c: cols[u], total: totals[u],
        segs: [0, 1, 2, 3, 4].map((k) => ({ v: who[u][k], c: kindCols[k], t: plural(who[u][k], KIND_ONE[k], k === 2 ? 'mix moves' : k === 3 ? 'MIDI edits' : k === 4 ? 'tempo or marker changes' : null) })) })),
      Math.max(1, ...totals)));
    const tk = users.map((_, u) => u).filter((u) => who[u][0] > 0).sort((a, z) => who[z][0] - who[a][0]);
    const tfig = bars('Takes per person', tk.length ? null : 'No recorded takes yet.', tk.map((u) => ({ name: users[u], c: cols[u], total: who[u][0],
      segs: [{ v: who[u][0], c: cols[u], t: plural(who[u][0], 'take') }] })), Math.max(1, ...tk.map((u) => who[u][0])));
    grid.append(tfig);
    // the busiest days
    const dfig = mk('figure', 'hschart');
    const top3 = days.slice().sort((a, z) => z[1] - a[1]).slice(0, 3).map((d) => d[0]);
    dfig.append(mk('h3', '', 'Busiest days'), mk('p', 'dim', top3.length ? 'Most changes on ' + top3.join(', ') + '.' : ''));
    const cols3 = mk('div', 'hsdays');
    const dmax = Math.max(1, ...days.map((d) => d[1]));
    for (const [d, n] of days) {
      const b = mk('button');
      b.type = 'button';
      b.style.height = Math.max(3, (n / dmax) * 100) + '%';
      b.title = d + ': ' + plural(n, 'change');
      b.setAttribute('aria-label', d + ': ' + plural(n, 'change'));
      if (top3.includes(d)) { b.classList.add('top'); b.append(mk('em', '', d.slice(5))); }
      b.addEventListener('click', () => { let i = -1; F.forEach((f, j) => { if (dayOf(f.t) <= d) i = j; }); jump(i); });
      cols3.append(b);
    }
    const dax = mk('div', 'hsaxis');
    dax.append(mk('span', '', days.length ? days[0][0] : ''), mk('span', '', days.length ? days[days.length - 1][0] : ''));
    dfig.append(cols3, dax);
    grid.append(dfig);
    // how it grew (two charts, one scale each)
    grid.append(lineChart('Song length', stats.map((s) => s.len), mmss), lineChart('Tracks', stats.map((s) => s.nt), (v) => String(v)));
    sum.append(grid);
    // the numbers as a table
    const det = mk('details', 'hstable');
    det.append(mk('summary', '', 'Show as a table'));
    const wrap = mk('div', 'wrap'), tbl = mk('table'), hr = mk('tr');
    for (const c of ['Person', ...KINDS, 'Tracks added', 'Notes', 'First', 'Last']) hr.append(mk('th', '', c));
    tbl.append(hr);
    for (const u of users.map((_, i) => i)) {
      const w = who[u], tr = mk('tr');
      tr.append(mk('td', '', users[u]));
      for (let k = 0; k < 7; k++) tr.append(mk('td', '', String(w[k] || 0)));
      tr.append(mk('td', '', w[7] ? dayOf(w[7]) : ''), mk('td', '', w[8] ? dayOf(w[8]) : ''));
      tbl.append(tr);
    }
    wrap.append(tbl);
    det.append(wrap);
    sum.append(det);
  }

  // ---- a new hist from Live sync ------------------------------------------------------------------------------------------------------------
  function take(h) {
    const atEnd = !H || st.f >= F.length - 1, was = st.f;
    H = h;
    F = arr(h.frames);
    cols = arr(h.users).map((_, u) => (h.cols || [])[u] || SPARE[u % SPARE.length]);
    places = arr(h.tracks).map((t) => (t[1] >= 0 ? t[1] : null));
    // per frame: tracks, items, the song's length, changes so far (one pass; a few hundred frames)
    reset();
    stats = [];
    let done = 0;
    for (let i = 0; i < F.length; i++) { apply(i); done += F[i].n; stats.push({ nt: st.tracks.size, ni: itemsNow(), len: songLen(), done }); }
    reset();
    seek(atEnd ? F.length - 1 : Math.min(was, F.length - 1));
    range.max = String(Math.max(0, F.length - 1));
    const rd = h.read || {}, ln = h.lengths || {};
    said.textContent = !rd.done ? 'Reading the room’s history: ' + (rd.got || 0) + ' of ' + (rd.of || '?') + ' changes so far.'
      : (ln.need && ln.have < ln.need) ? 'Reading item lengths: ' + ln.have + ' of ' + ln.need + ' (items not read yet show their last known length).' : '';
    buildChips();
    buildSessions();
    buildSummary();
    label();
    draw(0);
  }

  let shown = false, last = null;
  const want = (on) => { if (on !== false && !(shown && !document.hidden)) return; ssTabs.act('history', { want: on !== false }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', () => { if (shown) want(!document.hidden); });
  function onState() {
    const T = ssTabs.topics;
    if (!shown || !T.hist || T.hist === last) return;
    last = T.hist;
    take(T.hist);
  }
  ssTabs.add('history', 'History', page, (on) => {
    shown = on;
    want(on);
    if (!on) { setPlaying(false); return; }
    setBy(by);
    last = null;
    onState();
    draw(0);
  });
  addEventListener('ss-state', onState);
  addEventListener('ss-tabs', onState);
  addEventListener('resize', () => { if (shown && !playing) draw(0); });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (shown) { buildChips(); buildSummary(); draw(0); } });
  new MutationObserver(() => { if (shown) { buildChips(); buildSummary(); draw(0); } }).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
})();
