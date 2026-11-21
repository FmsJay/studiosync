# The Project page's missing edits (rt-p14, package P14, 2026-11-21)

Delete, fades, sends, automation items and CC lanes on the web Project page (backlog 3.17), the Follow wording (P7's) and the region
playlists question (1.11). One commit a feature. **Offline-tested only** (Lua tests on a stand-in REAPER, and the page's real scripts in
headless Chromium against a stand-in server: `node tests/rt_p14_browser.mjs`, not part of `tests/run.py`; it needs Chrome or Edge and says
"ok" with a note when neither is installed). Nothing ran in REAPER or on the test computers.

Every edit takes the path the page's earlier edits take: `{topic:"daw", edit | note | auto: {id, op, ...}}` -> `dawview.action` ->
`lib/dawedit.lua` or `lib/dawmidi.lua`, which finds what the page named (still where the page saw it), checks it as REAPER's own edit would be
checked (`sync.authority`, `sync.maker_may`, claims and Driver only, `claimask` asking in Claims mode), applies it through the API in one undo
point ("StudioSync web page: ...") and answers as the `dawedit` topic (`{id, ok | why, ask}`); the normal sync carries it from there. A page
edit sets `dawview`'s `dirty_all`, so the next look reads every track (rt-perfcut4).

## 0. Wording: the "Follow" select (`lib/webui/daw.js`)
P7 renamed the other Follows. The Project page's select is now labelled **View** (its accessible name is "Watch a bandmate"), the options read
Nobody / Play cursor / This REAPER / **Watch <name>**, and the note says "Watching <name>: their view arrives once their StudioSync sends it."
Internal names (`follow`, `dfollow`) are unchanged.

## 1. Delete (`lib/dawedit.lua`, `lib/webui/daw.js`, `lib/webui/autolanes.js`)
- **Items:** op `delete`, named as every item edit is (track place, item place, position, length, still where the page saw it). Checked with
  `item_why` like a move (the track's name and the spot; the maker while nobody claimed it; Claims asks the claimer, answer `ask`). Applied with
  `DeleteTrackMediaItem` in one undo point ("delete item"). `claimask.web_ask` is worked out *before* the item goes (it reads the item, which
  is gone after) and the answer kept in `dawedit.asking_at.pre`.
- **Markers and regions:** op `delete_marker` (`i`, `r`, `p`, as move/rename name them): `sync.watch_timeline`'s rule through
  `timeline_refusal` (the driver's timeline; a region someone claimed stays theirs), `DeleteProjectMarker`. This computer's own marks (pings,
  claims, punches) can't be named, so can't be deleted.
- **Page:** a Delete button in the edit row, the Delete / Backspace key (not in a box, not while the piano roll is open: it has the keys), and
  Delete in the item's and the marker's long-press / right-click menu. A refusal snaps back with the reason; the item goes when its chunk comes
  back without it. Selecting an item or marker clears an envelope point selected before (`X.autoClear`, autolanes.js), so Delete is never two.
- **Tests:** `tests/test_0_60_rt_dawedit.lua` (parse, claimed track refused, claimant allowed, Chilio-here ask worked out before the item goes,
  Driver only, a claimed region, own marks, undo label); `tests/rt_p14_browser.mjs` (select, Delete button and key, refusal, chunk back
  without the item, a marker, a region from the right-click menu).
- **Check in REAPER:** on a song with a bandmate: delete an item, a marker and a region from the page (each one Ctrl+Z, and gone on their side);
  delete on a track they claimed (Claims, they're here: made here and asked; away: refused, snaps back, says who); as a guest in Driver only
  (refused); the Delete key with the piano roll open deletes a note only.

## 2. Fades (`lib/dawview.lua`, `lib/dawedit.lua`, `lib/webui/daw.js`, `daw.css`)
- **Read:** each item carries its own fade lengths (`fi`, `fo` seconds, only when there is one) and, when not linear, the shape (`fis`, `fos`,
  REAPER's 0 to 6, shown as "type 1 (linear)" to "type 7", REAPER's own words for its set-fade-shape actions). Two more REAPER calls an item
  (`D_FADEINLEN`, `D_FADEOUTLEN`), two more only for an item that has a fade; on rt-bigproj's 4,000 items a whole look costs 8,000 calls more
  (the partial look's per-track reads are unchanged). The item's signature has them, so a fade edit resends only its chunk. **Not** the
  auto-crossfade lengths (`D_FADEINLEN_AUTO`): those come from overlaps and aren't the item's own, so a crossfade REAPER made from an overlap
  isn't drawn. `items_fp` (the partial look's fingerprint) is **not** extended: a fade edit in REAPER selects the item (a hinted track, read at
  once), a bandmate's lands through `mirror.apply` (a whole read) and the page's own sets `dirty_all`; only another script's fade on an
  unselected item shows at the next whole read (10 s), as for any other property already read.
- **Edit:** op `fade` `{side: in|out, len?, shape?}` (either or both): `item_why` like a trim; the length is from the item's edge, snapped as
  REAPER snaps the fade handle (SnapToGrid: only with snapping on; 0 stays 0), never past the other fade (which isn't changed). Set with
  `SetMediaItemInfo_Value(D_FADEINLEN | D_FADEOUTLEN | C_FADEINSHAPE | C_FADEOUTSHAPE)` in one undo point ("item fade in", "item fade out",
  "... shape"). Fades are item-level lines of the item's state (`mirror.lua` ITEM_LEVEL FADEIN/FADEOUT), so the normal sync carries them.
- **Page:** the dimmed triangle and a line along each fade (drawn straight whatever the shape, as other envelope shapes are), a square handle at
  each fade's end on the selected item (top corners), dragged to set the length (mouse: any item's corner; phone: the selected item's), and two
  boxes in the edit row for the shapes. A drag through the middle still moves the item.
- **Tests:** `tests/test_0_60_rt_dawedit.lua` (parse and refusals, snapped lengths, out measured from the end, not past the other, 0, shape alone,
  a claimed track, its claimant), `tests/test_0_60_rt_dawview.lua` (the reader, the chunk, shapes read only with a fade),
  `tests/rt_p14_browser.mjs` (corner drags, a refusal, the chunk back, the shape boxes, the middle still moves).
- **Check in REAPER:** drag each fade handle on an item and compare with REAPER's own fade (length, and one Ctrl+Z); change the shape and look
  at the item in REAPER (the shape numbers are REAPER's C_FADEINSHAPE 0 to 6; the page's labels follow its action names, unchecked against
  the item's fade menu); snapping on and off; a fade longer than the item (clamped); an item with a fade REAPER made from a crossfade (not
  drawn).

## Review later (security)
- (none yet)
