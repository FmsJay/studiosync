# rt-sync2c: phases 3 and 4 of the sync-core redesign (2026-11-27)

Builds `docs/rt/rt-sync2.md` section 9's phase 3 (the look and what it may delete) and phase 4 (track order as a rank per track) on top of
rt-sync2a's harness and rt-sync2b's judge. Nothing here was run in REAPER; the REAPER checks for James are below.

## Summary for James

- **A knob turned at an awkward moment now always goes out.** Two ways it didn't: you deleted track 1 in the same second (StudioSync took
  that for the project being opened again), or a bandmate's plug-in chain landed less than a minute before you turned a knob and the project
  was then opened again in its tab. Either way the knob stayed on your computer alone. Four of the long soak's seven failures were this.
- **Deleting half the song's tracks or more asks first** (your decision 2): "Delete 2 of the song's 3 tracks for everyone?" in StudioSync's
  bar, Yes / No. Until you answer nothing goes to the others; No, or no answer in 30 s, puts them back with everything on them. Deleting
  fewer doesn't ask. A delete-all asks too. The web page doesn't show this ask yet (phase 3, "(4), as built").
- **A deletion needs the thing to have been in your project.** A record of a track that this session never actually had (records merged in
  from a file, say) is put back, not sent as a deletion, however much you edited meanwhile.
- **Track order travels with each track** (decision 4, first half). Each track carries its place as a short code that sorts; a move gives the
  moved track a code between its new neighbours', so two moves made at once both stand and every computer, a late joiner included, sorts
  the same way. Your room switches over by itself: on its first quiet moment after the update each computer gives the tracks it made their
  codes (the log says "N track(s) given their place as a rank"). Older StudioSyncs in the room keep working from the order lists, which
  new ones keep writing. **Folders are unchanged**: depth still travels as before; parent + rank folders are phase 4b (see "Deviations").
- **The soak:** 237 seeds, baseline (with the stricter oracle below) 230. After phase 3: 234. At the end: **235**; the two left are the tempo
  map class (phase 5) and the markers class (markers as objects). No track-order failure anywhere. With one computer on the previous version:
  30 of 30 after phase 3, 28 of 30 at the end (one is that old computer's own Undo missing the fix below; one a moment in the soak's Undo
  check while an older computer's track settles).

## Commits

| Commit | What | Test that fails without it |
| --- | --- | --- |
| fc0081b | oracle: the soak's state hash names an item's track and a track's folder parent; `N.show` prints an item's track | (the baseline below) |
| 7a948e2 | phase 3: the project's instance told by its master track, not its first track (`W.order`, `mirror.watch`) | `test_0_60_rt_reopen` 1 |
| 077551c | phase 3: a new opening keeps a chain's knobs as it landed when it landed in the last minute (`W.order`) | `test_0_60_rt_reopen` 2 |
| e43a7f1 | phase 3: a deletion needs the object to have been here (`W.gone`, `mirror.seen_here`) | `test_0_60_rt_reopen` 3 |
| 2f1f835 | phase 3: deleting half the song's tracks or more asks first (`W.gone`, `claimask.big_delete`, Live sync one line); the soak's deletion gate | `test_0_60_rt_reopen` 4 |
| 969797d | phase 4: `lib/rank.lua` (new) | `test_0_60_rt_rank` 1 |
| 2f3605d | phase 4: ranks on tracks, the order sorted by rank, migration, hv 9 | `test_0_60_rt_rank` 2-7 |
| bd02384 | phase 4: ranks through Undo, Restore and old computers (five fixes, one commit: they share apply's few lines) | `test_0_60_rt_rank` 5, 8, 9, 10 |
| 1b8d408 | phase 4: the order comes from the versions held, not from the ranks left on the tracks (`mirror.held_place`) | `test_0_60_rt_rank` 11 |
| 58558b9 | phase 4: a receive pass that lands a track sorts the whole order by rank (`sync.receive`) | `test_0_60_rt_rank` 12 |
| 043acd4 | phase 4: `W.order` tells a room with ranks from the look's own track states (speed only: 750 fewer REAPER calls a look on rt-bigproj's song) | detcheck `--against 58558b9`: identical on 6 seeds |
| 41980c2 | phase 3: a track StudioSync's Undo or Restore makes again brings what a bandmate made on it while it was gone (`mirror.revert`, `contents_owed`) | `test_0_60_rt_reopen` 5 |
| (this doc) | docs/rt/rt-sync2c.md | |

Files: `lib/mirror.lua`, `lib/claimask.lua`, `lib/mirror_merge.lua` (merge_track: a missing rank is no change), `lib/rank.lua` (new),
`lib/page_health.lua` (small: the "another order" line), `lib/sync.lua` (the end-of-pass sort), `StudioSync - Live sync.lua` (one line:
`big_delete` in the watch call's opts),
`tests/test_0_60_rt_reopen.lua` (new), `tests/test_0_60_rt_rank.lua` (new), `tests/test_0_60_rt_edits.lua` (one line), `tools/soak/node.lua`,
`tools/soak/scenarios/tempo-env.json`. Shared files touched: Live sync (one added line in phase 3) and `lib/page_health.lua` (one message);
nothing of rt-uifix1/2's. `lib/files.txt` isn't edited (the release script adds `lib/rank.lua`). Nothing pushed (the brief said not to).

## 0. The oracle, and the new baseline

`tools/soak/node.lua` `N.state` hashes each item's text with its track oid in front, and each track's line with its folder parent; `N.show`
prints "on <track> |" before an item's text, so soak.py's 1e-9 noise allowance can't take two tracks for the same. No seed draws anything
different; only what the oracle sees changes.

Baseline: fc0081b (HEAD cb66750 plus the oracle), the 237 seeds of rt-sync2a's ranges at 150 edits, each seed by number from a clean clone
(`rt-sync2c_range.py`, scratch: soak's `run_once` per seed, 8 processes).

| Range | Seeds | Baseline (fc0081b) | Failed |
| --- | --- | --- | --- |
| 5000 | 58 | 56 | 5010, 5025 |
| 9000 | 60 | 57 | 9006, 9033, 9059 |
| 13000 | 60 | 59 | 13008 |
| 15000 | 59 | 58 | 15015 |
| all | 237 | **230** | 7 |

**What the stricter oracle revealed: nothing new on these 237 seeds.** The same seven fail as at rt-sync2b's last commit (3262be1), with the
same signatures: four knob-class (F differs), two timeline (9033, 13008), one undo probe (15015). The item-track class rt-sync2b found by its
side check (9001, 9006, 5000) was fixed in b540208 before this baseline, and the two stand-in cases (9002, 15011) are invisible to it: a grey
stand-in isn't in `mirror.scan`. A one-line oracle check for stand-ins left at quiet (any item still marked `band_arriving` once everything has
arrived) does catch both (9002: James's copy of a stand-in left on Gtr; 15011: one on Keys for an item the others no longer have, and one with
its id cleared on a "(yours, not sent)" track); it isn't committed, because it would need its own baseline and a fix (Recommendation 2).

## Phase 3: the look and what it may delete

### The knob class (5028; 5010, 5025, 9006, 9059)

Two causes, one symptom: a chain's knobs noted afresh as "how it loaded" (`mirror.fx_load_knobs`) at a moment when a knob had just been
turned, so for the next minute the chain's difference from the band's read as the plug-in loading and was never sent.

1. **Deleting track 1 was a reopen** (7a948e2). `W.order` told a file opened again in the tab by the first track's pointer going. Now a new
   opening is `mirror.on_open`'s (a new master track), as `sync.settled_for` and the timeline already tell it, and `mirror.watch` forgets
   `order_seen` there (so the first look follows the opening even when the opening look returns early through `W.keep_held`). `cc_seen` goes.
2. **A reopen inside the minute after a chain landed** (077551c). All four long-soak seeds were this, not (1): a bandmate's chain lands, a knob
   is turned, the file is saved and opened again in its tab before a look sees the knob. The first look of the opening re-noted the knobs
   (with the turned one). Now a chain the band's version landed on in the last `FX_LOAD_SECS` keeps the knobs it landed with; a chain that only
   reloads still reads back as it landed. Narrower than rt-converge's held one-liner (keep any existing note), which REAPER check 12 worried
   would keep a really reopened file's notes from before.

All four seeds pass at phase 3. The frozen `seed-5028` scenario already passed (it moved off the bug at rt-sync2b).

### Deletion evidence (rt-sync2 section 6)

| Part of section 6 | State |
| --- | --- |
| (1) the look against the projection | **not rebuilt** (below) |
| (2a) the same project as at the last look, by its master track | done: rt-guard's `on_open`, and now `W.order` too (7a948e2) |
| (2b) the object was there at that last look | done (e43a7f1), as "a look since this opening saw it, or StudioSync put it here since the last look" |
| (2c) an undo point of the person's since | rt-guard's `mirror.user_edited`, unchanged |
| (3) never "all of it" | rt-guard's `EMPTY_SECS` hold, unchanged (a delete-all with REAPER's undo point on top still goes, now after asking) |
| (4) a big deletion asks first | done (2f1f835) |

**(2b), as built.** `mirror.seen_here[proj]` gathers every object any look has seen since the project's opening (forgotten on a new opening);
an absence is judged the person's deletion only for an object in it or put here by StudioSync since the last look (`mirror.remembered`: an item
that landed and was deleted before the next look). "The last look" literally would have broken rt-guard's empty-project wait (the look after
an emptied project sees nothing), so it's "since this opening". Its value is narrow: rt-guard's guard already puts back what a new opening
lacks; this covers a record that turns up without its object outside an opening.

**(4), as built.** `W.gone` counts the tracks it is about to send as deleted (absences judged the person's) against the song's tracks (the
studio's tracks here plus those). At half or more it asks through `opts.big_delete` and holds them and everything on them, as a claim ask holds
an edit (`mirror.unsent`, `w.held_tracks`). `claimask.big_delete` is the ask: the words in the log and in the panel's bar (`claimask.bar`, Yes /
No, never a modal box), the answer carried by ExtState (`delete answer <proj>`) to Live sync's `claimask.tick`, as the Undo ask's is. Yes
sends; No, or no answer in `claimask.BIG_WAIT` (30 s), puts the tracks back with their items and parts. A different set of tracks is another ask.
Only callers that pass `big_delete` ask: Live sync does (one line); tests and Autostart's `sync.preload` don't (Autostart has no bar to answer
in, and its looks need rt-guard's evidence anyway). **The web page:** it shows claim asks (Release / Keep, the "claimask" topic in
`lib/webui.lua`, drawn by `lib/webui/play.js`) but no local confirm of any kind (StudioSync's Undo ask isn't there either). Adding one is a
"delete ask" in the presence model beside `pm.asks` plus a "bigdelete" topic answering `claimask.big_answer`; not built (web files are
rt-uifix's this round). **Small songs:** with one or two tracks, any track deletion is half; James's rule taken literally, so it asks.

**The soak's gate** ("never a deletion sent without a user undo point"): `node.lua` errors when a deletion goes out from a computer with no
edit of that person's in the last 90 s, outside an edit of theirs (Undo, Redo and Restore send their own), or after a reopen or an emptied
project. The soak answers big-deletion asks Yes on the next look. No seed in the phase 3 or 4 long runs tripped it.

**(1) not rebuilt.** The look still compares REAPER with the records, with containment as one special branch ("the item went with its
track"). Phase 2's judge already makes every receive, heal and catch-up land the projection, so what the look sends matches it in every case I
could construct; rebuilding `W.gone` around `mirror.lands(proj, mirror.judge(...))` would change no outcome a test or seed shows, at a judge
call per absence. Left for phase 9 (the look as a module), where it belongs with `W.gone`'s other branches.

### A track brought back by StudioSync's own Undo (5023, found by phase 4's gate)

The long soak at 58558b9 (and the mixed one) met seed 5023: Cee deletes Drums; Bee, not having seen it, records a take on Drums; the take
reaches Cee while Drums is gone there, so it is recorded gone with its track; Cee's Undo makes Drums again, and the take stays missing on Cee
alone. Only a receive pass judged what a returning track holds (`sync.contents_due`); a track `mirror.revert` makes didn't. Older than these
phases (phase 2's containment); these phases' writes changed the draws enough to show it. 41980c2 owes a remade track's contents to the next
receive pass. Seed 15015 (the undo probe, failing in every run so far) passes with it too.

### The grey stand-in leftovers (9002, 15011)

Not fixed. Traced: **9002 is look-side**: James copies an item whose audio is still arriving; the copy keeps the stand-in's id and
`band_arriving` mark; the look never sees stand-ins (`mirror.scan` skips them), and when the real item lands `apply` replaces one of the two, so
the copy stays grey for good on that computer. **15011 is receive/heal-side**: a stand-in made for a version that was then beaten by a
deletion, and one whose id was cleared when its track went to "(yours, not sent)"; neither is ever replaced or removed. Recommendation 2.

## Phase 4: ranks

### What it is

- **`lib/rank.lua`** (pure): base-62 fractions in `[0-9A-Za-z]`, at most 32 characters, never ending in 0; compared byte by byte (Lua's string
  `<` uses the C library's collation: a case-insensitive locale on one computer would order ranks differently); `between`, `spread`, `order`
  (ranked tracks by rank then oid, an unranked one right under the track its version names, oldest first).
- **On the track:** `P_EXT:band_rank`; `mirror.track_state` reads it as `rank`, so it travels in the track's version (an added field old
  computers ignore). A track's line has `r<rank>` at its end when it has one: **hash version 9** (`mirror.HV`). A track with no rank hashes as
  before, so nothing goes out again on update. `mirror.same_line` reads a version with no rank as the same track; `merge_track` reads a
  missing rank as no change.
- **Meant ranks only** (`mirror.rank_in`): every track version this version sends carries `rk`; a rank counts only beside it. An older
  StudioSync's Undo or Restore copies an old state whole, rank and all; that stale rank is ignored.
- **The order is worked out from the versions held** (`mirror.held_place`): each track's place is the rank its held version gives it
  (`mirror.rank_from`: its own, else the newest meant rank in what it builds on, so an Undo or Restore of a version from before ranks keeps the
  place), or none and the track its version sits under; only a track not sent yet uses the rank on it. That is the design's projection for the
  order: two computers holding the same versions sort the same, whatever is left on their tracks. `mirror.keep_order` sorts by it once the room
  has ranks (else goes to the order list as before) and puts each track's own rank back in line with it; it runs where it always ran (opening,
  the order heal, rt-guard's put-backs, the soak's late joiner) and now also **at the end of every receive pass that landed a track**
  (`sync.receive`, not mid-drag; keep_order waits for the tab in front, stopped and caught up), as the design's "Applying" says.
  `mirror.apply` places a landing track by the rank its version gives among the tracks here (`mirror.rank_above`); a new track is inserted
  straight there.
- **A move** (`W.order`): a track this person moved, or made here, gets a rank between its new neighbours' (as REAPER has them now) and goes
  out with it, with `moved` and `after` as before. StudioSync's Undo and Restore send the rank too: the one it has here, or for a move taken back
  one for the place it goes back to (`mirror.rank_at`).
- **Migration:** a room with no ranks gets them on its first quiet moment on the studio's list order (`mirror.order_heal` -> `mirror.rank_due`
  -> `mirror.rank_room`): each computer ranks the tracks its person made (and may change), by place (`rank.spread`, so whoever does it writes
  the same ranks), as StudioSync's own act (`auto`: no Undo step). A track whose maker never comes back stays unranked and sits under the track
  its version names; `rank_room` also ranks a maker's unranked tracks later, between their ranked neighbours, whenever `keep_order` finds the
  order right.
- **Old computers in the room:** they ignore ranks and follow `after`, `moved` and the newest order list, which new computers keep writing:
  on a move, after a pass that landed a move (as before), and now whenever `keep_order` finds the newest list saying another order than its
  ranks (old computers then follow it). A move from an old computer goes where its version says, as on the old computers, and leaves the track
  unranked until its maker's computer sends a rank; a merge with such a move on either side is placed by the `after` it merges.
- **`lib/page_health.lua`:** the "another order" line says it mends itself once the room has ranks.

### Deviations from the design, on purpose

- **Folders: parent + rank is not built (phase 4b).** Ranks are flat: they order the tracks; folders stay REAPER's depths as before (`depth`
  travels, `parent` travels unhashed as it always did). Building James's decision 4 for folders means parent in the hash, depth worked out
  from the tree on apply, and REAPER's indent / outdent read as parent changes; and in a mixed room, an old computer only learns a folder from
  depths, which a parent-only sender wouldn't send. That is its own phase with its own REAPER checks (section 10's folder risk). Within flat
  ranks, a folder moved by drag moves as its tracks, each given a rank in order.
- **The order heal stays** (`order_heal`, `ORDER_IDLE`/`ORDER_WAIT`, `order_apart_for`, the lists): it now sorts by rank, and old computers
  need the lists until the floor. With ranks it's the safety net, not the mechanism: every pass that lands a track sorts at once.
- **`sync.receive`'s sit-under order of a pass's tracks stays**: unranked tracks still need their anchor first; ranked ones are placed by rank
  whatever the order.
- **Live sync's one line** in phase 4 wasn't needed (the design's was removing the order heal's call).
- **Migration by maker**, not by every computer: every computer ranking every track at once doubled each track's versions and raced with
  moves; the maker is one computer per track, and tracks whose maker is away are handled as unranked.
- **No rank made up on receive.** An earlier cut gave an old computer's move a rank for its place on each new computer; two new computers
  holding different neighbours at that moment made different ranks (the mixed soak). Now only a computer that sends a version picks a rank.

### Known limits

- Two moves made at once by an old and a new computer can end apart until the order heal brings the old one to the newest list (old
  computers place by `after`, new ones by rank). The mixed soak below measures it.
- **While two computers stay in different orders, each rewrites the order list every order-heal round** (at most every 30 s): a new computer
  says its ranks' order in the list whenever the newest list says another. Harmless small writes, but the soak then never goes quiet: a
  disagreement shows as "settle" rather than "order differs". 1b8d408 removed the cause the soak found (a version recorded without being put
  in place); any other would show the same way.
- A move made in the minutes a room is being ranked can lose to the ranking: the ranking's rank (built on the version before the move) merges
  with the move's version, which has none yet. Every computer ends the same; the move is lost. The person moves it again.
- An Undo, in a ranked room, of a move made before the room was ranked restores the place by `after` (the rank for that place is worked out
  by the computer that undoes it and sent): fine. An Undo of a move made by an old computer is that old computer's to send.

## Gates

### Phase 3 (fresh clone of 6d2f839: 7a948e2..2f1f835 plus rt-uifix2's web commits)

| Check | Result |
| --- | --- |
| `python tests/run.py --no-luals`, local time | fails 1: `test_0_60_rt_drivebg` ("ps: no look at it over 20 ms", worst 43.5 ms; eight soak processes running). Alone, still under that load: failed twice (45.7, 65.2 ms); alone with the machine quiet: **ok**. drivebg times `lib/drivebg.lua`'s PowerShell worker, which phase 3 doesn't touch. `test_0_60_rt_bigproj` alone: ok |
| the same with `TZ=UTC0` | **fails 0** |
| `soak.py --quick`, detcheck (inside run.py) | ok, both runs |
| `soak.py --scenario all` | 14 of 14 as they say |
| long soak, 237 seeds | **234** (baseline 230): 9033, 13008 (tempo map / markers), 15015 (undo probe), all three in the baseline; 5010, 5025, 9006, 9059 pass |
| deletion gate | never tripped |
| mixed soak `--old cb66750` (Cee on the commit before my first), seeds 5000-5029 | **30 of 30** |

### Phase 4 (fresh clone of 41980c2, the last code commit)

| Check | Result |
| --- | --- |
| `python tests/run.py --no-luals`, local time | fails 1: `test_0_60_rt_drivebg` ("ps: the job never finished", eleven soak processes running); **alone: ok** (and `test_0_60_rt_bigproj` alone with `SS_TIMING_STRICT=1`: ok) |
| the same with `TZ=UTC0` | fails 1: `test_0_60_rt_drivebg` (worst 21.5 ms against 20, under the same load); **alone, `TZ=UTC0`: ok** |
| `soak.py --quick`, detcheck (inside run.py) | ok, both runs |
| `soak.py --scenario all` | 14 of 14 as they say (`tempo-env` now says passes: moved off, see phase 5) |
| long soak, 237 seeds | **235** (baseline 230): 13007 (E differs: the tempo map class, phase 5's; it failed at rt-sync2a's baseline too, passed by luck at rt-sync2b), 15057 (tempo map / markers: the timeline class, rt-sync2b Recommendation 7) |
| "order" failures | **0** (no "track order differs", no track `T` differs, in any seed) |
| deletion gate | never tripped |
| mixed soak `--old cb66750`, seeds 5000-5029 | **28 of 30**: 5023 (the take missing on Cee, the old computer: its own Undo, from before 41980c2, doesn't bring a remade track's contents; the new computers have it), 5017 (in the soak's Undo check, after Bee's Undo two new computers held an older computer's moved, unranked track in different places when compared; not traced to the line) |
| files_check / release_check | NOTE (lib/files.txt lacks `lib/rank.lua` until the release script runs), as for any new lib file |

### Every phase 4 run, in order

Each from a fresh clone of that commit, the 237 seeds and the mixed 5000-5029 (Cee on cb66750), seed by seed.

| Commit | Long soak | Its failures | Mixed | Its failures |
| --- | --- | --- | --- | --- |
| 2f3605d | (stopped at 76 seeds) | 5003, 13036, 15004 (T differs), 5007 (undo), 13007 (E) | 18 of 30 | 12 on track order |
| bd02384 | 221 | 13 never went quiet (5010, 5038, 5044, 9010, 9026, 9029, 9050, 13007, 13032, 13042, 13057, 15005, 15050), 15021, 15057 (timeline), 9023 (undo) | 28 | 5000 (undo), 5015 (never quiet) |
| 1b8d408 | 234 | 13007 (E differs), 15021, 15057 (timeline) | 29 | 5000 (undo probe, order) |
| 58558b9 | 234 | 13007 (E differs), 15057 (timeline), 5023 (I missing) | 28 | 5017 (undo probe, order), 5023 (I missing) |
| 41980c2 | **235** | 13007 (E differs), 15057 (timeline) | 28 | 5017 (undo probe, order), 5023 (the old computer's own Undo) |

### The phase 4 runs before the last (what each gate found)

At 2f3605d the long soak showed four new track-order failures (5003, 5007 undo, 13036, 15004) and the mixed soak 12 of 30 failing on order.
Traced: (5003, 13036, 15004) an Undo, by a new computer, of a version from before ranks went out with no rank and every other computer made
up its own; (5007) the same through the undo probe; (mixed) an old computer's Undo copying a stale rank back, ranks made up on receive for an
old computer's moves differing between new computers, and old computers following an order list the ranks had moved past. bd02384 fixed all
of them (each with a test part). Its own long soak (221 of 237) then showed 13 seeds that never went quiet: a claimer's answer to a rename
(`sync.set_back`) records the bandmate's version without putting it in place, the rank left on that track kept the computer in another order,
and bd02384's list writing made the disagreement endless. 1b8d408 takes each track's place from the version held. Its long soak: 234 of 237
(13007 E differs, the tempo class; 15021 and 15057 tempo map / markers, the timeline class) and the mixed soak 29 of 30 (5000: in the undo
probe two new computers held different orders inside the order heal's 120 s wait after the Undo's move landed, an older computer's
unranked track sitting elsewhere on one). 58558b9 sorts the whole order at the end of the pass that lands a track. Its run met 5023 (a take
missing after a track was remade by StudioSync's own Undo: phase 3's section above), fixed in 41980c2, which also took 15015 off the list.

## REAPER checks for James

All on the real computers after a release with these files. Keep a copy of the test song's folder first.

**Phase 3**
1. **rt-reopen's re-checks** (docs/rt/rt-reopen.md "rt-guard: REAPER re-checks" 1-5): an older file after a restart and in the same tab,
   closing or loading the tab, real deletions (by hand, the top track, Ctrl+Z / Ctrl+Shift+Z), a deletion with the tab behind. Nothing
   changes in what's expected, except a delete-all now asks first (check 4: answer Yes).
2. **Check 12, as built:** open a song with TONEX or Superior Drummer on the laptop, close the project and open it again in the same tab with
   Live sync running: nothing goes out for those chains. Then turn a knob from a control surface and delete track 1 within the same second:
   the knob reaches the others. Then: let a bandmate change that chain, within a minute turn a knob, save, and open the file again in its tab:
   the knob reaches the others; doing the same without turning a knob sends nothing.
3. **The master track on reopen** (read only, ReaScript console): `reaper.GetMasterTrack(0)` before and after File > Open of the same project
   in the same tab. They must differ. If REAPER hands back the same pointer, a reopen in the same tab isn't seen as one (rt-guard's guard and
   phase 3's knob rule both lean on it); tell me.
4. **The big-deletion ask:** in a 4-track song, select 2 tracks and delete: StudioSync's bar says "Delete 2 of the song's 4 tracks for everyone?
   (30 s) Yes / No"; the others keep them. Yes: gone everywhere. Again with No: back on yours with their items and plug-ins, nothing went. Again
   with no answer: back after 30 s. Delete 1 of 4: no ask. Ctrl+A, delete: asks.

**Phase 4**
5. **The switch-over:** after updating every computer, open the song: within a minute each computer's log says "N track(s) given their place as
   a rank" once (for the tracks its person made); Health shows nothing about order.
6. **Two moves at once:** the desktop drags Keys to the top while the laptop drags Drums to the bottom, within a second: the desktop, laptop
   and Mac end in the same order with both moves.
7. **A late joiner after moves:** open the song fresh on a computer that hasn't had it: same order as the others, before and after its first
   minute.
8. **Folders still work as before** (ranks are flat): indent a track into a folder, outdent it, drag a whole folder up: the others show the
   same folders and order. Then a folder moved on one computer while a child is dragged out of it on another, within a second: report what
   each computer ends with (the design's folder model, phase 4b, is what fixes any mismatch).
9. **An old-version computer in the room** (one computer kept on the previous release): moves made there land on the new computers at the same
   place and stay; moves made on a new computer land there; after a minute of quiet all three show one order.
10. **Undo of a move:** move a track, StudioSync Undo, Redo: every computer follows each step.

## What phase 5 should know

- **`mirror.HV` is 9 now, for tracks.** Phase 5 planned "hv 9" for items and automation (beats); it has to be 10. `hv` is one number for every
  kind, compared per event (`mirror.receive`'s drift check skips any event whose hv isn't this version's).
- **`tempo-env` moved off its bug** with phase 4's writes (its `today` is now `passes`, with a `moved_off` note): it is a frozen seed, not
  fixed. Write a hand-made scenario for the 15033 class before phase 5's work. The long soak still meets the class: 13007 (E differs) fails
  at the end of phase 4.
- **The timeline is still newest-wins** by the maker's clock: 9033 and 13008 failed through phase 3, 15021 / 15057 in phase 4's runs (the
  draws moved); rt-sync2b Recommendation 7, markers as objects.
- **15015** (rt-sync2b's "undo probe limit") passes since 41980c2: the remade track's contents were the missing part.
- **Ranks aren't times**: a tempo change moves no track and changes no rank. Nothing in phase 5 needs to touch `lib/rank.lua`.
- **The soak's oracle** now hashes an item's track and a track's parent (not its rank: the order is compared as the order).

## Recommendations (ranked)

Recommend only; none built here.

1. **Build phase 4b, folders as parent + rank**, before phase 5 if REAPER check 8 shows any mismatch: parent in the hash, depth from the tree on
   apply, REAPER's indent/outdent read as parent changes, a loop of parents broken by the newest change. Keep sending depth while old
   computers can be in a room.
2. **Fix the stand-in leftovers and add the oracle's stand-in check with a new baseline.** When an item lands on its stand-in, any other item
   carrying its id and `band_arriving` (a copy the person made) becomes a copy of the landed item with a fresh id (it then goes out as theirs);
   a stand-in whose version is beaten or whose id was cleared goes. The one-line check (`node.lua`: any `band_arriving` item at quiet is a
   double) catches 9002 and 15011 today.
3. **The web page's confirm for a big deletion** (and StudioSync's Undo ask, which isn't there either): a "local asks" list in the presence model
   and a topic that answers `claimask.big_answer` / `undo`'s ExtState. A person working from the web page while REAPER's window is hidden
   can't answer today, and no answer keeps the tracks: safe, but confusing.
4. **A floor for the big-deletion ask** (James to decide): with one or two tracks any deletion is "half". Ask only from 2 tracks deleted, or
   from 3 tracks in the song.
5. **Sort ids byte-wise everywhere the judge sorts** (`lib/judge.lua`, `merge_order`, `rank.order`'s oid tie-break already does): Lua's
   string `<` follows the C library's collation, and the determinism the judge relies on assumes every computer orders "a" and "B" alike.
6. **A second sign of a new opening** besides the master track pointer (REAPER check 3): if REAPER can reuse the pointer, a reopen in the same
   tab goes unseen. For instance a session token kept only in memory per project tab and compared with one written into the project's state
   at each look.
7. **The look against the projection** (section 6 (1)) with phase 9: `W.gone` asking `mirror.lands(mirror.judge(...))` for each absence, its
   special branches folded in.
8. **Retire `rank_room`'s "by maker" for a "by anyone, once" rule** if James's rooms often hold tracks whose maker has left: those stay
   unranked (correct, but they follow `after`, so they're the one place the old order rules still decide).

## Review later (security)

- `rank` is bandmate data: `rank.valid` (1-32 characters of `[0-9A-Za-z]`) on every read; anything else is no rank. A forged rank can move
  only what any change can move, and only from a version that carries `rk` (any computer can set it: same trust as every field today).
- `claimask.big_delete`'s answer comes only from this computer's own ExtState (the panel's bar), never over the link.
- `mirror.seen_here` is per project tab, in memory, one entry per object seen: on a 4,000-item song about the size of `mirror.looks`.

## What I didn't check

- Nothing was run in REAPER.
- The web page's ask (not built), folders under ranks (REAPER check 8), and REAPER's master track pointer on a reopen (check 3).
- Two old computers in a mixed room (only Cee was old), and a room migrating while moves happen.
- The 9002 / 15011 stand-in fixes (analysis only).
