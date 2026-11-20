// StudioSync's Song page: the shared DAW view, stage 1 (view only), and the song's history on the same timeline. Drawn on a canvas from the
// topics lib/dawview.lua publishes (daw, dawc<k>, dawcur, dawhist), which app.js hands over as an 'ss-state' event. Nothing here changes the
// song: the only things sent are "I'm looking" (so Live sync builds the topics at all), Play/Stop together (refused by Live sync for whoever
// may not) and "Restore this", which only opens that version on the panel's own Restore page, where it asks as ever. Bandmates' text goes in
// as text (canvas fillText, textContent), never HTML. No framework or CDN. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const arr = (x) => (Array.isArray(x) ? x : []);
  const clamp = (v, a, z) => Math.max(a, Math.min(z, v));
  const PEAK = {}; // peak character -> 0..1
  '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_'.split('').forEach((c, i) => { PEAK[c] = i / 63; });
  const KIND = { a: 'added an item', c: 'changed an item', d: 'deleted something', r: 'brought something back', t: 'changed the track',
    f: 'changed plug-ins', e: 'changed automation or settings', m: 'changed tempo or markers' };

  // ---- the page itself: a "Song" tab beside the main view, made here so index.html only links this file ------------------------------
  const main = document.querySelector('main');
  const tabs = mk('nav', 'tabs');
  tabs.setAttribute('aria-label', 'Pages');
  const tabHere = mk('button', 'tab', 'Home'), tabSong = mk('button', 'tab', 'Project'); // (James: "project" and "home" read better than "song" and "here")
  for (const b of [tabHere, tabSong]) { b.type = 'button'; tabs.append(b); }
  const title = document.querySelector('header .title');
  title.after(tabs);
  const page = mk('div', 'song');
  page.id = 'song';
  page.hidden = true;
  page.innerHTML = // (fixed markup, no data in it)
    '<div class="dbar">' +
    '<button type="button" class="dplay" title="Play together: everyone starts from your edit cursor, after a bar’s count-in" aria-label="Play together">▶</button>' +
    '<button type="button" class="dstop" title="Stop together" aria-label="Stop together">■</button>' +
    '<span class="dtime" aria-live="off"></span>' +
    '<label class="dfollow">Follow <select aria-label="Follow"></select></label>' +
    '<button type="button" class="dfit" title="Whole project">Fit</button>' +
    '<button type="button" class="dhistb" aria-pressed="false" title="The project’s life: every change, saved versions, notes">History</button>' +
    '</div>' +
    '<div class="dhist" hidden><canvas class="dstrip" height="36" aria-label="When things changed: saved versions and changes over time"></canvas>' +
    '<div class="dlegend"></div><div class="dvers"><ol></ol><div class="ddetail"></div></div></div>' +
    '<div class="dwrap"><canvas class="dcv" role="img" aria-label="The project’s arrange view"></canvas><div class="dtip" hidden></div></div>' +
    '<div class="dmsg dim" role="status"></div>';
  main.after(page);
  const q = (s) => page.querySelector(s);
  const cv = q('.dcv'), wrap = q('.dwrap'), tip = q('.dtip'), msg = q('.dmsg'), sel = q('.dfollow select');
  const strip = q('.dstrip'), histBox = q('.dhist'), histBtn = q('.dhistb'), vlist = q('.dvers ol'), detail = q('.ddetail');
  const ctx = cv.getContext('2d');

  let onSong = false;
  function showPage(song) {
    onSong = song;
    main.hidden = song;
    page.hidden = !song;
    tabHere.setAttribute('aria-pressed', String(!song));
    tabSong.setAttribute('aria-pressed', String(song));
    try { localStorage.setItem('ss-page', song ? 'song' : 'here'); } catch (e) {}
    if (song) { want(); resize(); }
  }
  tabHere.addEventListener('click', () => showPage(false));
  tabSong.addEventListener('click', () => showPage(true));

  // ---- talking to Live sync ----------------------------------------------------------------------------------------------------------
  function act(o) {
    return fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
      body: JSON.stringify(Object.assign({ topic: 'daw' }, o)) }).then((r) => { if (!r.ok) throw new Error(String(r.status)); });
  }
  let histOn = false;
  // (Live sync builds the Song page's topics only while a page says it's looking: every 10 s, and at once on a change)
  function want() { if (onSong && !document.hidden) act({ want: true, history: histOn }).catch(() => {}); }
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', want);

  // ---- the state ---------------------------------------------------------------------------------------------------------------------
  const T = {}; // topics as last received (the stream sends only the changed ones)
  let engine = false, head = null, lanes = [], cur = null, curAt = 0, hist = null, songEnd = 10;
  function model() {
    head = T.daw && T.daw.key ? T.daw : null;
    lanes = [];
    if (!head) return;
    songEnd = Math.max(10, head.len || 0);
    for (let k = 0; k < (head.chunks || 0); k++) {
      const c = T['dawc' + k];
      if (!c || c.key !== head.key || c.gone) continue;
      arr(c.tr).forEach((items, j) => {
        lanes[c.from + j] = arr(items);
        for (const it of arr(items)) songEnd = Math.max(songEnd, it.p + it.l);
      });
    }
  }
  // seed: only topics not had yet (the stream's first, whole snapshot can come before this script listens; later ones carry changes only)
  function take(s, seed) {
    const t = s.topics || {};
    engine = !!s.engine;
    let song = false;
    for (const k in t) {
      if (seed && k in T) continue;
      T[k] = t[k];
      if (k === 'daw' || /^dawc\d+$/.test(k)) song = true;
    }
    if (song) { const first = !head; model(); if (first && head) fit(); dirty = true; }
    if (t.dawcur) { cur = t.dawcur; curAt = performance.now(); followView(); followList(); }
    if (t.dawhist) { hist = t.dawhist; histPanel(); dirty = true; }
    bar();
    draw();
  }
  addEventListener('ss-state', (e) => take(e.detail || {}, false));
  fetch('api/state').then((r) => r.json()).then((s) => take(s, true)).catch(() => {});

  // ---- the view: seconds at the left edge, pixels a second, vertical scroll -------------------------------------------------------------
  let x0 = 0, pps = 20, y0 = 0, W = 300, H = 200, dirty = true, follow = 'off';
  const off = document.createElement('canvas'), octx = off.getContext('2d');
  const narrow = () => W < 480;
  const HEAD = () => (narrow() ? 64 : 140), TOP = 34, LANE = () => (narrow() ? 30 : 40);
  const xOf = (t) => HEAD() + (t - x0) * pps;
  function clampView() {
    const span = W - HEAD();
    pps = clamp(pps, span / (songEnd * 4), 4000);
    x0 = clamp(x0, -span / pps * 0.5, songEnd);
    y0 = clamp(y0, 0, Math.max(0, lanes.length * LANE() - (H - TOP) + 8));
  }
  function fit() { x0 = 0; pps = (W - HEAD()) / (songEnd * 1.02); y0 = 0; clampView(); dirty = true; }
  function resize() {
    const r = wrap.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    if (r.width < 10 || r.height < 10) return;
    const was = W - HEAD();
    W = r.width; H = r.height;
    for (const c of [cv, off]) { c.width = Math.round(W * dpr); c.height = Math.round(H * dpr); }
    cv.style.width = W + 'px'; cv.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); octx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (was > 0) pps *= (W - HEAD()) / was; // (the same stretch of song stays in view)
    clampView();
    dirty = true;
    draw();
  }
  new ResizeObserver(() => { if (onSong) resize(); }).observe(wrap);
  new MutationObserver(() => { dirty = true; draw(); drawStrip(); }).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { dirty = true; draw(); drawStrip(); });

  // ---- time and bars -----------------------------------------------------------------------------------------------------------------
  function barAt(t) { // the bar (0-based) holding t, by binary search
    const b = arr(head && head.bars);
    let lo = 0, hi = b.length - 1;
    if (!b.length || t < b[0]) return -1;
    while (lo < hi) { const m = (lo + hi + 1) >> 1; if (b[m] <= t) lo = m; else hi = m - 1; }
    return lo;
  }
  function sigAt(bar) { let s = [0, 4, 4]; for (const x of arr(head && head.sigs)) { if (x[0] <= bar) s = x; else break; } return s; }
  function barLen(i) { const b = head.bars; return i + 1 < b.length ? b[i + 1] - b[i] : (i > 0 ? b[i] - b[i - 1] : 2); }
  function mmss(t) { const m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(1); }
  function where(t) {
    const i = head ? barAt(t) : -1;
    if (i < 0) return mmss(Math.max(0, t));
    const num = sigAt(i)[1];
    return (i + 1) + '.' + (Math.floor((t - head.bars[i]) / (barLen(i) / num)) + 1) + '  ' + mmss(t);
  }
  function playPos() {
    if (!cur || !cur.play) return null;
    const p = cur.play;
    return p.on ? p.pos + (performance.now() - curAt) / 1000 * (p.rate || 1) : null;
  }

  // ---- colours -----------------------------------------------------------------------------------------------------------------------
  let C = {};
  function colours() {
    const cs = getComputedStyle(document.documentElement), v = (n) => cs.getPropertyValue(n).trim();
    C = { bg: v('--bg'), panel: v('--panel'), text: v('--text'), dim: v('--dim'), line: v('--line'), accent: v('--accent'), rec: v('--rec'), play: v('--play') };
  }
  function personCol(name, given) {
    if (given) return given;
    let h = 0;
    for (const ch of String(name)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return 'hsl(' + (h % 360) + ',65%,55%)';
  }

  // ---- drawing: the song in an offscreen layer (only when it or the view changes), cursors on top every frame ---------------------
  function drawSong(g) {
    colours();
    const head_w = HEAD(), lh = LANE();
    g.fillStyle = C.bg; g.fillRect(0, 0, W, H);
    if (!head) return;
    const t0 = x0, t1 = x0 + (W - head_w) / pps;
    // lanes
    const first = Math.max(0, Math.floor(y0 / lh)), last = Math.min(head.tracks.length - 1, Math.floor((y0 + H - TOP) / lh));
    for (let i = first; i <= last; i++) {
      if (i % 2) { g.fillStyle = C.panel; g.globalAlpha = 0.5; g.fillRect(head_w, TOP + i * lh - y0, W - head_w, lh); g.globalAlpha = 1; }
    }
    // bars, beats and the grid
    const bars = arr(head.bars);
    let from = Math.max(0, barAt(t0)), labelEvery = 1;
    const bl = bars.length > 1 ? barLen(from) * pps : 100;
    while (bl * labelEvery < 34) labelEvery *= 2;
    g.font = '11px system-ui, sans-serif';
    for (let i = from; i < bars.length && bars[i] <= t1; i++) {
      const x = xOf(bars[i]), len = barLen(i), s = sigAt(i), num = s[1], den = s[2];
      g.fillStyle = C.line; g.fillRect(Math.round(x), TOP, 1, H - TOP);
      const beat = len / num;
      if (beat * pps >= 10) {
        g.globalAlpha = 0.45;
        for (let k = 1; k < num; k++) g.fillRect(Math.round(x + k * beat * pps), TOP, 1, H - TOP);
        const qn = num * 4 / den, per = head.grid > 0 ? qn / (head.grid * 4) : 0, step = per > 0 ? len / per : 0;
        if (step > 0 && step * pps >= 8 && Math.abs(per - num) > 1e-6) {
          g.globalAlpha = 0.2;
          for (let k = 1; k < per; k++) g.fillRect(Math.round(x + k * step * pps), TOP, 1, H - TOP);
        }
        g.globalAlpha = 1;
      }
      if (i % labelEvery === 0) { g.fillStyle = C.dim; g.fillText(String(i + 1), x + 3, 12); }
    }
    // items
    for (let i = first; i <= last; i++) {
      const tr = head.tracks[i] || {}, y = TOP + i * lh - y0 + 2, h = lh - 4;
      for (const it of arr(lanes[i])) {
        if (it.p > t1 || it.p + it.l < t0) continue;
        const xa = Math.max(head_w, xOf(it.p)), xz = Math.min(W, xOf(it.p + it.l));
        if (xz - xa < 0.5) continue;
        const col = it.c || tr.c || C.dim;
        g.globalAlpha = it.m || tr.m ? 0.15 : 0.35; g.fillStyle = col; g.fillRect(xa, y, xz - xa, h);
        g.globalAlpha = it.m || tr.m ? 0.35 : 0.9; g.strokeStyle = col; g.strokeRect(xa + 0.5, y + 0.5, xz - xa - 1, h - 1);
        g.fillStyle = C.text; g.globalAlpha = it.m || tr.m ? 0.3 : 0.75;
        if (it.x) drawNotes(g, it, y, h);
        else if (it.k) drawPeaks(g, it, y, h, xa, xz);
        if (it.n && xz - xa > 44 && h > 18) { g.globalAlpha = 0.8; g.save(); g.beginPath(); g.rect(xa, y, xz - xa - 2, h); g.clip(); g.fillText(it.n, xa + 3, y + 11); g.restore(); }
        g.globalAlpha = 1;
      }
    }
    if (histOn && hist) drawHistory(g);
    // track names over the left edge
    g.fillStyle = C.panel; g.fillRect(0, TOP, head_w, H - TOP);
    g.fillStyle = C.line; g.fillRect(head_w - 1, TOP, 1, H - TOP);
    g.font = (narrow() ? '11px' : '12px') + ' system-ui, sans-serif';
    for (let i = first; i <= last; i++) {
      const tr = head.tracks[i] || {}, y = TOP + i * lh - y0;
      g.fillStyle = tr.c || C.line; g.fillRect(0, y + 1, 4, lh - 2);
      const ind = 6 + Math.min(tr.d || 0, 6) * (narrow() ? 4 : 8);
      g.fillStyle = tr.m ? C.dim : C.text;
      g.save(); g.beginPath(); g.rect(ind, y, head_w - ind - (narrow() ? 14 : 30), lh); g.clip();
      g.fillText((tr.f ? '▾ ' : '') + (tr.n || 'Track ' + (i + 1)), ind, y + lh / 2 + 4); g.restore();
      let bx = head_w - 4;
      if (tr.s) { bx -= 12; g.fillStyle = '#e8c547'; g.fillText('S', bx, y + lh / 2 + 4); }
      if (tr.m) { bx -= 12; g.fillStyle = C.rec; g.fillText('M', bx, y + lh / 2 + 4); }
      g.fillStyle = C.line; g.fillRect(0, y + lh - 1, head_w, 1);
    }
    // the ruler, markers and regions on top
    g.fillStyle = C.panel; g.fillRect(0, 0, W, TOP);
    g.fillStyle = C.line; g.fillRect(0, TOP - 1, W, 1);
    g.font = '11px system-ui, sans-serif';
    for (let i = from; i < bars.length && bars[i] <= t1; i++) {
      if (i % labelEvery === 0) { const x = xOf(bars[i]); if (x >= head_w) { g.fillStyle = C.dim; g.fillText(String(i + 1), x + 3, 12); g.fillRect(Math.round(x), 0, 1, 16); } }
    }
    for (const m of arr(head.markers)) {
      const x = xOf(m.p);
      if (m.e != null) {
        const xz = xOf(m.e);
        if (xz < head_w || x > W) continue;
        g.globalAlpha = 0.45; g.fillStyle = m.c || C.accent; g.fillRect(Math.max(head_w, x), 17, Math.min(W, xz) - Math.max(head_w, x), 15); g.globalAlpha = 1;
        if (m.n) { g.fillStyle = C.text; g.save(); g.beginPath(); g.rect(Math.max(head_w, x), 17, Math.max(0, Math.min(W, xz) - Math.max(head_w, x) - 2), 15); g.clip(); g.fillText(m.n, Math.max(head_w, x) + 3, 29); g.restore(); }
      } else if (x >= head_w && x <= W) {
        g.fillStyle = m.c || C.rec; g.fillRect(Math.round(x), 17, 2, 15);
        if (m.n) { g.fillStyle = C.text; g.fillText(m.n, x + 4, 29); }
      }
    }
    g.fillStyle = C.panel; g.fillRect(0, 0, head_w, TOP);
    g.fillStyle = C.dim; g.fillText(head.tracks.length + ' tracks', 6, 12);
  }
  function drawPeaks(g, it, y, h, xa, xz) {
    const k = it.k, n = k.length, colW = it.l * pps / n, mid = y + h / 2;
    const stride = Math.max(1, Math.floor(1 / colW)); // (columns under a pixel wide: the loudest of each pixel's)
    for (let i = Math.max(0, Math.floor((xa - xOf(it.p)) / colW)); i < n; i += stride) {
      const x = xOf(it.p) + i * colW;
      if (x > xz) break;
      let v = 0;
      for (let j = i; j < i + stride && j < n; j++) v = Math.max(v, PEAK[k[j]] || 0);
      const a = v * (h / 2 - 2);
      if (a >= 0.5) g.fillRect(x, mid - a, Math.max(1, colW * stride - (colW > 3 ? 1 : 0)), a * 2);
    }
  }
  function drawNotes(g, it, y, h) {
    const nt = arr(it.nt);
    if (!nt.length) return;
    let lo = 127, hi = 0;
    for (let i = 2; i < nt.length; i += 3) { lo = Math.min(lo, nt[i]); hi = Math.max(hi, nt[i]); }
    const span = Math.max(12, hi - lo + 1), nh = Math.max(1, Math.min(4, (h - 4) / span)), base = y + h - 2 - (h - 4 - span * nh) / 2;
    for (let i = 0; i + 2 < nt.length; i += 3) {
      const x = xOf(it.p + nt[i] / 1000);
      if (x > W) break;
      g.fillRect(Math.max(HEAD(), x), base - (nt[i + 2] - lo + 1) * nh, Math.max(1, nt[i + 1] / 1000 * pps), nh);
    }
  }
  function draw() {
    if (!onSong) return;
    if (dirty) { drawSong(octx); dirty = false; }
    ctx.clearRect(0, 0, W, H);
    ctx.drawImage(off, 0, 0, W, H);
    if (!sayUntil) msg.textContent = !engine ? 'Live sync isn’t running, so the project can’t be shown.' : !head ? 'Waiting for the project…' : '';
    if (!head || !cur) return;
    const head_w = HEAD();
    // everyone's edit cursor in their colour, then the play cursor
    ctx.font = '11px system-ui, sans-serif';
    const marks = [];
    if (cur.me && cur.me.cur != null) marks.push([cur.me.cur, personCol(cur.me.user, cur.me.col), 'you']);
    for (const p of arr(cur.people)) if (p.cur != null) marks.push([p.cur, personCol(p.user, p.col), p.user]);
    for (const [t, col, who] of marks) {
      const x = xOf(t);
      if (x < head_w || x > W) continue;
      ctx.fillStyle = col; ctx.globalAlpha = 0.9; ctx.fillRect(Math.round(x), TOP, 1, H - TOP);
      ctx.globalAlpha = 1; ctx.fillRect(Math.round(x) - 3, 0, 7, 4);
      const tw = ctx.measureText(who).width; // (a pill, so it reads over a region's name)
      ctx.fillStyle = C.panel; ctx.fillRect(x + 2, TOP - 13, tw + 4, 12);
      ctx.fillStyle = col; ctx.fillText(who, x + 4, TOP - 3);
    }
    const pp = playPos();
    if (pp != null) {
      const x = xOf(pp);
      if (x >= head_w && x <= W) { ctx.fillStyle = cur.play.rec ? C.rec : C.play; ctx.fillRect(Math.round(x) - 1, 0, 2, H); }
      if (follow === 'play' && (x > W - 20 || x < head_w)) { x0 = pp - (W - head_w) * 0.05 / pps; clampView(); dirty = true; }
      bar();
      requestAnimationFrame(draw);
    }
  }

  // ---- history on the same timeline: dots on their tracks at their positions, notes, the life strip and the versions ----------------
  let pick = -1; // the chosen version (index in hist.versions)
  function inPick(t) {
    if (pick < 0 || !hist) return true;
    const v = hist.versions, a = pick > 0 ? v[pick - 1].t : -Infinity;
    return t > a && t <= v[pick].t;
  }
  function userCol(u) { return personCol(hist.users[u], hist.cols[u]); }
  function drawHistory(g) {
    const head_w = HEAD(), lh = LANE();
    for (const d of arr(hist.dots)) {
      const [t, lane, u, , pos] = d, chosen = inPick(t);
      const x = pos === false ? head_w + 5 : xOf(pos), y = lane < 0 ? 24 : TOP + lane * lh - y0 + lh / 2;
      if (x < head_w || x > W || y < (lane < 0 ? 0 : TOP) || y > H) continue;
      g.globalAlpha = chosen ? 0.95 : 0.15; g.fillStyle = userCol(u);
      g.beginPath(); g.arc(x, y, chosen && pick >= 0 ? 4 : 3, 0, Math.PI * 2); g.fill();
    }
    g.globalAlpha = 1;
    for (const n of arr(hist.notes)) {
      if (n.pos == null) continue;
      const x = xOf(n.pos), y = n.lane == null ? 24 : TOP + n.lane * lh - y0 + 4;
      if (x < head_w || x > W) continue;
      g.fillStyle = userCol(n.u); g.fillRect(x - 5, y - 5, 10, 8); g.beginPath(); g.moveTo(x - 2, y + 3); g.lineTo(x, y + 6); g.lineTo(x + 2, y + 3); g.fill();
    }
  }
  function drawStrip() {
    if (!hist || histBox.hidden) return;
    const r = strip.getBoundingClientRect(), dpr = window.devicePixelRatio || 1, w = r.width, h = 36;
    strip.width = Math.round(w * dpr); strip.height = Math.round(h * dpr);
    const g = strip.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    colours();
    g.fillStyle = C.panel; g.fillRect(0, 0, w, h);
    const ts = arr(hist.dots).map((d) => d[0]).concat(arr(hist.versions).map((v) => v.t));
    if (!ts.length) return;
    const a = Math.min(...ts), z = Math.max(...ts, a + 60), X = (t) => 8 + (t - a) / (z - a) * (w - 16);
    strip._x = X;
    if (pick >= 0) {
      const v = hist.versions;
      g.fillStyle = C.accent; g.globalAlpha = 0.18;
      const xa = pick > 0 ? X(v[pick - 1].t) : 0;
      g.fillRect(xa, 0, X(v[pick].t) - xa, h); g.globalAlpha = 1;
    }
    for (const d of arr(hist.dots)) { g.fillStyle = userCol(d[2]); g.fillRect(Math.round(X(d[0])), 14, 1, 14); }
    arr(hist.versions).forEach((v, i) => {
      const x = X(v.t);
      g.fillStyle = i === pick ? C.accent : C.text; g.fillRect(Math.round(x), 2, 2, h - 4);
      g.beginPath(); g.moveTo(x + 1, 2); g.lineTo(x + 7, 6); g.lineTo(x + 1, 10); g.fill();
    });
  }
  strip.addEventListener('click', (e) => {
    if (!hist || !strip._x) return;
    const x = e.clientX - strip.getBoundingClientRect().left;
    let best = -1, bd = 14;
    arr(hist.versions).forEach((v, i) => { const d = Math.abs(strip._x(v.t) - x); if (d < bd) { bd = d; best = i; } });
    choose(best);
  });
  const when = (t) => new Date(t * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  function histPanel() {
    if (!hist) return;
    if (pick >= arr(hist.versions).length) pick = -1;
    const lg = q('.dlegend');
    lg.replaceChildren();
    arr(hist.users).forEach((name, u) => { const s = mk('span', 'who', name); s.style.setProperty('--c', userCol(u)); lg.append(s); });
    vlist.replaceChildren();
    const vs = arr(hist.versions);
    for (let i = vs.length - 1; i >= 0; i--) {
      const v = vs[i], li = mk('li'), b = mk('button', i === pick ? 'on' : '');
      b.type = 'button';
      b.append(mk('span', 'vl', v.label + (v.keep ? ' (kept)' : '')), mk('span', 'dim', ' ' + (v.by ? v.by + ', ' : '') + when(v.t)));
      b.addEventListener('click', () => choose(i === pick ? -1 : i));
      li.append(b);
      vlist.append(li);
    }
    if (!vs.length) vlist.append(mk('li', 'dim', 'No saved versions yet. Every handover saves one.'));
    details();
    drawStrip();
  }
  function choose(i) { pick = i; histPanel(); dirty = true; draw(); }
  function details() {
    detail.replaceChildren();
    if (pick < 0 || !hist) { detail.append(mk('p', 'dim', 'Pick a saved version to see what changed since the one before it.')); return; }
    const v = hist.versions[pick], prev = pick > 0 ? hist.versions[pick - 1] : null;
    const ds = arr(hist.dots).filter((d) => inPick(d[0]));
    detail.append(mk('h3', '', v.label), mk('p', 'dim', (prev ? 'Since “' + prev.label + '” (' + when(prev.t) + ')' : 'Everything before it') + ': ' +
      ds.length + ' change' + (ds.length === 1 ? '' : 's') + (v.behind ? '. Saved while catching up: it restores by time.' : '')));
    const by = {};
    for (const d of ds) { const k = hist.users[d[2]] + ' on ' + (d[1] >= 0 && head && head.tracks[d[1]] ? head.tracks[d[1]].n || 'a track' : 'the project'); by[k] = (by[k] || 0) + 1; }
    const ul = mk('ul', 'dsum');
    Object.keys(by).sort((a, z) => by[z] - by[a]).slice(0, 12).forEach((k) => ul.append(mk('li', '', by[k] + ' × ' + k)));
    detail.append(ul);
    const lines = mk('ol', 'dlines');
    ds.slice(-30).reverse().forEach((d) => lines.append(mk('li', '', words(d))));
    if (ds.length) detail.append(lines);
    const b = mk('button', 'drestore', 'Restore this…');
    b.type = 'button';
    b.title = 'Opens this version on the panel’s Restore page in REAPER: it asks there before anything changes';
    b.addEventListener('click', () => act({ restore: v.f }).then(() => say('Opened on the panel’s Restore page in REAPER: confirm there.'))
      .catch(() => say('Couldn’t reach Live sync.')));
    detail.append(b);
  }
  function words(d) {
    const [t, lane, u, k, pos] = d;
    const on = lane >= 0 && head && head.tracks[lane] ? ' on ' + (head.tracks[lane].n || 'a track') : '';
    return hist.users[u] + ' ' + (KIND[k] || 'changed something') + on + (pos !== false ? ' at ' + where(pos) : '') + ' · ' + when(t);
  }
  histBtn.addEventListener('click', () => {
    histOn = !histOn;
    histBtn.setAttribute('aria-pressed', String(histOn));
    histBox.hidden = !histOn;
    want();
    if (histOn) histPanel();
    resize();
  });

  // ---- the bar: play/stop together, where, follow ----------------------------------------------------------------------------------
  const playB = q('.dplay'), stopB = q('.dstop'), timeEl = q('.dtime');
  let sayUntil = 0;
  function say(t) { msg.textContent = t; sayUntil = performance.now() + 5000; }
  function bar() {
    const may = !!(head && head.may), ok = engine && !!head;
    playB.disabled = stopB.disabled = !(ok && may);
    const why = !ok ? 'Live sync isn’t running' : may ? '' : 'Only the driver starts and stops in this room';
    playB.title = why || 'Play together: everyone starts from your edit cursor, after a bar’s count-in';
    stopB.title = why || 'Stop together';
    const pp = playPos();
    timeEl.textContent = head ? where(pp != null ? pp : cur && cur.me ? cur.me.cur || 0 : 0) : '';
    timeEl.classList.toggle('rec', !!(cur && cur.play && cur.play.rec));
  }
  playB.addEventListener('click', () => act({ play: 'start' }).then(() => say('Play together sent: everyone starts in a few seconds.')).catch(() => say('Couldn’t reach Live sync.')));
  stopB.addEventListener('click', () => act({ play: 'stop' }).then(() => say('Stop together sent.')).catch(() => say('Couldn’t reach Live sync.')));
  q('.dfit').addEventListener('click', () => { setFollow('off'); fit(); draw(); });
  function followList() {
    const want = ['off', 'play', 'me'].concat(arr(cur && cur.people).map((p) => p.user));
    const have = Array.from(sel.options).map((o) => o.value);
    if (want.join('\n') === have.join('\n')) return;
    sel.replaceChildren();
    for (const v of want) {
      const o = mk('option', '', v === 'off' ? 'Nobody' : v === 'play' ? 'Play cursor' : v === 'me' ? 'This REAPER' : v);
      o.value = v;
      sel.append(o);
    }
    sel.value = want.includes(follow) ? follow : 'off';
  }
  function setFollow(v) { follow = v; if (sel.value !== v) sel.value = v; followView(); }
  sel.addEventListener('change', () => setFollow(sel.value));
  function followView() {
    if (!cur || follow === 'off' || follow === 'play') return;
    const p = follow === 'me' ? cur.me : arr(cur.people).find((x) => x.user === follow);
    const v = p && p.view;
    if (!v || !(v[1] > v[0])) { if (p && !v) say(follow + '’s view arrives once their StudioSync sends it.'); return; }
    x0 = v[0]; pps = (W - HEAD()) / (v[1] - v[0]); clampView(); dirty = true;
  }

  // ---- pan and zoom: drag, two-finger pinch, wheel (Ctrl/pinch zooms, Shift scrolls sideways), double-click fits -----------------------
  const pts = new Map();
  let pinch = null, tapAt = 0, moved = false;
  function zoomAt(px, f) {
    const t = x0 + (px - HEAD()) / pps;
    pps *= f; clampView();
    x0 = t - (px - HEAD()) / pps; clampView();
    dirty = true;
  }
  function manual() { if (follow !== 'off' && follow !== 'play') setFollow('off'); }
  cv.addEventListener('pointerdown', (e) => {
    cv.setPointerCapture(e.pointerId);
    pts.set(e.pointerId, { x: e.offsetX, y: e.offsetY, x0: e.offsetX, y0: e.offsetY });
    moved = false;
    if (pts.size === 2) { const [a, b] = [...pts.values()]; pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), mx: (a.x + b.x) / 2 }; }
  });
  cv.addEventListener('pointermove', (e) => {
    const p = pts.get(e.pointerId);
    if (!p) { hover(e); return; }
    const dx = e.offsetX - p.x, dy = e.offsetY - p.y;
    p.x = e.offsetX; p.y = e.offsetY;
    if (Math.hypot(p.x - p.x0, p.y - p.y0) > 6) moved = true;
    if (pts.size === 1 && moved) { x0 -= dx / pps; y0 -= dy; manual(); clampView(); dirty = true; draw(); }
    else if (pts.size === 2 && pinch) {
      const [a, b] = [...pts.values()], d = Math.hypot(a.x - b.x, a.y - b.y), mx = (a.x + b.x) / 2;
      if (pinch.d > 10) zoomAt(mx, d / pinch.d);
      x0 -= (mx - pinch.mx) / pps; clampView();
      pinch = { d, mx }; manual(); dirty = true; draw();
    }
  });
  const up = (e) => {
    const was = pts.get(e.pointerId);
    pts.delete(e.pointerId);
    if (pts.size < 2) pinch = null;
    if (was && !moved && pts.size === 0) {
      const now = performance.now();
      if (now - tapAt < 300) { setFollow('off'); fit(); draw(); } else hover(e, true);
      tapAt = now;
    }
  };
  cv.addEventListener('pointerup', up);
  cv.addEventListener('pointercancel', up);
  cv.addEventListener('wheel', (e) => {
    e.preventDefault();
    const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? H : 1;
    if (e.ctrlKey || e.metaKey) zoomAt(e.offsetX, Math.exp(-e.deltaY * k * 0.0025));
    else if (e.shiftKey) x0 += e.deltaY * k / pps;
    else { x0 += e.deltaX * k / pps; y0 += e.deltaY * k; }
    manual(); clampView(); dirty = true; draw();
  }, { passive: false });
  cv.addEventListener('pointerleave', () => { if (!pts.size) tip.hidden = true; });

  // a history dot or note under the pointer (hover with a mouse, a tap on a phone): who, what, when
  function hover(e, tap) {
    if (!histOn || !hist || !head) { tip.hidden = true; return; }
    const x = e.offsetX, y = e.offsetY, lh = LANE();
    let best = null, bd = tap ? 14 : 8;
    for (const n of arr(hist.notes)) {
      if (n.pos == null) continue;
      const nx = xOf(n.pos), ny = n.lane == null ? 24 : TOP + n.lane * lh - y0 + 4, d = Math.hypot(nx - x, ny - y);
      if (d < bd) { bd = d; best = hist.users[n.u] + (n.client ? ' (from ' + n.client + ')' : '') + ' · ' + when(n.t) + '\n' + n.text; }
    }
    for (const dd of arr(hist.dots)) {
      if (!inPick(dd[0])) continue;
      const dx = dd[4] === false ? HEAD() + 5 : xOf(dd[4]), dy = dd[1] < 0 ? 24 : TOP + dd[1] * lh - y0 + lh / 2, d = Math.hypot(dx - x, dy - y);
      if (d < bd) { bd = d; best = words(dd); }
    }
    if (!best) { tip.hidden = true; return; }
    tip.textContent = best;
    tip.hidden = false;
    tip.style.left = Math.min(x + 12, W - 220) + 'px';
    tip.style.top = Math.min(y + 12, H - 60) + 'px';
  }

  setInterval(() => { if (sayUntil && performance.now() > sayUntil) { sayUntil = 0; draw(); } }, 1000);
  let start = 'here';
  try { start = localStorage.getItem('ss-page') || 'here'; } catch (e) {}
  showPage(start === 'song');
})();
