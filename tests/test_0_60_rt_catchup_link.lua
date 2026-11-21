-- rt-catchup (2026-11-21), from the LinuxBox test of catch-up over the direct link (docs/rt/rt-linkmove.md, "Round 5"):
--   1. a computer whose Syncthing is paused reads everyone's status file as stale, so nobody was here, the link had no peers and the need
--      list never asked. Now Live sync's status write also goes, every HELLO_EVERY s, to the studio's computers whose person isn't here
--      (lib/direct.lua strangers: trusted, Tailscale-named, not removed, not this person's), and a bandmate's status that comes back over the
--      link makes them here (presence.from_msg, as before), so the link's peers have them. For the first LINK_HOLD s you aren't read as alone
--      while the link is on (presence.link_hold), so full control isn't granted on stale files before the link could hear anyone;
--   4. an item that went with its deleted track isn't "played" (drive.media_in_use), though its own newest change doesn't say so.
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
band.log = function() end
local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - ago) end

local ANN = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA"
local BEE = "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB"
local LIN = "LLLLLLL-LLLLLLL-LLLLLLL-LLLLLLL-LLLLLLL-LLLLLLL-LLLLLLL-LLLLLLL"
local LIN2 = "MMMMMMM-MMMMMMM-MMMMMMM-MMMMMMM-MMMMMMM-MMMMMMM-MMMMMMM-MMMMMMM"
local REX = "RRRRRRR-RRRRRRR-RRRRRRR-RRRRRRR-RRRRRRR-RRRRRRR-RRRRRRR-RRRRRRR"
local SUFFIX = "tail1.ts.net"
local services, trust, access, groups = require("services"), require("trust"), require("access"), require("groups")
services.my_device_id = function() return LIN end
local trusted = { [ANN] = true, [BEE] = true, [LIN] = true, [LIN2] = true, [REX] = true }
trust.device_ok = function(_, _, dev) return trusted[dev] end
access.read = function() return nil end
groups.tailnet = function() return { name = "tail1", suffix = SUFFIX } end
groups.trusted = function() return {} end
local function device(user, dev, host) files["R/_band/devices/" .. user .. ".json"] = { user = user, device = dev, ts = { [SUFFIX] = host .. "." .. SUFFIX } } end
device("Ann", ANN, "desktop"); device("Bee", BEE, "laptop"); device("Lin", LIN, "linuxbox"); device("Rex", REX, "rexpc")
files["R/_band/removed/Rex.json"] = { user = "Rex", at = 1 } -- (taken out of the studio)

local direct = require("direct")
local sent = {}
direct.available = function() return true end
direct.live_available = function() return true end
direct.ensure = function() return true end
direct.send_live = function(_, kind, d, song, room, id, to) sent[#sent + 1] = { kind = kind, d = d, song = song, room = room, to = to } end
local sync = require("sync")
sync.room_dir = function(_, song, room) return "R/" .. song .. "/rooms/" .. room end
local presence = require("presence")
local cfg = { root = "R", user = "Lin" }
local SDIR = "R/Song/rooms/main/status"
local ANN_P, BEE_P = "desktop." .. SUFFIX .. ":" .. direct.PORT, "laptop." .. SUFFIX .. ":" .. direct.PORT

-- ---- 1. Syncthing paused here: the others' status files are stale, nobody is here ----------------------------------------------------
files[SDIR .. "/Ann.json"] = { user = "Ann", time = iso(300), room = "main" }
files[SDIR .. "/Bee.json"] = { user = "Bee", time = iso(300), room = "main" }
assert(#presence.peers(cfg, "Song", "main") == 0 and #direct.refresh_peers(cfg, "Song", "main") == 0, "stale files: nobody here, the link has no peers (the test's case)")
-- (rt-p3: the studio's computers the link may send to, here or not, where studio-wide signed files go: lib/signed.lua drain)
local all = direct.studio_peers(cfg, "Song")
assert(#all == 2 and all[1] == ANN_P and all[2] == BEE_P, "studio_peers: every trusted studio computer, not this one, not one taken out: " .. table.concat(all, " "))
local strangers = direct.strangers(cfg, "Song", "main")
assert(#strangers == 2 and strangers[1] == ANN_P and strangers[2] == BEE_P,
  "the studio's trusted computers whose person isn't here: not this one, not one taken out of the studio: " .. table.concat(strangers, " "))

-- the status write says hello to them
local s, wrote = { fp = "", at = 0 }, {}
local function write(info, link_only) info.user, info.time, info.room = cfg.user, iso(0), "main"; wrote[#wrote + 1] = link_only end
local info = { n = 1 }
presence.put_status(cfg, "Song", "main", s, info, "1", clock, write)
local hello = sent[#sent]
assert(#wrote == 1 and hello and hello.kind == "presence" and hello.d == info and hello.d.user == "Lin" and hello.song == "Song" and hello.room == "main"
  and #hello.to == 2 and hello.to[1] == ANN_P and hello.to[2] == BEE_P, "this computer's status goes to them over the link, though nobody is here")
local n = #sent
clock = clock + 1
presence.put_status(cfg, "Song", "main", s, { n = 2 }, "2", clock, write)
assert(#wrote == 2 and #sent == n, "the next write: not again within HELLO_EVERY")

-- Ann's Live sync takes it as any status off the link and answers with hers: Ann is here now, and on the link's list
assert(presence.from_msg(cfg, "Song", "main", { user = "Ann", time = iso(0), room = "main" }, "presence"), "Ann's status over the link")
clock = clock + direct.PEERS_EVERY + 1
local peers = direct.refresh_peers(cfg, "Song", "main")
assert(#peers == 1 and peers[1] == ANN_P, "Ann is here (her file is still 300 s old): the link sends her everything")
local who = presence.here(cfg, "Song", "main", 45)
assert(#who == 1 and who[1] == "Ann", "and here for Live sync's who's-here too: not alone, so no full control while the link hears her")
strangers = direct.strangers(cfg, "Song", "main")
assert(#strangers == 1 and strangers[1] == BEE_P, "the hello now goes to Bee's computer alone")
clock = clock + presence.HELLO_EVERY
n = #sent
presence.put_status(cfg, "Song", "main", s, { n = 3 }, "3", clock, write)
assert(#sent > n and sent[#sent].to[1] == BEE_P and #sent[#sent].to == 1, "the next hello: Bee's computer")

-- an untrusted computer (its devices file not written by it) never gets one
trusted[BEE] = false
clock = clock + direct.PEERS_EVERY + 1
assert(#direct.strangers(cfg, "Song", "main") == 0, "a devices file its own computer didn't write: no hello")
trusted[BEE] = true
-- with the link off, no hello
direct.live_available = function() return false end
clock = clock + presence.HELLO_EVERY + presence.HEARTBEAT + 1
n = #sent
presence.put_status(cfg, "Song", "main", s, { n = 4 }, "4", clock, write)
assert(#sent == n, "no link: nothing sent")
direct.live_available = function() return true end

-- ---- 1b. not alone in the first LINK_HOLD s while the link is on ---------------------------------------------------------------------
assert(presence.link_hold(cfg) == true, "the first call (Live sync's start, link on): held")
clock = clock + presence.LINK_HOLD - 1
assert(presence.link_hold(cfg) == true, "still within LINK_HOLD")
clock = clock + 2
assert(presence.link_hold(cfg) == false, "after LINK_HOLD: alone may be said, as before")
-- (rt-p3: round 5 named it HOLD, which set the edit hold, presence.editing's and mirror's put-back rule, from 3 s to 8 s)
assert(presence.HOLD == 3 and presence.LINK_HOLD == 8, "the edit hold stays 3 s; the link's start hold has a name of its own")

-- ---- 4. an item that went with its deleted track isn't played ---------------------------------------------------------------------
local drive = require("drive")
local function ev(oid, time, t) t = t or {}; t.oid, t.time, t.id = oid, time, oid .. time; return t end
local room = {
  ev("T1", "1", { obj = "track" }),
  ev("I1", "2", { obj = "item", track = "T1", media = { { "main", "kept.wav" } } }),
  ev("T2", "1", { obj = "track" }),
  ev("I2", "1", { obj = "item", track = "T2", media = { { "main", "lost.wav" } } }),
  ev("T2", "3", { obj = "track", gone = true }), -- (Ann deleted the track)
  ev("I2", "4", { obj = "item", track = "T2", media = { { "main", "lost.wav" } } }), -- (Bee moved its item before the delete reached her)
  ev("I3", "1", { obj = "item", track = "T3", media = { { "main", "moved.wav" } } }),
  ev("T3", "2", { obj = "track", gone = true }),
  ev("I3", "3", { obj = "item", track = "T1", media = { { "main", "moved.wav" } } }), -- (its item moved to a track still here first)
  ev("I4", "1", { obj = "item", track = "T9", media = { { "main", "notrack.wav" } } }), -- (a track nothing here says anything of)
}
local used = drive.media_in_use({ main = room }, "main")
assert(used["kept.wav"] and used["moved.wav"] and used["notrack.wav"], "items on tracks still here are played")
assert(not used["lost.wav"], "the item that went with its deleted track isn't played, though its newest change came after the delete")
room[#room + 1] = ev("T2", "5", { obj = "track" }) -- (the track restored)
assert(drive.media_in_use({ main = room }, "main")["lost.wav"], "the track back: its item plays again")

print("ok rt-catchup link presence and in-use")
