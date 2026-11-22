# rt-soak: the convergence soak (backlog package T3, 2026-11-21)

Package T3 of `docs/rt/backlog.md` "Plan to finish", the investment `docs/REVIEW-FULL-2026-11-18.md` recommends: three computers, each running
the real sync code with a folder of its own, a shim that delivers late, out of order, half-written and twice, seeded random edits, and an oracle
that compares every object. Offline only: the three computers are the stand-in REAPER, not REAPER (see "What it doesn't cover").

Files: `tools/soak/soak.py` (driver, shim, oracle, shrinker), `tools/soak/node.lua` (one computer), `tools/soak/.gitignore` (`out/`). No `lib/`
file was touched.

## How to run it

From the repo root (or anywhere: it changes to the repo). Python with `lupa`, as `tests/run.py`; `psutil` for the memory cap (optional).

| Command | What it does |
| --- | --- |
| `python tools/soak/soak.py --quick` | about 60 s: the soak's self-check, then 40-edit seeds from seed 1 until 55 s are up. Last line `ok soak` or `soak FAILED`; exit 0 only when every seed passed |
| `python tools/soak/soak.py --selfcheck` | only the self-check (under a second): the plug-in model and the driver's plug-in edits |
| `python tools/soak/soak.py --long --minutes 45` | 150-edit seeds until the time is up; each failure shrunk (up to `--shrink-secs`, default 600) and written to `tools/soak/out/seed-N.json` |
| `python tools/soak/soak.py --seed 17` | one seed; prints the failure and the last 60 trace lines (`--trace`: the whole trace as it runs) |
| `python tools/soak/soak.py --seed 17 --shrink` | one seed, shrunk to its fewest edits; prints the command that replays them |
| `python tools/soak/soak.py --seed 17 --keep 3,9,12` | only those edits of seed 17 (what a shrink prints) |

Other switches: `--edits N` (per seed), `--first N` (first seed of a quick or long run), `--clean` (no network faults and no clock skew: checks
the soak itself), `--no-undo-probe`, `--no-shrink`, `--first-edit S` (simulated seconds before the first edit; default 20, see bug 1). The
memory cap is `tests/run.py`'s: `STUDIOSYNC_TEST_MEM_MB`, default 4096; past it the run ends at once (exit 2). A 120-edit seed takes 3-10 s;
the process stayed under 170 MB over 108 seeds (each run's Lua states are collected before the next).

**Seeds reproduce.** The edits come from the seed alone; the network's delays, losses, pauses and the clocks' skew come from a second random
stream seeded from it; each computer's `math.random` is seeded too. The driver picks items by id and place, not by their place in a track's
list. Two runs of one seed gave the same trace and the same end for seeds 2, 7, 11, 13, 21, 41, 57 and 3005 at 60 edits; seed 30's trace differed
only in the order of names in one log message (`pairs` again), and seed 9 differed for real (bug 8).
The caveat: Lua 5.4 seeds its string hashes per state from the clock and addresses, so `pairs` order differs between runs, and StudioSync
itself sometimes decides differently with it (bug 8); then a seed can end differently, though in every pair seen the verdict was the same.
Shrinking copes (it re-runs and compares signatures), and a shrunk repro was stable in every case in this note.

**Adding it to `tests/run.py` (not done, as asked):** one more entry in `steps`, after `tools/js_check.py`:
`("tools/soak/soak.py --quick", False)`. `False` makes it a NOTE, not a failure, while the bugs below are open (quick mode fails today on most
seeds); switch it to `True` once they're fixed. Meanwhile `("tools/soak/soak.py --selfcheck", True)` can be fatal at once: it only checks the
soak itself. It runs as a subprocess, so `run.py`'s per-test timer doesn't cover it; its own 55 s budget and
memory cap do. The long mode is for nightly and before a release, as the review suggests.

## Design

**A computer** (`node.lua`) is a fresh `lupa` Lua 5.4 state with `tests/fixtures/editreaper.lua` as `reaper` and the real `lib/` modules loaded
by `require`, as Live sync loads them. Three states share nothing: no module tables, caches (`sync.ev_cache`, the claims cache, `mirror.looks`),
or clock. The edits test models computers as tabs in one Lua, which shares all of that.
- **Its disk** is a table in memory behind `io.open`, `io.lines`, `os.remove`, `os.rename` and REAPER's `EnumerateFiles`,
  `EnumerateSubdirectories`, `file_exists` and `RecursiveCreateDirectory`. `band.write_json`'s temp-file-then-rename, `band.read_json`'s parse,
  the listing caches and the direct link's inbox all run for real. Writes under the studio's folder, except Syncthing's own temp names, go to
  an outbox for the shim.
- **Its clock:** `os.time`/`os.date` from the simulated time plus the computer's skew (up to 1.5 s either way; the laptop ran 0.9 s ahead), and
  REAPER's `time_precise` the same.
- **A pass** is Live sync's `P.who` / `P.look` / `P.receive` without the parts that aren't sync: `sync.authority` (and `sync.soft`), then
  `sync.watch_timeline`, then `mirror.watch` with the options Live sync passes (claims' `ask`, `sent`, `soft`), `claimask.flush`, then
  `sync.receive` until it has nothing more, then Live sync's `P.heal` (a caught-up bandmate whose project has differed for a minute brings
  ours in line, `mirror.heal`) and `mirror.order_heal`. Every 5 s a real `sync.write_status` with the fields `P.heal` compares (pending, the
  project's root, the order code), so presence (and so Claims mode's "isn't here") is real.
- **The link's messages** handled: `event` (`sync.take_event`, into the inbox), `presence`/`heartbeat` (`presence.from_msg`), `claim`
  (`sync.live_claim`), `claim_ask`/`claim_answer` (`claimask`). Nobody answers an ask, so asks time out after 30 s and the edit is put back.
- **Stubbed:** `direct.available` (true: the extension is mandatory), `direct.send_live` (to the shim), `prints.choose` (as the tests do),
  `trust.claim_ok` (true: Syncthing says each file's writer), and REAPER's `MB` answers Yes (Undo's "a bandmate changed it since").

**The song.** James shares four tracks (an envelope on Drums), nine audio items and two MIDI items, with each audio item's file written into the
studio's media folder, so a receiver's grey stand-in waits for the file like REAPER does. Every computer opens with the song's markers. The
room's mode is Claims (`open`, the default) for three seeds in five and Open (`everyone`) for the other two.

**The shim** (`Sim` in `soak.py`), a discrete-event simulation in 0.1 s steps:
- **Syncthing:** each file reaches each other computer 0.5-6 s later; 12 % are late (15-90 s, so other files and the link overtake them);
  5 % come again later; 3 % are first seen half-written (half the bytes, then the whole). A computer's Syncthing pauses now and then for
  20-120 s (nothing in or out). Syncthing never puts an older version over a newer one. Deletes travel the same way.
- **The link:** one lane per pair of computers, in order (the extension's `direct_msg` queues frames per peer over TCP); a lane goes down for
  0.5-8 s now and then and what it carries meanwhile is lost; 2 % of frames come twice, right after themselves. The link is never out of order
  within a lane: an earlier version of the soak reordered it and the sharing itself failed, which the real link can't do.
- **The driver:** 22 kinds of edit, weighted: items moved, resized, muted, deleted, recorded, copied (REAPER's copy: chunk and `P_EXT` kept,
  new GUIDs), moved to another track; tracks added, renamed, deleted, faded, reordered; tempo (the first marker, a new one, one deleted);
  markers and regions added, moved, renamed, deleted; MIDI notes added, transposed, removed; CC7 drawn or changed; plug-ins added, removed,
  reordered, turned; automation points; claims taken and let go; Undo and Redo (`undo.step`); a whole-song Restore (`sync.restore_timeline`
  then `mirror.revert` of `mirror.plan_restore`, as the Restore page does). Each edit is made on a random computer as REAPER leaves the
  project. Edits come in bursts (0.6 s apart on average) with gaps of 3-12 s, from 20 s after the share, squeezed into 0.9 s per edit.
- **Quiesce:** after the last edit the faults stop, everything still on its way arrives (paused Syncthing resumes), and passes continue until
  nothing but presence has moved for 140 s (was 90: Live sync's heal waits 60 s, its order heal 120 from a bandmate's track move landing;
  at most 400 s, past that it's a `settle` failure: something never stops
  sending).

**The oracle**, in order, stopping at the first category that fails:
1. `errors`: anything StudioSync logged through `band.log_error` (every `band.try` that caught something) or that raised out of a pass, an
   edit or a link message.
2. `doubles`: an id twice in one computer's `mirror.scan`; two items on one track alike in all but their GUIDs (the driver never puts two items
   at one place: every place is a fresh random time to 0.1 ms).
3. `converged`: every object's hash, the track order, the tempo map and markers the same on all three. Numbers in a part's text are compared to
   9 decimals: REAPER's moves for a tempo map and back leave the 14th digit different from the event's text (`mirror.rounded` makes the same
   allowance).
4. `log`: a late joiner, Dee, opens the song (its markers), gets the whole studio folder as James has it, and catches up by reading every
   change. It must end as James's. This checks that the events tell the same story as the projects: a change that only reached projects, or
   one that lands differently on a fresh read, shows here.
5. `undo`: on each computer in turn, Undo, wait until quiet, Redo, wait until quiet. After each, all three the same; after the Redo, as before
   the Undo (when both did something).

**The shrinker** is ddmin over the edits, then one at a time, keeping the network's randomness and the clocks the seed's, and accepting a
smaller list only when it fails with the same signature (category, and for object differences the kind of object: track, item, plug-ins,
automation...). It prints the replay command and each remaining edit as the computer made it.

## Status after rt-converge (2026-11-22)

All nine bugs below are fixed in `docs/rt/rt-converge.md` (causes, fixes, the pass-rate table, what's left), each with a test in
`tests/test_0_60_rt_converge.lua`. Every repro command in this note passes at that head. Bug by bug: 1, 5, 7: a version names its tempo
map; 2: only a real rename is answered, and the newer of two claims on one track holds it; 3: a change is judged by the claims of its own
time; 4: a returning track brings its items back everywhere; 6: only a move moves a track, the order list follows every move, new tracks
are ordered as they landed; 8: `mirror.revert` and `mirror.heal` work in one order (two runs of a seed now write the same things);
9: an Undo of nothing leaves nothing to redo, and Undo goes by what a change was built on.

The soak itself changed too (eleven artifacts, listed there): each computer starts the link and runs Live sync's apart note, the
stand-in REAPER moves items for a tempo change as `mirror.retime` does, the late joiner waits out refused changes and gets the order
heal a real one gets, the oracle waits 140 s of quiet (the order heal needs 120) and allows a whole number written two ways, each file
write has its own Syncthing version, the in-memory disk keeps up with `band.write_atomic`, the driver edits studio tracks only and keeps
one tempo marker to a place, and the undo probe doesn't compare where the log says a claim stood in front of the Redo.

**`python tools/soak/soak.py --quick` passes: the `tests/run.py` entry below can be fatal (`True`).** A 20-minute `--long` run passes
over 95 % of its seeds (rt-converge.md has each run); the failures left are listed there with what they are: a knob turned in the moment
the first track goes, a restore racing a bandmate's edit, and a late joiner's order of tracks made in the last seconds.

The rest of this section is the note as written at HEAD 905f000, kept for the record.

## What the long run found

Soak time spent (about 2.5 hours of runs across parallel processes, memory never above 170 MB per process):
- **The final statistics run** (final code, `--long --minutes 20 --first 3000 --edits 120 --no-shrink`, output in `tools/soak/out/long-run.txt`):
  195 seeds, 14 passed (7 %). Failures by first category: converged 122, settle 38, log 14, undo 4, doubles 1, errors 2 (the two `errors`
  seeds were `lib/mirror.lua` half-edited by another agent at that moment: "attempt to call a nil value (field 'user_edited')" at 0.2 s;
  the one `doubles` seed didn't fail that way when re-run on HEAD's code).
- An earlier 12-minute sweep (108 seeds of 120 edits, before the last two soak artifacts below were fixed): 5 passed. On a clean network (`--quick --clean`, 13 seeds of 40 edits): 3 passed. So
  most of what fails is concurrency itself, not the network's faults.
- Shrinking: two runs with shrink (45 min from seed 1000, 30 min from seed 1), plus targeted shrinks of clean-network and `doubles` failures.

**Checked at HEAD 905f000.** The soak loads `lib/` from the working tree, where other agents had uncommitted edits during these runs
(`lib/mirror.lua`, `lib/sync.lua`, `lib/claimask.lua` and more). Every repro below was re-run from a `git archive` of HEAD 905f000
(`lib`, `tests/fixtures`, `tools/soak`) and fails there. Two that failed only against the working tree's edits of the moment are left out
(a track deleted against an item move then undone, seed 1003; a rename variant, seed 6). For a nightly run, run from a clean checkout.

Every bug below was shrunk by the soak and then read by hand in the trace and the computers' logs (`N.eval` in `node.lua` runs Lua inside one
computer). Each "repro" line replays it exactly. Bugs 3, 4, 5 and 6 were also run with 250 s of quiet instead of 90 (Live sync's heal and order
heal had their chance) and still failed. None is fixed here: the files are other packages'. "Suspected place" is where the trace led, not a diagnosis.

**1. A hand edit in the 15 s after a tempo map lands from elsewhere is kept on that computer only, silently and for good.**
Repro: `python tools/soak/soak.py --seed 1 --edits 10 --keep 1 --clean --no-undo-probe --first-edit 2` (no network faults needed).
Mid-session form: `python tools/soak/soak.py --seed 1006 --edits 120 --keep 87,89 --no-undo-probe`: James sets the first tempo to 129 at
93.6 s, Bee moves James's Drums 1 at 97.3 s; Bee keeps it at 2.74 s, everyone else has it at 3.72 s. Any tempo change by anyone opens the
15 s window on everyone else.
Claims mode. James shares the song; Cee opens it, so the song's tempo map lands on Cee at 0.2 s (its tempo window runs to 15.2 s). At 5.6 s Cee
moves an item on Bass, which James auto-claimed. The look first says "a change on Bass waits: the studio's last version of it isn't readable"
(the item's last change came over the link; Syncthing's copy of it arrives at 6.4 s). At 6.6 s the look records Cee's moved item as the band's
version (`mirror.remember` with Cee's own hash) without sending it, asking James, or putting it back. Cee keeps the item at 15.98 s; James and
Bee have it at 12.5 s; nothing in anyone's log. Live sync's heal can't see it either: `mirror.root` hashes event ids, not content, so Health
says the same.
Suspected place: `lib/mirror.lua` `W.refuse`, the "the tempo changed and REAPER moved this with it" branch (line ~5104): it takes any item that
differs from its last version only in POSITION/LENGTH/... for REAPER's move, and `mirror.map_moved` returns true whenever `tempo_from` is nil,
which it is for a map that wasn't made here (backlog 1.10's fix covers only this computer's own tempo change). Also `W.send`'s "unread" wait
(line ~4950) doesn't look in the link's inbox, where the last version already is.

**2. A track renamed while someone else holds it: the two computers rename it back and forth for ever.**
Repro: `python tools/soak/soak.py --seed 5 --edits 40 --keep 5 --no-undo-probe` (this seed's network; with `--clean` it passes). Also the
4-edit shrink of seed 1000 (`--seed 1000 --edits 120 --keep 102,103,118,119`, roles the other way round) and seed 1001's
8-edit one. Every `settle`
failure of the run had a track rename in its shrunk edits.
Claims mode. Cee renames Drums (James's auto-claim) to T3553. The rename goes out, and Cee's auto-claim takes "T3553". James's receive puts the
name back ("their StudioSync is older and didn't ask first", although it's the same StudioSync), and Cee's receive, holding T3553, puts
James's "rename" back the same way. Every 1.5-3 s, for the 400 s the soak waited: an event file each way each time (hundreds), two log lines
each time on every computer, and the track's name flips on Bee's screen.
Suspected place: `lib/sync.lua` `sync.receive`'s `set_back` (line ~1939) assumes "only whoever holds the track answers", but after the rename
both do: James by the old name, Cee by the new one (`lib/claimask.lua` `claimask.on_sent` auto-claims what went out under its new name).
And the look let a rename of a track someone else holds go out at all; the comment says this StudioSync holds such a rename for a minute.

**3. A late joiner refuses older changes by today's claims: a whole track missing on anyone who opens the song later.**
Repro: `python tools/soak/soak.py --seed 1 --edits 40 --keep 30 --no-undo-probe` (also with `--clean`).
Claims mode. One edit: Cee claims Bass at 49 s. The three computers already have Bass (James shared it at 0 s). Dee, opening the song after
and reading every change, never applies James's Bass track or its four items (`known` nil, not marked applied) and says nothing; it ends
without Bass. A bandmate who reopens a song after a catch-up, or joins late, gets a different song from everyone else.
Suspected place: `lib/sync.lua` `sync.receive` judges each change by `can(ev.user, name, pos)` from `sync.authority` now, with the claims as
they are now, not as they were when the change was made: James's 0 s change is "someone else's edit to Cee's Bass".

**4. An Undo that deletes tracks loses a bandmate's fresh recording on them, on the recorder's own computer only.**
Repro: `python tools/soak/soak.py --seed 16 --edits 40 --keep 0,1,32 --no-undo-probe` (also with `--clean`).
Bee records an item on Bass at 20.2 s; at 20.3 s James presses Undo, whose last act is sharing the song, so it deletes all four tracks
("16 changes brought back"); at 53.5 s James presses Redo. James ends with Bee's take on Bass; Bee doesn't have its own take; Cee has it on a
local track ("an item of the studio's is on a track of your own"). Track order differs too. Bee's take is gone from the person who recorded it.
Suspected place: the track deletion's race with the item (`mirror.gone_race` / "a track's deletion beats an edit made without seeing it",
rt-p1) is decided differently per computer, and the Redo's "caught up on 1 change ... (their track is back)" re-applies Bee's item on James
but Bee never re-applies its own change from the log.

**5. A refused edit put back under a tempo map that changed meanwhile lands on the old map's timing.**
Repro: `python tools/soak/soak.py --seed 507 --edits 40 --keep 5,6 --clean --no-undo-probe`; also seed 1002's 2-edit shrink
(`--seed 1002 --edits 120 --keep 10,14 --no-undo-probe`: Bee resizes James's Gtr, then sets the first tempo to 114; Bee ends with Gtr at
2 / 6 s, everyone else at 2.105 / 6.316 s).
Claims mode. Bee adds a note to James's Keys A (held: Bee asks James) and at the same moment sets the first tempo to 126. The map goes out;
on James and Cee REAPER stretches Keys A (LENGTH 4 -> 3.8095). Nobody answers the ask; after 30 s Bee's note is put back by writing the item's
last version, made under 120 bpm: LENGTH 4. Bee's Keys A stays 4 long, everyone else's 3.81, for good.
Suspected place: `lib/mirror.lua` `W.put_back` (line ~4805) applies the last event's text as it is; Restore and Undo re-time a version from
another map (`mirror.retime` via `opts.map_of` / `opts.retimed`, rt-p1b), a put-back doesn't.

**6. A track deleted against its claimer is put back in another place: the track order never agrees again.**
Simplest repro, one edit: `python tools/soak/soak.py --seed 10 --edits 40 --keep 1 --no-undo-probe` (this seed's network; passes with
`--clean`). Claims mode: Cee deletes Keys (James's auto-claim); Cee asks, nobody answers, and after 30 s Keys is put back on Cee, but under
Drums instead of under Bass. Cee's order stays different from James's and Bee's.
Three-edit repro on a clean network: `python tools/soak/soak.py --seed 500 --edits 40 --keep 26,27,29 --clean --no-undo-probe`.
Claims mode, three edits within 0.5 s: Cee claims Bass, Bee deletes Drums (James's; put back after the ask times out), James moves Gtr to
second place. All objects agree but Bass and Gtr have different `after` on James and Bee, and stay so through 250 s of quiet with
`mirror.order_heal` running on each pass (it moved nothing).
Also seed 7's 3-edit shrink (`--seed 7 --edits 40 --keep 26,27,28 --no-undo-probe`): Cee renames James's Gtr (put back) while James adds
a track; the order never agrees.
Suspected place: the put-back of a track (`W.put_back` writing it where its last event says) and the concurrent move's or add's `after`
chain; `mirror.order_heal` waits for `order_apart_for` and `ORDER_WAIT` after a landed move, and doesn't act here.

**7. An edit made just before a bandmate's tempo map arrives lands on the others at the old map's timing.**
Repro: `python tools/soak/soak.py --seed 1005 --edits 120 --keep 37,38 --no-undo-probe`.
Cee sets the first tempo to 106 at 54.8 s; at 55.0 s, before Cee's map has reached him, James draws a CC in his own Keys B. James's REAPER
then moves Keys B when the map lands (9.06 s, 4.53 long); Bee and Cee land James's version, made under the old map, after the map: 8 s, 4 long,
for good. Most of the unshrunk tempo failures look like this one or bugs 1 and 5 (seed 1000 before shrinking: Bee's Drums 1 at 40.0084 /
5.6549, James's at 40.1336 / 5.7963).
Suspected place: a change carries the map it was made under (`tl`, `mirror.map_stamp`) only inside this computer's own tempo window; a change
made under an older map than the receiver's newest isn't re-timed on landing (`mirror.retime`, as Restore does), so it lands at its old times.

**8. What StudioSync sends depends on Lua's table order.** Repro: `python tools/soak/soak.py --seed 9 --edits 60` twice (or the repeat
check described above). The two runs agree until 75.1 s, where Bee sends the same change built on a different base: two different
Cee events of 19:00:48 as `base_ev` (`...-00023-...` in one run, `...-00014-...` in the other, at HEAD 905f000). Both runs converge, to different songs. Lua 5.4 randomises string hashing
per state, so `pairs` order differs between runs here and between real computers: some choice of which version an edit builds on (or the
order a pass lands changes in) follows `pairs`. Suspected place: wherever `mirror`/`sync` walk a `pairs` table to pick a base or an order
without sorting (the receive pass's newest-of-each-object pick and the merge's `common_base` are the first places to look). A
determinism mode for the soak would need a Lua built with a fixed hash seed.

**9. (Minor, from the undo probe) Redo after an Undo that took nothing back redoes an older Undo.** Repro:
`python tools/soak/soak.py --seed 505 --edits 40 --keep 14,15,29,30,31,32,33,34 --clean`. Cee copied an item at 46.7 s and undid that at
49.9 s. Much later Cee presses Undo: "0 change(s) brought back (1 not yours to change, left as they are)", then Redo: "1 change(s) brought
back", and the copy undone two minutes earlier reappears (as a new item). To the person, Undo-then-Redo added something.
Suspected place: `lib/undo.lua` `undo.step` / `mirror.last_undo`: an Undo that changed nothing still leaves the older undone act as the next
Redo.
A second probe case, `--seed 8 --edits 40 --keep 23` (Open mode): Cee deletes an item; much later James's Undo and Redo of his whole share
run; then Cee's Undo brings the item back and Cee's Redo says "0 change(s) ... (kept what collaborators added since: Bass)" and leaves it:
James's Redo re-creating the track counted as a bandmate adding the item since (`mirror.undo_keeping`).

**Soak artifacts found and removed on the way** (in case someone sees these in an older run):
- The link was first modelled with independent delays per frame, so frames overtook each other on one lane: tracks then landed out of order
  and the sharing itself failed (receivers sent the order back). The real lane is in order; the soak now is.
- The stand-in has no plug-ins through the API, so every chain edit read as REAPER re-encoding the chain (`fx_readback`: same knobs, same
  presets) and was never sent: `node.lua` now reads one knob per plug-in from the chain's text.
- Without Live sync's order heal, a late joiner's order differed after any track deletion: `node.lua` runs `mirror.order_heal` and `P.heal`
  now.
- Edits in the song's first 15 s all hit bug 1; the driver starts at 20 s (`--first-edit 2` to put them back).
- The stand-in counts GUIDs from 0 in every Lua, so a track made on one computer could share a GUID with a take from another: `node.lua` starts
  each computer's count in a range of its own.
- The driver's plug-in edit first found a chain's end at the first plug-in's closing `>`, leaving a track body unbalanced: the stand-in then
  read an item's lines as a track ("a track named Bass 3 with an item's id", every `doubles` failure of the first sweeps). Fixed, and
  `--selfcheck` (run first by `--quick`) checks 60 such edits.

## What it doesn't cover (and review-later)

- **The stand-in REAPER, not REAPER.** Plug-ins are chunk text read through a small `TrackFX_*` model (one knob each), no take FX, sends, automation items,
  lanes, pooled MIDI, or REAPER's own Undo. A REAPER build of the soak (three instances on the desktop, LinuxBox and a VM, as the backlog has
  it) needs the lab (T2) and a driver through the dev-eval hook; this soak is the part that could run offline now.
- **Everyone in the song the whole time.** No one leaves or joins mid-run except the late joiner at the end, no Driver or Admins-only mode,
  nobody answers a claim ask (each times out and is put back), no web page, phone or panel edits, no Hold or Bring into main, no other rooms.
- **No media beyond a small file per recording**: big copies (`copy_pending`), the cloud copy and catch-up's need list are out.
- **The shim's model of Syncthing** is per file with independent delays; conflicts (two computers writing one file) are counted, not modelled as
  `.sync-conflict` copies.
- **Security (review-later):** none of the signing, trust or size checks are exercised; `trust.claim_ok` is stubbed to true. A soak computer
  that sends forged or oversized events would be a natural next step.
