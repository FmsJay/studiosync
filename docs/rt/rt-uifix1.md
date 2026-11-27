# rt-uifix1: three small follow-ups to the web view phases

## 1. Settings with no studio project open

The hook rt-ui10b's "Left for later" asked for, in rt-ui2's files:
- `lib/webroute.lua`: `FREE.settings = true`, and `run` hands a "settings" action to `websettings.action` with whether the page is on this computer (`StudioSync_WebUIPollHere`), as `lib/webui.lua` does for Live sync.
- `lib/weblobby.lua`: Autostart's tick calls `websettings.tick` after Home's and the invite tick, so the topic is built while a page shows Settings.

Rules kept: nothing changes unless the page is on this computer (websettings' own check; a phone or another device is told "refused"). Studio rows need a studio known: Autostart answers only when `weblobby.cfg` found one (`cfg.root`), as for every topic it answers; the owner/admin checks are websettings' own. With no cfg at all (no user, no studio) Autostart answers nothing, as before; You (the page's own) still works.

Tests: `tests/test_0_60_rt_ui2.lua` (the rule, the router's hand-over with `here` 0 and 1, the tick publishing "settings") and `tests/test_0_60_rt_ui10b.lua` section 8b (the real websettings through the router: this computer's page changes a setting, another device's changes nothing, the want is taken). Both fail without the change.
