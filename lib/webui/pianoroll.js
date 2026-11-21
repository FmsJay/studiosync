// StudioSync's piano roll: the shared DAW view, stage 3 (docs/realtime-roadmap.md). A MIDI item's notes over the Project page's arrange view,
// opened by double-clicking (double-tapping) the item, its long-press menu or the edit row's Piano roll button (daw.js's X.openMidi). Drawn
// from the dawmidi topic lib/dawmidi.lua publishes while this page says it's looking (every 10 s); edits (add, move, resize, delete,
// velocity) go to Live sync as actions, which checks them as REAPER's own edits to that item are (claims, Driver only, a bandmate's hold) and
// applies them there in one undo point; the normal sync sends them on. Until the change comes back the note is drawn where it's going; a
// refusal snaps it back with the reason (stage 2's dawedit topic). Phones: tap a note to select it, then drag it (anything else pans), a
// double tap on an empty spot adds a note, a long press opens a menu. A controller lane under the velocity lane (rt-p14) shows one CC number
// of the item as a stepped line with its points: drag a point (time and value), double-click to add one, Delete removes it. Text goes in as
// text, never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const ssDaw = window.ssDaw;
  if (!ssDaw) return;
  const X = ssDaw.X;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const arr = (x) => (Array.isArray(x) ? x : []);
  const clamp = (v, a, z) => Math.max(a, Math.min(z, v));
  const NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'], BLACK = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0];
  const noteName = (k) => NAMES[k % 12] + (Math.floor(k / 12) - 1); // (REAPER's default: 60 is C4)

  // ---- the panel: over the arrange view, inside its box ------------------------------------------------------------------------------
  const box = mk('div', 'proll');
  box.hidden = true;
  box.setAttribute('role', 'region');
  box.setAttribute('aria-label', 'Piano roll');
  box.innerHTML = // (fixed markup, no data in it)
    '<div class="pbar"><span class="pname"></span>' +
    '<label>Grid <select class="pgrid" aria-label="Grid">' +
    '<option value="p">Project</option><option value="1">1/4</option><option value="0.5">1/8</option><option value="0.25">1/16</option>' +
    '<option value="0.125">1/32</option><option value="0.3333333333">1/8 T</option><option value="off">Off</option></select></label>' +
    '<label>Controller <select class="pcc" aria-label="Controller lane"></select></label>' +
    '<label>Velocity <input class="pvel" type="number" min="1" max="127" step="1" aria-label="The selected note’s velocity"></label>' +
    '<button type="button" class="pdel" title="Delete the selected note (Delete)">Delete</button>' +
    '<button type="button" class="pstep" aria-pressed="false" title="Play notes on the keys or a MIDI controller: each goes in at the step cursor">Step input</button>' +
    '<button type="button" class="pback" title="Step cursor back a grid step" hidden>Back</button>' +
    '<button type="button" class="prest" title="Step cursor on a grid step, no note (a rest)" hidden>Rest</button>' +
    '<button type="button" class="pclose" title="Back to the project (Esc)">Close</button></div>' +
    '<div class="pwrap"><canvas class="pcv" tabindex="0" role="img" aria-label="The item’s notes"></canvas></div>' +
    '<div class="pkeys" hidden></div>' +
    '<div class="pmsg dim" role="status"></div>';
  ssDaw.wrap.append(box);
  const q = (s) => box.querySelector(s);
  const cv = q('.pcv'), pwrap = q('.pwrap'), nameEl = q('.pname'), gsel = q('.pgrid'), velIn = q('.pvel'), delB = q('.pdel'), msg = q('.pmsg'), ccSel = q('.pcc');
  const ctx = cv.getContext('2d');
  const menu = mk('div', 'dmenu');
  menu.hidden = true;
  menu.setAttribute('role', 'menu');
  pwrap.append(menu);

  // ---- the state ---------------------------------------------------------------------------------------------------------------------
  let want = null;   // the item asked for: { lane, idx, p, l } as the arrange view drew it
  let M = null;      // its dawmidi topic (ref: where it is now, which edits name)
  let last = null;   // the latest dawmidi topic whatever it was for (only changes come: reopening an unchanged item brings nothing new)
  let N = [];        // M's notes: { n (index), a, z (project seconds), k, v, s (ticks), m }
  let sel = null;    // the selected note: { s, k } (as Live sync names it), or { a, k } until a move or add comes back
  let ovr = null;    // a note drawn where it's going: { n (-1: a new one), a, z, k, v, gone }
  let pend = null;   // the edit sent and not back yet: { id, until, ok, sel }
  let ccN = null;    // the controller lane shown under the velocity lane (a CC number), or null
  let CE = [];       // M's events for it: { n (index among the take's controller events), a (project seconds), v, s (ticks), ch }
  let selC = null;   // the selected controller point: { s } (ticks, as Live sync names it), or { a } until it comes back
  let ovrC = null;   // a point drawn where it's going: { n (-1: a new one), s, a, v, gone }
  let seq = 0, lastLen = 0, lastVel = 100, fitted = false, sayUntil = 0;
  let W = 300, H = 200, px0 = 0, pps = 100, py0 = 0;
  const coarse = () => matchMedia('(pointer: coarse)').matches;
  const narrow = () => W < 480;
  const KEYS = () => (narrow() ? 30 : 44), RULER = 18, VEL = () => (narrow() ? 40 : 56), KH = () => (coarse() ? 14 : 10);
  const xOf = (t) => KEYS() + (t - px0) * pps, timeAt = (x) => px0 + (x - KEYS()) / pps;
  const yOf = (k) => RULER + (127 - k) * KH() - py0, keyAt = (y) => clamp(127 - Math.floor((y - RULER + py0) / KH()), 0, 127);
  const CCH = () => (ccN === null ? 0 : VEL());
  const bottom = () => H - VEL() - CCH(), velBottom = () => H - CCH(); // (the notes end where the velocity lane starts; it ends where the controller lane starts)
  const sameRef = (a, b) => !!(a && b) && a.lane === b.lane && a.idx === b.idx && Math.abs(a.p - b.p) < 0.002 && Math.abs(a.l - b.l) < 0.002;

  function notes() {
    const out = [], nt = arr(M && M.nt), p = M && M.ref ? M.ref.p : 0;
    for (let i = 0, n = 0; i + 5 < nt.length; i += 6, n++) {
      out.push({ n, a: p + nt[i] / 1000, z: p + (nt[i] + nt[i + 1]) / 1000, k: nt[i + 2], v: nt[i + 3], s: nt[i + 4], m: nt[i + 5] === 1 });
    }
    return out;
  }
  const CCNAME = { 1: 'Modulation', 2: 'Breath', 7: 'Volume', 10: 'Pan', 11: 'Expression', 64: 'Sustain', 71: 'Resonance', 74: 'Brightness', 91: 'Reverb', 93: 'Chorus' };
  const ccName = (n) => 'CC ' + n + (CCNAME[n] ? ' ' + CCNAME[n] : '');
  function ccList() { // the box: none, the usual controllers, and any other number the item has (marked)
    const have = arr(M && M.ccs), nums = Array.from(new Set(Object.keys(CCNAME).map(Number).concat(have))).sort((a, z) => a - z), sig = nums.join(',') + '|' + have.join(',');
    if (ccSel.dataset.sig === sig) return;
    ccSel.dataset.sig = sig;
    ccSel.replaceChildren();
    const none = mk('option', '', 'None');
    none.value = '';
    ccSel.append(none);
    for (const n of nums) { const o = mk('option', '', ccName(n) + (have.includes(n) ? ' ●' : '')); o.value = String(n); ccSel.append(o); }
    ccSel.value = ccN === null ? '' : String(ccN);
  }
  function ccEvents() { // M's events for the number shown (the topic carries only that one's)
    const c = M && M.cc, ev = arr(c && c.ev), p = M && M.ref ? M.ref.p : 0;
    CE = [];
    if (!c || c.c !== ccN) return;
    for (let i = 0; i + 4 < ev.length; i += 5) CE.push({ n: ev[i], a: p + ev[i + 1] / 1000, v: ev[i + 2], s: ev[i + 3], ch: ev[i + 4] });
  }
  function ccShown() { // with one being dragged or just sent where it's going
    let list = CE.slice();
    if (ovrC) {
      list = list.filter((x) => x.n !== ovrC.n);
      if (!ovrC.gone) list.push({ n: ovrC.n, a: ovrC.a, v: ovrC.v, s: ovrC.s, ovr: true });
      list.sort((a, z) => a.a - z.a);
    }
    return list;
  }
  function selCC() {
    if (!selC) return null;
    const x = selC.s != null ? CE.find((p) => Math.abs(p.s - selC.s) < 0.5) : CE.find((p) => Math.abs(p.a - selC.a) < 0.003);
    if (x && selC.s == null) selC = { s: x.s };
    return x || null;
  }
  function selNote() {
    if (!sel) return null;
    const x = sel.s != null ? N.find((n) => Math.abs(n.s - sel.s) < 0.5 && n.k === sel.k) : N.find((n) => Math.abs(n.a - sel.a) < 0.003 && n.k === sel.k);
    if (x && sel.s == null) sel = { s: x.s, k: x.k };
    return x || null;
  }

  // ---- the grid: the project's (REAPER's grid setting), or one picked here; in quarter notes, counted from each bar's start ----------
  function gridQ() {
    const v = gsel.value, h = ssDaw.head;
    if (v === 'off') return 0;
    if (v === 'p') return h && h.grid > 0 ? h.grid * 4 : 1;
    return Number(v) || 0;
  }
  function stepAt(t, qn) { // seconds of qn quarter notes in the bar holding t
    const h = ssDaw.head, i = h ? ssDaw.barAt(t) : -1;
    if (i < 0 || !qn) return 0;
    const s = ssDaw.sigAt(i);
    return ssDaw.barLen(i) * qn / (s[1] * 4 / s[2]);
  }
  function snap(t, how) {
    t = Math.max(0, t);
    const qn = gridQ(), h = ssDaw.head, i = h ? ssDaw.barAt(t) : -1, st = stepAt(t, qn);
    if (!(st > 0)) return t;
    const b = h.bars[i];
    return Math.max(0, b + (how || Math.round)((t - b) / st + 1e-9) * st);
  }

  // ---- talking to Live sync ----------------------------------------------------------------------------------------------------------
  function look() { if (ssDaw.onSong() && !document.hidden) ssDaw.act({ look: { item: want || false, cc: ccN === null ? false : ccN } }).catch(() => {}); }
  setInterval(() => { if (want) look(); }, 10000);
  document.addEventListener('visibilitychange', () => { if (want) look(); });
  function edit(o) {
    if (!M || !M.ref) return;
    const id = 'n' + Date.now().toString(36) + (seq++);
    pend = { id, until: performance.now() + 4000, sel: pend ? pend.sel : sel && Object.assign({}, sel), selC: pend ? pend.selC : selC && Object.assign({}, selC) };
    ssDaw.act({ note: Object.assign({ id }, o, { item: M.ref, g: gridQ() }) }).catch(() => snapBack('couldn’t reach Live sync'));
  }
  function snapBack(why) {
    if (pend) { sel = pend.sel; selC = pend.selC; }
    pend = null; ovr = ovrC = null;
    if (why) say('Not changed: ' + why + '.');
    bar(); draw();
  }
  setInterval(() => { if (pend && performance.now() > pend.until) { pend = null; ovr = ovrC = null; bar(); draw(); } }, 1000);
  function takeTopic(m) {
    if (!want || !m || !(sameRef(m.asked, want) || sameRef(m.ref, want))) return;
    if (m.gone) { close(); ssDaw.say('Piano roll closed: ' + m.gone + '.'); return; }
    M = m; N = notes(); ccList(); ccEvents();
    if (pend && pend.ok) { pend = null; ovr = ovrC = null; } // (the change is back)
    ghosts = ghosts.filter((g) => performance.now() < g.until && !N.some((n) => n.k === g.k && Math.abs(n.a - g.a) < 0.003)); // (step input's: back)
    if (!fitted) fit();
    bar();
  }
  function take(t, seed) {
    if (t.dawmidi) last = t.dawmidi;
    if (!seed && t.dawedit && pend && t.dawedit.id === pend.id) { if (t.dawedit.why) snapBack(t.dawedit.why); else pend.ok = true; }
    if (t.dawmidi) takeTopic(t.dawmidi);
    if (!box.hidden) draw();
  }
  addEventListener('ss-state', (e) => take((e.detail || {}).topics || {}, false));
  fetch('api/state').then((r) => r.json()).then((s) => take(s.topics || {}, true)).catch(() => {});

  // ---- step input (docs/rt/rt-vmidi.md): notes played on the on-screen keys (vkeys.js, loaded the first time) or a MIDI controller go in at
  // the step cursor (the dashed line), a grid step long at the velocity played; a chord (notes held together) goes in at one place and the
  // cursor moves on a step when they're all let go. Rest moves it on without a note, Back moves it back. Each note is an ordinary add (the same
  // checks, one undo point each); until it comes back it's drawn faint where it's going.
  let step = null, vk = null, midi = null, ghosts = []; // step: { at (seconds), held: Set of notes, len }
  const stepB = q('.pstep'), restB = q('.prest'), backB = q('.pback'), keysBox = q('.pkeys');
  function loadKeys() {
    if (window.VKeys) return Promise.resolve();
    if (!document.querySelector('link[href="vkeys.css"]')) { const l = mk('link'); l.rel = 'stylesheet'; l.href = 'vkeys.css'; document.head.append(l); }
    return new Promise((res, rej) => { const s = mk('script'); s.src = 'vkeys.js'; s.onload = res; s.onerror = () => rej(new Error('the keyboard (vkeys.js) didn’t load')); document.head.append(s); });
  }
  const stepLen = (at) => stepAt(at, gridQ() || 1) || 0.25;
  function stepStart() {
    const r = M.ref, cur = ssDaw.cur && ssDaw.cur.me ? ssDaw.cur.me.cur : null;
    const at = snap(cur != null && cur >= r.p && cur < r.p + r.l ? cur : r.p, Math.floor);
    return at < r.p - 1e-6 ? r.p : at;
  }
  async function stepOn(on) {
    if (!on || !M || !M.ref) {
      step = null; ghosts = [];
      keysBox.hidden = true;
      if (midi) { midi.stop(); midi = null; }
      if (vk) vk.panic();
      if (on) say('Wait for the notes to load.');
      bar(); draw();
      return;
    }
    try { await loadKeys(); } catch (e) { say(e.message); return; }
    step = { at: stepStart(), held: new Set(), len: 0 };
    keysBox.hidden = false;
    if (!vk) vk = VKeys.create(keysBox, { onMidi: stepMidi, store: 'ss-vkp-' });
    VKeys.midiIn((d) => {
      const k = d[0] & 0xf0;
      if (k === 0x90 || k === 0x80) vk.light(d[1], k === 0x90 && d[2] > 0);
      vk.hear(d);
      stepMidi(d);
    }).then((m) => { if (step && !midi) midi = m; else if (m) m.stop(); }).catch(() => {});
    bar(); draw();
  }
  function stepMidi(d) {
    if (!step || !M || !M.ref) return;
    const kind = d[0] & 0xf0, r = M.ref;
    if (kind === 0x90 && d[2] > 0) {
      if (step.at >= r.p + r.l - 1e-4) { say('The step cursor is at the item’s end: Back, or make the item longer in REAPER.'); return; }
      const len = Math.min(stepLen(step.at), r.p + r.l - step.at);
      edit({ op: 'add', k: d[1], a: step.at, z: step.at + len, v: d[2], step: true }); // (step: a run of these is one undo point on the computer)
      ghosts.push({ a: step.at, z: step.at + len, k: d[1], v: d[2], m: false, until: performance.now() + 4000 });
      step.held.add(d[1]); step.len = len; lastVel = d[2];
      draw();
    } else if ((kind === 0x80 || kind === 0x90) && step.held.delete(d[1]) && !step.held.size) {
      step.at += step.len || stepLen(step.at);
      bar(); draw();
    }
  }
  function stepMove(dir) {
    if (!step || !M || !M.ref) return;
    const r = M.ref;
    step.at = dir > 0 ? Math.min(r.p + r.l, step.at + stepLen(step.at)) : Math.max(r.p, snap(step.at - stepLen(Math.max(r.p, step.at - 1e-4)), Math.round));
    step.held.clear();
    bar(); draw();
  }
  stepB.addEventListener('click', () => stepOn(!step));
  restB.addEventListener('click', () => stepMove(1));
  backB.addEventListener('click', () => stepMove(-1));

  // ---- opening and closing -----------------------------------------------------------------------------------------------------------
  X.openMidi = (h) => {
    want = { lane: h.lane, idx: h.idx, p: h.it.p, l: h.it.l };
    M = null; N = []; CE = []; sel = ovr = pend = selC = ovrC = null; fitted = false;
    box.hidden = false;
    closeMenu();
    look();
    resize();
    takeTopic(last);
    bar(); draw();
    try { cv.focus({ preventScroll: true }); } catch (e) { /* (older browsers) */ }
  };
  function close() {
    stepOn(false);
    want = M = null; N = []; CE = []; sel = ovr = pend = selC = ovrC = null;
    box.hidden = true;
    closeMenu();
    ssDaw.act({ look: { item: false } }).catch(() => {});
    ssDaw.redraw();
  }

  // ---- the view: seconds at the left edge, pixels a second, pixels scrolled down from the top note (127) --------------------------------
  function clampView() {
    pps = clamp(pps, 2, 4000);
    const r = M && M.ref;
    if (r) px0 = clamp(px0, r.p - (W - KEYS()) / pps * 0.9, r.p + r.l);
    py0 = clamp(py0, 0, Math.max(0, 128 * KH() - (bottom() - RULER)));
  }
  function fit() {
    if (!M || !M.ref || W < 10) return;
    fitted = true;
    const r = M.ref;
    pps = (W - KEYS()) / Math.max(0.25, r.l * 1.04);
    px0 = r.p - r.l * 0.02;
    let lo = 127, hi = 0;
    for (const x of N) { lo = Math.min(lo, x.k); hi = Math.max(hi, x.k); }
    if (lo > hi) { lo = 48; hi = 72; }
    py0 = (127 - (lo + hi) / 2) * KH() - (bottom() - RULER) / 2;
    clampView();
  }
  function zoomAt(px, f) { const t = timeAt(px); pps = clamp(pps * f, 2, 4000); px0 = t - (px - KEYS()) / pps; clampView(); }
  function resize() {
    const r = pwrap.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    if (r.width < 10 || r.height < 10) return;
    W = r.width; H = r.height;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    cv.style.width = W + 'px'; cv.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (!fitted) fit();
    clampView(); draw();
  }
  new ResizeObserver(() => { if (!box.hidden) resize(); }).observe(pwrap);
  new MutationObserver(() => draw()).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

  // ---- drawing -----------------------------------------------------------------------------------------------------------------------
  let raf = 0;
  function drawNote(g, x, col, on, C) {
    const kh = KH(), xa = xOf(x.a), xz = xOf(x.z), y = yOf(x.k);
    if (xz < KEYS() || xa > W || y > bottom() || y + kh < RULER) return;
    g.globalAlpha = x.m ? 0.3 : 0.45 + 0.5 * x.v / 127;
    g.fillStyle = col; g.fillRect(xa, y + 1, Math.max(2, xz - xa - 1), kh - 2);
    g.globalAlpha = 1;
    g.strokeStyle = on ? C.text : col; g.lineWidth = on ? 2 : 1;
    g.strokeRect(xa + 0.5, y + 1.5, Math.max(1, xz - xa - 2), kh - 3);
    g.lineWidth = 1;
    if (xz - xa > 30 && kh >= 12) { g.fillStyle = C.text; g.fillText(noteName(x.k), xa + 3, y + kh - 3); }
  }
  function gridLines(g, C, t0, t1) {
    const h = ssDaw.head, bars = arr(h && h.bars);
    const qn = gridQ();
    for (let i = Math.max(0, ssDaw.barAt(t0)); i < bars.length && bars[i] <= t1; i++) {
      const x = xOf(bars[i]), len = ssDaw.barLen(i), s = ssDaw.sigAt(i), num = s[1], beat = len / num;
      g.fillStyle = C.line; g.fillRect(Math.round(x), RULER, 1, H - RULER);
      if (beat * pps >= 8) { g.globalAlpha = 0.45; for (let k = 1; k < num; k++) g.fillRect(Math.round(x + k * beat * pps), RULER, 1, H - RULER); }
      const st = qn ? len * qn / (num * 4 / s[2]) : 0;
      if (st > 0 && st * pps >= 6 && Math.abs(st - beat) > 1e-6) {
        g.globalAlpha = 0.2;
        for (let tt = st; tt < len - 1e-6; tt += st) g.fillRect(Math.round(x + tt * pps), RULER, 1, H - RULER);
      }
      g.globalAlpha = 1;
    }
  }
  // The controller lane: the number's events as a stepped line (each value holds to the next point) and its points.
  function drawCC(g, C, col, top) {
    const kw = KEYS(), h = H - top, y = (v) => top + 4 + (1 - v / 127) * (h - 8), list = ccShown(), s = selCC();
    g.fillStyle = C.panel; g.fillRect(kw, top, W - kw, h);
    g.fillStyle = C.line; g.fillRect(kw, top, W - kw, 1);
    g.globalAlpha = 0.35; g.fillRect(kw, Math.round(y(64)), W - kw, 1); g.globalAlpha = 1;
    if (!list.length) { g.fillStyle = C.dim; g.fillText((coarse() ? 'Double-tap' : 'Double-click') + ' to add a point to ' + ccName(ccN), kw + 8, top + h / 2 + 4); return; }
    g.strokeStyle = col; g.lineWidth = 1.5; g.beginPath();
    g.moveTo(kw, y(list[0].v));
    list.forEach((p, j) => { const x = xOf(p.a); if (j > 0) g.lineTo(x, y(list[j - 1].v)); g.lineTo(x, y(p.v)); });
    g.lineTo(W, y(list[list.length - 1].v)); g.stroke(); g.lineWidth = 1;
    for (const p of list) {
      const x = xOf(p.a);
      if (x < kw - 4 || x > W + 4) continue;
      const on = p.ovr || p === s;
      g.fillStyle = on ? C.accent : col; g.beginPath(); g.arc(x, y(p.v), on ? 5 : coarse() ? 4 : 3, 0, Math.PI * 2); g.fill();
      if (on) { g.fillStyle = C.text; g.fillText(String(p.v), Math.min(W - 18, x + 7), y(p.v) - 4); }
    }
  }
  function draw() {
    if (box.hidden || !ssDaw.onSong()) return;
    const C = ssDaw.colours(), g = ctx, kw = KEYS(), kh = KH(), bot = bottom();
    g.fillStyle = C.bg; g.fillRect(0, 0, W, H);
    const t0 = timeAt(kw), t1 = timeAt(W), s = selNote(), col = (M && M.c) || C.accent;
    g.font = '10px system-ui, sans-serif';
    // the rows (black keys shaded, a line under each C), outside the item dimmed, the grid
    g.save(); g.beginPath(); g.rect(kw, RULER, W - kw, H - RULER); g.clip();
    for (let k = keyAt(bot - 1); k <= keyAt(RULER); k++) {
      const y = yOf(k);
      if (BLACK[k % 12]) { g.fillStyle = C.panel; g.globalAlpha = 0.8; g.fillRect(kw, y, W - kw, kh); g.globalAlpha = 1; }
      if (k % 12 === 0) { g.fillStyle = C.line; g.fillRect(kw, y + kh - 1, W - kw, 1); }
    }
    if (M && M.ref) {
      const xa = xOf(M.ref.p), xz = xOf(M.ref.p + M.ref.l);
      g.fillStyle = C.text; g.globalAlpha = 0.07;
      if (xa > kw) g.fillRect(kw, RULER, xa - kw, bot - RULER);
      if (xz < W) g.fillRect(xz, RULER, W - xz, bot - RULER);
      g.globalAlpha = 1;
    }
    gridLines(g, C, t0, t1);
    // the notes (one being dragged or just sent where it's going)
    g.save(); g.beginPath(); g.rect(kw, RULER, W - kw, bot - RULER); g.clip();
    for (const x of N) if (!(ovr && ovr.n === x.n)) drawNote(g, x, col, x === s, C);
    if (ovr && !ovr.gone) drawNote(g, ovr, col, true, C);
    g.globalAlpha = 0.5;
    for (const x of ghosts) drawNote(g, x, col, false, C);
    g.globalAlpha = 1;
    g.restore();
    if (step) { // (the step cursor)
      const x = Math.round(xOf(step.at));
      if (x >= kw && x <= W) { g.strokeStyle = C.accent; g.setLineDash([4, 3]); g.beginPath(); g.moveTo(x + 0.5, RULER); g.lineTo(x + 0.5, bot); g.stroke(); g.setLineDash([]); }
    }
    // the velocity lane
    const vb = velBottom();
    g.fillStyle = C.panel; g.fillRect(kw, bot, W - kw, vb - bot);
    g.fillStyle = C.line; g.fillRect(kw, bot, W - kw, 1);
    const vh = vb - bot - 8;
    for (const x0 of N) {
      const x = ovr && ovr.n === x0.n ? (ovr.gone ? null : ovr) : x0;
      if (!x) continue;
      const xa = xOf(x.a);
      if (xa < kw - 3 || xa > W) continue;
      const hv = x.v / 127 * vh;
      g.fillStyle = x0 === s ? C.accent : col; g.globalAlpha = x.m ? 0.4 : 0.9;
      g.fillRect(xa, vb - 4 - hv, 3, hv); g.fillRect(xa - 1, vb - 5 - hv, 5, 2);
    }
    if (ovr && ovr.n < 0 && !ovr.gone) { const hv = ovr.v / 127 * vh; g.fillStyle = C.accent; g.fillRect(xOf(ovr.a), vb - 4 - hv, 3, hv); }
    g.globalAlpha = 1;
    if (ccN !== null) drawCC(g, C, col, vb);
    g.restore();
    // the keyboard
    g.fillStyle = C.panel; g.fillRect(0, RULER, kw, H - RULER);
    g.save(); g.beginPath(); g.rect(0, RULER, kw, bot - RULER); g.clip();
    for (let k = keyAt(bot - 1); k <= keyAt(RULER); k++) {
      const y = yOf(k);
      if (BLACK[k % 12]) { g.fillStyle = C.text; g.globalAlpha = 0.75; g.fillRect(0, y, kw * 0.6, kh); g.globalAlpha = 1; }
      else { g.fillStyle = C.line; g.fillRect(0, y + kh - 1, kw, 1); }
      if (k % 12 === 0 && kh >= 9) { g.fillStyle = C.dim; g.fillText(noteName(k), kw * 0.62 > 20 ? kw * 0.62 - 18 : 1, y + kh - 2); }
    }
    g.restore();
    g.fillStyle = C.line; g.fillRect(kw - 1, RULER, 1, H - RULER);
    g.fillStyle = C.dim; g.fillText('Vel', 3, bot + 14);
    if (ccN !== null) g.fillText('CC ' + ccN, 3, vb + 14);
    // the ruler: bar numbers
    g.fillStyle = C.panel; g.fillRect(0, 0, W, RULER);
    g.fillStyle = C.line; g.fillRect(0, RULER - 1, W, 1);
    const bars = arr(ssDaw.head && ssDaw.head.bars);
    let every = 1;
    while (bars.length > 1 && ssDaw.barLen(Math.max(0, ssDaw.barAt(t0))) * pps * every < 30) every *= 2;
    g.fillStyle = C.dim;
    for (let i = Math.max(0, ssDaw.barAt(t0)); i < bars.length && bars[i] <= t1; i++) {
      const x = xOf(bars[i]);
      if (i % every === 0 && x >= kw) { g.fillText(String(i + 1), x + 3, 12); g.fillRect(Math.round(x), 0, 1, RULER); }
    }
    // the edit cursor and the play cursor
    const cur = ssDaw.cur, pp = ssDaw.playPos();
    if (cur && cur.me && cur.me.cur != null) { const x = xOf(cur.me.cur); if (x >= kw && x <= W) { g.fillStyle = C.accent; g.globalAlpha = 0.8; g.fillRect(Math.round(x), RULER, 1, H - RULER); g.globalAlpha = 1; } }
    if (pp != null) {
      const x = xOf(pp);
      if (x >= kw && x <= W) { g.fillStyle = cur.play.rec ? C.rec : C.play; g.fillRect(Math.round(x) - 1, 0, 2, H); }
      if (!raf) raf = requestAnimationFrame(() => { raf = 0; draw(); });
    }
    if (!M) { g.fillStyle = C.dim; g.font = '13px system-ui, sans-serif'; g.fillText(want ? 'Loading notes…' : '', kw + 12, RULER + 24); }
  }

  // ---- the bar and messages ----------------------------------------------------------------------------------------------------------
  function say(t) { msg.textContent = t; sayUntil = performance.now() + 5000; }
  setInterval(() => { if (sayUntil && performance.now() > sayUntil) { sayUntil = 0; bar(); } }, 1000);
  function bar() {
    const s = selNote(), ok = !!(ssDaw.engine && M);
    nameEl.textContent = M ? (M.track ? M.track + ': ' : '') + (M.name || 'MIDI item') : want ? 'Loading notes…' : '';
    delB.disabled = !(ok && (s || selCC()));
    velIn.disabled = !(ok && s);
    if (!s) velIn.value = '';
    else if (document.activeElement !== velIn) velIn.value = String(s.v);
    stepB.setAttribute('aria-pressed', String(!!step));
    stepB.disabled = !ok && !step;
    restB.hidden = backB.hidden = !step;
    if (sayUntil) return;
    msg.textContent = !ssDaw.engine ? 'Live sync isn’t running, so nothing can change.' : M && M.more ? 'Only the first 4000 notes are shown.'
      : step ? 'Step input: play a note or a chord (the keys below, the computer’s keys, a MIDI controller); it goes in at the dashed line, a grid step long · Rest skips a step'
      : coarse() ? 'Double-tap to add a note · tap one to select it, then drag it · hold for more'
        : 'Double-click to add a note · drag a note to move it, its right edge to resize it · Delete removes it';
  }
  gsel.addEventListener('change', draw);
  ccSel.addEventListener('change', () => { // (a controller lane under the velocity lane, or none)
    ccN = ccSel.value === '' ? null : +ccSel.value;
    selC = ovrC = null; CE = [];
    look();
    resize(); bar(); draw();
  });
  q('.pclose').addEventListener('click', close);
  delB.addEventListener('click', () => { const s = selNote(), c = s ? null : selCC(); if (s) delNote(s); else if (c) delCC(c); });
  velIn.addEventListener('change', () => {
    const s = selNote(), v = Math.round(Number(velIn.value));
    if (s && v >= 1 && v <= 127 && v !== s.v) velNote(s, v); else bar();
  });

  // ---- edits ---------------------------------------------------------------------------------------------------------------------------
  const ident = (x) => ({ n: x.n, s: x.s, k: x.k });
  function addNote(t, k) {
    const a = snap(t, Math.floor), len = lastLen || stepAt(a, gridQ() || 1) || 0.25;
    ovr = { n: -1, a, z: a + len, k, v: lastVel, m: false };
    sel = { a, k };
    edit({ op: 'add', k, a, z: a + len, v: lastVel });
    bar(); draw();
  }
  function moveNote(x, a, k) {
    ovr = Object.assign({}, x, { a, z: a + (x.z - x.a), k });
    sel = { a, k };
    edit(Object.assign({ op: 'move', to: a, tok: k }, ident(x)));
    bar(); draw();
  }
  function resizeNote(x, z) {
    ovr = Object.assign({}, x, { z });
    lastLen = z - x.a;
    edit(Object.assign({ op: 'resize', z }, ident(x)));
    bar(); draw();
  }
  function delNote(x) {
    ovr = { n: x.n, gone: true };
    sel = null;
    edit(Object.assign({ op: 'delete' }, ident(x)));
    bar(); draw();
  }
  // controller points of the number shown (the same path as a note's edit: Live sync checks them as an edit to the item)
  const cident = (x) => ({ n: x.n, s: x.s, c: ccN });
  function addCC(t, v) {
    const r = M.ref, a = clamp(snap(t, Math.floor), r.p, r.p + r.l - 0.001);
    ovrC = { n: -1, a, v };
    selC = { a }; sel = null;
    edit({ op: 'cc_add', c: ccN, a, v });
    bar(); draw();
  }
  function moveCC(x, a, v) {
    ovrC = { n: x.n, s: x.s, a, v };
    selC = { a }; sel = null;
    edit(Object.assign({ op: 'cc_move', to: a, v }, cident(x)));
    bar(); draw();
  }
  function delCC(x) {
    ovrC = { n: x.n, gone: true };
    selC = null;
    edit(Object.assign({ op: 'cc_delete' }, cident(x)));
    bar(); draw();
  }
  function velNote(x, v) {
    ovr = Object.assign({}, x, { v });
    lastVel = v;
    edit(Object.assign({ op: 'vel', v }, ident(x)));
    bar(); draw();
  }

  // ---- the pointer: select, drag to move (a note's right edge resizes), the velocity lane, pan, pinch, double-click to add ---------------
  function noteAt(x, y, touch) {
    if (y < RULER || y > bottom() || x < KEYS()) return null;
    const k = keyAt(y), pad = touch ? 8 : 2, edge = touch ? 14 : 6;
    for (let j = N.length - 1; j >= 0; j--) {
      const n = N[j];
      if (n.k !== k) continue;
      const xa = xOf(n.a), xz = xOf(n.z);
      if (x >= xa - pad && x <= xz + pad) return { x: n, mode: xz - xa > edge * 2 && xz - x < edge ? 'resize' : 'move' };
    }
    return null;
  }
  function ccAt(x, y, touch) { // a controller point under a point
    if (ccN === null || y < velBottom() || x < KEYS()) return null;
    const top = velBottom(), h = H - top, yy = (v) => top + 4 + (1 - v / 127) * (h - 8);
    let best = null, bd = touch ? 14 : 7;
    for (const p of CE) { const d = Math.hypot(xOf(p.a) - x, yy(p.v) - y); if (d < bd) { bd = d; best = p; } }
    return best;
  }
  const inCC = (x, y) => ccN !== null && y >= velBottom() && x > KEYS();
  const ccVal = (y) => clamp(Math.round((1 - (y - velBottom() - 4) / (H - velBottom() - 8)) * 127), 0, 127);
  function velAt(x, y, touch) {
    if (y < bottom() || y >= velBottom() || x < KEYS()) return null;
    let best = null, bd = touch ? 12 : 5;
    for (const n of N) { const d = Math.abs(xOf(n.a) + 1 - x); if (d < bd) { bd = d; best = n; } }
    return best;
  }
  const pts = new Map();
  let grab = null, moved = false, pinch = null, lp = null, lpFired = false, tapAt = 0;
  cv.addEventListener('pointerdown', (e) => {
    cv.setPointerCapture(e.pointerId);
    closeMenu();
    pts.set(e.pointerId, { x: e.offsetX, y: e.offsetY, x0: e.offsetX, y0: e.offsetY });
    moved = false; grab = null; clearTimeout(lp); lp = null; lpFired = false;
    if (pts.size === 2) { const [a, b] = [...pts.values()]; pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), mx: (a.x + b.x) / 2 }; return; }
    if (pts.size > 1) return;
    const x = e.offsetX, y = e.offsetY, touch = e.pointerType !== 'mouse';
    if (touch) lp = setTimeout(() => { lp = null; lpFired = true; grab = null; openMenu(x, y); }, 550);
    if (e.button > 0 || !M) return; // (right button: the menu)
    const cp = ccAt(x, y, touch);
    if (cp) { // (a controller point: on a phone only the selected one moves)
      if (touch && cp !== selCC()) return;
      grab = { kind: 'cc', x: cp };
      if (!touch) { selC = { s: cp.s }; sel = null; bar(); draw(); }
      return;
    }
    const v = velAt(x, y, touch), h = v ? null : noteAt(x, y, touch), hit = v || (h && h.x);
    if (touch && !(hit && hit === selNote())) return; // (a phone: only the selected note moves; anything else pans)
    if (v) grab = { kind: 'vel', x: v };
    else if (h) grab = { kind: h.mode, x: h.x, t0: timeAt(x), k0: keyAt(y) };
    if (grab && !touch) { sel = { s: hit.s, k: hit.k }; selC = null; bar(); draw(); }
  });
  function dragTo(x, y) {
    const n = grab.x;
    if (grab.kind === 'cc') { const r = M.ref; ovrC = { n: n.n, s: n.s, a: clamp(snap(timeAt(x)), r.p, r.p + r.l - 0.001), v: ccVal(y) }; draw(); return; }
    if (grab.kind === 'vel') ovr = Object.assign({}, n, { v: clamp(Math.round((velBottom() - 4 - y) / (VEL() - 8) * 127), 1, 127) });
    else if (grab.kind === 'move') {
      const a = snap(n.a + timeAt(x) - grab.t0);
      ovr = Object.assign({}, n, { a, z: a + (n.z - n.a), k: clamp(n.k + keyAt(y) - grab.k0, 0, 127) });
    } else {
      const z = snap(n.z + timeAt(x) - grab.t0);
      ovr = Object.assign({}, n, { z: z > n.a + 0.001 ? z : n.a + (stepAt(n.a, gridQ()) || 0.01) });
    }
    draw();
  }
  cv.addEventListener('pointermove', (e) => {
    const p = pts.get(e.pointerId);
    if (!p) {
      if (e.pointerType === 'mouse') { const h = noteAt(e.offsetX, e.offsetY, false); cv.style.cursor = h ? (h.mode === 'resize' ? 'ew-resize' : 'move') : ''; }
      return;
    }
    const dx = e.offsetX - p.x, dy = e.offsetY - p.y;
    p.x = e.offsetX; p.y = e.offsetY;
    if (Math.hypot(p.x - p.x0, p.y - p.y0) > 6) { moved = true; if (lp) { clearTimeout(lp); lp = null; } }
    if (pts.size === 2 && pinch) {
      const [a, b] = [...pts.values()], d = Math.hypot(a.x - b.x, a.y - b.y), mx = (a.x + b.x) / 2;
      if (pinch.d > 10) zoomAt(mx, d / pinch.d);
      px0 -= (mx - pinch.mx) / pps;
      pinch = { d, mx }; clampView(); draw();
      return;
    }
    if (!moved || pts.size !== 1) return;
    if (grab) { dragTo(e.offsetX, e.offsetY); return; }
    px0 -= dx / pps; py0 -= dy; clampView(); draw();
  });
  function up(e) {
    const was = pts.get(e.pointerId);
    pts.delete(e.pointerId);
    if (pts.size < 2) pinch = null;
    clearTimeout(lp); lp = null;
    if (lpFired) { lpFired = false; grab = null; return; }
    const g = grab;
    grab = null;
    if (g && moved && g.kind === 'cc') { // (a controller point dragged)
      const o = ovrC, n = g.x;
      if (e.type === 'pointerup' && o && (Math.abs(o.a - n.a) > 1e-4 || o.v !== n.v)) moveCC(n, o.a, o.v); else ovrC = null;
      draw();
      return;
    }
    if (g && moved) {
      const o = ovr, n = g.x;
      if (e.type !== 'pointerup' || !o) { ovr = null; draw(); return; }
      if (g.kind === 'vel') { if (o.v !== n.v) velNote(n, o.v); else ovr = null; }
      else if (g.kind === 'move') { if (Math.abs(o.a - n.a) > 1e-4 || o.k !== n.k) moveNote(n, o.a, o.k); else ovr = null; }
      else if (Math.abs(o.z - n.z) > 1e-4) resizeNote(n, o.z);
      else ovr = null;
      draw();
      return;
    }
    if (!was || moved || pts.size || e.type !== 'pointerup') return;
    const x = e.offsetX, y = e.offsetY, touch = e.pointerType !== 'mouse', now = performance.now();
    const h = noteAt(x, y, touch), hit = h ? h.x : velAt(x, y, touch), cph = ccAt(x, y, touch);
    if (now - tapAt < 300 && !hit && !cph && M && y > RULER && y < bottom() && x > KEYS()) { tapAt = 0; addNote(timeAt(x), keyAt(y)); return; }
    if (now - tapAt < 300 && !cph && M && inCC(x, y)) { tapAt = 0; addCC(timeAt(x), ccVal(y)); return; }
    tapAt = now;
    sel = hit ? { s: hit.s, k: hit.k } : null;
    selC = cph ? { s: cph.s } : null;
    bar(); draw();
  }
  cv.addEventListener('pointerup', up);
  cv.addEventListener('pointercancel', up);
  cv.addEventListener('wheel', (e) => {
    e.preventDefault();
    const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? H : 1;
    if (e.ctrlKey || e.metaKey) zoomAt(e.offsetX, Math.exp(-e.deltaY * k * 0.0025));
    else if (e.shiftKey) px0 += e.deltaY * k / pps;
    else { px0 += e.deltaX * k / pps; py0 += e.deltaY * k; }
    clampView(); draw();
  }, { passive: false });

  // ---- keys: Delete removes the selected note, arrows move it (Shift: an octave), Esc closes ---------------------------------------------
  document.addEventListener('keydown', (e) => {
    if (box.hidden || !ssDaw.onSong() || /^(INPUT|SELECT|TEXTAREA)$/.test((e.target && e.target.tagName) || '')) return;
    if (e.key === 'Escape') { if (!menu.hidden) closeMenu(); else close(); e.preventDefault(); return; }
    const s = selNote(), c = s ? null : selCC();
    if ((!s && !c) || pend) return; // (one at a time: the next names the note as it comes back)
    if (e.key === 'Delete' || e.key === 'Backspace') { if (s) delNote(s); else delCC(c); }
    else if (!s) return; // (a controller point: only Delete)
    else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      const k = clamp(s.k + (e.key === 'ArrowUp' ? 1 : -1) * (e.shiftKey ? 12 : 1), 0, 127);
      if (k !== s.k) moveNote(s, s.a, k);
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      const st = stepAt(s.a, gridQ() || 1) || 0.1;
      moveNote(s, snap(s.a + (e.key === 'ArrowRight' ? st : -st)), s.k);
    } else return;
    e.preventDefault();
  });

  // ---- the menu (a long press, or right-click) -----------------------------------------------------------------------------------------
  function closeMenu() { menu.hidden = true; }
  function openMenu(x, y) {
    if (!M) return;
    const touch = coarse(), h = noteAt(x, y, touch), hit = h ? h.x : velAt(x, y, touch), cph = ccAt(x, y, touch);
    menu.replaceChildren();
    const add = (text, fn) => { const b = mk('button', '', text); b.type = 'button'; b.setAttribute('role', 'menuitem'); b.addEventListener('click', () => { closeMenu(); fn(); }); menu.append(b); };
    if (cph) {
      selC = { s: cph.s }; sel = null;
      add('Delete controller point (' + cph.v + ')', () => delCC(cph));
    } else if (inCC(x, y)) {
      const t = timeAt(x), v = ccVal(y);
      add('Add a controller point here (' + v + ')', () => addCC(t, v));
    } else if (hit) {
      sel = { s: hit.s, k: hit.k }; selC = null;
      add('Delete note', () => delNote(hit));
      add('Velocity…', () => {
        const r = prompt('Velocity (1 to 127)', String(hit.v)), v = Math.round(Number(r));
        if (r != null && v >= 1 && v <= 127 && v !== hit.v) velNote(hit, v);
      });
    } else if (y > RULER && y < bottom() && x > KEYS()) {
      const t = timeAt(x), k = keyAt(y);
      add('Add a note here (' + noteName(k) + ')', () => addNote(t, k));
    }
    if (!menu.childElementCount) return;
    add('Close', () => {});
    menu.hidden = false;
    menu.style.left = Math.max(4, Math.min(x, W - menu.offsetWidth - 4)) + 'px';
    menu.style.top = Math.max(4, Math.min(y, H - menu.offsetHeight - 4)) + 'px';
    bar(); draw();
  }
  cv.addEventListener('contextmenu', (e) => { e.preventDefault(); openMenu(e.offsetX, e.offsetY); });
  document.addEventListener('pointerdown', (e) => { if (!menu.hidden && !menu.contains(e.target) && e.target !== cv) closeMenu(); });
  ssDaw.redraw(); // (the edit row's Piano roll button: X.openMidi is here now)
})();
