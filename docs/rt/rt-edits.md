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

Limit, fixed since (fix R): when a newer map did land, it replaced the whole timeline, so a marker you added in those first seconds was
gone and the log didn't say so.

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
- Both are fixed in the next round: fixes L and M below.

**J. Redo after undoing "Copy contents" lost half a lane track's items** (`lib/mirror.lua`, `mirror.sits_there`). Found in REAPER on
0.59.49.74.

Cause, as the checker guessed, reproduced in the stand-in first:
- on a track in lanes, REAPER's "Time selection: Copy contents" leaves the items it already had (their GUIDs, so their ids) at the copy's
  place, and makes new items, the same in every way, where they were;
- Undo takes the new ones away and moves the old ones back. Redo brings the new ones back and moves the old ones to the copy's place;
- bringing a new item back, `mirror.revert` asks `mirror.sits_there`: "is the same thing already on that lane under another id?" (that
  check stops a comp piece coming back twice). The old item, its twin, was still there, because the same Redo hadn't moved it yet;
- which items were lost depended on the order the plan was walked in, which is why the two runs lost different lanes. Every computer applied
  the same events, so all agreed and nothing flagged it.

Fix: `sits_there` is given the plan, and an item the plan is about to move off that place, or remove, doesn't count.

Test: a new matrix case makes that edit on the lanes track. After Undo, each bring-back is asked both ways: without the plan the twin counts
(the old answer), with it it doesn't. Every case now also checks, after Redo, that every object is as the edit left it; before, only the
laptop being equal to the desktop was checked, and they were equal.

**K. What REAPER moves when a tempo map lands is not that computer's edit** (`lib/mirror.lua`, `lib/sync.lua`). Found in REAPER on
0.59.49.74.

Cause: with fix H a receiver takes the map first. If a look then runs before the sender's items and automation arrive, the receiver sees
its own REAPER's moves as changes:
- where it may edit the object, it sent its own copy, which then met the sender's ("...as you did, at the same time: both changes are
  kept"). For automation it also held the sender's back until its own had gone;
- where it may not, it went through the refusal path, which asks the claimer ("LinuxBox wants to edit XT Rec A: Release or Keep").

First fix (0ae5fbf, replaced): a flag for the first whole look after a map landed, in which an item whose only difference from the
sender's event was its timing was taken in. Rechecked on 0.59.49.75 it held on the laptop but not on LinuxBox, which still asked ("LinuxBox
wants to edit XT Rec A: Release or Keep") and put eight "edits" back at each tempo step. Two reasons:
- LinuxBox's REAPER writes an item's text a little differently from the desktop's, so "the same as the sender's event but for timing" was
  never true there;
- the flag lasted one look, and the items trickled in over several.

Fix now (`mirror.map_landing`, called by `sync.apply`, `sync.timeline_heal` and the timeline's first look, around `band.apply_tempo`): every
item and automation is read just before the map is put in place and again just after. One that was as its record says before, and differs
only in its timing after, has its record moved with it there and then. So no look ever sees it as changed, however many looks run and
however late the sender's own versions arrive (they land over it):
- nothing is sent, nobody is asked, nothing is put back;
- the compare is between this computer's own two readings, so how its REAPER writes an item doesn't matter;
- a change of your own that hadn't gone out yet is left alone (its record didn't match before), so it still goes.
Cost: two full reads of the project for each tempo map that lands.

Test ("Edits tempo" block): a fourth computer whose REAPER writes items another way gets the map alone. It may edit nothing, so any "edit"
would be refused. Looks run after the map alone, again, with half the items there and with all of them: nothing sent, nothing refused or
put back at any of them, and it ends with every item and point where the desktop has it.

**L. The marker-colour echo** (`lib/band.lua`, `band.sws_colours`). Measured in REAPER (a marker added on the desktop and put back).

Cause: SWS, not StudioSync's colours. Both computers have SWS's auto marker colouring on (`sws-autocoloricon.ini`: `AutoColorMarkerEnable=1`,
one rule, "any marker" gets a colour). A marker made or landed with the default colour is coloured by that computer's SWS a moment later;
each computer read that as its own change to the timeline and sent it. The desktop's SWS did it to its own marker too: the run showed three
timeline changes for one marker.

Fix: SWS's auto marker colouring and auto region colouring are switched off while a studio song is in front, and back on for other
projects, exactly as its auto track colouring has been since 2026-11-01. Only what StudioSync switched off is switched back. The command
names (`_S&MAUTOCOLOR_MKR_ENABLE`, `_S&MAUTOCOLOR_RGN_ENABLE`) were checked in REAPER.

Not covered: anything else that recolours a marker after it lands (another script) would echo the same way.

Test ("Edits sws" block): the stand-in's SWS colours a default-colour marker as SWS did, and the laptop sends it back (the echo). With the
switch, a new marker goes out once, nothing comes back over three rounds of passes, and it keeps the default colour on both.

**M. The studio's timeline is one file per computer** (`lib/sync.lua`). James, 2026-11-20: no file that several computers write.

- Each computer keeps the last timeline it sent in `rooms/<room>/timeline/<user>.json` (`sync.session_timeline`). The newest stamp among them
  is the studio's (`sync.studio_timeline`), which is what a project opening behind takes and what the stamp check reads.
- A file counts only if it's named for the person it says it's from. Where the studio pins computers, that person's own computer must
  have written it (`trust.own_file_ok`, the check session.json's sharer already gets). One not known yet is left out.
- session.json's timeline is still read: when it's the newest (a computer on an older build wrote it), or the only one.
- session.json's timeline is still written, in the main room only, while anyone here is on a build that only reads that. A computer on this
  build says so by having a file in `timeline/` from its first look (`sync.timeline_reads`), so "everyone here has a file" is the rule
  (`sync.timeline_old_readers`). Nobody's version number is compared.
- A side room's timeline used to be written into session.json, where it was read as the main room's. It now goes to the side room's own
  files only, and a side room gets the "opened behind" look too.

Your rule, checked: it holds. One thing to know: a computer that's away while everyone else is on the new build comes back to a
session.json whose timeline is older. That's safe on an older build too, because it takes session.json's map only when its stamp is newer
than its own, and the room's events bring it the newest map either way.

Not done here:
- session.json as it stands was last written by a computer that isn't its sharer's, so the hub's "set aside" stays until the sharer's
  computer writes it again. Nothing writes it now once everyone is on this build.
- `StudioSync - Open session.lua` still starts a new project from session.json's tempo and markers. Live sync's first look then takes the
  newest from the files.

Test ("Edits files" block): each computer writes only its own file, the newest stamp wins, session.json is untouched until an older build is
here and written again when one is, session.json's newer timeline is still read, a side room keeps to its own files, and a file named for
someone else is left out.

**N. Old starts and stops were replayed into the log** (`lib/sync.lua`, `sync.receive`).

"James-Laptop: record together at 1.84..." and "stop together" after each desktop restart come from `sync.receive`, which main and realtime
share: so it's both, not main's only. The desktop's project file is from 11-19, so every cue since is news to it at each restart. Nothing
played: Live sync drops a cue whose moment has passed. Now a start or stop older than `sync.CUE_OLD` (120 s) is marked done without being
applied or logged. The test's last block checks an old one and a fresh one.

**O. Redo was short when the Undo's writes crossed a clock second** (`lib/mirror.lua`, `mirror.plan_undo_moment`; `lib/undo.lua`). Found in
REAPER on 0.59.49.75: an Undo wrote 3 changes at 02:00:13 and 18 at 02:00:14; Redo said "the act has 18 changes" and two items and three
automation points stayed missing on every computer. Undo then stepped to an older change.

Cause: the changes one Undo (or Redo) writes were found again by `undoes`/`redoes` and *the same second*. Fix: every change of one press
carries one step id (`act`, made in `undo.step`), and the plan groups by `undoes`/`redoes` and that id, whatever second each was written in.
An older build's changes have no id and group by the second as before.

Undo stepping to an older change after the short Redo was the same fault: the Redo's own changes were split over two seconds too, so the next
Undo found only part of them. It goes with the fix.

Test: the matrix's Undo and Redo now write their third change in the next second (`press`), for every case, and each case runs a second
Undo and Redo with every object and the timeline checked after each. Without the fix the first case fails at Redo.

**P. Undo past an auto-claim made since** (`lib/mirror.lua`, `mirror.revert`; `lib/sync.lua`, `sync.receive`; `lib/undo.lua`). Found in
REAPER on 0.59.49.75: "19 brought back (2 not yours to change)", because the laptop held an auto-claim on XT Drums A.

Decision: an Undo or Redo of your own change goes past a bandmate's **auto-claim**, as the original edit did, when the newest version of
the thing is still yours (so nothing of theirs is in what's taken back). On the sender `mirror.revert` allows it; on every receiver
`sync.receive` lets it land past its own auto-claim when the version it's built on is the sender's. A **lasting claim** (one somebody made
by hand) still refuses, and the Undo says "not yours to change" as before. If the claimer has changed the thing since, the newest version
isn't yours and the Undo is held back there as before.

Test ("Edits claim" block): the laptop auto-claims Bass after the desktop's item went out. Undo goes through on the desktop and lands at
once on the laptop. With a lasting claim an Undo of a mute is refused.

**Q. A track's colour flipped at each restart, and each flip auto-claimed the track** (`lib/mirror.lua`). Found in REAPER on 0.59.49.75
(XT Drums A).

Who writes the colour: StudioSync's own colour hold (`mirror.hold_colours`), not SWS (its auto track colouring reads off on both
computers). The hold was made for SWS's rules, which recolour every track when one goes in or out: it snapshots every track's colour just
before a track is inserted or deleted and puts the snapshot back at each look for 5 s. A computer reopened from an old file catches up:
- a track goes (the snapshot is taken, old colours and all);
- another track's newer colour lands in the same pass;
- the next look puts the old colour back. That reads as this computer's own change ("something with no undo point changed XT Drums A
  right after a bandmate's change landed"), goes out, and auto-claims the track.
On the desktop the snapshot also held a stale "who's working" paint (the old file has XT Drums A at 33538636 with the band's colour, 16576,
kept beside it). When the paint came off, the hold put the paint's number back as if it were the track's colour, and that went out.
Both builds do it: main's Live sync on the desktop sent 33538636 at each restart (its events carry no `act`), the realtime build on the
laptop sent 16576 back.

Those two numbers are not the same colour: 33538636 has REAPER's "custom colour set" flag (0x1000000), 16576 doesn't, so it means "no
colour", whatever its other bits. REAPER keeps whatever number is set (measured: 33538636, 16576, 0 and flag|16576 all read back as set).

Fix:
- the hold only runs where SWS's auto track colouring is on on this computer. With it off, which is how a studio song runs
  (`band.sws_colours`), nothing recolours tracks by itself and there's nothing to hold;
- where it does run, a colour StudioSync itself sets replaces that track's entry in the snapshot (`mirror.held_colour`);
- "no colour" compares equal however it's stored (`mirror.colour_key`): a colour without the flag hashes as 0, and landing "none" over
  "none" writes nothing. A track shared by an older build, whose hash was made from the stored number, is taken as the same track by the
  existing alias check (`mirror.same_line`), so nothing goes out again after the update. `mirror.HV` stays 8.

Test (last block but one): a track out and a colour change in one pass on the laptop: the colour stays, nothing is sent back (without the
fix: "Bee sent back what landed"). 16576 and 0 read the same, a track an older build shared doesn't go out again, and "none" over "none"
writes nothing. With SWS's colouring on, the hold still puts back what SWS recoloured but not over a colour StudioSync set.

Left: main's build has the same hold. Until the desktop runs only a build with this fix, a restart there can still send the stale paint
once; this build then no longer sends it back, so it stops after one change instead of bouncing.

**R. A marker, region or tempo change of yours that hadn't gone out was lost when a newer timeline landed** (`lib/sync.lua`). Backlog 1,
fourth round.

The timeline travels whole. A change of yours waits while a project catches up after opening (fix I), and a bandmate's can land between
two of your looks at any time. What landed replaced yours, and nothing said so.

Rule now: **what you changed since this project's last look is made again on top of what landed**, as if you had made it a moment later.
The next look sends it. If the timeline isn't yours to change (Driver only), that look puts it back and says so, as for any such change.
- `sync.timeline_unsent`, before the newer timeline goes in: the difference between the project and its last look's note.
  - Markers and regions added and removed, told apart by kind, place, end and name. A moved or renamed one is one of each.
  - The tempo map, if it differs. Then markers are told apart by kind, number and name, because REAPER moved them all.
- `sync.timeline_carry`, after the newer tempo map is in: the markers you added are read again where REAPER moved them for that map.
- `sync.timeline_redo`, after the newer markers are in and noted as seen: yours removed again, yours added again (a number the newer
  timeline gave to another marker is left to REAPER), your tempo map put back on if you had changed it. The log says what was kept:
  "<who>'s newer tempo map and markers landed before your own change had gone out. Kept on top of theirs: ...".
- Both changed the tempo map: yours is kept and theirs is replaced, and the log says "your tempo map (theirs is replaced)". This is the
  same outcome as two people changing the map one after the other.
- The same in the first look of a project opened behind the studio's timeline (`sync.watch_timeline`).
- What can't be told: a note written by an older version (another `TIMELINE_FORMAT`) whose tempo map reads differently. Then the newer
  timeline replaces the project's as before, and the log says so and that REAPER's Undo brings yours back. Markers alone are still merged
  from an older note. Project settings (title, notes, grid) aren't covered: REAPER reads some of them differently as a file opens.

Tests: the "Edits reopen" block (a marker added as the project opens survives both paths and reaches the laptop) and the new "Edits
unsent" block (a marker under a bandmate's region; a move and a removal, not doubled; a marker kept at its beat under a bandmate's tempo
change; your tempo map kept over a bandmate's marker; an older note that can't be compared).

**S. A claimed track renamed by a computer whose StudioSync doesn't ask** (`lib/sync.lua` `sync.receive`, `lib/mirror.lua`
`mirror.set_back`). Backlog 1.

Only the sender judged a rename; receivers took it by its new name, which nobody has claimed. So a computer on a build from before the
rename fix (0.59.49.74) could rename a bandmate's claimed track for everyone. Now:
- **Every receiver judges it by the name the track has there**, which is the name the claim is on (`refused` in `sync.receive`). A rename
  its sender may not make waits like any refused change: up to a minute, for a claim or handover that may still be on its way.
- **The claimer's computer answers instead of applying it** (`set_back`): the rename is noted as the band's newest version without being
  put in place, so the next look sends the track as it is there, built on the rename. The old name comes back on every computer, the
  renamer's too. The others, still holding the rename for their minute, never show it. Only a computer whose own person may change the
  track under its present name answers, so there is one answer, from the computer whose claims are its own and current.
- **Bound:** only a rename made in the last `sync.RENAME_BACK` (600 s). An older one (the claimer was away) lands after its minute, and
  the claim follows the track (`sync.follow_claims`) as before: a name everyone has had for a while isn't taken back.
- **What the older sender sees:** its rename shows on its own computer for a few seconds, then the old name is back, with a line in its
  log from the claimer's change: "<claimer> has claimed <track>: <renamer>'s rename to <new name> is put back (their StudioSync is older
  and didn't ask first)". The claimer's log says the same from its side, and that they can rename it themselves.

Test ("Edits rename" block): a third computer holds the rename; the claimer's keeps the name and answers; the renamer's goes back; the
claimer's own rename lands at once; a rename older than the bound lands after its minute.

**T. Track order** (`lib/mirror.lua`, one call in `StudioSync - Live sync.lua`). Backlog 1, rt-undo's limits, and the REAPER check on
0.59.49.76.

What the check showed (events in `Cross Test/rooms/main/events`): at the desktop's restart, main's Live sync sent XT Drums A at rev 18
with its older file's place, "sits under XT Rec A". XT Rec A's own newest change (23:13:51Z) says "sits under XT Drums A": a ring.
- LinuxBox, running, applied the one change and moved XT Drums A under XT Rec A.
- The laptop applied it too (20:51:06 its time), restarted, reopened its older file and caught up. A catch-up applies each track's newest
  change: XT Drums A went under XT Rec A, then XT Rec A went under XT Drums A. It ended in the studio's order.
- Nothing put the order right during a session: `mirror.keep_order` ran once as a project opened, and did nothing then if changes still
  waited.

1. **The order heals during the session** (`mirror.order_heal`, asked by Live sync every pass). Tracks go onto the studio's newest order
   list (`order/<person>.json`, as when opening), so whichever computer is off moves. The rule, so tracks never move under someone at
   work:
   - only with this tab in front, the transport stopped (not playing, not recording), and the project's first catch-up done;
   - only 10 s (`ORDER_IDLE`) after your last edit, and never while a mouse button is down;
   - the first time after opening: as soon as nothing of the band's waits to land. No waiting for anyone to differ;
   - after that: only when a caught-up bandmate has had another track order for 30 s (the same input as Health's red row), not within
     120 s (`ORDER_WAIT`) of a bandmate's move landing here (the mover's order list comes through Syncthing, seconds behind the move),
     and at most every 30 s.
   The log says "N track(s) put in the studio's order". The look after sends nothing: it isn't your move.
2. **Undo and Restore leave a track where it sits unless a move is taken back.** A track's older version names the track it sat under
   on the day it was made. Undo of a mute moved the track above one added since, for everyone. Now a change sent with a move of yours
   says where the track sat before (`moved`, set in `W.send`), and `mirror.revert` asks `mirror.moved_since`: if a move is among what's
   taken back, the track goes back under that track; if none is, it stays. Redo moves it again (the undo's change carries `moved` too).
   Moves made before this build carry no `moved`, so undoing one of those no longer moves the track back.
3. **Heal doesn't make an old merge** (`mirror.heal`, `MERGE_NEWS_SECS` = 1 hour). Where heal settles on a merge of two changes, this
   computer holds the newer of them, and the merge's newest change is over an hour old, heal leaves it. That is the case of two changes
   from before tracks merged, or the same change sent by two computers: every computer took the newer one then. A computer that holds
   neither the merge nor the newer change is behind and still gets it.

Tests ("Edits order" block): Undo of a mute with a track added above since; a move, its Undo and Redo; the check's scenario (a change
carrying an older file's place, one computer moving, one not), with each of the rule's conditions refusing in turn and then the heal on
both computers that were off; a file reopened with another order; a merge an hour old on the computer that holds the newer change, and
on one that holds neither.

**U. A note or automation point moved by both people was doubled** (`lib/mirror.lua` `moved_twice`, `merge_midi`, `merge_env`). Backlog 1,
rt-merge's limits.

A note has no id, so a move reads as one taken away and one added, and each side's copy was kept.

Rule now: **the same note or point is one thing; the later change stands, whole.** Where the earlier side moved it and the later side
changed it too (moved it, changed it in place, or removed it), the later side's stands and the earlier side's moved copy is left out. It
counts as a clash, so the earlier side is told and has Use mine, as for any clash. In Claims mode the same-piece ask already applies before
it gets this far (`mirror.clashes` goes by pieces: the note taken away is the claimer's piece).
- Which added note is the moved one is only told where it's plain: among notes of one channel, length and velocity (a move keeps those),
  the side took away exactly as many as it added. They pair in order of time, then pitch. That covers one note moved, a selection dragged
  and everything shifted. A pitch change is a move.
- Points: the same, among one envelope's points, paired in order of time.
- Other counts (some deleted and some new of one kind): not paired, both copies stay as before. So does a note moved and resized at once.
  Left like that on purpose: leaving out a note that was really new would lose work.

Tests (last block): both moved one note; a pitch change, a velocity change and a removal against a move; different notes moved (both
stand, no clash); the same for points. The 4,000-note merge in rt-merge's test still runs in well under a second.

**V. Given claims: the link's copy, and the signature file** (`lib/sync.lua` `sync.follow_claims`). Asked for by rt-linkmove (its hooks 1
and 2).
- `follow_claims` skips a given claim while what's read is the direct link's copy (`band.overlay_of`). Folded from that copy, it was
  folded again on every pass, because there is no file to remove. `sync.authority` counts the link's copy meanwhile, so the track is the
  person's at once. The folder's file is folded in, once, when Syncthing brings it. `sync.GIVEN_WAITS = true` tells `lib/signed.lua` that
  this holds, so it now takes a given claim's link copy on its own person's computer.
- Folding removes the given file's `.sig` too. Every given claim had left one in `claims/`.
Test: in `tests/test_0_60_rt_linkmove.lua`, beside rt-linkmove's own (the link's copy is never folded and still counts; the folder's
file is folded once, with one "gave you" line; the file and its `.sig` are gone; nothing on the next pass).

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
21. **Redo of a region copy (fix J):** the F3 steps again (Copy contents of Verse to 24.0 s, a volume change on the laptop, one StudioSync
    undo, one StudioSync redo). After the redo all 8 of XT Rec A's items are at 3.69 s and 8 at 24.92 s on all three, and the log's count
    is the undo's (21). Then undo again to put it back.
22. **Tempo change, no asks or echoes (fix K):** the tempo marker at 8.0 s, then the first tempo to 120, then both back. On the desktop no
    "wants to edit ... Release or Keep" appears and no "...as you did, at the same time"; on the laptop and LinuxBox no "change(s) went to
    the others" follows the map. All three still match after each step.
23. **Marker colour (fix L):** add a marker on the desktop with the default colour. One "sent the markers" line on the desktop, none on the
    laptop; the marker keeps colour 0 on both. In REAPER's Actions list, "SWS/S&M: Toggle auto marker coloring enable" and "...region..."
    read off while Cross Test is in front, and on again with another project in front.
24. **Timeline files (fix M):** after any marker change, `Cross Test/rooms/main/timeline/` holds one file per computer and no new
    `session.sync-conflict` file appears. With all three on this build, session.json's modified time doesn't move on a marker change. With
    one computer on the older build and here, it does.
25. **Old cues (fix N):** restart REAPER on the desktop: no "record together" or "stop together" lines in the log from the catch-up.
26. **Undo and Redo across a second (fix O):** the F3 steps again (Copy contents of Verse to 24.0 s, wait for it on the others, one
    StudioSync undo, one redo, then undo, redo, undo). The undo's events may be spread over two seconds (look at their `time`). Each redo's
    "the act has N changes" is the undo's whole count (21 in the last runs), and after each step all three computers hold the same: 8 items
    at 3.69 s only after an undo, 8 there and 8 at 24.92 s after a redo, with XT Drums A's and XT Rec A's automation points to match. The
    second undo takes the same act back, not an older change.
27. **Undo past an auto-claim (fix P):** make the copy on the desktop, then on the laptop change something small on XT Drums A so it
    auto-claims the track (not the copied items). Undo on the desktop: "N brought back" with no "not yours to change", and the laptop takes
    it without asking. Then claim XT Drums A by hand on the laptop and try the same: the desktop's Undo says "not yours to change" for
    that track's objects.
28. **Tempo marker, LinuxBox quiet (fix K, redone):** the tempo marker at 8.0 s (`SetTempoTimeSigMarker(proj, -1, 8.0, -1, -1, 100, 0, 0,
    false)`), the first tempo to 120, then both back, with the laptop or LinuxBox holding a claim or auto-claim on XT Rec A. On the desktop
    no "wants to edit ... Release or Keep"; on LinuxBox no "Not sent: ... didn't answer" and no "Your edit is put back"; no "change(s) went
    to the others" after the map on the laptop or LinuxBox. All three match after each step.
29. **Colour at restart (fix Q):** restart REAPER on the desktop, then on the laptop. No event for XT Drums A appears in
    `Cross Test/rooms/main/events/` from either restart, no "something with no undo point changed XT Drums A" line, and nobody holds an
    auto-claim on it afterwards. If the desktop still runs main's Live sync first, one colour event from the desktop is possible; the
    laptop must not answer it with one of its own.

30. **A marker added as a project opens (fix R):** add a region on the desktop and wait for it on the others. Restart REAPER on the
    laptop. As soon as Cross Test shows, before the log's "loaded: the studio's N change(s)" line, run
    `reaper.AddProjectMarker2(proj, false, 30.0, 0, "M30", -1, 0)` there. The laptop's log says "...newer tempo map and markers landed
    before your own change had gone out. Kept on top of theirs: 1 marker(s) or region(s) you added", then "sent the markers to the studio".
    All three have the region and M30. Delete both afterwards.
31. **A rename from a StudioSync that doesn't ask (fix S):** needs a sender that doesn't judge the rename. Either a computer on
    0.59.49.70 to .73, or a script on LinuxBox that posts the change as that build did: read XT Rec A's record (`mirror.known`), its
    newest event's state, set `name` (and `state.name`) to "XT Rec A9", post it with `sync.post` at `rev + 1` on `base_ev`, rename the
    track there and `mirror.remember` it. With the desktop holding an auto-claim on XT Rec A:
    - the desktop's track keeps its name; its log says "LinuxBox renamed XT Rec A, which you've claimed, to XT Rec A9 ... the name is put
      back for everyone";
    - the laptop never shows XT Rec A9;
    - LinuxBox's track is XT Rec A again within a few seconds, with "James has claimed XT Rec A: LinuxBox's rename to XT Rec A9 is put
      back ..." in its log.
32. **Track order (fix T):**
    - Restart REAPER on the desktop. If main's Live sync sends its one stale change (XT Drums A under XT Rec A), LinuxBox and the laptop
      move the track. With Cross Test in front, stopped and nobody editing, each logs "1 track(s) put in the studio's order" within about
      three minutes (120 s after the move landed, 30 s apart, 10 s idle) and shows Keys C, Drums A, Rec A. The desktop does the same when
      the realtime build's Live sync is the one running there; under main's it stays on its file's order and Health stays red for it.
    - Without main's help: put another project tab in front on the laptop, move a track on the desktop, bring Cross Test to the front
      on the laptop and leave it alone. Within about 40 s it logs the line and has the desktop's order. While playing, or within 10 s of
      an edit, it must not move.
    - Add a track between two others, mute the lower one, one StudioSync undo: the track order is unchanged on all three. Move a
      track, one StudioSync undo: it's back where it sat on all three. Redo: moved again.
33. **A note moved by both (fix U):** Who controls set to Open (in Claims mode the second mover is asked instead). Move the same note
    of XT Drums A's MIDI item on the laptop and on LinuxBox to two different places within the same half second (a script on each,
    started together). One note on all three, where the later mover put it; the earlier mover's log has the clash line with Use mine. The
    same with one point of XT Rec A's volume envelope.
34. **A given claim (fix V):** on the desktop, Who controls > a member > Give them control of > a track. On that member's computer the
    track is theirs to edit within a second; "<admin> gave you <track>" is logged once, when Syncthing's file arrives; afterwards
    `Cross Test/rooms/main/claims/` holds no `given-*.json` and no `given-*.json.sig`.

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
- Undo past an auto-claim (fix P): `undoes`, `redoes` and `base_ev` are the sender's word. A changed client could mark an ordinary edit as
  an undo to get past a bandmate's auto-claim on a thing whose newest version is its own. It gets no further than that: signed messages,
  room permissions and lasting claims are checked as before, and an auto-claim already lets edits that merge through. Review later:
  receivers could check that the state brought back equals an earlier version of that object.
- The colour hold's ExtState is local. `mirror.colour_key` only reads a number.
- Fix R reads and writes only this project's own timeline. The log line names the sender of the timeline that landed.
- Fix S: a receiver now also judges a track change by the name the track has there, with the same `can` as before, so nothing is
  allowed that wasn't. The answer's `note` is text built on the claimer's computer from track and person names; every computer logs a
  change's `note` for an hour, as before. A legitimate rename whose claim file is late waits up to a minute where it landed at once.
- Fix T: `moved` is a string from a bandmate's event. It's only read on the computer that undoes or restores, as the id of a track to
  sit under; `mirror.apply` moves only under a track that exists. The order heal moves tracks only onto the studio's order list, whose
  files are signed since rt-linkmove.
- Fix V: `follow_claims` still folds only a file that passes `given_ok` (a giver who may, written by their computer). The link's copy
  is never folded.

## Round 5 (rt-edits2, finishing rt-edits' cut-off round)

Seven items from backlog 1, each with a fixture test in `tests/test_0_60_rt_edits.lua` that fails without its fix (each fix was switched
off in turn and its test failed). rt-edits had items 1 to 3 written, uncommitted, when it stopped; they were kept as they were, checked
and finished (items 2's stuck case and Restore, below). Files: `lib/sync.lua`, `lib/undo.lua`, `lib/mirror.lua`,
`tests/fixtures/editreaper.lua`, the test, and one line in `StudioSync - Live sync.lua` (rt-edits' own: `edited_at = changed_at` in
P.look's `mirror.watch` call).

**W. A timeline edit made right after updating** (`sync.watch_timeline`). A last-look note in an older `TIMELINE_FORMAT` read as a first
look, so a marker or tempo change made between the old version's last look and the new one's first was taken in and never sent. Now the
older note is compared first (`sync.timeline_unsent`: the tempo map, and each marker's kind, place, end and name, which both formats hold).
If they differ, the note stays and the change goes out as any change does. If nothing differs, it's a first look, as before. A tempo map
that reads differently counts as a change (its fields haven't changed since format 4). Test: "Edits update" (nothing changed: no event;
a marker: one event, reaches the desktop; a tempo change: likewise). This only matters on an update that bumps `TIMELINE_FORMAT`.

**X. Undo of an act that is only a timeline change** (`mirror.last_mine`, `mirror.last_undo`, `lib/undo.lua`). A marker added and nothing
else was stepped over, and Undo took back the edit before it.
- Rule: a tempo map or marker change of yours is a change for Undo when it's the whole act. One sent with an act's items still goes back
  with them (fix G, `sync.act_timeline`); it's passed over once its items are undone. One sent in a later pass than some of its act's items
  is taken from those items, so the act goes back as one step.
- Undo of one: `sync.undo_timeline` takes back what it added and brings back what it took away. A bandmate's markers since stay. Redo
  puts it on again.
- Nothing left to take back (a bandmate removed the marker, or changed the map since): every press stopped there before. Now Undo says
  "The tempo map or markers have changed since: nothing was taken back. Undo again goes to your change before it." The change is noted in
  the project (`undo passed`, the last 20) and passed over from then on, on this computer.
- A Restore's timeline event now carries `restored` (`sync.restore_timeline`) and isn't a change Undo steps back, as a restored object
  isn't.
- Test: "Edits marker undo" (marker alone: undo, redo, undo, then the edit before it; a marker and an item as one act, both ways; a marker
  the laptop removed: one press says so, the next undoes the edit before; Undo after a Restore).

**Y. One act, one step, across looks** (`mirror.watch`, `mirror.last_act`). A script's edit to unselected items on two tracks is found
one track now and the other within 10 s (the quick look's hints), and a plug-in chain goes once it holds still: each was its own act.
- Rule: what a look finds while you haven't edited since the last look that sent something is the rest of that look's act, for up to
  `ACT_KEEP` (70 s, past the next full look). "Edited" is Live sync's change count without its own writes (`opts.edited_at`). Without it
  (the panel, Undo), nothing changes.
- An Undo, Redo or Restore (`mirror.revert`) ends it: what the next look finds isn't the rest of the act before.
- Test: "Edits acts" (two tracks found 4 s apart, no edit between: one act, one Undo; an edit between: two acts; past ACT_KEEP: two).

**Z. Heal's changes made undo points on top of the person's list** (`mirror.keep_order`, `mirror.heal`).
- What REAPER allows: every undo point is a snapshot of the project. There is no way to change the project without its state landing in
  some point. With no block, the heal's changes go into the person's next point, and REAPER's Undo of that edit undoes the heal too.
  API calls that make their own point (`ReorderSelectedTracks` makes "Change track order", one per track moved) do so unless they run inside
  an undo block.
- Chosen: one point per heal, named "StudioSync: the studio's track order" or "StudioSync: changes that hadn't arrived here". Ctrl+Z on a
  "StudioSync" point is StudioSync's Undo of your own last change (`undo.native`), so the heal is skipped harmlessly, as a bandmate's
  landed change already is. Before, "Change track order" on top read as your own edit: Ctrl+Z went to REAPER's Undo, which undid the heal,
  and the next look sent that as your move. `mirror.heal` opens its block only once it changes something, and always closes it.
- The fixture now keeps REAPER's undo points when a test asks (`F.undos`): a block is one point under its name, and a reorder outside one
  is "Change track order". Test: "Edits order" (the order heal: one StudioSync point, no "Change track order"; a catch-up: one; a heal
  that changes nothing: none).
- Left: REAPER's own Edit > Undo (not the bound Ctrl+Z) still undoes a heal's point, as it does a landed change.

**AA. Claims: deleting several claimed things at once asks** (`W.gone`). A deletion of someone else's claimed item or track went
straight to the older suggestion (`propose`): put back at once, nobody asked.
- Now it asks first, through the same `opts.ask` as an edit (`claimask.hold`). While the ask waits, the deletion is held: still gone
  here, nothing sent, the band's changes to it waiting (`unsent`). A held track's plug-ins, automation and sends wait with it.
- Release: the deletion goes out on a later look. Keep, or no answer: put back with the claimer's words, the track whole.
- One ask per claim, however many of its things went (claimask keys asks by claim). Where no ask applies (Driver only, Admins only, an
  older StudioSync), the suggestion path stays as it was.
- The dead `room_mode == "claims"` code in `W.refuse` (the bar's "Claim it") is gone; `sync.put_back` is no longer passed a claim.
- Test: "Edits ask" (two items and a track deleted at once: asked, held for two looks, no suggestion; Keep: all back, the log says why,
  the laptop unchanged; again, then Release: the deletions reach the laptop).

**AB. A note moved and resized at once by two people** (`moved_twice`, `merge_midi`). Closed.
- A note pairs with its moved copy by channel, length and velocity. A resize changes the length, so a moved-and-resized note never paired
  and stayed doubled.
- Now what that leaves unpaired is paired again by channel and velocity alone, on the same rule: the loser removed exactly as many of that
  kind as it added, in order of time, then pitch.
- Why that's as safe as the first pass: the risk is the same one the first pass already takes. A note deleted and another drawn in its
  place, of the same channel and velocity, reads as that note moved. Its copy is left out only where the winner changed the deleted note
  too, and the loser is told, with Use mine. A note whose velocity changed as well still isn't paired, and still doubles.
- Test: the last merge block (moved and resized against a move; both moved and resized; the other way round; a note taken away and another
  of another velocity drawn: both stand).

**AC. A member releasing a claim given to them** (`sync.set_claims`, `sync.authority`, `sync.follow_claims`).
- The panel's path (a chip's x: their claims less that one, through `set_claims`) works once the given claim is folded in. Two things
  undid it:
  - **Others still counted it.** A computer that still read the given file counted it. That's one Syncthing hadn't told of the removal
    yet, or one holding the direct link's copy for its minute (`signed.GIVEN_KEEP`). Now `set_claims` notes what you let go of, and when, in
    your claims file (`dropped`, lasting claims only, kept 7 days). `sync.authority` passes over a given claim for you dated before
    that. Claimed again, or given again later, it counts.
  - **The fold re-dated it.** Folding a given claim made it today's (the comment said "dated as given"; the code didn't). So a driver's
    release (`released/`) made between the gift and the fold was undone by the fold. Now a folded claim keeps the date it was given, and the
    fold leaves out what a `released/` stamp or your own `dropped` came after. The released stamp and the folded claim agree.
- Test: "Edits given" (folded with the given date; released from the panel; a computer still reading the given file doesn't count it; the
  file folded again doesn't bring it back; a new gift counts; a driver's release before the fold holds after it).
- Left: in the seconds between the link's copy and Syncthing's file on the member's own computer, the claim isn't in their own file. The
  chip's release then has nothing to remove, and the claim stays until they release it again after the fold. See question 1.

### Round 5 REAPER checks

Same setup as above (Cross Test, desktop, laptop, LinuxBox on this build).

35. **Undo of a marker alone (X):** on the desktop mute an item, then add a marker by itself. Wait for both on the others. One StudioSync
    Undo: the marker is gone on all three and the item stays muted. Redo: the marker is back. Undo again, then Undo once more: the item
    unmutes. Then add a marker, delete it on the laptop, and press Undo on the desktop. You see "...changed since: nothing was taken back.
    Undo again goes to your change before it". The next Undo takes back your edit before it.
36. **One act across looks (Y):** run a script on the desktop that, with nothing selected, mutes one item on XT Drums A and one on XT Rec A
    (`SetMediaItemInfo_Value(it, "B_MUTE", 1)` on both, then `UpdateArrange()`). Their two events in `rooms/main/events/` carry the same
    `act`, even when their times differ by seconds. One StudioSync Undo unmutes both on all three.
37. **Heal undo points (Z):** make the track order differ on the laptop (as step 32) and wait for "N track(s) put in the studio's order".
    REAPER's Edit menu reads "Undo StudioSync: the studio's track order", not "Change track order". Ctrl+Z then undoes your own last
    change through StudioSync, and the order stays. When a "caught up on N change(s)" line appears, the menu reads "Undo StudioSync: changes
    that hadn't arrived here".
38. **Asks on deletions (AA):** Claims mode. LinuxBox claims XT Rec A by hand. On the desktop select two of XT Rec A's items and delete
    them.
    - LinuxBox gets one "James wants to edit XT Rec A: Release / Keep".
    - On the desktop the items stay deleted and nothing goes out meanwhile.
    - Keep: the items are back on the desktop, and its log says LinuxBox kept it.
    - Delete again, Release: the items go on all three.
    - Repeat with the XT Rec A track itself: Keep brings it back with its automation.
39. **Moved and resized (AB):** as step 33, but one computer's script moves the note and changes its length at once. One note on all three,
    where the later one put it.
40. **A given claim released (AC):** on the desktop, give the laptop's person XT Keys C.
    - Once the laptop logs "James gave you XT Keys C", release it from the laptop's panel (the chip's x).
    - Within a second LinuxBox's Who controls no longer shows it as the laptop's. After a minute nothing has brought it back, on any
      computer.
    - Then stop Live sync on the laptop, give it XT Keys C again from the desktop, and as driver press "Release <laptop>'s claims".
    - Start Live sync on the laptop: XT Keys C isn't the laptop's anywhere.

Not checkable in REAPER yet: W, until an update bumps `TIMELINE_FORMAT` (then: stop Live sync before updating, add a marker, update, start
Live sync; the log says "sent the markers to the studio" and the others get it).

### Round 5 review-later (security)

- `dropped` is read from a person's own claims file or their live claim. It can only make that person's given claims count less. It's
  type-checked (string keys and times), compared, and never used as a path.
- `undo passed` is local project state.
- A held deletion keeps `unsent` set only while `claimask.hold` says the ask waits (`ASK_WAIT`). Keep, a timeout or Release ends it.

### Round 5 questions for James

1. A claim given to you, released from the panel in the few seconds before Syncthing's copy arrives (the direct link's copy only), isn't
   released: there's nothing in your own claims to remove. The options:
   - (a) leave it: release it again after the "gave you" line;
   - (b) a one-line change in the panel so its release also marks a given-only claim as let go;
   - (c) fold the link's copy at once (this changes rt-linkmove's agreed hook, and its test).
2. Moved-and-resized pairing (AB): a note you delete and another you draw of the same channel and velocity, while a bandmate changes the
   deleted note, is read as a move: your drawn note is left out, as a clash with Use mine. Keep it so, or keep doubling instead?
3. A heal's undo point (Z) is skipped by the bound Ctrl+Z, but REAPER's own Edit > Undo still undoes it, and the next look then sends that
   as yours. OK as it is?
