-- sync.write_status reads its own file back (two computers using one name) at most every CLASH_EVERY s, not on every write, and still says
-- so when the other computer's write is the one there. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock = 1000
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetAppVersion = function() return "7.86/win64" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local sync = require("sync")
local on_disk, reads, said = nil, 0, {}
band.read_json = function(path) if path:find("/status/James.json$") then reads = reads + 1; return on_disk end end
band.write_json = function(path, t) if path:find("/status/James.json$") then on_disk = t end end
package.loaded.direct = { send_live = function() end }
package.loaded.rthealth = { free_mb = function() return 1000 end }
package.loaded.colours = { look = function() return nil end, parity = function() return true end } -- (the studio's Colour parity switch: rt-perfcut4)
sync.room_dir = function() return "R/Song/rooms/main" end
sync.machine = function() return "desk" end
sync.put_back = function(text) said[#said + 1] = text end
local cfg = { root = "R", user = "James" }
for _ = 1, 10 do sync.write_status("P", cfg, "Song", "main", {}); clock = clock + 2 end
assert(reads == 1, "ten writes in 20 s: read back once (" .. reads .. ")")
clock = clock + sync.CLASH_EVERY
on_disk = { machine = "laptop", time = os.date("!%Y-%m-%dT%H:%M:%SZ") } -- (the other computer's write is the one there now)
sync.write_status("P", cfg, "Song", "main", {})
assert(reads == 2 and #said == 1 and said[1]:find("also using the name James", 1, true), "past CLASH_EVERY: read again, and the clash said")
clock = clock + sync.CLASH_EVERY
sync.write_status("P", cfg, "Song", "main", {})
assert(reads == 2 and #said == 1, "said once: not read back again")
print("ok")
