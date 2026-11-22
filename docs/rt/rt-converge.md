# rt-converge: the sync core converging under concurrent edits (2026-11-21/22)

The convergence soak (`docs/rt/rt-soak.md`) failed 93 % of its seeds. This package fixes the sync core until it passes: the nine bugs of
rt-soak.md, what rt-fix6a left (a fresh REAPER's lane names going out), three of the four sync-core bugs of the third REAPER re-check (rt-r2,
`docs/rt/rt-p1.md`), the three of the fourth (rt-r3, in `docs/rt/rt-fix6a.md`), and what the soak found on the way once those were out of
the way. Files: `lib/mirror.lua`, `lib/sync.lua`, `lib/undo.lua`, `lib/claimask.lua` (one hook, for rt-r3); `tools/soak/soak.py`,
`tools/soak/node.lua`; tests `tests/test_0_60_rt_converge.lua` (new, 30 parts) and two expectations in `tests/test_0_60_rt_edits.lua`.
No shared file touched (`StudioSync - Live sync.lua`, web UI, panel). **Nothing here was run in REAPER**: the checks are at the end.

Every fix has a part in `tests/test_0_60_rt_converge.lua` that fails with the fix taken out (checked by running the test against a copy of
`lib/` with that one change reverted). Each fix is its own commit. `python tests/run.py --no-luals` ends `fails 0` in a clean checkout
of the head, in local time and with `TZ=UTC0`; which commits were also run one by one is under "Limits" ("Per-commit checks").

## What was wrong, in three sentences

The sync core is an event log per object with merges, and it converges when every computer's project is the same function of the same
events. It wasn't, in four ways: (1) an item's text is in seconds and nothing said which tempo map those seconds were on; (2) several code
paths each decided what an object is (the live receive, the catch-up, heal, the look), and they disagreed whenever things arrived in another
order; (3) decisions were made from what one computer happened to hold at that moment (today's claims, a 15 s window, which version had
arrived, Lua's table order) instead of from the change's own facts; (4) what a look couldn't send stayed on that computer, silently or
asked about for ever. Most fixes below are one of those four.

## Commits and pass rates

Measured from a clean checkout of each commit (`--seed N --edits E`, undo probe on): the 18 repro commands listed in rt-soak.md and
rt-fix6a.md, seeds 1-40 at 40 edits, seeds 3000-3023 at 120 edits; from row 27 also seeds 5000-5053 at 150 edits, the length of a
`--long` run; from row 35 the seven seeds of other ranges that still failed there (3003 at 120 edits; 6002, 6037, 7015, 7045, 7051, 7055
at 150). An empty cell wasn't measured; `=` is "as the row above" (a test-only commit). Three things to read the table by:

- Seeds only became repeatable at row 14 (bug 8), so earlier rows wobble by a seed or two.
- Every fix changes what a run does after it, so fixing one failure in a seed often uncovers the next: a row can dip (16, 28), and a seed
  can pass at one row and fail at a later one (6002 passed at 37 and failed again at 40, for another reason).
- Each row was measured as the work went, before the later rebases onto other packages' commits (rt-fix7, rt-fix8, rt-t1 and the
  browser guests' buffer: none touches these files), so under another hash; the hashes shown are the ones on `realtime`.

| # | Commit | What | Repros (18) | 1-40 @ 40 | 3000-3023 @ 120 | 5000-5053 @ 150 | 7 late seeds |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 1c9958f | before (rt-fix6a) | 8 | 7 | 2 | | |
| 1 | 86f4e89 | soak: link inbox read, stand-in tempo move as `mirror.retime`, late joiner waits out refused changes | 10 | 9 | 2 |  |  |
| 2 | cf83d10 | **A version names its tempo map** (bugs 1, 5, 7) | 10 | 18 | 5 |  |  |
| 3 | c2c6563 | **A change is judged by the claims of its own time** (bug 3) | 10 | 17 | 5 |  |  |
| 4 | 4e23eeb | soak: Live sync's apart note and claim tidy in each computer, 140 s of quiet | 14 | 23 | 13 |  |  |
| 5 | 1a31427 | **A track change moves its track only when its place is what it changes** (bug 6) | 13 | 23 | 11 |  |  |
| 6 | 6f61c33 | **Two holders of one track don't answer each other's rename for ever** (bug 2) | 14 | 22 | 11 |  |  |
| 7 | a3ba473 | **What a look can't send doesn't stay on that computer, asked about every 90 s** (the settle failures) | 13 | 23 | 11 |  |  |
| 8 | 25dd2ac | **A track that comes back brings its items back on every computer** (bug 4) | 15 | 24 | 12 |  |  |
| 9 | ca171fb | **Undo then Redo brings the song back** (bug 9, undo probe) | 17 | 33 | 10 |  |  |
| 10 | 9ef10d9 | soak: the oracle's number allowance covers whole numbers | 18 | 35 | 15 |  |  |
| 11 | dffe89e | **The studio's track order is the order everyone landed** (bug 6, late joiner) | 18 | 37 | 17 |  |  |
| 12 | f1b94a8 | **An edit beaten by a deletion stays beaten when the deletion is taken back** | 17 | 39 | 20 |  |  |
| 13 | 8e3d984 | **Undo/Redo of a marker or tempo change go by the timeline's own order** | 17 | 40 | 19 |  |  |
| 14 | 6128c12 | **No choice follows Lua's table order** (bug 8) | 18 | 40 | 21 |  |  |
| 15 | 9b45210 | **A claim made in the same second as a change doesn't count against it** (rt-r2 P1-1/P1-2's 61 s) | 18 | 40 | 20 |  |  |
| 16 | cb05709 | **A plug-in knob turned unseen holds the band's chain back** (rt-r2 P1-4, P1-1) | 18 | 39 | 15 |  |  |
| 17 | 07c44bf | **REAPER's own Undo of a track deletion brings the track back** (rt-r2 P1-6) | 18 | 39 | 15 |  |  |
| 18 | 7426cd9 | test: a pin for rt-r2's P1-5 (no code change) | = | = | = |  |  |
| 19 | 31ed5e2 | **Only a move moves a track; only a sent move reaches the order list** | 18 | 39 | 16 |  |  |
| 20 | 65e98d4 | soak: a version per file write; the driver edits studio tracks only | 18 | 39 | 16 |  |  |
| 21 | 667b5b8 | **An Undo doesn't bring back what a bandmate deleted since** | 18 | 39 | 16 |  |  |
| 22 | d25f95f | **Lanes that only read differently here, with no edit behind the look, don't go out** (rt-fix6a's "left") | 18 | 39 | 16 |  |  |
| 23 | 11e7c9d | **The unseen-knob check compares with the chain's knobs as it last landed or went out** (fixes 16) | 18 | 40 | 18 |  |  |
| 24 | 2552442 | **A merge isn't built while a version it rests on is still on its way** | 18 | 40 | 20 |  |  |
| 25 | 7875311 | **An item moved onto a track deleted that moment goes with the track everywhere** | 18 | 40 | 20 |  |  |
| 26 | c68818f | **Undo and Redo go back to the version a change was built on** (undo probe) | 18 | 40 | 21 |  |  |
| 27 | aa9b3bd | soak: the in-memory disk keeps up with `band.write_atomic` as rt-fix7 left it (nothing ran without it after the rebase) |  |  | 21 | 47 |  |
| 28 | a9917bd | **Each computer says its track order when a bandmate's move lands** (late joiner) |  |  | 22 | 43 |  |
| 29 | cb0d0e8 | **A plug-in chain changed back to what an earlier version was still goes out** |  |  | 22 | 44 |  |
| 30 | 7b8374f | **The order list follows a landed move only when the move is fresh** (fixes 28) |  |  | 23 | 49 |  |
| 31 | acad972 | soak: the late joiner gets the order heal a real one gets |  |  | 23 | 50 |  |
| 32 | 0244086 | **Deleting an item goes out though a grey stand-in carries its id** |  |  | 23 | 51 |  |
| 33 | da606de | **A deletion waiting for an answer doesn't hold the item back once the band has deleted it** |  |  | 23 | 52 |  |
| 34 | 5073d63 | soak: one tempo marker to a place |  |  | 23 | 53 |  |
| 35 | 71ed3fc | **An item that went with its deleted track stays gone when its earlier versions arrive after** | 18 | 40 | 23 | 54 | 0 / 7 |
| 36 | c3f2d44 | **Undo of a marker change compares the markers on the map in place** (undo probe) |  |  |  |  | 2 |
| 37 | d8237d7 | **Undo of a timeline change goes back to the version it was made on** (undo probe) |  |  |  |  | 3 |
| 38 | 7b9927b | **A note the claimer moved stays theirs through your own change to it** (rt-r3, 7) |  |  |  |  | 3 |
| 39 | c6fce65 | **A change sent past an auto-claim whose claimer can't be asked lands at once elsewhere too** (rt-r3, 8) |  |  |  |  | 3 |
| 40 | 735f7cb | **A deleted track's auto-claim goes with it; an edit held for its deleter's answer goes with the track** (rt-r3, 9) |  |  |  |  | 4 |
| 41 | 9c2cfaa | **A deleted track comes back where it sat when it was deleted** (undo probe) |  |  |  |  | 5 |
| 42 | a3fc936 | **An item's older versions don't wait for ever where its newest sits on a track deleted since** (late joiner) | 18 | 40 | 24 | 53 | 6 |
| 43 | 23158a9 | **Undo of a marker change leaves a marker a bandmate has changed since** (undo probe; seed 6002) |  |  |  |  | 7 |
| 44 | c19caa6 | **A new chain lands where no plug-in is here** (fixes 16; seeds 5008, 9026) |  |  |  |  |  |
| 45 | ee95e87 | **Heal doesn't undo a deletion held here whose file isn't readable just now** (seed 8059) |  |  |  |  |  |
| 46 | e44693c | **An item put in place anew keeps its id when it's copied before the next look** (seed 8023) |  |  |  |  |  |
| 47 | 078d71f | soak: the undo probe doesn't compare where the log says a claim stood in front (seed 7017) | 18 | 40 | 24 | 53 | 7 |
| 48 | f23bb9b | **A track's part changed just as the track was deleted comes back as it was changed** (long run; seed 11013) | 18 | 40 | 24 | 53 | 7 |

**At the head (row 48), from clean checkouts.** The 18 repro commands: 18 pass. Seeds 1-40 at 40 edits: 40 of 40. Seeds 3000-3023 at 120
edits: 24 of 24. At 150 edits, 60 seeds each: 6000-6059: 59 (6006, below), 7000-7059: 60, 8000-8059: 60. `python tests/run.py --no-luals`:
`fails 0`, in local time and with `TZ=UTC0`. `python tools/soak/soak.py --quick`: `ok soak`. (Measured just before the last rebase onto
two commits of other packages, which touch none of these files.)

**The goal's long run.** `python tools/soak/soak.py --long --minutes 20 --no-shrink`, 150 edits a seed, each from a clean checkout:

| Head | First seed | Seeds run | Passed | |
| --- | --- | --- | --- | --- |
| row 28 | 5000 | 54 | 43 | 79.6 % (the first long run of this package) |
| row 42 | 5000 | 61 | 59 | 96.7 % (5008: fixed by row 44; 5057: left, below) |
| row 42 | 9000 | 61 | 56 | 91.8 % (9026, 9041: fixed by rows 43-46; 9029, 9034, 9058: left, below) |
| row 47 | 5000 | 66 | 64 | 97.0 % (5028, 5057: left) |
| row 47 | 9000 | 66 | 63 | 95.5 % (9029, 9034, 9058: left) |
| row 47 | 11000 (never run before) | 59 | 58 | 98.3 % (11013: fixed by row 48; cut at 59 seeds, I removed its folder a minute early) |
| row 48 | 5000 | 71 | 69 | 97.2 % (5028, 5057: left) |
| row 48 | 13000 (never run before) | 73 | 73 | 100 % |

At HEAD 1c9958f the soak failed 93 % of its seeds. From row 47 on every long run is over 95 %, and the failures left are each listed
under "Limits, and what's left" with what they are. What the numbers don't say: each fresh range of about 60 seeds still finds one to
three new failures, so "the soak passes" means "over 95 %, the rest known", not "nothing left to find" (Recommendation 1 is about why).

## The nine bugs of rt-soak.md

**1. A hand edit in the 15 s after a bandmate's tempo map was kept on that computer only, silently.** Root cause: `W.refuse` took any
difference in an item's timing lines, inside `mirror.TEMPO_SECS` of any tempo change, for REAPER's move, and `mirror.map_moved` could only
check that for this computer's own tempo change. Fix (commit 2): the band's version names its map, so "is this only the map's move?" is
asked exactly, at any time (`mirror.map_moved`, `mirror.only_map_moved`): the version on today's map against where the item is. A hand edit
is asked about or sent. The second half ("the studio's last version isn't readable") was a soak artifact: the soak's computers never
started the link, so mirror couldn't read a version that was only in the link's inbox (commit 1).

**2. A rename war between two holders.** Root cause: claims go by name, so after a rename two names mean one track and two people can each
hold it; each computer judged the other's version by the name the track has *there* and answered it (`set_back`), for ever. Fix (commit 6):
only a change that itself renames is a rename (its name against the version it was built on); and of two claims on one track, by its old
name and its new, the newer holds it (`sync.track_claims`, as two claims on one name are settled). One side's answer then stands.

**3. A late joiner judged old changes by today's claims.** Root cause: `sync.receive` asked `sync.authority` about now. Fix (commit 3):
`can`, `is_claimed` and `owner_of` take the change's own time; a claim made after it (or in its second, commit 15) doesn't count. A claim
that held then and is released since isn't known any more and doesn't refuse either. `sync.gone_before_claim` (rt-fix6a) is this rule for
one case; it stays. The soak's late joiner also stopped at its first quiet pass, before refused changes' minute was up (commit 1).

**4. An Undo deleting tracks lost a bandmate's fresh take on the recorder only.** Root cause: an item whose track the band deletes goes with
the track and has no deletion of its own; when the track returned, the item was brought back only where its change had been skipped while
the track was gone (`mirror.orphaned`), not where it had landed first or was kept on "(yours, not sent)". Fix (commit 8): every band
deletion of a track notes it, so a returning track is looked over on every computer, and `mirror.heal` brings back an item recorded gone
with its track whose newest change isn't a deletion.

**5. A refused edit was put back on the old tempo map.** Same root as 7. `W.put_back` applies the band's last version; `mirror.apply` now
puts any version on the map in place (commit 2).

**6. A deleted claimed track came back in another place; the order never agreed.** Three causes. (a) Every track change carries the place
its track had on its sender's computer, and `mirror.receive` moved the track there whatever the change was: fixed in two steps, commit 5
(not when the place is the one the held version names) and commit 19 (only when someone moved it on purpose: `mirror.says_move` over
`mirror.moved_since`). (b) The studio's order list wasn't written for a move of an auto-claimed track, was written for a move that was
then held and put back, and a move made just after a bandmate's track landed wasn't seen as a move at all (commits 11, 19:
`w.order_out`, `mirror.order_after_band`). (c) `mirror.wanted_order` placed tracks newer than the list by id, the reverse of how they
land (commit 11). The order heal itself never ran in the soak (commit 4: a soak artifact).

**7. An edit made just before a bandmate's map arrived landed on the old timing.** Root cause: an item's text is in seconds, and only a
change made within 15 s of this computer's own tempo change said which map it was on (`tl`). Fix (commit 2): every item and automation
change carries the map it was made under (`tm`: `band.capture_tempo`'s list, up to `mirror.MAP_MAX` = 64 points; `tb`: the timebase).
`mirror.apply` puts a version on the same beats under the map in place (`mirror.on_map` over `mirror.retime` / `retime_env`), so receive,
put-back, heal, Undo and Restore all do; versions made under different maps are merged on the winner's map (`event_file`), with
`mirror.snap_to` so a place worked out two ways isn't read as changed. A version from before carries no map and lands as before.
`sync.map_waits` is unchanged (a change still waits for a map it's ahead of).

**8. Choices followed Lua's table order.** Two runs of one seed wrote different things from the first Undo on. `mirror.revert` sorted its
plan by kind only, so one act's changes went out in the plan table's order (another every run: each object got another id and clock tick);
`mirror.heal` walked the room's newest changes with `pairs`, so an item came before its track and waited five minutes for the next heal, and
a track before the one it sits under went to the top. Both now have one order (commit 14). Checked with `detcheck.py` (two runs of a seed in
two sets of Lua states, comparing everything each computer wrote): seeds 1-17 at 60 edits and 3000-3003 at 120 are identical run to run;
seeds 9 and 30 differed before. The other `pairs` loops in `lib/mirror.lua` (91), `lib/sync.lua` (16), `lib/undo.lua` (1) and
`lib/claimask.lua` (9) were read: they build sets or maps, take a maximum with a tie rule (`driver_at`, `read_order`, claims), work per key
with no cross-talk (`move_pairs` per group, `merge_midi` per lane, `merge_track` per setting), or sort before use (`W.gone`, `first_diff`,
`whose`). `merge_track`'s list of what both changed is in table order (words only).

**9. Redo after a no-op Undo redid an older Undo; a bandmate's Redo counted as "added since".** Fixes (commits 9, 13, 21): an Undo that
took nothing back leaves nothing to redo (ExtState `undo nothing <proj>`); a Redo takes away what your own Undo brought back; Undo and
Redo of a change built on a merge go back to that merge, not to one of its two sides; the timeline change "before" one is by the
timeline's own order, not History's rows; an Undo doesn't bring back what a bandmate deleted since.

**rt-fix6a's "left": a fresh REAPER's lane names.** Commit 22: a track whose lanes alone differ from the band's version, on a look with no
edit of the person's behind it and after the project's first look, is REAPER's reading: not sent, said once. See "Limits".

## What the soak found once those were fixed

- **An edit beaten by a deletion came back when the deletion was undone, on some computers** (commit 12, `mirror.beaten_by`): the old
  shortcut in `mirror.gone_race` ("walk each side's ancestry for gones if restore races ever show up"). They show up with every Undo of a
  share.
- **A merge with the same id and different contents** (commit 24): built from the wrong base while an ancestor was still on its way, and
  kept in memory for good. Nothing compares contents, so nothing would ever have put it right.
- **What a look couldn't send stayed** (commit 7): refused plug-ins or automation on a track that had none ("it stays on this computer"), an
  item recorded gone and left in the project, a put-back of a deletion ("the studio's version hasn't arrived"). Each asked the claimer
  again every 90 s for as long as the session ran.
- **An item moved onto a track deleted that moment** stayed on every computer but the mover's (commit 25).
- **Undo of a change built on a merge** went back to one of the merge's two sides (commit 26): "the version before" is the one the change
  names as its base, walked down past the act's own changes.
- **The late joiner's track order** (commits 28, 30): the studio's order is the newest whole list anyone wrote, and only movers wrote one,
  so of two moves made at once the later list hadn't the other's move. Each computer now writes its list when a bandmate's fresh move
  lands (made in the last `sync.CUE_OLD` = 120 s, on a project past its first catch-up: a computer replaying old moves writes none).

At 150 edits (the long run's length) four more, each on one computer alone and with no line in the log:

- **A plug-in chain changed back to exactly what an earlier version was never went out** (commit 29): `mirror.fx_readback` (what the
  band's chain reads back as here, so a plug-in's own re-encoding isn't sent) outlived the version it was for.
- **Deleting an item was never sent while a grey stand-in carried its id** (commit 32): a copy of a stand-in (a track or a stretch
  duplicated while the audio was arriving) keeps the id and the "arriving" mark for good, and `W.gone` took it for the item still here.
- **An item's return waited for good behind a deletion nobody was left to answer** (commit 33): a deletion held for a claimer's answer
  leaves its "not sent yet" flag on; when the claimer deleted the whole track meanwhile, the item was recorded gone with the flag still
  set, and only a look at an object still recorded takes it off.
- **An item that went with its deleted track came back on one computer** (commit 35): where its versions arrived newest first (Syncthing
  brings files in any order, a version waits for its audio), nothing was recorded for the newer one, or it was recorded without the order
  that settles equal revisions, and the older version then landed as the newest.
- **"Receiving 2" for good, and never the studio's track order** (commit 42): a merge whose winner had been moved onto a track deleted
  that moment was tried every pass ("its track hasn't arrived"), and `mirror.keep_order` waits for nothing to be pending. An edit a
  deletion had beaten was also merged into a newer version where that version had gone with its track.
- **A new plug-in chain never landed on one computer** (commit 44, a correction to commit 16's knob check): the knobs noted when the
  old chain landed were still there after the chain had gone with its track; with the track back and bare they read as "a knob turned
  since", and no look settles a chain recorded gone. The check now needs a plug-in to be here.
- **Heal undid a deletion on one computer** (commit 45): the deletion had come over the link and its file wasn't in the folder yet when
  `mirror.heal` ran, so heal settled on a bandmate's edit made without seeing it (newer by the clock, beaten by the deletion) and put the
  item back. Heal now leaves a held version it couldn't read when the settled one doesn't build on it.
- **Two items alike** (commit 46): an item made anew by a put-back or a restore has another REAPER GUID than the one noted for its id;
  copied before the next look, the copy took the id and the band's item went out as new. `mirror.apply` now notes the GUID as it places
  the item.
- **Plug-ins back on one computer after an Undo of their track's deletion** (commit 48): a returning track brings its parts back as this
  computer's record names them, and a part's newer version that arrived while the track was away wasn't recorded. As commit 35, for
  plug-ins, automation and sends.

And three in Undo, found by the soak's undo probe (Undo then Redo on each computer must bring the song back):

- **Undo of a marker change after a bandmate's tempo change** (commit 36): markers were compared by their seconds, which are under each
  version's own tempo map. The renamed marker stayed, the old one came back beside it at its old seconds. Bug 7's cause again, for markers:
  both versions' markers are now put on the map in place first (`mirror.time_on`).
- **Undo of a timeline change took back what its maker had never seen** (commit 37): "the version before" was the newest timeline change
  below it by order; of two made a moment apart the later wasn't made on the earlier. A timeline change now names the one it was made
  on (`built_on`), as an object change names its `base_ev`.
- **A track brought back by Undo or Redo returned at the top** (commit 41): it went under the track its last version names, the place of
  the day that version was made. A track's deletion now names where it sat (`was_after`).
- **Undo of a rename put a second marker beside one a bandmate had renamed since** (commit 43): markers are told apart by kind, place and
  name, so the bandmate's marker wasn't recognised as the same one. What an Undo brings back is now held off where a marker with its
  number is still here in another shape.

## Soak artifacts fixed (tools/soak, own commits 1, 4, 10, 20, 27, 31, 34, 47)

1. The link was never started in a soak computer, so a version only in the link's inbox was "not readable" (`direct.started`).
2. The stand-in REAPER moved an item's place and length for a tempo change; `mirror.retime` also stretches fades, snap offset and an
   audio take's rate, as REAPER does in beats (position, length, rate). The soak's REAPER now moves as `mirror.retime` does. This makes the
   two agree by construction: whether `mirror.retime` agrees with REAPER is REAPER check 1.
3. The late joiner stopped at its first quiet pass (refused changes wait a minute).
4. The soak ran Live sync's heal without its note of who's apart, so no computer ever put its track order right; and the oracle ran after
   90 s of quiet, before `mirror.ORDER_WAIT` (120 s) let the order heal act.
5. `1.000000000` against `1` counted as a difference (a rate that went to another map and back).
6. Two writes of one file in one 0.1 s step shared a Syncthing version, so the older could land last.
7. The driver dragged studio items onto a computer's own "(yours, not sent)" tracks, which is out of the studio by design.
8. After the rebase onto rt-fix7 (47dc516) no soak computer could write a file: `band.write_atomic` now reads a written file's size from
   its handle (`seek("end")`), which the soak's in-memory disk answered with 0 ("is the disk full?"). And on Windows the write now always
   moves the old file aside first, which the soak's Syncthing passed on as a deletion and a new file with separate delays (a bandmate's
   claims or order list gone for seconds, which Syncthing's watcher never shows): one drain now sends one change of a path.
9. The late joiner has nobody beside it, so `mirror.order_heal` (which acts once after opening, then only when a caught-up bandmate has
   had another order for 30 s) never ran for tracks that landed after its first heal (a refused change lands a minute later). Once
   everything has landed it runs the heal's own act (`mirror.keep_order`).
10. The driver set a second tempo marker at a time that already had one; the stand-in kept both, in whatever order `table.sort` left two
   of one time, so two computers read one map as two tempos from there on. It now changes the marker that is there. This assumes REAPER
   keeps one tempo marker to a place (REAPER check 9).
11. The undo probe (Undo then Redo on each computer must bring the song back) also compared where the Redo's own words said "1 not yours
   to change, left as they are": a claim someone made on purpose since the change stands in front of its Redo, as of any new change, so
   the song differs by design. It now skips the comparison there, as it does for "nothing to undo"; the three computers must still agree
   after each press.

## The three sync-core findings of the fourth REAPER re-check (rt-r3, docs/rt/rt-fix6a.md)

- **7. P1-8's second part (the laptop's second move of the same note wasn't asked): fixed, commit 38.** `mirror.clashes` collects what the
  claimer changed lately by each piece's key, and a note's key is its channel, pitch and tick. After the laptop's own transposition was
  the newest version, the note James had moved went by another key and its start no longer counted as his work. The keys are now carried
  forward through each version between the claimer's and the newest (`mirror.note_changes` pairs a note with what it was). A second move
  asks; another transposition, or another note, still doesn't.
- **8. An edit past an off-link auto-claim reached the on-link computers after 60-120 s: fixed, commit 39.** rt-fix6a lets the edit go
  out (an auto-claim doesn't hold when its claimer can't be asked), but only the sender knew; each receiver held it back for the
  auto-claim, the minute a refused change waits. The change now says so (`unasked`), and `sync.receive` lands it as it went out. Only an
  auto-claim gives way; a claim made on purpose still refuses. LinuxBox's 120 s was the same minute plus Syncthing.
- **9. Deleting a track you'd just made and auto-claimed: fixed, commit 40, with one case left.** (a) The deleter's auto-claim on the track
  is let go with the deletion (the look tells Claims of a track deletion it sent), so it's gone from Who controls at once, and an ask
  about it that crossed with the deletion is answered Release with no prompt. (b) Where the deletion lands on a computer holding an edit
  of the band's item for the deleter's answer, nothing is left to answer: the edit goes with the track, as it does when it had already
  gone out (rt-fix6a's rule), not to "(yours, not sent)". An item of your own making is still kept. **Left:** a track deleted by
  StudioSync's Undo (not in REAPER) keeps its auto-claim until it idles out (10 min), as before; and a hand claim on a deleted track
  stays for `sync.GONE_WAIT` (10 min), by the earlier decision (a whole-song Back takes a track away for a while).

## The four sync-core bugs of the third REAPER re-check (rt-r2, docs/rt/rt-p1.md)

- **E. Plug-in race (P1-4, P1-1's first try): fixed, commits 16 and 23.** A knob written by a script, a control surface or automation moves
  neither REAPER's change count nor its undo list, so Live sync's "a look first" gate didn't hold a bandmate's chain back: it replaced the
  local chain and the edit was gone everywhere with no line. `mirror.receive` now compares the chain's knobs as it last landed or went out
  (`mirror.fx_last`) with the knobs now; moved, theirs waits for a look (it sends yours, and the two merge by plug-in; or it finds nothing
  changed and takes the knobs as they are). **P1-1's 61 s:** the laptop's change was refused on the desktop by the desktop's own auto-claim
  made in the same second; commit 15 (a claim of the change's own second doesn't count) lands it at once.
- **P1-5 (a change to another plug-in still asks): no code change, commit 18 pins it.** `mirror.clashes` does judge by plug-in: a change to
  another plug-in than the claimer changed merges with no ask. It asked in rt-r2 because the desktop had *added* both plug-ins minutes
  before, inside the auto-claim's ten minutes, which makes each plug-in its recent work. Re-run P1-5 with the chain added by a third
  computer, or more than `sync.AUTO_IDLE` (10 min) before. If James wants "added it a while ago, hasn't touched it since" not to count, the
  change is one line in `mirror.clashes` (count a piece only when the claimer's change to it has a base, i.e. isn't its creation); say so.
- **C. Ctrl+Z after a track delete (P1-6): fixed, commit 17.** REAPER brings the track back as its undo point had it, without StudioSync's
  id; the look gave the id back and took that for a file opened without its last save, so the track was deleted again and each of its parts
  threw through the dead track. Now only a project's first look keeps those marks; later, what comes back is the person's change (sent, built
  on the deletion). The dead-track errors are also guarded where a look does take a track away.
- **D. A given claim's link copy isn't taken until Syncthing's file arrives (P1-14): not changed, left.** This is by the current design, not
  a convergence bug: `sync.follow_claims` deliberately leaves a link copy alone (`sync.GIVEN_WAITS`, rt-linkmove hook 1: folding it wrote
  the fold on every pass) while `sync.authority` already counts it, so the track *is* the person's to edit at once; what's missing is the
  log line "X gave you Y" at link time and a chip to release it from. It belongs to the claims UI (`lib/signed.lua`, the panel and web
  chips, `set_claims`' `let_go`): say the line when the link copy is first counted, and let the release pass the key through `let_go`
  (which already exists for exactly this). Not attempted here: it needs the panel and web files and a REAPER check with Syncthing paused.

## Limits, and what's left

**What the last long runs still fail, each categorised.** Seeds at 150 edits unless said.

- **5028: a bug left, with its cause. A knob turned in the moment the project's first track goes is never sent.** The look takes "the first
  track's pointer is gone" for a file opened again in the same tab and makes a first look (W.order), which notes every chain's knobs
  afresh as "how it loaded" (`mirror.fx_load_knobs`). A knob turned since the last look is then inside that note, so for the next minute
  the chain's difference from the band's reads as the plug-in's own loading (`mirror.fx_readback`): never sent, on that computer alone,
  no line. One line fixes the seed with every test passing (keep a chain's note when it already has one), but a file really reopened in
  the same tab would then keep its notes from before, and those loading rules were tuned on real plug-ins (TONEX, Pro-L 2, Superior
  Drummer): not shipped without REAPER check 12. It only showed once row 46 changed which item kept an id in this seed.
- **5057, 9029, 9058: one class of bug left, not traced to the line. An Undo's or Redo's restore made at the same time as a bandmate's
  edit of the same thing ends as different merges.** In each, two computers hold the merge of the restore with the bandmate's version and
  the third holds one side alone (5057: Cee holds James's restore unmerged; 9058: Cee is three versions behind with nothing pending;
  9029: Bee merged two old versions of an automation lane into a restore that James holds unmerged, and holds another merge of an item).
  Likely causes, from the records: `mirror.merge_for` waits two minutes for a version between and then decides by revision and clock
  (the third computer got the pieces in another order), and for automation the "a deletion beats an edit made without seeing it" rule
  (`RACES`) covers items only. Three seeds of about 180; each needs an Undo within a second or two of a bandmate's edit of the same item.
  Recommendations 1, 6 and 9 are this.
- **9034: a bug left, the rest of bug 6. A late joiner places tracks made after the newest order list by rule; the three placed them as
  they landed.** Two tracks made in the last seconds of the run sit in the other order on the computer that joins later. It heals when
  anyone next moves a track (a new list). Recommendation 3 (a rank per track) ends the class.
- **127 at 40 edits: an accepted design limit.** A Redo of a rename is answered by the bandmate whose claim is on the track's old name:
  claims go by name, and after the Undo the track has that name again. By design today; claims by track id would end it.
- **7017 and the like: an accepted design limit, and the soak now knows it (artifact 11).** A claim made on purpose since a change stands in
  front of its Redo.
- **6006: an accepted design limit, as 127.** James's Redo of a rename is answered by Cee, whose edit of the track in the same moment
  had auto-claimed it under its old name.

**Other limits of what was built.**

- **A copy of a grey stand-in stays grey** until the real item is deleted (row 32 takes it away then). Delete it by hand; it's never sent.
- **A track deleted by StudioSync's Undo keeps its auto-claim** until it idles out (row 40 lets it go only for a deletion made in REAPER).
- **Per-commit checks.** `python tests/run.py --no-luals` ended `fails 0` in a clean checkout, in local time and with `TZ=UTC0`, at rows
  42 and 48. Rows 1-24 were each checked the same way on the base before the last rebase: every one `fails 0` except, on some,
  `test_0_60_rt_drivebg.lua` and `test_0_60_rt_bigproj.lua`, which time REAPER's thread against the wall clock (20 ms, 600 ms) and failed
  only while the soak ran beside them; both pass alone and in the two full runs above. Rows 25-41 and 43-47 were not run one by one
  on the final base (each was run with its own test and the full Lua suite as it was written).

- **`mirror.retime` is the truth for cross-map placement, and it isn't checked against REAPER** (fades, snap offset, rate; a gradual tempo
  change isn't converted; an item's timebase -1 goes by the project's). It only acts where a version meets another map than its own,
  which before landed at the wrong seconds for good; where the maps are the same nothing changed.
- **A tempo map of more than 64 points isn't carried** (`mirror.MAP_MAX`): those songs behave as before this package.
- **Versions from before this package carry no map**: a merge or a late landing across a tempo change that involves one is as before.
- **Lanes:** the read-back rule needs Live sync's edit time and isn't applied on a project's first look (changes made with Live sync off
  must still go out), so LinuxBox2's case is only covered if its REAPER re-read the lanes after the first look, as the 21 s suggests.
  REAPER check 6.
- **A stuck Undo:** an Undo that takes nothing back (not yours to change any more) still lands on the same change at the next press; the
  Redo no longer misfires, but Undo doesn't step past it (the timeline's Undo does, with `undo passed`). Small, not done.
- **Timing judgements by whole seconds across two clocks** (claims against changes) remain a guess inside a second or two of each other.
- **The order heal still waits** `ORDER_WAIT` + `APART_SECS` and only acts when a caught-up bandmate differs; three computers that agree on
  an order the list doesn't say stay on it until someone joins. After commits 11 and 19 the soak no longer produces that, but nothing
  enforces it (Recommendation 3).

## REAPER checks (nothing above was run in REAPER)

1. **Cross-map landing against REAPER's own move.** Desktop and laptop on Cross Test, project timebase beats (position, length, rate). Pause
   the laptop's link and Syncthing; on the desktop set the first tempo from 120 to 100; on the laptop move an audio item with fades and a
   snap offset, and a MIDI item; resume. Pass: both items sit at the same place, length, fades and rate on both computers (to the
   millisecond), and the desktop's copy (moved by StudioSync) matches what REAPER itself did to an untouched neighbour. If fades or the snap
   offset differ from REAPER's own, that's `mirror.retime` (one line each).
2. **Bug 1 again.** Claims mode; the desktop sets a tempo marker; within 10 s the laptop moves an item on a track the desktop holds. Pass:
   the laptop asks (or the move goes out and merges), never a silent local move.
3. **Bug 5 again.** The laptop edits a note in the desktop's claimed part and at once the desktop changes the tempo; Keep (or no answer).
   Pass: the put-back part has the length every other computer has.
4. **Rename war.** The desktop renames a track in the same second the laptop moves its fader (timed, as rt-r2 did). Pass: one name on all
   computers within a few seconds, at most one "renamed ..., which you've claimed" line, and the Activity log stops.
5. **P1-4 and P1-1 again** (plug-in race) and **P1-6's Ctrl+Z** (the track returns everywhere with its items and plug-ins; no "opened
   without its last save", no "mirror sync skipped").
6. **LinuxBox2's lanes:** open Cross Test on LinuxBox2 and touch nothing for two minutes: XT Rec A's lane names stay the band's on every
   computer; LinuxBox2's log may say "its lanes read differently here ...". Then rename a lane there by hand: it goes out.
7. **A late joiner:** with three computers editing (tracks added, moved, deleted and undone), open the song on a fourth after ten minutes.
   Pass: Health green on all four within three minutes, the track order the same, no order heal line on the three that were there.
8. **Undo:** delete a bandmate's item, Undo, Redo (gone again); edit an item a bandmate then deletes, Undo ("deleted by a bandmate since,
   left deleted"); Undo of your marker made a second after a bandmate's Restore, then Redo (the marker is back). Rename a marker, have a
   bandmate change the first tempo, then Undo: the old name is on the marker where it sits now, no second marker. Add a track at the top,
   have a bandmate add one above it, Undo then Redo: yours is second again on every computer.
9. **One tempo marker to a place** (the soak assumes it, artifact 10): insert a tempo marker, then run "Insert tempo marker" at exactly
   the same position with another tempo. Pass: one marker there, with the second tempo. If REAPER keeps two, say so: the stand-in's
   order of two markers at one time then needs pinning instead.
10. **A copied stand-in:** pause the laptop's Syncthing for media (or use a long take), record on the desktop, and on the laptop duplicate
   the track while the take still shows grey "arriving"; when the audio lands, delete the real take on the laptop. Pass: it goes on
   every computer, and the grey copy goes with it.
11. **rt-r3 again:** P1-8's second part (the laptop's second move of the note the desktop moved: asked); the desktop's edit of a track
   LinuxBox2 auto-claimed off the link (the laptop and LinuxBox have it within seconds of "your edit went out"); the desktop deletes a
   track it just made while LinuxBox, offline, moves its item (no "(yours, not sent)" track on LinuxBox, no Release/Keep on the desktop,
   the track gone from Who controls at once).
12. **For seed 5028's fix (not shipped):** with the one-line change in W.order (keep `mirror.fx_load_knobs` for a chain that has one), open
   a song with TONEX or Superior Drummer on the laptop, close the project and open it again in the same tab with Live sync running: no
   "edits not sent" for those chains, nothing goes out. Then turn a knob from a control surface and delete track 1 within the same
   second: the knob reaches the others. If both pass, the change can ship.

## Recommendations (ranked by what they would fix)

These are for James and the coordinator to decide; none is built here.

**1. One judge of what an object is: `settled(events)`, used by every path.** Evidence: at least four places decide which version an object
has: `sync.receive`'s catch-up (`latest`, `apart`, "superseded", ~120 lines), `mirror.receive` (`wins`, `merge_for`, `gone_race`, now
`beaten_by`), `mirror.heal` (`mirror.settled`), and `W.one`. Bugs 3 and 4, the restore races, the wrong-base merge and every "late joiner"
failure were two of them disagreeing; I fixed each by teaching one path what another knew. `mirror.settled(room_dir, newest, all)` already
is the right definition (pure over an object's events). Plan: (a) keep an index oid -> its events, fed as files are listed (the listing is
cached already; `room_newest` re-reads the room per heal, "up to a second or more"); (b) `receive(ev)` becomes "recompute settled(oid); if
it isn't what's held, apply it"; (c) the catch-up's newest-only shortcut falls out (settled is applied once per object); (d) delete
`wins`/`merge_for`/`gone_race`/`beaten_by` call sites outside `settled`. Then arrival order can't matter by construction, and the soak's
late-joiner oracle holds trivially. Risk: the unsent-edit protection and "waits" (media not here, tab behind) stay per object, as now.
Of this package's 38 code fixes, 11 are one path being taught what another already knew (commits 8, 12, 24, 25, 33, 35, 42, 45 and
parts of 5, 19, 28): the single biggest source of bugs here, and the one a redesign removes rather than patches.

**2. Times in beats on the wire.** Evidence: bugs 1, 5, 7, half the first sweep's failures, and this package's biggest change. `tm` (the
map on every change) works, but it re-implements REAPER's tempo math in `mirror.retime` (unverified for fades and rate, no gradual
tempos), costs ~70 bytes a tempo point on every item change, and leaves in place: the tempo-maker re-sending every item it may change
(N events and N merges per tempo change), `map_landing`'s two full project reads per landed map, the 15 s window, `map_waits`,
`tempo_only`, `only_retimed`. Plan: carry an item's place and length (and each automation point) in quarter notes beside the seconds;
receivers place by `TimeMap2_QNToTime` on their own map (REAPER's math, ramps included); a tempo change then sends one timeline event and
nothing else, and the window heuristics go. Two releases: write both, then read beats.

**3. Track order as its own small object.** Evidence: bug 6, commits 5, 11, 19, and `order_seen` / `order_band` / `moved_set` /
`moved_from` / `moved_since` / `wanted_order` / `keep_order` / `order_heal` / `apart_note` with three timers. All of it exists because a
track's place rides inside every track change as "the track above me on my computer". Plan: give each track a rank (a fractional-index
string, changed only by a move, newest wins per track); the order is `sort by (rank, id)`. No order lists, no order heal, nothing to
publish, a late joiner sorts. Migration: ranks from the studio's current list, once.

**4. Don't refuse on receive.** Evidence: bug 2, bug 3, the 61 s of rt-linkmove round 5 C and of rt-r2 P1-1/P1-2, `gone_before_claim`,
`soft_ok`, `set_back`, `deferred`, `refused_since`. A refused change "waits a minute, then lands like any other" (the code's words; the
security notes agree it's no boundary), so receive-side refusal is a delay that makes computers differ for a minute and has needed five
special cases. The sender's look already asks or refuses. Plan: keep the rename answer (`set_back`) and the too-old-sender case; land
everything else at once. If claims must bind against a modified client, that's a signature question for the security pass, not a timer.

**5. The soak in CI, with scenarios and a determinism check.** `python tools/soak/soak.py --quick` can go into `tests/run.py` as fatal once
this lands (it passes); `--long` nightly. Add: a two-run determinism check (found bug 8's cause in minutes: `detcheck.py` in my scratch
folder, 40 lines), a way to script a scenario (fix6a and rt-r2 each wanted one), someone leaving and joining mid-run, asks that are
answered, and a REAPER-backed run to validate the stand-in (the two soak artifacts that mattered most were the stand-in's).

**6. Timers into facts.** 15 s (tempo), 60 s (refused), 120 s (merge wait), 30 s (ask), 120 + 30 s (order heal), 60 s + 300 s (heal), 30 s
(`SESSION_SECS`, `EDIT_SECS`), 60 s (`FX_LOAD_SECS`). Each is a place where two computers decide differently because one was slower.
Where the question is "has X arrived?", ask for X (the need list exists) instead of waiting; where it's "is this the same edit?", use
ancestry (`base_ev`), which every version already carries.

**7. Health can't see different contents under the same ids.** `mirror.root` hashes which events a computer holds, not what the objects
are. Bug 1 (kept locally, silently) and the wrong-base merge were both invisible to it, and so to heal. Plan: a second code in the status
over each object's settled id plus its band hash (the alias hashes mirror already keeps for read-backs), compared the same way; heal then
targets what differs.

**8. `lib/mirror.lua`'s shape (7,400 lines).** Evidence: every `W.*` function opens with the same 4 lines unpacking ~30 fields of `w`
(12 copies); about 40 module tables are keyed `tostring(proj) .. oid` (`unsent`, `held_back`, `reopened`, `sessions`, `fx_*` x 14, ...),
most never pruned, and "what does this computer know about this object" is 40 lookups in 40 places (the knob bug in commit 16 was reading
the wrong one of them; commits 29, 33, 44 and 46 are each a flag or a note that outlived the thing it was about: `fx_readback`, `unsent`,
`fx_last`, the GUID note). Plan: one record per project and object (`P[proj][oid]`), dropped with the project; split the pure merge code
(`merge_item/midi/env/track/fx`, `pieces`, `clashes`: ~900 lines, no REAPER) into its own file with property tests (merging in any order
gives one result; merging with yourself changes nothing), which would have caught the order-dependence class without a soak.

**9. Undo from ancestry, not from History's rows.** `plan_undo` finds "the version before" by time and rank among rows sorted by each
computer's clock; commits 9, 13 and 26 patched three cases (a merge has no row; rows of one second sort by name; a change built on a
merge), and commits 36, 37 and 41 three more of the same kind for the timeline and for a track's place (`built_on`, `was_after`, markers
on the map in place). Every change names what it was built on (`base_ev`, and now `built_on`); "before" is that, always. The timeline
itself (one whole document, newest wins, so a marker added a second before a bandmate's is lost) would be better as one object per marker
with the same merge rules as everything else; its Undo would then need no code of its own.

**10. The event log as one file per change.** It works and much care went into listing it cheaply (`band.listing`, `settled_for`,
`ev_cache`, APPLIED marks per id in the project file, `forget_trimmed`). A per-writer append-only log with a high-water mark per reader
would shrink Syncthing's work (thousands of tiny files), make "what am I missing" an offset, and drop the per-id marks. A real redesign;
lowest, because nothing here was caused by it.

## Review-later (security)

- `tm` on a change is a bandmate's data: `mirror.map_ok` accepts only a list of up to 64 points with a numeric time (0 to 1e9) and tempo
  (above 0, below 1e6); anything else and the change lands as it is. A forged map can only place that sender's own change oddly.
- Judging by the change's own time (`ev.time`, its sender's word): a sender with a clock set back gets its change past a claim made since,
  at once instead of after the minute it would land anyway. No new power; noted for the pass that decides whether claims should bind.
- `sync.track_claims` (who holds which track name since when) is read from the same claims files `sync.authority` already trusts.
- The unseen-knob check reads this computer's own plug-ins; `mirror.fx_last` is memory only.
- Three more words on a change are a bandmate's data. `built_on` (a timeline change): a string, used only to pick one of the timeline
  changes already read. `was_after` (a track's deletion): an id string under 200 characters, used only to look up a track here; a forged
  one puts that sender's own returning track somewhere else. `unasked` (true): lands a change past someone's **auto**-claim at once
  instead of after the minute it would land anyway; a claim made on purpose doesn't give way to it. No new power, noted for the pass that
  decides whether claims should bind (Recommendation 4).

## REAPER re-check results (rt-r4, 2026-11-22 12:18-13:32 UTC, StudioSync 0.59.49.96 from 904bffe + extension 1.0.37, Deafen 1, no sound tests)

Desktop (d), laptop (l), LinuxBox (x); LinuxBox2 (x2) resumed 13:24-13:32 for checks 6, 7 and 11, then suspended again. The Mac was offline.
Edits by script through each REAPER's dev eval hook, in undo blocks as REAPER's own actions name them; paired edits at one moment on the shared
link clock (`direct.shared_now`, each pair ran 3-60 ms apart). Claims mode ("open") unless said. Where a check pauses "the laptop's" link and
Syncthing, LinuxBox stood in (Live sync stopped and its Syncthing paused through its REST API): the desktop's and laptop's Syncthing were not
touched. Cross Test was put back after each check and compared on all computers (`cmp.lua`: tracks, items, notes, envelopes, markers, tempo):
equal to the starting state each time, the laptop included up to the soak. Probes: `<scratchpad>/rt-r4/` (`tm.sh` + `c/*.lua`, `cmp3.sh`,
`soak_body.lua`).

**The laptop's REAPER is blocked since 13:13:10 UTC (left that way, see the soak).** A modal StudioSync box, "Undo: changed an item on XT
Keys C at 7.38 s? It goes to everyone. James changed it after that ...", Yes/No, opened by the soak driver's StudioSync Undo (`undo.step`
asks with `reaper.MB` when a bandmate changed the same thing since). Its Live sync and dev hook are stopped behind it. Answer **No** there (it
undoes nothing); its project then catches up. The laptop may still hold the soak's first edit of its own unsent (one op before the box):
compare the three after it's answered and put back if anything differs.

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Cross-map landing against REAPER's own move | **pass** | Project timebase 1 (beats: position, length, rate). XT Rec A's lane-0 take given fades 0.5/0.7 s and snap offset 0.3, synced. LinuxBox offline; the desktop set the first tempo 130 -> 100 (REAPER moved its items: that take to 4.799979, fades 0.65/0.91, snap 0.39, rate 0.769231); LinuxBox, still on 130, moved that take and XT Keys C's item one beat (to 4.153830 and 7.846154); back online 12:21:41. All three, to the microsecond: take pos 5.399979 len 7.099733 fades 0.650/0.910 snap 0.390 rate 0.769231, XT Keys C 10.200000 len 4.799600 (= 4.153830 x 1.3, 7.846154 x 1.3). The desktop's copy was placed by `mirror.retime` ("LinuxBox changed an item on XT Rec A as you did, at the same time: both changes are kept"), LinuxBox's by REAPER: fades, snap offset and rate agree with REAPER's own. |
| 2 | Bug 1 again | **pass** | Desktop hand-claimed XT Drums A, set 130 -> 120 bpm; 12 s later (the tempo had landed) the laptop moved the item +0.5 s: "asked James to release XT Drums A ..." -> 30 s -> "Not sent ... put back"; all three 2.166667. No silent local move. |
| 3 | Bug 5 again | **pass** | Desktop hand-claimed XT Keys C. The laptop lengthened the note (0-960 -> 0-1440) and the desktop set 130 -> 100 bpm 0.33 s later (12:31:14). The laptop asked, no answer, "Not sent ... put back" at 06:31:43 CT; all three `pos=9.6 len=4.799600 notes 48@0-960` (the length on the new map). Also run with the tempo 12 s before the edit: the same. |
| 4 | Rename war | **no war; the rename is lost (bug A)** | The desktop renamed XT Drums R4 -> R5 and the laptop set that track's fader 0.5 at the same moment (12:35:15.020 / .017). One name everywhere within a second, no "which you've claimed" line, the log stops. But the name on all three, **the desktop included, is the old "XT Drums R4"**, with the laptop's 0.5: the desktop's rename never went out ("James-Laptop: changed a track on XT Drums R4", then nothing) and its log says nothing about its own edit. Again with R4 -> R6 / 0.7 at 12:37:30: the same. A rename alone goes out at once (12:33:33). |
| 5 | P1-4, P1-1, P1-6's Ctrl+Z | **pass** | See P1-1, P1-4, P1-6 below. |
| 6 | LinuxBox2's lanes | **pass** | LinuxBox2 took 0.59.49.96 by Syncthing within 30 s of resuming; its REAPER restarted (13:27:09), Cross Test opened, Live sync on .96. Untouched until 13:29:50: no change went out from it, XT Rec A's lane names `1..8` on d, x, x2. Lane 0 renamed "1 r4" there by hand (13:30:14): "claimed XT Rec A ... 1 change(s) went", on d and x within 12 s. |
| 7 | A late joiner | **partial pass** | LinuxBox2 (suspended since 11-21 21:58) joined after the soak and its put-back: "caught up on 14 changes ..." and 57 changes landed; equal to the desktop and LinuxBox within 3 minutes, track order included; no order heal line on d or x. Health not read; the laptop was blocked, so "all four" wasn't possible. |
| 8 | Undo | **pass, 4 of 5 parts** | (a) the desktop deleted the laptop's new item, Undo (REAPER's), Redo: back on all three, then gone on all three. (b) The desktop moved the laptop's item, the laptop deleted it, the desktop's Undo: "0 change(s) brought back ... (1 deleted by a bandmate since, left deleted)". (d) Marker "R4 mark" renamed, the laptop set 130 -> 100, the desktop's Undo: "R4 mark" at 7.8 s (where it sits now) on all three, one marker, 100 bpm kept; the log's words "now 130 bpm" are wrong (the tempo stayed 100). (e) "R4 Mine" added at the top, the laptop added "R4 Theirs" above it, Undo then Redo: Theirs, Mine, ... on all three. (c) Undo of a marker made a second after a bandmate's Restore: **not run** (Restore needs the panel's History page; no scripted Restore). |
| 9 | One tempo marker to a place | **one marker, but the first tempo** | `AddTempoTimeSigMarker` at 10 s with 120, then at 10 s with 110: one marker at 10 s, **120** (both calls returned true). So REAPER keeps one marker to a place, but a second insert there is ignored rather than changing it; the soak's stand-in "changes the marker that is there". The UI action (it opens a dialog) wasn't tried. |
| 10 | A copied stand-in | **not run** | Needs a recorded take kept grey on one computer (Syncthing paused there) and a duplicate made meanwhile; the desktop's input is the work-call bus and no sound tests were allowed this round. |
| 11 | rt-r3 again | **pass** | P1-8's second part, the off-link auto-claim and bug 9: below. |
| 12 | Seed 5028 | **shipped build: not reproduced; the patch: not run** | The laptop turned XT Drums A's ReaComp ratio to 0.5 with no undo point (as a control surface) and deleted the project's first track (XT Keys C) in the same script call (13:02:37): "3 change(s) went to the others", the knob 0.500 on all three. The one-line W.order change was not tried: `_tools/studiosync` is in the synced studio folder, so patching it on the laptop would reach every computer. (REAPER's own Undo of that deletion also put the knob back to 0.400, on all three alike: REAPER's undo state, not StudioSync.) |

**The P1 re-runs (rt-p1.md) and rt-r3's three.**

| Check | Result | Evidence |
| --- | --- | --- |
| P1-1 (no 61 s, no lost laptop edit) | **pass** | ReaEQ + ReaComp added to XT Keys C by LinuxBox. Desktop EQ band 2 gain 0.7, laptop ReaComp ratio 0.2, at shared ...876.0 (10 and 13 ms late): all three 0.700 / 0.200; both "... as you did, at the same time: both changes are kept"; the laptop's change on the desktop in the same second (05:51:16), not 61 s. |
| P1-4 (plug-in race, no silent loss) | **pass** | Desktop moved ReaComp to the top while the laptop set EQ gain 0.8 (both with undo points): ReaComp first with 0.800 on all three, "both changes are kept". With the knob turned raw (no undo point, rt-r2's cause) against the desktop moving ReaComp back: the laptop's chain was held for a look and its change asked ("James is editing the plug-ins on XT Keys C too: both changes go in ..." then "asked James to release" in the same second), Not sent after 30 s with the chain saved as an RfxChain: no silent loss, but the two lines contradict each other (rt-r1's pattern, here for a knob found by a later look). |
| P1-5 | **pass (chain added by a third computer); asked as designed when the claimer added it** | Desktop auto-claim on XT Keys C from its EQ edits; the laptop's ReaComp change went out with no ask; the laptop's change of EQ band 2 asked ("James-Laptop wants to edit XT Keys C") and was put back after 30 s. With ReaDelay + ReaComp added to XT Drums A by the desktop a minute before: the laptop's ReaComp change asked ("asked James to release XT Drums A"), as rt-converge row 18 expects. Released by the desktop inside the 30 s, the edit then went out. |
| P1-6 Ctrl+Z after a track delete | **pass** | XT Gtr (one MIDI item, ReaEQ) deleted on the desktop at ...367.06, renamed on the laptop at ...367.14: "James also changed something on XT Gtr at the same moment as you: theirs is in"; gone on all three for a minute. The desktop's Ctrl+Z (REAPER's Undo of "Remove tracks"): XT Gtr back at #3 with its item, note and ReaEQ on all three in under 10 s; no "opened without its last save", no "mirror sync skipped", no error line in any log. Left: the laptop kept its auto-claim on "XT Gtr renamed" (a name nothing has) until released by hand, as in rt-r2. |
| P1-8 second part | **pass** | Desktop moved XT Keys C's note a beat (48@0 -> 48@960, auto-claim), the laptop transposed it +2 0.4 s later: "both changes go in", all three `50@960-1920`. The laptop's second move of that note: "asked James to release XT Keys C" -> put back after 30 s. Another transposition then: went out with no ask (`52@960-1920` on all three). |
| fix6a off-link auto-claim timing (rt-r3 8) | **pass for LinuxBox; the laptop not run** | LinuxBox2 (no Tailscale) auto-claimed XT Rec A by renaming a lane; the desktop's lane rename at 13:30:40: "LinuxBox2 auto-claimed XT Rec A, but the direct link can't reach them to ask ...: your edit went out"; LinuxBox applied it in the same second (13:30:40), LinuxBox2 at 13:30:42. (rt-r3: 60 s and 2 min.) The laptop was blocked. |
| rt-r3 bug 9 | **pass** | The desktop made "XT R4 del" (auto-claimed), LinuxBox offline, the desktop deleted it ("let go of your claim on XT R4 del: you deleted it": Who controls empty at once), LinuxBox moved its item, then came back: its move went out, the deletion stood, no "(yours, not sent)" track, no Release/Keep on the desktop. Also "let go of your claim on R4 Mine / R4 Theirs: you deleted it" in check 8 (e). |

**Mini soak (13:13:00-13:18:14 UTC).** A driver in each REAPER (`soak_body.lua`, seeds 401/402/403): every 2-6 s one of move (the three
studio items or a scratch item), rename a studio track (`name~<who><n>`, or back), fader, tempo (110/120/130/140), add a scratch track at a
random place, delete a scratch track, add or delete a scratch MIDI item, StudioSync Undo or Redo (the Ctrl+Z script's logic). The desktop
switched the room to Open ("everyone") at half time. 71 ops on the desktop, 78 on LinuxBox, **one on the laptop**: its first StudioSync Undo
opened the modal box above at 13:13:10 and the laptop did nothing more. Then quiet. **Desktop and LinuxBox were identical at quiet + 90 s,
+ 180 s and + 270 s** (cmp.lua, the desktop's local "StudioSync live out" track aside): XT Keys C~x9 0.8, XT Drums A~x11 0.5, XT Rec A~d16
0.9 with the envelope and all 8 takes moved to 110 bpm alike, one scratch track, tempo 110, "Verse" 3.2727-21.8182. Two claim holders were
left on one track (James and LinuxBox both auto on "XT Rec A~d16"), settled by "the newer holds" as designed. No error line in either log.
The laptop's comparison is still owed (it froze 10 s in). Put back from the desktop (13:23:13: scratch tracks deleted, names, faders,
positions, tempo 130, room back to Claims): desktop = LinuxBox = LinuxBox2 = the starting state.

**Bugs found.**

- **A. A rename made at the same moment as a bandmate's change of that track is lost on the renamer's own computer, silently** (check 4, two of
  two). The laptop's fader change, built on the old name, landed over the desktop's rename before a look had sent it; the desktop's track
  went back to the old name, nothing went out and nothing was said. The P1-4 class (an incoming version applied over an edit no look has
  seen yet), for a track's settings: `sync.seen_mine` should hold the receive while REAPER's change count has moved since the last look, so
  the rename was either not seen as moving it in time or the incoming track version was applied whole instead of merged by setting.
- **B. A tempo change made after a bandmate's tempo change auto-claims XT Rec A** (three of three; never when the previous tempo change was
  this computer's own, two of two). XT Rec A is the track with automation (a volume envelope) and eight takes on fixed lanes; XT Keys C and
  XT Drums A aren't claimed. `mirror.lua` ~5455: `tempo_only` (`mirror.only_map_moved`) is false for one of XT Rec A's objects whose band
  version was made by a bandmate under another map. Round 10's "tempo changes claim nothing" holds only for the computer that made the last one.
- **C. (rig, not the product) StudioSync Undo's "a bandmate changed it since" box is modal**, so a scripted Undo blocks that REAPER until it's
  answered. A soak driver should stub `reaper.MB` in its own Lua state around `undo.step` (answer No) instead of calling it bare.
- Small: Undo of a marker rename says "now 130 bpm" though the bandmate's 100 bpm stays; the tempo-maker's own re-sent items are reported
  as "LinuxBox changed the same thing as you on an item on XT Keys C: theirs stands" on the computer that only changed the tempo (check 1);
  a renamer's auto-claim on a deleted track outlives the track's return; a raw knob found by a later look gets "both changes go in" and
  "asked ... to release" in the same second (P1-4).

**Left for the next re-check.** Answer the laptop's box and compare the three; the laptop's part of the soak (re-run with the MB stub); 8 (c)
with the panel's Restore; 10 (a copied stand-in, needs a take); 12's patched build (only in a non-synced copy); 7's Health on all four;
P1-9..P1-16 as listed in rt-p1.md.

## rt-fix9: the fixes for rt-r4's findings (2026-11-22)

Files: `lib/mirror.lua`, `lib/sync.lua`, `lib/undo.lua`, `lib/claimask.lua`, `tools/soak/node.lua`, `tools/soak/soak.py`; tests: parts 32-36
of `tests/test_0_60_rt_converge.lua` and an assert in its part 22; one line each in `tests/test_0_60_rt_converge.lua` and
`tests/test_0_60_rt_merge.lua` (`undo.confirm` in place of their `reaper.MB` stub). No shared file touched (`StudioSync - Live sync.lua`,
the panel, the web UI, `tests/fixtures/editreaper.lua`). **Nothing here was run in REAPER**: the re-checks are at the end. Each fix's test
was run against a copy of the repo with that one fix taken out: each fails there with its own assertion (A, B's two halves, 4a-4d, the
Undo ask, and the merge's own-base condition).

**A. A rename made at the same moment as a bandmate's change to that track was lost on the renamer's computer.** The bandmate's track
version, built on the old name, was applied whole over a rename no look had seen yet. Why Live sync's gate (`sync.seen_mine`) let it
through isn't proven: the desktop log shows the laptop's change landing and no look of the desktop's rename at all (`05:35:15`, `05:37:30`),
so the receive ran before any look saw the rename. The fix doesn't depend on that answer: `mirror.receive` now holds a bandmate's track
change while the track's settings here differ from what the last look read or a change put in place (`mirror.track_seen`, compared by
`mirror.track_line`, so the track's place in the list doesn't count), exactly as commit 16 holds a plug-in chain for an unseen knob. The
look then sends the rename built on the version both came from and the two merge by setting (`merge_track`): name and fader both stand.
It covers every setting a track object carries, so the other track-level attributes asked about (colour, mute, volume and pan, lanes,
phase, automation mode) have the same hold; solo is each person's own and never travelled. Items and automation were already held by
`mirror.unsent` and the gate; nothing changed there. Cost: one `track_state` read per incoming track change, one `track_line` per track
per look. A held change waits one look (`mirror.unsettled` makes Live sync look at once).

**B. A tempo change made after a bandmate's auto-claimed XT Rec A.** Of the 11 changes the desktop sent at 05:24:04 and 05:27:48 (8 takes,
the automation, XT Keys C's and XT Drums A's items) one of XT Rec A's was judged "not only the map's move" by `mirror.only_map_moved`,
which compares this computer's reading with the band's text, here LinuxBox's. The items can't be it: they read back byte for byte as
LinuxBox sent them (no "came out different" in the log). The automation, the one object only XT Rec A has, is compared by
`env_sans_tempo` text equality, and the likely cause is that LinuxBox's REAPER writes a point's line its own way and the desktop's rewrites
it in its own once its tempo change moves the points. Likely, not proven: no log names the object. Two changes, so a tempo change can't
claim either way:
- `mirror.env_same_but_times`: automation compared line by line and number by number (other digits, trailing fields that are absent read
  as 0). Used by `only_map_moved`, `map_landing` and the new check below. `env_sans_tempo` also leaves out automation items' places and
  their points' times (`BANDAI` / `BANDAIPT`), which a tempo change moves too.
- `mirror.moved_by_map` in `W.send`: an item or automation that was the band's at the last look (`L.clean`) and differs since only as the
  map moved it (that look's reading, kept in the quick look's record, retimed from that look's map, `N.map`, to this one) is the map's
  move, whatever the band's text says. It reads only this computer's own two readings, as `map_landing` does for a bandmate's map. An
  automation item's lines aren't in the look record, so automation with automation items still goes by the band's text.
A version that went out as only the map's move says so (`retimed = true`), which 4b uses.

**3. StudioSync's Undo asked with a modal `reaper.MB`.** Chosen: no box at all, the panel's existing ask bar plus "press it again".
`undo.step` notes the ask per tab (ExtState `undo ask <proj>`: the change, Undo or Redo, the words, 30 s), says it in the log and in a
tooltip by the mouse when the panel isn't showing, and returns. The same Undo (or Redo) pressed again within `undo.ASK_WAIT` = 30 s is
Yes; the panel's bar shows the ask with Yes / No (`claimask.bar`, beside the claim asks it already draws), and Yes goes to Live sync
through ExtState `undo answer <proj>`, which `claimask.tick` carries out (`undo.step` with `confirmed`). No answer is No: nothing changes
and the ask runs out. The panel's own Undo (which always asks) asks the same way. Nothing in Live sync's loop waits on it. Not done: the
web page doesn't show the Undo ask (it would need `lib/webui.lua` and `app.js`, which have other agents' uncommitted edits); a timed-out
modal wasn't needed. Tests replace the answer with `undo.confirm`; the soak presses the key a second time, and its `reaper.MB` now records
an error if anything opens a modal box.

**Small ones.**
- **(a) "now 130 bpm".** An Undo or Redo of a tempo or marker change now says what that change changed against the timeline it was made on
  (`sync.timeline_words`, sharing `undo_timeline`'s choice of "the version before"): "undo: changed the markers", "changed the tempo map
  (130 -> 100 bpm)". History's own words stay as they were.
- **(b) "theirs stands" on the computer that only changed the tempo.** Check 1's XT Keys C: the version both sides came from was made
  before versions named their map, so the tempo-maker's re-sent version (only REAPER's move) read as changing the item's timing, and the
  bandmate's move "clashed" with it. Where the map's side won the order it was worse than the words: the hand's move was lost. Now a side
  that says `retimed` and builds straight on the shared version brings nothing to the merge but the map (`mirror.event_file`: its state is
  taken as the base's), and nothing is said on its maker's computer. A side built on a change of its own made since keeps that change.
- **(c) A renamer's auto-claim outlived the track's return.** `sync.drop_gone_claims` lets an auto-claim on a track name nothing has go at
  once (a lasting claim still waits `sync.GONE_WAIT`). This also ends rt-converge's "a track deleted by StudioSync's Undo keeps its
  auto-claim until it idles out".
- **(d) One tempo marker to a place.** The soak's stand-in now does what check 9 found: an insert (`SetTempoTimeSigMarker` with index -1,
  or `AddTempoTimeSigMarker`) at a marker's time does nothing and says true; changing a marker by its index still changes it. Done in
  `tools/soak/node.lua`, not the shared `tests/fixtures/editreaper.lua`; `soak.py --selfcheck` (run by `--quick`, so by `tests/run.py`)
  checks it. In lib, `band.apply_tempo` and `lib/histhear.lua` delete every marker and insert the map's points with index -1: only a map
  with two points at one time would come out differently in REAPER (the first kept), and `band.capture_tempo` never reads one. Nothing
  relies on the stand-in's old behaviour. Not checked in REAPER: whether `SetTempoTimeSigMarker(-1)` at a marker's time is ignored as
  `AddTempoTimeSigMarker` was (assumed the same).

**Not fixed here:** P1-4's two contradicting lines for a raw knob ("both changes go in" and "asked ... to release" in the same second),
seed 15033 of the long run below (an item's length differs on one computer, pre-existing), and the soak can't catch bug A (a lost edit
converges: the oracle has no idea of intent), so there's no soak scenario for it; parts 32 and 33 are the scenarios.

**Review-later (security).** `retimed` on a change is a bandmate's word: it only makes that sender's own side count for nothing in a merge
(no power over anyone else's change). The Undo ask is ExtState on this computer only.

**Soak.** `python tools/soak/soak.py --long --minutes 10 --no-shrink --first 15000`, 150 edits a seed, from clean clones: before (9018131)
44 seeds, 43 passed (97.7 %; 15033: an item's length differs between James and Cee); after: SOAK_AFTER.

**REAPER re-checks for rt-fix9.**
1. **A again** (check 4): the desktop renames a track in the same moment the laptop moves that track's fader (timed on the shared clock, as
   rt-r4). Pass: both computers end with the new name and the laptop's fader; the desktop's log has its "1 change(s) went"; no "which you've
   claimed". Then the same with a colour change and a mute instead of the rename.
2. **B again**: LinuxBox changes the first tempo; once it has landed, the desktop changes it. Pass: no "claimed XT Rec A" on the desktop
   (three tries). Then the desktop changes the tempo and moves an automation point on XT Rec A in one undo block: claimed, as an edit.
3. **The Undo ask**: the desktop moves the laptop's item, the laptop renames it, the desktop presses StudioSync's Undo (Ctrl+Z). Pass: no
   box; a tooltip and the log say "... Press Ctrl+Z again within 30 s"; Live sync carries on (a bandmate's edit lands meanwhile); Ctrl+Z
   again undoes it. Again with the panel open: its bar shows the ask with Yes / No; Yes undoes it, No and silence leave it.
4. **(a)**: rename a marker, have a bandmate change the first tempo, Undo: the log says "undo: changed the markers", no bpm.
5. **(b)**: check 1 again with XT Keys C: no "theirs stands" and no "as you did" on the desktop; LinuxBox's move stands everywhere.
6. **(c)**: P1-6 again (the desktop deletes XT Gtr while the laptop renames it, then the desktop's Ctrl+Z): the laptop's Who controls has no
   claim on "XT Gtr renamed" within 10 s of the track's return.
7. **(d)**: run "Insert tempo marker" (the action, not the API) at an existing marker's place with another tempo; and
   `SetTempoTimeSigMarker(proj, -1, t, ...)` at an existing marker's time. Pass: one marker, the first tempo, for both.
