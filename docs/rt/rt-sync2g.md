# rt-sync2g: phase 5's follow-up from the real-REAPER live checks (2026-11-28)

rt-sync2f's live checks (`tools/live/sets/sync2f.py`) ran on 0.63.0 on the desktop and LinuxBox and passed 2 of 8 (f2, f7). This round
finds each failure's cause, fixes StudioSync where it was StudioSync and the live tool where it was the tool, and answers rt-sync2f's open
question about auto-stretch and stretch markers by measuring REAPER itself. On top of 1b0f3b5. Hash version and level go to 13 together.
Nothing deployed, released, pushed or version-bumped; `lib/webui.lua` and `lib/webui/index.html` (someone else's) untouched.

## Summary for James

- **A tempo change inside an item no longer re-sends it.** REAPER keeps an item's fades and snap offset on their beats where they sit, not
  as a share of the item's length. StudioSync assumed the share, so any tempo marker inside an item (the fade-out after it) made the item
  go out again. Now it reads them as REAPER keeps them.
- **Auto-stretch band audio stays quiet too.** When a tempo marker lands inside an auto-stretch item REAPER adds stretch markers of its own;
  StudioSync now leaves those out of what it sends and lets each computer's REAPER make them from the map, which gives exactly the same item
  (checked on Windows and Linux).
- **The "automation values read 0" failure was the live tool's**, not StudioSync's: it wrote volume points in the wrong units (a gain of
  about -190 dB), which REAPER itself saves as 0.
- **The "track re-sent every 40 s" was the live tool's too**: it counted the laptop's old files (named "James-Laptop-...") as the desktop's
  ("James-..."). Nothing was being re-sent.
- **The live tool now clears leftover test tracks first**, waits for that to settle, doesn't hang when the laptop is off, and c3 checks what
  StudioSync does on a reopen rather than a REAPER fact that never changes.
- **Update every computer together**: this build is level 13. A level-12 computer sends nothing until it updates. Updating sends nothing:
  history from 0.63.x is read the new way.
- **Two new problems seen live on 0.63.1, not fixed here.** In the live song's tab REAPER keeps track automation in seconds at a tempo
  change (a new tab moves it), so the desktop re-sends automation after a tempo change (f1, f6). And c3, rewritten, shows a reopen in the
  same tab isn't always caught: once the track the file lacked never came back on the desktop.
- rt-fixlive1's rechecks on 0.63.1: c1.2, c1.4b, c1.4c, c5, c11, c12, d1, e4, floor f3 (after a tool fix) and f6 pass.
- Not yet seen live: fixes 1a and 1b need this build deployed (the orchestrator's). Run list below.

## Commits

| Commit | Fix | Test or check that fails without it |
| --- | --- | --- |
| 79b24c2 | finding 1a: snap offset, fades and their auto lengths in quarter notes where they sit (`lib/beats.lua`); the stand-in REAPER moves them so (`tests/fixtures/editreaper.lua`, the soak's too); hv 13, level 13; hv-12 items read into today's form (`beats.upgrade12`, `beats.near` in W.one's re-anchor) | `test_0_61_rt_beats` 2 (a marker inside Gtr), 3, 6, 9 |
| 66a67b7 | finding 1b: stretch markers in quarter notes; a take with its own markers keeps its rate; an auto-stretch item's own (REAPER-made) markers left out and made again on landing (`beats.rewarp`) | `test_0_61_rt_beats` 10 |
| 1cef0a4 | finding 2 (tool): `LV.env_add` / `env_points` in gains, through the envelope's scaling mode | live sync2f f1, f3, f6 prep |
| e213ed0 | finding 3 (tool): `LV.events_since` reads only the writer's own files; soak `idle-leftover-track` | live sync2f f8 |
| 194e149 | finding 4 (tool): setup clears every `LV ` track and waits quiet; `peer_ips` can't hang on a laptop that's off; a passed retry drops its failed why | live sync2f f4/f5 (leftover re-sends), f8 first try |
| 0af4b91 | finding 4 (tool): sync2c c3 checks that StudioSync sees a reopen | live sync2c c3 |
| 322ffa8 | (tool) floor f3: StudioSync's own Undo path for the refusal; waits for the bandmate's event file | live floor f3 on 0.63.1 (fail -> pass) |
| 91bc612 | (tool) sync2f: the tempo back to 120 on every computer, through 121 when only the desktop has it | live sync2f f1 on 0.63.1 ("the computers differ") |
| (this doc) | docs/rt/rt-sync2g.md | |

## REAPER, measured

Every fact below was read on the desktop's REAPER 7.86 and LinuxBox's REAPER 7.86 through the dev hook, in a new project tab of its own (never
the song's), closed without saving (`Main_openProject("noprompt:")` of the tool's empty project, then the clean tab closed); the WAV it used
was deleted after. Project timebase beats (position, length, rate), 120 bpm, an audio item at 10 s, 6 s long.

| Case | What REAPER did at the tempo change |
| --- | --- |
| a 90 bpm marker at 10.5 s, no stretch markers | length 6 -> 7.8333; rate 1 -> 0.766 (rate x length kept); fade in 1 -> 1.1667, its auto 0.8 -> 0.9; fade out 0.5 -> 0.6667, its auto 0.4 -> 0.5333; snap offset 3 -> 3.8333 (each span keeps its quarter notes where it sits: a share of the length would give 1.2222 for the fade in); take envelope points unchanged |
| the same, a marker at 4 s (before the item) | the same rule: everything x1.333 (where the two rules agree, which is why f2 passed) |
| stretch markers of the take's own (1/1, 3/2.5) | rate kept at 1; each marker kept on its beats (1 -> 1.1667, 3 -> 3.8333); two more added, at 0 and at the end (7.8333 / 5.5: the last segment now fixed); take envelope points moved on their beats too |
| auto-stretch (C_AUTOSTRETCH 1, chunk `IMPLIEDWARP 1`), no markers | rate x length kept; REAPER added markers of its own at the item's start, the tempo marker and its end, each flagged `0 1` (`SM 0 0 0 1 + 0.383 0.5 0 1 + 6 6 0 1`); a second change (f4's 90 -> 80) moved them in take time with the rate (1.636 -> 1.5) and kept their quarter notes |
| those markers taken out of the chunk, then C_AUTOSTRETCH set 0 and 1 | the very same chunk back (both computers): REAPER makes them from the map alone |
| a track's volume automation, track timebase -1, 1 and 0 | points kept on their beats for -1 (the project's: beats) and 1; in seconds for 0 |
| a volume envelope in fader scaling (VOLTYPE 1) | the API's values are raw, 0 to 1000 (716.2 = 0 dB); a raw 0.5 is a gain of 2.5e-10, which the chunk writes as `PT 8 0 0`, and that chunk set back reads 0 |

## Each finding: cause, fix, test

### 1. Fades (and snap offset, stretch markers) follow the local tempo (f4, f5)

**Cause.** `lib/beats.lua` (rt-sync2f) kept an item's snap offset and fades as fractions of its length. REAPER keeps each span's beats where
it sits (table above). With a tempo marker inside an item, the fraction changes (f4: FADEOUT 0.01 -> 0.0133 while the length went 6 ->
7.333, x1.333 against x1.222), so the canonical text changed and the item went out after every tempo change inside it, on every computer
that had it. f4 also saw REAPER's own stretch markers appear and move in the auto-stretch item's SM line, which was carried as written (take
time), so it changed too.

**Fix (79b24c2).** Mode 1's snap offset, fade in and its auto length are quarter notes from the item's start; the fade out and its auto
length are quarter notes back from its end (f9). Written back with the receiver's own map; a value one microsecond from a round one is
written round only where that reads back as the same text (the 5022 rule, now with `qn` passed to `item_seconds`). The stand-in REAPER
(`tests/fixtures/editreaper.lua`, which `tools/soak/node.lua` uses for REAPER's move) moves them the same way, so the soak sees it. First the
stand-in, then the test, seen failing on 1b0f3b5's `lib/beats.lua`: `test_0_61_rt_beats` 2, "a 90 bpm marker at 12 s, inside Gtr: nothing but
the timeline goes out (1: I-...)".

**Fix (66a67b7).** Each stretch marker's place is quarter notes from the item's start (`q6`: REAPER writes them to 1e-9 s). A take with
markers of its own keeps its PLAYRATE as it is (REAPER keeps it); without, rate x length as before. An auto-stretch item whose markers are
all REAPER's (flag bit 1) leaves them out of the text; `beats.rewarp`, after every SetItemStateChunk of a travelling text (apply and its
copies, a kept take put back, the send's shared-media rewrite), sets C_AUTOSTRETCH off and on so REAPER makes them from the map here.

**Updating.** Hash version 12's items carry fractions: `mirror.legacy_beats` reads an hv-12 item through `beats.upgrade12` (a fraction times
the length in quarter notes, exact wherever the tempo holds over the item; REAPER's own stretch markers on an auto-stretch item left out),
and W.one's re-anchor accepts it within 1e-7 quarter notes (`beats.near`: a share at 1e-9 times the length can't promise better). So the
first look after updating sends nothing.

**Tests and knock-outs** (each knocked out in the tree, the test run, then put back):

| Part | What | Knock-out -> fails at |
| --- | --- | --- |
| `test_0_61_rt_beats` 1 | the forms (fades in quarter notes) and back, the 5022 read-back | (changed expectations) |
| 2 | a 90 bpm marker inside Gtr sends nothing but the timeline (plus the step, first tempo and gradual cases) | 1b0f3b5's beats.lua with the new stand-in -> "nothing but the timeline goes out (1: I-...)" |
| 3 | an edit crossing a gradual map: fade and snap offset 1.5 / 2.5 quarter notes from the start on all three | (was shares of the length; expectation changed with the rule) |
| 6 | format 2, hv 13, level 13 | `HV = 12` -> "format 2, hash version 13, level 13" |
| 9 | records of hash version 12 over hv-12 items with snap offsets and fades: the first look sends nothing, each re-anchored | legacy_beats' hv-12 branch -> "sends nothing (3: I-...)"; beats.near in W.one -> the same |
| 10 | REAPER's chunks before and after (f4's; a take's own markers): one canonical text; a landing of an auto-stretch item sets C_AUTOSTRETCH 0 then 1, one with its own markers doesn't; hv-12's copy of REAPER's markers left out | the leave-out -> "reads the same before and after"; the rate rule -> "its rate as it is"; apply's rewarp -> "set off and on (0)" |

### 2. Automation values read 0 on the receiver (f1, f3, f6): the tool's

**Cause.** `env_add` in `tools/live/lua/live.lua` gave `InsertEnvelopePoint` raw values 0.5 to 0.9. In fader scaling (REAPER's default for
volume) raw values run 0 to 1000; 0.5 is a gain of about 2.5e-10, which REAPER's chunk writes as 0. The desktop's API read 0.5 back, but its
own chunk (which StudioSync reads and sends) said 0, and every receiver read 0. f2, f4, f5 and f7 have no automation, which is why they got
past prep. StudioSync carried REAPER's chunk exactly.

**Fix (1cef0a4).** `env_add` converts a gain with `ScaleToEnvelopeMode(GetEnvelopeScalingMode(env), gain)`, `env_points` back with
`ScaleFromEnvelopeMode` (all three in the API index). The sets' values (0.5 ... 0.9, 0.25) are gains now.

**Check.** sync2f's prep (Drums' automation equal on every computer): failed on 0.63.0 with the old helper; passed with the new one on
0.63.0 (the interrupted run below) and 0.63.1.

### 3. A track "re-sent every 40 s" (f8): the tool's

**Cause.** `LV.events_since(SONG, "James", t)` matched file names by the prefix `James-`, which the laptop's `James-Laptop-...` files share;
`Laptop-...` sorts after any time stamp, so the laptop's three old events of 'LV c6twomovesaton Drums' (04:19-04:27) were read as the
desktop's in every scenario. The desktop's events folder had no such event after 06:00Z.

**Fix (e213ed0).** The prefix must be followed by the time stamp's digit. Soak scenario `idle-leftover-track` pins StudioSync's side: James
makes a track, Bee changes it and goes offline, James's computer sends nothing for the next 220 s. It passes before and after (there was no
loop to reproduce); a copy with one change of James's at 200 s fails its check, so the check bites.

**Check.** f8 on 0.63.1 (below).

### 4. Tool problems

- **Leftover test tracks** (194e149): setup deleted only its own scenario's prefix. "LV late Gtr" (an older set's) sat in the song through
  the sync2f run, and its item's re-sends at f4's and f5's tempo changes were counted as theirs. Setup now deletes every `LV ` track on each
  computer of the run, then, when it deleted any, waits for everything quiet (f8's first try on 0.63.1 counted the leftovers' own deletions;
  its retry passed).
- **A missing computer** (194e149): `peer_ips` asked the laptop over ssh with no timeout; with the laptop off that waited for TCP's, in a
  step or a clean-up. Now ConnectTimeout 8 s, BatchMode, a 20 s cap, and the desktop's address alone without it. The rest of the clean-up
  already skipped a computer that doesn't answer.
- **c3** (0af4b91): rewritten per rt-fixlive1 Recommendation 1: a track made after the song's file was last saved, File > Open of the song's
  own file in its tab on each computer; seen as an opening, the track is back within 45 s (the heal would take 61-120 s) and nothing goes out
  as a deletion. The master track pointer is noted, not asserted.
- **live.py** (194e149): a scenario that passed on a retry kept the failed try's "why" in its row; now only in "retried".

## Live checks run

Every run with `--on d,x` (the laptop off), `X_IP=192.168.86.129`, Mute me and Deafen on everywhere (the tool's check), nothing saved.
Reports in the session scratchpad (`live/*.json`), not committed.

**On 0.63.0, with the env and events fixes (before 0.63.1).** `sync2f -k f1 -k f3 -k f6 -k f8`: f1's prep passed (Drums' automation equal on
both: finding 2's fix works), then the desktop sent the timeline **and Drums' automation** at the 100 bpm marker; the 0.63.1 deploy then
landed mid-run ("StudioSync won't load lib/band.lua: it changed in the shared folder") and the run was stopped.

**rt-fixlive1 rechecks on 0.63.1** (after `live.py restart --on d,x`, `song`; `up` showed lib 0.63.1 on both):

| Run | Result | Notes |
| --- | --- | --- |
| `sync2c -k c1.2` | pass | the track the older file lacks back on LinuxBox 64 s after the load, and 292 s after the second (rt-fixlive1 expected seconds: below) |
| `sync2c -k c1.4b` | pass | |
| `sync2c -k c1.4c` | pass | |
| `sync2c -k c2` | couldn't automate | parts 1-2 pass; part 3 needs a save. Tracks back 132 s after the reopen |
| `sync2c -k c5` | pass | no "given their place" line after three new tracks, on either |
| `sync2c -k c11` | pass | order unchanged while playing |
| `sync2c -k c12` | pass | no "(yours, not sent)" left |
| `sync2d -k d1` (also matched d10) | pass, pass | |
| `sync2e -k e4` | pass | |
| `floor -k f3` | fail, then **pass** with 322ffa8 | the set's own two errors (the Ctrl+Z script went to REAPER's own Undo; the bandmate's event file read before Syncthing brought it) |
| `floor -k f6` | pass | |
| `sync2c -k c3` (rewritten, 0af4b91) | **fail** | try 1: desktop's track back 14 s after File > Open, LinuxBox's 62 s (over the 45 s line). Try 2: the desktop's never came back within 165 s while LinuxBox kept it: the computers differed. No deletion went out. A real problem of rt-fixlive1's reopen handling on 0.63.1 (Recommendation 2) |

**This round's sync2f on 0.63.1 with the tool fixes** (fixes 1 and 2 aren't in 0.63.1, so f4 and f5 weren't run: they fail there as before):

| Run | Result | Notes |
| --- | --- | --- |
| `sync2f -k f8` (first, after the restart) | pass (on retry) | try 1 counted the deletions of two leftover tracks setup had just made (fixed in 194e149: setup waits quiet); try 2: 0 and 0 events in 120 s. The "re-sent every 40 s" is gone with e213ed0 |
| `-k f1` | **fail** | the desktop sends Drums' automation at the tempo change: see "Track automation in the song's tab" below |
| `-k f2` | pass | |
| `-k f3` | pass | |
| `-k f7` | pass | |
| `-k f6` | **fail** | the same cause: "Drums' automation off its beats on the desktop: 8 vs 7.67, 16 vs 15, 24 vs 22.33" |

**Track automation in the song's tab (found here, not fixed).** In the live song's tab, REAPER kept a track's volume points in seconds at a
tempo change: a probe track ("LV probe Drums", points at 0, 4, 8, 12 s, track timebase -1, project timebase 1) and a 100 bpm marker at 4 s,
read back in the same eval: points still at 8 and 12 s (quarter notes 14.67, 21.33). The same track chunk copied into a new tab, a new tab
with the same settings, and a copy of the song's own project header opened in a new tab all moved the points (8 -> 8.8, 12 -> 13.6). The
project values read equal in both (PROJECT_TIMEBASE 1, PROJECT_TIMEBASE_FLAGS 0, itemtimelock 1, tempoenvtimelock 1, envattach 3, locking
off), on both computers. So it's the open song tab's state, not its file, and nothing StudioSync writes was found that sets it. StudioSync's
automation in quarter notes (rt-sync2f) then reads REAPER's unmoved points as an edit and sends them: f1, f6. Items in the same tab do move
(f2, f3 pass). The probe track and the marker were taken out afterwards.

**The tempo after the restart (found here, not fixed).** After `live.py restart` the desktop's song tab had 120 bpm (its older file) while
LinuxBox had the room's newest timeline change, the desktop's own 100 bpm marker from the run the deploy interrupted. The desktop never took
it back. Likely the interrupted run: that change was made while the desktop's Live sync was refusing the newly deployed files, so its
session.json / timeline file may not have been written; not confirmed. The tool now puts the tempo back on every computer (91bc612).

**REAPER probes** (the "REAPER, measured" table above): read-only on the song, in tabs of their own, on both computers.

## hv and LEVEL

- **`mirror.HV` 13**: an item's hash covers its snap offset and fades in quarter notes where they sit and its stretch markers in quarter
  notes, REAPER's own on an auto-stretch item left out.
- **`sync.LEVEL` 13**, with it. `band.FORMAT` stays 2 (the wire form's shape is the same; the floor keeps level-12 computers from mixing).
  A computer at the floor holds every level-12 change (rt-floor's rule), and reads level-12 history for records, merges and History through
  `beats.upgrade12`.

## Gates

| Check | Result |
| --- | --- |
| `tests/run.py --no-luals`, local time, at 66a67b7's lib (later commits are tools/live, the soak scenario and this doc) | **fails 0** |
| the same, `TZ=UTC0`, at 0af4b91 | **fails 0** (rt_bigproj and rt_drivebg passed: no A/B needed) |
| `tools/soak/soak.py --scenario all` | **20 of 20 as they say** (19 at 1b0f3b5, plus `idle-leftover-track`; `rename-redo-claim` fails as it says) |
| long soak, `range.py` from a fresh clone of 0af4b91, 8 procs (no other `range.py` / `soak.py` running: checked before) | **237 of 237** (baseline 237). The commits after it change only tools/live and this doc |
| soak --quick, detcheck (inside run.py) | ok, ok |
| on the way | 79b24c2's tree alone: suite fails 0, scenarios 20 of 20 |

## Live scenarios to run after deploying this build

Deploy to the desktop and LinuxBox (`live.py restart --on d,x`, `song`, `up` shows the new version on both), then:

| Run | Expect |
| --- | --- |
| `sync2f -k f8 --on d,x` first | pass: nothing goes out in 120 s (the level-13 switch-over re-anchors hv-12 records) |
| `sync2f -k f4` | pass: only the timeline event at both tempo changes inside the auto-stretch item, the item and its REAPER-made stretch markers equal on both |
| `sync2f -k f5` | a take with markers of its own: REAPER adds two at the first tempo change, so the desktop sends that item once (Known limits); the markers agree on both. Expect "fail" on its no-obj check until the set allows that one re-send |
| `sync2f -k f2 -k f3 -k f7` | pass |
| `sync2f -k f1 -k f6` | fail until the song-tab automation question is answered (Recommendation 1) |
| `sync2c -k c3` | pass (rewritten) |
| the rt-fixlive1 rechecks above | as on 0.63.1 |

## Known limits

- **A take with stretch markers of its own** goes out once at the first tempo change that reaches it: REAPER adds a marker at each end then
  (the last segment's speed becomes a fixed pair), a real change of the item. Later tempo changes leave it equal. History of such items in
  hash version 12 (markers in take seconds, rate as rate x length) isn't upgraded (it needs the map): those items go out once after updating.
- **Take envelopes** stay as REAPER writes them: unchanged at a tempo change for a take without stretch markers (measured), moved on their
  beats for one with them (measured), so the latter re-send at a tempo change as well.
- **A fade or snap offset across a tempo change in hash version 12's history** reads back at the share the old form held (exact where the tempo
  holds over the item); a merge against such a base may see a difference below 1e-7 quarter notes as a change.
- **Spans across a tempo marker**: measured where the fade ends on either side of a step; a gradual change inside a fade is assumed to follow
  the same rule (quarter notes kept), as TimeMap2 counts it.
- **`beats.rewarp`** needs `IMPLIEDWARP 1` in the chunk and no SM line; an auto-stretch item with markers of its own keeps REAPER's alongside
  them in the text (in quarter notes), as REAPER mixes them.
- **Track automation in the live song's tab stays in seconds at a tempo change** (Live checks: cause not found). There, StudioSync sends a
  track's automation after every tempo change that should have moved it, and the beats form disagrees with what REAPER does in that tab.

## Recommendations (ranked)

1. **Find why REAPER keeps automation in seconds in the live song's tab** (f1, f6) before anything else about automation in beats: a probe
   with Live sync stopped on that tab (REAPER restarted without it), then with it, tells StudioSync's runtime from REAPER's tab state. If it's
   REAPER's, automation should follow what REAPER does (read the track's envelope timebase rather than assume the project's).
2. **rt-fixlive1's reopen in the same tab isn't reliable on 0.63.1**: c3's second try left the desktop without the track the file lacked
   (LinuxBox kept it), and c1.2 / c2 took 64-292 s, not seconds. Look at `mirror.on_open`'s "none of the last look's tracks left" test and
   the receive's catch-up after a load-guard settle, with c3 as the check.
3. **Deploy this build to the desktop and LinuxBox together and run the list above**, f8 first, then f4.
4. **Give `sync2f` f5 its expected one re-send** (a take's own markers get REAPER's edge markers at the first tempo change), or make its
   item auto-stretch-free with edge markers already in place, so the check says what StudioSync controls.
5. **Take envelopes in beats for takes with stretch markers** (the same transform as the markers: about 15 lines in `beats.item`), if songs
   with hand-placed stretch markers and take automation matter.
6. **A live scenario for the level-13 update with real history**: items with fades and snap offsets made on 0.63.1, then this build: no
   item goes out (the suite's part 9 on the stand-in only).
7. **The timeline after a restart onto an older file** when the room's newest timeline change was this computer's own (seen once, after an
   interrupted run): a live scenario for it.
8. **rt-fixlive1's remaining live items** (c2 with the laptop's TONEX, the save case of bug 2) when the laptop is back.
