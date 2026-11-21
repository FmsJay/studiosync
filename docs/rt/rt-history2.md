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
