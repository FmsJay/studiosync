# Song history playback: hear it as it was, A/B, restore (rt-history, 2026-11-20; Lua tests and a stand-in server in Chromium only, not run in REAPER yet)

Roadmap item 12: "Scrub through how the song evolved, change by change, and restore any point." The History page's time lapse
(docs/rt/rt-timelapse.md) is the scrubber; this adds a **Hear it as it was** panel under it.

## How to use it
On the web UI's **History** tab, move the time lapse to a point (scrubber, strip, a session button), then:
- **Listen to this point**: a background REAPER renders the song as it stood then and it plays in the page. The status line says which
  pass it's on and for how long; **Cancel** stops it. A preview made once is kept (10 per song and room), so the same point plays at once
  the next time.
- **Compare with now**: renders today's song too; **A · Then** / **B · Now** switch between the two at the same place, playing or not.
- **Restore this point…**: the whole song (driver only, as on the panel) or ticked tracks. **Check what changes** says, in words, what
  would come back, go and change (and which tracks); **Restore now** does it. It's a new change everyone gets; today's version stays in
  History.

## How it's built
- **`lib/histhear.lua` (new)**, reached through the History page's own topic: `lib/webhistory.lua` forwards `{topic:"history", hear |
  cancel | restore}` to it and calls `histhear.tick` first in its tick. It publishes topic `hhear`: `then` / `now` (state, pass, seconds,
  file id, why, recordings missing), `ask` (a restore's words and id), `said`, `tracks` (oid, name), `driver`.
- **The copy, never the open project**: `band.save_copy` (Main_SaveProjectEx options 0: a copy, the project not renamed, its changed mark
  kept, as prints and bounces do) into `<temp>/bandsync-render/hear-<id>/`, then **`histhear.rebuild`** (pure) rewrites its text to the point
  from `mirror.plan_restore`'s plan (the Restore page's own):
  - tracks made since go, deleted ones come back under the track they sat under (a new GUID), this computer's own tracks (click, talkback,
    kept as yours, live views) go;
  - every `AUXRECV` is tied to its source track first and renumbered after tracks come and go (one from a track not there goes, with its
    envelopes);
  - plug-ins (`<FXCHAIN>`, the master's `<MASTERFXLIST>`), automation, sends and groups through `mirror.splice_parts`;
  - items as History has them (`mirror.only_shared` + `resolve_media`, as `mirror.apply`), made-since ones out;
  - an object already at that version here (`mirror.known`) is left as it is and its state never read (History's states are read lazily
    from their files);
  - StudioSync's own `<EXTSTATE BANDSYNC*>` blocks go.
- **What a chunk can't say** goes in the job's `prep.lua` (`histhear.prep`, values only as Lua literals): each restored track's settings
  (mirror's TRACK_MORE/TRACK_MIX lists, volume, pan, mute, phase, folder depth, fixed lanes and which play), each item's lane and picked
  take (counted past prints, as `mirror.pick_take`), and the render: master mix, whole project, Opus 48 kHz with a FLAC beside it (the pass
  script compares FLAC sizes), no normalizing. **bgrender's pass script now runs a job's `prep.lua` once before its first render** (small
  additive change in `lib/bgrender.lua`); prints and bounces have none and are unchanged.
- **The job**: `bgrender.launch_job` (the hidden REAPER on its own desktop / background app), 2 passes at most (`maxpasses.txt`), its limit
  `bg.time_limit(length x 2)`. `poll` as `bounces.lua`: `passes.txt` done, `pid.txt` failed, `done.txt` quit without a print, past its limit
  ended. One render at a time ("then" first, then "now"), at most one start every 3 s, never started while recording; a new point ends the
  render going.
- **Kept**: `<temp>/bandsync-hear/<fnv of studio|song|room>/<32-hex id>.opus` with an `index.json` (newest last, 10 kept). Not in the
  studio folder (Syncthing would carry it) and not in bgrender's folder (its launcher tidies that). Offered to pages with
  `StudioSync_WebUIOffer(id, path)`, the old offer of that slot withdrawn; played from `GET /api/file?id=`.
- **Restore**: `{restore:{t, tracks?}}` builds the plan (`histhear.scope` for chosen tracks: as `mirror.selection_scope`, from oids) and
  publishes `ask` with `histhear.describe`'s words and a random id (good for 120 s). `{restore:{id, yes:true}}` then rebuilds the plan from
  fresh History and runs `sync.restore_timeline` (whole song only) and `mirror.revert` with the panel's options plus `at_once = true` (one
  REAPER undo point, "StudioSync: go back") and `act`. **`mirror.revert` now puts `act = opts.act` on every event it sends** (three
  fields, small additive change in `lib/mirror.lua`), so `mirror.same_moment` shows the restore as one act and **Undo this change** on any
  row of it takes all of it back. The whole song needs the driver (checked at the ask and at the yes); chosen tracks go through revert's
  per-object rules as always.
- **Page**: `lib/webui/histhear.js` (new, loaded after history.js), styles appended to `history.css`. `history.js` exposes
  `window.ssHistory.point()` and fires `ss-hist-point`; its note now says "Watching changes nothing; Restore below asks first."

## Tests
`tests/test_0_60_rt_histhear.lua` (in `python tests/run.py`):
1. **The copy matches the known state at the point** (a stand-in history in the real event formats and a stand-in project in REAPER's
   text): tracks then (made-since out, deleted back under its track with a new GUID, local track out), a moved item where it was with its
   media path here, deleted items back (on a deleted track too), made-since items out, plug-ins then, automation gone since back, sends
   then with the gone source's send and envelope dropped, unchanged objects' states never read, blocks balanced, BANDSYNC state out, other
   extensions' state kept; "now" (empty plan) renumbers sends past a dropped local track; the master's chain then.
2. **prep.lua** run against a stand-in REAPER: render settings, the restored track's settings and lanes, an item's lane and take past a
   print, untouched tracks and items not touched; a hostile track name stays a string.
3. **Render lifecycle with a stand-in bgrender and disk**: start (copy saved with options 0, rebuilt job, prep, 2 passes, limit by length),
   progress, one at a time, done -> kept and offered (32 hex), job folder tidied and its REAPER ended, then the A/B's now, cached second
   time, a point before History, cancel, a new point replacing the running one, didn't start / quit without a print / stuck past its
   limit, waiting while recording, the kept list. **Nothing in the open project touched**: every reaper.* call recorded, none is a
   Set/Delete/Insert/Add/Undo/Main_On/Mark/Split/Move, and Main_SaveProjectEx runs once a render.
4. **Restore**: the ask's words (counts, track names, Undo), a wrong id and a reused id do nothing, yes runs revert with `at_once` and an
   `act` and the timeline, chosen tracks only touch theirs (and not the timeline), an ask runs out, bad track lists refused, not the
   driver: whole song refused, chosen tracks asked. **One undoable act**: restore events with one `act` across seconds and kinds are one
   row (`mirror.same_moment`), and `mirror.plan_undo_moment` takes all of it back to before; revert carries `act` in all three events.
5. The page's wiring.

`test_0_60_rt_history.lua` stubs histhear (its stand-in REAPER's file listing never ends). `python tests/run.py --no-luals`: my tests and
history/bgrender/bounces pass; at the time of writing the run had 3 fails that aren't mine: `test_0_60_rt_webui` and `test_0_60_rt_phonefix`
from another agent's uncommitted `webdraw` tick in `lib/webui.lua` (`sync.room_dir` nil in their stand-in), and `test_0_60_rt_bigproj`'s
strict timing (a different mirror look over budget each run while six agents share the machine).

**Stand-in server in Chromium** (Python + lupa running the real `webhistory.build`; `hhear` driven as histhear would; previews are sine
WAVs served as octet-stream, as the extension serves .opus): Listen -> rendering, pass 1/2, 2/2 -> ready and playing; Compare with now; A/B
switch kept the place (2.5 s) and swapped players; Restore: Check what changes -> words -> Restore now -> said; actions seen by the server
were exactly `hear{t}`, `hear{now}`, `restore{t}`, `restore{id,yes}`; Cancel; phone width 375 px with no sideways scroll; light and dark; no
console errors.

## Check in REAPER
1. Web UI, History tab on a song with a few sessions: scrub back to an earlier session, **Listen to this point**. Health/Task Manager: a
   hidden `reaper.exe` appears and goes; `%TEMP%\bandsync-render\hear-*\` has `job.rpp`, `prep.lua`, then `preview.opus`. It plays in the
   page, and sounds like the song then (a track added later is absent, a take moved later is where it was, a plug-in swapped later is the
   old one). The open project shows no change, no "modified" star appears, its file name is unchanged, Undo history unchanged.
2. Open `%TEMP%\bandsync-render\hear-*\job.rpp` (copy it first; it's deleted when done) in a new tab if anything sounds wrong: check a
   fixed-lanes track's lanes and which play, and a comp item's picked take (these are set by prep.lua through the API).
3. **Compare with now**: both render one after the other; A/B switches at the same spot.
4. Press Listen on the same point again: plays at once (cached). Cancel while rendering: the hidden REAPER goes.
5. A song with a missing plug-in or media not synced yet: the status says recordings are missing; the render finishes (silent there).
6. **Restore this point… > The whole song** as driver: Check what changes, read the words, Restore now. Everyone gets it; History shows
   one act; REAPER's Undo has one "StudioSync: go back"; **Undo this change** on one of the restored rows (panel Restore page) brings today's
   version back for everyone.
7. Not driving: The whole song is greyed out; chosen tracks restore only those tracks.
8. A phone on the studio link: Listen and A/B play (Safari: check it plays an Ogg Opus served as octet-stream).
9. Mac: the background REAPER (helpers) renders the preview the same way.

## Not done / limits
- The tempo map and markers in the preview are today's (the restore itself does put the timeline back, as the panel does). Items keep their
  positions in seconds, so a song whose tempo changed since previews with its old positions on the new grid.
- The master's automation and sends, and track order changes (a track moved since), aren't rebuilt in the preview.
- Which take or print plays is the first/picked take: `prints.choose` (wet print vs dry notes) isn't run in the copy.
- Previews are keyed by History's last entry at or before the point; "now" by the newest entry, so local edits not yet sent don't make a
  new "now" preview until something new arrives.
- The page doesn't move the time lapse with the audio's position (the design's step 4).
- Saving the copy, `recall.entries` and reading the changed objects' states run on REAPER's thread once per render (a big song: a
  moment); the rebuild is a text pass over the copy.
- `.opus` goes out as `application/octet-stream` (extension's `offer_type` knows video and images only); Chromium and Firefox sniff it.
  Adding `opus -> audio/ogg` needs an extension build.

## Review later (security)
- A web-token holder (phone, browser on the link) can start renders: rate limited (one at a time, a start per 3 s, cached), but not
  permission-checked beyond the token. Restores follow the panel's rules (driver for the whole song, revert's per-object checks) and need
  an ask id from the same server first, but act as this computer's user, like the Mixer page's edits.
- `prep.lua` is loaded by the hidden REAPER from the job folder in the per-user temp folder (same trust as job.rpp and the launcher
  scripts). Its values are literals (`%q`), tested with a hostile name.
- The rebuilt copy takes media paths only through `mirror.only_shared` + `resolve_media` (the studio's media, `..` refused), as
  `mirror.apply`.
- The restore ask id is 16 hex from `band.secret`; asks expire after 120 s and are single use.
