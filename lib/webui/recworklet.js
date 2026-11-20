// StudioSync's Record page: the microphone's samples as they come, on the audio thread (record.js). The first block's context time goes
// first, so the page can tell when its first sample was heard; then 4096 samples a message. 'stop' sends what's left and ends. The input
// picked (processorOptions.pick): 0 or 1 (that input, mono), 'stereo' (1 and 2, interleaved) or 'sum' (1 and 2 mixed to mono). GPL-3.0-or-later.
class SsRec extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.pick = (options && options.processorOptions && options.processorOptions.pick) || 0;
    this.buf = new Float32Array(4096);
    this.n = 0;
    this.first = true;
    this.on = true;
    this.port.onmessage = (e) => { if (e.data === 'stop') this.on = false; };
  }
  push(v) {
    this.buf[this.n++] = v;
    if (this.n === this.buf.length) { this.port.postMessage({ samples: this.buf }); this.buf = new Float32Array(4096); this.n = 0; }
  }
  process(inputs) {
    const ins = inputs[0] || [];
    const a = ins[0], b = ins[1] || ins[0]; // (a mono input as input 2: its one channel)
    if (!this.on) {
      this.port.postMessage({ samples: this.buf.slice(0, this.n), done: true });
      return false;
    }
    if (!a) return true; // (the stream not started yet)
    if (this.first) { this.first = false; this.port.postMessage({ first: currentTime }); }
    for (let i = 0; i < a.length; i++) {
      if (this.pick === 'stereo') { this.push(a[i]); this.push(b[i]); } // (4096 is even: a frame never splits across messages)
      else this.push(this.pick === 'sum' ? (a[i] + b[i]) * 0.5 : this.pick === 1 ? b[i] : a[i]);
    }
    return true;
  }
}
registerProcessor('ss-rec', SsRec);
