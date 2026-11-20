// StudioSync's phone app (record.js): the files a take is kept and sent as, and the phone's own store for them. A WAV take carries its
// place in the song as a BWF time reference (the bext chunk, which REAPER reads: "move to source preferred position"); a MIDI take is a
// Standard MIDI File (format 0, 960 ticks a beat at 120 bpm, so a tick is 1/1920 s whatever the song's tempo: lib/phonerec.lua turns it back
// into seconds). Takes and mixes live in IndexedDB, so they survive the page closing and the phone being offline. GPL-3.0-or-later.
'use strict';
const phonefile = (() => {
  const ascii = (s, n) => { const b = new TextEncoder().encode(String(s || '')); return b.length > n ? b.slice(0, n) : b; };
  // chunks: Float32Arrays of interleaved samples; at: the song position of the first sample (seconds, null when the computer places it).
  function wav(chunks, frames, rate, channels, at, desc, who) {
    const h = new DataView(new ArrayBuffer(12 + 8 + 602 + 8 + 16 + 8));
    const bytes = new Uint8Array(h.buffer);
    const tag = (o, s) => { for (let i = 0; i < 4; i++) h.setUint8(o + i, s.charCodeAt(i)); };
    const data = frames * channels * 4;
    tag(0, 'RIFF'); h.setUint32(4, 4 + 610 + 24 + 8 + data, true); tag(8, 'WAVE');
    tag(12, 'bext'); h.setUint32(16, 602, true);
    bytes.set(ascii(desc, 256), 20);
    bytes.set(ascii('StudioSync phone', 32), 276);
    bytes.set(ascii(who, 32), 308);
    const d = new Date(), p2 = (n) => String(n).padStart(2, '0');
    bytes.set(ascii(d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()), 10), 340);
    bytes.set(ascii(p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds()), 8), 350);
    const ref = at > 0 ? Math.round(at * rate) : 0;
    h.setUint32(358, ref % 4294967296, true); h.setUint32(362, Math.floor(ref / 4294967296), true);
    h.setUint16(366, 1, true); // (BWF version 1; the UMID and the reserved bytes stay zero)
    const f = 12 + 8 + 602;
    tag(f, 'fmt '); h.setUint32(f + 4, 16, true); h.setUint16(f + 8, 3, true); h.setUint16(f + 10, channels, true); // (3: 32-bit float, lossless)
    h.setUint32(f + 12, rate, true); h.setUint32(f + 16, rate * channels * 4, true); h.setUint16(f + 20, channels * 4, true); h.setUint16(f + 22, 32, true);
    tag(f + 24, 'data'); h.setUint32(f + 28, data, true);
    return new Blob([h.buffer, ...chunks], { type: 'audio/wav' });
  }
  // events: [{ t: seconds from the take's start, data: [status, ...] }] (channel messages), len: the take's seconds.
  function smf(events, len) {
    const out = [];
    const vlq = (n) => { const b = [n & 127]; while ((n = Math.floor(n / 128)) > 0) b.unshift(128 | (n & 127)); return b; };
    out.push(0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20); // (tempo: 500000 us a beat, 120 bpm)
    let last = 0;
    for (const e of events.slice().sort((a, z) => a.t - z.t)) {
      const tick = Math.max(0, Math.round(e.t * 1920));
      out.push(...vlq(tick - last), ...e.data);
      last = tick;
    }
    out.push(...vlq(Math.max(0, Math.round(len * 1920) - last)), 0xff, 0x2f, 0);
    const head = [0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 960 >> 8, 960 & 255, 0x4d, 0x54, 0x72, 0x6b];
    const n = out.length, file = new Uint8Array(head.length + 4 + n);
    file.set(head);
    file.set([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255], head.length);
    file.set(out, head.length + 4);
    return new Blob([file], { type: 'audio/midi' });
  }
  // ---- the store: takes (by the phone's id for each) and mixes (by song) ----------------------------------------------------------------
  let opened = null;
  function db() {
    if (!opened) opened = new Promise((res, rej) => {
      const r = indexedDB.open('studiosync-phone', 1);
      r.onupgradeneeded = () => { r.result.createObjectStore('takes', { keyPath: 'cid' }); r.result.createObjectStore('mixes', { keyPath: 'song' }); };
      r.onsuccess = () => res(r.result);
      r.onerror = () => { opened = null; rej(r.error); };
    });
    return opened;
  }
  function run(store, mode, fn) {
    return db().then((d) => new Promise((res, rej) => {
      const tx = d.transaction(store, mode);
      const q = fn(tx.objectStore(store));
      tx.oncomplete = () => res(q && q.result);
      tx.onerror = tx.onabort = () => rej(tx.error || new Error('the phone’s storage refused it (full?)'));
    }));
  }
  const put = (store, v) => run(store, 'readwrite', (s) => s.put(v));
  const get = (store, k) => run(store, 'readonly', (s) => s.get(k));
  const all = (store) => run(store, 'readonly', (s) => s.getAll());
  const del = (store, k) => run(store, 'readwrite', (s) => s.delete(k));
  const id = () => Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, '0')).join('');
  return { wav, smf, put, get, all, del, id };
})();
if (typeof module !== 'undefined') module.exports = phonefile; // (tests)
