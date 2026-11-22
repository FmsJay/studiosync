# P12: Jam and the full-quality copy (rt-p12, 2026-11-21)

Package P12 of `docs/rt/backlog.md` "Plan to finish": items 1.14, 1.15, 1.16 and 3.15, plus P7's leftover Jam wording and P8's live
audio merge cache. Built on P9 (7eafd6f: `livex.lua` host election) and P11 (0249568, c9f40c2: audience/direct_audio drift and guests).
Offline and native tests only; **nothing was run in REAPER or on the test computers.** The extension changes need the next extension
release (EXT_VERSION not bumped). No section-4 question applied; where a choice had to be made it is named below as "Chosen".

## What was built

### Jam (backlog 1.15, 3.15; `lib/jam.lua`, `extension/direct_audio.cpp`)
1. **Only to those with Jam on.** Each computer with Jam on sends `jam_hear { user, opus }` every 2 s (`jam.HEAR_EVERY`) to the room's
   peers. A run streams only to peers whose person said so within 6 s (`jam.audience`); with nobody listening nothing is captured and Health
   says "nobody here has Jam on (it goes only to those who do)". A peer list without people's names (an older cache) falls back to
   everyone, the WAV, as before.
2. **A latecomer hears the next interval, not the next play.** One who says Jam on mid-run is added to the same stream with
   `direct.stream_start(..., { newcomer })` (the link sends a peer added later from the beginning of the file) and the `jam` message (where
   each stretch sits) goes at once to everyone on the run.
3. **Opus.** Chosen: Opus over FLAC, because the problem named was bandwidth (1.5 Mbit/s a listener): Ogg Opus at 192 kbit/s stereo,
   complexity 8, 20 ms frames, written by the Jam worker (not the audio thread) when the capture's path ends `.opus`. Used when this device
   runs at 48 kHz, every listener says it can decode (its extension has `StudioSync_JamDecode`), and Opus hasn't failed here this session;
   otherwise the 16-bit WAV as before. Every packet is a page of its own; the last page's granule trims the copy to exactly the frames fed.
   - **Receiver:** `StudioSync_JamDecode(src, dst, mode)` (new, `direct_audio.cpp`) decodes the growing Ogg copy on one worker thread into a
     growing 16-bit stereo WAV beside it (`<copy>.opus.wav`), dropping the encoder's pre-skip so frame k of the WAV is frame k fed: the
     segments' file frames and all of `jam.chunks`' placement hold unchanged. mode 0 goes on, 1 finishes once the stream is done, 2 drops the
     job. `jam.lua` takes frames and the end from the decoder, places from the WAV, and on forgetting a run drops the job and deletes the WAV.
   - An Opus run reaching a computer without the decoder isn't taken there (their live Play stays heard, as with Jam off).
   - The native test measures: decoded in place (best lag 0), over 25 dB to what was fed, exactly the frames fed, a fifth of the WAV or less.
4. **Wording (P7, section 4 question 3):** "Follow each other" is now "Play and stop together" in `lib/jam.lua` (header, Health's warning,
   the Settings tooltip, a comment); `tests/test_0_60_rt_jam.lua` checks the words and that none of the old ones are left.

### The full-quality copy (backlog 1.14, 3.15; `lib/double.lua`, `extension/direct_audio.cpp`)
1. **Drift stamps every second.** The keep hook stamps `{ file frame, link clock }` about once a second (`stamps` in
   `StudioSync_KeepStatus`, a ring of 64; Lua reads at 10 Hz). Lua puts each on the shared clock as it reads it, and `double.fit` takes the
   least-squares slope over the stamps inside each no-transport stretch: the item's `D_PLAYRATE` is the device's real rate (frames a shared
   second / nominal), its length in shared seconds. Left at 1 under 10 s of stamps, past 1000 ppm (a clock jump, not a crystal), or when it
   would move the stretch's end under 0.5 ms. Transport stretches need none (the song position and the frames come from the same device clock).
   No pitch processing for a drift's rate (0.03 cents at 20 ppm).
2. **Play rates other than 1.** The hook reads `Master_GetPlayRate` with the play position; a stretch at another rate is one segment
   (segments carry the rate), placed as one item at `p0 - latency * rate`, its take play rate `1 / rate`, preserve pitch on. Before, every block
   started a segment.
3. **MIDI tracks.** A track recording a MIDI input (I_RECMODE 0, 7-9, 15, 16) is no longer "not copied": the run reads REAPER's recent-input
   history (`MIDI_GetRecentInputEvent`) every tick from the run's start, keeps channel messages for the armed MIDI tracks (device and channel as
   the track's input says), each with REAPER's project position (transport) or its moment on the shared clock (live), and lands them as MIDI
   items (`CreateNewMIDIItemInProj`, `MIDI_InsertEvt`), an item a track a stretch (a play, the time stopped, each loop pass). Claims and
   lanes as for audio. A run with only MIDI tracks starts without the extension's capture. Tracks recording their own output are still not
   copied (Record keeps those), and say so.
4. **The no-transport anchor's place.** Each computer's anchor now carries `past` and `endp` (a bar past its own project's end); `double.pick`
   keeps the earliest start and the furthest `endp` (associative, so every computer that heard the same anchors agrees), and a live jam lands a
   bar past the longest copy of the song. `double.valid` checks `endp` (0-1e6).

### Their time and Produce (backlog 1.16; `lib/livex.lua`, `lib/producer.lua`)
1. **Takes recorded in Their time move back.** While not recording, `livex.their_tick` notes the armed tracks' items; while recording, the
   delay is held (no 10 ms steps mid-take) and the armed tracks kept; when it ends, new items on those tracks (not streamed placeholders,
   `band_arriving`) move earlier by that delay (front trimmed at 0), one undo point "StudioSync: takes recorded in Their time moved N ms
   earlier", and the log says so. Nothing moves when nothing was noted just before the take (Their time came on mid-take).
2. **Produce's first second.** The performer's computer sends `produce_rec { user, rec }` the tick a take starts or ends
   (`producer.rec_tick`, every Live sync tick) to the computers producing it; the producer's `producer.on_rec` sets the duck at once and calls
   `liveaudio.apply`. For 5 s (`producer.FAST_FOR`) that word goes before the status's `recording` in `producer.tick`, so a stale status
   doesn't put the duck back.

### Live audio's merges (P8's rt-perfcut4 section 4; `lib/liveaudio.lua`)
`heard_merge`, `vouch_merge`, `livex.guests` and the peer lookups run only when what they read changes (`liveaudio.merge_sig`: the room's
list after the NAT merge, the not-listed addresses heard, who's near, each fresh status's user, time and `hub.sees`, the heard ones kept), or
every `MERGE_HOLD` = 2 s for the time-based parts. `presence.here` and `presence.peers` are still read each run (both cached by presence).

## Files
- Mine: `lib/jam.lua`, `lib/double.lua`, `lib/producer.lua`, `lib/livex.lua` (Their time's takes only), `lib/liveaudio.lua` (the merge
  cache only), `extension/direct_audio.cpp`, tests `tests/test_0_60_rt_jam.lua`, `tests/test_0_60_rt_jam2.lua` (new),
  `tests/test_0_60_rt_double.lua`, `tests/test_0_60_rt_double2.lua` (new), `tests/test_0_60_rt_p12.lua` (new), `tests/jam_test.cpp`,
  `tests/keep_test.cpp`, `tests/build_jam_test.cmd`, this doc. `extension/audience.cpp` not touched (nothing in P12 needed it).
- Shared, small and additive: `StudioSync - Live sync.lua` (3 lines: the `jam_hear` and `produce_rec` handlers, `producer.rec_tick` after
  `double.tick`); `extension/direct.h` (the `direct_jam_decode` declaration, the keep status's comment, `direct_keep_feed`'s `rate = 1.0`
  default); `.github/workflows/extension.yml` (the Jam test step built with `-DJAM_OPUS`, the Opus include and `libssdeps.a`, both jobs).
- `direct_audio.cpp` compiles Opus in when `DIRECT_STANDALONE` is off (the extension, which links Opus already) or `JAM_OPUS` is set (the Jam
  test); every other standalone test builds it without Opus as before.

## Tests
- `python tests/run.py --no-luals`: fails 0 (in the shared worktree, and in a clean clone of the commit, also with `TZ=UTC0`).
- Each new Lua test fails on HEAD's file before the change (checked by swapping in `git show HEAD:<file>`).
- Native: `tests\build_jam_test.cmd` (now with Opus) and `tests\build_keep_test.cmd`: all ok. `extension\build_windows.cmd` with a scratch
  `DLL_OUT`: builds. The extension without Opus (`/DDIRECT_STANDALONE` only) compiles.

## REAPER checks for the real computers (after the next extension release; desktop + laptop, LinuxBox as the third)
Tools: `tools/ears` (`docs/rt/rt-ears.md`; `ears.lua` through the eval hook, song "Cross Test"; `ears.py` on the desktop). Write each
result here (pass, fail, not run) with the numbers.

1. **Extension.** Console on each: `reaper.StudioSync_JamDecode("", "", 2)` returns `{"state":"none",...}`; `reaper.StudioSync_KeepStatus()`
   contains `"stamps":[`; `reaper.StudioSync_JamStatus()` contains `"codec":`.
2. **Only to those with Jam on.** `jamset on=true` on the desktop only, `track add=true` there (the pattern), `transport play=true pos=0`.
   Health's Jam row: "nobody here has Jam on". `jamset on=true` on the laptop: within 2 s the desktop's `StudioSync_JamStatus()` is `on` with
   `"codec":"opus"`, and `StudioSync_DirectStreams()` has one `out` stream `...~jam-*.opus` whose peers are the laptop only (LinuxBox, Jam off,
   isn't in it). Note the stream's bytes a minute: about 1.4 MB at 192 kbit/s (it was about 11.5 MB as WAV).
3. **Opus heard right (ears).** Desktop sending as in 2, laptop listening: on the desktop `tap peer="" stream=play secs=30 out=send.wav`; on
   the laptop `jamwatch out=jam.log secs=30`, then copy the laptop's `<inbox>/.streams/Cross Test/main~<desktop user>~jam-*.opus.wav`. Then
   `ears.py wav send.wav got.wav --pattern <pattern dir>`: level within 2 dB, no dropouts, spectrum within 3 dB (the lossy limit). (`--exact` is
   for WAV runs only: Opus isn't bit-exact.) In `jam.log`, each interval's item starts on its bar line; **note the ms** (rt-ears had 0.002 ms
   with WAV; the decoder keeps frames in place, so it should be the same).
4. **A latecomer.** Desktop playing and sending to LinuxBox (Jam on there), laptop Jam off. Turn the laptop's Jam on mid-run: its
   `jamwatch` shows the desktop's items from the next whole interval (at most two intervals after turning on), without the desktop stopping.
5. **WAV fallback.** One computer's device at 44.1 kHz (LinuxBox can be set in its REAPER audio prefs): its runs are `"codec":"wav"` and still
   heard on the others; a 48 kHz sender to it still sends Opus (it can decode at any rate: REAPER resamples the 48 kHz WAV).
6. **Full-quality copy, play rate.** Project play rate 1.5 on both, Jam on, keep a full-quality copy on, play together 8 bars, stop. The
   part lands as one item per track (not dozens), take play rate 0.667, preserve pitch on, its hits on the bars they were played to (note
   the ms against the grid).
7. **Full-quality copy, drift (needs a signal on an input: LinuxBox with a PulseAudio null sink + loopback is a system audio change, so
   James's OK first; never a real mic).** A 5-minute live jam, no transport, desktop and LinuxBox: the parts' take play rate is the device's
   real rate (|rate - 1| x 1e6 = its ppm against the shared clock, often 5-50; exactly 1 when under 0.5 ms over the part). `ears.py wav
   --exact`-style comparison of the recorder's own file against the copy that lands on the other: bit-exact source; the clap lines line up
   within 1 ms at the start and at the end (before: ~7 ms apart at the end at 20 ppm).
8. **Full-quality copy, MIDI.** Arm a MIDI track (REAPER's Virtual MIDI Keyboard as input is fine) beside an audio one, keep a full-quality
   copy on, play a few notes live (no transport) and then with the transport, stop. A MIDI item each stretch on that track, the notes where
   played: with the transport, compare against the same notes recorded by REAPER on a second armed MIDI track in Record (**note the ms**:
   `MIDI_GetRecentInputEvent`'s project position is assumed to match REAPER's own recording offset; if it's off by the output latency, that's
   the fix). Undo history: one "StudioSync: full-quality parts from the jam".
9. **The anchor past the longest song.** Laptop's copy of the song 20 s longer than the desktop's (an item at the end, before it syncs,
   or a scratch song with Syncthing paused on one): a live jam with the copy on lands a bar past the longer end on both computers.
10. **Their time's takes.** Desktop and laptop, live audio on; desktop Home > Their time (note the delay Home shows, e.g. 150 ms). Record 4
    bars on an armed track while the laptop plays the pattern. Within 2 s of stopping, the take moves earlier by that delay (Undo history:
    "StudioSync: takes recorded in Their time moved 150 ms earlier"; the log says so); a streamed placeholder from the laptop and the other
    tracks don't move. Home's delay doesn't change while recording.
11. **Produce's first second.** Laptop produces the desktop (live route). On the laptop `poll out=p.jsonl secs=20` while the desktop starts
    recording with the pattern playing: the desktop's Play level on the laptop (`play_level`) drops to silence within 0.3 s of the take's
    start (before: up to ~1 s), and comes back within 0.3 s of its end. ExtState `live audio duck play` on the laptop follows the same.
12. **Live audio's merges (perf).** Desktop, live audio on, three computers: the live audio sub-lap in Health's perf rows (or `tick stats`)
    with nothing changing in the room: about 2 ms less a run than before; a computer joining still appears on the list within a second.
13. **Mac and Linux builds:** checks 1-3 at least (the Opus writer and decoder on SWELL builds).

## Untested / limits
- Nothing ran in REAPER. Assumptions the checks measure: `MIDI_GetRecentInputEvent`'s project position matches where REAPER records the
  same note (8); `MIDI_InsertEvt` with raw note on/off makes notes after `MIDI_Sort` (8); `Master_GetPlayRate` is safe to call from the audio
  hook's pre call, as `GetPlayPosition2Ex` is (6); take play rate with preserve pitch is what a band wants for a part played at another rate (6).
- Jam still doesn't follow play rates other than 1 (every block starts a segment there, as before): not in the backlog's P12 list.
- A latecomer's catch-up downloads the run's copy from its start (192 kbit/s: about 86 MB for an hour-long run; WAV runs about 690 MB). The
  link has no "from here" for a stream (`direct.cpp`, P13's).
- An Opus run doesn't reach a listener that joins without the decoder (an older extension) until the next run; a WAV run does.
- Their time: a take shorter than the 2 s tick that starts and ends between two ticks isn't moved; a take recorded into an existing item
  (REAPER's takes mode, not lanes) adds no new item and isn't moved.
- The merge cache holds up to 2 s on changes it doesn't see (a status going stale past `hub.VOUCH`, `HEARD_S` expiring).

## Review-later (security)
- `jam_hear`'s `user` and `produce_rec`'s `user` are self-claimed in the signed message (as `jam`'s and `double`'s are): a room peer could
  claim another's name to be added to a Jam run (it's on the room's link already) or to flip a producer's duck for the one it produces.
  Tying them to the sending peer's own person (the link knows which peer sent it) is the fix for all four.
- The Jam decoder reads only files the link wrote into this computer's inbox; it bounds a packet at 64 KB and pages at 255 segments, stops
  on anything that isn't an Ogg page or an Opus head, and is local-only (no link message starts it); 16 jobs at most.
- A `double` anchor's `endp` lets a peer push where this computer's no-transport parts land later in the project (bounded 0-1e6 s), as an
  early `t` already could (rt-double's note).

## Re-check results (non-audio only) (rt-r2, 2026-11-21 evening MT / 11-22 UTC, StudioSync 0.59.49.94 from 905f000 + extension 1.0.36 on the desktop, laptop, LinuxBox and LinuxBox2; Deafen 1 everywhere, no sound tests)

- **1: pass on all four** (Windows desktop and laptop, both Linux VMs, so check 13's first part on Linux too): `StudioSync_JamDecode("", "", 2)` ->
  `{"state":"none","frames":0,"error":""}`, `StudioSync_KeepStatus()` has `"stamps":[`, `StudioSync_JamStatus()` has `"codec":`.
- `jam_hear`'s effect wasn't run: Health's Jam row checks live audio's Play before listeners (`jam.why_not`), so with Deafen on it only ever says Play
  isn't going, and Jam's switch also turns In time and Play-and-stop-together at 0 bars on. Everything else needs sound.

## Re-check results with sound (rt-r3, 2026-11-22 05:24-05:34 UTC, StudioSync 0.59.49.95 from 747151f + extension 1.0.37 on the desktop, laptop and LinuxBox)

The desktop sent the ears pattern ("XT Ears", its own, no master send) on Play only, transport from 60 s (past the song's end, so nothing of
the song sounds); the listeners Mute me at live audio volume 0 (so their Jam tracks play at 0: Jam's level is the cue mix's); `tools/ears`'
`jamset`/`transport`/`jamwatch`; Jam, Deafen and "Play and stop together" put back on all three after, LinuxBox's `stopprojlen` back to 1.

| # | Result | Numbers |
| --- | --- | --- |
| 2 only to those with Jam on | **pass** | Jam on the desktop only, playing: Health "Jam (every 1 bar): you send nothing: nobody here has Jam on (it goes only to those who do); nobody else is jamming", `JamStatus` `on: false`, no jam stream. The laptop's Jam on: the run `main~James~jam-20261122-052600Z-018.opus` started (the run's name says 05:26:00, the laptop's `jamset` returned 05:26:05), `codec: "opus"`, its only peer the laptop (LinuxBox, Jam off, not in it). Bytes: ~1.3 MB a minute while the pattern sounded (136873 -> 409581 bytes over the 10 s pattern and ~3 s around it: about 192 kbit/s), ~90 KB a minute of silence. |
| 3 Opus heard right | **pass** | The desktop's own Play tap against the laptop's decoded `.streams/Cross Test/main~James~jam-...opus.wav`: corr 0.9995, level 0.0 dB, no gaps, spectrum 0.06 / 0.02 dB, speed 1.0000, steady (0.0 ms over 17 windows). Every Jam item in `jamwatch` starts on its bar line: `bar` 114.000000, 115.000000, ... (0.000 ms at the log's 1 µs). Note: the growing `.opus.wav` has 0 in its RIFF/data sizes while the run goes on (Python's wave readers see it as empty; read past the header by hand), and the `.opus` beside it read 0 bytes on the laptop. |
| 4 a latecomer | **pass** | Run `...053008Z-446.opus` going to LinuxBox only (Jam on there, `stopprojlen` 0 for the run). The laptop's Jam on between link times ...547.1 and ...571.5: added to the same stream (its peers then the laptop and LinuxBox, sizes equal: sent from the start), and its first Jam item (bar 283) was placed at ...564.4 while its playhead was 1 s into that bar, then 284, 285, ... each on its bar; the desktop never stopped. |
| 5 WAV fallback | not run | Needs LinuxBox's REAPER audio device set to 44.1 kHz (an audio preference change and device restart in the VM). |
| 10 Their time, 11 Produce | not run (time) | |
