-- rt-hubsmall (2026-11-21): the hub's live mix and room lists after the first four-computer sound test. With a stand-in REAPER:
--   2. the status's round trip (lrtt) held, so a status doesn't change every pass (a computer the link didn't reach everywhere rewrote its
--      status file every 2 s);
--   3. a computer neither side lists, while a computer here reaches it (its hub.sees), goes on the live audio list, so audio flows and the
--      other side's heard_merge adds this one;
--   4. a sender heard here that falls silent (its talkback goes to someone else) stays listed while it's still in the room;
--   5. the mix host's network probe asks for the route in use (Windows' route + interface metric, macOS's primary service, Linux's
--      `ip route get`), with the fallback through a VPN or exit node;
--   6. the live mix's host waits the song hub's REACH_SETTLE before a move that is only about reach, SETTLE for wired / round trip.
-- (1, the extension's fallbacks and rescues, is a C++ change for the next extension release: docs/rt/rt-hubsmall.md.)
package.path = "lib/?.lua;" .. package.path
local clock, ext, front = 1000, {}, "P1"
local E = { running = false, peers = {}, json = nil, rtt = {} }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  EnumProjects = function() return front end,
  GetPlayState = function() return 0 end,
  StudioSync_LiveAudioStart = function() E.running = true; return 1 end,
  StudioSync_LiveAudioStop = function() E.running = false end,
  StudioSync_LiveAudioPeers = function(js) E.json = js; return 1 end,
  StudioSync_LiveAudioPeerSet = function() return 1 end,
  StudioSync_LiveAudioStatus = function()
    local band = require("band")
    local peers = {}
    for p, r in pairs(E.rtt) do peers[p] = { resolved = true, streaming = true, rtt_ms = r, gain = 1 } end
    for p, v in pairs(E.peers) do peers[p] = v end
    return band.json_encode({ running = E.running, first = 0, nch = 1, kbps = 128, peers = peers, not_here_peers = E.nhp or {} })
  end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
local function src(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return (s:gsub("\r\n", "\n")) end
package.loaded.services = { run_hidden = function(name) return name == "direct-fw" and
  "Rule Name: StudioSync direct link\r\nLocalPort: 47281\r\nProtocol: UDP\r\nProgram: C:\\REAPER\\reaper.exe\r\n" or nil end, TMP = "T",
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "MEMEMEMEMEME" end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "t.ts.net" } end,
  sonobus_secret = function() return "s3cret" end, live_audio = function() return true end, live_hub = function() return 0 end }
local guests = {}
package.loaded.removal = { guest_names = function() return guests end }
local fresh, here = {}, {} -- (presence: the statuses fresh here; everyone within a window, by user -> age)
package.loaded.presence = { peers = function() return fresh end,
  here = function(_, _, _, within) local t = {}; for u, age in pairs(here) do if age < within then t[#t + 1] = u end end; table.sort(t); return t end }
local hub = require("hub")
local direct = require("direct")
local DESK, LAP, MAC, LIN = "desk.t.ts.net:47281", "lap.t.ts.net:47281", "mac.t.ts.net:47281", "lin.t.ts.net:47281"
local peers_here, users_here = { DESK }, { [DESK] = "Desk" }
direct.peers = function() return peers_here, {}, users_here end
direct.port = function() return 47281 end
local la = require("liveaudio")
local livex = require("livex")
local cfg = { root = "R", user = "Lin" }

-- ---- 2. the status's round trip, held ---------------------------------------------------------------------------------------------------
-- (three bandmates' round trips jitter by tens of ms each second, as the desktop's view showed: 132, 82, 0.5 ms)
math.randomseed(7)
local tens_moves, held_moves, last_t, last_h = 0, 0, nil, nil
for i = 1, 60 do -- (two minutes of Live sync passes, every 2 s)
  clock = 2000 + i * 2
  E.rtt = { [DESK] = 120 + math.random(-25, 25), [LAP] = 80 + math.random(-25, 25), [MAC] = 1 + math.random(0, 3) }
  local t = livex.rtt_tens(la.status())
  local h = livex.status_part("P1").lrtt
  if last_t and t ~= last_t then tens_moves = tens_moves + 1 end
  if last_h and h ~= last_h then held_moves = held_moves + 1 end
  last_t, last_h = t, h
end
assert(tens_moves >= 15, "the round trip in tens alone moves most passes (" .. tens_moves .. " in 60): what the status said before")
assert(held_moves <= 2, "held: the status's lrtt moved " .. held_moves .. " times in two minutes of jitter")
-- a real change lands within LRTT_FLOOR s and the same value goes to this computer's own ranking
E.rtt = { [DESK] = 260, [LAP] = 220, [MAC] = 200 }
clock = clock + livex.LRTT_FLOOR
assert(livex.status_part("P1").lrtt == 230, "a real change (40 -> 230 ms): said at once past the floor")
clock = clock + 2
E.rtt = { [DESK] = 260, [LAP] = 240, [MAC] = 200 }
assert(livex.status_part("P1").lrtt == 230, "and 10 ms more isn't news")
E.rtt = {}
assert(livex.status_part("P1").lrtt == nil and livex.lrtt({ peers = {} }, clock) == nil, "nothing measured: nothing said")
assert(src("lib/livex.lua"):find("rtt = livex.lrtt(st, reaper.time_precise())", 1, true), "the pick ranks this computer by the held value too, as the others read it")

-- ---- 3. a computer neither side lists, vouched for by one that reaches it ----------------------------------------------------------------
-- Lin's room lists Desk; Mac's status is 70 s old here (Syncthing behind) and Mac's room doesn't list Lin either; Desk's fresh status says its
-- link reaches Mac.
local function st(user, sees) return { user = user, time = "t", hub = { ext = "1.0.31", sees = sees } } end
local peer_of = function(u) return ({ Mac = MAC, Lap = LAP, Gus = "gus.t.ts.net:47281" })[u] end
local list, added, by = la.vouch_merge({ DESK }, { [DESK] = "Desk" }, { st("Desk", { "Lap", "Lin", "Mac" }) }, { Desk = true, Mac = true }, peer_of, {})
assert(table.concat(list, " ") == DESK .. " " .. MAC and added[MAC] == "Mac" and by.Mac == "Desk", "Mac added, vouched for by Desk: " .. table.concat(list, " "))
list = la.vouch_merge({ DESK }, { [DESK] = "Desk" }, { st("Desk", { "Lin" }) }, { Desk = true, Mac = true }, peer_of, {})
assert(#list == 1, "nobody here reaches Mac: not added (it may have left)")
list = la.vouch_merge({ DESK }, { [DESK] = "Desk" }, { st("Desk", { "Mac" }) }, { Desk = true }, peer_of, {})
assert(#list == 1, "Mac's status older than hub.VOUCH here (not near): not added")
list = la.vouch_merge({ DESK }, { [DESK] = "Desk" }, { st("Gus", { "Mac" }) }, { Desk = true, Mac = true, Gus = true }, peer_of, { Gus = true })
assert(#list == 1, "a guest's word isn't counted")
list = la.vouch_merge({ DESK }, { [DESK] = "Desk" }, { st("Desk", { "Mac" }) }, { Desk = true, Mac = true }, function() return nil end, {})
assert(#list == 1, "not a studio computer trusted here (no devices file of its own, a guest without the song): not added")
list = la.vouch_merge({ DESK }, { [DESK] = "Desk" }, { st("Desk", { "Lap" }), st("Lap", { "Desk" }) }, { Desk = true, Lap = true }, peer_of, {})
assert(#list == 1, "Lap's status is fresh here: the room's own list decides (no Tailscale name there means none here either)")
list = la.vouch_merge({ DESK, MAC }, { [DESK] = "Desk", [MAC] = "Mac" }, { st("Desk", { "Mac" }) }, { Desk = true, Mac = true }, peer_of, {})
assert(#list == 2, "already listed (heard): once")
-- the peer from the person's name: its own devices file, written by its own computer, a guest's list with the song
local files = {}
local read_json, files_fn = band.read_json, band.files
band.read_json = function(path) return files[path] end
band.files = function(dir, ext2)
  local t = {}
  for path in pairs(files) do local d, f = path:match("^(.*)/([^/]+)$"); if d == dir and f:sub(-#ext2) == ext2 then t[#t + 1] = f end end
  table.sort(t)
  return t
end
local wrote_itself = { MACMACMACMAC = true }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function(_, _, dev) return wrote_itself[dev] or false end }
package.loaded.access = { read = function() return nil end, shows = function(set, song) return not set or set[song] == true end }
files["R/_band/devices/Mac.json"] = { user = "Mac", device = "MACMACMACMAC", ts = { ["t.ts.net"] = "mac.t.ts.net" } }
files["R/_band/devices/Rogue.json"] = { user = "Rogue", device = "ROGUEROGUERO", ts = { ["t.ts.net"] = "rogue.t.ts.net" } }
local direct_studio_peer = direct.studio_peer
assert(la.peer_of_user(cfg, "Song", "Mac") == MAC, "Mac -> its peer")
assert(la.peer_of_user(cfg, "Song", "Rogue") == nil, "a devices file its computer didn't write: none")
assert(la.peer_of_user(cfg, "Song", "Nobody") == nil, "no devices file: none")
band.read_json, band.files = read_json, files_fn
local _ = direct_studio_peer

-- Live sync's tick end to end: Mac goes on the list handed to the extension while Desk vouches, and off once nobody does
la.peer_of_user = function(_, _, u) return peer_of(u) end
local b = { song = "Song", room = "main" }
local function sent() return table.concat(band.json_decode(E.json).peers, " ") end
local function tick(dt) clock = clock + (dt or 1); la.tick(cfg, b, "P1") end
fresh, here = { st("Desk", { "Lin", "Mac" }) }, { Desk = 1, Mac = 70 }
E.rtt, E.peers = {}, {}
tick(); tick()
assert(sent() == DESK .. " " .. MAC, "the tick sends to Mac too: " .. sent())
local said = 0
for _, l in ipairs(logs) do if l:find("Mac's status is late here, but Desk's computer reaches it", 1, true) then said = said + 1 end end
assert(said == 1, "said once: " .. said)
fresh = { st("Desk", { "Lin" }) }
tick()
assert(sent() == DESK, "Desk's link lost Mac: off the list again")

-- ---- 4. a sender heard here stays listed while it's in the room, silent or not -------------------------------------------------------------
local kept, now = {}, 500
local studio = { ["100.3.3.3:47281"] = { LAP, "Lap" } }
local function by_addr(a) local p = studio[a]; if p then return p[1], p[2] end end
list = la.heard_merge({ DESK }, { not_here_peers = { ["100.3.3.3:47281"] = { ago = 0.1 } }, peers = {} }, by_addr, kept, now, { Lap = true })
assert(#list == 2, "Lap heard (its room lists this computer, this one's doesn't yet): added")
now = now + 40 -- (Lap holds Talk to someone else: nothing comes here)
list = la.heard_merge({ DESK }, { peers = { [LAP] = { heard_ago = 40 } } }, by_addr, kept, now, { Lap = true })
assert(#list == 2, "silent 40 s, but its status is still near (late, not gone): kept, so its next word to everyone is heard at once")
list = la.heard_merge({ DESK }, { peers = { [LAP] = { heard_ago = 41 } } }, by_addr, kept, now + 1, {})
assert(#list == 1 and next(kept) == nil, "its status gone past hub.VOUCH (it left): off the list")
kept = {}
la.heard_merge({ DESK }, { not_here_peers = { ["100.3.3.3:47281"] = { ago = 0.1 } }, peers = {} }, by_addr, kept, now)
list = la.heard_merge({ DESK }, { peers = { [LAP] = { heard_ago = 16 } } }, by_addr, kept, now + 16)
assert(#list == 1, "no status here at all: HEARD_S, as before")
-- end to end: heard, then silent for a minute with its status 60 s old here
fresh, here = { st("Desk", { "Lin" }) }, { Desk = 1, Lap = 60 }
la.peer_of_addr = function(_, _, a) return by_addr(a) end
E.nhp = { ["100.3.3.3:47281"] = { ago = 0.1 } }
tick()
assert(sent() == DESK .. " " .. LAP, "heard: on the list: " .. sent())
E.nhp, E.peers = {}, { [LAP] = { resolved = true, heard_ago = 60 } }
tick(60)
assert(sent() == DESK .. " " .. LAP, "a minute of talkback elsewhere: still on the list")
here = { Desk = 1 }
tick()
assert(sent() == DESK, "its status gone: off")
E.peers = {}

-- ---- 5. the network probe asks for the route in use -------------------------------------------------------------------------------------
-- (the desktop: Ethernet and Wi-Fi both up, both default routes with RouteMetric 0; Windows sends over Ethernet by its interface metric
-- 25 against Wi-Fi's 30. Sorting by RouteMetric alone could name either.)
assert(livex.NET_WIN:find("Find-NetRoute", 1, true) and livex.NET_WIN:find("InterfaceMetric", 1, true) and not livex.NET_WIN:find("Sort-Object RouteMetric", 1, true),
  "Windows: the route Windows picks (route + interface metric), not the lowest RouteMetric alone")
assert(livex.NET_WIN:find("-Physical", 1, true) and livex.NET_WIN:find("'Unspecified'", 1, true), "through a VPN or exit node: the best physical adapter")
assert(not livex.NET_WIN:find("%", 1, true) and select(2, livex.NET_WIN:gsub('"', "")) == 2, "one quoted -Command, nothing a batch file would expand")
assert(livex.NET_UNIX:find("ip -o route get", 1, true) and livex.NET_UNIX:find("route -n get default", 1, true) and livex.NET_UNIX:find("scutil --nwi", 1, true),
  "Linux: the kernel's own choice; macOS: the primary service's interface, then scutil's order")
assert(livex.net_parse("802.3\r\n") == "wired" and livex.net_parse("Native 802.11\r\n") == "wifi" and livex.net_parse("Unspecified\r\n") == nil, "the words, as before")
-- the shell part with stand-in tools, where there's a POSIX shell (the Mac and Linux CI)
if package.config:sub(1, 1) == "/" then
  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute("mkdir -p '" .. dir .. "/bin' '" .. dir .. "/sys/wlan0/wireless' '" .. dir .. "/sys/eth0'"))
  local function tool(name, body) local f = assert(io.open(dir .. "/bin/" .. name, "w")); f:write("#!/bin/sh\n" .. body .. "\n"); f:close(); os.execute("chmod +x '" .. dir .. "/bin/" .. name .. "'") end
  local script = dir .. "/net.sh"
  local f = assert(io.open(script, "w")); f:write((livex.NET_UNIX:gsub("/sys/class/net", dir .. "/sys"))); f:close()
  local function run() local p = assert(io.popen("PATH='" .. dir .. "/bin':$PATH sh '" .. script .. "'")); local out = p:read("a"); p:close(); return livex.net_parse(out) end
  tool("uname", "echo Linux")
  tool("ip", [[case "$*" in *"route get"*) echo "1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.5 uid 1000";; *"show default"*) printf "default via 192.168.1.1 dev wlan0 proto dhcp metric 600\ndefault via 192.168.1.1 dev eth0 proto dhcp metric 100\n";; esac]])
  assert(run() == "wired", "Linux, both up, the kernel routes over eth0: wired")
  tool("ip", [[case "$*" in *"route get"*) echo "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.6 uid 1000";; esac]])
  assert(run() == "wifi", "Linux, routed over wlan0: Wi-Fi")
  tool("ip", [[case "$*" in *"route get"*) echo "1.1.1.1 dev tailscale0 table 52 src 100.1.2.3 uid 1000";; *"show default"*) printf "default dev tailscale0 metric 0\ndefault via 192.168.1.1 dev wlan0 proto dhcp metric 50\ndefault via 192.168.1.1 dev eth0 proto dhcp metric 100\n";; esac]])
  assert(run() == "wifi", "Linux through an exit node: the lowest-metric default that isn't a tunnel (wlan0)")
  tool("uname", "echo Darwin")
  tool("networksetup", [[printf "Hardware Port: Ethernet\nDevice: en0\n\nHardware Port: Wi-Fi\nDevice: en1\n"]])
  tool("route", [[printf "  interface: en0\n"]])
  assert(run() == "wired", "macOS, the primary service is Ethernet: wired")
  tool("route", [[printf "  interface: utun4\n"]])
  tool("scutil", [[printf "IPv4 network interface information\n   Network interfaces: en1 en0 utun4\n"]])
  assert(run() == "wifi", "macOS through a VPN: scutil's first hardware port (Wi-Fi)")
  os.execute("rm -rf '" .. dir .. "'")
end

-- ---- 6. the live mix's host: a move only about reach settles as long as the song's hub's ---------------------------------------------------
local function c(user, x) x = x or {}; x.user, x.net, x.rtt, x.cpu, x.can = user, x.net or "wired", x.rtt or 20, 10, true; return x end
-- desk mixes; a link drop leaves one bandmate unable to reach it, so lin is better reached; nothing else differs
local L = { c("desk", { lmix = true, miss = 1 }), c("lin", { miss = 0 }) }
local p, why = livex.mix_pick(L)
assert(p.user == "lin" and why == "reach", "better reached alone: why 'reach'")
local mem = { cur = "desk" } -- (desk mixes, as this computer saw it)
assert(livex.mix_decide(mem, L, true, "desk", "me", 0) == "desk", "not at once")
assert(livex.mix_decide(mem, L, true, "desk", "me", livex.SETTLE + 1) == "desk", "nor after SETTLE: a link down for 16 s doesn't hand the mix over")
local h, _, wait = livex.mix_decide(mem, L, true, "desk", "me", hub.REACH_SETTLE)
assert(h == nil and wait:find("handing the live mix to lin", 1, true), "after REACH_SETTLE s of it, as the song's hub: handed to lin")
-- the link back within REACH_SETTLE: no move, and the count starts again
mem = { cur = "desk" }
livex.mix_decide(mem, L, true, "desk", "me", 0)
livex.mix_decide(mem, { c("desk", { lmix = true, miss = 0 }), c("lin", { miss = 0 }) }, true, "desk", "me", 20)
assert(livex.mix_decide(mem, L, true, "desk", "me", 25) == "desk" and livex.mix_decide(mem, L, true, "desk", "me", 25 + hub.REACH_SETTLE - 1) == "desk", "a break starts the count again")
-- wired against the mixer's Wi-Fi: SETTLE, as before
mem = { cur = "desk" }
local W = { c("desk", { lmix = true, net = "wifi" }), c("lin", { net = "wired" }) }
p, why = livex.mix_pick(W)
assert(p.user == "lin" and why == "best", "wired against Wi-Fi: 'best'")
livex.mix_decide(mem, W, true, "desk", "me", 0)
h, _, wait = livex.mix_decide(mem, W, true, "desk", "me", livex.SETTLE)
assert(h == nil and wait:find("handing the live mix to lin", 1, true), "wired: after SETTLE s, as before")

print("ok: rt-hubsmall (lrtt held; vouched and near computers listed for live audio; the route in use; reach settles as the song's hub)")
