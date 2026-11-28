# rt-sync2j: phase 8, timers into facts and Health compares contents; two loose ends (2026-11-28)

rt-sync2's phase 8 (`docs/rt/rt-sync2.md` §5b, §5c, §9), plus rt-sync2h Recommendation 3 (the restart log) and rt-fixlive3's Restore
count. On top of 05fd64a (0.65.3, hv 14, level 14). **No hv or level change**: nothing that goes into a hash changed, and the event format
didn't; the status gains two fields and the link two message shapes, which an older computer ignores. Nothing deployed, released, pushed or
version-bumped; `lib/webui.lua` and `lib/webui/index.html` (someone else's) untouched.

## Summary for James

- **The restart log's "skipped a change ... that StudioSync can't read" lines are gone (once deployed).** They were every deletion in the
  song, at every restart: 295 on the desktop's last one. Cause: REAPER's startup file runs the REAPER Daemon bridge before StudioSync in the
  same Lua, and the bridge's own `json` module was the one StudioSync got there. That module reads JSON's `null` as nothing, so a deletion
  (which has no state) looked unreadable. StudioSync now always uses its own.
- **History's Restore says the right count.** "Bringing back 668 changes" for two changes was every object the song ever had. It now counts
  only what really changes.
- **Computers that hold different songs put it right at once**, only for the part that differs, instead of after a minute and at most every
  5 minutes. Each computer now says a code for what its song holds (and 16 smaller ones), so StudioSync can tell which part differs.
- **A bug class StudioSync couldn't see before now shows:** "the same changes, a different song" (Health has a new row, and the log names the
  objects), and "drift here", where REAPER holds something other than the version StudioSync thinks it holds. That one is put back, with a
  line saying so once.
- **A change a computer is missing is asked of the bandmates by name at once**, and if none has it, nobody waits two minutes for it.
- **To see it live: deploy this build to the desktop and LinuxBox, then run `sync2j`** (end of this doc). Nothing to do by hand.

## Commits

| Commit | What | Fails without it |
| --- | --- | --- |
| aebc33a | `lib/band.lua`: StudioSync's own json in Autostart's Lua (`band.json`; `sync.readable` a module function; signedwrites on it) | `test_0_60_rt_json_own` (new) |
| d71c627 | a track's deletion keeps or takes your items by facts: `asked_of`'s 60 s and `just_made_here`'s 120 s gone | `test_0_60_rt_delete_race` (the asked_of block, the no-list case) |
| 0ef44be | what the judge lacks, and a file that doesn't read, asked of the bandmates by id (`lib/needlist.lua`) | `test_0_60_rt_health2` 1 (new) |
| 16800eb | the content code and 16 bucket codes in the status; heal at once in the buckets that differ; "same changes, different song" noted (Health row, log) | `test_0_60_rt_health2` 2, 3 |
| 16e34fb | drift here: the look puts the version held back and says so once; `mirror.test_drift` (the test-only fault) | `test_0_60_rt_health2` 4 |
| 981da80 | `mirror.revert`: a Restore's slices count what really changes | `test_0_60_rt_health2` 5 |
| 1d7ea20 | `tools/live/sets/sync2j.py`: j1-j4 | live (below) |
| 3ffa602 | `mirror.contents`: a change is named by its id; only a merge is read and hashed | `test_0_60_rt_health2` 2 (the unread count) |
| (this doc) | docs/rt/rt-sync2j.md | |

## 1. §5b, the timers, as they now stand

The rule: a timer may decide when something happens, or whether this computer sends; never which version anyone holds. Each row checked in
the code at 05fd64a first (grep of the name and its use), then after this round.

| Timer | At 05fd64a | Now | Kind |
| --- | --- | --- | --- |
| `TEMPO_SECS` 15 | gone (rt-sync2f: beats) | gone | |
| `MAP_WAIT` 30, `tl` | gone (rt-sync2f) | gone | |
| refused 60 s (`refused_since`) | gone (rt-sync2h, option A) | gone | |
| merge wait 120 s (`merge_for`, `gone_race`'s `first_seen`) | gone (rt-sync2b); the judge's "incomplete", trimmed by id age (`MERGE_DAYS`), `WAIT_MISSING` 120 s as the bound before what's missing counts as trimmed | **plus the ask by id**: what's missing is asked of every bandmate here at once; once every one asked says it hasn't it, it's trimmed at once. `WAIT_MISSING` stays only for when nobody here answers | when (an interim answer: once the version arrives the object is judged again) |
| heal 60 s apart + 5 min | Live sync `P.heal`, by the `mirror` codes | **gone**: `mirror.heal_plan`, the content code differing from a caught-up bandmate's (both caught up): heal at once, only the buckets that differ, once per difference. `HEAL_AGAIN` 300 s: when a heal that changed nothing is tried again for the very same codes | when |
| `ORDER_WAIT` 120, `APART_SECS` 30, `ORDER_IDLE` 10 | still in `mirror.order_heal`; in a ranked room the order is the rank tree's (rt-sync2c, d) whatever lands when | unchanged: they only decide *when* the tree is sorted again (and when Health's "apart" row shows), never which order | when |
| `MERGE_NEWS_SECS` 3600 | gone (rt-sync2b: `JUDGE_SINCE`, grandfathered history) | gone | |
| `just_made_here` 120 s, `asked_of` 60 s | in `mirror.apply`'s track deletion (the deletion's `items` already named its items since rt-sync2b; these were the rest) | **gone**: an edit held for the deleter's answer goes when the last look held it so (`asked_of`, cleared by every look of the object that doesn't hold it again) and the deletion names it; new work the deleter never had (not named, every version yours) is kept however old | |
| `RENAME_BACK` 600 (`set_back`) | gone (rt-sync2h, the floor) | gone | |
| `SESSION_SECS` 30 | stays | stays | sender-side |
| `EDIT_SECS` 30 | stays | stays | sender-side, auto-claims |
| `FX_LOAD_SECS` 60, `FX_SET_GAP` 5 | stay | stay | send decision; a wait |
| `ACT_SECS`, `ACT_KEEP` | stay | stay | sender-side |
| `UNREADABLE_SECS` 600 (`sync.receive`) | a file still unreadable after 10 minutes is skipped | **asked of the bandmates by id first; skipped at once when every one asked says it hasn't it**; 600 s stays for one they do have (a cloud drive still writing it here) or when nobody answers | when |
| `CUE_OLD`, `AUTO_IDLE`, `GONE_WAIT`, `ASK_WAIT`, `COOLDOWN`, `CONFIRM`, presence 45 s | stay | stay | human and session rules |

Unrelated names that share a word: `drive.lua`'s `first_seen` (a file missing on the cloud drive) and `services.lua`'s `UNREADABLE_SECS` (a
saved Tailscale token that won't unlock) aren't sync timers.

## 2. What was built

### The content code and its buckets (`mirror.contents`, §5c)

- A hash over each held object's `oid=version:content`, in the status beside `mirror` as `content`, and 16 bucket codes (`bk`, 6 hex digits
  each, oids grouped by the first hex digit of their own hash: `mirror.bucket_of`).
- **What a version holds:** a change is named by its id (a change never changes, so nothing is read for it); a merge by its state hashed
  as this computer puts it together. So equal `mirror` codes with different content codes on two caught-up computers mean the judge put the
  same changes together into different songs. (§5c named a change's own `hash`; reading every held change's file, state and all, at each
  start bought nothing an id doesn't say: commit 3ffa602.)
- Held as `mirror.root` is (until the project's change count moves, this script writes a record, or 10 s pass).

### Heal at once (`mirror.heal_plan`)

- Live sync's `P.heal` (and the soak's node): when this computer and a bandmate both have every change and their content codes differ,
  heal now, only the objects in the buckets that differ (`mirror.heal`'s new `only`). Once per difference (the codes on both sides); the
  same difference again after `HEAL_AGAIN`. Only with the tab in front, as before.
- **"Same changes, different song":** a bandmate whose `mirror` equals ours and whose content code doesn't, with every held merge readable
  here, is noted (`mirror.judge_apart_note`): non-persisted ExtState `content apart <proj>` = who|merged objects in the differing buckets,
  read by Health's new row "The same changes make the same song here" (red, "That's a bug in StudioSync: please report it. Restore > Restore
  whole project to here brings everyone in line"), and logged once per bandmate and objects. Never healed: heal can't fix the judge.
- Health's "come out the same here" text no longer says "after a minute, at most every 5 minutes".

### Drift here (`W.one`, §5c)

- Once per record, an item or automation that REAPER reads as its record says, but whose held version holds something else
  (`W.reads_as`: the look's re-anchoring comparison, now a function), gets the studio's version back through the look's own put-back: once
  per version held, nothing sent. Said once (`sync.put_back`: "An item on Keys here wasn't the studio's version of it (nothing you did):
  it's put back as the studio has it"), and only when the put-back changed something here.
- Left out: plug-in chains (they read back their own way per computer), tracks (their folder and place are the tree's), stand-ins, a pick
  that hasn't travelled yet (`only_pick_new`), print labels.
- `W.reads_as` no longer takes a merge's `hash` (its winner's, copied by `event_file`) for what the merge holds.
- **The test-only fault:** `mirror.test_drift(proj, oid, room_dir, local_mix)` writes the object's record naming the version it holds
  under REAPER's reading of it as it is now. Change the object first, in the same script step, and the look takes it for the band's.

### Asked by id (`lib/needlist.lua`)

- `needlist.want_id(room_dir, id[, there])`: from `mirror.judge` (each id an incomplete answer waits on) and `sync.receive` (a file that
  doesn't read, `there`). Live sync's needlist tick asks every bandmate here not asked yet ("need_ask" `{ want = { room, ids } }`, the shape
  the event catch-up uses), every tick while something is wanted.
- The bandmate's `serve_events` sends the files it has (as before) and now answers which ids it hasn't (`"need_list" { dev, room, none }`).
- `needlist.gone_everywhere(room_dir, id)`: every bandmate asked said it hasn't it. Then the judge gives up waiting at once and receive
  skips the file at once.

### Loose end 1: the restart log (`lib/band.lua`)

Found live: every one of the 242 (later 295) ids the desktop's autostart logged was a **deletion** in "LV Checks" (`gone`, no `state`,
format 2, level 14). In the eval hook the same files pass `readable`. Scripts/__startup.lua dofiles the REAPER Daemon bridge before
StudioSync's Autostart in one Lua, and the bridge's `bridge/json.lua` was `package.loaded.json` there. It has no `null` (it decodes `null` as
nil), so `ev.state ~= require("json").null` was `nil ~= nil` for every deletion. Autostart's `band.lua` also decoded and encoded everything
with the bridge's json. Now `band.lua` loads StudioSync's own `json.lua` (marked `STUDIOSYNC`) by path when the loaded one isn't it, as
`band.json`; `sync.readable` and `signedwrites` use it. The bridge's json is left in `package.loaded` (its watchdog reloads it from there).
Each skipped deletion was marked done in the unsaved project, so nothing was lost: the next save would have kept them as done.

### Loose end 2: the Restore count (`mirror.revert`)

A whole-project Restore's plan names every object the room ever had. What's already as the plan has it (gone then and gone now, or held at
that very version: `one()` never touched those) is left out of the list before the slices' count. On 0.65.3, live: "bringing back 668
changes", ended "2 change(s) brought back".

## 3. Tests and knock-outs

`tests/test_0_60_rt_health2.lua` (new):

1. what the judge lacks is asked of both bandmates by id, once each; after one "hasn't it" it still waits; a computer that isn't here isn't
   counted; after both, the answer is complete at once; the bandmate's side answers which ids it hasn't; a file that doesn't read is wanted
   by id and skipped once both say they haven't it
2. the content code and buckets equal on two computers; a change marked done without landing (a skipped change) makes them differ in its
   bucket alone; heal is due at once in that bucket, once per difference, again after `HEAL_AGAIN`, never while changes are still to land;
   heal brings it in and the codes agree; a held change whose file isn't here is neither read nor unread
3. both hold the same merge; with Bee's merge content made different, the same `mirror` and another content code; noted with the merged
   object, logged once; the note goes when the songs agree again
4. the fault on Bee's (item moved, record swapped): the look puts it back to 4 s, nothing sent, said once, not again
5. a sliced Restore with three objects in the plan, one of them a real change: "bringing back 1 changes", ends "1 change(s) brought back"

`tests/test_0_60_rt_json_own.lua` (new): another script's json (no `null`) in `package.loaded` before band: `band.json` is StudioSync's,
the other is left loaded, a deletion is readable, a state that is JSON's `null` still isn't, signedwrites loads.

`tests/test_0_60_rt_delete_race.lua`: a new block (held for Al's answer ten minutes, Al deletes the track naming it: it goes; held for Bo:
kept; not named: kept) and the no-list case now keeps both of my items. `test_review95`'s `just_made_here` asserts went with it.

Knock-outs (each made in a scratch copy of `lib` and `tests`, the test run, the copy thrown away):

| Knocked out | Fails at |
| --- | --- |
| band.lua's own-json load | json_own "band.json is StudioSync's own" |
| `sync.readable` on `require("json").null` | json_own "a deletion reads" |
| `asked_of` by the 60 s again | delete_race "held for Al's answer ... it goes, held ten minutes or not" |
| a no-list deletion keeps nothing of mine | delete_race "no list: both of mine stay mine, however old" |
| the judge's "gone everywhere" | health2 1 "neither has it: it counts as trimmed at once" |
| receive's "gone everywhere" | health2 1 "nobody has it: skipped at once" |
| the "none" answer | health2 1 "it answers which ids it hasn't" |
| asking by id | health2 1 "asked of both bandmates at once, by id" |
| heal once per difference | health2 2 "once per difference" |
| heal after a minute (the old wait) | health2 2 "heal is due at once" |
| `judge_apart_note` | health2 3 "noted for Health with the merged object" |
| drift here | health2 4 "the look puts the studio's version back: 7" |
| the Restore filter | health2 5 "it says the one real change (was ... 3)" |
| a change's content its id | health2 2 "a change held whose file isn't here: not read, not unread" |
| drift "said only when it changed something" | not caught: no stand-in case reads differently yet lands the same |

## 4. Gates

All from a fresh clone of 3ffa602 (the last code commit; the live set and this doc change nothing the tests or the soak run).

| Check | Result |
| --- | --- |
| `tests/run.py --no-luals`, local time | **fails 0** |
| the same, `TZ=UTC0` | **fails 0** |
| `soak.py --scenario all` | **21 of 21 as they say** |
| `soak.py --quick`, `detcheck.py` (inside run.py) | ok, ok |
| long soak, `range.py <clone> --procs 8` (no other `range.py` / `soak.py` running: checked) | **237 of 237** (baseline 237). The oracle now also checks content codes agree at quiet: no seed differed |
| `files_check` / `release_check` | notes only, as at 05fd64a (`lib/files.txt` is made at release) |

`rt_bigproj` and `rt_drivebg` passed in both runs, so no A/B against 05fd64a was needed. The drift commit's tree (16e34fb) was also run
whole before it was committed: fails 0, 21 of 21 scenarios.

## 5. Live results

All runs `--on d,x` (laptop off), `X_IP=192.168.86.129`, in "LV Checks" (Open), Mute me and Deafen on, nothing saved. Both computers run
**0.65.3**: this build isn't deployed, so these show the old behaviour and that the checks catch it.

| Run | Report | Result | What it shows |
| --- | --- | --- | --- |
| j4 Restore count | `sync2j-20261128-113030.json` | fail (expected on 0.65.3) | "bringing back 668 changes" for a Restore that ended "2 change(s) brought back" (2362 rows in History) |
| j3 restart log | `sync2j-20261128-113221.json` | fail (expected on 0.65.3) | `live.py restart` + `song`: the desktop logged 295 "skipped a change from James that StudioSync can't read" lines |
| j1, j2 | | not run | they need `mirror.contents` / `mirror.test_drift` on both computers and stop at once on 0.65.3 |

Also checked live: the 242 ids of the 10:16 restart were all deletions (189 tracks, 53 items), all readable in the eval hook's Lua, so the
fault was Autostart's Lua, which led to the bridge's json.

**After deploying this build to the desktop and LinuxBox** (`live.py restart --on d,x`, `song`, `up` shows the version on both):

| Run | Expect |
| --- | --- |
| `sync2j --on d,x` | j1 pass: the two status files' `content` and `bk` equal, both pending 0. j2 pass: LinuxBox's item back at 3 s within a look or two of the fault, its log says "wasn't the studio's version" once, History shows no new change for the item. j3 pass: no "can't read" line on either after the restart. j4 pass: the slices' count equals the end's (2 or so) |

## 6. Known limits

- **Drift here covers items and automation only.** Plug-in chains read back their own way per computer, and tracks' folders and places
  are the rank tree's. A first look after a restart compares each item once (a string compare for nearly all; the normalised compare only
  where REAPER's reading and the version's hash differ).
- **The drift put-back makes an undo point** ("StudioSync" put-back) even when it changed nothing visible; it's once per object version.
- **"Same changes, different song" names the merges in the differing buckets**, not exactly the ones that differ: a bucket with several merges
  names them all. Finding the exact ones would need the bandmate's bucket lists over the link (§5c's ask); not built.
- **An unreadable file a bandmate does have** still waits 600 s: its copy lands in the link's inbox, but the folder's (damaged) copy is
  the one read. A file nobody made is skipped at once.
- **Asked by id needs the direct link** (`needlist.on`, a bandmate here). Without it the 120 s / 600 s bounds are as before.
- **Heal's "once per difference"** means a heal that couldn't land something (playing, its tab behind) is tried again for the same codes
  only after 5 minutes, or as soon as either code changes.
- **The order heal's timers are unchanged**: they only decide when the rank tree is sorted again.
- **The test-only fault exists in the shipped code** (`mirror.test_drift`); nothing calls it outside tests and the live set.

## 7. Recommendations (ranked)

1. **Deploy this build to the desktop and LinuxBox together and run `sync2j --on d,x`.** j3 and j4 flip from fail to pass; j1 and j2 run.
   Run j3 last: it restarts both REAPERs.
2. **Read the inbox copy when the folder's copy of an event doesn't read** (`mirror.light_event`'s `lazy_state`, `plain_event`,
   `sync.receive`). Then the ask by id fixes a damaged file at once instead of after 10 minutes.
3. **The bucket lists over the link** (§5c): ask a bandmate for its `oid=version:content` lines in the buckets that differ, so "same changes,
   different song" names exactly the objects that differ, and Health can show what differs for any "apart".
4. **Drift here for tracks**, through `mirror.same_line` with the rank tree's folder and place left out, once the item case has run live.
5. **Warn the REAPER Daemon bridge's owners** that its `json` sits in `package.loaded` for every script `__startup.lua` runs after it.
   StudioSync no longer cares, but another script might.
