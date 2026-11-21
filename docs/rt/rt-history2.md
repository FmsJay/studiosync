# History playback, faithful to its moment (rt-history2, 2026-11-21; offline tests and headless Chromium only, not run in REAPER)

`docs/rt/backlog.md` section 1 (the preview used today's tempo map and markers, didn't rebuild the master's automation or track order;
`.opus` served as octet-stream) and section 3 (the time lapse didn't follow the audio; no markers, tempo or track moves on it). Builds on
`docs/rt/rt-history.md` and `docs/rt/rt-timelapse.md`. All four items are done.

## What changed
1. **Tempo map and markers then** (`lib/histhear.lua`):
   - `histhear.timeline_at(entries, upto, o)`: the map at the point is, of the timeline changes at or before it, the one with the highest
     `order` (what the studio goes by: `sync.newest_map`), not the latest file time. None by then: the song's first map
     (`histhear.first_map`: a side room's room.json, else session.json's `first_timeline`), never session.json's own `tempo` (since 0ae5fbf
     it isn't kept up to date, so it can be any map since). History with no timeline change at all: today's stood then too. Otherwise
     unknown: left as it is, and said.
   - **Preview**: `rebuild` records the map each item put in from History was made under (`histhear.map_of`: its `tl`, else the newest map
     before it); `histhear.tempo_plan` groups them; the job's `prep.lua` puts the map then in the way live sync does (delete + add markers, as
     `band.apply_tempo`), so REAPER moves what follows the tempo exactly as when a map lands: every item held (timebase time), then for the
     copy's own items (today's map) and for each other map: that map in, those items let go, the map then in, held again; at the end each
     item's own timebase back. Then the markers then (all deleted, then's added). The page says when the map then isn't known.
   - **Restore** (whole song): puts the same map back through `sync.restore_timeline` (handed just that change, or `{first_timeline}`);
     unknown: nothing put in. Its words say "It puts the tempo map and markers back as they were too" or that they aren't kept in History.
2. **Track order and the master** (preview): tracks moved since go back, newest move first, each under the track its change says it sat
   under (`moved`, `histhear.moves_since`), as `mirror.revert` does for Restore (Restore already did this, and already restores E-MASTER).
   The master's automation then (E-MASTER) is put in the background REAPER's master chunk by prep (envelope blocks swapped, as
   `mirror.apply` splices them; the FX button from `BANDFXEN`). The master has no sends in History (only F-MASTER and E-MASTER travel), so
   there's nothing more to rebuild.
3. **`.opus` as `audio/ogg`**: one added line in `extension/webui.cpp` `offer_type`; a check in `tests/webui_test.cpp`. Needs an extension
   build (not done, no EXT_VERSION bump). An extension still sending octet-stream keeps working in Chromium (checked: the stand-in serves
   octet-stream).
4. **Time lapse** (`lib/webhistory.lua`, `lib/webui/history.js`, `lib/webui/histhear.js`): frames carry the lanes' order when it changes
   (`o`: a track sits under its change's `after`, read from the event's text like lane info; unknown: by today's place), markers (`mk`, not
   regions) and the tempo map (`tp`) when they change. A move counts as an edit; the master's parts no longer make a lane. The page orders
   lanes as they stood, draws marker flags with name plates, the tempo where it changes under the ruler, lights the ruler on a timeline
   change, and shows "Tempo 120 to 96 bpm" in the counts. While a preview plays, the lapse goes to the preview's point (today's: the last
   frame) and draws a playhead at the audio's position (`ssHistory.playhead`). **Comp areas**: the events don't hold which source lane each
   comp section came from; a comp lane's items show as the playing lane's items, as before.
- `histhear.RECIPE` 2 -> 3 (an older build's kept preview, on today's map, is never served).

## Tests
- `tests/test_0_60_rt_history2.lua` (new): which map stood then (order beats file time; first map; today; unknown; never session.json's
  own); `map_of`; the copy's track order with a move undone; master automation as mirror puts it; prep run in a stand-in background REAPER
  that moves beat-timebase items on tempo changes as REAPER does: an item made under A (120) lands at beat 8 on B (60), an unchanged item on
  today's map C goes back onto B, one made under B stays, a time-based one doesn't move, timebases restored, markers then; the master chunk
  swap; Listen's live path writes all of it into job.rpp/prep.lua; Restore puts B back, picks the higher-order map, never a stale
  session.json map, uses first_timeline; the lapse's order, markers and tempo frames; page wiring; the `offer_type` line. Each item's check
  was confirmed to fail with its change taken out (mutation runs).
- `tests/test_0_60_rt_histhear.lua`: its restore assertions now expect no timeline call when History holds no tempo change.
- `tests/webui_test.cpp`: passes (all ok) built with ports moved; in the repo copy here its link port 47391 is held by another agent's
  python process since 11-20, so the stock build fails 49 link checks on this computer for that reason only.
- Headless Chrome (`--mute-audio --disable-gpu`, fake devices) against a stand-in serving the real `webhistory.build`: 21 checks pass
  (tempo counts per frame, Listen, playhead told the point then the position going forward, lapse back to the point after scrubbing away,
  paused clears it, A/B to today goes to the last frame, only `want` and `hear` actions, 375 px no sideways scroll, dark, no console errors).
  Headless Chrome with the GPU on hung here (stuck GPU processes; the RTX fault issue).

## Check in REAPER (desktop, after deploy and an extension build)
1. A song whose tempo changed (Project settings or a tempo marker) after some takes: History, scrub to before the change, Listen. The
   kept `%TEMP%\bandsync-render\hear-*\job.rpp` (copy it while it renders) opened in a tab: the tempo map is the old one, takes sit on the
   same beats as then, markers are then's. It sounds at the old tempo.
2. Delete a take recorded before the tempo change, then preview a point after the change and before the delete: the take is on its beat.
3. Drag a track to another place, then preview a point before: the track sits where it was. Draw master volume automation, preview a
   point before it: none; after: it plays.
4. Restore the whole song to before the tempo change: the words mention the tempo map; after, the map and markers are then's for everyone;
   Undo this change brings today's back.
5. Web UI over the link on a phone (Safari): the preview plays (needs the new extension: `curl -I` on `/api/file?id=` shows `audio/ogg`).
6. History: markers and tempo appear on the ruler at their moments, a moved track changes lanes when it moved; press Listen and play: the
   lapse jumps to the point and an orange playhead follows the audio; B · Now jumps to the last frame.

## Limits
- Automation placed from History that was made under another map isn't moved onto the map then (envelopes follow tempo with each map
  change in the prep, so unchanged ones are right; a changed one made under an older map keeps its seconds' QN from today's map).
- Moves from before rt-edits carry no `moved` and aren't taken back; a restored track's own `after` is its version's.
- Restore of items made under another map than the moment's: put at their stored seconds (`mirror.revert`, not my file). Rare: a take last
  changed before a tempo change, restored to a point after it. Fix later in mirror.revert by the same map-of logic.
- Automation items (BANDAI) on the master aren't rebuilt in the preview.

## Review later (security)
- prep.lua now also carries tempo maps, markers (names via `%q`) and the master's envelope text as literals; same trust as before.
- `webhistory.detail` reads `after` from event text with a plain match (no decode).

## Left
Nothing half done. Not run: the full `tests/run.py` in a clean clone was not finished before the desktop restart (the four history test
files, compile/free-names/locals/js checks pass in the worktree).

## Round 2 (rt-p6, backlog package P6; offline tests only, not run in REAPER or a browser)
- **Master automation items in the preview** (`lib/histhear.lua`): `rebuild` keeps each automation part's `BANDAI`/`BANDAIPT` lines (`info.ai`,
  keyed by track oid, `MASTER` for the master) and prep rebuilds them through the API (the `PREP_ENV` part: `InsertAutomationItem`, rate, offset,
  baseline, amplitude, loop, mute, pool length, points of one pass; as `mirror.set_ai`). Done for track envelopes too (they lost theirs the same
  way). A plug-in parameter's items (`PARMENV:`) and a receive's (`AUX:`) stay as the copy has them.
- **Automation placed under another tempo map**: `rebuild` also records the map each automation put in was made under (`info.envplaced`);
  `histhear.tempo_plan(placed, tl, now, envplaced)` gives `envs` (key -> its map's place in `maps`). prep reads each such envelope's point times
  and item positions on the copy's map, puts the map each was made under in (the same dance as for items), reads their beats there, and after the
  map then is in for good writes every point and item at its beat (explicit times, so it does not depend on the envelope's timebase).
  The ME swap (master chunk) now runs before the tempo block, so the master's envelopes exist when it moves them.
- **Time lapse comp areas** (`lib/webui/history.js`): a lane that plays with the others (`C_LANEPLAYS` 2, already in the frames' `p`) is a
  comp: its items are drawn with a dashed outline and counted ("Comp pieces"). The events still don't say which lane each piece came from, so the
  page can't name it (decision: show what the events hold; naming the source needs a new field in the item's change, in the sync core).
- **Not mine, needs the owner of `lib/mirror.lua`** (restore, not preview): `mirror.revert` converts an item's position (and length in beats
  mode) from the map it was made under with `mirror.retime`; its rate, fades and snap offset are kept as stored, a gradual tempo change isn't
  converted, and an envelope's points (`p.t.obj == "env"`) aren't retimed at all. Proposal: in `mirror.retime` scale `D_FADEINLEN`, `D_FADEOUTLEN`
  and `D_SNAPOFFSET` by the length ratio of the item's own span between the two maps (as it does for the length), and run the same for env states.
- Tests (`tests/test_0_60_rt_history2.lua`, end of file; each fails with its change removed, tried): the items and the map kept by `rebuild`, the plan's
  `envs`, prep in a stand-in REAPER with envelopes and automation items (point 4 s on A is 8 s on B, item beats 4-8 stay beats 4-8, rebuilt rate and
  points, nothing moves for today's map), and history.js's comp wiring.
- **Check in REAPER (desktop)**: (1) a song with an automation item on the master volume (Insert automation item) drawn after a tempo change:
  History, scrub to a point after it, Listen: the kept `hear-*/job.rpp` plus the render has the item (open the copy in a tab: the master volume lane
  shows the item); before it was drawn: none. (2) Make the item under tempo A, change the tempo to B, preview a point after: the item sits on the same
  beats as it did (bar numbers), not the same seconds. (3) Fixed lanes track with a comp (two takes, comp areas across both): the time lapse at that
  moment draws the comp lane's pieces dashed and says "Comp pieces N" in the counts; a take lane that doesn't play stays hidden.

## Round 3 (rt-p1b: P6's two sync-core leftovers; offline tests only, not run in REAPER or a browser)
- **A restored item under another tempo map** (`mirror.retime`, `lib/mirror.lua`): in beats (position, length, rate) the whole item is stretched as
  REAPER stretches it when the map changes: length to the same beats (as before), and with it `SNAPOFFS` and both fades' length and auto length
  (seconds inside the item, so they stay on the same part of the audio), and every audio take's `PLAYRATE` by the inverse (the same stretch of source
  fills the new length; `SOFFS` is a source position and stays). A MIDI take's rate stays: its notes are in beats already. Beats (position only)
  moves only the position; time moves nothing. A version made under the map in place comes back byte for byte.
- **Automation restored under another map** (`mirror.retime_env`, called by `mirror.revert` for `env` changes with `opts.map_of`, so both History's
  and the Restore page's Restore): every `PT` point, each automation item's place (`POOLEDENVINST`, `BANDAI`) and, in mode 1, its length go onto their
  beats, and the item's points (`BANDAIPT`, read as project time) with them; an automation item's rate stays (its pool is in beats). Values that
  don't move keep their text.
- **A comp piece's source lane** (`mirror.comp_from`; `W.send` adds `from_lane` to an item's change, and a restored change carries its version's):
  a piece in a lane that plays which is the same file (by name), rate and alignment as an item on another lane of its track, within that item's span,
  names that lane (0-based, the lowest when several match). Not set for a source take in a lane that doesn't play, MIDI, or an item not on a lane.
  `lib/webhistory.lua` (small additive edit: `detail` reads `from_lane`, a frame's item row gets it as an 8th field only when known) and
  `lib/webui/history.js`: such an item is a comp piece (dashed, counted) even when its lane plays alone, and is labelled "from lane N" (1-based;
  "LN" when narrow). Older changes have no `from_lane`, and their pieces show as before.
- Limits: a gradual (linear) tempo change still isn't converted (left as stored); an item with timebase -1 goes by the project's timebase, not its
  track's (as before); take envelopes inside an item aren't stretched; MIDI comp pieces and pieces of a looped or rate-changed source aren't named
  unless rate and alignment match exactly (1 ms).
- Tests: `tests/test_0_60_rt_p1b.lua` (new: the stretch, the MIDI take, position only, unchanged maps; automation points, items and their points, a map
  with a change in it; comp matching cases; `detail` and the frame row; history.js wiring) and two end-to-end blocks in `tests/test_0_60_rt_edits.lua`
  (Drums' automation restored from its version made under 120 onto a project now at 60: points 0 8 16 24, and the laptop the same; a comp piece's
  sent change names lane 2, a source take and an unaligned item none). Each change was confirmed to fail its test with the change removed
  (11 mutations).
- **Check in REAPER (desktop)**:
  1. An audio take with a fade in, a fade out and a snap offset (Alt+drag in the item's top) at 120 bpm, project timebase beats (position, length,
     rate). Change the tempo to 60, then in REAPER itself note what the item looks like (length, fades, rate in Item properties). Undo the tempo change,
     delete the take, set 60 again, and Restore the take from History (a point before the delete): the length, fades, snap offset and rate match
     what REAPER did itself. If REAPER keeps fades or snap offset in seconds for that timebase, say so (one line each in `mirror.retime`).
  2. The same with a MIDI item: after the Restore its rate is still 1.0 and its notes sit on the same beats.
  3. Project timebase beats (position only): the restored take keeps its length, fades and rate; only its position moves.
  4. Draw volume automation with points on bar lines and an automation item (Insert automation item) at 120, change to 60, delete the points and
     the item, Restore that automation from History: the points and the item sit on the same bar lines as before; the item's shape plays the same
     (if its points come back shifted, `BANDAIPT` times are relative, not project time: tell me).
  5. A track in fixed lanes, two takes, comp across both (comp areas); on the other computer, History: the comp lane's pieces are dashed and read
     "from lane 2" / "from lane 3" (or "L2") on each piece, matching where REAPER drew the comp areas. A piece made before this build shows dashed
     with no label (only when its lane plays with others), as before.
