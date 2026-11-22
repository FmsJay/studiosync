# P7: wording, other scripts, ReaPersona's four changes (rt-p7)

Backlog items 1.36, 3.10 and 4.3 (section 4 question 3). Offline only; nothing was run on the test computers.

## What was built

1. **The three "Follow"s (4.3, James's default: rename).** Taken as the backlog's section-4 default.
   - The transport one is now **Play and stop together** (web Play together page, the panel's Play page, and the web page's refusal line "the web page's Play and stop together was left as it is: Real time mode is on").
   - The view one is now **Watch a bandmate** (heading and select label), each option reads **Watch <name>**, the note says "Watching <name>: ...", and the web action says "watching <name>" / "stopped watching" / "the web page's Watch was left as it is...".
   - Not renamed (other agents' or older files): `lib/jam.lua` still says "Follow each other" in its settings line and tooltip; `lib/webui/daw.js` has its own "Follow" select (P14's); `lib/follow.lua`'s comments; the panel's "Always follow the driver". The internal field names (`follow`, `mate`, `bars`) are unchanged so older pages and tests keep working.
2. **`startup.keep_open_mode` vs Autostart's copy (1.36).** `startup.lua`'s `kept_was` lived in Autostart's Lua state and was written back at the next tab change, undoing the choice Live sync's `keep_open_mode` had put in the plan. Now `startup.note` and `on_quit` read the person's choice from the plan on disk first (`held()`), so the plan file is the one copy. The shortcut noted in rt-compat §6 is gone.
3. **`PreventUIRefresh` left on (1.36).** REAPER has no call that reads the count, so a running leak can't be seen. What can be seen is a script whose text calls `PreventUIRefresh(1)` more times than `PreventUIRefresh(-1)` (comments ignored). `compat.scan_text` now reports that as a new kind `uirefresh`, with its own words and fix for Health, for every script the self-check scans (started with REAPER, or all scripts on "Check other scripts now"). It cannot catch a script that is balanced in text but throws between the two; the words say "restart REAPER" for that.
4. **ReaPersona's four changes (3.10), in `DAW/Utility/reapersona`, committed locally (5502ab4), not released, version not bumped (CHANGELOG has an "Unreleased" entry).**
   1. In a studio song (`BandSync/song` set in the project) a switch skips snap 1157, auto-crossfade 40041, crossfade on split 40912, ripple 40309-40311 and the ripple toggles 41990/41991 (added: they are what the shipped personas actually use). Put-back skips them too, and the tab the last persona changed is not visited when nothing else of the project's is left to put back there.
   2. A layer's Ctrl+Z / Ctrl+Shift+Z uses StudioSync's Undo / Redo script (found in the keymap's own `SCR` lines) when Main has no key bound there yet; otherwise as before (what Main runs, then REAPER's 40029/40030). Main section only; the MIDI editor's keys are still done by its per-key scripts (not changed).
   3. A persona's `promptendrec` line now reads "on (its box after each take pauses every script, StudioSync's sync too, until you answer)".
   4. ExtState `ReaPersona/switching` is stamped with `time_precise` when a switch starts and ends (never cleared; non-persistent). StudioSync's `compat` poll treats a stamp under 5 s old like a persona change, so a switch to the persona already in use, or changes that land passes later, are put back with the same words. Old ReaPersonas simply don't write it.

## Tests (each fails with its change removed)

- `tests/test_0_60_rt_p7.lua` (new): the wording in `play.js`, `page_play.lua`, `webpages.lua`; the plan file keeping a newer open-mode choice across a tab change and across the "no studio song left" put-back; `uirefresh` unbalanced, balanced and commented.
- `tests/test_0_60_rt_webpages.lua`: the refusal line says "Play and stop together". `tests/test_0_60_rt_follow.lua`: "watching Bo" (was "following Bo"). `tests/test_0_60_rt_compat.lua`: the `switching` stamp.
- ReaPersona `tests/test_core.lua` block 44: studio song vs not (snap left / applied), nothing kept to put back, the stamp, put-back, tab visit only when needed, Undo from the keymap and the fallback; the `promptendrec` words in block 1171. `python tools/check.py` there: all checks passed.

## REAPER checks for James

1. Play together page: "Play and stop together: press play, stop and record as usual" and, above it, "Watch a bandmate" with a "Watch <name>" list. The panel's Play page shows the same checkbox text. Pick a name: the line under says "Watching <name>..." once they send a view.
2. Open a studio song, switch ReaPersona to Pro Tools (snap on) and to Logic: Snap and auto-crossfade in the studio song stay as the band has them, and no "Not sent" line or `compat persona` Health row appears. In a plain project the same switch still sets snap.
3. With a persona that has snap, switch while a studio song is in front, then another tab, then another persona: the studio tab isn't flipped to (watch the tab bar).
4. REAPER Preferences > Startup: with a studio song open, set "Open projects on startup" to something else, wait for Health's "openmode" row, then open and close a second tab: the setting must stay held and the plan's choice (reopen.json `loadlastproj`) must stay the one you set. Quit and restart: songs reopen without boxes, your choice is back after.
5. Run a throwaway script with `reaper.PreventUIRefresh(1)` and no `-1` through Actions, then Health > Check other scripts now: a row "stops REAPER's screen redrawing" for it. Remove it afterwards.
6. After ReaPersona is released with this: Settings > shortcuts install on a computer where StudioSync's Undo script is in the Actions list but Ctrl+Z isn't bound in Main: the layer's Ctrl+Z shows StudioSync's Undo.

## Left / for James or others

- `lib/jam.lua` (not mine): its "Follow each other" strings (line 14 comment, 122 message, 445 tooltip) should be renamed to "Play and stop together" by its owner; `test_0_60_rt_jam.lua` quotes them.
- `lib/webui/daw.js` "Follow" select: P14's; section 4 question 3 would call it "Watch".
- ReaPersona: the MIDI editor's Ctrl+Z not touched; release is James's (the CHANGELOG entry needs a version).
- `lib/page_play.lua` and the web page still share one concept in two renderers; nothing was merged.

## Files

Mine: `lib/compat.lua`, `lib/startup.lua`, `lib/page_play.lua`, `lib/webpages.lua`, `lib/webui/play.js`, the four test files above, this doc. Shared files: none. ReaPersona: `ReaPersona/reapersona_core.lua`, `tests/test_core.lua`, `CHANGELOG.md`.

## Re-check results (rt-r2, 2026-11-21 evening MT / 11-22 UTC, StudioSync 0.59.49.94 from 905f000 + extension 1.0.36 on the desktop, laptop, LinuxBox and LinuxBox2; Deafen 1 everywhere, no sound tests)

- **1: pass (web).** Play page: "Play and stop together: press play, stop and record as usual"; above it "Watch a bandmate" with Watch James-Laptop /
  LinuxBox / LinuxBox2. The panel's Play page not looked at.
- 2, 3, 6: skipped (ReaPersona's commit isn't released). 4, 5: not run (Preferences and Health's button are panel/ImGui steps).
