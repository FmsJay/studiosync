// StudioSync's Record page (lib/phonerec.lua has the why): pick a track, press Record, sing along with the computer, press Stop. The take
// is captured here (an AudioWorklet to a 32-bit float WAV: lossless; MediaRecorder's compressed file where there's no worklet), sent to the
// computer serving this page (POST api/upload), and put in on the track where the song was when this phone heard its first sample, on the
// computer's link clock (GET api/time, the quickest of 8 round trips). GPL-3.0-or-later.
'use strict';
const $ = (id) => document.getElementById(id);
const root = document.documentElement;
try { const t = localStorage.getItem('ss-theme'); if (t) root.dataset.theme = t; } catch (e) {}
const keep = (k, v) => { try { if (v === undefined) return localStorage.getItem(k) || ''; localStorage.setItem(k, v); } catch (e) {} return ''; };
const MAX_BYTES = 160 * 1024 * 1024 - 4096; // (the server's limit for one upload, extension/webui.cpp)

let topic = null, engine = false, clock = null, rec = null, pending = null, saidAt = null, stopTimer = null;
const secure = window.isSecureContext && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
const local = /^(127\.0\.0\.1|localhost)$/.test(location.hostname);

function msg(t) { $('msg').textContent = t || ''; }
function conn(text, cls) { const c = $('conn'); c.textContent = text; c.className = 'conn ' + (cls || ''); }
function post(a) {
  return fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' }, body: JSON.stringify(Object.assign({ topic: 'phonerec' }, a)) })
    .then((r) => { if (!r.ok) throw new Error('the computer said ' + r.status); });
}
function clockText(s) { const neg = s < 0; s = Math.abs(s); const m = Math.floor(s / 60); return (neg ? '-' : '') + m + ':' + (s % 60).toFixed(1).padStart(4, '0'); }

// ---- the computer's clock: offset = its time at the middle of the quickest round trip -----------------------------------------------------
async function syncClock(n) {
  let best = null;
  for (let i = 0; i < (n || 8); i++) {
    const t0 = performance.now();
    const r = await fetch('api/time', { cache: 'no-store' });
    if (!r.ok) throw new Error(r.status === 404 ? 'the computer’s StudioSync extension is older' : 'no clock from the computer (' + r.status + ')');
    const j = await r.json();
    const t1 = performance.now();
    if (!best || t1 - t0 < best.rtt) best = { rtt: t1 - t0, off: j.now * 1000 - (t0 + t1) / 2 };
  }
  return best;
}
const linkNow = () => (clock ? (performance.now() + clock.off) / 1000 : null);

// ---- what the computer says ---------------------------------------------------------------------------------------------------------------
const openedAt = Date.now();
setTimeout(() => render(), 5000);
function render() {
  const p = topic;
  $('older').hidden = !!p || !engine || Date.now() - openedAt < 4500; // (no state a few seconds after asking: an extension without uploads)
  if (!p) return;
  $('where').textContent = p.song || '';
  const sel = $('track'), want = sel.value || keep('ss-rec-track');
  const sig = JSON.stringify(p.tracks || []);
  if (sel.dataset.sig !== sig) {
    sel.dataset.sig = sig;
    sel.replaceChildren();
    for (const t of p.tracks || []) {
      const o = document.createElement('option');
      o.value = t.guid;
      o.textContent = t.name + (t.may ? '' : ' (' + (t.why || 'not yours') + ')');
      o.disabled = !t.may;
      sel.append(o);
    }
    const ok = (p.tracks || []).find((t) => t.guid === want && t.may) || (p.tracks || []).find((t) => t.may);
    if (ok) sel.value = ok.guid;
    $('trackwhy').textContent = (p.tracks || []).some((t) => t.may) ? '' : 'No track here is yours to record on in this room (claims, or the room’s rules).';
  }
  if (p.secure) { $('securea').href = p.secure; $('phonea').href = p.secure; }
  $('securelink').hidden = !p.secure;
  if (p.said && p.said_at !== saidAt) { saidAt = p.said_at; if (!rec) msg(p.said); }
  $('nudge').hidden = !p.last || !!rec;
  // the computer stopped while this phone records: its take ends a moment later (the last note's tail)
  if (rec && p.playing) rec.sawPlaying = true;
  if (rec && rec.sawPlaying && !p.playing && !stopTimer) stopTimer = setTimeout(stop, 1500);
}
function tick() {
  const p = topic, now = linkNow();
  if (p) {
    const pos = p.playing && now ? p.pos + (now - p.at) : p.pos;
    let state = p.playing ? 'playing, bar ' + p.bar : 'stopped, bar ' + p.bar, cls = '';
    if (p.due && now && now < p.due) { state = 'starts in ' + (p.due - now).toFixed(1) + ' s'; cls = 'count'; }
    else if (p.playing && p.cue != null && pos < p.cue) { state = 'count-in: ' + (p.cue - pos).toFixed(1) + ' s'; cls = 'count'; }
    if (rec) { state = (cls ? state + ' · ' : '') + 'recording here ' + clockText((performance.now() - rec.startedAt) / 1000); cls = cls || 'live'; }
    $('pos').textContent = clockText(pos);
    $('state').textContent = state;
    $('big').className = 'big ' + cls;
    if (rec && rec.kind === 'wav' && rec.frames * 4 > MAX_BYTES) stop(); // (the longest take the computer takes in one go)
  }
  requestAnimationFrame(tick);
}

function show(s) {
  if (!s) return;
  engine = !!s.engine;
  conn(s.engine ? 'live' : 'Live sync isn’t running', s.engine ? 'ok' : 'bad');
  const t = s.topics || {};
  if (t.phonerec) topic = t.phonerec;
  render();
}
if (window.EventSource) {
  const es = new EventSource('api/events');
  es.onmessage = (e) => { try { show(JSON.parse(e.data)); } catch (err) {} };
  es.onerror = () => conn('reconnecting', 'bad');
} else {
  const poll = () => fetch('api/state').then((r) => r.json()).then(show).catch(() => conn('offline', 'bad')).finally(() => setTimeout(poll, 2000));
  poll();
}
const want = () => post({ want: true }).catch(() => {});
want();
setInterval(want, 10000);
setInterval(() => { if (!rec && document.visibilityState === 'visible') syncClock(4).then((c) => { clock = c; }).catch(() => {}); }, 15000);
syncClock().then((c) => { clock = c; }).catch(() => {});
requestAnimationFrame(tick);

// ---- recording ------------------------------------------------------------------------------------------------------------------------------
// When the block at context time ctxTime was really heard here, on the computer's link clock: the output timestamp says when that frame
// leaves the speaker; it was worked on the output latency before that, and its input came in the input latency before then.
function firstHeard(ctx, ctxTime, inLat) {
  const ts = ctx.getOutputTimestamp ? ctx.getOutputTimestamp() : null;
  let perf = performance.now() - (ctx.currentTime - ctxTime) * 1000; // (the block was worked on about this long ago: to a callback's length)
  const byTs = ts && ts.performanceTime > 0 ? ts.performanceTime + (ctxTime - ts.contextTime) * 1000 - (ctx.outputLatency || ctx.baseLatency || 0) * 1000 : null;
  // (the timestamp is finer, but a fresh context gave one 10 s stale in Chrome: used only when it agrees)
  if (byTs != null && Math.abs(byTs - perf) < 200) perf = byTs;
  return (perf - (inLat || 0) * 1000 + clock.off) / 1000;
}
async function startCapture(stream) {
  const settings = stream.getAudioTracks()[0].getSettings ? stream.getAudioTracks()[0].getSettings() : {};
  const inLat = typeof settings.latency === 'number' ? settings.latency : null;
  const r = { stream, inLat, startedAt: performance.now(), t0: null, frames: 0, chunks: [] };
  if (window.AudioWorkletNode && window.AudioContext) {
    const ctx = new AudioContext({ latencyHint: 'interactive' });
    await ctx.audioWorklet.addModule('recworklet.js');
    const src = ctx.createMediaStreamSource(stream);
    const node = new AudioWorkletNode(ctx, 'ss-rec', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1, channelCountMode: 'explicit' });
    const mute = ctx.createGain();
    mute.gain.value = 0; // (pulled through to the output so it runs; nothing heard)
    src.connect(node); node.connect(mute); mute.connect(ctx.destination);
    Object.assign(r, { kind: 'wav', ctx, node, rate: ctx.sampleRate });
    r.done = new Promise((res) => {
      node.port.onmessage = (e) => {
        const d = e.data;
        if (d.first !== undefined) r.t0 = firstHeard(ctx, d.first, inLat);
        if (d.samples && d.samples.length) { r.chunks.push(d.samples); r.frames += d.samples.length; }
        if (d.done) res();
      };
    });
    if (ctx.state === 'suspended') await ctx.resume();
    return r;
  }
  // (no AudioWorklet: the browser's own compressed recording; its start is only known to tens of ms)
  const mr = new MediaRecorder(stream);
  const type = mr.mimeType || '';
  Object.assign(r, { kind: /webm/.test(type) ? 'webm' : /ogg/.test(type) ? 'ogg' : 'mp4', mr, type });
  mr.ondataavailable = (e) => { if (e.data.size) r.chunks.push(e.data); };
  r.done = new Promise((res) => { mr.onstop = res; });
  mr.onstart = () => { r.t0 = linkNow() - (inLat || 0); };
  mr.start(1000);
  return r;
}
function wav(chunks, frames, rate) { // mono 32-bit float
  const h = new DataView(new ArrayBuffer(44));
  const tag = (at, s) => { for (let i = 0; i < 4; i++) h.setUint8(at + i, s.charCodeAt(i)); };
  tag(0, 'RIFF'); h.setUint32(4, 36 + frames * 4, true); tag(8, 'WAVE');
  tag(12, 'fmt '); h.setUint32(16, 16, true); h.setUint16(20, 3, true); h.setUint16(22, 1, true);
  h.setUint32(24, rate, true); h.setUint32(28, rate * 4, true); h.setUint16(32, 4, true); h.setUint16(34, 32, true);
  tag(36, 'data'); h.setUint32(40, frames * 4, true);
  return new Blob([h.buffer, ...chunks], { type: 'audio/wav' });
}
function upload(blob, progress) {
  return new Promise((res, rej) => {
    const x = new XMLHttpRequest();
    x.open('POST', 'api/upload');
    x.setRequestHeader('X-StudioSync', '1');
    x.setRequestHeader('Content-Type', 'application/octet-stream');
    x.upload.onprogress = (e) => { if (e.lengthComputable) progress(Math.round(e.loaded * 100 / e.total)); };
    x.onload = () => { try { const j = JSON.parse(x.responseText); if (x.status === 200 && j.ok) return res(j.id); } catch (e) {} rej(new Error(x.status === 413 ? 'the take is too long for one upload' : 'the computer said ' + x.status)); };
    x.onerror = () => rej(new Error('the connection dropped'));
    x.send(blob);
  });
}
let lock = null;
async function go() {
  const track = $('track').value;
  if (!track) return msg('Pick a track you may record on.');
  keep('ss-rec-track', track);
  keep('ss-rec-name', $('singer').value.trim());
  $('go').disabled = true;
  try {
    msg('Getting the microphone ready…');
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
    clock = await syncClock(); // (fresh, just before the take: the clocks drift a little over minutes)
    rec = await startCapture(stream);
    rec.track = track;
    stopTimer = null;
    await post({ start: { track, bars: +$('bars').value } });
    try { lock = navigator.wakeLock ? await navigator.wakeLock.request('screen') : null; } catch (e) { lock = null; } // (a sleeping phone stops recording)
    $('go').hidden = true; $('stop').hidden = false; $('again').hidden = true; $('nudge').hidden = true;
    msg(rec.kind === 'wav' ? 'Recording (lossless). Press Stop when you’re done.' : 'Recording, compressed: this browser can’t record lossless.');
  } catch (e) {
    msg('Couldn’t start: ' + (e.name === 'NotAllowedError' ? 'the microphone was refused (the browser’s site settings)' : e.message));
    if (rec) { rec.stream.getTracks().forEach((t) => t.stop()); if (rec.ctx) rec.ctx.close(); rec = null; }
  } finally { $('go').disabled = false; }
}
async function stop() {
  if (!rec) return;
  const r = rec;
  rec = null;
  clearTimeout(stopTimer); stopTimer = null;
  $('stop').hidden = true;
  post({ stop: true }).catch(() => {});
  if (r.node) r.node.port.postMessage('stop'); else r.mr.stop();
  await Promise.race([r.done, new Promise((res) => setTimeout(res, 1500))]);
  r.stream.getTracks().forEach((t) => t.stop());
  if (r.ctx) r.ctx.close();
  if (lock) { lock.release().catch(() => {}); lock = null; }
  const len = r.kind === 'wav' ? r.frames / r.rate : (performance.now() - r.startedAt) / 1000;
  if (r.t0 == null || len < 0.2) { $('go').hidden = false; return msg('Nothing was recorded.'); }
  const err = Math.round(clock.rtt / 2 + 5 + (r.inLat == null ? 30 : 10) + (r.kind === 'wav' ? 0 : 40));
  pending = { blob: r.kind === 'wav' ? wav(r.chunks, r.frames, r.rate) : new Blob(r.chunks, { type: r.type }),
    take: { track: r.track, t0: r.t0, len, kind: r.kind, name: keep('ss-rec-name') || undefined, err } };
  send();
}
async function send() {
  const p = pending;
  if (!p) return;
  $('again').hidden = true;
  try {
    const id = await upload(p.blob, (pct) => msg('Sending the take… ' + pct + '%'));
    await post({ take: Object.assign({ id }, p.take) });
    pending = null;
    msg('Sent: it goes in on the computer in a moment.');
  } catch (e) {
    msg('The take didn’t get there (' + e.message + '). It’s still here: Send again.');
    $('again').hidden = false;
  }
  $('go').hidden = false;
}

// ---- the page ----------------------------------------------------------------------------------------------------------------------------
$('singer').value = keep('ss-rec-name');
$('insecure').hidden = secure;
$('phone').hidden = secure && !local;
$('go').disabled = !secure;
$('go').addEventListener('click', go);
$('stop').addEventListener('click', stop);
$('again').addEventListener('click', send);
$('setup').addEventListener('click', () => post({ setup: true }).then(() => msg('Asked the computer to set it up…')).catch((e) => msg(e.message)));
$('copy').addEventListener('click', () => {
  const u = $('phonea').href;
  if (!topic || !topic.secure) return msg('The computer has no Tailscale name for this yet (MagicDNS on?).');
  (navigator.clipboard ? navigator.clipboard.writeText(u) : Promise.reject(new Error())).then(() => msg('Copied: send it to the phone.')).catch(() => msg('Copy it from the link above.'));
});
for (const b of document.querySelectorAll('#nudge button')) b.addEventListener('click', () => post({ nudge: +b.dataset.ms }).catch((e) => msg(e.message)));
addEventListener('beforeunload', (e) => { if (rec || pending) { e.preventDefault(); e.returnValue = ''; } }); // (a take not sent yet)
