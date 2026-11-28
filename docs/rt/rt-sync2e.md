# rt-sync2e: grey stand-ins that never go away, and byte-wise id order (2026-11-27)

rt-sync2c's Recommendations 2 (the stand-in leftovers, 9002 and 15011) and 5 (sort ids byte-wise everywhere the judge sorts), on top of
rt-sync2d (87e2bcc, v0.61.3). Nothing here was run in REAPER; the REAPER checks are below. Per James's decision of 11-27 18:33 (StudioSync is
only on his own computers), no compatibility code for older versions was added and the mixed soak is information only.

## Summary for James

- **Grey "arriving" boxes no longer stay grey for good.** While a bandmate's take is still arriving, StudioSync shows a grey stand-in where it
  goes. Four ways left one behind for ever on one computer, and the soak's new check found them in **85 of 237** long-soak seeds (not 2, as
  rt-sync2c expected: its check was never committed, and the cases are common once the oracle looks):
  1. you copied the grey box (duplicated the track or a stretch) before the take arrived: the take landed on one of the two, the copy stayed
     grey. Now the copy becomes a copy of the real take, where you put it, and goes out to the others as yours;
  2. the take was deleted (by its maker, or with its track) before it arrived: now its grey box goes with it;
  3. the track it sat on was deleted: the grey box went to "<track> (yours, not sent)" with its id cleared, grey for ever. Now it goes with
     the track (it holds nothing of yours);
  4. StudioSync's own Undo / Redo brought back a take whose audio wasn't on this computer: it left a grey box that nothing would ever fill
     (the Undo says "couldn't change here yet" and doesn't try again). Now it makes none.
- **Every order StudioSync decides by is byte order** (rt-sync2c Recommendation 5): which of two simultaneous changes wins on a tie, how a
  merge is built, which claim on a track wins in the same second, the order heal and Undo work in, the trim's "newest". Lua's string compare
  follows the computer's language settings, which can sort "a" before "B" on one computer and after it on another. Where Lua's own compare
  already is byte order (the usual case; it is in the test runner), nothing changes and it costs nothing; elsewhere StudioSync compares byte by
  byte.
- **Soak:** long soak 236 of 237 (only 15057, the tempo map / markers class every round since rt-sync2c), with the stand-in check that alone
  fails 85. See Gates.

## Commits

| Commit | What | Test that fails without it |
| --- | --- | --- |
| ec878cf | soak oracle: a `band_arriving` item left at quiet is a double (`tools/soak/node.lua` `N.state`) | (the baseline: 152 of 237) |
| 910b098 | stand-ins: landing turns a person's copy into theirs; deletion and a gone record take every stand-in; a deleted track's stand-in goes with it; Undo makes none (`lib/mirror.lua`) | `test_0_60_rt_standin` 1-5 (each part with its piece taken out) |
| 21f8e1b | byte-wise orders: `rank.less` (Lua's `<` where it is byte order, else `rank.bytes_less`), used by `lib/judge.lua`, `lib/mirror.lua`, `lib/mirror_merge.lua`, `lib/sync.lua`, `lib/evindex.lua`, `lib/trim.lua` | `test_0_60_rt_bytesort` 2 (judge's ties); 1 pins `rank.native_ok` |
| ac7ec2b | `rank.cmp`: a plain sort keeps C's `table.sort` (no Lua comparator) where Lua's `<` is byte order | (speed only: the bigproj A/B in Gates) |
| (this doc) | docs/rt/rt-sync2e.md | |

Nothing of `lib/webui*` (the uncommitted edits there are someone else's), no version bump, nothing pushed. No new lib file; `lib/files.txt`'s sizes and hashes are regenerated at release (Recommendation 8).

## What was built

### Task 1: stand-ins (`lib/mirror.lua`)

A stand-in is `mirror.placeholder`'s grey item (`P_EXT:band_arriving`, `band_oid` = the item's id). `mirror.is_standin(it)` says one is: the
mark, and not a live take's or a jam's (`lib/streams.lua`, `lib/jam.lua` mark theirs `band_arriving` too, with `band_stream` / `band_jam`; they
go their own way and are untouched). `mirror.standins(proj, oid)` walks the project's items for every stand-in carrying an id; it runs only
once a stand-in has been met, never on the usual path.

- **Landing (`mirror.apply`, item branch; rt-sync2c's 9002).** When the item `mirror.find` returns is a stand-in, the version lands on the
  stand-in nearest its own place on its own track (a person's copy may sit first in the project, where `find` looks first: landing on it moved
  the copy onto the original's place and left the original grey, two alike). Every other stand-in carrying the id is a copy the person made:
  it gets the landed item's chunk (the same `only_shared` / `resolve_media` text: no GUIDs, no pool), keeps its own position and lane, loses the
  mark and the id, and gets the landed item's `band_theirs` paths (as apply notes them, so its take FX files aren't copied out as this
  person's). The next look's `settle_ids` gives it a fresh id and sends it as new: theirs. The landed item's mark is cleared explicitly too
  (REAPER's `SetItemStateChunk` without an `<EXT` block drops P_EXT, and the fixture does the same; cleared anyway, it costs one call).
- **Deletion landing (`mirror.apply`, gone branch).** When the item found is a stand-in, every stand-in with its id goes (was: only the one
  `find` picked).
- **A gone record (`mirror.remember` -> `mirror.standins_go`; rt-sync2c's 15011 first half, the soak's 15050 and others).** Whenever an item
  is recorded gone here (its deletion, or "gone with its track" in receive or heal, or W.gone), any stand-in carrying its id goes. One
  `mirror.find` per such record; the walk only if a stand-in turns up. A version that still has to land after that (a bandmate reviving the
  item) makes a stand-in again on receive's next try, as before.
- **A deleted track (`mirror.apply`'s track-deletion loop; 15011's second half).** A stand-in on the deleted track goes with it instead of
  being moved to "<track> (yours, not sent)" and losing its id there (the unknown id read as "new work of yours").
- **StudioSync's Undo / Redo (`mirror.revert` -> `mirror.apply(..., no_standin = true)`; the soak's 9029).** Revert applies once and, when a
  version can't land (audio missing), counts it as "couldn't change here yet" and sends nothing. The stand-in it made was never filled or
  removed. `mirror.apply`'s new fifth argument skips the stand-in; only revert passes it. Put-backs and receive still make stand-ins (they try
  again).

A first cut also removed stand-ins in `mirror.receive` when an answer lands nothing; the soak showed it unneeded once `remember` does it
(84 of the 85 baseline failures pass without it, the 85th is 15057), so it isn't in the commit.

### Task 2: byte-wise orders

`lib/rank.lua`:

- `rank.bytes_less(a, b)`: byte order, skipping a common start 8 bytes at a time (ids share long starts: `James-20261122-1901...`).
- `rank.native_ok(lt)`: does a comparator (Lua's `<` by default) order every pair of printable ASCII characters as bytes do, and put each one
  before "a" when followed by "b" (a collation that passes over "-" or "'", as Windows' word sort does, reads "-b" after "a")? 0.5 ms.
- `rank.less`: Lua's own `<` when `native_ok()` held as the file loaded (`rank.native`), else `bytes_less`. `rank.cmp` is the same for
  `table.sort`'s argument: `nil` (C's own sort, no Lua call per comparison) where native is byte order, else `bytes_less`. Measured on a sort of 4,000 ids:
  native 2-3 ms, the plain byte loop rt-sync2c had 76-88 ms, `bytes_less` 39 ms. So where Lua's `<` already is byte order (the C locale every C
  program starts in; true in the test runner) the change costs nothing and changes nothing; elsewhere the order is right at 13-20x the cost
  of a native sort (about 40 ms per sort of 4,000 ids, and a heal sorts all the room's objects: see Recommendations 3).

Used for every order that decides a winner or a sequence from ids, clocks or names:

| Where | What |
| --- | --- |
| `lib/judge.lua` | `newer`'s name tie, `later`'s id tie, `merge_order`'s id tie (the merged id), `settled`'s version order, `s.beaten`, `s.missing`, `ids_of` |
| `lib/mirror.lua` | `wanted_order`'s new-track tie, note-name keys (hashed: the `misc` part), `restore_unsent`'s order, W.gone's deletion order, revert's plan order, `mirror.root`'s code (hashed and compared between computers), `room_newest`, heal's object order |
| `lib/mirror_merge.lua` | moved pairs' tie, MIDI events' text tie, the merged keys list, `TRACK_TOGETHER` lanes (hashed) |
| `lib/sync.lua` | claims (prints, tracks, regions, time stretches: the later name wins a same-second tie), the driver handover tie, a rename's claim tie, the receive pass's pending order, the group order |
| `lib/evindex.lua` | `oids`, `contents` |
| `lib/trim.lua` | `later` (which version is kept as newest) |
| `lib/rank.lua` | `rank.order` already used `rank.less` |

Left as Lua's `<` on purpose: ISO time strings (`2026-11-22T19:01:02Z`: digits in fixed places, the same under any collation), numbers, and
sorts that are local only (log lines, the panel's names, `who_here`, the stash signature, `items` lists sent as sets).

**Different versions in one room.** Nothing persisted changes format; no hv bump. On a computer whose Lua `<` was already byte order (every
computer `rank.native_ok` accepts) every order is exactly as before. On one where it wasn't, a tie broken by a name or id with mixed case or
punctuation now goes the other way; that computer was already disagreeing with byte-order computers there. A merged version's id
(`m(winner&loser)`) is persisted only as a later edit's `base_ev`, which the judge reads through `split_merge` (both sides, order free), so an
old merged id still reads; a record holding an old merged id that the new order names differently lands the merge again once (same content
unless the two sides changed the same setting). Mixed rooms aren't required (James, 11-27).

## Tests

- `tests/test_0_60_rt_standin.lua` (new), against the chunk-faithful fixture: 1 landing with a copy above (copy turned theirs, nothing doubled,
  a look gives it its own id); 2 deletion takes both; 3 a gone record takes the stand-in, another item's record doesn't; 4 a deleted track's
  stand-in goes with it, no "(yours, not sent)"; 5 apply with `no_standin` makes none. Knock-out check (each piece removed from a copy of
  lib/, the test run): copies -> part 1 fails ("no stand-in left"); the nearest pick -> part 1 ("the copy stays where the person put it");
  deletion of all -> 2; the remember hook -> 3; the track-deletion skip -> 4; `no_standin` -> 5.
- `tests/test_0_60_rt_bytesort.lua` (new): 1 `bytes_less` cases, `native_ok` refuses a case-insensitive and a "-"-skipping collation and
  accepts bytes, `rank.less` agrees with bytes on 5,000 random words; 2 loads `lib/judge.lua` with `rank.less` reversed and checks `newer`,
  `later` and `merge_order` follow it (with 87e2bcc's judge, part 2 fails at its first assert: the judge used `<`).

## Gates

All from a fresh clone of **ac7ec2b** (the last code commit) under the scratchpad, run one after another (no two soaks at once). Long soak:
the 237 seeds (5000-5057, 9000-9059, 13000-13059, 15000-15058) at 150 edits, seed by seed in a pool of 8 (rt-sync2d's runner).

| Check | Result |
| --- | --- |
| long soak, 237 seeds, oracle check alone (ec878cf = 87e2bcc's code) | **152** (85 failed: 84 on stand-ins left, plus 15057) |
| long soak, 237 seeds, ac7ec2b | **236** (15057 only: tempo map / markers, the timeline class; failing in every round since rt-sync2c) |
| stand-ins left at quiet, ac7ec2b | **0** in all 237 (9002 and 15011 pass) |
| `soak.py --scenario all` | **15 of 15** as they say |
| `TZ=UTC0 python tests/run.py --no-luals` | fails 2: `test_0_60_rt_bigproj` (a quick look 71 ms against 57) and `test_0_60_rt_drivebg` ("no look over 20 ms", worst 24 ms): both load-sensitive, A/B'd below |
| `python tests/run.py --no-luals`, local time | **fails 0** |
| `files_check` / `release_check` | NOTE only (files.txt regenerated at release; not ready to release: no version bump, as asked) |
| browser tests | not run: nothing under `lib/webui` changed (they load only the page's own files) |
| mixed soak, Cee on 9164f56, 5000-5029 (information only, James 11-27) | **27 of 30**: 5013 and 5025 are stand-ins left on Cee, the old lib (no fix there: expected now the oracle looks); 5008 is Bee's undo probe ("Undo then Redo didn't bring the song back: an item of James's missing"). At ec878cf all three fail on stand-ins (5008 on James too), which stopped the check before the undo probe ran, so 5008's undo class may be older; not chased (mixed rooms aren't required) |

**The timing tests, A/B (each run alone, alternating, the same machine load):** `test_0_60_rt_bigproj` 87e2bcc 6 of 8 passes, this
round's code 7 of 8 (before ac7ec2b's `rank.cmp`: 1 of 3 against 2 of 3, which is why ac7ec2b exists); `test_0_60_rt_drivebg` 87e2bcc 1 of 3,
ac7ec2b 0 of 3, every failure the same "no look over 20 ms" (worst 24-40 ms on both). It fails at least as often on 87e2bcc under the same load,
so I don't count it as this round's. An earlier full run on the worktree (this round's code before ac7ec2b), at a quieter moment, had fails 0
in UTC, bigproj and drivebg included.

### The runs on the way

| Code | Long soak | What it showed |
| --- | --- | --- |
| ec878cf (oracle only) | 152 | 84 seeds with a stand-in left: copies of stand-ins on band tracks, "(yours, not sent)" ones with no id, ones for deleted items |
| + landing copies, deletion takes all, track deletion, a receive-time removal | 81 of the 85 | 9029: StudioSync's Undo made a stand-in it never filled (revert); 15049, 15050: a stand-in for an older version made after the item was recorded gone with its track |
| + `no_standin` for revert, + the `remember` hook | 236 of 237 | (the receive-time removal then shown unneeded: 84 of 85 without it) |
| 910b098 + 21f8e1b + ac7ec2b (the gate) | 236 of 237 | as above |

## REAPER checks for James

All on the real computers after a release with these files. Keep a copy of the test song's folder first. To make a take "arrive late" on
the laptop, pause Syncthing there (its tray icon, Pause all) before recording on the desktop, and resume it when the step says.

1. **A copy of a grey box becomes yours.** Laptop's Syncthing paused; record an 8-bar take on the desktop. Resume Syncthing only long enough
   for the change to arrive (the laptop shows the grey "arriving: ... still syncing" box), pause again. On the laptop Ctrl+drag the grey box to
   bar 20 (or duplicate its track). Resume Syncthing: the original becomes the take at its place, the copy becomes the same take at bar 20
   (not grey), and within seconds the desktop and Mac show the laptop's copy at bar 20 as a new item. Nothing grey left anywhere.
2. **Deleted before it arrived.** Same start (grey box on the laptop, Syncthing paused); on the desktop delete the take. Resume: the grey box
   goes, no take appears.
3. **Its track deleted before it arrived.** Same start; on the desktop delete the whole track. Resume: the track goes on the laptop, and no
   "<track> (yours, not sent)" track appears there (it did before, holding a grey box for good).
4. **StudioSync's Undo with the audio missing** (optional, fiddly): on the laptop, with Syncthing paused before a bandmate's new take's audio
   arrived, use StudioSync's Undo on something that brings that take back: the Undo says "couldn't change here yet", and no grey box is left
   behind once Syncthing resumes and the take lands normally.
5. **Which order Lua uses in REAPER** (read only, ReaScript console, one line of Lua, on each computer):
   `reaper.ShowConsoleMsg(tostring("a" < "B") .. "\n")`. `false` means REAPER's Lua compares by bytes (StudioSync then uses Lua's own compare,
   nothing changed); `true` means a language setting changes the order (StudioSync now compares byte by byte there, slower on big songs). Tell
   me which, per computer: it decides whether Recommendation 3 matters.

## Recommendations (ranked)

Recommend only; none built here.

1. **Make "pending landing" one piece of state, not a property of items.** Today a stand-in is an ordinary REAPER item carrying the id, so
   every path that copies, moves, deletes or records items has to remember it (this round found four, and live takes and jams reuse the same
   mark). A per-project table `pending[oid] = { guid, version id }` written by `placeholder`, with one reconcile at the end of each receive
   pass and each heal (stand-in kept iff the judge's answer for `oid` is a version not yet in place whose audio is missing; else removed, and
   any other item with the stand-in's id turned into a copy) would replace `remember`'s hook, apply's three branches and revert's flag with
   one invariant, and the oracle's new check would be a unit test of it.
2. **Record a stand-in's GUID like a landed item's (`mirror.GSEC`).** `mirror.find` would then pick the original stand-in for sure (as it does
   for a landed item), and the "nearest to the version's place" guess in apply goes away; a copy of a stand-in would be recognised by GUID
   like any copy of a band item (`studio_item`). Small change; worth doing with 1 or alone.
3. **If any computer reports `true` in REAPER check 5:** byte-wise sorts cost 13-20x a native sort there (39 ms per 4,000 ids; heal sorts
   every object). Either a byte compare exported by the StudioSync extension DLL, or a sort key made once per id (each byte as three decimal
   digits: digits-only strings sort the same under every collation, so the native `<` on the keys is byte order on the ids).
4. **An oracle check for everything the scan doesn't see.** The stand-in class hid for many rounds because the oracle compares only what
   `mirror.scan` returns. Count every item and track on each computer that the scan skipped (stand-ins, local tracks, live placeholders) and
   require each to be explicitly expected at quiet (a "(yours, not sent)" track with a reason logged, a live take while a stream runs).
5. **The last long-soak failure is 15057, tempo map / markers** (rt-sync2b Recommendation 7, markers as objects with their own versions).
   With the stand-in class fixed it is the only class left in the 237 seeds.
6. **`mirror.remember` is the wrong layer for cleanup.** It's a record write; the stand-in hook sits there because every "gone here" path
   calls it. A `mirror.record_gone(proj, oid, ...)` used by those paths (there are about ten `remember(..., "", ...)` calls) would make the
   meaning explicit and let a later change see all of them.
7. **Live takes and jams share `band_arriving` with stand-ins** (`lib/streams.lua`, `lib/jam.lua`): `mirror.is_standin` tells them apart by
   `band_stream` / `band_jam`. A distinct mark (`band_live`) for those would remove the guess; the soak doesn't exercise either.
8. **`lib/files.txt` is regenerated only at release**: `tools/files_check.py` notes 8 differences after this round (7 lib files changed here,
   and `lib/webui.lua`'s uncommitted edits). Run `python tools/make_index.py` with the next version bump, as usual.

## What I didn't check

- Nothing was run in REAPER: whether REAPER's `SetItemStateChunk` drops P_EXT the way the fixture does (the landed item's mark is cleared
  explicitly anyway, so either way is safe), and whether REAPER's Lua `<` is byte order on James's computers (check 5).
- Live takes and jams (their `band_arriving` items are excluded by `band_stream` / `band_jam`; not exercised by the soak).
- Mixed rooms beyond the one information run (not required: James, 11-27).
- The receive-time removal I dropped (answer lands nothing -> stand-ins go) was shown unnecessary only on the 85 baseline failures and the
  full gate; a case where a stand-in outlives a non-gone answer whose item isn't here would need it (I couldn't construct one: such an answer
  lands, which fills the stand-in).
