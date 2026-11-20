// A screen share's "REAPER mix" (call.js): the extension streams REAPER's own output as 16-bit stereo (GET /api/mix, extension/webui.cpp);
// call.js posts each piece here, and this plays it into a MediaStream track that goes out with the shared picture. A small jitter buffer:
// it starts once PRE is in, refills after running dry, and drops back to PRE when it holds more than MAX (REAPER's audio clock and the
// browser's drift apart slowly; shortcut: a skip or a gap every few minutes rather than resampling, upgrade if anyone hears it). (rt-share)
// GPL-3.0-or-later.
/* global sampleRate, registerProcessor, AudioWorkletProcessor */
'use strict';
const N = 1 << 17; // frames held at most (2.7 s at 48 kHz)
class ShareMix extends AudioWorkletProcessor {
  constructor() {
    super();
    this.l = new Float32Array(N); this.r = new Float32Array(N);
    this.w = 0; this.rd = 0; this.run = false;
    this.PRE = Math.round(sampleRate * 0.06); this.MAX = Math.round(sampleRate * 0.25);
    this.port.onmessage = (e) => {
      const p = e.data;
      if (!(p instanceof Int16Array)) return;
      for (let i = 0; i + 1 < p.length; i += 2, this.w++) { const at = this.w % N; this.l[at] = p[i] / 32768; this.r[at] = p[i + 1] / 32768; }
      if (this.w - this.rd > N) this.rd = this.w - this.PRE;
    };
  }
  process(inputs, outputs) {
    const out = outputs[0], L = out[0], R = out[1] || out[0], n = L.length;
    let have = this.w - this.rd;
    if (have > this.MAX) { this.rd = this.w - this.PRE; have = this.PRE; }
    if (!this.run && have >= this.PRE) this.run = true;
    if (!this.run || have < n) { this.run = false; L.fill(0); if (R !== L) R.fill(0); return true; }
    for (let k = 0; k < n; k++, this.rd++) { const at = this.rd % N; L[k] = this.l[at]; R[k] = this.r[at]; }
    return true;
  }
}
registerProcessor('ss-share-mix', ShareMix);
