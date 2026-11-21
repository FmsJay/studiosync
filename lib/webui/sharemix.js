// A screen share's "REAPER mix" (call.js): the extension streams REAPER's own output as 16-bit stereo (GET /api/mix, extension/webui.cpp);
// call.js posts each piece here, and this plays it into a MediaStream track that goes out with the shared picture. A small jitter buffer:
// it starts once PRE is in, refills after running dry, and drops back to PRE when it holds more than MAX (a burst). REAPER's audio clock and
// the browser's drift apart slowly, so it's read at a rate that follows its average fill (1 + (fill - PRE) x DRIFT_K, within DRIFT_MAX: 0.5%,
// 9 cents at most and only when far off) through a 4-point Hermite interpolator, instead of skipping or refilling every few minutes
// (rt-p11, backlog 1.19). { stats: 1 } -> { stats: {...} } (tests). (rt-share) GPL-3.0-or-later.
/* global sampleRate, registerProcessor, AudioWorkletProcessor */
'use strict';
const N = 1 << 17; // frames held at most (2.7 s at 48 kHz)
const DRIFT_TAU = 2, DRIFT_K = 0.05, DRIFT_MAX = 0.005; // (s the fill is averaged over; rate per second of fill off PRE; the rate's bound)
function hermite(a, b, c, d, t) { // (4-point, 3rd-order: b at t 0, c at t 1)
  const c1 = 0.5 * (c - a), c2 = a - 2.5 * b + 2 * c - 0.5 * d, c3 = 0.5 * (d - a) + 1.5 * (b - c);
  return ((c3 * t + c2) * t + c1) * t + b;
}
class ShareMix extends AudioWorkletProcessor {
  constructor() {
    super();
    this.l = new Float32Array(N); this.r = new Float32Array(N);
    this.w = 1; this.rd = 1; this.run = false; this.avg = 0; this.rate = 1; this.drops = 0; this.under = 0; // (rd fractional, a frame of history behind it)
    this.PRE = Math.round(sampleRate * 0.06); this.MAX = Math.round(sampleRate * 0.25);
    this.port.onmessage = (e) => {
      const p = e.data;
      if (p && p.stats) { this.port.postMessage({ stats: { rate: this.rate, fill: this.w - this.rd, avg: this.avg, drops: this.drops, under: this.under } }); return; }
      if (!(p instanceof Int16Array)) return;
      for (let i = 0; i + 1 < p.length; i += 2, this.w++) { const at = this.w % N; this.l[at] = p[i] / 32768; this.r[at] = p[i + 1] / 32768; }
      if (this.w - this.rd > N - 4) this.rd = this.w - this.PRE;
    };
  }
  process(inputs, outputs) {
    const out = outputs[0], L = out[0], R = out[1] || out[0], n = L.length;
    let have = this.w - this.rd;
    if (have > this.MAX) { this.rd = this.w - this.PRE; have = this.PRE; this.avg = have; this.drops++; }
    if (!this.run && have >= this.PRE) { this.run = true; this.avg = have; }
    if (!this.run || have < n * (1 + DRIFT_MAX) + 3) {
      if (this.run) this.under++;
      this.run = false; L.fill(0); if (R !== L) R.fill(0); return true;
    }
    this.avg += (have - this.avg) * Math.min(1, n / (sampleRate * DRIFT_TAU));
    this.rate = 1 + Math.max(-DRIFT_MAX, Math.min(DRIFT_MAX, (this.avg - this.PRE) / sampleRate * DRIFT_K));
    const l = this.l, r = this.r;
    let p = this.rd;
    for (let k = 0; k < n; k++, p += this.rate) {
      const i = Math.floor(p), t = p - i, i0 = (i - 1) % N, i1 = i % N, i2 = (i + 1) % N, i3 = (i + 2) % N;
      L[k] = hermite(l[i0], l[i1], l[i2], l[i3], t);
      if (R !== L) R[k] = hermite(r[i0], r[i1], r[i2], r[i3], t);
    }
    this.rd = p;
    return true;
  }
}
registerProcessor('ss-share-mix', ShareMix);
