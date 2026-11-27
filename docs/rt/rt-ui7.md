# rt-ui7: the Project tab and the Edit switch (Phase 7 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave B" > Phase 7, with 2.6, under James's decisions of 2026-11-27 (decision 3: the Edit
switch goes back to View on every open of the Project tab and after 5 minutes idle; decision 8: Mixer inside Project). Findings served
(`docs/rt/findings-2026-11-27.md`): item 15 ("look, feel and edit exactly like the real project, with a toggle for actually editing there
so nobody edits by accident"), and a little of "waveforms not showing on some tracks" (nothing new there: rt-setup's `take_peaks` fix is
kept as it was).

## What was built

**The View / Edit switch** (`lib/webui/daw.js`, `daw.css`), at the left of the Project bar (Arrange), and the same switch on the Mixer.
- **View** (how the tab always opens): a click selects, a drag scrolls (an item too), the wheel zooms, a double-click opens the piano
  roll to look at, a tap on a track's name opens its automation lanes, the sends panel opens with its controls off. The edit row shows
  only the selection, Piano roll and Sends; the right-click / long-press menu offers only Piano roll. **Nothing is sent.** Play / Stop
  together, Follow and History still work: they aren't edits.
- **Edit**: the bar and the arrange get an orange frame and "Editing: changes go to everyone"; everything from rt-p14 and before works
  as it did.
- **Back to View**: each time the Project tab opens (from any other tab, a pop-out opening, the project closing and coming back; moving
  between Arrange and Mixer keeps it), and after 5 minutes without an edit ("Back to View: 5 minutes without an edit."). Any edit sent
  restarts the 5 minutes; switching to Edit does too. One state for the whole page (the switch on the Mixer is the same one).
- **The flag**: every edit the page sends carries `edit: true` in its body: `{ topic: "daw", edit: { op, ..., edit: true } }`, and the same
  inside `note`, `auto` and `send`. It's added in one place, daw.js's `act`, which also refuses (no request at all) an edit while in View,
  so a forgotten guard in a page can't send one. The piano roll (`pianoroll.js`) and the lanes (`autolanes.js`) also check
  `ssDaw.editing()` themselves, so in View they don't start drags, add on double-click, open their menus or take Delete and arrow keys;
  step input stops when the page goes back to View.
- **Live sync refuses an edit without the flag**: `lib/dawedit.lua` (items, markers, regions) and `lib/dawmidi.lua` (notes and
  controllers, envelope points and automation items, sends) answer "the Project page is in View: switch to Edit to change things there"
  before asking REAPER anything. A stale tab, an older cached page or a page in View can't edit by accident. This is a UI safety, not a
  security check: claims and permissions are unchanged and still apply to flagged edits.
- **The Mixer** (`mixer.js`): the switch at its top. In View the song's controls are locked (volume, pan, mute, plug-in bypass, sends;
  with Local mixing on, volume and pan stay yours and keep working). Solo and Your monitor mix are only yours, so they always work. In
  Edit its edits carry `edit: true` too, but **`lib/webmixer.lua` doesn't check it** (not in Phase 7's files, and the phone app's
  track volume and mute go through it without a switch): see "Left for later".
- **The follow select** reads "Follow" (it said "View", which now names the switch); its aria-label and options are unchanged.

**Looks like REAPER** (`lib/dawview.lua`, read by `daw.js`; rt-follow's view fields and rt-setup's `take_peaks` untouched):
- **Track heights**: each track's `h` (REAPER's `I_TCPH`, px). The page draws each lane at that height relative to the others (the
  middle one at the page's own lane height, between 16 px and four lanes), so a tall track in REAPER is tall here. Following a bandmate's
  vertical scroll (`top`) still lands on the same track. Read with the track lines at every look; a height change alone shows at the next
  whole look (within 10 s).
- **Fixed lanes**: on a track in fixed-lane mode with items in more than one shown lane, `nl` (rows) on the track and `ln` (row) on each
  item; the page draws and selects each item in its row. (Only the lanes that play are shown, as before: `items_of`.)
- **The ruler's format**: `rf` in the header (`dawview.ruler_mode`: REAPER's own `format_timestr_pos(t, "", -1)` matched against modes
  0 to 5). In a time format the ruler shows minutes and seconds and the time reads m:ss; in bars.beats it reads bar.beat alone; in both
  (or anything else) as before.

**Pop-out ready**: Project > Arrange joins Mixer, Sheet and Beat in tabs.js's `POP` (one line), so ⋯ > Pop out this page works on it;
a pop-out opens in View. Mixer, Sheet and Beat were already Project sub-tabs (their `ssTabs.add` names land there by tabs.js's `LEGACY`,
rt-ui1); their registration is unchanged, as `tests/test_0_60_rt_mixer.lua` reads it.

## Files

- `lib/webui/daw.js`, `daw.css`, `pianoroll.js`, `autolanes.js`, `mixer.js` (Phase 7's own).
- `lib/dawedit.lua`, `lib/dawmidi.lua`, `lib/dawview.lua` (Phase 7's own).
- `lib/webui/tabs.js`: one additive line (`POP.add('project/arrange')`), staged from HEAD.
- Not touched: `lib/webui.lua`, `lib/webui/index.html` (no new topic, action or file), `sheet.js`, `visuals.js` (see below).
- Tests: new `tests/test_0_60_rt_ui7.lua`, `tests/rt_ui7_browser.mjs`; `tests/test_0_60_rt_dawedit.lua` and `test_0_60_rt_dawmidi.lua`
  (their edit helpers add `edit = true`, one line each), `tests/rt_p14_browser.mjs` (switches to Edit before its edits; "Follow").

## Tests

- `tests/test_0_60_rt_ui7.lua`: six item and marker edits and a note, an envelope point and a send, each well formed, refused without
  the flag (and with `"true"` as a string) with the page's id and why, and REAPER not called once; with the flag each goes on to REAPER;
  looks need no flag; `dawview.lane_rows`; `dawview.build`'s `h`, `nl`, `ln`, `rf` and a lane change resending its chunk;
  `dawview.ruler_mode` for modes 0 to 5, an unknown format and no answer; the page files' gate, switch, idle, reopen and guards.
- `tests/rt_ui7_browser.mjs` (by hand: `node tests/rt_ui7_browser.mjs`; Chrome or Edge, a stand-in server, no devices): opens in View;
  a click, a drag, Delete, the menu, a marker drag, the sends panel, a page script calling `ssDaw.act`, the piano roll (double-click to
  open, double-click inside, Escape) and the Mixer (mute and bypass off; solo still goes) send no edit; Edit shows the frame and the
  line, and Delete, a send level and the Mixer's mute each carry `edit: true`; back to View after the idle time (set short in the test) and
  nothing sent then, an edit restarting it; back to View on reopening the tab (on Arrange and on the Mixer), not between its sub-tabs;
  heights, fixed-lane rows (clicks select the right row's item) and the ruler's two formats; no page errors.
- Results: see the report (a fresh clone of the commit: `python tests/run.py --no-luals`, the same with `TZ=UTC0`,
  `node tests/rt_ui1_browser.mjs`, `node tests/rt_p14_browser.mjs`, `node tests/rt_ui7_browser.mjs`).

## Checks for James (after a release with these files)

In REAPER, docked web view, a studio project open:
1. Project > Arrange opens with **View** pressed at the left of the bar. Click an item: it's selected; drag it: the view scrolls, the item
   stays. Press Delete: nothing. Right-click it: only Piano roll (for MIDI) or nothing. Double-click a MIDI item: the piano roll opens and
   says it's to look at; double-click inside: no note.
2. Press **Edit**: an orange frame round the bar and the arrange, "Editing: changes go to everyone". Move an item: it moves in REAPER as
   before (and on the bandmate's computer).
3. Go to Chat and back to Project: View again. Go Arrange > Mixer while in Edit: still Edit there (orange frame on the Mixer); mute a
   track from the Mixer: it mutes. Back in View on the Mixer: volume, pan, mute and bypass don't move; solo does (yours only).
4. Leave it in Edit for 5 minutes without editing: it goes back to View and says "Back to View: 5 minutes without an edit."
5. Make one track much taller in REAPER (and one short): within 10 s the page shows them tall and short too. Put a track in fixed lanes
   with two lanes playing (Lanes: play all): its items show in two rows. Switch REAPER's ruler to Minutes:Seconds (right-click the ruler,
   or Options > Time display): the page's ruler and time read m:ss; to Measures.Beats: bar.beat.
6. An old tab (a browser left open from before this release) that tries an edit: refused with "the Project page is in View: switch to
   Edit to change things there" (reload it to get the switch).
7. ⋯ > Pop out this page on Project > Arrange: the arrange in its own window, in View.
8. The phone app's Project view and the panel: unchanged (the phone's take picking and track volume/mute don't go through the switch).

## Left for later

- **Edit greyed out with why** ("Bo is in control", "View only in this room"), from plan 2.6: not done. A room in Driver mode still lets
  a track's or item's maker edit their own (`sync.maker_may`), so greying the whole switch would block edits that work today; the room's
  refusals still come per edit, with their reason, as before. Doing it right needs a per-room "may edit anything at all" answer from
  `sync.authority` + `maker_may` in the daw header.
- `lib/webmixer.lua` doesn't refuse a move without the flag (the page sends it; the phone app's mixer moves don't, so it can't be required
  there yet). One line once Phase 11 brings the phone app into the shell.
- `lib/webui/draw.js` (rt-draw's drawing layer) anchors a drawing to a track with the page's base lane height, not the track's own
  (`ssDaw.laneH(i)` now exists for it); drawings on a tall track are placed at its top, scaled as a normal one. Not Phase 7's file.
- The Sheet stays editable in View: it's typed text saved as you type, not REAPER's project, and the phone's Sheet edits the same way.
  Say if it should follow the switch (a readOnly on its boxes).
- REAPER-likeness not done: take lanes when REAPER shows all takes (only the active take is drawn), the non-playing fixed lanes when a
  track's lanes are expanded, REAPER's own fade curves (drawn straight), the time formats samples / h:m:s:f / absolute frames shown as
  m:ss, the edit cursor's and selection's REAPER look, and fade handles on a lower fixed-lane row (they're found at the lane's top).
- Track heights update only at a look (the change count or every 10 s): REAPER's vertical zoom doesn't move the change count.

## Review later (security)

- The `edit: true` flag is a UI safety against accidental edits, not an authorisation: anyone who can post to `api/action` can set it,
  exactly as before. Claims, grants and `sync.authority` still decide every edit.
- `dawview.ruler_mode` calls `format_timestr_pos` seven times a look (cheap; formats the project in front).
