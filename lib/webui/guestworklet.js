// StudioSync's guest page (guest.js, lib/guestweb.lua): one processor for both directions, so the input and the output share one frame
// count (the context's): what the guest heard at output frame f and what they played at input frame f + their round trip line up.
//  in:  the interface's input, every 512 frames to the page: { f (its first frame), live (Int16 mono of the picked inputs), take (Float32,
//       the picked inputs, interleaved when stereo) }.
//  out: the session mix from the page ({ mix: Int16Array stereo, t: the link clock of its first frame }), through a jitter buffer (heard
//       once its size has come, cut back to it past size + OVER) read at a rate that follows REAPER's clock (ssPace below), at `gain`; every
//       16 blocks while it plays, { map: [frame, t] }: which link-clock moment the output frame carried. { click: n }: n short clicks, 0.5 s
//       apart, instead of the mix (the loopback test), each said as { clickAt: frame }. { stats: 1 } -> { stats: {...} } (tests).
// The buffer's size (rt-audio3, from rt-t1's 15-minute run: a guest 78 ms of round trip away dropped out 15 times a minute): it starts at
// TARGET and grows GROW on every underrun, up to TARGET_MAX (0.8 s; it was 0.4, and a link with holds past that ran it dry once a minute,
// rt-r5: past 0.15 s nobody plays along, hearing the session whole counts), and at once to the hold that ran it dry when that was longer
// (20 ms an underrun took 30 dropouts to get from 0.08 s to a 0.7 s hold; it grows when the sound comes again, and not after a wait of
// HOLD_MAX or more: that was a pause, not the link); after `need` s without one it comes back SHRINK at a time, and when a shrink
// is followed by an underrun inside `need`, `need` doubles (up to NEED_MAX), so it doesn't probe the same edge every minute. It was a fixed
// 80 ms. And it starts playing AT its size: what piled up behind a network pause is skipped while it's silent anyway, not played off.
// Drift: REAPER's audio clock and the browser's run apart (a few hundred ppm between devices), so the buffer is read at 1 + R + P: ssPace,
// the same control as extension/rtaudio.cpp's (its comment at RATE_*). It was 1 + (fill - TARGET) x 0.05 within 0.5 %, level only: every
// restart behind a burst left the buffer over its size, and reading that off took the full 0.5 % for most of a minute, at both ends of a
// guest's path (the host's ring for the guest, extension/webui.cpp, and the hearing guest's worklet): a guest was heard up to 0.85 % sharp
// (15 cents) and still 0.2-0.5 % after 15 minutes. Through a 4-point Hermite interpolator. GPL-3.0-or-later.
'use strict';
const TARGET = 0.08, TARGET_MAX = 0.8, HOLD_MAX = 1, GROW = 0.02, SHRINK = 0.01, NEED = 60, NEED_MAX = 960, OVER = 0.2, FRESH_OVER = 0.06, N = 1 << 17; // (s...; frames held at most: 2.7 s at 48 kHz)
// The read rate from the buffer: 1 + R + P (rt-audio3). fill, target: s; dt: s since the last call; st: its state, kept. Once a PACE_WIN:
//  - P = PACE_KP x (the window's mean fill - target), within PACE_P (0.1 %, under 2 cents; it was 0.3 %, and a tone moved by that at every packet that came late, rt-r5): it brings the level back and holds it;
//  - R, the learned ratio of the sender's clock to this one's (within PACE_R), integrates the error, but only while P isn't getting its
//    way: when the level, against PACE_BACK windows ago, came back less than half of what P alone did since. A level left off by a burst
//    comes back at P's pace and teaches R nothing; a real clock difference holds it off against P.
// age (rt-audio3 round 2, from rt-r5: over a link that held pieces 150-750 ms the buffer's mean swung with every hold, P ran at its
// bound either way and R wandered: a guest's tone moved +-0.5 %): the level is a time, what waits plus how long ago the newest piece
// came, so it holds still while the link holds pieces and lets them go together (the buffer then sits at its size right after a piece
// and under it while the link holds: it runs dry when a hold outlasts the size, which is what a size is for). And a window whose level
// jumped more than PACE_JUMP from the one before isn't a rate: R learns nothing from it or the two after.
// The same text in lib/webui/sharemix.js and lib/webui/listen.js (a worklet can't share a file with a page in every browser).
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
    this.playing = false; this.gain = 1; this.blocks = 0; this.rate = 1; this.drops = 0; this.under = 0;
    this.arr = 0; this.dry = false; // (the frame the newest piece of the mix came at: the level's age; it ran dry and hasn't been sized to the hold yet)
    this.size = TARGET; this.need = NEED; this.calm = 0; this.shrunk = 1e9; this.fresh = 0; this.pace = {}; // (the buffer's size now, s; s without an underrun; s since it last shrank; s since it started playing)
    this.n = 0; this.live = new Int16Array(512); this.take = new Float32Array(1024); this.f0 = 0;
    this.clicks = []; // (output frames to click at)
    this.port.onmessage = (e) => {
      const d = e.data;
      if (d.mix) {
        const p = d.mix;
        this.marks.push([this.w, d.t]);
        if (this.dry) { // (it ran dry, and the sound is back: a bigger buffer, the hold that did it and a step when that was longer)
          const held = (currentFrame - this.arr) / sampleRate;
          if (held < HOLD_MAX) this.size = Math.min(TARGET_MAX, Math.max(this.size, held) + GROW);
          this.dry = false;
        }
        this.arr = currentFrame;
        if (this.marks.length > 64) this.marks.shift();
        for (let i = 0; i + 1 < p.length; i += 2, this.w++) { const at = this.w % N; this.l[at] = p[i] / 32768; this.r[at] = p[i + 1] / 32768; }
        if (this.w - this.rd > N - 4) this.rd = this.w - Math.round(this.size * sampleRate);
      }
      if (d.gain != null) this.gain = d.gain;
      if (d.pick != null) this.pick = d.pick;
      if (d.click) {
        const at = currentFrame + Math.round(sampleRate * 0.3);
        for (let i = 0; i < d.click; i++) this.clicks.push(at + Math.round(i * sampleRate * 0.5));
      }
      if (d.stats) this.port.postMessage({ stats: { rate: this.rate, fill: this.w - this.rd, avg: (this.pace.mean || 0) * sampleRate, drops: this.drops, under: this.under,
        target: this.size, ratio: this.pace.r || 0 } });
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
    const dt = len / sampleRate, target = this.size * sampleRate;
    let have = this.w - this.rd;
    if (!this.playing && have >= target + len) { // (it starts at its size: what a burst piled on top is skipped here, in the silence, not played off sharp)
      this.playing = true; this.fresh = 0;
      this.rd = this.w - target - len; have = target + len;
      ssPaceAgain(this.pace);
    }
    // (and for its first second: the rest of that burst may come a few messages later)
    if (this.fresh < 1 && have > target + FRESH_OVER * sampleRate) { this.rd = this.w - target; have = target; ssPaceAgain(this.pace); }
    this.fresh += dt;
    if (have > (this.size + OVER) * sampleRate) { this.rd = this.w - target; have = target; this.drops++; ssPaceAgain(this.pace); } // (a burst, or far off)
    if (!this.playing || have < len * (1 + PACE_R + PACE_P) + 3) {
      if (this.playing) { // (ran dry: a bigger buffer from here; one that follows a shrink means that size was the edge)
        this.under++;
        if (this.shrunk < this.need) this.need = Math.min(NEED_MAX, this.need * 2);
        this.calm = 0; this.dry = true;
      }
      this.playing = false; L.fill(0); if (R !== L) R.fill(0); return true;
    }
    this.calm += dt; this.shrunk += dt;
    if (this.calm > this.need && this.size > TARGET) { this.size = Math.max(TARGET, this.size - SHRINK); this.calm = 0; this.shrunk = 0; } // (P reads the 10 ms off, at 0.1 % at most)
    this.rate = ssPace(this.pace, have / sampleRate, this.size, dt, (currentFrame - this.arr) / sampleRate);
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
