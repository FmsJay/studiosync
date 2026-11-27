# rt-ui10a: the Plug-ins tab (Phase 10a of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md` section 6, Wave B, **Phase 10a Plug-ins**, with 2.1 (the tab's subs), 3.4 (what each device may do) and 4.4
(pop-outs), under James's decisions of 2026-11-27. Findings served (`docs/rt/findings-2026-11-27.md`): items 3 and 10 (borrow for real, dry
and wet: kept as rt-borrow built them), 4 ("Show its window" kept from rt-share), and the small items "a notification when someone asks to try
your VST, and a better UI on the Try screen" and "pop out the parts of the UI where it makes sense (chat, plug-ins, ...)".

**Tested offline only** (Lua tests with a stand-in REAPER, headless Chromium against a stand-in server). Nothing was run in REAPER or on
the test computers. No C++ changed: no extension release needed.

## What was built

The panel's **Plugins** page and **Settings > Extras** are now the Plug-ins tab's subs in the web view. The tab's four subs, all built:

| Sub | What it shows | What it does (this computer's page only) | Another device |
|---|---|---|---|
| **This project** | every plug-in the project uses (master too), its tracks, who in the studio lacks it ("everyone has it (JSFX)" for JSFX), the studio's stand-in and who set it; **Drum maps** for the tracks selected in REAPER (Written for / Played here on, how many notes move); **Plug-ins everyone has** (the FX browser folder, whose lists count) | **Apply stand-ins here**; **Set a stand-in / Change** (a search of this computer's plug-ins, "Use it"); **Remove** (asks once in the page: "Remove it? Yes"); the drum map choices; **Make a map…** (name and each kit sound's note, General MIDI to start); **Update the folder now** | the same lists, read only, with "Read only here: … set in REAPER on <computer>" |
| **Try a bandmate's** | unchanged from rt-borrow / rt-share: asks first, your tries (Add to track, Print, Show its window, Stop / Stop the hop), the search | as before | not shown (as rt-ui1 had it) |
| **Find a plug-in** | search, REAPER's categories (and Instruments), **Only what everyone has**, up to 200 rows with the count, where Add puts it (the selected track, or the master: then Only comes back on, as the panel does) | **Add** (on the selected track, its window open) | not shown (it opens a REAPER window) |
| **Plug-in pack** | the pack and extras ("n of m here"), what others in the studio have that this computer doesn't (and who), **What's in them** | **Get the pack / Get the extras** (the installer of this release in its own window, as the panel) | read only, no Get |

- **`lib/webplugins.lua`** (new): the `plugins` topic, built only while a page shows one of those subs (it says so every 10 s; built at most
  every 3 s, published only when changed), from the panel's own models: `page_plugins.used` / `translations` / `apply_here` /
  `apply_drum_track`, `plugins.lists` / `publish` / `update_folder` / `FOLDER`, `fxpick.list` / `matches` / `only_for`, `pack.status` /
  `ITEMS` / `get`, `drummap.KIT` / `GM` / `table` / `load`. The page's actions run those same functions. Every action that changes the
  project, writes a file or opens a REAPER window or the installer is **refused unless the page is on this computer**
  (`StudioSync_WebUIPollHere`), with a log line; searching (Find, the stand-in picker) is allowed anywhere. What came in is checked: a
  stand-in only for a plug-in in this project and only one installed here (by exact name), a drum map choice only a map that exists, a drum
  map's name through `band.clean` (not "gm", not a Windows reserved name, 64 characters at most) and its notes 0-127, Add only one of this
  computer's plug-ins.
- **The Try tab's gate** (`webplugins.try_refused`, called from `lib/webui.lua`): from another device, a Try ask may turn knobs, change the
  knob page or filter, search, and Allow / Deny / Stop someone using *your* plug-in (the toast on every page, rt-borrow); **try, Add to track,
  Print and Stop** are refused (they change this computer's project). Before, `hoptry.web_action` took them from any page.
- **`lib/webui/tryfx.js`**: the three subs after the Try code (registered with `ssTabs.sub`; the "coming" pages are gone); the Try toast now
  **brings the REAPER window back from the strip or the button** when a new ask arrives (`win:full`, ui-web-plan 4.5: the toast can't show in a
  strip), once per ask. Everything from a topic goes in as text.
- **`lib/webui/tryfx.css`**: their look (style.css's and pages.css's colours, light and dark), and the pop-out rule below.
- **Pop-out:** `index.html?pop=plugins` shows the whole Plug-ins tab in its own window **with its sub-tabs** (a pop-out hides sub-tabs
  otherwise); `?pop=plugins/try` is the plug-in you're trying alone (its knobs), as before. The ⋯ menu offers "Pop out this page" on every
  Plug-ins sub.

Small shared edits (additive, from HEAD):
- `lib/webui.lua`: `ACTIONS.plugins`; the `plugins` handler (with whether the page is here); the Try branch now asks
  `webplugins.try_refused` first; `webplugins.tick` beside `hoptry.web_tick`.
- `lib/webui/tabs.js`: one line adding `plugins/project`, `plugins/find`, `plugins/pack` to `POP` (not in the brief's list of shared files,
  but the ⋯ menu's pop-out has no other way in).
- `tests/rt_ui1_browser.mjs` (rt-ui1's): its `open()` now ends the last page's event streams before loading the next page. With every
  Plug-ins sub built, its "a part not built yet" step no longer runs, and then `?pop=chat` hung every time: six event streams of earlier pages
  were still open on the stand-in server, Chrome's limit for one host, so the new page's scripts never all ran. A harness fault, not the
  pages' (the same three lines are in `rt_ui10a_browser.mjs`); the other `rt_ui*_browser.mjs` copies of that harness may want them too.
- Not touched: `lib/webui/index.html` (tryfx.js and tryfx.css were already linked), `lib/page_plugins.lua`, `fxpick.lua`, `pack.lua`,
  `hoptry.lua`, `hops.lua`. The panel's Plugins page works as before.

## Checks for James (in REAPER, after a release with these files)

1. Open a studio project with plug-ins someone lacks. Web view > Plug-ins > **This project**: each plug-in with its tracks and "Missing for
   …" in amber; JSFX say "everyone has it (JSFX)". Compare with the panel's Plugins page: the same names, tracks and missing lists.
2. **Set a stand-in** on a plug-in you lack: type part of a name, Use it. The row shows "Stand-in: … (set by you)", and the panel shows it
   too. **Apply stand-ins here**: the stand-in appears right after the original on this computer only (the log says how many). **Remove**:
   the first press asks "Remove it? Yes", the second removes it (gone from the panel too).
3. Select a drum track in REAPER: **Drum maps** names it; set Written for / Played here on: the panel shows the same, and the
   "StudioSync drum map" effect appears first in the chain when they differ. **Make a map…**, give a name, Save: it's in both lists (and in
   `<studio>/drummaps`).
4. **Update the folder now**: the line says how many plug-ins everyone has and whose lists; the FX browser's "StudioSync (everyone has)" folder
   has them after reopening it.
5. **Find a plug-in**: search, pick a category, untick Only what everyone has: the rows change as in the panel's Find. Select a track and
   press Add: the plug-in is on the track and its window opens. Select the master: the line says so and Only comes back on.
6. **Plug-in pack**: the counts match the panel's Settings > Extras; Get the pack opens the installer window (cancel it).
7. On the phone link (another device): Plug-ins shows This project and Plug-in pack only, read only (no Set, Remove, Apply, Make a map,
   Update, Get), the drum map boxes shown but greyed.
8. Try notification: shrink the web view to the strip (or the button); have the laptop ask to try one of your plug-ins: the view opens
   full and the toast shows Allow / Deny.
9. ⋯ > Pop out this page on This project (or open `http://127.0.0.1:47281/?pop=plugins`): the Plug-ins tab in its own window with its four
   sub-tabs; they switch there.
10. The Try tab as in rt-borrow's checks (Add to track, Print, Show its window, Stop): unchanged from this computer. From the phone link, a
    Try page can't be opened, and a hand-sent `{"topic":"tryfx","try":…}` is refused (the log says so).

## Tests

- `tests/test_0_60_rt_ui10a.lua` (in `tests/run.py`): the models (who lacks each, JSFX, stand-ins; Find's search, category, Only and cap;
  the pack's items, Linux's none / stand-in; a drum map's name and notes); every change refused from another device with nothing run;
  each run from this computer's page through the panel's functions (the stand-in file where `page_plugins` reads it, only plug-ins in the
  project and installed here; drum maps on each selected track, only maps that exist; a map file; the folder; Get; Add on the selected track
  or the master, its window opened); the Try asks a phone may and may not send; the topic only while a page shows a sub, at most every 3 s,
  stopped when the page stops asking, a failure said; webui's wiring and the page files.
- `tests/rt_ui10a_browser.mjs` (by hand: `node tests/rt_ui10a_browser.mjs`; needs Chrome or Edge): the real index.html and page files
  against a stand-in server (rt_ui1_browser's harness): all four subs and no "coming" page in REAPER, every row and button above and the
  action each sends, the picker, Remove's in-page ask, drum maps, Make a map, the folder, Find (categories, Only, Add off with no track, the
  master), the pack (Get, others, What's in them); a new Try ask brings the window back from the strip once; `?pop=plugins` with its sub-tabs
  and switching; every Plug-ins sub poppable; another device read only; no page errors.
- `tests/test_0_60_rt_borrow.lua`, `test_0_60_rt_hoptry.lua`, `test_0_60_rt_share.lua`, `tests/rt_share_browser.mjs`,
  `tests/rt_ui1_browser.mjs`: passing (see the report for the full runs).

## Left for later

- **Set a stand-in** opens a plain search of this computer's plug-ins (the panel's right-click list), not REAPER's own Add FX window (the
  panel's left-click): that window is REAPER's and the panel's helper-track trick needs the panel's tick. Say if the web should do it too.
- Drum maps act on REAPER's selected tracks, as the panel's do; a per-track picker in the page would be friendlier.
- The Try tab from another device ("Try's knobs yes, while the computer runs it" in 3.4): the server now takes only knob turns from there,
  but the sub itself is still this-computer-only (rt-ui1's `ENVS`), so a phone can't see the knobs yet. Showing a knobs-only Try page there
  is a small follow-up in tryfx.js and tabs.js.
- Find lists at most 200 rows (with the count); the panel lists all.
- The strip's words don't mention a waiting Try ask (the window opens instead); `shell.js`'s `stripWords` could add it.

## Review later (security)

- Every change from the page is refused unless the extension says the page is on this computer; the check is the same one AI and Health
  use. A page on this computer can do what the panel can (write a stand-in or drum map file in the studio folder, add FX, run the pack's
  installer), no more.
- Values from the page: lengths capped (searches 80, map names 64), names checked against what's really installed or really a map, the map
  name cleaned to letters, digits, space, `-` and `_` (no path), notes clamped. The stand-in file name is the plug-in key's hash, as the
  panel's.
- `try_refused` is an allow list (what a phone may send to the Try tab); a new Try ask that's safe from a phone needs adding there.
