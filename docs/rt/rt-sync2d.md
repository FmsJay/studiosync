# rt-sync2d: phase 4b of the sync-core redesign, folders as parent + rank (2026-11-27)

Builds `docs/rt/rt-sync2.md` section 3's folder half (James's decision 4) on top of rt-sync2c's ranks, as rt-sync2c's Recommendation 1
describes. Plus James's floor for the big-deletion ask (his decision of 15:57). Nothing here was run in REAPER; the REAPER checks are below.

## Summary for James

- **A track's folder now travels as "which folder it is in".** Dragging a track into a folder, out of one, or REAPER's indent / outdent
  sends that track's folder (its parent) with it. Each computer works out REAPER's folder depths from the folders every track says it is in,
  so a folder change that arrives in pieces (the child before the folder track) is right at once instead of briefly putting the tracks below
  into the wrong folder, and the depths StudioSync works out are never sent back as anyone's edit.
- **Two people dragging tracks into each other at the same moment** (Keys into Bass while Bass goes into Keys) now end with one valid
  folder on every computer: the track whose change is newest leaves the loop and sits at the top level with the other inside it. Before,
  each computer kept whichever depths landed last and the folders could end apart, or broken (two tracks closing a folder that never opened:
  the soak's new `folder-loop` scenario shows exactly that on the previous version).
- **Your room switches over by itself**, the way ranks did: on the first quiet moment after the update, each computer gives the tracks its
  person made their folder ("N track(s) given their folder as a parent" in the log).
- **Older StudioSyncs in the room keep working.** New computers keep sending depths, and keep each track's depth and rank in line with the
  folders, so an older computer (which shows the depths as they come, and sorts by rank alone) shows the same folders and order. Where a
  version's folder is off (two folder changes merged, a loop broken), a new computer that holds the same changes as a caught-up bandmate
  says it again.
- **The big-deletion ask has your floor:** it asks only when 2 or more tracks are deleted and they are half the song or more. Deleting one
  track never asks.
- **Soak:** see Gates. Folder moves are now in the soak's draws (half of its track moves), which changed the baseline (recorded first).

## Commits

| Commit | What | Test that fails without it |
| --- | --- | --- |
| ddb6582 | the big-deletion ask from 2 tracks deleted (James's floor) | `test_0_60_rt_reopen` 4 (1 of 2: no ask) |
| 7efd304 | soak: folder moves in the draws; the oracle compares folders as parent and order; the stand-in REAPER's DeleteTrack keeps the folders around it | (the new baseline below) |
| c3dff2e | folders as parent + rank: `lib/rank.lua` (`rank.tree`, `rank.depths`, `rank.depth_parents`), `lib/mirror.lua`, `lib/mirror_merge.lua`, hv 10, the `folder-loop` scenario | `test_0_60_rt_folders` 1-10 (see "Tests" for which piece each part pins) |
| 468f054 | StudioSync's own versions (`auto`) don't count as a bandmate's change for Undo's "kept what collaborators added since" (`mirror.revert`; the long soak's 5016 at c3dff2e) | `test_0_60_rt_folders` 11 |
| fe9ccb2 | the every-30-s folder heal still waits `ORDER_WAIT` after a bandmate's move lands; `folder-loop`'s check accepts either valid tree | `test_0_60_rt_edits` (its order-heal wait) |
| (this doc) | docs/rt/rt-sync2d.md | |

Files: `lib/rank.lua`, `lib/mirror.lua`, `lib/mirror_merge.lua` (one table entry), `tests/test_0_60_rt_folders.lua` (new),
`tests/test_0_60_rt_reopen.lua` (part 4), `tests/test_0_60_rt_rank.lua` (one line: hv 9 or later), `tests/fixtures/editreaper.lua`
(DeleteTrack), `tools/soak/node.lua`, `tools/soak/scenarios/folder-loop.json` (new). Nothing of `lib/webui*`, `lib/claimask.lua` or
presence. `lib/files.txt` needs no change (no new lib file). Nothing pushed, no version bumped.

## What was built

### The data

- **`parent`** (already in every track version since 0.30, read from REAPER's `GetParentTrack`) is now in the track's hashed line again
  (`mirror.track_line`'s second field): **`mirror.HV` = 10**. An older version's hash without it reads as the same track wherever the band's
  hash is checked (`W.one`'s alias, apply's `same_line`), so nothing goes out again on update.
- **`pk = 1`** on a track version says its parent is meant (`mirror.parent_in`), as `rk` does for ranks. New computers set it on every track
  version they send in a room with ranks (`W.send`, `mirror.revert`, `mirror.rank_room`). A version without it (an older StudioSync's, or one
  from before the room switched over) has an unreliable `parent`: an older StudioSync never sent a track again when only its parent changed
  (a folder closed further down moves the tracks above into it without touching their own depth).
- **`unfolder`** on a version a person sent after putting the track in another folder: the folder it left (as `moved` names the track a moved
  one sat under), for Undo.
- **Depth still travels** (the brief: keep sending it while old computers can be in a room) and stays in the hash; what changes is who decides
  it. In a room with ranks, REAPER's depth for a track with a rank is never taken from a version (`mirror.set_track_state` skips it): it comes
  from the tree.

### The tree (`lib/rank.lua`, pure)

`rank.tree(tracks)`: each track `{ oid, rank, after, parent, depth, newest }`. The flat order is phase 4's `rank.order`; each track's parent
is the one its version says (`pk`), else the one its version's depth gives it in that flat order (`rank.depth_parents`: REAPER's own rule,
the old way, for tracks no new computer has said yet); a parent not here, or itself, is the top level. **Loops** are broken by the track
whose held version is newest (its clock, then its id, byte-wise) going to the top level: the change made last couldn't have seen the other.
The order is a depth-first walk, each level in rank order. `rank.depths(order, parent)` gives REAPER's depths for an order (1 opens, -n
closes n), and where the order can't hold the tree (not sorted yet) puts that track at the top level.

### Where it's used (`lib/mirror.lua`)

- **The order heal sorts by the tree** (`mirror.rank_order` -> `rank.tree`; `mirror.keep_order`), then sets REAPER's depths from it
  (`mirror.tree_depths`, only where REAPER would read another parent: an open folder at the end stays as it is) under StudioSync's undo
  point. In a room with ranks the order heal now also runs every `APART_SECS` once quiet and `ORDER_WAIT` after a bandmate's move landed
  (it was only when a bandmate's order was apart), which puts back the folders of a refused or put-back folder change.
- **A landing track** is placed in the tree (`mirror.rank_above` with the landing version as a `tree_entry`) and the depths are set from the
  tree for the order REAPER has right then (`mirror.apply`); the end-of-pass sort (rt-sync2c's 58558b9) then sorts the rest.
- **Reading a folder change (the look).** `W.order` keeps each track's REAPER parent and depth as the look before saw them, or as StudioSync
  last wrote them (`mirror.tree_seen`, updated beside `order_seen` in `W.order`, `keep_order`, `order_after_band` and on a new opening).
  A track whose parent or depth differs from that, with no bandmate's track landed since (`order_band`, as for moves), is this person's
  (`w.refoldered`); it gets a new rank among its new siblings (between its list neighbours when that also sorts it among its siblings, so an
  older computer sorting by rank alone agrees), and goes out with REAPER's parent and depth, `pk` and `unfolder`. **Any other track's parent
  and depth are the band's version's** (`W.one`, before the alias checks): what REAPER reads there meanwhile (a change in pieces, the tree's
  depths, an older StudioSync's stale parent) is nobody's edit. A track sent for another reason takes the tree's parent (`W.send`), so a stale
  parent isn't made the truth by a rename.
- **Merges** (`lib/mirror_merge.lua`): `parent` and `depth` merge together as one setting group ("folder", like the lanes group): one side's
  parent with the other side's depth made a folder neither had, and an older computer (which shows the depth) another tree than the parent
  gives. In `event_file`, a side without `pk` changed the parent only where it changed the depth too; the merge says `pk` when either side did.
- **Migration** (`mirror.rank_room`, from `keep_order` when the order is right): each track whose held version doesn't say its folder gets a
  version that does, by its maker, from the tree (its depth-given parent), with the tree's depth: two computers doing it write the same.
- **Keeping old computers in line** (`mirror.rank_room` again): a version whose folder isn't the tree's (a loop broken, two folder changes
  merged, a stale depth) or whose rank is out of the tree's order (the fewest such tracks: `mirror.moved_tracks` of rank order against tree
  order) is said again with the tree's parent, its depth as `rank.depths` spells it and a rank between its tree neighbours. By its maker as
  usual, and by any computer that finds it so while it holds the same versions as a caught-up bandmate (a peer's status with pending 0 and
  the same `mirror.root` code), whoever's claim stands. See "Deviations".
- **Undo / Restore** (`mirror.revert`): a track keeps the folder the tree gives it now, with its depth here, unless a folder change someone made
  is among what's taken back (`unfolder` on a version between, through `mirror.moved_since`'s new `field` argument); then it goes back to that
  folder. It sends `pk`.

### Deviations from the design, on purpose

- **Depth still travels and is still hashed** (the design: "depth stops travelling", hash without it). Old computers need it; and with
  `W.one` taking parent and depth from the band's version for every track this person didn't refolder, a depth StudioSync worked out is never
  read as an edit, so keeping it in the hash costs nothing. It can leave the hash at the floor.
- **A track with no folder said isn't placed by `after`** (the brief: "placed the way phase 4 places unranked tracks"): its place in the list
  is still phase 4's (rank, or under `after`); its *folder* is the one its version's depth gives it in that list, which is what REAPER's
  depths have always meant. Its own `parent` field is not used: it's the stale one. (I tried "use the version's `parent` once any track says
  its folder": a room's first edit after the update then let every stale `parent` decide, and restructured the song.)
- **The loop rule is "newest held version leaves"**, not "newest parent change": the held version is what every computer has; which version
  last changed the parent would need a walk per track. In practice the newest version of a track in a loop is the move that made it.
- **Write-back by anyone (off-tree versions).** The design has each computer only *show* the tree. Mixed rooms showed why that isn't enough:
  an older computer puts the versions' depths in place and sorts by rank alone, so wherever a version's depth or rank isn't the tree's, it
  shows other folders, and only an older computer's own tracks (which no new computer may change as maker) stay off. Makers alone: mixed soak
  21 of 30. Any computer, at once: a late joiner still catching up said its half of the versions again, newer than the edits on their way, and
  won the merges (the long soak's 9017). Any computer after 60 s with nothing landing: still a late joiner waiting on a merge's missing side.
  Any computer **holding the same versions as a caught-up bandmate** (a fact from the statuses, no timer): the version it writes is the
  one every such computer writes (the same tree from the same versions), and two of them merge to themselves.
- **The order heal runs every 30 s in a room with ranks** (it waited for an "apart" status; it still waits `ORDER_WAIT` after a bandmate's
  move lands): the folders a put-back leaves in REAPER need it, and in a room with ranks it moves nothing that isn't off the tree.
- **`mirror.edited_here` reads a ranked track's folder as the tree's** (Undo's "changed here since"): after the tree put a restored folder
  right, a Redo found the track "changed here since" and skipped it (the long soak's 5029).
- **Undo looks past StudioSync's own versions** (`auto`: ranks, folders said again) to the last version a person made when it decides
  "kept what collaborators added since". A write-back on a track your Undo had brought back kept it from your Redo (468f054).
- **`mirror.set_track_state` never writes the depth of a track with a rank.** An item landing (`lanes_back`) put its track's held version back
  whole, depth and all, and undid the folder a bandmate's track had just been put in (the quick soak's seed 2, test part 8).

## Known limits

- **An older computer's folder change that moves a track without sending it** (REAPER's indent of a range, a folder closed further down)
  doesn't move that track on new computers once it says its folder: an older StudioSync never sends a track whose own depth didn't change.
  The soak's folder moves (drags) don't do that; REAPER's indent does. Mixed rooms only; gone at the floor.
- **A put-back folder change** (refused by a claim) is put back by the order heal within 30 s (two minutes after a bandmate's move), not at once.
- **An empty folder at the end of the song** (depth 1 with nothing under it) is kept as REAPER has it on the computer that made it; the
  others show the same tree (no children) with depth 0. Same song, other spelling; the oracle compares parents and order.
- **The write-back needs a second new computer** holding the same versions (or the track's maker): a room of one new computer and older
  ones repairs only the new person's own tracks. Until a write-back lands an older computer shows a merged or restored version's depth.
- Undo's three-way merge already keeps a bandmate's folder change made since (test part 7); revert's own folder rule matters for Restore and
  for versions from before `pk`, which no test part pins on its own (see Tests).

## Tests (`tests/test_0_60_rt_folders.lua`)

Each part checked against the piece it pins by turning that piece off in a scratch copy:

| Part | What | Fails without |
| --- | --- | --- |
| 1 | `rank.tree` / `rank.depths` / `rank.depth_parents` (pure): tree order, children under their folder whatever their rank, folders by depth when not said, loops broken by the newest, depths | `lib/rank.lua`'s new functions |
| 2 | a track put in a folder sends parent (pk, hv 10); lands in that folder; and out again | hv 10 / pk (fails on the previous commit at its first assert) |
| 3 | a folder change in pieces: the child lands first and is in the folder at once; Bee sends nothing | `W.one`'s band parent and depth ("Bee sends nothing") |
| 4 | a loop of parents from two computers: one valid tree on both | migration (`rank_room`'s `par`: without it a third, unsaid track is read into the loop's folder by depth) |
| 5 | an older StudioSync's version (no pk, stale `parent`): folder by depth | depth inference (part 1 pins it too) |
| 6 | migration: once, by the maker, from the tree; Bee says nothing | `rank_room`'s `par` |
| 7 | Undo of a folder move takes it back; an Undo after one keeps it; an Undo past an older computer's folder change keeps that folder and says `pk` | passes with revert's folder rule turned off (Undo's merge keeps it): see Known limits |
| 8 | an item landing on a folder track keeps the folder | `set_track_state`'s depth skip |
| 9 | merge: parent and depth together | the "folder" group in `merge_track` |
| 10 | an off-tree version (stale depth, rank out of tree order) said again by a non-maker only once a caught-up bandmate holds the same versions, once | the write-back |
| 11 | a bandmate's computer's write-back on a track your Undo brought back doesn't keep it from your Redo | 468f054 |

`test_0_60_rt_reopen` part 4 (the floor): fails without ddb6582 ("never settled": it asked for 1 of 2).

## Gates

Each from a fresh clone of the commit named, the 237 seeds of rt-sync2a's ranges (5000-5057, 9000-9059, 13000-13059, 15000-15058) at 150
edits, seed by seed (soak's `run_once` per seed in a pool, a scratch script as rt-sync2c's), and the mixed soak 5000-5029 with Cee on
`9164f56` (pushed main).

### The baseline (7efd304: folder moves in the draws, before any behaviour change)

| Range | Seeds | Passed | Failed |
| --- | --- | --- | --- |
| all | 237 | **233** | 9056 (a track differs: Gtr's folder, the depth model's own class, now drawn), 9059 (undo probe: an item missing after Undo then Redo), 13008 (tempo map / markers), 15057 (tempo map / markers) |

Mixed at 7efd304: **30 of 30**. Scenarios: 14, 13 as they say: `tempo-env` (the frozen seed rt-sync2c moved off its bug) fell back on it
there (its one track_move draw is now a folder move); at 468f054 it passes again, as it says. The new `folder-loop` scenario on 7efd304 ends
on every computer with Keys and Bass both closing a folder that never opened.

### The gate (fe9ccb2, the last code commit; 468f054's numbers beside it)

| Check | Result |
| --- | --- |
| long soak, 237 seeds | not finished at handback (468f054: **236**, 15057 only: tempo map / markers, the timeline class, rt-sync2b Recommendation 7, in every run since rt-sync2c; baseline 233, rt-sync2c's gate 235) |
| folder or order failures | **0** (no track `T` differs, no "track order differs", in any seed; 9056 passes) |
| deletion gate | never tripped |
| mixed soak, Cee on 9164f56, 5000-5029 | not finished at handback (468f054: **30 of 30**) |
| `soak.py --scenario all` | not finished at handback (468f054: 14 of 15, `folder-loop` on the other valid tree, see below) |
| `python tests/run.py --no-luals`, local time | at fe9ccb2: not finished at handback. At 468f054 (soak load running beside it): fails 2, `test_0_60_rt_bigproj` (36.0 ms against 36: a strict timing test under load) and `test_0_60_rt_edits` (the order-heal wait, fixed in fe9ccb2; alone at fe9ccb2: ok) |
| the same with `TZ=UTC0` | not finished at handback |

`folder-loop` at 468f054 first ended on the other valid tree than the one its check named (Keys holding Bass): the write-back (any computer
holding the same versions as a caught-up bandmate) fixes the tree as it stands when it runs, so which of the two stays on top isn't the
loop rule's alone. All computers agreed and the tree was valid; the check now accepts either.

### The runs on the way (what each found)

| Code | Long soak | Mixed | What it showed |
| --- | --- | --- | --- |
| first cut (no depth skip) | (quick soak) | | seed 2 at 40 edits: an item landing put a folder track's old depth back (`lanes_back`): `set_track_state` skips a ranked track's depth |
| + depth skip, order heal every 30 s | 235 (9018 undo probe, 15057) | 16 of 30 | older computers show versions' depths and sort by rank alone: merges split parent from depth; tracks out of rank order |
| + parent and depth merged together | | 18 | |
| + write-back by makers | | 21 | an older computer's own tracks stay off (no new computer is their maker) |
| + write-back by anyone, ranks re-sorted, canonical depths | | 27 -> 29 | a late joiner catching up wrote back its half (newer than the edits on their way); timers tried (120 s, 60 s) |
| write-back only while holding a caught-up bandmate's versions | 9017 passes; 5029 (Redo found a ranked track "changed here since") | | `edited_here` reads a ranked track's folder as the tree's |
| c3dff2e | 5016 (undo probe) in the first 96 seeds | | Redo kept a track your Undo brought back because a write-back (auto) on it read as a bandmate's change: 468f054 |
| 468f054 | **236** | **30** | the test suite: `test_0_60_rt_edits` pins the order heal's ORDER_WAIT after a move lands, which the every-30-s heal skipped: fe9ccb2 |


## REAPER checks for James

All on the real computers after a release with these files. Keep a copy of the test song's folder first.

1. **The switch-over:** update every computer, open the song: within a minute or two the log says "N track(s) given their folder as a
   parent" on each computer, once (for the tracks its person made). Folders look exactly as before.
2. **Into and out of a folder:** on the desktop drag Gtr into the Bass folder; the laptop and Mac show Gtr inside Bass within seconds. Drag it
   out again; same. Then select a track and use REAPER's indent (Track: Indent / make folder) and outdent actions: the others follow.
3. **A folder change landing in pieces:** with the laptop's Syncthing paused for 20 s, drag two tracks into a folder on the desktop; unpause:
   the laptop shows them inside the folder without any track jumping into another folder on the way, and its log shows nothing sent.
4. **Two folder moves at once** (rt-sync2c check 8, now expected to agree): the desktop drags Keys into Bass while the laptop drags Bass into
   Keys, within a second. All three end with the same valid folder (one inside the other), and stay so after a minute.
5. **A folder moved while a child is dragged out of it** on another computer, within a second: all three end the same.
6. **Item on a folder track:** record a take on a folder track while someone else drags a track into that folder: the folder stays.
7. **Undo:** drag a track into a folder, press StudioSync's Undo: out again everywhere; Redo: back in. Rename a track inside a folder, Undo the
   rename: it stays in the folder.
8. **An old-version computer in the room** (one computer kept on the previous release): drag tracks into and out of folders on it and on a
   new one; within a minute of quiet all three show the same folders and order.
9. **The big-deletion ask's floor** (rt-sync2c check 4, amended): in a 2-track song delete 1 track: no ask, it goes. In a 4-track song delete 2:
   it asks; delete 1 of 4: no ask; Ctrl+A, delete: asks.
10. **REAPER's own depth after a drag** (read only, ReaScript console): after dragging a folder track with two children up past another track,
    print `I_FOLDERDEPTH` of each track. Tell me if REAPER moved the children with it and what depths it wrote: `mirror.tree_depths` rewrites
    them from the tree after StudioSync's own moves, but a person's drag is read as REAPER leaves it.

## What phase 5 should know

- **`mirror.HV` is 10 now** (parent in a track's line). Phase 5's beats need **11**. hv is one number for every kind.
- **Track versions carry `pk`** beside `rk`: a new field old computers ignore; anything that copies a track state whole (Undo, Restore,
  `rank_room`) should say it or not as `mirror.revert` does.
- **`mirror.set_track_state` skips the depth of a ranked track.** Anything new that puts a track's state in place gets folders from
  `mirror.tree_depths` (or the next order heal), not from the version.
- **The order heal runs every 30 s in a room with ranks** (it waited for "apart"). A tempo change moves no track; nothing in phase 5 needs
  `lib/rank.lua`.
- `tempo-env` is still a frozen seed on phase 5's class (see Gates).

## Recommendations (ranked)

Recommend only; none built here.

1. **Tell old computers apart from new ones in a room** (rt-sync2's `v` field, phase 6, sooner): today a new computer can't know whether an
   older StudioSync is present, so it pays for mixed rooms always (depth kept in the hash, the write-back, the order lists). With `v` on every
   change, the write-back could run only while an older computer is in the room, and the floor would be a fact, not a guess.
2. **Make StudioSync's own write-backs lose ties to people's edits.** A write-back (`rank_room`'s `auto` versions: ranking, migration,
   off-tree) is a full version, newer than the edit it was built beside, so in a merge it can win a setting a person changed at the same
   moment. Giving `auto` versions their base's rev (so any person's edit, rev + 1, outranks them in `merge_order`) would let any computer write
   back without waiting to match a bandmate. Needs care in the judge (equal revs on one object from one parent).
3. **Group rank with the folder in merges** (`rank` in the "folder" group): a move into a folder changes both; merged apart, the rank of one
   side and the folder of the other is a place neither chose. The write-back repairs it after the fact today.
4. **Read REAPER's indent of a range as each track's parent change on old computers too**: not possible on old versions; at the floor, drop
   depth from the hash and the write-back's depth half.
5. **Health's content code** (rt-sync2 5c) would show "same versions, different folders" between a new and an old computer directly, instead
   of the soak finding it.

## Review later (security)

- `parent` is bandmate data: a parent that isn't a track here (or itself) is the top level; a loop is broken; nothing reads it as a path.
- **The write-back passes claims**: any new computer says an off-tree track's folder, depth and rank again, whoever claimed it. It changes
  only those three fields to values every computer computes from the versions it holds, and older computers' receive still holds a claimed
  change a minute; but it is a StudioSync act on a claimed track by someone who doesn't hold the claim. Same trust as every field today (the
  studio's key signs for everyone).
- `mirror.tree_seen` is per project tab, in memory, one string per track.
- The write-back trusts bandmates' statuses (`mirror` code, `pending`) to decide *whether* to send; a forged status can make a computer send a
  write-back, never choose its content (that is the tree of what it holds).

## What I didn't check

- Nothing was run in REAPER: REAPER's own depth handling on a drag and on `ReorderSelectedTracks` (check 10), indent/outdent actions (check 2).
- Two old computers in a mixed room; a room migrating while folder moves happen; Restore across a folder change (only Undo is tested).
