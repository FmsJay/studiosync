-- The connection without Tailscale's Lua side (lib/nat.lua, stage 1: live audio): which pairs go this way (both read the same two devices
-- files), the STUN list, the setup handed to the extension (only bandmates in the room whose own computer wrote their file, the studio's
-- secret, nothing while the studio has it off), live audio's peer list with their Tailscale names swapped for "nat:<device>", the devices
-- file entry (lib/removal.lua publish), the Windows firewall rule's words, and Health's rows. The extension itself: tests/nat_test.cpp and
-- tests/nat_audio_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
local setups, stops, status_json, keys_asked = {}, 0, "{}", 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  StudioSync_NatKey = function() keys_asked = keys_asked + 1; return string.rep("ab", 32) end,
  StudioSync_NatSetup = function(json) setups[#setups + 1] = json; return 1 end,
  StudioSync_NatStatus = function() return status_json end,
  StudioSync_NatStop = function() stops = stops + 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local listings, jsons = {}, {}
band.files = function(d, e) local out = {}; for _, f in ipairs(listings[d] or {}) do if not e or f:sub(-#e) == e then out[#out + 1] = f end end; return out end
band.read_json = function(p) return jsons[p] end
local hidden_out
package.loaded.services = { run_hidden = function(name) return name == "nat-fw" and hidden_out or nil end, TMP = "T",
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "MEMEMEMEMEME" end,
  tailnet_now = function() return nil, nil end }
local trusted, secret, tailnet = { nat = true }, "s3cret", { name = "x", suffix = "tail99.ts.net" }
package.loaded.groups = { trusted = function() return trusted end, tailnet = function() return tailnet end, sonobus_secret = function() return secret end }
local device_ok = {}
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function(_, u) return device_ok[u] ~= false end }
local here = { "Chilio", "Laptop" }
package.loaded.presence = { peers = function() local t = {}; for _, u in ipairs(here) do t[#t + 1] = { user = u } end; return t end }
package.loaded.access = { read = function() return nil end, shows = function(set, song) return not set or set[song] == true end }
local nat = require("nat")

local PUB_ME, PUB_C, PUB_L = string.rep("ab", 32), string.rep("cd", 32), string.rep("ef", 32)
local me = { user = "James", device = "MEMEMEMEMEME", ts = { ["tail99.ts.net"] = "james-main.tail99.ts.net" }, nat = { pub = PUB_ME, tailnet = true } }
local chilio = { user = "Chilio", device = "CHILIOCHILIO", nat = { pub = PUB_C, tailnet = false } } -- (no Tailscale at all)
local laptop = { user = "Laptop", device = "LAPTOPLAPTOP", ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net" }, nat = { pub = PUB_L, tailnet = true } }

-- Which pairs go this way: pure, and the same from both sides
assert(nat.pair_needs(me, chilio, "tail99.ts.net") and nat.pair_needs(chilio, me, "tail99.ts.net"), "someone without Tailscale: this way, from either side")
assert(not nat.pair_needs(me, laptop, "tail99.ts.net") and not nat.pair_needs(laptop, me, "tail99.ts.net"), "both on the studio's tailnet: Tailscale, as before")
local off = { user = "Laptop", device = "LAPTOPLAPTOP", ts = laptop.ts, nat = { pub = PUB_L, tailnet = false } }
assert(nat.pair_needs(me, off, "tail99.ts.net") and nat.pair_needs(off, me, "tail99.ts.net"), "a name on the tailnet but off it now: this way")
assert(nat.pair_needs(me, laptop, nil), "a studio without a tailnet: this way for everyone with a key")
assert(not nat.pair_needs(me, { user = "Old", device = "OLDOLDOLDOLD" }, nil), "no key in their file (older StudioSync, or the setting off there): not this way")
assert(not nat.pair_needs(me, { user = "X", device = "XXXXXXXXXXXX", nat = { pub = "zz" } }, nil), "a key that isn't 64 hex: not this way")

-- The STUN list
assert(nat.stun_list(nil)[1] == "stun.cloudflare.com:3478" and #nat.stun_list("") == 2, "the public list by default")
local own = nat.stun_list("hub.example.net:3478 junk 10.0.0.2:40041")
assert(#own == 2 and own[1] == "hub.example.net:3478" and own[2] == "10.0.0.2:40041", "the studio's own list, anything that isn't host:port left out")

-- The devices file entry
assert(nat.entry("R", true).pub == PUB_ME and nat.entry("R", true).tailnet == true and nat.entry("R", false).tailnet == false, "entry: this computer's key and whether it's on the tailnet")
trusted.nat = nil
assert(nat.entry("R", true) == nil, "entry: nothing while the studio has it off")
trusted.nat = true

-- The setup handed to the extension, and live audio's peers
local root = "J:/St/Smiley"
listings[root .. "/_band/devices"] = { "James.json", "Chilio.json", "Laptop.json", "Ghost.json" }
jsons[root .. "/_band/devices/James.json"], jsons[root .. "/_band/devices/Chilio.json"], jsons[root .. "/_band/devices/Laptop.json"] = me, chilio, laptop
jsons[root .. "/_band/devices/Ghost.json"] = { user = "Someone", device = "GHOSTGHOSTGH", nat = { pub = PUB_C, tailnet = false } } -- (a file naming someone else: not theirs)
local cfg = { root = root }
local peers, users, devs = nat.peers(cfg, { song = "Nostalgia", room = "main" })
assert(#peers == 1 and peers[1] == "nat:CHILIOCHILIO" and users[peers[1]] == "Chilio" and devs.CHILIOCHILIO, "peers: only Chilio (the laptop is on the tailnet; the ghost file isn't its writer's)")
assert(#setups == 1, "set up once")
local s = band.json_decode(setups[1])
assert(s.folder == root .. "/_band/nat" and s.me == "MEMEMEMEMEME" and s.secret == "s3cret" and s.port == 47282 and #s.stun == 2, "setup: the folder, this device, the secret, the port, STUN")
assert(#s.peers == 1 and s.peers[1].device == "CHILIOCHILIO" and s.peers[1].pub == PUB_C, "setup: Chilio's device and key")
assert(s.key:find("%.studiosync/nat%-key$"), "setup: the key file beside the update key: " .. tostring(s.key))
clock = clock + 5
nat.peers(cfg, { song = "Nostalgia", room = "main" })
assert(#setups == 1, "the same setup isn't handed over again")
here = { "Laptop" }
clock = clock + 5
peers = nat.peers(cfg, { song = "Nostalgia", room = "main" })
assert(#peers == 0 and stops == 1, "Chilio left the room: nobody this way, the links stopped")
here = { "Chilio" }
device_ok.Chilio = false
clock = clock + 5
peers = nat.peers(cfg, { song = "Nostalgia", room = "main" })
assert(#peers == 0, "a file Syncthing says another computer wrote: not trusted")
device_ok.Chilio = nil
trusted.nat = nil
clock = clock + 5
peers = nat.peers(cfg, { song = "Nostalgia", room = "main" })
assert(#peers == 0, "the studio turned it off: nothing")
trusted.nat = true

-- Live audio's list: the Tailscale entry of a bandmate who goes this way is swapped out
local list, u = nat.merge({ "chilio.tail99.ts.net:47281", "james-laptop.tail99.ts.net:47281" },
  { ["chilio.tail99.ts.net:47281"] = "CHILIOCHILIO", ["james-laptop.tail99.ts.net:47281"] = "LAPTOPLAPTOP" },
  { ["chilio.tail99.ts.net:47281"] = "Chilio", ["james-laptop.tail99.ts.net:47281"] = "Laptop" },
  { "nat:CHILIOCHILIO" }, { ["nat:CHILIOCHILIO"] = "Chilio" }, { CHILIOCHILIO = true })
assert(#list == 2 and list[1] == "james-laptop.tail99.ts.net:47281" and list[2] == "nat:CHILIOCHILIO" and u["nat:CHILIOCHILIO"] == "Chilio" and u[list[1]] == "Laptop", "merge: Chilio by nat:, the laptop by Tailscale")

-- Off the tailnet here
assert(nat.off_tailnet(root), "Tailscale not up here: off the studio's tailnet")
package.loaded.services.tailnet_now = function() return "x", "tail99.ts.net" end
assert(not nat.off_tailnet(root), "on it")

-- The firewall rule
local cmd = nat.firewall_command("C:\\REAPER\\reaper.exe")
assert(cmd:find('name="StudioSync connection without Tailscale"', 1, true) and cmd:find("protocol=UDP localport=47282-47297", 1, true) and not cmd:find("remoteip"), "the rule: UDP 47282-47297, from any address")
assert(nat.firewall_in("Rule Name: StudioSync connection without Tailscale\nProgram: C:\\REAPER\\reaper.exe\nLocalPort: 47282-47297", "C:\\REAPER\\reaper.exe"), "the rule found")
assert(not nat.firewall_in("Rule Name: StudioSync direct link\nProgram: C:\\REAPER\\reaper.exe\nLocalPort: 47281", "C:\\REAPER\\reaper.exe"), "the direct link's rule isn't it")

-- Health
local ok, text = nat.peer_text({ state = "up", path = "direct", up_s = 12 }, "Chilio")
assert(ok and text == "Chilio: direct (through both NATs), up 12s", text)
ok, text = nat.peer_text({ state = "up", path = "relayed", up_s = 3 }, "Chilio")
assert(ok and text:find("relayed"), text)
ok, text = nat.peer_text({ state = "connecting", why = "" }, "Chilio")
assert(not ok and text == "Chilio: connecting", text)
ok, text = nat.peer_text({ state = "waiting", why = "ICE found no path (both behind strict NATs and no relay?)" }, "Chilio")
assert(not ok and text:find("trying again shortly") and text:find("no path"), text)
local rows = nat.rows_from({ nat = "strict", peers = { CHILIOCHILIO = { state = "up", path = "direct", up_s = 1 } } }, { CHILIOCHILIO = "Chilio" }, true, false)
assert(#rows == 3 and rows[1][2] == true and rows[1][4]:find("Chilio: direct") and rows[2][1] == "nat strict" and rows[3][1] == "nat firewall", "rows: the bandmate, strict NAT, the firewall")
rows = nat.rows_from({ nat = "easy", peers = {} }, {}, true, false)
assert(#rows == 0, "nobody this way and an easy NAT: no rows (and no firewall nag)")
rows = nat.rows_from({ nat = "blocked", error = "can't write J:/x", peers = {} }, {}, false, true)
assert(#rows == 2 and rows[1][5]:find("can't write") and rows[2][5]:find("UDP may be blocked"), "rows: an error and blocked UDP")
status_json = '{"on":true,"nat":"easy","peers":{"CHILIOCHILIO":{"state":"up","path":"direct","up_s":4}}}'
hidden_out = "Rule Name: StudioSync connection without Tailscale\nProgram: C:\\REAPER\\reaper.exe\nLocalPort: 47282-47297"
here = { "Chilio" }
clock = clock + 5
nat.peers(cfg, { song = "Nostalgia", room = "main" })
rows = nat.health_rows(cfg)
assert(#rows == 1 and rows[1][4]:find("^Without Tailscale: Chilio: direct"), "Health: Chilio by name, the rule there: one green row")
print("ok")
