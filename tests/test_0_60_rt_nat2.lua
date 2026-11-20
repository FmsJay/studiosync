-- The connection without Tailscale, stage 2 (docs/rt/rt-nat2.md): the direct link's Lua side. Which peers go as "nat:<device>" (only a
-- bandmate whose link without Tailscale is up; one whose link is down keeps its Tailscale entry: today's path), the link started for a studio
-- with no tailnet, live audio's stop ignored while the direct link uses the links, and Health naming each peer with the way it goes. The
-- reliable streams themselves: tests/nat_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
local setups, stops, status_json, direct_status, starts = {}, 0, "{}", "{}", {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  StudioSync_NatKey = function() return string.rep("ab", 32) end,
  StudioSync_NatSetup = function(json) setups[#setups + 1] = json; return 1 end,
  StudioSync_NatStatus = function() return status_json end,
  StudioSync_NatStop = function() stops = stops + 1 end,
  StudioSync_DirectStart = function(id, secret, inbox, port) starts[#starts + 1] = { id = id, secret = secret, port = port }; return 0 end,
  StudioSync_DirectStop = function() end,
  StudioSync_DirectSend = function() return 1 end,
  StudioSync_DirectStatus = function() return direct_status end,
  StudioSync_DirectMsg = function() return 1 end,
  StudioSync_DirectClock = function() return '{"now":1,"peers":{}}' end,
  StudioSync_DirectStream = function() return 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local listings, jsons = {}, {}
band.files = function(d, e) local out = {}; for _, f in ipairs(listings[d] or {}) do if not e or f:sub(-#e) == e then out[#out + 1] = f end end; return out end
band.read_json = function(p) return jsons[p] end
band.info = function() return { id = "studio1" } end
band.home = function() return "H" end
package.loaded.services = { run_hidden = function() return "Rule Name: StudioSync direct link\nProgram: C:\\REAPER\\reaper.exe\nLocalPort: 47281\nProtocol: TCP" end, TMP = "T",
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "MEMEMEMEMEME" end,
  tailnet_now = function() return nil, nil end }
local trusted, secret, tailnet = { nat = true }, "s3cret", { name = "x", suffix = "tail99.ts.net" }
package.loaded.groups = { trusted = function() return trusted end, tailnet = function() return tailnet end, sonobus_secret = function() return secret end }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function() return true end }
local here = { "Chilio", "Laptop" }
package.loaded.presence = { peers = function() local t = {}; for _, u in ipairs(here) do t[#t + 1] = { user = u } end; return t end }
package.loaded.access = { read = function() return nil end, shows = function() return true end }
local nat, direct = require("nat"), require("direct")

local PUB_ME, PUB_C, PUB_L = string.rep("ab", 32), string.rep("cd", 32), string.rep("ef", 32)
local me = { user = "James", device = "MEMEMEMEMEME", ts = { ["tail99.ts.net"] = "james-main.tail99.ts.net" }, nat = { pub = PUB_ME, tailnet = true } }
-- Chilio has a Tailscale name but is off the tailnet now (the pair goes without it); Laptop is on it (Tailscale, as before)
local chilio = { user = "Chilio", device = "CHILIOCHILIO", ts = { ["tail99.ts.net"] = "chilio.tail99.ts.net" }, nat = { pub = PUB_C, tailnet = false } }
local laptop = { user = "Laptop", device = "LAPTOPLAPTOP", ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net" }, nat = { pub = PUB_L, tailnet = true } }
local root = "R"
listings[root .. "/_band/devices"] = { "James.json", "Chilio.json", "Laptop.json" }
jsons[root .. "/_band/devices/James.json"], jsons[root .. "/_band/devices/Chilio.json"], jsons[root .. "/_band/devices/Laptop.json"] = me, chilio, laptop
local cfg = { root = root, user = "James" }

-- nat.direct_merge: pure
local list = { "chilio.tail99.ts.net:47281", "james-laptop.tail99.ts.net:47281" }
local dev_of = { ["chilio.tail99.ts.net:47281"] = "CHILIOCHILIO", ["james-laptop.tail99.ts.net:47281"] = "LAPTOPLAPTOP" }
local users = { ["chilio.tail99.ts.net:47281"] = "Chilio", ["james-laptop.tail99.ts.net:47281"] = "Laptop" }
local out, dv, u = nat.direct_merge(list, dev_of, users, { "nat:CHILIOCHILIO" }, { ["nat:CHILIOCHILIO"] = "Chilio" }, { peers = { CHILIOCHILIO = { state = "connecting" } } })
assert(#out == 2 and out[1] == "chilio.tail99.ts.net:47281", "a link not up yet: the Tailscale entry stays (today's path)")
out, dv, u = nat.direct_merge(list, dev_of, users, { "nat:CHILIOCHILIO" }, { ["nat:CHILIOCHILIO"] = "Chilio" }, { peers = { CHILIOCHILIO = { state = "up", path = "direct" } } })
assert(#out == 2 and out[1] == "james-laptop.tail99.ts.net:47281" and out[2] == "nat:CHILIOCHILIO", "the link up: nat:<device> in place of the Tailscale name, sorted")
assert(dv["nat:CHILIOCHILIO"] == "CHILIOCHILIO" and u["nat:CHILIOCHILIO"] == "Chilio" and u["chilio.tail99.ts.net:47281"] == nil, "its device (the clock's reference) and whose it is")
out = nat.direct_merge({}, {}, {}, { "nat:CHILIOCHILIO" }, {}, { peers = { CHILIOCHILIO = { state = "up" } } })
assert(#out == 1 and out[1] == "nat:CHILIOCHILIO", "no Tailscale name at all: the link alone")

-- The link started for a studio without a tailnet when the setting is on; not when it's off
tailnet = nil
assert(direct.ensure(cfg) == true and starts[#starts].secret == "s3cret", "no tailnet, connect without Tailscale on: the link starts (send only; what comes in rides the links)")
trusted.nat = nil
clock = clock + 11
assert(direct.ensure(cfg) == false, "no tailnet and the setting off: no link, as before")
trusted.nat = true
tailnet = { name = "x", suffix = "tail99.ts.net" }
clock = clock + 11

-- refresh_peers: the Tailscale list with Chilio swapped in once her link is up
status_json = '{"on":true,"peers":{"CHILIOCHILIO":{"state":"connecting"}}}'
local peers = direct.refresh_peers(cfg, "Song", "main")
assert(#setups == 1 and setups[1]:find("CHILIOCHILIO") and not setups[1]:find("LAPTOPLAPTOP"), "the extension set up for Chilio only (Laptop is on the tailnet)")
assert(table.concat(peers, " ") == "chilio.tail99.ts.net:47281 james-laptop.tail99.ts.net:47281", "link connecting: Tailscale names as today")
status_json = '{"on":true,"peers":{"CHILIOCHILIO":{"state":"up","path":"direct"}}}'
clock = clock + 3
local p2, d2, u2 = direct.refresh_peers(cfg, "Song", "main")
assert(table.concat(p2, " ") == "james-laptop.tail99.ts.net:47281 nat:CHILIOCHILIO" and d2["nat:CHILIOCHILIO"] == "CHILIOCHILIO" and u2["nat:CHILIOCHILIO"] == "Chilio",
  "link up: changes, messages and pings go to nat:CHILIOCHILIO")
assert(ext[band.SECTION .. "/direct peers studio1 Song/main"]:find("nat:CHILIOCHILIO"), "the list other scripts read has it too")

-- live audio off asks the links to stop every tick: ignored while the direct link uses them, honoured once it hasn't for a while
local before = stops
nat.peers(nil)
assert(stops == before, "live audio's stop while the direct link uses the links: ignored")
clock = clock + nat.HOLD + 1
nat.peers(nil)
assert(stops == before + 1, "and honoured once the direct link hasn't asked for a while")

-- Health: each peer with its way
assert(direct.way_text("nat direct"):find("without Tailscale") and direct.way_text("direct") == "Tailscale, direct" and direct.way_text(nil) == "Tailscale", "the ways in words")
assert(direct.nat_way({ peers = { CHILIOCHILIO = { path = "relayed" } } }, "nat:CHILIOCHILIO").path == "nat relayed" and direct.nat_way({}, "bo.ts.net:47281") == nil, "a nat peer's way from the extension's status")
assert(direct.who_of({ chilio }, "nat:CHILIOCHILIO") == "Chilio" and direct.who_of({}, "nat:CHILIOCHILIO") == "CHILIOC", "whose a nat peer is")
assert(direct.peer_name("nat:CHILIOCHILIO", { ["nat:CHILIOCHILIO"] = "Chilio" }) == "Chilio" and direct.peer_name("james-laptop.tail99.ts.net:47281") == "james-laptop", "short names")
status_json = '{"on":true,"peers":{"CHILIOCHILIO":{"state":"up","path":"direct"}}}'
direct_status = '{"listening":false,"bind":"","error":"Tailscale isn\'t up here","rejected":0,"peers":{"nat:CHILIOCHILIO":{"ok":true,"ms":42,"at":1,"sent":3,"rate":0,"rtt_ms":40,"window":0,"busy":false,"error":""}}}'
ext[band.SECTION .. "/menu extension"] = "1.0.24"
nat.S.users["nat:CHILIOCHILIO"] = "Chilio"
local s = direct.status(cfg)
assert(s.peers[1].path == "nat direct", "status: the nat peer's way")
local ok, text = direct.health_line(cfg)
assert(ok == true and text:find("over the connection without Tailscale") and text:find("Chilio %(without Tailscale, through both NATs%)"), text)
local sok, stext = direct.speed_line_of(s.peers, function(p) return direct.peer_name(p) end)
assert(sok == true and stext:find("Chilio: without Tailscale, through both NATs, 40 ms"), tostring(stext))

-- one hub per computer: another Live sync tab (another song) that set it up just now keeps it from the direct link here; live audio's
-- engine (the song in front) takes it
clock = clock + 10
ext[band.SECTION .. "/nat setup by"] = "another-tab\t" .. clock
local n0, s0 = #setups, stops
local np = nat.peers(cfg, { song = "Song", room = "main" }, "direct")
assert(#np == 0 and #setups == n0 and stops == s0, "another tab holds the hub: the direct link here sets nothing up and stops nothing")
clock = clock + 3
np = nat.peers(cfg, { song = "Song", room = "main" })
assert(#np == 1 and #setups == n0 + 1 and ext[band.SECTION .. "/nat setup by"]:find("^" .. nat.ME), "live audio's engine (the song in front) takes it")
clock = clock + 3
ext[band.SECTION .. "/nat setup by"] = "another-tab\t" .. (clock - nat.HOLD - 1)
np = nat.peers(cfg, { song = "Song", room = "main" }, "direct")
assert(#np == 1, "a claim gone stale: the direct link here takes it")
print("ok")
