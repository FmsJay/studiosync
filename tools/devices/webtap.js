// tools/devices/webtap.js: what a page plays, captured inside the page (rt-t1, docs/rt/rt-t1.md). GPL-3.0-or-later.
// Injected before the page's own scripts (Playwright add_init_script / CDP Page.addScriptToEvaluateOnNewDocument). Every node a page connects to
// its AudioContext's destination is also connected to one ScriptProcessor per context, which keeps what reaches the speakers (the sum of
// everything connected there, before the device) while armed. Nothing is changed in what the page plays. Test-only: never on a real page.
//   window.__ssTap.start()            arm (clears what was kept); -> the context's currentTime
//   window.__ssTap.stop()             disarm; -> { frames, rate, blocks, missed, t0 }
//   window.__ssTap.chunk(i, n)        frames [i, i + n) as base64 of little-endian float32, interleaved stereo
//   window.__ssTap.stats()            { armed, frames, rate, blocks, missed, contexts, worklet: the guest worklet's last stats or null }
// `missed`: blocks whose playbackTime didn't follow the one before (the main thread was late and the browser skipped one): such a capture
// has holes of its own, not the page's. The guest worklet (guestworklet.js) answers { stats } on its port; webtap asks every 2 s.
'use strict';
(() => {
  if (window.__ssTap) return;
  const N = 4096;
  const S = { armed: false, L: [], R: [], frames: 0, rate: 0, blocks: 0, missed: 0, last: null, t0: null, ctxs: new Set(), procs: new Map(), worklet: null };
  const origConnect = AudioNode.prototype.connect;
  function procFor(ctx) {
    let p = S.procs.get(ctx);
    if (p) return p;
    p = ctx.createScriptProcessor(N, 2, 2);
    p.onaudioprocess = (e) => {
      const a = e.inputBuffer;
      S.rate = a.sampleRate;
      if (!S.armed) { S.last = null; return; }
      if (S.last != null && Math.abs(e.playbackTime - (S.last + N / a.sampleRate)) > 0.5 / a.sampleRate * N) S.missed++;
      if (S.t0 == null) S.t0 = e.playbackTime;
      S.last = e.playbackTime;
      S.L.push(new Float32Array(a.getChannelData(0)));
      S.R.push(new Float32Array(a.numberOfChannels > 1 ? a.getChannelData(1) : a.getChannelData(0)));
      S.frames += a.length;
      S.blocks++;
    };
    origConnect.call(p, ctx.destination); // (a ScriptProcessor runs only when pulled; its output stays silent)
    S.procs.set(ctx, p);
    S.ctxs.add(ctx);
    return p;
  }
  AudioNode.prototype.connect = function (dest, ...rest) {
    const r = origConnect.call(this, dest, ...rest);
    try {
      if (dest instanceof AudioDestinationNode && !(this instanceof ScriptProcessorNode && S.procs.get(this.context) === this)) origConnect.call(this, procFor(this.context));
    } catch (e) { /* a test hook must never break the page */ }
    return r;
  };
  if (window.AudioWorkletNode) {
    const W = window.AudioWorkletNode;
    window.AudioWorkletNode = function (ctx, name, opts) {
      const n = new W(ctx, name, opts);
      if (name === 'ss-guest') {
        n.port.addEventListener('message', (e) => { if (e.data && e.data.stats) S.worklet = Object.assign({ at: Date.now() }, e.data.stats); });
        setInterval(() => { try { n.port.postMessage({ stats: true }); } catch (e) { /* closed */ } }, 2000);
      }
      return n;
    };
    window.AudioWorkletNode.prototype = W.prototype;
  }
  function b64(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }
  window.__ssTap = {
    start() { S.armed = true; S.L = []; S.R = []; S.frames = 0; S.blocks = 0; S.missed = 0; S.last = null; S.t0 = null; const c = [...S.ctxs][0]; return c ? c.currentTime : null; },
    stop() { S.armed = false; return { frames: S.frames, rate: S.rate, blocks: S.blocks, missed: S.missed, t0: S.t0 }; },
    chunk(i, n) {
      const out = new Float32Array(n * 2);
      let k = 0, base = 0;
      for (let b = 0; b < S.L.length && k < n; b++) {
        const len = S.L[b].length;
        if (base + len > i) {
          for (let j = Math.max(0, i - base); j < len && k < n; j++, k++) { out[2 * k] = S.L[b][j]; out[2 * k + 1] = S.R[b][j]; }
        }
        base += len;
      }
      return b64(new Uint8Array(out.buffer, 0, k * 8));
    },
    stats() { return { armed: S.armed, frames: S.frames, rate: S.rate, blocks: S.blocks, missed: S.missed, contexts: S.ctxs.size, worklet: S.worklet }; },
  };
})();
