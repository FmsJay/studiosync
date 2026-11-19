-- 0.59.46 (Round 2 review): roles go by the owner's own roles file; an admin's self-rename needs names.json fresh and can't land on a member's
-- name; a renamed owner keeps their pinned computers; trusted settings ask Syncthing once per band.json and write only on change; a save
-- doesn't write the held-back empty settings; a guest list replaced with nothing doesn't widen. Lupa or Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext, writes = 1000, {}, 0
reaper = setmetatable({
  time_precise = function() clock = clock + 40; return clock end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v, persist) ext[k] = v; if persist and k:find("^trusted settings") then writes = writes + 1 end end,
  DeleteExtState = function(_, k) ext[k] = nil end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log = function() end
local files = {}
band.read_json = function(p) return files[p] end
band.read = function(p) return files[p] and band.json_encode(files[p]) or nil end
local wrote = {}
band.write_json = function(p, t) files[p] = t; wrote[#wrote + 1] = p end
local writer, asks, mine = "", 0, "MMMMMMM-MINE"
package.loaded.services = { modified_by = function() asks = asks + 1; return writer end, my_device_id = function() return mine end,
  device_name = function(x) return tostring(x) end, is_device_id = function(x) return type(x) == "string" end }
local trust = require("trust")
local groups = require("groups")

local R = "/st"
local pins = { owner = "Olive", admins = { "Adam" }, devices = { Olive = { "OOOOOOO-1" }, Adam = { "AAAAAAA-1" } } }
band.set_ext_json(band.SECTION, "role pins studio-1 /st", pins, true)
ext.user = "Gus"

-- roles: the owner's roles file wins over an admin's later band.json save
files[R .. "/_band/band.json"] = { id = "studio-1", name = "St", owner = "Olive", admins = { "Adam" }, roles_at = 1 }
files[R .. "/_band/roles.json"] = { owner = "Olive", admins = { "Adam", "Bob" }, roles_at = 5 }
writer = "OOOOOOO"
local owner, admins = trust.roles(R, files[R .. "/_band/band.json"])
assert(owner == "Olive" and #admins == 2, "the owner made Bob an admin in the roles file: believed, though band.json (an admin's save) still has the old roles")
files[R .. "/_band/roles.json"] = { owner = "Adam", admins = { "Olive" }, roles_at = 6 }
writer = "AAAAAAA"
owner = trust.roles(R, files[R .. "/_band/band.json"])
assert(owner == "Olive", "an admin's computer writing the roles file: set aside")
files[R .. "/_band/roles.json"] = nil

-- self-rename: onto a member's name, refused; names.json not there yet, asked again later (not kept as a "no")
band.set_ext_json(band.SECTION, "role pins studio-1 /st", pins, true)
assert(not trust.self_rename(pins, "Olive", { "Mia" }, "AAAAAAA", { ADAM = "Mia" }, "MMMMMMM-OTHER"), "onto Mia's name, whose devices file names her computer: refused")
assert(trust.self_rename(pins, "Olive", { "Adam2" }, "AAAAAAA", { ADAM = "Adam2" }, "AAAAAAA-1"), "onto a new name with their own computer's file: allowed")
local ok, why = trust.self_rename(pins, "Olive", { "Adam2" }, "AAAAAAA", {}, nil)
assert(not ok and why == "names", "names.json not arrived yet: a no that isn't kept")
files[R .. "/_band/band.json"] = { id = "studio-1", name = "St", owner = "Olive", admins = { "Adam2" }, roles_at = 7 }
files[R .. "/_band/devices/Adam2.json"] = { user = "Adam2", device = "AAAAAAA-1" }
writer = "AAAAAAA"
assert(trust.roles(R, files[R .. "/_band/band.json"]) == "Olive" and not trust.pins(R).devices.Adam2, "before names.json: the roles it had")
files[R .. "/_band/names.json"] = { ADAM = "Adam2" }
local _, a2 = trust.roles(R, files[R .. "/_band/band.json"])
assert(a2[1] == "Adam2", "names.json arrived: the rename is taken, not refused for the session")
assert(trust.pins(R).devices.Adam2 and trust.pins(R).devices.Adam2[1] == "AAAAAAA-1", "and they keep the computer pinned under the old name")

-- repin: someone in charge who renamed keeps their computers, whatever their devices file says
local p = trust.repin({ owner = "Jim", admins = {}, devices = { Jim = { "JJJJJJJ-1" } } }, "James", {}, function() return nil end, nil, { JIM = "James" })
assert(p.devices.James and p.devices.James[1] == "JJJJJJJ-1", "a renamed owner keeps the computer pinned as theirs (it was locked out when the file couldn't be checked)")

-- trusted settings: one ask per band.json, a write only when they differ
local T = "/t"
files[T .. "/_band/band.json"] = { id = "studio-2", owner = "Olive", call = "https://meet.example.org/a" }
band.set_ext_json(band.SECTION, "role pins studio-2 /t", { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } }, true)
writer, asks, writes = "OOOOOOO", 0, 0
for _ = 1, 120 do groups.trusted(T) end -- (10 minutes of looks every 5 s)
assert(groups.trusted(T).call == "https://meet.example.org/a" and asks == 1 and writes == 1, "unchanged band.json: one ask and one write (" .. asks .. ", " .. writes .. ")")
files[T .. "/_band/band.json"] = { id = "studio-2", owner = "Olive", call = "https://meet.example.org/b" }
groups.trusted(T)
assert(asks == 2 and groups.trusted(T).call == "https://meet.example.org/b", "changed: asked again")

-- a save with nothing checked yet keeps the file's own settings, not the empty ones this computer goes by meanwhile
local U = "/u"
files[U .. "/_band/band.json"] = { id = "studio-3", owner = "Olive", call = "https://meet.example.org/c", updates = "folder" }
band.set_ext_json(band.SECTION, "role pins studio-3 /u", { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } }, true)
writer = nil
local t, sure = groups.trusted(U)
assert(next(t) == nil and sure == false, "not checked yet: nothing, and said to be held back")
groups.edit(U, function(j) j.sonobus = "x" end)
assert(files[U .. "/_band/band.json"].updates == "folder" and files[U .. "/_band/band.json"].call, "the save left the file's own settings (it wiped them for everyone)")

-- a guest list replaced with nothing doesn't widen
package.loaded.access = nil
local access = require("access")
mine = "GUESTID-1"
ext["guest list /g"] = band.json_encode({ "Lantern" })
files["/g/_band/guest-access/GUESTID.json"] = {}
local set = access.mine("/g")
assert(set and set.Lantern and not set.Other, "a list file replaced with {}: the list as it was (it gave every project)")
print("ok")
