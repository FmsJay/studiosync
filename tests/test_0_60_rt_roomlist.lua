-- rt-roomlist (2026-11-20): the computers disagreed about who's in the room for live audio. The laptop's list left the desktop out while the
-- desktop listed it and sent (one-way), the Mac (the song's hub) left the desktop out of its mix, and the laptop's not_here from the Mac kept
-- climbing. Each cause, reproduced:
--   1. presence: a heartbeat over the link counts though the status file is old (the file is the fallback, 45 s);
--   2. the quiet status file: written every FILE_QUIET s while "the link reaches everyone here", where "here" left out whoever's status had
--      gone old here, who then got no link messages from this computer and only a file older than 45 s whenever Syncthing took over 15 s;
--   3. live audio: a studio computer whose audio comes here (it lists this one) is added to the list here while it keeps sending, a
--      non-studio computer never (lib/liveaudio.lua heard_merge, direct.studio_peer, direct.ips_in; the extension's not_here_peers and
--      heard_ago, tests/rtaudio_test.cpp not_here_test);
--   4. Health says "sends here but isn't in this room" only while it's so, not for the rest of the session.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })

local band = require("band")
local files = {}
band.read_json = function(path) local v = files[path]; return type(v) == "table" and v or nil end
band.read = function(path) return files[path] and band.json_encode(files[path]) or nil end
band.files = function(dir, ext)
  local t = {}
  for path in pairs(files) do
    local d, f = path:match("^(.*)/([^/]+)$")
    if d == dir and (not ext or f:sub(-#ext) == ext) then t[#t + 1] = f end
  end
  table.sort(t)
  return t
end
band.info = function() return { id = "studio1", name = "Studio" } end
local logged = {}
band.log = function(t) logged[#logged + 1] = t end
local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - ago) end

local link = { reach = {} }
package.loaded.direct = {
  available = function() return true end, live_available = function() return true end, ensure = function() return true end,
  reach = function() return link.reach end,
}
local sync = require("sync")
sync.room_dir = function(_, song, room) return "R/" .. song .. "/rooms/" .. room end
local presence = require("presence")
local cfg = { root = "R", user = "James" }
local SDIR = "R/Song/rooms/main/status"
local function here(user, song) for _, st in ipairs(presence.peers(cfg, song or "Song", "main")) do if st.user == user then return true end end return false end

-- ---- 1. a heartbeat over the link beats an old file (another song: its live status stays out of part 2) ---------------------------------
files["R/Song1/rooms/main/status/Lap.json"] = { user = "Lap", time = iso(60), room = "main" }
assert(not here("Lap", "Song1"), "a status file 60 s old and nothing over the link: not here (the file's 45 s rule)")
assert(presence.from_msg(cfg, "Song1", "main", { user = "Lap", time = iso(0), room = "main" }, "heartbeat"), "the link's heartbeat taken")
clock = clock + 2
assert(here("Lap", "Song1"), "the heartbeat makes Lap here, though the file is still 60 s old")

-- ---- 2. quiet only while everyone who may read the file gets the link's messages ------------------------------------------------------
files[SDIR .. "/Bee.json"] = { user = "Bee", time = iso(0), room = "main" }
files[SDIR .. "/Mac.json"] = { user = "Mac", time = iso(60), room = "main" } -- (Mac's status old here: Syncthing behind, or its Live sync held)
link.reach = { Bee = { ok = true, at = 0 } } -- (Mac isn't on this computer's list, so the link doesn't try it)
clock = clock + 2
assert(not here("Mac"), "Mac's status is old here: not on the room's list")
local quiet = presence.link_carries(cfg, "Song", "main")
assert(quiet == false, "Mac may still read this computer's file and gets no link messages from it: not quiet, today's pace (every 15 s)")
local s = { fp = "", at = 0 }
local wrote = {}
local function put(n) return presence.put_status(cfg, "Song", "main", s, { n = n }, tostring(n), clock, function(_, link_only) wrote[#wrote + 1] = link_only end) end
assert(put(1) == "file", "the file")
clock = clock + presence.HEARTBEAT + 1
assert(put(1) == "file", "again within 15 s, not 30: Mac reads it under 45 s old even with Syncthing 25 s behind")
files[SDIR .. "/Mac.json"].time = iso(presence.READERS + 5)
clock = clock + 2
presence.peers(cfg, "Song", "main") -- (the file changed here now: here by that rule for READERS s more)
assert(presence.link_carries(cfg, "Song", "main") == false, "its file just changed here: not quiet yet")
clock = clock + presence.READERS + 1
quiet = presence.link_carries(cfg, "Song", "main")
assert(quiet == true, "Mac gone for over READERS s: the quiet file again")
link.reach.Mac = { ok = true, at = 0 }
files[SDIR .. "/Mac.json"].time = iso(0)
clock = clock + 2
assert(presence.link_carries(cfg, "Song", "main") == true, "Mac here and reached: quiet")

-- ---- 3. live audio: a studio computer heard here is added while it sends ---------------------------------------------------------------
local la = require("liveaudio")
local DESK, LAP, EVE = "james-main.t.ts.net:47281", "james-laptop.t.ts.net:47281", "eve.t.ts.net:47281"
local studio = { ["100.1.1.1:47281"] = { DESK, "James" }, ["100.2.2.2:47281"] = { LAP, "James-Laptop" } } -- (100.9.9.9: not a studio computer)
local function peer_of(addr) local p = studio[addr]; if p then return p[1], p[2] end end
local kept, now = {}, 500
-- the laptop's room lists the Mac only; the desktop sends here (it lists the laptop), and so does a stranger with the secret
local list, users = la.heard_merge({ "mac:47281" }, { not_here_peers = { ["100.1.1.1:47281"] = { ago = 0.1, n = 300 }, ["100.9.9.9:47281"] = { ago = 0.1, n = 9 } },
  peers = {} }, peer_of, kept, now)
assert(table.concat(list, " ") == DESK .. " mac:47281" and users[DESK] == "James", "the desktop added (two-way at once), the stranger not: " .. table.concat(list, " "))
-- next tick: the desktop's slot hears it (heard_ago), no longer not_here
now = now + 10
list = la.heard_merge({ "mac:47281" }, { not_here_peers = { ["100.1.1.1:47281"] = { ago = 10.1 } }, peers = { [DESK] = { heard_ago = 0.02 } } }, peer_of, kept, now)
assert(#list == 2, "kept while it keeps sending, though its not_here entry is old")
now = now + 14
list = la.heard_merge({ "mac:47281" }, { peers = { [DESK] = { heard_ago = 13 } } }, peer_of, kept, now)
assert(#list == 2, "a quiet spell under HEARD_S: kept")
now = now + 3
list = la.heard_merge({ "mac:47281" }, { peers = { [DESK] = { heard_ago = 16 } } }, peer_of, kept, now)
assert(#list == 1 and next(kept) == nil, "silent past HEARD_S (its room dropped this computer, or it left): off the list")
-- an old not_here entry doesn't bring anyone back
list = la.heard_merge({ "mac:47281" }, { not_here_peers = { ["100.2.2.2:47281"] = { ago = 30 } } }, peer_of, kept, now)
assert(#list == 1, "heard 30 s ago: not added")
-- the room lists it in time: nothing kept apart
list = la.heard_merge({ LAP }, { not_here_peers = { ["100.2.2.2:47281"] = { ago = 0.1 } } }, peer_of, kept, now)
assert(#list == 1 and next(kept) == nil, "already on the room's list: once, and nothing kept")
list = la.heard_merge({}, { not_here_peers = { ["100.2.2.2:47281"] = { ago = 0.1 } } }, peer_of, kept, now)
assert(list[1] == LAP and kept[LAP], "added")
list = la.heard_merge({ LAP }, { peers = { [LAP] = { heard_ago = 0.1 } } }, peer_of, kept, now + 1)
assert(#list == 1 and next(kept) == nil, "the room lists it now: the room's list takes over")
local _ = EVE

-- ---- 3b. the address -> a trusted studio computer: Tailscale's names, then the devices files -----------------------------------------------
local ts_json = [[{"Peer":{"k1":{"DNSName":"james-main.t.ts.net.","TailscaleIPs":["100.1.1.1","fd7a::1"]},
  "k2":{"DNSName":"Eve.T.ts.net.","TailscaleIPs":["100.3.3.3"]},"k3":{"DNSName":"rogue.t.ts.net.","TailscaleIPs":["100.4.4.4"]}}}]]
package.loaded.direct = nil
package.loaded.services = { run_hidden = function(name) return name == "ts-peers" and ts_json or nil end, tailscale_exe = function() return "tailscale" end,
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "LLLLLLLLLLLL" end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "t", suffix = "t.ts.net" } end }
local wrote_itself = { DDDDDDDDDDDD = true, EEEEEEEEEEEE = true } -- (rogue's devices file names a computer that didn't write it)
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function(_, _, dev) return wrote_itself[dev] or false end }
local guest_songs = { EEEEEEEEEEEE = { Other = true } } -- (Eve is a guest without this song)
package.loaded.access = { read = function(_, dev) return guest_songs[dev] end, shows = function(set, song) return not set or set[song] == true end }
files["R/_band/devices/James.json"] = { user = "James", device = "DDDDDDDDDDDD", ts = { ["t.ts.net"] = "james-main.t.ts.net" } }
files["R/_band/devices/Eve.json"] = { user = "Eve", device = "EEEEEEEEEEEE", ts = { ["t.ts.net"] = "eve.t.ts.net" } }
files["R/_band/devices/Rogue.json"] = { user = "Rogue", device = "RRRRRRRRRRRR", ts = { ["t.ts.net"] = "rogue.t.ts.net" } }
local direct = require("direct")
local ips = direct.ips_in(ts_json)
assert(ips["100.1.1.1"] == "james-main.t.ts.net" and ips["100.3.3.3"] == "eve.t.ts.net", "Tailscale's addresses -> names, lower case, no last dot")
local p, u = la.peer_of_addr(cfg, "Song", "100.1.1.1:47281")
assert(p == DESK and u == "James", "the desktop's address -> its peer and user: " .. tostring(p))
assert(la.peer_of_addr(cfg, "Song", "100.3.3.3:47281") == nil, "a guest whose list hasn't this song: not added")
assert(la.peer_of_addr(cfg, "Song", "100.4.4.4:47281") == nil, "a devices file its computer didn't write: not added")
assert(la.peer_of_addr(cfg, "Song", "100.5.5.5:47281") == nil, "an address Tailscale doesn't name: not added")
assert(la.peer_of_addr(cfg, "Song", "100.1.1.1:5000") == nil, "another port: not added")
assert(la.peer_of_addr(cfg, "Song", "198.18.0.7:47281") == nil, "the connection without Tailscale's addresses: lib/nat.lua's")
package.loaded.trust.device_ok = function() return nil end
assert(la.peer_of_addr(cfg, "Song", "100.1.1.1:47281") == nil, "Syncthing hasn't said yet: not yet")

-- ---- 4. Health: "sends here but isn't in this room" while it's so ------------------------------------------------------------------------
local base = { nch = 1, kbps = 128, rejected = 0, not_here = 13589, not_here_from = "100.9.9.9:47281", peers = { [LAP] = { resolved = true, streaming = true, latency_ms = 20, buffer_ms = 10, loss = 0 } } }
local function text_of(nhp) base.not_here_peers = nhp; local _, t = la.health_text(base, { [LAP] = "James-Laptop" }); return t end
assert(text_of({ ["100.9.9.9:47281"] = { ago = 0.5 } }):find("sends here but isn't in this room", 1, true), "sending now: said")
assert(not text_of({ ["100.9.9.9:47281"] = { ago = 40 } }):find("sends here", 1, true), "40 s ago (added since, or stopped): not news")
assert(not text_of({}):find("sends here", 1, true), "nobody in the last minute: nothing")
assert(text_of(nil):find("sends here", 1, true), "an older extension (no not_here_peers): the count, as before")

print("ok: rt-roomlist (a heartbeat beats an old file; the quiet file waits for everyone who may read it; live audio heard from a studio computer is two-way; Health's not_here only while so)")
