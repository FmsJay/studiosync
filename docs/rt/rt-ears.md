# rt-ears: listening at both ends, automatically (2026-11-21)

James's idea: "Live audio could record what's happening on each machine's ends and compare that they're the same", with more than tones:
something like a real project. This is that harness: a known signal goes in at one computer, every other computer captures what it gets,
and a comparer says, with numbers, whether it arrived whole, on time, at the right level and sounding the same.

Built and run for real on the desktop, laptop and LinuxBox (StudioSync 0.59.49.91, extension 1.0.33) for live audio peer to peer, live audio
through the hub, and Jam. The Hop's held-note check ran only on the desktop alone (no cross-computer try: see "Left").

## Files
- `tools/ears/ears.py`: the test pattern, and the comparer (`env`: live audio from status polls; `wav`: two recordings of the same thing;
  `tail`: a held note's end). numpy + scipy (installed here; the tests skip without them). Prints JSON with numbers and a pass per check.
- `tools/ears/test_ears.py`: offline tests: a simulated link (delay, a lossy codec's top end, noise, dropouts) and simulated status polls
  (block sizes, a reader that steals peaks, as Live sync does) must give back the numbers put in. `tests/run.py` runs them (one added line).
- `tools/ears/ears.jsfx`: plays the pattern (or a MIDI note) on an armed track without the transport, and captures a track's sound, through
  gmem `StudioSyncEars`.
- `tools/ears/ears.lua`: REAPER's side, run through a dev eval hook with `EARS = {mode=...}`: load, track, fire, note, poll, live, hub,
  capread, jamset, transport, jamwatch, slot. Only the song "Cross Test"; every call pcall-wrapped with full arguments; results tagged `EARS`.
- `tools/ears/rig.sh`: the rig's runner (setup, run, live, cleanup) for desktop/laptop/LinuxBox.

## The design

### The signal (`ears.py pattern`, 9.75 s, 48 kHz, peak -6 dBFS)
| s | section | what it tests |
|---|---|---|
| 0.5-2.5 | 8 clicks (1 ms pulses) every 250 ms | timing: each one an isolated onset |
| 2.5-4.5 | 440 Hz at -6, -12, -18, -24 dBFS, 0.4 s each | level and its steps (a mix or codec that isn't linear) |
| 4.5-5.0 | log chirp 100 Hz-12 kHz at -9 dBFS | the spectrum, and timing |
| 5.25-9.25 | two bars at 120 bpm: kick, snare, hats, a saw bass, Cmaj7/Am7 keys, a voice-like formant synth gliding "a" to "i" | something like a real project: dense, full-range, transients over sustain |
| throughout | a -60 dBFS noise bed | keeps live audio's "back after a gap" fade-in (under -80 dBFS) from touching any event |

Synthesised in numpy (deterministic, no samples, nothing to license; GPL with the repo) rather than rendered from REAPER's stock
instruments, so the offline tests use exactly what the real runs play. The receivers hear it at -46 dBFS at most (volume 0.01), or not at all
(volume 0: the meters read before the volume).

### Where each end listens (what extension 1.0.33 exposes, no microphone, nothing out loud)
- **Sender, live audio**: its own Play stream's peak per audio block, `StudioSync_LiveAudioStatus` `play_level` (read before Mute me).
- **Receiver, live audio**: each bandmate's Play peak (`peers[...].play_level`) or the hub's mix (`hub.level`), before the cue mix's level.
  These peaks are all the extension exposes of a received stream: no waveform. So live audio is compared as **envelopes**: `ears.lua poll`
  reads the status every ~2 ms for 20 ms of each defer cycle (the rest left to REAPER and Live sync), with the link clock
  (`StudioSync_DirectNow`) and the audio callback count. The comparer maps each read onto the **block clock** (callback count fitted to the
  link clock: REAPER runs blocks in bursts, LinuxBox ~10 every ~100 ms, so read times are jittery but block numbers are the audio's own
  clock) and the receiver's clock onto the sender's with `StudioSync_DirectClock`'s offset (spread 0.1-1.9 ms here).
- **Jam**: the sender's own Jam WAV (`<home>/direct/<studio>/.jam/`) and each receiver's copy (`.streams/<song>/`), plus where the receiver
  put the hidden "Jam: <name>" items (`ears.lua jamwatch` logs every item as it's made): a true waveform comparison, and placement.
- **Track sound (the Hop)**: `ears.jsfx` in Capture after the instrument (or the Hop) records the track digitally into gmem; `capread`
  writes a WAV. Never through an output.

### What's compared, and the pass thresholds
`env` (live audio):
- **Alignment**: dB envelope cross-correlation (100 ms then 25 ms grids) finds the pattern at each end; >= 0.5 to count.
- **Latency**: each of the 13 isolated onsets found at the sender (rising edge past 30% of that event's own peak), then at the receiver
  within +-120 ms of the latency so far, so a jump is followed. The band excerpt's latency from its 25 ms envelope. Reported: each event,
  median, IQR, largest jump. Pass: IQR <= 20 ms and no jump > 40 ms, each plus the reads' own resolution (median span of a read at both
  ends: 13 ms desktop/laptop, ~100 ms with LinuxBox). Why: a block or two of jitter either way is the readings, more is the delay moving
  (sound dropped or repeated). A single reading no neighbour confirms is listed as an outlier (a false onset after a hole) and left out.
- **Level**: median of receiver dB - sender dB - the expected gain over loud 50 ms bins; within 2 dB (Opus and block peaks move a peak ~1 dB).
- **Dropouts**: a 50 ms bin inside sustained sound heard 20 dB under what was sent, in runs at least as long as one read spans.
- **Tone steps**: the 6 dB steps within 1.5 dB.
- **Band envelope**: correlation of the 50 ms dB envelopes >= 0.7 (block peaks; LinuxBox's bursts smear it).
- Not possible from peaks: the spectrum. That needs a waveform tap (below).

`wav` (Jam; a future tap): FFT cross-correlation lag; level (10 ms RMS) within 2 dB; dropouts (frames 20 dB under); third-octave band
difference 50 Hz-16 kHz over the chirp and the band excerpt <= 3 dB (lossy) or 0.1 dB with `--exact`, which also wants bit-exact samples.

`tail` (the Hop): the note's onset gives the path's delay; its tail must end within release + 200 ms (rt-hop2's bound) + one block of the
note-off plus that delay, and not before the note-off.

Jam placement: the pattern's sample 0 in the sender's Jam WAV against the effect's own `play_position` at that sample (the extension's
play-position stamp), and the receiver's item for it against the sender's position + one interval - the sender's input+output latency;
within 10 ms (rt-jam's REAPER step 3).

## How to run (the rig)
```
OUT=<scratch> tools/ears/rig.sh setup
tools/ears/rig.sh run d "EARS={mode='load', f32=[[<desktop path>/pattern.f32]]}"     # and l, x with theirs, when they send
tools/ears/rig.sh run d "EARS={mode='track', add=true}"                              # the sender's armed test track (yours, never sent)
tools/ears/rig.sh run d "EARS={mode='live', role='send', volume=0}"                  # Play only, not deafened
tools/ears/rig.sh run l "EARS={mode='live', role='recv', volume=0}"                  # muted (send nothing); 0.01 through a hub
tools/ears/rig.sh live r1 d          # or: live h1 d d   (d mixes, the others listen through it)
python tools/ears/ears.py env $OUT/pattern $OUT/r1_d.jsonl $OUT/r1_l.jsonl --peer james-main   (--hub --gain 0.01 through a hub)
...then on every computer: live role=restore (Deafen 1), hub peer='' serve=0, track add=false; rig.sh cleanup
```
Jam: `jamset on=true` on all, `jamwatch` on the receivers, `transport play=true pos=60` on the sender (past Cross Test's last item at
22.75 s; metronome off), `fire`, copy the receivers' `.streams` files before stopping (they're pruned once played), `transport play=false`,
`jamset on=false`, then `ears.py wav sent.wav received.wav --pattern <dir> --exact`.

## Results, 2026-11-21 (14:00-14:35 MT)
Desktop: WASAPI 512 (10.7 ms), Voicemeeter VAIO. Laptop: ASIO 128 (2.7 ms), over the internet (78 ms round trip). LinuxBox: PulseAudio 512 in
a VM on the desktop (0.3 ms round trip), blocks in bursts of ~10 every ~100 ms. Latency here = the sender's block going out to the receiver
decoding it, on block clocks; device output buffers are not in it (LinuxBox's alone is 133 ms).

| Run | Path | Latency (median; events) | Level | Gaps | Steps | Verdict |
|---|---|---|---|---|---|---|
| r1 | desktop -> laptop | **294-334 ms for 3.5 s, then ~222** (band) | -0.01 dB | 200 ms (3.55, 3.8, 4.3, 4.95 s) | 0.19 dB | fail: jump 112 ms, holes |
| r1 | desktop -> LinuxBox | 134 ms (IQR 17) | +0.12 dB | none | 0.20 dB | **pass** |
| r2 | desktop -> laptop | **~300 ms, then ~201 from 4.0 s** | 0.00 dB | 150 ms | 1.01 dB | fail: jump 117 ms, holes |
| r2 | desktop -> LinuxBox | 143 ms | +0.03 dB | 100 ms at 7.75 s (at LinuxBox's resolution) | 0.17 dB | fail (gap, band envelope) |
| h1 | desktop mixes and sends -> laptop via the mix | 129 ms (IQR 29) | **+0.04 dB vs the expected -40 dB** | none | 0.58 dB | **pass** |
| h1 | desktop mixes and sends -> LinuxBox via the mix | 146 ms | +0.06 dB vs -40 | none | 0.33 dB | fail (readings spread, LinuxBox resolution) |
| h2 | laptop -> desktop (the hub hears it direct) | 110.6 ms (IQR 7) | +0.01 dB | none | 0.25 dB | **pass** |
| h2 | laptop -> desktop's mix -> LinuxBox (two hops) | 165 ms | +0.05 dB vs -40 | none | 0.46 dB | fail (band envelope, readings spread) |

The hub's mix level read 0.00507-0.00514 on the listeners: the pattern's 0.51 x their volume 0.01, exactly.

Jam (desktop sends, one bar at 130 bpm = 1.846 s, two runs):
- The pattern sits in the sender's Jam WAV at frame 205312 (run 2: 205824), exactly where the effect's own `play_position` says: the
  extension's play-position stamp is right to the sample (rt-jam's first unverified assumption, now checked).
- The laptop placed it at 66.120093 s against 66.120091 expected (run 2: 66.173427 / 66.173425): **0.002 ms**. 13-14 items each run, joined
  end to start within 0.008 ms.
- The laptop's and LinuxBox's copies are **byte-identical** to the sender's WAV (run 2, copied mid-run; `wav --exact`: bit-exact,
  spectra 0.0 dB).
- **LinuxBox placed no Jam items at all**, both runs, though it received the whole stream: see Findings 3.

The Hop's tool chain, desktop alone (ears.jsfx MIDI note -> ReaSynth -> ears.jsfx capture): note held 506 ms, tail ends 6.1 ms after the
note-off (ReaSynth's release), allowed 210.7 ms: pass. With a StudioSync Hop in ReaSynth's place the same check measures a try.

## Findings
1. **The laptop heard the desktop's Play stream ~100 ms later than live audio says, until a resync dropped audio.** In both peer-to-peer
   runs the first 3.5 s arrived ~300-330 ms after sending; then, during the -18 dB tone, ~130 ms of silence, low-level garbage and a ~100 ms
   fade-in (the decoder re-joining), and from there ~200 ms: what the laptop's status `latency_ms` (186-195 ms) said all along. The status
   counters (underruns, jitter, switched, trims, buffer 145-150 ms) didn't move at that moment: they're Talk's, and Play's sink has none of
   its own. Each test came after ~10 s of digital silence on the Play stream. Not seen on LinuxBox (LAN) nor laptop -> desktop. Worth a look
   in `rtaudio.cpp`: how Play's sink buffers after a long silence, and Play-stream counters in the status.
2. **A hub test set from outside doesn't hold.** Live sync asks for its own plan whenever the room's size changes (the Mac's entry came and
   went on the laptop's and LinuxBox's lists); the first h1 attempt lost the hub that way, the listeners spent 80% of it joining or on direct
   streams, and the mix they did hear was silent. `ears.lua poll` now asks again (and notes it) whenever who-mixes isn't what the test set.
   Only Live sync's normal behaviour, but a hub with three computers can only be tested this way (HUB_FROM is 4).
3. **On LinuxBox, Play together moves the cursor but its transport doesn't run.** Its log says "playing together from 60.05 s", yet 1-4 s
   later `GetPlayStateEx` is 0 and the cursor still 60.03, while the laptop is at 71.6 s. So Jam has nothing to place there. Its log also says
   "Syncthing didn't answer" since its Live sync restarted at 20:53 UTC. To check by hand on LinuxBox.
4. **The laptop's and LinuxBox's eval hooks are shared and have no lock.** Another session's probe came back as my result twice (and saw my
   test's Deafen off). `rig.sh` gives its source its own name and retries untagged results; a lock like the desktop's would be better.

## Limits
- Live audio is compared from peaks, not waveforms: no spectrum, and timing to a read's span (13 ms; LinuxBox ~100 ms, where latency
  steadiness, short gaps and the band envelope can't be judged reliably). Hole edges can still give a false onset next to them.
- Live sync's own status reads take some peaks (about 4% of the reads after a poller pause on the desktop); the comparer keeps those reads
  for levels and uses them for timing only when they span 15 ms or less.
- The poller holds REAPER's main thread 20 ms of every ~33 ms while it runs (~40 s a test).
- The pattern's 250 ms click spacing can be a whole number of REAPER's defer periods (the laptop's): every click then lands in the poller's
  pause. Handled as above; a spacing like 263 ms would avoid it next time the pattern changes.

## Left
- **A waveform tap for live audio** (needs an extension release): `StudioSync_LiveAudioEars(peer, stream, path, seconds)`, stream "talk",
  "play" or "hub" for a bandmate's decoded stream (in `rt_mix`'s `hear`, after the fade-in, before the cue mix's gain: full level whatever
  the volume) and peer "" for this computer's own Play (in `play_feed`, after Mute me), into a lock-free ring as `StudioSync_DirectAudioDump`
  does, a worker writing 32-bit float WAV, at most 60 s, and the steady-clock age of its first frame in the status so Lua can stamp it with
  `StudioSync_DirectNow`. Then `ears.py wav` gives spectra, exact gaps and latency for live audio, through the hub too.
- **The Hop across computers**: a try (desktop trying a laptop-only instrument) needs Allow on the laptop's screen. Then: `track add=true
  note=60 instrument=<the tried plug-in's track: the Hop> capture=true` on the requester, `note frames=144000 off=48000`, `capread`, `ears.py
  tail`; for a lost note-off, set the requester's Hop offline while the note is held and capture on the laptop's hidden track instead.
- **The full-quality copy** (rt-double): it records armed tracks' hardware inputs, so it needs a signal on an input, and none of the three
  has one I may use (the desktop's is the work-call bus, the laptop's a real interface, LinuxBox's would need a PulseAudio null sink + loopback,
  a system audio change). With one: `wav --exact` of the recorder's WAV against the copy that lands on the others (bit-exact expected).
- **Listening links and browser guests**: open the page in Chromium (fake devices only, `--use-fake-device-for-media-stream
  --use-file-for-fake-audio-capture=pattern.wav` for a guest that sends) and tap its Web Audio output in the page (a MediaStreamDestination on
  the page's AudioContext into a MediaRecorder, the blob handed back over CDP), with `--mute-audio` so nothing plays. Then `ears.py wav`
  against the sender's Play.
- **The S23** (a later round, not run): the phone plays a listening link or a guest page; capture its playback digitally with scrcpy, already
  on both PCs: `scrcpy -s <S23 serial> --no-video --no-window --audio-source=playback --audio-codec=raw --record=s23.wav` (Android 11+; the
  sound is captured instead of played unless `--audio-dup`, so nothing is heard; apps can opt out of playback capture, Chrome doesn't). Its
  timing against the PC's clock is good to ADB's start-up (tens of ms): enough for gaps, level and spectrum; for latency, stamp the start
  from the phone (`ssh s23 date +%s.%N` before and after) or compare against a PC guest started at the same moment. Never the phone's mic.
- Tests: the offline tests pass; nothing in CI runs Python with numpy (the tests skip without it).

## Review later (security)
- `ears.lua` writes files only where its caller says (a local eval hook, already able to run anything), and changes live audio's ExtStates
  only through the same keys the panel uses, saving and restoring them.
- gmem `StudioSyncEars` is readable and writable by any JSFX or script on that computer: test-only, holds the pattern and captures.
- The proposed tap would write received audio to disk on a local call: keep it local-only (no link message may start it), path checked,
  60 s cap.
