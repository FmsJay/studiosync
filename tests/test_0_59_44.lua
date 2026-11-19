-- 0.59.44 (full review fixes): who's here with a clock behind, "confirmed elsewhere" only on fresh lists from people still in, the code
-- list's hashes.
package.path = "lib/?.lua;" .. package.path
local clock = 1000
reaper = setmetatable({ time_precise = function() return clock end, GetExtState = function() return "" end, SetExtState = function() end },
  { __index = function() return function() return "" end end })

-- Who's here (lib/presence.lua presence.here): a bandmate whose clock runs 120 s behind, still writing, is here
local files = {}
package.loaded.band = nil
local band = require("band")
local real_age = band.age
band.files = function() local t = {}; for f in pairs(files) do t[#t + 1] = f end; table.sort(t); return t end
band.read_json = function(p) return files[p:match("[^/]+$")] end
package.loaded.sync = { room_dir = function() return "R" end }
package.loaded.presence = nil
local presence = require("presence")
local cfg = { user = "James" }
local ages = { ["Bee.json"] = 0, ["Cal.json"] = 0 }
band.age = function(t) return tonumber(t) and (os.time() - tonumber(t)) or 1e9 end
local function stamp(behind) return tostring(os.time() - behind) end
files["Bee.json"] = { user = "Bee", time = stamp(120) } -- clock 120 s behind
files["Cal.json"] = { user = "Cal", time = stamp(5) }
presence.peers(cfg, "S", "main") -- first look: Bee's stamp is old
clock = clock + 2
files["Bee.json"] = { user = "Bee", time = stamp(118) } -- it changed: still writing
presence.peers(cfg, "S", "main")
local here = presence.here(cfg, "S", "main", 90)
local function has(list, n) for _, x in ipairs(list) do if x == n then return true end end end
assert(has(here, "Bee") and has(here, "Cal"), "a bandmate whose clock is behind but still writing is here, not gone (full control was handed over their claims)")
clock = clock + 200 -- Bee stops writing for 200 s
presence.peers(cfg, "S", "main")
assert(not has(presence.here(cfg, "S", "main", 90), "Bee"), "and gone once their file stops changing")
band.age = real_age

-- Delete my copy (lib/localcopy.lua copy.holders): a holder counts only on a list said again lately, by someone not taken out
package.loaded.localcopy = nil
local copy = require("localcopy")
local lists = {
  { user = "Bob", time = "fresh", songs = { Song = { digest = "d1" } } },
  { user = "Old", time = "stale", songs = { Song = { digest = "d1" } } },
  { user = "Gone", time = "fresh", songs = { Song = { digest = "d1" } } },
  { user = "NoTime", songs = { Song = { digest = "d1" } } },
}
local age = function(t) return t == "fresh" and 3600 or 30 * 86400 end
local h = copy.holders(lists, "Song", "d1", "James", { Gone = true }, age)
assert(#h == 1 and h[1] == "Bob", "only Bob: a list from a month ago, a removed member's, or one with no time doesn't confirm a copy")

-- The code list (lib/band.lua band.files_list): path, length and hash; an older list without hashes still reads
local l = band.files_list("version 1.2\nlib/a.lua\t12\t00ff00ff00ff00ff\nlib/b.lua\t7\n")
assert(#l == 2 and l[1].path == "lib/a.lua" and l[1].len == 12 and l[1].hash == "00ff00ff00ff00ff" and l[2].len == 7 and l[2].hash == nil,
  "hash column read, and a list without it still works")
print("ok")
