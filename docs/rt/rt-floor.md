# rt-floor: the studio's version floor, and the mixed-version code it lets go (2026-11-27)

StudioSync runs only on James's own computers; nothing has been distributed (James, 11-27: "don't worry about older versions right now
since nothing has actually been installed on any systems other than my own"). So instead of compat code for rooms where old and new
versions mix, a **version floor**: a computer below it is told to update and stops sending, and the compat code can go. On top of
rt-sync2e (d1b3d56). Nothing here was run in REAPER; the Live checks below are written for the live-check tool to run.

## Summary for James

- **One floor for the studio, and it only goes up.** Each StudioSync has a level (now 11). The first computer that runs level 11 writes it
  into the studio's folder (`_band/floor`); that is the floor from then on. A computer below it **sends nothing** and says so: "This
  computer's StudioSync (...) is older than the studio's: nothing you change here goes to the others until you update StudioSync. You
  still get their changes." in the log, and as a red **update floor** row on Health (the panel's and the web page's), with an Update
  StudioSync button.
- **Nothing you do on an old computer is lost.** What you change there is kept as "not sent yet" (as a change waiting on a big file copy
  is), so the others' changes to that same thing wait behind it, and it all goes out on the first look after you update. Everything else
  the others change still lands there.
- **Computers at the floor never take a change made below it.** They hold it (not applied, not marked done, not counted as "still to
  come"), and say "<who>'s StudioSync is older than the studio's: their changes wait ...". History from before the floor lands as ever.
- **The code that only mattered for a room with a pre-folders StudioSync is gone**: the folder write-back ("N track(s) given their folder
  as a parent" by computers that weren't the track's maker), the re-ranking for old computers, the tree's depths written into versions,
  and the order list rewritten to match the ranks. A ranked track's depth is no longer part of its fingerprint (hash version 11). The
  room's one-time switch-over to folders (by each track's maker) stays: your rooms have history from before it.

## Commits

| Commit | What | Tests that fail without it |
| --- | --- | --- |
| 754b290 | the floor (`lib/sync.lua`, `lib/mirror.lua` guards, `lib/page_health.lua` row, `StudioSync - Live sync.lua`, `tools/soak/node.lua`); the removals; hv 11 | `test_0_61_rt_floor` 1-7, `test_0_60_rt_folders` 10, `test_0_60_rt_rank` 10 (see Tests) |
| e494d42 | the soak's studio starts with its floor file in place, as `band.json` is (each node writing one reshuffled every seed's network draws: see Gates) | (the long soak: 234 -> 236) |
| (this doc) | docs/rt/rt-floor.md; `tools/soak/scenarios/tempo-env.json` back to "today": "fails" (a frozen seed the floor file moved back onto its bug; see Gates) | |

Nothing of `lib/webui*` (the uncommitted edits there are someone else's) or `tools/live/`. No new lib file (`lib/files.txt` unchanged),
no version bump, nothing pushed.

## The floor's design

### The pieces

- **`sync.LEVEL = 11`** (`lib/sync.lua`). Raised at a release whose events older code mustn't mix with: whenever `mirror.HV` changes (what
  goes into a hash) or `band.FORMAT` (the event format). `test_0_61_rt_floor` 7 asserts `sync.LEVEL >= mirror.HV`, so an hv bump without
  a level bump fails the suite. `mirror.HV`'s comment says the same.
- **Every event carries its level**, `lv` (`sync.post`). Obj events already carried `hv`; timeline, notes, cues and the rest carried
  nothing that said which code made them. `lv` is one number on all of them.
- **The floor is recorded in the studio's folder**: `<root>/_band/floor/<level>-<user>.json`, content `{ level, since }`. `_band` is
  band-wide (`songsync.BAND_WIDE`'s `/_*`), so every computer gets it. `sync.floor_read(cfg)` lists that folder (at most every 10 s):
  the floor is the highest level in it; `since` is the earliest `since` of any file (when floors began). If this computer's level is
  higher than every file, it writes its own file first. **One file per writer** (named by level and user), so two computers raising the
  floor at once never write the same file (no Syncthing conflict), and **nobody deletes them**, so the floor only goes up and a computer
  that has never run the new code finds it when it does. A file that can't be written is tried again on the next read.
- **`sync.floor(cfg)`** sets `sync.floor_now`, the floor a Lua state goes by. Live sync's pass (`P.look`), `sync.preload` (Open session,
  Autostart) and the soak's node call it. The panel (Health) and Undo/Restore use `sync.floor_read` without changing what that state
  holds.

### Below the floor: nothing goes out

| Where | What it does below the floor |
| --- | --- |
| `W.send` (the look's send) | marks the object unsent (`mirror.unsent`) and says the floor words once; nothing is written, no audio copied into the studio's folder |
| `W.gone` (a deletion of yours) | the same: the deletion waits unsent |
| `sync.post` | refuses (returns nil) and logs once: the backstop for every other sender |
| `mirror.revert` (Undo, Redo, Restore, History, forks) | refused whole, "Not done: ..." (an Undo that changed REAPER without sending would be lost) |
| `mirror.rank_room`, `mirror.publish_order` | skip |
| Live sync `P.look` | logs the floor words once; leaves the tempo map and markers unlooked (a timeline change of yours stays in REAPER and goes once updated) |
| Health (`page_health`) | a red `update floor` row with the words and an Update StudioSync button (the panel and the web page both build Health from these rows) |

Why the look still runs below the floor: it is what marks your edits as yours. Skipped, nothing protects an edit from a bandmate's change
to the same object (receive goes ahead 30 s after the last look regardless: `sync.seen_mine`), and an edit would be overwritten. With
`mirror.unsent` set, receive keeps the band's change to that object waiting (`mirror.receive`'s unsent checks), exactly as for a change
waiting on a big copy, and everything else lands. Once the computer is updated, the next look finds those objects still differing from
the band's versions and sends them.

### At the floor: changes made below it are held

`sync.held_by_floor(ev)`: with a floor read, an event is held when its `lv` is lower than the floor, or when it has no `lv` (a StudioSync
from before floors) and was made at or after `since`. It is folded into `sync.too_new`, so **every** place that already set aside a
change from a newer StudioSync sets these aside too: the receive pass (`sync.deferred`, not marked applied, not counted by
`pending_events`), the newest-per-object pick, the judge's version sets (`mirror.lua`'s two `too_new` filters). The receive pass logs it
once per sender.

**Held, not dropped**, and why: a dropped change (marked done) would be gone for good on every computer that saw it. A held one stays in
the room, unapplied. It never lands by itself (it was made by code that the floor says mustn't mix), but nothing of it is lost: the
person's edit is still in their REAPER project, kept unsent there if their StudioSync knew the floor, and it goes out at the new level
once they update; and the held file is still in the room if anyone needs to look at what it was. The one case it doesn't cover: a
StudioSync from before floors (no floor code at all) recorded its change as sent; after updating, its look sees nothing to send for it.
Only James's computers ever ran one, and this release is the first with a floor.

**History is not held**: an event with no `lv` older than `since` is from before floors, and lands as it always did (James's rooms are
full of them). That is the only thing `since` is for. Clocks matter only for events without `lv`; every event from now on has one.

### How the floor is raised (the whole procedure)

1. A release changes what goes into a hash (`mirror.HV`) or the event format (`band.FORMAT`): raise `sync.LEVEL` to match (the suite
   fails if `LEVEL < HV`).
2. The first computer that runs it writes `<LEVEL>-<user>.json`. From then on every computer below it sends nothing and shows
   "update StudioSync"; every computer at it holds what the others send until they update.

Nothing else: no setting, no button, nobody to remember it.

## What was removed (and what stayed)

| Removed | Its only job | What replaces it |
| --- | --- | --- |
| `mirror.rank_room`'s write-back: a version whose folder or rank is off the tree said again by **any** computer holding the same versions as a caught-up bandmate (`same_as`, the `presence.peers` status check), and by makers | an older StudioSync puts versions' depths in place and sorts by rank alone, so it showed other folders | nothing: every computer at the floor works the same tree out of the same versions (`rank.tree`: parents, loops broken by the newest version) and sets REAPER's depths from it (`mirror.tree_depths`) |
| `rank_room`'s re-ranking of tracks out of the tree's rank order (`unsorted`, `moved_tracks` of rank order against tree order) | the same: an older StudioSync sorts by rank alone | nothing: the tree orders by parent, then rank among siblings |
| `rank_room` writing the tree's depth into versions (`rank.depths` -> `st.depth`), and the `off` check on a depth that differs | the same: an older StudioSync shows versions' depths | nothing: a ranked track's depth is never read from a version (`set_track_state` skips it; the tree gives it) |
| `keep_order`'s `list_too`: the order list rewritten to match the ranks in a room with ranks | only a StudioSync before ranks reads the list there | nothing: a room with ranks goes by ranks; lists are still written after moves and landings for rooms not ranked yet |
| depth in a **ranked** track's hashed line (`mirror.track_line`) | kept because old computers needed accurate depths; rt-sync2d already noted it "can leave the hash at the floor" | the tree. **hv 10 -> 11.** An unranked track keeps depth in its line (its folder still comes from its depth) |

Kept on purpose, with why:

- **Depth still travels** in every track version. A room not ranked yet (a brand-new room before its first quiet moment) still decides
  folders by depth, and so does history from before the switch-over (`rank.depth_parents`). It costs nothing: it's out of a ranked
  track's hash, and nothing reads it for one.
- **The switch-over** (`rank_room`'s ranking, and each track's folder said once with `pk`, by its maker, "N track(s) given their folder as
  a parent"). Your rooms have versions from before ranks and folders; a new room passes through an unranked moment too. These are
  history, not old computers.
- **The no-`rk` / no-`pk` branches** (`mirror.rank_in`, `mirror.parent_in`, `rank.tree`'s depth inference, the merge's "a side without
  `pk` changed the parent only where it changed the depth", `mirror.rank_from`'s `after`, revert's folder rule): each reads a version made
  before ranks or folders, which is in every existing room's history and lands as history. Only a *live* older computer was the mixed-room
  problem, and the floor now holds its changes.
- `W.order`'s rank choice "between its list neighbours when that also sorts it among its siblings": made for old computers, but it also
  keeps the global rank order sorted, which the depth inference of not-yet-switched-over history uses. Harmless, left.
- `sync.OLD_TYPES` (pre-0.32 kinds), the version notice (`band.check_version`, Health's "update <version>" row): unrelated, left.
- The mixed-version soak harness (`soak.py --old`, `range.py --old`): kept. It is how a later floor raise can show what an old computer in
  the room would do. Not a gate.

## The hv change

- `mirror.HV` 10 -> **11**: a ranked track's line has `""` where its depth was. `sync.LEVEL` 11, the floor at 11.
- Updating doesn't send anything again: `W.one`'s track alias compares the band's version and REAPER's state through `same_line`, which
  uses the new line on both sides, and records the band's hash when only the formula differs; apply's hash check compares only at the
  same hv.
- **Phase 5 (beats) was planned for hv 11; it now needs 12**, and must raise `sync.LEVEL` to 12 with it.

## Tests

`tests/test_0_61_rt_floor.lua` (new) on the chunk-faithful fixture, two computers sharing one studio folder:

| Part | What | Knocked out (scratch copy, the test run) -> fails at |
| --- | --- | --- |
| 1 | pure: lower `lv` held, `too_new` says so; at/above not; no `lv` since the floor held; no `lv` before it (history) lands; no floor read holds nothing | `held_by_floor` returning false -> "a lower level: held" |
| 2 | the floor file written on the first read; same level writes nothing more; a higher level raises it, `since` stays the first; the lower computer is below; a still lower one never lowers it, and writes nothing | the raise removed -> "James's level recorded"; a floor that follows a lower level -> "James at 11 is below it now" |
| 3 | below the floor: a rename sends nothing, says "update StudioSync", is kept unsent; a deletion too; `sync.post` refuses; Undo refused; a bandmate's rename of another track lands, theirs of the same track waits | `W.send`'s guard -> "kept as a change of James's not sent yet"; its unsent mark -> the same; `W.gone`'s guard -> "a deletion too"; `sync.post`'s refusal -> "sync.post refuses"; revert's -> "Undo is refused" |
| 4 | updated: the kept rename and the deletion go out on the next look, at the new level | (needs 3's pieces; `lv` stamp knocked out fails earlier, at 3's setup: the song itself is held) |
| 5 | at the floor: every change carries `lv` | `lv` stamp -> fails (song held) |
| 6 | a change at lv 10 and one with no `lv` since the floor: not applied, not marked done, not pending, logged; one from before the floor lands | the receive log's words -> "the log says whose wait"; `held_by_floor` -> part 1 |
| 7 | hv 11: a ranked track's hash ignores depth, an unranked one's doesn't; `LEVEL >= HV` | the old line -> "a ranked track's depth isn't in its hash" |

Changed tests:

- `test_0_60_rt_folders` part 2: hv 11. Part 10 now pins the removal: an off-tree version is shown as the tree has it on both computers
  and **nobody** says it again, even with a caught-up bandmate holding the same versions. With 87e2bcc's / d1b3d56's `rank_room` put back
  it fails ("Bee said Gtr and Bass again ...: 2").
- `test_0_60_rt_rank` part 10: a room with ranks keeps its order and leaves a newer order list alone. With the old `keep_order` put back it
  fails (the list rewritten "by James").

Every knock-out above was run (scratch scripts: a copy of `lib/` and `tests/` with the piece taken out or the old code put back, the test run; not kept): all 13 fail as listed.

## Gates

All from fresh clones under the scratchpad, one run at a time (the orchestrator's leftover `range.py` from 5:49 PM, a pool respawning
workers whose tree was gone, was stopped by the orchestrator before the long soaks).

| Check | 754b290 | e494d42 (final code) |
| --- | --- | --- |
| long soak, 237 seeds at 150 edits, 8 procs (`range.py`) | 234: 5034 (undo probe), 13008 (items under the tempo map), 15021 (tempo map / markers); 15057 passed | **236: 15057 only** (tempo map / markers, the class in every run since rt-sync2c) = the d1b3d56 baseline |
| `soak.py --scenario all` | 15 of 15 as they say, `folder-loop` passes | 14 of 15 as they say: `tempo-env` fails (`converged:E differs`) where it said "passes"; with its `today` set back to "fails" (this doc's commit) 15 of 15. `folder-loop` passes |
| `tests/run.py --no-luals`, local time | fails 2: `test_0_60_rt_bigproj`, `test_0_60_rt_drivebg` (timing, machine loaded) | fails 1: `test_0_60_rt_bigproj` (timing: 39 ms against 33) |
| the same, `TZ=UTC0` | fails 1: `test_0_60_rt_drivebg` (20.2 ms against 20) | **fails 0** |
| soak --quick, detcheck (inside run.py) | ok, ok | ok, ok |
| mixed soak, Cee on d1b3d56, 5000-5029 (information only) | | 0 of 30, as designed: Cee's StudioSync has no floor, its changes (no `lv`, made after the floor) are held by James and Bee, so Cee's objects are "missing" on them (16 `E missing`, 12 `E differs`, 2 `F differs`) |

**The load-sensitive tests, A/B'd** (the same tests, alternating, the two clones side by side, while another soak ran):
`test_0_60_rt_bigproj` failed 5 of 10 runs on 754b290 and 4 of 10 on 87e2bcc; `test_0_60_rt_drivebg` 4 of 4 and 3 of 4. Both are
timing budgets (a quick look's ms, a background pass's ms); nothing in this round touches either path beyond one `below_floor()` call
per send.

**Why 754b290 went 234, and what was done.** Bisected on the four seeds (5034, 13008, 15021, 15057), each variant of 754b290's tree:

| Variant | Failed |
| --- | --- |
| 754b290 as committed | 5034, 13008, 15021 |
| the old `rank_room` put back | 5034, 13008, 15021 |
| the old `keep_order` (order list) put back | 5034, 13008, 15021 |
| depth back in the ranked line | 5034 |
| all three put back | 5034, 13008 |
| the soak's floor read taken out of `node.lua` | **none** |
| the floor read kept, the holding off | 5034, 13008, 15021 |
| the floor read kept, its file write off | **15057** (the baseline) |
| the floor read kept, its folder and file write off | **15057** |

So the three were the floor *file*: each soak node wrote `_band/floor/11-<name>.json` at its first look, three more files through the
simulated network, whose every delivery takes random draws (delay, late, half, twice), so every later fault in the seed moved: other
runs of the same seeds. None of the three is new: 5034 is the undo probe's class (rt-sync2d's 9059 and 9018), 13008 and 15021 the tempo
map class of 15057 (rt-sync2b Recommendation 7). The fix (e494d42) puts the floor file in the soak's studio when it's made, as
`band.json` is: the soak models a studio in its steady state, and raising the floor is the unit test's (part 2). Then 236 of 237, the
baseline, from a fresh clone. (e494d42's commit message says the seeds also went back to the baseline "with the pieces of the removal put
back one by one"; the table above is the truth: they didn't. The floor file alone decides it.)

**tempo-env.** A frozen seed of the tempo map class whose own notes say it "moved off the bug by the rank versions' extra writes, not
fixed" (rt-sync2c). With the floor file in the soak's file system it fails again, and it does so with nothing reading the file (the
floor read taken out too): the file's presence alone reshuffles that run (my guess: the fake file system's Lua tables iterate in another
order; see Recommendations). With the removals put back it still fails. Its `today` is back to "fails" with a note; phase 5's gate.

## Live checks

For the live-check tool (`tools/live/`, another agent's): each is a scenario it can script through the REAPERs' dev-eval hooks. Computers:
**D** (desktop, JAMES-MAIN), **L** (laptop), **M** (Mac). Before: every computer on this build, the test song open with Live sync on, all
caught up (each status `pending` 0). `<root>` is the studio folder, `<room>` = `<root>/<song>/rooms/main`. Lua below runs in the REAPER
named. "Within N s" means poll every second up to N s. Each scenario cleans up after itself.

1. **The floor is recorded.**
   - D, L, M: `local f = require("sync").floor_read(cfg, true)`.
   - Read back: `<root>/_band/floor/` lists at least one `11-<user>.json`, each `{ "level": 11, "since": "<ISO time>" }`.
   - Pass: on all three `f.level == 11`, `f.below == false`, and the same `f.since`. Fail otherwise.
2. **Updating sends nothing (hv 11 switch-over).**
   - Note the newest event file name in `<room>/events` at the start. Nobody edits for 120 s.
   - Read back: event files written in those 120 s, by user, and each one's `auto`/`rk`/`pk`.
   - Pass: no event file from any computer except `auto` rank/folder versions (the one-time switch-over, at most one per track, each by
     the track's maker). Fail: any track version without `auto`.
3. **Below the floor: nothing goes out, nothing lost.**
   - D: write `<root>/_band/floor/12-livecheck.json` = `{ "level": 12, "since": "<now, ISO UTC>" }` (every computer is now below).
   - Within 15 s on D, L, M: `require("sync").floor_read(cfg, true).below == true`; Health rows (`require("page_health").build_rows()` in the
     panel, or the web page's health topic) include id `update floor`, colour `red`; Live sync's log has "older than the studio's".
   - D: rename track "Gtr" to "Gtr floor" (`GetSetMediaTrackInfo_String(tr, "P_NAME", ...)`). L: rename "Keys" to "Keys floor".
   - Wait 15 s. Read back: no event file in `<room>/events` newer than the start of this step; on D `Undo` (`require("undo").step(...)`)
     returns text starting "Not done:" and writes no file.
   - D: delete `12-livecheck.json` (test-only: the floor normally never goes down). Within 25 s (10 s floor cache + a look):
     L and M show "Gtr floor", D and M show "Keys floor"; one event each from D and L with `lv == 11`.
   - Pass: every read-back above as stated. Fail: any event while below, any rename lost, the row missing.
4. **A change made below the floor is held.**
   - D: copy the newest event of track "Bass" in `<room>/events` to a new file `LiveCheck-<yyyymmdd-HHMMSS>Z-00001-0001.json` with
     `user = "LiveCheck"`, `id` = that name, `rev` + 1, `base` = old rev, `base_ev` = old id, `state.name = "Bass HELD"`, `lv = 10`, `time` now.
   - Within 30 s on L and M: no track named "Bass HELD"; `GetProjExtState(proj, "BandSync.applied", <id>)` is `""`; their status
     `pending` back to 0; the log has "LiveCheck's StudioSync is older than the studio's".
   - Clean up: delete the file on D.
   - Pass: as stated. Fail: "Bass HELD" anywhere, or `applied` "1".
5. **Two folder moves at once end the same, with no write-back.**
   - D: put Keys inside Bass (make Bass a folder: Bass `I_FOLDERDEPTH` 1, Keys moved under it and closing it, -1). Within 1 s, L: put Bass
     inside Keys the same way.
   - Wait 60 s with nobody editing.
   - Read back on D, L, M: each track's `GetParentTrack` name and the track order; the event files written in that minute with `auto`.
   - Pass: all three show the same parents and order, one of the two inside the other; no `auto` event names Keys or Bass (no
     write-back). Fail: any computer differs, or an `auto` version of Keys/Bass from a computer that isn't its maker.
6. **Web Health shows the floor.**
   - With `12-livecheck.json` present (step 3's first line), fetch D's web page health topic (`lib/webpages.lua` model).
   - Pass: a row `update floor`, colour red, its button "Update StudioSync". Clean up: delete the file.

## Known limits

- **A StudioSync from before floors isn't stopped**, only held: it has no floor code, sends as ever, and its changes since the floor are
  held by everyone at it. If it is then updated, changes it recorded as sent stay held and don't go out again (see "Held, not dropped").
  Only James's computers ever ran one; update them all to this build together.
- **Clocks**: a change without `lv` is told from history by its time against `since`. A pre-floor computer whose clock runs minutes behind
  could have a change land that was made after the floor. Only events without `lv` depend on clocks; every new event has one.
- **A timeline change made below the floor** stays in REAPER unsent; if a bandmate changes the tempo map or markers meanwhile, theirs lands
  over it (the timeline has no per-object "unsent" hold). It goes out after the update otherwise.
- **Below the floor, receive's own answers don't go out** (a claimer's put-back of a rename, `sync.set_back`): `sync.post` refuses them.
  The rename waits on the others until this computer is updated.
- **A bogus floor file stops everyone**: anyone who can write the studio folder can write `99-x.json` and every computer stops sending
  until it's deleted. Same trust as every studio file (see Review later).
- **A floor file can't be taken back** except by hand: a test build with a raised `LEVEL` run once puts the whole studio below it. Raise
  `LEVEL` only in a release build.
- A suggestion to a claimer (`W.propose`, Claims mode) can still be written below the floor; it's a request, not a change.

## Recommendations (ranked)

1. **Update every computer to this build in one sitting.** The first computer on it records floor 11; the rest stop sending until updated
   (nothing they do is lost, but nothing they do reaches anyone either).
2. **Make the release check refuse a build whose `mirror.HV` or `band.FORMAT` changed without `sync.LEVEL`** (tools/release_check.py): the
   suite catches `LEVEL < HV`, not a format bump.
3. **Phase 5: hv 12 and `sync.LEVEL` 12** in the same commit.
4. **Drop depth from versions entirely** once every room is ranked and switched over (a room records "switched over" in `_band` or the
   room): then the depth inference, the merge's no-`pk` rule and `rank_in`'s `rk` check can go too. Needs a way to know a room's history
   has no pre-rank version left that can still win (the trim, or a re-say of every track at the switch-over).
5. **Give a held change a Health row** on the computers holding it ("Cee's changes are held: they need to update"), not only a log line.
6. **Find what in the soak (or the lib) depends on a file system's iteration order**: one unread file in the soak's fake file system
   changes tempo-env's outcome. If it's the lib (a `pairs()` over files whose order decides something), it's a determinism bug of the kind
   rt-sync2e fixed for collation; if it's only the harness, the soak should sort.
7. **Let a `held` file be re-made**: on update, a computer could re-send its own held events' objects (clear their known hash) so the
   pre-floor case in Known limits loses nothing either. Only worth it if a pre-floor build ever leaves James's computers.

## Review later (security)

- `_band/floor` is written by anyone with the studio folder (guests too: `/_*` is band-wide for them). A raised floor is a denial of
  service, never a content change: a computer below the floor only stops sending. A floor file's content is two fields, read as a number
  and a time string.
- A forged `lv` (an old computer claiming 11) passes the hold; the floor is a guard against mistakes, not against a hostile member.
