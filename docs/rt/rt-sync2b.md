# rt-sync2b: phase 2 of the sync-core redesign, the judge (2026-11-27)

Builds `docs/rt/rt-sync2.md` section 9's phase 2 ("One judge", section 1) on top of rt-sync2a's harness (`docs/rt/rt-sync2a.md`). Every
computer now works out what each object is from that object's own versions, the same way, and puts that in place: receiving, catching up,
heal, Restore and History playback, the join bootstrap, history trim and media in use all ask one pure function, `lib/judge.lua`. Nothing
here was run in REAPER; the REAPER checks for James are below.

## Summary for James

- **What changed for you:** nothing to click. Two people's edits made apart, a deletion racing an edit, an Undo racing a bandmate's edit:
  every computer now ends on the same version whatever order the changes reached it in, for every kind of thing (items, tracks, plug-ins,
  automation, sends). Before, plug-ins and automation raced by clock, and a two-minute wait decided some races by when things arrived.
- **An item moved to another track while someone else nudged it** keeps both changes (it stayed on the old track everywhere before, and
  every log said "both changes are kept").
- **A track deleted elsewhere** keeps your own new work on it as "(yours, not sent)" because the deletion now says which items it took
  (a fact, however old your item is), not because your item is under two minutes old.
- **Restore and History playback** rebuild each object as the band held it at that moment: a merge where two people edited apart, and a
  deletion over an edit made without seeing it.
- **The soak:** 230 of the 237 baseline seeds pass at the last commit (the baseline passed 227). The seven left are classed below: four
  are phase 3's knob class (three of them failed at the baseline too), two a tempo-map race decided by the maker's clock, one a limit of
  the soak's own Undo probe. Seven of the baseline's ten failures now pass.
- **Two older bugs found on the way**, which the soak's oracle couldn't see: an item dragged to another track right after a tempo change
  was never sent (fixed, b540208), and a grey "arriving" stand-in can be left behind (not fixed: phase 3, recommended).

## Commits

| Commit | What | Test that fails without it |
| --- | --- | --- |
| cac5cf8 | `lib/judge.lua`: `judge.settled`, `judge.support`; descends, apart, common_base, merge_order, too_old_to_merge, split_merge / merge_id, id_span, newer / order_parts / order_of / utc_secs moved in unchanged (mirror keeps its names) | `tests/test_0_60_rt_judge.lua` (new) |
| 50ccb99 | an item's track merged as an attribute (`event_file`, judge step 5) | rt_judge's event-file section; scenario `item-track-merge` flips |
| 629b73b | the judge decides what lands: `mirror.judge`, `mirror.lands`, the new `mirror.receive`, `sync.receive` judging each object once, containment for a returning or deleted track, `lib/evindex.lua` (new); wins, gone_race / RACES, merge_for / first_seen, lands_over, beaten_by, latest / apart / the after-sort, orphaned and heal_due removed | scenarios `seed-9058`, `seed-15043` flip (and `late-joiner-order`, `seed-5028`: see below); rt_edits' late joiner |
| d3e540c | wire field `items` on a track's deletion; the receiver keeps by that fact | `tests/test_0_60_rt_delete_race.lua` (named / empty / absent / malformed lists) |
| a56079b | a merge that can't be built isn't one on its way (`event_file`) | rt_judge (three edit leaves on a deletion); the long soak's 5009 and 15055 (log: I missing) |
| 23da527 | heal is the judge over every object; the grandfather rule; an unreadable held version stands in from its record | rt_delete_race (heal keeps an item its deletion never saw); converge 29 keeps passing |
| 2ebd048 | Restore and History playback by the judge (`mirror.plan_restore`) | rt_judge (the merge at a row; the deletion over a newer edit) |
| ac05c99 | history trim keeps the judge's support; the join bootstrap asks the judge | `tests/test_trim.lua` (a deletion that beat a newer edit stays) |
| 284b8fc | media in use: containment by the judge (`drive.media_in_use`, `needlist`) | `tests/test_0_60_rt_catchup_link.lua` (both takes made apart are played) |
| 595bd72 | comments that named gone_race / merge_for | |
| b540208 | a tempo map never moves an item to another track (`only_map_moved`; older than this phase, found by the track check below) | rt_judge (on another track: a hand's move) |
| 3262be1 | an answer whose file can't be read just now waits; it isn't left out (`mirror.judge`) | rt_judge (unreadable, then readable); the long soak's 15017 |
| (this doc) | docs/rt/rt-sync2b.md | |

Files: `lib/judge.lua`, `lib/evindex.lua` (new); `lib/mirror.lua`, `lib/sync.lua`, `lib/joinboot.lua`, `lib/drive.lua`, `lib/needlist.lua`,
`lib/trim.lua`; tests `test_0_60_rt_judge.lua` (new), `test_0_59_45_engine`, `_48`, `_49`, `rt_delete_race`, `rt_edits`, `rt_converge`
(comments), `test_trim`, `rt_catchup_link`; `tools/soak/scenarios/` (five `today`s flipped); **`tools/soak/node.lua`: one additive line**
(`mirror.JUDGE_SINCE` set to 1970 for the soak: it models life after the judge, so heal's grandfather rule doesn't apply to its history).
`lib/page_restore.lua`, `lib/histhear.lua` and rt-ui3's `lib/webrestore.lua` needed no change: `plan_restore` changed under them, and
`histhear.settle` already is the containment the design asks for. `lib/files.txt` isn't edited (the release script adds the two new files).

## What the judge is

`judge.settled(vs, read, opt) -> s` (pure: no REAPER, no clock, no module state; every iteration that decides goes in id order):

1. **Ancestry** through `base_ev` and both sides of a merge (`descends`, unchanged, capped at 400 steps, stopping below the target's clock).
2. **Leaves**: the versions nothing in `vs` names as a base (a merge named as a base names its sides), then pruned pairwise where one builds
   on another through a version not in `vs`. If that can't be told (a version on the way), the answer is **incomplete**: `s.v` nil,
   `s.missing` names what's missing. A missing id dated more than `MERGE_DAYS` before the newest version counts as trimmed.
3. **A deletion beats every leaf that didn't see it** (a deletion here not in its ancestry), whatever its rev or clock, for **every kind**.
   Beaten leaves leave the race (`s.beaten`).
4. One edit leaf is the answer.
5. Several are merged oldest first, each newer winning (`merge_order`; the merged version is `read(merge id)`, which `mirror.event_file`
   builds), when every one may merge (`mirror.mergeable`, read through `mirror.` as rt-sync2a asked), has a base, and they're within
   `MERGE_DAYS`. If the merge's shared base isn't here yet: incomplete.
6. Otherwise (unmergeable, too far apart, a merge that can't be built): the newest leaf (rev, clock, name, id).
7. More than 64 leaves: the newest, unmerged.

`judge.support(vs, s)`: the leaves, the beaten, and with several leaves the deletions (what history trim and the join bootstrap must keep).

`mirror.judge(proj, oid, room_dir, news, skip)` feeds it: the object's versions in the index (`lib/evindex.lua`), the ones a receive pass just
read, and what this computer holds (a merge's sides too). A held version whose file can't be read stands in from its record: as a deletion
when it's held absent (so an edit made without seeing it doesn't bring the thing back while the deletion's file is on its way: converge 29),
and otherwise as an unmergeable leaf that keeps anything from landing beside it until it reads. Changes too new for this version
(`sync.too_new`) and those `skip` names (refused here for their minute, waiting for their tempo map) are left out. `mirror.lands(proj, s)`
says whether the answer changes anything here: another version than the one held, or the one held but not in place (recorded gone with its
track, the track here).

`lib/evindex.lua`: per room, every version of every object (folder and the link's inbox), kept light as `room_newest` kept them (state read
from the file when asked), and which items and parts each track has held. `sync.receive` adds what it reads; heal and a track's contents load
the rest once a session; a file that has left the folder (trimmed) leaves the index.

## The paths, before and after

| Path | Before | Now |
| --- | --- | --- |
| live receive and catch-up (`sync.receive`, `mirror.receive`) | per change, in time order: newest-only catch-up (`latest`, `apart`, superseded), `wins`, `merge_for` with its 120 s wait, `gone_race` (items, tracks), `beaten_by`, `lands_over`, the after-sort, the orphaned and heal_due heals | each object with changes in the pass judged once; tracks first (each after the one it sits under), then the tempo map, then parts and items by id, then notes and cues; the answer put in place where it differs from what's held; a track that comes back or goes brings what it holds into the same pass (`evindex.contents`; what can't land now is owed to the next pass, `sync.contents_due`) |
| heal (`mirror.heal`) | `room_newest` + `settled`, then the ahead, old_merge, bare rules and `MERGE_NEWS_SECS` | the judge over every object in the index; the grandfather rule; a track's deletion applied with what it names |
| Restore, History playback (`plan_restore`, `histhear.settle`) | each object's winner by rev at or before the row | the judge over its versions up to the row (missing ones trimmed); containment stays `histhear.settle`'s |
| join bootstrap (`joinboot.compact`) | the newest by rev, or every change when another wasn't on its line | the judge's leaves: one leaf hands over that leaf, more hand over every change (the same choice, asked of the judge) |
| history trim (`trim.plan`) | the newest, rivals that are edits with bases, their bases | every leaf that could be weighed (has a base, or is a deletion), the deletions of an object with more than one leaf, their bases |
| media in use (`drive.media_in_use`, `needlist`) | each object's newest by time, unless its track's newest removed it | the judge per object from the summaries (now with rev, clock, base), every unbeaten leaf's files, unless the answer or its track's is a deletion |

### `items`: a track's deletion names what went with it

`W.gone` lists the items missing with a deleted track (sorted, at most `mirror.ITEMS_MAX` = 2,000; past that the field is left out), and so
does `mirror.revert`'s deletion of a track. A receiver's `apply` keeps an item on "(yours, not sent)" when the deletion doesn't name it and
every version of it is this person's (`new_here`), however old; one it names goes, however new. An unsent edit of yours is kept as before
(and the asked-of "moot" rule still lets it go when the deleter is the one you asked). A deletion without the list (a StudioSync from before
this, or past 2,000 items) gets the old two-minute guess (`just_made_here`, `only_retimed`, `new_here`) and `kept_new`, which a deletion with
the list never needs. `mirror.named_items` treats the field as bandmate data: strings of at most 200 characters, no slashes, at most 2,000,
upper-cased; anything else is ignored (the old guess applies).

## Deviations from the design, on purpose

- **A bound on waiting, `mirror.WAIT_MISSING` (120 s).** An incomplete answer applies nothing, as designed; after 120 s by this computer's
  clock what's missing counts as trimmed and the answer is put in place. The design's way out is the need list asking for the missing ids
  and treating a version every bandmate says it lacks as trimmed; `lib/needlist.lua` asks by day, not by id, and building ask-by-id with the
  bandmates' answers is phase 8 work. The bound only decides *when*: when the missing version arrives, the object is judged again and every
  computer ends on the same answer. It is the old merge wait's two minutes (merge_for, gone_race), kept as a liveness bound.
- **The grandfather rule is narrower.** An object whose every version predates `mirror.JUDGE_SINCE` ("20261128-000000", by the ids' time)
  keeps its held version only where that version is one of its leaves (a race settled before the judge); a held version behind a leaf (a
  change skipped here) is still brought forward, as heal did before. The soak sets `JUDGE_SINCE` to 1970 (`tools/soak/node.lua`).
- **Kept, for computers before this change:** `just_made_here`, `only_retimed`, `new_here` and `kept_new` serve a track deletion without
  `items`. The asked-of moot rule in `apply` is kept (it decides about an edit of yours held unsent, which is data safety, not the race).
- **Kept for phases 3, 4, 7:** `bring_parts` (apply's own, for put-backs and Restores that make a track), `tracks_back` (the look's), the
  order code (`placed`, `STAY`, `says_move`, `after`), `room_newest` (now over the index, for Use mine / Bring into main / forks /
  page_rooms / webrooms), `mirror.settled` (a one-line wrapper of the judge, used by `plan_bring`), `set_back` and the refusals (phase 6).
- **Not asked of the judge yet (outside phase 2's file list):** `lib/webhistory.lua`'s "which revision stands" (`mirror.newer`) and
  `lib/page_rooms.lua` / `lib/webrooms.lua` / `lib/forks.lua`, which read `room_newest` (now over the index, same answers as before). Use
  mine and Bring into main (`plan_bring`) ask `mirror.settled`, which is the judge now.
- **Non-object changes land around the objects**, not interleaved by time: a tempo map after the pass's tracks (a region names the tracks it
  renders: rt_edits' late joiner lost a region's render track when the map landed first) and before their parts and items (an item lands on
  its beat under the map in place: landed after, REAPER moved them on the late joiner); notes and cues after everything. A change stamped
  with a map not here yet (`map_waits`) is now asked at judging time, so it lands in the pass that brings its map.

## The replay comparison

`rt-sync2b_replay.py` (scratch, not committed: it drives `tools/soak`): for each seed the soak runs until quiet, James's whole studio folder is
recorded (`N.shared_files`), and replayed into two fresh late joiners, one on the old receive (lib from f5c3bd5, the commit before this
phase) and one on the judge. Every object whose state differs between the two is listed with its versions; the track order and the timeline
are compared too.

Folders written two ways: by the old code on all three computers (the histories a release meets on the real computers) and by this phase's
code. The judge's late joiner and the old receive's late joiner are compared object by object (each object's state, and from the second
batch on each item's track too, which the soak's own state hash leaves out: see "What the soak can't see" below), the track order and the
timeline.

| Folders | Written by | Objects | Differ | Order / timeline differ |
| --- | --- | --- | --- | --- |
| 24 long-soak seeds (5000-5005, 9000-9005, 13000-13005, 15000-15005) | this phase | 1,162 | 1 | 0 / 0 |
| 22 seeds: the quick seeds 1-6, every seed that failed at the baseline or during this phase (5001, 5009, 5010, 5025, 9006, 9027, 9034, 9036, 9058, 9059, 13007, 13008, 13014, 15015, 15043, 15055) | the old code | 983 | 0 | 0 / 0 |
| the 14 scenarios | the old code | 526 | 2 | 0 / 0 |
| the 14 scenarios | this phase | 522 | 1 | 0 / 0 |

Every difference, explained:

1. **seed 9004 (written by this phase), item I-JAMES-...65686.** Two Restores made apart, Cee's moving the item to another track: merged.
   The old receive's merge copied the winner's track, which had been deleted, so the item went with it (held, absent); the judge's merge keeps
   Cee's track (judge step 5) and the item is there, as on the three computers. *The track merged as an attribute.*
2. **item-track-merge (both writers), Bass 1.** The scenario itself: the old receive leaves Bass 1 on Bass, the judge puts it on Gtr (Bee's
   move) at James's nudge. *The track merged as an attribute.* On the old-written folder the three old computers hold the same merge id
   with Bass 1 on Bass: a computer updated to this phase keeps it (the id it holds is the judge's answer, so nothing lands), a fresh joiner
   puts it on Gtr. That's an "old history" difference: Health's content code (phase 8) shows it, "Bring in line" settles it.
3. **seed-9058 (written by the old code), the automation E-JAMES-...19408.** James's version at 19:00:45 emptied it (a part's deletion);
   Bee and Cee went on editing it for a minute from the version before, without that deletion (five versions, the newest rev 8). The old
   receive took the newest (rev and clock: parts weren't in `RACES`); the judge's deletion rule beats every version that didn't see the
   deletion, for every kind, so the automation is empty. *One deletion rule for every kind* (judge step 3), the design's fix for the restore
   race (9029, 9058). On real computers this is grandfathered in heal while the held version is a leaf, and shows in Health's content code.

No difference in track order or the timeline anywhere: the judge doesn't decide either (ranks are phase 4, the timeline stays newest-wins).

## rt-bigproj: the judge at size

`rt-sync2b_big.lua` (scratch): rt-bigproj's project (tools/bigproject.lua: 150 tracks, 520 plug-ins, 4,000 items) has its first look
(4,154 objects, 4,472 events), then synthetic history on top to **20,000 events** (chains of edits by three people, a fork about every tenth,
deletions and restores); files in memory, applying stubbed (REAPER's time, measured in REAPER by rt-bigproj).

| Measured (os.clock, one run, the machine loaded by other agents) | Before (f5c3bd5) | The judge |
| --- | --- | --- |
| rt-bigproj's own catch-up (4,472 events, about one version per object; `tests/test_0_60_rt_bigproj.lua`) | 118 ms | 213 ms (each object judged: about 20 us an object more) |
| a caught-up pass at 4,472 events | 2.0 ms | 1.7 ms |
| a late joiner's catch-up at 20,000 events (4,154 objects) | 1,599 ms | 1,231 ms (one judgement per object instead of the newest-only sort and apart checks over every version) |
| a caught-up pass at 20,000 events | 94 ms | 85 ms (both the stand-in's listing of 20,000 names) |
| heal, first (every file read light, every object judged / settled) | 500 ms | 513 ms |
| heal again (nothing to do) | 226 ms | 306 ms (every object judged again: the index makes the reading free, the judging isn't) |
| Lua memory added by heal | +32 MB | +19 MB |

Judging is per object: an incoming change costs one sort of that object's versions and a walk per pair of leaves and per deletion (capped at
400 steps). A catch-up's extra cost at the bigproj size is small beside REAPER's own applying (seconds at this size, rt-bigproj step 7), and a
catch-up is spread over passes at LOAD_BUDGET (1 s) anyway. Heal judging every object again costs about a third more than settling did:
heal runs after a minute of a bandmate differing (Live sync's P.heal), not every pass; phase 8 makes it run only when content codes differ.

## The long soak, before and after

`python tools/soak/soak.py`'s long run, the 237 seeds of rt-sync2a's baseline (5000-5057, 9000-9059, 13000-13059, 15000-15058) at 150 edits,
each seed run once from a clean clone (`rt-sync2b_range.py`, which calls the soak's own `run_once` per seed; the machine was loaded by other
agents throughout, so seeds were run by number rather than by the clock).

| Range | Seeds | Baseline (88282e1 / bf500ba, rt-sync2a) | 629b73b (the judge decides) | 23da527 (heal) | 595bd72 | b540208 | **3262be1 (last)** |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5000 | 58 | 56 | 55 | 56 | 56 | 56 | **56** |
| 9000 | 60 | 55 | 57 | 58 | 57 | 57 | **57** |
| 13000 | 60 | 58 | 59 | 59 | 59 | 59 | **59** |
| 15000 | 59 | 58 | 57 | 58 | 58 | 57 | **58** |
| all | 237 | 227 | 228 | 231 | 230 | 229 | **230** |

Seed by seed, baseline against the last commit:

| Seed | Baseline | Last | Class |
| --- | --- | --- | --- |
| 5001 | F differs | passes | |
| 9027, 9034, 13014 | log: T differs (late joiner's order) | pass | phase 4's class; pass by the pass's sit-under order, not by construction |
| 9036 | undo | passes | |
| 13007 | E differs (tempo map) | passes | phase 5's class; moved off it |
| 15043 | I missing | passes | containment (`seed-15043`) |
| 5025, 9006, 9059 | F differs | F differs | a plug-in knob differing with the same version held on all three: 5028's class (phase 3) |
| 5010 | passes | **F differs** | the same class (James and Bee hold one version, a knob differs; a `reopen` in the run) |
| 9033, 13008 | pass | **tempo map / markers differ** | the timeline is newest-wins by `time .. id` (no `order` on these): a Restore's map posted by a computer whose clock was behind a map it had just landed loses to it on the others and stands on the restorer's (13008 traced: Bee's Restore at 19:02:19 by its clock, James's marker at 19:02:20 by his). The timeline isn't the judge's; Recommendation 7 |
| 15015 | passes | **undo** | the probe's limit: Cee's last act moved an item onto a track deleted since, so the item was gone with it on all three; Cee's Undo brings it back on its old track, and the Redo can't go to a deleted track ("couldn't change here yet"). Correct, not what the probe expects; Recommendation 6 |

Earlier runs also showed (and later commits fixed): 5009, 15055 (log: I missing: a merge that couldn't be built taken for one on its way,
a56079b), 9058 (the same, then by the scenario's own fix), 15017 (I differs: an answer's file unreadable for a moment, 3262be1).

## Scenarios

`python tools/soak/soak.py --scenario all`: 14 of 14 as they say at HEAD.

| Scenario | Before (rt-sync2a) | Now | Why |
| --- | --- | --- | --- |
| `item-track-merge` | fails | **passes** (50ccb99) | the track is merged as an attribute |
| `seed-9058` | fails | **passes** (629b73b) | the restore race: the judge's deletion rule for every kind, no 120 s wait deciding by arrival |
| `seed-15043` | fails | **passes** (629b73b) | an item lost after Restores and a track deletion: containment, the track's contents judged in the pass it comes back |
| `late-joiner-order` | fails | passes (629b73b) | a frozen seed: its class is phase 4's (ranks); it passes because the late joiner now lands a pass's tracks in their sit-under order in one go, which moves this seed off the bug, not by construction. The long soak's 9027, 9034, 13014 (the same class at baseline) now pass too; phase 4 should keep the scenario |
| `seed-5028` | fails | passes (629b73b) | a frozen seed of phase 3's class (a knob around a new opening never sent): the receive order changed and moved it off the bug. The class is still in the long soak (5010, 5025, 9006) |
| `restore-race`, `late-joiner-midi` | pass | pass | |
| `tempo-env` | fails | fails | phase 5 |
| `rename-redo-claim` | fails | fails | phase 6 |
| the rest | pass | pass | |

## What the soak can't see: which track an item sits on

The soak's oracle (`tools/soak/node.lua` `N.state`) hashes an item's text with its numbers rounded, and an item's track isn't in its text, so
two computers holding an item on different tracks read as converged. `rt-sync2b_tracks.py` (scratch) compares every studio item's track on
the three computers at quiet (local "(yours, not sent)" tracks left out):

| Seeds | f5c3bd5 (before this phase) | 595bd72 (this phase, before b540208) | b540208 |
| --- | --- | --- | --- |
| 5000-5019 | 0 of 20 | 1 (5000) | 0 |
| 9000-9007 | 2 (9001, 9006) | 3 (9001, 9002, 9006) | 1 (9002) |
| 15010-15019 | | | (3262be1) 1 (15011: a stand-in on Bee for an item the others no longer have) |

- **9001, 9006, 5000: an item moved to another track with its position unchanged, read as a tempo map's move** (`only_map_moved` compared
  only position and length), recorded as it was and never sent. Older than this phase; fixed in b540208 (a tempo map never moves an item to
  another track), with a test.
- **9002: a grey stand-in copied.** James copied an item whose audio was still on its way (its stand-in, `band_arriving`); the copy kept the
  stand-in's id and mark, and stayed on Gtr beside the real item when it landed. Look-side (phase 3's ground), not fixed here.
- **15010-15019 at 3262be1: a stand-in left behind** on Bee for an item the others no longer have (its versions agree everywhere). Not
  traced; not checked against the old code. The same family as 9002: stand-ins aren't in the oracle's state either.

## Mixed soak

Cee on ab2f54a's lib (rt-sync2a's commit, before this phase), James and Bee on this phase's, from a clean clone of 3262be1:

| Run | Result |
| --- | --- |
| `soak.py --old ab2f54a --quick` | 5 of 5 (the 55 s budget, loaded machine; 6 of 6 earlier at 629b73b) |
| seeds 5000-5029 at 150 edits | 25 of 30 |

The five: **5021, 5024** (automation differs, James and Bee empty, Cee with points: the judge's deletion rule for every kind beats edits
that didn't see an automation's deletion; the old computer races automation by clock), **5027** (a plug-in chain differs between James and
Cee: a race the two versions settle differently), **5025** and **5028** (a knob differing between two new computers: phase 3's class; 5025
fails unmixed too). The first three are what the design expects of a mixed room ("new and old computers may hold different merges for a
race made while both were in the room... everyone updates together"); Health shows "apart". Nothing in the mixed runs errors or stalls.

## Judge agreement at quiet

At quiet, each computer's held version of every object against the judge's answer from the studio's folder alone (no held version), and
whether the answer would put anything in place (`mirror.lands`): `rt-sync2b_agree.py` (scratch).

| Commit | Seeds | Object x computer | Disagree |
| --- | --- | --- | --- |
| 595bd72 | 5000-5011, 9000-9007 | 2,301 | 0 |
| 3262be1 | 15010-15019 | 1,167 | 0 |

(The one disagreement seen on the way, 15017 at b540208, was the unreadable-file case fixed in 3262be1.) Agreement on held versions isn't
agreement on REAPER's state: the knob class (5028) holds one version everywhere with a knob differing, and the track check below found
items on other tracks with every version agreeing.

## Gate

All from a fresh clone of 3262be1 (the last code commit; this doc's commit changes no code), on a machine loaded by four soak processes
and other agents:

| Check | Result |
| --- | --- |
| `python tests/run.py --no-luals`, local time | **fails 0** (soak `--quick` and detcheck inside: ok) |
| the same with `TZ=UTC0` | fails 1: `test_0_60_rt_drivebg` ("no look at it over 20 ms", worst 48 ms, with four soaks running); **alone: ok** (and `test_0_60_rt_bigproj` alone: ok) |
| `soak.py --quick` | ok (inside run.py, both runs) |
| detcheck (two runs identical) | ok (inside run.py, both runs) |
| `soak.py --scenario all` | 14 of 14 as they say |
| long soak, 237 seeds of 5000 / 9000 / 13000 / 15000 at 150 edits | **230 of 237** (baseline 227); every failure classed above |
| judge agreement at quiet | 0 disagreements (above) |
| mixed soak `--old ab2f54a` | quick 5 of 5; 25 of 30 on 5000-5029, the five classed above |

`files_check` and `release_check` say NOTE (lib/files.txt lists neither new file until the release script runs), as for any new lib file.
At b540208 the suite was fails 0 in local time and fails 1 under `TZ=UTC0` (`test_0_60_rt_bigproj`, 42.0 ms against 42, loaded; alone: ok).

## REAPER checks for James

All on the real computers, after a release with these files. Each is something the stand-in can't prove.

1. **rt-converge check 8 (Undo), and P1-6's Ctrl+Z.** On the desktop, move an item and change a plug-in knob on one track; StudioSync's Undo
   twice (panel or Ctrl+Z through StudioSync), then Redo twice. The laptop and Mac follow each step and end as the desktop. Then REAPER's own
   Ctrl+Z after a bandmate's change has landed: it undoes your last edit, not theirs.
2. **The restore race, by script** (an Undo a second after a bandmate's edit of the same thing): delete an item on the desktop; on the laptop,
   within a second of the desktop's Undo of that deletion, nudge the item. Repeat with the item's track automation (move a point) and with its
   plug-ins (change a knob). On all three computers the item, the automation and the plug-in end the same (the restore stands; the laptop's
   nudge, made without seeing the deletion, is beaten), and nothing comes back later on one computer only.
3. **A late joiner.** With a song that has had races (two people editing one item apart, a track deleted and undone), open it fresh on a
   computer that hasn't had it (or a new room copy) and let it catch up: it ends identical to the others (Health shows no "apart").
4. **An item moved to another track while someone else nudges it**: Bee drags an item to another track while offline; James nudges it on the
   old track; Bee comes back online. Every computer shows it on Bee's track at James's position, and the log says both changes are kept.
5. **A track deleted under your new take:** the laptop records a take on Bass and keeps it unsent (Hold, or offline); the desktop deletes
   Bass. The laptop keeps the take on "Bass (yours, not sent)", however long ago it recorded it. An item on Bass that the desktop had (and
   so named in its deletion) goes with the track.
6. **Restore to a moment where two people had edited one item apart**: History, pick a row just after both edits, Restore the whole project
   to here: the item comes back with both edits in it (before, only the newer one's).

7. **An item moved to another track right after a tempo change** (b540208): change the first tempo on the desktop, and within 15 s drag an
   item straight down to another track (Shift held, so its time doesn't move). The laptop and Mac show it on the new track.

## What phase 3 and 4 should know

- **The look still compares REAPER with the records**, not with the projection. `mirror.lands` and `on_gone_track` (now used by the judge's
  callers for containment) are what "should be present" means here: an answer that isn't a deletion, on a track whose record isn't gone. Phase
  3's "absent where the projection says present" is `mirror.lands(proj, mirror.judge(proj, oid, room_dir, {}))` being true for something the
  look doesn't find.
- **Containment lives in two places now:** `sync.receive` judges a track's contents in the pass it comes back or goes (with `force` for an
  item deleted in REAPER with its track before a look recorded it), and heal records an item whose answer sits on a deleted track as gone
  with it. W.gone's "the band deleted its track, and the item went with it" branch is now mostly redundant but harmless; phase 3 can take it out.
- **`items` is on every track deletion sent by this version.** Phase 3's deletion evidence can use it: a track deletion names exactly what
  went with it.
- **The tempo map lands after the pass's tracks** and before parts and items (sync.receive). Phase 5 removes `map_waits`; the order
  stays useful (render tracks named by regions).
- **Phase 4 (ranks):** the pass orders tracks by `after` (each after the one it sits under when that one is in the pass) and heal does the
  same on the judge's answers; both are the places a rank sort replaces. `late-joiner-order` passes today by luck (above).
- **5028's class is now the long soak's commonest failure** (5010, 5025, 9006: a knob differing with the same version held everywhere).
- **The undo probe's limit** (15015): an Undo that brings an item back from a track deleted since can't be redone onto that track
  ("couldn't change here yet"); the probe then reads it as Undo/Redo not bringing the song back. Phase 7 meets this (and should teach the probe
  to skip a Redo that couldn't change anything, as it skips "not yours to change").

## Recommendations (ranked)

Recommend only; none built here.

1. **Put an item's track into the soak's state hash** (`tools/soak/node.lua` `N.state`: hash the track oid with the text). Today the oracle
   can't see an item on another track (above); `rt-sync2b_tracks.py` found three seeds in 28 of the code before this phase. It changes no
   seed's draws, only what the oracle sees, so do it with a new baseline (some seeds that "passed" will fail, on real bugs).
2. **A copy of a grey stand-in** should get a fresh id and lose `band_arriving` (or stand-ins shouldn't be copyable): seed 9002.
3. **Ask for missing versions by id** (`lib/needlist.lua`), and treat one every bandmate says it lacks as trimmed, so `WAIT_MISSING` can go.
   Today an answer waits up to 120 s for a version on its way, as merge_for did; the design's fact replaces that timer.
4. **Phase 3 next, with the master-track instance test first**: the knob class (5028) is now the most common long-soak failure (3 of 7).
5. **A judge-agreement check in the soak's oracle**: at quiet, each computer's held version against `mirror.judge(nil, ...)` from the folder
   (`rt-sync2b_agree.py` does it from outside). It catches "receive and the judge disagree" before it shows as a difference.
6. **Teach the undo probe two limits**: skip a Redo that couldn't change anything here, and an Undo whose object came back from a track
   deleted since.
7. **Timeline order by causality, not the maker's clock** (13008): a Restore's map posted with an older clock than a map it had already
   landed loses to it on the other computers but stands on the restorer's. Recommendation 3 of rt-sync2 (markers as objects) ends it; until
   then `sync.post` could give a timeline the order "after the newest map landed here" whenever it's posted by a Restore or Undo.
8. **Content codes in Health** (phase 8): the judge's answers make a content code meaningful; held ids agreeing (as they do at quiet in the
   soak) while REAPER readings differ is exactly the knob class.
9. **The stand-in REAPER's `<EXT` vs `<EXTI`** (rt-sync2a Recommendation 1) still stands; not done here (it would rebaseline every seed).
10. **Prune `lib/evindex.lua` per room** when a room is archived or the song closes (today it lives for the session, as `light_events` does).
11. **Move `mirror.clashes`'s walk onto the index** (rt-sync2a's note): it still reads `base_ev` chains through `event_file` on its own.

## Review later (security)

- `items` is bandmate data: checked (at most 2,000 strings of at most 200 characters, no slashes); a forged list can only make a receiver
  keep or drop *its own* unsent-free new work on a track that is being deleted anyway (a forged empty list keeps more on "(yours, not sent)";
  a forged full list loses what the old two-minute guess would have kept). Same trust as any change today (the studio's key signs for all).
- The judge's bounds (64 leaves, 400-step walks, merge depth 12) are the design's security limits too: a member flooding one object with
  versions can't make a computer walk past them.
- A held version that can't be read stands in from this computer's own record only.
- `WAIT_MISSING` lets a member who withholds a version delay an object's answer by up to 120 s on every computer (the old merge wait did the
  same).

## What I didn't check

- Nothing was run in REAPER.
- Phase 8's content code, the need list's ask-by-id and the "Bring in line" button aren't built; the grandfather rule's real effect on the
  computers' history is unmeasured.
- 13008, 5010 / 5025 / 9006 and 15015 were traced as far as their class (above), not to the line of a fix.
- The mixed soak ran with one old computer (Cee); two old computers weren't tried.
