# rt-sync2i: phase 7, Undo from ancestry (2026-11-28)

rt-sync2's phase 7 (`docs/rt/rt-sync2.md` §5a, §9): StudioSync's Undo and Redo decided from what each change was built on, not from
History's rows. On top of 4ebead2 (0.65.2, hv 14, level 14). No hv or level change. Nothing deployed, released, pushed or version-bumped;
`lib/webui.lua` and `lib/webui/index.html` (someone else's) untouched.

## Summary for James

- **Undo takes back your newest act by your own computer's clock.** Until now it went by History's list, which is sorted by each computer's
  clock. A computer whose clock was off, or a marker moved in the same second as an item, could make Undo pick the wrong act.
- **What an Undo writes is your change taken back, built on what everyone has now.** If a bandmate changed something else on the same item,
  track, automation or plug-in chain since, their change stays. Where you both changed the same thing, yours goes back (the ask says so, as
  before). Redo is the same rule run on the Undo.
- **A deleted thing you undo comes back as it was, at its place in the track order, with what was on it.** An edit of yours that a
  bandmate's deletion beat stays deleted.
- **History's "Undo this change" uses the same rule**, and Undo on a Restore's row still puts today's tempo map back (your 11-21 decision).
- **Nothing to do for you.** The live checks are written but weren't run (the live machines were busy); the build isn't deployed.

## Commits

| Commit | What | Fails without it |
| --- | --- | --- |
| c8b0e34 | phase 7: Undo from ancestry (`lib/undo.lua`; removals in `lib/mirror.lua`; `lib/page_restore.lua`, `lib/webrestore.lua`; a timeline change carries `hlc`, an Undo's timeline change its press's `act`, `lib/sync.lua`); tests moved to the new functions; soak scenario `undo-after-bandmate` | `test_0_60_rt_undo2` 1-6, `test_0_60_rt_converge` 8d and 23, `test_0_59_45_engine`, `test_0_59_46_engine`, `test_0_60_rt_edits`; scenario `undo-after-bandmate` (knock-outs below) |
| ede0a18 | a track's deletion no longer names where it sat (`was_after`): its rank says | `test_0_60_rt_converge` 27 |
| (live set) | `tools/live/sets/sync2i.py`: i1-i4 | live (below) |
| (this doc) | docs/rt/rt-sync2i.md | |

## 1. What was built (`lib/undo.lua`)

### Which act

- `undo.acts(entries, user)`: your own acts, newest first. An act is the changes one look (or one Undo or Redo press) sent, grouped by
  their `act`; a change with none (an older build's) is an act on its own. Acts are ordered by your own clock, `hlc` (milliseconds; a change
  from before clocks counts by its second). History's row order decides nothing.
- A Restore (`restored`, with no `undoes` or `redoes`) and StudioSync's own refreshes (`auto` alone) aren't acts Undo steps. Before, a
  Restore's restored rows were passed over but its deletions weren't, so Ctrl+Z after a Restore brought back only what the Restore deleted.
- **Undone:** a change an Undo names (`undoes`, `undoes_all`), unless a Redo names that Undo (`redoes`, `redoes_all`).
- `undo.last_mine`: the newest edit act with changes not taken back. An act whose object changes are all taken back counts as undone with
  its timeline change (an older build's Undo didn't name it). Passed-over timeline changes ("undo passed") skip their act. A deletion on
  another lane than the act's newest change waits for the next press, as `mirror.same_moment` keeps a pass and its comp copies apart
  (Mac 0.42.10), except when the act deletes a track: then the track comes back whole.
- `undo.last_undo`: your newest Undo act not redone; a change of yours since (not an Undo or Redo) ends Redo.
- **A timeline change now carries `hlc`** (`sync.post`), so a marker moved in the same second as an item edit is ordered by when it was made.
  An Undo's own timeline change carries the press's `act`, so it belongs to that Undo.

### What it writes

`undo.plan(entries, rows, read, held)`, per object of the act: `a` is the act's newest version of it, `before` what the act's first version
was built on (`base_ev`, down past the act's own versions; a merge `m(x&y)` is read whole).

| Case | Written |
| --- | --- |
| the act made it (nothing before it, `mirror.began`) | it goes |
| `a` is a deletion | `before` comes back: its state, rank and parent; its items and parts by containment (`mirror.revert`'s `contents_owed`). Nothing if it's already back (someone else undid the deletion) |
| `before` is a deletion (an Undo of a deletion, redone) | it goes |
| an edit, held version not a deletion | `undo.reverse(a, before, held)` = `merge_state(kind, base = a, winner = before, loser = held)`: a bandmate's change since stays where it's theirs alone; where both changed one thing, going back wins |
| an edit, held version a deletion | marked `beaten`: `mirror.revert` leaves it and says "deleted by a bandmate since, left deleted". An edit a deletion beat stays beaten, whoever's the deletion |
| `before` can't be read (trimmed away, not here yet) | nothing for that object |

"Held" is the version this computer holds (`mirror.known`): the judge's answer once it has landed. `mirror.revert` writes each version on
it, as before.

- `undo.since(read, a, held, me)`: who else's versions are in what's held that `a` didn't see: later versions and versions made apart and
  merged in. This is the ask's "X changed it after that".
- `undo.moment(entries, i)`: History's "Undo this change" rows: `mirror.same_moment`, plus, where they delete a track or items on one, the rest
  of that deletion in the same act.
- **Redo** runs `undo.plan` on the Undo act's own versions: a creation's Undo (a deletion) comes back, a deletion's Undo (built on the
  deletion) goes, an edit's Undo goes back to what was held when you pressed Undo, a bandmate's change included.

`undo.step` is rewritten on these. History's panel button and the History web page (`page_restore`'s `undo_plan` / `undo_change`,
`webrestore.undo_words`) use `undo.moment` + `undo.plan` and its `since`.

## 2. Removed

| Removed | Was |
| --- | --- |
| `mirror.plan_undo`, `mirror.plan_undo_moment` (and its walk over History for a track's deletion across seconds) | the version before by History's rows |
| `mirror.last_mine`, `mirror.last_undo`, `mirror.later_by_others` | which act, and who changed it since, by History's rows |
| `mirror.undo_keeping` | the reverse merge, now `undo.reverse` |
| `undo.step`'s `base_ev` walk | the version before, now `undo.plan` |
| `was_after` (written by `W.gone` and `mirror.revert`, read by `mirror.revert`; `w.order_was`; revert's `sat`) | where a deleted track goes back; its rank says now |
| `mirror.revert`'s "a bandmate's deletion since" test for Undo and Redo | the plan says it (`beaten`) |

Kept for history reading only: `undoes`, `undoes_all`, `redoes`, `redoes_all`, `restored`, `act` on the wire, and `mirror.same_moment` /
`entry_lane` / `lane_words` (History's rows).

## 3. Kept

- **On this computer only:** the ask (press again within 30 s, or the bar's Yes), "undo nothing" (an Undo that took nothing back leaves
  nothing to redo) and "undo passed" (a timeline change a bandmate changed since is passed over), per tab.
- **The timeline's own undo** (`sync.undo_timeline`, `timeline_before` by `built_on`): markers aren't objects yet (rt-sync2
  Recommendation 3).
- **Comparing markers "on the map in place"** (`undo_timeline`'s `placed`). §5a lists it under "what goes" because markers carry quarter
  notes, but they don't (`band.capture_markers` writes seconds). Removing it would bring back the soak's seed 3003. It goes when markers
  become objects.
- **Panel Restore** (`plan_restore`) is unchanged; **Undo on a Restore's row** still puts today's tempo map back first.

## 4. Tests and knock-outs

`tests/test_0_60_rt_undo2.lua` (new):

1. the act is chosen by your own clock, not History's rows; an act is its `act` across seconds and kinds; a Restore (its deletions too)
   and an automatic refresh aren't acts; a bandmate's change isn't yours
2. an Undo names what it took back; a Redo makes it count again; a change since ends Redo; two Undos then two Redos; an older build's
   Undo that didn't name the act's timeline change; a passed-over timeline change; the comp-lane rule
3. a creation goes; a deletion comes back at its rank; a deletion already undone by someone else brings nothing; a trimmed base plans
   nothing; a restore's Redo deletes; an edit a deletion beat is planned beaten
4. an edit undone after a bandmate's mute keeps the mute; both moved it: going back wins; built on a merge of two made apart: her change stays
5. `undo.since`: a later version's maker, never you, nobody when nothing since, not StudioSync's own refresh
6. Redo is Undo applied to the Undo act: exactly what was held comes back; Redo of a creation's Undo brings it back; Redo of a deletion's
   Undo deletes again

Moved to the new functions (same assertions, fixtures given `base_ev`, `act` or `hlc` where the rule now reads them): `test_mirror` (History
glue, comp lanes, the print after an Undo), `test_review_sync` (trimmed base, creation, empty plan), `test_0_59_45_engine` (S11 three items,
S5 a track with items on two lanes), `test_0_59_46_engine` (Redo after an Undo that removed, two Redos, a track with items a second apart),
`test_0_60_rt_histhear` (a Restore undone as one act), `test_0_60_rt_edits` (Undo this change covers the Restore's changes),
`test_0_60_rt_answers`, `test_0_60_rt_ui3` (the ask's names). New in `test_0_60_rt_converge` 23: a marker moved in the same second as an
item edit is undone first.

Soak scenario `undo-after-bandmate` (new): James's Undo a second after Bee's edit of the same item (her mute), its automation (another point)
and its plug-ins (the other plug-in), each on another part than his. Every computer ends with his change taken back and hers kept, then the
undo probe. The plug-in Undo lands inside `FX_SET_GAP` (5 s since Bee's chain change landed) and says "do it again"; James presses again at
97 s if his turn is still his newest act.

Knock-outs (each made in a scratch copy of the tree, the tests run, the code put back):

| Knocked out | Fails at |
| --- | --- |
| own clock: acts by History's second instead of `hlc` | undo2 1 "the newest act by my own clock, not by History's rows (a1)" |
| the reverse merge (plain going back) | undo2 4 "my move goes back, her mute stays"; scenario `undo-after-bandmate` "James's move of Drums 1 is undone" |
| `beaten` (an edit planned plainly over a held deletion) | undo2 3; converge 8d "Bee's Undo of her move leaves his deletion" |
| Redo naming an Undo | undo2 2 "the second Redo reaches the earlier Undo" |
| a deletion's reverse when it's back already | undo2 3 "a deletion already undone by someone else" |
| the lane rule's track exception | 46 engine D "and both its items" |
| `undo.moment`'s rest of a track deletion | 45 engine S5 "undoing the items brings their track deleted with them" |
| a timeline change's `hlc` (the field assertion taken out too) | converge 23 "Bee's Undo takes the marker back first ... C1@9" |
| an Undo's timeline change's `act` | rt_edits "copy a region with its items ...: the second Undo took away what the edit made" |
| `was_after` gone | converge 27 "nor does a deletion made in REAPER" |

## 5. Gates

| Check | Result |
| --- | --- |
| `tests/run.py --no-luals`, local time, at ede0a18's tree | **fails 0** (266 tests ok) |
| the same, `TZ=UTC0` | **fails 0** |
| `soak.py --scenario all` at ede0a18 | **21 of 21 as they say** (`restore-race` and `undo-gone-with-track` pass; `undo-after-bandmate` new) |
| `soak.py --scenario all` at c8b0e34 (commit 1 alone, from `git archive`) | 21 of 21 as they say; undo2, converge, edits, mirror and both engine tests pass there too |
| long soak, `range.py` from a fresh clone of ede0a18, 8 procs (no other `range.py` / `soak.py` running: checked) | **237 of 237** (baseline 237). Every seed's check ends with the undo probe (an Undo then a Redo on each computer, the song the same after each and as it was), so the probe passes on every long-run seed. The live set and this doc change nothing the soak runs |
| `files_check` / `release_check` | notes only, as at 4ebead2 (`lib/files.txt` is made at release) |

`rt_bigproj` and `rt_drivebg` passed in both runs, so no A/B against 4ebead2 was needed.

## 6. hv and LEVEL

Unchanged (14 and 14). Nothing that goes into a hash changed. On the wire, a timeline change gains `hlc` and an Undo's timeline change
gains `act`, both optional fields an older computer ignores; a track's deletion drops `was_after`, which an older computer's revert only
used to place a returning track (it then goes by its rank, as rooms are ranked). Undo is decided on the presser's computer and writes
ordinary versions, so a 0.65.2 computer in the same room keeps working.

## 7. Live results

**Not run.** The orchestrator was running its full live regression on the desktop and LinuxBox throughout this round and hadn't
handed `tools/live` over, so nothing here touched them. The set is written and parses: `tools/live/sets/sync2i.py`.

| Run | What it does | Expect on this build | On today's 0.65.2 |
| --- | --- | --- | --- |
| i1 | desktop moves an item, the bandmate mutes it, desktop's StudioSync Undo (asks, answered by pressing again), then Redo | item back at 4 s and still muted on both; Redo: at 8 s, muted | the same (0.65.2 already merged an Undo onto what's held, `undo_keeping`) |
| i2 | an item with notes deleted and undone; then its track deleted and undone | item back with the same notes, place and id; then the track with its item; no "(yours, not sent)" track on either | the same expected |
| i3 | (timebase beats) desktop moves an item from beat 8 to 12, the bandmate sets 60 bpm, desktop undoes then redoes | item at beat 8 (8 s) with 60 bpm kept; Redo onto beat 12 | the same expected |
| i4 | History's "Undo this change" on the desktop's move (bandmate's mute since); then a whole-project Restore to before a bandmate's 100 bpm and a move; then "Undo this change" on the Restore's row | the move back, mute kept; the Restore puts 120 bpm and beat 4 back; its Undo puts today's 100 bpm and 7 s back | the same expected |

Run: `export X_IP=192.168.86.129; python tools/live/live.py run sync2i --on d,x` (laptop off). It changes the project timebase in i3/i4 and
puts it back, and leaves the tempo on one marker of 120 bpm. On 0.65.2 every row should already pass: this round changes how Undo decides,
not what these four end with. What only this build changes (same-second order, a Restore's deletions passed over, a deletion already
undone by someone else) is in the offline tests.

## 8. Known limits

- **An Undo pressed within 5 s of a plug-in chain change landing** on that track isn't done ("couldn't change here yet ... do it again
  then"): `FX_SET_GAP`, REAPER's crash guard. As before; the scenario presses again.
- **"Held" is what this computer holds**, so an Undo pressed before a bandmate's edit has arrived builds on the version before it; the two
  are made apart and the judge merges them (the scenario covers both orders).
- **A room not ranked yet**: a deleted track that comes back goes where its version says (`after`), not where it sat when deleted. Rooms
  are ranked from their first tracks (rt-rank 14) or at the first order heal.
- **History's "Undo this change" now leaves an edit a deletion beat deleted**, as StudioSync's Undo does. A Restore still brings back what
  it's asked to.
- **An older build's Undo whose timeline change has no `act`** is an act of its own here. It only matters for a Redo pressed right after
  such an Undo; `sync.act_timeline` still finds its timeline change by what it undid.
- **Item timing is one thing in the merge** (position, length, offset, rate, stretch markers: `merge_item`'s TIMING): a bandmate's resize
  and your move of the same item clash, and going back wins.
- **The ask's wording in History** ("undoing it takes their change back too") is unchanged, though only what you both changed goes back.

## 9. Recommendations (ranked)

1. **Run `sync2i --on d,x` once the live machines are free** (on 0.65.2 now, then again after a deploy). It should pass on both.
2. **Retry a plug-in Undo after `FX_SET_GAP` instead of asking for another press.** Undo within 5 s of a chain change landing does nothing
   and says "do it again"; Live sync could carry the press out once the gap passes (as it carries the bar's Yes).
3. **Markers as objects** (rt-sync2 Recommendation 3). Then `sync.undo_timeline`'s marker comparison "on the map in place" and `built_on`
   go, and timeline Undo needs no code of its own.
4. **Reword History's ask** to say only what you both changed goes back (StudioSync's own ask already says so).
5. **Phase 8 (timers into facts, Health content code)** is next in rt-sync2's plan.
