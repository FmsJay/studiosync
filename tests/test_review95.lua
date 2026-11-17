-- 0.58.95's fixes from the pre-test review (lupa or Lua 5.4, from the repo root): a tempo map posted here is ordered after the newest seen
-- here (through sync.post itself), the together clock's half-minute window, and a just-made item kept when its track is deleted elsewhere.
package.path = "lib/?.lua;" .. package.path
local clock, pext, ext, written = 1000, {}, { ["StudioSync/user"] = "James" }, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetProjExtState = function(_, sec, key) local v = pext[sec .. "/" .. key]; return v and 1 or 0, v or "" end,
  SetProjExtState = function(_, sec, key, v) pext[sec .. "/" .. key] = v end,
  GetExtState = function(sec, key) return ext[sec .. "/" .. key] or "" end,
  RecursiveCreateDirectory = function() return 1 end,
}, { __index = function() return function() end end })
for _, m in ipairs({ "band", "sync", "together", "mirror" }) do package.loaded[m] = nil end
local band = require("band")
band.write_json = function(p, t) written[#written + 1] = t; return true end
band.song_dir = function() return "R/song" end
band.SECTION = "StudioSync"
local sync = require("sync")
local P = {}

-- a tempo map made here, after a newer-stamped one from a computer whose clock runs ahead, still comes after it (it never did: no proj)
pext[sync.NEWEST .. "/timeline"] = "2099-01-01T00:00:00ZMac-1"
sync.post({ user = "James", root = "R" }, "song", "main", { type = "timeline", tempo = {}, markers = {} }, P)
local ev = written[#written]
assert(ev.order == "2099-01-01T00:00:00ZMac-1+", "ordered after the newest map seen here: " .. tostring(ev.order))
assert(pext[sync.NEWEST .. "/timeline"] == ev.order, "and it's the newest here now")
assert(sync.newest_map({ ev }, "2099-01-01T00:00:00ZMac-1") == ev.id, "so the others take it, whatever its clock says")

-- the together clock: a high reading is kept for half a minute, not for good
local together = require("together")
local real_time, wall = os.time, 5000
os.time = function(t) if t then return real_time(t) end; return wall end
local function second(precise_at_tick) wall = wall + 1; clock = precise_at_tick; together.tick() end
together.tick()
second(1000.0) -- (offset 4001.0: a tick read on time)
assert(math.abs(together.now() - (clock + 4001.0)) < 1e-6, "the first reading")
second(1001.3) -- (a late look: lower)
assert(math.abs(together.now() - clock - 4001.0) < 1e-6, "a late look doesn't move it")
for i = 1, 40 do second(1001.3 + i * 1.0002) end -- (the wall clock now runs a little slow)
assert(math.abs((together.now() - clock) - (wall - clock)) < 0.01, "after half a minute it follows the clock as it is: " .. (together.now() - clock) - (wall - clock))
os.time = real_time

-- a track deleted elsewhere: an item whose newest version is mine and from the last two minutes stays here
local mirror = require("mirror")
local known = {}
mirror.known = function(_, oid) local k = known[oid]; if k then return 1, "", "", k end end
known["I-NEW"] = "1700000000000|James"
known["I-OLD"] = "1699999000000|James"
known["I-THEIRS"] = "1700000000000|Laptop"
assert(mirror.just_made_here(P, "I-NEW", 1700000060000), "my take from a minute ago: kept")
assert(not mirror.just_made_here(P, "I-OLD", 1700000060000), "mine, but long settled: goes with the track")
assert(not mirror.just_made_here(P, "I-THEIRS", 1700000060000), "someone else's: goes with the track")
assert(not mirror.just_made_here(P, "I-NONE", 1700000060000), "never known: (kept by the older rule)")
print("ok")
