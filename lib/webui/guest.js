// StudioSync's guest page (lib/guestweb.lua, extension/webui.cpp; docs/rt/rt-browserjoin.md): someone with only a browser and an audio
// interface joins one project and room. Join asks for the interface (no echo cancellation, noise suppression or gain control: the input as
// it is), then one WebSocket carries the session mix down and their sound up (guestworklet.js does both on the audio thread). A take is
// recorded here, lossless, while the host's REAPER plays, and sent as a WAV; the computer puts it on "<name> (guest)" where the song was
// when they heard it: the link-clock stamp the mix carried at (first frame - their round trip), plus REAPER's output latency. The round trip
// comes from the loopback test (a cable from an output to an input, or headphones held to the mic) or, until it's run, the browser's own
// latency figures. Everything from the computer goes in as text. GPL-3.0-or-later.
'use strict';
const $ = (id) => document.getElementById(id);
const keep = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) {} return null; };
const S = { topic: null, ctx: null, node: null, stream: null, ws: null, map: [], rec: null, rate: 0, rt: null, test: null, muted: false, joined: false, upq: [] };
const MAX_TAKE_BYTES = 150 * 1024 * 1024; // (the computer keeps 160 MB a guest upload)

function say(t) { $('msg').textContent = t || ''; }
function conn(text, cls) { const c = $('conn'); c.textContent = text; c.className = 'conn ' + (cls || ''); }
function post(a) {
  return fetch('api/guest/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' }, body: JSON.stringify(a) })
    .then((r) => { if (!r.ok) throw new Error(r.status === 503 ? 'busy: try again' : 'the computer said ' + r.status); });
}
function clock(s) { const m = Math.floor(s / 60); return m + ':' + (s % 60).toFixed(1).padStart(4, '0'); }

// ---- the round trip ----------------------------------------------------------------------------------------------------------------------
// Where each click came back: the first sample past halfway from the input's own level (the 40 ms before the click) to the loudest in the
// window after it (a click to the next, less a little); a click must stand well above that level, and no sooner than 1 ms (a mic hearing a
// steady sound isn't a cable). clicks: output frames; got(frame) -> the input sample at that frame or undefined. -> the median lateness in
// frames, or null with fewer than 3. Pure.
function findLatency(clicks, got, rate) {
  const lates = [];
  for (let i = 0; i < clicks.length; i++) {
    const from = clicks[i], to = from + Math.round(rate * 0.45);
    let peak = 0, floor = 0;
    for (let f = from - Math.round(rate * 0.04); f < from; f++) { const v = got(f); if (v !== undefined) floor = Math.max(floor, Math.abs(v)); }
    for (let f = from; f < to; f++) { const v = got(f); if (v !== undefined) peak = Math.max(peak, Math.abs(v)); }
    if (peak < 0.02 || peak < floor * 3) continue; // (nothing came back: no cable, the volume down, or only what the input hears anyway)
    for (let f = from; f < to; f++) {
      const v = got(f);
      if (v !== undefined && Math.abs(v) >= floor + (peak - floor) * 0.5) { if (f - from >= rate * 0.001) lates.push(f - from); break; }
    }
  }
  if (lates.length < 3) return null;
  lates.sort((a, z) => a - z);
  return lates[(lates.length - 1) >> 1];
}
// The link-clock moment output frame f carried, from the worklet's map points (the nearest one, its rate on from there). Pure.
function timeAt(map, f, rate) {
  if (!map.length) return null;
  let best = map[0];
  for (const p of map) if (Math.abs(p[0] - f) < Math.abs(best[0] - f)) best = p;
  return best[1] + (f - best[0]) / rate;
}
// The round trip in frames: measured here (kept per input and output, as the test can only be redone by hand), else the browser's figures.
function roundTrip() {
  const m = Number(keep(rtKey()));
  if (m > 0) return { frames: Math.round(m * S.rate), measured: true };
  const st = S.stream && S.stream.getAudioTracks()[0].getSettings ? S.stream.getAudioTracks()[0].getSettings() : {};
  const est = (S.ctx.outputLatency || S.ctx.baseLatency || 0.01) + (typeof st.latency === 'number' ? st.latency : 0.01);
  return { frames: Math.round(est * S.rate), measured: false };
}
const rtKey = () => 'ss-guest-rt ' + ($('input').value || 'default') + ' ' + ($('output').value || 'default');

// ---- the interface -------------------------------------------------------------------------------------------------------------------------
async function devices() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;
  const list = await navigator.mediaDevices.enumerateDevices();
  for (const [id, kind, none] of [['input', 'audioinput', 'Default input'], ['output', 'audiooutput', 'Default output']]) {
    const sel = $(id), was = sel.value || keep('ss-guest-' + id) || '';
    sel.replaceChildren(new Option(none, ''));
    for (const d of list) if (d.kind === kind && d.deviceId && d.deviceId !== 'default') sel.append(new Option(d.label || kind + ' ' + (sel.length), d.deviceId));
    sel.value = [...sel.options].some((o) => o.value === was) ? was : '';
  }
  $('outrow').hidden = !(window.AudioContext && AudioContext.prototype.setSinkId);
}
async function openInput() {
  const audio = { channelCount: { ideal: 2 }, echoCancellation: false, noiseSuppression: false, autoGainControl: false, latency: { ideal: 0 } };
  if ($('input').value) audio.deviceId = { exact: $('input').value };
  const stream = await navigator.mediaDevices.getUserMedia({ audio });
  const st = stream.getAudioTracks()[0].getSettings ? stream.getAudioTracks()[0].getSettings() : {};
  $('inputwhy').textContent = st.channelCount === 1 && $('chans').value !== '0' ? 'This input gives the browser one channel: input 1 is used.' :
    st.echoCancellation ? 'The browser kept echo cancellation on for this input: use headphones and another browser if it sounds processed.' : '';
  return stream;
}
const pickOf = () => { const v = $('chans').value; return v === '1' ? 1 : v === 'stereo' || v === 'sum' ? v : 0; };

async function join() {
  if (!(window.isSecureContext && navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) return say('This page needs its https:// address (the link the host sent) for the microphone.');
  if (!window.AudioWorkletNode) return say('This browser can’t do live audio here (no AudioWorklet): try a current Chrome, Edge, Firefox or Safari.');
  const t = S.topic || {};
  $('join').disabled = true;
  try {
    S.rate = t.srate > 0 ? t.srate : 48000;
    S.ctx = new AudioContext({ sampleRate: S.rate, latencyHint: 'interactive' }); // (REAPER's rate: the browser converts to the device's)
    if ($('output').value && S.ctx.setSinkId) await S.ctx.setSinkId($('output').value).catch(() => {});
    await S.ctx.audioWorklet.addModule('guestworklet.js');
    S.stream = await openInput();
    await devices();
    const src = S.ctx.createMediaStreamSource(S.stream);
    S.node = new AudioWorkletNode(S.ctx, 'ss-guest', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [2], channelCount: 2,
      channelCountMode: 'max', channelInterpretation: 'discrete', processorOptions: { pick: pickOf() } });
    S.node.port.onmessage = fromWorklet;
    S.node.port.postMessage({ gain: Number($('vol').value) });
    src.connect(S.node);
    S.node.connect(S.ctx.destination);
    if (S.ctx.state === 'suspended') await S.ctx.resume();
    S.joined = true;
    live();
    show();
    say('Joined. Put headphones on: the session plays here, and what your interface hears goes to the session.');
  } catch (e) {
    $('join').disabled = false;
    say('Couldn’t start: ' + (e && e.name === 'NotAllowedError' ? 'the browser wasn’t allowed the microphone' : (e && e.message) || e));
  }
}
function live() {
  if (S.ws) return;
  const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/guest/live');
  ws.binaryType = 'arraybuffer';
  S.ws = ws;
  ws.onopen = () => conn('live', 'ok');
  ws.onmessage = (e) => {
    const d = e.data;
    if (!(d instanceof ArrayBuffer) || d.byteLength < 20) return;
    const v = new DataView(d);
    if (v.getUint32(0, true) !== 0x00314753) return; // ("SG1\0")
    const rate = v.getUint32(4, true), t = v.getFloat64(8, true);
    if (rate !== S.rate) return restart(rate);
    const pcm = new Int16Array(d, 16, (d.byteLength - 16) >> 1);
    S.node.port.postMessage({ mix: pcm, t }, [d]);
  };
  ws.onclose = (e) => {
    S.ws = null;
    if (e.code === 1008) { conn('ended', 'bad'); return say('The host ended your session.'); }
    conn('reconnecting', 'bad');
    if (S.joined) setTimeout(live, 2000);
  };
}
async function restart(rate) { // (REAPER's rate changed: the audio again at the new one)
  say('The session’s sample rate changed: starting the audio again.');
  S.joined = false;
  if (S.ws) S.ws.close();
  if (S.ctx) await S.ctx.close();
  S.topic = Object.assign({}, S.topic, { srate: rate });
  $('join').disabled = false;
  join();
}
let live16 = [], liveN = 0;
function fromWorklet(e) {
  const d = e.data;
  if (d.map) { S.map.push(d.map); if (S.map.length > 4000 && !S.rec) S.map.splice(0, 2000); }
  if (d.clickAt != null && S.test) S.test.clicks.push(d.clickAt);
  if (!d.live) return;
  let pk = 0;
  for (let i = 0; i < d.take.length; i++) pk = Math.max(pk, Math.abs(d.take[i]));
  S.peak = Math.max(S.peak || 0, pk);
  if (S.test) { S.test.blocks.push([d.f, d.take, pickOf() === 'stereo' ? 2 : 1]); }
  if (S.rec && !S.rec.stopped) {
    if (S.rec.f0 == null) S.rec.f0 = d.f;
    S.rec.chunks.push(d.take);
    S.rec.frames += 512;
    if (S.rec.frames * 4 * S.rec.channels > MAX_TAKE_BYTES) stopTake('the take reached the longest the computer takes in one go');
  }
  if (S.ws && S.ws.readyState === 1 && !S.muted) { // (10 ms or so a message)
    live16.push(d.live); liveN += 512;
    if (liveN >= 512) { for (const b of live16) S.ws.send(b.buffer); live16 = []; liveN = 0; }
  }
}

// ---- the loopback test --------------------------------------------------------------------------------------------------------------------
function loopTest() {
  if (!S.node) return say('Join first.');
  if (S.rec && !S.rec.stopped) return say('Stop the take first: the test plays clicks instead of the session.');
  if (S.test) return;
  S.test = { clicks: [], blocks: [] };
  say('Measuring: the clicks play on your output; a cable to an input (or headphones held to the mic) brings them back…');
  S.node.port.postMessage({ click: 8 });
  setTimeout(() => {
    const t = S.test;
    S.test = null;
    const got = (f) => {
      for (const [f0, take, ch] of t.blocks) if (f >= f0 && f < f0 + 512) return take[(f - f0) * ch];
      return undefined;
    };
    const lat = findLatency(t.clicks, got, S.rate);
    if (lat == null) return say('No clicks came back: connect an output to an input with a cable (or hold the headphones to the mic) and turn it up.');
    keep(rtKey(), String(lat / S.rate));
    say('Round trip: ' + (lat / S.rate * 1000).toFixed(1) + ' ms (kept for this input and output). Takes are placed by it.');
    show();
  }, 4800);
}

// ---- takes --------------------------------------------------------------------------------------------------------------------------------
function startTake() {
  if (!S.joined) return say('Join first.');
  const stereo = pickOf() === 'stereo';
  S.rec = { chunks: [], frames: 0, f0: null, channels: stereo ? 2 : 1, cid: Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, '0')).join(''), played: false };
  say('Recording: it goes in where the host’s REAPER plays. Stop when you’re done (it stops by itself when the host stops).');
  show();
}
async function stopTake(why) {
  const r = S.rec;
  if (!r || r.stopped) return;
  r.stopped = true;
  show();
  if (!r.frames) { S.rec = null; return say('Nothing was recorded.'); }
  const rt = roundTrip();
  const heard = timeAt(S.map, r.f0 - rt.frames, S.rate);
  if (heard == null) { S.rec = null; return say('The session’s sound never reached this page, so the take has no place: is the host’s REAPER playing audio?'); }
  const t0 = heard + ((S.topic && S.topic.outlat) || 0);
  const len = r.frames / S.rate;
  const blob = phonefile.wav(r.chunks, r.frames, S.rate, r.channels, null, 'StudioSync guest take: ' + ((S.topic && S.topic.song) || ''), (S.topic && S.topic.name) || 'guest');
  r.blob = blob;
  r.take = { t0, len, err: rt.measured ? 8 : 30, cid: r.cid };
  saveLink(blob);
  S.upq.push(r);
  S.rec = null;
  say((why ? why + ': ' : '') + 'sending the take (' + (blob.size / 1048576).toFixed(1) + ' MB)…');
  send(r);
}
function upload(blob) {
  return new Promise((res, rej) => {
    const x = new XMLHttpRequest();
    x.open('POST', 'api/guest/upload');
    x.setRequestHeader('X-StudioSync', '1');
    x.setRequestHeader('Content-Type', 'application/octet-stream');
    x.upload.onprogress = (e) => { if (e.lengthComputable) $('up').value = e.loaded / e.total; };
    x.onload = () => { try { const j = JSON.parse(x.responseText); if (x.status === 200 && j.ok) return res(j.id); } catch (e) {} rej(new Error(x.status === 413 ? 'the take is too long for one upload' : 'the computer said ' + x.status)); };
    x.onerror = () => rej(new Error('the connection dropped'));
    x.send(blob);
  });
}
async function send(r) {
  try {
    const id = await upload(r.blob);
    await post({ take: Object.assign({ id }, r.take) });
    say('Sent: the computer says where it went in a moment.');
  } catch (e) {
    say('The take wasn’t sent (' + e.message + '): press Send again, or Save it to this computer.');
    $('again').hidden = false;
  }
}
function saveLink(blob) {
  const a = $('save');
  if (a.href) URL.revokeObjectURL(a.href);
  a.href = URL.createObjectURL(blob);
  a.download = 'StudioSync guest take ' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.wav';
  a.hidden = false;
}

// ---- what the computer says -----------------------------------------------------------------------------------------------------------------
let saidAt = 0, wasPlaying = false;
function fromTopic(t) {
  if (!t) return;
  S.topic = t;
  $('who').textContent = (t.name || 'Guest') + (t.host ? ' (invited by ' + t.host + ')' : '');
  $('where').textContent = (t.song || '') + (t.room && t.room !== 'main' ? ' / ' + t.room : '');
  $('pos').textContent = !t.here ? 'The host has another project in front right now.' : t.playing ? (t.rec ? 'Recording at ' : 'Playing at ') + (t.bar || clock(t.pos || 0)) : 'Stopped at ' + (t.bar || clock(t.pos || 0));
  if (t.said && t.said_at !== saidAt) { saidAt = t.said_at; $('said').textContent = t.said; }
  if (S.rec && !S.rec.stopped) { // (the take ends when the host's playing does, once it played during it)
    if (t.playing) S.rec.played = true;
    else if (wasPlaying && S.rec.played) setTimeout(() => stopTake('the host stopped'), 600); // (the last of the mix is still on its way)
  }
  wasPlaying = !!t.playing;
  if (t.ends) $('ends').textContent = 'Your session ends at ' + new Date(t.ends * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + '.';
}
function show() {
  $('join').hidden = S.joined;
  $('controls').hidden = !S.joined;
  $('rec').textContent = S.rec && !S.rec.stopped ? 'Stop the take' : 'Record a take';
  $('rec').classList.toggle('on', !!(S.rec && !S.rec.stopped));
  $('mute').textContent = S.muted ? 'Unmute' : 'Mute me';
  if (S.ctx) { const rt = roundTrip(); $('rt').textContent = (rt.frames / S.rate * 1000).toFixed(1) + ' ms ' + (rt.measured ? '(measured)' : '(estimated: run the test)'); }
}
function meter() {
  $('level').value = Math.min(1, S.peak || 0);
  S.peak = (S.peak || 0) * 0.85;
  requestAnimationFrame(meter);
}

// ---- wiring --------------------------------------------------------------------------------------------------------------------------------
if (typeof document !== 'undefined' && $('join')) {
  history.replaceState(null, '', location.pathname); // (the code never stays in the address bar or the history)
  $('join').addEventListener('click', join);
  $('rec').addEventListener('click', () => (S.rec && !S.rec.stopped ? stopTake() : startTake()));
  $('mute').addEventListener('click', () => { S.muted = !S.muted; show(); });
  $('test').addEventListener('click', loopTest);
  $('again').addEventListener('click', () => { $('again').hidden = true; const r = S.upq[S.upq.length - 1]; if (r) send(r); });
  $('leave').addEventListener('click', () => { if (confirm('Leave the session? The link won’t work again.')) post({ leave: true }).then(() => { S.joined = false; if (S.ws) S.ws.close(); say('You left the session.'); }); });
  $('vol').addEventListener('input', () => { keep('ss-guest-vol', $('vol').value); if (S.node) S.node.port.postMessage({ gain: Number($('vol').value) }); });
  $('chans').addEventListener('change', () => { keep('ss-guest-chans', $('chans').value); if (S.node) S.node.port.postMessage({ pick: pickOf() }); });
  for (const id of ['input', 'output']) $(id).addEventListener('change', () => { keep('ss-guest-' + id, $(id).value); if (S.joined) say('Leave and open the page again to use the new ' + id + '.'); show(); });
  $('vol').value = keep('ss-guest-vol') || '1';
  $('chans').value = keep('ss-guest-chans') || '0';
  devices();
  requestAnimationFrame(meter);
  const es = new EventSource('api/guest/events');
  es.onmessage = (e) => {
    try {
      const s = JSON.parse(e.data);
      for (const k in s.topics || {}) if (k.startsWith('guest-')) fromTopic(s.topics[k]);
      if (!S.joined) conn(s.engine ? 'ready' : 'the host’s Live sync isn’t running', s.engine ? 'ok' : 'bad');
    } catch (err) {}
  };
  es.onerror = () => { if (!S.joined) conn('reconnecting', 'bad'); };
  window.ssGuest = { S, findLatency, timeAt, stopTake, startTake }; // (tests)
}
if (typeof module !== 'undefined') module.exports = { findLatency, timeAt }; // (tests)
