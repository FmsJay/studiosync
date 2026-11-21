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

## Review later (security)
- (none yet)
