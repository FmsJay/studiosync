// StudioSync's video calls and screen share (docs/realtime-roadmap.md step 5). The browser, or REAPER's docked view, does the media itself,
// peer to peer over WebRTC between bandmates' Tailscale addresses, with no STUN, TURN or other outside server. The setup (offer and answer,
// each carrying its ICE candidates) goes page -> POST /api/action -> Live sync -> the direct link -> the bandmate's Live sync -> their
// page, in the "rtc" topic (lib/webcall.lua). Each bandmate's page must be open: a page that can do video says "here" every 10 s, and the
// list shows who has theirs open, with Call and Share screen. Call audio is off unless ticked (live audio already carries the music).
// Screen share is view-only: whoever watches can click to point, and the sharer sees a dot on their preview; there's no remote control in
// this version. While sharing, a bar at the top always says so, with Stop. Bandmates' names go in as text, never HTML. (James, rt)
// GPL-3.0-or-later.
'use strict';
(() => {
  const sec = document.getElementById('call'), bar = document.getElementById('sharebar');
  if (!sec || !bar) return;
  const make = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const button = (text, fn, cls) => { const b = make('button', cls || '', text); b.type = 'button'; b.addEventListener('click', fn); return b; };
  const docked = /^(docked|floating)$/.test(new URLSearchParams(location.search).get('host') || '');
  // (camera and screen capture need a secure page: http://127.0.0.1 and the docked view are; a phone's http://<name>:47281 link isn't)
  const can = !!(window.isSecureContext && window.RTCPeerConnection && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  const canShare = can && typeof navigator.mediaDevices.getDisplayMedia === 'function';
  const RING_FOR = 40000, CONNECT_FOR = 20000, HERE_EVERY = 10000;
  const sessions = new Map(); // call id -> { id, dev, user, kind ('call' | 'screen'), role ('caller' | 'callee'), state, pc, tile, timer, offer }
  let model = null, boot = null, last = 0, cam = null, screen = null, camTile = null, screenTile = null, failedHere = false, hereTimer = null;

  // ---- the section's parts (made once; the lists are drawn again on every change, the video tiles kept) ------------------------------
  const h = make('h2', '', 'Video'); h.id = 'call-h';
  const audioBox = make('input'); audioBox.type = 'checkbox'; audioBox.id = 'call-audio';
  const audioLabel = make('label', 'call-opt'); audioLabel.append(audioBox, ' Call audio (off: live audio already carries the music)');
  const note = make('p', 'call-note dim');
  const rings = make('div', 'call-rings'), now = make('ul', 'call-now'), people = make('ul', 'call-people');
  const big = make('div', 'call-big'), tiles = make('div', 'call-tiles');
  const browser = make('a', 'call-browser', 'Open StudioSync in your browser for video');
  browser.href = location.origin + '/'; browser.target = '_blank'; browser.rel = 'noopener'; // (the docked view hands new windows to the browser)
  sec.append(h, audioLabel, rings, now, people, note, browser, big, tiles);

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
  function post(m, keepalive) {
    return fetch('api/action', { method: 'POST', keepalive: !!keepalive, headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
      body: JSON.stringify(Object.assign({ topic: 'rtc' }, m)) }).then((r) => { if (!r.ok) throw new Error('the web UI said ' + r.status); });
  }
  // (no trickle: the offer and answer go once gathering is done, candidates inside. Host candidates only, so it's quick; 3 s at most)
  function gathered(pc) {
    return new Promise((res) => {
      if (pc.iceGatheringState === 'complete') return res();
      const t = setTimeout(res, 3000);
      pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') { clearTimeout(t); res(); } });
    });
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
  function dot(f, x, y, label) {
    const b = f && box(f.video);
    if (!b) return;
    const d = make('span', 'dot', label);
    d.style.left = (f.video.offsetLeft + b.x + x * b.w) + 'px';
    d.style.top = (f.video.offsetTop + b.y + y * b.h) + 'px';
    f.append(d);
    setTimeout(() => d.remove(), 2500);
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
    // (no audio: live audio carries the music; REAPER's window or the whole screen, as the browser's own picker offers)
    screen = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 15, max: 30 } }, audio: false });
    screen.getVideoTracks().forEach((t) => t.addEventListener('ended', stopSharing)); // (the browser's own "Stop sharing")
    screenTile = tile(screen, 'Your screen, as they see it (their clicks show here as dots)', { muted: true, big: true });
    return screen;
  }
  function stopScreen() { if (screen) screen.getTracks().forEach((t) => t.stop()); screen = null; if (screenTile) screenTile.remove(); screenTile = null; }
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

  // ---- a call or share with one bandmate ---------------------------------------------------------------------------------------------
  function newPC(s) {
    const pc = new RTCPeerConnection({ iceServers: [] }); // (Tailscale addresses are host candidates: nothing outside is asked)
    pc.ontrack = (e) => {
      const stream = e.streams[0] || new MediaStream([e.track]);
      if (s.tile) { if (s.tile.video.srcObject !== stream) s.tile.video.srcObject = stream; return; }
      s.tile = s.kind === 'screen' ? tile(stream, s.user + '’s screen (click to point)', { big: true, muted: true })
        : tile(stream, s.user, { muted: !audioBox.checked });
      if (s.kind === 'screen') s.tile.video.addEventListener('click', (ev) => point(s, ev));
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'connected') { s.state = 'live'; clearTimeout(s.timer); render(); }
      else if (pc.connectionState === 'failed') end(s, 'Couldn’t connect to ' + s.user + ' over Tailscale (is Tailscale up on both, and the page allowed the microphone or camera?)', true);
    };
    pc.ondatachannel = (e) => wire(s, e.channel);
    return pc;
  }
  // The pointer: the viewer's clicks, as a place on the picture (0 to 1 each way), over the call's own data channel; the sharer draws a dot.
  function wire(s, dc) {
    s.dc = dc;
    dc.onmessage = (e) => {
      if (!(s.kind === 'screen' && s.role === 'caller')) return; // (only the sharer draws others' points)
      let p = null;
      try { p = JSON.parse(e.data); } catch (err) { return; }
      if (p && p.t === 'point' && Number.isFinite(p.x) && Number.isFinite(p.y) && p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1) dot(screenTile, p.x, p.y, s.user);
    };
  }
  function point(s, ev) {
    const b = box(s.tile.video);
    if (!b) return;
    const x = (ev.offsetX - b.x) / b.w, y = (ev.offsetY - b.y) / b.h;
    if (x < 0 || x > 1 || y < 0 || y > 1) return;
    dot(s.tile, x, y, 'you');
    if (s.dc && s.dc.readyState === 'open') s.dc.send(JSON.stringify({ t: 'point', x, y }));
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
      for (const t of stream.getTracks()) s.pc.addTrack(t, stream);
      if (kind === 'call' && !stream.getAudioTracks().length) s.pc.addTransceiver('audio', { direction: 'recvonly' }); // (their call audio, if they send it)
      wire(s, s.pc.createDataChannel('pointer'));
      await s.pc.setLocalDescription(await s.pc.createOffer());
      await gathered(s.pc);
      if (!sessions.has(s.id)) return;
      await post({ t: 'offer', to: s.dev, call: s.id, kind, audio: kind === 'call' && stream.getAudioTracks().length > 0, sdp: s.pc.localDescription.sdp });
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
      await s.pc.setLocalDescription(await s.pc.createAnswer());
      await gathered(s.pc);
      if (!sessions.has(s.id)) return;
      await post({ t: 'answer', to: s.dev, call: s.id, sdp: s.pc.localDescription.sdp });
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
    if (tell && s.state !== 'ringing') post({ t: 'bye', to: s.dev, call: s.id }).catch(() => {});
    if (s.pc) s.pc.close();
    if (s.tile) s.tile.remove();
    if (text) say(text);
    const rest = [...sessions.values()];
    if (!rest.some((x) => x.kind === 'call' && x.state !== 'ringing')) stopCam();
    if (!rest.some((x) => x.kind === 'screen' && x.role === 'caller')) stopScreen();
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
      bar.replaceChildren(make('span', '', 'You’re sharing your screen' + (watching.length ? ' with ' + watching.join(', ') : '') + '.'), button('Stop', stopSharing, 'stop'));
    }
  }

  addEventListener('ss-state', (e) => {
    const s = e.detail || {}, r = s.topics && s.topics.rtc;
    if (!r) return;
    take(r);
    // (only while Live sync is running and can pass it on: a stopped one would leave the server's queue full of these)
    if (can && s.engine && !hereTimer) { post({ t: 'here' }).catch(() => {}); hereTimer = setInterval(() => post({ t: 'here' }).catch(() => {}), HERE_EVERY); }
    if (!s.engine && hereTimer) { clearInterval(hereTimer); hereTimer = null; }
  });
  addEventListener('pagehide', () => { for (const s of sessions.values()) if (s.state !== 'ringing') post({ t: 'bye', to: s.dev, call: s.id }, true).catch(() => {}); });
})();
