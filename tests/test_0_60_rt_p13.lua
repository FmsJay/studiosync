-- Connect without Tailscale, the rest (package P13, docs/rt/rt-nat3.md round 2): the Lua side of
--  - the relay's role staying with a computer whose relay was reached from outside (relay_reach) and isn't behind CGNAT, while it's online,
--    and the devices file carrying both (backlog 1.32);
--  - Health: a relay that answers but doesn't relay, a relay hub behind CGNAT, a relay reached from outside, what still needs Tailscale (3.2 A);
--  - the direct link's stale "can't reach" row for a peer it stopped trying (1.31);
--  - the hello for a computer not here, over a quiet link without Tailscale (rt-linkmove round 6 item 8);
--  - the video-call pages' ICE servers (3.2 A); phone pages on this computer's own network (4.7).
-- The extension's side (SACK, the relay's failures, UPnP, quiet links, the LAN listener): tests/nat_test.cpp and tests/direct_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
local setups, status_json, direct_status, lan_ports = {}, "{}", "{}", {}
local fns = {
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  StudioSync_NatKey = function() return string.rep("ab", 32) end,
  StudioSync_NatSetup = function(json) setups[#setups + 1] = json; return 1 end,
  StudioSync_NatStatus = function() return status_json end,
  StudioSync_NatStop = function() end,
  StudioSync_NatIce = function() return '{"user":"MEMEMEMEMEME","pass":"00112233445566778899aabbccddeeff"}' end,
  StudioSync_DirectStart = function() return 1 end, StudioSync_DirectSend = function() return 1 end,
  StudioSync_DirectStatus = function() return direct_status end,
  StudioSync_DirectMsg = function() return 1 end, StudioSync_DirectClock = function() return '{"now":1,"peers":{}}' end, StudioSync_DirectStream = function() return 1 end,
  StudioSync_DirectLan = function(port) lan_ports[#lan_ports + 1] = port; return port > 0 and 1 or 0 end,
}
reaper = setmetatable(fns, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local listings, jsons = {}, {}
band.files = function(d, e) local out = {}; for _, f in ipairs(listings[d] or {}) do if not e or f:sub(-#e) == e then out[#out + 1] = f end end; return out end
band.read_json = function(p) return jsons[p] end
local hidden = {}
package.loaded.services = { run_hidden = function(name) return hidden[name] end, TMP = "T", is_device_id = function(id) return type(id) == "string" and #id > 10 end,
  my_device_id = function() return "MEMEMEMEMEME" end, tailnet_now = function() return true, "james-main", "tail99.ts.net" end }
local trusted = { nat = true }
package.loaded.groups = { trusted = function() return trusted end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end, sonobus_secret = function() return "s3cret" end }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function() return true end }
local here = {}
package.loaded.presence = { peers = function() local t = {}; for _, u in ipairs(here) do t[#t + 1] = { user = u } end; return t end }
package.loaded.access = { read = function() return nil end, shows = function() return true end }
package.loaded.removal = { mark = function() return false end }
local hub_user = "James"
package.loaded.hub = { view = function() return { studio = hub_user } end }
local nat, direct = require("nat"), require("direct")

local PUB_ME, PUB_C, PUB_L = string.rep("ab", 32), string.rep("cd", 32), string.rep("ef", 32)
local yes = function() return true end

-- 1. Who relays (backlog 1.32): the role stays with a computer whose relay was reached from outside, while it's online
local me = { user = "James", device = "MEMEMEMEMEME", ts = { ["tail99.ts.net"] = "james-main.tail99.ts.net" }, nat = { pub = PUB_ME, tailnet = true } }
local chilio = { user = "Chilio", device = "CHILIOCHILIO", nat = { pub = PUB_C, tailnet = false } }
local laptop = { user = "Laptop", device = "LAPTOPLAPTOP", ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net" },
  nat = { pub = PUB_L, tailnet = true, relay = "203.0.113.5:47298", relay_reach = "203.0.113.5" } }
local on, addr, who = nat.relay_plan("Chilio", "James", { me, laptop }, yes, { James = true, Laptop = true })
assert(on == false and addr == "203.0.113.5:47298" and who == "Laptop", "the hub (James) isn't proven, the laptop's relay was reached from outside and it's online: the laptop relays")
assert(nat.relay_plan("Laptop", "James", { me, laptop }, yes, { James = true, Laptop = true }) == true, "and the laptop itself runs it")
assert(nat.relay_plan("James", "James", { me, laptop }, yes, { James = true, Laptop = true }) == false, "and the hub doesn't")
assert(nat.relay_plan("James", "James", { me, laptop }, yes, { James = true }) == true, "the proven laptop offline: the hub, as before")
assert(nat.relay_plan("James", "James", { me, laptop }, yes) == true, "nothing known of who's online: the hub, as before")
local cg = { user = "Laptop", device = "LAPTOPLAPTOP", nat = { pub = PUB_L, relay = "203.0.113.5:47298", relay_reach = "203.0.113.5", cgnat = true } }
assert(nat.relay_plan("James", "James", { me, cg }, yes, { James = true, Laptop = true }) == true, "a computer behind CGNAT never counts as proven")
local me_proven = { user = "James", device = "MEMEMEMEMEME", nat = { pub = PUB_ME, relay_reach = "198.51.100.7", relay = "198.51.100.7:47298" } }
assert(nat.relay_plan("James", "James", { me_proven, laptop }, yes, { James = true, Laptop = true }) == true, "a proven hub keeps it, whoever else is proven")
assert(select(2, nat.relay_plan("Chilio", "James", { me, laptop }, function(d) return d.user ~= "Laptop" end, { James = true, Laptop = true })) == nil,
  "a proven computer whose file its own computer didn't write: not used")

-- 2. Learning it: the relay reached from a public address remembers this public address; the devices file says so; CGNAT the same way
local root = "J:/St/Smiley"
jsons[root .. "/_band/band.json"] = { id = "smiley-1" }
status_json = '{"on":true,"public":"198.51.100.7:51234","relay":{"on":true,"running":true,"outside":40,"wan":"","cgnat":false},"peers":{}}'
nat.learn(root, band.json_decode(status_json))
assert(nat.remembered(root).reach == "198.51.100.7", "reached from outside 40 s ago: remembered at this public address")
local e = nat.entry(root, true)
assert(e.relay_reach == "198.51.100.7" and e.cgnat == nil, "the devices file says this computer's relay is reachable")
status_json = '{"on":true,"public":"192.0.2.44:5000","peers":{}}'
assert(nat.entry(root, true).relay_reach == nil, "a new public address (another network): no claim until it's reached there")
status_json = '{"on":true,"public":"198.51.100.7:51234","relay":{"on":true,"running":true,"outside":-1,"wan":"100.70.1.2","cgnat":true},"peers":{}}'
nat.learn(root, band.json_decode(status_json))
assert(nat.entry(root, true).cgnat == true, "CGNAT seen: the devices file says so (the others don't make it the relay)")
status_json = '{"on":true,"public":"198.51.100.7:51234","relay":{"on":true,"running":true,"outside":-1,"wan":"198.51.100.7","cgnat":false},"peers":{}}'
nat.learn(root, band.json_decode(status_json))
assert(nat.entry(root, true).cgnat == nil, "the router's WAN address the public one again: no longer said")

-- 3. Health's relay rows
local rows = nat.rows_from({ turn = "203.0.113.5:47298", relay_ok = false, relay_answers = true, relay_bad = 2, relay_hold = 55, peers = {} }, {}, false, true, "Laptop")
assert(#rows == 1 and rows[1][1] == "nat relay" and rows[1][5]:find("answers but didn't carry the last 2 links") and rows[1][5]:find("55 s"), rows[1] and rows[1][5])
rows = nat.rows_from({ turn = "203.0.113.5:47298", relay_ok = false, relay_answers = false, relay_bad = 0, peers = {} }, {}, false, true, "Laptop")
assert(#rows == 1 and rows[1][5]:find("doesn't answer"), "a relay that doesn't answer at all: as before")
rows = nat.rows_from({ relay = { on = true, running = true, bytes = 0, over_cap = 0, outside = 600, cgnat = true, wan = "100.70.1.2" }, peers = {} }, {}, false, true, "James")
assert(#rows == 2 and rows[1][4]:find("Reached from outside this network 10 min ago") and rows[2][1] == "nat cgnat" and rows[2][5]:find("100%.70%.1%.2"),
  "the relay hub: reached from outside, and behind CGNAT (its router's own address named)")
local t = nat.tailscale_row(true, {})
assert(t and t[5]:find("still need Tailscale here: the Hop plug%-in") and t[5]:find("Phone pages on this network"), "off the tailnet: what still needs Tailscale")
t = nat.tailscale_row(false, { "Chilio" })
assert(t and t[5]:find("^Reached without Tailscale: Chilio") and t[5]:find("browser guests"), "reaching Chilio without it: what doesn't reach Chilio")
assert(nat.tailscale_row(false, {}) == nil, "on the tailnet and nobody without it: no row")

-- 4. The direct link's stale "can't reach" (backlog 1.31): a peer it stopped trying isn't shown failing
local now = os.time()
direct_status = '{"listening":true,"bind":"100.64.0.5","peers":{"james-laptop.tail99.ts.net:47281":{"ok":false,"ms":-1,"at":' .. (now - 300) ..
  ',"error":"timed out"},"nat:CHILIOCHILIO":{"ok":true,"ms":31,"at":' .. now .. ',"error":""}}}'
status_json = '{"on":true,"peers":{"CHILIOCHILIO":{"state":"up","path":"direct"}}}'
local cfg = { root = root, user = "James" }
local okh, text = direct.health_line(cfg)
assert(okh == true and not text:find("can't reach") and text:find("reaches"), text)
direct_status = direct_status:gsub(tostring(now - 300), tostring(now - 5))
okh, text = direct.health_line(cfg)
assert(okh == false and text:find("can't reach james%-laptop"), "one still being tried shows: " .. text)

-- 5. The hello for a computer not here, over a quiet link (rt-linkmove round 6 item 8)
listings[root .. "/_band/devices"] = { "James.json", "Chilio.json", "Laptop.json" }
jsons[root .. "/_band/devices/James.json"], jsons[root .. "/_band/devices/Chilio.json"], jsons[root .. "/_band/devices/Laptop.json"] = me, chilio, laptop
here = {} -- (Chilio's status files are stale here: not here)
status_json = '{"on":true,"public":"198.51.100.7:51234","peers":{}}'
clock = clock + 10
local peers = nat.peers(cfg, { song = "Song", room = "main" }, "direct")
local s = band.json_decode(setups[#setups])
local quiet
for _, p in ipairs(s.peers) do if p.device == "CHILIOCHILIO" then quiet = p.quiet end end
assert(#peers == 0 and quiet == true, "the direct link's call: Chilio (not here, no Tailscale) gets a quiet link, not a peer here")
local n = #setups
clock = clock + 3
nat.peers(cfg, { song = "Song", room = "main" })
assert(#setups == n, "live audio's call in between keeps the same setup (no link dropped and made again)")
status_json = '{"on":true,"public":"198.51.100.7:51234","peers":{"CHILIOCHILIO":{"state":"up","path":"direct","quiet":true}}}'
local all, users = direct.studio_peers(cfg, "Song")
local has = false
for _, p in ipairs(all) do has = has or p == "nat:CHILIOCHILIO" end
assert(has and users["nat:CHILIOCHILIO"] == "Chilio", "its quiet link up: the studio's computers include nat:CHILIOCHILIO, so the hello reaches it: " .. table.concat(all, " "))
here = { "Chilio" }
clock = clock + 3
nat.peers(cfg, { song = "Song", room = "main" }, "direct")
s = band.json_decode(setups[#setups])
quiet = "?"
for _, p in ipairs(s.peers) do if p.device == "CHILIOCHILIO" then quiet = p.quiet end end
assert(quiet == nil, "once Chilio is here: an ordinary link")

-- 6. The video-call pages' ICE servers (3.2 A)
local webcall = require("webcall")
hub_user = "Laptop"
here = {}
clock = clock + 3
nat.peers(cfg, { song = "Song", room = "main" }, "direct")
local m = webcall.model(webcall.me(cfg), os.time(), false)
assert(type(m.ice) == "table" and m.ice[1].urls[1] == "stun:stun.cloudflare.com:3478", "STUN servers for the pages")
assert(m.ice[2] and m.ice[2].urls[1] == "turn:203.0.113.5:47298?transport=udp" and m.ice[2].username == "MEMEMEMEMEME" and m.ice[2].credential == "00112233445566778899aabbccddeeff",
  "the studio's relay as TURN with this computer's own credentials")
trusted.nat = false
m = webcall.model(webcall.me(cfg), os.time(), false)
assert(m.ice == nil, "the connection without Tailscale off: no ICE servers (host candidates, as over Tailscale)")
trusted.nat = true

-- 7. Phone pages on this computer's own network (4.7)
assert(nat.lan_firewall_command("C:\\REAPER\\reaper.exe", 47281):find('protocol=TCP localport=47281 remoteip=LocalSubnet'), "the rule: TCP, the link's port, this network only")
lan_ports = {}
nat.lan_tick(root)
assert(lan_ports[#lan_ports] == 0, "off by default: nothing listens")
ext[band.SECTION .. "/" .. nat.lan_key(root)] = "1"
nat.lan_tick(root)
assert(lan_ports[#lan_ports] == 0, "on, but Windows has no rule for it yet: still nothing (no Windows box in REAPER's face)")
hidden["nat-lan-fw"] = "Rule Name: StudioSync phone pages on this network\nProgram: C:\\REAPER\\reaper.exe\nLocalPort: 47281\nRemoteIP: LocalSubnet"
nat.lan_tick(root)
assert(lan_ports[#lan_ports] == 47281, "on, with the rule: listening on the link's port")
local r = nat.lan_row({ bind = "192.168.1.20", port = 47281, error = "" }, "abcdef01", true)
assert(r[2] == true and r[4]:find("http://192%.168%.1%.20:47281/%?t=abcdef01") and r[4]:find("No microphone"), r[4])
r = nat.lan_row({ bind = "", port = 0, error = "this computer's address on its network isn't a private one" }, "abcdef01", true)
assert(r[2] == false and r[5]:find("isn't a private one"), "not listening says why")
assert(nat.lan_row({}, "x", false)[5]:find("firewall rule"), "no rule: Health says it waits for it")
trusted.nat = false
nat.lan_tick(root)
assert(lan_ports[#lan_ports] == 0, "the studio's connection without Tailscale off: phone pages off too")
print("ok")
