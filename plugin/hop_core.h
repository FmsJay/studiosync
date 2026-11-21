// StudioSync Hop's timing, apart from DPF so tests/hop_test.cpp can check it without a host (docs/realtime-roadmap.md 4b).
// The rule (James, rt: "always has to do playback so everything is synced up, means playing everything later enough"): the plug-in
// reports a FIXED latency L to the host, REAPER's delay compensation plays everything else L later, and at frame i the plug-in outputs
// what came back for frame i - L. If that isn't back yet, it outputs its own input from frame i - L (or silence), so a late network
// costs the sound of that block, never the timing. GPL-3.0-or-later.
// MIDI (rt-hopvst, an instrument you don't have): what the host gives the plug-in goes into the mapping's send_midi under its frame
// number; what the extension puts in ret_midi comes out of the plug-in with the ret[] frame of the same number, so L later, like the audio.
// Held MIDI (rt-hop2: "a note-off lost twice hangs a note until the try stops"): the sending Hop adds a snapshot of what's held to its
// MIDI, every SNAP_S and in each block where a note or pedal changed: per channel, the held notes of each 5-note group that has a note held
// or let go within RECENT_S, and each held controller (pitch bend, mod wheel CC1, sustain CC64, sostenuto CC66, soft CC67, hold 2 CC69,
// channel pressure) that is off its rest value or changed within RECENT_S. They travel as ordinary short messages with the undefined
// statuses 0xF4 (notes) and 0xF5 (controllers), every data byte 7-bit, so the network leg (extension/hopnet.cpp) carries them with its usual
// repeats and needs no change. The Hop that plays network MIDI (the remote's Hop X) keeps track of what it has sent on: a snapshot lets go
// of every note it has sounding that the snapshot says isn't held and puts each controller back to the snapshot's value; and once it has
// had a snapshot (a 0.2.1 sender: an older one's MIDI plays as before), if HOLD_S passes with no new one while anything is sounding or off
// its rest value, it lets go of all of it. A note-on or controller set arriving more than HOLD_S late is dropped (it would sound after the
// snapshots that could undo it). So under any loss, a note X sounds stops at most HOLD_S + a block after the later of its note-off and its
// start, and the controllers come back as fast. X never plays the snapshots themselves.
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

  // Held MIDI (see the top). Kinds of held controller: 0 pitch bend (its MSB), 1 CC1, 2 CC64, 3 CC66, 4 CC67, 5 CC69, 6 channel pressure.
  enum { SNAP_NOTES = 0xF4, SNAP_CTL = 0xF5, KINDS = 7, GROUPS = 26 };
  static constexpr double SNAP_S = 0.05, HOLD_S = 0.2, RECENT_S = 0.4; // (RECENT_S must pass HOLD_S + a block: docs/rt/rt-hop2.md)
  uint8_t held[16][128], ctl_in[16][KINDS];       // sending: what the host's MIDI holds now
  uint64_t grp_at[16][GROUPS], ctl_at[16][KINDS]; // sending: local frame + 1 of a group's last note-off, a controller's last change (0: never)
  uint64_t snap_next = 0;                         // sending: the next periodic snapshot's local frame
  uint8_t on[16][128], ctl_out[16][KINDS];        // playing: what our MIDI out has left sounding, and set
  bool armed = false, dirty = false;              // playing: a snapshot was seen; something may be sounding or off its rest value
  uint64_t snap_due = 0;                          // playing: the latest snapshot's local frame

  HopCore() { midi_clear(); }
  // Activate: a fresh timeline (not on the audio thread: it clears 1 MB).
  void reset()
  {
    std::fill(dry.begin(), dry.end(), 0.f);
    t = 0;
    midi_clear();
    attach(shm);
  }
  static uint8_t rest(int kind) { return kind == 0 ? 64 : 0; } // (bend centred, the others at 0)
  // The held controller a channel message sets, and to what: its kind, or -1.
  static int kind_of(uint8_t st, uint8_t d1, uint8_t d2, uint8_t &v)
  {
    static const uint8_t cc[5] = { 1, 64, 66, 67, 69 };
    switch (st & 0xF0) {
    case 0xE0: v = d2 & 127; return 0;
    case 0xD0: v = d1 & 127; return 6;
    case 0xB0: v = d2 & 127; for (int k = 0; k < 5; k++) if (d1 == cc[k]) return k + 1; break;
    }
    return -1;
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
  void midi_clear()
  {
    memset(held, 0, sizeof(held)); memset(on, 0, sizeof(on)); memset(grp_at, 0, sizeof(grp_at)); memset(ctl_at, 0, sizeof(ctl_at));
    for (int c = 0; c < 16; c++) for (int k = 0; k < KINDS; k++) ctl_in[c][k] = ctl_out[c][k] = rest(k);
    snap_next = snap_due = 0;
    armed = dirty = false;
  }
  uint64_t frames_of(double sec) const // (the mapping's rate may have been scribbled on: 48 kHz unless it's sane)
  {
    const double sr = shm && shm->srate >= 8000 && shm->srate <= 768000 ? shm->srate : 48000;
    return (uint64_t)(sec * sr);
  }
  static void put(hop_shm *s, uint64_t &k, uint64_t frame, uint32_t msg)
  {
    hop_midi &m = s->send_midi[k & (HOP_MIDI - 1)];
    m.frame = frame; m.msg = msg; m.len = 3;
    k++;
  }
  // Sending: what the host's MIDI holds after this event at local frame lf. -> true when a note or pedal changed (a snapshot goes now).
  bool track_in(uint8_t st, uint8_t d1, uint8_t d2, uint64_t lf)
  {
    const int ch = st & 15, hi = st & 0xF0;
    uint8_t v;
    if (hi == 0x90 && d2) { held[ch][d1 & 127] = 1; return true; }
    if (hi == 0x80 || hi == 0x90) { held[ch][d1 & 127] = 0; grp_at[ch][(d1 & 127) / 5] = lf + 1; return true; }
    if (hi == 0xB0 && (d1 == 120 || d1 == 123)) { // (all sound / notes off)
      for (int n = 0; n < 128; n++) if (held[ch][n]) { held[ch][n] = 0; grp_at[ch][n / 5] = lf + 1; }
      return true;
    }
    if (hi == 0xB0 && d1 == 121) { // (reset all controllers)
      for (int k = 0; k < KINDS; k++) if (ctl_in[ch][k] != rest(k)) { ctl_in[ch][k] = rest(k); ctl_at[ch][k] = lf + 1; }
      return true;
    }
    const int k = kind_of(st, d1, d2, v);
    if (k < 0 || ctl_in[ch][k] == v) return false;
    ctl_in[ch][k] = v; ctl_at[ch][k] = lf + 1;
    return k >= 2 && k <= 5; // (a pedal: as soon as possible; bend, the wheel and pressure stream, and go with the next periodic one)
  }
  // Sending: the snapshot at local frame lf (see the top).
  void snapshot(hop_shm *s, uint64_t &k, uint64_t lf)
  {
    const uint64_t W = frames_of(RECENT_S), f = lf + off;
    for (int c = 0; c < 16; c++) {
      for (int g = 0; g < GROUPS; g++) {
        uint32_t bits = 0;
        for (int n = 0; n < 5 && g * 5 + n < 128; n++) bits |= (uint32_t)held[c][g * 5 + n] << n;
        if (bits || (grp_at[c][g] && lf + 1 - grp_at[c][g] <= W))
          put(s, k, f, SNAP_NOTES | (uint32_t)(c | (g & 7) << 4) << 8 | (uint32_t)((g >> 3) << 5 | bits) << 16);
      }
      for (int kd = 0; kd < KINDS; kd++)
        if (ctl_in[c][kd] != rest(kd) || (ctl_at[c][kd] && lf + 1 - ctl_at[c][kd] <= W))
          put(s, k, f, SNAP_CTL | (uint32_t)(c | kd << 4) << 8 | (uint32_t)ctl_in[c][kd] << 16);
    }
  }
  // Before any of the block's send_w: an event is there by the time its frame is published.
  void midi_in(hop_shm *s, const HopMidiEv *min, uint32_t nmin, uint32_t frames)
  {
    uint64_t k = hop_load(&s->send_mw);
    const uint64_t k0 = k;
    bool changed = false;
    for (uint32_t e = 0; e < nmin; e++) {
      if (min[e].size < 1 || min[e].size > 3 || min[e].frame >= frames) continue; // (short messages only: no SysEx over a hop)
      const uint8_t st = min[e].data[0], d1 = min[e].size > 1 ? min[e].data[1] : 0, d2 = min[e].size > 2 ? min[e].data[2] : 0;
      if (st == SNAP_NOTES || st == SNAP_CTL) continue; // (undefined in MIDI, and ours on the way)
      hop_midi &m = s->send_midi[k & (HOP_MIDI - 1)];
      m.frame = t + off + min[e].frame;
      m.msg = (uint32_t)st | (uint32_t)d1 << 8 | (uint32_t)d2 << 16;
      m.len = min[e].size;
      k++;
      if (st >= 0x80 && st < 0xF0 && track_in(st, d1, d2, t + min[e].frame)) changed = true;
    }
    if (frames && (changed || t + frames >= snap_next)) { // (after the block's own events, at its last frame: in order)
      snapshot(s, k, t + frames - 1);
      snap_next = t + frames + frames_of(SNAP_S);
    }
    if (k != k0) hop_store(&s->send_mw, k);
  }
  // Playing: one event to the host at offset `at`, while there's room.
  void emit(uint32_t at, uint8_t b0, uint8_t b1, uint8_t b2, uint32_t len)
  {
    if (nmout >= MIDI_OUT) return;
    HopMidiEv &o = mout[nmout++];
    o.frame = at; o.size = len;
    o.data[0] = b0; o.data[1] = b1; o.data[2] = b2; o.data[3] = 0;
  }
  void emit_ctl(uint32_t at, int c, int kd, uint8_t v)
  {
    static const uint8_t cc[5] = { 1, 64, 66, 67, 69 };
    if (kd == 0) emit(at, (uint8_t)(0xE0 | c), 0, v, 3);
    else if (kd == 6) emit(at, (uint8_t)(0xD0 | c), v, 0, 2);
    else emit(at, (uint8_t)(0xB0 | c), cc[kd - 1], v, 3);
    ctl_out[c][kd] = v;
    if (v != rest(kd)) dirty = true;
  }
  // Playing: what our MIDI out leaves sounding and set, after an event it plays.
  void track_out(uint8_t st, uint8_t d1, uint8_t d2)
  {
    const int ch = st & 15, hi = st & 0xF0;
    uint8_t v;
    if (hi == 0x90 && d2) { on[ch][d1 & 127] = 1; dirty = true; }
    else if (hi == 0x80 || hi == 0x90) on[ch][d1 & 127] = 0;
    else if (hi == 0xB0 && (d1 == 120 || d1 == 123)) memset(on[ch], 0, sizeof(on[ch]));
    else if (hi == 0xB0 && d1 == 121) for (int k = 0; k < KINDS; k++) ctl_out[ch][k] = rest(k);
    else {
      const int k = kind_of(st, d1, d2, v);
      if (k >= 0) { ctl_out[ch][k] = v; if (v != rest(k)) dirty = true; }
    }
  }
  // Playing: a snapshot's message. Notes it says aren't held are let go; a controller goes to its value.
  void apply(uint8_t st, uint8_t d1, uint8_t d2, uint32_t at)
  {
    const int c = d1 & 15;
    if (st == SNAP_CTL) {
      const int kd = (d1 >> 4) & 7;
      if (kd < KINDS && ctl_out[c][kd] != (d2 & 127)) emit_ctl(at, c, kd, d2 & 127);
      return;
    }
    const int g = ((d1 >> 4) & 7) | ((d2 >> 5) & 3) << 3;
    for (int n = 0; n < 5 && g * 5 + n < 128; n++)
      if (on[c][g * 5 + n] && !(d2 >> n & 1)) { emit(at, (uint8_t)(0x80 | c), (uint8_t)(g * 5 + n), 0, 3); on[c][g * 5 + n] = 0; }
  }
  // Playing: no snapshot for HOLD_S: everything sounding let go, every controller back at rest (what doesn't fit goes next block).
  void let_go(uint32_t at)
  {
    bool left = false;
    for (int c = 0; c < 16; c++) {
      for (int n = 0; n < 128; n++)
        if (on[c][n]) { if (nmout < MIDI_OUT) { emit(at, (uint8_t)(0x80 | c), (uint8_t)n, 0, 3); on[c][n] = 0; } else left = true; }
      for (int kd = 0; kd < KINDS; kd++)
        if (ctl_out[c][kd] != rest(kd)) { if (nmout < MIDI_OUT) emit_ctl(at, c, kd, rest(kd)); else left = true; }
    }
    dirty = left;
  }
  // ret_midi's events due in this block: event at mapping frame f plays at local frame f - off + L; one already due plays at the block's start.
  void midi_out(hop_shm *s, uint32_t frames)
  {
    const uint64_t mw = hop_load(&s->ret_mw), hold = frames_of(HOLD_S);
    if (mw < mr) mr = mw; // (scribbled on)
    else if (mw - mr > HOP_MIDI) mr = mw - HOP_MIDI; // (fell a whole ring behind: the oldest are gone)
    uint32_t last = 0;
    for (; mr < mw && nmout + 6 <= MIDI_OUT; mr++) { // (6: the most one event can play, a snapshot letting go of 5 notes)
      const hop_midi m = s->ret_midi[mr & (HOP_MIDI - 1)];
      if (m.frame < off + start) continue; // (before our time in this mapping)
      const uint64_t due = m.frame - off + latency;
      if (due >= t + frames) break; // (later: in order, so the rest are too)
      uint32_t at = due > t ? (uint32_t)(due - t) : 0;
      if (at < last) at = last; // (a host wants them in order)
      last = at;
      const uint32_t len = m.len >= 1 && m.len <= 3 ? m.len : 3; // (anything in the mapping may have been scribbled on)
      const uint8_t st = (uint8_t)m.msg, d1 = len > 1 ? (uint8_t)(m.msg >> 8) : 0, d2 = len > 2 ? (uint8_t)(m.msg >> 16) : 0;
      if (st == SNAP_NOTES || st == SNAP_CTL) {
        if (len == 3) { armed = true; snap_due = std::max(snap_due, due); apply(st, d1, d2, at); }
        continue;
      }
      uint8_t v;
      const int kd = st >= 0x80 && st < 0xF0 ? kind_of(st, d1, d2, v) : -1;
      const bool sets = ((st & 0xF0) == 0x90 && d2) || (kd >= 0 && v != rest(kd));
      if (sets && due + hold < t) continue; // (too late: the snapshots that could undo it have gone by)
      emit(at, st, d1, d2, len);
      if (st >= 0x80 && st < 0xF0) track_out(st, d1, d2);
    }
    if (armed && dirty && t + frames > snap_due + hold) let_go(frames - 1);
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
