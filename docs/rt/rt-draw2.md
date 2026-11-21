# Drawing in the web UI, finished: Line, Box, Highlighter, Undo and Redo, share notes kept, the Mixer on History (rt-draw2, 2026-11-20)

`docs/rt/backlog.md` section 3: "Drawing: no Line, Box or Highlighter and no undo on the web; share notes aren't saved to the room's layer;
Mixer drawings aren't on the time lapse." All four are built, on `docs/rt/rt-draw.md`'s layer. **Tested offline only** (Lua tests, headless
Chromium against a two-computer stand-in with a stand-in screen); **not run in REAPER or between two real computers yet.**

## What it does
1. **Highlighter, Line, Box** beside Pen, Arrow, Circle, Text and Eraser, in the panel's own order, on the Project page, the Mixer page and
   the phone's Project view. The four swatches the panel has and the web lacked (yellow, lime, cyan, pink) are added. A shape drawn on
   either side is the same file, so it shows on the other.
2. **Undo** and **Redo** buttons while drawing (greyed when there's nothing to take). Undo takes back the last thing you did on that view:
   a drawing you made goes, one you erased comes back. Redo puts it back. Both are live for everyone, like any drawing or removal. Only
   ever your own drawings: an admin's Eraser on someone else's drawing isn't a step, and Undo never touches another person's. The Project
   page and the Mixer each have their own pile; the phone and the computer's pages share this computer's piles (Live sync keeps them).
   With nothing done from a page since Live sync started, Undo takes your newest drawing on that view, as the panel's Undo does.
3. **A screen share's notes are kept.** An Arrow, Circle or Text note drawn on a share (by a watcher, or by the sharer on the preview)
   that sits on one of the studio's tracks is also saved, the moment it's drawn, as its author's own drawing on the arrange view. It
   outlives the share and shows wherever drawings do (Project page, the panel, the phone, History), labelled "name, on a share". It's the
   author's like any drawing: their Undo, Eraser and Clear mine take it. **To wipe them:** **Clear kept notes** under the shared picture,
   or **Clear share notes** in the Draw bar (there only while you have some): both ask first with the count and take away your own kept
   notes in this room, for everyone. The share's own Clear mine / Clear all still clear only the share's picture.
4. **The Mixer's drawings on History.** The time lapse has no mixer, so under it there's a row "Drawings on the Mixer": a small strip for
   each track of the frame, in the frame's order, with each Mixer drawing on its strip from the frame at which it was drawn (stronger
   within ten minutes, faded after; at the last frame, all of them). The row is there only while the room has Mixer drawings and
   Drawings is ticked.

## How each kind is stored
One file per drawing, `rooms/<room>/drawings/<id>.json`, the panel's form (unchanged):
`{ user, time (UTC, ISO), kind, points = { { time in s, track oid, place down the track 0-1 } }, color = 0xRRGGBBAA, size = 2|4|8, text }`.
No `color` means the author's own colour.

| Tool | `kind` | `points` | Drawn as |
|---|---|---|---|
| Pen | `pen` (a file without a kind is a pen stroke) | 2 to 400, every point of the drag | a line through them, `size` wide |
| Highlighter | `marker` | 2 to 400, every point | the same, three times as wide, a third as strong |
| Line | `line` | exactly 2: the ends | a straight line |
| Arrow | `arrow` | exactly 2: tail, point | a line with a filled head |
| Box | `box` | exactly 2: opposite corners | a rectangle's outline |
| Circle | `circle` | exactly 2: opposite corners | the ellipse inside that rectangle |
| Text | `text` | 1, with `text` (200 characters) | the words |

A Mixer drawing adds `view = "mixer"`, its points `{ place down the strip 0-1, the strip's track oid, place across it 0-1 }`. A kept share
note adds `from = "share"` (arrange view only, kinds arrow, circle, text, no colour, size 4). A drawing Redo or Undo puts back is a new
file with a new id and the `time` it was first drawn, so History still shows it then.

## How it's built
- `lib/webdraw.lua`:
  - **Steps** (`webdraw.step`, `can_step`): for each room and view, an undo pile and a redo pile of at most `STEPS_MAX` (50) steps. A step
    is `{ ids }` (drawings of yours that are there: taken back by removing them) or `{ gone }` (drawings of yours the Eraser took: taken
    back by saving them again). Taking one back turns it into its opposite on the other pile. A put-back drawing gets a new id (the old
    file's deletion is still travelling), so old id -> new id is remembered and earlier steps still find it. A new drawing or erase
    empties Redo. Clear mine / Clear all aren't steps and start both piles afresh.
  - A page's actions gained `{ undo = true, view }`, `{ redo = true, view }` and `{ clear = "mine", share = true }` (never "all": a
    `share` with anything else is refused, so it can't fall through to Clear all). `clean` keeps `from = "share"`.
  - The topic gained `un` = `{ Undo, Redo on the arrange view, Undo, Redo on the Mixer }` (booleans, for the buttons), `sh` on a drawing
    kept from a share, and each track's 8-character GUID start as a 4th element (screen share's own name for a track).
  - `webdraw.save(cfg, b, s, time)`: an optional time to keep.
- `lib/webui/draw.js`: the three tools (the highlighter collects points as the pen does), Undo / Redo / Clear share notes buttons,
  `shareTag`, `shareNote`, `shareClear` (called by call.js), and `histMixer` (the History row, a canvas draw.js adds after the lapse's stage;
  `history.js` is unchanged, its existing one call to `ssDrawLayer.hist` drives both).
- **Share notes, the path:** a share names tracks by the start of their GUIDs, which are the sharer's own. The sharer's page adds each
  track's oid and the room's key to the view it already sends watchers (`shareTag`, from its own draw topic). When anyone draws a note,
  their own page (`shareNote`) checks the view is for their own room, that both ends are on tracks with a well-formed oid, and posts an
  ordinary `draw` add with `from: "share"` to their own Live sync. So the author is right, by the usual rules, with no new message kind.
- No change to `lib/webui.lua`, `lib/webui/index.html`, `record.html`, `history.js`, `anchor.js`, the panel (`StudioSync - Draw.lua`) or
  any C++.

## Files touched in others' files (small, additive)
- `lib/webui/call.js` (rt-share's): `viewOf` passes its view through `ssDrawLayer.shareTag` (2 lines changed to name the view, 1 added);
  `addNote` calls `ssDrawLayer.shareNote(n, f.view)` first (1 line); `board` adds the **Clear kept notes** button (4 lines).

## Tests
- `tests/test_0_60_rt_draw2.lua` (new): Line, Box and Highlighter from a page cleaned into the panel's form and passed by the panel's own
  check; the page's tool list equals the panel's, in order, and each is a kind the layer keeps; parse of undo, redo and the share's clear.
  **Two stand-in computers** (own disks, a stand-in link, Syncthing later): three drawings on James's page, Undo takes the newest (gone on
  Bo's at once), Redo puts it back (a new file, same time, live on Bo's), two Undos then Redo in order, a new drawing empties Redo; Bo
  with nothing of his own undoes nothing, nor as an admin; an admin's Eraser on James's drawing is no step of the admin's; a step whose
  drawing went some other way is passed over; the Eraser on your own is a step (Undo, Redo, Undo); the Mixer's pile and the Project
  page's are separate; Clear mine can't be undone and empties the piles; the newest-of-yours fallback (never someone else's newer one)
  and its Redo keeping a 1 November time; `STEPS_MAX`; a put-back stops at the room's limit. **Share notes:** kept as their author's own
  files with `from = "share"`, over the link, flagged in the topic; Clear share notes takes only the asker's share notes and leaves
  their other drawings, other people's notes and their Undo pile. Wiring of every piece; names and words still never go in as HTML.
- `tests/test_0_60_rt_draw.lua` (rt-draw's) passes unchanged.
- **Headless Chromium** (its own profile and port; fake devices; the "screen" a drawn canvas, never this computer's) against a stand-in
  (`scratchpad/rt-draw2/standin_rtdraw2.py`, not committed: rt-draw's two computers running the real `lib/webdraw.lua` and
  `webhistory.build`, plus rt-share's rtc relay and `rtview`; Bo an admin), driven by `drive_rtdraw2.mjs`: **95 checks, all pass.**
  Line, Box and Highlighter dragged with the mouse on James's Project page: each file read back in the panel's form (two ends, two
  corners, 13 points as `marker`), on Bo's page at once, in the panel's yellow and pink, the highlighter at alpha 85 of 255 and 12 px
  wide; Undo / Redo with the buttons (gone and back on Bo's page, same time, greyed states); three Undos, two Redos, a new drawing
  greying Redo; Bo's Undo taking only Bo's arrow after his admin Eraser took James's circle; Undo putting back an erased box. Mixer page:
  a Box and a Line on strips, its own Undo and Redo. History: the row appears; Bo's 9:30 Mixer box absent at the 9:10 frame, pink on
  Drums' strip at 10:00, today's Box on Vox only at the last frame; Drawings off hides the row. Phone (412 px, touch): the same tools,
  no sideways scroll, a finger's Highlighter, Box and Line, the phone's Undo and Redo, the computer's page undoing the phone's last two.
  Share: James shares the stand-in screen, Bo watches; the view carries the room and `T-JAMES-1` / `T-BO-2` (none for James's own
  track); Bo's arrow on Vox 0:15-0:20 becomes Bo's file with `from: "share"` and shows on James's pages; an arrow on James's own track
  stays the share's; a circle across two tracks and "too loud here" kept; James's own preview note kept as James's; the share's Clear
  all leaves the kept ones; Clear kept notes asks ("your 1 note") and takes James's, never Bo's; after Stop the notes are still on both
  Project pages, drawn on Vox; Bo's Undo takes his last note; Clear share notes asks ("your 2 notes"), takes them, leaves Bo's own arrow
  and James's drawings, and the button goes. No page errors.

## Not done / limits
- Undo's piles live in Live sync's memory: after Live sync restarts, Undo falls back to "your newest drawing on this view" and there's
  nothing to Redo. The panel's Undo is unchanged (no Redo there) and the panel's drawings aren't on the web's piles.
- Clear mine and Clear all can't be undone (their confirm says so).
- No keyboard shortcut for Undo / Redo on the web (the Project page has its own keys).
- A share note is kept only when the share shows the room's own song, the timeline's place in the picture is known, and the note's ends
  are on studio tracks. A note on the picture alone (another window, no JS_ReaScriptAPI / SWS on the sharer's computer), on one of
  StudioSync's own tracks, or on a share of a project that isn't the room's, stays the share's own and goes when the share ends. The
  page doesn't say which notes were kept (they show on the Project page).
- A kept note is in its author's own colour at size M, not the share's name colour.
- While the sharer's panel shows drawings over REAPER's arrange view, a kept note is in the shared picture too, so watchers see it twice
  (the share's note and the picture's) until the share's notes are cleared or hidden.
- Both sides need this build: a sharer on an older page sends no room or oids, so nothing is kept.
- The History row is a thumbnail: strips up to 90 px wide and 95 px tall, in the frame's track order, only for tracks alive in that
  frame. Text in it is drawn at the layer's usual size.
- Within one second, `read`'s "newest" order goes by the id's text; only the newest-of-yours fallback depends on it.

## Review-later security notes
- The share's view now tells watchers the room's key (`song/room`) and each studio track's oid. Watchers are bandmates in the call; one
  whose own Live sync is in another room learns this room's name and oids.
- A watcher's page takes the oid for a note's track from the sharer (shape-checked on the page, checked again by `webdraw.clean`, and
  used only when the view's room equals the watcher's own): a hostile sharer's page could make a watcher's kept note land on another
  track or time of the same room, as that watcher's drawing.
- `from = "share"` is only a label: any page of this computer can put it on its own arrange drawings (then Clear share notes takes them).
- Undo / Redo can be asked by any page with this computer's web token, for this computer's user's drawings only (as add and remove).
  Undoing an erase re-saves up to 50 drawings (one remove's limit) and sends as many link messages at once.
- A put-back drawing is written with the `time` text its file had; `webdraw.valid` checks that field only as a string, without a length
  limit (rt-draw's check, unchanged).
- The piles hold at most 50 steps a room and view; the old id -> new id map grows by one entry per put-back until Live sync stops.
- Everything a page draws from the topic (names, words, the label) still goes on a canvas as text; the two new confirm texts are built
  from a count only.

## To check in REAPER (two computers, Live sync on in the same song and room, the web UI open on each; a phone on the studio link)
1. Desktop web UI, Project page, **Draw**: a **Line**, a **Box** and a **Highlighter** stroke over the vocal track, in the yellow and
   pink swatches. The laptop's Project page shows each within a second. Run the panel's Draw tool on the laptop: the three look the same
   over REAPER's arrange view, on the same bars. Draw a Line, Box and Highlighter stroke in the panel: they show on both web UIs.
2. Desktop: **Undo** three times: each drawing goes on the laptop's page and panel too. **Redo** twice: two come back on both. Draw
   something new: Redo greys out.
3. Desktop: **Eraser** on one of your drawings, then **Undo**: it's back on both computers.
4. Laptop: Undo is greyed while the laptop's user has no drawing there; draw one, Undo takes only that. As an admin, erase one of the
   desktop's drawings, then Undo: it stays gone, and nothing of the desktop's is touched.
5. Mixer page on the desktop: a Box on a strip, Undo, Redo; the Project page's drawings don't change.
6. Phone (Record > Project): **Draw**: the same tools, Undo and Redo fit without sideways scrolling; a finger Line shows on both
   computers; the phone's Undo takes it; the desktop's Undo takes the next phone drawing.
7. Desktop shares REAPER's window (the room's song in front), laptop watches. Laptop: **Arrow** over a chorus on the vocal track and a
   **Text** note. Both show on the desktop's Project page labelled "name, on a share", and in the laptop's panel. Stop the share: they're
   still there. An arrow drawn over REAPER's toolbar or track panel (not the tracks) is not kept.
8. Laptop, Project page, Draw: **Clear share notes** asks with the count and takes only the laptop's kept notes, on both computers.
   Repeat 7 and use **Clear kept notes** under the shared picture instead.
9. History page with at least one Mixer drawing in the room: the row "Drawings on the Mixer" shows under the time lapse; scrub: each
   Mixer drawing appears from the frame after it was drawn, on its track's strip. Untick Drawings: the row goes.
10. Restart Live sync on the desktop, then Undo on the web: it takes the desktop's newest drawing on that view. Health/log: nothing new
    except "cleared N share notes from the web page".

## Round 2 (rt-p6, backlog 1.23; offline tests only, not run in REAPER)
- **A removal from the link whose Syncthing deletion never comes** (`lib/webdraw.lua`, `read`): a removal a bandmate sent over the link hid the
  file for `LIVE_FOR` (10 minutes) and then the drawing showed again if the deletion hadn't arrived. The removal was already checked when it came
  (only what its sender may remove), so when its hold ends and the file is still here, this computer deletes the file itself (it is what the
  sender's own deletion would do; Syncthing then carries a deletion nobody disagrees with). Test: `tests/test_0_60_rt_draw.lua` ("rt-p6 (1.23)",
  fails with the line removed). Decision taken from the backlog: none was James's.
- Still as in rt-draw2: Undo's piles live in Live sync's memory; Clear mine and Clear all can't be undone; a share note's limits.
- **Check in REAPER (two computers)**: Bo draws a mark, both see it. Pause Syncthing on James's computer, Bo removes the mark (it hides at once on
  James's through the link); wait 11 minutes, with Syncthing still paused: the mark stays hidden and its file in `rooms/<room>/drawings` on James's
  computer is gone (before: it showed again). Resume Syncthing: no mark comes back.
