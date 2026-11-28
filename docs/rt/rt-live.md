# rt-live: the REAPER checks, run by agents (2026-11-27/28)

James (2026-11-27): "For anything like that you need to build a way to check without me, I shouldn't be needed for anything." This round
built `tools/live/` (see its README) and turned the open "REAPER checks for James" of rt-sync2c, rt-askweb, rt-sync2d and rt-sync2e into
scenarios that drive the real REAPERs through their dev-eval hooks, then ran them. Nothing in `lib/` was changed.

## Summary for James

- **One command runs a check list now**: `python tools/live/live.py run sync2c` (or `sync2d`, `sync2e`, `askweb`, and `floor` for
  rt-floor's once 0.62.0 is out). It prints a pass/fail table and writes a JSON report. Each scenario makes its own tracks in the test song
  **LV Checks** (Smiley Studios, made for this), deletes them afterwards, and never saves a project.
- **Results** (details below): of the 32 items (rt-askweb lists 5), **21 pass**, **6 fail** (rt-sync2c 1's delete-all case, 3, 5, 11, 12; rt-sync2d 1), **1 passes with a part only a person can do** (rt-sync2c 2's "save and reopen"), **2 pass except bug 1's case** (rt-sync2c 4, rt-sync2d 9) and **2 are not applicable** (the old-version computer). rt-askweb 5 of 5 and rt-sync2e 5 of 5 pass (sync2e 5 on the desktop and LinuxBox; the laptop's waits for it). rt-sync2c 11's mouse-button half can't be scripted.
- **Real bugs found** (each with the scenario that reproduces it, for a fix round to use as its test): (1) a delete-all right after another deletion is silently put back, no ask (`sync2c -k c1.4b`); (2) REAPER keeps the master track pointer across File > Open in the same tab, so StudioSync can't tell a reopen by it (`-k c3`); (3) after an older file is opened in the same tab, the tracks it lacks come back only with the next catch-up, 1-5 minutes later (`-k c1.2`); (4) others' track moves land while you play (`-k c11`); (5) StudioSync's Undo of a deletion leaves a "(yours, not sent)" duplicate of the take that was saved aside (`-k c12`, `sync2e -k e4`); (6, minor) the one-time switch-over log lines come again for every new track (`-k c5`, `sync2d -k d1`).
- **The laptop went offline at 21:44 MT** (asleep or off the tailnet; never touched). Every scenario was written to use the laptop as the
  bandmate when it's there; while it was away, LinuxBox played the bandmate and the desktop and LinuxBox were the two computers that had to
  agree. Still to run with the laptop when it's back: `sync2e -k e5` (its byte order), `sync2c -k c2` (with TONEX), and one full `run sync2c` with all three (two moves at once failed once with the laptop in it: worth a few tries).
- **Live audio was briefly unmuted on the laptop and LinuxBox** at the start of the round: opening the test song started Live sync, which
  turns live audio on, and it sent the laptop's input 2 and LinuxBox's input 1 for about 4 minutes (21:16:36-21:20 MT) before this tool
  muted both (the extension then read `mute: true`). Every computer was deafened, so nobody heard anything, but those inputs may be real
  (the laptop's interface, a VM's input that can be the desktop's microphone). Deafen was set; Mute me wasn't, my mistake. The tool now
  sets Mute me and Deafen on every computer before a song opens, and every scenario refuses to run unless both are on.

## How it ran

- StudioSync 0.61.4 (3ab996c) on the desktop (main checkout), the laptop and LinuxBox (the studio folder's signed copy). REAPER 7.86.
- Song **LV Checks** in Smiley Studios, published by the desktop with Publish session's "publish as" (as tests/cross/cross_test.lua does),
  opened on the others with Open session; room mode **Open** (claims off), so auto-claims and claim asks don't decide these sync checks
  (claims have rounds of their own).
- Edits through each REAPER's hook in undo blocks named as REAPER's own actions name them ("Insert new track", "Remove tracks", "Reorder
  tracks", "Recorded media"); StudioSync's Undo / Redo are the real Ctrl+Z / Ctrl+Shift+Z scripts; the panel's bar is the ExtState it
  writes. Paired edits at one moment on the studio's link clock (`direct.shared_now`): every pair ran 0 ms apart by that clock.
- "Audio arriving late": LinuxBox's Syncthing paused through its REST API (approved), never the real PCs'. "A folder change landing in
  pieces": LinuxBox's Syncthing paused and its direct link cut inside the VM (`tools/lab/netlab.sh`), both undone after.
- A failed scenario runs once more (`--retries 1`); the tables show the final result and how many tries failed.

## rt-sync2c (docs/rt/rt-sync2c.md, 12 checks)

Set `sync2c`; reports `tools/live/reports/sync2c-20261127-222605.json` (all) and `sync2c-20261127-224739.json` (the re-run of the reworked
ones). Desktop + LinuxBox (the laptop offline).

| # | Check | Scenario(s) | Result | Evidence |
| --- | --- | --- | --- | --- |
| 1 | rt-reopen re-check 1: an older file after a restart | `c1.1 older file after a restart` | **pass** | LinuxBox closed without saving (SIGTERM), started on an older file lacking a track, Open session: no `gone` event from it; the track back 6 s after Open session; the desktop kept it. |
| 1 | rt-reopen 2: an older file in the same tab | `c1.2 older file, same tab` | **pass, slow** (bug 3) | No `gone` event, no "change(s) went". The missing tracks came back 3 s after the first load, **63 s** after the second. Earlier tries: 61 s, 113 s, and once not within 120 s. |
| 1 | rt-reopen 3: closing or loading the tab | `c1.3 closing or loading the tab` | **pass** | LinuxBox closed the tab; later loaded an empty project into the tab Live sync ran in: the desktop unchanged both times, no `gone` events from LinuxBox. |
| 1 | rt-reopen 4: real deletions still go | `c1.4 real deletions still go`, `c1.4b`, `c1.4c` | **fail** (bug 1) | A deletion, REAPER's Ctrl+Z and Ctrl+Shift+Z, the top track: all reached LinuxBox. **Select every track and delete, right after another deletion: no ask, put back, nothing sent** (2 of 2; `c1.4b` 2 of 2). The same delete-all as the first deletion asks (`c1.4c` pass). |
| 1 | rt-reopen 5: a deletion with the tab behind | `c1.5 deletion with the tab behind` | **pass** | An item deleted and another tab brought in front at once: the deletion reached LinuxBox. |
| 2 | Check 12: a chain's knobs on reopen; a knob and track 1 in one second | `c2 reopen keeps chains; knob + track 1` | **pass (parts 1-2); part 3 couldn't be automated** | Reopen in the same tab sent nothing for the chain's track (ReaEQ on LinuxBox: TONEX / Superior Drummer are on the laptop, which was offline). A knob turned without an undo point (as a control surface does) with track 1 deleted in the same second reached the desktop. Part 3 ("save, and open the file again") needs saving the project. The song's tracks came back 61 s after the reopen (bug 3). |
| 3 | The master track on reopen (read only) | `c3 master track differs after reopen` | **fail: REAPER keeps the pointer** (finding 2) | File > Open of the same project in the same tab: `GetMasterTrack` returned the same pointer on the desktop (Windows, `00000000E002A000` before and after) and LinuxBox (Linux, `0xc991240`), 2 of 2 each. The project pointer stays too. |
| 4 | The big-deletion ask (with rt-sync2d 9's floor) | `c4 big deletion: Yes / No / no answer`, `c4 delete 1 of 4, and all`, `c4 2-track song: delete 1` | **pass, except delete-all after a deletion** (bug 1) | "Delete 2 of the song's 4 tracks for everyone?" asked; LinuxBox kept them while it waited; Yes: gone everywhere; No: back with their items, the log not saying it deleted; no answer: back after 31 s; 1 of 4 and 1 of 2: no ask, went. Delete-all right after deleting 1: no ask (2 of 2). |
| 5 | The switch-over to ranks | `c5 switch-over to ranks (logs)` | **fail (minor)** (bug 6) | The one-time switch-over itself can't be re-run (see below). But the line comes again for new tracks: the desktop made 2 tracks in one undo point and 25-45 s later logged "2 track(s) given their place as a rank (StudioSync's track order, from this version on)" (2 of 2; 36 such lines in its log tonight, one per scenario). LinuxBox's single new track: nothing. |
| 6 | Two moves at once | `c6 two moves at once` | **pass** (1 of 3 tries failed on the first run) | The desktop dragged Keys to the top as the other computer dragged Drums to the end, 0 ms apart: Keys, Bass, Gtr, Drums everywhere. On the very first run (desktop, laptop and LinuxBox, before the laptop left) one try ended Keys, Drums, Bass, Gtr (the laptop's move lost); its retry was spoiled by that time's clean-up (since fixed); the two later runs (desktop + laptop + LinuxBox, then desktop + LinuxBox) passed. Not reproduced since: worth re-running with the laptop. |
| 7 | A late joiner after moves | `c7 late joiner after moves` | **pass** | LinuxBox closed the song; the desktop made two moves; LinuxBox opened it again: D, B, C, A at once and a minute later, as the desktop. |
| 8 | Folders as before | `c8 folders as before` | **pass** | Into a folder, out, the whole folder dragged: the same everywhere. A folder moved on the desktop as a child was dragged out of it on LinuxBox, 0 ms apart: both ended Bus, Other, Last, Kid (both moves kept). |
| 9 | An old-version computer | `c9 an old-version computer` | **not applicable** | James's decision of 11-27: no old-version compatibility; no computer is kept on an older release. |
| 10 | Undo of a move | `c10 Undo of a move` | **pass** | Move, StudioSync's Undo, Redo: LinuxBox followed each step. |
| 11 | Tracks put in order as changes land | `c11 order waits while playing` | **fail** (bug 4) | The desktop played (at 5000 s, past everything, metronome off); LinuxBox moved C above A; the desktop's order changed **while it played** (play state 1), 4 of 4. Its log: "LinuxBox: changed a track on LV c11orderwaitsw C / 1 change from the others" during playback. The mouse-button half can't be scripted (below). |
| 12 | A track brought back by StudioSync's Undo | `c12 a track brought back by Undo` | **fail** (bug 5) | The desktop deleted Gtr as LinuxBox recorded a 3 s take on it, 0 ms apart; LinuxBox's take went to "Gtr (yours, not sent)". The desktop's StudioSync Undo: Gtr back on both **with** LinuxBox's take, but LinuxBox **kept "Gtr (yours, not sent)" with the same take beside it** (2 of 2, still there 90 s later). |

## rt-sync2d (docs/rt/rt-sync2d.md, 10 checks)

Set `sync2d`; report `tools/live/reports/sync2d-20261127-225854.json`. Desktop + LinuxBox. Check 9 (the big-deletion floor) runs in the
sync2c set (`c4 ...` above): pass.

| # | Check | Scenario | Result | Evidence |
| --- | --- | --- | --- | --- |
| 1 | The switch-over to parents | `d1 switch-over to parents (logs)` | **fail (minor)** (bug 6) | As sync2c 5, for folders: LinuxBox made one new track and logged "1 track(s) given their folder as a parent (StudioSync's folders, from this version on)" a minute later, 2 of 2; 34 such lines in the desktop's log tonight. |
| 2 | Into and out of a folder; indent / outdent | `d2 into and out of a folder` | **pass** | Gtr dragged into Bass and out: LinuxBox the same each time. REAPER has no indent action of its own: SWS's "Indent selected track(s)" / "Unindent" (what a person binds) put Keys into Gtr and out, followed everywhere. |
| 3 | A folder change landing in pieces | `d3 a folder change landing in pieces` | **pass** | LinuxBox's Syncthing paused and its direct link cut (inside the VM) while the desktop dragged two tracks into a folder; unchanged meanwhile; on resuming, sampled every 0.3 s: Bus,A,B,Other -> Bus,A<Bus,B<Bus,Other, no track in another folder on the way; no event from LinuxBox. (Everything arrived in one pass here, so "in pieces" was the risk, not what happened.) |
| 4 | Two folder moves at once | `d4 two folder moves at once` | **pass** | Keys into Bass on the desktop as Bass into Keys on LinuxBox, 0 ms apart: Keys, Bass<Keys, Other on both at once, valid depths, the same a minute later. |
| 5 | A folder moved while a child leaves | `d5 folder moved while a child leaves` | **pass** | Bus (with Kid1, Kid2) dragged above Top on the desktop as Kid2 was dragged out on LinuxBox: Bus, Kid1<Bus, Top, End, Kid2 on both, valid depths. |
| 6 | A take on a folder track | `d6 a take on a folder track` | **pass** | A 3 s recorded take on the folder track Bus on the desktop as LinuxBox dragged New into Bus, 0 ms apart: the folder kept, the take on Bus everywhere, not grey. |
| 7 | Undo into a folder; rename inside | `d7 Undo into a folder; rename inside` | **pass** | Drag in, StudioSync's Undo (out everywhere), Redo (in); a rename inside the folder undone: stays in the folder. |
| 8 | An old-version computer | `d8 an old-version computer` | **not applicable** | James's decision of 11-27. |
| 9 | The big-deletion floor | (sync2c `c4 ...`) | **pass** | 1 of 2: no ask; 2 of 4: asks; 1 of 4: no ask; all: asks (except right after another deletion: bug 1). |
| 10 | REAPER's own depths after a drag (read only) | `d10 REAPER's depths after a folder drag` | **pass (information)** | Before: Above=0 Bus=1 K1=0 K2=-1 After=0. Bus alone dragged up past Above (`ReorderSelectedTracks`, as a drag of the folder track): REAPER moved its children with it and wrote Bus=1 K1=0 K2=-1 Above=0 After=0; StudioSync's next pass read Bus, K1<Bus, K2<Bus, Above, After. |

## rt-askweb (docs/rt/rt-askweb.md, checks 1-5)

Set `askweb`; reports `tools/live/reports/askweb-20261127-230620.json` and `askweb-20261127-230916.json` (w3 again after a harness fix).
The desktop's real web page (`http://127.0.0.1:47281/#session/here`) in the installed Chrome, headless, through Playwright, fake media
devices; LinuxBox as the bandmate.

| # | Check | Scenario | Result | Evidence |
| --- | --- | --- | --- | --- |
| 1 | The delete ask on the page: Yes, No, nothing | `w1 delete ask on the page: Yes, No, nothing` | **pass** | "Delete 2 of the song's 3 tracks for everyone? (NN s)" with Yes / No and a countdown that counts; the page's Yes: gone on LinuxBox, the line leaves; No: back on the desktop, LinuxBox kept them; nothing: back after 30 s. |
| 2 | The bar and the page answer each other | `w2 bar and page answer each other` | **pass** | The bar's No (its ExtState): the page's line left 1.8 s later. The page's No: the bar's ask cleared 1.5 s later. |
| 3 | The Undo ask on the page | `w3 Undo ask on the page` | **pass** (first run: a harness slip, below) | The desktop renamed A -> A2, LinuxBox then set its volume, the desktop's StudioSync Undo: the page listed "Undo: changed track LV w3... A2? It goes to everyone. LinuxBox changed it after that: what they changed stays, ..." with Yes / No; Yes: the name back everywhere; No: nothing changed. |
| 4, 5 | A page on another device (the phone; the laptop's browser) | `w4 a page on another device` | **pass** | The desktop's page at its Tailscale address with the phone-link token (read by the runner, never printed): `ssEnv.where` is "remote"; the ask's words and "Answer this in StudioSync on the computer itself", no buttons. The web UI tells devices apart by the request's address, so a headless Chrome reaching the tailnet address gets exactly what the phone and the laptop's browser get. |

## rt-sync2e (docs/rt/rt-sync2e.md, 5 checks), on 0.61.4

Set `sync2e`; report `tools/live/reports/sync2e-20261127-232900.json` (and `sync2e-20261127-234150.json` for check 4). Desktop + LinuxBox. "Arriving late"
on LinuxBox: its Syncthing paused **and its copy of the song's media folder read-only** (the check's own recipe, Syncthing paused alone,
doesn't delay audio on this branch: it rides the direct link; see Bugs, "Also seen").

| # | Check | Scenario | Result | Evidence |
| --- | --- | --- | --- | --- |
| 1 | A copy of a grey box becomes yours | `e1 a copy of a grey box becomes yours` | **pass** | An 8-bar (16 s) take recorded on the desktop; LinuxBox showed the grey stand-in; LinuxBox copied it (Ctrl+drag, the item's chunk with every mark) to bar 20 (38 s); resumed: on both computers the take at 2 s and LinuxBox's copy at 38 s, neither grey. |
| 2 | Deleted before it arrived | `e2 deleted before it arrived` | **pass** | Grey on LinuxBox; the desktop deleted the take; resumed: the track with no item on both, nothing grey. |
| 3 | Its track deleted before it arrived | `e3 its track deleted before it arrived` | **pass** | Grey on LinuxBox; the desktop deleted the track; resumed: gone on LinuxBox, no "(yours, not sent)" track. |
| 4 | StudioSync's Undo with the audio missing | `e4 StudioSync's Undo with the audio missing` | **pass** (with bug 5 again) | Deleting a grey box isn't a deletion (it never was the take there), so the take is brought back the way the check means: LinuxBox deleted Gtr at the moment the desktop recorded a take on it (0 ms apart), the take's audio unable to reach LinuxBox; LinuxBox's StudioSync Undo brought Gtr back with no item and no grey box (its log didn't say "couldn't change here yet": the track came back, the take simply hadn't arrived); resumed: the take landed on Gtr on LinuxBox, nothing grey anywhere (2 of 2). The desktop, whose take had gone to "Gtr (yours, not sent)" when the deletion landed, kept that copy beside the brought-back Gtr: bug 5 from the other side. The first version of this scenario (LinuxBox deleting the grey box) failed only on its own premise. |
| 5 | Which order Lua uses | `e5 which order Lua uses` | **pass (desktop, LinuxBox); laptop not run** | `"a" < "B"` is false and `"a-b" < "ab"` true (byte order), collate locale C, on the desktop and LinuxBox. The laptop was offline: run `live.py run sync2e -k e5` when it's back. |


## Bugs found, with their repro scenarios

Each was reproduced at least twice. "Repro" is the scenario a fix round can run as its test: `python tools/live/live.py run SET -k NAME`
(desktop + LinuxBox at least; the laptop joins as the bandmate when it's on). None was fixed here (lib/ is another agent's).

1. **A delete-all right after another deletion is silently put back** (real bug; data-loss class: a person's deletion undone with no ask).
   Repro `sync2c -k c1.4b` (control `c1.4c`: the same delete-all as the first deletion asks, passes). Steps: three tracks; delete one
   (REAPER's undo top "Remove tracks"); 17 s later select all and delete. Expected: "Delete 2 of the song's 2 tracks for everyone?". Got: no
   ask; the log says "this project has no tracks but still holds the studio's ..." then "2 track(s) or item(s) of the studio's weren't in
   this project, with no deletion of yours behind it (a file older than the studio, or a project read while closing or loading): they're
   back". Cause, from the code: rt-guard's empty-project rule needs "a new undo point of someone's on top since the last look", and
   `mirror.watch` decides that by the undo top's **text** changing (`w.new_point = ... (top or "") ~= es.top and mirror.user_point(top)`,
   lib/mirror.lua; `mirror.user_edited` likewise). Two deletions in a row both read "Remove tracks", so the second isn't a new point. Also in
   `c1.4` and `c4 delete 1 of 4, and all` (2 of 2 each), and it bit this tool's own clean-up (now uses an undo name of its own). Fix idea:
   compare `GetProjectStateChangeCount` (or the undo history's depth) with the last look's, not the name.
2. **REAPER keeps the master track pointer across File > Open in the same tab** (a REAPER fact the design leans on). Repro `sync2c -k c3`.
   `GetMasterTrack(proj)` returns the same pointer before and after `Main_openProject` of the tab's own file, on Windows and Linux REAPER 7.86
   (the project pointer stays too). rt-sync2c's 7a948e2 ("the project's instance told by its master track") can't see a reopen in the same
   tab by it. What did see the reopens tonight: Live sync's load guard ("'LV Checks' was loaded again in its tab"), and c2's reopen sent
   nothing for the chain, so the knob rule held anyway here; the rule's own trigger should move to the load guard's count.
3. **After File > Open of an older file in the same tab, the tracks it lacks come back only with the next catch-up** (real; slow, up to
   minutes). Repro `sync2c -k c1.2` (the second reload) and `-k c2`. Measured on LinuxBox: 3, 61, 63, 61, 113 s, and once not within 120 s;
   each time the log says "caught up on N changes that hadn't arrived here", the heal Live sync runs only after the room has differed for 60 s,
   at most once per 300 s, with the tab in front (StudioSync - Live sync.lua, `heal_since` / `healed_at`). The prompt put-back ("weren't in
   this project ... they're back", 10 s on the desktop's empty-project case) doesn't run after a reload in the same tab. No deletion is ever
   sent (the guard holds), but the song looks short of tracks for up to 5 minutes.
4. **Track moves from others land while this computer plays** (real, against rt-sync2c check 11's spec: "never ... while playing (then at
   the next stop)"). Repro `sync2c -k c11` (4 of 4). The desktop played (5000 s, nothing there, metronome off); LinuxBox moved C above A;
   the desktop's order changed during playback; its log: "LinuxBox: changed a track on LV c11orderwaitsw C / 1 change from the others".
   Either the receive should hold track moves while playing, or the spec should say only the order heal waits.
5. **StudioSync's Undo of a deletion leaves a "(yours, not sent)" copy on the computer whose take saved it** (real: a duplicate track with
   the same take). Repro `sync2c -k c12` (2 of 2). The desktop deleted Gtr as LinuxBox recorded a take on it (same moment); LinuxBox's take
   went to "Gtr (yours, not sent)" (as designed). The desktop's StudioSync Undo brought Gtr back everywhere **with** LinuxBox's take (41980c2
   works), but LinuxBox kept "Gtr (yours, not sent)" with the same take beside it, still there 90 s later. The kept-aside copy should go once
   the brought-back track holds its take.
6. **The one-time switch-over lines come again for new tracks** (minor: misleading log, and an extra auto version per new track). Repro
   `sync2c -k c5`, `sync2d -k d1` (2 of 2 each). Tracks made by "Insert new track" get their rank or parent by a second version 25-60 s
   later, logged as "N track(s) given their place as a rank (StudioSync's track order, from this version on)" / "... given their folder as a
   parent ..." (the desktop's 2 tracks made in one undo point: ranks; LinuxBox's single track: parent). 36 + 34 such lines in the desktop's
   log tonight. rt-floor keeps "the room's one-time switch-over by each track's maker", so this likely survives 0.62.0: a new track should
   be sent with its rank and parent the first time.

Also seen (not a sync bug): the log says "live audio on: sending input N ..." when Mute me is on (the extension is muted, `mute: true`;
liveaudio.lua logs the line whenever the engine starts with an input). With Mute me on, saying "live audio on (muted)" would avoid alarm.
And a recipe in rt-sync2e's checks doesn't work on this branch: "pause Syncthing to make a take arrive late" — the take's audio also
travels over the direct link (lib/streams.lua `offer_media`, any media file written in the last 10 minutes), so it arrives with its change.
The tool makes it late by pausing LinuxBox's Syncthing and making its copy of the song's media folder read-only.

## rt-floor's Live checks: written, not run

`sets/floor.py` scripts docs/rt/rt-floor.md's six Live checks (`f1` the floor recorded, `f2` updating sends nothing, `f3` below the floor:
nothing out, nothing lost, `f4` a change made below the floor held, `f5` two folder moves at once with no write-back, `f6` web Health's
row). Its setup refuses to run until every computer has `sync.LEVEL` (the 0.62.0 build), and deletes a stray `_band/floor/12-livecheck.json`
before every scenario; `f3` and `f6` delete theirs in a clean-up too, and `f4`'s held event file is deleted after. To move every computer
onto a new build at once: `python tools/live/live.py restart` (desktop, laptop and LinuxBox in parallel, never saving), then `live.py song`.

## What couldn't be automated, and why

Close to nothing: of the 32 items, these parts need a person's hand or a rule forbids them.

| Check | Part | Why |
| --- | --- | --- |
| rt-sync2c 2 (check 12) | "turn a knob, save, and open the file again in its tab" | Needs saving the project; these checks never save one. (A copy saved elsewhere isn't the same: the point is the tab's own file.) |
| rt-sync2c 2 | TONEX / Superior Drummer | On the laptop only, which was offline: ReaEQ stood in, which doesn't change its state on load, so the check's real risk (a plug-in that rewrites its chunk as it loads) waits for the laptop. `c2` picks TONEX automatically when the bandmate has it. |
| rt-sync2c 11 | "never while you hold the mouse button" | StudioSync reads the real mouse button (`JS_Mouse_GetState`); a script can't hold it. The playing half is automated (and fails). |
| rt-sync2c 5, rt-sync2d 1 | the one-time switch-over itself | It happened on each computer's first run of those builds; re-running it needs a song from a pre-rank / pre-parent StudioSync, which James's no-old-versions decision retired. What is automated: that the line doesn't come again (it does: bug 6). |
| rt-sync2c 9, rt-sync2d 8 | an old-version computer in the room | Not applicable: James's decision of 11-27 (no old-version compatibility). |
| all | the Mac | Not in this round's computers (Windows-only testing; LinuxBox stands in). |

## Harness lessons (fixed in the tool during the round)

- `live.py` run as a script made its own exception classes `__main__.Fail`; the sets imported `live.Fail`, so a set's Fail read as "error".
  Fixed (`sys.modules["live"]`).
- The clean-up's delete-all hit StudioSync's big-deletion ask (half the song or more), then bug 1 below; it now answers its own ask Yes and
  uses an undo name of its own.
- A REAPER restarted within 20 s of the old one closing finds the old Live sync lock fresh ("is syncing in another REAPER on this
  computer") and doesn't sync; LinuxBox has no Autostart to try again. The restart waits 21 s.
- The laptop's REAPER, handed the dev hook with `-nonewinst` 27 s after starting, opened a second REAPER (stopped at once; it held only the
  hook). `start_laptop.ps1` now waits 60 s and stops a stray second REAPER, three tries.
- Bash heredocs collapse `\\n` in inline Lua: helpers that need patterns live in `lua/live.lua`.

## Recommendations (ranked)

For making future rounds hand over "live check scenarios" instead of manual steps:

1. **Each round ends with a `tools/live/sets/<round>.py`, not a "REAPER checks for James" list.** The builder knows the expected log lines,
   ExtState keys and orderings; writing them as `ctx.check(...)` costs minutes and makes the check re-runnable as the fix's test. The
   doc then carries a table of scenario names and expected results. rt-floor's "Live checks" section (written for this tool, one round in)
   is the halfway form: precise enough to script in an hour.
2. **Name what each check reads, in StudioSync's own terms**: the log line (exact words), the ExtState key, the event field (`gone`,
   `auto`, `lv`), the Health row id. Checks phrased as "you see X on screen" need translating and guessing; "the log says '...'" doesn't.
3. **Give every StudioSync ask and state a readable hook, as `claimask.local_asks` already does**: the big-deletion ask was trivial to
   automate because it lives in ExtState with an id; the mouse-button hold (c11) and the panel's widgets aren't. A tiny `debugmode`
   override ("treat the mouse as held") would make the last unautomatable sync check scriptable.
4. **Write recipes for the branch as it is**: rt-sync2e's "pause Syncthing" doesn't delay audio any more (it rides the direct link). A
   scenario fails loudly on its own premise ("harness: the audio arrived with its change"), which a manual step can't.
5. **Keep a standing test song and computer roles**: LV Checks (Open mode) is now in Smiley Studios; `live.py song` opens it everywhere
   with live audio muted and deafened. Scenarios that need "the laptop" should say "a bandmate" (`B(ctx)`), so a sleeping laptop costs
   coverage, not the run.
6. **Run the sets after every deploy** (`run sync2c`, `sync2d`, `sync2e`, `askweb`, and `floor` from 0.62.0): about 25 + 20 + 15 + 10
   minutes on two computers. Timing-sensitive ones (two moves at once) deserve `--retries 2` under the orchestrator's CPU soaks.
