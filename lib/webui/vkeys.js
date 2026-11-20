// StudioSync's on-screen instrument (docs/rt/rt-vmidi.md): a keyboard (octave shift, velocity from where a key is touched or the pen's
// pressure, sustain, chords with several fingers, sliding along the keys) and a 4x4 drum pad (General MIDI drums by default, each pad's note
// can be changed), the same on a phone and in a desktop browser (the computer's keys play it too: A W S E D F T G Y H U J K O L P, Z/X for the
// octave; the pads on 1-4, Q-R, A-F, Z-V; Space holds sustain). Plus MIDI controllers through Web MIDI (Chrome, Edge, Android) and a small
// Web Audio sound to hear it on this device. It only makes MIDI bytes: where they go is the page's (phonedaw.js's Play view: a take on the
// phone, live into REAPER; pianoroll.js: step input). Touch: pointer events, no click delay, no scrolling or zooming on the instrument
// (vkeys.css: touch-action none). GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  if (window.VKeys) return;
  const NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'], BLACK = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0];
  const noteName = (k) => NAMES[k % 12] + (Math.floor(k / 12) - 1); // (REAPER's default: 60 is C4)
  const clamp = (v, a, z) => Math.max(a, Math.min(z, v));
  const keep = (k, v) => { try { if (v === undefined) return localStorage.getItem(k) || ''; localStorage.setItem(k, v); } catch (e) {} return ''; };
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  // General MIDI drums, pads 1-16 from the bottom left (as an MPC's), and names for the notes a pad may be set to.
  const GM_PADS = [36, 38, 42, 46, 37, 39, 44, 49, 45, 47, 48, 51, 41, 53, 55, 56];
  const GM = { 35: 'Kick 2', 36: 'Kick', 37: 'Side stick', 38: 'Snare', 39: 'Clap', 40: 'Snare 2', 41: 'Floor tom', 42: 'Hat', 43: 'Floor tom 2',
    44: 'Pedal hat', 45: 'Low tom', 46: 'Open hat', 47: 'Mid tom', 48: 'High tom', 49: 'Crash', 50: 'High tom 2', 51: 'Ride', 52: 'China',
    53: 'Bell', 54: 'Tambourine', 55: 'Splash', 56: 'Cowbell', 57: 'Crash 2', 59: 'Ride 2', 75: 'Claves', 76: 'Block' };
  const PAD_KEYS = ['z', 'x', 'c', 'v', 'a', 's', 'd', 'f', 'q', 'w', 'e', 'r', '1', '2', '3', '4'];
  const KEY_KEYS = 'awsedftgyhujkolp;';
  const KEYS_CH = 0, PADS_CH = 9; // (keys on channel 1, pads on 10: General MIDI's drums)

  // ---- the instrument -----------------------------------------------------------------------------------------------------------------
  // opts: { onMidi(bytes, timeStamp), modes: ['keys', 'pads'] (or one), sound: true (a "Hear it here" switch), store: 'ss-vk-' (settings' keys) }.
  // -> { el, light, panic, hear, ... }
  function create(host, opts) {
    opts = opts || {};
    const modes = opts.modes || ['keys', 'pads'];
    const P = opts.store || 'ss-vk-'; // (where its settings are kept: the piano roll's step keys have their own)
    let pads = GM_PADS.slice();
    try { const p = JSON.parse(keep(P + 'pads') || 'null'); if (Array.isArray(p) && p.length === 16 && p.every((n) => n >= 0 && n <= 127)) pads = p; } catch (e) {}
    const oct = parseInt(keep(P + 'oct'), 10);
    const S = { mode: modes.includes(keep(P + 'mode')) ? keep(P + 'mode') : modes[0], oct: clamp(Number.isFinite(oct) ? oct : 4, 0, 8),
      vel: keep(P + 'vel') || 'touch', fixed: clamp(+keep(P + 'fixed') || 100, 1, 127), sus: false, edit: false, hear: keep(P + 'hear') !== '0' };
    const el = mk('div', 'vk');
    const bar = mk('div', 'vkbar');
    const btn = (text, title, fn) => { const b = mk('button', '', text); b.type = 'button'; if (title) b.title = title; b.addEventListener('click', fn); return b; };
    const modeB = modes.map((m) => { const b = btn(m === 'keys' ? 'Keys' : 'Pads', '', () => setMode(m)); b.dataset.m = m; return b; });
    const octDn = btn('‹', 'An octave down (Z)', () => octave(-1)), octUp = btn('›', 'An octave up (X)', () => octave(1)), octL = mk('span', 'vkoct');
    const velS = mk('select');
    velS.setAttribute('aria-label', 'Velocity');
    for (const [v, t] of [['touch', 'Velocity: where you touch'], ['fixed', 'Velocity: fixed']]) { const o = mk('option', '', t); o.value = v; velS.append(o); }
    velS.value = S.vel;
    const velN = mk('input');
    Object.assign(velN, { type: 'number', min: 1, max: 127, step: 1, value: S.fixed, title: 'The fixed velocity' });
    velN.setAttribute('aria-label', 'Fixed velocity');
    const susB = btn('Sustain', 'Tap to latch, hold to sustain while held (Space)', () => {});
    const editB = btn('Edit pads', 'Tap a pad to give it another note', () => { S.edit = !S.edit; draw(); });
    const resetB = btn('GM pads', 'Back to General MIDI drums', () => { pads = GM_PADS.slice(); keep(P + 'pads', JSON.stringify(pads)); draw(); });
    const hearL = mk('label', 'vkhear');
    const hearC = mk('input');
    hearC.type = 'checkbox'; hearC.checked = S.hear;
    hearL.append(hearC, document.createTextNode(' Hear it here'));
    const info = mk('span', 'vkinfo dim');
    if (modes.length > 1) bar.append(...modeB);
    bar.append(octDn, octL, octUp, velS, velN, susB, editB, resetB);
    if (opts.sound !== false) bar.append(hearL);
    bar.append(info);
    const play = mk('div', 'vkplay');
    play.tabIndex = 0;
    play.setAttribute('role', 'application');
    play.setAttribute('aria-label', 'On-screen instrument: touch to play');
    el.append(bar, play);
    host.append(el);

    // ---- the layout: white keys to fit the width from the octave's C; pads 4x4 -----------------------------------------------------------
    let cells = []; // { k (note), x, y, w, h, black, pad (0-15), el }
    const lit = new Map(); // note -> how many hold it (fingers, the computer's keys, a controller)
    function layout() {
      const W = play.clientWidth || 300, H = play.clientHeight || 160;
      cells = [];
      if (S.mode === 'pads') {
        const w = W / 4, h = H / 4;
        for (let i = 0; i < 16; i++) cells.push({ k: pads[i], pad: i, x: (i % 4) * w, y: (3 - Math.floor(i / 4)) * h, w, h });
        return;
      }
      const coarse = matchMedia('(pointer: coarse)').matches;
      const whites = clamp(Math.round(W / (coarse ? 46 : 34)), 7, 36), ww = W / whites;
      let k = 12 * (S.oct + 1), wi = 0;
      while (wi < whites && k <= 127) {
        if (BLACK[k % 12]) cells.push({ k, x: wi * ww - ww * 0.32, y: 0, w: ww * 0.64, h: H * 0.6, black: true });
        else { cells.push({ k, x: wi * ww, y: 0, w: ww, h: H }); wi++; }
        k++;
      }
    }
    function draw() {
      layout();
      play.className = 'vkplay ' + S.mode + (S.edit ? ' editing' : '');
      play.replaceChildren(...cells.slice().sort((a, z) => (a.black ? 1 : 0) - (z.black ? 1 : 0)).map((c) => {
        const d = mk('div', c.pad != null ? 'vkpad' : c.black ? 'vkb' : 'vkw');
        Object.assign(d.style, { left: c.x + 'px', top: c.y + 'px', width: c.w + 'px', height: c.h + 'px' });
        if (c.pad != null) {
          d.append(mk('span', 'vkpn', GM[c.k] || noteName(c.k)), mk('span', 'vkpk dim', noteName(c.k) + ' · ' + c.k));
        } else if (c.k % 12 === 0) d.append(mk('span', 'vkkn', noteName(c.k)));
        if (lit.get(c.k)) d.classList.add('on');
        c.el = d;
        return d;
      }));
      for (const b of modeB) b.setAttribute('aria-pressed', String(b.dataset.m === S.mode));
      const keys = S.mode === 'keys';
      octDn.hidden = octUp.hidden = octL.hidden = !keys;
      octL.textContent = 'C' + S.oct;
      editB.hidden = resetB.hidden = keys;
      editB.setAttribute('aria-pressed', String(S.edit));
      resetB.hidden = keys || !S.edit;
      velN.hidden = S.vel !== 'fixed';
      susB.setAttribute('aria-pressed', String(S.sus));
      info.textContent = S.edit ? 'Tap a pad to change its note' : S.vel === 'touch' ? (keys ? 'Lower on a key: louder' : 'Lower on a pad: louder') : '';
    }
    function paint(k) { for (const c of cells) if (c.k === k && c.el) c.el.classList.toggle('on', !!lit.get(k)); }
    function light(k, on) { lit.set(k, Math.max(0, (lit.get(k) || 0) + (on ? 1 : -1))); if (!lit.get(k)) lit.delete(k); paint(k); }

    // ---- MIDI out ---------------------------------------------------------------------------------------------------------------------------
    let synth = null;
    function hear(bytes) { if (S.hear && opts.sound !== false) { synth = synth || makeSynth(); synth.midi(bytes); } }
    function out(bytes, ts) {
      hear(bytes);
      if (opts.onMidi) opts.onMidi(bytes, ts || performance.now());
    }
    const ch = () => (S.mode === 'pads' ? PADS_CH : KEYS_CH);
    const sounding = new Map(); // who -> { k, ch }: each finger, computer key
    function on(who, k, v, ts) {
      off(who, ts);
      const c = ch();
      sounding.set(who, { k, ch: c });
      light(k, true);
      out([0x90 | c, k, clamp(Math.round(v), 1, 127)], ts);
    }
    function off(who, ts) {
      const s = sounding.get(who);
      if (!s) return;
      sounding.delete(who);
      light(s.k, false);
      out([0x80 | s.ch, s.k, 0], ts);
    }
    function sustain(v, ts) {
      if (S.sus === v) return;
      S.sus = v;
      susB.setAttribute('aria-pressed', String(v));
      for (const c of new Set([KEYS_CH, PADS_CH])) out([0xb0 | c, 64, v ? 127 : 0], ts);
    }
    function panic() {
      for (const who of [...sounding.keys()]) off(who);
      sustain(false);
    }

    // ---- touch, pen, mouse -------------------------------------------------------------------------------------------------------------
    function hit(x, y) {
      for (const c of cells) if (c.black && x >= c.x && x < c.x + c.w && y >= c.y && y < c.y + c.h) return c;
      for (const c of cells) if (!c.black && x >= c.x && x < c.x + c.w && y >= c.y && y < c.y + c.h) return c;
      return null;
    }
    function velocity(e, c, y) {
      if (S.vel === 'fixed') return S.fixed;
      // (a pen's pressure, or a screen that reports a real one; most phones say 0, 0.5 or 1 for every touch)
      const p = e.pointerType !== 'mouse' && e.pressure > 0 && e.pressure !== 0.5 && e.pressure !== 1 ? e.pressure : null;
      if (p != null) return 20 + p * 107;
      return 25 + clamp((y - c.y) / c.h, 0, 1) * 102;
    }
    const pos = (e) => { const r = play.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
    play.addEventListener('pointerdown', (e) => {
      if (e.button > 0) return;
      e.preventDefault(); // (no focus-scroll, no text selection, no emulated mouse events)
      try { play.setPointerCapture(e.pointerId); } catch (err) { /* (a pointer already gone) */ }
      const [x, y] = pos(e), c = hit(x, y);
      if (!c) return;
      if (S.edit && c.pad != null) {
        const r = prompt('Note for this pad (0 to 127; General MIDI: 36 kick, 38 snare, 42 hat)', String(c.k)), n = Math.round(Number(r));
        if (r != null && n >= 0 && n <= 127) { pads[c.pad] = n; keep(P + 'pads', JSON.stringify(pads)); draw(); }
        return;
      }
      on('p' + e.pointerId, c.k, velocity(e, c, y), e.timeStamp);
    });
    play.addEventListener('pointermove', (e) => {
      const s = sounding.get('p' + e.pointerId);
      if (!s || S.mode !== 'keys') return; // (pads: a finger stays on the pad it hit)
      const [x, y] = pos(e), c = hit(x, y);
      if (c && c.k !== s.k) on('p' + e.pointerId, c.k, velocity(e, c, y), e.timeStamp); // (sliding along the keys)
    });
    for (const t of ['pointerup', 'pointercancel', 'lostpointercapture']) play.addEventListener(t, (e) => off('p' + e.pointerId, e.timeStamp));
    play.addEventListener('contextmenu', (e) => e.preventDefault()); // (a long press is a held note, not a menu)
    // Sustain: a tap latches it (and a second lets go), holding it sustains only while held.
    let susAt = 0, susWas = false;
    susB.addEventListener('pointerdown', (e) => { e.preventDefault(); susWas = S.sus; susAt = performance.now(); sustain(!susWas, e.timeStamp); });
    susB.addEventListener('pointerup', (e) => { if (!susWas && performance.now() - susAt > 350) sustain(false, e.timeStamp); });
    susB.addEventListener('keydown', (e) => { if (e.key === 'Enter') sustain(!S.sus); });

    // ---- the computer's keys (when the instrument shows and nothing is being typed) -----------------------------------------------------------
    const typing = (t) => t && (/^(INPUT|SELECT|TEXTAREA)$/.test(t.tagName) || t.isContentEditable);
    const shown = () => el.offsetParent !== null;
    function keyNote(key) {
      if (S.mode === 'pads') { const i = PAD_KEYS.indexOf(key); return i >= 0 ? pads[i] : null; }
      const i = KEY_KEYS.indexOf(key);
      return i >= 0 ? clamp(12 * (S.oct + 1) + i, 0, 127) : null;
    }
    document.addEventListener('keydown', (e) => {
      if (!shown() || typing(e.target) || e.ctrlKey || e.metaKey || e.altKey) return;
      const key = e.key.toLowerCase();
      if (e.key === ' ') { e.preventDefault(); if (!e.repeat) sustain(true, e.timeStamp); return; }
      if (e.repeat) { if (keyNote(key) != null) e.preventDefault(); return; }
      if (S.mode === 'keys' && (key === 'z' || key === 'x')) { octave(key === 'z' ? -1 : 1); e.preventDefault(); return; }
      const k = keyNote(key);
      if (k == null) return;
      e.preventDefault();
      on('k' + key, k, S.vel === 'fixed' ? S.fixed : 100, e.timeStamp);
    });
    document.addEventListener('keyup', (e) => {
      if (e.key === ' ') { if (shown()) sustain(false, e.timeStamp); return; }
      off('k' + e.key.toLowerCase(), e.timeStamp);
    });
    addEventListener('blur', () => { for (const who of [...sounding.keys()]) if (who[0] === 'k') off(who); }); // (a key held when the window lost focus)

    // ---- settings ---------------------------------------------------------------------------------------------------------------------------
    function setMode(m) { if (m === S.mode) return; panic(); S.mode = m; S.edit = false; keep(P + 'mode', m); draw(); }
    function octave(d) { const o = clamp(S.oct + d, 0, 8); if (o === S.oct) return; S.oct = o; keep(P + 'oct', String(o)); draw(); }
    velS.addEventListener('change', () => { S.vel = velS.value; keep(P + 'vel', S.vel); draw(); });
    velN.addEventListener('change', () => { S.fixed = clamp(Math.round(+velN.value) || 100, 1, 127); velN.value = S.fixed; keep(P + 'fixed', String(S.fixed)); });
    hearC.addEventListener('change', () => { S.hear = hearC.checked; keep(P + 'hear', S.hear ? '1' : '0'); if (!S.hear && synth) synth.quiet(); });
    new ResizeObserver(() => draw()).observe(play);
    draw();
    return {
      el, light, panic, noteName, hear, // (hear: a controller's notes through this device's sound too, when it's on)
      get mode() { return S.mode; },
      setHear(v) { if (opts.sound === false) return; S.hear = !!v; hearC.checked = S.hear; if (!S.hear && synth) synth.quiet(); },
      held: () => sounding.size,
      redraw: draw,
    };
  }

  // ---- a small sound on this device: a soft triangle for keys, simple drums on channel 10 --------------------------------------------------
  function makeSynth() {
    const ctx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'interactive' });
    const master = ctx.createGain();
    master.gain.value = 0.5;
    master.connect(ctx.destination);
    const voices = new Map(), sus = new Set(), held = new Set();
    let noise = null;
    function noiseBuf() {
      if (noise) return noise;
      noise = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
      const d = noise.getChannelData(0);
      for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
      return noise;
    }
    function drum(k, v) {
      const t = ctx.currentTime, g = ctx.createGain(), amp = v / 127;
      g.connect(master);
      const kick = k === 35 || k === 36, tom = [41, 43, 45, 47, 48, 50].includes(k), cym = [49, 51, 52, 53, 55, 57, 59].includes(k);
      if (kick || tom) {
        const o = ctx.createOscillator(), f = kick ? 55 : 80 + (k - 41) * 12;
        o.frequency.setValueAtTime(f * 3, t); o.frequency.exponentialRampToValueAtTime(f, t + 0.08);
        g.gain.setValueAtTime(amp, t); g.gain.exponentialRampToValueAtTime(0.001, t + (kick ? 0.35 : 0.45));
        o.connect(g); o.start(t); o.stop(t + 0.5);
        return;
      }
      const n = ctx.createBufferSource(), f = ctx.createBiquadFilter();
      n.buffer = noiseBuf();
      const hat = [42, 44, 46].includes(k), len = k === 46 ? 0.35 : hat ? 0.06 : cym ? 1.2 : 0.18;
      f.type = hat || cym ? 'highpass' : 'bandpass'; f.frequency.value = hat ? 8000 : cym ? 5000 : 1800;
      g.gain.setValueAtTime(amp * (hat ? 0.5 : 0.8), t); g.gain.exponentialRampToValueAtTime(0.001, t + len);
      n.connect(f); f.connect(g); n.start(t); n.stop(t + len + 0.05);
    }
    function stopVoice(key) {
      const vo = voices.get(key);
      if (!vo) return;
      voices.delete(key);
      const t = ctx.currentTime;
      vo.g.gain.cancelScheduledValues(t); vo.g.gain.setTargetAtTime(0, t, 0.08);
      vo.o.stop(t + 0.5);
    }
    return {
      midi(b) {
        if (ctx.state === 'suspended') ctx.resume();
        const kind = b[0] & 0xf0, c = b[0] & 15, key = c * 128 + b[1];
        if (kind === 0x90 && b[2] > 0) {
          if (c === PADS_CH) return drum(b[1], b[2]);
          stopVoice(key);
          const o = ctx.createOscillator(), g = ctx.createGain(), t = ctx.currentTime;
          o.type = 'triangle'; o.frequency.value = 440 * Math.pow(2, (b[1] - 69) / 12);
          g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.35 * b[2] / 127, t + 0.005); g.gain.setTargetAtTime(0.2 * b[2] / 127, t + 0.01, 0.4);
          o.connect(g); g.connect(master); o.start(t);
          voices.set(key, { o, g });
          held.add(key);
        } else if (kind === 0x80 || kind === 0x90) {
          held.delete(key);
          if (sus.has(c)) return; // (sustain down: it rings on until sustain comes up)
          stopVoice(key);
        } else if (kind === 0xb0 && b[1] === 64) {
          if (b[2] >= 64) sus.add(c);
          else { sus.delete(c); for (const k2 of [...voices.keys()]) if (Math.floor(k2 / 128) === c && !held.has(k2)) stopVoice(k2); }
        } else if (kind === 0xb0 && (b[1] === 123 || b[1] === 120)) { for (const k2 of [...voices.keys()]) stopVoice(k2); }
      },
      quiet() { for (const k2 of [...voices.keys()]) stopVoice(k2); sus.clear(); held.clear(); },
    };
  }

  // ---- MIDI controllers (Web MIDI: Chrome, Edge, Android; not Safari or iPhone) ------------------------------------------------------------
  // cb(bytes, timeStamp, inputName) for every channel message; onList(names) when controllers come and go. -> Promise of { stop() } or null.
  async function midiIn(cb, onList) {
    if (!navigator.requestMIDIAccess) return null;
    const access = await navigator.requestMIDIAccess();
    const mine = new Set();
    const msg = (e) => { const d = e.data; if (d && d.length >= 2 && d[0] >= 0x80 && d[0] < 0xf0) cb([d[0], d[1], d.length > 2 ? d[2] : 0], e.timeStamp, e.target && e.target.name); };
    function attach() {
      for (const i of access.inputs.values()) if (!mine.has(i)) { mine.add(i); i.addEventListener('midimessage', msg); }
      if (onList) onList([...access.inputs.values()].filter((i) => i.state !== 'disconnected').map((i) => i.name || i.id));
    }
    access.addEventListener('statechange', attach);
    attach();
    return { stop() { access.removeEventListener('statechange', attach); for (const i of mine) i.removeEventListener('midimessage', msg); mine.clear(); } };
  }

  window.VKeys = { create, midiIn, noteName, GM_PADS, GM };
})();
