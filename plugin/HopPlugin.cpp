// StudioSync Hop (docs/realtime-roadmap.md 4b): put it where the plug-ins you don't have would go. It hands its input to the StudioSync
// extension through the hop's shared memory (plugin/hop_shm.h), plays what comes back, and tells REAPER a fixed latency so REAPER's delay
// compensation keeps everything else in time with the returned audio. The timing itself is in plugin/hop_core.h. GPL-3.0-or-later.
// MIDI in and out (rt-hopvst): the MIDI it gets goes along with the audio (an instrument on a bandmate's computer), and at the hidden track's
// first Hop the MIDI that came over the network comes out, for that instrument. It doesn't pass its own MIDI input on.
#include "DistrhoPlugin.hpp"
#include "hop_core.h"

START_NAMESPACE_DISTRHO

enum { P_HOP, P_LATENCY, P_DRY, P_BYPASS, P_LATE, P_COUNT };

class HopPlugin : public Plugin {
public:
  HopPlugin() : Plugin(P_COUNT, 0, 0)
  {
    pid = hop_reaper_pid();
    setLatency(core.latency);
  }
  ~HopPlugin() override { hop_shm_close(&map); }

protected:
  const char *getDescription() const override { return "Sends this point's audio to a bandmate's plug-ins through StudioSync and plays it back in time."; }
  const char *getMaker() const override { return "StudioSync"; }
  const char *getHomePage() const override { return "https://github.com/FmsJay/studiosync"; }
  const char *getLicense() const override { return "GPL-3.0-or-later"; }
  uint32_t getVersion() const override { return d_version(0, 2, 0); }

  void initParameter(uint32_t index, Parameter &p) override
  {
    switch (index) {
    case P_HOP: // (which remote chain: StudioSync gives each hop in the studio a number)
      p.hints = kParameterIsInteger;
      p.name = "Hop id"; p.symbol = "hop";
      p.ranges.min = 1; p.ranges.max = 64; p.ranges.def = 1;
      break;
    case P_LATENCY: // (the studio's hop budget: round trip + remote processing + a jitter margin; default about 150 ms at 48 kHz)
      p.hints = kParameterIsInteger;
      p.name = "Latency budget"; p.symbol = "latency"; p.unit = "samples"; // (not "Latency": DPF's VST3 adds its own read-only one)
      p.ranges.min = 256; p.ranges.max = HOP_LAT_MAX; p.ranges.def = 7200; // (up to 680 ms at 48 kHz: long links, rt-hopvst)
      break;
    case P_DRY:
      p.hints = kParameterIsAutomatable | kParameterIsBoolean; // (on: a late block plays the input at the same latency; off: silence)
      p.name = "Dry when late"; p.symbol = "dry_when_late";
      p.ranges.min = 0; p.ranges.max = 1; p.ranges.def = 1;
      break;
    case P_BYPASS:
      p.initDesignation(kParameterDesignationBypass); // (the host's bypass lands here, so the latency stays and nothing else moves)
      break;
    case P_LATE:
      p.hints = kParameterIsOutput | kParameterIsInteger;
      p.name = "Late blocks"; p.symbol = "late";
      p.ranges.min = 0; p.ranges.max = 1e7f; p.ranges.def = 0;
      break;
    }
  }

  float getParameterValue(uint32_t index) const override
  {
    switch (index) {
    case P_HOP: return (float)want_hop;
    case P_LATENCY: return (float)want_latency;
    case P_DRY: return core.dry_when_late;
    case P_BYPASS: return core.bypass ? 1.f : 0.f;
    case P_LATE: return (float)core.late_blocks;
    }
    return 0.f;
  }

  // (May come on the audio thread: only plain stores here; the mapping and the latency change in run() while stopped, or in activate().)
  void setParameterValue(uint32_t index, float v) override
  {
    switch (index) {
    case P_HOP: want_hop = v < 1.f ? 1 : v > 64.f ? 64 : (int)(v + 0.5f); break;
    case P_LATENCY: want_latency = v < 256.f ? 256u : v > (float)HOP_LAT_MAX ? HOP_LAT_MAX : (uint32_t)(v + 0.5f); break; // (the host may send anything)
    case P_DRY: core.dry_when_late = v > 0.5f ? 1.f : 0.f; break;
    case P_BYPASS: core.bypass = v > 0.5f; break;
    }
  }

  void activate() override
  {
    apply();
    core.reset();
  }

  void run(const float **inputs, float **outputs, uint32_t frames, const MidiEvent *midi, uint32_t nmidi) override
  {
    if ((want_hop != hop || want_latency != core.latency) && !getTimePosition().playing)
      apply(); // shortcut: opening a mapping is a system call on the audio thread; it only happens while stopped, after a change
    uint32_t n = 0;
    for (uint32_t i = 0; i < nmidi && n < MIDI_IN; i++) { // shortcut: past MIDI_IN events in one block the rest are dropped; raise it if a dense controller ever fills it
      if (midi[i].size < 1 || midi[i].size > 3) continue; // (short messages only)
      HopMidiEv &e = inbuf[n++];
      e.frame = midi[i].frame; e.size = midi[i].size;
      memcpy(e.data, midi[i].data, 4);
    }
    core.process(inputs, outputs, frames, inbuf, n);
    for (uint32_t i = 0; i < core.nmout; i++) {
      MidiEvent me;
      me.frame = core.mout[i].frame; me.size = core.mout[i].size; me.dataExt = nullptr;
      memcpy(me.data, core.mout[i].data, 4);
      if (!writeMidiEvent(me)) break;
    }
  }

private:
  void apply()
  {
    core.latency = want_latency;
    setLatency(core.latency);
    if (want_hop != hop || !map.p) {
      hop_shm_close(&map);
      hop = want_hop;
      hop_shm_open(&map, pid, hop); // shortcut: on Mac/Linux an open in the instant the other side is sizing it fails, and the hop plays dry until the next change while stopped
    }
    if (map.p) map.p->srate = getSampleRate();
    core.attach(map.p);
  }

  static const uint32_t MIDI_IN = 512;
  HopMidiEv inbuf[MIDI_IN];
  HopCore core;
  hop_map map = {};
  unsigned long pid = 0;
  int hop = 0, want_hop = 1;
  uint32_t want_latency = 7200;

  DISTRHO_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(HopPlugin)
};

Plugin *createPlugin() { return new HopPlugin(); }

END_NAMESPACE_DISTRHO
