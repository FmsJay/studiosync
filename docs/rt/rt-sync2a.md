# rt-sync2a: phases 0 and 1 of the sync-core redesign (2026-11-27)

Builds `docs/rt/rt-sync2.md` section 9's first two phases. **Phase 0** is the harness: a determinism check, scripted scenarios and a
mixed-version soak. **Phase 1** moves the pure merges out of `lib/mirror.lua` into `lib/mirror_merge.lua`, with property tests, and
changes nothing they do. Nothing here was run in REAPER and nothing needs to be: phase 0 touches only `tools/soak/` and one step of
`tests/run.py`, phase 1 is a move whose soak output is byte-identical to the commit before it.

Files: `tools/soak/soak.py`, `tools/soak/node.lua`, `tools/soak/detcheck.py` (new), `tools/soak/scenarios/*.json` (new, 14),
`tests/run.py` (one step); `lib/mirror_merge.lua` (new), `lib/mirror.lua`, `tests/test_0_60_rt_merge_props.lua` (new). No shared file
touched. `lib/files.txt` isn't edited: `tools/make_index.py` adds `mirror_merge.lua` at release (rt-sync2 section 9).

| Commit | What |
| --- | --- |
| 0eed6ad | phase 0: detcheck, scenarios, `--old`; detcheck's quick form in `tests/run.py` |
| 100ef13 | phase 1: `lib/mirror_merge.lua`, the property test |
| (this doc) | docs/rt/rt-sync2a.md |

## Phase 0: the harness

### `--detcheck` (tools/soak/detcheck.py)

A seed run twice, each time in fresh Lua states (Lua seeds its string hashes per state, so anything that follows `pairs` order shows), and
everything each computer wrote or sent compared: every file (its path and a hash of its contents), every link message, and each computer's
song at the end. rt-converge's scratch version compared paths only; this one compares contents too, and still finds two runs identical.

```
python tools/soak/detcheck.py                       # the quick check: seeds 1 and 2 at 40 edits, two runs each (~20 s); in tests/run.py
python tools/soak/detcheck.py --edits 150 5001 9006 # those seeds
python tools/soak/detcheck.py --against <commit> 1 2 3   # this code against that commit's (git archive of lib, tools/soak, tests/fixtures)
python tools/soak/soak.py --detcheck --seed 17 [--against <commit>]   # the same, from soak.py
```

`--against` is phase 1's gate and every later pure refactor's (phase 9): a move must write exactly what the commit before wrote. On a
difference it prints the first entry where the two runs part (time, computer, what, where).

### `--scenario <file | folder | all>`

A scenario is a JSON file in `tools/soak/scenarios/`: edits at given times on given computers, network events, and checks of what each person
meant (the oracle only sees that the three agree, and an edit lost everywhere converges). The format is in `soak.py`'s docstring:

- `seed` (the network's and the computers' randomness), `faults` (`"clean"`, or Faults fields to change, e.g. `{"clean": true, "link_max":
  0.01}`), `mode` (`"open"` Claims, `"everyone"` Open), `undo_probe`;
- `edits`: `{t, node, kind, r}` (one of the driver's edits with its six numbers) or `{t, node, lua}` (code run on that computer, with
  `track(name)`, `item(name)`, `EDITS`, `reopen(F.save())`, `N`, `sync`, `mirror`, `reaper` at hand; returning nil means "not the person's
  edit": Live sync's edit count doesn't move). Two scenario-only kinds, never drawn by the seeded driver: `empty` (the tab read with no tracks
  and every record) and `lua`;
- `net`: `{t, until, offline: name}` (that computer's Syncthing paused and its link lanes down), `{.., pause: name}`, `{.., link_down: [a, b]}`;
- `checks`: `{on: "all" | [names], what, lua}`, asserts run on each computer once the song has settled, before the late joiner;
- `today` (`"fails"` or `"passes"` at the commit it was written at) and `signature` (the failure it shows then).

A run passes when every scenario does what it says. A scenario that starts passing prints "if a fix made it pass, set its today to passes":
the phase that fixes it flips the word in the same commit.

```
python tools/soak/soak.py --scenario all
python tools/soak/soak.py --scenario tools/soak/scenarios/item-track-merge.json --trace
```

### `--old <commit>` (the mixed-version soak)

`--old-nodes` (default `Cee`; comma-separated) load `lib` from a `git archive` of that commit (a temporary folder, removed at exit); the stand-in
REAPER and the driver stay this checkout's. Works with `--quick`, `--long`, `--seed` and `--scenario`. With every computer old it also tells
whether a scenario failed before a fix: that's how the table below says which commits each passing scenario guards
(`--old 508cf43 --old-nodes James,Bee,Cee --scenario ...`). Tried with 508cf43 (before rt-guard), 9018131 (before rt-fix9) and HEAD; a lib
from before rt-converge lacks `mirror.retime`, which the stand-in's tempo move calls.

### What node.lua gained

`SOAK_LIB` (the lib folder, for `--old`); `reopen(snap)` as a function (the driver's `reopen` edit and scenarios share it; it tolerates a lib
without `mirror.opened`); `eval`'s environment with `E`, `undo`, `N`, `EDITS`, `reopen`, `track(name)`, `item(name)`; the `empty` and `lua`
edits. The seeded driver's table (`soak.py` `EDITS`) is unchanged, so every seed draws exactly what it drew before (detcheck `--against`
the commit before shows it).

### The scenarios

Run at the phase 0 commit (0eed6ad) and again at phase 1 (100ef13): the same results. "Fails before" is `--old <commit> --old-nodes
James,Bee,Cee`. All 14 take about 90 s (`--scenario all`).

| Scenario | What it reproduces | Phase that should fix or keep it | Today | Fails before |
| --- | --- | --- | --- | --- |
| `item-track-merge` | rt-sync2 Recommendation 2 / judge step 5: Bee moves Bass 1 to Gtr while offline, James nudges it (newer rev) | 2 | **fails**: Bass 1 stays on Bass on all three, and each log says "both changes are kept". Reproduced, so the design's reading of `event_file` is right | |
| `seed-9058` | the restore race (5057, 9029, 9058): 9058 drawn from the old table, shrunk 150 to 130 edits | 2 | **fails**: Keys A muted on James, not on Cee, nothing pending | |
| `restore-race` | the same class by hand: James's Undo 0.4 s after Bee's edit of the same item, automation and plug-ins | 2 (keep) | passes, in all of 100 network seeds tried, and in 40 more with Cee offline across each race | |
| `seed-15043` | today's 15043, shrunk to 140: an item James recorded missing on Cee after Restores and a track deletion | 2 (likely: containment) | **fails** | |
| `late-joiner-midi` | 15044's class: Keys A's notes edited apart by all three, Bee offline; the late joiner must build the same merges | 2 (keep) | passes | |
| `seed-5028` | 5028 drawn from the old table, shrunk to 85: a knob turned around a new opening never sent | 3 | **fails**: ReaComp's knob differs between James and Bee | |
| `empty-project` | rt-guard's A (Cross Test, 11-23): the tab read with no tracks and every record | 3 (keep) | passes | 508cf43: every track and item sent as deleted |
| `empty-then-load` | A, then the file in place 1.5 s later: no deletion, no track put back twice | 3 (keep) | passes | 508cf43: as above |
| `reopen-older-file` | an older `.rpp` opened in the tab (stale versions), then a file without Keys (rt-guard's B) | 3 (keep) | passes | 508cf43: Keys and its items sent as deleted (the stale-versions part passes there too) |
| `late-joiner-order` | 9034's class: today's seed 9034 (fails the same way by coincidence), whole, it didn't shrink | 4 | **fails**: Dee's tracks under other neighbours than James's | |
| `tempo-env` | 15033's class: today's 13007, shrunk to 55: Drums' automation and two items on another tempo map on Cee | 5 | **fails** | |
| `rename-redo-claim` | 127's class: James's Redo of a rename crossing Bee's hand claim on the old name | 6 | **fails**: "Bee has claimed Drums: James's rename to T1 is put back" on all three (sync.set_back) | |
| `rename-redo-autoclaim` | 6006's class: the same crossing Cee's fader move (an auto-claim) | 6 (keep) | passes (soft_ok merges the fader and the rename) | |
| `rename-vs-fader` | rt-r4 bug A: a rename unseen by any look when a bandmate's fader change lands (James holds his receives, then receives right after renaming) | (rt-fix9; keep) | passes | 9018131: the rename lost on all three |

**The design's seed numbers no longer reproduce as they were.** rt-guard added the `reopen` edit to the driver's table, which changes every
seed's draws, so "seed 5057" today is another run. Drawn from the old table (a scratch copy of `make_edits` without `reopen`) at bf500ba:
5028 and 9058 still fail (frozen as `seed-5028` and `seed-9058`, shrunk); 5057, 9029, 9034, 127, 6006, 15033 and 15044 pass. Their classes are
carried by the other scenarios: the restore race by `seed-9058` (and `restore-race`, which passes in 140 network seeds: the class needs a
particular arrival order at the third computer, which rt-converge read from the records but didn't pin down), 9034 by `late-joiner-order` (today's seed 9034, which fails the same way by coincidence),
127 by `rename-redo-claim`, 15033 by `tempo-env`, 15044 by `late-joiner-midi` (passes).

**Fragile by nature:** a scenario frozen from a soak seed keeps the seed's network randomness, which is drawn in the order the code drains
and delivers. A change anywhere before the failure can move it off the bug without fixing it. The hand-written ones (`faults: "clean"`, the
race made with `net` events) don't have that problem. A frozen one that starts passing needs the long soak's word before it's called fixed.

## Phase 1: `lib/mirror_merge.lua`

Moved as it was (a script cut the line ranges, checked by their text, and rewrote only `mirror.side3(` / `mirror.merge_midi(` / `function
mirror.X` to `M.`): `merge_item` with `elements`, `TIMING`, `ITEM_LEVEL`; `side3`, `merge_keyed`, `move_pairs`, `moved_twice`, `keyed_lines`;
`midi_read`, `midi_cmps`, `note_keys`, `note_parts`, `note_changes`, `merge_midi`; `env_units`, `merge_env`; `TRACK_TOGETHER`, `merge_track`;
`fx_units`, `merge_fx`; `pieces`, `pieces_changed`; and the two text helpers they use, `portable` and `restless_key` (mirror.lua takes them
back as locals). 767 lines left `mirror.lua` (7,859 to 7,101); `mirror.lua` sets `mirror[k] = merges[k]` for the nine public names, so no
caller or test changed. Its top-level local names go from 167 to 154 (fourteen out, `merges` in; Lua's limit is 200; check_locals: ok).

**Kept in mirror.lua, on purpose:**
- `mergeable`, `merge_state`, `MG`, `MERGE_SINCE`, `MERGE_MG`, `MERGES`: which versions may merge is policy, and seven tests replace
  `mirror.MERGE_SINCE` whole (`tests/test_0_60_rt_edits.lua`, `_merge`, `_merge_p1`, `_undo`); moved, they'd read the module's copy and the
  tests would silently stop testing what they say.
- `clashes`: not pure (it reads events through `mirror.event_file` and the clock), and it walks `base_ev` chains the way phase 2's index will.
  It belongs with `lib/evindex.lua` or the judge, not here.

**tests/test_0_60_rt_merge_props.lua:** random versions of five kinds (an audio item in one or two takes, a MIDI item, automation in one or
two envelopes, a track's settings, a plug-in chain), each edited one to three times apart by two people, 200 cases a kind from a fixed
pseudo-random sequence (well under a second). For every merge: (1) a version merged with itself, or with an unchanged other side either way
round, is itself, with no clash; (2) every piece (`mirror.pieces`) only one side changed comes out as that side has it, one neither changed as
the base has it, one both changed alike as both have it, and nothing appears from nowhere without a clash; (3) the same merge twice, or a
track's settings built in another order, comes out the same; (4) `mirror.X` is `mirror_merge`'s and `merge_state` picks the same merge.
Mutation checks: making `side3` always pick the winner, or `merge_track` keep the base's fader, fails it at once.

Where property 2 doesn't hold by design (asked only where it does, with the reason in the test): a take both re-recorded keeps the loser's as
one more take, whose timing lines join the item's single timing piece; a plug-in removed by one side and changed by the other stays (a clash)
and the chain's order piece with it; a point the loser moved that the winner changed is left out with a clash (merge_env's `moved_twice`); and
MIDI notes, which are paired across moves so a note can come out made of both sides' changes (asked instead: the merge reads back as notes).

**What the property test found:** the stand-in REAPER (`tests/fixtures/editreaper.lua`) writes an item's P_EXT as `<EXT`; REAPER writes
`<EXTI` (mirror.lua's own comment, `normalize_item`), and `merge_item`'s `ITEM_LEVEL` lists `<EXTI`. So in every soak and test that merges an
item, the item's id block is treated as a line of its first take, and a take copied for a both-re-recorded clash carries the item's
`band_oid` block inside it. In REAPER it doesn't. Not changed (the fixture is shared and phase 1 changes nothing); Recommendation 1.

## Gates

Each from a fresh clone of the commit (`git clone` of the shared repo into my scratch folder, that sha checked out). The machine was busy
throughout (my four long-soak processes, other agents' work), which is what the two strict timing tests failed on; each was then run alone.

| Check | Phase 0 (0eed6ad) | Phase 1 (100ef13) |
| --- | --- | --- |
| `python tests/run.py --no-luals`, local time | fails 1: `test_0_60_rt_bigproj` (a quick look 48 ms against its 42 ms budget, under load); alone (with `test_0_60_rt_drivebg`): ok | **fails 0** |
| the same with `TZ=UTC0` | fails 1: `test_0_60_rt_drivebg` ("the slow job took 2.0 s", under load); alone (with `_bigproj`): ok | fails 1: `test_0_60_rt_drivebg` (a look at 38.8 ms against 20, under load); alone (with `_bigproj`): ok |
| `soak.py --quick` (inside run.py) | ok soak, both runs | ok soak, both runs |
| `detcheck.py` quick (inside run.py) | ok, both runs | ok, both runs |
| detcheck `--against` the commit before | c68a293: the same on seeds 1-3 at 60 edits (the driver draws what it drew) | 0eed6ad: **the same** on seeds 1-6 at 60 edits and 5001, 9006, 13007, 15043, 9034 at 150 (four of those fail the soak: identical failures too) |
| `--scenario all` | 14 of 14 as they say | 14 of 14 as they say, the same signatures |
| mixed soak `--quick` | | `--old 0eed6ad` (Cee on phase 0's lib): 5 of 5 seeds |
| 20-minute long soak, four ranges | identical to before on every seed (below) | identical to before on every seed (below) |

For contrast, `--old 508cf43 --quick` (Cee on the lib from before rt-guard) fails 3 of 7: the old computer sends deletions after a reopen,
as that version did. That's what a mixed room with an old computer looks like, and what phase 2's mixed soak will show for merges.

## The long soak, before and after

`python tools/soak/soak.py --long --minutes 20 --no-shrink --first <range>` (150 edits a seed), the four ranges of rt-converge's last table
run side by side, each from a clean clone. "Before" is 88282e1, whose sync code is bf500ba's and the phase 0 parent's (c68a293 changed only
web files). The soak is deterministic, so a seed passes or fails the same way at every commit that writes the same: the phase 0 and 1 runs did fewer
seeds in their 20 minutes (the machine was busier), so the seeds they missed were run one by one afterwards (`--seed N --edits 150`, the
same run) to complete the set. Every seed ended the same way at all three commits.

| Range | Seeds | Before (88282e1) | Phase 0 (0eed6ad) | Phase 1 (100ef13) | Failed (the same seeds in all three) |
| --- | --- | --- | --- | --- | --- |
| 5000 | 5000-5057 | 56 of 58 | 56 of 58 (54 in 20 min + 4 run after) | 56 of 58 (54 + 2) | 5001, 5025 |
| 9000 | 9000-9059 | 55 of 60 | 55 of 60 (56 + 4) | 55 of 60 (58 + 2) | 9006, 9027, 9034, 9036, 9059 |
| 13000 | 13000-13059 | 58 of 60 | 58 of 60 (56 + 4) | 58 of 60 (59 + 1) | 13007, 13014 |
| 15000 | 15000-15058 | 58 of 59 | 58 of 59 (56 + 3) | 58 of 59 (58 + 1) | 15043 |
| all | 237 | 227 (95.8 %) | 227 | 227 | 10 |

These aren't comparable with rt-converge's 97-100 % (5000: 69 of 71 at row 48): rt-guard's `reopen` edit changed every seed's draws and added
a kind of edit that opens projects anew, which the 5028 class feeds on.

**Today's ten failures, by class** (each signature from the run; traced as far as said):

| Seed | Signature | Class | The phase that should end it |
| --- | --- | --- | --- |
| 5025, 9006, 9059 | converged: F differs | a plug-in knob never sent on one computer, with `reopen` edits in the run: 5028's class (`seed-5028`) | 3 |
| 5001 | converged: F differs | a plug-in chain differs on one computer; no reopen in the run (a track brought back by Undo, a knob turned, Undo/Redo after): not traced | 3 or 7 |
| 9027, 9034, 13014 | log: T differs | the late joiner places tracks under other neighbours (9034's class, `late-joiner-order`) | 4 |
| 13007 | converged: E differs | automation and two items on another tempo map on one computer (15033's class, `tempo-env`) | 5 |
| 15043 | converged: I missing | an item missing on one computer after Restores and a track deletion (`seed-15043`), likely containment | 2 |
| 9036 | undo | Cee's Undo then Redo didn't bring an item back | 7 |

## Where rt-guard already covers phase 3

rt-sync2 section 6 lists five parts; rt-guard (b34f25e, 148f9e4) built most of three of them, differently:
- **(2c) an undo point of the person's behind a deletion:** built as `mirror.user_edited` (Live sync's count moved by them in 30 s, or a new
  undo point of someone's on top), the auto-claim test, plus REAPER's own undo point fresh on top for a project with no tracks.
- **The first look never deletes:** built (`mirror.on_open`: this script's first look at a project, or a new master track).
- **(2a) the same project as at the last look, told by its master track:** half built. `mirror.on_open` tells a reopen by the master track,
  so a new opening forgets the old project's edit state and guard marks. But `W.order` and `fx_load_knobs` still take "the first track's
  pointer is gone" for a reopen, which is exactly 5028 (`seed-5028` fails): phase 3's remaining part.
- **(3) never "all of it":** built differently. An empty project sends nothing for `mirror.EMPTY_SECS`, then the studio's tracks are put back;
  a delete-all with REAPER's undo point fresh on top still goes (James's cross-test step 1). Section 6 said "whatever the undo list says".
- **(2b) the object was there at the last look** and **(4) ask before a big deletion** (James's decision 2: half the song's tracks or more):
  not built. Nor is the look against the projection (that needs phase 2's judge).

The `empty-project`, `empty-then-load` and `reopen-older-file` scenarios pin what rt-guard covers (each fails at 508cf43, the commit before it).

## What phase 2 should know

- **Its gate scenarios:** `seed-9058` and `item-track-merge` should flip to passes (flip `today` in the same commit); `seed-15043` probably
  (containment); `restore-race` and `late-joiner-midi` must keep passing. The design's own gate ("5057, 9029, 9058 at 150 edits") can't be
  run as written: those seed numbers draw other runs since rt-guard. Use the scenarios and the long soak's ranges.
- **The merges to call** are `lib/mirror_merge.lua`'s (pure, no `mirror`), through `mirror.merge_state(kind, base, winner, loser,
  loser_name)` for the dispatch. Which versions may merge (`mirror.mergeable`, `MERGE_SINCE`, `MERGE_MG`) stays in `mirror.lua` because
  tests replace `mirror.MERGE_SINCE` whole: read it through `mirror.` or take it as an argument, never copy it into a local.
- **`event_file` copies the winner's fields** (`track`, `files`, `user`, `retimed`...) and merges only `state`. `item-track-merge` shows the
  cost; when `track` becomes an attribute, the merged version's words (`v.clashed`, "both changes are kept") should say what was kept.
- **Revs inside one edit session stay the same** (`SESSION_SECS`, 30 s): a person's quick re-edit of their own version keeps its rev, so
  a re-edit within 30 s of your own last change to a thing loses to a bandmate's change built on the same version (their rev+1) even when
  yours is later. `item-track-merge`'s first draft (James's nudge 28 s after he made the item, rev 1) lost to Bee's earlier move (rev 2) and
  passed; the scenario nudges at 60 s.
- **`clashes`** (the claim check's walk down `base_ev` chains) stayed in `mirror.lua`: it reads events and the clock. It walks ancestry the
  way `lib/evindex.lua` will; consider moving it there rather than leaving a second walk.
- **The soak today is deterministic** on every seed tried (two runs in fresh Lua states, contents compared: quick seeds, 1-6 at 60 edits,
  5001, 9006, 13007, 15043, 9034 at 150). The judge must keep it so (sort by id wherever it iterates); `tests/run.py` now fails if the quick
  pair differs.
- **The mixed soak:** `python tools/soak/soak.py --old 100ef13 --long --minutes 20 --first 5000` (Cee on phase 1's lib) is the comparison
  phase 2 asks for; the design expects races made while old and new were both in the room to end apart, so categorise those, don't fix them.
- **The replay comparison** (phase notes: the soak's event folders through the old receive and the judge): `N.shared_files()` already hands
  over a computer's whole studio folder (the late joiner is built from it); dump it at quiesce for a few seeds and replay.
- **What fails today, by class** (the long soak below): a plug-in chain differing on one computer is now the most frequent failure (4 of
  10; three of them after a `reopen`, 5028's class), because rt-guard's `reopen` edit makes new openings common. That's phase 3, but if phase
  2's numbers look noisy, that's why.

## Recommendations (ranked)

Recommend only; none built here.

1. **The stand-in REAPER should write an item's P_EXT as `<EXTI`, as REAPER does** (`tests/fixtures/editreaper.lua`, shared by many tests).
   Today every soak and test merge treats the item's id block as a line of its first take, and a take copied for a both-re-recorded clash
   carries the item's `band_oid` block inside it, which REAPER never sees. The soak's merges are subtly not REAPER's. A small change, but
   it can move item states in every test that shares the fixture and every soak seed's run: do it at a phase boundary, with a new baseline.
2. **Merge an item's track as an attribute** (rt-sync2 Recommendation 2), now reproduced by `item-track-merge`; and make the merged version's
   words come from what the merge really kept (here every log said "both changes are kept" while Bee's move was lost).
3. **Bring phase 3's master-track instance test forward, or ship rt-converge's held one-line 5028 patch with REAPER check 12.** The 5028
   class is the long soak's commonest failure since the `reopen` edit (4 of 10 failures), and it's silent: a knob never sent, on one computer.
4. **Record the network schedule in a scenario, not only its seed.** A scenario frozen from a soak seed keeps the seed's random delays, drawn
   in the order the code drains and delivers, so any change before the failure can move it off the bug. Recording each delivery's delay by
   (writer, path, nth write) and replaying that would make `seed-9058`, `seed-5028` and the rest robust to unrelated changes.
5. **Let a soak pass receive before it looks, sometimes.** `N.pass` always looks first, so the soak never meets "a bandmate's change lands
   before any look saw mine" (rt-r4's bug A) except by scenario; Live sync's look and receive run on their own timers. It changes every
   seed's draws, so do it with a new baseline.
6. **Shrink faster:** a shrink try runs the whole oracle, late joiner and undo probe included (10-20 s); 20 minutes took 9034 nowhere and
   9058 from 150 to 130. Skip the undo probe unless the signature is "undo", and stop at the first failing check.
7. **`--scenario all` in `tests/run.py`** once it's under 30 s (about 90 s today; the three frozen 130-150-edit ones are most of it).
8. **Take merge policy out of module state.** `mirror.MERGE_SINCE` is reassigned whole by seven tests; the judge should receive "which
   versions may merge" as an argument, so a test can't change it for every later test in the same Lua state.
9. **An item's timing piece covers every take** (`pieces("item")`'s `\0timing`), so a take added by a clash reads as a timing change to
   `clashes`; and a chain's `\0order` piece moves when a plug-in removed by one side stays because the other changed it. Both make the claim
   check ask a little more than it needs. Low.

## Left, and not checked

- Phase 2 onwards (the judge), as the brief says.
- The design's 5057, 9029, 127, 6006, 15033 and 15044 no longer fail drawn as they were; their classes are carried by other scenarios
  (table above), and `restore-race` (hand-made) doesn't reproduce the restore race in 140 network seeds, Cee offline or not.
- `seed-15043` and the long soak's 9036 (an Undo then Redo that didn't bring an item back: phase 7's class) and 5001 (a chain differing with
  no reopen in the run) weren't traced to the line.
- `--old` against libs from before rt-converge, and a mixed long soak (only quick checks and scenarios were run mixed).
- Nothing was run in REAPER; nothing here needs a REAPER check (the soak harness and a pure move).
- Review-later (security): none new. `--old` archives a commit of this repo; scenarios run Lua from files in the repo inside the soak's own
  Lua states only.
