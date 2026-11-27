# rt-ui3: the History tab (Phase 3 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave A" → Phase 3, with 2.5 (History and Restore as one tab), 5.2 (History playback in REAPER)
and James's decisions of 2026-11-27 (a phone may restore with an in-page confirm; History playback through REAPER with SWS by default; Mixes
under History). Findings served (`docs/rt/findings-2026-11-27.md`): item 7 ("History and Restore become one tab, with playback as a sub-tab")
and the question "Can History playback be viewed in REAPER itself?" (answered below).

## What was built

History now has all four sub-tabs: **Changes · Versions · Playback · Mixes**. It opens on Changes, the first one, as tabs.js does for
every tab.

- **Changes** (`lib/webrestore.lua`, page in `lib/webui/history.js`): every change, newest first, one row per act, with the panel's
  filters (person, kind, track, words) and Clear filters. Open a row to get **Go to it** (this computer only), **Undo this change**,
  **Restore the whole project to here** (only the person in control) and **Restore chosen tracks to here…** (tick the tracks, then
  Check what changes). Deletes show in red and things brought back in green, as on the panel. The newest 300 that match are sent; the page
  says how many more matched.
- **Versions** (same module and page): Save this version (a name, Save permanently), the saved versions (Restore the whole project or chosen
  tracks to one; one older than everything in History is greyed, as on the panel), **Open it as it was before StudioSync** (this computer only),
  and **Kept automation** (Put mine back, Let it go) while any is waiting.
- **Playback** (`lib/histhear.lua`, `lib/webui/histhear.js`): what was there (the time lapse, Listen to this point, Compare with now, Restore
  this point), plus:
  - **Play through REAPER**, a checkbox that is on by default when SWS is installed and the page is on this computer. The preview plays through
    SWS's preview player (`CF_CreatePreview` and the other `CF_Preview_*` calls), so the sound comes out of REAPER's own output (your audio
    interface). The page gets its own Play/Pause, a scrubber and the time. A/B switches at the same place, and the time lapse follows the sound.
    Untick it to go back to the web view's own player. The setting is kept per browser.
  - **Open this point in REAPER**: opens the point as a project of its own in a new tab (see the answer below).
- **Mixes** (`lib/webmixes.lua`, page in `lib/webui/history.js`): Render current mix, Export stems and Dry stems (this computer only: they open
  REAPER's Render window). On the idle computers: Render stems for each track or each folder, Render mix on the hub, Time selection only, with the
  bounce line from `lib/bounces.lua`. Credits draft (written from any device, opened only here). Save as studio template. Save a copy outside the
  studio (this computer only: it opens a folder picker), with WAV files or not. **Compare two mixes (A/B)**: two mixes played at the same loudness
  (-16 LUFS, as the panel does), switching at the same place, through REAPER (this computer only, needs SWS). Below that, every mix and every stems
  folder, with who made it and when.

### How it fits together

- All of History's actions use the existing `history` action topic. `lib/webhistory.lua` sends `{ changes = … }` to webrestore,
  `{ mixes = … }` to webmixes, and hear, restore, rplay, rstop and open to histhear. It works out `here` once
  (`StudioSync_WebUIPollHere`: whether the page is on this computer). webhistory's tick runs webrestore's and webmixes' ticks.
  **So `lib/webui.lua` and `lib/webui/index.html` needed no change**: no ACTIONS line, no tick line and no new file to load. The new page code
  sits in the existing `history.js` and `histhear.js`, and the new styles at the end of `history.css`.
- New topics: `hchanges` (built while a page shows Changes or Versions: every 4 s, and straight after a filter change or an action),
  `hmixes` (while Mixes shows: every 5 s, and on every tick while A/B is playing). `hhear` gained `rp` (the REAPER player: key, pos, len, on)
  and `sws`.
- Restores and undos call the panel's own functions (`page_restore`'s `plan_for`, `restore_whole`, `restore_tracks` and `undo_change`, through
  its `R.test` table set up for this tick's project, the same way `tests/test_0_60_rt_histhear_panel.lua` uses them). They do exactly what the
  panel's buttons do, under the same rules. `lib/page_restore.lua`, `mirror`, `sync` and `recall` are unchanged. The panel's Restore and Mixes
  pages are unchanged.
- **Confirms, phone included.** Nothing that changes the project, or can't be taken back (Undo, both kinds of Restore, Let it go), happens on a
  single message. The page asks first. Live sync replies with what would change: `histhear.describe`'s words, the tempo map, and whose later
  changes an undo also takes back. It sends those words with an id, and the page shows them in its own box under the row. Only "Yes, do it"
  sends `{ yes = <id>, confirm = true }`, and Live sync does it only if the id is the one it gave out, less than 120 s ago, used once, and the
  person is still in control for a whole-project restore. A phone works the same way. The older "Restore this point" on Playback already
  worked like this (an ask, then a yes with the id).
- **This computer only**: Go to it, Open it as it was before StudioSync, Play through REAPER, Open this point in REAPER, Render, stems,
  Save a copy outside and A/B. All of these open a REAPER window or a dialog, or play out of the studio computer's speakers. The page hides
  them on another device, and Live sync refuses them if a remote page asks anyway.
- REAPER and SWS calls used, each checked against the API index (the index was stale only because of the newer StudioSync DLL, so
  I read the index file directly): `CF_CreatePreview`, `CF_Preview_Play`, `CF_Preview_Stop` (stops *and destroys*), `CF_Preview_SetValue`,
  `CF_Preview_GetValue` (D_POSITION), `PCM_Source_CreateFromFile`, `PCM_Source_Destroy` (only after the preview is gone: SWS doesn't own the
  source), `GetMediaSourceLength`, `CalculateNormalization`, `Main_OnCommand(40859)` (New project tab), `Main_openProject`,
  `AddRemoveReaScript`. Every SWS call is behind `reaper.CF_CreatePreview ~= nil`; without SWS the page says so and nothing is called.

## Can History playback be viewed in REAPER itself?

**Yes, in two ways, and both are now built.**

1. **Hear it through REAPER.** On Playback, "Play through REAPER" (on by default with SWS) plays the point's preview through SWS's preview player,
   so it comes out of REAPER's own output and audio interface, not the web view's default device. That was the real problem with the History tab
   in REAPER's docked view: the pictures were already in REAPER, but the sound went to the wrong speakers on an ASIO setup. Nothing in the
   project changes and nothing is synced.
2. **See it in REAPER's own arrange and mixer.** "Open this point in REAPER" rebuilds the project as it was at that point, using the same rebuild
   the preview render uses (`histhear.rebuild`, and its prep for lanes, picked takes, track settings and the tempo map then). It saves the result
   as `<project> (as it was <date> <time>, not synced).rpp` in this computer's temp folder and opens it in a new tab. The copy has StudioSync's
   project state removed (`sessionfile.plain`), so Live sync doesn't run in it and nothing in it reaches anyone. You hear it through your own
   plug-ins and monitoring. Close the tab when you're done.

What still isn't possible: replaying the animated time lapse on REAPER's own arrange view. REAPER draws its arrange, and a script can't replay
history on it without changing the project. Opening the point as its own tab is the REAPER-native equivalent.

## Checks for James (in REAPER, after a release with these files)

1. With a studio project open, open the web view and go to History. It opens on **Changes** with the newest changes. Pick a person, then a kind:
   the list narrows. Clear filters brings everything back.
2. Click your own recent change, then **Undo this change**. A box under it explains what will happen. **Not now** does nothing. Try again and
   press **Yes, do it**: it's undone and the others get it. Then click the undo's own row and undo that, which brings the change back.
3. While you're in control, use **Restore the whole project to here** on an older change: the box says what changes, and Yes does it. Then
   hand over control: the button greys out.
4. **Restore chosen tracks to here…**: tick one track, then Check what changes, then Yes. Only that track goes back.
5. **Versions**: save a version with a name, then save another with Save permanently. Both are listed (the second says "(kept)"). Restore
   to one. On a project published before StudioSync, **Open it as it was before StudioSync** opens a new tab.
6. **Playback** with SWS installed: "Play through REAPER" is ticked. Listen to a point, then press Play: the sound comes out of your audio
   interface. Drag the scrubber, and switch A/B while it plays: it stays at the same place. Untick it to get the web player back.
7. **Open this point in REAPER**: a new tab named "… (as it was …, not synced)" opens, looking like it did then. Change something in it:
   nothing goes to the others, and Live sync stays off in that tab. Close it.
8. **Mixes**: Render current mix opens the Render window as the panel's button does. Export stems and Dry stems work the same way. Run
   Render stems: each track on the idle computers, and progress shows. Credits draft opens credits.txt. Save as studio template (with a name)
   shows up in New from template. Save a copy outside opens the folder picker. A/B with two mixes: Play A, then Play B, switching at the
   same place and the same loudness.
9. **On the phone** (the phone link): History > Changes shows the list. Undo or Restore shows the same box and Yes works. There's no Go to it,
   no Open it as it was before StudioSync, no Play through REAPER and no Open in REAPER. Mixes has no Render, stems, copy or A/B, but the idle
   computers, credits and template are there.
10. The panel's Restore and Mixes pages are unchanged.

## Tests

- `tests/test_0_60_rt_ui3.lua` (in `tests/run.py`): the rows and filters (one row per act, newest first, the cap, who/kind/track/words, prints left
  out), where a saved version stands, undo's words. The ask → yes rule: refused without `confirm`, with another id, after 120 s, or a second
  time; done with the id and confirm, from a phone too. A whole-project restore needs control both at the ask and at the yes. Track lists are
  checked, a saved version must be in the list, and one older than History is refused. Go to it and Open as before are this computer only.
  Save cleans its name, the topic is built only while someone looks, and Let it go asks first. For Mixes: the lists, files picked only from
  the list, what's this-computer-only, the template name, credits opened only here, and A/B at the common loudness switching at the same
  place. For the REAPER player: refused from another device, playing from the asked place, end-of-file handling, Stop keeping the place,
  another song clearing it, and no SWS. Also the page-side text checks.
- `tests/rt_ui3_browser.mjs` (by hand: `node tests/rt_ui3_browser.mjs`; needs Chrome or Edge; uses `tests/rt_ui1_browser.mjs`'s harness): on
  this computer, on another device and on a phone, against stand-in topics. Checks the four sub-tabs (none "coming"), that History opens on
  Changes, the rows (names as text), the filter going out, Undo and Restore asking first, the confirm showing Live sync's words, Yes sending
  the id with confirm and Not now sending nothing, chosen tracks, not-in-control, the note row, Versions (save, before, restore, old,
  kept), Mixes (A/B, render, idle computers, template), Playback (Play through REAPER on by default, Play, Pause and the time, Open this
  point, switching it off), another device (none of the this-computer-only buttons), the phone's confirm, no sideways scroll, and no page errors.
- `tests/rt_ui1_browser.mjs`: updated for the built History. It now opens on Changes and all four subs are built. Its "coming" check moved
  to Session > Rooms.

## Left for later

- **Open in a room** and **Fork from here** (panel Restore) aren't on Changes yet: they make rooms, which belongs with Phase 6's Rooms
  (`lib/webrooms.lua`). The panel still has both.
- The panel's "Since you were last here" filter and its grouping by person (the web list is flat, one row per act), and the session recap
  at the top of Restore.
- The panel's "Review" section in Mixes (a mix for someone outside the studio, and their comments). The plan merges it with listening
  links in Studio > People.
- A/B from another device through the web player. It would need each mix offered through `/api/file`, and mixes are large WAVs. For now
  the page says to compare on the studio computer.
- The tab opened by "Open this point in REAPER" has no Close button on the page: while it's in front, no Live sync answers the page. Phase 2's
  Autostart answering could add one.
- Rendering, Export stems and Save a copy outside open REAPER dialogs from Live sync's tick. Like the panel's, those dialogs block every
  script while they're open.

## Shared files

- `lib/webui.lua`, `lib/webui/index.html`: **not changed** (see "How it fits together").
- `tests/rt_ui1_browser.mjs` (rt-ui1's test): the History lines changed, as described under Tests.
- `tests/test_0_60_rt_history.lua`: its "the page only says it's looking" check now reads only the time lapse's part of `history.js`. The
  new part does send changes, but only after the ask and the confirm.
- `lib/histhear.lua`: `start` now shares its copy-building with Open this point (`copy_at`), with no change in behaviour. `histhear.action`
  takes `here`. `histhear.track_names` is exposed.

## Review later (security)

- Every restore and undo needs a server-made, single-use id that expires after 120 s, plus `confirm = true`. The page alone can't do one in a
  single message, and a stale page can't replay one. The rules (whole project: in control only; tracks: each object's own) are checked again
  at the yes.
- Files named by a page are only ever matched against the server's own listing: mixes for A/B, saved versions by file name, kept
  automation by file name. Track ids must match `^T%-[%w%-_]+$`, at most 200 of them. A template name is cleaned (`webui.clean_text`) and
  capped at 80, and `extras.save_template` cleans it again for the file name. A saved version's label is cleaned and capped.
- Whatever opens a window, a dialog or a tab, or plays sound, on this computer is refused unless `StudioSync_WebUIPollHere` says the page is
  on this computer.
- The "Open this point" copy is written to this computer's temp folder with StudioSync's project state removed, so it can't become a session
  tab. It still carries the objects' `band_oid` markers, like the preview's copy does. If someone later opened it with Live sync by hand, the
  tracks would be recognised. Worth a look when the security review comes.
