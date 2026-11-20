# Keep a full-quality copy: the double-ender (rt-double, 2026-11-20)

Roadmap "More big ideas" 7: everyone records their own part in full quality during a jam, and the lossless takes go into the song afterwards,
lined up by the shared clock, so the jam becomes a real multitrack session.

Tested with stand-ins only: Lua tests, the native capture test, `direct_audio.cpp` compiled with the REAPER build's flags. **Not run in REAPER
yet.** The full Windows DLL build currently stops on another agent's uncommitted `nat.cpp` (line 1986), not on this work.

## What existed already
- **Jam** (`lib/jam.lua`, rt-jam) captures each person's live audio **Play feed** per run: the armed tracks after their FX, mixed to one
  16-bit stereo WAV, streamed to the others and played an interval late on hidden local tracks, then deleted. It's for hearing, not keeping:
  lossy (16-bit), mixed (not per track), post-FX, and never placed in the project.
- **Recording while jamming** works: pressing Record instead of Play puts REAPER's own takes in the song. That needs everyone's transport in
  Record, streams each take as a placeholder during the jam, and does nothing for a live jam with no transport.
- **Phone and browser takes** (`lib/phonerec.lua`) place an outside recording by the link clock against this computer's play readings. The
  same idea, but for one take recorded while this computer plays the song.
- Nothing recorded each person's input locally and losslessly during a live jam. That's what this adds.

## What it does
- **Settings > Options, under Jam:** "Keep a full-quality copy of my part while we jam or play live" (this computer's, ExtState
  `keep full copy`).
- **While it runs**, the panel's top bar shows a red **Recording your part in full quality** button. Its tooltip names the tracks, the time so
  far and who else is recording; clicking it adds your part now. Settings and Health show the same, plus any armed track that isn't copied.
- **When:**
  - with Jam on: from play to stop;
  - otherwise, while live audio runs (transport or not), with someone on the direct link.
- **It stops and lands when:**
  - the transport stops after playing;
  - live audio stops;
  - nobody has been on the link for 10 s (a computer that drops out lands its part up to then, on its own computer);
  - the switch goes off;
  - you click the top bar's button;
  - Live sync ends.
- **Nothing goes into the project before then.** A file nearing 3 GB, a change of armed inputs, a failed writer or a new device rate only
  start new files; every file lands together at the stop.
- **Afterwards**, a blue button shows for a minute, for example **3 parts added, lined up** (tooltip: "yours: Gtr; Ann: Vox; Bob: Bass").
  It counts your own parts plus the others', from the `done` message each computer sends. The log has it too.

### Recording: the extension's tap, not a REAPER recording (and why)
`StudioSync_KeepStart(spec)` in `extension/direct_audio.cpp` installs its own audio hook. Before REAPER's processing, it copies each armed
track's **raw hardware input** (what REAPER would record from that input) into 32-bit float WAVs, **one per track** (mono, or the stereo
pair), in `<record path>/StudioSync full quality/`.

Each block carries this computer's link clock (`direct_now`) and REAPER's play position and state, all read in the same hook call. A block that
doesn't follow on starts a segment `{ file frame, clock, playing, position }`: the first block, play or stop, a seek or loop while playing
(more than 20 ms off), or a dropped block. The audio thread allocates nothing, locks nothing and writes no file. The worker rewrites each
header every second, so a computer that dies mid-jam leaves files readable up to then.

Why not REAPER's Record:
- A live jam often has no transport running.
- Record would change the jam: Record together for everyone, In time streaming each take as it grows, and REAPER putting items into the
  project at its own position, which would then need moving.
- The tap gets the shared-clock stamp in the audio thread.

What Record does better, and the gap this leaves: **tracks recording MIDI or their own output (instruments) aren't copied.** The UI says so
for each one ("Keys records MIDI or its own sound (REAPER's Record keeps those)"). ReaRoute/loopback and multichannel inputs aren't copied
either. The limit is 16 tracks or 32 inputs per copy.

### Lining up
Placement is per segment, in `double.place`. "Offset" below is REAPER's input manual offset, which `lib/calibrate.lua` sets from its
measured loopback.
- **Played with the transport:** the segment goes at its song position less input latency + output latency + offset. That's what REAPER
  takes off a recording, so every part sits on the bars it was played to (Jam's intervals included, whatever each computer's latency).
- **Without the transport:** the segment goes by the studio's shared clock (`direct.shared_now`; the link clock's offset is read as each
  segment arrives). Its position is anchor position + (segment time − input latency − offset − anchor time).
- **The anchor** `{ shared time, project position }` is the earliest start any computer in the jam reports. Each computer sends its anchor
  every 2 s in a `double` message and takes the earliest it hears; on a tie, the name decides. The anchor's position is the song position
  it started at, or, with no transport, the first bar line at least a bar past that computer's project end, so a live jam never lands on top
  of the song.
- Other rules:
  - a loop gives each pass its own item at its bars;
  - a dropped block keeps its gap;
  - anything before the project's start is trimmed;
  - the moment between a stop and the copy's end isn't placed;
  - a computer with no shared clock places by its own clock, and the summary says so.

### Media and lanes
- **Media:** each part is an ordinary new item (named "Jam 14:05 - Ann (full quality)") on the track it was recorded from, in one undo point.
  `mirror.touch` tells the next quick look (rt-look), so it goes out as any new item does: `lib/streams.lua` offers the file over the link
  at once, and Syncthing keeps the record. No new media path.
- **Claims:** a track the user may not change at that position (`sync.authority`) isn't written. The summary says "not added: Locked isn't
  yours to change here (the file: ...)" and the file stays on disk.
- **Lanes:** the jam's live and interval audio was never in the project: Jam's items are local and go at the stop, and live audio is never
  recorded. So the lossless parts simply land. Where the track already has something there (a take recorded during the jam, or the first
  pass of a loop), the part goes on **a new lane at the bottom that doesn't play** (the comp stays), the way `prints.takes_into_new_lanes`
  does it. That happens while the studio's "Takes become lanes" is on. Off, the part goes in beside what's there, as REAPER would.

## Files
- `lib/double.lua` (new): everything Lua. Pure parts: `inputs`, `spec`, `place`, `cut_tail`, `pick`, `wanted`, `valid`, `summary`,
  `running_text`. Then the run (chunks, poll, land), messages, and the panel, Settings and Health pieces, which read Live sync's state
  through ExtState `double state`. "Add it now" goes through ExtState `double land`.
- `extension/direct_audio.cpp` + `direct.h` (additive): `direct_keep_start/stop/status/feed`, its own hook `on_keep_audio`, and ReaScript
  `StudioSync_KeepStart(spec)`, `StudioSync_KeepStop()` and `StudioSync_KeepStatus()`, added to `stop_all`.
- Small additive hooks in shared files:
  - `StudioSync - Live sync.lua`: the `double` handler, `double.tick` after `jam.tick`, `double.on_exit` after Jam's;
  - `StudioSync - Panel.lua`: `double.options` after `jam.options`, and `double.bar_ui` after live audio's in the top bar;
  - `lib/page_health.lua`: `double.health_rows` before Jam's row;
  - `.github/workflows/extension.yml`: `tests/keep_test.cpp` in the paths and a step in both jobs.
- Tests:
  - `tests/test_0_60_rt_double.lua`: the pure parts, then whole jams with stand-ins (see the file's head);
  - `tests/keep_test.cpp` + `tests/build_keep_test.cmd`: native, the capture without REAPER.

## Needs a new extension
`StudioSync_KeepStart` comes with the next extension build (EXT_WANT not bumped). Without it, Settings and Health say "needs a newer StudioSync
extension" and nothing else changes. At release, `lib/files.txt` needs `tools/make_index.py` because of the new `lib/double.lua`.

## REAPER checks for the real computers
1. Build and install the extension; restart REAPER. In the console, `reaper.StudioSync_KeepStatus()` returns `{"on":false,"state":"none",...}`.
2. Desktop and laptop in one song, live audio on, direct link up. On both: Settings > Options > tick "Keep a full-quality copy...". Each arms
   one audio track (desktop a stereo input, laptop a mono mic).
   - The top bar turns red: "Recording your part in full quality".
   - The tooltip names the track and says "<the other> too".
   - Nothing appears in the arrange view.
3. **Live, no transport:** play together for about 30 s, with a few loud claps that both mics hear (or one person counting on Talk and both
   playing a hit on each count). Then both press the red button, or turn live audio off.
   - Each computer gets one item on its armed track, in "StudioSync full quality".
   - After a few seconds each has the other's item too.
   - Both sit a bar past the song's end.
   - The claps line up across the two items. Zoom in and **note the offset in ms**: it measures the shared clock plus input-latency
     correction.
   - The blue button says "2 parts added, lined up".
4. **Jam with the transport:** tick Jam on both, press Play together, play to the click for 8 bars, stop.
   - Each part lands on the bars it was played on. Check one hit against the grid on each computer and **note the ms**.
   - The items are 32-bit float WAVs (Source properties).
5. **Loop:** loop bars 1-4, jam two passes. With "Takes become lanes" on: the second pass is on a new lane that doesn't play; the first plays.
6. **MIDI or instrument track armed:** Settings and Health say "not copied: Keys records MIDI...". Its notes aren't lost if Record was used.
7. **Drop out:** three computers live; pull the network on one for over 10 s. That computer lands its part right away, and the other two get
   nothing in their project until they stop. Once the network is back, its part reaches them as a normal new item.
8. **Mid-jam safety:** during a 2-minute jam, Edit > Undo history shows no StudioSync entry until the stop. Then "StudioSync: full-quality
   parts from the jam" appears, once.
9. **Long run (optional):** a 30-minute live jam. The files grow on disk while it runs (header updated each second), and REAPER stays smooth
   (Health's audio rows show no xruns from the hook).
10. **Mac and Linux:** steps 2-4 at least (the hook and the float writer on SWELL builds).
11. **Exit mid-jam:** close Live sync while recording. The part lands as it stops.

## Untested / limits
- Nothing ran in REAPER. Unverified assumptions:
  - the hook's pre call gives this block's play position (rt-jam assumes the same);
  - `direct_now()` at the pre call minus REAPER's reported input latency (plus the offset) is when the first sample hit the converter; the
    block-start jitter is at most a block;
  - `GetInputOutputLatency` and the input offset match what REAPER takes off its own recordings.
  Checks 3 and 4 measure these.
- No drift correction: the stamp is one per stretch, and after that it's sample counting. Two interfaces 20 ppm apart drift about 7 ms over
  5 minutes. (shortcut: one clock stamp per stretch. Upgrade: stamp every second and set each item's play rate from the fit.)
- Play rates other than 1 start a segment on every block, which places them correctly but splits them into many items.
- MIDI and instrument tracks aren't copied (see above). The input is taken as REAPER's input setting gives it; REAPER's forced mono or stereo
  isn't applied.
- Mono and stereo files only; each file stays under 4 GB (a new file every ~3 GB; float stereo at 48 kHz is about 2 h 10 min).
- A no-transport jam's anchor position depends on the anchoring computer's project end at that moment. If projects differ (mid-sync), the
  others still land relative to it, which is consistent, but not necessarily a bar past their own end.
- The summary counts others' parts from their `done` message within 60 s. A computer that dropped off isn't counted on the others, though
  its part still arrives.

## Review-later (security)
- `double` messages travel the signed direct link and are checked: run id characters and length, a user name that's a plain segment, an
  anchor time of 1e9-1e10 and position of 0-1e6, at most 16 track names of 120 bytes, and parts as a whole number 0-1000.
- A peer can still move where **this** computer's no-transport parts land: an early, plausible anchor wins. Worth tying anchors to peers
  actually in the room's live audio session, or bounding them to the run's own time span.
- Peer-supplied track names appear in the summary and the log (bounded, and shown as text only).
- Files go in the project's record path. The track and song names in the file name are reduced to `[%w%-_ ]`.
