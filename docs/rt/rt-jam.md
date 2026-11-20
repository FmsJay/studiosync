# Jam: classic NINJAM play-along built in (rt-jam, 2026-11-20)

James's decision (2026-11-20): build play-along (classic NINJAM "Jam": everyone plays live, each hears the others one interval behind, no
recording needed) into StudioSync's built-in "In time (NINJAM style)". Until it matches in REAPER, the external ReaNINJAM path stays.
This closes rt-audit's "Classic NINJAM Jam" gap (§2: In time only followed a take being recorded).

Tested with stand-ins only: Lua tests, the native capture test, and the extension built (Windows) to a scratch DLL. **Not run in REAPER yet.**

## What it does
- **Jam is a choice under In time** (Settings > Options, under "Parts play": "Jam: everyone plays at once, nothing recorded"). Ticking it
  turns In time on and Follow each other at 0 bars (its old bars kept in the project's "side before jam" and put back when Jam goes off), so
  Play together and everyone's own play and stop start and stop everyone at once. The interval is In time's existing "bars behind (the
  interval)".
- **Sending** (the tab in front, while the transport plays): live audio's Play feed (every armed track after its FX, after Mute me and Deafen,
  exactly what Play would send) goes into a growing 16-bit stereo WAV on this computer (`<home>/direct/<studio>/.jam/`, never the shared
  folder), written by the extension, and streamed to the others over the direct link as it grows. Each play-to-stop run is one file
  (and a new one every hour, so a WAV stays under 4 GB and nobody's inbox fills).
  - The extension stamps each block with REAPER's play position (read in its own audio hook before REAPER processes the block). A block that
    doesn't start where the last ended (play, seek, loop, a dropped block) starts a **segment** `{ file frame, song position }`.
  - A `jam` message (every second, and at once on a new segment) carries the run, the file, the rate, the sender's interval and the newest
    16 segments, each position moved back by this computer's input + output latency (where the player heard the song, as REAPER's own
    recording offset does). `jam_end` at stop.
- **Hearing** (any computer with Jam on): each bandmate plays on a hidden track of this computer's own (`Jam: <name>`, `band_local = "jam"`,
  never sent, never fed into Play), as short items: what they played in interval k (bars kN+1..(k+1)N) starts on the first bar of interval
  k+1, by this project's tempo map. A part interval (a start or seek mid-interval) keeps its place in the bar; an interval longer than its
  slot after a tempo change is cut at the slot's end; on a loop back the newer pass wins once any of it has arrived. Items are made up to
  1.5 s ahead from what has arrived and made again (a fresh source: REAPER reads a file's length once) when the interval is whole or the
  playhead nears what's there. Never looped (`B_LOOPSRC` 0), `band_arriving` (mirror skips them), gone once played, all gone at stop.
- **Level and mute** come from live audio's cue mix: the bandmate's Play level times the master; their mute and Deafen silence them.
- **Keeping live audio separate**: while a bandmate's run is live here, their live audio Play stream is silent for this listener
  (`liveaudio.ducks[name]`, refreshed every tick, as rt-share's screen-share duck), so nobody hears a part twice. Their Talk is untouched.
  A listener without Jam on ignores the jam messages and hears their live Play as before.
- **Recording while jamming** still works: In time's lag for a take you follow is off while jamming, and the take's streamed placeholder
  stays muted (it's heard through Jam, an interval late). The real take arrives as ever.
- **UI**: the Jam checkbox and a "Hearing Ann, Bob, an interval late" / "You send nothing: ..." line in Settings > Options; a **Health** row
  (what goes out and to how many, who's heard with intervals heard, late and missed, a bandmate on another interval length, Follow each other
  not at 0); the web UI's **Beat** page shows "Jam, every N bars: interval 12, bar 2 of 4 · hearing Ann, Bob an interval late".

## Files
- `extension/direct_audio.cpp` (+ `direct.h`): the capture (`direct_jam_start/stop/status/feed`; ReaScript `StudioSync_JamStart(path)`,
  `StudioSync_JamStop()`, `StudioSync_JamStatus()`), a second audio hook that only reads the play position, `rt_play_tap` set at load.
  Audio thread: no allocation, lock or file; a whole block that doesn't fit the 5 s ring is dropped and the next starts a segment.
- `extension/rtaudio.cpp` / `rtaudio.h` (rt-hubfix's this hour; **additive only**): `rt_play_tap`, a function pointer like `rt_talk_add`,
  defined next to it, and one call in `play_feed` after the Mute me line, before the AOO source: `if (rt_play_tap) rt_play_tap(l->pptr, 2, len, l->cfg_sr);`.
- `lib/jam.lua`: everything else (pure placement math, message checks, sender, receiver, Health, Beat info, options).
- Small additive hooks: `StudioSync - Live sync.lua` (handlers `jam`/`jam_end`, `jam.tick` after `streams.tick`, `jam.on_exit` at exit),
  `StudioSync - Panel.lua` (`jam.options` after `streams.options`), `lib/page_health.lua` (`jam.health_rows` after the stream format row),
  `lib/songsheet.lua` (`jam` in the `beat` topic), `lib/webui/visuals.js` (the Beat page's Jam line), `lib/streams.lua` (two one-line
  guards: `in_time_lag` returns nothing while jamming; `receive_tick` treats Jam as Show only for take placeholders; both outside rt-prune's
  settings lines).
- Tests: `tests/test_0_60_rt_jam.lua`, `tests/jam_test.cpp` (+ `tests/build_jam_test.cmd`, and a step in both CI jobs).

## Needs a new extension
`StudioSync_JamStart` comes with the next extension build (not bumped here: James releases). Without it, Health says "needs a newer
StudioSync extension" and nothing else changes. `lib/files.txt` needs `tools/make_index.py` at release (new `lib/jam.lua`).

## REAPER checks for the real computers
1. Build and install the extension; restart REAPER. `reaper.StudioSync_JamStatus()` in the console returns `{"on":false,...}`.
2. Two computers in one song, live audio on, direct link up. On both: Settings > Options > Parts play > tick Jam. Follow each other shows
   "0 bars behind". Health has a Jam row.
3. Each arms a track with an instrument/mic and monitoring on. Press Play on one: both start (side by side at 0). Each plays a bar-length
   figure. Check: you hear the other exactly one interval later, starting on the bar (record the master on a third track to measure: the
   figure should land within ~10 ms of the bar line; note how far off, it tells whether the latency correction and the play-position read
   are right).
4. Check you do NOT also hear their live Play (only the delayed one); their Talk still comes through live.
5. Listen for a click or dropout about 0.3-1 s into each interval (the moment an item's source is made again). If there is one, note it.
6. Change "bars behind" to 2 on both; play again: two-bar intervals. Set one to 1 and one to 2: Health says the other is on another interval.
7. Add a tempo change (e.g. 120 to 90 at bar 5) and jam across it: every interval still starts on its bar; one recorded at the old tempo is
   cut at the next bar line.
8. Loop bars 1-4 with repeat on, Play together: after the wrap you hear the latest pass, never the old pass doubled.
9. Chat > Call: lower the bandmate's Play level, then mute them, then Deafen: the Jam track follows each. Mute me on the sender: Jam sends
   nothing (Health: "you send nothing: live audio's Play isn't going").
10. Three computers (desktop, laptop, Mac): each hears both others, each on its own hidden "Jam: <name>" track (View > Show all tracks to see
    them), an interval late.
11. Record on one computer while jamming: the others hear the take through Jam (once), its placeholder muted; the real take lands as ever.
12. Stop: all Jam items vanish. Untick Jam: the Jam tracks go and Follow each other returns to what it was.
13. Pull the network for a few seconds mid-jam: Health counts late/missed intervals; it picks up again on its own.
14. Mac and Linux: steps 2-4 at least (the play-position hook and the 16-bit writer on SWELL builds).

## Untested / limits
- Nothing ran in REAPER. Unverified assumptions: `GetPlayPosition2Ex` in the audio hook's pre call is the position of the block about to be
  processed, and every hook's pre call comes before processing (step 3 measures it); swapping a playing item's source is click-free enough
  (step 5; In time's placeholders do the same).
- A bandmate who arrives mid-run hears that person from their next play (no catch-up from the middle of a run).
- Play rates other than 1 aren't followed (every block would start a segment). A rotation (hourly) costs at most one interval.
- Only stereo, 16-bit, at the device's rate (about 1.5 Mbit/s per listener at 48 kHz: WAV, the link's only codec today). Opus would need an
  Ogg writer or a link codec; FLAC through REAPER's sink would add REAPER's 256 KB write steps (2-5 s, see streams' FLAC hint).
- The send is to everyone here (not only those with Jam on); a listener without Jam drops it, which wastes their bandwidth.

## Review-later (security)
- Messages are checked (names worked out by the receiver, sizes and counts bounded: 32 segments, rates 1-384 kHz, 1-16 bars, positions and
  frames bounded) and travel the signed direct link to the room's peers only. The stream is the link's existing one (16 GB cap).
- A peer can still make a receiver write up to an hour of WAV per run into its inbox (about 700 MB at 48 kHz); the inbox prune removes it
  once done. A per-peer rate/size budget for streams in general is worth a look.
- The jam folder in the link's inbox is cleaned at each new run (files whose stream finished); a crash leaves files until the next run.
