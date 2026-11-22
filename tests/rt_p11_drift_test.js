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
// far (rt-audio3, rt-t1's guest 78 ms of round trip away through `tailscale serve`, TCP): { delay (s, one way), every, pause (s) }: every
// `every` s or so the link holds everything for `pause` s (a lost segment's retransmit, a stalled tab), and what was held comes at once;
// settle: the seconds left out of the counts. Also -> under (the worklet's own count from settle on), rateMean (its read rate from then
// on, averaged), rateLo and rateHi (the lowest and highest it read at from then on) and size (its buffer's size at the end, s).
// far.big, far.bigEvery (rt-audio3 round 2): a longer hold of ~big s every ~bigEvery s on top (rt-r5's link: ping 84-748 ms).
function run(file, ppm, mk, secs = 600, seed = 7, far = null, settleS = 20) {
  const { scope, cls } = load(file);
  const proc = new cls({ processorOptions: {} });
  let rnd = seed;
  const rand = () => { rnd = (rnd * 1103515245 + 12345) % 2147483648; return rnd / 2147483648; };
  const PIECE = 480, BLK = 128, srS = SR * (1 + ppm * 1e-6);
  const queue = []; // ([arrival time, pcm, t])
  let sent = 0, phase = 0, nextSend = 0, lastArr = 0, heldTo = 0, nextPause = far ? far.every : 1e18, nextBig = far && far.big ? far.bigEvery : 1e18;
  let rateLo = 9, rateHi = 0;
  const L = new Float32Array(BLK), R = new Float32Array(BLK);
  let prev = 0, jumps = 0, quietRun = 0, gaps = 0, fillMin = 1e9, fillMax = -1e9, frames = 0, under0 = -1, rateSum = 0, rateN = 0;
  const settle = settleS * SR;
  for (let b = 0; b * BLK < secs * SR; b++) {
    const now = b * BLK / SR;
    while (nextSend <= now) { // (the sender's pieces, on its own clock, each with its network delay; never out of order)
      const pcm = new Int16Array(PIECE * 2);
      for (let i = 0; i < PIECE; i++) { const v = Math.round(0.5 * Math.sin(phase) * 32767); pcm[2 * i] = pcm[2 * i + 1] = v; phase += 2 * Math.PI * 440 / SR; }
      if (far && nextSend >= nextPause) { heldTo = nextSend + far.pause * (0.6 + 0.8 * rand()); nextPause = nextSend + far.every * (0.5 + rand()); }
      if (nextSend >= nextBig) { heldTo = nextSend + far.big * (0.75 + 0.5 * rand()); nextBig = nextSend + far.bigEvery * (0.5 + rand()); }
      const arr = Math.max(lastArr, nextSend + (far ? far.delay : 0) + rand() * 0.015, heldTo);
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
      if (st) {
        fillMin = Math.min(fillMin, st.fill); fillMax = Math.max(fillMax, st.fill);
        if (under0 < 0) under0 = st.under;
        rateSum += st.rate; rateN++;
        rateLo = Math.min(rateLo, st.rate); rateHi = Math.max(rateHi, st.rate);
      }
    }
  }
  const st = scope.lastStats || {};
  return { jumps, gaps, fillMin: fillMin / SR * 1000, fillMax: fillMax / SR * 1000, stats: scope.lastStats, under: under0 < 0 ? -1 : st.under - under0,
    rateMean: rateN ? rateSum / rateN : 0, rateLo, rateHi, size: st.target || 0 };
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

// rt-audio3 (rt-t1's 15-minute guest run, 2026-11-22): a guest 78 ms of round trip away over TCP, whose link holds everything for 0.1-0.25 s
// every few seconds. Its fixed 80 ms ran dry at every hold (15 underruns a minute), and each restart, behind the burst the hold let go, was
// read off at the full 0.5 % for most of a minute: heard 0.2-0.85 % sharp. Now the buffer grows to what the link needs and the read rate is
// the clocks' ratio (300 ppm here) on average.
{
  const r = run(files.guest, 300, guest, 900, 11, { delay: 0.039, every: 4, pause: 0.18 }, 240);
  console.log(`     guest page, far away (39 ms each way, held ~0.18 s every ~4 s, REAPER +300 ppm) for 15 minutes: ${r.under} underruns from 4 minutes on; read at ${((r.rateMean - 1) * 1e6).toFixed(0)} ppm on average; its buffer's size ${(r.size * 1000).toFixed(0)} ms at the end`);
  check(r.under >= 0 && r.under <= 4, 'guest page, far away: its buffer grew to what the link needs: 4 underruns at most in 11 minutes (it was 15 a minute: a fixed 80 ms)');
  check(Math.abs(r.rateMean - 1.0003) < 0.0006, 'guest page, far away: read at the two clocks\' ratio on average, not sharp (it was heard 0.2-0.85 % sharp for 15 minutes)');
  check(r.size > 0.1 && r.size <= 0.4, 'guest page, far away: and it says its buffer\'s size (stats target)');
}

// rt-audio3 round 2 (rt-r5's guests run, 2026-11-22, the guest pages on a laptop whose link to the host pinged 84-748 ms, 190 on average):
// the pages' buffers sat at their 0.4 s most and still ran dry 12 and 14 times in 11 minutes, and a guest's 1500 Hz tone was heard at
// 1492.8-1506.3 Hz (+-0.5 %): with every hold the buffer's mean fell and rose again, P ran at its bound either way and R wandered. Here
// the link holds everything ~0.2 s every ~1.5 s and ~0.6 s every ~50 s. The buffer may now grow to 0.8 s, and the level the rate goes by
// is a time (what waits plus how long ago the newest piece came), which a hold doesn't move.
{
  const r = run(files.guest, 300, guest, 900, 23, { delay: 0.08, every: 1.5, pause: 0.2, big: 0.6, bigEvery: 50 }, 240);
  const off = Math.max(Math.abs(r.rateLo - 1.0003), Math.abs(r.rateHi - 1.0003));
  console.log(`     guest page, a link that holds (~0.2 s every ~1.5 s, ~0.6 s every ~50 s, REAPER +300 ppm) for 15 minutes: ${r.under} underruns from 4 minutes on; read at ${((r.rateLo - 1) * 1e6).toFixed(0)} to ${((r.rateHi - 1) * 1e6).toFixed(0)} ppm (${((r.rateMean - 1) * 1e6).toFixed(0)} on average); its buffer's size ${(r.size * 1000).toFixed(0)} ms at the end`);
  check(r.under >= 0 && r.under <= 8, 'guest page, a link that holds: 8 underruns at most in 11 minutes (12 and 14 at a 0.4 s most, rt-r5)');
  check(off < 0.0015, 'guest page, a link that holds: read within 0.15 % of the two clocks\' ratio in every look (a tone moved +-0.5 %, rt-r5)');
  check(r.size > 0.4 && r.size <= 0.8, 'guest page, a link that holds: its buffer grew past 0.4 s to what the link holds');
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
  // rt-audio3 (rt-t1: `ahead` wandered 0.14-1.03 s over 15 minutes): the same with the link holding ~0.5 s every ~20 s, the page's own
  // rules (listen.js play(): the lead 50 ms longer after an underrun, a packet past lead + OVER dropped, the pace started again at each).
  // Once the lead has grown to the link, `ahead` never sits more than 0.3 s past it (it dips under while the link holds, and comes back)
  // and the packets play at the clocks' ratio on average.
  {
    const rules = scope.window.ssListenRules || { OVER: 0.4, FRESH_OVER: 0.4 }, again = scope.window.ssListenPaceAgain || (() => {}); // (the old page: lead + 0.4 always, no restart)
    let rnd = 5, next = 0, lead = 0.25, heldTo = 0, nextPause = 20, under = 0, over = 0, rateSum = 0, rateN = 0, st = {}, fresh = -1e9;
    const rand = () => { rnd = (rnd * 1103515245 + 12345) % 2147483648; return rnd / 2147483648; };
    const srS = SR * 1.0003;
    for (let k = 0; k < 900 * 50 && typeof pace === 'function'; k++) {
      const made = k * 960 / srS;
      if (made >= nextPause) { heldTo = made + 0.3 + 0.4 * rand(); nextPause = made + 10 + 20 * rand(); }
      const now = Math.max(made + 0.02, heldTo);
      if (next < now + 0.02) { if (next) { if (k > 12000) under++; lead = Math.min(0.8, lead + 0.05); } next = now + lead; fresh = now; again(st); }
      if (next > now + lead + (now - fresh < 1 ? rules.FRESH_OVER : rules.OVER)) continue;
      const rate = pace(st, next - now, lead);
      next += 960 / SR / rate;
      if (k > 12000) { over = Math.max(over, next - now - lead); rateSum += rate; rateN++; }
    }
    console.log(`     listen page, held ~0.5 s every ~20 s for 15 minutes: from 4 minutes on ${under} underruns, ahead at most ${(over * 1000).toFixed(0)} ms past its lead (${(lead * 1000).toFixed(0)} ms by then), played at ${((rateSum / Math.max(1, rateN) - 1) * 1e6).toFixed(0)} ppm on average (the clocks: +300)`);
    check(over < 0.3 && Math.abs(rateSum / Math.max(1, rateN) - 1.0003) < 0.0006, 'listen page, a link that holds: ahead never sits 0.3 s past its lead and the pace is the clocks\' ratio (ahead wandered 0.14-1.03 s, read off sharp)');
  }
}
console.log(fails ? `fails ${fails}` : 'ok, fails 0');
process.exit(fails ? 1 : 0);
