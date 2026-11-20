// StudioSync's Record page: the microphone's samples as they come, on the audio thread (record.js). The first block's context time goes
// first, so the page can tell when its first sample was heard; then 4096 samples a message. 'stop' sends what's left and ends. GPL-3.0-or-later.
class SsRec extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buf = new Float32Array(4096);
    this.n = 0;
    this.first = true;
    this.on = true;
    this.port.onmessage = (e) => { if (e.data === 'stop') this.on = false; };
  }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!this.on) {
      this.port.postMessage({ samples: this.buf.slice(0, this.n), done: true });
      return false;
    }
    if (!ch) return true; // (the stream not started yet)
    if (this.first) { this.first = false; this.port.postMessage({ first: currentTime }); }
    for (let i = 0; i < ch.length; i++) {
      this.buf[this.n++] = ch[i];
      if (this.n === this.buf.length) { this.port.postMessage({ samples: this.buf }); this.buf = new Float32Array(4096); this.n = 0; }
    }
    return true;
  }
}
registerProcessor('ss-rec', SsRec);
