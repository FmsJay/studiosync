# Other scripts and extensions beside StudioSync (rt-compat)

James's request: "compatability with other scripts - make sure reapersona and other scripts won't mess with functionality of studiosync + a way to
see if it does for other scripts that might not play nice".

Built: `lib/compat.lua` (self-check, guards, detectors, Health rows), `tests/test_0_60_rt_compat.lua`. Small hooks in shared files are listed at
the end.

## 1. The audit: what other scripts can do to StudioSync, and what happens now

| Pattern | What it did to StudioSync | Now |
|---|---|---|
| **ReaPersona: persona switch** (by hand, or "switch with the project" following tabs) | A persona's "editing" options run Snap (1157) and Auto-crossfade (40041) in the project in front. Both are a studio song's shared settings (`band.FRONT_TOGGLES`, `band.PROJECT_CFG`). As driver every switch sent them to the studio; otherwise StudioSync put them back saying "only the driver changes...". With "switch with the project" on, every tab change did it, and `restore_feel` flips back to the old tab to undo its options there. | **Fixed.** `compat.timeline_veto` sees a settings-only change within 5 s of a ReaPersona persona change (ExtState `ReaPersona/style`) and puts the studio's settings back with words that say why. A Health row ("compat persona") tells the person how to stop it. |
| ReaPersona: keymap install (reaper-kb.ini swapped at install and restart) | Could take Ctrl+Z off StudioSync's Undo. ReaPersona already merges the keymap and avoids shortcut layers holding StudioSync's Undo. StudioSync re-registers its actions at every start (`band.sync_actions`) and sets missing keys (`undo.auto_keys`), but treats a key it once set and later found gone as the owner's choice. | Survived. The existing "keys" row has the Set Ctrl+Z button. |
| ReaPersona: mouse modifiers, themes | StudioSync doesn't depend on either (mirror.watch only waits while the mouse button is down). | No conflict. |
| ReaPersona: startup block in `Scripts/__startup.lua` | Its block is wrapped in a pcall and its `strip_startup` leaves other lines alone. Its "-- Start script:" lines are `Main_OnCommand`, which can't raise. | No conflict. If anything rewrites the file without StudioSync's block, the self-check puts it back. |
| ReaPersona: preferences | Queued for REAPER's next start, from a short list (fades, zoom, new-track defaults, `promptendrec`, solo dim). None of them is shared by StudioSync. `promptendrec` (ask about new files when recording stops) opens a modal box after every take, and every script, Live sync included, waits behind it. | Self-check item "promptendrec" says so. |
| ReaPersona: restart (File: Quit, its installer, start again) | A normal quit, so Autostart's `atexit` runs `startup.on_quit`, and the reopen plan is on disk all the time anyway. The keymap swap after the quit can drop registrations made during the session. | Survived: Autostart registers them again at start. The self-check also holds REAPER's "open projects on startup" while a plan is kept (`startup.keep_open_mode`). |
| ReaPersona: a persona's project part (template, rate, tempo, grid, render, starter tracks, colours) | Applied only to a fresh, untitled, empty project (`fresh_project`). A studio song is always a saved file, so it is never touched. `wset` (load window set) runs regardless. | No conflict. Window sets are untested with the docked panel. |
| **Grid-adapting scripts** (FTC's Adaptive grid and Gridbox start from James's `__startup.lua`; MPL's zoom-changes-grid mousewheel actions) | The grid travels with the timeline (`band.capture_settings`). Each zoom changed the grid, so the driver sent the grid to the studio at every zoom, and everyone else had it put back at every zoom (a "Not sent" line each time). | **Fixed.** `compat.grid_local()` keeps the grid this computer's own (left out of capture and apply) while FTC's Adaptive grid runs (its own ExtState says so), while a scanned startup script writes the grid, or for the session after 5 grid-only changes in a minute. The flip itself is not sent ("quiet"). A green Health row says why. |
| Scripts writing the `BandSync` ExtState or project ExtState | They would change StudioSync's settings, bindings or ids. | **Detected.** The scan flags a script whose text writes the `BandSync` section. Live check: the ExtState round-trip item. The section keeps its historic name: renaming it would break every install. |
| Scripts writing `P_EXT:band_*` | They change StudioSync's ids. | Detected by the scan ("pext"). |
| **Actions or scripts that regenerate track/item GUIDs** | Identity is `P_EXT:band_oid`, not the GUID. The GUID-to-oid map (`BandSync.mirrorg`, `<project>.bandsync-ids.json`) is only used to settle copies and to restore oids an unsaved reopen lost. A regenerated GUID keeps its oid, and `settle_ids` records the new GUID. It breaks only when **both** the GUID and the P_EXT are lost (a script rebuilding a track from a chunk without its `<EXT>`): the studio then sees a deletion plus a new track. The content is kept, but its history and claims are lost, and a bandmate's simultaneous edit lands nowhere (the "skipped" row). If a copy and its source both get new GUIDs at once, whichever is first in the track list keeps the oid. | Survived for GUID-only changes. The rebuild case is detected only through "pext" and the after-land detector. Not fixed: that would need a design change (a content fingerprint). |
| **`PreventUIRefresh` left on** (a script erroring between 1 and -1) | REAPER stops redrawing tracks. Deferred scripts still run, so StudioSync keeps syncing, but you don't see bandmates' changes. | REAPER exposes no API to read the refresh count, so this can't be detected. The fix is to restart REAPER. |
| **Long defer loops or blocking scripts** | Live sync gets fewer turns, so changes go out and come in late. | **Measured.** `compat.tick` gets the time spent elsewhere between Live sync's passes (from Live sync's own `t0` and `took`). A median of 250 ms or more gives the "loop" item and row. |
| **Other extensions on 47281-47297** | A second REAPER or another program on TCP 47281 stops the direct link listening (the extension says "can't listen on"). Syncthing still carries changes. | **Detected and named.** The owner comes from `netstat -ano` plus `tasklist` (Windows) or `lsof` (Mac/Linux), and the fix depends on whether the owner is a REAPER. The NAT UDP range 47282-47297 is only used when the studio turns it on, and is not checked here (lib/nat.lua has its own rows). |
| Other audio hooks | REAPER chains every `Audio_RegHardwareHook`. Nothing is exclusive; the only cost is CPU. | No conflict. |
| **ReaImGui / js_ReaScriptAPI versions** | Each script has its own Lua state and its own `require "imgui" "x"` shim, so another script pinning an old API doesn't touch StudioSync. Problems come only from the DLL itself: older than 0.10, or two copies in UserPlugins (REAPER loads one, maybe the older). | Self-check items "imgui" and "dll <family>" (studiosync, imgui, js_ReaScriptAPI, sws, reablink). `.dll.old` and `.prev` files are not counted, because REAPER doesn't load them. |
| **SWS startup actions** | A project startup action on a studio song runs on every open, and whatever it changes goes to the studio as yours. The global action runs at REAPER's start. | The project action gets its own item. The global action's script is scanned like the `__startup.lua` ones. |
| ReaBlink's own Puppet/Master mode (without StudioSync's Link bridge) | It edits tempo and play rate outside the studio's rules. `ablink.lua` already warns, but only while StudioSync's Link is on. | Item "reablink" covers the other case. |
| Scripts changing **tempo** in a defer loop | The driver sends a tempo map at every change; anyone else has it put back. | Scanned ("tempo"). The after-land and restless detectors name it at run time. |
| **Sample rate** | Not shared through the timeline (`prep.keep_format` holds it). ReaPersona sets it only on fresh projects. | No conflict. |
| Background **recolouring** | Track colours are shared, so each recolour goes out. SWS auto-colour was already handled (`band.sws_colours`). | Scanned ("colour"). |

## 2. ReaPersona: what it should change (documented here only; its repo was not edited)

1. **Leave per-project options alone in a studio song.** In `apply_feel` and `restore_feel`, skip Snap (1157), Auto-crossfade (40041), crossfade on split (40912) and ripple (40309-40311) when `reaper.GetProjExtState(proj, "BandSync", "song") ~= ""`. Don't flip tabs with `SelectProjectInstance` to put options back in a studio song. StudioSync now puts them back anyway, so this only removes the round trip and the Health row.
2. **Keep StudioSync's Undo on Ctrl+Z / Ctrl+Shift+Z** (Main and MIDI Editor) in every layer it builds, whenever `Scripts/StudioSync*/StudioSync - Undo.lua` is registered. It mostly does this today ("used only when no clean one is free").
3. If a persona turns on `promptendrec`, say in its preview that the box pauses StudioSync during takes.
4. Optional: set an ExtState such as `ReaPersona/switching` = time while `use_id` runs, so StudioSync's attribution doesn't need the 5 s window.

## 3. What was built

### Self-check (`compat.run_check`)
It runs 15 s after the tab in front starts Live sync, then every 10 minutes, and on demand from Health's **Check again** or the web Health page's **Check other scripts now**. On demand it also scans every script in the Actions list. It runs as a coroutine in the front tab's Live sync, 25 scripts per pass. Items:

- `loop`: the median time spent elsewhere between Live sync's looks.
- `startup`: StudioSync's block is in `Scripts/__startup.lua`. If it's missing, it is **put back** and the time is said (plus the file's last-write time with js_ReaScriptAPI). It is always on, as the panel already has it.
- `startup order`: a bare `dofile`/`require` or a top-level `return` above StudioSync's block can stop the file before StudioSync starts. The action **Move StudioSync's start to the top** keeps the render guard first and every line of the person's. It refuses a rewrite that comes out shorter.
- `autostart`: Autostart's loop beats (new ExtState `autostart beat`, written every 2 s).
- `extension`: the wanted version (the red "menu ext" row says what to do), and `dll <family>` for duplicates.
- `port`: 47281 is StudioSync's, or who has it.
- `extstate`: a nonce round-trip. Non-persistent; nothing touches the project.
- `detect`: change detection (`mirror.track_hash`) sees a scratch edit on a synthetic track state. This catches a half-updated copy. It deliberately doesn't touch the project: any real edit would mark it dirty, and in a studio song it would be sent.
- `imgui`, `openmode`, `promptendrec`, `sws project action`, `reablink`, and `reapersona` (informational).
- Scripts: those `__startup.lua` starts (by `_RS…` id through reaper-kb.ini, or a literal `dofile`) and SWS's global startup action, checked for `extstate`, `pext`, `grid`, `tempo` and `colour`. Scripts run by hand are checked only for `extstate` and `pext`. StudioSync's own files (any path containing "studiosync") are left out.

### Something else changed what StudioSync just wrote
- `sync.receive` notes each bandmate change that lands (`compat.landed`), with the top of REAPER's undo list at that moment.
- `mirror` W.send and `watch_timeline` report each change going out (`compat.sent`). If the same thing landed under 5 s ago:
  - The undo top is still "StudioSync: changes from the others": nothing with an undo point did it (a script, an extension or a plug-in). Shown after 2 times in 10 minutes.
  - Another name: that action did it. Shown after 3 times, since a person editing the same thing right after a bandmate is rare.
  - These don't count: StudioSync's own follow-ups (its names, and the unprefixed colour points), an undo of StudioSync's point, and refreshed prints.
- Restless: 5 sends of one thing in a minute with no new undo point between them. Plug-in chains with a window open are skipped, because that's someone turning knobs.
- Each case is logged once a minute. Health shows events from the last 10 minutes for the tab in front (ExtState `compat <tab>`).

### Health
`compat.rows` (page_health) and the same rows on the web Health page:

- A summary row lists the passing checks. It's green with a Check again button (new `ok_action`), or yellow when an item needs a look.
- Each failing item gets its own row.
- A row per clashing script, with its fix. Grid-only scripts show green while the grid is kept local.
- The grid row, and the event rows (persona, a named action, unnamed changes, restless, the loop).

## 4. How to use
- Panel: Settings > Health. Rows starting "Other scripts and extensions..." plus any `compat …` rows. Use **Check again** for a full scan.
- Web: the Health tab, **Check other scripts now**. The result appears within a few seconds, and the Console logs a one-line summary.
- To find a misbehaving script: wait for the "changed what a bandmate had just changed" or "kept changing by itself" row. It names the action when REAPER's undo history does. If it doesn't, stop the scripts listed as starting with REAPER one at a time.

## 5. Untested (needs the real computers)
- Everything against a live REAPER: the undo names REAPER gives for script edits, `Undo_CanUndo2` while sync.receive's block is open, and whether ReaPersona's persona switch lands within 5 s of a Live sync look.
- FTC Adaptive grid with a real zoom. Gridbox.
- `netstat`/`tasklist`/`lsof` output on each OS, and `ExecProcess` blocking (up to 4 s each, only when the port is taken).
- The window-set load (`wset`) with StudioSync's panel docked.
- The web button in a browser. The page change is three lines, using the existing `ssTabs.act`.

## 6. Shortcuts and limits
- `startup.keep_open_mode` writes the person's new choice into the plan, but Autostart keeps its own copy (`kept_was`) in its Lua state. The next tab change can write the old value back. Upgrade path: keep it only in the plan file.
- Grid-local latching from a scanned startup script is static: a script that only writes the grid on a click still makes the grid local. That's harmless (the grid is then simply per computer), and James can reverse it by removing the `latch_grid` call in run_check.
- Restless detection relies on REAPER making undo points for user edits. Plug-in knob turns without an undo point are excluded only while the plug-in's window is open.

## 7. Review later (security)
- The web page can now ask for a self-check (`{topic:"health", compat:true}`). It only reads files and is rate-limited to once every 10 s, but a phone with the studio's token can make this computer read every script in its Actions list (up to 512 KB each) and run `netstat`/`tasklist` when the port is taken. The output never leaves the computer: only rows and names go to the page.
- Scanned scripts' names and paths appear in Health rows and on the web page, which reveals local script names to anyone with the page.
- `compat.move_block_first` rewrites `Scripts/__startup.lua` from a panel button only (not from the web).
- The `startup` re-assert writes `__startup.lua` without asking, the same as the panel already does.

## Files touched
Mine: `lib/compat.lua`, `tests/test_0_60_rt_compat.lua`, this doc.

Small additive hooks in shared files:
- `StudioSync - Live sync.lua`: one line, `compat.tick` after each pass.
- `StudioSync - Autostart.lua`: one line, the `autostart beat` ExtState.
- `lib/page_health.lua`: the rows block, plus a green row's `ok_action` button.
- `lib/sync.lua`: the `timeline_veto` before sending or putting back a timeline change (the `if can(...)` became `elseif can(...) and not veto`, and the put-back words use the veto's), plus one `compat.landed` line in receive.
- `lib/mirror.lua`: one `compat.sent` line in W.send.
- `lib/band.lua`: `and not require("compat").grid_local()` on the grid lines of `capture_settings` and `apply_settings`.
- `lib/startup.lua`: new `startup.keep_open_mode`.
- `lib/webpages.lua`: `compat` on the health action.
- `lib/webui/health.js`: the button.
