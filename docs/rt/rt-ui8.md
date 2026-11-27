# rt-ui8: the REAPER window (Phase 8 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave A" > Phase 8, with 4.1-4.6, under James's decisions of 2026-11-27 (when REAPER takes the
focus: shrink to the strip by default; button, stay, go behind REAPER and fade as options). The page side was rt-ui1's (`docs/rt/rt-ui1.md`).

## What was built

- **`extension/webui_dock.cpp`**
  - **Views, one per window** (Windows): one WebView2 environment for REAPER's run, a view for the main window and one for each pop-out.
    A view moves alive between windows (`put_ParentWindow`), so Dock / Undock, the strip, the button and full screen never reload the
    page: a call, a share, a try or a playback in it goes on.
  - **Window shapes** (the main window and each pop-out): docked, or floating as *full* (the framed window, its place kept), *strip*
    (380 x 36, no frame), *button* (22 / 28 / 40 / 56 px square, no frame) or *full screen* (the monitor it's on, no frame). The strip and
    button sizes follow the display's scale (150 % gives 570 x 54). They stay inside REAPER's window where they're dropped, or on a monitor
    when REAPER's window is on another one or too small. Full screen ends with Esc or the button again.
  - **Drag**: a press on the strip or button (the page's `win:drag`) makes the window follow the mouse until the button is let go. It is
    kept inside REAPER's window, and the place is remembered. The click that ends a drag doesn't open the view. "Lock position" in the menu
    stops it.
  - **The button's right-click** (`win:menu`), like the panel's box menu: Open StudioSync, Lock position, Make it a strip / button,
    Size (Small, Medium, Large, Big), Close.
  - **The focus rule** (the main window, floating full or full screen). When a REAPER window it covers takes the focus (`WM_ACTIVATE` plus
    the panel's `ui.should_hide` test as `webui_dock_covers`), it follows the ExtState `BandSync` / `web ui focus` setting:
    - `strip` (the default, and for anything unknown) or `button`: it shrinks to that shape.
    - `stay`: nothing happens.
    - `behind`: the window has no owner, so REAPER's window can cover it, and it gets a taskbar button.
    - `fade`: 25 % opacity while REAPER has the focus, full while the mouse is over it.

    It comes back on a click on the strip or button, the toolbar button, `StudioSync_WebUIDock(1)` (so a `nav` with `wake`, through
    Lua), or "Open StudioSync" in the menu.
  - **Pop-out windows**: `window.open` of `/?pop=<route>` (tabs.js's Pop out, call.js's `?pop=share&call=`) opens a REAPER window of its
    own with its own view, handed to WebView2 as the opened window, so `window.opener` holds. Up to 6. Each pop-out can dock (ident
    `studiosync_webui_pop_<name>`), float or go full screen on its own, and REAPER remembers where. They close with the main window. A
    page's `window.close()` (the pop page's "Back into the main window") closes its window. Any other new window still goes to the browser.
  - **The window icon**: `studiosync.rc` (icon 101) and `studiosync.ico` (lib/webui/icon.svg drawn at 256 px, with grey bars that read on
    light and dark title bars), set with `WM_SETICON` on every window.
  - **Opening where it was**: closed in full screen, it opens in full screen next time; otherwise docked or floating as before.
- **`extension/webui_dock.h`**: the pure parts listed under Tests, the per-window view calls, and `dock_win_*` (frame, opacity, owner).
- **`extension/webui_dock_mac.mm`**: a WKWebView per window, pop-outs through `createWebViewWithConfiguration` (WebKit's configuration, so
  the opener holds), `didFinishNavigation` and `webViewDidClose`, the page told through `evaluateJavaScript("ssShell.fromHost(...)")`. The
  window functions:
  - frame: `styleMask` titled or borderless
  - opacity: `alphaValue`
  - owner: SWELL's owned-window list, so behind means taken off it at the normal level
- **Linux** (WebKitGTK): unchanged behaviour (docked and floating, Dock / Undock makes the view again, new windows go to the browser).
  `dock_win_can()` is false there, so the window never sends `{"win"}` and the page keeps the strip, button and full-screen buttons hidden.
- **`extension/reaper_menu.cpp`** (4 additive lines): with ExtState `BandSync` / `ui` = `web`, the toolbar button's action ("StudioSync")
  runs `webui_dock_button()` instead of the panel script:
  - closed: it opens where it was
  - docked: it toggles
  - floating full or full screen: it shrinks to the strip (or the button, when that's the rule)
  - strip or button: it comes back full

  The button is lit while the view is open in any shape. Without that setting nothing changes (the panel stays the UI until James's band
  test: decision 5).
- **`extension/build_windows.cmd`**: `rc studiosync.rc` and the `.res` linked into StudioSync's DLL (not ReaPersona's).
- **`lib/webui/shell.js`** (small, additive, rt-ui1's file):
  - The Dock button is wired wherever the view's channel exists. A pop-out has no `?host=`, so it shows once the window says `docked`.
  - The window's `docked` sets its label and `ssEnv.host`, and `pop` sets `ssEnv.winPop`.
  - A press on the strip or button sends `win:drag`, and the logo isn't an image drag.

## The messages

Page to window (the view's own channel, the pages' origin only):

| Message | What the window does |
|---|---|
| `key:<vk>:<mods>` | as before (REAPER's shortcuts); in full screen, Esc leaves it |
| `dock` | Dock / Undock: the other kind of window, same view (Linux: made again, as before) |
| `win:full` | back to the full window (into the docker if that's where it lives) |
| `win:strip`, `win:button` | that shape |
| `win:fullscreen` | full screen; again: back to full |
| `win:menu` | the strip's or button's menu |
| `win:drag` | follows the mouse till it's let go (strip and button only, not when locked) |

Anything else, like `win:float` or `win:dock:left` from the plan's table, is ignored: docking to a side stays in Lua (`Dock_UpdateDockID`).

Window to page, after every load and every change: `{"win":"full"|"strip"|"button"|"fullscreen","focus":bool,"docked":bool,"pop":true}`.
WebView2 sends it with `PostWebMessageAsJson` (shell.js's `message` listener). WKWebView sends it with `ssShell.fromHost(...)`. Linux sends
nothing.

ExtState (`BandSync`, persisted):
- Read by the window:
  - `web ui focus`: strip, button, stay, behind or fade. This is the setting Settings > This computer > Window should write; Wave B
    builds that page.
  - `web ui button size`: 22, 28, 40 or 56.
  - `web ui lock`: "1" means locked.
  - `ui` = `web`: the toolbar button opens the web view.
- Written by the window:
  - `web ui strip`, `web ui button`: the "x y" each shape was dropped at.
  - `web ui mode`: "fullscreen" when it closed in full screen.
  - Each pop-out's own `web ui pop <name> docked`, `... rect`, `... strip`, `... button`.

## Checks for James in REAPER (after a release with this extension)

On Windows (JAMES-MAIN):
1. Open the web UI docked: the strip, button and full-screen buttons appear beside Undock (the window has now told the page it can).
2. Undock: the window floats and the page doesn't reload (start a video call or a Try first: it keeps going). Dock again: back in its
   docker, still no reload.
3. Floating, press ▁ (strip): a thin bar at REAPER's top right, inside REAPER's window. Drag it by its words or logo to another place inside
   REAPER: it can't leave REAPER's window. Close and reopen REAPER: it comes back where you dropped it. Press Open: the full window again.
4. ▢ (button): a small square. Drag it, then right-click: the menu. Try Size > Big, Lock position (now it can't be dragged), Make it a
   strip, Close.
5. ⛶ (full screen): the whole monitor, no frame. Esc leaves; ⛶ again leaves too. On a second monitor it fills that one.
6. The focus rule, floating full, with `reaper.SetExtState("BandSync", "web ui focus", "<rule>", true)` for each rule:
   - default (strip): click the arrange view under the window and it shrinks to the strip. Click another app, a REAPER dialog, or a REAPER
     window on another monitor, and it stays.
   - `button`: it shrinks to the button.
   - `stay`: nothing happens.
   - `behind`: REAPER's window covers it. Alt+Tab or the taskbar button (with the StudioSync icon) brings it back.
   - `fade`: it fades to 25 % and comes back to full under the mouse. **Unchecked**: whether WebView2 draws in a layered window. If it
     shows blank while faded, say so.
7. The window icon in the title bar (and in the taskbar under `behind`).
8. Pop out: Project > Beat, ⋯ > Pop out this page. A REAPER window opens with the Beat alone, not the browser. Press "Back into the main
   window" and it closes. Pop out Chat, then press Dock in it: it docks on its own. Close the main window: the pop-outs go too.
9. With `reaper.SetExtState("BandSync", "ui", "web", true)`, the toolbar button opens the view and works as described above (open, shrink,
   back), and it is lit while the view is open. Delete the key and the button opens the panel again.
10. Keys still reach REAPER from the view, in the main window and in a pop-out (Space plays).

On the Mac (when testing resumes), the same 1-8:
- Borderless strip and button windows, and whether they take clicks and keys.
- Alpha fade.
- Behind: the window off SWELL's owned list, so REAPER covers it.
- The pop-out's `window.opener`.
- Full screen leaves the menu bar over its top (shortcut: no full-screen space).

On Linux: unchanged from before (docked / floating, no strip buttons).

## Tests

- `tests/webui_dock_test.cpp` (`tests\build_webui_dock_test.cmd`; CI's Mac and Linux jobs run its pure parts):
  - the page's asks, the mode names and the JSON told to the page
  - the focus rule's names and its default
  - button sizes, strip and button sizes at a scale
  - places kept inside REAPER's window and on a monitor: past the edges, REAPER on another monitor (one left of the main one), REAPER too
    small, wider than the monitor
  - the cover test: a click on it, no focus, a dialog, another app, our own window, another monitor, touching or overlapping by a pixel,
    no rect
  - pop-out names: chat, encoded and plain sub-routes, the share, `pop` after another field, and 13 refusals including other origins,
    other pages, upper case, `..`, spaces, `_` and over 32 characters
  - headless on Windows: the page's `view:loaded` from its window, the view moved alive into another window, posting to the page, the
    view closed; frame, opacity (25 % = 63 alpha, then not layered) and owner on plain hidden windows
- `extension\build_windows.cmd` builds clean, with the icon resource in the DLL (checked: icon group 101 found).
- `node tests/rt_ui1_browser.mjs` with the new shell.js (see the report for its result).

Not compiled here: `webui_dock_mac.mm` and the shared window code's macOS and Linux branches. There is no clang or SWELL toolchain on this
PC, and agents don't push, so CI hasn't run. Each SWELL function and constant used was checked by name against WDL's `swell-functions.h`
and `swell-types.h` (a 2025-06 WDL copy on this drive): `SWELL_GetViewPort`, `GetAsyncKeyState(VK_LBUTTON)`, `GetTickCount`,
`TrackPopupMenu` with `TPM_RETURNCMD`, `MENUITEMINFO.fState` / `hSubMenu`, `SW_SHOWNA`, `WA_INACTIVE`. SWELL's owner selectors
(`swellAddOwnedWindow:`, `swellRemoveOwnedWindow:`, `swellSetOwner:`) were checked against `swell-dlg.mm`. The orchestrator's push will
show whether the Mac and Linux jobs build.

## Left for later

- **call.js** (rt-share's file) still hides Pop out in the docked view (`if (!docked)`). It can show it when `ssEnv.winPop` is true; that's a
  one-line change for call.js's owner.
- The strip's words for "View only: Bo is in control" (decision 6) are the page's (`stripWords` in shell.js). Phase 9/11 or whoever owns the
  strip's words should add them.
- Settings > This computer > Window: the page that writes `web ui focus` and the button size (Wave B).
- The panel's Window menu (Fill this screen, halves, next screen, Back to before) for the floating full window: not built. Full screen
  covers the main use.
- Linux strip, button, full screen and pop-outs: SWELL-generic's frame changes and a second WebKitGTK view in an XBridge are untested ground.
- Fade on Windows if WebView2 draws blank in a layered window: the alternative is a DirectComposition-hosted view, a bigger change.
- A strip or button on a monitor with a different scale from REAPER's main window uses the main window's scale.

## Review later (security)

- Pop-out windows open only for the pages' own origin and only for `/` or `/index.html` with `?pop=` set to a lower-case route of up to 32
  characters (`webui_dock_pop_name`). A pop-out view gets the same handlers as the main one: messages from its own origin only, navigation
  kept to the origin, camera and mic for the origin only. Anything else still goes to the browser, http(s) only.
- The pop-out name goes into ExtState keys and a docker ident, so it's limited to `[a-z0-9_-]`.
- `view:loaded` and `view:close` arrive on the same channel as page messages, so a page could post them itself. The effects are harmless:
  the window re-sends its state, and a pop-out closes itself (it can do that with `window.close()` anyway).
- The window never runs anything a page names. The page asks only for shapes, a drag, a menu, and keys (unchanged).
