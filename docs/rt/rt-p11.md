# rt-p11: audio on the browser side, Play's resync and the ears tap (2026-11-21)

Backlog package P11 (`docs/rt/backlog.md`, "Plan to finish"): items 1.19, 1.21, 1.22, 1.24 and 3.6, plus two items from the sound test
(`docs/rt/rt-ears.md`, "Findings 1" and "Left"). Nothing here ran in REAPER or on the test computers (a re-checker had them): the checks
below are for the next REAPER run. Needs an extension build after 1.0.34 (Play's fix, the ears tap, the output pair, the guests' changes).

## What was built

### 1. Play's resync (rt-ears Findings 1) - `extension/rtaudio.cpp`
**What happened:** the laptop heard the desktop's Play ~100 ms later than its status `latency_ms` said, then mid-tone ~130 ms of silence,
low-level garbage and a ~100 ms fade-in, and no counter moved.

**Cause:** two things together.
- A re-buffer (a quiet trim or shrink, which re-buffered while that peer was quiet: the laptop's status showed 155 trims) can finish
  *above* its size on an internet link: AOO starts playing once it has its latency in hand, and packets that were late come in together
  right after, so the buffer holds its size plus that lateness for good. The laptop's buffer for the desktop's Play sat ~100 ms over its
  145 ms. `latency_ms` uses AOO's buffer latency event, which is the size *when buffering ended*, not what's held since: so the status said
  ~190 ms while ~300 was heard.
- AOO's jitter buffer holds twice its latency by default, so a buffer already ~100 ms over had ~45 ms of room; the next burst (or audio
  callbacks held up for a moment) didn't fit and AOO reset the stream (`handle_overrun`: a re-buffer, its latency of concealment, and Opus's
  decoder rejoining over ~100 ms: the silence, garbage and fade-in). Overruns were counted nowhere, and Play had no counters at all. The
  laptop's Talk buffer re-buffered at the same moment (its `buffer_ms` moved 145 -> 150 at 10.8 s in `r2_l.jsonl`): the burst overran both.

**Fix:**
- `size_sink`: every sink gets `CAP_HEAD` (300 ms) of room over its size (`AooSink::setBufferSize` beside `setLatency`); `fill_of` uses the
  same capacity.
- A stream measured above its size + `TRIM_OVER` (25 ms) for a stretch is **shed**, not re-buffered: `adapt` asks for the excess, and
  `rt_mix`'s `hear` plays the block, has AOO skip the excess (`reportXRun`: AOO's own xrun skip, a lock-free count), plays the next block
  and crossfades the two over one block. At most `SHED_STEP` (40 ms) a block (each step decodes that much at once). No gap, so it no longer
  waits for quiet, and a shed can't itself finish high the way a re-buffer could.
- Counted: Talk's `overruns`, `mix_overruns`, and Play's own `play_underruns`, `play_overruns`, `play_resyncs` (both: each a re-buffer),
  `play_trims` (sheds), `play_buffer_ms` (Play's buffer as measured now) and `play_latency_ms` (half the round trip + that + AOO's codec
  and reblocking for it) per peer in `StudioSync_LiveAudioStatus`.

### 2. The ears tap - `extension/rtaudio.cpp`, `tools/ears/`
`StudioSync_LiveAudioEars(peer, stream, path, seconds)`: what this computer actually hears of a bandmate's stream (`"talk"`, `"play"`,
`"hub"`: decoded, in `rt_mix`'s `hear` after the fade-in, before any level, so full level whatever the volume), or with peer `""` and
`"play"` its own Play as it goes out (`play_feed`, after Mute me), written to a 32-bit float stereo WAV. The audio thread only copies into a
lock-free ring (2.7 s); a worker writes. `.wav` paths only, no `..`, 0-60 s, one at a time, while live audio runs; a local call only
(nothing on the link can start it). Status `ears`: `what`, `state` (writing/done/failed), `frames`, `lost`, `first_age_s` (the first
frame's age on the steady clock: `StudioSync_DirectNow() - first_age_s` is when it was heard, on the link clock).
- `tools/ears/ears.lua` mode `tap` (`peer=... stream=... secs=N out=<file.wav>`): starts it (pcall, all four arguments), and when it's done
  writes `<out>.json` beside it: `t_first` on the link clock, `me`, `StudioSync_DirectClock()`.
- `tools/ears/ears.py wav REF GOT --stamps`: the latency on the sender's clock from the two stamps and the WAVs' lag; and on every live
  (non `--exact`) comparison a `steady` check: the lag window by window (0.5 s), so a step (a resync, sound dropped or repeated) fails it.

### 3. Drift in listening links, browser guests and the share's mix (1.19)
REAPER's audio clock and the browser's (or a guest's sound card) run a few hundred ppm apart; each side used to skip (a buffer past its
limit) or gap and refill. Now each reads at a rate that follows its buffer's average fill (2 s): `1 + (fill - size) x 0.05/s`, within
0.5% (9 cents at the bound, only when far off), through a 4-point Hermite interpolator:
- `lib/webui/guestworklet.js` (the guest hears the session): now a ring with a fractional read position; `map` points still give the link
  clock of what's played (each piece's start kept).
- `lib/webui/sharemix.js` (a screen share's REAPER mix).
- `lib/webui/listen.js` (the listening page): each decoded 20 ms plays at `ssListenPace`'s rate (`AudioBufferSourceNode.playbackRate`).
- `extension/webui.cpp` (the guest's sound into REAPER): the guest's up ring the same way (`GDRIFT_*`).

### 4. Listening links (1.21)
- The live indicator and "who's playing" count a bandmate whose own status (their status file or its link copy, `lib/presence.lua` peers)
  says their transport plays or records, with this computer's live audio on or off (`audience.band_playing`, `audience.who`'s new `sts`).
- Browser guests are in what listeners hear: `webui_guest_audio` hands listeners the mix after the guests are added (it was before).
- "Only the web UI's Home has the controls": left as is (3.6's default: no panel UI, the web UI only).

### 5. Browser guests (1.22)
- Guests hear each other: each live slot keeps `oth`, the other live guests' sum at the session mix's frames, which its sender adds to the
  session mix it sends (never its own sound).
- Four live at once (`GUEST_LIVE` 4, lib/guestweb.lua's `MAX`; it was two).
- Left: one take held per guest (a new upload replaces their previous one; Lua takes each in as it arrives, with `TAKE_GAP` 3 s, so it only
  matters for two uploads inside that gap) and the 160 MB per upload: the upload code is rt-p5's (P5) and wasn't changed here. The guest on
  the studio's Tailscale: P13.

### 6. The share's sound (1.24)
- **Output pair:** `lib/liveaudio.lua` reads the master's first hardware output (`out_pair`, every 0.5 s in its tick) and tells the extension
  (`StudioSync_LiveAudioOutPair(first)`); the audio hook then mixes live audio's bandmates into that pair and takes REAPER's mix for a share's
  sound, guests and listeners from it (`hook_pair` in `extension/audiohook.h`; a pair the device doesn't have: the first pair, as before).
- **Duck by computer:** a watcher's duck (`lib/webcall.lua local_msg`) goes by the sharing computer's peer (`open[dev].peer`), and
  `liveaudio.apply` reads `ducks[peer]` or `ducks[name]` (Jam's, P12's, still by name): a bandmate's other computer in the room keeps its Play.
- **System audio mid-share:** picking System audio while sharing asks the browser's picker again for the sound only (`call.js setSound`:
  its picture is stopped at once, its sound replaces the share's track; it ends with No sound, another pick or the share).

### 7. Panel UI (3.6)
Default kept: none, the web UI only.

## Tests (each fails with its change removed)
- `tests/rtaudio_test.cpp` (`rtaudio_test playresync`; also in `underruns` and the full run):
  - `trim_test`: now sheds while D plays, with no gap in what E hears (quietest 10 ms RMS 0.32; it was held until quiet).
  - `play_resync_test`: P sends Play to Q; a stall leaves Q's Play buffer ~45 ms over, then Q's audio callbacks are held up 43 ms. Before:
    an overrun mid-tone (quietest 10 ms RMS 0.001, the field's gap); now none, Play's counters (`play_overruns` 0, `play_resyncs` 0,
    `play_trims` >= 1, `play_buffer_ms`, `play_latency_ms`), and the ears tap: Q's WAV of P's Play at the tone's level, P's own Play
    sample for sample, bad arguments refused, one at a time, `first_age_s`.
  - Removed-change run: the same test file against HEAD's rtaudio.cpp (with a stub `rt_ears`): 10 fails, including the gap.
- `tests/webui_test.cpp` `guests_together_tests`: four live; A and B heard here (0.25 + 0.125) and by listeners (the tap had the tone
  alone); A hears the mix and B, B the mix and A, C both; 200 ms of a guest's ramp waiting plays at 1.005 samples a sample (one sample per
  sample: 1). Note: `extension/webui.cpp`'s P11 hunks and a first version of this test went into rt-p5's commit 9996e32 (it staged the
  whole shared working file while this work was in it); that first version's drift check (a block count) failed, and the second P11 commit
  replaces it with the ramp. Against the pre-P11 webui.cpp: 6 fails (two live only, the listeners' tap without the guests,
  nobody hearing the others, one sample per sample).
- `tests/audience_test.cpp`: `hook_pair` (the master on 3/4, a mono last channel, a pair the device lacks, the first pair).
- `tests/rt_p11_drift_test.js` (run by `tests/test_0_60_rt_p11.lua` when Node is here): the guest worklet and the share mix with REAPER's
  clock +-400 ppm off for 10 minutes, with jitter: no skip or gap, the buffer within its size -30/+40 ms; the listening page's pace: no
  underrun or dropped packet. Against HEAD's three files: 5 fails (skips and gaps every few minutes, no pace).
- `tests/test_0_60_rt_p11.lua`: the live indicator (`band_playing`, `who` with statuses), the duck by computer, `out_pair`, the mid-share
  System audio path in call.js.
- `tools/ears/test_ears.py`: a 100 ms step fails `steady`; the stamps give the latency.

## REAPER checks (desktop, laptop, LinuxBox; StudioSync with this extension build on all three)
1. **The ears re-run, desktop -> laptop direct (the one that failed):** as rt-ears' r1/r2 (`rig.sh` setup, `load`, `track add=true`, `live
   role=send` on the desktop, `live role=recv volume=0` on the laptop), and before firing, a tap at each end:
   `rig.sh run l "EARS={mode='tap', peer='james-main.tail99132c.ts.net:47281', stream='play', secs=14, out=[[<laptop tmp>/r3_l.wav]]}"` and
   `rig.sh run d "EARS={mode='tap', peer='', stream='play', secs=14, out=[[<desktop out>/r3_d.wav]]}"`, then `rig.sh live r3 d` as before.
   Fetch both WAVs and their `.json`, then `python tools/ears/ears.py wav r3_d.wav r3_l.wav --pattern <pattern dir> --stamps` and `env` on
   the polls as before. **Pass:** `steady` true (no step through the whole pattern), `no_gaps` true, `latency_ms` within ~20 ms of the
   laptop's `play_latency_ms` at that time, the laptop's `play_overruns`/`play_resyncs` unchanged through it. Do it twice, after ~10 s of
   silence each time (r1/r2's conditions). Also `env`: one latency (IQR <= 20 ms, no jump > 40 ms).
2. Same, desktop -> LinuxBox, and laptop -> desktop: `steady` and `no_gaps` true. Through the hub: `stream='hub'` on a listener, the
   desktop serving.
3. The laptop's status during a quiet minute after a song: `trims` may rise (sheds), `overruns`/`play_overruns` stay 0, `play_buffer_ms`
   stays within ~25 ms of `target_ms`, and nothing is heard as a click (a shed in silence is silent).
4. **A master on outputs 3/4** (desktop): route the master's hardware output to 3/4 (and listen there): bandmates' live audio is heard on 3/4;
   a screen share with REAPER mix carries the song; a guest and a listening link hear it. Put it back to 1/2 afterwards.
5. **Duck by computer:** with a bandmate who has two computers in the room (or the laptop and LinuxBox under one user name), watch one's
   share with its sound: only that computer's Play goes quiet here; the other's is still heard.
6. **System audio mid-share:** share a screen with No sound, then pick System audio: the browser's picker comes up again; pick the same
   screen and tick "Share audio": the watcher hears system sound, no second picture appears; No sound stops it.
7. **Guests:** two browser guests (Chromium with fake devices on the tailnet, `--use-fake-device-for-media-stream
   --use-file-for-fake-audio-capture=<a wav>`, `--mute-audio`): each hears the other in its session mix, not itself; a listening link hears
   both; a third and fourth can join live. Leave a guest live 15 minutes: the host's row shows no new `drops`/`under` after the first seconds.
8. **Listening page drift:** a listening link open 15 minutes in Chromium: `window.ssListen.stats()` keeps `under` at its first value and
   `ahead` near `lead` (0.25 s).
9. **Live indicator:** live audio off on the desktop, the laptop plays its transport: the desktop's listening page says "Live now" and names
   the laptop's user.

## Untested / limits
- Nothing ran in REAPER or a real browser; the drift controllers were checked against simulated clocks only (+-400 ppm), not real devices.
- A shed while someone plays is a crossfade between two moments of the same stream (one block): smooth, but a held note can show a short
  comb-like dip at the crossfade. It happens only after a whole stretch (5 s at the default speed) with the buffer >= 25 ms over its size.
- `play_latency_ms` follows Play's measured buffer, which moves with each packet's arrival (a sawtooth of a few ms); `latency_ms` (Talk's)
  is still AOO's size at buffering's end, kept as it was because the hub's logic compares against it (P9's file).
- The guests' `oth` sum is 16-bit and clipped like the session mix; four guests at full level on top of a loud mix can clip in what each
  guest hears (not in REAPER).
- The output pair follows the master's first hardware output only; a master sent to several pairs feeds from the first.
- The listening page's pace changes the playback rate per 20 ms packet (pitch moves by at most 0.5%, typically ~0.04% for 400 ppm).

## Review later (security)
- `StudioSync_LiveAudioEars` writes received audio to a path a local script gives: `.wav` only, no `..`, 60 s cap, one at a time; it's a
  ReaScript function (anything that can call it can already write files), and nothing on the link can start it.
- Guests hear each other now: a guest's voice reaches the other guests (as it already reached the bandmates and this computer). The guest
  link's warning text doesn't say so yet.
- System audio mid-share opens the browser's own picker again (the user picks; nothing new is captured without that).
- `StudioSync_LiveAudioOutPair` takes any channel number under 1024 from a local script; a pair the device lacks falls back to the first.

## REAPER check results (rt-r1, 2026-11-21, 0.59.49.93 + extension 1.0.35)

How: `tools/ears` as written (`rig.sh setup`/`cleanup`, `ears.lua` load/track/live/poll/tap/fire), each call through the locked hook
runners (rig.sh's laptop path takes no lock); the sender's "XT Ears" track (its own, never sent, no master send), receivers Mute me and
volume 0, never a microphone; Deafen back to 1 on all three after. Each run fired after more than 10 s of silence on the sender's Play.
Results in my scratchpad (`rt-r1/ears/r3..r6_*`).

| Check | Result | Evidence |
| --- | --- | --- |
| 1, run r3 (desktop -> laptop) | **fail** | `ears.py wav --stamps`: latency 305 ms on the sender's clock while the laptop's `play_latency_ms` said 111-136; gaps 210 ms (longest 40); not aligned (corr 0.13), so `steady` not computed; `env`: latency 310-368 ms falling through the run, gaps at 4.45, 9.10, 9.15 s. Laptop's `play_underruns`/`play_resyncs` 5 -> 12 during the run, `play_overruns` 0, `play_trims` 0 -> 1. |
| 1, run r4 (same, again) | **fail** | stamps 82 ms (laptop said 84 at the start, 192 at the end); gaps 260 ms (longest 70); corr 0.07; `env` 85-164 ms, gaps at 4.45, 6.65 s; `play_resyncs` 18 -> 28, `play_overruns` 0. |
| 2, desktop -> LinuxBox (r5) | **pass by hand, ears.py says fail** | No gaps, level 0.0 dB, spectra 0.08/0.15 dB; every 0.25 s window that matches at 0.98+ sits at the same lag (or one click period, 250 ms, away in the click train), so the delay held; `ears.py`'s `steady` flags the click train's and the tone ladder's periodic lags (127 ms "jump"), and corr 0.72 < 0.8 fails "aligned". Stamps 176 ms vs LinuxBox's `play_latency_ms` 82-96. LinuxBox's counters unchanged (5/0/5). |
| 2, laptop -> desktop (r6) | **not measurable: the desktop's tap is silent** | The desktop's tap of `james-laptop...:47281` `play` wrote 30 s of ~0 (peak 2e-34) while the desktop's own poll in the same seconds read that peer's `play_level` at 0.50 (the pattern) and the laptop's own tap has it at full level. The tap's status said `what: james-laptop... play`, `done`, 1440000 frames, 0 lost. Not found why: `rt_ears` takes the first resolved slot with that peer name, and `hear` writes only for `same_addr(ears.addr, p.addr)`; the desktop's entry for the laptop shows `lone: 2`. |
| 2, through the hub | not run (time) | |
| 3, quiet minute after a song (laptop) | **partial** | 4 reads over 80 s with the desktop's Play silent: `overruns` 0, `play_overruns` 0, `play_resyncs` steady at 51; `trims` 16 -> 18, `play_trims` 6 -> 7 (sheds); `play_buffer_ms` against `target_ms`: 111/110, 150/80, 45/60, 27/30 (one read 70 ms over while the target shrank). Clicks not judged (nothing listened to). But between the runs, with the desktop silent, `play_resyncs` rose 12 -> 18 -> 51 over ~8 minutes. |

**Finding: the laptop plays the desktop's Play stream 1.5-2 % fast.** The pattern's 440 Hz tone ladder arrives at the laptop at
446.5 Hz (r3) and 448.8 Hz (r4), on every step, with the tones 0.49 s apart instead of 0.50; LinuxBox hears the same stream at
440.0 Hz. Playing 2 % fast drains a ~100 ms buffer in about 5 s, which is the steady climb of `play_underruns` = `play_resyncs` (one
underrun, one re-buffer, a gap each) and the latency sawtooth above; so rt-p11's overrun fix holds (`play_overruns` 0 throughout) but
the laptop's Play now underruns instead. All three run 48 kHz (desktop WASAPI 512, laptop ASIO 128, LinuxBox PulseAudio 512), and
`clock_ppm` reads 0.8 (desktop), -59 (laptop), -9 (LinuxBox), so it isn't the local clock estimate; 2 % is the clamp in `clock_step`
(`v` within +-0.02), which suggests the laptop's sink (AOO's dynamic resampling) takes the desktop's rate as 2 % slow. To look at in
`extension/rtaudio.cpp`: what the desktop's source stamps (kAooPreciseTimestamp from `clock_step`) and what the laptop's sink makes
of them over the internet path (78 ms round trip); `rt_test_drift(l, 0)` on the laptop would show whether it's the resampler.
