# The cloud copy's round that never ended, and the 331 ms drive step (rt-drive2, 2026-11-21)

After rt-perfcut1 (b9542db, deployed 03:35 as 0.59.49.79) the desktop's cloud copy partly caught up, then stalled again: no "Google Drive copy
up to date", `drive status` stuck at `{"more":true,"moved":7}`, "drive" the biggest step of every 10 s window's slowest tick (22-45 ms), and
one tick at 04:26:27 with drive at 331 ms on REAPER's thread.

## What happened (read from disk and ExtState on the desktop, then reproduced offline against the real folders)

Read-only: the worker's job folder (`%TEMP%/bandsync-drive-237df11a0c1a95e4`: `lists/`, `beat`, `owner`, the spawn files), file counts in the
studio folder and on `G:`, the day's log, and four ExtState/timing probes in REAPER (`<scratchpad>/rt-drive2/probe*_rt-drive2.lua`). Then a
dry-run of the repo's planner against the real studio folder and the real `G:` (lists and fetches into scratch, every write answered "no")
to see each unit and pass (`sim_rt-drive2.py`, `sim2_rt-drive2.py` there).

1. **03:54 to 04:52: the round read another song's changes for an hour, and nothing new of James's went up.** The worker's spawn files show a
   round every ~3.5 minutes until 03:54 (round, rest, round...). At 03:54 Cross Test's room unit finished; the next unit, `upkeep`, took
   Nostalgia (2,406 changes, 16 MB). The listing files say so: Nostalgia's ten room folders were listed again every 30-90 s until 04:51:51,
   Cross Test's not once from 03:54 to 04:55. (The "36-minute gap" in the listings was an artefact: each listing file is overwritten, and
   Nostalgia's kept being rewritten.) The 03:54 worker stayed up the whole hour (it idles out after 60 s without a job).
   - Reading a room's changes gets `drive.READ_MIN` (4 ms) a pass after its listing (REAPER here: 3 ms to list 2,406 names, 0.28 ms a change),
     and a pass plans only every ~2 s (Live sync's poll), only while no job is out and the transport is stopped.
   - Each pass read some changes, so `read_n` grew and the back-off never rested: it counts reading as something happening, by design.
   - `"moved":7` never changing did not count as movement (only a job's own `moved > 0` resets the count); reading did.
   - The open song's room, done at 03:54, wasn't looked at again until the round ended. The next round (04:55:25) sent up the 42 changes
     (Cross Test's James events: 2,189 here, 2,189 in the cloud since; the 213 still missing are James-Laptop's, which this computer
     correctly never writes).
2. **Since 04:52: the storage sweep never finished, so no round could end.** There is no ExtState `cloud storage` at all in this REAPER: no
   sweep has finished since it started. The round's last unit, `cm` (lib/cloudmodes.lua's sweep), only ran in what the rooms and upkeep left
   of a pass's 8 ms (usually nothing), and its reading wasn't counted as something happening. So each round planned 10 times, rested 3
   minutes, started again (the watch at 04:58-05:02: Cross Test listed, then `_tools` and the rooms list, then nothing). `drive status` stayed
   `more` for good and "up to date" was never said.
3. **The 331 ms.** When the sweep did get a turn (a pass whose units left a sliver of budget), a room of it ran to the end unbudgeted: four
   `trim.plan`s (80-200 ms each for a room with saved versions in Standard's 14-day window), an open of every file for its size (3,000-3,500
   opens, ~200 ms), every end-of-session project parsed (13-20 of them, 20-36 ms each). Offline against the real folders one call took 345,
   451, 645, 712 ms and once 5.7 s. Not `drive.root`'s 5-minute look (0.6 ms on G: here) or a listing parse (6 ms for 2,400 lines).

## The fixes

**lib/drive.lua (`drive.bg_step`)**
- **The open song's rooms again every `drive.SOON` (30 s) while the round goes on.** A room unit done (and not failed) is re-opened 30 s after
  it finished, so a long upkeep or sweep no longer holds your new changes back. A room done again doesn't count as something happening.
- **"Up to date" when the copy is, not when the sweep is.** `copied` = every unit but `cm` done and nothing out. Then `bg_step` returns
  `moved, false` once (Live sync writes the status without `more`, logs "Google Drive copy up to date (N files this pass)" when N > 0, and
  runs `sessionfile.catch_up`), and its moved count starts again from 0. The round carries on for the sweep, saying `more = false` unless a
  re-opened room moves files again (then "still copying" until it's done, and "up to date (N)" once more). The round ends when the sweep has
  finished too.
- **The back-off, as it now works.** A round rests (ends; the next waits `drive.EVERY`, 180 s) after `drive.STALL` (10) plans in a row with
  none of: files moved by a job, a unit finished for the first time, a change read, a step of the sweep (`cloudmodes.progress()`). A room
  done again or a status that never changes is not movement. "Nothing is moving though it isn't up to date" is said only while the copy
  isn't done (a stalled sweep alone rests quietly, and the rest reports `more = false` then).
- `read_events` keeps the listing it started from while a big folder is read over several passes (3 ms a pass here), then lists once more
  for what came meanwhile, so nothing that arrived during the read is missed (media deletes depend on that).

**lib/cloudmodes.lua (the sweep)**
- **A step at a time.** A room's sweep keeps its place in `sw.cur`: changes read (as before), saved versions read (now deadline-bounded),
  judged (a trim plan isn't started after the pass's deadline: `cm.LATER`, and the plans made are kept), then the files counted one by one
  against the deadline. End-of-session projects: asked for together, read and scanned one a step.
- **One cutoff per sweep** (`sw.cutoff`), so a plan made on one pass is the one the next pass finds (the cutoff had seconds in it: every
  pass made every plan again).
- **No trim plan where none can take anything**: `trim.plan` only ever takes changes older than the cutoff, so with none older the answer is
  empty without running it (all of the desktop's songs are younger than Standard's 14 days: the 80-200 ms plans are gone there).
- **The cloud copy judged once when it has every change of the room** (same records, same answer).
- **Sizes from the worker's listing** in a planned pass (free), the studio folder's file only for what the cloud copy doesn't have.
- `cloudmodes.progress()` counts the sweep's steps for the back-off.
- `read_events` keeps its listing while a folder is read over several passes, as drive.lua's.

**lib/sessionfile.lua**: `sessionfile.each_file(text, fn)`, the FILE paths of a project without rebuilding its text (13-15 ms instead of
20-36 ms a project), for the sweep.

Offline, against the desktop's real folders (dry run): the whole sweep is now ~200 passes, the slowest 36 ms (was one call of 345 ms to
5.7 s); a whole round from a fresh start read Nostalgia in ~170 passes at ~8 ms each, re-opened Cross Test every ~34 s, said "up to date"
when the copy was, and ended normally once the sweep finished, never resting.

## Tests (tests/test_0_60_rt_drivebg.lua), each failing without its fix (checked against the old files)

- **3d** a round whose other song is never done (and reads every pass): a change made in the open room after it was done goes up within
  `SOON` + 10 s, in the same round. Old code: never.
- **3e** a round whose storage sweep takes 40 passes: "up to date" is returned while the sweep goes on, with the files moved (≥ 10), not taken
  back by the room looked at again; the round ends after the sweep without resting or saying it rested. Old code: `more` until the end,
  and it rested after 10 plans.
- **3f** the real sweep with stand-in costs (a trim plan 50 ms, a change read 1 ms) and three kept saved versions older than the window: no
  pass over its budget plus one trim plan (old: 201 ms in one pass), and the sums (stored, would, drop, kinds, essentials) the same as the
  whole sweep in one go the old way. `each_file` finds the same paths as `map_files` (quoted, unquoted, CRLF, tab-indented, not `XFILE` or
  `<FILE`).

`python tests/run.py --no-luals`: in the report (run in a clean clone of the commit).

## Per-lap perf stats (rt-perfcut1's "Left" list, finished; a second commit)

- `StudioSync - Live sync.lua` (small, additive; the only uncommitted lines in that file were rt-perfcut1's, committed with these):
  `perf.laps`, `sub_lap`, `laps_add`, `laps_table`, `laps = laps_table(perf.laps)` in "tick stats", the reset, `laps_add` at the tick's end
  inside `if perf.on` (rt-perfcut1's lines), and 17 `sub_lap("start/...")` lines in `tick_body` before `lap("start")`, one after each
  sub-tick (lock and follow file, plug-ins and takes, shared prefs, calibrate, clip and together, link, controllers, signed, needlist,
  ablink, liveaudio, hops, claimask, webui, hub, bounces, follow). With perf stats on, "start" is then only the transport ExtState part.
  Off, a sub-lap is one comparison.
- `tests/reaper/rt_perf.lua` prints each tab's laps over the 10 s: total ms (/ 100 = % of one core), ticks, worst ms, the 12 largest.
- `tests/test_0_60_rt_perfcut1.lua`: `laps_add`/`laps_table` loaded from the file's text (totals, ticks, worst, order, rounding); every
  `sub_lap("start/...")` inside `tick_body` before `lap("start")`; `laps_add` called once, inside `if perf.on`; published and reset.

## REAPER checks for James (desktop, once deployed)

1. Cross Test open, Live sync running, `tests/reaper/rt_perf.lua` on: within a few minutes of the first round the log says "Google Drive copy
   up to date (N files this pass)" (or, with nothing to send, `drive status` loses `more`), and ExtState `cloud storage` appears within
   ~10 minutes (the first sweep reads every song's changes, a few ms a pass).
2. Make a change in Cross Test while the round is still busy (right after a start): it reaches
   `G:/My Drive/StudioSync - Smiley Studios/Cross Test/rooms/main/events` within about a minute.
3. The slowest ticks: "save, drive" mostly under ~15 ms, the worst under ~40 ms (a big change read, a listing parsed); no 100+ ms drive step.
4. `%TEMP%/bandsync-drive-*/lists/`: Cross Test's room folders rewritten every ~30 s while a round lasts; between rounds, quiet.
5. The log never says "nothing is moving though it isn't up to date" while the copy is actually up to date.
6. `tests/reaper/rt_perf.lua` shows "laps over 10 s" per tab, with `start/...` rows: which sub-tick owns the start lap.

## Left / not done

- **`trim.plan` itself** (lib/trim.lua, not mine) is 80-200 ms for a 2,500-change room with ~180 saved versions in Standard's window
  (its saved-versions loop is points x changes). The sweep now makes at most one per pass and skips the ones that can't take anything, but
  a studio older than its window still gets one such step per plan, a few per sweep, every 10 minutes. Caching judgements across sweeps for
  a room whose changes didn't change, or a faster trim.plan, would remove them.
- **`cm.filter`** (drive.mirror's filter in Essentials/Standard) still judges a room in one go each time the room's change count moves:
  not the desktop's case (Everything), but a 100-300 ms step in those modes.
- A room's first full planned pass (all its folders, listings parsed) is still 30-55 ms; reading big single changes can make a pass 20-30 ms.
- `sessionfile.catch_up` still copies on REAPER's thread when it has pending recordings (empty on the desktop: `session_media <song>` is
  `[]`); it now runs whenever the copy is up to date, which it never was before.
- Why Nostalgia's read took an hour on the desktop rather than the ~6-20 minutes its numbers give is not fully explained: likely the transport
  running (no planning while it plays) for part of it. The re-opened rooms make it harmless to the open song either way.

## Review-later (security)

None new: the worker, plans and the sweep's removal rules are unchanged (removals still only of the cloud folder, by the same judgement).
