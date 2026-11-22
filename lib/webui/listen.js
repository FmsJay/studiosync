// The listening page (lib/audience.lua, extension/audience.cpp; docs/rt/rt-audience.md): the band's live session as Opus packets over one
// WebSocket (/listen/live?l=<code>), decoded with WebCodecs and played a quarter of a second behind; the song, whether it's live and (on the
// tailnet) who's playing come as small JSON texts on the same socket. When nobody plays, the song's latest mix (/listen/mix?l=<code>). It
// sends nothing back. Everything shown goes in as text. GPL-3.0-or-later.
'use strict';
// The pace (rt-p11, backlog 1.19): REAPER's audio clock and the browser's drift apart, so packets played back to back at exactly their rate
// pile up (one dropped past lead + OVER) or run dry (an underrun) every so often on a long listen. Each one plays at 1 + R + P: ssPace, the
// control lib/webui/guestworklet.js explains (the same text). It was 1 + (ahead - lead) x 0.05 within 0.5 %, level only: after an underrun
// the packets behind it piled up to lead + 0.4 s and were read off for minutes, and `ahead` wandered 0.14-1.03 s on a 15-minute listen
// (rt-t1). rt-audio3. st: its state. Pure.
const PACE_WIN = 0.5, PACE_KP = 0.2, PACE_P = 0.001, PACE_R = 0.01, PACE_I = 0.05, PACE_BACK = 4, PACE_JUMP = 0.03, PACE_AGE = 1;
function ssPace(st, fill, target, dt, age) {
  if (age != null) fill += Math.max(0, Math.min(PACE_AGE, age)); // (the level as a time: what waits plus how long ago the newest piece came)
  st.sum = (st.sum || 0) + fill * dt; st.t = (st.t || 0) + dt;
  if (st.t < PACE_WIN) return st.rate || 1 + (st.r || 0);
  const e = st.sum / st.t - target, T = st.t, h = st.h || (st.h = []), was = Math.abs(st.p || 0) * T;
  st.sum = 0; st.t = 0; st.mean = e + target;
  if (h.length && Math.abs(e - h[h.length - 1][0]) > PACE_JUMP) h.length = 0; // (a jump between two windows isn't a rate: R learns nothing from it)
  let did = was;
  for (let i = 1; i < h.length; i++) did += h[i][1];
  if (h.length >= 2 && Math.abs(e) > Math.abs(h[0][0]) - 0.5 * did)
    st.r = Math.max(-PACE_R, Math.min(PACE_R, (st.r || 0) + PACE_KP * PACE_KP / 4 * Math.max(-PACE_I, Math.min(PACE_I, e)) * T));
  h.push([e, was]); if (h.length > PACE_BACK) h.shift();
  st.p = Math.max(-PACE_P, Math.min(PACE_P, PACE_KP * e));
  return (st.rate = 1 + (st.r || 0) + st.p);
}
function ssPaceAgain(st) { st.sum = 0; st.t = 0; st.h = []; st.p = 0; st.rate = 1 + (st.r || 0); } // (a restart or a cut: the level starts anew, R is kept)
window.ssListenPace = (st, ahead, lead) => ssPace(st, ahead, lead, 0.02); // (a look per 20 ms packet)
window.ssListenPaceAgain = ssPaceAgain;
// The lead: LEAD, 50 ms more after each underrun (up to LEAD_MAX), and back 50 ms at a time after `need` s without one; `need` doubles when
// a step back is followed by an underrun inside it, as the guest page's buffer. OVER: a packet that far past the lead is dropped.
const LEAD = 0.25, LEAD_MAX = 0.8, LEAD_STEP = 0.05, NEED = 60, NEED_MAX = 960, OVER = 0.25, FRESH_OVER = 0.06;
window.ssListenRules = { OVER, FRESH_OVER }; // (tests)
(() => {
  const $ = (id) => document.getElementById(id);
  const code = new URLSearchParams(location.search).get('l') || '';
  const ui = { song: $('song'), dot: $('dot'), state: $('stateText'), who: $('who'), go: $('go'), vol: $('vol'), note: $('note'), mixBox: $('mixBox'), mix: $('mix') };
  const RATE = 48000;
  let info = {}, ws = null, fails = 0, ended = false, lastPacket = 0, ctx = null, gain = null, dec = null, next = 0, lead = LEAD, on = false;
  let gaps = 0, under = 0, lastSeq = -1, mixSet = false, pace = {}, need = NEED, calm = 0, shrunk = 1e9, drops = 0, fresh = -1e9;
  const canLive = typeof AudioDecoder === 'function' && typeof EncodedAudioChunk === 'function' && window.isSecureContext;
  if (!canLive) ui.note.textContent = 'This browser can’t play the live stream (it needs a recent Chrome, Edge, Firefox or Safari on an https link). The latest mix still plays.';

  function draw() {
    const live = !!info.live && performance.now() - lastPacket < 1500;
    ui.song.textContent = info.song || '…';
    document.title = (info.song ? info.song + ' · ' : '') + (live ? 'live' : 'listening');
    ui.dot.className = 'dot' + (live ? ' live' : '');
    ui.state.textContent = ended ? 'This listening link has ended.' : !ws || ws.readyState !== 1 ? (fails > 2 ? 'Can’t reach the band right now. Trying again…' : 'Connecting…')
      : live ? 'Live now' : 'Nobody’s playing right now';
    const who = Array.isArray(info.who) ? info.who.filter((n) => typeof n === 'string') : [];
    ui.who.hidden = !who.length;
    ui.who.textContent = who.length ? 'Playing: ' + who.join(', ') : '';
    const hasMix = !!info.mix;
    if (hasMix && !mixSet) { ui.mix.src = 'mix?l=' + encodeURIComponent(code); mixSet = true; }
    ui.mixBox.hidden = !hasMix || (live && ui.mix.paused);
    ui.go.disabled = !canLive || ended;
    ui.go.textContent = on ? 'Stop listening' : 'Listen live';
    ui.go.setAttribute('aria-pressed', on ? 'true' : 'false');
  }

  function connect() {
    if (ended || !code) return;
    ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/listen/live?l=' + encodeURIComponent(code));
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => { fails = 0; draw(); };
    ws.onmessage = (e) => {
      if (typeof e.data === 'string') {
        try { const j = JSON.parse(e.data); if (j && typeof j === 'object') info = j; } catch (_) { /* not ours */ }
        draw();
        return;
      }
      if (e.data.byteLength < 5) return;
      const seq = new DataView(e.data).getUint32(0, true);
      if (lastSeq >= 0 && seq !== lastSeq + 1) gaps++;
      lastSeq = seq;
      const was = performance.now() - lastPacket > 1500;
      lastPacket = performance.now();
      if (was) draw();
      if (on && dec && dec.state === 'configured') {
        try { dec.decode(new EncodedAudioChunk({ type: 'key', timestamp: seq * 20000, data: new Uint8Array(e.data, 4) })); } catch (_) { gaps++; }
      }
    };
    ws.onclose = (e) => {
      ws = null;
      if (e.code === 1008) { ended = true; stop(); draw(); return; }
      fails++;
      draw();
      setTimeout(connect, Math.min(10000, 1000 * fails));
    };
  }

  // A decoded 20 ms: on the clock `lead` ahead; an underrun waits a little longer next time (up to 0.8 s), and running far ahead drops one.
  function play(data) {
    const n = data.numberOfFrames, ch = Math.min(2, data.numberOfChannels);
    if (!ctx || !n) { data.close(); return; }
    const now = ctx.currentTime, dur = n / data.sampleRate;
    if (next < now + 0.02) { // (ran dry, or the first one: from the lead again)
      if (next) { under++; if (shrunk < need) need = Math.min(NEED_MAX, need * 2); lead = Math.min(LEAD_MAX, lead + LEAD_STEP); calm = 0; }
      next = now + lead; fresh = now;
      ssPaceAgain(pace);
    }
    // (the burst behind a pause isn't kept as delay, nor read off for minutes: past lead + OVER a packet is dropped, and for the first second
    // after running dry past lead + FRESH_OVER, so it starts again at its lead)
    if (next > now + lead + (now - fresh < 1 ? FRESH_OVER : OVER)) { data.close(); drops++; return; }
    calm += dur; shrunk += dur;
    if (calm > need && lead > LEAD) { lead = Math.max(LEAD, lead - LEAD_STEP); calm = 0; shrunk = 0; }
    const buf = ctx.createBuffer(2, n, data.sampleRate);
    for (let c = 0; c < 2; c++) {
      const plane = new Float32Array(n);
      data.copyTo(plane, { planeIndex: Math.min(c, ch - 1), format: 'f32-planar' });
      buf.copyToChannel(plane, c);
    }
    data.close();
    const src = ctx.createBufferSource();
    src.buffer = buf;
    const rate = window.ssListenPace(pace, next - now, lead);
    src.playbackRate.value = rate;
    src.connect(gain);
    src.start(next);
    next += n / buf.sampleRate / rate;
  }

  function start() {
    if (!canLive || on) return;
    ctx = new AudioContext({ sampleRate: RATE, latencyHint: 'playback' });
    gain = ctx.createGain();
    gain.gain.value = Number(ui.vol.value);
    gain.connect(ctx.destination);
    dec = new AudioDecoder({ output: play, error: () => { gaps++; setTimeout(restartDecoder, 200); } });
    dec.configure({ codec: 'opus', sampleRate: RATE, numberOfChannels: 2 });
    next = 0; lead = LEAD; on = true; pace = {}; need = NEED; calm = 0; shrunk = 1e9;
    if (!ui.mix.paused) ui.mix.pause();
    draw();
  }
  function restartDecoder() {
    if (!on) return;
    try { dec.close(); } catch (_) { /* gone */ }
    dec = new AudioDecoder({ output: play, error: () => { gaps++; } });
    dec.configure({ codec: 'opus', sampleRate: RATE, numberOfChannels: 2 });
    next = 0; pace = {};
  }
  function stop() {
    on = false;
    try { if (dec) dec.close(); } catch (_) { /* gone */ }
    if (ctx) ctx.close();
    dec = null; ctx = null; gain = null;
  }

  ui.go.addEventListener('click', () => { if (on) stop(); else start(); draw(); });
  ui.vol.addEventListener('input', () => { const v = Number(ui.vol.value); if (gain) gain.gain.value = v; ui.mix.volume = Math.min(1, v); });
  ui.mix.addEventListener('play', () => { if (on) { stop(); draw(); } });
  setInterval(draw, 1000);
  window.ssListen = { stats: () => ({ on, gaps, under, drops, lead, lastSeq, ahead: ctx ? next - ctx.currentTime : 0, rate: pace.rate || 1, ratio: pace.r || 0, state: ctx ? ctx.state : 'none' }) }; // (for tests)
  if (!code) { ended = true; ui.state.textContent = 'This page needs the full listening link the band sent.'; ui.go.disabled = true; return; }
  draw();
  connect();
})();
