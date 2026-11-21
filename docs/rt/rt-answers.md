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

1. **"When the driver starts with that action"**: ReaScript can't see which action started playback, and REAPER has no skip *mode* to read
   (40317 is a one-shot action). So today the driver asks for the skip with the panel's box. To honour REAPER's own 40317 (and a toolbar
   button bound to it) directly, the extension would note it (`hookcommand` for 40317, not consuming it, writing an ExtState Live sync reads
   when the band starts): a small C++ change and an extension release. Build that? And should the web UI's Play/Song pages get the box?
2. A start whose position is inside the time selection isn't given a skip (REAPER's own behaviour from inside a selection wasn't checked
   offline). OK?
3. With REAPER's "loop points linked to time selection" on, setting the leader's selection on a follower moves its loop range too; a looped
   Play together with a skip then loops the selection. Leave it?

## Left / not done

- Not run in REAPER or between computers. The full `tests/run.py --no-luals` result is in the report.
- The web UI's starts don't carry a skip; follow mode doesn't either (it re-cues on the leader's jump, as before).
