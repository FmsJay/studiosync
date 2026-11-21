# Edits we hadn't tried (rt-edits)

James, 2026-11-20: "Make sure support for any edits we haven't tried, for example: copying regions, cutting regions or items, skipping
regions/time selections from the setting that does that, looping a session, loop recording, anything else that needs to be tested or
proven."

This round also fixes a bug found in REAPER the same day: the laptop's Cross Test had Hold sync on since the night before.

## 1. The edit matrix (`tests/test_0_60_rt_edits.lua`)

### The harness

- **`tests/fixtures/editreaper.lua`** is a new stand-in REAPER whose tracks and items *are* their chunks. It does what REAPER does to a chunk:
  - an item's GUID and P_EXT are written into its chunk when it's read and taken out when it's set;
  - position, length, mute, group, selection, takes and the active take are read from the item's text and written back into it;
  - setting a track's chunk replaces its items, which keep their pointers by IGUID;
  - it keeps markers, regions, the region render matrix, the tempo map, the loop range, repeat and track selection with reordering.
- Each computer gets its own instance: the desktop (James), the laptop (Bee) and a late joiner (Cee). They share one events folder in
  memory, standing in for Syncthing. The test uses the real `mirror.watch`, `sync.watch_timeline`, `sync.receive`, `undo.step` and
  `mirror.revert`.
- Every step is a new second (`os.date`/`os.time` are faked), because Undo groups an act by its second and by its look.

### What each edit must do

The matrix runs twice. The first round detects edits with Live sync's quick look and the second with full looks. Each round edits a fresh
song.

1. **Detected:** every object a full scan reads differently after the edit has gone out. That's in the edit's first look, except for what
   StudioSync itself makes of the edit in that look (takes into lanes), which goes in the next. In the quick round:
   - it must be a quick look (adding a track is a full look by design);
   - afterwards, the look's view of every object must equal a full scan's.
2. **Sent and applied the same:** every object's hash and the track order on the laptop equal the desktop's. So do the tempo map and markers,
   the marker numbers and the render matrix. Nothing that landed is sent back.
3. **One Ctrl+Z:**
   - the laptop renames a track and that lands on the desktop, so a StudioSync undo point is on top of the desktop's list;
   - the desktop's `undo.step` then puts back every object the edit touched, on both computers, and the laptop's rename stays;
   - redo is one step too.
4. **Late joiner:** after all the edits, a computer that opens the song (its file's markers, no objects) catches up from the events and
   ends up exactly like the desktop.

| Edit | Result |
|---|---|
| Copy a region with its items on two tracks, envelope points moving with items (the region copied too) | passes (after fix A) |
| Copy a region with its items, envelope points staying | passes |
| Cut a region with its items (ripple off) | passes |
| Cut items with ripple per track | passes |
| Ripple on all tracks: an item deleted, items on every track, markers and envelope points after it move | passes |
| Duplicate items | passes |
| Duplicate a time selection (pieces of items) | passes |
| Split at the time selection (right parts carry the item's id, as REAPER copies P_EXT) | passes |
| Heal splits | passes |
| Glue (the glued item keeps the first item's id) | passes |
| An item's take envelope | passes |
| Loop recording: one item, three takes | passes |
| Loop recording into lanes (track to fixed lanes, three items on three lanes) | passes (one Ctrl+Z after fix A) |
| Recording with a time selection, auto-punch (the take trimmed to it) | passes; the record mode itself travels as `projrecmode` in the project settings |
| Markers and regions renumbered | **failed, fixed** (fix B) |
| The region render matrix | **failed, fixed** (fix B) |
| A tempo marker added under items in beats (REAPER moves what's after it), one item set to time staying | **failed in REAPER, fixed** (fixes G, H) |
| The first tempo changed under items in beats (REAPER moves them all) | **failed in REAPER, fixed** (fixes G, H) |
| A track template inserted, made from a shared track (its items carry the studio's ids) | passes: new ids, the original untouched everywhere |
| An item moved to another track, nothing else changed | **failed in REAPER, fixed** (fix F) |
| An item dragged to another track and along it | passes |
| Pooled MIDI copies, then the pool edited | passes: each copy arrives as plain MIDI with the same notes |
| An empty item, and one with notes | passes |
| Items grouped, then moved together | passes: both moves go out; group ids stay each computer's own (by design, 0.58.91) |
| Play together while looping | **failed, fixed** (fix D) |
| Late joiner after all of the above | **failed, fixed** (fix C) |

### Fixes

**A. One Ctrl+Z took back only part of an edit that touched several tracks or kinds** (`lib/mirror.lua`)
- Cause: Undo grouped an act by `mirror.same_moment`: the same second, the same person, the same kind of object, the same track. A region
  copied with items on Drums and Bass and their envelope points was three presses, as was recording into lanes (track and items).
- Fix:
  - every change one look sends now carries `act`, an id for that look;
  - a burst spread over several passes (`mirror.more`) keeps its first pass's act (`mirror.more_act`);
  - `same_moment` also takes the rest of the act, whatever its track, kind or second;
  - deletions on different lanes still stay apart, as the comp-lane rule from 0.42.10 wants;
  - events without `act` (older versions) group exactly as before.
- Note: this only matters when Ctrl+Z goes through StudioSync, that is when a bandmate's change (a StudioSync undo point) is on top of your
  list. With your own edit on top, `StudioSync - Undo.lua` runs REAPER's own undo, which was already one step.

**B. Marker numbers and the region render matrix stayed each computer's own** (`lib/band.lua`, `lib/sync.lua`)
- `band.capture_markers` now also gives each marker's `num`, and each region's `render` row: the ids of the tracks that render it, with
  "MASTER" for the master mix. A region with no row gives no `render`.
- `band.apply_markers` gives each marker the sender's number (`SetProjectMarkerByIndex2`) and sets each region's row. Your own local tracks
  in a row are left alone.
- Only lists that carry numbers are applied this way. An older StudioSync's timeline leaves numbers and rows as they are here.
- `sync.TIMELINE_FORMAT` is now 6, so the first look after updating isn't taken for an edit.

**C. A late joiner could put a track at the top for good** (`lib/sync.lua`, `sync.receive`)
- Cause: catching up, a track's newest change could come before the newest change of the track above it. It found nothing to sit under, so it
  went first. An Undo's or Redo's track change carries no hash, so nothing ever read it as out of place.
- Fix: within a pass, a track's newest change now lands after the track it sits under, when that one lands in the same pass. A loop of them
  stays in time order.

**D. Play together didn't carry the loop** (`lib/together.lua`, `StudioSync - Live sync.lua`)
- Cause: only a producer's remote start carried the loop. With Play together, each REAPER looped by its own repeat and loop range, so the band
  came apart at the first loop end.
- Fix:
  - `together.go` adds `loop` to a start: `{ start, end }` with repeat on, or `false`;
  - Live sync applies it for a band start (`together.apply_loop`), but not for a follow cue, which already re-cues on every jump;
  - a start from an older StudioSync (no `loop`) leaves yours alone.

**E. A held computer never took the band's timeline after the update** (`lib/sync.lua`, `sync.timeline_waits`). Found in REAPER on
0.59.49.69.

What the REAPER check showed (read-only probes, plus test edits on Cross Test's region 1, put back afterwards):
- **On the desktop, both edits go out within a second:**
  - unticking XT Rec A in the render matrix wrote event `James-20261120-182753Z-00005` about 1 s later;
  - renumbering region 1 from 1 to 5 wrote `James-20261120-182822Z-00006` about 1 s later;
  - neither needs the change count to move (it did move: 9 -> 10), because `sync.watch_timeline` runs every pass.
- **The laptop never applied them.** Its Cross Test has `hold = "1"`: the colour try's Hold from before fix 2. The laptop's log says "Hold my
  changes is on in this project" at 12:16:48.
  - While held, Live sync doesn't look at the timeline, so the laptop's "seen" timeline was still written in format 4.
  - `timeline_waits` compares that with a format-6 signature. The new `num` and `render` fields read as a timeline change of the laptop's
    own, so every map and marker from the band waited for good.
  - This would happen to anyone holding across the update.

Fix:
- when "seen" is in another format (or has none: Open/Publish session write one without), only what both formats hold counts as yours: the
  tempo map and each marker's kind, place, end, name and colour;
- a real held marker edit still holds the band's timeline back.

One more limit: a timeline edit made in the moments after updating, before Live sync's first look in the new version, is taken in as that
first look and not sent. That was already so for every format bump.

Test (`tests/test_0_60_rt_edits.lua`, last block):
- a render-matrix tick and a renumbering are written straight into the stand-in, with no change count;
- they go out in the next Live sync pass (quick look, then the timeline's look);
- the laptop, held with a format-4 "seen", takes both;
- a held marker rename of its own still keeps the band's next marker change waiting;
- with `timeline_waits` as it was, the test fails at "held, the laptop took the renumbering".

**F. An item moved to another track, with nothing else changed, was never sent** (`lib/mirror.lua`, `W.one` and `mirror.edited_here`). Found in
REAPER on 0.59.49.72 (checklist step 12).

Cause, confirmed in REAPER (the first item on XT Keys C moved to XT Drums A and back inside one script run, so nothing was sent and the project
ended as it was):
- `MoveMediaItemToTrack` leaves the item's chunk, GUID and id exactly as they were. Only its track changes, as in the stand-in.
- The look did see it: the item's hash takes its track in, and it read `af216e0e` against the recorded `2006d785`.
- `W.one` then asks "is this just the band's version, read anew?" in three places, and all three compared the band's item with the one here
  on the track it's on *now*, or with no track at all:
  - the anchor check hashed the event's item with the item's present track;
  - the "only which take plays is new" check did the same;
  - the "same but for its dry/wet labels" check (`mirror.same_but_labels`) compares the two texts only. In REAPER it answered `true` for the
    moved item, so the move was recorded as nothing and never went out.
- `mirror.edited_here` (what Restore and Undo ask before replacing an item) had the same hole.

Fix: each of those checks now also needs the item to be on the track the band's version names. An event that names no track (an older one)
is judged as before.

Why the matrix didn't catch it: its case moved the item to another track *and* along it, so the text differed too. The fixture's move
already behaved as REAPER's does.

Test: two cases replace the one. "An item moved to another track, nothing else changed" asserts the chunk is untouched by the move and that
`edited_here` says yes, then goes through the whole matrix (sent by a quick and a full look, applied by a move on the laptop, one Ctrl+Z,
redo, late joiner). "An item dragged to another track and along it" keeps the old case. With the fix taken out, the first fails at "detected
and sent (0 objects)".

**G. Ctrl+Z left the act's region and markers behind** (`lib/mirror.lua`, `lib/sync.lua`, `lib/undo.lua`). Found in REAPER on 0.59.49.73
(F3: "Time selection: Copy contents" synced, and after the StudioSync undo every computer still had the copied region).

Cause: an act held object changes only. The tempo map and markers go as one "timeline" change, sent just before the look that sends the
items, and Undo never looked at it.

Fix:
- **The timeline change is part of the act.** `sync.watch_timeline` runs before the look, so it takes the act id the look is about to use
  (`mirror.act_for`); the look then sends under that id if it follows within `mirror.ACT_SECS` (2.5 s).
- **Undo puts it back first** (`sync.undo_timeline`, called from `undo.step`), where the timeline is yours to change:
  - markers and regions: what the act added goes, what it took away comes back, matched by kind, place, end and name. Everything else stays
    as it is now, including a bandmate's markers made since;
  - where the act changed the tempo map, places can't be compared across the two maps, so the whole earlier timeline comes back, and only
    if what's here is still what the act left. Otherwise the timeline is left alone;
  - the tempo goes back before the items, so REAPER moves nothing the restores put in place.
- **Redo** does the same in reverse: the undo's own timeline change carries `undoes`, and redo inverts that one.
- After a tempo undo REAPER has just moved the act's items and points. `mirror.revert` now takes that for what it is (`opts.retimed`),
  not for "an unsent edit of yours" or "already there". Before, it left those items alone, the next look sent REAPER's moves as new
  changes, and Redo then said there was nothing to redo.

Not changed: an act that is only a timeline change (a marker added and nothing else) is still not something StudioSync's Undo steps back.
REAPER's own undo does, when your edit is on top.

Test: every matrix case that changes the timeline now also checks, after one Ctrl+Z, that the tempo map, regions and markers are what they
were before the edit, and after Redo that they're what the edit left. That covers the region copies, the ripple that moves markers, and both
tempo cases.

**H. A tempo change left receivers different** (`lib/mirror.lua`, `lib/sync.lua`). Found in REAPER on 0.59.49.73 (F6).

Cause, matched to the numbers from the check:
- when the tempo map changes, REAPER moves everything that's in beats. The sender sends the map, and the items and automation REAPER moved;
- the items and automation go as messages on the link and usually arrive first. The map came as a file only;
- a receiver that took an item first put it where the new map has it (4.615 s long), and then its own REAPER moved it again when the map
  landed (5.815 s: scaled twice). The laptop got the map first and was right; LinuxBox wasn't;
- nothing put it right afterwards: a receiver that may not change the item takes REAPER's move as "nobody's edit" and records it.

Fix:
- every change sent while REAPER may be moving things for a map (15 s after a tempo change) names the map it was made under (`tl`, from
  `mirror.map_stamp`). Undo's and Restore's changes carry it too;
- a receiver lands such a change only once it holds that map (`sync.map_waits` in `sync.receive`). In the pass that brings the map, the map
  lands first and the change after it. If the map never comes, the change lands anyway after `sync.MAP_WAIT` (30 s);
- the map now goes as a message on the link too, so it isn't the slow one.

Older versions send no `tl`, so their changes land as before.

Test (the "Edits tempo" block): a tempo marker, the first tempo changed, both put back. Each time the laptop takes the map first and a
third computer is given the items and points first, with the map's file held back. Nothing lands there before the map, and both end as the
desktop. A fourth computer is given the same changes without `tl`: its length comes out scaled twice, as LinuxBox's did.

The stand-in REAPER now moves items, track envelope points, markers, regions and later tempo markers by their beats when the map changes.
Its numbers match the check's: at 130 bpm, a 100 bpm marker at 8.0 s takes an item at 7.385 + 3.692 s to 4.615 s long.

**I. A project behind the studio's timeline could keep its stale markers, and would have published them** (`lib/sync.lua`). Found in REAPER
on 0.59.49.73 (F7: the desktop had lost the Verse region).

What the desktop's files show:
- `Cross Test.rpp` was last saved on 11-19 at 15:11. Every restart reopens that file and catches up.
- That file noted its timeline in an older `TIMELINE_FORMAT`. A note in another format reads as a first look, and the "opened behind the
  song" look at session.json only ran for a note in the current format. So after the update that look was skipped.
- The autosave made 5 minutes after the 15:22 restart has the newest map's stamp, that map's event marked done, and no region. I couldn't
  find the path that marked it done without applying it (two REAPERs were running on the desktop at 15:22, which may be part of it).

Fix, three parts:
- **Behind by the stamp.** At a project's first look, if session.json's map is newer than the newest this project has made or applied, the
  project takes it, whatever the file last noted (nothing, another format, or marker edits never sent). The stamp is now set only after the
  map is in place.
- **The stamp is checked against what's here** (`sync.timeline_heal`). Once per stamp and opening, when nothing of yours waits to go, the
  map the stamp names is read (its event, or session.json) and compared with the project's tempo and markers (kind, place, end, name). If
  they differ, the map is put in place and the log says so. This is what would have brought the desktop's region back.
- **Nothing of the timeline goes out while behind.** While a project is still catching up after opening, a tempo or marker change of yours
  waits if a newer map is waiting to land, or if that can't be told yet (`sync.timeline_behind`). A marker added before the open still goes
  out at once when nothing newer waits, as before.

Limit: when a newer map does land, it replaces the whole timeline, so a marker you added in those first seconds is gone. The log doesn't
say so yet.

Test (the "Edits reopen" block), each from a saved copy of the project reopened as a new REAPER would:
- a file noted in an older format with session.json newer takes the studio's region at its first look and sends nothing;
- a project with the newest stamp and the event marked done, but without its markers, gets them;
- with session.json not there and a marker added before the first catch-up, nothing of the timeline goes out, and the laptop keeps the region.

**The two `session.sync-conflict` files in Cross Test.** session.json is written by `sync.session_timeline`, on whichever computer sends a
timeline change. Two computers sending one within a second or two of each other both write it, and Syncthing keeps the loser as a conflict
copy.
- Today's (21:25:43-44 UTC): the desktop added a marker with the default colour. The laptop applied it, read it back with a colour
  (22955745 where the desktop said 0), took that for a change of its own and sent the timeline back one second later. The desktop applied
  that and sent again. Three timeline changes in two seconds, two computers writing session.json. This marker-colour echo is not fixed here.
- The 11-19 one is a timeline from the Mac while the desktop was also sending.
- It also explains the log line "session.json says it's James's, but another computer wrote it, so it was set aside": that check
  (`trust.own_file_ok`, used by the hub) expects only the sharer's computer to write session.json, and `sync.session_timeline` breaks that.
- Not fixed: both want a decision (one writer for session.json's timeline, or the timeline kept in a file per computer). Listed under
  "What's left".

### Not carried (gaps, not fixed)

- **"Transport: Play (skip time selection)"** and REAPER 7's region playlists ("skip hidden regions") are playback, not project state.
  - Play together starts everyone at the same place, and the skip happens only on the leader's computer.
  - In side-by-side follow mode, the leader's jump at the skip is a seek, so followers re-cue to it (Live sync's "jumped" check).
  - In a band Play together, followers play through the selection. Carrying the skip would need the start cue to name the action and its range.
- **REAPER's own undo when your edit is on top** is a whole-project snapshot. It goes out like any other edit through a full look, which the
  matrix proves for every kind of change. The snapshot itself can't be run offline.

## 2. Hold sync left on after a colour try (`lib/colours.lua`, `lib/mirror.lua`, `lib/sync.lua`, `lib/status.lua`, `lib/page_health.lua`)

Cause, as suspected:
- trying a colour scheme set ProjExtState `hold` to "1", the same value as Hold my changes;
- the crash-safe file (`mirror.stash_unsent`) stashed that as `hold = true`;
- after REAPER restarted mid-try, `mirror.restore_unsent` put Hold back on, with no Keep or Put back left to clear it, because the try lived in
  the panel's Lua;
- a project saved mid-try had the same effect.

Fix:
- **A try's hold is its own value:** `"try"`, or `"try1"` when your own Hold was already on. Everything that asks "is sending held?"
  (`hold ~= ""`) still holds during a try.
- **The try is live for this REAPER only:** `try_first` sets a non-persistent ExtState, `colour try <proj>`. Keep and Put back clear it.
- **Only your own Hold is stashed:** `sync.hold_mine(v)`.
- **A try from before a restart goes:** on each opening, `mirror.restore_unsent` turns a `try` hold that has no live try back into what Hold
  was before it, and says so in the log. If Live sync is restarted while the panel is still trying a scheme, the try stays.
- **Hold on is never invisible:**
  - Health has a yellow row, `sync.hold_words`, that says how to switch Hold off. Dismissing it lasts only that day.
  - The handover check says "Hold sync is on", or "trying a colour look".
  - The log says it each time a project opens with Hold on.
  - The panel's "Holding your changes" pill was already there.

Test: `tests/test_0_60_rt_edits_hold.lua`. It covers keep and put back, the stash, a restart without saving, a save mid-try (with Hold on and
off before it), Live sync restarted during a live try, your own Hold kept across a restart, and the Health and handover words.

Not fixed: a project already saved with the old `hold = "1"` from a try, like the laptop's Cross Test now, can't be told from a real Hold.
Switch it off once (Send now).

## Files

- New: `tests/fixtures/editreaper.lua`, `tests/test_0_60_rt_edits.lua`, `tests/test_0_60_rt_edits_hold.lua`, this doc.
- Mine: `lib/mirror.lua` (act ids and Undo grouping, the hold stash and restore), `lib/sync.lua` (`hold_mine`, `hold_words`, catch-up track
  order, `TIMELINE_FORMAT` 6).
- Small additive edits in shared files:
  - `lib/band.lua`: marker numbers and the render matrix, in `capture_markers` and `apply_markers`;
  - `lib/together.lua`: `loop_of`, `apply_loop`, and the loop on a start;
  - `StudioSync - Live sync.lua`: one line, a band start's loop;
  - `lib/colours.lua`: the try's own hold value and ExtState;
  - `lib/status.lua`: the try's words;
  - `lib/page_health.lua`: the Hold row.

## REAPER checklist (what can't be proven offline)

Run these on Cross Test with the desktop and the laptop, both on this build. "Same" means the same items, positions, takes and lanes on both,
and Health showing no mismatch.

1. **Copy a region with items:**
   - with "move envelope points with items" on, select the Verse region and its items on two tracks and copy-paste them later (the region
     too). Same on both. Then on the laptop rename any track and, once that has landed on the desktop, press Ctrl+Z on the desktop once:
     the pasted items, the points and the copy are all gone on both, and the rename stays;
   - repeat with envelope points not moving with items.
2. **Cut a region with its items:** once with ripple off, once with ripple per track, once with ripple on all tracks. On the laptop, markers
   and points after the cut moved too.
3. **Duplicate, split, heal and glue:**
   - Ctrl+D on items;
   - duplicate a time selection (Shift+Ctrl+D);
   - split at the time selection (S with a time selection);
   - heal splits;
   - glue (Ctrl+G, which also renders a new file: check it arrives and plays on the laptop).
4. **Take envelope:** show a take's volume envelope on an item and draw a point.
5. **Loop recording:**
   - with a loop and repeat on, record three passes as takes (record mode "new takes"), then the same into lanes ("new lanes");
   - on the laptop: the takes or lanes, the playing take, and lane names;
   - then record once with a time selection and auto-punch (Record: time selection auto-punch). The laptop's record mode is also set to
     auto-punch.
6. **Markers:** "Markers: Renumber all markers in timeline order", then the same for regions. The laptop shows the same numbers. Old builds on
   the Mac keep their own numbers, as before.
7. **Region render matrix:** tick a region for the Bass track and for master mix. Open the matrix on the laptop: the same ticks. Untick one:
   it goes there too.
8. **Play together while looping:**
   - set a loop over a few bars and turn repeat on, then Play together from the panel. Every computer loops the same bars;
   - turn repeat off and press Play together again: repeat goes off everywhere.
9. **"Transport: Play (skip time selection)" (not carried; check what happens):**
   - with a time selection, run it on the desktop while the laptop follows side by side: the laptop jumps over the selection about when the
     desktop does (a re-cue);
   - in a band Play together, the laptop plays through it. Tell me if that should be carried.
10. **Tempo map:**
    - add a tempo marker under an audio item in time timebase: audio stays where it is on both;
    - set a MIDI track to beats timebase and change the first tempo: its items move the same on both, and nothing comes back as
      "(yours, not sent)".
11. **Track template:** save a shared track as a template and insert it. The laptop gets a new track and the original is untouched.
12. **Item to another track:** drag an item straight down to another track (same position), then drag one to another track and along it. On
    the laptop each moved; it wasn't deleted and re-made as a new item.
13. **Pooled MIDI:** Ctrl+drag a MIDI item to make a pooled copy, edit a note in it. Both copies change on the laptop, and closing the
    project tab doesn't crash (the copies arrive unpooled).
14. **Empty items:** insert an empty item (Insert > Empty item), then give one notes (item notes). Both arrive.
15. **Grouping:** group two items (Ctrl+G is glue; use Item grouping > Group items) and drag one. Both move on the laptop, and the laptop's
    own groups are unchanged.
16. **Late joiner:**
    - close the project on the Mac, or have it offline, during steps 1-15, then open it;
    - it catches up to the same project with the same track order;
    - its log shows no "came out different".
17. **Hold after a colour try:**
    - in Colours, Try a scheme, then kill REAPER (Task Manager) before Keep or Put back, and start it again. Hold sync is off, the log says a
      colour look was being tried, and edits go out;
    - repeat after saving mid-try (Ctrl+S during the try);
    - with Hold my changes on, open Settings > Health: a yellow row says Hold is on and how to switch it off;
    - **switch Hold off on the laptop's Cross Test now** (it still has the old value).
18. **Undo of a region copy (fix G):** "Time selection: Copy contents" of a region with its items, wait for it on the others, make any edit
    on the laptop, then one StudioSync undo on the desktop. The copied region is gone on all three with the items, and redo brings both back.
19. **Tempo changes (fix H):** on the desktop, `SetTempoTimeSigMarker(proj, -1, 8.0, -1, -1, 100, 0, 0, false)`, then the first tempo to
    120, then both back. After each, the laptop and LinuxBox have the desktop's item positions and lengths and envelope points, and stay
    so. Then undo one of them with StudioSync's undo: the map and the items go back together everywhere.
20. **Reopened behind (fix I):** with a region made since the desktop's last save, restart REAPER on the desktop (it reopens the older
    file). The region is there after Live sync's first passes, the log says the project was behind, and no "sent the markers" line
    follows. The laptop keeps the region.

## Untested / limits

- Everything here ran against the stand-in REAPER. What's assumed about REAPER, and must be checked by the list above:
  - P_EXT copies with pasted, duplicated, split and template items;
  - `SetProjectMarkerByIndex2` changes a marker's number, and REAPER allows two markers with one number for a moment while they're
    renumbered;
  - `EnumRegionRenderMatrix` and `SetRegionRenderMatrix` take the region's number;
  - `ReorderSelectedTracks`' index.
- Track template inserts, glue and recordings make new audio files. The fixture says every file exists, so the media copy path is not
  exercised.
- Plug-ins, sends and automation items aren't in the fixture (it has no plug-ins through the API). The other rt tests and `tests/reaper/` cover
  those.
- Act grouping: two separate edits made within one look (about 0.1-2 s apart) are now one Undo step. Before, two edits of the same kind on one
  track within one second already were. An act spread over several looks (a plug-in chain that settles 0.3 s after the items) is still two.
  So is a script's edit to unselected items in the middle of two tracks: the quick look reads one track now and the other within
  `QUICK_ALL_SECS` (rt-look's hints), so they go as two acts. A dragged group is selected, so it's one.

## Review-later (security)

- `act` is a string from a bandmate's event, used only to compare with other events' `act`. It's never a path or code. Size limits on events
  are unchanged.
- The marker `num` and `render` fields come from a bandmate:
  - the number goes through `math.tointeger`;
  - the render row is matched against tracks already here by their id, and nothing is created from it. The row is not length-capped beyond
    the event's own size limit (review later: cap at the track count).
- `loop` on a start cue sets the loop range and repeat only; both numbers are checked. A bandmate could already start your transport with
  Play together.
- The `colour try` ExtState is local; nothing received can set it.
