// rt-p11 (backlog 1.19): the browser side's drift. REAPER's audio clock and the browser's run a few hundred ppm apart; the guest page's
// worklet (lib/webui/guestworklet.js) and the screen share's REAPER mix (lib/webui/sharemix.js) used to skip (a buffer filled past its
// limit) or gap and refill (drained) every few minutes; now they read at a rate that follows the buffer. Each worklet runs here in Node with
// a stand-in AudioWorklet scope: a 440 Hz sine sent in 10 ms pieces from a clock `ppm` off the browser's, arriving with up to 15 ms of
// jitter, for 10 minutes; after the first 20 s there must be no skip or gap (no jump between two output samples a sine can't make, no
// silent stretch) and the buffer must stay near its size. The listening page's pace (lib/webui/listen.js ssListenPace) the same way.
// Run: node tests/rt_p11_drift_test.js [guestworklet.js sharemix.js listen.js] (other copies: the change removed). GPL-3.0-or-later.
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const root = path.join(__dirname, '..');
const files = { guest: process.argv[2] || path.join(root, 'lib/webui/guestworklet.js'), share: process.argv[3] || path.join(root, 'lib/webui/sharemix.js'),
  listen: process.argv[4] || path.join(root, 'lib/webui/listen.js') };
let fails = 0;
const check = (ok, what) => { console.log((ok ? '  ok   ' : '  FAIL ') + what); if (!ok) fails++; };
const SR = 48000;

function load(file) {
  let cls = null;
  const scope = {
    sampleRate: SR, currentFrame: 0, Math, Float32Array, Int16Array, console,
    registerProcessor: (name, c) => { cls = c; },
    AudioWorkletProcessor: class { constructor() { this.port = { postMessage: (m) => { if (m && m.stats) scope.lastStats = m.stats; }, onmessage: null }; } },
  };
  vm.createContext(scope);
  vm.runInContext(fs.readFileSync(file, 'utf8'), scope, { filename: file });
  return { scope, cls };
}

// One run: the sender's clock ppm fast (or slow: negative); mk(pcm, t) wraps a piece the way the page posts it. -> what was heard and counts.
function run(file, ppm, mk, secs = 600, seed = 7) {
  const { scope, cls } = load(file);
  const proc = new cls({ processorOptions: {} });
  let rnd = seed;
  const rand = () => { rnd = (rnd * 1103515245 + 12345) % 2147483648; return rnd / 2147483648; };
  const PIECE = 480, BLK = 128, srS = SR * (1 + ppm * 1e-6);
  const queue = []; // ([arrival time, pcm, t])
  let sent = 0, phase = 0, nextSend = 0, lastArr = 0;
  const L = new Float32Array(BLK), R = new Float32Array(BLK);
  let prev = 0, jumps = 0, quietRun = 0, gaps = 0, fillMin = 1e9, fillMax = -1e9, frames = 0;
  const settle = 20 * SR;
  for (let b = 0; b * BLK < secs * SR; b++) {
    const now = b * BLK / SR;
    while (nextSend <= now) { // (the sender's pieces, on its own clock, each with its network delay; never out of order)
      const pcm = new Int16Array(PIECE * 2);
      for (let i = 0; i < PIECE; i++) { const v = Math.round(0.5 * Math.sin(phase) * 32767); pcm[2 * i] = pcm[2 * i + 1] = v; phase += 2 * Math.PI * 440 / SR; }
      const arr = Math.max(lastArr, nextSend + rand() * 0.015);
      lastArr = arr;
      queue.push([arr, pcm, sent / SR]);
      sent += PIECE;
      nextSend = sent / srS;
    }
    while (queue.length && queue[0][0] <= now) { const q = queue.shift(); proc.port.onmessage({ data: mk(q[1], q[2]) }); }
    scope.currentFrame = b * BLK;
    L.fill(0); R.fill(0);
    proc.process([[]], [[L, R]]);
    for (let i = 0; i < BLK; i++, frames++) {
      const v = L[i];
      if (frames > settle) {
        if (Math.abs(v - prev) > 0.06) jumps++; // (a 0.5 440 Hz sine moves 0.029 a sample at most)
        quietRun = Math.abs(v) < 1e-4 ? quietRun + 1 : 0;
        if (quietRun === 48) gaps++; // (1 ms of silence in a sine: a gap)
      }
      prev = v;
    }
    if (frames > settle && b % 64 === 0) {
      proc.port.onmessage({ data: { stats: 1 } });
      const st = scope.lastStats;
      if (st) { fillMin = Math.min(fillMin, st.fill); fillMax = Math.max(fillMax, st.fill); }
    }
  }
  return { jumps, gaps, fillMin: fillMin / SR * 1000, fillMax: fillMax / SR * 1000, stats: scope.lastStats };
}
const guest = (pcm, t) => ({ mix: pcm, t });
const share = (pcm) => pcm;

for (const [name, file, mk, size] of [['guest page', files.guest, guest, 80], ['share mix', files.share, share, 60]]) {
  for (const ppm of [400, -400]) {
    const r = run(file, ppm, mk);
    console.log(`     ${name}, REAPER ${ppm > 0 ? '+' : ''}${ppm} ppm for 10 minutes: ${r.jumps} jumps, ${r.gaps} gaps after 20 s; buffer ${r.fillMin.toFixed(0)}-${r.fillMax.toFixed(0)} ms (size ${size}); rate ${r.stats ? r.stats.rate.toFixed(5) : '?'}`);
    check(r.jumps === 0 && r.gaps === 0, `${name}: REAPER's clock ${ppm} ppm off the browser's: no skip or gap in 10 minutes`);
    check(!!r.stats && r.fillMin > size - 30 && r.fillMax < size + 40, `${name}: ${ppm} ppm: the buffer stays near its size (the read rate follows it)`);
  }
}

// The listening page: each decoded 20 ms is scheduled `ahead` of the context's clock at a playback rate ssListenPace gives; packets from a
// clock 400 ppm off for 10 minutes must neither run dry (an underrun: `next` behind the clock) nor pile past lead + 0.4 s (a dropped packet).
{
  const el = () => ({ textContent: '', hidden: false, disabled: false, value: '1', className: '', paused: true, addEventListener() {}, setAttribute() {}, pause() {} });
  const scope = { document: { getElementById: el, title: '' }, location: { search: '', protocol: 'https:', host: 'x' }, window: {}, URLSearchParams, setInterval() {},
    setTimeout() {}, performance: { now: () => 0 }, Math, Number, Array, JSON, console };
  scope.window.isSecureContext = true;
  vm.createContext(scope);
  vm.runInContext(fs.readFileSync(files.listen, 'utf8'), scope, { filename: files.listen });
  const pace = scope.window.ssListenPace;
  check(typeof pace === 'function', 'listen page: ssListenPace is there');
  for (const ppm of [400, -400]) {
    let under = 0, drops = 0, next = 0, lo = 1e9, hi = -1e9;
    const st = {}, lead = 0.25, srS = SR * (1 + ppm * 1e-6);
    for (let k = 0; k < 600 * 50; k++) {
      const now = k * 960 / srS + 0.02; // (packet k arrives when the sender's clock has made it, decoded at once)
      if (typeof pace !== 'function') break;
      if (next < now + 0.02) { if (next && k > 1000) under++; next = now + lead; }
      if (next > now + lead + 0.4) { if (k > 1000) drops++; continue; }
      const rate = pace(st, next - now, lead);
      next += 960 / SR / rate;
      if (k > 1000) { lo = Math.min(lo, next - now); hi = Math.max(hi, next - now); }
    }
    console.log(`     listen page, ${ppm} ppm for 10 minutes: underruns ${under}, dropped ${drops}; ahead ${(lo * 1000).toFixed(0)}-${(hi * 1000).toFixed(0)} ms (lead 250)`);
    check(typeof pace === 'function' && under === 0 && drops === 0 && lo > 0.15 && hi < 0.4, `listen page: ${ppm} ppm: no underrun or dropped packet, ahead stays near its lead`);
  }
}
console.log(fails ? `fails ${fails}` : 'ok, fails 0');
process.exit(fails ? 1 : 0);
