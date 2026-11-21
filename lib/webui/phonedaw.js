// StudioSync on the phone, stage 2 (docs/realtime-roadmap.md "StudioSync on the phone"): the phone app's Project and Sheet views and its
// headphones, beside the Record page (record.html; record.js's state is shared: takes, topic, rec, songs). Everything works from what the
// phone kept when it last heard the computer (phonefile.js's views store, per project) and syncs when the computer answers.
//   Project  the project's tracks and items drawn for touch from the Project page's own topics (lib/dawview.lua: daw, dawc<k>), with this
//            phone's takes that haven't gone in yet drawn in place (dashed). Drag to move, pinch to zoom, tap the ruler for the start, a track's
//            name for its levels, an item for its takes. Which take of an item plays (lib/phonedaw.lua: checked by the room's rules, as an edit
//            on the Project page) and a track's volume and mute in the project (the Mixer page's checked moves, lib/webmixer.lua) need the
//            computer; this phone's own levels for its playback (the mix, its takes per track) don't. Listen plays the kept mix and this phone's
//            takes from the cursor. Comments go to the project's chat with the place in front ("[1:23.4 Vox] ..."), kept here until they've gone.
//   Sheet    the Sheet page's lyrics and chords (lib/songsheet.lua's topic, read only here), big, the section you're in lit and followed:
//            along to the phone's own mix too, with no computer.
//   Headphones (on the Record view) hearing yourself with a reverb, the mix's level and an EQ on everything this phone plays: Web Audio,
//            only in the headphones (the take is recorded dry; nothing goes into the project).
// Bandmates' text goes in as text (textContent, canvas fillText), never HTML. GPL-3.0-or-later. (James, rt)
'use strict';
(() => {
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, fn) => { const b = mk('button', '', text); b.type = 'button'; b.addEventListener('click', fn); return b; };
  const clamp = (v, a, z) => Math.max(a, Math.min(z, v));
  const PEAK = {};
  '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_'.split('').forEach((c, i) => { PEAK[c] = i / 63; });
  const act = (t, o) => fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
    body: JSON.stringify(Object.assign({ topic: t }, o)) }).then((r) => { if (!r.ok) throw new Error('the computer said ' + r.status); });
  const say = (t) => { $('awhy').textContent = t || ''; };

  // ---- what Live sync says, kept per project for opening offline ------------------------------------------------------------------------
  const T = {}; // topics as last received (the stream sends only the changed ones)
  const views = {}; // song -> { song, at, head, chunks, pd, sheet, beatmap, chat }: what this phone kept
  const keySong = (k) => (typeof k === 'string' && k.includes('/') ? k.slice(0, k.lastIndexOf('/')) : null);
  const front = () => (online() && topic ? topic.song : null);
  function liveView() {
    const song = front();
    if (!song) return null;
    const head = T.daw && keySong(T.daw.key) === song ? T.daw : null, chunks = [];
    if (head) for (let k = 0; k < (head.chunks || 0); k++) { const c = T['dawc' + k]; chunks.push(c && c.key === head.key && !c.gone ? c : null); }
    return { song, head, chunks, pd: T.phonedaw && keySong(T.phonedaw.key) === song ? T.phonedaw : null, sheet: T.sheet || null, beatmap: T.beatmap || null, chat: T.chat || null };
  }
  function view(song) {
    const v = song && song === front() ? liveView() : null, k = views[song] || {};
    if (!v) return k.song ? k : null;
    return { song, live: true, head: v.head || k.head, chunks: v.head ? v.chunks : k.chunks, pd: v.pd || k.pd, sheet: v.sheet || k.sheet,
      beatmap: v.beatmap || k.beatmap, chat: v.chat || k.chat };
  }
  let keepTimer = 0;
  function keepSoon() {
    if (keepTimer) return;
    keepTimer = setTimeout(() => {
      keepTimer = 0;
      const v = liveView();
      if (!v) return;
      const k = views[v.song] || {};
      const out = { song: v.song, at: Date.now(), head: v.head || k.head, chunks: v.head ? v.chunks : k.chunks, pd: v.pd || k.pd, sheet: v.sheet || k.sheet,
        beatmap: v.beatmap || k.beatmap, chat: v.chat || k.chat };
      views[v.song] = out;
      phonefile.put('views', out).catch(() => {});
    }, 3000);
  }
  const OURS = /^(daw|dawc\d+|phonedaw|sheet|beatmap|chat|mix|mixr)$/;
  const SONGLESS = ['sheet', 'beatmap', 'chat', 'mixr']; // (topics that don't say their project: dropped when the computer's front one changes)
  let lastFront = null;
  function took(s, seed) {
    const t = (s && s.topics) || {};
    const f = front();
    if (f && f !== lastFront) { if (lastFront) for (const k of SONGLESS) if (!(k in t)) delete T[k]; lastFront = f; }
    let any = false;
    for (const k in t) { if (seed && k in T) continue; T[k] = t[k]; if (OURS.test(k)) any = true; }
    if (!any) return;
    keepSoon();
    dirty = true;
    if (t.phonedaw || t.mix || t.mixr || t.daw) drawPanel();
    if (t.chat) drawComments();
    if (t.sheet || t.beatmap) drawSheet();
  }
  addEventListener('ss-state', (e) => took(e.detail, false));
  fetch('api/state').then((r) => r.json()).then((s) => took(s, true)).catch(() => {});

  // ---- the views and what each asks the computer for while it shows ---------------------------------------------------------------------
  let shown = 'rec', screenLock = null;
  function wants(all) {
    if (!online() || document.hidden) return;
    if (all || shown === 'arr') { act('daw', { want: true }).catch(() => {}); act('phonedaw', { want: true }).catch(() => {}); }
    if (all || shown === 'sht') act('sheet', { want: true }).catch(() => {});
    if (panel && panel.kind === 'track') act('mixer', { want: true }).catch(() => {});
  }
  setInterval(() => wants(false), 10000);
  document.addEventListener('visibilitychange', () => wants(false));
  async function awake(on) { // (the sheet on a music stand: the screen kept on while it shows)
    try {
      if (on && !screenLock && navigator.wakeLock) screenLock = await navigator.wakeLock.request('screen');
      else if (!on && screenLock) { await screenLock.release(); screenLock = null; }
    } catch (e) { screenLock = null; }
  }
  function showView(v) {
    shown = v;
    for (const b of document.querySelectorAll('#views button')) b.setAttribute('aria-pressed', String(b.dataset.view === v));
    for (const id of ['rec', 'arr', 'sht', 'ply']) $(id).hidden = id !== v;
    keep('ss-phone-view', v);
    awake(v === 'sht');
    wants(false);
    if (v === 'arr') { resize(); drawComments(); }
    if (v === 'sht') drawSheet(true);
    if (v === 'ply') { kInit(); kTracks(); kSay(); }
  }
  for (const b of document.querySelectorAll('#views button')) b.addEventListener('click', () => showView(b.dataset.view));

  // ---- where the song is: the phone's own mix playing (recording along or Listen), else the computer, else the start picked --------------
  let L = null; // Listen: { ctx, song, from, startAt }
  function songPos() {
    const r = rec && rec.mode === 'phone' && rec.startAt != null ? rec : L;
    if (r && r.ctx && r.ctx.state !== 'closed' && r.startAt != null) return { pos: r.from + (r.ctx.currentTime - r.startAt), playing: true };
    if (online() && topic.song === curSong()) {
      const now = linkNow();
      return { pos: topic.playing && now != null ? topic.pos + (now - topic.at) : topic.pos || 0, playing: !!topic.playing };
    }
    return { pos: parseClock($('from').value) || 0, playing: false };
  }

  // ---- the headphones: levels, a reverb and an EQ, all in Web Audio, never in the take ------------------------------------------------------
  const M = { on: false, lvl: 0.8, rev: 0.25, mix: 1, lo: 0, mid: 0, hi: 0 };
  try { Object.assign(M, JSON.parse(keep('ss-phone-mon') || '{}')); } catch (e) {}
  const mineKey = (song) => 'ss-phone-mine:' + song; // this phone's own level and mute for its takes on each track (by GUID)
  function mine(song) { try { return JSON.parse(keep(mineKey(song)) || '{}') || {}; } catch (e) { return {}; } }
  function setMine(song, guid, o) { const m = mine(song); m[guid] = Object.assign({ v: 1 }, m[guid], o); keep(mineKey(song), JSON.stringify(m)); for (const c of chains) apply(c); dirty = true; }
  const chains = new Set();
  function impulse(ctx, secs) { // (a plain room: noise dying away, a little different on each side)
    const n = Math.round(ctx.sampleRate * secs), b = ctx.createBuffer(2, n, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch++) { const d = b.getChannelData(ch); for (let i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / n, 4); }
    return b;
  }
  // The headphone chain on a context: the mix, this phone's takes (a level per track) and your voice (dry and into the reverb) -> EQ -> out.
  function chain(ctx) {
    if (ctx.ssChain) return ctx.ssChain;
    const c = { ctx, song: '', bus: ctx.createGain(), mix: ctx.createGain(), mon: ctx.createGain(), revIn: ctx.createGain(), rev: ctx.createConvolver(), tracks: new Map() };
    c.eq = [['lowshelf', 200], ['peaking', 1500], ['highshelf', 5000]].map(([type, f]) => {
      const n = ctx.createBiquadFilter(); n.type = type; n.frequency.value = f; if (type === 'peaking') n.Q.value = 0.8; return n;
    });
    c.bus.connect(c.eq[0]); c.eq[0].connect(c.eq[1]); c.eq[1].connect(c.eq[2]); c.eq[2].connect(ctx.destination);
    c.rev.buffer = impulse(ctx, 2.2);
    c.mix.connect(c.bus); c.mon.connect(c.bus); c.mon.connect(c.revIn); c.revIn.connect(c.rev); c.rev.connect(c.bus);
    ctx.ssChain = c;
    chains.add(c);
    apply(c);
    return c;
  }
  function apply(c) {
    if (c.ctx.state === 'closed') { chains.delete(c); return; }
    const t = c.ctx.currentTime, set = (p, v) => p.setTargetAtTime(v, t, 0.03), m = mine(c.song);
    set(c.mix.gain, M.mix); set(c.revIn.gain, M.on ? M.rev : 0); set(c.mon.gain, M.on ? M.lvl : 0);
    c.eq.forEach((n, i) => set(n.gain, [M.lo, M.mid, M.hi][i]));
    for (const [g, node] of c.tracks) set(node.gain, m[g] && m[g].m ? 0 : m[g] ? m[g].v : 1);
  }
  const decoded = new Map(); // cid -> AudioBuffer (the last few: a second Listen doesn't decode again)
  // This phone's takes not in yet, played in their places along with the mix (r: { ctx, song, from, startAt }); "Plays here" off leaves one out.
  async function alongTakes(c, r) {
    for (const t of takes.slice()) {
      if (t.song !== r.song || t.kind === 'mid' || !t.blob || t.pos == null || t.plays === false) continue;
      try {
        let buf = decoded.get(t.cid);
        if (!buf) {
          buf = await c.ctx.decodeAudioData(await t.blob.arrayBuffer());
          decoded.set(t.cid, buf);
          if (decoded.size > 12) decoded.delete(decoded.keys().next().value);
        }
        if (c.ctx.state === 'closed') return;
        const at = t.pos + (t.nudge || 0) / 1000;
        const start = Math.max(c.ctx.currentTime + 0.05, r.startAt + Math.max(0, at - r.from)); // (a slow decode joins late, in its place)
        const off = r.from + (start - r.startAt) - at;
        if (off >= buf.duration) continue;
        let g = c.tracks.get(t.track);
        if (!g) { g = c.ctx.createGain(); g.connect(c.bus); c.tracks.set(t.track, g); }
        const s = c.ctx.createBufferSource();
        s.buffer = buf; s.connect(g); s.start(start, Math.max(0, off));
      } catch (e) {} // (a take the browser can't decode just doesn't play here)
    }
    apply(c);
  }
  // record.js's mix goes through here (startMix): -> the node to connect the mix to. r.startAt is set just after, so the takes wait a tick.
  window.ssPhoneOut = (ctx, r) => { const c = chain(ctx); c.song = r.song; Promise.resolve().then(() => alongTakes(c, r)); return c.mix; };
  function monAttach() { // (your voice into the chain, once a take's input is open: a second source on the same stream, the worklet's stays dry)
    if (!rec || rec.ssMon || !rec.stream || !rec.ctx || rec.ctx.state === 'closed') return;
    rec.ssMon = true;
    const c = chain(rec.ctx);
    c.song = rec.song;
    rec.ctx.createMediaStreamSource(rec.stream).connect(c.mon);
    const late = Math.round(((rec.inLat || 0.01) + (rec.ctx.baseLatency || 0) + (rec.ctx.outputLatency || 0.02)) * 1000);
    $('monlat').textContent = 'You hear yourself about ' + late + ' ms late (what the browser reports; Bluetooth adds more).';
  }
  const MON = { monon: 'on', monlvl: 'lvl', monrev: 'rev', mixlvl: 'mix', eqlo: 'lo', eqmid: 'mid', eqhi: 'hi' };
  for (const [id, k] of Object.entries(MON)) {
    const el = $(id);
    if (el.type === 'checkbox') el.checked = !!M[k]; else el.value = String(M[k]);
    el.addEventListener('input', () => {
      M[k] = el.type === 'checkbox' ? el.checked : +el.value;
      keep('ss-phone-mon', JSON.stringify(M));
      for (const c of chains) apply(c);
    });
  }

  // ---- Listen: the kept mix and this phone's takes from the cursor, no recording ---------------------------------------------------------
  async function listen() {
    if (L) return stopListen();
    if (rec) return;
    const song = curSong(), ctx = new AudioContext({ latencyHint: 'interactive' });
    const r = { ctx, song, from: Math.max(0, songPos().pos) };
    let buffer = null;
    try { buffer = await mixBuffer(ctx, song); } catch (e) {}
    if (!buffer && !takes.some((t) => t.song === song && t.blob && t.pos != null && t.kind !== 'mid')) {
      ctx.close();
      return say('Nothing to play on this phone yet: keep the mix (Record, Play along to the mix) or record a take along to it.');
    }
    if (ctx.state === 'suspended') await ctx.resume();
    const out = ssPhoneOut(ctx, r);
    r.startAt = ctx.currentTime + 0.2;
    if (buffer) {
      const src = ctx.createBufferSource();
      src.buffer = buffer; src.connect(out);
      src.onended = () => { if (L === r) stopListen(); };
      src.start(r.startAt, Math.min(r.from, buffer.duration));
    }
    L = r;
    $('alisten').textContent = 'Stop';
    say(buffer ? '' : 'No mix of this project on this phone: playing only its takes.');
  }
  function stopListen() { if (!L) return; const r = L; L = null; r.ctx.close().catch(() => {}); $('alisten').textContent = 'Listen'; }
  $('alisten').addEventListener('click', listen);

  // ---- the Project view: drawn on a canvas -------------------------------------------------------------------------------------------------
  const cv = $('acv'), wrap = $('awrap'), g2 = cv.getContext('2d');
  const HEAD = 84, TOP = 34, LANE = 52;
  let W = 300, H = 200, x0 = 0, pps = 10, y0 = 0, dirty = true, fitted = null, songEnd = 10, laneN = 0;
  if (window.ssVideo) window.ssVideo.onFrame(() => { dirty = true; }); // (a video item's frames came: video.js, rt-video2)
  const xOf = (t) => HEAD + (t - x0) * pps, tOf = (x) => x0 + (x - HEAD) / pps;
  // (the drawing layer, draw.js: this view as it's drawn, and its hook over(), called at the end of each draw. rt-draw)
  const PX = window.ssPhoneDaw = { over: null, cv, bar: $('afit').parentElement,
    view: () => ({ x0, pps, y0, W, H, HEAD, TOP, LANE, song: curSong(), live: online() && curSong() === front() }) };
  function lanesOf(v) {
    const out = [];
    for (const c of (v && v.head && v.chunks) || []) if (c) (c.tr || []).forEach((items, j) => { out[c.from + j] = items || []; });
    return out;
  }
  // This phone's takes not in the project yet with a place of their own, on the lane their track is drawn on.
  function pendingOf(v, song) {
    const out = [], lanes = (v && v.pd && v.pd.lanes) || [], names = ((v && v.head && v.head.tracks) || []).map((t) => t.n);
    let elsewhere = 0, unplaced = 0;
    for (const t of takes) {
      if (t.song !== song || t.state === 'in') continue;
      if (t.pos == null) { unplaced++; continue; }
      let i = lanes.findIndex((l) => l.g === t.track);
      if (i < 0) i = names.indexOf(t.tname);
      if (i < 0) { elsewhere++; continue; }
      out.push({ t, lane: i, at: t.pos + (t.nudge || 0) / 1000 });
    }
    return { list: out, elsewhere, unplaced };
  }
  function clampView() {
    const span = Math.max(50, W - HEAD);
    pps = clamp(pps, span / (songEnd * 4), 2000);
    x0 = clamp(x0, -span / pps * 0.3, songEnd);
    y0 = clamp(y0, 0, Math.max(0, laneN * LANE - (H - TOP) + 8));
  }
  function fit() { x0 = 0; pps = (W - HEAD) / (songEnd * 1.02); y0 = 0; clampView(); dirty = true; }
  function resize() {
    const r = wrap.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    if (r.width < 10 || r.height < 10) return;
    W = r.width; H = r.height;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    cv.style.width = W + 'px'; cv.style.height = H + 'px';
    g2.setTransform(dpr, 0, 0, dpr, 0, 0);
    clampView();
    dirty = true;
  }
  new ResizeObserver(() => { if (shown === 'arr') resize(); }).observe(wrap);
  $('afit').addEventListener('click', fit);
  const css = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  const COMMENT_AT = /^\[(\d+):(\d\d(?:\.\d+)?)/;
  // shortcut: the whole view is drawn again each frame while the song plays (no offscreen cache as daw.js has); fine for a band's song.
  function draw(sp) {
    dirty = false;
    const song = curSong(), v = view(song);
    const C = { bg: css('--bg'), panel: css('--panel'), line: css('--line'), text: css('--text'), dim: css('--dim'), acc: css('--accent'), rec: css('--rec') };
    g2.fillStyle = C.bg; g2.fillRect(0, 0, W, H);
    g2.font = '12px system-ui, sans-serif'; g2.textBaseline = 'middle';
    if (!v || !v.head) {
      laneN = 0;
      g2.fillStyle = C.dim;
      g2.fillText(online() && song === front() ? 'Asking the computer for the project…' : 'Not on this phone yet: open this view once while the computer has ' + song + ' open.', 12, H / 2);
      if (PX.over) PX.over();
      return;
    }
    const head = v.head, lanes = lanesOf(v), pd = v.pd || {}, pend = pendingOf(v, song);
    laneN = head.tracks.length;
    songEnd = Math.max(10, head.len || 0);
    for (const items of lanes) for (const it of items || []) songEnd = Math.max(songEnd, it.p + it.l);
    for (const p of pend.list) songEnd = Math.max(songEnd, p.at + p.t.len);
    if (fitted !== song) { fitted = song; fit(); }
    if (sp.playing && (xOf(sp.pos) > W - 24 || xOf(sp.pos) < HEAD)) x0 = sp.pos - (W - HEAD) * 0.1 / pps; // (the cursor kept in view)
    clampView();
    const bars = head.bars || [];
    const barLen = bars.length > 1 ? (bars[bars.length - 1] - bars[0]) / (bars.length - 1) : 2;
    let step = 1;
    while (step * barLen * pps < 40 && step < 1024) step *= 2;
    g2.strokeStyle = C.line; g2.lineWidth = 1;
    for (let m = 0; m < bars.length; m += step) { const x = Math.round(xOf(bars[m])) + 0.5; if (x > HEAD && x < W) { g2.beginPath(); g2.moveTo(x, TOP); g2.lineTo(x, H); g2.stroke(); } }
    // the lanes: items with their waveforms or notes, takes to choose between marked, this phone's takes dashed in place
    for (let i = 0; i < laneN; i++) {
      const y = TOP + i * LANE - y0, tr = head.tracks[i] || {};
      if (y > H || y + LANE < TOP) continue;
      if (i % 2) { g2.fillStyle = C.line; g2.globalAlpha = 0.25; g2.fillRect(HEAD, y, W - HEAD, LANE); g2.globalAlpha = 1; }
      (lanes[i] || []).forEach((it, j) => {
        const x = xOf(it.p), w = Math.max(2, it.l * pps);
        if (x > W || x + w < HEAD) return;
        const col = it.c || tr.c || C.acc, sel = panel && panel.kind === 'item' && panel.lane === i && panel.idx === j;
        g2.globalAlpha = it.m || tr.m ? 0.35 : 1;
        g2.fillStyle = col; g2.globalAlpha *= 0.3; g2.fillRect(x, y + 3, w, LANE - 6);
        g2.globalAlpha = it.m || tr.m ? 0.35 : 1;
        g2.strokeStyle = sel ? C.text : col; g2.lineWidth = sel ? 2 : 1; g2.strokeRect(x + 0.5, y + 3.5, w - 1, LANE - 7);
        g2.fillStyle = col;
        // (a video or picture item: its frames under the waveform. video.js, rt-video2)
        if (it.v && window.ssVideo && window.ssVideo.draw(g2, it, x, y + 3, w, LANE - 6, Math.max(x, HEAD), Math.min(x + w, W))) g2.globalAlpha *= 0.5;
        const mid = y + LANE / 2, amp = (LANE - 14) / 2;
        if (it.k) {
          const n = it.k.length, cw = w / n;
          for (let q = Math.max(0, Math.floor((HEAD - x) / cw)); q < Math.min(n, Math.ceil((W - x) / cw)); q++) {
            const a = (PEAK[it.k[q]] || 0) * amp;
            g2.fillRect(x + q * cw, mid - a, Math.max(1, cw - 0.3), a * 2 || 1);
          }
        } else if (it.x && it.nt && it.nt.length) {
          let lo = 127, hi = 0;
          for (let q = 2; q < it.nt.length; q += 3) { lo = Math.min(lo, it.nt[q]); hi = Math.max(hi, it.nt[q]); }
          const span = Math.max(12, hi - lo + 1), ph = (LANE - 12) / span;
          for (let q = 0; q + 2 < it.nt.length; q += 3) g2.fillRect(x + it.nt[q] / 1000 * pps, y + 6 + (hi - it.nt[q + 2]) * ph, Math.max(1, it.nt[q + 1] / 1000 * pps), Math.max(1.5, ph));
        }
        const tk = pd.takes && pd.takes[i + ':' + j];
        if (w > 24 && (it.n || tk)) {
          g2.save(); g2.beginPath(); g2.rect(x, y, w, LANE); g2.clip();
          g2.fillStyle = C.text;
          if (it.n) g2.fillText(it.n, Math.max(x, HEAD) + 4, y + 11);
          if (tk) { g2.fillStyle = C.acc; g2.fillText('take ' + (tk.a + 1) + '/' + tk.n.length, Math.max(x, HEAD) + 4, y + LANE - 11); }
          g2.restore();
        } else if (tk) { g2.fillStyle = C.acc; g2.fillRect(x + w - 6, y + 4, 5, 5); }
        g2.globalAlpha = 1;
      });
      for (const p of pend.list) {
        if (p.lane !== i) continue;
        const x = xOf(p.at), w = Math.max(3, p.t.len * pps);
        if (x > W || x + w < HEAD) continue;
        g2.globalAlpha = p.t.plays === false ? 0.4 : 1;
        g2.setLineDash([5, 4]); g2.strokeStyle = C.rec; g2.lineWidth = panel && panel.kind === 'phone' && panel.cid === p.t.cid ? 2.5 : 1.5;
        g2.strokeRect(x + 0.5, y + 6.5, w - 1, LANE - 13);
        g2.setLineDash([]);
        g2.fillStyle = C.rec;
        if (w > 30) { g2.save(); g2.beginPath(); g2.rect(x, y, w, LANE); g2.clip(); g2.fillText('phone: ' + label(p.t), Math.max(x, HEAD) + 4, y + LANE - 13); g2.restore(); }
        g2.globalAlpha = 1;
      }
    }
    // the track names (over the items scrolled under them); band mute, and this phone's own level for its takes
    const m = mine(song);
    g2.fillStyle = C.panel; g2.fillRect(0, TOP, HEAD, H - TOP);
    for (let i = 0; i < laneN; i++) {
      const y = TOP + i * LANE - y0, tr = head.tracks[i] || {}, g = pd.lanes && pd.lanes[i] && pd.lanes[i].g;
      if (y > H || y + LANE < TOP) continue;
      g2.fillStyle = tr.c || C.line; g2.fillRect(0, y + 3, 4, LANE - 6);
      g2.fillStyle = tr.m ? C.dim : C.text;
      g2.save(); g2.beginPath(); g2.rect(0, y, HEAD - 4, LANE); g2.clip();
      g2.fillText(tr.n || 'track ' + (i + 1), 8 + (tr.d || 0) * 6, y + LANE / 2 - 7);
      g2.fillStyle = C.dim;
      const words = [tr.m ? 'muted' : '', g && m[g] && (m[g].m ? 'off here' : m[g].v !== 1 ? Math.round(m[g].v * 100) + '% here' : '')].filter(Boolean).join(' · ');
      if (words) g2.fillText(words, 8 + (tr.d || 0) * 6, y + LANE / 2 + 9);
      g2.restore();
      g2.strokeStyle = C.line; g2.beginPath(); g2.moveTo(0, y + LANE + 0.5); g2.lineTo(HEAD, y + LANE + 0.5); g2.stroke();
    }
    // the ruler: bar numbers, regions and markers, comments with a place, the start picked; then the cursor over everything
    g2.fillStyle = C.panel; g2.fillRect(0, 0, W, TOP);
    for (const mk2 of head.markers || []) {
      const x = xOf(mk2.p);
      if (mk2.e != null) { g2.fillStyle = mk2.c || C.acc; g2.globalAlpha = 0.25; g2.fillRect(x, 0, (mk2.e - mk2.p) * pps, TOP); g2.globalAlpha = 1; }
      if (x < HEAD - 2 || x > W) continue;
      g2.fillStyle = mk2.c || C.acc; g2.fillRect(x, 0, 2, TOP);
      if (mk2.n) g2.fillText(mk2.n, x + 4, TOP - 9);
    }
    g2.fillStyle = C.dim;
    for (let n = 0; n < bars.length; n += step) { const x = xOf(bars[n]); if (x >= HEAD && x < W - 10) g2.fillText(String(n + 1), x + 3, 9); }
    for (const c of ((v.chat && v.chat.msgs) || [])) {
      const at = COMMENT_AT.exec(c.text || '');
      const x = at && xOf(+at[1] * 60 + +at[2]);
      if (x >= HEAD && x <= W) { g2.fillStyle = C.acc; g2.beginPath(); g2.moveTo(x, TOP); g2.lineTo(x + 7, TOP - 5); g2.lineTo(x, TOP - 10); g2.fill(); }
    }
    g2.fillStyle = C.panel; g2.fillRect(0, 0, HEAD, TOP);
    g2.fillStyle = C.dim; g2.fillText(online() && song === front() ? 'live' : 'kept ' + (v.at ? new Date(v.at).toLocaleDateString() : ''), 6, TOP / 2);
    const cx = xOf(sp.pos);
    if (cx >= HEAD && cx <= W) { g2.fillStyle = rec ? C.rec : C.text; g2.fillRect(Math.round(cx), 0, 1.5, H); }
    if (!rec) {
      const why = [pend.elsewhere ? pend.elsewhere + ' of this phone’s takes are on tracks not drawn here' : '',
        pend.unplaced ? pend.unplaced + ' recorded along to the computer: it places them' : ''].filter(Boolean).join('; ');
      if (why && !$('awhy').textContent) say(why + '.');
    }
    if (PX.over) PX.over();
  }

  // ---- touch: drag to move, pinch to zoom, tap to pick (a mouse's wheel too, for a computer) ------------------------------------------------
  const ptrs = new Map();
  let gest = null;
  const at = (e) => { const r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
  cv.addEventListener('pointerdown', (e) => {
    cv.setPointerCapture(e.pointerId);
    ptrs.set(e.pointerId, at(e));
    if (ptrs.size === 1) { const p = at(e); gest = { kind: 'pan', x: p.x, y: p.y, x0, y0, t: performance.now(), moved: false }; }
    else if (ptrs.size === 2) { const [a, b] = [...ptrs.values()]; gest = { kind: 'pinch', d: Math.max(20, Math.abs(a.x - b.x)), t: tOf((a.x + b.x) / 2), pps }; }
  });
  cv.addEventListener('pointermove', (e) => {
    if (!ptrs.has(e.pointerId) || !gest) return;
    ptrs.set(e.pointerId, at(e));
    if (gest.kind === 'pan') {
      const p = at(e), dx = p.x - gest.x, dy = p.y - gest.y;
      if (Math.abs(dx) + Math.abs(dy) > 8) gest.moved = true;
      if (gest.moved) { x0 = gest.x0 - dx / pps; y0 = gest.y0 - dy; }
    } else if (ptrs.size >= 2) {
      const [a, b] = [...ptrs.values()];
      pps = gest.pps * Math.max(20, Math.abs(a.x - b.x)) / gest.d;
      x0 = gest.t - ((a.x + b.x) / 2 - HEAD) / pps;
    }
    clampView(); dirty = true;
  });
  const up = (e) => {
    if (!ptrs.has(e.pointerId)) return;
    if (gest && gest.kind === 'pan' && !gest.moved && performance.now() - gest.t < 500 && e.type === 'pointerup') { const p = at(e); tap(p.x, p.y); }
    ptrs.delete(e.pointerId);
    gest = null; // (one finger left after a pinch doesn't jump the view: it starts again on the next touch)
  };
  cv.addEventListener('pointerup', up);
  cv.addEventListener('pointercancel', up);
  cv.addEventListener('wheel', (e) => {
    e.preventDefault();
    if (e.ctrlKey) { const t = tOf(e.offsetX); pps *= Math.exp(-e.deltaY / 300); x0 = t - (e.offsetX - HEAD) / pps; }
    else { x0 += (e.shiftKey ? e.deltaY : e.deltaX) / pps; if (!e.shiftKey) y0 += e.deltaY; }
    clampView(); dirty = true;
  }, { passive: false });
  function tap(x, y) {
    const song = curSong(), v = view(song);
    if (!v || !v.head) return;
    if (y < TOP) {
      const t = Math.max(0, tOf(x));
      $('from').value = clockText(t);
      say('Start from ' + clockText(t) + ': for Listen, and recording along to the mix on this phone.');
      dirty = true;
      return;
    }
    const i = Math.floor((y - TOP + y0) / LANE);
    if (i < 0 || i >= laneN) return closePanel();
    if (x < HEAD) return openPanel({ kind: 'track', lane: i });
    const t = tOf(x), tol = 8 / pps;
    const p = pendingOf(v, song).list.find((q) => q.lane === i && t >= q.at - tol && t <= q.at + q.t.len + tol);
    if (p) return openPanel({ kind: 'phone', lane: i, cid: p.t.cid });
    const items = lanesOf(v)[i] || [];
    for (let j = items.length - 1; j >= 0; j--) if (t >= items[j].p - tol && t <= items[j].p + items[j].l + tol) return openPanel({ kind: 'item', lane: i, idx: j });
    openPanel({ kind: 'track', lane: i });
  }

  // ---- the panel under the view: a track's levels, an item's takes, one of this phone's takes ----------------------------------------------
  let panel = null, asked = null, holding = false; // asked: { id, what } of the last change sent (its answer comes back as phonedaw.reply or mixr)
  $('apanel').addEventListener('pointerdown', (e) => { if (e.target.type === 'range') holding = true; });
  for (const ev of ['pointerup', 'pointercancel']) addEventListener(ev, () => { if (holding) { holding = false; setTimeout(drawPanel, 0); } });
  function openPanel(p) { panel = p; asked = null; dirty = true; if (p.kind === 'track') wants(false); drawPanel(); }
  function closePanel() { panel = null; $('apanel').hidden = true; dirty = true; }
  const dbOf = (v) => (v > 0.001 ? Math.round(20 * Math.log10(v) * 10) / 10 : -60);
  const ampOf = (db) => (db <= -60 ? 0 : Math.pow(10, db / 20));
  function row(...kids) { const r = mk('div', 'prow2'); r.append(...kids); return r; }
  function range(min, max, step, value, onchange, aria) {
    const r = mk('input'); r.type = 'range'; r.min = min; r.max = max; r.step = step; r.value = value; r.setAttribute('aria-label', aria);
    r.addEventListener('change', () => onchange(+r.value));
    return r;
  }
  function check(text, on, fn) { const l = mk('label', 'chk'), c = mk('input'); c.type = 'checkbox'; c.checked = on; c.addEventListener('change', () => fn(c.checked)); l.append(c, ' ' + text); return l; }
  function answer() { // the last change's word back: the phone that sent it hears why a refusal was
    const r = asked && (asked.what === 'take' ? T.phonedaw && T.phonedaw.reply : T.mixr);
    if (!asked) return null;
    if (!r || r.id !== asked.id) return mk('p', 'dim small', 'Asking the computer…');
    return mk('p', 'small' + (r.ok ? '' : ' bad'), r.ok ? (r.ask ? 'Asked ' + r.ask + ' for it (they claimed it): your pick waits for their answer, and goes back if they keep it.' : 'Done: it’s in the project.') : 'Not made: ' + (r.why || '?'));
  }
  function drawPanel() {
    const el = $('apanel');
    if (!panel) { el.hidden = true; return; }
    if (holding) return; // (not under a finger on a slider: drawn again when it lets go)
    const song = curSong(), v = view(song), head = v && v.head;
    if (!head || panel.lane >= head.tracks.length) return closePanel();
    const tr = head.tracks[panel.lane] || {}, lane = (v.pd && v.pd.lanes && v.pd.lanes[panel.lane]) || {}, live = !!v.live;
    const kids = [row(mk('strong', '', tr.n || 'track'), button('Close', closePanel))];
    if (panel.kind === 'track') {
      const m = mine(song)[lane.g] || { v: 1 };
      kids.push(mk('h3', '', 'On this phone (your headphones)'));
      if (lane.g) {
        kids.push(check('Play this phone’s takes on this track', !m.m, (on) => setMine(song, lane.g, { m: !on })));
        kids.push(range(0, 1.5, 0.01, m.v, (x) => setMine(song, lane.g, { v: x }), 'This phone’s level for its takes on ' + (tr.n || 'this track')));
      } else kids.push(mk('p', 'dim small', 'Open this once while the computer answers, to tie this phone’s takes to the track.'));
      kids.push(mk('h3', '', 'In the project (everyone hears it)'));
      const mix = T.mix && T.mix.song === song ? T.mix : null;
      const strip = live && lane.o && mix && (mix.strips || []).find((s) => s.o === lane.o);
      if (!live) kids.push(mk('p', 'dim small', 'Needs the studio computer with ' + song + ' open.'));
      else if (!strip) kids.push(mk('p', 'dim small', mix ? 'This track isn’t on the computer’s mixer.' : 'Asking the computer…'));
      else {
        const send = (k, val) => { asked = { id: 'm' + Date.now().toString(36), what: 'mix' }; act('mixer', { id: asked.id, set: { o: strip.o, k, v: val, done: true } }).catch((e) => say(e.message)); drawPanel(); };
        const vol = range(-60, 12, 0.5, dbOf(strip.v), (db) => send('v', ampOf(db)), 'Volume of ' + (tr.n || 'this track') + ' in the project');
        const mute = check('Muted in the project', !!strip.m, (on) => send('m', on ? 1 : 0));
        if (strip.why) { vol.disabled = true; mute.querySelector('input').disabled = true; }
        kids.push(row(mk('span', 'small', dbOf(strip.v) + ' dB')), vol, mute);
        if (strip.why) kids.push(mk('p', 'dim small', 'Not yours to change: ' + strip.why));
      }
      const a = answer();
      if (a) kids.push(a);
      const opt = lane.g && [...$('track').options].find((o) => o.value === lane.g && !o.disabled);
      if (opt) kids.push(button('Record on this track', () => { $('track').value = lane.g; keep('ss-rec-track', lane.g); showView('rec'); }));
    } else if (panel.kind === 'item') {
      const it = (lanesOf(v)[panel.lane] || [])[panel.idx];
      if (!it) return closePanel();
      const tk = v.pd && v.pd.takes && v.pd.takes[panel.lane + ':' + panel.idx];
      kids.push(mk('p', 'dim small', (it.n || 'an item') + ' · at ' + clockText(it.p) + ' · ' + clockText(it.l) + ' long'));
      if (!tk) kids.push(mk('p', 'small', 'One take: nothing to choose.'));
      else {
        kids.push(mk('h3', '', 'Which take plays'));
        const list = mk('div', 'takes2');
        tk.n.forEach((name, k) => {
          const b = button((k === tk.a ? '▶ ' : '') + (k + 1) + '. ' + (name || 'take ' + (k + 1)), () => {
            asked = { id: 'k' + Date.now().toString(36), what: 'take' };
            act('phonedaw', { id: asked.id, take: { lane: panel.lane, idx: panel.idx, p: it.p, l: it.l, k } }).catch((e) => say(e.message));
            drawPanel();
          });
          b.setAttribute('aria-pressed', String(k === tk.a));
          b.disabled = !live || k === tk.a;
          list.append(b);
        });
        kids.push(list);
        kids.push(mk('p', 'dim small', live ? 'This changes the project for everyone, as picking the take in REAPER would, if this room lets you.'
          : 'Needs the studio computer with ' + song + ' open.'));
        const a = answer();
        if (a) kids.push(a);
      }
    } else {
      const t = takes.find((x) => x.cid === panel.cid);
      if (!t) return closePanel();
      kids.push(mk('p', 'dim small', 'This phone’s take: ' + label(t) + ' · at ' + clockText(t.pos + (t.nudge || 0) / 1000) + ' · ' + clockText(t.len) + ' long · ' +
        (t.state === 'sent' ? 'sent, going in' : t.state === 'refused' ? 'not put in: ' + (t.said || '?') : 'waiting to go in')));
      kids.push(check('Plays here (Listen, and recording along to the mix)', t.plays !== false, (on) => { t.plays = on ? undefined : false; save(t); dirty = true; }));
      kids.push(row(button('Only this one here', () => { // (comp-lite on the phone: the others overlapping it on its track stay quiet here)
        for (const x of takes) if (x !== t && x.song === t.song && x.track === t.track && x.pos != null && x.pos < t.pos + t.len && t.pos < x.pos + x.len && x.plays !== false) { x.plays = false; save(x); }
        t.plays = undefined; save(t); dirty = true; drawPanel();
      }), button('In the take list', () => { showView('rec'); $('takes-h').scrollIntoView(); })));
      kids.push(mk('p', 'dim small', 'Every take goes into the project as recorded; choosing here is only what this phone plays.'));
    }
    el.replaceChildren(...kids);
    el.hidden = false;
  }

  // ---- comments: the project's chat, with the place in front; written offline, sent when the computer answers ------------------------------
  const OUT = 'ss-phone-outbox';
  function outbox() { try { return JSON.parse(keep(OUT) || '[]') || []; } catch (e) { return []; } }
  let flushing = false;
  async function flush() {
    if (flushing || !online()) return;
    flushing = true;
    try {
      for (const c of outbox()) {
        if (!online() || c.song !== topic.song) continue; // (the chat is the project open on the computer's: another project's wait)
        await act('chat', { text: c.text });
        keep(OUT, JSON.stringify(outbox().filter((x) => !(x.at === c.at && x.text === c.text))));
      }
    } catch (e) {} finally { flushing = false; drawComments(); }
  }
  setInterval(flush, 5000);
  $('acomf').addEventListener('submit', (e) => {
    e.preventDefault();
    const text = $('acomt').value.trim();
    if (!text) return;
    const v = view(curSong()), tn = panel && v && v.head && v.head.tracks[panel.lane] ? v.head.tracks[panel.lane].n : '';
    const box = outbox();
    box.push({ song: curSong(), text: '[' + clockText(Math.max(0, songPos().pos)) + (tn ? ' ' + tn : '') + '] ' + text, at: Date.now() });
    keep(OUT, JSON.stringify(box));
    $('acomt').value = '';
    drawComments();
    flush();
  });
  function drawComments() {
    if (shown !== 'arr') return;
    const song = curSong(), v = view(song), msgs = ((v && v.chat && v.chat.msgs) || []).slice(-30), ol = $('acoms');
    const lis = msgs.map((c) => {
      const li = mk('li'), when = c.time ? new Date(c.time).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' }) : '';
      li.append(mk('div', 'dim small', (c.user || '?') + (when ? ' · ' + when : '')), mk('div', '', c.text || ''));
      const a = COMMENT_AT.exec(c.text || '');
      if (a) { li.classList.add('at'); li.addEventListener('click', () => { $('from').value = clockText(+a[1] * 60 + +a[2]); x0 = +a[1] * 60 + +a[2] - (W - HEAD) * 0.2 / pps; clampView(); dirty = true; }); }
      return li;
    });
    for (const c of outbox().filter((x) => x.song === song)) { const li = mk('li', 'pending'); li.append(mk('div', 'dim small', 'you · waiting for the computer'), mk('div', '', c.text)); lis.push(li); }
    if (!lis.length) lis.push(mk('li', 'dim small', 'No comments on this project here yet.'));
    ol.replaceChildren(...lis);
  }

  // ---- the Sheet view: the song sheet big, the section you're in lit and followed ---------------------------------------------------------
  function lines(into, text) { // (ChordPro: "[Am]" inline, each chord over the word it falls on: the Sheet page's way, sheet.js)
    for (const line of String(text || '').split('\n')) {
      const r = mk('div', 'cline');
      if (/^\s*\{.*\}\s*$/.test(line)) { r.classList.add('dim'); r.textContent = line.trim(); into.append(r); continue; }
      const parts = line.split(/\[([^\]\n]{1,16})\]/);
      if (parts.length === 1) { r.textContent = line || ' '; into.append(r); continue; }
      if (parts[0]) { const p = mk('span', 'cseg'); p.append(mk('span', 'ch', ' '), mk('span', 'ly', parts[0])); r.append(p); }
      for (let i = 1; i < parts.length; i += 2) { const p = mk('span', 'cseg'); p.append(mk('span', 'ch', parts[i]), mk('span', 'ly', parts[i + 1] || ' ')); r.append(p); }
      into.append(r);
    }
  }
  function barTime(bm, bar) { for (const [first, num] of (bm && bm.bars) || []) if (num === bar) return bm.b[first]; return null; }
  let sheetDrawn, sheetSong, secs = [], manualUntil = 0;
  function drawSheet(force) {
    if (shown !== 'sht') return;
    const song = curSong(), v = view(song), sh = v && v.sheet;
    if (!force && sh === sheetDrawn && song === sheetSong) return;
    sheetDrawn = sh; sheetSong = song;
    const body = $('tpbody');
    body.replaceChildren();
    secs = [];
    for (const s of (sh && sh.sections) || []) {
      const blk = mk('div', 'tpsec'), ls = mk('div', 'tplines');
      blk.append(mk('h3', 'tpname', s.name || ''));
      if (s.plays) blk.append(mk('div', 'tpplays dim', s.plays));
      lines(ls, s.text);
      blk.append(ls);
      body.append(blk);
      secs.push({ s, blk, at: s.region && s.pos != null ? s.pos : s.bar != null ? barTime(v.beatmap, s.bar) : null, end: s.region ? s.rend : null });
    }
    if (!secs.length) body.append(mk('p', 'dim', sh ? 'Nothing on the sheet yet: write it on the Sheet page (the web page on a computer).'
      : 'No sheet of ' + song + ' on this phone yet: open this view once while the computer has it open.'));
  }
  const tpSize = () => +(keep('ss-phone-tpsize') || 28);
  function sizeTp(d) { const n = clamp(tpSize() + d, 16, 64); keep('ss-phone-tpsize', String(n)); $('tpbody').style.fontSize = n + 'px'; }
  $('tpsmall').addEventListener('click', () => sizeTp(-4));
  $('tpbigger').addEventListener('click', () => sizeTp(4));
  sizeTp(0);
  for (const ev of ['wheel', 'touchmove']) $('tpbody').addEventListener(ev, () => { manualUntil = performance.now() + 4000; }, { passive: true });
  function follow(sp) {
    let cur = null, next = null;
    for (const x of secs) if (x.at != null && x.at <= sp.pos && (!cur || x.at >= cur.at)) cur = x;
    for (const x of secs) if (cur && x.at != null && x.at > cur.at && (!next || x.at < next.at)) next = x;
    const where = clockText(Math.max(0, sp.pos)) + (cur ? '  ·  ' + (cur.s.name || '') : '');
    if ($('tpwhere').textContent !== where) $('tpwhere').textContent = where;
    $('tpwhere').classList.toggle('rec', !!rec);
    for (const x of secs) x.blk.classList.toggle('now', x === cur);
    if (!cur || !sp.playing || performance.now() < manualUntil) return;
    const body = $('tpbody'), vh = body.clientHeight, span = Math.max(0, cur.blk.offsetHeight - vh * 0.5);
    const end = cur.end != null ? cur.end : next ? next.at : null;
    const into = end != null && end > cur.at ? clamp((sp.pos - cur.at) / (end - cur.at), 0, 1) : 0;
    const target = cur.blk.offsetTop - body.offsetTop - vh * 0.2 + into * span;
    body.scrollTop += (target - body.scrollTop) * 0.12;
  }

  // ---- Play (stage 3, docs/rt/rt-vmidi.md): on-screen keys and drum pads (vkeys.js) and MIDI controllers (Web MIDI) ---------------------
  // The notes go into a MIDI take on this phone (record.js's: Record a MIDI take, along to the mix here or the computer as the Record view
  // says, placed like an audio take) and, with Live into REAPER, to the picked track's instrument on the computer as they're played
  // (lib/livekeys.lua: the track's room rule; armed on REAPER's virtual keyboard while played; the round trip shown). Stuck notes: whatever's
  // held is let go when the page hides or the link drops, and the computer lets go by itself when the page goes quiet.
  const K = { vk: null, sid: phonefile.id(), seq: 0, out: [], sent: new Map(), rtt: [], live: false, flushing: false, names: null, topic: null, track: '' };
  function kTracks() {
    const list = tracksFor(curSong());
    fill($('ktrack'), list.map((t) => ({ value: t.guid, text: t.name + (t.may ? '' : ' (' + (t.why || 'not yours') + ')'), disabled: !t.may })),
      $('ktrack').value || $('track').value || keep('ss-rec-track'));
  }
  function kSend(o, keepalive) {
    if (!K.track) return Promise.resolve();
    return fetch('api/action', { method: 'POST', keepalive: !!keepalive, headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
      body: JSON.stringify({ topic: 'phonedaw', keys: Object.assign({ track: K.track, sid: K.sid, on: true, pads: !!(K.vk && K.vk.mode === 'pads') || undefined }, o) }) })
      .then((r) => { if (!r.ok) throw new Error(String(r.status)); }).catch((e) => kSay('A note didn’t reach the computer (' + e.message + ').'));
  }
  function kFlush() {
    K.flushing = false;
    while (K.out.length) kSend({ ev: K.out.splice(0, 64) });
  }
  // Each note played here: into a take being recorded (the on-screen ones: a controller's reach record.js itself), and live to the computer.
  function kPlayed(d, ts, screen) {
    if (screen) ssKeysBus.dispatchEvent(new CustomEvent('midi', { detail: { data: d, p: ts } }));
    if (!K.live || !online()) return;
    K.out.push([d[0], d[1], d[2], ++K.seq]);
    K.sent.set(K.seq, performance.now());
    if (K.sent.size > 512) K.sent.delete(K.sent.keys().next().value);
    if (!K.flushing) { K.flushing = true; queueMicrotask(kFlush); } // (a chord's notes in one message)
  }
  function kInit() {
    if (K.vk || !window.VKeys) return;
    K.vk = VKeys.create($('kbox'), { onMidi: (d, ts) => kPlayed(d, ts, true) });
    if (!navigator.requestMIDIAccess) { K.names = false; return; }
    VKeys.midiIn((d, ts) => {
      const k = d[0] & 0xf0;
      if (k === 0x90 || k === 0x80) K.vk.light(d[1], k === 0x90 && d[2] > 0);
      if (!K.live) K.vk.hear(d);
      kPlayed(d, ts, false);
    }, (names) => { K.names = names; kSay(); }).catch((e) => { K.names = false; kSay('MIDI controllers weren’t allowed: ' + e.message); });
  }
  function kLive(on) {
    if (K.vk) K.vk.panic(); // (whatever's held goes off where it was going)
    kFlush();
    if (!on && K.live) kSend({ on: false });
    K.live = on;
    K.track = $('ktrack').value;
    $('klive').checked = on;
    if (on) { if (K.vk) K.vk.setHear(false); K.topic = null; kSend({ ev: [] }); } // (REAPER's sound, not this device's too: Hear it here turns it back on)
    kSay();
  }
  function kTopic(all) { // (each page of this computer has its own entry, and its own virtual keyboard channel: lib/livekeys.lua)
    const p = (all && all.pages && all.pages[K.sid]) || null;
    K.topic = p;
    if (p) {
      const at = K.sent.get(p.seq);
      if (at != null) { K.rtt.push(performance.now() - at); if (K.rtt.length > 9) K.rtt.shift(); K.sent.delete(p.seq); }
      if (p.why && K.live) { K.live = false; $('klive').checked = false; if (K.vk) K.vk.setHear(true); }
    }
    kSay();
  }
  addEventListener('ss-state', (e) => { const t = (e.detail && e.detail.topics) || {}; if (t.phonekeys) kTopic(t.phonekeys); });
  let kSaid = '', kSaidUntil = 0;
  function kSay(text) {
    if (text) { kSaid = text; kSaidUntil = performance.now() + 6000; }
    const p = K.topic && K.topic.sid === K.sid ? K.topic : null, parts = []; // (K.topic: this page's entry)
    if (performance.now() < kSaidUntil) parts.push(kSaid);
    if (p && p.why) parts.push('Not played in REAPER: ' + p.why + '.');
    if (!online()) parts.push('No studio computer: the keys and pads still record a MIDI take on this phone; Live into REAPER needs the computer.');
    else if (K.live) {
      const ms = K.rtt.slice().sort((a, z) => a - z)[Math.floor(K.rtt.length / 2)];
      parts.push((p && p.track === K.track && p.name ? 'Playing ' + p.name + ' in REAPER (virtual keyboard channel ' + p.ch + ')' : 'Asking the computer…') +
        (ms != null ? ' · ' + Math.round(ms) + ' ms to the computer and back (you hear it about half that after a touch, plus REAPER’s audio buffer)' : ''));
      if (p && p.also) parts.push('REAPER’s virtual keyboard also reaches ' + p.also.join(', ') + ' (armed, input: all MIDI or the virtual keyboard on this channel).');
    }
    if (K.names === false) parts.push('No Web MIDI in this browser (iPhone, Safari): the on-screen keys and pads only.');
    else if (K.names) parts.push(K.names.length ? 'MIDI: ' + K.names.join(', ') : 'No MIDI controller plugged in (Web MIDI is on: plug one in any time).');
    const t = parts.join('\n'); // (a real line break inside the quotes stopped this whole file loading: no Project, Sheet or Play view. rt-video2)
    if ($('kwhy').textContent !== t) $('kwhy').textContent = t;
  }
  $('klive').addEventListener('change', () => kLive($('klive').checked));
  $('ktrack').addEventListener('change', () => { if (K.live) kLive(true); else K.track = $('ktrack').value; });
  $('krec').addEventListener('click', () => {
    if (rec) return stop();
    $('what').value = 'midi';
    $('track').value = $('ktrack').value;
    render();
    go();
  });
  setInterval(() => { if (K.live && online() && !document.hidden) kSend({ ev: [] }); }, 1000); // ("still here": the computer keeps the track ready)
  let kWasOnline = false;
  function kFrame() { // (each frame while Play shows)
    if (kWasOnline && !online() && K.vk) { K.vk.panic(); kSay('The link dropped: the computer lets go of any held notes by itself within a few seconds.'); }
    kWasOnline = online();
    kTracks();
    const can = online() && topic && curSong() === topic.song;
    $('klive').disabled = !can;
    if (!can && K.live) { K.live = false; $('klive').checked = false; }
    const label = rec ? 'Stop' : 'Record a MIDI take';
    if ($('krec').textContent !== label) $('krec').textContent = label;
    const st = (rec ? $('pos').textContent + ' · ' + $('state').textContent + ' · ' : '') + $('msg').textContent;
    if ($('kstate').textContent !== st) $('kstate').textContent = st;
    if (performance.now() > kSaidUntil && kSaid) { kSaid = ''; kSay(); }
  }
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden || !K.vk) return;
    K.vk.panic(); kFlush();
    if (K.live) kSend({ panic: true }, true); // (and the computer lets go of anything still held)
  });
  addEventListener('pagehide', () => { if (K.live) kSend({ on: false }, true); });

  // ---- each frame --------------------------------------------------------------------------------------------------------------------------
  let wasOnline = false;
  function frame() {
    if (rec && L) stopListen(); // (a take started: its own mix plays)
    monAttach();
    if (online() && !wasOnline) { wasOnline = true; wants(true); flush(); } // (the computer's back: everything kept fresh for the next time offline)
    else if (!online()) wasOnline = false;
    const sp = songPos();
    if (shown === 'arr') {
      const t = clockText(Math.max(0, sp.pos));
      if ($('apos').textContent !== t) $('apos').textContent = t;
      if (dirty || sp.playing) draw(sp);
    }
    if (shown === 'sht') follow(sp);
    if (shown === 'ply') kFrame();
    requestAnimationFrame(frame);
  }
  setInterval(() => { dirty = true; }, 1000); // (a take just kept, a name changed: the view catches up)
  $('song').addEventListener('change', () => { closePanel(); dirty = true; drawComments(); drawSheet(true); });
  phonefile.all('views').then((list) => { for (const v of list) views[v.song] = v; dirty = true; drawComments(); drawSheet(true); }).catch(() => {});
  showView(['rec', 'arr', 'sht', 'ply'].includes(keep('ss-phone-view')) ? keep('ss-phone-view') : 'rec');
  requestAnimationFrame(frame);
})();
