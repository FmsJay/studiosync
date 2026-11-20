# History page: the song's life as a time lapse (rt-timelapse, 2026-11-20; Lua tests and a stand-in server in Chromium only, not run in REAPER yet)

James: "Visualizer of project progress and changes over time ... ways to see different types of changes and watch it as a time lapse ...
like the maps and other data you can see progress at the end of a game of Civ."

## What it is
- **Page:** the web UI's **History** tab (`lib/webui/history.js`, `history.css`; `lib/webhistory.lua`, ticked from `lib/webui.lua`). Read only:
  the page sends nothing but "I'm looking" and nothing in it changes the project.
- **The time lapse:** an arrange view drawn as it stood at each point: tracks appear (their name lights up), items land, move and get
  trimmed (each change lit for a moment), deleted items fade out as dashed ghosts, regions form along the ruler, a mix move (track
  settings, plug-ins, automation, sends) flashes a bar by the track's name. Lanes are in today's track order (deleted tracks where they
  first came); the time axis is fixed to the longest the song ever got, so you watch it fill out.
- **Controls:** Play / Pause (from the start again at the end), speed 0.5x to 16x (8 frames a second at 1x: a few hundred frames, under a
  minute at 1x), a scrubber, a strip under it showing how busy each frame was (sessions shaded in turn, saved versions as ticks, click or
  drag to jump), the sessions as buttons (date, length, changes, who; a click jumps there and plays). Keyboard on the view: Space plays,
  arrows step (Shift: 10).
- **Colour:** by person (the band's colours from `people.colours`, as the Song page) or by kind: takes, edits, mix moves, MIDI, tempo and
  markers (the first five slots of a fixed categorical order, stepped for light and dark). The legend chips are the filters: press one to
  hide that person or kind (their items go faint, their flashes stop); the other set's filters stay.
- **Summary (end of game):** tiles (sessions, days worked on, changes, takes, tracks now, length now); Who did what (each person's changes
  as a bar split by kind); Takes per person; Busiest days (a column a day worked on, the top three labelled; click a day to jump to its
  end); Song length and Tracks over the song's working time (two charts, one scale each; hover shows the value and when, click jumps);
  everything as a table under "Show as a table".

## How it's built
- **Topic `hist`**, built only while a page says it's looking (`{topic:"history", want}` every 10 s, 30 s grace), every 10 s at most and
  only when something new was read, published only when it changed. Source: `recall.warm` / `recall.read_so_far` (the same cache the Song
  page's History and the panel's Restore page use) and `recall.list` (saved versions). Nothing new is recorded.
- **Frames:** the events are replayed server side into at most 360 frames; each carries only what changed in it: items set
  (`[item#, track#, pos, len, person#, kind#]`, the last state in that frame), items gone, tracks added / gone, track-level changes
  (`[track#, person#, kind#]`), regions when they changed. A frame holds `per` changes (more for a long history) and never runs across a
  session (20 minutes quiet, as recaps count them) while sessions are under half the frames. The page replays the frames itself, so the
  song length, track and item counts per frame are worked out in the browser.
- **Item lengths:** an item event carries its position but not its length. It's read from the event file's text (the item chunk's
  `LENGTH`, a plain match, no JSON decode), a few files a tick within 4 ms, each once (kept beside recall's cache, weakly, so it goes when
  recall prunes). Only a new item's file is decoded, to tell a take: a take is a new item whose take is named as a recording (REAPER's own
  recorded-file name, or a smart take name: `lib/recap.lua`'s rule, reused). A MIDI item's change that doesn't move or trim it counts as
  a MIDI edit. Until a length is read the item shows its last known length (the page says lengths are still being read).
- **Kinds:** take (new recorded item); edit (items added, moved, trimmed, split, deleted; tracks added or removed; pre-mirror take
  edits); mix move (track settings, plug-ins, automation, sends, groups); MIDI (MIDI items made or their notes edited); tempo and markers
  (timeline and insert/remove time). Handovers, Play/Stop together, likes and `auto` events are left out; notes are counted per person
  (summary table) but not drawn.
- **Times:** stamps turned to real UTC seconds by date arithmetic (`webhistory.epoch`; `band.iso_time` is only right for differences);
  busiest days by this computer's local date.
- **Size and cost** (generated history, tests): 5,785 events, 4 people, 16 sessions: 344 frames, 108 KB, built in 0.08 s (lupa). The
  stand-in's 8,000 events, 5 people, 20 sessions: 138 KB. Build cost grows with the event count (a sort and one pass), every 10 s at most
  and only while History is open and new events arrive.

## Hearing the song as it was (designed, not built)
The history doesn't keep anything a browser can play: events keep each object's state (item chunks pointing at the room's shared media,
track chunks with their plug-ins), and saved versions keep which takes play where, but hearing them needs REAPER to run the plug-ins and
instruments. Design:
1. A **Hear it then** button on the History page at the current frame (and on each saved version) sends `{topic:"history", hear:{t}}`.
2. Live sync builds that moment's project as a **copy**, never the live one: the room's events up to `t` through `mirror.plan_restore`
   (what Restore already uses to go back to a moment), applied to a saved copy of the project (as `lib/bgrender.lua` saves its copies).
3. A **background REAPER** (`bgrender`'s hidden `-renderproject` job) renders a low-bitrate preview of the whole song (or the region
   under the frame) to `<room>/previews/<event id>.ogg`, one writer, kept a few (say 10) and trimmed. A job at a time, behind prints.
4. The page gets the file through the server's existing `GET /api/file?id=` route (Lua names each file, the server never picks a path),
   plays it in an `<audio>` element, and the time lapse follows the audio's position.
- Costs and limits: a render takes a while on a big song (bgrender's own time limit); plug-ins missing on this computer render silent
  (say so); media not here yet can't be heard. Permissions: rendering reads only, but a phone with the studio's token could start renders,
  so it should be rate limited and allowed only to people who may restore (`groups.may_manage` or the room's rule).

## Not yet
- Takes recorded before mirror sync (the old take manifests in `takes/`) aren't read: only events. Pre-mirror item edits are drawn
  keyed by take id.
- Items hidden by fixed lanes, lane switches and comping aren't drawn differently; take switches inside an item count as edits.
- Markers (not regions), tempo changes and item colours aren't drawn; items are coloured by who / what touched them last.
- A track moved to another place shows in today's order all the way through.
- Over 180 sessions (half the frames), frames run across sessions.
- Saved versions are ticks on the strip only (no "what changed since" here: the Song page's History has that).

## Tests
- `tests/test_0_60_rt_history.lua`: exact UTC times; an item's length, MIDI-ness and take-ness from its event file's text (a changed
  item never decoded); a generated, shuffled history of 5,785 events by four people over 16 sessions replayed into at most 360 frames that
  end exactly at the final arrangement (tracks, items, positions, lengths, regions); the summary (takes per person, every change credited,
  days add up, notes); size under 400 KB and build time; a short history (a frame per change, sessions, MIDI edits in place, deletes);
  the tick (nothing while nobody looks, lengths read a few a tick and each once, rebuilt once they're in, nothing rebuilt when nothing's
  new, stops when the page says so); the page's wiring, and that the page only ever sends `want` and the module calls nothing that
  changes REAPER.
- Stand-in server (Python + lupa running the real `webhistory.build` over a generated 8,000-event, five-person, 20-session history) in
  the desktop app's Chromium pane: the tab, play/pause, scrubbing, sessions strip following, colour by kind, a kind filter, phone width
  (375 px, no sideways scroll), light and dark, an empty history; no console errors; the server saw only `{topic:"history", want:true}`.

## Check in REAPER
1. Open the web UI (http://127.0.0.1:47281/) on a real song with a long history: History tab. It says it's reading, then fills in; item
   lengths fill in within half a minute or so (watch the line under the title).
2. Press Play: tracks appear in the order they were made, takes land on the right tracks at the right places, moves and trims follow;
   regions match the song's. The last frame should look like the song's arrangement now (fixed-lane songs: see "Not yet").
3. Colour by person matches the Song page's colours; By kind: a session of recording is mostly blue, a mix session aqua.
4. Summary: takes per person look right against who recorded what; busiest days match your memory of the sessions.
5. Tick cost with History open on the biggest song (tests/reaper/rt_perf.lua): the build every 10 s while events arrive.
6. A phone on the studio's link: the tab, play, scrub, the summary.

## Review later (security)
- The page is read only and sends only `want`; `webhistory.action` ignores anything else. `hist` carries the room's track names, people
  and session times to anyone with the web token (as the Song page's History does).
- Event files are read raw for `LENGTH` (`band.read`) and only a new item's is JSON-decoded; a huge event file is read whole once
  (recall already reads every event once). No size cap of its own.
- The "hear it then" design would let a token holder start renders: rate limit and permission-check it when built.
