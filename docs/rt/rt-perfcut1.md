# The cloud copy that never finished, and per-lap perf stats (rt-perfcut1, 2026-11-21)

rt-perf's cut 1 (done, committed) and the first half of cut 3 (half done, not committed: see "Left").

## 1. The cloud copy never finished (done)

**What was seen.** On the desktop, ExtState `drive status` stayed `{"more":true,"moved":0}` and every pass planned again: 15-76 ms in the
slowest tick of every 10 s window, moving nothing.

**Evidence (read from disk on the desktop, no REAPER probe needed in the end):**
- The worker's listings in `%TEMP%/bandsync-drive-237df11a0c1a95e4/lists/` (names are `drivebg.hash` of the folder): only the ten folders of
  `G:/My Drive/StudioSync - Smiley Studios/Cross Test/rooms/main` were listed, again every ~30-60 s (as each 30 s listing ran out). Nothing
  after that room had been planned since 2026-11-20 17:15-18:41 (the other songs, the update files).
- That room, studio folder against cloud copy: events 2,489 here, 775 in the cloud. **1,694 of the desktop's own changes never went up**,
  every one after `James-20261120-231845Z-00093` (16:18 MT on 11-20). recall 167/52, recall/known 157/49. Media, deleted, midi equal.
  All 2,489 event files parse. There is no `cloud_storage` setting (Everything).
- So the room unit of `drive.bg_step` answered "more" for ever, `rooms_left` held the other units back, and the round never ended.

**The cause.** Live sync plans 8 ms a tick (`drive.bg_step(..., 0.008)`). For this room:
1. `read_events` checks its deadline (`t0 + budget`) before reading each not-yet-read change. Listing 2,489 files alone takes longer than
   8 ms, so once the room was that big, a new change was never read: `read_events` returned nil, `drive.mirror` returned `0, true`.
2. Even with every change read, `drive.mirror`'s `out_of_time()` counts from the call's start. Its reading (two listings of the events
   folder, the events, owners) took more than 8 ms, so it was out of time at its first copy and planned nothing.
The burst of ~1,700 changes on 11-20 at 16:18 is when the room crossed that size. Nothing ever moved after it.
(The read-only REAPER probe written to time this, `probe1_rt-perfcut1.lua` in my scratch folder, was never picked up: REAPER stopped
answering deferred scripts around 02:28 under memory pressure. I removed the pending `eval.lua`.)

**The fix (`lib/drive.lua`, `lib/cloudmodes.lua`):**
- `read_events` (both files): after the folder's listing, each call gets at least `drive.READ_MIN` (4 ms) of reading, whatever the
  deadline. A big room's changes are read a few ms a pass until all are known (they're kept, as before).
- `drive.mirror`, planned only: the budget counts from the first step it plans, not from the call's start. Reading is the same work as
  before; it no longer throws its result away. The old way on REAPER's thread (`drivebg.direct`) is unchanged.
- cloudmodes' sweep had the same flaw in its own `read_events` (its first room never got past the listing); same fix.

**The back-off (`drive.bg_step`).** A round that plans `drive.STALL` (10) times in a row with nothing moved, no unit finished and no
change read further *rests*: it ends, returns `moved, true` (Health keeps "still copying"), and no new round starts for `drive.EVERY`
(180 s). Said once in the log ("... copy: nothing is moving though it isn't up to date, so it tries again every 3 minutes rather than every
pass"), again only after a round that ends normally. Counting plans, not seconds, keeps a slow drive's long listing jobs from looking stuck.
It also covers a copy that fails every time (plans keep being sent, nothing moves). A future "never done" now costs ~10 plans every
3 minutes, not every pass.

**Tests** (`tests/test_0_60_rt_drivebg.lua`):
- 3b: a stand-in room where each listing of its own events costs 10 ms, planned at 8 ms a tick. Every one of 59 changes goes up and the pass
  ends. Against the old code: 0 of 59 (checked).
- 3c: a stand-in round that always answers "more" with nothing moved. It plans 10 more times after its other units finish, then rests; the
  next plan is ≥ `drive.EVERY` later; it says so once.

`python tests/run.py --no-luals`: see the report (run in a clean clone of the commit).

## 2. Per-lap totals in perf stats (half done, NOT committed)

In the worktree, uncommitted, in `StudioSync - Live sync.lua` (all small and additive):
- after `local perf = ...`: `perf.laps`, `sub_lap(name)` (a lap only while perf stats is on), `laps_add(sums, laps)`,
  `laps_table(sums)` -> `{ {lap, total ms, ticks it ran in, worst ms}, ... }`, largest total first;
- `perf_publish`: a `laps = laps_table(perf.laps),` line in "tick stats"; `perf.laps = {}` after the reset line;
- the tick's end, inside `if perf.on`: `laps_add(perf.laps, laps)`.

## Left

1. Put `sub_lap("start/...")` lines in `tick_body` before `lap("start")`, one after each sub-tick: keep_lock/follow_file, plug-ins and
   takes, shared prefs, calibrate, together, `direct.live_tick` (link), controllers, signed, needlist, ablink, liveaudio, hops, claimask,
   webui, hub, bounces, follow. With perf stats on, "start" is then only what's left after the last sub-lap (the transport ExtState).
2. A test, `tests/test_0_60_rt_perfcut1.lua`: load `laps_add`/`laps_table` from the source text and check totals, counts and worst; check
   every `sub_lap` sits in `tick_body` and that `laps_add` is only called inside `if perf.on`.
3. `tests/reaper/rt_perf.lua`: print `st.laps` (lap, total ms, ticks, worst; total ms / 100 = % of one core over the 10 s).
4. Then commit through a private index (Live sync is shared: never stage another agent's `edited_at` line).

## REAPER checks for James (desktop, once deployed)

1. Cross Test open, Live sync running: within a few minutes the log says "Google Drive copy up to date (N files this pass)", and
   `G:/My Drive/StudioSync - Smiley Studios/Cross Test/rooms/main/events` reaches the studio folder's count of James-* files (1,694 more).
   recall and recall/known follow.
2. ExtState `drive status` then shows no `more`; `%TEMP%/bandsync-drive-*/lists/` also gets the other songs' folders and `_tools`.
3. `tests/reaper/rt_perf.lua` over 10 minutes idle: the "save, drive" lap no longer shows up in every window's slowest tick.

## Review-later (security)

None new. The worker and plan trust is as in rt-drivebg.
