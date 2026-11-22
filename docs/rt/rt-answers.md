# rt-answers: four of James's decisions (2026-11-21)

Lua only, offline: stand-in tests, not run in REAPER or between real computers. No extension change, no version bump.

Files: `lib/page_restore.lua`, `lib/sync.lua` (`restore_timeline`'s `act`, `undo_timeline`'s `restored` tag), `lib/histhear.lua` (two lines:
the History page's Restore passes its act on), `lib/hub.lua`, `StudioSync - Publish session.lua` (two lines), `lib/together.lua`,
`lib/page_play.lua`, one line in `StudioSync - Live sync.lua` (shared: the start's `reaper.OnPlayButtonEx(proj)` is now
`together.play(proj, transport)`), tests `tests/test_0_60_rt_answers.lua`, `test_0_60_rt_answers_home.lua`, `test_0_60_rt_answers_skip.lua`.

## 1. "Undo this change" on a whole-song Restore's row puts today's tempo map back (rt-edits round 6, question 1, option b)

- The Restore page's "Restore whole project to here" is now one act (`opts.act`, as the History page's Restore already was), and its tempo map
  and markers change carries the same `act` (`sync.restore_timeline(..., act)`). The History page's Restore passes its act the same way.
- "Undo this change" on any row of that act first finds the Restore's timeline change (`restored` and the row's `act`), takes it back with
  `sync.undo_timeline` (what StudioSync's Undo uses for an act's map: the map before the Restore comes back, and only while the map here is
  still the Restore's), then puts the objects back as before. What REAPER moves for the map isn't an edit of yours (`opts.retimed`, as Undo).
- Rule: only a Restore's timeline change, only when the map is yours to change (`can(user)`, the driver's). Rows of an ordinary edit are as
  before. The map it puts back goes out tagged `restored`, so StudioSync's top-bar Undo and Redo pass over it, as they pass over the restored
  objects.
- A Restore made before this build has no act on its timeline change: its rows undo the objects only, as before.

## 2. The Restore page puts a restored take back on its beat (round 6, question 3)

Both "Restore whole project to here" and "Restore selected tracks to here" hand `mirror.revert` the same `map_of` as the History page
(`histhear.map_of`, else the song's first map): an item's version made under another tempo map lands on its beat under the map in place
(`mirror.retime`; its limits stand: position, and length in beats mode, only; no gradual tempo changes). Undo this change doesn't (as
StudioSync's Undo doesn't).

## 3. A song's home is the member who added it

- Today's rule was: session.json's `host`, but only while that person's own computer had written session.json last (`trust.own_file_ok`).
  Any bandmate's computer that rewrote session.json (an older build's timeline) set the sharer aside, and the home came and went.
- Now: when a member shares a song, their computer notes it once in their own hub file, `<song>/hub/<person>.json` (`added = <time>`, beside
  its handovers: `hub.note_added`, called by Publish session for a new song or its own re-publish). Hub files are already signed per computer
  (`lib/signed.lua` kind "hub") and checked by `trust.own_file_ok`, and go over the direct link from their person's computer.
- `hub.transfers`: the sharer is session.json's `host` when that person's own hub file (believed by the same check) says `added`. Whoever wrote
  session.json last no longer matters, and the sharer isn't listed as forged. Otherwise the rule before.
- Handing on is unchanged (`hub.home_of`): the adder, the home now, or the owner or an admin; `hand_song` keeps the `added` note.
- **Old songs:** with no note, the rule before. The first time the sharer's own computer looks (Live sync's hub tick, Settings > Studio), it
  notes its person as the adder (only when session.json names this computer's person), so the home holds from then on.
- Not changed: a member who writes `added` in their own file isn't the adder unless session.json names them; hub ranking still takes the home
  as given, so the home hosts when it's here (rt-hubrank).

## 4. Band Play together honours "Transport: Play (skip time selection)"

- A start can carry `skip = { s, e }`: the time selection ahead of the start position (`together.start(..., skip)`, `together.skip_of`). Play
  only, never Record.
- Every computer fires it (`together.play`, from Live sync, the leader's own included) as REAPER's own action 40317 over that selection: the
  selection is set to the leader's, then Play (skip time selection). Without a skip, or from past the selection, it's Play as before.
- A late start (`together.plan`): from as far in as the others have got by skipping, so it lands past the selection with them.
- Received skips are checked: two numbers, 0 <= s < e < 1e7, else ignored.
- How the driver asks for it: the panel's Start together has a "skip the time selection" box under the count-in. The web UI's Play and Song
  pages don't offer it yet (they start without a skip).
- **Older followers** (no `together.play`) ignore `skip` and play through the selection: after the skip they're (e - s) seconds of song behind
  the others, as everyone was before. The leader and every follower on this build skip.
- Follow mode ("Follow each other", REAPER's own transport) is unchanged: the leader's skip is a seek there, and followers re-cue to it.

## Tests

- `tests/test_0_60_rt_answers.lua` (rt-edits' stand-in REAPER that moves beat items on a tempo change; a trimmed copy of its harness):
  a mute, then 90 bpm from 2 s; the page's whole-song Restore to before both (one act, its timeline change under that act); "Undo this change"
  on one of its rows: today's map back, Drums 2 back where today's map put it, Bass 1 muted again, the map's change tagged `restored`, nothing
  more sent as yours, the laptop the same. Item 2: Gtr at 2 s under 120, the tempo to 60 (Gtr to 4 s, sent), Gtr deleted, the tempo back to
  120; Restore selected tracks to the point after the change: Gtr at 2 s, 6 s long (beat 4 under 120), not 4 s; the laptop the same; the
  whole-song Restore hands the same `map_of` (60 bpm for that version).
- `tests/test_0_60_rt_answers_home.lua`: the adder noted once; session.json written by another computer: the home stays the adder and nobody
  is called forged; a member writing `added` isn't the adder; an adder file from another computer doesn't count (and is said); handovers by
  the adder, the home and the owner keep the note; an old song: the rule before, then its sharer's computer notes it and the home holds; the
  home hosts in `hub.elect_song` when here, the ranking when away; Publish session calls `note_added`.
- `tests/test_0_60_rt_answers_skip.lua`: the start carries the selection only when asked, for play, and only ahead of the start; received
  skips checked; late starts; `together.play` runs 40317 over the leader's selection, plain Play without one, from past it, for a recording, or
  in a tab that isn't in front (with a log line); Live sync's and the panel's wiring.
- Each item's test fails with its change taken out (mutation runs in a copy: the undo's timeline step off; `map_of` off; the act off the
  timeline change; the adder rule off; the old-song note off; together.play/plan absent).

## REAPER checks (desktop, laptop, LinuxBox on this build; Cross Test)

1. **Undo of a whole-song Restore (item 1):** on the desktop (driver) mute an item, then add a tempo marker at bar 3 (90 bpm); wait for both
   on the others. Restore page > the row before both > Restore whole project to here. Then click one of the Restore's rows > Undo this
   change. On all three: the 90 bpm marker is back, the items sit where they were after the tempo change (Health green), the item is muted.
   `rooms/main/events/`: the Restore's timeline event carries the same `act` as its objects; the undo's timeline event has `"restored": true`.
   The desktop's next looks send nothing more. StudioSync's Ctrl+Z after it doesn't take back that map.
2. **Take on its beat (item 2):** record a take at bar 2, set the tempo to 60 from the start (the take moves), delete the take, set the tempo
   back to 120. Select its track, Restore page > the row after the tempo change > Restore selected tracks to here: the take is on bar 2 beat 1
   (where it was at 120), on all three. A project set to Time timebase leaves it at its stored seconds.
3. **Home (item 3):** share a new song from the laptop. `<song>/hub/<laptop's person>.json` holds `"added"` and a `.sig` beside it. On the
   desktop, make an edit that makes it write session.json (a tempo change while a computer on an older build is in the room), or copy
   session.json over from the desktop: Health's hub row still says the laptop "shared it", and `rthf_view.lua` shows `home` = the laptop on
   all three. For an old song (Cross Test), the desktop's own hub file gains `"added"` within a few seconds of Live sync starting there.
   Settings > Studio > the song's hub: hand it to LinuxBox; LinuxBox hosts; the desktop's file keeps `"added"`.
4. **Skip (item 4):** time selection over the verse, edit cursor before it, panel > Play > Start together > tick "skip the time selection" >
   Play together. On all three REAPER jumps over the verse at the same moment (no re-cue gap); each computer's time selection is the
   desktop's. Start one computer late (Live sync started a few seconds after the click, past the verse's start): it starts after the verse.
   With the project in a background tab on one computer, that one plays through and its log says so. Repeat with Record together: no skip.
   A computer on an older StudioSync plays through the verse.

## Review later (security)

- `added` is a member's own word in their own signed hub file. It counts only for the person session.json names, so it gives nothing a
  member could not already take by writing session.json from their own computer (the rule before). Anyone in session.json's `host` field
  plus their own `added` is the home: session.json itself is still writable by any member's computer (unchanged).
- The old-song note is written only by the computer whose person session.json names, for that person.
- `skip` is two numbers, range-checked (`together.skip_range`); it sets this computer's time selection and runs a fixed action id.

## Questions for James

1. (answered in round 2: built) **"When the driver starts with that action"**: ReaScript can't see which action started playback, and REAPER has no skip *mode* to read
   (40317 is a one-shot action). So today the driver asks for the skip with the panel's box. To honour REAPER's own 40317 (and a toolbar
   button bound to it) directly, the extension would note it (`hookcommand` for 40317, not consuming it, writing an ExtState Live sync reads
   when the band starts): a small C++ change and an extension release. Build that? And should the web UI's Play/Song pages get the box?
2. (answered in round 2) A start inside the time selection: as REAPER does, below.
3. (answered in round 2: put back) With REAPER's "loop points linked to time selection" on, setting the leader's selection on a follower moves its loop range too; a looped
   Play together with a skip then loops the selection. Leave it?

## Left / not done

- Not run in REAPER or between computers. The full `tests/run.py --no-luals` result is in the report.
- The web UI's starts don't carry a skip; follow mode doesn't either (it re-cues on the leader's jump, as before).

## Round 2 (James's answers, 2026-11-21)

Files: `extension/reaper_menu.cpp` (C++: needs the next extension release; no version bumped), `lib/together.lua`, `StudioSync - Live
sync.lua` (shared: five small lines in the start fire and the follow code), `lib/webui/play.js`, `lib/webpages.lua`, `lib/webui/daw.js`,
`lib/webui/daw.css`, `lib/dawview.lua`, `tests/test_0_60_rt_answers_skip.lua`, one expected string in `tests/test_0_60_rt_dawview.lua` (the
Song page's Play now sends `{ play: 'start', skip: ... }`). `lib/webui.lua` and `lib/webui/index.html` weren't needed and weren't touched.

**1. REAPER's own Play (skip time selection) drives it.**
- The extension's `hookcommand` (`on_command`, StudioSync's build only, not ReaPersona's) notes every run of 40317 before anything else and
  never eats it: ExtState `BandSync` / `play skip` = REAPER's `time_precise()` then. Key, toolbar button, menu or script all go through it.
- Live sync's follow code (Follow each other / side by side, follow the driver): when this tab starts playing and a note from the last 2 s
  (`together.PRESS_WINDOW`) is there for the tab in front, the start cue carries `skip` = the time selection that ends after the start
  (`together.pressed_skip`; the note is taken, so a later plain Play isn't read as one). Followers fire it as REAPER's own action, as in round 1.
- REAPER's jump over the selection isn't a seek any more, on the leader or on a follower that skipped it (`together.skip_jump`: the jump lands
  where skipping puts it). Before, the leader's jump went out as a re-cue and everyone stopped and restarted. A real seek during a skip play
  still re-cues, and keeps the skip.
- A follower's own run of 40317 (from `together.play`) is noted by its extension too. `together.play` takes that note at once, so it is never
  read as the follower's own press.
- With an older extension nothing is noted: the panel's box is the way, as in round 1.
- The web UI: the Play page has "skip the time selection" beside count-in, click and bars later (`skip` in its `go`, play only). The Song page
  has a "skip selection" box beside the play button (`{ play: 'start', skip }`; `dawview.parse` takes `skip` only as `true` and only with a
  start).

**2. Starting inside the selection: do what REAPER does.** I couldn't find what 40317 does from inside a time selection: not in the reaper
skill's API index, the local action lists, or two web searches (no REAPER forum posts came up; sources below). So no StudioSync rule is written
for it: the start carries the skip whenever the selection ends after the start position (`together.skip_of`: before `e`, not only before `s`),
and every computer runs REAPER's own 40317 from the same place over the same selection (`together.play`: cursor before `e`). Whatever REAPER
does from inside (play on and skip nothing, or jump to the selection's end at once), each computer does the same. If the leader's REAPER jumps
to the end at once, its start cue already says the end and carries no skip. Not settled: a late joiner's position when the start was inside
(taken as plain time, which is right if REAPER plays on from inside). REAPER check 7 below settles it.
Sources searched: [Reaper shortcut key list by headings](https://reaperaccessibility.com/wiki/Reaper_shortcut_key_list_by_headings),
[Translations:Basic editing/9/en](https://reaperaccessibility.com/wiki/Translations:Basic_editing/9/en),
[Ardour discourse: skip range in playback](https://discourse.ardour.org/t/skip-range-in-playback/103353) (describes REAPER's action, not from inside).

**3. A follower's own time selection comes back.** `together.play` keeps this computer's own selection when it sets the leader's. Live sync's
pass (`together.restore_own`) puts it back once the playhead is past the skipped selection's end, or when playback stops, whichever comes first.
With loop points linked to the time selection, the loop comes back with it. A selection the person changed in the meantime is theirs: left as it
is. The leader (its own selection is the skip) has nothing to put back.

### Round 2 tests (`tests/test_0_60_rt_answers_skip.lua`, each failing with its change taken out)
- The start from inside the selection carries the skip, and `together.play` runs 40317 from inside; a selection behind the start doesn't.
- Own selection: kept while the playhead is before the end; back at stop (rt-fix5; was "back past it"); a selection changed meanwhile is left alone;
  nothing kept on the leader.
- The press note: taken once; an old one or one from another tab isn't a press; a follower's own run is taken by `together.play`.
- `skip_jump`: the jump over the skip, not a seek elsewhere or without a skip.
- The C++: `on_command` notes 40317 before its own action's check, so it isn't eaten; `"play skip"` = `time_precise()`; StudioSync's build
  only. Built with `extension/build_windows.cmd` (to a scratch file name through `DLL_OUT`, so the tracked DLL is unchanged) for StudioSync and
  for ReaPersona: both compile. No native test covers `reaper_menu.cpp` (it needs REAPER's API); the native sign and keep tests pass.
- Wiring in Live sync, the Play page, the Song page; `dawview.parse`'s `skip`.

### Round 2 REAPER checks (after the extension release; desktop, laptop, LinuxBox)
5. **REAPER's own action:** laptop and LinuxBox follow the desktop (panel > Play > Follow each other at 0 bars, or follow the driver). On the
   desktop make a time selection over the verse, put the edit cursor before it, press Alt+Space (Play (skip time selection)) or a toolbar
   button bound to it.
   - All three jump over the verse together, with no stop and restart on the followers when the desktop jumps.
   - The start event in `rooms/main/events/` has `"skip":[s,e]`.
   - The followers' time selections are back to their own once past the verse, or when you stop before then.
   - Press plain Space next: no skip anywhere.
6. **Linked loop:** on the laptop turn on Options > "Loop points linked to time selection" and set its own selection and loop elsewhere. Repeat
   5: after the verse, or at stop, the laptop's selection and loop are its own again. Check too that, playing on after its selection came back,
   the laptop doesn't skip its own selection when the playhead reaches it. If it does, REAPER skips whatever the selection is at the time, and
   the put-back has to wait until stop.
7. **From inside the selection:** cursor inside the verse's selection, Alt+Space on the desktop. Note what REAPER does (plays on from the cursor,
   or jumps to the selection's end) and that the followers do the same. Then start one follower's Live sync a few seconds late: say where it
   starts, and I'll set the late start's rule to match.
8. **Web UI:** Play page > tick "skip the time selection" > Play together: as step 4. Song page > tick "skip selection" > play: the same. In a
   375 px phone view the Song page's bar still fits (the box wasn't checked in a browser).

### Round 2 review-later (security)
- `play skip` is local ExtState from this computer's own extension; a script could write it too, which only adds a skip to this person's own
  start.

## REAPER check results (rt-r0, 2026-11-21, 0.59.49.92 + extension 1.0.34; desktop leads, laptop and LinuxBox follow)

How: each step through the dev-eval hooks. The panel's buttons were stood in for by the same functions in the same order (`page_restore`'s
`R.test.restore_whole` / `restore_tracks` / `undo_change` with the panel's env and opts; `hub.hand_song`; `together.start` / `together.go`); presses
of REAPER's own transport by `Main_OnCommand(40317)`, `OnPlayButtonEx`, `OnStopButtonEx` on the desktop; the web pages in the desktop's browser.
Transport timing from a defer sampler on each computer (play state, `GetPlayPosition2Ex`, selection, loop), mapped onto the desktop's link clock
(`StudioSync_DirectClock` offsets: laptop -1357 ms, LinuxBox -68 ms). Everything was put back (marker, mute, test track, hub, selections, follow).

| # | Result | Evidence |
| --- | --- | --- |
| 1 | **pass** | Drums item muted, 90 bpm at bar 3 (Keys 7.385 -> 9.026 s) on all three. Restore whole project to row 2725: one act (`...r431160`), its timeline event carries that act and `restored: true`, 11 items + 1 envelope; all three back at 130 bpm, unmuted. Undo this change on row 2740: 90 bpm back, Keys 9.026, Drums muted, on all three; the undo's timeline event has `"restored": true`; nothing more sent after. StudioSync's Undo would take 2738 (my own tempo act), not the restored map. Health's colour not read (positions compared directly). |
| 2 | **pass** (MIDI item, not a recorded take) | New track with a 1-bar MIDI item at bar 2 (1.846 s); tempo 60 (item to 4.000 s, sent); item deleted; tempo back to 130. Restore selected tracks to the row after the tempo change: 1.846 s + 1.846 s, bar 2 beat 1, on all three (not 4.0 s). Not run: a real audio take (no recording into the studio), the Time-timebase case. |
| 3 | **pass** (old song; no new song shared) | Desktop's `Cross Test/hub/James.json` has `added` (written 14:36 today) and a `.sig`. `home`/`hub` = James on all three. The laptop rewrote `session.json` (Syncthing carried it: the old rule now says no, `trust.own_file_ok(session.json, James) = false`), yet sharer = James, adder kept, nobody set aside, home James on all three. Handed to LinuxBox: all three `home`/`hub` = LinuxBox, LinuxBox "you're the hub", James.json keeps `added`; handed back. Not run: sharing a new song from the laptop (it would add a song to the studio). |
| 4 | **pass** | Start together, skip ticked, selection = Verse (2.769-18.462), cursor 0: start event `skip: [2.769, 18.462]`; all three start within 53 ms and jump over the verse within 4 ms (no re-cue); song time after within 38 ms; followers take the desktop's selection, then their own back past it. Late joiner (LinuxBox's Live sync stopped, started 8.6 s after the planned moment): "playing together from 24.28 s", in step 75 ms behind (past the verse). Background tab on LinuxBox: plays through, log "a start that skips a time selection plays through it in a tab that isn't in front". Record together with the box ticked: no skip (desktop and laptop recorded through the verse; nothing armed). Not run: an older StudioSync. |
| 5 | **pass, with the bug below** | 40317 pressed on the desktop with both following at 0 bars: start event has `skip`; all three jump together (140.17-140.23 s), no stop/restart; followers' own selections back past the verse, and back at stop when stopped before it; plain Play next: no skip anywhere. |
| 6 | **fail** (the case foreseen above) | Laptop with linked loop, own selection/loop 30-34: both come back after the verse, but REAPER's skip play then skips whatever the selection is: the laptop jumped 29.98 -> 34.02 s, that jump went out as a seek (a `James-Laptop` start event at 34.016 s) and the desktop and LinuxBox jumped with it. Same in check 5 with LinuxBox's own 25-27 s selection (LinuxBox start event at 27.006 s, everyone followed). So the put-back has to wait until stop. |
| 7 | **REAPER plays on from inside** | Cursor at 6 s inside the verse, 40317: REAPER plays on from 6 s and skips nothing, on all three (start event still carries `skip`); followers' selections back at 18.46 s. Late follower (LinuxBox 5.5 s late): "playing together from 11.59 s", plain time, in step (69 ms). The late-start rule as built (plain time from inside) matches REAPER. |
| 8 | **Play page pass; Song page layout pass; Song page start not run** | Play page, count-in 0, click off, skip ticked, Play together: start event `skip: [2.769, 18.462]`, all three jump at 572.44-572.45 s. Song page at 375 px: play, stop and "skip selection" fit on the first row, no sideways scroll (scrollWidth 375). Its Play wasn't pressed: it always counts in one bar with the metronome on every computer (`dawview.lua` `together.start(..., 1, true, ...)`), a sound outside the handoff's sound-test rules. |

**Bug (checks 5 and 6):** `together.restore_own` puts a follower's own time selection back while the skip play is still running; REAPER's 40317
play skips the selection in place when the playhead reaches it, so the follower jumps over its own selection, and in Follow each other that
jump is read as a seek (not `skip_jump`: `side.skip` is the leader's) and everyone follows it. Fix: put the selection back only at stop
(drop the "past the end" branch of `restore_own`), or treat a jump over the follower's own restored selection as a skip and not post it.

**Rig notes:** LinuxBox's REAPER has "Stop playback at end of project" on (`stopprojlen` = 1, its default; 0 on the desktop and laptop). Cross
Test is 22.754 s long, so LinuxBox stops at 22.8 s in any Play together, and a start past the end (rt-ears' 60.05 s) stops at once: that is
rt-ears' "transport doesn't run" (set to 0 in memory for checks 4/7's late joiner, put back to 1). LinuxBox also shows REAPER's "No tracks are
armed" box on Record together (it blocked REAPER 75 s; Live sync then said "REAPER didn't start (record ... was cancelled)").

## rt-fix5: fixes from this re-check (2026-11-21)

Offline build and tests only; nothing here was run in REAPER. Files: `lib/together.lua`, `StudioSync - Live sync.lua` (shared: the record
start, four lines, and one comment), `tests/test_0_60_rt_answers_skip.lua`, `tests/test_0_60_rt_fix5.lua`. `lib/page_play.lua` not touched.

**1. A follower's own time selection comes back at stop, never mid-play (checks 5 and 6).** `together.restore_own` waited for the playhead to
pass the skipped selection's end; REAPER's Play (skip time selection) skips whatever the selection is when the playhead reaches it, so the
follower then skipped its own selection and that jump went out as a seek everyone followed (LinuxBox's 25-27 s, the laptop's linked loop at
30-34 s). Now the selection, and so a linked loop, is put back only once playback has stopped (paused counts as playing: a resumed play still
skips). The round 2 rule "past the skip, or at stop, whichever comes first" is now "at stop".

**3. Record together with nothing armed (rig note above).** Before REAPER's Record, Live sync asks `together.armed(proj)` (any track with
`I_RECARM`). With none armed it doesn't record there: it plays along from the same place (so it stays in time with the take), logs it and puts
it on the panel's "together" line: "recording together, but no track is armed here: playing along without recording (arm a track to record
with the others)". REAPER's modal "No tracks are armed" box isn't reached.

Tests (each fails with its change taken out): `test_0_60_rt_answers_skip.lua` "past it, still playing: not yet", "paused: not yet", "back at
stop"; `test_0_60_rt_fix5.lua` part 3 (`together.armed`, and the Live sync wiring before `Main_OnCommand(1013)`).

### rt-fix5 REAPER checks (desktop leads, laptop and LinuxBox follow, Cross Test)

9. **Check 6 again (item 1).** Laptop: Options > "Loop points linked to time selection" on, own selection and loop at 30-34 s. LinuxBox: own
   selection at 25-27 s. Desktop: selection over the verse, cursor before it, Alt+Space (40317) with both following at 0 bars. Let it play past
   34 s (LinuxBox stops at 22.8 s by its own "Stop playback at end of project": set `stopprojlen` 0 in memory for this, as before).
   - While playing, the followers keep the desktop's selection; nobody jumps at 25 s or 30 s, and no `James-Laptop` or `LinuxBox` start event
     appears in `rooms/main/events/` during the play.
   - Stop on the desktop: within a second the laptop's selection and loop are 30-34 s again, LinuxBox's 25-27 s.
   - Pause instead of stop: the selections stay the desktop's until stopped.
10. **Record together, nothing armed on LinuxBox (item 3).** Disarm every track on LinuxBox; arm a silent track (no input) on the desktop.
    Panel > Record together. Expected on LinuxBox: no "No tracks are armed" box; its REAPER plays along in time; its log and panel line say
    "recording together, but no track is armed here: playing along without recording ...". The desktop records as usual. Stop together
    stops LinuxBox too. Put the arms back.

### rt-fix5 check results (rt-r1, 2026-11-21, 0.59.49.93 + extension 1.0.35; desktop leads, laptop and LinuxBox follow)

How: through the dev-eval hooks; 40317 / `OnPauseButtonEx` / `OnStopButtonEx` on the desktop's Cross Test tab; Record and Stop together as
`together.start(..., rec)` / `together.go(stop)`; a defer sampler on each computer (play state, position, selection, loop) mapped onto the
desktop's link clock. Follow each other at 0 bars ("side" = "0") on all three for the run (the desktop too: with its "side" empty it posts
no start at all, so the followers stayed stopped on the first try), then back (desktop "", laptop "2", LinuxBox ""). LinuxBox's
`stopprojlen` 0 in memory for the run, back to 1. The laptop's linked loop (40621) was already on and stayed on.

| # | Result | Evidence |
| --- | --- | --- |
| 9 | **pass, plus one bug** | Laptop 30-34 s selection and loop, LinuxBox 25-27 s, desktop the verse, 40317 at 0. All three take the desktop's selection at the start (same sample), jump the verse together (2.74 -> 18.47 s, within 70 ms), and play on to 59-65 s with no jump at 25, 27, 30 or 34 s and the desktop's selection kept. `rooms/main/events/` got only James's start (with `skip`) and stop; no `James-Laptop` or `LinuxBox` event. Stop on the desktop: the laptop's selection and loop are 30-34 again and LinuxBox's 25-27 in the same sample as their stop (about 60 ms after the desktop's). Pause instead: the followers pause too (30.6 s) and keep the desktop's selection. |
| 10 | **pass** (on the laptop too) | A silent armed track ("XT R1 take", its own output, no input) on the desktop only. Record together: no "No tracks are armed" box on LinuxBox or the laptop (both hooks answered throughout); both play along from 0 and log "recording together, but no track is armed here: playing along without recording (arm a track to record with the others)"; the desktop recorded a 10.6 s take; Stop together stopped both ("stopped together (James) at 12.44 s, by time"). The test track and take were deleted after (the take went to the Recycle Bin in the need-list check). |

**Bug (check 9): a pause then a stop on the leader isn't passed on.** Live sync posts a stop when `playing` (`ps & 1`) changes, so the
pause posts `stop` with `pause: true` (event `James-20261122-001129Z-00004`) and the stop after it posts nothing: paused is already "not
playing". The followers stayed paused at 30.6 s with the desktop's selection while the desktop sat stopped (checked 5 s and 30 s after);
pressing Stop on each follower put their own selections back at once. Fix: also post a stop when the state goes from paused (2) to
stopped (0) (`StudioSync - Live sync.lua`, the `playing ~= side.playing or jumped` test).

**Found (check 10): Record together is a bar out on a computer with REAPER's record pre-roll.** The desktop and laptop have
`preroll` = 2 (pre-roll before recording) with `prerollmeas` 1. The desktop's Record started at -1.856 s at the planned moment while
the followers started at 0 at the same moment (samples: desktop t - pos = ...527.454, laptop ...525.580, LinuxBox ...525.615), so the
followers play 1.85 s (one bar at 130 bpm) ahead of the recording computer, and stopped at 12.44 s where the desktop was at 10.70 s.
Followers that record would pre-roll too and line up; play-along ones (this round's item 3) and plain followers don't. Not fixed here:
either start the play-along followers at `pos - prerollmeas` bars, or have `together.start` (rec) leave the leader's pre-roll out.
