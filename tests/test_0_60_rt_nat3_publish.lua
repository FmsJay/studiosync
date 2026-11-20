-- The devices file's NAT entry is published on a gate of its own (rt-nat3, lib/removal.lua publish_all): a person in two studios on two
-- StudioSync versions had the older version's removal tick take the shared "removal look" slot every time, its publish carrying no `nat`,
-- so this computer's key never reached its devices file. Here the older version holds that slot and the entry is still written; a field
-- the older version (or a later one) wrote stays; and an older version's rewrite without `nat` is repaired on the next pass.
package.path = "lib/?.lua;" .. package.path
local ext, files = {}, {}
reaper = setmetatable({
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetOS = function() return "Win64" end,
  RecursiveCreateDirectory = function() return 1 end,
}, { __index = function() return function() end end })
local band = require("band")
band.read_json = function(p) return files[p] end
band.write_json = function(p, t) files[p] = t end
local root = "J:/St/Smiley"
band.bands = function() return { { root = root, id = "smiley", name = "Smiley" } } end
package.loaded.services = { my_device_id = function() return "MEMEMEMEMEME" end, tailnet_now = function() return nil, nil end, my_tailscale_name = function() return nil end }
package.loaded.groups = { tailnet = function() return nil end, tick = function() end, is_old = function() return true end }
package.loaded.nat = { entry = function() return { pub = string.rep("ab", 32), tailnet = false } end }
local removal = require("removal")
ext[band.SECTION .. "/user"] = "James"
local path = root .. "/_band/devices/James.json"

-- the older version's own file (no nat), and its removal tick has just taken the shared slot
files[path] = { user = "James", device = "MEMEMEMEMEME", future = "kept" }
local now = 100000
ext[band.SECTION .. "/removal look"] = tostring(now)
removal.tick(now)
local d = files[path]
assert(type(d.nat) == "table" and d.nat.pub == string.rep("ab", 32), "the NAT entry is published although the older version holds the shared gate")
assert(d.future == "kept" and d.user == "James" and d.device == "MEMEMEMEMEME", "a field this version doesn't know stays")
-- the older version rewrites the file without nat; within 30 s this one puts it back, and not before its own gate opens
files[path] = { user = "James", device = "MEMEMEMEMEME" }
removal.tick(now + 10)
assert(files[path].nat == nil, "its own gate: at most every 30 s")
ext[band.SECTION .. "/removal look"] = tostring(now + 40)
removal.tick(now + 40)
assert(type(files[path].nat) == "table", "the entry repaired on the next pass, the shared slot still the older version's")
-- a file naming another computer isn't carried over
files[path] = { user = "James", device = "OTHEROTHEROT", stray = "x" }
ext[band.SECTION .. "/devices publish rt"] = nil
removal.publish_all(now + 80)
assert(files[path].device == "MEMEMEMEMEME" and files[path].stray == nil, "another computer's file: written over, nothing of it kept")
print("ok")
