# Drawing in the web UI: one layer with the panel's Draw tool (rt-draw, 2026-11-20)

Roadmap ("What the web UI makes possible"): "Drawing. The existing Draw tool, moved into the web view: draw over the timeline, the mixer or a
screen share, live for everyone, kept as an annotation layer on the song (shown in history, removable)." **Tested offline only** (Lua tests,
Node for the anchoring math, Chromium against a two-computer stand-in); **not run in REAPER or between two real computers yet.**

## What it does
- **Draw** on the web UI's **Project** page (over the arrange view), the **Mixer** page (over the strips) and the phone app's **Project** view
  (touch). A **Draw** button beside **Drawings** on each; while drawing: **Pen, Arrow, Circle, Text, Eraser**, colours (**Mine** = your own
  colour, six swatches, any colour), sizes **S M L**, **Clear mine**, **Clear all** (owner and admins only), **Done**. Your tool, colour, size
  and the Drawings tick are kept on that computer/phone.
- **Anchored:** a Project-page drawing sits on song time + track (the track's mirror-sync oid) and a place down the track, so it stays on the
  same bar of the same track when anyone zooms or scrolls, on any screen size; the phone shows the same drawings in the same places. A Mixer
  drawing sits on its strip (the track's oid) and a place across and down it, so it follows its strip when the strips scroll or the tracks are
  reordered.
- **Live for everyone:** a drawing goes over the direct link the moment it's made (a "draw" message) and shows on everyone's pages at once,
  with its author ("you" or their name, small, at its start); its file follows through the shared folder and becomes the record. The same for a
  removal. Without the link, the file is the fallback (shown when Syncthing brings it, as before).
- **A layer:** **Drawings** shows or hides them (this computer only). The **Eraser** takes away a drawing you tap: your own, or anyone's if
  you're an admin (`groups.may_manage`); **Clear mine** / **Clear all** ask first (a confirm with the count).
- **History page:** every arrange-view drawing shows on the time lapse from the frame at which it was drawn (stronger within ten minutes of
  the frame, faded after), on its track; at the last frame, all of them.
- **One layer with the panel's Draw tool:** the web and the panel read and write the same files, `rooms/<room>/drawings/<id>.json`, in the
  panel's own form `{ user, time, kind, points = { { time, track oid, place 0-1 } }, color = 0xRRGGBBAA, size, text }`, named as the panel
  names them. Drawings made in the panel show on the web; drawings made on the web show in the panel (Mixer ones excepted: they say
  `view = "mixer"` and have no place on the arrange view). The panel now also sends its drawings and removals over the direct link, reads the
  link's drawings itself (its own place in the extension's messages), and gained **Circle** (the web's kind).

## How it's built
- `lib/webdraw.lua` (new): the check of a kept drawing (the panel's old check, moved here, plus bounds), a page's add (`clean`), the folder
  read (each file once: drawings never change), drawings and removals from the link before their files (`from_msg`), `save` / `remove`
  (file + link), the pages' **`draw`** topic (`model`: `{ key, me, admin, tracks: [[oid, REAPER track number, name]], list }`, each drawing
  `{ id, u, t (UTC s), k, c, w, x, v, o: [oids], p: flat [t, oid#, d] }`, the newest 400, 60,000 points at most, a long stroke thinned with
  its end kept), and the tick (only while a page looks; the folder every 1 s, at once after a change).
- **Removals:** removed here: the file is deleted, or (not here yet) noted so it's deleted when it arrives. A removal from the link hides the
  drawing until Syncthing's deletion comes (10 minutes at most), and only for what the sender may remove: their own, or anyone's when this
  computer's roles say they manage the studio.
- `lib/webui/anchor.js` (new): screen share's anchor code (`anchorOk`, `toPic`, `fromPic`) moved out of `call.js`, which now uses it; the
  drawing layer uses the same functions. Each surface describes itself as a share-style view (time range, the arrange view's place, tracks
  `[oid, y, h]`); the Mixer's is the same view with its axes swapped (strips across, the place down a strip as "time"). The one change: a track
  id may be up to 80 characters (mirror oids), was 16.
- `lib/webui/draw.js`, `draw.css` (new): the overlay canvas over each surface (takes the pointer only while drawing; the mouse wheel goes on to
  the view's own zoom and scroll), the tools, the History hook (`window.ssDrawLayer.hist`).

## Files touched in others' files (small, additive)
- `lib/webui.lua` (shared): `webui.ACTIONS.draw`, the `draw` action routed to `webdraw.action`, `handlers.draw` (the link's messages) and
  `webdraw.tick` after the History tick.
- `StudioSync - Draw.lua`: load/save/erase/Undo/Clear mine through `lib/webdraw.lua`; Mixer drawings skipped; Circle tool and drawing.
- `lib/page_chat.lua`: the All tab has no Go for a Mixer drawing (its first number isn't a time) and says "on the Mixer".
- `lib/webui/call.js`: its three anchor functions replaced by `window.ssAnchor` (no behaviour change, longer track ids allowed).
- `lib/webui/daw.js`: one line, `if (X.over) X.over();` after the arrange view is drawn.
- `lib/webui/mixer.js`: one line, each strip gets `data-o` (its track's oid).
- `lib/webui/history.js`: one call to `window.ssDrawLayer.hist(...)` before the strip is drawn.
- `lib/webui/phonedaw.js`: `window.ssPhoneDaw` (the view and its bar) and two `PX.over()` calls in its draw.
- `lib/webui/index.html`, `record.html`: anchor.js (before call.js), draw.css and draw.js.
- `tests/test_0_60_rt_webui.lua`, `tests/test_0_60_rt_phonefix.lua`: a `webdraw` stand-in beside the other modules' (their stand-in REAPER
  lists folders forever).

## Tests
- `tests/test_0_60_rt_draw.lua`: ids, oids, the kept-drawing check (old pen strokes without a kind, own-track points, ten bad shapes), a page's
  add for every kind (point counts, bounds, rounding, 0-1 down a track, Mixer places, text cleaned and capped, 400 points), the topic (each oid
  once, newest first, colours, UTC seconds, an old stroke, a 100,000-point stroke thinned and still ending at its end); **two stand-in
  computers** with their own disks, a stand-in link and "Syncthing" copying files and deletions later: drawn on James's page -> file there,
  live on Bo's at once with its author -> Bo's pages get it -> the file arrives and takes over; duplicates, spoofed authors, bad song names and
  bad drawings from the link refused; Bo (member) can't remove James's or Clear all; a removal message from Bo for James's drawing ignored;
  James removes his own -> hidden on Bo's at once, Bo's file goes with Syncthing; Bo as admin removes James's before its file arrives -> deleted
  on arrival, and James's computer takes the removal; Clear mine / Clear all; the room's limit. **The panel's storage:** an old panel file read,
  a damaged one skipped, the panel's save through webdraw (file + link), the panel's own poll of the link; Draw.lua's source uses webdraw for
  read/save/erase/Undo/Clear mine, skips Mixer drawings, draws circles. Wiring of every piece. Runs `tests/rt_draw_anchor_test.js` with Node
  when it's here.
- `tests/rt_draw_anchor_test.js`: a Project-page point keeps its time, track and place through 4x zoom, a 10 s scroll and a lane's scroll, and
  on a phone-sized view; a track not shown -> not drawn; names column and ruler aren't places; Mixer marks follow their strip through a
  scroll and a reorder and onto a narrower window.
- **Chromium** (the desktop app's browser pane) against a stand-in (`scratchpad/rt-draw/standin_rtdraw.py`, not committed): two web UI servers
  serving the real pages, each running the real `lib/webdraw.lua` (and `webhistory.build` for the History topic) in its own Lua on its own
  folder, a stand-in link between them, Syncthing every 4 s; James a member, Bo an admin. Checked: an arrow dragged with the mouse on the
  Project page lands on 0:15-0:20 of Vox and stays exactly there through a Ctrl+wheel zoom and a scroll (the wheel over the layer reaches the
  view); a blue circle shows on Bo's topic live before its file arrives; text (prompt answered); James's eraser refuses Bo's drawing ("Nothing
  of yours there") and takes his own (gone on Bo's at once, deleted there by Syncthing); Clear all hidden for James; a Mixer stroke on Vox's
  strip follows it when the strips are reordered; History: the 9:30 panel drawing shows from the 10:00 frame, not at 9:00/9:10, today's only at
  the last frame; the phone's Project view (375 px, no sideways scroll): a touch stroke on Vox anchored to its track, buttons wrap; Bo (admin)
  Clear all asks with the count and empties James's at once; Drawings off and on. No console errors from the new code.

## Not done / limits
- **Screen share:** drawing over a share stays the share's own notes (rt-share, now on the shared anchor code); they aren't saved to the
  room's layer.
- Drawings show on History only for the arrange view; Mixer drawings aren't on the time lapse.
- The phone draws only while the computer is live (the view kept offline shows no drawings).
- A drawing over automation lanes on the Project page is kept at its track's foot (the panel's 0-1 rule).
- No undo on the web (the panel's Undo is there); no Line/Box/Highlighter tools on the web (they're drawn when the panel made them).
- `draw.js` thins strokes over 400 points; the topic thins very long ones further for the page (the file keeps them whole).
- A removal from the link hides a file for 10 minutes; if Syncthing's deletion never comes, it shows again.

## Review-later security notes
- Link messages carry the author's name in the data (as chat's do): a bandmate's computer on the link could send a drawing claiming another
  name, or a removal "by" an admin's name. Files are trusted as every shared-folder file is. Removals from the link are only hidden here,
  never deleted here; drawings are bounded (400 points, 200 characters, 500 waiting, 2,000 a room for adds from this computer's pages).
- Any page with the web token (this computer's user) can draw and remove that user's drawings; an admin's page can clear the room.
- Page text (names, words) is drawn on canvas with fillText; nothing goes in as HTML.

## To check in REAPER (two computers, Live sync on in the same song and room, the web UI open on each)
1. Desktop web UI, Project page: **Draw**, Arrow across a chorus on the vocal track. The laptop's Project page shows it within a second,
   labelled with the desktop's name. Zoom and scroll on both: it stays on those bars of that track.
2. The panel's Draw tool on the laptop (arrange view): the web arrow shows there once its file arrives (or at once while the panel runs).
   Draw a Circle in the panel: it shows on both web UIs.
3. Laptop web UI, Eraser on the desktop's arrow: refused unless the laptop's user is an admin. Desktop: Eraser on it: gone on both at once.
4. Mixer page: Pen over a strip. Move that track in REAPER (reorder): the drawing follows its strip on both computers.
5. Phone (studio link, Record > Project): Draw, a finger stroke on a track: shows on both computers' Project pages.
6. History page: drawings appear at the frame when they were drawn.
7. **Drawings** off hides them on that computer only; Clear mine / Clear all (admin) ask first and clear for everyone.
8. Health/log: nothing new except "cleared N drawings from the web page" lines and refusals.
