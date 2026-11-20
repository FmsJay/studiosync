// StudioSync's video calls and screen share (docs/realtime-roadmap.md step 5). The browser, or REAPER's docked view, does the media itself,
// peer to peer over WebRTC between bandmates' Tailscale addresses, with no STUN, TURN or other outside server. The setup (offer and answer,
// each carrying its ICE candidates) goes page -> POST /api/action -> Live sync -> the direct link -> the bandmate's Live sync -> their
// page, in the "rtc" topic (lib/webcall.lua). Each bandmate's page must be open: a page that can do video says "here" every 10 s, and the
// list shows who has theirs open, with Call and Share screen. Call audio starts ticked unless StudioSync's live audio runs on this computer
// (it already carries the music: the "rtc" model's live); once someone ticks or unticks it, theirs stays.
// Screen share is view-only: there's no remote control in this version. While sharing, a bar at the top always says so, with Stop.
// Bandmates' names and notes go in as text, never HTML. (James, rt)
// The share's sound and "like your own timeline" (rt-share, docs/rt/rt-share.md):
//  - Sound: REAPER mix (the extension's audio hook, before live audio adds anyone you hear: GET api/mix -> sharemix.js -> a track),
//    System audio (the browser's own, picked when the share starts), or None. It rides the share's own connection, so it stays with the
//    picture. A watcher with live audio here mutes the sharer's live Play meanwhile (it's in their mix already: no double sound).
//  - Timeline: the sharer's Live sync says where REAPER's arrange view is and what it shows (lib/webcall.lua, the "rtview" topic); the
//    sharer's page works out where that sits in the shared picture and sends it with each change. Watchers get Full screen cropped to the
//    arrange view, and the pointer and notes (arrows, circles, text) are kept as time + track, so they stay put when the sharer scrolls or
//    zooms. Notes go through the sharer, who names their author; anyone can hide them, and a watcher can save theirs to the project's chat
//    as timeline comments ("[1:23.4 Vox] ..."), the phone app's form.
// GPL-3.0-or-later.
'use strict';
(() => {
  const sec = document.getElementById('call'), bar = document.getElementById('sharebar');
  if (!sec || !bar) return;
  const make = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, fn, cls) => { const b = make('button', cls || '', text); b.type = 'button'; b.addEventListener('click', fn); return b; };
  const kept = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { /* (no storage: defaults) */ } return null; };
  const docked = /^(docked|floating)$/.test(new URLSearchParams(location.search).get('host') || '');
  // (camera and screen capture need a secure page: http://127.0.0.1 and the docked view are; a phone's http://<name>:47281 link isn't)
  const can = !!(window.isSecureContext && window.RTCPeerConnection && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  const canShare = can && typeof navigator.mediaDevices.getDisplayMedia === 'function';
  const canMix = !!(window.AudioWorkletNode && window.ReadableStream);
  const RING_FOR = 40000, CONNECT_FOR = 20000, HERE_EVERY = 10000, VIEW_EVERY = 2000, DUCK_EVERY = 10000;
  const NOTES_MAX = 100, NOTES_EACH = 40, TEXT_MAX = 200, MSG_MAX = 64 * 1024;
  const sessions = new Map(); // call id -> { id, dev, user, kind ('call' | 'screen'), role ('caller' | 'callee'), state, pc, tile, timer, offer, dc, atx }
  let model = null, boot = null, last = 0, cam = null, screen = null, camTile = null, screenTile = null, failedHere = false, hereTimer = null;

  // ---- the section's parts (made once; the lists are drawn again on every change, the video tiles kept) ------------------------------
  const h = make('h2', '', 'Video'); h.id = 'call-h';
  const audioBox = make('input'); audioBox.type = 'checkbox'; audioBox.id = 'call-audio';
  const audioLabel = make('label', 'call-opt'); audioLabel.append(audioBox, ' Call audio (on unless live audio runs here: it carries the music)');
  let audioSet = false; // (ticked or unticked by hand: kept from then on, whatever live audio does)
  audioBox.addEventListener('change', () => { audioSet = true; });
  // The share's sound: REAPER mix / System audio / None (kept on this computer), with its level
  const SOUND = { reaper: 'REAPER mix', system: 'System audio', none: 'No sound' };
  let soundMode = SOUND[kept('ss-share-sound')] ? kept('ss-share-sound') : (canMix ? 'reaper' : 'none');
  const soundPick = make('select'); soundPick.id = 'call-sound';
  for (const k of Object.keys(SOUND)) { const o = make('option', '', SOUND[k]); o.value = k; o.disabled = k === 'reaper' && !canMix; soundPick.append(o); }
  soundPick.value = soundMode;
  soundPick.addEventListener('change', () => setSound(soundPick.value));
  const soundMeter = make('meter', 'call-level'); soundMeter.min = 0; soundMeter.max = 1; soundMeter.low = 0.6; soundMeter.high = 0.9; soundMeter.optimum = 0.3;
  soundMeter.title = 'What the share sends';
  const soundLabel = make('label', 'call-opt'); soundLabel.append('Share’s sound ', soundPick, ' ', soundMeter);
  const note = make('p', 'call-note dim');
  const rings = make('div', 'call-rings'), now = make('ul', 'call-now'), people = make('ul', 'call-people');
  const big = make('div', 'call-big'), tiles = make('div', 'call-tiles');
  const browser = make('a', 'call-browser', 'Open StudioSync in your browser for video');
  browser.href = location.origin + '/'; browser.target = '_blank'; browser.rel = 'noopener'; // (the docked view hands new windows to the browser)
  sec.append(h, audioLabel, soundLabel, rings, now, people, note, browser, big, tiles);

  let noteTimer = null;
  function say(text) { note.textContent = text || ''; clearTimeout(noteTimer); if (text) noteTimer = setTimeout(() => { note.textContent = ''; }, 12000); }
  function why(e) {
    const n = e && e.name;
    if (n === 'NotAllowedError') return 'not allowed (the browser or the system said no)';
    if (n === 'NotFoundError') return 'no camera found';
    if (n === 'NotReadableError') return 'the camera is in use by another app';
    return (e && e.message) || String(e);
  }
  function rid() { const b = new Uint8Array(16); crypto.getRandomValues(b); return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join(''); }
  function act(base, m, keepalive) {
    return fetch('api/action', { method: 'POST', keepalive: !!keepalive, headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
      body: JSON.stringify(Object.assign(base, m)) }).then((r) => { if (!r.ok) throw new Error('the web UI said ' + r.status); });
  }
  const post = (m, keepalive) => act({ topic: 'rtc' }, m, keepalive);
  // (no trickle: the offer and answer go once gathering is done, candidates inside. Host candidates only, so it's quick; 3 s at most)
  function gathered(pc) {
    return new Promise((res) => {
      if (pc.iceGatheringState === 'complete') return res();
      const t = setTimeout(res, 3000);
      pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') { clearTimeout(t); res(); } });
    });
  }
  // A screen share's Opus as music: stereo, up to 256 kbit/s (WebRTC's default is mono at voice rates). In both sides' own descriptions as
  // well as what they send: stereo=1 asks the other to send stereo, and this side's decoder only gives two channels when its own says so. Pure.
  function musicSdp(sdp) {
    const m = /a=rtpmap:(\d+) opus\/48000\/2/i.exec(sdp);
    if (!m) return sdp;
    return sdp.replace(new RegExp('a=fmtp:' + m[1] + ' ([^\\r\\n]*)'), (line, p) =>
      /stereo=/.test(p) ? line : 'a=fmtp:' + m[1] + ' ' + p + ';stereo=1;sprop-stereo=1;maxaveragebitrate=256000');
  }

  // ---- media ------------------------------------------------------------------------------------------------------------------------
  function tile(stream, label, opts) {
    const f = make('figure', 'tile' + (opts.big ? ' big' : '') + (opts.mirror ? ' mirror' : ''));
    const v = make('video'); v.autoplay = true; v.playsInline = true; v.muted = !!opts.muted; v.srcObject = stream;
    f.video = v;
    f.append(v, make('figcaption', '', label));
    (opts.big ? big : tiles).append(f);
    return f;
  }
  // The shown picture's place inside its video element (object-fit: contain leaves bars), relative to the element.
  function box(v) {
    const vw = v.videoWidth, vh = v.videoHeight, w = v.clientWidth, hh = v.clientHeight;
    if (!vw || !vh || !w || !hh) return null;
    const k = Math.min(w / vw, hh / vh);
    return { x: (w - vw * k) / 2, y: (hh - vh * k) / 2, w: vw * k, h: vh * k };
  }
  async function startCam() {
    if (cam) return cam;
    cam = await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 640 }, height: { ideal: 360 } },
      audio: audioBox.checked ? { echoCancellation: true, noiseSuppression: true } : false });
    camTile = tile(cam, 'You', { muted: true, mirror: true });
    return cam;
  }
  function stopCam() { if (cam) cam.getTracks().forEach((t) => t.stop()); cam = null; if (camTile) camTile.remove(); camTile = null; }
  async function startScreen() {
    if (screen) return screen;
    // (REAPER's window or the whole screen, as the browser's own picker offers. Its audio only for System audio: REAPER mix comes from the
    // extension, and the picker then has no audio box to tick by mistake. No echo cancelling or levelling: it's music)
    const sys = soundMode === 'system';
    screen = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 15, max: 30 } },
      audio: sys ? { echoCancellation: false, noiseSuppression: false, autoGainControl: false, restrictOwnAudio: true } : false,
      systemAudio: sys ? 'include' : 'exclude' });
    screen.getVideoTracks().forEach((t) => t.addEventListener('ended', stopSharing)); // (the browser's own "Stop sharing")
    screenTile = tile(screen, 'Your screen, as they see it (their pointer and notes show here)', { muted: true, big: true });
    board(screenTile, null);
    screenTile.video.addEventListener('resize', shareView); // (the picture's size is known: where the arrange view sits in it)
    await setSound(soundMode);
    viewTimer = setInterval(() => post({ t: 'view' }).catch(() => {}), VIEW_EVERY);
    post({ t: 'view' }).catch(() => {});
    return screen;
  }
  function stopScreen() {
    if (shareSound) shareSound.stop();
    shareSound = null; myView = null; sentView = ''; notes.clear();
    clearInterval(viewTimer); viewTimer = null;
    if (screen) screen.getTracks().forEach((t) => t.stop());
    screen = null;
    if (screenTile) { if (screenTile.bar) screenTile.bar.remove(); screenTile.remove(); }
    screenTile = null;
  }
  function stopSharing() {
    for (const s of [...sessions.values()]) if (s.kind === 'screen' && s.role === 'caller') end(s, null, true);
    stopScreen();
    render();
  }
  // Over Tailscale: a page that may use neither camera nor microphone only gets the default route's address, hidden behind an mDNS name, and
  // neither reaches across Tailscale (it carries no multicast), so a screen share between two such pages can't connect unless both are on
  // one network. Asking once for the microphone, and letting go of it at once, makes the browser offer every address, Tailscale's too.
  // Nothing is recorded or sent. A video call doesn't need it: the camera does the same. (James, rt)
  async function allowAddresses() {
    if (cam) return;
    for (const name of ['microphone', 'camera']) {
      try { if ((await navigator.permissions.query({ name })).state === 'granted') return; } catch (e) { /* (not every browser can ask) */ }
    }
    try { (await navigator.mediaDevices.getUserMedia({ audio: true })).getTracks().forEach((t) => t.stop()); }
    catch (e) { say('The microphone wasn’t allowed, so the browser may not use the Tailscale address: on one network it still connects.'); }
  }

  // ---- the share's sound ------------------------------------------------------------------------------------------------------------
  let shareSound = null, soundAsk = 0;
  function level(an, into) { // (an AnalyserNode's peak, 0-1, into a <meter> while it's in the page)
    const buf = new Float32Array(an.fftSize);
    const tick = () => {
      if (!into.isConnected || an.context.state === 'closed') return;
      an.getFloatTimeDomainData(buf);
      let pk = 0;
      for (const v of buf) pk = Math.max(pk, Math.abs(v));
      into.value = Math.max(pk, into.value * 0.85);
      setTimeout(tick, 60);
    };
    tick();
  }
  // REAPER's own mix: the extension's stream (16-bit stereo at REAPER's rate) into sharemix.js's jitter buffer, out as a track.
  async function reaperMix() {
    const stop = new AbortController();
    const r = await fetch('api/mix', { signal: stop.signal, cache: 'no-store' });
    if (!r.ok || !r.body) throw new Error(r.status === 503 ? 'REAPER’s audio isn’t running' : r.status === 404 ? 'this extension is older (no REAPER mix yet)' : 'the web UI said ' + r.status);
    const rate = +r.headers.get('X-Rate') || 48000;
    const ac = new AudioContext({ sampleRate: rate, latencyHint: 'interactive' });
    const src = { mode: 'reaper', ac, track: null, stop() { this.gone = true; stop.abort(); if (this.track) this.track.stop(); ac.close().catch(() => {}); } };
    try {
      await ac.audioWorklet.addModule('sharemix.js');
      const node = new AudioWorkletNode(ac, 'ss-share-mix', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2] });
      const dest = ac.createMediaStreamDestination();
      dest.channelCount = 2;
      node.connect(dest);
      src.an = ac.createAnalyser();
      node.connect(src.an);
      src.track = dest.stream.getAudioTracks()[0];
      src.track.contentHint = 'music';
      ac.resume().catch(() => {});
      (async () => {
        const rd = r.body.getReader();
        let left = null;
        try {
          for (;;) {
            const { value, done } = await rd.read();
            if (done) break;
            let b = value;
            if (left) { const j = new Uint8Array(left.length + b.length); j.set(left); j.set(b, left.length); b = j; }
            const n = b.length - (b.length % 4);
            if (n) { const pcm = new Int16Array(b.buffer.slice(b.byteOffset, b.byteOffset + n)); node.port.postMessage(pcm, [pcm.buffer]); }
            left = n < b.length ? b.slice(n) : null;
          }
        } catch (e) { /* (stopped, or the extension went) */ }
        if (!src.gone && shareSound === src) { // (REAPER's rate changed or its audio stopped: asked again shortly)
          say('REAPER’s sound stopped (its audio device restarted?): trying again.');
          setTimeout(() => { if (screen && shareSound === src && soundMode === 'reaper') setSound('reaper'); }, 2000);
        }
      })();
      return src;
    } catch (e) { src.stop(); throw e; }
  }
  function systemSound(track) {
    const ac = new AudioContext();
    const an = ac.createAnalyser();
    ac.createMediaStreamSource(new MediaStream([track])).connect(an);
    return { mode: 'system', track, an, stop() { ac.close().catch(() => {}); } }; // (the track is the share's: it goes when the share does)
  }
  // The share's sound now: set on every share's connection at once (no new offer: each has its audio sender from the start).
  async function setSound(mode) {
    soundMode = SOUND[mode] ? mode : 'none';
    kept('ss-share-sound', soundMode);
    soundPick.value = soundMode;
    if (!screen) return render(); // (for the next share)
    const ask = ++soundAsk;
    if (shareSound) shareSound.stop();
    shareSound = null;
    let src = null;
    try {
      if (soundMode === 'reaper') src = await reaperMix();
      else if (soundMode === 'system') {
        const t = screen.getAudioTracks()[0];
        if (!t) throw new Error('none came with this share. Stop, then share again with System audio picked (tick "Share audio" in the browser’s picker; on Windows a single window has none: share a screen or a tab)');
        src = systemSound(t);
      }
    } catch (e) { say('The share’s sound didn’t start: ' + why(e)); }
    if (ask !== soundAsk || !screen) { if (src) src.stop(); return; } // (picked again, or the share stopped, meanwhile)
    shareSound = src;
    if (src) {
      level(src.an, soundMeter);
      if (src.mode === 'system' && model && model.live) say('System audio carries everything this computer plays, the bandmates you hear too: they’ll hear themselves. REAPER mix leaves them out.');
    }
    for (const s of sessions.values()) if (s.kind === 'screen' && s.role === 'caller') { if (s.atx) s.atx.replaceTrack(src ? src.track : null).catch(() => {}); tellSound(s); }
    render();
  }
  function tellSound(s) { send(s, { t: 'sound', mode: shareSound ? shareSound.mode : 'none' }); }

  // ---- the timeline: where REAPER's arrange view is in the picture, and notes kept as time + track ------------------------------------
  // myView: Live sync's "rtview" (the sharer's; lib/webcall.lua view_model). A view as sent: { t0, t1, aw, ah, crop: {x,y,w,h} of the
  // picture (0-1) or null, tracks: [[id, y, h, name]] } (y, h in the arrange view's own pixels, from its top, scrolled as REAPER shows it).
  let myView = null, sentView = '', viewTimer = null, viewSentAt = 0, viewLater = null;
  // Where the arrange view sits in the shared picture. vw, vh: the picture's size; surface: the track's displaySurface. A window's rect on
  // Windows is wider than what's captured by its invisible borders (about 7 px left, right and bottom); a Mac's picture is in pixels, its
  // rects in points. The sizes must agree (that's also how a window that isn't REAPER's is told apart). -> {x,y,w,h} (0-1), or null. Pure.
  function cropOf(rv, vw, vh, surface, dpr) {
    if (!rv || !rv.arr || !(vw > 0) || !(vh > 0)) return null;
    let base = null;
    if (surface === 'window' && rv.win && rv.win.w > 0 && rv.win.h > 0) {
      for (const k of [1, dpr || 1, 2]) {
        const side = (rv.win.w - vw / k) / 2, foot = rv.win.h - vh / k;
        if (side >= -1 && side <= 12 && foot >= -1 && foot <= 12) { base = { x: rv.win.x + Math.max(0, side), y: rv.win.y, w: vw / k, h: vh / k }; break; }
      }
    } else if (surface === 'monitor' && rv.mon && rv.mon.w > 0 && rv.mon.h > 0 && Math.abs(rv.mon.w / rv.mon.h - vw / vh) < 0.01) base = rv.mon;
    if (!base) return null;
    const c = { x: (rv.arr.x - base.x) / base.w, y: (rv.arr.y - base.y) / base.h, w: rv.arr.w / base.w, h: rv.arr.h / base.h };
    return c.x >= -0.01 && c.y >= -0.01 && c.w > 0.05 && c.h > 0.05 && c.x + c.w <= 1.01 && c.y + c.h <= 1.01 ? c : null;
  }
  function viewOf(rv) {
    if (!rv || !(rv.t1 > rv.t0) || !rv.arr || !(rv.arr.w > 0) || !(rv.arr.h > 0) || !screenTile) return null;
    const v = screenTile.video, tr = screen && screen.getVideoTracks()[0], st = tr && tr.getSettings ? tr.getSettings() : {};
    return { t0: rv.t0, t1: rv.t1, aw: rv.arr.w, ah: rv.arr.h, crop: cropOf(rv, v.videoWidth, v.videoHeight, st.displaySurface, window.devicePixelRatio),
      tracks: Array.isArray(rv.tracks) ? rv.tracks.slice(0, 256) : [] };
  }
  function shareView() { // (the sharer: to every watcher when it changes, at most every 100 ms)
    if (!screen) return;
    const v = viewOf(myView), j = JSON.stringify(v);
    if (screenTile) screenTile.view = v;
    if (j === sentView) return;
    const wait = 100 - (Date.now() - viewSentAt);
    if (wait > 0) { clearTimeout(viewLater); viewLater = setTimeout(shareView, wait); return; }
    sentView = j; viewSentAt = Date.now();
    for (const s of sessions.values()) if (s.kind === 'screen' && s.role === 'caller') send(s, { t: 'view', v });
    redrawAll();
  }
  const okNum = (x, lim) => Number.isFinite(x) && Math.abs(x) <= lim;
  function viewOk(v) {
    if (v === null) return true;
    if (!v || typeof v !== 'object' || !okNum(v.t0, 1e7) || !okNum(v.t1, 1e7) || !(v.t1 > v.t0) || !okNum(v.aw, 1e5) || !okNum(v.ah, 1e5) || !(v.aw > 0) || !(v.ah > 0)) return false;
    if (v.crop !== null && !(v.crop && ['x', 'y', 'w', 'h'].every((k) => okNum(v.crop[k], 2)) && v.crop.w > 0 && v.crop.h > 0)) return false;
    return Array.isArray(v.tracks) && v.tracks.length <= 256 &&
      v.tracks.every((t) => Array.isArray(t) && typeof t[0] === 'string' && t[0].length <= 16 && okNum(t[1], 1e6) && okNum(t[2], 1e5) && t[2] > 0 && typeof t[3] === 'string' && t[3].length <= 64);
  }
  // anchors, and the arrange view <-> the picture: anchor.js (shared with the drawing layer, draw.js. rt-draw)
  const { anchorOk, toPic, fromPic } = window.ssAnchor;
  const KINDS = { arrow: true, circle: true, text: true };
  function noteOk(n) {
    return !!n && typeof n === 'object' && typeof n.id === 'string' && /^[\w-]{4,40}$/.test(n.id) && KINDS[n.kind] === true && anchorOk(n.a) &&
      (n.kind === 'text' ? typeof n.text === 'string' && n.text.length >= 1 && n.text.length <= TEXT_MAX : anchorOk(n.b));
  }
  function clock(t) { t = Math.max(0, t); const m = Math.floor(t / 60); return m + ':' + (t - m * 60).toFixed(1).padStart(4, '0'); }

  // Notes: the sharer keeps them (notes), each watcher shows what the sharer last sent (s.notes). Points last a moment.
  const notes = new Map(); // id -> { id, by, dev, kind, a, b, text }
  let notesOn = kept('ss-share-notes') !== '0', tool = 'point';
  const hue = (name) => { let x = 0; for (const c of String(name)) x = (x * 31 + c.charCodeAt(0)) % 360; return x; };
  const myName = () => (model && model.me && model.me.user) || 'Sharer';
  function notesFor(f) { return f === screenTile ? [...notes.values()] : (f && f.session && f.session.notes) || []; }
  // The drawing layer over a screen tile (the sharer's preview: s null; a watcher's: its session), and its tools under the picture.
  function board(f, s) {
    f.session = s;
    f.points = [];
    const cv = make('canvas', 'board');
    const bar2 = make('div', 'board-bar');
    const tools = {};
    for (const [k, label] of [['point', 'Point'], ['arrow', 'Arrow'], ['circle', 'Circle'], ['text', 'Text']]) {
      tools[k] = button(label, () => { tool = k; for (const x of Object.values(tools)) x.classList.toggle('on', x === tools[k]); });
      tools[k].classList.toggle('on', tool === k);
      bar2.append(tools[k]);
    }
    const show = make('input'); show.type = 'checkbox'; show.checked = notesOn;
    show.addEventListener('change', () => { notesOn = show.checked; kept('ss-share-notes', notesOn ? '1' : '0'); redrawAll(); });
    const showL = make('label', 'call-opt'); showL.append(show, ' Notes');
    bar2.append(showL, button(s ? 'Clear mine' : 'Clear all', () => clearNotes(f)));
    if (s) bar2.append(button('Save as comments', () => saveNotes(f)));
    f.full = button('Full screen', () => fullScreen(f));
    bar2.append(f.full);
    if (s) {
      f.vol = make('input', 'call-vol'); f.vol.type = 'range'; f.vol.min = 0; f.vol.max = 1; f.vol.step = 0.01; f.vol.value = kept('ss-share-volume') || '1';
      f.vol.title = 'Its volume here';
      f.vol.addEventListener('input', () => { f.video.volume = +f.vol.value; kept('ss-share-volume', f.vol.value); });
      f.meter = make('meter', 'call-level'); f.meter.min = 0; f.meter.max = 1;
      f.soundL = make('span', 'call-opt dim', '');
      f.soundBox = make('span', 'board-sound'); f.soundBox.hidden = true;
      f.soundBox.append(f.soundL, ' ', f.vol, ' ', f.meter);
      bar2.append(f.soundBox);
    }
    f.cv = cv;
    f.append(cv);
    f.after(bar2);
    f.bar = bar2;
    let drag = null;
    const pic = (ev) => { const b = box(f.video), r = f.video.getBoundingClientRect(); return b ? { x: (ev.clientX - r.left - b.x) / b.w, y: (ev.clientY - r.top - b.y) / b.h } : null; };
    cv.addEventListener('pointerdown', (ev) => {
      const p = pic(ev);
      if (!p || p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return;
      const a = fromPic(f.view, p.x, p.y);
      if (tool === 'point') return point(f, a);
      if (tool === 'text') {
        const text = (window.prompt('Note') || '').trim().slice(0, TEXT_MAX);
        if (text) addNote(f, { id: rid(), kind: 'text', a, text });
        return;
      }
      drag = { kind: tool, a, b: a };
      cv.setPointerCapture(ev.pointerId);
    });
    cv.addEventListener('pointermove', (ev) => { const p = drag && pic(ev); if (p) { drag.b = fromPic(f.view, p.x, p.y); f.drag = drag; redraw(f); } });
    cv.addEventListener('pointerup', () => {
      if (!drag) return;
      const d = drag; drag = null; f.drag = null;
      const pa = toPic(f.view, d.a), pb = toPic(f.view, d.b);
      if (pa && pb && Math.hypot(pa.x - pb.x, pa.y - pb.y) > 0.005) addNote(f, { id: rid(), kind: d.kind, a: d.a, b: d.b });
      redraw(f);
    });
    new ResizeObserver(() => { layout(f); redraw(f); }).observe(f);
    f.video.addEventListener('resize', () => { layout(f); redraw(f); });
    document.addEventListener('fullscreenchange', () => { layout(f); redraw(f); });
  }
  function point(f, a) {
    f.points.push({ a, by: 'you', until: Date.now() + 2500 });
    animate(f);
    if (f.session) send(f.session, { t: 'point', a });
    else for (const s of sessions.values()) if (s.kind === 'screen' && s.role === 'caller') send(s, { t: 'point', a, by: myName() });
  }
  function addNote(f, n) {
    if (!f.session) return keepNote(Object.assign(n, { by: myName() }));
    f.session.mine = f.session.mine || new Set();
    f.session.mine.add(n.id);
    send(f.session, { t: 'note', n });
  }
  function keepNote(n) { // (the sharer: kept, at most NOTES_MAX, the oldest going first; to every watcher)
    notes.set(n.id, n);
    while (notes.size > NOTES_MAX) notes.delete(notes.keys().next().value);
    shareNotes();
  }
  function shareNotes() {
    const list = [...notes.values()].map((n) => ({ id: n.id, kind: n.kind, a: n.a, b: n.b, text: n.text, by: n.by }));
    for (const s of sessions.values()) if (s.kind === 'screen' && s.role === 'caller') send(s, { t: 'notes', list });
    redrawAll();
  }
  function clearNotes(f) {
    if (f.session) return send(f.session, { t: 'clear' });
    notes.clear();
    shareNotes();
  }
  // A watcher's notes into the project's chat, the place in front ("[1:23.4 Vox] ..."), as the phone app's comments are (phonedaw.js).
  async function saveNotes(f) {
    const s = f.session, v = f.view, mine = (s.notes || []).filter((n) => s.mine && s.mine.has(n.id) && !(s.saved && s.saved.has(n.id)));
    if (!mine.length) return say('No notes of yours to save yet.');
    s.saved = s.saved || new Set();
    let n2 = 0;
    for (const n of mine) {
      const tr = 't' in n.a && v ? v.tracks.find((t) => t[0] === n.a.k) : null;
      const where = 't' in n.a ? '[' + clock(n.a.t) + (tr ? ' ' + tr[3] : '') + '] ' : '';
      try { await act({ topic: 'chat' }, { text: where + (n.kind === 'text' ? n.text : '(' + n.kind + ')') + ' (on ' + s.user + '’s screen share)' }); s.saved.add(n.id); n2++; }
      catch (e) { say('A note wasn’t saved: ' + why(e)); break; }
    }
    if (n2) say(n2 + (n2 === 1 ? ' note' : ' notes') + ' saved to this project’s chat.');
  }
  // Full screen: on a tile with the timeline known, the picture cropped and scaled to REAPER's arrange view (layout).
  function fullScreen(f) {
    if (document.fullscreenElement) return document.exitFullscreen().catch(() => {});
    (f.requestFullscreen ? f.requestFullscreen() : Promise.reject(new Error('no full screen here'))).catch((e) => say('Full screen didn’t start: ' + why(e)));
  }
  function layout(f) {
    const v = f.video, c = f.view && f.view.crop, full = document.fullscreenElement === f;
    f.classList.toggle('cropped', !!(full && c));
    if (!(full && c) || !v.videoWidth) { v.style.cssText = ''; return; }
    const W = f.clientWidth, H = f.clientHeight, aw = c.w * v.videoWidth, ah = c.h * v.videoHeight, k = Math.min(W / aw, H / ah);
    v.style.cssText = 'position:absolute;max-height:none;object-fit:fill;width:' + v.videoWidth * k + 'px;height:' + v.videoHeight * k + 'px;left:' +
      ((W - aw * k) / 2 - c.x * v.videoWidth * k) + 'px;top:' + ((H - ah * k) / 2 - c.y * v.videoHeight * k) + 'px;clip-path:inset(' +
      [c.y * v.videoHeight, (1 - c.x - c.w) * v.videoWidth, (1 - c.y - c.h) * v.videoHeight, c.x * v.videoWidth].map((x) => Math.max(0, x * k) + 'px').join(' ') + ')'; // (only the arrange view shows)
  }
  function redrawAll() { for (const f of [screenTile, ...[...sessions.values()].map((s) => s.tile)]) if (f && f.cv) { layout(f); redraw(f); } }
  function animate(f) { if (!f.anim) { f.anim = true; requestAnimationFrame(function go() { redraw(f); if (f.points.length && f.isConnected) requestAnimationFrame(go); else f.anim = false; }); } }
  function redraw(f) {
    const cv = f.cv, v = f.video, b = v && box(v);
    if (!cv) return;
    const dpr = window.devicePixelRatio || 1, W = f.clientWidth, H = f.clientHeight;
    if (cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)) { cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); }
    const g = cv.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    if (!b) return;
    const px = (a) => { const p = toPic(f.view, a); return p && { x: v.offsetLeft + b.x + p.x * b.w, y: v.offsetTop + b.y + p.y * b.h }; };
    g.lineWidth = 3; g.font = '600 13px system-ui, sans-serif'; g.textBaseline = 'middle';
    const label = (text, x, y, col) => {
      const w = g.measureText(text).width + 10;
      g.fillStyle = 'rgba(0,0,0,.7)'; g.fillRect(x, y - 10, w, 20);
      g.fillStyle = col; g.fillText(text, x + 5, y);
    };
    const draw = (n, ghost) => {
      const pa = px(n.a), pb = n.b && px(n.b), col = 'hsl(' + hue(n.by) + ',85%,60%)';
      if (!pa) return;
      g.strokeStyle = col; g.lineWidth = 3; g.globalAlpha = ghost ? 0.6 : 1;
      if (n.kind === 'arrow' && pb) {
        const ang = Math.atan2(pb.y - pa.y, pb.x - pa.x);
        g.beginPath(); g.moveTo(pa.x, pa.y); g.lineTo(pb.x, pb.y);
        for (const s of [-1, 1]) { g.moveTo(pb.x, pb.y); g.lineTo(pb.x - 14 * Math.cos(ang + s * 0.45), pb.y - 14 * Math.sin(ang + s * 0.45)); }
        g.stroke();
      } else if (n.kind === 'circle' && pb) {
        g.beginPath(); g.ellipse((pa.x + pb.x) / 2, (pa.y + pb.y) / 2, Math.abs(pb.x - pa.x) / 2 + 2, Math.abs(pb.y - pa.y) / 2 + 2, 0, 0, Math.PI * 2); g.stroke();
      }
      if (n.kind === 'text') label(n.text, pa.x, pa.y, col);
      else if (!ghost) label(n.by, Math.min(pa.x, pb ? pb.x : pa.x) + 4, Math.min(pa.y, pb ? pb.y : pa.y) - 12, col);
      g.globalAlpha = 1;
    };
    if (notesOn) for (const n of notesFor(f)) if (noteOk(n)) draw(n, false);
    if (f.drag) draw({ kind: f.drag.kind, a: f.drag.a, b: f.drag.b, by: 'you' }, true);
    const t = Date.now();
    f.points = f.points.filter((p) => p.until > t);
    for (const p of f.points) {
      const q = px(p.a);
      if (!q) continue;
      const left = (p.until - t) / 2500;
      g.globalAlpha = Math.min(1, left * 2.5);
      g.fillStyle = 'hsl(' + hue(p.by) + ',85%,60%)'; g.strokeStyle = '#fff'; g.lineWidth = 2;
      g.beginPath(); g.arc(q.x, q.y, 8 + 6 * left, 0, Math.PI * 2); g.fill(); g.stroke();
      label(p.by, q.x + 14, q.y, '#fff');
      g.globalAlpha = 1;
    }
  }

  // ---- a call or share with one bandmate ---------------------------------------------------------------------------------------------
  function newPC(s) {
    const pc = new RTCPeerConnection({ iceServers: [] }); // (Tailscale addresses are host candidates: nothing outside is asked)
    pc.ontrack = (e) => {
      const stream = e.streams[0] || new MediaStream([e.track]);
      if (s.tile) { if (s.tile.video.srcObject !== stream) s.tile.video.srcObject = stream; return; }
      s.tile = s.kind === 'screen' ? tile(stream, s.user + '’s screen (click to point)', { big: true, muted: true })
        : tile(stream, s.user, { muted: !audioBox.checked });
      if (s.kind === 'screen') { board(s.tile, s); s.tile.view = s.view; fullLabel(s.tile); if (s.sound) heard(s, s.sound); }
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'connected') { s.state = 'live'; clearTimeout(s.timer); render(); }
      else if (pc.connectionState === 'failed') end(s, 'Couldn’t connect to ' + s.user + ' over Tailscale (is Tailscale up on both, and the page allowed the microphone or camera?)', true);
    };
    pc.ondatachannel = (e) => wire(s, e.channel);
    return pc;
  }
  function send(s, m) { if (s.dc && s.dc.readyState === 'open') { const j = JSON.stringify(m); if (j.length <= MSG_MAX) s.dc.send(j); } }
  // The call's own data channel: the pointer, notes, the view and the share's sound. Everything that comes in is checked; the sharer names
  // a note's author itself (the bandmate this connection is with), never as the note says.
  function wire(s, dc) {
    s.dc = dc;
    dc.onopen = () => { if (s.kind === 'screen' && s.role === 'caller') { tellSound(s); send(s, { t: 'view', v: viewOf(myView) }); shareNotes(); } };
    dc.onmessage = (e) => {
      if (typeof e.data !== 'string' || e.data.length > MSG_MAX || s.kind !== 'screen') return;
      let p = null;
      try { p = JSON.parse(e.data); } catch (err) { return; }
      if (!p || typeof p !== 'object') return;
      if (s.role === 'caller') { // (the sharer: from a watcher)
        if (p.t === 'point') {
          const a = anchorOk(p.a) ? p.a : { fx: p.x, fy: p.y }; // (an older page's {x, y})
          if (!anchorOk(a) || !screenTile) return;
          screenTile.points.push({ a, by: s.user, until: Date.now() + 2500 });
          animate(screenTile);
          for (const o of sessions.values()) if (o !== s && o.kind === 'screen' && o.role === 'caller') send(o, { t: 'point', a, by: s.user });
        } else if (p.t === 'note' && noteOk(p.n) && !notes.has(p.n.id)) {
          if ([...notes.values()].filter((n) => n.dev === s.dev).length >= NOTES_EACH) return;
          keepNote({ id: p.n.id, kind: p.n.kind, a: p.n.a, b: p.n.kind === 'text' ? undefined : p.n.b, text: p.n.kind === 'text' ? p.n.text : undefined, by: s.user, dev: s.dev });
        } else if (p.t === 'clear') {
          for (const [id, n] of notes) if (n.dev === s.dev) notes.delete(id);
          shareNotes();
        }
        return;
      }
      // (a watcher: from the sharer)
      if (p.t === 'view' && viewOk(p.v)) { s.view = p.v; if (s.tile) { s.tile.view = p.v; layout(s.tile); redraw(s.tile); fullLabel(s.tile); } }
      else if (p.t === 'notes' && Array.isArray(p.list) && p.list.length <= NOTES_MAX) {
        s.notes = p.list.filter((n) => noteOk(n) && typeof n.by === 'string' && n.by.length <= 64).map((n) => Object.assign({}, n, { by: s.mine && s.mine.has(n.id) ? 'you' : n.by }));
        if (s.tile) redraw(s.tile);
      } else if (p.t === 'point' && anchorOk(p.a) && typeof p.by === 'string' && p.by.length <= 64 && s.tile) { s.tile.points.push({ a: p.a, by: p.by, until: Date.now() + 2500 }); animate(s.tile); }
      else if (p.t === 'sound' && SOUND[p.mode]) heard(s, p.mode);
    };
  }
  function fullLabel(f) { if (f.full) f.full.textContent = f.view && f.view.crop ? 'Full screen: like your own REAPER' : 'Full screen'; }
  // A watcher: the share's sound here (the picture's own element plays it), and live audio's copy of the sharer's Play muted meanwhile.
  function heard(s, mode) {
    s.sound = mode;
    const f = s.tile;
    if (f && f.soundBox) {
      f.soundBox.hidden = mode === 'none';
      f.soundL.textContent = SOUND[mode] + ':';
      f.video.volume = +f.vol.value;
      if (mode !== 'none' && f.video.muted) { f.video.muted = false; f.video.play().catch(() => { f.video.muted = true; say('Click the picture to hear ' + s.user + '’s share.'); }); }
      if (!f.ac && mode !== 'none' && f.video.srcObject && f.video.srcObject.getAudioTracks().length) {
        try {
          f.ac = new AudioContext();
          const an = f.ac.createAnalyser();
          f.ac.createMediaStreamSource(new MediaStream(f.video.srcObject.getAudioTracks())).connect(an);
          level(an, f.meter);
        } catch (e) { /* (no meter: it still plays) */ }
      }
    }
    duck(s, mode !== 'none');
  }
  function duck(s, on) {
    clearInterval(s.duckTimer); s.duckTimer = null;
    if (on && !(model && model.live)) on = false; // (no live audio here: nothing doubled)
    if (on) s.duckTimer = setInterval(() => post({ t: 'duck', to: s.dev, on: true }).catch(() => {}), DUCK_EVERY);
    if (on || s.ducked) post({ t: 'duck', to: s.dev, on }).catch(() => {});
    s.ducked = on;
  }
  function waitConnect(s) { clearTimeout(s.timer); s.timer = setTimeout(() => { if (s.state !== 'live') end(s, 'Couldn’t connect to ' + s.user + '.', true); }, CONNECT_FOR); }

  async function start(o, kind) {
    const s = { id: rid(), dev: o.dev, user: o.user, kind, role: 'caller', state: 'starting' };
    sessions.set(s.id, s);
    render();
    try {
      const stream = kind === 'call' ? await startCam() : await startScreen();
      if (kind === 'screen') await allowAddresses();
      if (!sessions.has(s.id)) return; // (hung up while the browser asked)
      s.pc = newPC(s);
      for (const t of stream.getTracks()) if (kind === 'call' || t.kind === 'video') s.pc.addTrack(t, stream);
      if (kind === 'call' && !stream.getAudioTracks().length) s.pc.addTransceiver('audio', { direction: 'recvonly' }); // (their call audio, if they send it)
      if (kind === 'screen') { // (the share's sound: its own sender from the start, so changing it later needs no new offer)
        s.atx = s.pc.addTransceiver('audio', { direction: 'sendonly', streams: [stream] }).sender;
        if (shareSound) await s.atx.replaceTrack(shareSound.track);
      }
      wire(s, s.pc.createDataChannel('pointer'));
      const offer = await s.pc.createOffer();
      await s.pc.setLocalDescription(kind === 'screen' ? { type: 'offer', sdp: musicSdp(offer.sdp) } : offer); // (here too: each side's own decoder reads it)
      await gathered(s.pc);
      if (!sessions.has(s.id)) return;
      const sdp = kind === 'screen' ? musicSdp(s.pc.localDescription.sdp) : s.pc.localDescription.sdp;
      await post({ t: 'offer', to: s.dev, call: s.id, kind, audio: kind === 'call' ? stream.getAudioTracks().length > 0 : !!shareSound, sdp });
      s.state = 'calling';
      s.timer = setTimeout(() => end(s, o.user + ' didn’t answer.', true), RING_FOR);
    } catch (e) {
      if (kind === 'screen' && docked) failedHere = true;
      end(s, (kind === 'call' ? 'The call didn’t start: ' : 'Screen share didn’t start: ') + why(e), false);
    }
    render();
  }
  function incoming(m) {
    const s = { id: m.call, dev: m.dev, user: m.user, kind: m.kind, role: 'callee', state: 'ringing', offer: m.sdp };
    sessions.set(s.id, s);
    s.timer = setTimeout(() => end(s, 'Missed: ' + s.user + (s.kind === 'screen' ? ' wanted to show you their screen.' : ' called.'), false), RING_FOR);
  }
  async function accept(s) {
    s.state = 'starting';
    clearTimeout(s.timer);
    render();
    try {
      const stream = s.kind === 'call' ? await startCam() : null;
      if (!stream) await allowAddresses();
      if (!sessions.has(s.id)) return;
      s.pc = newPC(s);
      await s.pc.setRemoteDescription({ type: 'offer', sdp: s.offer });
      if (stream) for (const t of stream.getTracks()) s.pc.addTrack(t, stream); // (into the transceivers their offer made)
      const ans = await s.pc.createAnswer();
      await s.pc.setLocalDescription(s.kind === 'screen' ? { type: 'answer', sdp: musicSdp(ans.sdp) } : ans);
      await gathered(s.pc);
      if (!sessions.has(s.id)) return;
      await post({ t: 'answer', to: s.dev, call: s.id, sdp: s.kind === 'screen' ? musicSdp(s.pc.localDescription.sdp) : s.pc.localDescription.sdp });
      if (s.state !== 'live') s.state = 'connecting';
      waitConnect(s);
    } catch (e) { end(s, 'Couldn’t answer: ' + why(e), true); }
    render();
  }
  async function answered(s, m) {
    if (s.role !== 'caller' || !s.pc || s.pc.signalingState !== 'have-local-offer') return;
    try {
      await s.pc.setRemoteDescription({ type: 'answer', sdp: m.sdp });
      if (s.state !== 'live') s.state = 'connecting';
      waitConnect(s);
    } catch (e) { end(s, 'Couldn’t connect: ' + why(e), true); }
    render();
  }
  // tell: say bye to their computer (a hang-up, a timeout, a failure here); not when they ended it.
  function end(s, text, tell) {
    if (sessions.get(s.id) !== s) return;
    sessions.delete(s.id);
    clearTimeout(s.timer);
    if (s.ducked || s.duckTimer) duck(s, false);
    if (tell && s.state !== 'ringing') post({ t: 'bye', to: s.dev, call: s.id }).catch(() => {});
    if (s.pc) s.pc.close();
    if (s.tile) {
      if (document.fullscreenElement === s.tile) document.exitFullscreen().catch(() => {});
      if (s.tile.ac) s.tile.ac.close().catch(() => {});
      if (s.tile.bar) s.tile.bar.remove();
      s.tile.remove();
    }
    if (text) say(text);
    const rest = [...sessions.values()];
    if (!rest.some((x) => x.kind === 'call' && x.state !== 'ringing')) stopCam();
    if (!rest.some((x) => x.kind === 'screen' && x.role === 'caller')) stopScreen();
    else if (s.kind === 'screen' && s.role === 'caller') { for (const [id, n] of notes) if (n.dev === s.dev) notes.delete(id); shareNotes(); }
    render();
  }
  function decline(s) { post({ t: 'busy', to: s.dev, call: s.id }).catch(() => {}); end(s, null, false); }

  // ---- the "rtc" topic --------------------------------------------------------------------------------------------------------------
  function take(r) {
    model = r;
    if (r.boot !== boot) { boot = r.boot; last = 0; } // (Live sync started again: its count did too)
    for (const m of r.msgs || []) {
      if (!(m.seq > last)) continue;
      last = m.seq;
      const s = sessions.get(m.call);
      if (m.out) { // (what a page here sent: another window answering a ring this one shows too)
        if (s && s.role === 'callee' && s.state === 'ringing' && (m.t === 'answer' || m.t === 'busy')) end(s, m.t === 'answer' ? 'Answered in another StudioSync window.' : null, false);
        continue;
      }
      if (m.t === 'error') { if (s) end(s, 'Couldn’t reach ' + s.user + ': ' + m.why + '.', false); continue; }
      if (m.t === 'offer') { if (can && !s) incoming(m); continue; }
      if (!s || s.dev !== m.dev) continue; // (only the computer this call is with)
      if (m.t === 'answer') answered(s, m);
      else if (m.t === 'bye' && s.state === 'ringing') end(s, 'Missed: ' + s.user + (s.kind === 'screen' ? ' wanted to show you their screen.' : ' called.'), false);
      else if (m.t === 'bye') end(s, s.user + (s.kind === 'screen' ? (s.role === 'caller' ? ' stopped watching.' : ' stopped sharing.') : ' hung up.'), false);
      else if (m.t === 'busy') end(s, s.user + ' didn’t take it.', false);
    }
    render();
  }
  const STATE = { starting: 'starting…', calling: 'waiting for them to answer…', connecting: 'connecting…', live: 'live', ringing: 'asking you' };
  function render() {
    sec.hidden = !model;
    if (!model) return;
    audioBox.disabled = !!cam; // shortcut: call audio is set before a call starts; changing it mid-call would need the call set up again
    if (!audioSet && !cam) audioBox.checked = !model.live;
    soundLabel.hidden = !canShare;
    soundMeter.hidden = !shareSound;
    browser.hidden = !(docked && (!can || !canShare || failedHere));
    rings.replaceChildren();
    now.replaceChildren();
    for (const s of sessions.values()) {
      const what = s.kind === 'screen' ? (s.role === 'caller' ? 'Showing your screen to ' : 'Watching the screen of ') : 'Video call with ';
      if (s.state === 'ringing') {
        const r = make('div', 'ring');
        r.append(make('strong', '', s.user), make('span', '', s.kind === 'screen' ? ' wants to show you their screen' : ' is calling (video)'),
          button(s.kind === 'screen' ? 'Watch' : 'Answer', () => accept(s), 'go'), button('No thanks', () => decline(s)));
        rings.append(r);
        continue;
      }
      const li = make('li');
      li.append(make('span', '', what), make('strong', '', s.user), make('span', 'dim', ' · ' + (STATE[s.state] || s.state)),
        button(s.kind === 'screen' && s.role === 'caller' ? 'Stop' : 'Hang up', () => end(s, null, true), 'stop'));
      now.append(li);
    }
    people.replaceChildren();
    if (!can) {
      people.append(make('li', 'dim', docked ? 'Video calls can’t start in this view.'
        : 'Video needs this computer’s own StudioSync page (127.0.0.1) or the docked view: a phone link isn’t a secure page, so the browser keeps the camera and screen share off.'));
    } else {
      for (const o of model.open || []) {
        const busy = (kind, role) => [...sessions.values()].some((s) => s.dev === o.dev && s.kind === kind && (!role || s.role === role));
        const li = make('li');
        li.append(make('span', 'name', o.user), make('span', 'dim', o.host ? ' ' + o.host : ''));
        const call = button('Call', () => start(o, 'call')); call.disabled = busy('call');
        const share = button('Share screen', () => start(o, 'screen')); share.disabled = !canShare || busy('screen', 'caller');
        if (!canShare) share.title = 'This view can’t capture the screen: open StudioSync in your browser';
        li.append(call, share);
        people.append(li);
      }
      if (!(model.open || []).length) people.append(make('li', 'dim', 'Nobody else has StudioSync’s web UI open now. Each bandmate’s page must be open for a call.'));
    }
    const watching = [...sessions.values()].filter((s) => s.kind === 'screen' && s.role === 'caller').map((s) => s.user);
    bar.hidden = !screen;
    if (screen) {
      bar.replaceChildren(make('span', '', 'You’re sharing your screen' + (watching.length ? ' with ' + watching.join(', ') : '') +
        (shareSound ? ', with ' + SOUND[shareSound.mode] : '') + '.'), button('Stop', stopSharing, 'stop'));
    }
  }

  addEventListener('ss-state', (e) => {
    const s = e.detail || {}, t = s.topics || {}, r = s.topics && s.topics.rtc;
    if (t.rtview && screen) { myView = t.rtview.on ? t.rtview : null; shareView(); }
    if (!r) return;
    take(r);
    // (only while Live sync is running and can pass it on: a stopped one would leave the server's queue full of these)
    if (can && s.engine && !hereTimer) { post({ t: 'here' }).catch(() => {}); hereTimer = setInterval(() => post({ t: 'here' }).catch(() => {}), HERE_EVERY); }
    if (!s.engine && hereTimer) { clearInterval(hereTimer); hereTimer = null; }
  });
  addEventListener('pagehide', () => {
    for (const s of sessions.values()) {
      if (s.ducked) post({ t: 'duck', to: s.dev, on: false }, true).catch(() => {});
      if (s.state !== 'ringing') post({ t: 'bye', to: s.dev, call: s.id }, true).catch(() => {});
    }
  });
  window.ssCallTest = { musicSdp, cropOf, toPic, fromPic, viewOk, noteOk, anchorOk, clock, state: () => ({ sessions, notes, screenTile }) }; // (tests: the pure parts; state to look at)
})();
