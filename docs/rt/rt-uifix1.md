# rt-uifix1: three small follow-ups to the web view phases

## 1. Settings with no studio project open

The hook rt-ui10b's "Left for later" asked for, in rt-ui2's files:
- `lib/webroute.lua`: `FREE.settings = true`, and `run` hands a "settings" action to `websettings.action` with whether the page is on this computer (`StudioSync_WebUIPollHere`), as `lib/webui.lua` does for Live sync.
- `lib/weblobby.lua`: Autostart's tick calls `websettings.tick` after Home's and the invite tick, so the topic is built while a page shows Settings.

Rules kept: nothing changes unless the page is on this computer (websettings' own check; a phone or another device is told "refused"). Studio rows need a studio known: Autostart answers only when `weblobby.cfg` found one (`cfg.root`), as for every topic it answers; the owner/admin checks are websettings' own. With no cfg at all (no user, no studio) Autostart answers nothing, as before; You (the page's own) still works.

Tests: `tests/test_0_60_rt_ui2.lua` (the rule, the router's hand-over with `here` 0 and 1, the tick publishing "settings") and `tests/test_0_60_rt_ui10b.lua` section 8b (the real websettings through the router: this computer's page changes a setting, another device's changes nothing, the want is taken). Both fail without the change.

## 2. Pop-out window limit

Each web page keeps one event stream, and Chromium (Chrome, Edge, REAPER's WebView2) allows six connections to one host. Measured in `tests/rt_uifix1_browser.mjs` (real page files, stand-in server): with five pages open (main plus four pop-outs) one connection is left and the page works; a sixth page hangs while its files load (its stream takes the last connection) and every action would wait. So the limit is **five pages, not six** as rt-ui9's note assumed: the shell refuses a fifth pop-out with "Close a popped-out window first: at most four at once."

How: `lib/webui/tabs.js` `ssTabs.room()` asks the other pages of this browser over a BroadcastChannel (`studiosync-pages`, "who's there?", each page answers; no timers, nothing kept, a crashed page isn't counted) and resolves true while fewer than `MAX_PAGES` (5) are open; if not, it puts a `role=alert` note (`#sspagelimit`, `lib/webui/shell.css`) on the page for 8 s. `ssTabs.popOut` and call.js's two window openers (the call's Pop out, a share's Pop out) ask first; they open the window about 250 ms later (a click's permission lasts longer). One shared constant, `MAX_PAGES`.

Not done: pages of another browser profile aren't counted (they don't share the channel), nor a REAPER window whose WebView2 profile differs from the browser's (the browser has its own pool then anyway); one shared stream (a SharedWorker) would lift the limit. Windows opened by the user by hand (a browser tab, Ctrl+N) aren't stopped, only counted.

Test: `node tests/rt_uifix1_browser.mjs` (needs Chrome or Edge): the other pages are iframes of the page (same origin and channel, real page files); counts, refusal, the note, room again after one closes, a pop-out page counting the others, the call's Pop out.
