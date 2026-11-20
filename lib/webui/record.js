// StudioSync's Record page (lib/phonerec.lua has the why): pick a track, press Record, sing along with the computer, press Stop. The take
// is captured here (an AudioWorklet to a 32-bit float WAV: lossless; MediaRecorder's compressed file where there's no worklet), sent to the
// computer serving this page (POST api/upload), and put in on the track where the song was when this phone heard its first sample, on the
// computer's link clock (GET api/time, the quickest of 8 round trips).
// The phone app (docs/realtime-roadmap.md "StudioSync on the phone", stage 1): installed (phone.webmanifest, phone-sw.js) it opens with no
// studio computer; then it plays the project's latest mix itself (kept on the phone, GET api/file) and the take knows its own place, the
// mix's position under its first sample. Every take is kept on the phone (phonefile.js: IndexedDB) until the computer says it's in, and
// goes by itself whenever the computer answers with its project in front. Input 1, 2 or both where the browser allows; a USB MIDI keyboard
// where there's Web MIDI (Android Chrome). GPL-3.0-or-later.
'use strict';
const $ = (id) => document.getElementById(id);
const root = document.documentElement;
try { const t = localStorage.getItem('ss-theme'); if (t) root.dataset.theme = t; } catch (e) {}
const keep = (k, v) => { try { if (v === undefined) return localStorage.getItem(k) || ''; localStorage.setItem(k, v); } catch (e) {} return ''; };
const MAX_BYTES = 160 * 1024 * 1024 - 4096; // (the server's limit for one upload, extension/webui.cpp)
const DONE_WAIT = 30000; // ms a sent take waits to hear it's in before it goes again (the computer puts each in once: its id)

let topic = null, engine = false, sse = false, clock = null, rec = null, saidAt = null, stopTimer = null;
const secure = window.isSecureContext && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
const local = /^(127\.0\.0\.1|localhost)$/.test(location.hostname);
const ios = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
let songs = {}; // song -> { tracks, mix: { id, file, bytes } }: what the computer last said, kept for opening offline
try { songs = JSON.parse(keep('ss-phone-songs') || '{}') || {}; } catch (e) {}
let takes = [], haveMix = {}, mixBuf = null; // (the takes on this phone, newest first; song -> { id, file } of its kept mix; the last decoded)
const online = () => engine && sse && !!topic;

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
  if (p) remember(p);
  songList();
  trackList();
  modeUi();
  mixUi();
  $('where').textContent = online() ? p.song || '' : 'on this phone';
  if (!p) return;
  if (p.secure) { $('securea').href = p.secure; $('phonea').href = p.secure; }
  $('securelink').hidden = !p.secure;
  if (p.said && p.said_at !== saidAt) { saidAt = p.said_at; if (!rec) msg(p.said); }
  $('nudge').hidden = !p.last || !!rec;
  heard(p);
  // the computer stopped while this phone records along to it: its take ends a moment later (the last note's tail)
  if (rec && rec.mode === 'computer' && p.playing) rec.sawPlaying = true;
  if (rec && rec.sawPlaying && !p.playing && !stopTimer) stopTimer = setTimeout(stop, 1500);
  // (an iPhone's home-screen app has its own cookies: the address it's added with carries the studio's token, so it gets in on its own)
  if (ios && !standalone && p.secure && !location.search) {
    const u = new URL(p.secure);
    if (u.origin === location.origin) history.replaceState(null, '', location.pathname + u.search);
  }
}
// What the computer said, kept for opening offline: the project in front's tracks, every project's newest mix.
function remember(p) {
  const was = JSON.stringify(songs);
  if (p.song) { songs[p.song] = Object.assign(songs[p.song] || {}, { tracks: p.tracks || [] }); if (keep('ss-phone-front') !== p.song) keep('ss-phone-front', p.song); }
  for (const m of p.mixes || []) songs[m.song] = Object.assign(songs[m.song] || {}, { mix: m });
  const now = JSON.stringify(songs);
  if (now !== was) keep('ss-phone-songs', now);
}
function fill(sel, items, want) { // items: [{ value, text, disabled }]; rebuilt only when they change
  const sig = JSON.stringify(items);
  if (sel.dataset.sig === sig) return;
  sel.dataset.sig = sig;
  sel.replaceChildren(...items.map((i) => { const o = document.createElement('option'); o.value = i.value; o.textContent = i.text; o.disabled = !!i.disabled; return o; }));
  const ok = items.find((i) => i.value === want && !i.disabled) || items.find((i) => !i.disabled);
  if (ok) sel.value = ok.value;
}
function songList() {
  const names = Object.keys(songs).sort((a, z) => a.localeCompare(z));
  if (topic && topic.song && !names.includes(topic.song)) names.unshift(topic.song);
  fill($('song'), names.map((n) => ({ value: n, text: n + (online() && n === topic.song ? ' (open on the computer)' : '') })), $('song').value || keep('ss-rec-song') || keep('ss-phone-front'));
}
const curSong = () => $('song').value;
const tracksFor = (song) => (topic && song === topic.song ? topic.tracks : songs[song] && songs[song].tracks) || [];
function trackList() {
  const list = tracksFor(curSong());
  fill($('track'), list.map((t) => ({ value: t.guid, text: t.name + (t.may ? '' : ' (' + (t.why || 'not yours') + ')'), disabled: !t.may })), $('track').value || keep('ss-rec-track'));
  $('trackwhy').textContent = !list.length ? 'No tracks known for this project yet: open the page once while the computer has it open.'
    : list.some((t) => t.may) ? '' : 'No track here is yours to record on in this room (claims, or the room’s rules).';
}
// Along to the computer only while it answers with this project in front; else the mix on this phone.
function modeUi() {
  const can = online() && curSong() === topic.song, along = $('along');
  along.options[0].disabled = !can;
  if (!can && along.value === 'computer') along.value = 'phone';
  if (can && !along.dataset.picked && !rec) along.value = keep('ss-rec-along') || 'computer';
  const phone = along.value === 'phone', midi = $('what').value === 'midi';
  for (const e of document.querySelectorAll('.phoneonly')) e.hidden = !phone;
  for (const e of document.querySelectorAll('.componly')) e.hidden = phone;
  for (const e of document.querySelectorAll('.audioonly')) e.hidden = midi;
  for (const e of document.querySelectorAll('.midionly')) e.hidden = !midi;
  if (topic && curSong() === topic.song && online()) $('from').placeholder = clockText(topic.pos || 0) + ' (the computer’s cursor)';
  else $('from').placeholder = '0:00.0';
}
function mixUi() {
  const song = curSong(), have = haveMix[song], there = songs[song] && songs[song].mix;
  const mb = (n) => (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + ' MB';
  let text, get = false;
  if (have && (!there || have.id === there.id)) text = 'The mix on this phone: ' + have.file;
  else if (have) { text = 'On this phone: ' + have.file + '. A newer mix is on the computer: ' + there.file + ' (' + mb(there.bytes) + ').'; get = true; }
  else if (there) { text = 'Not on this phone yet: ' + there.file + ' (' + mb(there.bytes) + ').'; get = true; }
  else text = online() ? 'No mix of this project yet: Render current mix on the computer (StudioSync’s Mixes tab).' : 'No mix of this project on this phone.';
  $('mixinfo').textContent = text;
  $('getmix').hidden = !get || !online() || !!fetching;
  $('getmix').textContent = have ? 'Get the newer mix' : 'Keep it on this phone';
  // the project open on the computer, played along to here: kept by itself (once a session)
  if (get && online() && song === topic.song && $('along').value === 'phone' && !fetching && !tried[there.id]) { tried[there.id] = true; getMix(song); }
}
const tried = {};
let fetching = null;
function getMix(song) {
  const m = songs[song] && songs[song].mix;
  if (!m || fetching) return;
  fetching = song;
  mixUi();
  const x = new XMLHttpRequest();
  x.open('GET', 'api/file?id=' + encodeURIComponent(m.id));
  x.responseType = 'blob';
  x.onprogress = (e) => { if (e.lengthComputable) msg('Getting the mix… ' + Math.round(e.loaded * 100 / e.total) + '%'); };
  const done = (text) => { fetching = null; msg(text); mixUi(); };
  x.onload = () => {
    if (x.status !== 200) return done('The mix didn’t come (' + x.status + '): the computer may have a newer one by now.');
    phonefile.put('mixes', { song, id: m.id, file: m.file, blob: x.response })
      .then(() => { haveMix[song] = { id: m.id, file: m.file }; persist(); done('The mix is on this phone: ' + m.file); })
      .catch((e) => done('Couldn’t keep the mix on this phone: ' + e.message));
  };
  x.onerror = () => done('The mix didn’t come: the connection dropped.');
  x.send();
}
const persist = () => { try { if (navigator.storage && navigator.storage.persist) navigator.storage.persist(); } catch (e) {} };
const parseClock = (s) => { const m = /^\s*(?:(\d+):)?(\d+(?:\.\d*)?)\s*$/.exec(s || ''); return m ? (+(m[1] || 0)) * 60 + +m[2] : null; };
function tick() {
  const p = topic, now = linkNow();
  let pos = parseClock($('from').value) || 0, state = online() ? '' : 'no studio computer: takes stay on this phone', cls = '';
  if (rec && rec.mode === 'phone' && rec.startAt != null) {
    pos = rec.from + (rec.ctx.currentTime - rec.startAt);
    state = pos < rec.from ? 'starting' : 'the mix, on this phone';
  } else if (p && online() && (rec ? rec.mode === 'computer' : $('along').value === 'computer')) {
    pos = p.playing && now ? p.pos + (now - p.at) : p.pos;
    state = p.playing ? 'playing, bar ' + p.bar : 'stopped, bar ' + p.bar;
    if (p.due && now && now < p.due) { state = 'starts in ' + (p.due - now).toFixed(1) + ' s'; cls = 'count'; }
    else if (p.playing && p.cue != null && pos < p.cue) { state = 'count-in: ' + (p.cue - pos).toFixed(1) + ' s'; cls = 'count'; }
  }
  if (rec) { state = (state ? state + ' · ' : '') + 'recording here ' + clockText((performance.now() - rec.startedAt) / 1000); cls = cls || 'live'; }
  $('pos').textContent = clockText(pos);
  $('state').textContent = state || 'stopped';
  $('big').className = 'big ' + cls;
  if (rec && rec.kind === 'wav' && rec.frames * 4 * rec.channels > MAX_BYTES) stop(); // (the longest take the computer takes in one go)
  requestAnimationFrame(tick);
}

function show(s) {
  if (!s) return;
  sse = true;
  engine = !!s.engine;
  conn(s.engine ? 'live' : 'Live sync isn’t running', s.engine ? 'ok' : 'bad');
  const t = s.topics || {};
  if (t.phonerec) topic = t.phonerec;
  render();
  pump();
}
const away = () => { sse = false; conn('offline: takes stay on this phone', 'bad'); render(); };
if (window.EventSource) {
  const es = new EventSource('api/events');
  es.onmessage = (e) => { try { show(JSON.parse(e.data)); } catch (err) {} };
  es.onerror = away;
} else {
  const poll = () => fetch('api/state').then((r) => r.json()).then(show).catch(away).finally(() => setTimeout(poll, 2000));
  poll();
}
const want = () => post({ want: true }).catch(() => {});
want();
setInterval(want, 10000);
// (recording along to the computer: "still here" every 2 s, so a start this page made stops if the page dies mid-take: lib/phonerec.lua watch)
setInterval(() => { if (rec && rec.mode === 'computer') post({ alive: true }).catch(() => {}); }, 2000);
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
// The input picked (device and channels), processing off. -> the stream and what the worklet takes from it.
async function openInput() {
  let pick = $('chans').value;
  const dev = $('input').value;
  const audio = { channelCount: { ideal: 2 }, echoCancellation: false, noiseSuppression: false, autoGainControl: false };
  if (dev) audio.deviceId = { exact: dev };
  const stream = await navigator.mediaDevices.getUserMedia({ audio });
  const s = stream.getAudioTracks()[0].getSettings ? stream.getAudioTracks()[0].getSettings() : {};
  $('inputwhy').textContent = '';
  if (pick !== '0' && s.channelCount === 1) { $('inputwhy').textContent = 'This input gives the page one channel: recording it as input 1.'; pick = '0'; }
  devices();
  return { stream, pick: pick === '0' ? 0 : pick === '1' ? 1 : pick, channels: pick === 'stereo' ? 2 : 1 };
}
async function startCapture(ctx, input) {
  const stream = input.stream;
  const settings = stream.getAudioTracks()[0].getSettings ? stream.getAudioTracks()[0].getSettings() : {};
  const inLat = typeof settings.latency === 'number' ? settings.latency : null;
  const r = { stream, inLat, startedAt: performance.now(), t0: null, first: null, frames: 0, chunks: [], channels: input.channels };
  if (window.AudioWorkletNode && ctx) {
    await ctx.audioWorklet.addModule('recworklet.js');
    const src = ctx.createMediaStreamSource(stream);
    // ('max', discrete: the input's own channels reach the worklet unmixed, so input 2 is input 2)
    const node = new AudioWorkletNode(ctx, 'ss-rec', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 2, channelCountMode: 'max',
      channelInterpretation: 'discrete', processorOptions: { pick: input.pick } });
    const mute = ctx.createGain();
    mute.gain.value = 0; // (pulled through to the output so it runs; nothing heard)
    src.connect(node); node.connect(mute); mute.connect(ctx.destination);
    Object.assign(r, { kind: 'wav', ctx, node, rate: ctx.sampleRate });
    r.done = new Promise((res) => {
      node.port.onmessage = (e) => {
        const d = e.data;
        if (d.first !== undefined) { r.first = d.first; if (clock) r.t0 = firstHeard(ctx, d.first, inLat); }
        if (d.samples && d.samples.length) { r.chunks.push(d.samples); r.frames += d.samples.length / r.channels; }
        if (d.done) res();
      };
    });
    if (ctx.state === 'suspended') await ctx.resume();
    return r;
  }
  // (no AudioWorklet: the browser's own compressed recording, mono; its start is only known to tens of ms)
  const mr = new MediaRecorder(stream);
  const type = mr.mimeType || '';
  Object.assign(r, { kind: /webm/.test(type) ? 'webm' : /ogg/.test(type) ? 'ogg' : 'mp4', mr, type, channels: 1 });
  mr.ondataavailable = (e) => { if (e.data.size) r.chunks.push(e.data); };
  r.done = new Promise((res) => { mr.onstop = res; });
  mr.onstart = () => { r.t0 = linkNow() - (inLat || 0); };
  mr.start(1000);
  return r;
}
// A USB keyboard's notes, controllers and bends (channel messages), with when each came (performance time, ms).
async function startMidi() {
  const access = await navigator.requestMIDIAccess();
  const want = $('midiin').value;
  const ins = [...access.inputs.values()].filter((i) => !want || i.id === want);
  if (!ins.length) throw new Error('no MIDI keyboard found (plug it in, then try again)');
  const r = { kind: 'mid', events: [], startedAt: performance.now(), channels: 1 };
  const on = (e) => { const st = e.data[0]; if (st >= 0x80 && st < 0xf0) r.events.push({ p: e.timeStamp, data: Array.from(e.data) }); };
  for (const i of ins) i.addEventListener('midimessage', on);
  r.off = () => { for (const i of ins) i.removeEventListener('midimessage', on); };
  return r;
}
// The mix's position heard at performance time P (ms): the output timestamp says which context frame is leaving the speaker when.
function mixAt(r, P) {
  const ts = r.ctx.getOutputTimestamp ? r.ctx.getOutputTimestamp() : null;
  const c = ts && ts.performanceTime > 0 ? ts.contextTime + (P - ts.performanceTime) / 1000
    : r.ctx.currentTime - (r.ctx.outputLatency || r.ctx.baseLatency || 0) - (performance.now() - P) / 1000;
  return r.from + (c - r.startAt);
}
// The project's mix on this phone, decoded (the last one kept in memory: a second take doesn't decode it again).
async function mixBuffer(ctx, song) {
  const m = await phonefile.get('mixes', song);
  if (!m) throw new Error('there’s no mix of this project on this phone' + (online() ? ': press Keep it on this phone first' : ''));
  if (mixBuf && mixBuf.id === m.id) return mixBuf.buffer;
  const buffer = await ctx.decodeAudioData(await m.blob.arrayBuffer());
  mixBuf = { id: m.id, buffer };
  return buffer;
}
function startMix(ctx, buffer, r) {
  const want = parseClock($('from').value);
  const from = want != null ? want : topic && r.song === topic.song && online() ? topic.pos || 0 : 0;
  r.from = Math.max(0, Math.min(from, buffer.duration - 0.5));
  const src = ctx.createBufferSource();
  src.buffer = buffer;
  src.connect(ctx.destination);
  r.startAt = ctx.currentTime + 0.3;
  r.src = src;
  src.onended = () => { if (rec === r) stop(); }; // (the mix ran out: the take ends with it)
  src.start(r.startAt, r.from);
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
  const track = $('track').value, song = curSong(), mode = $('along').value, midi = $('what').value === 'midi';
  if (!track) return msg('Pick a track you may record on.');
  keep('ss-rec-track', track); keep('ss-rec-song', song); keep('ss-rec-name', $('singer').value.trim());
  // (the audio context first, inside the tap: an iPhone starts one only there)
  const ctx = (!midi || mode === 'phone') && window.AudioContext ? new AudioContext({ latencyHint: 'interactive' }) : null;
  $('go').disabled = true;
  let r = null;
  try {
    let buffer = null;
    if (mode === 'phone') { msg('Getting the mix ready…'); buffer = await mixBuffer(ctx, song); }
    if (mode === 'computer') clock = await syncClock(); // (fresh, just before the take: the clocks drift a little over minutes)
    if (!midi) msg('Getting the input ready…');
    r = midi ? await startMidi() : await startCapture(ctx, await openInput());
    const t = tracksFor(song).find((x) => x.guid === track);
    Object.assign(r, { track, song, mode, ctx, tname: t ? t.name : '' });
    if (ctx && ctx.state === 'suspended') await ctx.resume();
    if (mode === 'phone') startMix(ctx, buffer, r);
    else { r.perf0 = performance.now(); await post({ start: { track, bars: +$('bars').value }, alive: true }); }
    rec = r;
    stopTimer = null;
    try { lock = navigator.wakeLock ? await navigator.wakeLock.request('screen') : null; } catch (e) { lock = null; } // (a sleeping phone stops recording)
    $('go').hidden = true; $('stop').hidden = false; $('nudge').hidden = true;
    msg(midi ? 'Recording the keyboard. Press Stop when you’re done.' : r.kind === 'wav' ? 'Recording (lossless). Press Stop when you’re done.'
      : 'Recording, compressed: this browser can’t record lossless.');
  } catch (e) {
    msg('Couldn’t start: ' + (e.name === 'NotAllowedError' ? (midi ? 'MIDI' : 'the microphone') + ' was refused (the browser’s site settings)' : e.message));
    if (r) { if (r.stream) r.stream.getTracks().forEach((x) => x.stop()); if (r.off) r.off(); }
    if (ctx) ctx.close();
    rec = null;
  } finally { $('go').disabled = false; }
}
async function stop() {
  if (!rec) return;
  const r = rec, P = performance.now();
  rec = null;
  clearTimeout(stopTimer); stopTimer = null;
  $('stop').hidden = true;
  if (r.mode === 'computer') post({ stop: true }).catch(() => {});
  let take = null;
  if (r.kind === 'mid') { r.off(); take = midiTake(r, P); }
  else {
    if (r.node) r.node.port.postMessage('stop'); else r.mr.stop();
    await Promise.race([r.done, new Promise((res) => setTimeout(res, 1500))]);
    r.stream.getTracks().forEach((t) => t.stop());
    take = audioTake(r);
  }
  if (r.src) try { r.src.onended = null; r.src.stop(); } catch (e) {}
  if (r.ctx) r.ctx.close();
  if (lock) { lock.release().catch(() => {}); lock = null; }
  $('go').hidden = false;
  if (!take) return msg('Nothing was recorded.');
  takes.unshift(take);
  takeList();
  try { await phonefile.put('takes', take); persist(); } catch (e) { msg('Couldn’t keep the take on this phone (' + e.message + '): it goes only while this page stays open.'); }
  msg(online() && take.song === topic.song ? 'Sending the take…' : 'Kept on this phone: it goes in when the computer answers with ' + take.song + ' open in front.');
  pump();
}
const extraMs = () => { const v = parseFloat($('extra').value); return isFinite(v) ? v : 0; };
function base(r, x) {
  return Object.assign({ cid: phonefile.id(), song: r.song, track: r.track, tname: r.tname, who: keep('ss-rec-name'), title: '', when: new Date().toISOString(),
    created: Date.now(), state: 'pending', nudge: 0 }, x);
}
function audioTake(r) {
  const len = r.kind === 'wav' ? r.frames / r.rate : (performance.now() - r.startedAt) / 1000;
  if (len < 0.2 || (r.mode === 'phone' ? r.first == null : r.t0 == null)) return null;
  let pos = null, err;
  if (r.mode === 'phone') { // (what was sung at the worklet's first block was heard the input and output latency before it, in context time)
    const out = r.ctx.outputLatency || r.ctx.baseLatency || 0;
    pos = r.from + (r.first - r.startAt) - (r.inLat || 0) - out - extraMs() / 1000;
    err = Math.round(5 + (r.inLat == null ? 40 : 15) + (r.ctx.outputLatency ? 5 : 25));
  } else err = Math.round(clock.rtt / 2 + 5 + (r.inLat == null ? 30 : 10) + (r.kind === 'wav' ? 0 : 40));
  const blob = r.kind === 'wav' ? phonefile.wav(r.chunks, r.frames, r.rate, r.channels, pos, 'StudioSync take: ' + r.song + ' / ' + r.tname, keep('ss-rec-name'))
    : new Blob(r.chunks, { type: r.type });
  return base(r, { kind: r.kind, blob, pos, t0: r.mode === 'phone' ? null : r.t0, len, err });
}
function midiTake(r, P) {
  if (!r.events.length) return null;
  let evs, len, t0 = null, pos = null;
  if (r.mode === 'phone') { // (from where the mix started: what was played before it is left out)
    pos = r.from;
    evs = r.events.map((e) => ({ t: mixAt(r, e.p) - r.from, data: e.data })).filter((e) => e.t >= 0);
    len = mixAt(r, P) - r.from;
  } else {
    t0 = (r.perf0 + clock.off) / 1000;
    evs = r.events.map((e) => ({ t: (e.p - r.perf0) / 1000, data: e.data })).filter((e) => e.t >= 0);
    len = (P - r.perf0) / 1000;
  }
  if (!evs.length || len < 0.2) return null;
  return base(r, { kind: 'mid', blob: phonefile.smf(evs, len), pos, t0, len, err: r.mode === 'phone' ? 10 : Math.round(clock.rtt / 2 + 10) });
}

// ---- the takes on this phone: each goes by itself when the computer answers with its project in front ---------------------------------
const label = (t) => (t.title || t.tname || 'take') + (t.kind === 'mid' ? ' (MIDI)' : '');
const save = (t) => phonefile.put('takes', t).catch((e) => msg('Couldn’t keep the change on this phone: ' + e.message));
let pumping = false;
async function pump() {
  if (pumping || !online() || rec) return;
  pumping = true;
  try {
    for (const t of takes.slice().reverse()) { // (oldest first)
      if (!online()) break;
      if (t.state === 'sent' && Date.now() - t.sentAt > DONE_WAIT) t.state = 'pending'; // (no word back: again; the computer puts it in once)
      if (t.state !== 'pending' || t.song !== topic.song || !t.blob) continue;
      if (t.blob.size > MAX_BYTES) { Object.assign(t, { state: 'refused', said: 'too long for one upload' }); save(t); continue; }
      const id = await upload(t.blob, (pct) => msg('Sending ' + label(t) + '… ' + pct + '%'));
      await post({ take: { id, cid: t.cid, track: t.track, tname: t.tname || undefined, song: t.song, kind: t.kind, len: t.len, err: t.err,
        name: t.who || undefined, title: t.title || undefined, when: t.when,
        pos: t.pos != null ? t.pos + (t.nudge || 0) / 1000 : undefined, t0: t.pos == null ? t.t0 : undefined } });
      Object.assign(t, { state: 'sent', sentAt: Date.now() });
      await save(t);
      msg('Sent ' + label(t) + ': it goes in on the computer in a moment.');
      takeList();
    }
  } catch (e) {
    msg('A take didn’t get there (' + e.message + '). It’s kept on this phone and goes again when the computer answers.');
  } finally { pumping = false; }
}
// The computer's word on each take sent: in (the phone lets go of its audio, keeps the note) or not, and why.
function heard(p) {
  let changed = false;
  for (const t of takes) {
    const d = t.state === 'sent' && p.done && p.done[t.cid];
    if (!d) continue;
    Object.assign(t, d.ok ? { state: 'in', said: d.said, blob: null } : { state: 'refused', said: d.said });
    save(t);
    changed = true;
  }
  if (changed) takeList();
}
function takeList() {
  const ul = $('takes'), song = curSong(), mine = takes.filter((t) => t.song === song);
  $('notakes').hidden = mine.length > 0;
  const btn = (text, fn) => { const b = document.createElement('button'); b.type = 'button'; b.textContent = text; b.addEventListener('click', fn); return b; };
  ul.replaceChildren(...mine.map((t) => {
    const li = document.createElement('li');
    li.className = t.state;
    const open = t.state === 'pending' || t.state === 'refused';
    const name = document.createElement('input');
    name.value = t.title || ''; name.placeholder = (t.who ? t.who + ', ' : '') + (t.tname || 'a track') + (t.kind === 'mid' ? ', MIDI' : '');
    name.maxLength = 32; name.disabled = !open; name.setAttribute('aria-label', 'The take’s name');
    name.addEventListener('change', () => { t.title = name.value.trim(); save(t); });
    const meta = document.createElement('div');
    meta.className = 'dim small';
    const where = t.pos != null ? 'at ' + clockText(t.pos + (t.nudge || 0) / 1000) + (t.nudge ? ' (nudged ' + (t.nudge > 0 ? '+' : '') + t.nudge + ' ms)' : '') : 'placed by the computer';
    const state = { pending: online() && t.song === topic.song ? 'going to the computer' : 'waiting for the computer, with ' + t.song + ' open in front',
      sent: 'sent, going in…', in: 'in the project' + (t.said ? ': ' + t.said : ''), refused: 'not put in: ' + (t.said || '?') }[t.state];
    meta.textContent = (t.tname || '') + ' · ' + where + ' · ' + clockText(t.len) + ' long · ' + state;
    const row = document.createElement('div');
    row.className = 'row';
    if (open && t.pos != null) for (const ms of [-20, -5, 5, 20]) row.append(btn((ms > 0 ? '+' : '') + ms, () => { t.nudge = (t.nudge || 0) + ms; save(t); takeList(); }));
    if (t.state === 'refused' && t.blob) row.append(btn('Send again', () => { t.state = 'pending'; save(t); takeList(); pump(); }));
    row.append(btn('Retake', () => retake(t)));
    row.append(btn('Delete', () => {
      if (open && t.blob && !confirm('Delete this take? It isn’t in the project yet.')) return;
      takes = takes.filter((x) => x !== t); phonefile.del('takes', t.cid).catch(() => {}); takeList();
    }));
    li.append(name, meta, row);
    return li;
  }));
}
// Record it again: the same track and start; a take not put in yet is let go once the new one's kept.
function retake(t) {
  if (rec) return;
  $('song').value = t.song; songList(); trackList();
  $('track').value = t.track;
  if (t.pos != null) $('from').value = clockText(Math.max(0, t.pos + (t.nudge || 0) / 1000));
  if (t.state === 'pending' || t.state === 'refused') { takes = takes.filter((x) => x !== t); phonefile.del('takes', t.cid).catch(() => {}); takeList(); }
  go();
}
async function devices() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;
  const list = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'audioinput' && d.deviceId && d.deviceId !== 'default');
  fill($('input'), [{ value: '', text: 'the phone’s own choice' }, ...list.map((d, i) => ({ value: d.deviceId, text: d.label || 'input ' + (i + 1) }))], $('input').value || keep('ss-rec-input'));
}
async function midiInputs() {
  try {
    const access = await navigator.requestMIDIAccess();
    const list = [...access.inputs.values()];
    fill($('midiin'), [{ value: '', text: 'every MIDI keyboard plugged in' }, ...list.map((i) => ({ value: i.id, text: i.name || i.id }))], $('midiin').value);
    access.onstatechange = () => midiInputs();
  } catch (e) { msg('MIDI wasn’t allowed: ' + e.message); }
}

// ---- the page ----------------------------------------------------------------------------------------------------------------------------
$('singer').value = keep('ss-rec-name');
$('insecure').hidden = secure;
$('phone').hidden = secure && !local;
$('go').disabled = !secure;
$('go').addEventListener('click', go);
$('stop').addEventListener('click', stop);
$('song').addEventListener('change', () => { keep('ss-rec-song', curSong()); render(); takeList(); });
$('along').addEventListener('change', () => { $('along').dataset.picked = '1'; keep('ss-rec-along', $('along').value); render(); });
$('what').addEventListener('change', () => { render(); if ($('what').value === 'midi') midiInputs(); });
$('input').addEventListener('change', () => keep('ss-rec-input', $('input').value));
$('chans').addEventListener('change', () => keep('ss-rec-chans', $('chans').value));
$('extra').addEventListener('change', () => keep('ss-rec-extra', String(extraMs())));
$('getmix').addEventListener('click', () => getMix(curSong()));
$('chans').value = keep('ss-rec-chans') || '0';
$('extra').value = keep('ss-rec-extra') || '0';
$('whatrow').hidden = !navigator.requestMIDIAccess;
if (navigator.mediaDevices && navigator.mediaDevices.addEventListener) navigator.mediaDevices.addEventListener('devicechange', devices);
devices().catch(() => {});
// the app: kept on the phone (phone-sw.js); Android offers Install, an iPhone adds it from Share (with no manifest, so it keeps this address)
if ('serviceWorker' in navigator && window.isSecureContext) navigator.serviceWorker.register('phone-sw.js').catch(() => {});
if (ios) { const m = document.querySelector('link[rel="manifest"]'); if (m) m.remove(); }
let installEv = null;
$('installrow').hidden = standalone || !secure || local || !ios;
$('ioshint').hidden = !ios;
addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); installEv = e; $('installrow').hidden = standalone; $('install').hidden = false; });
$('install').addEventListener('click', () => { if (installEv) installEv.prompt(); installEv = null; $('install').hidden = true; });
Promise.all([phonefile.all('takes'), phonefile.all('mixes')]).then(([t, m]) => {
  takes = t.sort((a, z) => z.created - a.created);
  for (const x of m) haveMix[x.song] = { id: x.id, file: x.file };
  render(); takeList(); pump();
}).catch((e) => msg('This phone’s storage isn’t available (' + e.message + '): takes go only while the page is open.'));
render();
$('setup').addEventListener('click', () => post({ setup: true }).then(() => msg('Asked the computer to set it up…')).catch((e) => msg(e.message)));
$('copy').addEventListener('click', () => {
  const u = $('phonea').href;
  if (!topic || !topic.secure) return msg('The computer has no Tailscale name for this yet (MagicDNS on?).');
  (navigator.clipboard ? navigator.clipboard.writeText(u) : Promise.reject(new Error())).then(() => msg('Copied: send it to the phone.')).catch(() => msg('Copy it from the link above.'));
});
for (const b of document.querySelectorAll('#nudge button')) b.addEventListener('click', () => post({ nudge: +b.dataset.ms }).catch((e) => msg(e.message)));
addEventListener('beforeunload', (e) => { if (rec) { e.preventDefault(); e.returnValue = ''; } }); // (a take still recording: the kept ones wait)
