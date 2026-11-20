// The drawing layer (lib/webdraw.lua; rt-draw): draw over the Project page, the Mixer page and the phone's Project view (pen, arrow, circle,
// text, colours, sizes, an eraser), live for everyone in the room, kept as a layer on the song: Drawings shows or hides it on this computer,
// you remove your own and admins anyone's, Clear asks first. A drawing on the Project page sits on song time + track (screen share's anchors,
// anchor.js), one on the Mixer on its strip, so both stay put however the view is zoomed, scrolled or the strips reordered. The panel's Draw
// tool draws on the same layer. The History page shows each drawing from the moment it was drawn (ssDrawLayer.hist, called by history.js).
// Reads the "draw" topic; sends { topic: "draw", add | remove | clear }. Names and words go on the canvas as text, never HTML. GPL-3.0-or-later.
'use strict';
(() => {
  const A = globalThis.ssAnchor;
  if (!A) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, fn, title) => { const b = mk('button', '', text); b.type = 'button'; if (title) b.title = title; b.addEventListener('click', fn); return b; };
  const kept = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { /* (a private window) */ } return null; };
  const TOOLS = [['pen', 'Pen'], ['arrow', 'Arrow'], ['circle', 'Circle'], ['text', 'Text'], ['erase', 'Eraser']];
  const SWATCHES = ['#ff5a5a', '#4cc2ff', '#7be07b', '#ffc24c', '#c88bff', '#ffffff', '#202020'];
  const SIZES = [[2, 'S'], [4, 'M'], [8, 'L']];
  const TEXT_SIZE = { 2: 14, 4: 20, 8: 30 }; // (the panel's)
  const POINTS_MAX = 400; // (lib/webdraw.lua's: a longer stroke is thinned to it)
  const TEXT_MAX = 200;

  // ---- the topic, and talking to Live sync -----------------------------------------------------------------------------------------------
  const T = {};
  let D = null; // the "draw" topic: { key, me, admin, tracks: [[oid, REAPER track number, name]], list: [{ id, u, t, k, c, w, x, v, o, p }] }
  let pending = []; // your drawings sent, shown until the topic has them: { d, sent, at }
  const cachePts = new WeakMap(); // a topic drawing -> its anchors
  function take(s, seed) {
    const t = (s && s.topics) || {};
    for (const k in t) if (!(seed && k in T)) T[k] = t[k];
    if (T.draw && T.draw !== D) {
      D = T.draw;
      const now = performance.now();
      pending = pending.filter((p) => !p.sent && now - p.at < 8000);
      redrawAll();
    }
  }
  addEventListener('ss-state', (e) => take(e.detail, false));
  fetch('api/state').then((r) => r.json()).then((s) => take(s, true)).catch(() => {});
  function act(o) {
    return fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
      body: JSON.stringify(Object.assign({ topic: 'draw' }, o)) }).then((r) => { if (!r.ok) throw new Error(String(r.status)); });
  }
  function anchors(d) { // a topic drawing's points as anchors { t, k, d }
    let a = cachePts.get(d);
    if (!a) {
      a = [];
      const o = Array.isArray(d.o) ? d.o : [], p = Array.isArray(d.p) ? d.p : [];
      for (let i = 0; i + 2 < p.length; i += 3) if (typeof o[p[i + 1]] === 'string') a.push({ t: +p[i], k: o[p[i + 1]], d: +p[i + 2] });
      cachePts.set(d, a);
    }
    return a;
  }
  const mine = (d) => D && d.u === D.me;
  const mayRemove = (d) => !!D && (d.u === D.me || !!D.admin);
  function list(view) { // the drawings on one view (undefined: the arrange view), with your own not back from Live sync yet
    const out = [];
    for (const d of (D && Array.isArray(D.list) ? D.list : [])) if ((d.v || undefined) === view) out.push(d);
    for (const p of pending) if ((p.d.v || undefined) === view) out.push(p.d);
    return out;
  }

  // ---- drawing one: on a 2D context, through a surface's anchor -> pixel function ----------------------------------------------------------
  let showOn = kept('ss-draw-show') !== '0';
  let tool = kept('ss-draw-tool') || 'pen', colour = kept('ss-draw-colour') || '', size = +(kept('ss-draw-size') || 4);
  if (!TOOLS.some((t) => t[0] === tool)) tool = 'pen';
  if (!SIZES.some((s) => s[0] === size)) size = 4;
  // d: a topic drawing (or one being drawn: { k, c, w, x, pts }); px(anchor) -> { x, y } or null. -> the segments drawn, for the eraser.
  function render(g, d, px, opts) {
    const pts = (d.pts || anchors(d)).map(px);
    const col = d.c || 'hsl(' + hue(d.u) + ',80%,60%)', w = d.w || 3, kind = d.k || 'pen';
    const a = pts[0], z = pts[pts.length - 1], segs = [];
    g.strokeStyle = col; g.fillStyle = col; g.lineWidth = w; g.lineCap = 'round'; g.lineJoin = 'round';
    g.globalAlpha = (opts && opts.alpha) || 1;
    if (kind === 'text') {
      if (!a) return segs;
      const fs = TEXT_SIZE[w] || 18;
      g.font = '600 ' + fs + 'px system-ui, sans-serif'; g.textBaseline = 'top';
      const words = String(d.x || ''), tw = g.measureText(words).width;
      g.fillText(words, a.x, a.y);
      segs.push({ box: [a.x, a.y, a.x + tw, a.y + fs] });
    } else if ((kind === 'box' || kind === 'circle' || kind === 'line' || kind === 'arrow') && a && z && pts.length >= 2) {
      g.beginPath();
      if (kind === 'box') { g.rect(Math.min(a.x, z.x), Math.min(a.y, z.y), Math.abs(z.x - a.x), Math.abs(z.y - a.y)); segs.push({ box: [Math.min(a.x, z.x), Math.min(a.y, z.y), Math.max(a.x, z.x), Math.max(a.y, z.y)], edge: true }); }
      else if (kind === 'circle') {
        const cx = (a.x + z.x) / 2, cy = (a.y + z.y) / 2, rx = Math.abs(z.x - a.x) / 2, ry = Math.abs(z.y - a.y) / 2;
        g.ellipse(cx, cy, Math.max(1, rx), Math.max(1, ry), 0, 0, Math.PI * 2);
        let q = { x: cx + rx, y: cy };
        for (let i = 1; i <= 24; i++) { const ang = i / 24 * Math.PI * 2, n = { x: cx + rx * Math.cos(ang), y: cy + ry * Math.sin(ang) }; segs.push({ a: q, z: n }); q = n; }
      } else {
        g.moveTo(a.x, a.y); g.lineTo(z.x, z.y);
        segs.push({ a, z });
      }
      g.stroke();
      const len = Math.hypot(z.x - a.x, z.y - a.y);
      if (kind === 'arrow' && len > 1) { // (a filled head at the end, sized to the line: the panel's)
        const ux = (z.x - a.x) / len, uy = (z.y - a.y) / len, h = 10 + w * 2;
        g.beginPath(); g.moveTo(z.x, z.y);
        g.lineTo(z.x - h * ux - h * 0.5 * uy, z.y - h * uy + h * 0.5 * ux);
        g.lineTo(z.x - h * ux + h * 0.5 * uy, z.y - h * uy - h * 0.5 * ux);
        g.closePath(); g.fill();
      }
    } else { // pen, highlighter: a line through the points shown (a track not shown breaks it)
      if (kind === 'marker') { g.lineWidth = w * 3; g.globalAlpha *= 0.35; }
      g.beginPath();
      let prev = null;
      for (const p of pts) {
        if (p && prev) { g.lineTo(p.x, p.y); segs.push({ a: prev, z: p }); } else if (p) g.moveTo(p.x, p.y);
        prev = p;
      }
      g.stroke();
      if (pts.length === 1 && a) { g.beginPath(); g.arc(a.x, a.y, w, 0, Math.PI * 2); g.fill(); }
    }
    g.globalAlpha = 1;
    if (opts && opts.tag && a && d.u) { // who drew it, small, at its start
      g.font = '10px system-ui, sans-serif'; g.textBaseline = 'bottom';
      const name = d.u === (D && D.me) ? 'you' : d.u, tw = g.measureText(name).width;
      g.globalAlpha = 0.75; g.fillStyle = 'rgba(0,0,0,.55)'; g.fillRect(a.x + 3, a.y - 15, tw + 6, 13);
      g.fillStyle = '#fff'; g.fillText(name, a.x + 6, a.y - 3); g.globalAlpha = 1;
    }
    return segs;
  }
  function hue(name) { let x = 0; for (const c of String(name || '')) x = (x * 31 + c.charCodeAt(0)) % 360; return x; }
  function segDist(x, y, s) {
    if (s.box) {
      const [l, t, r, b] = s.box;
      if (!s.edge) return x >= l - 4 && x <= r + 4 && y >= t - 4 && y <= b + 4 ? 0 : Infinity;
      const inX = x >= l - 6 && x <= r + 6, inY = y >= t - 6 && y <= b + 6;
      return inX && inY ? Math.min(Math.abs(x - l), Math.abs(x - r), Math.abs(y - t), Math.abs(y - b)) : Infinity;
    }
    const vx = s.z.x - s.a.x, vy = s.z.y - s.a.y, n = vx * vx + vy * vy;
    const k = n > 0 ? Math.max(0, Math.min(1, ((x - s.a.x) * vx + (y - s.a.y) * vy) / n)) : 0;
    return Math.hypot(s.a.x + k * vx - x, s.a.y + k * vy - y);
  }

  // ---- a surface: a view drawings go over --------------------------------------------------------------------------------------------------
  // o: { name, view (undefined: the arrange view; 'mixer'), target (the element covered), bar (where the buttons go), geom() -> { W, H, v (a
  // view in anchor.js's form), swap (the mixer: strips across, so the "time" axis is down), clip: [x, y, w, h], ok (anchor) -> bool } or
  // null, wheel(e) (the wheel while drawing: the view's own zoom and scroll go on) }
  const surfaces = [];
  function surface(o) {
    const s = Object.assign({ on: false, segs: new Map(), drag: null }, o);
    const cv = mk('canvas', 'drlayer');
    cv.setAttribute('aria-hidden', 'true');
    s.cv = cv;
    const mount = o.target.parentElement;
    if (getComputedStyle(mount).position === 'static') mount.style.position = 'relative';
    mount.append(cv);
    // the buttons: Draw and Drawings always; the tools while drawing
    const bar = mk('span', 'drbar');
    const drawB = button('Draw', () => setOn(!s.on), 'Draw over this for everyone in the room: it stays on its place in the song');
    drawB.setAttribute('aria-pressed', 'false');
    const showC = mk('input'); showC.type = 'checkbox'; showC.checked = showOn;
    showC.addEventListener('change', () => { showOn = showC.checked; kept('ss-draw-show', showOn ? '1' : '0'); for (const x of surfaces) x.showC.checked = showOn; redrawAll(); });
    const showL = mk('label', 'drshow', null); showL.append(showC, ' Drawings');
    showL.title = 'Show or hide everyone’s drawings, on this computer only';
    s.showC = showC;
    const tools = mk('span', 'drtools');
    tools.hidden = true;
    s.toolB = {};
    for (const [k, label] of TOOLS) { const b = button(label, () => setTool(k)); b.setAttribute('aria-pressed', String(tool === k)); s.toolB[k] = b; tools.append(b); }
    s.swB = [];
    const sw = mk('span', 'drsw');
    const mineB = button('Mine', () => setColour(''), 'Your own colour (the one Who’s here shows you in)');
    sw.append(mineB);
    s.swB.push([mineB, '']);
    for (const c of SWATCHES) { const b = button('', () => setColour(c), c); b.className = 'drswatch'; b.style.background = c; b.setAttribute('aria-label', 'Colour ' + c); sw.append(b); s.swB.push([b, c]); }
    const pick = mk('input'); pick.type = 'color'; pick.title = 'Any colour'; pick.setAttribute('aria-label', 'Any colour');
    pick.addEventListener('input', () => setColour(pick.value));
    sw.append(pick);
    s.sizeB = [];
    const sz = mk('span', 'drsz');
    for (const [n, label] of SIZES) { const b = button(label, () => setSize(n), 'Line size'); sz.append(b); s.sizeB.push([b, n]); }
    s.clearMine = button('Clear mine', () => clear('mine'));
    s.clearAll = button('Clear all', () => clear('all'), 'Everyone’s drawings in this room (owner and admins)');
    tools.append(sw, sz, s.clearMine, s.clearAll, button('Done', () => setOn(false)));
    s.said = mk('span', 'drsaid dim');
    s.said.setAttribute('role', 'status');
    bar.append(drawB, showL, tools, s.said);
    o.bar(bar);
    s.tools = tools;
    function setOn(on) {
      s.on = on;
      drawB.setAttribute('aria-pressed', String(on));
      drawB.textContent = on ? 'Drawing' : 'Draw';
      tools.hidden = !on;
      cv.classList.toggle('on', on);
      if (on && !showOn) { showOn = true; kept('ss-draw-show', '1'); for (const x of surfaces) x.showC.checked = true; }
      s.drag = null;
      s.said.textContent = on ? hint() : '';
      paintBar(); redrawAll();
    }
    s.setOn = setOn;
    // the pointer, while drawing
    const at = (e) => { const r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
    cv.addEventListener('pointerdown', (e) => {
      if (!s.on || e.button > 0) return;
      e.preventDefault();
      const g = s.geom(), p = at(e);
      if (!g) return;
      if (tool === 'erase') return erase(s, p);
      const a = anchorAt(g, p.x, p.y);
      if (!a) { s.said.textContent = s.view === 'mixer' ? 'Draw on a strip.' : 'Draw on the tracks (not the names or the ruler).'; return; }
      if (tool === 'text') {
        const words = (window.prompt('Text (everyone sees it)') || '').trim().slice(0, TEXT_MAX);
        if (words) send(s, { k: 'text', pts: [a], x: words });
        return;
      }
      s.drag = { k: tool, pts: [a], last: p };
      try { cv.setPointerCapture(e.pointerId); } catch (err) { /* (a pointer the browser no longer has) */ }
    });
    cv.addEventListener('pointermove', (e) => {
      if (!s.drag) return;
      const g = s.geom(), p = at(e);
      if (!g) return;
      const a = anchorAt(g, p.x, p.y);
      if (!a) return;
      if (s.drag.k === 'pen') { if (Math.hypot(p.x - s.drag.last.x, p.y - s.drag.last.y) >= 3) { s.drag.pts.push(a); s.drag.last = p; } }
      else s.drag.pts[1] = a;
      redraw(s);
    });
    const up = (e) => {
      if (!s.drag) return;
      const d = s.drag, g = s.geom();
      s.drag = null;
      if (e.type === 'pointerup' && g && d.pts.length >= 2) {
        const pa = pxOf(g, d.pts[0]), pz = pxOf(g, d.pts[d.pts.length - 1]);
        if (d.k === 'pen' || (pa && pz && Math.hypot(pz.x - pa.x, pz.y - pa.y) > 4)) send(s, { k: d.k, pts: thin(d.pts) });
      }
      redraw(s);
    };
    cv.addEventListener('pointerup', up);
    cv.addEventListener('pointercancel', up);
    cv.addEventListener('wheel', (e) => { if (s.on && s.wheel) { e.preventDefault(); s.wheel(e); } }, { passive: false });
    surfaces.push(s);
    paintBar();
    return s;
  }
  function hint() {
    return ({ pen: 'Drag to draw.', arrow: 'Drag from the tail to the point.', circle: 'Drag across where it goes.', text: 'Click or tap where the words go.',
      erase: 'Click or tap a drawing to take it away (yours; anyone’s if you’re an admin).' })[tool] || '';
  }
  function setTool(k) { tool = k; kept('ss-draw-tool', k); paintBar(); }
  function setColour(c) { colour = c; kept('ss-draw-colour', c); paintBar(); }
  function setSize(n) { size = n; kept('ss-draw-size', String(n)); paintBar(); }
  function paintBar() {
    for (const s of surfaces) {
      for (const k in s.toolB) s.toolB[k].setAttribute('aria-pressed', String(tool === k));
      for (const [b, c] of s.swB) b.setAttribute('aria-pressed', String(colour === c));
      for (const [b, n] of s.sizeB) b.setAttribute('aria-pressed', String(size === n));
      s.clearAll.hidden = !(D && D.admin);
      if (s.on) s.said.textContent = hint();
    }
  }
  // anchor <-> the surface's pixels, through anchor.js (the mixer's view is the same with its axes swapped)
  function anchorAt(g, x, y) {
    const p = g.swap ? A.fromPic(g.v, y / g.H, x / g.W) : A.fromPic(g.v, x / g.W, y / g.H);
    return 't' in p && (!g.ok || g.ok(p)) ? p : null;
  }
  function pxOf(g, a) {
    const q = A.toPic(g.v, a);
    if (!q) return null;
    return g.swap ? { x: q.y * g.W, y: q.x * g.H } : { x: q.x * g.W, y: q.y * g.H };
  }
  function thin(pts) { // at most POINTS_MAX, evenly, keeping the last
    if (pts.length <= POINTS_MAX) return pts;
    const out = [], step = (pts.length - 1) / (POINTS_MAX - 1);
    for (let i = 0; i < POINTS_MAX; i++) out.push(pts[Math.round(i * step)]);
    return out;
  }
  const r3 = (x) => Math.round(x * 1000) / 1000;
  function send(s, d) {
    const add = { kind: d.k, view: s.view, pts: d.pts.map((a) => [r3(a.t), a.k, r3(a.d)]), size };
    if (colour) add.color = colour;
    if (d.k === 'text') add.text = d.x;
    const p = { d: { id: 'pending', u: D ? D.me : '', k: d.k, c: colour || null, w: size, x: d.x, v: s.view, pts: d.pts }, sent: false, at: performance.now() };
    pending.push(p);
    redrawAll();
    act({ add }).then(() => { p.sent = true; }).catch(() => { pending = pending.filter((x) => x !== p); s.said.textContent = 'Couldn’t reach Live sync: not kept.'; redrawAll(); });
  }
  function erase(s, p) {
    let best = null, bd = 12;
    for (const [d, segs] of s.segs) {
      if (d.id === 'pending' || !mayRemove(d)) continue;
      for (const sg of segs) { const k = segDist(p.x, p.y, sg); if (k < bd) { bd = k; best = d; } }
    }
    if (!best) { s.said.textContent = 'Nothing of yours there to take away.'; return; }
    D.list = D.list.filter((d) => d !== best); // (gone here at once; the topic says so for everyone)
    redrawAll();
    act({ remove: best.id }).then(() => { s.said.textContent = mine(best) ? 'Taken away.' : 'Taken away (' + best.u + '’s).'; })
      .catch(() => { s.said.textContent = 'Couldn’t reach Live sync.'; });
  }
  function clear(which) {
    const n = (D && Array.isArray(D.list) ? D.list : []).filter((d) => which === 'all' || mine(d)).length;
    if (!n) { for (const s of surfaces) s.said.textContent = which === 'all' ? 'No drawings in this room.' : 'No drawings of yours here.'; return; }
    const q = which === 'all' ? 'Take away all ' + n + ' drawings in this room, everyone’s, for everyone? This can’t be undone.'
      : 'Take away your ' + n + ' drawing' + (n === 1 ? '' : 's') + ' in this room, for everyone? This can’t be undone.';
    if (!window.confirm(q)) return;
    act({ clear: which }).catch(() => { for (const s of surfaces) s.said.textContent = 'Couldn’t reach Live sync.'; });
  }

  // ---- painting a surface --------------------------------------------------------------------------------------------------------------------
  function redraw(s) {
    const cv = s.cv, t = s.target;
    if (!t.getClientRects().length) return; // (its page isn't showing)
    cv.style.left = t.offsetLeft + 'px'; cv.style.top = t.offsetTop + 'px';
    const W = t.clientWidth, H = t.clientHeight, dpr = window.devicePixelRatio || 1;
    cv.style.width = W + 'px'; cv.style.height = H + 'px';
    if (cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)) { cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); }
    const g = cv.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    s.segs = new Map();
    const geo = s.geom();
    if (!geo || !(showOn || s.drag)) return;
    g.save();
    g.beginPath(); g.rect(geo.clip[0], geo.clip[1], geo.clip[2], geo.clip[3]); g.clip();
    const px = (a) => pxOf(geo, a);
    if (showOn) for (const d of list(s.view)) s.segs.set(d, render(g, d, px, { tag: true }));
    if (s.drag) render(g, { u: D ? D.me : '', k: s.drag.k, c: colour || null, w: size, pts: s.drag.pts }, px, { alpha: 0.8 });
    g.restore();
  }
  function redrawAll() { for (const s of surfaces) redraw(s); }

  // ---- the Project page (daw.js: its hook X.over is called each time it draws) -------------------------------------------------------------
  // The tracks' oids by lane: the topic's, in the Song page's own order (both from dawview.shown), only for the same song and room.
  function oidsFor(key) { return D && D.key === key && Array.isArray(D.tracks) ? D.tracks : null; }
  if (window.ssDaw) {
    const S = window.ssDaw;
    const dawS = surface({
      name: 'daw', target: S.wrap.querySelector('canvas'),
      bar: (el) => S.page.querySelector('.dbar').append(el),
      geom() {
        const head = S.head, V = S.view(), tr = head && oidsFor(head.key);
        if (!tr || V.W <= V.HEAD || V.H <= V.TOP || !(V.pps > 0)) return null;
        const n = Math.min(tr.length, head.tracks.length), tracks = [];
        for (let i = 0; i < n; i++) tracks.push([String(tr[i][0]), S.laneY(i) - V.TOP, V.LANE, String(tr[i][2] || '')]);
        return { W: V.W, H: V.H, swap: false, clip: [V.HEAD, V.TOP, V.W - V.HEAD, V.H - V.TOP],
          v: { t0: V.x0, t1: V.x0 + (V.W - V.HEAD) / V.pps, aw: V.W - V.HEAD, ah: V.H - V.TOP, tracks: tracks.filter((t) => t[0]),
            crop: { x: V.HEAD / V.W, y: V.TOP / V.H, w: (V.W - V.HEAD) / V.W, h: (V.H - V.TOP) / V.H } } };
      },
      wheel: (e) => S.wrap.querySelector('canvas').dispatchEvent(new WheelEvent('wheel', e)), // (zoom and scroll as ever)
    });
    S.X.over = () => redraw(dawS);
  }

  // ---- the Mixer page: each strip by its track's oid (mixer.js puts it on the strip as data-o) ---------------------------------------------
  const strips = document.querySelector('.mxstrips');
  if (strips) {
    const mixS = surface({
      name: 'mixer', view: 'mixer', target: strips,
      bar: (el) => strips.before(el),
      geom() {
        const els = [...strips.querySelectorAll('.mxstrip[data-o]')];
        if (!els.length) return null;
        const sr = strips.getBoundingClientRect(), W = strips.clientWidth, H = strips.clientHeight;
        const tracks = els.map((el) => { const r = el.getBoundingClientRect(); return [el.dataset.o, r.left - sr.left, r.width, '']; });
        const f = els[0].getBoundingClientRect(), top = f.top - sr.top, sh = Math.max(1, f.height);
        // (swapped: the strips run across, so a strip is a "track" along x and the place down it the "time" along y, 0 at its top, 1 at its foot)
        return { W, H, swap: true, clip: [0, 0, W, H], ok: (a) => a.t >= -0.05 && a.t <= 1.05 && a.d >= -0.1 && a.d <= 1.1,
          v: { t0: 0, t1: 1, aw: sh, ah: W, tracks, crop: { x: top / H, y: 0, w: sh / H, h: 1 } } };
      },
      wheel: (e) => { strips.scrollLeft += e.deltaX + (e.shiftKey ? e.deltaY : 0); if (!e.shiftKey) window.scrollBy(0, e.deltaY); },
    });
    strips.addEventListener('scroll', () => redraw(mixS));
    new ResizeObserver(() => redraw(mixS)).observe(strips);
    new MutationObserver(() => redraw(mixS)).observe(strips, { childList: true }); // (mixer.js rebuilt the strips: reordered, added)
  }

  // ---- the phone's Project view (phonedaw.js: window.ssPhoneDaw, its hook over() called each time it draws) ---------------------------------
  if (window.ssPhoneDaw) {
    const P = window.ssPhoneDaw;
    const phS = surface({
      name: 'phone', target: P.cv,
      bar: (el) => P.bar.append(el),
      geom() {
        const V = P.view(), tr = V.live && D && typeof D.key === 'string' && D.key.slice(0, D.key.lastIndexOf('/')) === V.song ? D.tracks : null;
        if (!tr || V.W <= V.HEAD || V.H <= V.TOP || !(V.pps > 0)) return null;
        const tracks = tr.map((t, i) => [String(t[0]), i * V.LANE - V.y0, V.LANE, String(t[2] || '')]).filter((t) => t[0]);
        return { W: V.W, H: V.H, swap: false, clip: [V.HEAD, V.TOP, V.W - V.HEAD, V.H - V.TOP],
          v: { t0: V.x0, t1: V.x0 + (V.W - V.HEAD) / V.pps, aw: V.W - V.HEAD, ah: V.H - V.TOP, tracks,
            crop: { x: V.HEAD / V.W, y: V.TOP / V.H, w: (V.W - V.HEAD) / V.W, h: (V.H - V.TOP) / V.H } } };
      },
      wheel: (e) => P.cv.dispatchEvent(new WheelEvent('wheel', e)),
    });
    P.over = () => redraw(phS);
  }

  // ---- the History page: each arrange-view drawing from the moment it was drawn (history.js calls this as it draws a frame) -----------------
  // o: { t (the frame's time, UTC s), last (the last frame: everything), X(seconds) -> x, Y(row) -> y, lh (a lane's height), row (Map: the
  // page's track -> its row), places (the page's track -> REAPER's track number), clip: [x, y, w, h] }
  function hist(g, o) {
    if (!showOn || !D || !Array.isArray(D.tracks)) return 0;
    const rowOf = new Map(); // REAPER's track number -> row
    for (const [tid, i] of o.row) if (o.places[tid] != null) rowOf.set(o.places[tid], i);
    const yOf = new Map(); // oid -> row
    for (const t of D.tracks) if (rowOf.has(t[1])) yOf.set(t[0], rowOf.get(t[1]));
    const px = (a) => { const i = yOf.get(a.k); return i == null ? null : { x: o.X(a.t), y: o.Y(i) + Math.max(0, Math.min(1, a.d)) * o.lh }; };
    g.save();
    g.beginPath(); g.rect(o.clip[0], o.clip[1], o.clip[2], o.clip[3]); g.clip();
    let n = 0;
    for (const d of list(undefined)) {
      if (d.id === 'pending' || !(o.last || (typeof d.t === 'number' && d.t <= o.t))) continue;
      const fresh = typeof d.t === 'number' && o.t - d.t < 600 && !o.last; // (drawn within ten minutes of this frame: full strength)
      render(g, Object.assign({}, d, { w: Math.max(1, Math.min(3, (d.w || 3) / 2)) }), px, { alpha: fresh ? 1 : 0.6 });
      n++;
    }
    g.restore();
    return n;
  }
  window.ssDrawLayer = { hist, redraw: redrawAll, get topic() { return D; }, surfaces };
})();
