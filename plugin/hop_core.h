// StudioSync Hop's timing, apart from DPF so tests/hop_test.cpp can check it without a host (docs/realtime-roadmap.md 4b).
// The rule (James, rt: "always has to do playback so everything is synced up, means playing everything later enough"): the plug-in
// reports a FIXED latency L to the host, REAPER's delay compensation plays everything else L later, and at frame i the plug-in outputs
// what came back for frame i - L. If that isn't back yet, it outputs its own input from frame i - L (or silence), so a late network
// costs the sound of that block, never the timing. GPL-3.0-or-later.
#pragma once
#include <algorithm>
#include <vector>
#include "hop_shm.h"

struct HopCore {
  hop_shm *shm = nullptr;     // the hop's mapping, or null (then every block falls back)
  uint32_t latency = 7200;    // L, in frames: what the host is told
  float dry_when_late = 1.f;  // the input's level in a late block: 1 = dry, 0 = silence
  bool bypass = false;        // dry at the same latency, so the rest of the mix doesn't move when it's switched
  uint64_t late_blocks = 0;

  // Local frame numbers count this instance's frames since reset(); the mapping's frame number is local + off, fixed at attach().
  uint64_t t = 0, off = 0, start = 0; // start: the first local frame sent into the current mapping (older returns aren't ours)
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
  }

  void process(const float *const *in, float *const *out, uint32_t frames)
  {
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
      hop_store(&s->latency, latency);
      hop_store(&s->late, late_blocks);
      hop_store(&s->blocks, hop_load(&s->blocks) + 1);
    }
  }
};
