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

| Part | Commit | Files |
| --- | --- | --- |
| 0 + 1 Watch wording, delete | dac7459 | `lib/dawedit.lua`, `lib/webui/daw.js`, `lib/webui/autolanes.js` (`X.autoClear` only) |
| 2 Fades | 14ff962 | `lib/dawview.lua` (reader), `lib/dawedit.lua`, `lib/webui/daw.js`, `daw.css` |
| 3 Sends | 386e3a3 | `lib/dawmidi.lua`, `lib/dawview.lua` (routing), `lib/webui/daw.js`, `daw.css` |
| 4 Automation items | 0cade05 | `lib/dawmidi.lua`, `lib/webui/autolanes.js` |
| 5 CC lanes | 59001c0 | `lib/dawmidi.lua`, `lib/webui/pianoroll.js` |

`lib/webui/autolanes.js` isn't in the backlog's file list for P14, but it is where the automation lanes are drawn and no other package lists it,
so automation items live there. No shared file was touched (`lib/webui.lua`, `lib/webui/app.js`, `tabs.js`, `index.html`, `page_health.lua`,
`StudioSync - Live sync.lua`): the new topic `dawsend` and the new actions ride the existing `daw` topic and its `ACTIONS` entry. The tests
are `tests/test_0_60_rt_dawedit.lua`, `..._dawview.lua`, `..._dawmidi.lua` (each fails without its change, checked against the commit before)
and `tests/rt_p14_browser.mjs`.

P1's claim-ask path: delete and fade are `dawedit.lua` item edits, so they get `item_why`'s Claims handling and `claimask.web_ask`'s `ask` in the
answer as move, mute and trim do (delete works the ask out before the item goes). Notes, controller points, sends and automation items are
`dawmidi.lua`'s: an item edit there (a note, a controller point) is still made in Claims mode when the claimer is here and held by
`mirror.watch`, but the answer has never carried `ask` (an existing gap for notes; not changed), and the track-level ones (sends, automation)
are refused on a claimed track as point edits always were.

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

## 3. Sends (`lib/dawmidi.lua`, `lib/dawview.lua`, `lib/webui/daw.js`, `daw.css`)
- **Page:** a **Sends** button in the edit row (the selected item's track) and **Sends...** in the right-click / long-press menu on a track's
  name open a panel over the arrange view: each send's destination, a Mute box, a level slider (-60 to +12 dB, the far left is off: 0) with
  its dB readout, a pan slider with its readout, Remove; and, at the bottom, a list of every other track with Add send. Each change is one
  edit when the slider is let go. Values update in place; a hand on a slider keeps it, and an answer that refuses puts them back and says why.
- **Topic and path:** `{topic:"daw", look:{send: <the track's place> | false}}` (every 10 s, 30 s grace, as the piano roll's and the lanes') makes
  `dawmidi.tick` publish `dawsend` `{key, lane, name, sends:[{i (REAPER's index), to (the destination's place among the shown tracks), n,
  v (linear), p, m}]}` only while open and only when REAPER's change count moves. Sends to a hidden track or this computer's own (the live out
  track) aren't shown, as in the Mixer. Edits: `{topic:"daw", send:{id, op: add | remove | vol | pan | mute, lane, to, i?, v? p? on?}}`
  -> `dawview.action` (sets `dirty_all`) -> `dawmidi.action` -> `send_apply`; the answer is the `dawedit` topic (`{id, ok | why}`).
  A send is named by its track's place, its index and its destination's place, and must still be what the page saw.
- **Permissions:** a send is the destination's own object in the sync (`AUXRECV` is on the track it goes to), so the destination's rule is asked,
  exactly as the Mixer does (`webmixer`'s comment): `sync.authority` for its name with no spot, or the maker while nobody claimed it
  (`dawedit.item_refusal`). Level 0 to 4 (+12 dB), pan -1 to 1, a track can't send to itself, at most 32 sends shown a track. One undo point each
  ("send level Bass", "add send to Keys", "remove send Bass" ...). Mixer's own level slider is unchanged (it keeps its own
  `webmixer` path and "Not yet" list; this panel adds send mute, pan, add and remove for the Project page).
- **Not done:** a send's mode (post-fader / pre-FX), send channels, receives' view from the destination, sends with MIDI routing.
- **Tests:** `tests/test_0_60_rt_dawmidi.lua` (parse, each edit on a stand-in REAPER, the destination's claim refusing, its claimant, Driver only,
  stale sends, not to itself, the topic only while looking and only for the shown tracks, closing, running out), `tests/rt_p14_browser.mjs` (the
  panel from the edit row and from the name's menu, level, pan, mute, remove, add, a refusal putting the slider back, in-place updates).
- **Check in REAPER:** on a project with sends: open the panel on a track with two sends and compare levels with REAPER's send fader (0.0 dB, and a
  -6.0 dB one), pan and mute; move a slider, Ctrl+Z in REAPER takes it back once; add a send to a bandmate's claimed track (refused, says who) and
  to an unclaimed one (it appears for them); remove one; a send to this computer's own track isn't listed; change a send in REAPER while the panel
  is open (the panel follows).

## 4. Automation items (`lib/dawmidi.lua`, `lib/webui/autolanes.js`)
- **Scope, and why:** an envelope's automation items are **shown, moved, resized and muted**. **Not done:** adding one, deleting one, and editing the
  points inside one. Deleting: no API removes an automation item (`mirror.lua`'s `clear_ai` takes the `POOLEDENVINST` lines out of the envelope
  chunk; that is a chunk rewrite of a whole envelope, not an edit I'd make from a drag). Adding: `InsertAutomationItem` with a negative pool
  absorbs the envelope's own points under it, and with a pool number needs a fresh one project-wide (`mirror.next_pool`, local to mirror.lua);
  neither is a one-line edit. Points inside: I could not confirm from the disk whether `GetEnvelopePointEx(env, ai, n)`'s times are project
  or pool time (`mirror.item_lines` reads with the 0x10000000 one-pass flag), so what an item plays isn't drawn, only where it is.
  `tests/reaper/auto_items.lua` is the place to settle that if these are wanted.
- **Read:** `dawenv`'s envelopes carry `a`, flat triples (position, length, muted) from `CountAutomationItems` /
  `GetSetAutomationItemInfo(D_POSITION, D_LENGTH, D_MUTE)`, up to 200 an envelope; no key when there are none. Three calls an item, only for
  the open lanes.
- **Edit:** `{auto:{op: ai_move | ai_resize | ai_mute, lane, e, name, n (the item's index), t (where it was), to | len | on}}`, named as a point is
  (the envelope by index and name) and refused when the item at that index isn't at `t` any more. The track's automation rule, as a point edit
  (the track's name with no spot: its claim, Driver only; a bandmate editing it too merges). Move: `D_POSITION`, snapped as REAPER snaps (SnapToGrid,
  only with snapping on). Resize: the end snapped like a trimmed item's, never under `dawedit.MIN_LEN`. One undo point each ("move automation
  item", "resize automation item", "mute automation item" / "unmute ...").
- **Page:** a box over each item's span on its lane (dimmer when muted, an accent outline when selected, "automation item" when wide enough);
  drag it to move, drag its right edge to resize (a phone: the selected item only; a tap selects), the menu offers Mute / Unmute. A drag on a
  spot with no item or point still pans. A point under an item wins over the item.
- **Tests:** `tests/test_0_60_rt_dawmidi.lua` (parse, the published triples, each edit on a stand-in REAPER, stale index or place, a claimed track,
  its claimant, Driver only), `tests/rt_p14_browser.mjs` (open the lanes, drag, refusal, resize by the edge, the menu's Unmute, a drag on nothing).
  The first run of the Lua test caught a real bug in the reader (the third value of each triple went into slot 5).
- **Check in REAPER:** a track with an automation item (volume, a send's, an FX knob's): the box sits where REAPER's does; drag it by a bar and
  compare; resize by the right edge (REAPER's own end moves the same, and Ctrl+Z puts it back once); mute it (REAPER shows it muted and the
  envelope plays without it); a pooled pair (moving one doesn't move the other); looped or rate-changed items (position and length only);
  a bandmate's item on a track they claimed (refused).

## 5. CC lanes in the piano roll (`lib/dawmidi.lua`, `lib/webui/pianoroll.js`)
- **Page:** a **Controller** box in the roll's bar (None, the usual controllers, and any other number the item has, marked with a dot) puts a
  lane under the velocity lane (the notes and the velocity lane give up its height): the number's events as a stepped line, each value
  holding to the next point, with its points and the selected one's value. Drag a point (time snapped to the roll's grid, value from the
  lane's height, 0 to 127), double-click (double-tap) an empty spot to add one, Delete or the menu removes the selected one. A phone: the
  selected point moves, anything else pans; long press for the menu. Plain CC messages only (0xB0): pitch bend, pressure and program
  change aren't shown or touched. Step input (P5's flag) and the note editing are unchanged.
- **Topic and path:** the roll's look says `{item, cc: <number> | false}` (every 10 s, as before). `dawmidi` now carries `ccs` (the CC numbers
  the item has) and, for the number asked for, `cc: {c, ev}` with five numbers an event (its index among all the take's controller events,
  ms from the item's start, value, ticks, channel; up to 4,000 events). The signature uses `MIDI_GetHash(take, false)` (every event, not the
  notes only: a controller edit changes nothing else) and the number, so changing the number or an edit in REAPER publishes at once.
  Edits go on the notes' channel: `{note:{op: cc_add | cc_move | cc_delete, item, c, a | n s to v, ch?, g}}` -> `note_apply`: the item's rule as
  a note's (`item_why`: its track and spot, claims, Driver only, Claims asking), found as the page named the item, and the event named by
  index, ticks and number and refused when it isn't that any more (so a pitch bend or another number's isn't touched). Add:
  `MIDI_InsertCC(take, false, false, ticks, 0xB0, channel, number, value)` then `MIDI_Sort`; move: `MIDI_SetCC` (time on the page's grid in
  the take's own ticks, as notes; value); delete: `MIDI_DeleteCC`. One undo point each ("add controller point" ...).
- **Not done:** a point's shape or ramp (the line is drawn stepped), pitch bend / pressure / program change lanes, a lane's channel filter
  (all channels of the number are shown; an add uses channel 1), box-select, copy/paste.
- **Tests:** `tests/test_0_60_rt_dawmidi.lua` (parse and refusals, the reader, each edit on a stand-in REAPER, stale index/ticks/number, a pitch
  bend not a CC, a claimed track, Driver only, the topic: numbers, events for the one asked, change in REAPER republishes, switching number,
  closing). It caught that the first version dropped the take's event index (the page would have named the wrong event whenever another
  number's events sit between). `tests/rt_p14_browser.mjs` (the roll opens, the box, the look, drag, refusal, select and Delete, double-click add,
  the menu, close).
- **Check in REAPER:** an item with CC 1 and CC 7 automation (and a pitch bend): the box lists them; the lane matches REAPER's own CC lane
  (values and times); drag a point (one Ctrl+Z); add one (it's a CC at channel 1, which REAPER's lane shows); delete one; with the lane open a
  bandmate's change to the item shows within a second; a claimed track refuses; the notes and velocity lane still work with the lane open
  (resize the window short: the notes area shrinks).

## 6. Region playlists (backlog 1.11): decided, left
REAPER 7's region playlists ("skip hidden regions") aren't carried in Play together; the backlog's default was "rare: leave", and that stands. Nothing
was built. The page's regions are the project's markers and regions as `EnumProjectMarkers3` lists them, so a region that a playlist hides still
plays on the page's timeline exactly as before. If it is wanted later: the playlist lives in the project file (the name of its block wasn't
checked on this drive), not in the API this page uses, so it would be carried like the other project-level settings in `mirror.lua` / `lib/together.lua` first, and the page would
only show it.

## Review later (security)
- The page-supplied numbers are all validated and clamped on this computer (`parse_send`, `parse_note`'s controller ops, `parse_auto`'s item ops, the
  fade fields) before any REAPER call; sizes: 32 sends, 200 automation items an envelope, 4,000 controller events a topic. The sends and
  controller topics are only built while a page says it looks (30 s grace), like the others. Nothing here touches signing, the link or the
  files, and no check was weakened: each edit takes the rule the equivalent edit in REAPER takes (`dawedit.item_refusal` / `item_why`).
- A send is checked against the destination track only (the Mixer's rule); the source track's claim isn't asked. If a source's owner should also
  be asked, that is a rule change in `send_apply` for the security review.
- Deleting an item from a page deletes it for everyone through the normal sync (as REAPER's Delete does): one Ctrl+Z here, and the sync's
  put-back protects a claimed track as for any other deletion; worth a look in the review that a Driver-only room refuses it (tested).
