// StudioSync's Song page: the shared DAW view, stage 1 (view only), and the song's history on the same timeline. Drawn on a canvas from the
// topics lib/dawview.lua publishes (daw, dawc<k>, dawcur, dawhist), which app.js hands over as an 'ss-state' event. What's sent: "I'm looking"
// (so Live sync builds the topics at all), Play/Stop together (refused by Live sync for whoever may not), "Restore this", which only opens that
// version on the panel's own Restore page, where it asks as ever, and stage 2's item and marker edits (below: lib/dawedit.lua checks and
// applies them). Stage 3's piano roll and automation lanes are pianoroll.js and autolanes.js, through the hooks at window.ssDaw (X, below).
// Bandmates' text goes in as text (canvas fillText, textContent), never HTML. No framework or CDN. GPL-3.0-or-later. (James, rt)
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
    layout();
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
    if (!seed) edTake(t, song);
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
  // Stage 3's hooks, filled by pianoroll.js and autolanes.js (window.ssDaw, at the end): X.extra(i) px of automation lanes under track i,
  // X.drawAuto(g, i, y, part) draws them ('body', then 'head' over the names column), X.isOpen(i), X.header(i) for a tap on a track's name,
  // the pointer in the lanes (X.autoDown / autoMove / autoUp / autoTap / autoAdd / autoMenu), and X.openMidi(h) a MIDI item's piano roll.
  const X = {};
  let tops = [0]; // each track's top, px below the first's (its lane, then its automation lanes): layout()
  function layout() {
    const lh = LANE(), n = head ? head.tracks.length : 0;
    tops = [0];
    for (let i = 0; i < n; i++) tops[i + 1] = tops[i] + lh + (X.extra ? X.extra(i) : 0);
  }
  const laneY = (i) => TOP + (i < tops.length ? tops[i] : tops[tops.length - 1] + (i - tops.length + 1) * LANE()) - y0;
  // The track whose lane or automation holds y (px in the canvas): -1 above the first, the track count below the last.
  function trackAt(y) {
    const c = y - TOP + y0, n = tops.length - 1;
    if (c < 0) return -1;
    if (c >= tops[n]) return n;
    let lo = 0, hi = n - 1;
    while (lo < hi) { const m = (lo + hi + 1) >> 1; if (tops[m] <= c) lo = m; else hi = m - 1; }
    return lo;
  }
  function clampView() {
    const span = W - HEAD();
    pps = clamp(pps, span / (songEnd * 4), 4000);
    x0 = clamp(x0, -span / pps * 0.5, songEnd);
    y0 = clamp(y0, 0, Math.max(0, tops[tops.length - 1] - (H - TOP) + 8));
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
    layout();
    const t0 = x0, t1 = x0 + (W - head_w) / pps;
    // lanes
    const first = clamp(trackAt(TOP), 0, head.tracks.length - 1), last = Math.min(head.tracks.length - 1, trackAt(H));
    for (let i = first; i <= last; i++) {
      if (i % 2) { g.fillStyle = C.panel; g.globalAlpha = 0.5; g.fillRect(head_w, laneY(i), W - head_w, lh); g.globalAlpha = 1; }
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
    // items (one being dragged or just sent is drawn where it's going, by edItems)
    for (let i = first; i <= last; i++) {
      const tr = head.tracks[i] || {}, y = laneY(i) + 2, h = lh - 4;
      arr(lanes[i]).forEach((it, j) => { if (!(ovr && ovr.lane === i && ovr.idx === j)) drawItem(g, it, tr, y, h, it.p, it.p + it.l); });
    }
    edItems(g, first, last);
    if (X.drawAuto) for (let i = first; i <= last; i++) if (X.extra(i)) X.drawAuto(g, i, laneY(i) + lh, 'body');
    if (histOn && hist) drawHistory(g);
    // track names over the left edge
    g.fillStyle = C.panel; g.fillRect(0, TOP, head_w, H - TOP);
    g.fillStyle = C.line; g.fillRect(head_w - 1, TOP, 1, H - TOP);
    g.font = (narrow() ? '11px' : '12px') + ' system-ui, sans-serif';
    for (let i = first; i <= last; i++) {
      const tr = head.tracks[i] || {}, y = laneY(i);
      g.fillStyle = tr.c || C.line; g.fillRect(0, y + 1, 4, lh - 2);
      const ind = 6 + Math.min(tr.d || 0, 6) * (narrow() ? 4 : 8);
      g.fillStyle = tr.m ? C.dim : C.text;
      g.save(); g.beginPath(); g.rect(ind, y, head_w - ind - (narrow() ? 14 : 30), lh); g.clip();
      g.fillText((tr.f ? '▾ ' : '') + (tr.n || 'Track ' + (i + 1)), ind, y + lh / 2 + 4); g.restore();
      let bx = head_w - 4;
      if (tr.s) { bx -= 12; g.fillStyle = '#e8c547'; g.fillText('S', bx, y + lh / 2 + 4); }
      if (tr.m) { bx -= 12; g.fillStyle = C.rec; g.fillText('M', bx, y + lh / 2 + 4); }
      // (it has envelopes: a tap on its name opens its automation lanes under it, autolanes.js)
      if (tr.e) { bx -= 12; g.fillStyle = X.isOpen && X.isOpen(i) ? C.accent : C.dim; g.fillText('A', bx, y + lh / 2 + 4); }
      g.fillStyle = C.line; g.fillRect(0, y + lh - 1, head_w, 1);
      if (X.drawAuto && X.extra(i)) X.drawAuto(g, i, y + lh, 'head');
    }
    // the ruler, markers and regions on top
    g.fillStyle = C.panel; g.fillRect(0, 0, W, TOP);
    g.fillStyle = C.line; g.fillRect(0, TOP - 1, W, 1);
    g.font = '11px system-ui, sans-serif';
    for (let i = from; i < bars.length && bars[i] <= t1; i++) {
      if (i % labelEvery === 0) { const x = xOf(bars[i]); if (x >= head_w) { g.fillStyle = C.dim; g.fillText(String(i + 1), x + 3, 12); g.fillRect(Math.round(x), 0, 1, 16); } }
    }
    for (const m0 of arr(head.markers)) {
      const m = edMarker(m0), x = xOf(m.p);
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
    edMarkSel(g);
    g.fillStyle = C.panel; g.fillRect(0, 0, head_w, TOP);
    g.fillStyle = C.dim; g.fillText(head.tracks.length + ' tracks', 6, 12);
  }
  // One item: a, z the box's span (a trim being dragged keeps the content where it is in time, cut to the new edges).
  function drawItem(g, it, tr, y, h, a, z) {
    const head_w = HEAD(), t0 = x0, t1 = x0 + (W - head_w) / pps;
    if (a > t1 || z < t0) return;
    const xa = Math.max(head_w, xOf(a)), xz = Math.min(W, xOf(z));
    if (xz - xa < 0.5) return;
    const col = it.c || tr.c || C.dim, cut = a !== it.p || z !== it.p + it.l;
    g.globalAlpha = it.m || tr.m ? 0.15 : 0.35; g.fillStyle = col; g.fillRect(xa, y, xz - xa, h);
    g.globalAlpha = it.m || tr.m ? 0.35 : 0.9; g.strokeStyle = col; g.strokeRect(xa + 0.5, y + 0.5, xz - xa - 1, h - 1);
    g.fillStyle = C.text; g.globalAlpha = it.m || tr.m ? 0.3 : 0.75;
    if (cut) { g.save(); g.beginPath(); g.rect(xa, y, xz - xa, h); g.clip(); }
    // (a video or picture item: its frames under a fainter waveform. video.js, rt-video2)
    if (it.v && window.ssVideo && window.ssVideo.draw(g, it, xOf(it.p), y, it.l * pps, h, xa, xz)) { g.fillStyle = C.text; g.globalAlpha *= 0.5; }
    if (it.x) drawNotes(g, it, y, h);
    else if (it.k) drawPeaks(g, it, y, h, xa, xz);
    if (cut) g.restore();
    if (it.n && xz - xa > 44 && h > 18) { g.globalAlpha = 0.8; g.save(); g.beginPath(); g.rect(xa, y, xz - xa - 2, h); g.clip(); g.fillText(it.n, xa + 3, y + 11); g.restore(); }
    g.globalAlpha = 1;
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
    // (otherwise who's editing what right now: "Bo is editing this", lib/follow.lua)
    if (!sayUntil) msg.textContent = !engine ? 'Live sync isn’t running, so the project can’t be shown.' : !head ? 'Waiting for the project…'
      : arr(cur && cur.people).filter((p) => p.ed).map((p) => p.user + ' is editing ' + p.ed).join(' · ');
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
      const x = pos === false ? head_w + 5 : xOf(pos), y = lane < 0 ? 24 : laneY(lane) + lh / 2;
      if (x < head_w || x > W || y < (lane < 0 ? 0 : TOP) || y > H) continue;
      g.globalAlpha = chosen ? 0.95 : 0.15; g.fillStyle = userCol(u);
      g.beginPath(); g.arc(x, y, chosen && pick >= 0 ? 4 : 3, 0, Math.PI * 2); g.fill();
    }
    g.globalAlpha = 1;
    for (const n of arr(hist.notes)) {
      if (n.pos == null) continue;
      const x = xOf(n.pos), y = n.lane == null ? 24 : laneY(n.lane) + 4;
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
    edDown(e);
  });
  cv.addEventListener('pointermove', (e) => {
    const p = pts.get(e.pointerId);
    if (!p) { edHover(e); hover(e); return; }
    const dx = e.offsetX - p.x, dy = e.offsetY - p.y;
    p.x = e.offsetX; p.y = e.offsetY;
    if (Math.hypot(p.x - p.x0, p.y - p.y0) > 6) moved = true;
    if (edMove(e)) return; // (a drag that edits an item or marker, not a pan)
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
    if (edUp(e, was)) return;
    if (was && !moved && pts.size === 0) {
      const now = performance.now();
      // a double tap: a point in an automation lane, a MIDI item's piano roll (stage 3), else the whole project; on a track's name, nothing
      if (now - tapAt < 300) {
        const h = itemAt(e.offsetX, e.offsetY, e.pointerType !== 'mouse');
        if (e.offsetX < HEAD()) { /* (its taps open and close its automation) */ }
        else if (X.autoAdd && X.autoAdd(e.offsetX, e.offsetY)) { /* (a point added) */ }
        else if (h && h.it.x && X.openMidi) X.openMidi(h);
        else { setFollow('off'); fit(); draw(); }
      } else hover(e, true);
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
      const nx = xOf(n.pos), ny = n.lane == null ? 24 : laneY(n.lane) + 4, d = Math.hypot(nx - x, ny - y);
      if (d < bd) { bd = d; best = hist.users[n.u] + (n.client ? ' (from ' + n.client + ')' : '') + ' · ' + when(n.t) + '\n' + n.text; }
    }
    for (const dd of arr(hist.dots)) {
      if (!inPick(dd[0])) continue;
      const dx = dd[4] === false ? HEAD() + 5 : xOf(dd[4]), dy = dd[1] < 0 ? 24 : laneY(dd[1]) + lh / 2, d = Math.hypot(dx - x, dy - y);
      if (d < bd) { bd = d; best = words(dd); }
    }
    if (!best) { tip.hidden = true; return; }
    tip.textContent = best;
    tip.hidden = false;
    tip.style.left = Math.min(x + 12, W - 220) + 'px';
    tip.style.top = Math.min(y + 12, H - 60) + 'px';
  }

  // ---- stage 2: item and marker edits ---------------------------------------------------------------------------------------------------
  // Click (or tap) an item or marker to select it; drag it to move it, an item's edge to trim it (snapping to the grid when REAPER snaps);
  // the edit row splits at the cursor, mutes and colours it, and adds or renames markers and regions. On a phone a drag moves only what's
  // already selected (anything else pans), and a long press opens a small menu; right-click opens it with a mouse. Every edit goes to Live
  // sync as an action (lib/dawedit.lua), which checks it as REAPER's own edits are and applies it there; the normal sync sends it on. Until
  // the change comes back the item is drawn where it's going; a refusal snaps it back with the reason (the dawedit topic).
  let selI = null;   // the selected item: { lane, idx, p, l } as last drawn (idx -1: found again by p and l when its chunk comes)
  let selM = null;  // the selected marker or region: { i, r, p }
  let grab = null;  // a drag that edits: { kind: 'item', h, t0, y } or { kind: 'marker', m, t0 }
  let ovr = null;   // an item drawn where it's going: { lane, idx, it, a, z, shift, tolane, to }
  let ovrM = null;  // a marker drawn where it's going: { i, r, to }
  let pend = null;  // the edit sent and not yet back: { id, keys (topics that bring it back), until, sel, selM (to go back to on a refusal) }
  let lp = null, lpFired = false, seq = 0;
  const ebar = mk('div', 'dedit'), esel = mk('span', 'esel dim');
  const eb = (text, title) => { const b = mk('button', '', text); b.type = 'button'; b.title = title; return b; };
  const bSplit = eb('Split', 'Split the selected item at the edit cursor (the play cursor while playing), as REAPER’s S');
  const bMute = eb('Mute', 'Mute or unmute the selected item');
  const colIn = mk('input', 'ecol');
  colIn.type = 'color'; colIn.title = 'The selected item’s colour'; colIn.setAttribute('aria-label', 'Item colour');
  const bNoCol = eb('No colour', 'The selected item takes its track’s colour again');
  const bAddM = eb('+ Marker', 'A marker at the edit cursor (the play cursor while playing), as REAPER’s M');
  const bAddR = eb('+ Region', 'A region over the selected item, or a bar from the edit cursor');
  const bName = eb('Rename', 'Rename the selected marker or region');
  const bPiano = eb('Piano roll', 'Open the selected MIDI item’s notes (or double-click it)');
  ebar.append(esel, bSplit, bMute, colIn, bNoCol, bAddM, bAddR, bName, bPiano);
  q('.dbar').after(ebar);
  const menu = mk('div', 'dmenu');
  menu.hidden = true;
  menu.setAttribute('role', 'menu');
  wrap.append(menu);

  const timeAt = (x) => x0 + (x - HEAD()) / pps;
  const ref = (s) => ({ lane: s.lane, idx: s.idx, p: s.p, l: s.l });
  const keyOf = (lane) => 'dawc' + Math.floor(lane / ((head && head.per) || 4));
  const selItem = () => (selI && selI.idx >= 0 && lanes[selI.lane] ? lanes[selI.lane][selI.idx] : null);
  const markerOf = (s) => (s && head ? arr(head.markers).find((m) => m.i === s.i && (m.e != null) === s.r) : null);
  const cursorNow = () => { const pp = playPos(); return pp != null ? pp : cur && cur.me ? cur.me.cur || 0 : 0; };
  // A time on the project's grid, as REAPER snaps (only while its snapping is on; Live sync snaps it again with REAPER's own SnapToGrid).
  function snapT(t) {
    t = Math.max(0, t);
    const b = arr(head && head.bars);
    if (!head || !head.snap || !b.length) return t;
    const i = Math.max(0, barAt(t)), s = sigAt(i), per = head.grid > 0 ? (s[1] * 4 / s[2]) / (head.grid * 4) : 1;
    const step = per >= 1 ? barLen(i) / per : barLen(i);
    return Math.max(0, b[i] + Math.round((t - b[i]) / step) * step);
  }
  // What's under a point: an item (with the part grabbed: its edges trim) or a marker/region in the ruler.
  function itemAt(x, y, touch) {
    if (!head || y < TOP || x < HEAD()) return null;
    const lane = trackAt(y);
    if (lane < 0 || y > laneY(lane) + LANE()) return null; // (below its lane: its automation, autolanes.js)
    const list = arr(lanes[lane]);
    for (let j = list.length - 1; j >= 0; j--) {
      const it = list[j], xa = xOf(it.p), xz = xOf(it.p + it.l), edge = touch ? 14 : 6;
      if (x < xa - 1 || x > xz + 1) continue;
      const mode = xz - xa < edge * 3 ? 'move' : x - xa < edge ? 'trim_start' : xz - x < edge ? 'trim_end' : 'move';
      return { lane, idx: j, it, mode };
    }
    return null;
  }
  function markerAt(x, y, touch) {
    if (!head || y < 15 || y > TOP || x < HEAD()) return null;
    let best = null, bd = touch ? 14 : 8;
    for (const m of arr(head.markers)) if (m.i != null && m.e == null && Math.abs(xOf(m.p) - x) < bd) { bd = Math.abs(xOf(m.p) - x); best = m; }
    return best || arr(head.markers).find((m) => m.i != null && m.e != null && x >= xOf(m.p) && x <= xOf(m.e)) || null;
  }
  function select(h, m) {
    selI = h ? { lane: h.lane, idx: h.idx, p: h.it.p, l: h.it.l } : null;
    selM = m ? { i: m.i, r: m.e != null, p: m.p } : null;
    edBar(); dirty = true; draw();
  }

  // drawing (from drawSong): the moved item, the selection, a marker where it's going
  function edItems(g, first, last) {
    const lh = LANE();
    if (ovr && ovr.tolane >= first && ovr.tolane <= last) {
      const it = ovr.shift ? Object.assign({}, ovr.it, { p: ovr.it.p + ovr.shift }) : ovr.it;
      drawItem(g, it, head.tracks[ovr.tolane] || {}, laneY(ovr.tolane) + 2, lh - 4, ovr.a, ovr.z);
    }
    const it = selItem(), s = ovr ? { lane: ovr.tolane, a: ovr.a, z: ovr.z } : it ? { lane: selI.lane, a: it.p, z: it.p + it.l } : null;
    if (!s || s.lane < first || s.lane > last) return;
    g.strokeStyle = C.accent; g.lineWidth = 2;
    g.strokeRect(xOf(s.a) + 1, laneY(s.lane) + 2, Math.max(2, xOf(s.z) - xOf(s.a) - 2), lh - 4);
    g.lineWidth = 1;
  }
  function edMarker(m) {
    return ovrM && m.i === ovrM.i && (m.e != null) === ovrM.r ? Object.assign({}, m, { p: ovrM.to, e: m.e != null ? m.e + ovrM.to - m.p : m.e }) : m;
  }
  function edMarkSel(g) {
    const m0 = markerOf(selM);
    if (!m0) return;
    const m = edMarker(m0), x = xOf(m.p);
    g.strokeStyle = C.accent; g.lineWidth = 2;
    if (m.e != null) g.strokeRect(Math.max(HEAD(), x), 17, Math.max(2, xOf(m.e) - Math.max(HEAD(), x)), 15); else g.strokeRect(x - 3, 16, 8, 17);
    g.lineWidth = 1;
  }

  // sending, and hearing back
  function edit(o, keys) {
    const id = 'e' + Date.now().toString(36) + (seq++);
    pend = { id, keys, until: performance.now() + 4000, sel: pend ? pend.sel : selI && Object.assign({}, selI), selM: pend ? pend.selM : selM && Object.assign({}, selM) };
    act({ edit: Object.assign({ id }, o) }).catch(() => snapBack('couldn’t reach Live sync'));
  }
  function snapBack(why) {
    if (pend) { selI = pend.sel; selM = pend.selM; }
    pend = null; ovr = ovrM = null;
    if (why) say('Not changed: ' + why + '.');
    edBar(); dirty = true; draw();
  }
  function reselect() {
    if (selI && lanes[selI.lane]) {
      const list = lanes[selI.lane], j = list.findIndex((it) => Math.abs(it.p - selI.p) < 0.002 && Math.abs(it.l - selI.l) < 0.002);
      if (j >= 0) selI.idx = j; else if (!pend) selI = null;
    } else if (selI && !pend) selI = null;
    if (selM && !pend) { const m = markerOf(selM); if (m) selM.p = m.p; else selM = null; }
  }
  function edTake(t, song) {
    const r = t.dawedit;
    if (pend && r && r.id === pend.id) { if (r.why) { snapBack(r.why); return; } }
    // (the change is back once the topics it touched arrive: the item's chunk, or the header for a marker)
    if (pend && pend.keys.some((k) => k in t)) { pend = null; ovr = ovrM = null; dirty = true; }
    if (song || !pend) reselect();
    edBar();
  }
  setInterval(() => { if (pend && performance.now() > pend.until) { pend = null; ovr = ovrM = null; reselect(); edBar(); dirty = true; draw(); } }, 1000);
  function edBar() {
    const it = selItem(), m = markerOf(selM), ok = engine && !!head;
    for (const b of [bSplit, bMute, colIn, bNoCol]) b.disabled = !(ok && it);
    bName.disabled = !(ok && m);
    bPiano.disabled = !(ok && it && it.x && X.openMidi);
    bAddM.disabled = bAddR.disabled = !ok;
    bMute.textContent = it && it.m ? 'Unmute' : 'Mute';
    if (it && it.c) colIn.value = it.c;
    const tr = it && head.tracks[selI.lane];
    esel.textContent = it ? (tr && tr.n ? tr.n + ': ' : '') + (it.n || 'item') : m ? (m.e != null ? 'Region ' : 'Marker ') + (m.n || '') :
      matchMedia('(pointer: coarse)').matches ? 'Tap to select · hold for more' : 'Click to select, drag to move';
  }
  const itemOp = (op, more) => { const it = selItem(); if (it) edit(Object.assign({ op }, ref(selI), more), [keyOf(selI.lane)]); };
  bSplit.addEventListener('click', () => itemOp('split'));
  bMute.addEventListener('click', () => { const it = selItem(); if (it) itemOp('mute', { on: !it.m }); });
  colIn.addEventListener('change', () => itemOp('colour', { c: colIn.value }));
  bNoCol.addEventListener('click', () => itemOp('colour', { c: '' }));
  function addMarker(at, region) {
    const it = selItem();
    const a = region && it ? it.p : at, z = region && it ? it.p + it.l : null;
    let to = z;
    if (region && z == null) { const i = barAt(a); to = a + (i >= 0 ? barLen(i) : 2); }
    edit(region ? { op: 'add_marker', at: a, to, region: true, name: '' } : { op: 'add_marker', at: a, name: '' }, ['daw']);
  }
  bAddM.addEventListener('click', () => addMarker(cursorNow(), false));
  bAddR.addEventListener('click', () => addMarker(cursorNow(), true));
  function rename() {
    const m = markerOf(selM);
    if (!m) return;
    const n = prompt(m.e != null ? 'Region name' : 'Marker name', m.n || '');
    if (n != null && n !== (m.n || '')) edit({ op: 'rename_marker', i: m.i, r: m.e != null, p: m.p, name: n }, ['daw']);
  }
  bName.addEventListener('click', rename);
  bPiano.addEventListener('click', () => { const it = selItem(); if (it && it.x && X.openMidi) X.openMidi({ lane: selI.lane, idx: selI.idx, it }); });

  // the menu (a long press, or right-click): what fits what's under the point
  function closeMenu() { menu.hidden = true; }
  function openMenu(x, y) {
    const touch = matchMedia('(pointer: coarse)').matches, m = markerAt(x, y, touch), h = m ? null : itemAt(x, y, touch);
    select(h, m);
    menu.replaceChildren();
    const add = (text, fn) => { const b = mk('button', '', text); b.type = 'button'; b.setAttribute('role', 'menuitem'); b.addEventListener('click', () => { closeMenu(); fn(); }); menu.append(b); };
    if (X.autoMenu && X.autoMenu(x, y, add)) { /* (in an automation lane: autolanes.js's entries) */ }
    else if (h) {
      if (h.it.x && X.openMidi) add('Piano roll', () => X.openMidi(h));
      add('Split at cursor', () => itemOp('split'));
      add(h.it.m ? 'Unmute' : 'Mute', () => itemOp('mute', { on: !h.it.m }));
      add('Colour…', () => colIn.click());
      if (h.it.c) add('No colour', () => itemOp('colour', { c: '' }));
      add('Region over it', () => addMarker(h.it.p, true));
    } else if (m) add('Rename…', rename);
    else if (head && x >= HEAD()) { const t = snapT(timeAt(x)); add('Marker here', () => addMarker(t, false)); add('Region here (a bar)', () => addMarker(t, true)); }
    if (!menu.childElementCount) return;
    add('Close', () => {});
    menu.hidden = false;
    menu.style.left = Math.max(4, Math.min(x, W - menu.offsetWidth - 4)) + 'px';
    menu.style.top = Math.max(4, Math.min(y, H - menu.offsetHeight - 4)) + 'px';
  }
  cv.addEventListener('contextmenu', (e) => { e.preventDefault(); openMenu(e.offsetX, e.offsetY); });
  document.addEventListener('pointerdown', (e) => { if (!menu.hidden && !menu.contains(e.target) && e.target !== cv) closeMenu(); });

  // the pointer (from the canvas' own handlers above)
  function edDown(e) {
    closeMenu();
    clearTimeout(lp); lp = null; lpFired = false; grab = null;
    if (pts.size !== 1 || !head) return;
    const x = e.offsetX, y = e.offsetY, touch = e.pointerType !== 'mouse';
    if (touch) lp = setTimeout(() => { lp = null; lpFired = true; grab = null; openMenu(x, y); }, 550);
    if (e.button > 0) return; // (right button: the menu)
    if (X.autoDown && X.autoDown(e, touch)) { grab = { kind: 'auto' }; if (selI || selM) select(null, null); return; } // (an envelope point)
    const m = markerAt(x, y, touch), h = m ? null : itemAt(x, y, touch);
    const mine = (h && selI && selI.lane === h.lane && selI.idx === h.idx) || (m && selM && selM.i === m.i && selM.r === (m.e != null));
    if (touch && !mine) return; // (a phone: only what's selected moves; anything else pans)
    if (m) grab = { kind: 'marker', m, t0: timeAt(x) };
    else if (h) grab = { kind: 'item', h, t0: timeAt(x), y };
    if (grab && !touch) select(h, m);
  }
  function edMove(e) {
    if (moved && lp) { clearTimeout(lp); lp = null; }
    if (!grab || pts.size !== 1) return false;
    if (!moved) return true;
    if (grab.kind === 'auto') { X.autoMove(e); return true; }
    const dt = timeAt(e.offsetX) - grab.t0;
    if (grab.kind === 'marker') ovrM = { i: grab.m.i, r: grab.m.e != null, to: snapT(grab.m.p + dt) };
    else {
      const { lane, idx, it, mode } = grab.h, end = it.p + it.l;
      if (mode === 'move') {
        const to = snapT(it.p + dt), tolane = clamp(trackAt(e.offsetY), 0, head.tracks.length - 1);
        ovr = { lane, idx, it, a: to, z: to + it.l, shift: to - it.p, tolane, to };
      } else if (mode === 'trim_start') {
        const to = Math.min(snapT(it.p + dt), end - 0.01);
        ovr = { lane, idx, it, a: to, z: end, shift: 0, tolane: lane, to };
      } else {
        const to = Math.max(snapT(end + dt), it.p + 0.01);
        ovr = { lane, idx, it, a: it.p, z: to, shift: 0, tolane: lane, to };
      }
    }
    dirty = true; draw();
    return true;
  }
  function edUp(e, was) {
    clearTimeout(lp); lp = null;
    if (lpFired) { lpFired = false; grab = null; return true; }
    const g = grab;
    grab = null;
    if (g && g.kind === 'auto' && moved) { X.autoUp(e, e.type === 'pointerup'); return true; } // (an envelope point dragged: autolanes.js sends it)
    if (g && moved) {
      if (e.type !== 'pointerup') { ovr = ovrM = null; dirty = true; draw(); return true; }
      if (g.kind === 'marker') {
        if (!ovrM || Math.abs(ovrM.to - g.m.p) < 1e-4) { ovrM = null; dirty = true; draw(); return true; }
        edit({ op: 'move_marker', i: g.m.i, r: g.m.e != null, p: g.m.p, to: ovrM.to }, ['daw']);
        return true;
      }
      const h = g.h, o = ovr, from = h.mode === 'trim_end' ? h.it.p + h.it.l : h.it.p;
      if (!o || (Math.abs(o.to - from) < 1e-4 && o.tolane === h.lane)) { ovr = null; dirty = true; draw(); return true; }
      const body = Object.assign({ op: h.mode, to: o.to }, ref({ lane: h.lane, idx: h.idx, p: h.it.p, l: h.it.l }));
      if (o.tolane !== h.lane) body.tolane = o.tolane;
      edit(body, [keyOf(h.lane), keyOf(o.tolane)]);
      selI = { lane: o.tolane, idx: -1, p: o.a, l: o.z - o.a };
      return true;
    }
    if (was && !moved && pts.size === 0 && e.type === 'pointerup') {
      const touch = e.pointerType !== 'mouse', m = markerAt(e.offsetX, e.offsetY, touch);
      // (a track's name: its automation lanes open or close; in the lanes: a point selected, autolanes.js)
      if (e.offsetX < HEAD() && e.offsetY > TOP) { const i = trackAt(e.offsetY); if (X.header && head && i >= 0 && i < head.tracks.length) X.header(i); return false; }
      if (X.autoTap && X.autoTap(e.offsetX, e.offsetY, touch)) { if (selI || selM) select(null, null); return false; }
      select(m ? null : itemAt(e.offsetX, e.offsetY, touch), m);
    }
    return false;
  }
  function edHover(e) {
    if (e.pointerType !== 'mouse') return;
    const h = !markerAt(e.offsetX, e.offsetY, false) && itemAt(e.offsetX, e.offsetY, false);
    cv.style.cursor = h ? (h.mode === 'move' ? 'move' : 'ew-resize') : markerAt(e.offsetX, e.offsetY, false) ? 'pointer' : '';
  }
  edBar();

  // ---- for stage 3's pages: the piano roll (pianoroll.js) and the automation lanes (autolanes.js) fill X and read the view through this --
  window.ssDaw = { X, act, say, snapT, where, barAt, sigAt, barLen, laneY, trackAt, timeAt, xOf, cursorNow, playPos, page, wrap,
    get head() { return head; }, get lanes() { return lanes; }, get engine() { return engine; }, get cur() { return cur; },
    onSong: () => onSong, view: () => ({ x0, pps, W, H, y0, HEAD: HEAD(), TOP, LANE: LANE() }), colours: () => { colours(); return C; },
    redraw: () => { layout(); clampView(); dirty = true; draw(); edBar(); } };
  if (window.ssVideo) window.ssVideo.onFrame(() => { if (onSong) { dirty = true; draw(); } }); // (a video item's frames came: video.js, rt-video2)

  setInterval(() => { if (sayUntil && performance.now() > sayUntil) { sayUntil = 0; draw(); } }, 1000);
  let start = 'here';
  try { start = localStorage.getItem('ss-page') || 'here'; } catch (e) {}
  showPage(start === 'song');
})();
