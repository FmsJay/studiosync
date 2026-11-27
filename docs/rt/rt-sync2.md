# rt-sync2: the sync core redesigned (design only, 2026-11-27)

rt-converge (`docs/rt/rt-converge.md`) took the convergence soak from 7 % to over 97 % of seeds by teaching each code path what another
already knew, and ended with ten recommendations. This file designs the top ones as one thing. **Design only: no code in `lib/` was
written, changed or run.** rt-guard is editing `lib/mirror.lua`, `lib/sync.lua` and `lib/undo.lua` right now (the guard rt-reopen asked
for); the build starts after that lands, and phase 3 below makes its guard structural. Line numbers are at 3ffc001 and will move.

Read with: rt-converge (all rounds, Recommendations 1-10, rt-r4..r7), rt-soak, rt-reopen, rt-fix6a, rt-edits, rt-claims, rt-linkmove
round 5 (the hub election: "every computer must elect from the same inputs").

## Summary for James

Five changes, one idea: **the song is worked out from the list of changes, the same way on every computer.** Today four or five places
each decide what a track or item is, from whatever that computer holds at that moment. They disagree when things arrive in another order,
and 11 of rt-converge's 38 code fixes were one of them being taught what another already knew.

1. **One judge.** One small function says what each object is (track, item, plug-ins, automation, sends), from that object's own changes
   and nothing else. Receiving, catching up, healing, the look, Undo and Restore all ask it. Arrival order stops mattering because nothing
   looks at it.
2. **Times in beats.** Items and automation travel in quarter notes as well as seconds, so REAPER's own tempo maths places them. A tempo
   change is one change, not one per item. The 15-second tempo window and the re-sending go.
3. **A rank per track.** Each track carries its own place as a short code that sorts. The order lists, the order heal and its three timers
   go. A late joiner sorts and is right.
4. **No refusing on receive (needs your yes).** Claims are still kept where edits are made (asks, holds and put-backs, unchanged for
   anyone on a current StudioSync). What changes is that a change that has arrived is never held back for a minute any more. The cost: an
   old or modified StudioSync's edit to your claimed track lands at once instead of after a minute. It lands today too.
5. **Undo from what each change was built on**, timers turned into facts, a Health check that compares what each computer's song *is*
   rather than only which changes it holds, and `mirror.lua` split into modules one step at a time.

What you'd notice: no minute-long gaps where computers show different things, fewer "both changes are kept" surprises after races, a tempo
change that reaches everyone as one change, track order that never drifts, and Health able to tell "same changes, different song" (a bug)
from "not caught up yet". The 11-23 track deletion becomes impossible by design (section 6), not just guarded against.

Eleven phases (0-10), each landing green on its own: full suite, quick soak, and a long soak at least as good as before. About 18-22
agent-days plus your REAPER checks. Your decisions are in section 11.

## The idea: log, judge, projection

```
events (the folder + the link's inbox)
   |  index: per object, its versions
   v
judge: settled(versions)  ->  one version per object: a change, a merge, or gone
   |  projection: containment (an item is in the song only if its track is) + ranks (the order)
   v
what this REAPER should hold  --apply, after any per-object wait-->  REAPER
                                                                      |
REAPER  --look-->  differences from what's held: the person's edits (sent) or REAPER's own readings (not)
```

- **The judge's inputs come only from the changes themselves:** ids, `base_ev`, `rev`, `hlc`, `gone`, the state. It never uses this
  computer's clock, how long anything took, which change arrived first, the claims files as they read today, or Lua's table order. This is
  the hub election's rule from rt-linkmove round 5, applied to the whole song.
- **Waits are per object, and they only delay.** An unsent edit here, media still arriving, the tab behind, playing or recording, the part
  open in the MIDI editor, a chain inside `FX_SET_GAP`: each holds back *when* the judge's answer is put in place, never *what* it is.
- **The invariant:** two computers holding the same set of changes, with no waits, hold the same song. The soak's oracle checks it at the
  end of a run. The judge's property tests check it in milliseconds for any arrival order (phase 1).

## 1. One judge

### Inputs and outputs

```
judge.settled(vs, read) -> s
  vs    every readable version of one object found here: plain changes from the folder and the link's inbox (lib/evindex.lua),
        each { id, oid, obj, rev, hlc (or time + user), base_ev, gone, track, state (read on demand), mg, format }.
        Never one too new for this version (sync.too_new): those wait for the update, as today.
  read  id -> a change or a merged version (today's mirror.event_file: plain files cached, merges rebuilt from their sides)
  s     { v        = the version every computer ends on: a change, a merge "m(a&b)", or nil when vs is empty
          gone     = v.gone
          complete = false while a version the answer needs isn't here; s.missing = their ids (for the need list)
          leaves, beaten = ids, for History ("lost to a deletion") and Health }
```

The judge is pure: no REAPER calls, no clock, no module state except `read`'s cache. It lives in `lib/judge.lua`.

### The rule, step by step

1. **Ancestry.** A version builds on its `base_ev` and, if it is a merge, on both sides. `descends` works as today (a walk of at most 400
   steps, stopping below the target's `hlc`). If a walk needs a version that isn't here and isn't old enough to be trimmed (step 6), the
   answer is incomplete.
2. **Leaves.** The leaves are the versions nothing else here builds on. Several leaves means changes made apart.
3. **A deletion beats what didn't see it.** A version is beaten when some deletion here is missing from its ancestry, meaning it was
   made without seeing that deletion. Beaten versions leave the race whatever their rev or clock, and so does anything built only on them.
   A restore (an Undo of the deletion, a Restore, Use mine) builds on the deletion, so it isn't beaten. **This is one rule for every
   kind.** Today `RACES` covers only items and tracks, so automation and plug-ins raced by clock, which is one cause of 9029. After this
   step the leaves are either all deletions (the object is gone) or all edits that saw every deletion.
4. **One edit leaf** is the object.
5. **Several edit leaves are merged** as today, from the leaves alone. `merge_order` takes them oldest first, each newer one winning where
   both changed the same thing (newer means rev, then `hlc`, then name). The merge runs on the version both build on (`common_base`) and
   goes attribute by attribute for each kind: `merge_item` per line and block, `merge_midi` per note part, `merge_env` per envelope and
   point, `merge_track` per setting (rank and parent included, section 3), `merge_fx` per plug-in. The merged id `m(...)` names its leaves,
   so every computer builds the same merge under the same name.
   **New:** an item's `track` (which track it sits on) is merged as an attribute too. Today `event_file` copies the winner's fields and
   merges only the state, so if the losing side moved the item to another track and the winning side only nudged it, the move is lost.
   This comes from reading the code and hasn't been reproduced; phase 0 adds the scenario first.
6. **What can't be merged** goes to the newest leaf (rev, `hlc`, name). That covers versions more than `MERGE_DAYS` apart (today's
   `too_old_to_merge`, which decides from the ids alone) and kinds with no merge (a chain from before `mg = 1`). A missing version whose
   id dates it more than `MERGE_DAYS` before the newest counts as trimmed, not as on its way.
7. **Bounds.** More than 64 leaves (a flood) goes to the newest without merging. Walks stay capped at 400 steps. Both bounds give the same
   answer on every computer.

That answers the brief's four questions. **Concurrent versions:** steps 2 and 5. **Deletions:** step 3. **Claims at the change's time:**
not an input under option A (section 4). `OWNER_STEP` stays, because the sender decides "owned" and writes it into the rev, so it is part
of the change. **Merges per attribute:** step 5.

### Containment: what the projection adds

An object is in the song when its settled version isn't gone and its container is in the song. An item's container is the track its
settled version names. The plug-in chain, automation, sends and misc parts of track T-x (F/E/R/M-x) have T-x as their container. A track
has none (a track whose folder parent is gone sits at the top level, section 3).

This replaces every "on a deleted track" rule: `on_gone_track`, `mirror.orphaned`, the item "recorded gone with its track", `bring_parts`,
`heal_due` and `tracks_back`. When a track comes back, everything on it whose settled version isn't gone comes back in the same pass, on
every computer, whatever arrived when. An item moved onto a track deleted at that moment goes with that track everywhere (rt-converge
commits 25 and 42 hold by construction).

**Local rescue stays.** An item of yours that a bandmate's deletion never saw goes to "(yours, not sent)" instead of away. "Never saw"
becomes a fact: a track's deletion names the items that went with it (a new field, `items`; up to 2,000 ids, and past that the old rule
applies). An item on the deleted track that isn't named there, with every version yours, is kept. One that is named goes. This replaces
`just_made_here`'s two minutes, `new_here`'s walk, `kept_new`, and the `asked_of` / moot rule in `mirror.apply` (3928-3935).

### When it runs

- **Receive.** Each pass adds what it read to the index and notes which objects it touched. Each touched object is then judged, in one
  fixed order (tracks by rank, then parts, then items by id). If the answer differs from what's held (the record's event id), is complete,
  and nothing makes it wait, it is applied and recorded. `APPLIED` marks stay, for pending counts and Health, and are set on every version
  the answer covers.
- **Catch-up** is the same thing with many objects touched. Each object is judged once instead of each change being applied, so the
  newest-only shortcut (`latest`, `apart`, `superseded`, the after-sort) has nothing left to do.
- **Heal** is the judge run over every object in the index, compared with what's held. It runs at the first catch-up and whenever Health's
  content code differs from a caught-up bandmate's (5c), not after 60 s plus 5 minutes.
- **The look** does what it does now (send, ask, put back). "The band's version" is the held one, which is the judge's answer.
- **A container coming back** has its contents judged in the same pass. The index keeps a map from each track to its items and parts.
- **An incomplete answer** applies nothing for that object. Its missing ids go to the need list (asked for by id: `lib/needlist.lua` asks
  by day today), and the object counts as "Receiving". A missing version that every bandmate here says they don't have is treated as
  trimmed (step 6), the same way on every computer that asked.

### Who asks it

| Path | Today it decides by | With the judge |
| --- | --- | --- |
| live receive (`mirror.receive`, 4347) | `wins`, `merge_for` (its 120 s wait), `gone_race` (120 s), `beaten_by`, `lands_over` | the judge, plus the per-object waits (`keep_unsent`, `unsent`, the knob doubt) |
| catch-up (`sync.receive`, 1875) | newest per object, `apart`, `superseded`, the after-sort | the judge, once per object |
| heal (`mirror.heal`, 7555) | `mirror.settled` plus the `ahead` / `old_merge` / `bare` rules | the judge over everything |
| Restore, History playback (`plan_restore`, `histhear.settle`) | newest at or before a time, with its own deleted-track rule | the judge over versions up to that moment (cut by id time), plus containment |
| Undo / Redo (`undo.step`) | History rows sorted by each computer's clock, then a `base_ev` walk | 5a |
| Use mine, Bring into main (`plan_bring`), forks, `page_rooms` | `room_newest` | the judge over the room |
| join bootstrap (`lib/joinboot.lua`) | newest per object | the judge's support (the leaves, plus what a merge needs) |
| media in use (`drive.media_in_use`, `needlist.in_use`) | each item's newest, with its own deleted-track rule (rt-linkmove round 5 item 4) | containment |
| history trim (`lib/trim.lua`) | the newest plus its rivals | the judge's support (never trims a version a merge needs) |
| web history (`lib/webhistory.lua`) | `mirror.newer` | the judge |

### What it replaces

- **`lib/mirror.lua`, removed or reduced:**
  - `wins` (4158), `gone_race` and `RACES` (4193), `merge_for` and `first_seen` (4204), `lands_over` (4277), `beaten_by` (4738)
  - `receive`'s race part and its "on a deleted track" branch (4351-4444), and `on_gone_track` (3838)
  - `orphaned`, `heal_due`, `tracks_back` (2856, 2887) and `bring_parts` (7531)
  - `heal`'s `ahead`, `old_merge`, `bare` and `MERGE_NEWS_SECS` (7554-7620)
  - `room_newest` and `settled` (7413-7485), replaced by the index and the judge
  - `kept_new` and the moot rule in `apply`, plus `just_made_here`, `new_here` and `only_retimed` (3827-3870)
- **`lib/sync.lua`, removed:** `receive`'s `latest` / `apart` / readable-before-pick / after-sort (2047-2117), the orphaned and `heal_due`
  heals at the end of a pass (2245-2262), and the `lands_over` call (2183).
- **Moved into `lib/judge.lua` unchanged (kept, pure):** `descends`, `apart`, `common_base`, `event_file`'s merge building,
  `merge_order`, `too_old_to_merge`, `split_merge` / `merge_id`.
- **rt-converge fixes that become true by construction:**
  - commits 8, 25, 35, 42 and 48 (a track's contents and their late versions): containment
  - commit 12 (a beaten edit stays beaten): step 3
  - commit 24 (a merge built on a missing base): incomplete
  - commits 33 and 45 (held deletions, unreadable files): the judge over the index, which includes the inbox
  - rt-fix6a's `new_here` and rt-fix9's `kept_new`: the `items` fact

### Determinism

- Nothing that decides an answer iterates with `pairs`: the judge sorts by id wherever it iterates, and `merge_order` sorts.
- **Property tests** (phase 1 for the merges, phase 2 for the judge) generate random histories with forks, merges, deletions and restores,
  and feed them in every arrival order (or 200 random orders). Each must give the same answer and the same merged state. Merging a version
  with itself changes nothing, and an incomplete answer never returns a version. Bug 8 and the restore races are exactly the class this
  catches without a soak.
- The two-run determinism check (`detcheck`, phase 0) runs in CI.

### Old history: the judge's version

Applied to history made before it existed, a new judge could settle some old objects differently from what computers hold. That would
change tracks a day or a month late, which is what `MERGE_NEWS_SECS` guarded against. So there is a grandfather rule: for an object whose
newest version predates the judge's release (by id time) and whose held version is one of its own versions, the held version stands.
Health's content code (5c) then shows any old difference between computers, and one action the person sees, "Bring in line", settles
those deliberately. (A decision for James: a click in Health, or automatic.)

## 2. Times in beats on the wire

### Canonical form: what is compared and hashed

An item's or automation's **canonical form** is its text with its times put in the units its timebase keeps fixed. The effective timebase
is the item's `BEAT` if it is 0 or more, else the track's timebase (if REAPER has one there: to check), else the project's.

| Timebase | Position | Length and inside the item | Unchanged by a tempo change? |
| --- | --- | --- | --- |
| 0 time | seconds | seconds | yes (REAPER doesn't move it) |
| 2 beats (position only) | quarter notes | seconds | yes |
| 1 beats (position, length, rate) | quarter notes, start and end | fades, snap offset and stretch markers as fractions of the length; an audio take's rate as source seconds per item (rate x length in seconds); a MIDI take's rate as it is | yes |
| automation, project timebase beats | each `PT` time in quarter notes; each automation item's start and end in quarter notes; its points (`BANDAIPT`) in quarter notes | | yes |

These are exactly the quantities `mirror.retime` keeps fixed, and those were checked against REAPER to the microsecond in rt-r4 check 1.
Numbers in the canonical text are rounded to fixed decimals (quarter notes and fractions to 1e-9), so one reading hashes the same
everywhere.

Because a tempo change leaves the canonical form of everything unchanged, **the tempo-maker's look finds no difference and sends nothing
but the timeline change.** No re-sends, no merges of re-sends, and no auto-claim from a tempo change (rt-r4's bug B, which rt-fix9 handled
with `moved_by_map`). Hashes of the canonical form say `hv = 9`.

### What travels (phase 5: format 1, both forms)

Each item and automation change carries:
- `state`: the seconds text as today (old computers read only this);
- `tm`: as today, for old computers;
- `beat`: for items in a beats timebase, `{ tb = 1 | 2, p = <start QN>, e = <end QN> }`; for automation, `{ tb, pts = { QN, ... } }`,
  one per `PT` line in order, then each automation item's start and end;
- `tmid`: the identity of the tempo map its seconds were read under, a 12-hex hash of `band.capture_tempo`'s points (time, bpm, num,
  denom, linear) rounded to 1e-9.

**Placing it** (new computers):
- If `tmid` matches this computer's map, the seconds are used as sent: exact, with no drift.
- If it doesn't, the seconds text is rewritten from the quarter notes on this map with `TimeMap2_QNToTime`. REAPER's maths handles
  gradual tempos, which today's `retime` skips. In mode 1 the item's fades, snap offset, stretch markers and audio rate are scaled by the
  length ratio, as `retime` does now.
- If `beat` is absent (an old sender's change), today's `tm` path is used (`mirror.retime`, kept as the legacy reader). If `tm` is absent
  too, the seconds are used as they are (today's rule for versions from before rt-converge).

Arrival order no longer matters. Say an item change arrives before the bandmate's map: it is placed by QN on the old map, and when the map
lands REAPER moves it, keeping the QN. If it arrives after, it is placed by QN on the new map. Both give the same place, which is why
`map_waits` goes.

### Format 2 (phase 10, at the floor)

Format 2 sends the canonical text in place of the seconds and drops `tm`. Receivers render the seconds on their own map. Changes get
smaller (today `tm` costs about 70 bytes per tempo point on every item change). It is optional cleanup; everything above already works in
format 1.

### Items whose timebase is time

Their canonical form is seconds. A tempo change doesn't move them in REAPER, and nothing moves them here either. In a mixed project
(project timebase beats with one item set to time) this is decided per item. The same goes for automation when the project timebase is
time.

### What goes away

- **On new computers in phase 5:** `TEMPO_SECS`, `tempo_until`, `tempo_from` and `tempo_changed` (4850-4859); `map_moved` and
  `only_map_moved` (4869-4899); `map_landing` (4907: two full project reads per landed map); `map_stamp`, `tl` and `sync.map_waits` /
  `MAP_WAIT` (4934, sync 1248-1254); `W.send`'s `tempo_only` / `retimed` (5583-5585); `W.refuse`'s map branch (5659); `moved_by_map`,
  `state_on`, `on_map` and `snap_to`; `event_file`'s map branch (4700-4716); `env_same_but_times` and `sans_tempo` as they are used for
  map moves; `map_qn` / `map_time` (replaced by REAPER's `TimeMap2`).
- **At the floor:** `tm`, `MAP_MAX`, `retime` and `retime_env`.

### Mixed old and new computers (phase 5 is wire-compatible)

- New senders keep the seconds and `tm` and add `beat` and `tmid`. Old receivers ignore the new fields and place by `tm` as today.
- An old computer's tempo change still re-sends its items marked `retimed`. A new receiver finds each one equal to its base in canonical
  form: a version that changes nothing, which lands as a no-op and merges as one.
- New senders write hashes as `hv = 9`. Old receivers already skip "came out different" when `hv` differs (`ev.hv == mirror.HV`, 4556),
  and new receivers compare only `hv` 9 hashes.

### Rounding across computers

`TimeMap2_timeToQN` on Windows, Mac (ARM) and Linux may differ in the last bit. At 1e-9 rounding, a value crossing a rounding boundary that
way happens about 3 times in 100,000 numbers. To keep that from showing as a difference, cross-computer comparisons (Health's content
code, "came out different") hash at 1e-6 quarter notes. Applied states are rendered from one canonical text, so every computer starts from
identical inputs. REAPER check: the same item placed on the Mac and on Windows.

## 3. Track order as a rank per track

- **`rank`** is a fractional-index string (`[0-9A-Za-z]`, at most 32 characters) stored as a setting in the track's own version.
  `merge_track` merges it per setting, so a move and a rename made at once both stand; of two moves made at once, the newer stands (rev,
  then `hlc`, then name).
- **`parent`** is the folder the track is in (an oid, or "" for the top level). `track_state` already reads it; now it travels for real.
- **The order** is a depth-first walk of the folder tree, each level sorted by (rank, oid). A track whose parent is gone or not here sits
  at the top level. So does a track caught in a loop of parents (two moves at once, each into the other): in that case the track whose
  parent change is newest leaves the loop. Both rules give the same order on every computer.
- **`depth` (`I_FOLDERDEPTH`) stops travelling.** It is worked out from the tree when applied: 1 for a folder with children, -n on the last
  track closing n folders, 0 otherwise. Today depth travels and the parent is inferred from depths in list order, which is why "a folder
  change arriving in pieces made the tracks under it read as edited" (`track_line`'s comment, 2114). Hash version 9 leaves depth out and
  puts parent and rank in. (A decision for James: the folder model changes from "depths in order" to "parent + rank", so any two moves made
  at once give a valid folder tree.)
- **Reading a move (the look).** A move shows as the REAPER order differing from the order StudioSync last saw or wrote (`order_seen`,
  kept, now written after every apply and every look). The fewest tracks that moved (`mirror.moved_tracks`, kept) each get a new rank
  between their new neighbours' ranks under their new parent. `rank.between(a, b)` is about 40 lines with no dependency (base-62 digits,
  a midpoint); if two people pick the same key, the oid breaks the tie. A move into or out of a folder changes the track's parent.
- **Applying.** After a pass that changed any rank or parent (or brought a track in), and only when this tab is in front, nothing is being
  dragged (the mouse button is up: a fact) and REAPER's order differs from the sort: the fewest tracks are moved with
  `ReorderSelectedTracks` (as `keep_order` does today, under one StudioSync undo point), and `order_seen` is updated. A tab behind is
  reordered when it comes to the front, since REAPER reorders only the tab in front. A new track is inserted straight at its place in the
  sort.
- **Migration, once per room.** When no track in the room has a rank yet, the first look on the new version that is caught up, and whose
  order is the studio's newest order list (`order_code` agrees: `keep_order`'s own test), writes a rank for every track as one act
  ("StudioSync: track places"). Ranks are spaced evenly by place (`rank.spread(n)`), so two computers doing this at once on the same
  order write the same ranks and it doesn't matter which lands. A track with no rank (made by an old computer) sorts just after the track
  its `after` names, or at the end.
- **Old computers in the room** ignore rank and keep their order heal. New computers keep writing `after` and the order lists (on a move)
  until the floor, so old computers still have something to follow.

**What goes away on new computers:**
- the order heal: `order_heal`, `ORDER_IDLE` / `ORDER_WAIT`, `order_landed` / `order_moved` / `order_kept` (7228-7244), the call in Live
  sync's `P.heal` (line 639), and `apart_note`'s "apart order" with `order_apart_for` (7364-7372)
- deciding where tracks go: `keep_order`'s list logic (7146), `wanted_order` (1734), `moved_since` / `says_move` (7198-7214),
  `order_after_band` / `order_band` (7125, 4847), `mirror.STAY` (7553)
- `moved` and `was_after` on changes, and `W.order`'s `moved_from` (5300)
- the after-based ordering elsewhere: `sync.receive`'s after-sort (2097-2117) and `fresh_move` publish (2230), heal's place-after
  (7578-7587), and `apply`'s reorder by `after` (3970-3982)
- after the floor: `read_order` / `publish_order` (7130-7143) and `rooms/<room>/order/`

The order becomes part of the content code, since ranks are track settings. 9034 is fixed by construction: a late joiner sorts by rank.

## 4. Don't refuse on receive (needs James's yes)

### What refuses on receive today (`sync.receive`)

- **`refused(ev)`** puts a change in `sync.deferred` for a minute from its arrival (`refused_since`, 2358), after which it lands anyway.
  It is judged by `obj_allowed` (the claims at the change's time: `at`, rt-converge commits 3 and 15), by `maker_may`, and by the room's
  driver at the change's time (`driver_at`, `driver_history`).
- **`soft_ok`** (1988) lands a change at once if it merges with the auto-claimer's own. So do `unasked` (rt-converge 39), an Undo or Redo
  of the sender's own change, and `gone_before_claim` (1869, rt-fix6a).
- **Renames:** `renames`, `rename_stands` and `track_claims` (2020-2031), and `set_back` (2074), where the claimer's computer answers a
  rename with a new change.
- **Changes that aren't objects** (older kinds, the timeline) wait the same minute.

All of this exists to keep a change from landing for a minute, after which it lands anyway. Five special cases (`gone_before_claim`,
`soft_ok`, `unasked`, `rename_stands`, the same-second rule) were added because that minute made computers differ: bug 3, P1-1/P1-2's 61 s,
round 5 C, and rt-r3's 60-120 s.

### Proposal (option A)

- **Every readable change lands, judged by the judge alone.**
- **The sender enforces claims and room modes exactly as it does now:** `W.refuse`, claimask's asks, holds and put-backs, auto-claims,
  the Driver only and Admins only refusals, and the web pages' refusals. For anyone on a current StudioSync nothing changes, because their
  StudioSync doesn't send what it isn't allowed to.
- **Kept: `set_back`, but only for a sender too old to ask** (before 0.59.49.74), told by a new field `v` (the sender's version, on every
  change from phase 6). A change with no `v` that renames a track this computer holds by its old name gets today's answer. The answer is a
  new change made by the claimer's computer, which everyone then judges alike, so it isn't a refusal.
- **Kept: format deferral** (`sync.too_new`). A change this version can't read waits for the update. That is about reading, not
  permission.
- **Added: the claimer can see it.** When a change to their claim lands without having asked, their computer logs "X changed Y, which
  you've claimed: their StudioSync didn't ask". A change that went out on an answer says so (`asked`: the `claim_answer` id). So an old or
  modified client is visible.

### What users notice

- **Everyone on a current StudioSync:** nothing, except that the minute goes in which one computer shows an edit another is holding back
  (claims crossing in the same second, a late joiner, LinuxBox's round 5 C).
- **An old StudioSync** (from before asks): its edit to your claimed track lands on everyone at once instead of after a minute. Its renames
  are still answered.
- **Driver only and Admins only:** the same. They are enforced by the sender's StudioSync, and a non-driver's change from an old or
  modified StudioSync lands at once instead of after a minute.

### Options for James

- **A (recommended):** as above.
- **B:** keep today's refusal and its minute. No change: the five special cases and their bugs stay, and so do 127 and 6006.
- **C (later, on the security pass):** claims that really bind. Claims would become changes in the same log instead of files, each change
  would carry which claim changes its sender had seen, and the judge would drop a change made past a claim its sender had seen, the same
  way on every computer. That only means something with per-person signatures: today the link signs with the studio's key, so any member
  can write as anyone. It is a design for the security pass, not built here.

Security costs are in section 13.

## 5. Undo, timers, Health and the shape of `mirror.lua`

### 5a. Undo from ancestry

- **Which change to undo** is chosen from your own acts, ordered by your own clock (`hlc` only ever grows on one computer, so nothing is
  compared across computers' clocks). An act counts as undone when an Undo act of yours names it (`undoes`) and that Undo wasn't redone
  (`redoes`). The order of History's rows (`recall.entries`, sorted by each computer's clock) no longer decides anything.
- **What it writes, per object in the act:** a new version built on the object's current judge answer S. The act's change is reversed onto
  S by the same three-way merge, `merge_state(kind, base = the act's version a, winner = the version a was built on, loser = S)`:
  - what a bandmate changed since and you didn't stays; where you both changed something, yours goes back (today's ask says exactly this);
  - a creation's reverse is a deletion;
  - a deletion's reverse is the version it was built on, at its rank, with its items and parts back by containment;
  - an edit a deletion beat stays beaten (judge step 3).
- **Redo** is the same rule applied to the Undo act.
- **What goes:** `plan_undo` (1680), `plan_undo_moment`'s walk over History (1888), `last_mine` / `last_undo` / `later_by_others` by rows
  (1946-2005), `undo_keeping` (1598), `undo.step`'s `base_ev` walk (undo.lua 225-242), `was_after`, and comparing markers "on the map in
  place" for Undo (markers carry QN). The timeline keeps `built_on` (commit 37) until markers become objects (Recommendation 3).
- **What stays on this computer:** the ask (press again, or the bar), and "undo nothing" / "undo passed" per tab. They are per person and
  never decide what anyone else holds.

### 5b. Timers into facts

The rule: **a timer may decide when something happens, or whether this computer sends. It never decides which version anyone holds.**

| Timer | Where | What it decides today | Becomes |
| --- | --- | --- | --- |
| `TEMPO_SECS` 15 | `mirror.tempo_*` | is this only the map's move? | gone: beats |
| `MAP_WAIT` 30, `tl` | `sync.map_waits` | land a change only after its map | gone: placed by QN in either order |
| refused 60 s | `sync.refused_since` | a refused change lands later | gone (option A) |
| merge wait 120 s | `merge_for`, `gone_race` (`first_seen`) | is a version in between on its way? | the judge's "incomplete", plus a need-list ask by id; trimmed decided by id age |
| heal 60 s apart + 5 min | Live sync `P.heal` | did something never land? | Health's content code differs from a caught-up bandmate's (a fact): heal at once |
| `ORDER_WAIT` 120, `APART_SECS` 30, `ORDER_IDLE` 10 | the order heal | track order drift | gone: ranks (the mouse-down check stays, as a fact) |
| `MERGE_NEWS_SECS` 3600 | heal | a merge found late | gone: everyone holds the judge's answer; old history is grandfathered |
| `just_made_here` 120 s, `asked_of` 60 s | `apply` on a track deletion | did the deleter see this item? | the deletion names its items |
| `RENAME_BACK` 600 | `set_back` | the rename answer window | kept, for too-old senders only |
| `SESSION_SECS` 30 | `W.send` | does the same edit keep its rev? | stays: sender-side, and the rev is in the change |
| `EDIT_SECS` 30 | `user_edited` | auto-claim only after an edit | stays: sender-side, auto-claims only |
| `FX_LOAD_SECS` 60, `FX_SET_GAP` 5 | look, `apply` | a loading chain reads back its own way; the REAPER crash guard | stay: local send decision, and a wait |
| `ACT_SECS`, `ACT_KEEP` | look | grouping an act | stay: sender-side |
| `UNREADABLE_SECS` 600 | receive | a damaged file | asked of bandmates by id first; skipped once they say they don't have it |
| `CUE_OLD`, `AUTO_IDLE`, `GONE_WAIT`, `ASK_WAIT`, `COOLDOWN`, `CONFIRM`, presence 45 s | cues, claims, asks, previews, who's here | human and session rules | stay |

### 5c. Health compares contents

Today `mirror.root` hashes which event id each object holds. Equal codes mean "the same changes held", not "the same song". Bug 1 (an
edit kept on one computer, silently) and the wrong-base merge (commit 24) were invisible to it, and so to heal.

- **Content code**, in the status beside `mirror`: a hash over sorted (oid, the judge's answer id, the answer's content hash). The content
  hash is the change's own hash at `hv` 9, or a merge's canonical state hashed. If two caught-up computers have equal `mirror` codes and
  different content codes, the judge disagrees with itself. That is logged with the differing objects as a bug report, not something heal
  can fix. Track order is inside this code, through the ranks.
- **Drift here:** objects whose REAPER reading isn't the content of the held version (plug-in chains compared through the read-back
  aliases mirror already keeps), not counting unsent edits. Bug 1's class shows here, and heal puts the band's version back and says so
  once.
- **Finding which objects differ:** 16 bucket codes in the status (oids grouped by the first hex digit of their hash). Only the differing
  buckets' lists are asked for over the link. It's small.

### 5d. The shape of `mirror.lua`

Facts:
- 7,772 lines.
- 156 of Lua's 200 top-level locals are used (`tests/check_locals.py` counts them), so the file is close to a hard limit.
- About 40 module tables are keyed `tostring(proj) .. oid`, most never pruned: `unsent`, `held_back`, `asked_of`, `copied`, `fx_seen`,
  `fx_knobs`, `fx_alias`, `track_alias`, `fxk_ok`, `fx_set_at`, `fx_readback`, `fx_loading`, `fx_load_knobs`, `fx_open_at`, `fx_open_text`,
  `fx_quiet`, `fx_quiet_presets`, `fx_last`, `fx_doubt`, `kept_new`, `track_seen`, `sessions`, `auto`, `print_quiet`, `reopened`,
  `set_backs`, `previewing`, and more.
- 12 `W.*` functions each open with the same four lines unpacking about 30 fields of `w`.

The plan moves one module per phase, never as a big bang:

- **`lib/mirror_merge.lua` (phase 1):** `merge_item` / `midi` / `env` / `track` / `fx`, `pieces`, `clashes`, `note_changes`, `move_pairs`
  and their helpers, about 900 pure lines. `mirror` keeps `mirror.merge_item = M.merge_item` and so on, so callers and tests don't change.
- **`lib/judge.lua` and `lib/evindex.lua` (phase 2), `lib/rank.lua` (phase 4), `lib/beats.lua` (phase 5).**
- **`lib/objrec.lua` (phase 9):** one record per project and object (`P[proj][oid]`), dropped with the project and when the object leaves
  the song (judge says gone and it isn't in REAPER). Then what commits 29, 33, 44 and 46 fixed, a flag outliving its object, can't happen.
  Tables move one at a time behind a view (`mirror.unsent = objrec.view("unsent")`, a metatable over the old key shape), so callers move
  one at a time too.
- **`lib/look.lua` (phase 9):** `mirror.watch` and `W.*`. Each `W.*` reads `w.x` directly and the four-line unpacks go.
- **`mirror.lua` keeps REAPER reading and writing:** `scan`, `quick_scan`, item and track state, `apply`, `find`, `known` / `remember`.

Each move is its own commit, with tests unchanged. Rough size: about 1,000-1,300 lines leave `mirror.lua` and `sync.lua`, and about 500
come back in the new modules.

## 6. How the track-deletion bug class disappears

**The class:** an object missing from REAPER is read as deleted. `W.gone`'s whole test is "the record is here and the object isn't"
(rt-reopen). A look that reads a project mid-close, a reload in the same tab, an older `.rpp` or a script's removal can each delete the song
for everyone. Under the new design:

1. **The look compares REAPER with the projection** (what should be here), not with the records. Something absent where the projection
   also says absent (its track is gone) sends nothing. Today's "the item went with its track" branch becomes a special case of this.
2. **Something absent that should be present is a deletion only with evidence**, all three of:
   - (a) the same project is in the tab as at the last look. That is told by its master track, as `sync.settled_for` and the timeline
     already tell a reopen, not by its first track (that confusion is 5028);
   - (b) the object was there at that last look;
   - (c) the person has made an undo point since (`mirror.user_point`, as auto-claims use).

   If anything is missing, the object is put back from the band and this is said once: "N tracks the studio has weren't in this project:
   they're back".
3. **Never "all of it."** A look that finds no mirrored track while the song has some sends nothing, whatever the undo list says. That is
   rt-reopen's candidate A.
4. **(James decides) A big deletion asks first.** A look that would delete half the song's tracks or more asks "Delete 3 tracks for
   everyone? Yes / No", holding the deletion as asks do. No answer puts it back.
5. **Recovery is one Undo.** A deletion that does go out is an ordinary change. Undo builds on it and brings each track back at its rank
   with everything on it (containment), on every computer: no `was_after`, no `orphaned`, no `bring_parts`.

The first look of a project has nothing to compare with, so it never deletes anything. rt-guard's guard (being built now) is (2c) plus the
first-look rule. Phase 3 makes it structural and adds (2a), (2b), (3) and (4).

## 7. The soak's remaining failures, one by one

- **5028** (a knob turned in the moment the first track goes is never sent): **phase 3.** The project instance is told by its master track
  pointer, so deleting track 1 is no longer a reopen, `fx_load_knobs` isn't noted afresh, and the knob goes out. The one-line patch
  rt-converge held back for REAPER check 12 isn't needed, because what was wrong is the reopen test itself. The second half of check 12 is
  still owed.
- **5057, 9029, 9058** (an Undo's restore made at the same time as a bandmate's edit ends as different merges): **phase 2.** rt-converge
  named the causes: `merge_for` waits two minutes and then decides by rev and clock, which depended on arrival order; and the deletion rule
  covered items only. The judge has no timer (the answer stays incomplete until the missing version arrives), uses one deletion rule for
  every kind, and gives every computer the same merge. Gate: the three seeds pass at 150 edits, plus a scenario with an Undo within a
  second of a bandmate's edit of the same item, of its automation and of its plug-ins.
- **9034** (a late joiner places tracks made after the newest order list differently): **phase 4**, ranks.
- **127, 6006** (a Redo of a rename answered by the bandmate whose claim is on the old name): **phase 6** under option A, since a current
  StudioSync's changes aren't answered. Under option B they stay; Recommendation 4 (claims by track id) would also end them.
- **7017 and similar:** an accepted limit, unchanged. The sender's ask still stands in front of the Redo.
- **15033** (an item's length differs on one computer) and **15044** (a late joiner's MIDI merge), from rt-fix9's runs: most likely
  phases 5 and 2. Each gets a scenario before its phase and must pass after it.

## 8. Migration: formats, mixed rooms, rollback

**Event format.**
- `band.FORMAT` stays 1 through phases 0-9. Every wire change there is an added field that old computers ignore:
  - `items` on a track deletion (phase 2);
  - `rank` and `parent` in a track's state (phase 4);
  - `beat` and `tmid` on items and automation (phase 5);
  - `v` (phase 6);
  - `hv` 9 hashes (phases 4 and 5).
- **Format 2 comes only at the floor (phase 10).** It drops `tm`, the seconds text for beat content (the canonical text travels instead),
  `after` and the order lists, and may add marker objects. Old computers defer format-2 changes (`sync.too_new`: "update StudioSync and it
  lands"). The format-2 reader ships at least one release before the first writer, so rolling back from the writer lands on a version
  that can read what it wrote.

**Mixed rooms.**
- **Phase 2 (the judge)** changes nothing on the wire. New and old computers may hold different merges for a race made while both were
  in the room, which is what old computers already do among themselves. Health shows "apart", and everyone updates together (the studio
  folder updates every computer within a minute). Phase 0's mixed soak measures it.
- **Ranks:** old computers order by `after` and the order lists, which new computers keep writing. New computers follow ranks. The two
  agree when moves come one at a time; the mixed soak checks moves made at once.
- **Beats:** wire-compatible, as section 2 describes.
- **No refusal on receive:** old computers still refuse for a minute, and the changes they refuse land after it, as today.

**Rollback.**
- **Phases 0-9:** install the earlier version. There is no new format, and the extra fields are ignored. Ranks kept in versions do
  nothing, and rolled-back computers find the order lists new computers kept writing, so their order heal has something to go to.
- **Phase 10 (format 2):** only back to a version that has the format-2 reader (10a or later).

## 9. Phased build plan

Gate for every phase: `python tests/run.py --no-luals` ends `fails 0` (in local time and with `TZ=UTC0`), `soak.py --quick` passes, and a
20-minute long soak from a clean checkout on the seed ranges of rt-converge's last table (5000, 9000, 13000, 15000 at 150 edits) passes at
least as many seeds as the phase before, with any new failure categorised before landing. One commit per fix, each with a test that fails
without it (rt-converge's practice). New `lib` files are listed in `lib/files.txt` by `tools/make_index.py` at release.

| # | What | Files | Wire | Extra gate | Estimate |
| --- | --- | --- | --- | --- | --- |
| 0 | Soak and harness | `tools/soak/soak.py`, `tools/soak/node.lua`, `tools/soak/detcheck.py` (new), `tools/soak/scenarios/*.json` (new), `tests/run.py` (one step) | none | scenarios for every open failure | 1-1.5 days |
| 1 | Pure split of the merges | `lib/mirror_merge.lua` (new), `lib/mirror.lua`, `tests/test_0_60_rt_merge_props.lua` (new) | none | detcheck identical to the previous commit | 1 day |
| 2 | **The judge** | `lib/judge.lua`, `lib/evindex.lua` (new); `lib/mirror.lua`, `lib/sync.lua`, `lib/page_restore.lua`, `lib/histhear.lua`, `lib/joinboot.lua`, `lib/drive.lua`, `lib/needlist.lua`, `lib/trim.lua`; `tests/test_0_60_rt_judge.lua` (new) and about 12 tests that call the removed functions | `items` (added) | 5057, 9029, 9058, 15044; judge agreement at quiet; mixed soak | 3-4 days |
| 3 | The look against the projection, deletion evidence, instance by master track | `lib/mirror.lua` (`W.gone`, `W.order`, `watch`), `tests/test_0_60_rt_reopen.lua` (new), soak edit kinds | none | 5028; the soak never sees a deletion sent without a user undo point | 1.5 days |
| 4 | Ranks | `lib/rank.lua` (new), `lib/mirror.lua`, `lib/sync.lua`, `StudioSync - Live sync.lua` (one line), `lib/page_health.lua` (small), `tests/test_0_60_rt_rank.lua` (new), `tools/soak/node.lua` | `rank`, `parent` (added), `hv` 9 for tracks | 9034; "order" failures 0; mixed soak | 2-2.5 days |
| 5 | Beats | `lib/beats.lua` (new), `lib/mirror.lua`, `lib/sync.lua`, `tests/fixtures/editreaper.lua` and `tools/soak/node.lua` (`TimeMap2_*` in the stand-in, ramps included), `tests/test_0_60_rt_beats.lua` (new), 3-4 tests that pin `retime` / `map_moved` | `beat`, `tmid` (added), `hv` 9 | a new node's tempo change sends no item changes; 15033; mixed soak | 3 days |
| 6 | No refusal on receive (**James's yes first**) | `lib/sync.lua`, `lib/mirror.lua` (`v`, `set_back` gating), `lib/claimask.lua` (the "didn't ask" line), tests that pin the minute (claims, fix6a, converge parts) | `v` (added) | 127, 6006; no permission-based `deferred` in the soak | 1-1.5 days |
| 7 | Undo from ancestry | `lib/undo.lua`, `lib/mirror.lua`, `tests/test_0_60_rt_undo2.lua` (new), 6 tests using `plan_undo` / `last_mine` | none | the undo probe passes on every long-run seed | 2 days |
| 8 | Timers into facts, Health content code | `lib/mirror.lua`, `lib/sync.lua` (status), `StudioSync - Live sync.lua` and `lib/page_health.lua` (small), `lib/needlist.lua`, `tests/test_0_60_rt_health2.lua` (new) | status fields | content codes agree at quiet; a test-only fault (a held version swapped) is found and healed | 2 days |
| 9 | Shape: object records, the look as a module | `lib/objrec.lua`, `lib/look.lua` (new), `lib/mirror.lua` | none | tests unchanged, detcheck identical | 1.5-2 days |
| 10 | The floor: format 2 (10a reader, one release later 10b writer) | `lib/band.lua`, `lib/beats.lua`, `lib/mirror.lua`, `lib/sync.lua` | format 2 | mixed soak: old computers defer and say so | 1.5 days + a release cycle |

**Total: about 18-22 agent-days**, at rt-converge's pace (48 commits in about two days), not counting REAPER-check time.

### Phase notes

- **0. Harness.**
  - `--detcheck`: two runs of a seed in separate Lua states, comparing everything each computer wrote. It is about 40 lines; rt-converge
    found bug 8's cause with it in minutes.
  - `--scenario <file>`: edits at given times on given computers, plus network events. The first scenarios: 5057, 9029, 9058, 9034, 127,
    6006, 15033 and 15044; the restore race; a rename against a fader; an older file reopened; a look over an empty project; and the item
    track-merge loss from judge step 5.
  - `--old <commit>`: a node loads `lib` from a `git archive` of that commit, which is the mixed-version soak.
- **2. The judge.**
  - Before it lands, record the soak's event folders and replay them through both the old receive and the judge. Every difference is
    listed and explained.
  - Measure on rt-bigproj's 20,000-event song: judging is per object, and the index keeps light events as `room_newest` does today.
  - REAPER checks: rt-converge check 8 (Undo); the restore race by script (an Undo a second after a bandmate's edit of the same item, its
    automation and its plug-ins); a late joiner; P1-6's Ctrl+Z.
- **3. The look.** Tests cover: records present and an empty project; a first look; a reload in the tab; an older `.rpp`; a real delete;
  REAPER's Undo of a delete (bug C); and track 1 deleted with a knob turned (5028). REAPER checks: rt-reopen's re-check, and check 12.
- **4. Ranks.** REAPER checks: two moves at once on the desktop and laptop; a folder moved while a child is moved out of it; REAPER's own
  indent and outdent read as parent changes; a late joiner after moves; an old-version computer in the room.
- **5. Beats.** REAPER checks: rt-converge check 1 again (cross-map landing: fades, snap offset, rate); a gradual tempo change; an
  auto-stretch item; an item with stretch markers; the same placement on the Mac and on Windows; rt-r4 bug B (no claim from a tempo
  change).
- **6. No refusal.** REAPER checks: rt-fix6a check 2 (round 5 C lands within a second); a claim and an edit made in the same second.
- **7. Undo.** REAPER check: rt-converge check 8 in full, including (c) with a panel Restore.
- **8. Health.** REAPER checks: Health on every computer after a burst; a drift forced by script (a record edited) shows and heals.

## 10. Risks

- **Phase 2 is the core.** Everything goes through the judge, so a judge bug shows up everywhere at once. Mitigations: property tests,
  detcheck, the mixed soak, and the replay comparison against today's receive.
- **Performance.** Judging an object walks its ancestry (capped at 400 steps) each time its versions change. Catch-up judges each object
  once, so there are fewer applies than today. Measured in phase 2.
- **Beats rounding across Windows, Mac (ARM) and Linux:** coarser rounding for comparisons, plus a REAPER check on the Mac.
- **The stand-in's tempo maths becomes the soak's truth again.** That was rt-converge's biggest soak artifact, so phase 5 needs its
  REAPER check before it is trusted.
- **The folder model changes** (depth worked out from the tree). REAPER's own folder actions must read as parent changes; checked in
  phase 4.
- **Grandfathered history.** Old differences between computers stay until someone uses "Bring in line" (5c).

## 11. Decisions for James

1. **Receive:** option A (no refusal on receive), yes or no? And should claims that really bind (option C) go on the security pass's list?
2. **Big deletions:** should a look ask before deleting half the song's tracks or more? What threshold?
3. **Folders:** parent + rank, with depth worked out from the tree: yes?
4. **Format 2 and "the floor":** when may old computers stop being able to read new changes? (They wait for the update and say so.)
5. **Old history differences:** settled by a "Bring in line" click in Health (proposed), or automatically?
6. **Phase order:** the judge comes before ranks and beats here. Ranks and beats don't depend on it and could come first if you want 9034
   and the tempo fixes sooner.

## 12. Recommendations (ranked)

1. **Build phases 0-2 first, as one block.** The judge removes the biggest source of bugs, and every later phase leans on it.
2. **Merge an item's track as an attribute** (judge step 5). A loser's move to another track is lost when the winner only nudged the item.
   It comes from reading `event_file` and isn't reproduced; phase 0 writes the scenario first.
3. **Markers and regions as objects** (rt-converge Recommendation 9's second half). The timeline is one document where the newest wins, so
   a marker added a second before a bandmate's tempo change is lost. As objects, timeline Undo needs no code of its own. Needs format 2.
4. **Claims by track id**, with the name kept for display. That ends the rename class (127, 6006, the two-holders rule) even under
   option B.
5. **A REAPER-backed soak run** (three REAPERs driven through the dev-eval hook) after phase 5, to validate the stand-in's tempo and folder
   models.
6. **Treat the per-object leaf and walk bounds as security limits**, not only performance ones.
7. **A per-writer append-only log** (rt-converge Recommendation 10): after all of this. Nothing here needs it.
8. **Drop the legacy readers** (`tm`, `retime`, `after`) some months after format 2.
9. **A "judge disagreement" bug report** (the object's versions and both answers) whenever content codes differ while change codes are
   equal.
10. **Gather the sender-side timers** (`SESSION_SECS`, `EDIT_SECS`, `ACT_*`, `FX_LOAD_SECS`) under one heading in the code, with 5b's rule
    written beside them.

## 13. Review-later (security)

- **Option A.** A modified or old StudioSync's change to a claimed thing lands at once, as does a non-driver's in Driver only or a
  non-admin's in Admins only. Today it lands after a minute anyway: the minute isn't a security boundary (rt-converge Recommendation 4,
  and earlier security notes). The claimer's "didn't ask" line makes it visible. Real enforcement needs option C plus per-person
  signatures.
- **`v` is the sender's word.** A forged change without `v` gets the rename answer, which is harmless: it only re-asserts the claim.
- **New fields are bandmate data**, checked on receive with size limits:
  - `items`: at most 2,000 oid strings of at most 200 characters, no slashes;
  - `rank`: at most 32 characters, `[0-9A-Za-z]`;
  - `parent`: an oid string of at most 200 characters;
  - `beat`: finite numbers, |x| < 1e9, and the counts must match the state's `PT` lines or the field is ignored;
  - `tmid`: 12 hex characters.

  A forged rank or parent can move only what any change can move.
- **The judge's bounds:** per-object leaves (64), walks (400 steps), merge depth (12). A member flooding versions of one object can't stall
  REAPER past them.
- **Need-list asks by id** keep today's id checks (no slashes, a file named for its id).
- **Deletion evidence** uses this computer's own undo list only.
- **The content code** is hashes only, as `mirror` is today.

## What I didn't check

- Nothing was run and no code was written. This is from reading the docs named at the top and `lib/mirror.lua`, `lib/sync.lua`,
  `lib/undo.lua`, `lib/claimask.lua`, `lib/controllers.lua`, `tools/soak/*` and Live sync's `P.heal`.
- **REAPER behaviour assumed, still to check:**
  - the track timebase (`C_BEATATTACHMODE` on tracks) and which of item, track and project wins;
  - what a tempo change does to auto-stretch items, stretch markers and take envelopes;
  - REAPER's folder actions reading as parent changes;
  - `TimeMap2` giving the same results on every platform.
- The item track-merge loss (Recommendation 2) comes from reading `event_file`; it isn't reproduced.
- The estimates assume rt-converge's pace and don't include REAPER-check time.

## James's decisions (2026-11-27)
1. Option A (no refusing on receive): accepted, on the understanding that the editor's computer still enforces claims before sending (a hand claim puts the edit back at once on the editor's computer; an auto-claim asks the claimer first); the only edits that reach others past a claim are from computers too old to ask, or an auto-claim whose claimer can't be reached (rt-fix6a's rule), and those show a "didn't ask" note. Binding signed claims (option C) go on the security review's list.
2. A look asks before sending deletions of half the song's tracks or more.
3. Old-history differences: a "Bring in line" button in Health, not automatic.
4. The rest as proposed: folders as parent + rank; build order judge, then ranks, then beats; format 2 only at the final phase, after a reader release (old computers show "waiting for update").
