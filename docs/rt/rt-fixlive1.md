# rt-fixlive1: the six bugs rt-live found on real REAPER, and two small ones (2026-11-28)

rt-live (docs/rt/rt-live.md) ran the REAPER checks of rt-sync2c, rt-sync2d and rt-sync2e through `tools/live/` on 0.61.4 and found six bugs,
each with the scenario that reproduces it. This round fixes them on top of 52ce885 (sync phase 5: hv 12, LEVEL 12, FORMAT 2), one commit per
fix with a test that fails without it, plus the "live audio on" line with Mute me on and the floor line the live floor check (`floor -k f3`)
found on 0.62.0. Nothing of `tools/live/`, `lib/webui.lua` or `lib/webui/index.html` was touched. No version bump, nothing pushed, nothing
deployed. No live set was run (below: why, and which to run).

## Summary for James

- **A delete-all right after another deletion now asks and goes**, like any big deletion. It was put back silently because StudioSync told
  REAPER's undo points apart by their names, and two deletions both read "Remove tracks".
- **Opening a file again in the same tab is seen as a new opening.** REAPER keeps the tab's master track through File > Open, which is what
  StudioSync went by. Now it goes by Live sync's load guard (which did see those reopens) and checks the tracks really are new, so a save
  isn't taken for one.
- **The tracks an older file lacks come back at once** when it's opened in the same tab (they took 3 s to over 2 minutes, waiting for the
  catch-up).
- **Bandmates' track moves wait while you play or record**, and land when you stop.
- **StudioSync's Undo of a deletion no longer leaves a "(yours, not sent)" copy** of the take that was kept aside: the kept take goes back onto
  the track.
- **New tracks go out with their place and folder the first time.** The "given their place as a rank" / "given their folder as a parent"
  lines (and two extra auto versions) came for every new batch of tracks in an empty song.
- **Small ones:** the log says "live audio on (muted)" with Mute me on, not "sending input 2"; "older than the studio's" is said again each
  time a computer drops below the floor (it was once a session), and Health's "update floor" row shows a floor change at its next build.

## Commits

| Commit | Fix | Test that fails without it |
| --- | --- | --- |
| 055cec8 | bug 1: a new undo point told by its place in REAPER's undo history, not its name (`mirror.undo_top`) | `test_0_60_rt_guard` 9 |
| f3d9c00 | bug 2: a reopen in the same tab told by the load guard plus "none of the last look's tracks left" (`mirror.on_open`) | `test_0_60_rt_guard` 10 (the opening; a save isn't one) |
| 201ad56 | bug 3: `sync.settled_for`'s applied-files cache starts afresh with each opening | `test_0_60_rt_guard` 10 (the lacking track back at once) |
| c81864b | bug 4: a bandmate's move waits while playing or recording (`mirror.apply`, `sync.receive`), owed to `keep_order` at the stop | `test_0_60_rt_rank` 13 |
| adff29a | floor: `floor_said` / `floor_held` said again; Health reads the floor afresh (the coordinator's add-on, live check `floor f3`) | `test_0_61_rt_floor` 8 |
| 8c2edf4 | bug 5: a take kept on "(yours, not sent)" goes back onto the track StudioSync's Undo brings back (`mirror.kept_aside`) | `test_0_60_rt_reopen` 6 |
| 44af905 | bug 6: an empty room's first tracks ranked at once (`W.order`), so they go out with rank and folder the first time | `test_0_60_rt_rank` 14 |
| f449736 | "live audio on (muted)" with Mute me on (`liveaudio.on_words`) | `test_0_60_rt_liveux` (the on_words asserts) |
| 9dd3824 | bug 6's ranking asks `w.pending` only when the look has one | `test_0_60_rt_delete_race` (failed on 44af905: a minimal `w`) |
| e9e8fbb | bug 6's ranking lists the room's events only for an empty room's first tracks, not every look of an unranked song | `test_0_60_rt_bigproj` (44af905: 0 of 5; 52ce885 and e9e8fbb: 5 of 5 each, A/B alternating) |
| 34f1ebe | f3d9c00's timeline look on every opening taken back (the master track again) | soak `reopen-older-file`, `empty-then-load` (both failed with it: Cee lost the song's markers) |
| (this doc) | docs/rt/rt-fixlive1.md | |

## Each bug: cause, fix, test

### 1. A delete-all right after another deletion was put back (sync2c c1.4b)

**Cause.** rt-guard's empty-project rule lets a deletion out of a project with no tracks only with "a new undo point of someone's on top since
the last look" (`w.new_point`). `mirror.watch` decided that by the undo top's name changing; two "Remove tracks" in a row are one name, so
the second wasn't new, the project waited `EMPTY_SECS` and the studio's tracks came back with nothing sent. `mirror.user_edited` had the
same blind spot.

**REAPER, checked.** REAPER 7.79 added `Undo_GetNumEntries`, `Undo_GetCurEntry`, `Undo_GetEntryDesc`, `Undo_GetEntryTime` (the reaper skill's
`references/reascript.md` "Reading and navigating the undo history", the SDK header `reaper_plugin_functions.h` lines 7823-7852, and the
skill's API index). Read on the desktop's REAPER 7.86 (one read-only eval, nothing changed): entries are oldest first (0 = "--- Initial
state ---"), `Undo_GetCurEntry` is the top point, its description equals `Undo_CanUndo2`, and times are whole seconds.

**Fix.** `mirror.undo_top(proj)` returns the name and a key: name, current entry index and that entry's time (the name alone before 7.79).
`w.new_point` and `user_edited` compare keys. A second point of the same name has a new index (or, with the history full, a new time).

**Test.** `test_0_60_rt_guard` 9: Keys deleted ("Remove tracks", entry 1), 17 s later every track deleted ("Remove tracks", entry 2): it
stays deleted and reaches Bee. On 52ce885's `lib/mirror.lua`: "the delete-all stays deleted here (was: put back after EMPTY_SECS): Gtr,
Drums". The stand-in REAPER (`tests/fixtures/editreaper.lua`) gained `Undo_GetCurEntry` (`F.undo_n`) and `Undo_GetEntryTime`.

### 2. A reopen in the same tab wasn't seen (sync2c c3)

**Cause.** rt-sync2c's 7a948e2 told a new opening by the master track pointer (`mirror.on_open`), as `sync.settled_for` and W.order's
timeline look did. REAPER keeps that pointer (and the project pointer) through File > Open in the same tab, Windows and Linux (c3, 2 of 2
each). Live sync's load guard did see those reopens ("'LV Checks' was loaded again in its tab").

**Fix.** A new opening is also: the load guard has settled again since the last look (`loadguard.loads`, which moves when REAPER was
loading or saving, or the tab's name changed) **and** none of the tracks the last look began with is still a valid track. A save keeps the
tracks (not an opening); a deletion doesn't move the guard. `mirror.opened[proj]` is now a new table per opening (master, loads, tracks).
W.order's "opened behind the song" timeline look still goes by the master track: run on every opening (f3d9c00 did), it took a session.json
behind the room's in the soak's `reopen-older-file` and `empty-then-load` and Cee lost the song's markers, so 34f1ebe took it back (Known
limits).

**Test.** `test_0_60_rt_guard` 10: a save (guard count up, tracks kept) with a deletion just before it: the deletion still goes (fails with
the tracks check knocked out: "a deletion saved before the look still goes (0)"); File > Open of an older file in the same tab (the stand-in
keeps the master track, as REAPER does; guard count up): a new opening (fails on 52ce885).

### 3. The tracks an older file lacks came back only with the catch-up (sync2c c1.2, c2)

**Cause.** `sync.settled_for` caches which event files a project has applied, reset only on a new master track. After an older file opened
in the same tab, the cache still said "applied", so the receive didn't look at the changes the file's own applied list lacks; only the heal
(after 60 s of differing, at most every 300 s, tab in front) brought them.

**Fix.** The cache also starts afresh when `mirror.opened[proj]` (the opening, bug 2) changes. The next receive lands every change the
older file hasn't applied, as a fresh REAPER on an older file already did (c1.1, 6 s). No heal needed.

**Test.** `test_0_60_rt_guard` 10: Bee's Bass, made after the file was saved, is back right after the reopen's first receive, and Gtr,
deleted after the save, goes. Fails with this commit knocked out and with bug 2's ("Bass is back at once ...: Drums, Keys").

### 4. Bandmates' track moves landed while this computer played (sync2c c11)

**Cause.** `mirror.apply` reordered a moved track at once whenever the tab was in front; rt-sync2c check 11's spec says never while playing.

**Fix.** While playing or recording (`GetPlayStateEx & 5`), apply leaves the track where it is, as it does for a tab behind, and owes the
order (`mirror.order_owed`), which `mirror.watch`'s `keep_order` puts right on the first look stopped, in front and caught up (up to the
10 s look beat after the stop). `sync.receive`'s whole-order sort after a landed track owes it the same way rather than being skipped by
`keep_order`'s own play check. Paused counts as stopped.

**Test.** `test_0_60_rt_rank` 13: Bee plays; James moves Keys to the top; Bee's order stays while playing, nothing of hers is sent; at the
stop it's Keys first. Fails on 52ce885 ("Bee's tracks stay put while she plays: Keys, Drums, Bass, Gtr").

### 5. StudioSync's Undo of a deletion left a "(yours, not sent)" duplicate (sync2c c12, sync2e e4)

**Cause.** When a bandmate's deletion lands on a track with new work of yours, `mirror.apply` moves that item to "<track> (yours, not sent)"
and clears its id. StudioSync's Undo then brings the track back with that take (41980c2): the take lands as a new item, and the kept copy
stays beside it, on whichever side made the take.

**Fix.** Each item moved aside with no unsent edit in it is noted with the version it held (`mirror.kept_aside`). When an item version lands
and no item carries its id, and it is that very version, the kept item is taken back onto the track (its chunk set from the band's version
as any landing) and the kept track goes once empty. Another version (an edit since) leaves yours kept.

**Test.** `test_0_60_rt_reopen` 6: Bee deletes Gtr, James records a take on it and gets the deletion (take kept aside), Bee's Undo: James ends
with Gtr and his take, no kept copy. Fails on 52ce885 ("... Drums, Keys, Gtr, Gtr (yours, not sent)").

### 6. The switch-over lines and versions came back for every new track (sync2c c5, sync2d d1)

**Cause.** The live checks empty the song between scenarios, so each scenario's tracks were an empty room's first tracks. W.order gives a new
track a rank only in a room that already has one, so they went out unranked; `keep_order` then ran `rank_room` (the one-time switch-over),
which ranked them with a second auto version ("N track(s) given their place as a rank") and, once the room had ranks, a third for the
folder ("... given their folder as a parent").

**Fix.** W.order ranks an empty room's first tracks at once by place (`rank.spread`, as `rank_room` does), when every track here is new
(never recorded), none ranked, nothing of the band's waits, and it isn't an opening's first look. W.send then marks their folder as meant
(`pk`), so the first version carries both. What's waiting (a listing of the room's events) is asked last, only once every track here is
new (e9e8fbb: asked first, it slowed every look of an unranked song).

**Test.** `test_0_60_rt_rank` 14: two tracks made in an empty room (both computers had looked before), three rounds of keep / receive: no
"given their" line, exactly two track events, each with rank and folder, the same ranks on Bee's. On 52ce885 both lines appear.

### The floor line (coordinator's add-on, live check floor f3)

`sync.floor_said` was set once per Lua state, so a computer below the floor, back at it, then below again (or seeing the floor rise) said
nothing. `sync.floor` now clears it whenever this computer is at the floor or the floor's level changes, and clears `sync.floor_held` (the
per-bandmate "their changes wait" line) when the floor rises. Clearing a bandmate's mark when their changes stop being held isn't done: held
changes stay in the room and are looked at every pass, so the mark would flip each pass. Health's "update floor" row read the floor through
`sync.floor_read`'s 10 s cache; it reads it afresh (a listing and a few small files) at each build (1 s panel, 2 s web). `test_0_61_rt_floor`
8 (fails on 52ce885: "below the floor: said once (0)", part 3 had used the one shot).

### "live audio on" with Mute me on

`liveaudio.on_words` picks the start line from `send_plan`: muted, deafened or push-to-talk reads "live audio on (muted): nothing of yours
goes to the others until you unmute (input N ...)". `test_0_60_rt_liveux`.

## Gates

| Check | Result |
| --- | --- |
| `tests/run.py --no-luals`, local time, at 34f1ebe | **fails 0** |
| the same, `TZ=UTC0` | **fails 0** |
| on the way | at f449736 (before 9dd3824 / e9e8fbb): `test_0_60_rt_delete_race` failed (an unguarded `w.pending`, fixed in 9dd3824) and `test_0_60_rt_bigproj` failed in both time zones. A/B alternating against 52ce885: 52ce885 5 of 5, final tree 0 of 5; bisected to 44af905 (055cec8 to 8c2edf4 pass as 52ce885 does); e9e8fbb 5 of 5. A real cost, not load: every look of an unranked song listed the room's events |
| `tools/soak/soak.py --scenario all`, at 34f1ebe | **19 of 19 as they say** (`rename-redo-claim` fails as it says). At e9e8fbb, 17: `reopen-older-file` and `empty-then-load` lost Cee's markers (the timeline look, 34f1ebe) |
| long soak, `range.py` from a fresh clone of 34f1ebe, 8 procs (no other `range.py` / `soak.py` running: checked before starting) | **237 of 237** (baseline 237) |
| soak --quick, detcheck (inside run.py) | ok, ok |

The commits after 34f1ebe are this doc only.

## Live scenarios that should now pass

The laptop is off and LinuxBox wasn't running (`live.py up --on d,x`: desktop answers, on 0.62.0; LinuxBox "isn't running"), and deploying
is the orchestrator's, so none was run. After deploying this build to the desktop and LinuxBox (`live.py restart`, then `live.py song`):

| Run | Expect |
| --- | --- |
| `live.py run sync2c -k c1.4b --on d,x` | pass: the delete-all asks "Delete 2 of the song's 2 tracks for everyone?" (the tool answers it) and goes |
| `-k c1.4c`, `-k c1.4`, `-k "c4 delete 1 of 4, and all"` | pass (c1.4c and c4's other cases as before) |
| `-k c1.2`, `-k c2` | pass, and fast: the missing tracks back within seconds of the second load (was 61-120 s) |
| `-k c3` | **still "fails"**: it checks the REAPER fact itself (the master track pointer differs), which hasn't changed. What matters now is that StudioSync sees the reopen: the log's "was loaded again in its tab" and c1.2's timing. Recommendation 1. |
| `-k c11` | pass: the desktop's order unchanged while playing, C, A, B after the stop (within the 40 s wait) |
| `-k c12`, `sync2e -k e4` | pass: no "(yours, not sent)" left on either computer |
| `-k c5`, `sync2d -k d1` | pass: no "given their place as a rank" / "given their folder as a parent" after the three new tracks |
| `floor -k f3`, `-k f6` | the "older than the studio's" line each time; the web row at the next Health build |
| the rest of `sync2c`, `sync2d`, `sync2e`, `askweb` | as before (all passed at 0.61.4) |

## Known limits

- **Bug 2's test of "really reopened"** is "none of the last look's tracks is still valid". A delete-all saved before the next look reads as
  a reopen (its deletion is put back, as for any opening); REAPER reusing every freed track's address for the reopened file's tracks would
  read as no reopen (the old behaviour). An empty project's save after a load-guard settle counts as a reopen (harmless: nothing to put back
  that the empty-project wait wouldn't). Upgrade if REAPER ever gives a per-opening id.
- **The timeline's "opened behind the song" look** doesn't run on a same-tab reopen (it never did: it goes by the master track). An older
  file's tempo map and markers opened in the same tab are then read as the file has them; whether that sends them as a change wasn't
  checked here. Recommendation 3.
- **The stash of unsent changes** (`mirror.restore_unsent`) is still read once per master track, so an older file opened in the same tab
  doesn't get this session's unsent changes put back into it. Left so on purpose: whether a deliberate File > Open of an older file should
  bring them back is a design question.
- **Undo before REAPER 7.79** falls back to names (bug 1 stays there). Every computer here runs 7.86.
- **Moves while playing (bug 4)** also wait for StudioSync's own Undo / Restore and put-backs (every caller of `mirror.apply`), not only
  bandmates' moves: a person who presses StudioSync's Undo of a move mid-song sees the track move at the stop. Folder depths are still
  written at once (as for a tab behind). The mouse-button half of check 11 is unchanged.
- **The kept take (bug 5)** goes back only when the very version kept lands; if anyone edited the take while the track was gone, the edited
  version lands and yours stays kept (as designed: they differ).
- **Bug 6** covers an empty room's first tracks. New tracks made while the band's tracks are still on their way here (`pending` > 0) in an
  otherwise empty project, or in a room whose tracks are unranked for another reason, still go through `rank_room` (its lines once).
- **Floor:** a bandmate's "their changes wait" line comes again only when the floor rises, not when that bandmate updates and later falls
  behind again at the same floor.

## Recommendations (ranked)

1. **Change `tools/live/sets/sync2c.py` c3 to check what StudioSync does**, not the REAPER fact: after File > Open in the same tab, the next
   look is an opening (a debug hook reading `mirror.opened[proj]` before and after, or the receive's catch-up time as c1.2 measures). As
   written it fails for ever.
2. **Run `sync2c`, `sync2d -k d1`, `sync2e -k e4` and `floor` after deploying** (the table above), and `sync2c -k c2` with the laptop's TONEX
   when it's back.
3. **Check the timeline on a same-tab reopen of an older file**: a live scenario (open a file saved before a tempo change in the same tab:
   does the old tempo go out?) and, if it does, the timeline look on mirror.on_open's openings with session.json's own stamp checked first
   (the soak's two scenarios show what goes wrong without that).
4. **A live scenario for the save case** of bug 2: delete a track and save (Ctrl+S) inside a second, on a big song where the look lags: the
   deletion must still reach the others. The suite's guard 10 covers it on the stand-in only.
5. **Give `rank_room` the folder in the same version when it ranks a room with no ranks** (REAPER's own parent there), so the genuine
   switch-over (old songs) writes one version per track, not two.
6. **Re-read the stash of unsent changes on a same-tab reopen or say why not** (Known limits): decide with James whether File > Open of an
   older file should keep this session's unsent work.
