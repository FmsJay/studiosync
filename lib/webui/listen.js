// The listening page (lib/audience.lua, extension/audience.cpp; docs/rt/rt-audience.md): the band's live session as Opus packets over one
// WebSocket (/listen/live?l=<code>), decoded with WebCodecs and played a quarter of a second behind; the song, whether it's live and (on the
// tailnet) who's playing come as small JSON texts on the same socket. When nobody plays, the song's latest mix (/listen/mix?l=<code>). It
// sends nothing back. Everything shown goes in as text. GPL-3.0-or-later.
'use strict';
// The pace (rt-p11, backlog 1.19): REAPER's audio clock and the browser's drift apart, so packets played back to back at exactly their rate
// pile up (one dropped past lead + 0.4 s) or run dry (an underrun) every so often on a long listen. Each one plays at a rate that follows
// how far ahead the queue is on average: 1 + (ahead - lead) x K, within 0.5% (9 cents, only when far off). st: its state. Pure.
window.ssListenPace = (st, ahead, lead) => {
  st.avg = st.avg == null ? ahead : st.avg + (ahead - st.avg) * 0.01; // (~2 s of 20 ms packets)
  return 1 + Math.max(-0.005, Math.min(0.005, (st.avg - lead) * 0.05));
};
(() => {
  const $ = (id) => document.getElementById(id);
  const code = new URLSearchParams(location.search).get('l') || '';
  const ui = { song: $('song'), dot: $('dot'), state: $('stateText'), who: $('who'), go: $('go'), vol: $('vol'), note: $('note'), mixBox: $('mixBox'), mix: $('mix') };
  const RATE = 48000;
  let info = {}, ws = null, fails = 0, ended = false, lastPacket = 0, ctx = null, gain = null, dec = null, next = 0, lead = 0.25, on = false;
  let gaps = 0, under = 0, lastSeq = -1, mixSet = false, pace = {};
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
    const now = ctx.currentTime;
    if (next < now + 0.02) { if (next) { under++; lead = Math.min(0.8, lead + 0.05); } next = now + lead; }
    if (next > now + lead + 0.4) { data.close(); return; }
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
    next = 0; lead = 0.25; on = true; pace = {};
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
  window.ssListen = { stats: () => ({ on, gaps, under, lead, lastSeq, ahead: ctx ? next - ctx.currentTime : 0, state: ctx ? ctx.state : 'none' }) }; // (for tests)
  if (!code) { ended = true; ui.state.textContent = 'This page needs the full listening link the band sent.'; ui.go.disabled = true; return; }
  draw();
  connect();
})();
