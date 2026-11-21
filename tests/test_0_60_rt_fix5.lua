-- rt-fix5 (2026-11-21), from the REAPER re-check (docs/rt/rt-linkmove.md round 5 B, docs/rt/rt-answers.md check 6 and its rig notes):
--   2. LinuxBox said "nobody else is here" 8 s into Live sync while the laptop's ran: the first hello was spent whether the link was up yet or
--      not, a computer a device check missed waited for the next hello 15 s on, and a hello wasn't answered until the bandmate's own next one.
--      Now each stranger gets its first hello as soon as the link may send to it (looked for every HELLO_LOOK s), a hello is answered at once
--      with this computer's status (presence.answer, at most every ANSWER_EVERY s for each person), and LINK_HOLD covers that round trip;
--   3. Record together on a computer with nothing armed showed REAPER's modal "No tracks are armed" box (75 s on LinuxBox). Live sync asks
--      together.armed first and plays along instead, saying so (together.NO_ARM), never the box.
-- (Item 1, the skip's own selection back at stop: tests/test_0_60_rt_answers_skip.lua. Item 4, Syncthing's command line on Linux:
-- tests/test_0_60_rt_fix5_syncthing.lua.) Each assert below fails with its change taken out.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
local tracks = {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  CountTracks = function() return #tracks end,
  GetTrack = function(_, i) return tracks[i + 1] end,
  GetMediaTrackInfo_Value = function(tr, k) return k == "I_RECARM" and tr.arm or 0 end,
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
local SUFFIX = "tail1.ts.net"
local services, trust, access, groups = require("services"), require("trust"), require("access"), require("groups")
services.my_device_id = function() return LIN end
local trusted = { [ANN] = true, [LIN] = true } -- (Bee's computer: not checked yet, as when its device check missed its 50 ms)
trust.device_ok = function(_, _, dev) return trusted[dev] end
access.read = function() return nil end
groups.tailnet = function() return { name = "tail1", suffix = SUFFIX } end
groups.trusted = function() return {} end
local function device(user, dev, host) files["R/_band/devices/" .. user .. ".json"] = { user = user, device = dev, ts = { [SUFFIX] = host .. "." .. SUFFIX } } end
device("Ann", ANN, "desktop"); device("Bee", BEE, "laptop"); device("Lin", LIN, "linuxbox")

local direct = require("direct")
local sent, link_up = {}, false
direct.available = function() return true end
direct.live_available = function() return link_up end
direct.ensure = function() return link_up end
direct.send_live = function(_, kind, d, song, room, id, to) sent[#sent + 1] = { kind = kind, d = d, song = song, room = room, to = to } end
local sync = require("sync")
sync.room_dir = function(_, song, room) return "R/" .. song .. "/rooms/" .. room end
local presence = require("presence")
local cfg = { root = "R", user = "Lin" }
local SDIR = "R/Song/rooms/main/status"
local ANN_P, BEE_P = "desktop." .. SUFFIX .. ":" .. direct.PORT, "laptop." .. SUFFIX .. ":" .. direct.PORT
files[SDIR .. "/Ann.json"] = { user = "Ann", time = iso(300), room = "main" } -- (stale here: Syncthing paused, the LinuxBox test)
files[SDIR .. "/Bee.json"] = { user = "Bee", time = iso(300), room = "main" }

local s = {}
local function write(info) info.user, info.time, info.room = cfg.user, iso(0), "main" end

-- ---- 2a. the link not up yet at Live sync's first write: the hello goes as soon as it is, not 15 s later ---------------------------------
presence.put_status(cfg, "Song", "main", s, { n = 1 }, "1", clock, write)
assert(#sent == 0, "no link yet: nothing sent")
link_up, clock = true, clock + 0.5
local info2 = { n = 2 }
presence.put_status(cfg, "Song", "main", s, info2, "2", clock, write)
assert(#sent == 1 and sent[1].kind == "presence" and #sent[1].to == 1 and sent[1].to[1] == ANN_P,
  "the link up: the hello goes at the next write, to the strangers the link may send to (" .. #sent .. " sent)")
assert(sent[1].d.hello == true and sent[1].d.n == 2 and info2.hello == nil, "marked as a hello on a copy: the status Live sync keeps isn't")

-- ---- 2b. a computer a device check missed gets its hello at the next look, not at the next 15 s -----------------------------------------
trusted[BEE] = true
clock = clock + 1
presence.put_status(cfg, "Song", "main", s, { n = 3 }, "3", clock, write)
assert(#sent == 1, "within HELLO_LOOK: no new look")
clock = clock + presence.HELLO_LOOK
presence.put_status(cfg, "Song", "main", s, { n = 4 }, "4", clock, write)
assert(#sent == 2 and #sent[2].to == 1 and sent[2].to[1] == BEE_P, "Bee's computer, checked now: its hello at the next look; Ann's not again")
clock = clock + presence.HELLO_LOOK
presence.put_status(cfg, "Song", "main", s, { n = 5 }, "5", clock, write)
assert(#sent == 2, "each stranger once a HELLO_EVERY")
clock = clock + presence.HELLO_EVERY
presence.put_status(cfg, "Song", "main", s, { n = 6 }, "6", clock, write)
assert(#sent == 3 and #sent[3].to == 2, "then every HELLO_EVERY s, to all strangers, as before")

-- ---- 2c. a hello is answered at once, to that person's computers only ---------------------------------------------------------------
local mine = { n = 7 }
presence.put_status(cfg, "Song", "main", s, mine, "7", clock, write) -- (this computer's last status: what it answers with)
local n = #sent
assert(presence.from_msg(cfg, "Song", "main", { user = "Ann", time = iso(0), room = "main", hello = true }, "presence"), "Ann's hello is a status too")
local a = sent[#sent]
assert(#sent == n + 1 and a.kind == "presence" and a.d == mine and a.d.hello == nil and #a.to == 1 and a.to[1] == ANN_P and a.song == "Song" and a.room == "main",
  "answered at once with this computer's status (no hello mark: no answer back), to Ann's computer")
assert(presence.live(cfg, "Song", "main").Ann.hello == nil, "the hello mark isn't kept in Ann's status")
assert(#presence.here(cfg, "Song", "main", 45) == 1, "and Ann is here (her file is 300 s old)")
presence.from_msg(cfg, "Song", "main", { user = "Ann", time = iso(0), room = "main", hello = true }, "presence")
assert(#sent == n + 1, "not again within ANSWER_EVERY")
clock = clock + presence.ANSWER_EVERY
presence.from_msg(cfg, "Song", "main", { user = "Ann", time = iso(0), room = "main", hello = true }, "presence")
assert(#sent == n + 2 and sent[#sent].to[1] == ANN_P, "after ANSWER_EVERY, her next hello is answered too")
presence.from_msg(cfg, "Song", "main", { user = "Bee", time = iso(0), room = "main" }, "presence")
assert(#sent == n + 2, "a plain status isn't answered")
presence.from_msg(cfg, "Song", "main", { user = "Rex", time = iso(0), room = "main", hello = true }, "presence")
assert(#sent == n + 2, "a hello from someone the link can't name: nothing sent (their computer isn't in the studio's list)")

-- ---- 2d. the start hold covers one round trip with margin ----------------------------------------------------------------------------
-- (hello at the first pass, answered at once, read within 1 s by presence.peers and 2 s by the next pass; plus one missed device check, a
-- HELLO_LOOK, and a bandmate's 5 s heartbeat when it couldn't name this computer yet)
assert(presence.LINK_HOLD >= 1 + 2 + presence.HELLO_LOOK + 5 and presence.LINK_HOLD < presence.HELLO_EVERY,
  "LINK_HOLD covers the round trip and its margin, and is no longer than it needs (" .. presence.LINK_HOLD .. ")")

-- ---- 3. Record together with nothing armed: no REAPER box, play along and say so -----------------------------------------------------
local together = require("together")
tracks = {}
assert(not together.armed("P"), "no tracks: nothing armed")
tracks = { { arm = 0 }, { arm = 0 } }
assert(not together.armed("P"), "tracks, none armed")
tracks[2].arm = 1
assert(together.armed("P"), "one armed: record")
assert(together.NO_ARM:find("no track is armed", 1, true) and together.NO_ARM:find("playing along", 1, true), "said in the log and the panel's line")
local function src(path) local fh = assert(io.open(path, "rb")); local t = fh:read("a"); fh:close(); return (t:gsub("\r", "")) end
local live = src("StudioSync - Live sync.lua")
local ask = live:find("local no_arm = together_take and not together.armed(proj)", 1, true)
local rec = live:find("reaper.Main_OnCommand(1013, 0) -- Transport: Record (the active project)", 1, true)
assert(ask and rec and ask < rec and live:find("if no_arm then together_take = nil; reaper.OnPlayButtonEx(proj) end", 1, true)
  and live:find("elseif not no_arm then", 1, true) and live:find("local said = no_arm and together.NO_ARM or", 1, true),
  "Live sync asks before REAPER's Record, plays along with nothing armed (never Record's box), and says so in the log and the panel")

print("ok rt-fix5 hello answered, start hold, nothing armed")
