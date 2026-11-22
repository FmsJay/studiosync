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
