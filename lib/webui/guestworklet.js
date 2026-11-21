// StudioSync's guest page (guest.js, lib/guestweb.lua): one processor for both directions, so the input and the output share one frame
// count (the context's): what the guest heard at output frame f and what they played at input frame f + their round trip line up.
//  in:  the interface's input, every 512 frames to the page: { f (its first frame), live (Int16 mono of the picked inputs), take (Float32,
//       the picked inputs, interleaved when stereo) }.
//  out: the session mix from the page ({ mix: Int16Array stereo, t: the link clock of its first frame }), through a jitter buffer (heard
//       once TARGET has come, cut back to it past TARGET + OVER) read at a rate that follows REAPER's clock (drift below), at `gain`; every
//       16 blocks while it plays, { map: [frame, t] }: which link-clock moment the output frame carried. { click: n }: n short clicks, 0.5 s
//       apart, instead of the mix (the loopback test), each said as { clickAt: frame }. { stats: 1 } -> { stats: {...} } (tests).
// Drift (rt-p11, backlog 1.19): REAPER's audio clock and the browser's run apart (a few hundred ppm between devices), so a buffer read at
// exactly one sample per sample slowly fills (a skip when it passed TARGET + OVER) or drains (a gap and a refill). The read rate follows the
// buffer's average fill instead: 1 + (fill - TARGET) x DRIFT_K, within DRIFT_MAX (0.5%: 9 cents at most, far off only), through a 4-point
// Hermite interpolator. GPL-3.0-or-later.
'use strict';
const TARGET = 0.08, OVER = 0.2, N = 1 << 17; // (s, s, frames held at most: 2.7 s at 48 kHz)
const DRIFT_TAU = 2, DRIFT_K = 0.05, DRIFT_MAX = 0.005; // (s the fill is averaged over; rate per second of fill off TARGET; the rate's bound)
function hermite(a, b, c, d, t) { // (4-point, 3rd-order: b at t 0, c at t 1)
  const c1 = 0.5 * (c - a), c2 = a - 2.5 * b + 2 * c - 0.5 * d, c3 = 0.5 * (d - a) + 1.5 * (b - c);
  return ((c3 * t + c2) * t + c1) * t + b;
}
class SsGuest extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = (options && options.processorOptions) || {};
    this.pick = o.pick == null ? 0 : o.pick;
    this.l = new Float32Array(N); this.r = new Float32Array(N);
    this.w = 1; this.rd = 1; // (frames written; the read position, fractional: one frame of history behind it for the interpolator)
    this.marks = []; // ([frame written at, link clock]: where each piece from the page starts, for map)
    this.playing = false; this.gain = 1; this.blocks = 0; this.avg = -1; this.rate = 1; this.drops = 0; this.under = 0;
    this.n = 0; this.live = new Int16Array(512); this.take = new Float32Array(1024); this.f0 = 0;
    this.clicks = []; // (output frames to click at)
    this.port.onmessage = (e) => {
      const d = e.data;
      if (d.mix) {
        const p = d.mix;
        this.marks.push([this.w, d.t]);
        if (this.marks.length > 64) this.marks.shift();
        for (let i = 0; i + 1 < p.length; i += 2, this.w++) { const at = this.w % N; this.l[at] = p[i] / 32768; this.r[at] = p[i + 1] / 32768; }
        if (this.w - this.rd > N - 4) this.rd = this.w - Math.round(TARGET * sampleRate);
      }
      if (d.gain != null) this.gain = d.gain;
      if (d.pick != null) this.pick = d.pick;
      if (d.click) {
        const at = currentFrame + Math.round(sampleRate * 0.3);
        for (let i = 0; i < d.click; i++) this.clicks.push(at + Math.round(i * sampleRate * 0.5));
      }
      if (d.stats) this.port.postMessage({ stats: { rate: this.rate, fill: this.w - this.rd, avg: this.avg, drops: this.drops, under: this.under } });
    };
  }
  tAt(pos) { // (the link clock of the mix at read position pos: the piece it's in)
    let m = null;
    for (const x of this.marks) if (x[0] <= pos) m = x;
    return m ? m[1] + (pos - m[0]) / sampleRate : null;
  }
  process(inputs, outputs) {
    const ins = inputs[0] || [], out = outputs[0], L = out[0], R = out[1] || out[0], len = L.length;
    // the input, to the page
    const a = ins[0], b = ins[1] || ins[0];
    if (a) {
      if (this.n === 0) this.f0 = currentFrame;
      const stereo = this.pick === 'stereo';
      for (let i = 0; i < len; i++) {
        const v1 = a[i], v2 = b[i];
        const mono = stereo || this.pick === 'sum' ? (v1 + v2) * 0.5 : this.pick === 1 ? v2 : v1;
        this.live[this.n] = Math.max(-32768, Math.min(32767, Math.round(mono * 32767)));
        if (stereo) { this.take[2 * this.n] = v1; this.take[2 * this.n + 1] = v2; } else this.take[this.n] = mono;
        if (++this.n === 512) {
          this.port.postMessage({ f: this.f0, live: this.live, take: stereo ? this.take : this.take.slice(0, 512) });
          this.live = new Int16Array(512); this.take = new Float32Array(1024); this.n = 0; this.f0 = currentFrame + i + 1;
        }
      }
    }
    // the session mix out, or the loopback test's clicks
    if (this.clicks.length) {
      for (let i = 0; i < len; i++) {
        const f = currentFrame + i, c = this.clicks[0], k = f - c;
        L[i] = R[i] = k >= 0 && k < 96 ? (k < 48 ? 0.8 : -0.8) : 0; // (a 2 ms square pulse: a sharp edge to find)
        if (k === 0) this.port.postMessage({ clickAt: f });
        if (k >= 96) this.clicks.shift();
        if (!this.clicks.length) break;
      }
      this.rd = Math.min(this.w, this.rd + len);
      return true;
    }
    const target = TARGET * sampleRate;
    let have = this.w - this.rd;
    if (!this.playing && have >= target + len) { this.playing = true; this.avg = have; }
    if (have > (TARGET + OVER) * sampleRate) { this.rd = this.w - target; have = target; this.avg = have; this.drops++; } // (a burst, or far off)
    if (!this.playing || have < len * (1 + DRIFT_MAX) + 3) {
      if (this.playing) this.under++;
      this.playing = false; L.fill(0); if (R !== L) R.fill(0); return true;
    }
    this.avg += (have - this.avg) * Math.min(1, len / (sampleRate * DRIFT_TAU));
    this.rate = 1 + Math.max(-DRIFT_MAX, Math.min(DRIFT_MAX, (this.avg - target) / sampleRate * DRIFT_K));
    if (++this.blocks % 16 === 0) { const t = this.tAt(this.rd); if (t != null) this.port.postMessage({ map: [currentFrame, t] }); }
    const g = this.gain, l = this.l, r = this.r;
    let p = this.rd;
    for (let i = 0; i < len; i++, p += this.rate) {
      const k = Math.floor(p), t = p - k, k0 = (k - 1) % N, k1 = k % N, k2 = (k + 1) % N, k3 = (k + 2) % N;
      L[i] = hermite(l[k0], l[k1], l[k2], l[k3], t) * g;
      if (R !== L) R[i] = hermite(r[k0], r[k1], r[k2], r[k3], t) * g;
    }
    this.rd = p;
    return true;
  }
}
registerProcessor('ss-guest', SsGuest);
