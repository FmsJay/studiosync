// StudioSync's guest page (guest.js, lib/guestweb.lua): one processor for both directions, so the input and the output share one frame
// count (the context's): what the guest heard at output frame f and what they played at input frame f + their round trip line up.
//  in:  the interface's input, every 512 frames to the page: { f (its first frame), live (Int16 mono of the picked inputs), take (Float32,
//       the picked inputs, interleaved when stereo) }.
//  out: the session mix from the page ({ mix: Int16Array stereo, t: the link clock of its first frame }), through a jitter buffer (heard
//       once TARGET has come, trimmed back to it past TARGET + OVER), at `gain`; every 16 blocks while it plays, { map: [frame, t] }: which
//       link-clock moment the output frame carried. { click: n }: n short clicks, 0.5 s apart, instead of the mix (the loopback test), each
//       said as { clickAt: frame }. GPL-3.0-or-later.
'use strict';
const TARGET = 0.08, OVER = 0.2;
class SsGuest extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = (options && options.processorOptions) || {};
    this.pick = o.pick == null ? 0 : o.pick;
    this.q = []; this.qn = 0; this.head = 0; // (chunks waiting: { pcm, t }, frames waiting, frames of q[0] already played)
    this.playing = false; this.gain = 1; this.blocks = 0;
    this.n = 0; this.live = new Int16Array(512); this.take = new Float32Array(1024); this.f0 = 0;
    this.clicks = []; // (output frames to click at)
    this.port.onmessage = (e) => {
      const d = e.data;
      if (d.mix) { this.q.push({ pcm: d.mix, t: d.t }); this.qn += d.mix.length / 2; }
      if (d.gain != null) this.gain = d.gain;
      if (d.pick != null) this.pick = d.pick;
      if (d.click) {
        const at = currentFrame + Math.round(sampleRate * 0.3);
        for (let i = 0; i < d.click; i++) this.clicks.push(at + Math.round(i * sampleRate * 0.5));
      }
    };
  }
  drop(n) { // (the oldest n frames waiting, gone)
    while (n > 0 && this.q.length) {
      const left = this.q[0].pcm.length / 2 - this.head;
      if (left <= n) { n -= left; this.qn -= left; this.q.shift(); this.head = 0; } else { this.head += n; this.qn -= n; n = 0; }
    }
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
      this.drop(len);
      return true;
    }
    if (!this.playing && this.qn >= TARGET * sampleRate + len) this.playing = true;
    if (this.qn > (TARGET + OVER) * sampleRate) this.drop(this.qn - Math.round(TARGET * sampleRate)); // (the two clocks' drift, a burst)
    if (!this.playing || this.qn < len) { this.playing = false; L.fill(0); if (R !== L) R.fill(0); return true; }
    if (++this.blocks % 16 === 0) { const c = this.q[0]; this.port.postMessage({ map: [currentFrame, c.t + this.head / sampleRate] }); }
    for (let i = 0; i < len; i++) {
      const c = this.q[0];
      L[i] = c.pcm[2 * this.head] / 32768 * this.gain;
      if (R !== L) R[i] = c.pcm[2 * this.head + 1] / 32768 * this.gain;
      if (++this.head * 2 >= c.pcm.length) { this.q.shift(); this.head = 0; }
    }
    this.qn -= len;
    return true;
  }
}
registerProcessor('ss-guest', SsGuest);
