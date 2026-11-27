# rt-borrow: borrowing a plug-in for real, Hop deleted = stopped, dry/wet, the Try screen

Brief: `docs/rt/findings-2026-11-27.md` items 3, 8, 10, the small item "a notification when someone asks to try your VST, and a better UI on
the Try screen", and the question "is there a better/quicker way to try a VST, e.g. actually load the plug-in locally?".
Offline only: Lua tests with the stand-in REAPER and headless Chrome against a stand-in page. **Nothing was run in REAPER or on the test
computers.** No C++ changed (extension and Hop plug-in unchanged: no extension or plug-in release needed for this).

| Item | Status |
| --- | --- |
| 3. Borrow for real | Built: **Add to track** on a try puts the plug-in in the track's chain for real, played live through the existing hop from the owner's copy of the song, with the print as the fallback and the final sound |
| 8. Delete = stop | Built: deleting the StudioSync Hop from a track stops the hop exactly as Stop does, both sides; the owner deleting a try's hidden track is their Stop |
| 10. Dry/wet for everything | Removed the per-track Dry / Wet / Auto (three actions, the panel's row); kept Parts play for the whole computer; Auto now plays a part through a hop |
| Small: ask notification, Try screen | Built: an ask shows on the panel's bar and as a toast on every web page, Allow / Deny right there; the Try tab reordered and cleaned |
| Question: load it locally? | Answered below; detection of "installed here" exists and now also stops a hop whose plug-in became installed |

## 1. Borrow for real (findings 3)

James: "a way to simply add a bandmate's plug-in to the chain for processing ... borrowing someone's VST adds it to the track for real; you
hear the processing and adjust as you go. Combines with the existing VST processing (the Hop), and missing packets wouldn't be an issue."

**How to use it.** Try a bandmate's plug-in as before (Try tab, or the action "StudioSync - Try a bandmate's plug-in"); once its knobs show,
press **Add to track** (or run the action again on the track: "Add <plug-in> to the track for real"). When playback is stopped the plug-in
appears in the track's FX chain, in front of the Hop, offline on your computer (you don't have it) and loaded on theirs. Keep turning its
knobs on the Try tab; **Stop the hop** stops hearing it live (the plug-in stays in the project).

**What happens (no new mechanism: a try becomes the existing "Run plug-in on a bandmate" hop).**
1. Your computer asks the owner's for the plug-in's block (`op = "keep"`); theirs answers with the block exactly as REAPER wrote it for their
   hidden copy (`op = "kept"`), its current settings included. Only an ask of yours is answered, and only an answer to your own ask is taken.
2. Your computer checks the block (`hops.block_lines`: one plug-in of a kind a hop runs, the name you were trying, balanced, at most 48 KB;
   anything else in it, a second plug-in or a knob envelope, is left out, and its FXID dropped) and, **only while playback is stopped**, writes
   it into the track's chunk in front of the Hop (`hops.put_block`, `hops.borrow_in`; setting a chain from its chunk reloads its plug-ins).
3. The try's record becomes a hop for a plug-in of the song (`rec.borrowed`, `rec.of` = the new plug-in, a new token). The owner drops the
   try's hidden track; your computer asks them to host the song's plug-in (`borrowed = true`). Mirror sends the chain change to the band as
   **your** edit (claims and permissions as for any edit of yours); once it reaches the owner's copy, their computer hosts a copy of **their
   copy of the song's plug-in**, as "Run plug-in on a bandmate" always did, and its knobs still come to your Try tab and turn from it.
4. Knobs you turn change the owner's hidden copy at once (you hear them). When playback has been stopped for `FREEZE` (2 s) after the last
   turn, your computer asks for the block again and replaces the song's plug-in's settings (its id kept), so the project, the band and the
   print have them.

**Reliability: the design choice (the "missing packets" question).** The link can't be made lossless inside a live budget, so the final
sound
never depends on it:
- **While you play and adjust**, the hop is what it already is: the latency budget (grown automatically while stopped when a link needs more),
  a lost frame plays the dry input ("Dry when late"), held MIDI notes let go within 0.2 s (rt-hop2). A lost packet is a brief dry moment,
  never silence, never in the project.
- **The final sound is the studio's print, made on a computer that has the plug-in.** The borrowed plug-in is now in the song, so the
  existing prints (`lib/prints.lua`) apply: you lack it, so the track's parts get prints, and `prints.printer` picks a printer who has every
  plug-in (the author when they can, else someone here who can: the owner). Every print is rendered locally on that computer, never through
  the link, so packet loss can't reach it. The freeze in step 4 changes the song's settings, which changes the print's hash, so a new print
  follows on the owner's computer once the part settles: that is the "automatic print/freeze on the owner's computer when you stop".
- **Which one plays here (Auto):** while a hop runs for a plug-in, Auto counts that plug-in as here (`prints.hop_plays`), so the part plays its
  dry take through the hop and you hear your knob turns live. When the hop stops (Stop the hop, Live sync stops, the owner leaves), Auto plays
  the print again. Bandmates without the plug-in and without a hop hear the print. This also fixes a fault of the old "Run plug-in on a
  bandmate": once a print existed, Auto played it and held the track's FX off, the Hop included, so the live hop went silent.
- The try's own **Print** (rt-hopvst, rt-hop2) is unchanged: it still records the hop's output locally (wet only once the hop is warm), and is
  the way out when a plug-in's settings are too big to borrow (below).

**Limits.**
- A block over 48 KB (big synths and samplers with large states) can't be borrowed: "its settings are N KB, more than StudioSync sends in one
  go: Print it instead". `shortcut: one direct-link message (64 KB cap); upgrade by paging the block like the knob pages, or sending it as a
  file through the studio's sync, if big instruments need borrowing.`
- Between Add to track and the band's change reaching the owner's copy (their playback must be stopped and the project's tab in front for
  mirror to set a chain), the hop plays dry and Health says "waiting for the track's new plug-in to reach their copy of the project".
- Owner-side knob changes made in the plug-in's own window on the hidden copy of a borrowed plug-in aren't frozen into the song (only turns
  from your Try tab mark it for freezing).

## 2. Deleting the StudioSync Hop is stopping it (findings 8)

- **Your side** (`hops.tick`): a Hop that's gone from its track while the track's `band_local_fx` still names it (`<guid>for=hop;`) was
  deleted here by hand: `hops.stop` runs, as the Stop button does (the extension's side stopped, the owner told `op = "stop"` so their hidden
  track goes, the record, the track's real-time flag put back, `band_local_fx` cleaned, Auto rechosen), and Health and the log say "…stopped:
  its StudioSync Hop was removed from <track>". An offload's Hop deleted brings the chain back on here, as Bring back does.
- The Hop gone **and** its tag gone is still the band's chain replacing the track's (mirror empties `band_local_fx` when it sets the band's
  chain): the Hop goes back in, as before. That's how the two are told apart.
- `hops.stop` now cleans the tag even when the Hop wasn't found (it was left behind before).
- After the band replaces a chain, the song's plug-ins have new ids: a hop's record now follows its plug-in's new id (`rec.of`), so Auto and
  the freeze keep finding it (before, `hops.of_fx` from the plug-in lost it the same way).
- **The owner's side**: deleting a try's hidden track by hand is `hoptry.end_use` (their Stop: the bandmate is told, the yes goes). A lost
  "stop" message is still covered by the idle drop (30 s without the requester's audio or asks).

## 3. Dry / wet for everything (findings 10)

What existed: Settings > Options > **Parts play** (Auto / Dry / Wet, the whole computer), and per track **Dry / Wet / Auto** (the panel's
"Selected tracks play" row and the actions "StudioSync - Selected tracks play dry / wet / as chosen"), stored per track in the project.

Proposal and what was done:
- **Removed: the per-track choice.** Auto is already per track (dry where every plug-in loads, else the print). The per-track Wet mostly meant
  "I lack this track's plug-in: play the print", which Auto does; the per-track Dry meant "hear it without the missing plug-in", and a hop now
  gives you the real plug-in instead. The three actions are deleted, the panel's Dry / Wet / Auto buttons are gone (the row keeps Offload and
  "Show dry and wet takes"), `prints.track_choice` / `set_track_choice` are gone.
- **Old files:** a project saved with per-track choices (ProjExtState `BandSync plays`) has them cleared once per project at the first print
  pass (`prints.forget_track_choices`, from `prints.release_held`), and those tracks' parts chosen again, so a track left on Wet gets its FX
  back on where Auto says dry. A toolbar button or key bound to a deleted action stops working once ReaPack removes the file (an old folder
  copy still runs its own old code).
- **Kept: Parts play** (Auto default, Dry, Wet) for the whole computer: Wet still matters where a sampler's library differs between computers
  (Auto plays the notes when the plug-in loads, whatever library it has), Dry for someone deliberately hearing their own instruments.
- **Kept: prints themselves** (they're the final sound for anyone lacking a plug-in, and what borrowing relies on).
- James to confirm; reverting is putting the three files and the panel row back from 0.60.1.

## 4. The ask notification and the Try screen (small item)

- **REAPER:** Live sync puts pending asks in ExtState `try asks`; the panel's bar (beside claim asks) shows "<name> asks to try your <plug-in>
  on this computer" with **Allow** and **Deny**; the answer goes back through `try answer` and is taken at Live sync's next hop tick. The log
  line and Health's "Allow for this session" row stay.
- **Web:** every page gets the `tryask` topic (published whether or not the Try tab is open, only when it changes); `tryfx.js` shows a toast at
  the bottom of any tab with Allow / Deny per ask, gone once answered.
- **The Try tab, cleaner:** what waits on you first (Your plug-ins: asks with Allow / Deny, who's trying yours, hidden when there's none), then
  what's on your tracks (each try: Add to track, Print, Stop; each borrowed one: "in the project, played live from <name>'s computer", Stop
  the hop), then the search. Headings with nothing under them are hidden; the knob pager (`.tfnav`) has a style now.

## 5. The question: could a tried plug-in load locally?

No, not a plug-in you don't have installed and licensed. A VST/VST3/CLAP/AU is a binary that has to be installed on the computer running
it, most check a licence (iLok, a key file, an account), and StudioSync only ever carries audio, MIDI and knob values, never a plug-in's files
or licence; copying those would break the licence and usually still not run. So for a plug-in only a bandmate has, the hop (their computer
runs it) is the only live way, and the print is the way to keep its sound.

What is possible, and is now automatic:
- **If the same plug-in IS installed here, it's used here.** Detection exists: `plugins.installed()` (REAPER's own plug-in list, cached) is
  what the Try search already uses to list only plug-ins you **don't** have; `hoptry.start` now refuses a try of one that's installed here
  ("add it from REAPER's FX browser, it runs here"), in case the list on screen is stale.
- **A plug-in installed after its hop started:** for a hop on one of the song's plug-ins (Run plug-in on a bandmate, or borrowed), once it
  actually loads here (`prints.fx_here`: online, with its file) the hop stops by itself ("<plug-in> loads on this computer now, so it runs
  here") — it would otherwise be applied twice. REAPER loads a newly installed plug-in after a rescan and reopening the project (or setting
  it online).
- Quicker than now isn't possible without changing what a try is: the time to first sound is the owner's yes plus loading the plug-in there.

## Tests

- `tests/test_0_60_rt_borrow.lua` (new; the stand-in REAPER of test_0_60_rt_hoptry.lua plus track chunks, and the real `mirror.fx_blocks`):
  block checks (another plug-in refused, unbalanced, a container, too big, a second plug-in and an envelope left out, FXID dropped);
  `put_block` in front of the Hop and in place (id kept, before WAK); Hop deleted by hand on a run-on hop (stopped, owner told, extension
  stopped, tag gone, perf flag back, said, Auto rechosen) against the band replacing the chain (put back); an offload's Hop deleted (chain on
  again); a plug-in installed since (hop stops); the ask on the panel's bar (JSON, a stand-in ImGui's Allow taken at the next tick, the bar
  cleared) and on every page (`tryask` with no Try tab open); a block nobody asked for ignored; Add to track: the owner's block with its
  settings, kept while playing, in the chain once stopped (offline here, owner's settings), the record converted, the try's hidden track
  dropped, served as the song's plug-in with `borrowed`, a wait while the owner's copy lacks it, hosted from the owner's copy, knobs to the
  borrower, a turn reaching the owner's copy, the freeze only once stopped and once, the id kept; Stop the hop leaves the plug-in;
  `prints.track_plays` through a hop (not for printing); old per-track choices cleared once; the actions gone; the page's new strings.
  **Against HEAD's lib it fails** (no `hops.block_lines`).
- `tests/test_0_60_rt_hops.lua`, `tests/test_0_60_rt_hoptry.lua`, the prints tests: unchanged and passing.
- Headless Chrome (no media devices) against a stand-in `ssTabs` around the real `tryfx.js`: the toast shows the ask, Allow sends
  `{allow}`, the toast hides; a try's head has Add to track / Print / Stop, a borrowed one's Stop the hop; Add to track sends `{keep}`; Your
  plug-ins hidden with nothing in it.
- `python tests/run.py --no-luals` in a clean clone of HEAD plus these changes, also with `TZ=UTC0`: see the commit's report.
- Builds to scratch outputs only (nothing C++ changed): `extension\build_windows.cmd` with `DLL_OUT` in the scratch folder, and
  `plugin\build_windows.cmd` in the clean clone.

## Check in REAPER (two computers; desktop tries/borrows, laptop owns the plug-in)

Allow without a click is as in rt-hop2 round 2 (the laptop's own web UI over `ssh laptop`); or use the new bar/toast.
1. **Notification.** Desktop starts a try of a laptop-only plug-in. On the laptop: the panel's bar shows "Desktop-user asks to try your …"
   with Allow / Deny; any web UI tab (not Try) shows the toast. Deny once (the desktop's try ends: "… said no"), ask again, Allow from the
   toast: it loads.
2. **Add to track.** With the try running and its knobs showing, press Add to track while **playing**: nothing changes until Stop; stop: the
   plug-in appears in the desktop's chain in front of the Hop, offline, named as on the laptop. The log says "… is on <track> for real now".
   Health shows the "waiting for the track's new plug-in …" row until the laptop's copy has it (laptop stopped, tab in front), then the hop
   row green again. Check: the laptop's song track has the plug-in loaded with the knob settings the desktop had set; the laptop's old hidden
   track is gone and a new one exists.
3. **Hear it, adjust it.** Play on the desktop: the part sounds through the plug-in. Turn a knob on the Try tab: heard within ~a block.
   Stop: about 2 s later the laptop's song copy has the new value (open its window there to see), and a new print of the part is made on the
   laptop (Health / the print take's file name ends with the laptop's user).
4. **Fallback.** Stop the hop (Try tab): the desktop's part now plays the print (its active take is the wet one, the track's FX button held
   off); start Live sync again later: the hop restarts by itself and the dry take plays again. A third computer without the plug-in hears
   the print.
5. **A big plug-in.** Try one whose state is over 48 KB (a sampler with a library loaded) and press Add to track: the log says it's too big,
   nothing changes.
6. **Delete = stop.** With a try running, delete the StudioSync Hop from the desktop's track (FX chain, Remove): within a second the laptop's
   hidden track is gone, the desktop's Health says "… its StudioSync Hop was removed …", and `band_local_fx` on the track (`P_EXT`) no longer
   names it. Same with an offload's Hop: the track's own FX come back on. Then on the laptop, delete the hidden track of a try (show it in
   the TCP first): the desktop's try ends with "… stopped it".
7. **Band chain replace still re-adds.** With a run-on hop, have the laptop change that track's chain (add a ReaEQ): after mirror applies
   it on the desktop, the Hop is back in place (not stopped).
8. **Old project.** Open a project where a track was set to Wet with the old action (or set ProjExtState `BandSync plays` / <track GUID> =
   `wet` with Live sync stopped): after Live sync starts and a print pass runs, the key is gone and the track's FX button is back on where
   Auto plays dry. The panel's Advanced row no longer shows Dry / Wet / Auto.
9. **Installed since.** Install the borrowed plug-in on the desktop, rescan, reopen the project: the log says it loads here now and the hop
   stops; the part plays through the local copy.

## Files

- `lib/hops.lua`: block check and chunk put (`block_lines`, `put_block`, `borrow_in`), `stands` (S.stand), delete = stop and installed-since
  in `tick`, the freeze, `stop` cleans the tag, `forget`, `borrowed` on serve and follow, keep/kept routing, the asks tick.
- `lib/hoptry.lua`: `keep`, the keep/kept handlers, `set`/params for borrowed ones, `start` refuses one installed here, the asks on the bar
  (`asks_tick`, `asks_clear`, `bar`) and every page (`tryask`), the model's `borrowed`/`keeping`, `{keep}` from the page.
- `lib/prints.lua` (the dry/wet lib code): `hop_plays` in `track_plays`, `rechoose`, `forget_track_choices` (from `release_held`); the
  per-track choice removed.
- `lib/webui/tryfx.js`, `lib/webui/tryfx.css`: the toast, Add to track, Stop the hop, the order and hidden empty sections, `.tfnav`.
- `StudioSync - Try a bandmate's plug-in.lua`: "Add … to the track for real".
- Deleted: `StudioSync - Selected tracks play dry.lua`, `… wet.lua`, `… as chosen.lua`.
- **Shared-file edits (small):** `StudioSync - Panel.lua`: the Dry / Wet / Auto buttons removed from `ui.track_plays_row`, one line calling
  `hoptry.bar` after the claim asks bar.
- Not touched: `lib/files.txt` and `index.xml` still list the three deleted actions (regenerated at release; `tools/files_check.py` notes it
  until then). `docs/realtime-roadmap.md` still mentions them.

## Review later (security)

- **Consent widens on Add to track.** A try needs the owner's yes each Live sync session; once borrowed, the plug-in is a song plug-in and the
  owner's computer hosts it whenever the borrower runs a hop for it, and prints it, without asking (as for any song plug-in only they have).
  The owner is told once in the log when it's added. Whether Add to track should need its own yes is a product question for James.
- **A block from a bandmate goes into a track's chunk.** It's taken only over the signed direct link, only as the answer to our own ask for
  that token, at most 48 KB, and only one plug-in element of a hop's kinds with the asked-for name (anything else in it dropped, no FXID).
  Its state is opaque plug-in data as in any chain mirror receives; a JS block's path is a path in Effects, as mirror's chains carry
  (`fxfiles`/`note_theirs` checks apply when the band's chain is applied, not here).
- The owner answers `keep` only for its own serving token and only to that try's requester (`d.user == sv.user`); the answer goes to the
  requester's peer when known, else (as knob pages already do) to the room.
- The bar's answer is a local ExtState (`try answer`) written by the panel on this computer; anything that can write ExtState here could
  answer an ask, as for claim asks.

## Left

- `prints.hop_plays` reads Live sync's hop state, so a `prints.choose` run from the panel's own Lua (the Parts play radio buttons) doesn't
  see hops: a part with a live hop can switch to its print there until Live sync chooses it again (its next look of that item, or the hop's
  next start/stop). `shortcut: in-process state; publish S.stand through ExtState if the panel's choice matters.`

- Borrowing a plug-in whose state is over 48 KB (needs paging or a file).
- Owner-side window edits on a borrowed plug-in's hidden copy aren't frozen into the song.
- The REAPER facts this rests on are unchecked: `SetTrackStateChunk` with an added offline plug-in keeping its block verbatim (and the Hop's
  own state/params surviving the reload), and the order of FXID/WAK lines in a replaced block.
