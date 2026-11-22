// A screen share's "REAPER mix" (call.js): the extension streams REAPER's own output as 16-bit stereo (GET /api/mix, extension/webui.cpp);
// call.js posts each piece here, and this plays it into a MediaStream track that goes out with the shared picture. A small jitter buffer:
// it starts once PRE is in (at PRE: what piled on top is skipped in the silence), refills after running dry, and drops back to PRE when it
// holds more than MAX (a burst). REAPER's audio clock and the browser's drift apart slowly, so it's read at 1 + R + P (ssPace: the control
// lib/webui/guestworklet.js explains, the same text; it was 1 + (fill - PRE) x 0.05 within 0.5 %, level only, which read a buffer left
// over its size off sharp for most of a minute: rt-audio3) through a 4-point Hermite interpolator, instead of skipping or refilling every
// few minutes (rt-p11, backlog 1.19). { stats: 1 } -> { stats: {...} } (tests). (rt-share) GPL-3.0-or-later.
/* global sampleRate, registerProcessor, AudioWorkletProcessor */
'use strict';
const N = 1 << 17; // frames held at most (2.7 s at 48 kHz)
const PACE_WIN = 0.5, PACE_KP = 0.2, PACE_P = 0.003, PACE_R = 0.01, PACE_I = 0.05, PACE_BACK = 4;
function ssPace(st, fill, target, dt) {
  st.sum = (st.sum || 0) + fill * dt; st.t = (st.t || 0) + dt;
  if (st.t < PACE_WIN) return st.rate || 1 + (st.r || 0);
  const e = st.sum / st.t - target, T = st.t, h = st.h || (st.h = []), was = Math.abs(st.p || 0) * T;
  st.sum = 0; st.t = 0; st.mean = e + target;
  let did = was;
  for (let i = 1; i < h.length; i++) did += h[i][1];
  if (h.length >= 2 && Math.abs(e) > Math.abs(h[0][0]) - 0.5 * did)
    st.r = Math.max(-PACE_R, Math.min(PACE_R, (st.r || 0) + PACE_KP * PACE_KP / 4 * Math.max(-PACE_I, Math.min(PACE_I, e)) * T));
  h.push([e, was]); if (h.length > PACE_BACK) h.shift();
  st.p = Math.max(-PACE_P, Math.min(PACE_P, PACE_KP * e));
  return (st.rate = 1 + (st.r || 0) + st.p);
}
function ssPaceAgain(st) { st.sum = 0; st.t = 0; st.h = []; st.p = 0; st.rate = 1 + (st.r || 0); } // (a restart or a cut: the level starts anew, R is kept)
function hermite(a, b, c, d, t) { // (4-point, 3rd-order: b at t 0, c at t 1)
  const c1 = 0.5 * (c - a), c2 = a - 2.5 * b + 2 * c - 0.5 * d, c3 = 0.5 * (d - a) + 1.5 * (b - c);
  return ((c3 * t + c2) * t + c1) * t + b;
}
class ShareMix extends AudioWorkletProcessor {
  constructor() {
    super();
    this.l = new Float32Array(N); this.r = new Float32Array(N);
    this.w = 1; this.rd = 1; this.run = false; this.rate = 1; this.drops = 0; this.under = 0; this.pace = {}; // (rd fractional, a frame of history behind it)
    this.PRE = Math.round(sampleRate * 0.06); this.MAX = Math.round(sampleRate * 0.25);
    this.port.onmessage = (e) => {
      const p = e.data;
      if (p && p.stats) { this.port.postMessage({ stats: { rate: this.rate, fill: this.w - this.rd, avg: (this.pace.mean || 0) * sampleRate, drops: this.drops, under: this.under, ratio: this.pace.r || 0 } }); return; }
      if (!(p instanceof Int16Array)) return;
      for (let i = 0; i + 1 < p.length; i += 2, this.w++) { const at = this.w % N; this.l[at] = p[i] / 32768; this.r[at] = p[i + 1] / 32768; }
      if (this.w - this.rd > N - 4) this.rd = this.w - this.PRE;
    };
  }
  process(inputs, outputs) {
    const out = outputs[0], L = out[0], R = out[1] || out[0], n = L.length;
    let have = this.w - this.rd;
    if (have > this.MAX) { this.rd = this.w - this.PRE; have = this.PRE; this.drops++; ssPaceAgain(this.pace); }
    if (!this.run && have >= this.PRE + n) { this.run = true; this.rd = this.w - this.PRE - n; have = this.PRE + n; ssPaceAgain(this.pace); }
    if (!this.run || have < n * (1 + PACE_R + PACE_P) + 3) {
      if (this.run) this.under++;
      this.run = false; L.fill(0); if (R !== L) R.fill(0); return true;
    }
    this.rate = ssPace(this.pace, have / sampleRate, this.PRE / sampleRate, n / sampleRate);
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
