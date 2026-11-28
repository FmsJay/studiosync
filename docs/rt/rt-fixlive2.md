# rt-fixlive2: four problems from the real-REAPER live checks (2026-11-28)

rt-sync2g's live checks found two problems on 0.63.1, and the coordinator's sync2f run on 0.64.0 (level 13) added two more: track automation
left in seconds at a tempo change (sync2f f1, f6), a reopen in the same tab caught only by the heal (sync2c c3, c1.2, c2), an auto-stretch item
whose tempo marker is edited (f4), and a take's own stretch markers (f5). This round finds each cause on the real REAPERs (desktop and
LinuxBox, 7.86) with probes, fixes it in StudioSync, one commit per fix with a test that fails without it. On top of 4a40505. Hash version and
level go to 14 together. Nothing deployed, released, pushed or version-bumped; `lib/webui.lua` and `lib/webui/index.html` (someone else's)
untouched.

## Summary for James

- **Opening the song's file again in its tab now catches up at once.** File > Open of a file with the same name happens inside one REAPER
  call, so StudioSync's load guard never saw it, and REAPER reuses the old tracks' addresses for the new ones. StudioSync now notices that the
  project's own record of what it has applied went back to the file's, which nothing else does. Before: the missing track came back with the
  heal, 62-290 s later.
- **Automation written by a script follows a tempo change.** The live tool wrote points into a track's volume envelope that had never been
  shown. REAPER doesn't count such an envelope as the track's, and leaves its points where they are at a tempo change, while everyone else's
  copy moved. StudioSync now makes such an envelope a real one the first time it sees it. It wasn't the song's tab, and nothing a person
  does in REAPER makes one.
- **An auto-stretch item stays quiet when you edit a tempo marker inside it.** Adding a marker already sent nothing. Editing it made REAPER
  keep the rate and stretch its own markers, and StudioSync read that as a change. The computers also ended up playing different stretches of
  the audio. Now it reads what REAPER keeps, the stretch of audio the item plays.
- **Hand-placed stretch markers stay quiet at a tempo change.** REAPER adds a marker at each end of the take the first time the tempo changes.
  StudioSync now reads the take as if those two were already there, since they're what plays anyway.
- **Seen live on 0.65.0 / 0.65.1** (desktop and LinuxBox): c3 3/3, c1.2 3/3, c2 parts 1-2 3/3 (all in 2-5 s), f1, f4, f5, f6, f8 pass (f4
  and f5 after updating two of the tool's own checks).
- **Update both computers together**: this build is level 14. A level-13 computer sends nothing until it updates. Updating sends nothing.
  The one exception: an auto-stretch item whose tempo marker was edited on 0.64.0 goes out once.

## Commits

| Commit | Fix | Test that fails without it |
| --- | --- | --- |
| 6012cf3 | problem 2: a file loaded into the tab is told by its applied marks going back (`sync.settle`, `sync.marks_moved`, `mirror.on_open`) | `test_0_60_rt_guard` 11 |
| 8da59a9 | problem 1: an envelope REAPER hasn't taken in, with points, made a real one (`mirror.lua` `realise_envs`); the stand-in models one | `test_0_61_rt_beats` 11 |
| cbbed01 | problem 3: an auto-stretch item's rate as the source REAPER's own markers cover (`beats.lua` `made_span`); hv 14, level 14 | `test_0_61_rt_beats` 10, 6 |
| 2faa603 | problem 4: a take's own stretch markers read with their ends (`with_ends`); hv 12/13 records without them re-anchor (`beats.ends_off`) | `test_0_61_rt_beats` 10, 12 |
| 300ce01 | problem 4, follow-up: written back, the ends left out where they only play what plays anyway (`ends_left`), so a receiver's chunk is the sender's (f5 on 0.65.0: 4 markers on LinuxBox to the desktop's 2) | `test_0_61_rt_beats` 10 |
| e628d7b | (tool) sync2f f4 compares the item as it plays (place, length, each marker's item time and source), not its rate | live sync2f f4 on 0.65.0 (fail -> pass) |
| 49c2a18 | (tool) sync2f f5 expects the take's own two markers plus REAPER's two ends after the tempo change, then checks nothing went out | live sync2f f5 on 0.65.1 (fail -> pass) |
| (this doc) | docs/rt/rt-fixlive2.md | |

## REAPER, measured

Every probe ran through the dev hook, each in one eval (Live sync can't run in the middle of one, so nothing was sent), in a scratch tab of
its own unless it says the song's tab. The scratch tab was closed clean, nothing was saved, and any WAV or .rpp the probe wrote was deleted.
Probe scripts: the session scratchpad (`probe_*.py`), results in `live/probe_*.json` / `.txt` there.

| What | REAPER 7.86 (Windows = desktop, Linux = LinuxBox) |
| --- | --- |
| a file opened again in its own tab (`Main_openProject`, same file) | the project and master track kept; the desktop gave the reopened tracks **all 4 old addresses** (LinuxBox: 1 of 4); ProjExtState back to the file's; the undo history reset (entry 0's time = the load, whole seconds); change count +1; clean |
| ProjExtState written inside an undo block, then Undo | **not** undone (and Redo leaves it too): only a load puts a project's marks back |
| a new track's volume envelope, never shown, points inserted through `GetTrackEnvelopeByChunkName` | `CountTrackEnvelopes` 0, chunk `ACT 0` `VIS 0` with the points; a 110 bpm marker at 2 s: **points stay** 0/4/8/12 s. Its chunk set back once (`SetEnvelopeStateChunk`): counted, and the points move (4.18/8.55/12.91). Both systems |
| the same envelope made any other way (track chunk, action 40406 first, `SetEnvelopeStateChunk`), ACT and VIS 0 or 1, the tempo set plainly or in an undo block, with or without a marker at 0 | points move, in a new tab and in the song's tab alike |
| the song's tab itself, the probe track by chunk, in front and behind | moves (8 -> 8.8, 12 -> 13.6), as a new tab; project values as rt-sync2g read them. `itemtimelock` written through SWS works both ways (0: points stay; 1: they move) |
| auto-stretch item (10 s, 6 s, 120 bpm), 90 bpm marker added at 12 s, then edited to 80 | added: rate x length kept (6), its markers `0 0 0 1 + 1.636 2 0 1 + 6 6 0 1`; edited: **rate kept** 0.818, length 8, end marker `6.545 6 0 1`: rate x length 6.545, the source covered still 6. Same chunks on both |
| that item's canonical text landed on a second item (rate = text / length, then C_AUTOSTRETCH off/on) | with the old reading (6.545): markers item 2 s -> src 2.18, 8 s -> src 6.545 (LinuxBox's divergence in f4); with the new (6): item 2 s -> src 2, 8 s -> src 6, the sender's exactly |
| a take with its own markers (`SM 1 1 + 3 2.5`), a 100 bpm marker at 4 s (before the item), then 90 at 12 s | the first change keeps rate 1 and each marker's beats and **adds one at each end**: `SM 0 0 + 1.2 1 + 3.6 2.5 + 7.2 5.5` (the source at each end what plays there anyway: 1 - 1 and 2.5 + (6 - 3)); the second keeps them on their beats. Same chunks on both |

## Each problem: cause, fix, test

### 1. Track automation stays in seconds at a tempo change (f1, f6)

**Cause.** The live tool's `LV.env_add` asks `GetTrackEnvelopeByChunkName(t, "<VOLENV2")` and runs REAPER's "show volume envelope" (40406) only when
that returns nothing. On a track made with REAPER's defaults it returns an envelope object at once, so 40406 never ran and the points went
into an envelope REAPER hadn't taken in as the track's (table above). REAPER leaves its points in seconds at a tempo change. Its chunk lists
it, so StudioSync sent it, and each receiver's copy, made from that chunk, is a real one that moves. The desktop's canonical text (quarter
notes) then changed at every tempo change, and the desktop sent it. That's why a new tab, a copy of the song's project, and the same track's
chunk copied anywhere all moved, and why rt-sync2g found every project setting equal.

How it was told apart (probe 4/6/7): in the song's tab with Live sync running, the tool's way kept seconds both before Live sync had seen the
track (one eval) and after it had sent it, so it wasn't StudioSync's doing. In the song's tab and in a scratch tab, making the envelope any
other way moved. In a scratch tab with no StudioSync at all, the tool's way kept seconds again, and `CountTrackEnvelopes` read 0.

**Fix (8da59a9).** `mirror.lua` `realise_envs`, called from `add_parts` once per track and envelope text: an envelope block with points in the
track's chunk whose object (`GetTrackEnvelopeByChunkName`) isn't among the track's envelopes gets its own chunk set back
(`SetEnvelopeStateChunk`), which makes it a real one that REAPER moves at a tempo change, as every receiver's already does. A person can't
make such an envelope, but any script that writes automation the tool's way can (a ReaScript or an MCP tool that writes points into a hidden
volume envelope).

The tool is left as it was on purpose, so sync2f f1 and f6 exercise this fix.

**Test.** The stand-in (`tests/fixtures/editreaper.lua`) gains `t.phantom[tag]`: such an envelope is in the chunk and left out of
`CountTrackEnvelopes` / `GetTrackEnvelope`, `GetTrackEnvelopeByChunkName` finds it, its points stay at a tempo edit, and `SetEnvelopeStateChunk`
takes it in. `test_0_61_rt_beats` 11: a script's automation in one on Gtr, sent; then a 110 bpm marker at 2 s: only the timeline goes out, all
three computers hash the same. With `realise_envs` taken out: "nothing but the timeline goes out (1: E-JAMES-...)".

### 2. A reopen in the same tab caught up only with the heal (c3, c1.2, c2)

**Cause.** rt-fixlive1 told a new opening by the load guard settling again **and** none of the last look's tracks still valid. Both halves
fail on real REAPER:
- File > Open runs inside one REAPER call (the menu's or `Main_openProject`). Live sync's tick never runs while REAPER is loading, and the
  tab's name doesn't change for the same file, so the guard doesn't settle again. c3 opens the song's own file.
- REAPER hands the reopened file's tracks the old addresses: all 4 on the desktop, 1 of 4 on LinuxBox (table above). So "none left" is false
  even when the guard did move (c1.2 opens another file name).
`sync.settled_for`'s cache then still said the project had applied every change, so the receive never looked at what the file lacked. Only
the heal brought it, after 60 s of differing and at most every 300 s. That gives 62/63 s, 190/290 s, 248 s, and never within 165 s once
the heal had just run.

**Fix (6012cf3).** Each settled cache keeps the last file it took as applied (`sync.settle`, both places a file is marked settled). Every
`settled_for` checks that file's applied mark is still in the project. A load is the only thing that takes a mark away (Undo doesn't:
measured). So a missing mark resets the cache and counts in `sync.marks_back[proj]`. `mirror.on_open` takes a move of that count for an
opening whatever the guard and the tracks say, after checking it itself, so the order of receive and look doesn't matter. Marks cleared on
purpose (`forget_trimmed`) forget the kept file first, and Try again already drops the cache. Cost: one ProjExtState read per events folder per
pass.

**Test.** `test_0_60_rt_guard` 11: James saves, Bee makes Bass, James makes Keep. Then James's song's own file is opened again with the guard
count not moving. Bee's Bass and James's own Keep are back at the next receive, in Bee's order. It's a new opening, nothing is sent, and Bee
keeps both. A later deletion still goes and isn't taken for an opening. On 4a40505: "Bee's Bass and James's own Keep back at once (was: only
with the heal): Keep, Drums, Keys, Gtr". With only the sync half: "a new opening".

### 3. An auto-stretch item at an edited tempo marker (f4)

**Cause.** rt-sync2g's form wrote an auto-stretch item's rate as rate x length ("source seconds per item") and left REAPER's own stretch markers
out. That's right when a tempo marker is added. When one inside the item is edited, REAPER keeps the rate and moves its own markers in take
time, keeping their source positions (table above). Rate x length went 6 -> 6.545, so the desktop re-sent the item. LinuxBox wrote rate
6.545 / 8 and made its markers from the map over 6.545 s of source, so it played a different stretch than the desktop.

**Fix (cbbed01).** For an auto-stretch item whose markers are all REAPER's, the canonical PLAYRATE is the source those markers cover, last
srcpos minus first, when they run from the item's start to its end. Otherwise it's rate x length, as before. Writing back is unchanged. The
desktop probe landed the canonical text on a second item, and its markers came out the sender's (item 2 s -> src 2, 8 s -> src 6).
`mirror.HV` 14, `sync.LEVEL` 14.

**Test.** `test_0_61_rt_beats` 10: REAPER's chunk after the edit (f4's numbers) reads as the item did before any change. On 6012cf3's
`beats.lua` it fails with `PLAYRATE 6.545454545`. Part 6 checks hash version 14 and level 14.

### 4. A take's own stretch markers at a tempo change (f5)

**Cause.** At the first tempo change that reaches a take with markers of its own (even a change before the item), REAPER adds a marker at
each end of the take with the source that plays there. The text gained two entries, so the item went out once (rt-sync2g's known limit).

**Fix (2faa603).** `beats.item` reads such a take (not an auto-stretch one) with those two ends added where they're missing. Each end's source
is the next marker's, running 1:1 in take time (what plays there anyway), written as REAPER writes it (`%.9f` trimmed). Written back, the ends
went into REAPER's chunk explicitly in 2faa603. That changed nothing heard, but REAPER shows every marker, and f5 on 0.65.0 found LinuxBox's
copy with 4 markers to the desktop's 2. **300ce01** (`ends_left`) leaves an end out when writing back if its source is what the next marker
gives running 1:1 in take time, so a receiver's chunk is the sender's. An end REAPER wrote at a tempo change holds another source position
and stays. Updating: `beats.ends_off` drops those ends from both sides, and W.one's
re-anchor accepts a record of hash version 12 or 13 that lacks them. So the first look after updating sends nothing.

**Test.** `test_0_61_rt_beats` 10: REAPER's chunks before and after the 100 bpm marker read the same, and back in seconds read as they
travelled. Without `with_ends` it fails with "the same before REAPER added the ends". Written back at 120 bpm it's `SM 1 1 + 3 2.5` as REAPER had
it, and REAPER's stretched ends are kept. Without `ends_left` it fails with "the ends left out where they play anyway". Part 12: a record of hash version 13 without the ends;
the first look sends nothing. With the re-anchor taken out it fails with "sends nothing (1: I-JAMES-...)".

## Live results

Every run used `--on d,x` (the laptop off) and `X_IP=192.168.86.129`. Mute me and Deafen were on everywhere (the tool's check), and nothing
was saved. Reports are in the session scratchpad (`live/*.json`), not committed.

**Before, on 0.64.0 (level 13):**

| Run | Result | Notes |
| --- | --- | --- |
| `sync2c -k c3` | fail | Keep back 63 s (desktop) and 62 s (LinuxBox) after File > Open: the heal |
| `sync2c -k c1.2` | pass, slow | 190 s after the older file loaded, 290 s after the second |
| `sync2c -k c2` | couldn't automate (parts 1-2 pass) | tracks back 248 s after the reopen |
| coordinator's `sync2f` (report `tools/live/reports/sync2f-20261128-042540.json`) | f2, f3, f7, f8 pass; f1, f4, f5, f6 fail | f1/f6 problem 1, f4 problem 3, f5 problem 4 |

**After:**

On 0.65.0 (= 2faa603 plus the 0.64.0 release merge), restarted onto it by the coordinator:

| Run | Result | Notes |
| --- | --- | --- |
| `sync2f -k f8` (first after the restart) | pass | 0 and 0 events in 120 s: updating from level 13 sent nothing |
| `sync2c -k c3`, 3 runs | **pass, pass, pass** | Keep back on the desktop 5, 2, 2 s after File > Open; LinuxBox 3, 3, 3 s (before: 63 / 62 s); no deletion |
| `sync2c -k c1.2`, 3 runs | **pass x3** | back 5 s after the older file loaded, and 5 s after the second load, every run (before: 190 / 290 s) |
| `sync2c -k c2`, 3 runs | couldn't automate x3 (parts 1-2 pass) | tracks back 3 s after the reopen every run (before: 248 s); part 3 needs a save |
| `sync2f -k f1` | **pass** | only the timeline event (problem 1) |
| `sync2f -k f6` | **pass** | Drums' automation on its beats, nothing claimed, nothing sent (problem 1) |
| `sync2f -k f4` | fail, fail, then **pass** with e628d7b | first try: prep's "tempo back to 120" timed out (LinuxBox not yet back on one marker after the restart, rt-sync2g's Recommendation 7; agreed later). Second: no item sent at either tempo change, but the raw check differed: the desktop's edit kept rate 0.818, LinuxBox, whose map landed whole, made its markers anew at rate 0.75; srcpos equal, take times scaled alike: the same audio. The tool now compares the item as it plays: pass |
| `sync2f -k f5` | fail | nothing sent, but LinuxBox's copy had 4 markers to the desktop's 2 (2faa603 wrote the ends into the chunk): 300ce01 |

On 0.65.1 (= 300ce01 plus the 0.65.0 release merge), restarted onto it:

| Run | Result | Notes |
| --- | --- | --- |
| `sync2f -k f4` | **pass** | nothing sent at either change; the item plays the same on both |
| `sync2f -k f5` | fail, then **pass** with 49c2a18 | markers equal on both before the change (2 and 2: 300ce01 works); after it REAPER's ends on both (4), and the old check "exactly 2" stopped the run before its no-obj check. With the check updated: pass, nothing sent through the crossing |
| `sync2f -k f1` | **pass** | |
| `sync2c -k c3` | **pass** | 2 s (desktop), 3 s (LinuxBox) |

Scratch-tab probes: the table in "REAPER, measured". One probe of mine left a stray unsaved scratch tab on the desktop
(an `InsertTrackAtIndex` that went to the tab in front, two empty tracks); found by its undo history (only the probe's own two points,
created during the probe) and closed clean. Nothing of James's tabs was touched.

## hv and LEVEL

- **`mirror.HV` 14**: an auto-stretch item's rate is the source its own markers cover, and a take's own stretch markers carry one at each end.
- **`sync.LEVEL` 14**, with it. `band.FORMAT` stays 2. A level-13 computer's changes are held at the floor.
- Updating sends nothing, with one exception: an auto-stretch item whose tempo marker was edited on 0.64.0 (its hv-13 text holds rate x
  length) goes out once. It was already wrong on the computers that had it.

## Gates

| Check | Result |
| --- | --- |
| `tests/run.py --no-luals`, local time, at 300ce01's lib (later commits are tools/live and this doc) | **fails 0** |
| the same, `TZ=UTC0` | **fails 0** |
| `tools/soak/soak.py --scenario all` at 300ce01 | **20 of 20 as they say** (`rename-redo-claim` fails as it says) |
| long soak, `range.py` from a fresh clone of e628d7b (= 300ce01's lib), 8 procs, nothing else of range/soak running | **237 of 237** (baseline 237) |
| long soak from a fresh clone of 2faa603 (on the way) | 237 of 237 |
| on the way | 6012cf3: local fails 0, scenarios 20/20; its UTC run failed `rt_bigproj` once (a quick look 35.0 ms against 33): A/B against 4a40505, 5 runs each alternating, strict timing: 5 of 5 each. Load, not this change |
| knock-outs | each fix's test run with the fix taken out of the tree, then put back: the failures quoted in each section above |

## Known limits

- **Problem 2's mark check** catches a load of a file that lacks a mark the session had applied. A file saved after the newest change applied
  here has every mark, so its load isn't told apart from no load. There's nothing it lacks, so nothing to catch up (rt-fixlive1's guard and
  tracks test still apply). The first pass after Live sync starts takes the files' old marks in any order, so until a new change lands the
  kept file may be any applied one. A load of an older file still lacks the newest marks, and the next applied change becomes the kept one.
- **Problem 1**: only envelopes on the track's own chunk (volume, pan, width, mute, trim...) are made real. A plug-in parameter's envelope
  made the same way isn't looked at (none seen).
- **Problem 3**: an auto-stretch item with markers of its own next to REAPER's keeps both in the text, as before.
- **Problem 4**: the ends assume the source runs 1:1 in take time past the outer markers (true of REAPER's measured case at rate 1). A take
  with another rate and its own markers wasn't measured. History of hash version 12/13 is matched by the re-anchor only; a merge whose base
  is such a version may see the ends as a change.
- **Problem 4, written back**: a marker of the take's own exactly at its start (or end) whose source is what plays there anyway is left out of
  a receiver's chunk like an end (the same audio and canonical text; one marker fewer shown there).
- **Problem 3, the raw chunk**: a computer whose tempo map lands whole has REAPER make its own markers anew (rate = source / length), while an
  edit of the marker keeps the rate: the same audio and canonical text, a different PLAYRATE and marker take times in the chunk.
- **Updating from 0.64.0**: an auto-stretch item whose tempo marker was edited goes out once (above).

## Recommendations (ranked)

1. **Make `LV.env_add` write automation the way a person does** (show the envelope, 40406, when it isn't one of the track's) once f1/f6 have
   been seen passing on the StudioSync fix a few more times, and add a separate check that keeps the script-made envelope case, so both stay
   covered.
2. **The timeline after a restart** (rt-sync2g Recommendation 7): f4's first try here timed out at prep because LinuxBox wasn't back on the
   room's one-marker 120 bpm map within 90 s after the deploy restart. Worth its own live scenario.
3. **A plug-in parameter envelope made by a script** the same way (`GetFXEnvelope(..., create)` then points): check whether REAPER counts it
   and moves it; `realise_envs` looks only at the track's own envelope blocks.
4. **Measure a take with its own stretch markers at a rate other than 1** (problem 4 assumes the outer segments run 1:1 in take time, which
   held at rate 1), and an auto-stretch item with markers of its own beside REAPER's.
5. **A live scenario for updating to level 14 with real history**: items with own stretch markers and an edited auto-stretch item made on
   0.64.0, then this build (the suite's part 12 on the stand-in only).
6. **rt-fixlive1's remaining items** (c2 part 3 needs a save; c2 with the laptop's TONEX when the laptop is back).
