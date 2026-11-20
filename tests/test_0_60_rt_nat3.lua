-- The connection without Tailscale, stage 3 (docs/rt/rt-nat3.md), its Lua side (lib/nat.lua): who relays (the studio hub, lib/hub.lua's
-- choice) and who uses its relay (only an address its own computer wrote in its devices file), the setup's relay and turn, the devices
-- file entry carrying the relay's address, Health's words ("relayed by <hub>", "direct (through both NATs)", "no path", the hub's
-- port-forward note, a relay that doesn't answer, a strict NAT that needs one), and the firewall rule's wider range on the hub. The
-- extension's relay, caps, network changes and signalling: tests/nat_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
local setups, stops, status_json = {}, 0, "{}"
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
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local listings, jsons = {}, {}
band.files = function(d, e) local out = {}; for _, f in ipairs(listings[d] or {}) do if not e or f:sub(-#e) == e then out[#out + 1] = f end end; return out end
band.read_json = function(p) return jsons[p] end
package.loaded.services = { run_hidden = function() return nil end, TMP = "T", is_device_id = function(id) return type(id) == "string" and #id > 10 end,
  my_device_id = function() return "MEMEMEMEMEME" end, tailnet_now = function() return nil, nil end }
local trusted = { nat = true }
package.loaded.groups = { trusted = function() return trusted end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end, sonobus_secret = function() return "s3cret" end }
local device_ok = {}
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function(_, u) return device_ok[u] ~= false end }
local here = { "Chilio" }
package.loaded.presence = { peers = function() local t = {}; for _, u in ipairs(here) do t[#t + 1] = { user = u } end; return t end }
package.loaded.access = { read = function() return nil end, shows = function() return true end }
local hub_user = "James"
package.loaded.hub = { view = function() return { studio = hub_user } end }
local nat = require("nat")

local PUB_ME, PUB_C, PUB_L = string.rep("ab", 32), string.rep("cd", 32), string.rep("ef", 32)
local me = { user = "James", device = "MEMEMEMEMEME", ts = { ["tail99.ts.net"] = "james-main.tail99.ts.net" }, nat = { pub = PUB_ME, tailnet = true } }
local chilio = { user = "Chilio", device = "CHILIOCHILIO", nat = { pub = PUB_C, tailnet = false } }
local laptop = { user = "Laptop", device = "LAPTOPLAPTOP", ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net" }, nat = { pub = PUB_L, tailnet = true, relay = "203.0.113.5:47298" } }

-- who relays: pure
local yes = function() return true end
assert(nat.relay_plan("James", "James", {}, yes) == true, "the studio hub runs the relay itself")
local on, addr, who = nat.relay_plan("Chilio", "Laptop", { me, laptop }, yes)
assert(on == false and addr == "203.0.113.5:47298" and who == "Laptop", "another computer uses the hub's relay from its devices file")
assert(select(2, nat.relay_plan("Chilio", "Laptop", { laptop }, function() return false end)) == nil, "a relay address in a file another computer wrote: not used")
assert(select(2, nat.relay_plan("Chilio", "James", { me, laptop }, yes)) == nil, "only the hub's own file names the relay (the laptop isn't the hub)")
assert(select(2, nat.relay_plan("Chilio", "Laptop", { { user = "Laptop", device = "LAPTOPLAPTOP", nat = { pub = PUB_L, relay = "evil.example:1" } } }, yes)) == nil, "an address that isn't ip:port: not used")
assert(nat.relay_plan("Chilio", nil, { laptop }, yes) == false, "no studio hub: no relay")

-- the setup: this computer is the hub, so it relays for every studio computer with a key
local root = "J:/St/Smiley"
listings[root .. "/_band/devices"] = { "James.json", "Chilio.json", "Laptop.json" }
jsons[root .. "/_band/devices/James.json"], jsons[root .. "/_band/devices/Chilio.json"], jsons[root .. "/_band/devices/Laptop.json"] = me, chilio, laptop
local cfg = { root = root, user = "James" }
nat.peers(cfg, { song = "Nostalgia", room = "main" })
local s = band.json_decode(setups[#setups])
assert(type(s.relay) == "table" and s.relay.port == 47298 and #s.relay.users == 3 and s.relay.users[1] == "CHILIOCHILIO" and s.turn == nil, "the hub: a relay for the studio's computers, no relay of another's")
assert(nat.S.relay_on == true and nat.S.relay_name == "James", "the hub knows it relays")
status_json = '{"on":true,"public":"198.51.100.7:51234","peers":{}}'
assert(nat.entry(root, true).relay == "198.51.100.7:47298", "the hub's devices file carries its relay at its public address")
-- nobody this way in the room, but the hub still relays for the others
here = {}
clock = clock + 5
local n0 = #setups
nat.peers(cfg, { song = "Nostalgia", room = "main" })
assert(#setups == n0 + 1 and stops == 0 and band.json_decode(setups[#setups]).relay ~= nil and #band.json_decode(setups[#setups]).peers == 0, "the hub with nobody to reach itself: still set up, relaying")
-- another computer is the hub: this one uses its relay
hub_user = "Laptop"
here = { "Chilio" }
clock = clock + 5
nat.peers(cfg, { song = "Nostalgia", room = "main" })
s = band.json_decode(setups[#setups])
assert(s.relay == nil and s.turn == "203.0.113.5:47298" and nat.S.relay_name == "Laptop", "not the hub: the hub's relay to use, and whose it is")
assert(nat.entry(root, true).relay == nil, "not the hub: no relay in this computer's file")
hub_user = "Laptop"
here = {}
clock = clock + 5
nat.peers(cfg, { song = "Nostalgia", room = "main" })
assert(stops == 1, "not the hub and nobody to reach: stopped")

-- Health's words
local ok, text = nat.peer_text({ state = "up", path = "relayed", up_s = 3 }, "Chilio", "Laptop")
assert(ok and text == "Chilio: relayed by Laptop, up 3s", text)
ok, text = nat.peer_text({ state = "up", path = "direct", up_s = 9 }, "Chilio", "Laptop")
assert(ok and text == "Chilio: direct (through both NATs), up 9s", text)
ok, text = nat.peer_text({ state = "waiting", nopath = true, why = "no connection in 60 s" }, "Chilio", nil)
assert(not ok and text:find("^Chilio: no path") and text:find("no relay"), text)
ok, text = nat.peer_text({ state = "waiting", nopath = true }, "Chilio", "Laptop")
assert(not ok and text:find("no path") and text:find("Laptop's relay"), text)
-- the hub's own row: what it relays, and the router's port forward it needs (written, never done)
local rows = nat.rows_from({ nat = "easy", peers = {}, relay = { on = true, running = true, port = 47298, error = "", bytes = 2097152, over_cap = 3 } }, {}, true, false, "James")
assert(#rows == 2 and rows[1][1] == "nat relay" and rows[1][2] == true and rows[1][4]:find("UDP 47298%-47314") and rows[1][4]:find("router forwards")
  and rows[1][4]:find("never changes a router") and rows[1][4]:find("2.0 MB relayed"), "the hub: its relay's row with the port forward to set up: " .. tostring(rows[1][4]))
assert(rows[2][1] == "nat firewall" and rows[2][5]:find("47282%-47314"), "the hub's firewall rule covers its relay's ports too")
rows = nat.rows_from({ nat = "easy", peers = {}, relay = { on = true, running = false, error = "the relay couldn't start (UDP 47298 taken?)" } }, {}, false, true, "James")
assert(#rows == 1 and rows[1][2] == false and rows[1][5]:find("taken"), "a relay that couldn't start says why")
-- a computer using the hub's relay
rows = nat.rows_from({ nat = "easy", turn = "203.0.113.5:47298", relay_ok = false, peers = {} }, {}, false, true, "Laptop")
assert(#rows == 1 and rows[1][1] == "nat relay" and rows[1][5]:find("doesn't answer") and rows[1][5]:find("Laptop"), "the hub's relay not answering: its router may not forward the ports yet")
rows = nat.rows_from({ nat = "strict", turn = "203.0.113.5:47298", relay_ok = true, peers = {} }, {}, false, true, "Laptop")
assert(#rows == 1 and rows[1][1] == "nat strict" and rows[1][5]:find("needs a relay") and rows[1][5]:find("Laptop's relay answers"), "a strict NAT with the hub's relay answering")
rows = nat.rows_from({ nat = "strict", peers = {} }, {}, false, true, nil)
assert(#rows == 1 and rows[1][5]:find("none answers yet"), "a strict NAT and no relay: what it needs")

-- the firewall rule: the hub's wider range; a wider rule does for a computer that isn't the hub (now)
assert(nat.ports() == "47282-47297" and nat.ports(true) == "47282-47314", "the ports")
assert(nat.firewall_command("C:\\REAPER\\reaper.exe", true):find("localport=47282-47314", 1, true), "the hub's rule")
local narrow = "Rule Name: StudioSync connection without Tailscale\nProgram: C:\\REAPER\\reaper.exe\nLocalPort: 47282-47297"
local wide = "Rule Name: StudioSync connection without Tailscale\nProgram: C:\\REAPER\\reaper.exe\nLocalPort: 47282-47314"
assert(nat.firewall_in(narrow, "C:\\REAPER\\reaper.exe") and nat.firewall_in(wide, "C:\\REAPER\\reaper.exe"), "not the hub: either rule")
assert(not nat.firewall_in(narrow, "C:\\REAPER\\reaper.exe", true) and nat.firewall_in(wide, "C:\\REAPER\\reaper.exe", true), "the hub: only the wider one")
print("ok")
