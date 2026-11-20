// StudioSync Hop's timing, apart from DPF so tests/hop_test.cpp can check it without a host (docs/realtime-roadmap.md 4b).
// The rule (James, rt: "always has to do playback so everything is synced up, means playing everything later enough"): the plug-in
// reports a FIXED latency L to the host, REAPER's delay compensation plays everything else L later, and at frame i the plug-in outputs
// what came back for frame i - L. If that isn't back yet, it outputs its own input from frame i - L (or silence), so a late network
// costs the sound of that block, never the timing. GPL-3.0-or-later.
// MIDI (rt-hopvst, an instrument you don't have): what the host gives the plug-in goes into the mapping's send_midi under its frame
// number; what the extension puts in ret_midi comes out of the plug-in with the ret[] frame of the same number, so L later, like the audio.
#pragma once
#include <algorithm>
#include <vector>
#include "hop_shm.h"

struct HopMidiEv { uint32_t frame, size; uint8_t data[4]; }; // (a block's MIDI, frame = offset in the block, as DPF's MidiEvent)

struct HopCore {
  static const uint32_t MIDI_OUT = 512; // (events played in one block at most; more wait for the next)
  hop_shm *shm = nullptr;     // the hop's mapping, or null (then every block falls back)
  uint32_t latency = 7200;    // L, in frames: what the host is told
  float dry_when_late = 1.f;  // the input's level in a late block: 1 = dry, 0 = silence
  bool bypass = false;        // dry at the same latency, so the rest of the mix doesn't move when it's switched
  uint64_t late_blocks = 0;
  HopMidiEv mout[MIDI_OUT];   // process()'s MIDI out, offsets in its block, in order
  uint32_t nmout = 0;

  // Local frame numbers count this instance's frames since reset(); the mapping's frame number is local + off, fixed at attach().
  uint64_t t = 0, off = 0, start = 0; // start: the first local frame sent into the current mapping (older returns aren't ours)
  uint64_t mr = 0;                     // ret_midi events read so far
  std::vector<float> dry = std::vector<float>((size_t)HOP_FRAMES * HOP_CH); // our own input, for late blocks and bypass

  // Activate: a fresh timeline (not on the audio thread: it clears 1 MB).
  void reset()
  {
    std::fill(dry.begin(), dry.end(), 0.f);
    t = 0;
    attach(shm);
  }
  // Use this mapping from the next frame on: our frames go after whatever it already holds.
  void attach(hop_shm *s)
  {
    shm = s; // (kept even if its header isn't ready yet: the other side may be making it right now; chunk() checks every block)
    start = t;
    off = shm ? hop_load(&shm->send_w) - t : 0;
    mr = shm ? hop_load(&shm->ret_mw) : 0;
  }

  // min: the block's MIDI in (offsets in the block, in order); its MIDI out is in mout[0..nmout) after.
  void process(const float *const *in, float *const *out, uint32_t frames, const HopMidiEv *min = nullptr, uint32_t nmin = 0)
  {
    nmout = 0;
    if (hop_shm *s = shm && hop_shm_ok(shm) ? shm : nullptr) {
      midi_in(s, min, nmin, frames);
      midi_out(s, frames);
    }
    const uint32_t CHUNK = 4096; // (keeps a block well inside the rings, whatever size the host passes)
    for (uint32_t done = 0; done < frames;) {
      uint32_t n = frames - done < CHUNK ? frames - done : CHUNK;
      const float *i2[HOP_CH] = { in[0] + done, in[1] + done };
      float *o2[HOP_CH] = { out[0] + done, out[1] + done };
      chunk(i2, o2, n);
      done += n;
    }
  }

private:
  // Before any of the block's send_w: an event is there by the time its frame is published.
  void midi_in(hop_shm *s, const HopMidiEv *min, uint32_t nmin, uint32_t frames)
  {
    uint64_t k = hop_load(&s->send_mw);
    const uint64_t k0 = k;
    for (uint32_t e = 0; e < nmin; e++) {
      if (min[e].size < 1 || min[e].size > 3 || min[e].frame >= frames) continue; // (short messages only: no SysEx over a hop)
      hop_midi &m = s->send_midi[k & (HOP_MIDI - 1)];
      m.frame = t + off + min[e].frame;
      m.msg = (uint32_t)min[e].data[0] | (uint32_t)min[e].data[1] << 8 | (uint32_t)min[e].data[2] << 16;
      m.len = min[e].size;
      k++;
    }
    if (k != k0) hop_store(&s->send_mw, k);
  }
  // ret_midi's events due in this block: event at mapping frame f plays at local frame f - off + L; one already due plays at the block's start.
  void midi_out(hop_shm *s, uint32_t frames)
  {
    const uint64_t mw = hop_load(&s->ret_mw);
    if (mw < mr) mr = mw; // (scribbled on)
    else if (mw - mr > HOP_MIDI) mr = mw - HOP_MIDI; // (fell a whole ring behind: the oldest are gone)
    uint32_t last = 0;
    for (; mr < mw && nmout < MIDI_OUT; mr++) {
      const hop_midi m = s->ret_midi[mr & (HOP_MIDI - 1)];
      if (m.frame < off + start) continue; // (before our time in this mapping)
      const uint64_t due = m.frame - off + latency;
      if (due >= t + frames) break; // (later: in order, so the rest are too)
      uint32_t at = due > t ? (uint32_t)(due - t) : 0;
      if (at < last) at = last; // (a host wants them in order)
      last = at;
      const uint32_t len = m.len >= 1 && m.len <= 3 ? m.len : 3; // (anything in the mapping may have been scribbled on)
      HopMidiEv &o = mout[nmout++];
      o.frame = at; o.size = len;
      o.data[0] = (uint8_t)m.msg; o.data[1] = (uint8_t)(m.msg >> 8); o.data[2] = (uint8_t)(m.msg >> 16); o.data[3] = 0;
    }
  }

  void chunk(const float *const *in, float *const *out, uint32_t n)
  {
    hop_shm *s = shm && hop_shm_ok(shm) ? shm : nullptr;
    // 1. The input, into our ring and the send ring, before any output is written (the host may pass the same buffers for both).
    for (uint32_t k = 0; k < n; k++) {
      size_t pos = (size_t)((t + k) & HOP_MASK) * HOP_CH;
      dry[pos] = in[0][k]; dry[pos + 1] = in[1][k];
      if (s) {
        size_t sp = (size_t)((t + off + k) & HOP_MASK) * HOP_CH;
        s->send[sp] = in[0][k]; s->send[sp + 1] = in[1][k];
      }
    }
    t += n;
    uint64_t rw = 0;
    if (s) {
      hop_store(&s->send_w, t + off);
      rw = hop_load(&s->ret_w); // (after this, ret[] below rw is complete: the extension stored ret_w after writing it)
    }
    // 2. The output: frame i plays frame i - L.
    bool late = false;
    for (uint32_t k = 0; k < n; k++) {
      uint64_t i = t - n + k;
      if (i < (uint64_t)latency) { out[0][k] = out[1][k] = 0.f; continue; } // (before anything was played in)
      uint64_t idx = i - latency;
      size_t pos = (size_t)(idx & HOP_MASK) * HOP_CH;
      float d0 = dry[pos], d1 = dry[pos + 1];
      uint64_t sidx = idx + off;
      if (bypass || idx < start) { out[0][k] = d0; out[1][k] = d1; continue; } // (older returns belong to another instance)
      if (s && sidx < rw && rw - sidx <= HOP_FRAMES) {
        size_t rp = (size_t)(sidx & HOP_MASK) * HOP_CH;
        out[0][k] = s->ret[rp]; out[1][k] = s->ret[rp + 1];
      } else {
        out[0][k] = d0 * dry_when_late; out[1][k] = d1 * dry_when_late;
        late = true;
      }
    }
    if (late) late_blocks++;
    if (s) {
      hop_store(&s->dry_lost, dry_when_late > 0.5f ? 1 : 0);
      hop_store(&s->latency, latency);
      hop_store(&s->late, late_blocks);
      hop_store(&s->blocks, hop_load(&s->blocks) + 1);
    }
  }
};
