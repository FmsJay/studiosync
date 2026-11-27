// StudioSync's Mixer page, the shared DAW view's stage 4: the studio's tracks as channel strips (volume, pan, mute, solo, a meter, plug-ins
// with their bypass, sends with their levels), the master read only, and your monitor mix of everyone's live audio. Reads the "mix", "mixm",
// "mixmon" and "mixr" topics (lib/webmixer.lua, only while a page shows this: it says so every 10 s, and "not any more" when hidden); sends
// on the "mixer" topic. Live sync checks every move as it checks your own edits, and a refused one snaps back with why. Faders, pan and sends
// drag from where they are (no jump on a tap), double-tap (or double-click) resets them, arrow keys move them. Names go in as text, never
// HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (!window.ssTabs) return;
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const arr = (x) => (Array.isArray(x) ? x : []);
  const SEND_EVERY = 60;   // ms between a drag's moves sent (Shared controllers send 20 a second)
  const HOLD_FOR = 1500;   // ms the page keeps showing your value after you let go, until Live sync's comes back
  // the fader scale: -60 to +12 dB, straight in dB, the bottom off (0 dB at 5/6 of the way up)
  const LO = -60, HI = 12;
  const dbOf = (v) => (v > 0 ? 20 * Math.log10(v) : -Infinity);
  const posOfGain = (v) => Math.max(0, Math.min(1, (dbOf(v) - LO) / (HI - LO)));
  const gainOfPos = (p) => (p <= 0.001 ? 0 : Math.pow(10, (LO + p * (HI - LO)) / 20));
  const dbText = (v) => { const d = dbOf(v); return d <= LO + 0.05 ? '-inf' : (d > 0 ? '+' : '') + d.toFixed(1); };
  const panText = (p) => (Math.abs(p) < 0.005 ? 'C' : (p < 0 ? 'L' : 'R') + Math.round(Math.abs(p) * 100));

  // One slider: dragged from where it is (relative, so a tap never jumps it), double-tap resets, arrow keys step. o: { label, vertical, pos
  // (value -> 0..1), val (0..1 -> value), reset, step (in position), text (value -> words), move (value, done) }.
  function slider(o) {
    const el = mk('div', 'mxsl' + (o.vertical ? ' mxv' : ' mxh'));
    const fill = mk('div', 'mxfill'), knob = mk('div', 'mxknob');
    el.append(fill, knob);
    el.tabIndex = 0;
    el.setAttribute('role', 'slider');
    el.setAttribute('aria-label', o.label);
    el.setAttribute('aria-orientation', o.vertical ? 'vertical' : 'horizontal');
    const s = { el, value: o.reset, held: 0, dragging: false, disabled: false, sentAt: 0, timer: 0 };
    function paint() {
      const p = o.pos(s.value) * 100;
      if (o.vertical) { knob.style.bottom = p + '%'; fill.style.height = p + '%'; } else { knob.style.left = p + '%'; fill.style.width = p + '%'; }
      el.setAttribute('aria-valuetext', o.text(s.value));
      el.title = o.label + ': ' + o.text(s.value) + (s.why ? ' (' + s.why + ')' : '');
    }
    function send(done) {
      clearTimeout(s.timer);
      const now = performance.now();
      if (done || now - s.sentAt >= SEND_EVERY) { s.sentAt = now; o.move(s.value, done); return; }
      s.timer = setTimeout(() => send(false), SEND_EVERY - (now - s.sentAt));
    }
    function set(v, done) { s.value = v; s.held = performance.now() + HOLD_FOR; paint(); send(done); }
    let start = null, lastTap = 0;
    el.addEventListener('pointerdown', (e) => {
      if (e.button > 0) return;
      if (s.disabled) { if (s.why) said.textContent = 'Locked: ' + s.why + '.'; return; } // (a touch screen has no tooltips)
      e.preventDefault();
      el.focus({ preventScroll: true });
      const now = performance.now();
      if (now - lastTap < 320) { lastTap = 0; set(o.reset, true); return; } // (a double tap: back to 0 dB / centre)
      lastTap = now;
      const r = el.getBoundingClientRect();
      start = { x: e.clientX, y: e.clientY, p: o.pos(s.value), size: o.vertical ? r.height : r.width, moved: false };
      el.setPointerCapture(e.pointerId);
      s.dragging = true;
    });
    el.addEventListener('pointermove', (e) => {
      if (!start) return;
      const d = o.vertical ? start.y - e.clientY : e.clientX - start.x;
      if (!start.moved && Math.abs(d) < 3) return;
      start.moved = true;
      const fine = e.shiftKey ? 0.25 : 1; // (Shift: finer)
      set(o.val(Math.max(0, Math.min(1, start.p + (d / Math.max(40, start.size)) * fine))), false);
    });
    const end = () => {
      if (!start) return;
      const moved = start.moved;
      start = null;
      s.dragging = false;
      if (moved) set(s.value, true);
    };
    el.addEventListener('pointerup', end);
    el.addEventListener('pointercancel', end);
    el.addEventListener('keydown', (e) => {
      if (s.disabled) return;
      const k = { ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1, PageUp: 5, PageDown: -5 }[e.key];
      if (!k) return;
      e.preventDefault();
      set(o.val(Math.max(0, Math.min(1, o.pos(s.value) + k * o.step))), true);
    });
    s.show = (v) => { if (s.dragging || performance.now() < s.held) return; s.value = v; paint(); };
    s.drop = () => { s.held = 0; }; // (a refusal: Live sync's value shows again at once)
    s.enable = (on, why) => { s.disabled = !on; s.why = on ? '' : why; el.classList.toggle('off', !on); el.setAttribute('aria-disabled', String(!on)); paint(); };
    paint();
    return s;
  }
  const fader = (label, move) => slider({ label, vertical: true, pos: posOfGain, val: gainOfPos, reset: 1, step: 1 / (HI - LO), text: (v) => dbText(v) + ' dB', move });
  const hfader = (label, move) => slider({ label, pos: posOfGain, val: gainOfPos, reset: 1, step: 1 / (HI - LO), text: (v) => dbText(v) + ' dB', move });
  const panner = (label, move) => slider({ label, pos: (p) => (p + 1) / 2, val: (x) => Math.round((x * 2 - 1) * 100) / 100, reset: 0, step: 0.01, text: panText, move });

  // ---- the page ------------------------------------------------------------------------------------------------------------------------
  const page = mk('section', 'mixer');
  page.setAttribute('aria-labelledby', 'mix-h');
  const h = mk('h2', '', 'Mixer');
  h.id = 'mix-h';
  const note = mk('p', 'dim mxnote', 'Solo is only yours: it isn’t sent to the band. The master is each person’s own listening level. Plug-in windows stay in REAPER.');
  const said = mk('p', 'mxsaid');
  said.setAttribute('role', 'status');
  const strips = mk('div', 'mxstrips');
  const monH = mk('h2', '', 'Your monitor mix');
  const monNote = mk('p', 'dim mxnote', 'How loud each bandmate’s live audio comes in, only for you: never the song’s mix, never sent.');
  const mon = mk('div', 'mxmon');
  page.append(h, note, said, strips, monH, monNote, mon);
  // View / Edit (rt-ui7): the Project page's one switch (daw.js), shown here too. In View the song's controls are locked (volume, pan, mute,
  // plug-ins, sends; volume and pan stay yours with local mixing on); solo and your monitor mix are only yours, so they always work.
  const VIEW = 'View: switch to Edit, top left, to change it';
  const editing = () => !window.ssDaw || ssDaw.editing();
  if (window.ssDaw) { h.after(ssDaw.modeSwitch(page)); ssDaw.onEdit(() => { last.mix = null; draw(); }); }

  let shown = false, n = 0;
  const want = (on) => { if (on !== false && !(shown && !document.hidden)) return; ssTabs.act('mixer', { want: on !== false }).catch(() => {}); };
  setInterval(want, 10000);
  document.addEventListener('visibilitychange', () => { if (shown) want(!document.hidden); });
  ssTabs.add('mixer', 'Mixer', page, (on) => { shown = on; want(on); if (on) { last = {}; draw(); } });

  const pending = {}; // move number -> the slider (or button) it came from, for a refusal
  // (this page's own prefix: Live sync keeps only the last answer, which another page, or this one before a reload, may have asked for)
  const me = 'mx' + Math.random().toString(36).slice(2, 10) + '-';
  function act(o, from) {
    const k = o.fx ? 'fx' : o.send ? 'send' : o.set && (o.set.k === 'm' || (o.set.k !== 's' && !(last.mix && last.mix.local_mix))) ? 'set' : null;
    if (k) { // (a change to the song: only in Edit, and it says so, as the Project page's edits do)
      if (!editing()) { said.textContent = VIEW + '.'; if (from && from.drop) from.drop(); last.mix = null; draw(); return; }
      o = Object.assign({}, o, { [k]: Object.assign({}, o[k], { edit: true }) });
      if (window.ssDaw) ssDaw.edited();
    }
    const id = me + (++n);
    if (from) pending[n] = from;
    ssTabs.act('mixer', Object.assign({ id }, o)).catch(() => { said.textContent = 'Couldn’t reach Live sync.'; if (from && from.drop) from.drop(); });
  }

  // ---- strips --------------------------------------------------------------------------------------------------------------------------
  let rows = {}, sig = '', masterF = null, masterM = null;
  function meter() { const m = mk('div', 'mxmeter'); m.append(mk('div', 'mxpeak')); m.setAttribute('aria-hidden', 'true'); return m; }
  function setMeter(m, db) {
    if (!m) return;
    const p = Math.max(0, Math.min(1, (db - LO) / (HI - LO)));
    m.firstChild.style.height = (p * 100) + '%';
    m.classList.toggle('hot', db >= 0);
  }
  function build(m) {
    strips.replaceChildren();
    rows = {};
    for (const s of arr(m.strips)) {
      const r = { o: s.o };
      const el = mk('div', 'mxstrip');
      if (s.o) el.dataset.o = s.o; // (the drawing layer finds each strip by its track: draw.js, rt-draw)
      if (s.rgb) el.style.setProperty('--mxc', s.rgb);
      const name = mk('div', 'mxname', s.name || '(no name)');
      name.title = s.name || '';
      // plug-ins
      const fx = mk('ul', 'mxfx');
      r.fx = arr(s.fx).map((f) => {
        const li = mk('li'), b = mk('button', 'mxfxb', f.n || 'plug-in');
        b.type = 'button';
        b.disabled = !!f.x;
        b.title = f.x ? 'This computer’s own, or running on a bandmate’s: change it in REAPER.' : 'On or bypassed, for everyone (the normal sync). Its window stays in REAPER.';
        b.addEventListener('click', () => { const on = b.getAttribute('aria-pressed') !== 'true'; b.setAttribute('aria-pressed', String(on)); act({ fx: { o: s.o, i: f.i, name: f.n, on } }, { drop() { last.mix = null; draw(); } }); });
        li.append(b);
        fx.append(li);
        return { b, f };
      });
      if (!r.fx.length) fx.append(mk('li', 'dim mxnone', 'no plug-ins'));
      // sends
      const sends = mk('div', 'mxsends');
      r.sends = arr(s.sends).map((x) => {
        const row = mk('div', 'mxsend');
        const sl = hfader('Send to ' + x.name, (v, done) => act({ send: { o: s.o, i: x.i, to: x.to, v, done } }, sl));
        row.append(mk('span', 'mxsendn' + (x.m ? ' muted' : ''), '→ ' + x.name), sl.el);
        sends.append(row);
        return { sl, x };
      });
      // pan, the fader and its meter, mute and solo
      r.pan = panner(s.name + ' pan', (v, done) => act({ set: { o: s.o, k: 'p', v, done } }, r.pan));
      r.vol = fader(s.name + ' volume', (v, done) => act({ set: { o: s.o, k: 'v', v, done } }, r.vol));
      r.meter = meter();
      r.db = mk('div', 'mxdb');
      const fz = mk('div', 'mxfz');
      fz.append(r.meter, r.vol.el);
      r.by = mk('div', 'mxby');
      r.why = mk('div', 'mxwhy');
      r.mute = mk('button', 'mxm', 'M');
      r.solo = mk('button', 'mxs', 'S');
      r.mute.type = r.solo.type = 'button';
      r.mute.setAttribute('aria-label', s.name + ' mute');
      r.solo.setAttribute('aria-label', s.name + ' solo, only yours');
      r.solo.title = 'Solo: only on your computer, never sent to the band.';
      r.mute.addEventListener('click', () => { const on = r.mute.getAttribute('aria-pressed') !== 'true'; r.mute.setAttribute('aria-pressed', String(on)); act({ set: { o: s.o, k: 'm', v: on ? 1 : 0, done: true } }, { drop() { last.mix = null; draw(); } }); });
      r.solo.addEventListener('click', () => { const on = r.solo.getAttribute('aria-pressed') !== 'true'; r.solo.setAttribute('aria-pressed', String(on)); act({ set: { o: s.o, k: 's', v: on ? 1 : 0, done: true } }); });
      const btns = mk('div', 'mxbtns');
      btns.append(r.mute, r.solo);
      r.pant = mk('div', 'mxpant');
      el.append(name, r.why, fx, sends, r.pan.el, r.pant, r.by, fz, r.db, btns);
      strips.append(el);
      rows[s.o] = r;
    }
    // the master: read only, each listener's own
    const el = mk('div', 'mxstrip mxmaster');
    masterF = fader('Master volume (yours only)', () => {});
    masterF.enable(false, 'your own listening level, set in REAPER');
    masterM = meter();
    const fz = mk('div', 'mxfz');
    fz.append(masterM, masterF.el);
    masterF.db = mk('div', 'mxdb');
    el.append(mk('div', 'mxname', 'Master'), mk('p', 'dim mxmnote', 'Your own level, not shared'), fz, masterF.db);
    strips.append(el);
    if (!arr(m.strips).length) strips.prepend(mk('p', 'dim', 'No tracks yet (a new track shows once Live sync has looked at it).'));
  }
  function values(m) {
    for (const s of arr(m.strips)) {
      const r = rows[s.o];
      if (!r) continue;
      const ed = editing(), may = !s.why && ed, faders = may || !!m.local_mix;
      r.vol.enable(faders, s.why || VIEW); r.pan.enable(faders, s.why || VIEW);
      r.vol.show(s.v); r.pan.show(s.p);
      r.db.textContent = dbText(r.vol.value);
      r.pant.textContent = 'pan ' + panText(r.pan.value);
      r.mute.disabled = !may;
      r.mute.title = may ? 'Mute, for everyone' : s.why || VIEW;
      r.mute.setAttribute('aria-pressed', String(!!s.m));
      r.solo.setAttribute('aria-pressed', String(!!s.s));
      arr(s.fx).forEach((f, k) => { const x = r.fx[k]; if (x) { x.b.setAttribute('aria-pressed', String(!!f.on)); if (!f.x) x.b.disabled = !may; } });
      arr(s.sends).forEach((x, k) => { const y = r.sends[k]; if (y) { y.sl.enable(ed, VIEW); y.sl.show(x.v); } });
      const by = s.by ? [...new Set(Object.values(s.by))] : [];
      r.by.textContent = by.length ? by.join(', ') + ' moving' : '';
      r.why.textContent = s.why || '';
      r.why.title = s.why || '';
    }
    if (masterF && m.master) { masterF.show(m.master.v); masterF.db.textContent = dbText(m.master.v); }
  }

  // ---- monitor mix ---------------------------------------------------------------------------------------------------------------------
  let monRows = {}, monSig = '';
  function drawMon(t) {
    if (!t || !t.on) {
      monSig = '';
      mon.replaceChildren(mk('p', 'dim', t && t.error ? 'Couldn’t read live audio: ' + t.error : 'Live audio is off for this studio (Settings > Studio).'));
      return;
    }
    const s = JSON.stringify([!!t.play, arr(t.peers).map((p) => [p.peer, p.name])]);
    if (s !== monSig) {
      monSig = s;
      mon.replaceChildren();
      monRows = {};
      const all = mk('div', 'mxmrow');
      const allS = hfader('Everyone', (v, done) => act({ all: Math.min(4, v) }, done ? allS : null));
      all.append(mk('span', 'mxmname', 'Everyone'), allS.el);
      mon.append(all);
      monRows[''] = { talk: allS };
      for (const p of arr(t.peers)) {
        const row = mk('div', 'mxmrow');
        const r = { lv: meter() };
        r.lv.classList.add('mxmlv');
        r.talk = hfader(p.name + ' Talk', (v) => act({ mon: { peer: p.peer, talk: Math.min(4, v) } }, r.talk));
        r.mute = mk('button', 'mxm', 'Mute');
        r.mute.type = 'button';
        r.mute.addEventListener('click', () => { const on = r.mute.getAttribute('aria-pressed') !== 'true'; r.mute.setAttribute('aria-pressed', String(on)); act({ mon: { peer: p.peer, mute: on } }); });
        r.name = mk('span', 'mxmname', p.name);
        const talk = mk('label', 'mxml');
        talk.append(mk('span', 'dim', t.play ? 'Talk' : 'Volume'), r.talk.el);
        row.append(r.name, r.lv, talk);
        if (t.play) {
          r.play = hfader(p.name + ' Play', (v) => act({ mon: { peer: p.peer, play: Math.min(4, v) } }, r.play));
          const play = mk('label', 'mxml');
          play.append(mk('span', 'dim', 'Play'), r.play.el);
          play.title = 'Their armed tracks, as they monitor them.';
          row.append(play);
        }
        row.append(r.mute);
        mon.append(row);
        monRows[p.peer] = r;
      }
      if (!arr(t.peers).length) mon.append(mk('p', 'dim', t.running ? 'Nobody else is heard here yet.' : 'Starts while Live sync runs with a studio project in front.'));
    }
    monRows[''].talk.show(t.all);
    for (const p of arr(t.peers)) {
      const r = monRows[p.peer];
      if (!r) continue;
      r.talk.show(p.talk);
      if (r.play) r.play.show(p.play);
      r.mute.setAttribute('aria-pressed', String(!!p.mute));
      r.name.classList.toggle('dim', !p.live);
      r.name.title = p.live ? '' : 'Not heard yet';
      setMeter(r.lv, Math.max(p.lt, p.lp));
    }
  }

  let last = {};
  function draw() {
    if (!shown) return;
    const T = ssTabs.topics;
    const m = T.mix;
    if (m !== last.mix) {
      last.mix = m;
      if (!m) { strips.replaceChildren(mk('p', 'dim', 'Asking Live sync…')); sig = ''; }
      else {
        const s = JSON.stringify(arr(m.strips).map((x) => [x.o, x.name, x.rgb, arr(x.fx).map((f) => [f.n, f.x]), arr(x.sends).map((y) => [y.i, y.to, y.name, y.m])]));
        if (s !== sig) { sig = s; build(m); }
        values(m);
      }
    }
    const mm = T.mixm;
    if (mm && mm !== last.mixm) {
      last.mixm = mm;
      for (const o in rows) setMeter(rows[o].meter, (mm.p || {})[o] ?? LO);
      setMeter(masterM, mm.master ?? LO);
    }
    if (T.mixmon !== last.mixmon) { last.mixmon = T.mixmon; drawMon(T.mixmon); }
    const r = T.mixr;
    if (r && r !== last.mixr && typeof r.id === 'string' && r.id.startsWith(me)) {
      last.mixr = r;
      const k = Number(r.id.slice(me.length)), from = pending[k];
      for (const p in pending) if (Number(p) <= k) delete pending[p]; // (a drag's earlier moves were answered by the same tick's last)
      if (r.why) { said.textContent = 'Not made: ' + r.why + '.'; if (from && from.drop) from.drop(); last.mix = null; draw(); }
      else if (from) said.textContent = '';
    }
  }
  addEventListener('ss-state', draw);
  addEventListener('ss-tabs', draw);
})();
