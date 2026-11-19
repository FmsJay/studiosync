-- 0.59.45 (Round 1 review): closed.json counts only from the owner's computer (never the "left" route), who's in charge changes only from the
-- owner's computer (an admin renaming themselves allowed), a trusted setting isn't believed before it's checked. Lupa or Lua 5.4, repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() clock = clock + 40; return clock end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log = function() end
local files = {}
band.read_json = function(p) return files[p] end
band.read = function(p) return files[p] and band.json_encode(files[p]) or nil end
local writer, mine = "", "MMMMMMM-MINE"
package.loaded.services = { modified_by = function() return writer end, my_device_id = function() return mine end, device_name = function(x) return tostring(x) end,
  is_device_id = function(x) return type(x) == "string" end }
local trust = require("trust")
local groups = require("groups")

local R = "/st"
files[R .. "/_band/band.json"] = { id = "studio-1", name = "St", owner = "Olive", admins = { "Adam" } }
local pins = { owner = "Olive", admins = { "Adam" }, devices = { Olive = { "OOOOOOO-1" }, Adam = { "AAAAAAA-1" } } }
band.set_ext_json(band.SECTION, "role pins studio-1 /st", pins, true)
ext.user = "Gus"

-- closed.json: from the owner's computer, yes; from an admin's, no; a member's with the "left" trick (their own device, by = the owner), no
files[R .. "/_band/closed.json"] = { by = "Olive", at = 1 }
writer = "AAAAAAA"
assert(not groups.closed_ok(R), "written by an admin's computer: not the owner's, so the studio isn't closed")
files[R .. "/_band/closed.json"] = { by = "Olive", at = 2, left = true, device = "GGGGGGG-1" }
writer = "GGGGGGG"
assert(not groups.closed_ok(R), "a member's file naming the owner, marked left with their own device: set aside (it closed the studio for everyone)")
files[R .. "/_band/closed.json"] = { by = "Olive", at = 3 }
writer = "OOOOOOO"
assert(groups.closed_ok(R), "from the owner's pinned computer: it counts")
files[R .. "/_band/closed.json"] = { by = "Adam", at = 4 }
writer = "AAAAAAA"
assert(not groups.closed_ok(R), "naming an admin: only the owner closes")

-- who's in charge: an admin's computer making themselves owner isn't believed; the owner's computer handing over is
assert(trust.self_rename(pins, "Olive", { "Adam2" }, "AAAAAAA", { ADAM = "Adam2" }), "an admin renaming themselves, from their own computer: allowed")
assert(not trust.self_rename(pins, "Olive", { "Adam2" }, "AAAAAAA", {}), "not when names.json doesn't say so")
assert(not trust.self_rename(pins, "Olive", { "Adam2" }, "GGGGGGG", { ADAM = "Adam2" }), "nor from someone else's computer")
assert(not trust.self_rename(pins, "Adam", { "Olive" }, "AAAAAAA", {}), "an admin making themselves owner is no rename")
files[R .. "/_band/band.json"] = { id = "studio-1", name = "St", owner = "Adam", admins = { "Olive" }, roles_at = 10 }
writer = "AAAAAAA"
local owner = trust.roles(R, files[R .. "/_band/band.json"])
assert(owner == "Olive", "an admin's computer writing owner = themselves: the roles this computer had stand (it was believed everywhere)")
files[R .. "/_band/band.json"] = { id = "studio-1", name = "St", owner = "Adam", admins = { "Olive" }, roles_at = 11 }
writer = "OOOOOOO"
owner = trust.roles(R, files[R .. "/_band/band.json"])
assert(owner == "Adam", "the owner's computer handing over: believed")

-- groups.trusted: an owner named, nothing checked here yet, Syncthing not saying: nothing, not band.json as anyone wrote it
local G = "/new"
files[G .. "/_band/band.json"] = { id = "studio-2", owner = "Olive", updates = "folder" }
band.set_ext_json(band.SECTION, "role pins studio-2 /new", { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } }, true)
writer = nil
assert(groups.trusted(G).updates == nil, "not checked yet: no folder updates from a file a member could have written")
local P = "/old"
files[P .. "/_band/band.json"] = { id = "studio-3", updates = "folder" }
assert(groups.trusted(P).updates == "folder", "a studio from before owners: as written, as before")
print("ok")
