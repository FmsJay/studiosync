# rt-sync2f: times in beats (rt-sync2 phase 5) (2026-11-27)

An item's and automation's times now travel, and are hashed, in the units their timebase keeps fixed: quarter notes, and fractions of the
item's length. A tempo change leaves all of that as it was, so **it sends nothing but the timeline change**, claims nothing, and a version
lands on the same beat on every computer whichever arrives first, it or the map. REAPER's own `TimeMap2_*` places things, gradual tempos
included. The map-move machinery that tried to tell REAPER's moves from people's (tempo windows, map stamps, waits, re-time guesses) is gone;
a reader for older history stays. On top of rt-floor (05b3a0e) and rt-live (e28aa82, the live-check tool). Nothing here was run in REAPER: the Live checks below are written for the
live-check tool.

## Summary for James

- **Changing the tempo sends only the tempo change.** Items, automation and sends that REAPER moves with it are no longer re-sent by your
  computer, and nobody's track gets auto-claimed for it (the desktop's 90 bpm marker once sent 11 items and claimed three tracks).
- **Edits and tempo changes made at the same time end the same everywhere.** A part edited on the laptop while the desktop changed the tempo
  sits on the same beat, the same length in beats, with its fades, snap offset and stretch, on every computer, in either arrival order.
- **Gradual tempo changes work.** Before, any map with a gradual change wasn't converted at all, so a part made under another map stayed at its
  old seconds there.
- **Long tempo maps work.** Before, a map of more than 64 markers wasn't carried, with the same result.
- **Updating sends nothing.** Your rooms' history is read the new way: the first look after updating finds everything as the studio has it.
- **Not yet seen in REAPER.** The one thing that matters most: StudioSync puts band audio on REAPER's auto-stretch, and whether REAPER keeps
  such an item's rate in step with its length at a tempo change decides whether those items stay quiet too. Live check f4 says.
- **Update every computer together.** This build is StudioSync level 12 (format 2): a computer still on level 11 is below the studio's
  floor, sends nothing, and holds these changes until it updates ("update StudioSync and it lands").
- **The long soak passes all 237 seeds** (236 before, 15057 failing), the 19 scenarios as they say, and the test suite in local time and UTC.
- **15057, the last long-soak failure, wasn't StudioSync's**: the soak's own stand-in dropped an argument, so its timeline changes were
  never ordered as Live sync orders them. Fixed in the soak.
- **Three Undo bugs the soak found on the way are fixed** (the beats change sent fewer events, so the soak ran other histories): an Undo
  then Redo of moving an item onto a track a bandmate deleted at the same moment left the item in the song (9040); an Undo of a folder
  track's rename could put it back in a folder it had left (9033), or leave the folder's child out of it (9018), on the undoing computer
  alone.

## Commits

| Commit | What | Tests that fail without it |
| --- | --- | --- |
| 4075de0 | the soak orders timeline changes as Live sync does: its `sync.post` wrapper passed four arguments and dropped the project (15057) | `tools/soak/scenarios/timeline-order.json` (the Chorus region left on James and Cee) |
| 9ffe5a2 | times in beats: `lib/beats.lua` (new), the look and apply through it, the legacy reader, the removals, format 2 / hv 12 / level 12, the stand-in's `TimeMap2` with gradual tempos and REAPER's move by timebase, the soak driver's gradual tempos | `test_0_61_rt_beats` 1-7 (see Tests), `tempo-env.json`, `tempo-ramp.json` |
| 5eabf4f | Undo and Redo leave an item that went with a track a bandmate deleted since (long-soak 9040, found once beats moved the soak's histories) | `tools/soak/scenarios/undo-gone-with-track.json` |
| e681a6e | a move is taken back only from the versions between (`mirror.moved_since`; long-soak 9033, the same way) | `test_0_61_rt_beats` 8 |
| 69cb230 | a track put back by Undo or Restore in a room with ranks sorts the order after it (`mirror.order_owed`; long-soak 9018, the same way) | `tools/soak/scenarios/seed-9018.json` |
| f9e3f73 | the soak's oracle compares tempo maps and markers within 2e-6 s (long-soak 15055: one place 1e-12 s apart across the 1e-6 rounding) | the soak's self-check, "the timeline compare" (in `--quick`, so `tests/run.py`) |
| (this doc) | docs/rt/rt-sync2f.md | |

Nothing of `lib/webui*` (the uncommitted edits there are someone else's) or `tools/live/`. One new lib file, `lib/beats.lua`
(`lib/files.txt` is made at release by `tools/make_index.py`: files_check notes it, as before). No version bump, nothing pushed.

## 15057: markers, and the soak's

The failing difference was a region: Bee deleted the Chorus region in the second after James's tempo change had landed on her, and only Bee
ended without it. `sync.post` orders a timeline change after the newest one seen in its project (time..id, else that change's order plus
"+"), when it's given the project as its fifth argument. Live sync passes it. The soak's node wrapped `sync.post` (its deletion check) as
`function(c, song, room, ev) ... return post(c, song, room, ev) end`, so in the soak no timeline change was ever ordered (`order` and
`built_on` absent from every one): Bee's change, made after James's, sorted before it by its id (`Bee-` < `James-` in one second), and
James and Cee passed over it as older. Not beats, and not a StudioSync bug. The wrapper now passes every argument on. Markers as objects
(rt-sync2e Recommendation 5) is still worth doing for concurrent marker edits; it wasn't needed for 15057.

`tools/soak/scenarios/timeline-order.json` makes it by hand: both looks in second 30, clocks unskewed. It fails without the fix ("the
Chorus region is still here" on James and Cee) and passes with it.

## The wire form, and why

**Format 2: the canonical text in place of the seconds.** rt-sync2 planned phase 5 as format 1 with both forms (`state` in seconds for old
computers, `tm`, plus `beat` / `tmid` fields) and format 2 at the floor (phase 10). With no old computers to serve (James, 11-27) and the
floor keeping them out, the simplest correct form is the one form: an item's and automation's `state` is its canonical text. Why it's
simpler and safer than format 1:

- **One text is what's compared, hashed, merged and stored.** With seconds plus a `beat` side field, every merge needed the three versions
  put on one map first (event_file's old map branch), every hash a projection, and two fields could disagree. With the canonical text,
  `mirror_merge` merges it as it is (a move is a POSITION change, a resize a LENGTH change, in any map), the judge and the records see one
  thing, and a merge is the same on every computer by construction.
- **The boundary is two places.** `mirror.item_state(s)` and the look's automation read REAPER's seconds into the canonical text (`beats.read_item`,
  `beats.read_env`); `mirror.apply` writes it back as seconds on the map in place (`beats.write`). Everything between is unchanged code.
- **No map travels.** `tm` (about 70 bytes per tempo point on every item change, cut at 64 points) and the `tl` stamps are gone; nothing
  needs `tmid`, because nothing is in seconds.

The canonical text (`lib/beats.lua`):

| Timebase (the item's BEAT, else its track's C_BEATATTACHMODE, else the project's) | Canonical text |
| --- | --- |
| 0 time | the seconds as REAPER writes them, no mark |
| 2 beats (position only) | `BANDBEAT 2` after `<ITEM`; POSITION in quarter notes |
| 1 beats (position, length, rate) | `BANDBEAT 1`; POSITION and LENGTH in quarter notes; SNAPOFFS and each FADEIN / FADEOUT length and auto length as fractions of the length; an audio take's PLAYRATE as source seconds per item (rate x length); a MIDI take's PLAYRATE as it is |
| automation and sends, project timebase 1 or 2 | `BANDBEAT <tb>` first; each PT time, POOLEDENVINST / BANDAI place (and in 1 its length), BANDAIPT time in quarter notes; automation with no times carries no mark |

Quarter notes to 1e-6, fractions and rates to 1e-9. What a computer writes reads back as the same text: places and lengths come back on their
1e-6 grid; a fraction-derived value is written to the microsecond only when that still reads back as the same fraction with this computer's
length (a receiver's length can differ from the sender's in the 7th digit; see the long soak below). Items set to time, and projects in time,
keep their seconds: REAPER doesn't move them, and neither does StudioSync.

Sends (`recv`) are in beats too: their envelopes and automation items move with the tempo like a track's (rt-sync2 left them out; they were
re-sent at every tempo change).

**Order of arrival.** An edit made under a map that hasn't reached a computer lands at once, in seconds on that computer's map; when the map
lands, REAPER moves it keeping its beats. Landing after the map, it's placed on the new map. Both give the same place, so `sync.map_waits`
went (and with it REAPER check F6's double stretch can't happen: nothing waits, nothing is moved twice).

## What was removed, and what stayed for history

Removed (`lib/mirror.lua` unless named):

| What | It did |
| --- | --- |
| `TEMPO_SECS`, `tempo_until`, `tempo_from`, `tempo_changed` (and its calls in `lib/sync.lua`) | the 15 s window after a tempo change in which moves were taken for the map's |
| `map_moved`, `only_map_moved` | "is this only the map's move?" against the band's version |
| `map_landing` (its calls in `lib/sync.lua`: a landed map is now just `band.apply_tempo`) | two full project reads per landed map, re-recording what REAPER moved |
| `map_stamp`, `tl` on changes, `sync.map_waits`, `sync.MAP_WAIT` | a change waited up to 30 s for the map it was made under |
| `map_tag`, `tm` / `tb` on changes, `MAP_MAX` | every item and automation change carried its map, up to 64 points |
| `W.send`'s `tempo_only` / `retimed`, `look_reading`, the look's `look_was` / `map_now` / `N.map` | telling a tempo change's move from an edit at the send |
| `W.refuse`'s map branch | "the tempo changed and REAPER moved this: nobody's edit" |
| `state_on`, `on_map`, `retimed_here`, `snap_to` | putting a version on the map in place at apply; merges of near-equal places |
| `event_file`'s map branch | the three versions of a merge put on the winner's map first |
| `moved_by_map`, `env_same_but_times`, `env_sans_tempo`, `sans_tempo`, `same_words` | the comparisons all the above used |
| `retime`, `retime_env`, `map_qn`, `map_time`, `maps_ok` | the step-only conversions (they skipped any gradual map) |
| `only_retimed` | apply's guess that a just-sent change was only a re-time (a track deletion from an older StudioSync) |
| `opts.retimed` (`lib/undo.lua`, `lib/page_restore.lua`, `mirror.revert`) | an Undo that put a map back skipped the edited-here check |

Stayed, for history only (nothing writes these now):

- **`mirror.legacy_beats`** (called by `plain_event`, so every event read): a format-1 item or automation version that names its map (`tm`,
  `tb`, written since rt-converge) is read into beats by that map (`beats.upgrade`, pure list maths with gradual tempos). One with no map
  (before rt-converge) keeps its seconds, which land as they are (the rule for those versions before too).
- **`mirror.revert`'s `map_of`** (History's Restore): a version with no mark is read into beats by the map it names, or the one History says
  it was made under.
- **W.one's re-anchor in beats**: a record holding a hash version 11 hash whose event reads, in beats (with its map, or on today's map if it
  names none), as what's here is re-anchored, not sent. This is what makes updating send nothing.
- **`retimed` in merges** (`event_file`'s `only_w` / `only_l`, receive's words): a side that an older StudioSync sent as only a tempo map's
  move brings nothing to a merge (rt-fix9). Kept because a merge's base may be a version from before maps were named (in seconds) against
  sides read into beats: the units differ, and without the rule the map's side "changed the timing".
- **`mirror.time_on`** (markers under one map onto another: `sync.undo_timeline`): kept, now on `lib/beats.lua`'s maths, gradual tempos
  included.
- **histhear's `map_of` / `tl`**: History's preview places a version from before by the map it was made under; one in beats is put in
  seconds on the map then (`then_map`) and placed there.

## hv, LEVEL and FORMAT

- **`mirror.HV` 12**: what an item's and automation's hash covers changed (the canonical text).
- **`band.FORMAT` 2**: an item's and automation's `state` is canonical. A format-1 StudioSync holds a format-2 change as too new
  (`sync.too_new`) rather than reading quarter notes as seconds.
- **`sync.LEVEL` 12**, with them (rt-floor's rule: a hash or format change raises the level). The first computer on this build records floor
  12; a level-11 computer is below it and sends nothing until updated (rt-floor). History in format 1 reads as before (`legacy_beats`).

## The soak's stand-in

- `tests/fixtures/editreaper.lua`: `TimeMap2_timeToQN` / `TimeMap2_QNToTime` count gradual tempos (a linear point ramps to the next point's
  tempo; the beats between are a trapezoid's); a tempo edit moves each item by its timebase as REAPER does (the item's BEAT, else its
  track's `C_BEATATTACHMODE`, else the project's): 1 keeps place and length in beats and stretches what's inside (snap offset, fades, an
  audio take's rate by the inverse), 2 keeps its place, 0 stays; markers after an edited one keep their beats, a gradual change into one
  included. A track's `C_BEATATTACHMODE` reads -1 (the project's) unless set, as REAPER's new tracks.
- `tools/soak/node.lua`: REAPER's move is the fixture's (it was `mirror.retime`'s, which skipped gradual maps); a third of the driver's tempo
  edits are gradual (`r[4] < 0.3`, a draw the tempo edit didn't use).

## Tests and knock-outs

`tests/test_0_61_rt_beats.lua`, each part knocked out in a scratch copy of the tree (the piece taken out, the test run):

| Part | What | Knocked out -> fails at |
| --- | --- | --- |
| 1 | pure: canonical forms by timebase and back (fades, snap, audio and MIDI rates; automation, automation items); gradual-tempo maths against the closed form and the stand-in's TimeMap2; a receiver's render reads back as it travelled; the stand-in keeps markers on their beats past a gradual change | seg_q's gradual branch -> "quarter notes through and past a ramp"; mode-1 fractions -> "fades and auto lengths as fractions"; the render's read-back check -> "read back as it travelled (1.0000002)"; the stand-in's trapezoid -> "the marker after it keeps its beat" |
| 2 | a step, the first tempo and a gradual tempo each send nothing but the timeline and claim nothing; an item set to time stays; a mute made with a tempo change goes and claims | the look's items in beats -> "nothing but the timeline goes out (2: I-...)"; the look's automation in beats -> the same (1: E-...) |
| 3 | an edit (length, fade, snap offset, rate, an automation point) crossing a tempo change, a step and a gradual one: the same beats and inner fractions on all three computers, Cee getting the edit before the map | apply's `beats.write` for items -> fails at the song itself ("Beats2: the song: I-... differs"): a version in beats written as seconds |
| 4 | a format-1 version with `tm` reads into beats and lands on its beat at 60 bpm, its fade with it; with no map, its seconds; automation likewise | `plain_event`'s `legacy_beats` -> "read into beats by its map" |
| 5 | records of hash version 11 over format-1 versions (half with `tm`, half without): the first look sends nothing and records each in beats | W.one's item read in beats -> "the first look after updating sends nothing (2: I-...)"; its automation compare -> the same (1: E-...) |
| 6 | format 2, hv 12, level 12; a format-1 reader holds a format-2 change; format-1 history isn't held | `FORMAT = 1` -> "format 2, hash version 12, level 12" |
| 7 | History's preview: a version in beats in seconds on the map then, placed under it | histhear's `then_map` branch -> "in seconds on the map then" |
| 8 | `mirror.moved_since`: a walk by a merge's winner that never reaches the version meant takes back nothing; a move between still is | the reach check -> "a walk by the merge's winner ... takes back nothing" |
| scenario | `undo-gone-with-track.json`: James moves an item onto Keys while Bee, offline, deletes Keys; the undo probe | revert's gone-with-its-track rule -> "James's Undo then Redo didn't bring the song back" |
| scenario | `seed-9018.json`: the long soak's 9018, frozen (all 150 edits: the shrink kept them all) | revert's `order_owed` -> "after Bee's undo ... T-BEE-... differs" (at e681a6e) |

Every knock-out above was run: all fail as listed.

Changed tests (each pinned something removed, or an old expectation the change reverses):

- `test_0_59_39`, `test_suggest`: "a move only the tempo made is the same part" now in beats (`beats.env`, `beats.item`).
- `test_0_60_rt_p1b` parts 1-2: `mirror.retime` / `retime_env`'s numbers, now from `beats.upgrade` + `beats.seconds_on` (a shim in the
  test); a lone gradual point is converted (it holds its tempo) where it was left as stored.
- `test_0_60_rt_converge` 1a-1c (a version onto another map, apply on the map in place, merges across maps: now beats and the legacy
  reader), 33a (pure, in beats), 33b (Bee's tempo change re-sends nothing now: the band's item is still James's), 34 (merges read through
  `seconds_on`), 25 (a fabricated version's place in quarter notes).
- `test_0_60_rt_edits`: the first-tempo case sends nothing but the map (min 0); REAPER check F6 rewritten (only the map goes out; an edit
  made under a map that hasn't reached LinuxBox lands at once and ends as long as on the desktop; the `MAP_WAIT` part went); the Restore's
  pure checks on `beats.upgrade`; automation's first version in beats; round 7: a tempo change sends nothing and claims nothing.
- `test_0_60_rt_answers` (no `opts.retimed`; map_of still handed over), `test_0_60_rt_claims` (the send's claim line), `test_0_60_rt_judge`
  (a track move is a hash change), `test_0_60_rt_delete_race` (no re-time guess: Bo's own-built version is his work, his merge goes with the
  track), `test_0_60_rt_folders` / `test_0_61_rt_floor` (hv), `test_0_60_rt_nohold` (an event's place read in seconds).

## Gates

From fresh clones under the scratchpad, one long soak at a time (no other `range.py` / `soak.py` running before each was started).

| Check | before (05b3a0e / 4075de0) | e681a6e | 69cb230 | f9e3f73 (final) |
| --- | --- | --- | --- | --- |
| long soak, 237 seeds at 150 edits, 8 procs (`range.py`) | 05b3a0e: 236, 15057 (rt-floor's baseline). 4075de0 (the soak fix alone): **237** | 236: 9018 | 236: 15055 (the oracle's rounding, below) | **237 of 237** |
| `soak.py --scenario all` | 05b3a0e: 15 of 15 as they say (`tempo-env` saying "fails") | 18 of 18 | 19 of 19 | **19 of 19** as they say: `tempo-env` (by hand) passes; `tempo-ramp`, `timeline-order`, `undo-gone-with-track`, `seed-9018` new and passing; `rename-redo-claim` fails as it says |
| `tests/run.py --no-luals`, local time | 4075de0: fails 0 | fails 0 | fails 0 | **fails 0** |
| the same, `TZ=UTC0` | | fails 1: `test_0_60_rt_bigproj` (32.0 ms against 31, the suite's other work running); A/B, alternating, nothing else running: e681a6e 5 of 5 pass, 3ab996c 5 of 5 pass | **fails 0** | (f9e3f73 changes only `tools/soak/soak.py`: 69cb230's run stands) |
| soak --quick, detcheck (inside run.py) | ok, ok | ok, ok | ok, ok | ok, ok |

**The targets, before and after.**

| Target | Before | After |
| --- | --- | --- |
| long-soak 15057 ("tempo map / markers differ") | fails at 05b3a0e: Bee alone without the Chorus region (her deletion, made after James's tempo change landed, sorted before it: the soak's `sync.post` wrapper dropped the project) | passes (4075de0 onwards); `timeline-order.json` fails without the fix |
| `tempo-env.json` | a frozen seed (13007, E differs) that passed or failed by the soak's draws ("fails" at 05b3a0e, passing by luck at 4075de0) | made by hand (70 tempo steps crossing an edit and an automation point): on 4075de0's lib with this round's stand-in it fails on all three computers (Gtr on quarter note 57.67, the point on 38.375, where Bee put them on 60 and 40); passes now |
| rt-sync2's 15033 class (a part's timing differing on one computer after tempo changes) | tm/retime: step maps of up to 64 points only, a merge's sides put on one map first | 15033 passes in every long soak here; the class is `tempo-env.json` (automation and an item crossing a map) and `tempo-ramp.json` (a gradual map: on 4075de0's lib Bass 2 on quarter note 17.92 and the point on 11.25 everywhere, not 20 and 12; passes now) |

**On the way.** A long soak of the beats change before the read-back check and the stand-in's marker fix (the tree only, not a commit):
216 of 237. The 21 were a fade's fraction read across a rounding step on one computer (5022, 5024 and others: a receiver's length differs
from the sender's in its 7th digit, and its fade put back to a round 0.01 read as another fraction), the stand-in's markers after a gradual
change (13005: placed as if the ramp stopped, the map out of order), and 9018, 9033, 9040, 9041. With the read-back check (`beats.item_seconds`'
`snapped`) and the stand-in fix (both part 1) the next run had 234: 9018, 9033, 9040, all the undo probe's and none about items' times: the
beats change sends fewer events after tempo changes, which moves every later network draw of a seed (as rt-floor's floor file did), so the
soak ran histories it hadn't. 9040 (5eabf4f), 9033 (e681a6e) and 9018 (69cb230) are fixed, each with its scenario or test part. 69cb230's
own extra events (the order sort after an Undo) moved the draws once more, onto 15055: after Bee's Undo of a tempo change, a marker's place
read 49.742042 on James and 49.742043 on Bee and Cee, the same place 1e-12 s apart (StudioSync's `mirror.time_on` on one computer, the
stand-in's REAPER move on the others) across the oracle's 1e-6 rounding; the oracle now compares timelines within 2e-6 s (f9e3f73), as it
already compared objects (noise()). One preview run couldn't be stopped early (stopping its processes was refused by the permission
system); it was left to finish.

## Live checks

For the live-check tool (`tools/live/`, e28aa82; a set `sets/sync2f.py` to be written by its owner, not here). Computers as the tool names
them: **d** (desktop), **l** (laptop), **x** (LinuxBox, the Mac's stand-in). Before each: `setup(ctx)` (the song open and in front, live
audio muted and deafened), every computer on this build (`live.py up` shows it), and in each REAPER the project timebase beats (position,
length, rate): `reaper.GetSetProjectInfo(P, "PROJECT_TIMEBASE", 1, true)`. Tracks are the scenario's own (`add(ctx, "d", "Gtr", "Drums")`,
named `LV <scenario> <name>`): Gtr holds one audio item (`LV`'s generated WAV) at 10 s, 6 s long, fades 0.01 s, rate 1; Drums has volume
automation with points at 0, 4, 8, 12 s. `QN(t)` below is `reaper.TimeMap2_timeToQN(P, t)`. "x crosses" means `x_syncthing(True)` and
`x_cut(True)` (x's Syncthing paused and its link cut, `sets/_lv.py`) for the step, then both undone and `ctx.quiet()`. Every scenario ends
with the tempo put back (one marker, 120 bpm: `band.apply_tempo(P, {{time=0,bpm=120,num=4,denom=4}})` on d, then `ctx.quiet()`) and its
tracks cleaned up as the tool does. Edits go in undo blocks named as REAPER names them ("Edit tempo map", "Item properties", "Add point").

1. **f1 a tempo change sends only the timeline** (rt-r4's bug B).
   - marks = `ctx.log_marks()`; note each computer's newest event file. d: a tempo marker of 100 bpm at 4 s
     (`SetTempoTimeSigMarker(P, -1, 4, -1, -1, 100, 4, 4, false)`, "Edit tempo map"). `ctx.quiet()`.
   - Read back: the event files written since, by user and `type` / `obj`; each computer's claims file before and after; `ctx.log_since`.
   - Pass: one new event, d's `type = "timeline"`; no `obj` event from anyone; no claim added for d; no "came out different" in any log.
2. **f2 a cross-map landing with fades, snap offset and rate.**
   - x crosses. Meanwhile d: the 100 bpm marker at 4 s; x (still on 120): Gtr's item `D_LENGTH` 7.5, `D_FADEINLEN` 0.75, `D_SNAPOFFSET` 1.25,
     its take's `D_PLAYRATE` 0.8 ("Item properties"). Undo the crossing; `ctx.quiet()`.
   - Read back on d, l, x: p = `D_POSITION`, l = `D_LENGTH`, f = `D_FADEINLEN`, s = `D_SNAPOFFSET`, r = the take's `D_PLAYRATE`.
   - Pass: on all three QN(p) = 20 and QN(p + l) - QN(p) = 15 (to 1e-5); f / l = 0.1 and s / l = 1/6 (to 1e-7); r x l = 6 (to 1e-6); the
     three agree to 1e-6. Fail otherwise, naming the computer that differs (x is the one whose edit met the map after it).
3. **f3 a gradual tempo.**
   - x crosses. d: `SetTempoTimeSigMarker(P, 0, 0, -1, -1, 120, 4, 4, true)` then `SetTempoTimeSigMarker(P, -1, 16, -1, -1, 80, 4, 4, false)`
     (120 to 80 over 16 s). x (on 120): Gtr's item to 10 s (QN 20); a Drums volume point at 6 s of value 0.25 (QN 12, "Add point").
     Undo the crossing; `ctx.quiet()`.
   - Read back on d, l, x: QN(p) for Gtr's item; the time t of the Drums point of value 0.25 and QN(t); `GetTempoTimeSigMarker(P, 0)`'s linear.
   - Pass: QN(p) = 20 and QN(t) = 12 (to 1e-5) everywhere, the first marker linear everywhere.
4. **f4 an auto-stretch item.**
   - d: Gtr's item `C_BEATATTACHMODE` 1 and `C_AUTOSTRETCH` 1 ("Item properties"); `ctx.quiet()`.
   - Note the newest event files. d: a 90 bpm marker at 12 s (inside the item). `ctx.quiet()`.
   - Read back on d, l, x: p, l, r, and the take's stretch markers (`GetTakeNumStretchMarkers`, each `GetTakeStretchMarker`'s pos, srcpos);
     the events since.
   - Pass: only d's timeline event; p, l, r and every stretch marker equal on the three (to 1e-6). If an `obj` event went for the item,
     REAPER rewrote its chunk for the tempo (a known limit): `ctx.note` its chunk's lines before and after, and fail.
5. **f5 stretch markers.**
   - d: two stretch markers on Gtr's take (`SetTakeStretchMarker(take, -1, 1.0)`, `SetTakeStretchMarker(take, -1, 3.0, 2.5)`); `ctx.quiet()`;
     l and x read the same two (pos, srcpos to 1e-9).
   - x crosses. d: the 100 bpm marker at 4 s; x: Gtr's item 1 s later. Undo the crossing; `ctx.quiet()`.
   - Read back on d, l, x: the stretch markers, p, l.
   - Pass: the three agree to 1e-6, and no `obj` event from d for the tempo change. Fail otherwise (stretch markers are in item time: if
     they differ by the length's ratio, they need beats too, a known limit).
6. **f6 no claim from a tempo change, in Claims mode.**
   - The room in Claims mode; l claims Drums. d: a 110 bpm marker at 2 s. `ctx.quiet()`.
   - Pass: no ask (`LV.asks(P)` empty on l), nothing put back on d, no `obj` event from d, l's claim unchanged, d's claims file names
     neither Drums nor Gtr.
7. **f7 the same placement on Linux and Windows** (the Mac's own when it's back).
   - After 3, on d and x: `TimeMap2_timeToQN(P, t)` for t = 0.5, 7, 15.9, 16, 22.25, and Gtr's p and l.
   - Pass: equal to 1e-9 on d and x. Between 1e-9 and 1e-6: `ctx.note` it (the canonical form still agrees) and pass.
8. **f8 updating sends nothing** (the hv 12 switch-over).
   - Once, as every computer first starts this build together (`live.py restart`, then `song`). Note the newest event files; nobody
     edits for 120 s.
   - Pass: no `obj` event from any computer (W.one re-anchors history in beats). Fail: any item, automation or send event.

## Known limits

- **Take envelopes and stretch markers** stay in item time (seconds), as `mirror.retime` left them: a tempo change that stretches an item in
  beats (position, length, rate) changes how REAPER reads them, if it scales them, and they'd go out. Live checks 4 and 5 say whether REAPER
  does.
- **Auto-stretch** (`C_AUTOSTRETCH`), which StudioSync itself sets on band audio in beats (position, length, rate) (`band.follow_tempo`):
  read as beats (position, length, rate), its rate as source seconds. That holds if REAPER scales an auto-stretch item's rate with its
  length at a tempo change as for any item in that timebase, the stretch inside it worked out from the map; if it keeps the rate and
  stretches by itself, the rate times the length changes and such items would go out after a tempo change. Not known without REAPER: live
  check f4, first.
- **A project timebase other than 0, 1, 2** (if REAPER has one) is read as time.
- **Different timebases on two computers**: the project timebase travels in the project settings only where SWS reads it
  (`band.capture_project`'s `itemtimelock`); a track's travels with the track. Where they differ, each computer renders by the version's
  mark and reads back by its own, so its record holds its own reading and "came out different" may show once. Same as before (each
  computer's retime used its own project timebase), now visible.
- **Automation follows the project timebase**, not the track's (as before).
- **A version from before rt-converge** (no `tm`) has no known map: its seconds stand (as before), and a merge of it with versions in
  beats compares seconds with quarter notes; the `retimed` rule covers the one case history makes often (an older StudioSync's re-send
  against such a base). A merge where both sides changed timing across that base takes the winner's timing (a clash, as before).
- **A version from before with a track timebase** is read by the project's timebase it names (`tb`) and its own BEAT: the track's isn't in
  history.
- **The quarter-note grid (1e-6)** moves a received part by up to a quarter of a microsecond (at 120 bpm) from where its sender has it.
- **Web History's time lapse** draws an item's length from the change's `len` (seconds, since this build); one sent by an Undo or Restore
  has no `len`, and a beats item's LENGTH is in quarter notes, so the lapse keeps the length it had for it.

## Recommendations (ranked)

1. **Update every computer to this build in one sitting.** Level 12 / format 2: the first computer on it raises the floor, and a level-11
   computer then sends nothing and holds these changes as too new until it's updated (nothing it does is lost: rt-floor).
2. **Run the Live checks above** (a `sets/sync2f.py` for the tool), first f4 (auto-stretch: StudioSync sets it on band audio, so it's most
   items in a real song) and f5 (stretch markers), then f1, f2, f3 and f7.
   They answer the two things this round couldn't: whether REAPER rewrites an item's chunk (auto-stretch, stretch markers, take envelopes)
   at a tempo change, and whether TimeMap2 agrees across platforms past 1e-9.
3. **If f4 or f5 fail: stretch markers and take envelopes in beats too** (`lib/beats.lua`'s item form: their positions as fractions of the
   length in beats (position, length, rate), as the fades). About 30 lines and a part in `test_0_61_rt_beats`.
4. **Hand-made scenarios for 9033 and 9018** in place of the frozen `seed-9018.json` and part 8's events: a frozen seed is moved off its bug
   by any change before it (this round moved 9018 onto one). An Undo of a folder track's rename after a bandmate's concurrent change of it,
   and one whose version carries `moved`.
5. **The project timebase without SWS**: `band.capture_project` reads it through SWS (`itemtimelock`) only; `GetSetProjectInfo(proj,
   "PROJECT_TIMEBASE")` reads and sets it in plain REAPER, so two computers never read one item by two timebases.
6. **Markers as objects** (rt-sync2e Recommendation 5): 15057 turned out to be the soak's, but the timeline is still one newest-wins object,
   so two marker edits made at once lose one.
7. **`lib/files.txt`** gets `lib/beats.lua` at the next release (`tools/make_index.py`): files_check notes it until then.
8. **A later floor can drop the history readers** (`legacy_beats`, the `retimed` merge rule, revert's `map_of` for unmarked versions,
   W.one's re-anchor of hash version 11 records) once every room's history from before this build is past `lib/trim.lua`'s window and every
   computer has re-anchored (one full look after updating).
