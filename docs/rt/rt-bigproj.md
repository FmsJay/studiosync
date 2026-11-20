# Bigger projects (rt-bigproj)

James's request: "Make sure no issues with bigger projects - lots of tracks plugins and items and midi plus long (5 minutes at least)".

Built:
- `tools/bigproject.lua`: a seeded generator for one big test project. It writes REAPER's own `.rpp` text and the track and item chunks the
  offline harness serves. Pure Lua 5.4.
- `tests/fixtures/bigreaper.lua`: a fake REAPER that serves that model. It counts every API call and the bytes the chunk calls hand back.
- `tests/test_0_60_rt_bigproj.lua`: Live sync's costs at that size, with budgets. It fails when a tick goes over budget.
- `tests/reaper/big_project.lua`: writes the project on a real computer and opens it. Run again, it times what REAPER itself does for
  StudioSync at that size.

## The project

`G.model()` defaults:
- 150 tracks: 10 folders and 4 FX returns, with 12 sends into the returns.
- 520 plug-ins: stock JSFX, plus every 4th one a stand-in VST holding a 16 KB saved state (130 of them).
- 4,000 items over 7 minutes. 60 of them are MIDI, with 72,000 notes and 36,000 CC.
- Automation: a volume envelope on every track, pan on every 3rd, a plug-in knob on every 10th (25,800 points in all).
- 50 regions, 20 markers and 4 tempo changes.

The `.rpp` is 7.3 MB. Every audio item plays one 10 s silent WAV, looped, that the script writes beside the project, so nothing is offline.

Any option can be changed, e.g. `G.model({ tracks = 300, items = 10000 })`. The same options make the same bytes on every computer.

## Measured offline (fake REAPER, Lua 5.4 through lupa, this desktop while other agents were busy)

A fake API call costs next to nothing, so the REAPER call counts below are the real-cost hint. Each one is roughly 0.3 to 1 µs in REAPER, and
a chunk call costs REAPER serialising every plug-in's state on that track.

| Work | When | Before | After |
|---|---|---|---|
| Project page look (dawview read + build + publish), page open | each change-count move, up to 4 a second while editing | **~60-80 ms in one tick**, 54,600 calls | the same work, spread at **3 ms a tick** (`dawview.SLICE`); first look of 862 KB of topics over ~60-90 ticks |
| Mixer page strips | every 0.25 s while it's open | read 2 ms + **4 ms JSON every time**, even with nothing moving | JSON only when the mix changed (`webmixer.same`): idle tick p95 13 → 4-6 ms |
| mirror.hash of a changed long text (root's 290 KB list, big plug-in chains, MIDI items) | each look and pass, on anything changed | 9 ms per 300 KB | 2 ms per 300 KB, the same hash (`mirror.fnv`) |
| catch-up sort of pending events | each pass while catching up | ~100,000 joined strings a pass at 4,400 events | keys made once (same order) |
| a tick, nothing changing (controllers, follow, recap, Project page and Mixer open) | every tick | | median ~1 ms, p95 4-6 ms, 2,173 calls |
| a tick while editing (an edit every 8 ticks) | every tick | p95 dominated by the 60-80 ms looks | median 4 ms, p95 9-15 ms |
| look (mirror.watch), nothing changed | on change, 10 s floor, at most 1/5 of the time | 150-200 ms, 144,000 calls, 7.3 MB of chunks | unchanged (see "Left as it is") |
| look after one item move / one MIDI note | | 150-300 ms, 1 change out | unchanged |
| scan alone, nothing changed | inside the look | 60-120 ms, 52,600 calls | unchanged |
| first look, everything out (4,154 objects) | once | 2.5-4.8 s in one pass | unchanged (the real Live sync sends a quarter second a pass) |
| mirror.root | each pass | 12-37 ms, 4,756 EnumProjExtState | 12-18 ms (hash part faster) |
| colour parity's look | every 5 s, in a pass | 17-35 ms, 29,500 calls | unchanged |
| controllers.tick + settle | every tick with a peer here | 0.25 ms, 1,218 calls | unchanged |
| note_open_fx | every second | 0.2 ms, 1,500 calls | unchanged |
| late joiner, 4,457 events (files in memory, apply stubbed) | catch-up | 80-90 ms to read and pick the newest | the same; a caught-up pass 1-2 ms |
| Lua memory after all of it | | ~100 MB | the same (the memo keeps up to twice 64 MB of text between looks) |

The test's budgets with `SS_TIMING_STRICT=1` (default; `0` or `CI` set means 4x):
- idle tick: median ≤ 2 ms, p95 ≤ 15 ms, ≤ 2,500 REAPER calls
- editing tick: median ≤ SLICE + 3 ms, p95 ≤ 30 ms
- warm look ≤ 600 ms, look after one edit ≤ 800 ms
- mirror.root ≤ 60 ms, colour look ≤ 60 ms
- caught-up pass ≤ 20 ms
- Lua memory ≤ 400 MB

`os.clock` only steps in milliseconds on Windows, and the p95 of a shared machine is noisy, so medians and call counts are held tight and p95
loosely.

The test also checks that the changes behave as before:
- `mirror.fnv` matches the plain byte loop at every length.
- A Project page look spread over ticks publishes byte for byte what one tick did.
- Tracks deleted while a look is paused cause no error, and the next look is right.
- An unchanged mix isn't handed over again, and a fader moved without an undo point still goes out.
- One edit sends exactly one change, and a late joiner gets the newest of each object once.

## Changes, all behaviour-preserving

1. **`lib/dawview.lua`**: `dawview.tick` runs the look (read, build, publish of changed chunks, then the header) in a coroutine.
   - `pause()` hands the tick back between tracks once `dawview.SLICE` (3 ms) is spent.
   - No REAPER pointer is held across a pause: each track is fetched again by its index.
   - After a pause, a closed tab or deleted tracks end the read. The change count kept from the look's start then makes the next look follow.
   - Outside the coroutine (tests, direct calls) nothing pauses.
   - The chunks still go before the header.
2. **`lib/webmixer.lua`**: the strips build compares the new mix with the last one sent (`same`, value for value) and only then hands it to
   `publish`. Before, it was JSON-encoded every 0.25 s only for `publish` to find it equal.
3. **`lib/mirror.lua`**: FNV-1a reads eight bytes a call and masks once at the end. The low 32 bits of a wrapping 64-bit product depend only on
   the low 32 bits of its operands, so it gives the identical hash, and `HV` doesn't change. `mirror.fnv` is exported for the test.
4. **`lib/sync.lua`**: `sync.receive` makes each pending event's sort key once.

## Left as it is (found, not changed: a design change or a behaviour change)

- **The look is the big one at this size.** Each look asks REAPER for every track's chunk (7.3 MB here, with every plug-in serialising its
  state) and does ~150-200 ms of Lua with 144,000 API calls. It runs on any change, at most a fifth of REAPER's time, with a 10 s floor.
  - On a real big session with heavy plug-ins, expect a stall of a few hundred ms to over a second after each edit.
  - Spreading the look over ticks would need it to tolerate a project changing mid-snapshot (it writes oids and puts back refused edits).
    That is a redesign, not a tweak.
  - Measure it first: `big_project.lua` gives "every track's chunk" and rt_perf gives the slowest pass and its laps.
  - A cheaper per-track change detector would need REAPER to tell which tracks changed. Its API has only the project's change count.
- **colour parity's look** walks every item's and take's colour (29,500 calls) every 5 s inside the pass. It could follow the change count, but
  colours set by scripts without an undo point would then be missed.
- **mirror.root**: in REAPER, `EnumProjExtState(i)` may cost O(i), which would make root quadratic in objects. `big_project.lua` times it.
  A cache keyed by the change count would miss ExtState written by other scripts (the panel's Restore, Undo) and undo.
- **The Mixer's strips** are still read every 0.25 s (2 ms, 4,200 calls). Faders moved by automation or a bandmate's controller don't move the
  change count, so the read can't follow it.
- **The Project page's look** is now spread over ticks, but its total work is the same: ~12% of REAPER's time while editing continuously at this
  size. Cutting the work itself needs a per-track change signal REAPER doesn't give.

## REAPER measurements to run on the real computers

On each of desktop, laptop and Mac, with the extension loaded:

1. **Make the project.** In REAPER: Actions > Show action list > New action > Load ReaScript...: `tests/reaper/big_project.lua` from the repo,
   then run it.
   - It writes `<resource>/StudioSync/tests/bigproject/StudioSync Big Test.rpp` and the WAV, and opens the project in a new tab.
   - Close REAPER's missing-plug-in list: the 130 "StudioSync Big State Test" stand-ins keep their data.
   - Note how long REAPER took to open it.
2. **What REAPER itself costs.** With that tab in front, run `big_project.lua` again. It prints these (all read-only):
   - every track's chunk (ms, MB, the slowest track): the floor of every look
   - every item's chunk
   - GetProjectStateChangeCount
   - every track's fader, pan and mute (controllers' per-tick read)
   - mirror.root, which says whether EnumProjExtState is linear
   - the Project page's whole look (first, with peaks, then warm)
   - the Mixer's strips
   - colour parity's look
   - this script's memory

   Before step 3, the numbers for mirror.root mean little, since Live sync hasn't recorded anything yet. Run it again after step 3.
3. **Live sync on it.** Save the tab, then publish it into the test studio (StudioSync panel > publish, as for any song) on the desktop, and
   open it on the laptop and the Mac.
   - Time the publish, and the laptop's and Mac's catch-up: the 4,000+ events arriving, from the first "change(s) came in" line to Health
     green.
   - Then run `tests/reaper/rt_perf.lua` once on each computer (it switches the timings on).
   - Wait 20 s idle and run it again. Record tick median/p95/slowest, pass median/p95/slowest and the slowest tick's laps.
4. **Editing.** With timings on:
   - Move one item, then nudge 50 items at once, then edit one MIDI note in the piano roll, then turn one plug-in knob.
   - After each, wait 10 s and run rt_perf.lua. Record the slowest pass (the look's lap "look") and how long until the other two computers
     showed the change.
5. **Playing.** Play from the start for 2 minutes with all three computers in, then run rt_perf.lua.
   - Record tick p95 and slowest, and whether audio dropped out (REAPER's performance meter: xruns).
6. **Pages open.** On the desktop, open the web UI's Project page and Mixer (phone or docked), edit for a minute, and run rt_perf.lua.
   - Record tick p95/slowest. The Project page should fill in within a second or two and follow edits within about a second.
   - Open the piano roll on a MIDI item and the automation lanes, and check they draw and edit.
7. **Late joiner.** Close the song on the Mac, delete its local copy (panel > Delete my copy), and join again. Record how long until it's
   complete (Health green), and the slowest pass during it.
8. **Memory.** After all of this, note REAPER's memory (Task Manager / Activity Monitor) on each computer, and again after 30 minutes idle with
   the song open.

Send the printed lines from steps 2-7. The offline harness gives the same figures for comparison (`python tests/run.py --no-luals`, the
`bigproj:` lines).

## Untested

- Nothing here has run in REAPER. The dawview slicing, webmixer comparison, faster hash and catch-up sort were only tested offline.
- Applying the events in a late join (SetTrackStateChunk / SetItemStateChunk at this size) can't be timed offline. Step 7 measures it.
- Real plug-ins serialising big states inside GetTrackStateChunk are the unknown that matters most. Step 2 measures it with stand-ins (REAPER
  keeps a missing plug-in's data as text, which is cheaper than a real synth serialising), so a real heavy session will be slower.

## Review-later (security)

- None new. The generator and fake REAPER are test-only.
- `big_project.lua` writes only under REAPER's resource folder, and reads only when measuring.
- No received data is parsed differently: the hash gives the same values, and the catch-up keeps the same order.
