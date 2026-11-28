# rt-sync2h: phase 6, nothing refused on receive; and the timeline after a restart (2026-11-28)

rt-sync2's phase 6 under option A (James, 2026-11-27, decision 1), simplified by the version floor, plus the timeline a computer took
after a restart. On top of 9d4d353 (0.65.1, hv 14, level 14). No hv or level change. Nothing deployed, released, pushed or
version-bumped; `lib/webui.lua` and `lib/webui/index.html` (someone else's) untouched.

## Summary for James

- **A change to something you've claimed lands on everyone at once.** Your claim is still enforced where the edit is made: a bandmate's
  StudioSync asks you first, or puts their edit back. What changes is the receiving end. Until now a computer that judged a change "not
  theirs to make" held it for a minute and then let it in anyway. Because of that minute, computers showed different things for a while,
  and five special cases had grown up around it. One of them could lose a Redo for everyone.
- **When a change does get past your claim, you're told.** That happens when your claim and their edit cross in the same moment, or when the
  direct link couldn't reach you to ask. Your log says, for example: "James changed Keys, which you've claimed: their StudioSync didn't ask".
- **A computer that starts now takes the studio's newest tempo map at once.** After an update that raised StudioSync's level, the newest
  tempo change had been made by the older version. The floor held it back, and that also blocked every older map. So LinuxBox, or the
  desktop, kept the tempo from its own file until someone changed the tempo again.
- **To see this live, deploy this build to the desktop and LinuxBox together, then run `sync2h`** (the list is at the end of this doc). On
  today's 0.65.1, the live set shows each old behaviour this round removes.

## Commits

| Commit | What | Fails without it |
| --- | --- | --- |
| 739dc82 | phase 6: nothing refused on receive; the claimer's "didn't ask" word (`lib/sync.lua`, `lib/mirror.lua`); tests rewritten to the rule; soak scenarios' expectations | `test_0_60_rt_converge` 25, 39; `test_0_60_rt_edits` (the rename block); `test_0_60_rt_fix6a`, `test_0_60_rt_bounds` (the removed pieces); soak `rename-redo-claim` |
| 6cf450f | task 2: a timeline change with a level isn't held by the floor; `sync.newest_map` picks only a map this version can apply | `test_0_61_rt_floor` 9 (each half knocked out separately) |
| f0e37c9 | `tools/live/sets/sync2h.py`: h1-h4 | live (below) |
| (this doc) | docs/rt/rt-sync2h.md | |

## 1. Phase 6: what was removed, and what stayed

### Removed (on receive, `sync.receive`)

| Removed | Its only job |
| --- | --- |
| `refused(ev)`, `sync.refused_since` (and its table) and the two receive branches that used them, one for object changes and one for the other kinds | holding a change judged not its sender's to make for a minute from its arrival (`sync.deferred`, the judge's `skip`), after which it landed anyway |
| `soft_ok` | letting a change past that minute when it merged with the auto-claimer's own, was `unasked`, was an Undo or Redo of the sender's own change, or was a deletion made before my auto-claim |
| `sync.gone_before_claim` | the deletion case of `soft_ok` (rt-fix6a) |
| `renames`, `rename_stands`, `sync.track_claims` | judging a rename by the name the track has here, and settling two holders of one track (rt-converge's bug 2) |
| `set_back`, `mirror.set_back`, `mirror.set_backs`, `sync.RENAME_BACK`, the `ok_before` exception in `W.one` and the `note` in `W.send` | the claimer's computer answering a rename of its claimed track with the track as it was (the soak's 127 and 6006: a crossing Redo lost everywhere) |
| `latest` / `mirror_newer` in receive | picking the newest change of each object, used only by `set_back` |
| `mirror.judge`'s `skip` parameter | leaving refused changes out of the judge |

The minute also covered the kinds of change that aren't objects: a timeline change, cues and notes from someone who isn't driving in Driver
only. Those land at once now too. The sender's look still puts back a timeline change that isn't its sender's to make.

### Stayed

- **Enforcement where the edit is made**, untouched: `W.refuse` (put-backs and their copies), claimask's asks, holds, Keep and cooldown,
  auto-claims and their lapse, the Driver only and Admins only refusals, the web pages' refusals (`lib/dawedit.lua`), `maker_may`.
- **Format deferral** (`sync.too_new`): a change this version can't read, or one the floor holds, waits in `sync.deferred` as before.
- **`sync.authority`'s `at` and the same-second rule.** Receive no longer refuses with them, but they now decide the claimer's word, below.
  Without them, a claim made in the same second as a crossing edit, or after it, would wrongly say "didn't ask". The comment says so.
- **`unasked` on the wire.** The sender still marks a change it sent past an unreachable auto-claimer. It now changes only which words the
  claimer sees.
- **`sync.obj_allowed`.** It's now used only for the word.

### The "didn't ask" word

`past_mine` in `sync.receive`, worked out before the change lands (for a rename, the claim is on the name the track has here) and said
after it lands:

- It applies only to a bandmate's object change in a room where claims bind (not Driver only, not Open), when this computer held the claim
  at the change's time (`at`) and the change wasn't its sender's to make then.
- With my auto-claim, a change that merges goes out unasked by design, so nothing is said. The word comes only when the change says it
  went out `unasked` (the direct link couldn't reach me).
- The wording is "<who> changed / deleted / renamed <thing>, which you've claimed[, to <new name>]: their StudioSync didn't ask" or
  "...couldn't reach you to ask". It's said once a minute per project, person and thing.

**`asked` (the claim_answer id) was not added.** Under the floor it's moot. A change that went out on an answer reaches the claimer's
computer after the claimer has let go: `claimask.answer` takes the thing out of their claims file before it replies Release. So that change
is never judged past the claimer's claim there, and the word never comes. Only the claimer's own computer says the word, so a third
computer has nothing to say either. A modified StudioSync could fake `asked` anyway.

## 2. The floor simplification

The design kept `set_back` for a sender too old to ask (before 0.59.49.74), recognised by a new field `v` on every change. The version floor
(rt-floor) already holds every object change from a StudioSync below the floor: a lower `lv`, or no `lv` on a change made since floors
began. Such a sender's edit never lands, so there is nothing to answer.

- `set_back` is gone, and nothing current depended on it. The only other user was `test_0_60_rt_rank` 11, which used it to record a version
  without putting it in place. That test now writes the record directly, the way `set_back` did.
- No `v` field was added.
- The changes that can still reach a claim without asking are: claims crossing in the same moment, an auto-claim whose claimer the link
  can't reach (rt-fix6a's rule), and a modified StudioSync. James's decision 1 names these. The word shows them.

## 3. Task 2: the timeline after a restart

**Cause.** `sync.newest_map` picks the single timeline change a receive pass applies. Every other timeline change is marked done as
superseded. It looked at every timeline change waiting, including ones this version won't apply: `sync.too_new`, which covers a newer
format and, since rt-floor, anything the floor holds. Right after a deploy that raises the level, the room's newest timeline change was
made at the old level. So:

1. The floor holds it, and it waits unapplied.
2. It is still picked as the newest, so every older map is marked superseded.
3. A computer that restarted onto an older file applies no map at all, and keeps its file's map until someone changes the tempo again.

Both sightings came right after a level rise:

- rt-sync2g: 0.63.1 was level 13. The desktop's own 100 bpm marker had been made at level 12, and the desktop never took it back.
- rt-fixlive2's f4 prep: 0.65.0 was level 14. LinuxBox wasn't on the one-marker 120 bpm map within 90 s. It agreed once the tool sent a new
  change at level 14.

The plain case already worked. In this round's probe (117 bpm, both REAPERs restarted onto their files), both computers were on 117 within
a second of opening.

**Fix (6cf450f).**

- `sync.held_by_floor`: a timeline change that carries a level isn't held. The floor exists for what goes into a hash (`mirror.HV`) and for
  the event format (`band.FORMAT`, which `too_new` checks on its own). A timeline has no hash. Its shape is versioned by `TIMELINE_FORMAT`,
  which hasn't changed since before floors. A timeline change with no `lv` made since floors began is still held, because that code is
  unknown.
- `sync.newest_map` only considers a map this version can apply. A map it can't read (a newer format) waits for the update and no longer
  keeps the newest readable map out.

**Test.** `test_0_61_rt_floor` 9 (see the knock-out table below).

## 4. Tests and knock-outs

Each knock-out was made in the tree (or in a `git archive` of 9d4d353 with the new tests copied in), the test was run, and the code was put
back.

| Part | What | Knock-out -> fails at |
| --- | --- | --- |
| converge 25 (rewritten) | a change past a lasting claim lands on a third computer at once | 9d4d353's lib -> "lands at once as well (was: held back a minute...): 5" |
| converge 39a (new) | past my lasting claim: lands on Cee's and on mine at once; I'm told; my computer sends nothing back | 9d4d353's lib -> "Bee's move lands on Cee's at once ...: 1"; `past_mine` returning nil -> "James is told who didn't ask" |
| converge 39a, once a minute | a second move at once isn't said again; a minute on it is | the 60 s gate taken out -> "a second move at once lands, said once already" |
| converge 39b | a merge past my auto-claim lands and isn't news; one marked `unasked` says "couldn't reach you to ask" | the auto-claim exclusion taken out -> "a merge past his auto-claim lands and isn't news" |
| converge 39c | after my release (an ask answered), nothing is said | (guard) |
| converge 39d | a non-driver's timeline change in Driver only lands at once | 9d4d353's lib (39a-c disabled) -> "Bee's tempo lands on Cee's at once though James drives (was: a minute): 120" |
| converge 2 | `at` still judges a change by the claims of its time (messages reworded: it now decides the word) | (unchanged assertions) |
| edits, the rename block (rewritten) | a rename of a lastingly claimed track by a StudioSync that didn't ask lands on all three at once, the claimer is told, nothing is answered, the claimer's own rename lands | 9d4d353's lib -> "a bandmate's computer takes the rename at once"; `past_mine` returning nil -> "its log says who didn't ask" |
| fix6a (pure part) | `gone_before_claim` and `refused_since` are gone; part 2 (the deletion lands within three passes) still passes | 9d4d353's lib -> "no refusal on receive" |
| bounds | `refused_since` gone (its bounding test went with it) | 9d4d353's lib -> "no refusal minute on receive" |
| rank 11 | the order comes from the versions held (the record now written directly) | (adapted, passes either way) |
| floor 9 (new) | a newest map made a level lower lands; an object change a level lower and a timeline with no level are still held; a newest map of a newer format doesn't keep the newest readable one out, and waits unmarked | `held_by_floor`'s timeline exception taken out -> "the room's newest map lands though it was made a level lower ... (100)"; `newest_map`'s `too_new` filter taken out -> "a map this version can't read isn't picked as the newest ... (120)" |
| soak `rename-redo-claim` | 127's class: the Redo stands on all three | was "fails, as it says" at 9d4d353; "today" is now "passes" |
| soak `rename-redo-autoclaim` | 6006's class | passes before and after: it no longer needs `soft_ok`. Text updated |

**Seeds 127 and 6006** (§7's targets): `soak.py --seed 127 --edits 40` and `--seed 6006 --edits 150` pass on this build. They also pass at
9d4d353 (checked from a `git archive`), because earlier rounds changed the soak's draws since rt-converge. What pins the classes now is the
two scenarios above: `rename-redo-claim` flips from fails to passes.

## 5. Gates

| Check | Result |
| --- | --- |
| `tests/run.py --no-luals`, local time, at 739dc82's tree | fails 1: `rt_bigproj` timing (35.0 ms against 31 ms), run while the live set restarted REAPER and the soak ran. It passed on its own right after, and in the `TZ=UTC0` run of the same tree |
| the same, `TZ=UTC0`, at 739dc82's tree | **fails 0** |
| `tests/run.py --no-luals`, local time, at 6cf450f's tree | **fails 0** |
| the same, `TZ=UTC0`, at 6cf450f's tree | **fails 0** |
| `soak.py --scenario all` at 739dc82's tree | 20 scenarios, 19 as they say; `rename-redo-claim` passed though it said it fails, and its "today" was set to passes in the same commit |
| `soak.py --scenario all` at 6cf450f's tree | **20 of 20 as they say** |
| long soak, `range.py` from a fresh clone of f0e37c9, 8 procs (no other `range.py` / `soak.py` running: checked) | **237 of 237** (baseline 237). This doc's commit changes nothing the soak runs |
| `files_check` / `release_check` | notes only, as at 9d4d353 (`lib/files.txt` is made at release) |

**hv and LEVEL:** unchanged (14 and 14). Nothing that goes into a hash changed, and no field was added to the wire. The `lv` rule for
timeline changes changes only what a computer at the floor holds. No hv or level change is needed for it: older computers keep holding, so
they behave as on 0.65.1.

## 6. Live results

All runs used `--on d,x` (laptop off), `X_IP=192.168.86.129`, with Mute me and Deafen on (setup checks this) and nothing saved. Both
computers run **0.65.1**: this build isn't deployed. So these runs show what the old build does and confirm the checks catch it.

**Probe (task 2's plain case, on 0.65.1).** 117 bpm set on the desktop, then `live.py restart --on d,x` and `song`. Both were on 117 within
1 s of opening: the desktop through session.json's "this project was behind the studio's copy", LinuxBox through Open session's catch-up.
This is not the bug, which led to the floor cause above.

**`sync2h` on 0.65.1** (report `tools/live/reports/sync2h-20261128-065851.json`, not committed):

| Scenario | Result | What it shows |
| --- | --- | --- |
| h1 asked | **pass** | 2.3 s from LinuxBox's Release to the desktop's edit landing there; no "didn't ask" |
| h2 a claim crossing an edit | fail (expected on 0.65.1) | 63.5 s from reconnecting to the edit landing on LinuxBox: the refusal minute this round removes |
| h3 Redo of a rename vs a claim (127) | fail (expected on 0.65.1) | LinuxBox answered: "James renamed ... Drums, which you've claimed, to ... T1, without asking ...: the name is put back for everyone". That's `set_back`, now gone |
| h4 restart timeline | a: **pass** (both on 117 1 s after Live sync ran); b: fail (expected on 0.65.1) | the room's newest map made at lv 13 (113 bpm), then both REAPERs restarted: both stayed on 117 for 60 s. That's task 2's bug reproduced live |

Afterwards both computers were on 120 bpm, the hand-written event was gone on both, and the room was back to Open.

## 7. Known limits

- **A modified StudioSync that leaves out its ask can edit your claim.** You're told, but the change stands. Binding, signed claims are
  option C on the security list (James's decision 1).
- **No word for a clash past my auto-claim.** A clash that a modified client sent without asking, or without saying `unasked`, lands
  silently: the word for my auto-claims needs `unasked`.
- **The word is per computer.** A third computer says nothing about a change past someone else's claim.
- **A timeline change made by a StudioSync from before floors** (no `lv`) after floors began is still held. Only James's computers ever ran
  one.
- **Driver only and Admins only.** A non-driver's change from a modified client lands at once and nobody is told. The word covers claims
  only.
- **Computers that already marked older maps superseded** while a held newest map waited: the held map lands now (fix part 1), so they end
  on it. A computer on 0.65.1 or older in the same room keeps holding it until it updates.

## 8. Live scenarios to run after deploying this build

Deploy to the desktop and LinuxBox together, then run `live.py restart --on d,x`, `song`, and `up` (it should show the new version on both).
Then:

| Run | Expect |
| --- | --- |
| `sync2h --on d,x` | h1 pass (as on 0.65.1). h2 pass: the edit lands within seconds of Syncthing or the link bringing it, and LinuxBox's log says "... which you've claimed: their StudioSync didn't ask". h3 pass: T1 on both, and LinuxBox's log says "renamed ..., which you've claimed, to ...: their StudioSync didn't ask". h4 pass: a, and b with both on 113 within 60 s |
| `sync2f -k f8` first, before h4 | pass: nothing goes out in 120 s (this build adds nothing to send) |
| rt-fixlive2's rechecks | as on 0.65.1 |

## 9. Recommendations (ranked)

1. **Deploy this build to the desktop and LinuxBox together and run `sync2h`.** h2, h3 and h4b are the checks that flip. Run h4 last: it
   restarts both REAPERs.
2. **Check the other non-hashed kinds against the floor the same way.** Notes, likes, cues, handovers and inserted time are still held when
   made a level lower, which only matters right after a deploy. `shift` (inserted time) is the one worth a look: it moves items, and it
   carries no hash.
3. **The desktop's autostart logs dozens of "skipped a change from James that StudioSync can't read" lines at each restart** (seen in the
   probe: James's events from 12:37-13:18Z today). They fail `readable` in receive (checked after `too_new`, so they aren't held ones).
   Find out which field fails: not looked into here.
4. **A word for Driver only and Admins only** past-the-mode changes, if a modified or test client ever matters: the same `past_mine` shape,
   keyed on `obj_allowed` with no claim.
5. **Claims by track id** (rt-sync2 Recommendation 4) would end renames moving claims around. It's no longer needed for 127 and 6006.
