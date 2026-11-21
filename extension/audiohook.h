// REAPER's audio hook (audio_hook_register_t, Audio_RegHardwareHook): which hardware buffers a call has.
// REAPER leaves the struct's input_nch / output_nch at 0 (found on the desktop, REAPER 7.86 WASAPI, 2026-11-20: every hook here read them, so
// live audio captured nothing and mixed nobody in, and the screen share's, browser guests' and listeners' feeds never ran; another
// extension measured the same on 7.83, and LICEcap's own hook never reads them: it asks GetBuffer and checks for null). So the channels a
// call has are the ones GetBuffer hands out: from 0 up to the first it doesn't have, `most` at most. A count REAPER did set (another
// version) still limits how many are asked for. Audio thread only, inside OnAudioBuffer. A template over the struct so
// tests/audience_test.cpp checks it without the SDK. GPL-3.0-or-later.
#pragma once
template <class Reg, class T> static inline int hook_buffers(Reg *reg, bool output, T **bufs, int most)
{
  const int set = output ? reg->output_nch : reg->input_nch;
  if (set > 0 && set < most) most = set;
  int n = 0;
  while (n < most && (bufs[n] = reg->GetBuffer(output, n)) != nullptr) ++n;
  return n;
}
// The output pair REAPER's master plays out of (rt-p11, backlog 1.24: a master routed off the first pair wasn't heard in a screen share's
// sound, by guests or listeners, and live audio's bandmates went where nobody listened): `first` its first channel (0-based, from the master's
// hardware output, lib/liveaudio.lua out_pair). That pair when the device has it (one channel: mono), else the first pair as before.
template <class Reg, class T> static inline int hook_pair(Reg *reg, int first, T **out)
{
  out[0] = out[1] = nullptr;
  if (first > 0 && (out[0] = reg->GetBuffer(true, first)) != nullptr) return (out[1] = reg->GetBuffer(true, first + 1)) != nullptr ? 2 : 1;
  return hook_buffers(reg, true, out, 2);
}
