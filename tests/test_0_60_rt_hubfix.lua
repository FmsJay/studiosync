-- rt-hubfix (2026-11-20, the four-computer test with extension 1.0.27): the laptop heard the Mac's mix, the Mac's peer list left the desktop
-- out, and the desktop sat "joining" for minutes while the laptop heard nothing of it. The extension's side (extension/rtaudio.cpp hub_watch,
-- 'H'; tests/rtaudio_test.cpp start_order_test) keeps a peer the hub doesn't hear on its own streams and stops a join no mix answers. Here:
-- Health's words for both, from the extension's status (per peer via_hub only for those in the hub's mix; hub join_fails). Pure.
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ time_precise = function() return 0 end, GetOS = function() return "Win64" end, GetExtState = function() return "" end },
  { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local la = require("liveaudio")
local MAC, LAP, DESK = "mac.ts.net:47281", "lap.ts.net:47281", "desk.ts.net:47281"
local names = { [MAC] = "Chilio-Mac", [LAP] = "James-Laptop", [DESK] = "James" }

-- the laptop: through the Mac's mix, the desktop heard directly (not in the Mac's mix): its own latency is shown, and it's green
local ok, text = la.health_text({ nch = 1, kbps = 128, hub = { peer = MAC, state = "hub", latency_ms = 370, direct_ms = 150 }, peers = {
  [MAC] = { resolved = true, streaming = false, via_hub = true },
  [DESK] = { resolved = true, streaming = true, via_hub = false, latency_ms = 140, buffer_ms = 90, loss = 0, target_ms = 30, floor_ms = 30 } } }, names)
assert(ok, "everyone heard: " .. text)
assert(text:find("James 140 ms", 1, true) and text:find("through Chilio-Mac's mix", 1, true), "the desktop by its own stream, the Mac through its mix: " .. text)

-- the desktop: no mix came when it asked (the Mac doesn't list it): direct, said once with the count
local t = la.hub_text({ peer = MAC, state = "direct", serve = false, join_fails = 3, fallbacks = 0 }, names)
assert(t == "; Chilio-Mac's mix didn't come when asked (3 times), so you hear everyone's own streams; asked again every 10 s", t)
assert(la.hub_text({ peer = MAC, state = "direct", join_fails = 1 }, names):find("(1 time)", 1, true), "one ask")
assert(la.hub_text({ peer = MAC, state = "hub", join_fails = 2, latency_ms = 300, direct_ms = 100 }, names):find("didn't come", 1, true) == nil,
  "heard through it now: the old asks aren't news")
assert(la.hub_text({ peer = "", state = "direct", serve = true, serving = 2, load = 0.02, join_fails = 2 }, names):find("didn't come", 1, true) == nil,
  "mixing here: nothing to join")
assert(la.hub_text({ peer = MAC, state = "joining" }, names) == "; joining Chilio-Mac's mix", "still asking")

print("ok: rt-hubfix (Health: a peer outside the hub's mix heard directly; a join no mix answers)")
