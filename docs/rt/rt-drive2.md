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

## Round 2 (after the desktop's checks on 0.59.49.80)

All checks passed except 5: "nothing is moving though it isn't up to date" still appeared at 05:34:42, 05:49:30 (36 s after "up to date
(12 files)") and 06:10:27, with `drive status` `{"moved":0}`.

**Cause.** After "up to date" the round goes on for the storage sweep. 05:34 was during the first sweep after the reload (it finished
~05:38), and 05:49 and 06:10 during the next sweeps (one every 10 minutes). A sweep waits on listings: plans that need one only send a job,
and plans where the open room's 30 s look used the whole budget give the sweep no turn. Ten such plans in a row and the round rests, which
is fine. But the log's condition was "the copy units aren't all done", and a room re-opened for its 30 s look is not done while it waits for
its listings. A rest that fell on that look logged the line.

**Fix (`lib/drive.lua`, `lib/drivebg.lua`).** The line, and the rest's `more`, now go by `behind`: not up to date yet this round, or files
moved since "up to date" was last said, or a copy that failed and hasn't gone since. The worker's results now list each copy or move that
failed and each that went (`failed`, `wrote`); a failed one stays failing until the same target goes. A bandmate's change still arriving
("not whole yet", left for later as before) doesn't count. A room looked at again, or the sweep waiting, isn't behind.

**Test 3g.** From a settled copy, a round whose sweep makes progress for k + 6 plans and then waits, for every k from 0 to 20 (so the rest
falls at every point of the room's 30 s look): it rests, the rest says up to date, and the line is never logged. The old drive.lua logs it
at k = 2. And a copy that keeps failing (a new change the stand-in worker can't copy): the rest says not up to date and the line is logged
once.

**`reaper_studiosync.dylib` "changed while it copied" (05:27:18).** The deploy rewrote `_tools` (05:24:58-05:25:01) while a round was copying
the update files to the cloud. That copy retries by itself: the next update-files pass (every `drive.EVERY` = 180 s, in a later round)
checks the cloud's copy against its signature again. A copy with one file wrong doesn't check, so it goes "out" again with the files that
differ. On the desktop the cloud's dylib was rewritten at 05:37:58, and all 150 files in `lib/files.txt` are now byte-identical between the
studio folder and `G:`. Meanwhile no member could have taken the half copy, because "in" needs a copy that checks as signed. No fix needed.
Its "couldn't copy" line is logged once per file per session, so a retry that fails again is silent (as before).

REAPER check after deploy: over an hour with edits and sweeps (`cloud storage` `at` moving every ~10 minutes), the log has no "nothing is
moving though it isn't up to date" unless a "couldn't copy ..." line came before it in that round.

**"Google Drive: bringing the studio's copy of this room up to date" only with something to send (follow-up commit).** Live sync logs it
when a pass result says `more` after one that didn't. It came at the first job of most rounds, every 30 s to 3 minutes, because a new round
said `more` until its first check was done.
- Now `more` (outside a rest) means work: files moved since "up to date" was last said, a copy unit put write steps into a plan since the
  copy was last done (`drivebg.pending()` before and after each unit; the sweep's removals don't count), or a copy that keeps failing.
- A round with nothing to send says `more = false` throughout. Its status is written as up to date and the line isn't logged.
- A bandmate's cloud change the worker found "not whole yet" isn't planned again until its size or time in the listing changes. That's how
  the old pass left it for later. Planned every pass, it made every look "copying"; it comes as soon as it's whole.
- Test 3h, from a settled copy, using the same Live sync rule (a false-to-true change of `more` counts as one log line): a quiet round logs
  it 0 times, a round with one new change once, the next quiet round 0. The half-written change comes once it's whole. The old code logs it
  in the quiet round.
- Tests 3b, 3e and the stand-in pass helper now read a pass as over when its round is (`more = false` alone no longer means the round has
  done its work).

## Round 3 (the round 11 recheck on 0.59.49.82, after the desktop's REAPER restarted at 07:33)

### 1. One drive step of 970 ms at 07:39:25 ("StudioSync 0.59.49.82 is in the Google Drive copy")

**Cause.** After a restart the update-files unit (`drive.tools_pass`) has no memo, and one plan ran it all on REAPER's thread. Measured
there, read only (`probe7_rt-drive2.lua`):
- `band.signed_ok` of the studio's copy costs ~270 ms: the extension's SHA-256 check (`StudioSync_VerifyFiles`) 77 ms, plus every code file
  hashed in Lua (`band.code_files`) 191 ms.
- The pass made three of these: the studio's copy and the cloud's staged copy (to choose the way), and the copy about to go.
- It also read every listed file twice to compare (4 MB, ~30 ms).

**Fix (`lib/drive.lua`).**
- Planned, the way is chosen with the extension's check alone (`drive.verify`: signature plus every listed file's SHA-256). The full
  `band.signed_ok` still runs, and must pass, before anything is copied.
- One such heavy check per plan. Once it's spent, `drivebg.NEED`: the unit is planned again next pass and keeps what it has done (the
  memos, and the tools_at restore that was already there).
- The code files for the full check are hashed `drive.TOOLS_STEP` (8 ms) a plan, then passed to `band.signed_ok(src, key, now)`.
  - Hashes from earlier plans count only while lib/files.txt and the code files' names are the same, and they're used once.
  - A file changed after it was hashed fails the check (its hash no longer matches the signed list); it never passes.
  - Each file hashed counts as something happening for the back-off.
- The destination's listings are asked for **before** the hashing. Asked after it, they were 30 s old again by the time the hashing was done:
  test 3j found that livelock.
- Direct mode (the fallback on REAPER's thread) is unchanged.

**Test 3j.** Stand-in costs: the extension's check 77 ms, 2 ms a code file, 100 code files. The owner's new version goes out whole and is
logged, and no plan exceeds one extension check plus ~15 ms. The old way: 554 ms in one plan.

### 2. The drive lap at 40-117 ms of every 10 s from 07:41 to 07:46, `cloud storage` empty

**This was the first sweep after the restart.**
- The floor in every window is ~40 ms: 5 passes × the 8 ms the plan is given.
- The sweep was reading every change of every song (~5,000) a few ms a pass. The copy (rooms, other songs) parses the same files first,
  and each kept its own record, so every change was read and parsed twice.
- `cloud storage` appeared at 07:50:35 (probe6), 17 minutes after the restart. After that the round ends; perf stats were already off by
  then, so I couldn't measure the steady state (rt-perfcut3's table: 7 ms per 10 s).
- It recurs after every restart, not in between: later sweeps re-read only new changes.

**Fix.** Each change is parsed once:
- `drive.lua`'s `read_events` hands the parsed file to `cloudmodes.note`.
- The sweep's `read_events` hands its parse of a studio-folder change to `drive.note_event`, whichever reads first.
- An upload's validity check doesn't read again a change already read whole (events are written once).
- That halves the parsing after a restart, so the first sweep should take about half as long.

**Test 3k.** A round with the sweep: every change of the room is parsed exactly once. The old code parsed all 40 twice.

### 3. "Google Drive copy up to date (1 file this pass)" 70 s after an edit, with no "bringing ..." line

**The expectation was wrong, and the line was inconsistent.**
- The "bringing" line ("carries on between passes") is meant for a copy that takes more than one pass.
- In round 2, `more` said "work" as soon as a plan held writes. That only reached Live sync when the planning pass also collected a job's
  results:
  - it did in the stand-in, whose room plan always followed a listing job;
  - on the desktop the copy planned on a pass without results, and the next pass's results finished it, so only "up to date" was said.
- Now `more` means files moved with more still to plan, or a copy failing. So a copy done in one job says only "up to date (N files)", and
  one spanning jobs says "bringing" once, then "up to date (N)".

**Test 3h (updated).** A quiet round logs nothing. One change copied in one job: no "bringing", one "up to date (1)". 250 changes (more than
a job holds): one "bringing", one "up to date (250)". The round-2 code says "bringing" for the one-change round.

### REAPER checks after deploy
1. After a restart (or a new version deployed), no drive step over ~100 ms. The update files go out over a minute or so of passes, then
   "StudioSync <v> is in the Google Drive copy".
2. `cloud storage` appears in about half the 17 minutes after a restart. During that time the drive lap is ~40 ms per 10 s; afterwards it's
   back near rt-perfcut3's 7 ms.
3. An edit: "Google Drive copy up to date (1 file this pass)" alone. A big copy: one "bringing" line first.

## Round 4 (the round 12 measurement on 0.59.49.83, after a restart at 08:08:50)

### 1. Drive steps over 100 ms: 118 ms (08:12:08 window), 176 ms (08:13:07), 201 ms (08:25:58)

- **118 ms and 176 ms: the update-files unit.** The 77 ms extension check ran in a plan that had already spent its time.
  - Hashing the code (8 ms a plan) ends on whichever file it's on, and band.lua and mirror.lua are ~200 KB each: ~20 ms in Lua. The heavy
    check then ran in the same plan.
  - At 08:13:07 the full check was followed in the same plan by reading all 150 files twice to compare them (4 MB each side).
- **Fix:**
  - A heavy check only runs in the first 4 ms of a plan (`drive.HEAVY_BY`, from `drive.plan_t0`). Otherwise `drivebg.NEED`, and the next
    plan does it first.
  - After the full check passes, the copy is compared and its copies planned a few files a plan (`sending`, `drive.TOOLS_STEP`), in those
    plans' jobs. lib/files.txt and its signature still go last, so a copy half across never checks as signed.
  - Each update-files plan is now the 77 ms check alone, or a few ms. The check itself is one call to the extension and can't be split.
- **201 ms at 08:25:58: not identified.** It was the end of the round, a minute after the sweep, right after the undo's copy.
  - From outside it can't be told which part it was. Probes on REAPER's thread: listing parses 1-5 ms, the room folders' listings 2.5-4.7
    ms, `drive.root`'s look 0.6 ms, and the change files are small.
  - **Added:** with perf stats on, a plan over 50 ms writes ExtState `drive slow` = { at, total, ms = { poll, room, upkeep, tools, cm, submit } }.
    The next one names its part.
  - One suspect is reduced anyway: the sweep kept every end-of-session project's text in Live sync's memory for good (Nostalgia's 13 are
    19 MB). Planned, it now reads them from the worker's local copy each sweep and doesn't keep them. A smaller heap means shorter
    garbage-collection steps, which land in whichever lap allocates.

### 2. The first sweep took 16 minutes, not ~8

**Why the halving didn't show.**
- Parsing was never most of it. The work after a restart is ~2.6 s of CPU in all:
  - the copy reading two songs' changes, ~1.4 s;
  - the sweep counting ~7,000 files, judging and scanning the end-of-session projects, ~1 s;
  - the update files' hashes, ~0.2 s.
- At 8 ms a plan and 5 plans per 10 s that's ~11 minutes at least.
- The units also run in order within a plan, and the sweep gets only what's left. While the other song is read (≥ 4 ms a plan), or the
  room has its 30 s look (35-55 ms), the sweep gets nothing.
- That's the 37-122 ms per 10 s: the 8 ms a plan, plus the room's looks, listing parses and single large changes.

**And three of the 16 minutes were a rest.**
- From 08:21:42 to 08:24:44 nothing ran (the lap dropped to 0.1 at 08:21:50), and the sweep finished in the next round (08:24:50).
- The rest came because the sweep's turns were starting with less time than one step needed: a saved version not read, a trim plan not
  started, a file not counted. Ten turns with no progress, and the back-off rested.
- **Fix (`cloudmodes.lua`):** every turn makes at least one step: one saved version read, one trim plan made, one file counted, one
  end-of-session project scanned. The sweep keeps moving however little time its turn gets.

To finish sooner than ~11 minutes would need more than 8 ms a plan for this background work. That's a choice for James, not a bug.

### 3. "Bringing ... up to date" at 08:21:42 with no edit

- That line was the rest. The rest reported `more = behind`, and behind was true: a copy kept failing (which one isn't known; it was never
  logged, so most likely a move). Live sync logs "bringing" when a result says `more` after one that didn't.
- **Fix:** a rest is never `more`.
  - Not up to date, it returns `0, false` and an error, "nothing moved for a while (X keeps failing); it tries again in 3 minutes". Health
    shows it as the last pass failing.
  - The log line names the failing file too: "nothing is moving though it isn't up to date (X keeps failing), ...".

### 4. "Couldn't save the end-of-session project to Google Drive: the project has never been saved" (08:07:58)

- **Wrong.** The project is saved. Live sync's end of session ran as REAPER closed (it restarted at 08:08:13), and a tab being closed gives
  no file name, so `sessionfile.export` took it for an unsaved project.
- It now says "REAPER was closing the project, so there was no file to copy (the saved version is kept)" when the song's own project file
  is known and on disk. "Never been saved" is kept for a project that really has no file.
- Quieting the line entirely would mean changing Live sync's `end_of_session` (outside my lines). The saved version itself was kept.

### Tests (each fails without its fix, checked)
- **3c/3g (updated):** a rest returns `more = false`, with the error when not up to date. A failing copy is named in the error and in the
  log line. Round 3's code returned `more` (3c: "true nil").
- **3j (tightened):** the room's look costs 30 ms in a plan, an update file read 0.2 ms, and one code file 20 ms. No plan goes over one
  extension check + 12 ms. Without the early-plan rule: 105 ms. Without the spread compare: 119 ms.
- **3l:** the other song uses 7.5 of the plan's 8 ms every plan, and listing the room's saved versions costs 1 ms. The sweep finishes in
  the round, never resting. With round 3's cloudmodes it rests.
- **3m:** a 60 ms plan with perf stats on writes `drive slow` naming the room.
- **3n:** a saved project being closed says so; one never saved says "never been saved". Round 3's sessionfile says "never been saved"
  for both.

### REAPER checks after deploy (desktop, after a restart)
1. With perf stats on: no drive step over ~90 ms. If one is, ExtState `drive slow` names its part.
2. No "bringing the studio's copy ..." line without a "Google Drive copy up to date" after it. A rest shows in Health as the last pass
   failing, with the file.
3. `cloud storage` within ~11-12 minutes of the restart, with no 3-minute pause in the drive lap before it.
4. At REAPER's exit: "REAPER was closing the project ...", not "never been saved".

## Round 5 (the round 13 measurement on 0.59.49.84, restart at 08:44:45)

Passed: no drive step over 62 ms, no stray "bringing" lines, an edit's "up to date (1 file)" in 2 s, and the new end-of-session wording.
Failed: no `cloud storage` after 21 minutes, a 3-minute flat stretch (08:52:59-08:55:46), no "StudioSync 0.59.49.84 is in the Google
Drive copy" line, and one `cm` part of 34.8 ms.

**One cause for the first three: round 4's own rule kept the update files from ever being checked.**
- Round 4 allowed a heavy check only in the first 4 ms of a plan. But before the check, the update-files unit looks over the cloud's
  staged copy: 150 files, each a listing lookup and a file-exists, ~5-8 ms. So no plan ever reached the check.
- The unit asked again every plan, and each time spent its ~8 ms. That left the sweep nothing (it only gets what's left).
- Ten plans with no progress, and the round rested quietly at ~08:52:46 (the copy itself was up to date). A new round did the same; the
  sweep only moved in the odd plan, so it never finished.
- Read from disk: the cloud's `_tools/studiosync/lib/files.txt` still says 0.59.49.83 (written 08:13:07). band.lua, cloudmodes.lua,
  drive.lua and sessionfile.lua differ from the studio folder's. **The update did not go up**; the cloud wasn't already current.
- Reproduced offline: a dry run of the round 4 planner on the real folders (real update files, the extension's check stood in) rested at
  virtual 440 s with the update-files unit never done.

**Fix (`drive.lua`).**
- Whether the update-files unit may make its heavy check is decided as it starts: if it started within 4 ms of the plan's start, one check;
  otherwise none, and the next plan.
- A plan that hashed code doesn't also make the check. A big file's ~20 ms hash and the 77 ms check never share a plan.
- The same dry run now sends the update (the "is in the Google Drive copy" line, copies refused by the dry run), never rests, and the sweep
  finishes and the round ends (`cloud storage` at virtual 982 s). Its worst plan was 61.5 ms.

**The 34.8 ms `cm` plan: one end-of-session project read and scanned** (Nostalgia's are ~1.5 MB each), the one step a turn may always make.
- `sessionfile.each_file` now finds "FILE " with a plain search and checks its line, instead of a pattern tried at every line start.
  Same paths on all 33 of the studio's projects in the cloud copy; 9 ms for all of them instead of 151.
- Each project's recordings are kept as a short list (`rpp_keys`) once it's read. Projects are written once under their own names, so
  later sweeps read none.

**How long the first sweep takes, honestly.**
- The dry run, at 2 s a plan and 8 ms each, spent:
  - 0-162 s reading Cross Test's changes;
  - 162-406 s reading Nostalgia's;
  - to ~710 s the update files;
  - to 982 s the rest of the sweep.
- That is about the floor this budget allows: ~2.6 s of work at 4 ms a second.
- My earlier "11-12 minutes" left out the units running one after another, and the jobs in between. Expect about 15-17 minutes after a
  restart at 8 ms a plan, with no rest in it. Shorter would need a bigger budget for this background work (James's call).

**`submit` 19 ms** in the same plan: writing the plan file and, when the worker had idled out (60 s without a job), starting it again (a
process start). Left as it is.

### Tests (each fails without its fix, checked)
- **3j:** looking over the staged copy now costs 5 ms. With round 4's rule the owner's new version never goes out ("nil").
- **3o:** two sweeps over a settled cloud copy with two end-of-session projects. The first reads each project once, the second reads none,
  and both count the same. Round 4 read them again ("2 then 2").
- `each_file`'s behaviour is checked in 3f (quoted, unquoted, CRLF, tab-indented, `XFILE`, `<FILE`, a bare `FILE`). Its speed was measured,
  not tested.

### REAPER checks after deploy (desktop, after a restart)
1. Within a few minutes: "StudioSync 0.59.49.<new> is in the Google Drive copy", and the cloud's `_tools/studiosync/lib/files.txt` names the
   new version.
2. `cloud storage` appears in ~15-17 minutes, with no flat stretch in the drive lap before it, and the drive lap then falls to ~0.1 ms per
   window.
3. No `drive slow` over ~65 ms. A second sweep 10 minutes later costs little (no project reads).

## Round 6 (0.59.49.85, restart at 09:19:49)

Passed: the update went up at 09:24:23 (the cloud's files.txt says .85), `cloud storage` came at 09:30:00 (10 min 11 s, no flat stretch),
and an edit went up in 6 s. Two things were left.

### 1. The update files' step over 65 ms four times (123.8 ms at 09:22:48, 76.5, 78.4, 109.0 ms)

**Cause.** The 77 ms check still shared its plan with other work:
- the unit's own look at the cloud's staged copy (150 files, ~5-8 ms), in the same call before the check;
- whatever the plan's units had done before the unit, up to the 4 ms allowed;
- the sweep after it in the same plan.

**Fix (`drive.lua`): the check is now a plan of its own.**
- **Staging first:** the staged copy is looked over in one plan and remembered for its lib/files.txt and signature (`staged`); the check
  runs in a later plan.
- **Nothing before it:** the check runs only if the unit started within 3 ms of the plan's start (`drive.HEAVY_BY`, counted from the start
  of `drive.bg_step`, so collecting the last job's results counts), and the unit itself did at most 5 ms of work first (`drive.HEAVY_IN`).
- **Nothing after it:** `drive.bg_step` stops the plan right after the unit that made the check (`drive.heavy_done`), so the sweep doesn't
  run in that plan.
- **No livelock:** a check waits for a quiet plan at most `drive.HEAVY_WAIT` (5) plans. A plan that can never be quiet still gets it, so it
  can't stall the way round 4's rule did.

**Expect** an update-files plan of about 77 ms (the extension's check alone, one call) two or three times per new version or restart, and a
few ms otherwise.

**Test 3j:** the sweep after the unit now costs 5 ms a plan, and no plan may exceed the check + 4 ms. Round 5's code: 83 ms.

### 2. A change made after the round ended waited ~3 minutes for the next round

**Cause.**
- Live sync starts a cloud pass soon after **sent** changes (`sync.posted`), otherwise every 3 minutes.
- A StudioSync Undo and the hub's snapshot (saved version) are files this computer writes in the room without sending them as changes. They
  waited for the 3-minute pass: 09:33:18 → 09:36:09, 09:36:21 → 09:39:10.

**Fix (`drive.lua`).** `drive.bg_busy()`, which Live sync asks each pass, now also says yes when a new file of this computer's appears in
the open song's rooms' `events` or `recall`.
- **What it starts:** a short round of just those rooms, without the other songs, the update files or the storage sweep, so the sweep
  isn't started again.
- **During a round:** it brings the rooms forward instead of waiting for their 30 s look.
- **How it's cheap:** each folder's own modified time is read (js_ReaScriptAPI's `JS_File_Stat`, 0.06 ms; checked on the desktop). The
  folder is listed only when that time moves, and for 3 s after, since it's to the second. Without js_ReaScriptAPI it's listed every 5 s.
  The listing is `band.listing`'s, shared.
- **What counts:** only names that are this computer's (`drive.mine`). A bandmate's change Syncthing brings starts nothing.
- **During a rest:** a short round still starts; full rounds still wait.

**Test 3p** uses Live sync's gate (bg_step only while busy):
- nothing new: no round;
- a bandmate's change: none;
- this computer's undo and a hub snapshot: both in the cloud copy within 10 s, in a round of the rooms only (neither the other song nor the
  sweep is called).

The old code never sends them within the minute.

Also: a job's results collected during a rest said `more`; now they don't (the stray "bringing" line's last way in).

### REAPER checks after deploy
1. After a restart: `drive slow` with `tools` only at ~77 ms, and no plan with tools over ~85 ms.
2. With the round over (`drive status` without `more`, `cloud storage` set): a StudioSync Undo, and a hub snapshot, each in
   `G:/My Drive/StudioSync - Smiley Studios/Cross Test/rooms/main/{events,recall}` within ~10 s, and "Google Drive copy up to date
   (1 file this pass)". `cloud storage`'s `at` doesn't change with it.
3. A bandmate's edit arriving starts no drive round: the drive lap stays ~0.1 ms per window.

## Round 7 (0.59.49.86, restart at 09:59:48)

Passed: an edit reached the cloud in 0.2 s and its Undo in 2.3 s, a hub snapshot in 2.1 s, `cloud storage`'s `at` was unchanged, and a
bandmate's change started nothing.

Failed:
- runs over 85 ms in Live sync's drive lap that `drive slow` didn't name (111, 128, 121 ms, and some of 73-79 ms);
- an 834 ms tick with drive at 485 ms, 24 s after the restart;
- the 3-minute flat stretch before `cloud storage`;
- a plan every ~3 minutes after the round.

### 1-2. Naming everything in the drive lap
`drive slow` only ever timed `drive.bg_step`. Live sync's "save, drive" lap also covers other work in `P.save_drive`:
- the project save after a delete went out;
- every 60 s: `removal.tick`, `listen.tick`, the change count and the end-of-session check (this also runs at Live sync's first pass,
  which is when the 485 ms was: Live sync had restarted at 10:00:11);
- `drive.root`;
- `drive.bg_busy`;
- after a step: the status, Syncthing rescans of anything brought down (each one starts a process), and `sessionfile.catch_up`.

**Now (perf stats on):**
- That lap is split into sub-laps: `drive/save`, `drive/quiet`, `drive/root`, `drive/due, busy`, `drive/step`, `drive/status`, and
  `save, drive` is what's left.
- Every tick over 50 ms in a 10 s window is kept with all its laps (up to 8), published as `over` in "tick stats" and printed by
  `tests/reaper/rt_perf.lua`. The "slow tick" ExtState (ticks over 150 ms) shows the parts too.
- `drive.bg_busy` writes `drive slow` with `ms.busy` when its own look takes over 20 ms.
- So the next measurement will name the 485 ms and the 73-128 ms runs exactly. I couldn't from outside.

**What's already cut:**
- **The worker now waits 240 s for its next job, not 60 s.** Live sync's rounds are 3 minutes apart, so each one started a new PowerShell on
  REAPER's thread. That was the 32.6 ms "submit" at 10:11:18.
- **`drive.bg_busy`'s look for new files now counts this computer's files** instead of building a set of every name. When a bandmate's
  change arrived it listed and set-built 2,700 names: the ~16 ms single-pass spikes every minute or so.
- **Compiling the drive's modules isn't it:** measured on REAPER's thread at 17 ms for all 19 together.

**Suspects for the 485 ms, unconfirmed:** Live sync's first-pass 60 s block (`removal.tick`, `listen.tick`, outside my files), `drive.root`'s
first look in a new Live sync, and process starts (the worker, rescans). The sub-laps will say which.

### 3. The flat stretch (10:08:32-10:11:26)
- A round rested mid-sweep at ~10:08:22. It was quiet because the copy was up to date, and the sweep finished in the next round
  (`cloud storage` at 11:38).
- **Not reproduced offline:** the same planner against the real folders, at 2 s a plan with 4 s jobs, finished the sweep at virtual 702 s
  with no rest.
- **Now** every rest writes ExtState `drive rest` = { at, plans = what each of the last ten plans did, sweep = where it was }.
  - Each plan is listed as its units: `name?` waiting for a listing, `name!` failed, `name+` done, `name-` more to do, each with its ms.
  - `sent` if it sent a job, `moving` if something happened.
  - `sweep` gives the song, room or projects, and how far.
- The next rest will say why.

### 4. The plan every ~3 minutes after the round (10:12:24, 10:15:26, 10:18:27)
- **What it is:** Live sync's scheduled cloud pass (`drive.EVERY`, 180 s), a full round:
  - the open room's ten cloud folders listed, then its full plan (28-51 ms: comparing 2,700 changes both ways);
  - the other song;
  - the update files (cheap, memo);
  - the storage sweep every 10 minutes.
- **What it's still for:**
  - bringing down a bandmate's work that is only in the cloud copy (someone working while not on the link with you);
  - keeping the other songs' copies;
  - the update files and the sweep.
- **What it's no longer for:** this computer's own changes go up within seconds by the short rounds (round 6).
- **Whether every 3 minutes is needed** is a product choice. It could stretch when nothing came in (3, 6, 12 minutes), at the cost of a
  bandmate's cloud-only work arriving later. Catch-up already asks for a pass when Syncthing needs files nobody on the link has. I left it
  at 3 minutes; it's no longer a process start each time.

### Tests (each fails without its fix, checked)
- **3c:** a rest writes `drive rest` with the last ten plans' units.
- **3p:** a slow look for new files (25 ms) writes `drive slow` with `ms.busy`. The worker scripts idle 240 s.
- **tests/test_0_60_rt_perfcut1.lua:** `sub_lap("drive/...")` marks are only inside `P.save_drive` (at least 6). Ticks over 50 ms are kept
  only inside `if perf.on`, and published and reset. Round 6's Live sync has none.

### Live sync lines (shared file, additive, perf-stat lines only)
Six `sub_lap("drive/...")` lines in `P.save_drive`, and `perf.over`: created, published as `over`, reset, and filled at the tick's end inside
`if perf.on`.

### REAPER checks after deploy (perf stats on, after a restart)
1. `tests/reaper/rt_perf.lua`'s "over 50 ms" lines and the "slow tick" ExtState name which `drive/...` part each slow drive run is. Send me
   them, with `drive slow` and `drive rest` if present.
2. `submit` no longer ~30 ms at each 3-minute round (no new worker each time). Look in `drive slow`, or for a `powershell` that stays
   between rounds.

## Round 8 (0.59.49.87, restart at 10:41:10; the instrumentation named everything)

### 1. The update files checked (77 ms) and sent again and again after the copy was current

**Cause, from disk.** The cloud copy is right (all 152 files equal to the studio folder's). But the worker's staged copy of it for 0.59.49.87
(`stage/a8e877a497e40410`) lacks `lib/grants.lua`, and the cloud's `lib/grants.lua` was rewritten at 11:01:34.
- One fetch of `grants.lua` into the stage failed (around the upload, 10:44-10:45). A failed fetch is remembered until the file changes, so
  the stage looked "done".
- The check of that half stage failed, so the copy went "out" again: `grants.lua` was uploaded again (it differed from the stage, which
  lacked it).
- With lib/files.txt and its signature unchanged, round 6's `staged` memo kept that same half stage, so every update-files pass checked it
  (77 ms) and uploaded again: 10:55:33, 10:55:47, 11:01:30...
- The "is in the Google Drive copy" line didn't repeat because it's said once per version.

**Fix (`drive.lua`, `drivebg.lua`).**
- A staged copy is remembered and checked only when every file it lists is there.
- A missing one is forgotten from the worker's failed list (`drivebg.forget`) and fetched again next plan.
- So after a send the cloud's copy is checked once, and not again until lib/files.txt or its signature changes. That memo was already there;
  the failing check was what kept clearing it.

**Test 3j (extended).** After the new version goes out, the stand-in worker fails the first fetch of one staged file. Over six more update
passes the copy is checked at most once and the file is never uploaded again. Round 7's code: 3 checks and a re-upload.

### 2. The extension's check on its own thread (`extension/sign.cpp`, for 1.0.33)
It was cheap, so it's done.
- `sign_verify_start(dir, key)` runs `sign_verify_files` on a thread (`std::async`) and returns a ticket.
- `sign_verify_poll(ticket)` returns "" while it runs, the answer once, then "?" for that ticket.
- At most 16 at once; past that it returns "", and the caller checks the usual way.
- `std::async`'s futures wait for their thread when destroyed, so unloading the extension never cuts one off.
- Registered as `StudioSync_VerifyFilesStart(dir, key)` and `StudioSync_VerifyFilesPoll(ticket)`. `StudioSync_VerifyFiles` is unchanged.
- No EXT_VERSION change, no binary. `sign.h` is untouched: the native test declares the two functions itself.
- **Native test** (`tests/sign_test.cpp`, `tests/build_sign_test.cmd`, run here): the threaded answer equals the direct one; a wrong key is
  refused the same way; an answer comes once; an unknown ticket gives "?"; past 16, "". All ok, and the Python-signed copy check too.

**Lua side (`drive.lua`).** Where the extension has `StudioSync_VerifyFilesStart`, the update files' checks run on its thread.
- The unit waits with `drivebg.NEED` and polls next plan; REAPER's thread never waits.
- **Choosing the way:** that answer is used as before.
- **The full check before a copy:** band.signed_ok's own steps run on the threaded answer, in the same order: the signed version is the one
  on disk, the code files match the signed list, and every code file has a SHA-256 line.
- Without it (extension 1.0.32 and older), the checks are as before: one 77 ms heavy step in a plan of its own.

**Test 3j (threaded):** with stand-in `verify_start`/`verify_poll`, the version goes out and no plan exceeds 30 ms (the hashing's 8 ms plus a
20 ms file). The synchronous way stays at the check + 4 ms.

### 3. The rest at 10:51:08: waiting counted as stuck
`drive rest` showed 8 of the last 10 plans as `cm? 0 sent`: the sweep waiting for a listing it had just asked for, a new one each time.
- "Sunset Drive sessions (21 of 22)": the sweep's 22 items include songs only named here (songsync's list) with no folder in the cloud copy.
  Each asked for its rooms, its projects folder and its projects' media folder, one listing job each.

**Fixes.**
- **`drive.lua`:** a plan in which a unit waits for something it asked the worker for, and a job went, doesn't count toward a rest, for up to
  `drive.WAIT_MAX` (120 s) since anything last happened. A listing that never comes still ends in a rest; a job that hangs is failed by the
  worker's own 30 s timeout, as before.
- **`cloudmodes.lua`:** the sweep doesn't ask about a song's rooms or projects in the cloud copy when the cloud copy has no folder for it.

**Test 3q:**
- a sweep asking for a new folder 15 plans running: the round carries on and ends, no rest (round 7: it rests);
- one that never stops asking: still rests, after `WAIT_MAX`;
- a song only named here: no listing asked for its rooms or projects (round 7: 3).

### 4. `drive/quiet` 15-20 ms
This is Live sync's once-a-minute block in `P.save_drive`: `removal.tick`, `listen.tick`, the change count (`band.listing` of the room's
events) and the 20-quiet-minutes check. None of it is the cloud copy's. `removal.lua`, `listen.lua` and those Live sync lines aren't mine, so
I left them. If it matters, they could take turns (one of the three a minute) or be split across passes; worth a look by whoever owns them.

### Also
`drive slow` now carries the last five slow plans in `recent`, so one 2 s later no longer hides the one before (10:44:13's 102 ms).

### REAPER checks after deploy
1. After a restart: one update-files check (~77 ms, or nothing on REAPER's thread with extension 1.0.33) per version, and none at later
   passes. The cloud's `_tools/studiosync/lib/grants.lua` keeps its time (no re-uploads).
2. No `drive rest` during the first sweep; `cloud storage` with no flat stretch before it.
3. With 1.0.33: `drive slow` shows no `tools` entry near 77 ms.

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
