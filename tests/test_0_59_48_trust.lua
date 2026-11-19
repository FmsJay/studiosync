-- 0.59.48 (Round 3 review): an invited computer held before its inviter's writing leaves held by band.json (not the owner-only roles file);
-- an invited computer with no pins is held whatever band.json's owner says; a "not from a manager" answer is kept 2 minutes; the roles file
-- is written only from the owner's computer, and by a rename; no-click saves wait while nothing is verified; the roles-file backfill runs
-- once per studio and session and logs a failure; the verified settings survive a crash. Lupa or Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  EnumerateFiles = function() return nil end, EnumerateSubdirectories = function() return nil end,
}, { __index = function() return function() return "" end end })
local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
band.log_file = function(s) logged[#logged + 1] = s end
local files, writes = {}, {}
local function copy(t) return t and band.json_decode(band.json_encode(t)) end -- (each file its own table, as on disk)
band.read_json = function(p) return copy(files[p]) end
band.read = function(p) return files[p] and band.json_encode(files[p]) or nil end
band.write_json = function(p, t)
  if FAIL_ROLES and p:find("roles.json", 1, true) then error("disk full") end
  files[p] = copy(t); writes[p] = (writes[p] or 0) + 1
end
reaper.file_exists = function(p) return files[p] ~= nil end
local writer, by_file, asks, mine = "", {}, 0, "MMMMMMM-MINE"
package.loaded.services = {
  modified_by = function(_, rel) asks = asks + 1; if by_file[rel] ~= nil then return by_file[rel] end return writer end,
  my_device_id = function() return mine end, device_name = function(x) return tostring(x) end,
  is_device_id = function(x) return type(x) == "string" and x ~= "" end,
  tailnet_now = function() return "net", "net-x.ts.net" end, days_quiet = function() return nil end, forget_folder = function() return true end,
}
package.loaded.alerts = { channel = function() return nil end }
local trust = require("trust")
local groups = require("groups")
local function pins_at(root, id, p) band.set_ext_json(band.SECTION, "role pins " .. id .. " " .. root, p, true) end
local OLIVE = { owner = "Olive", admins = { "Adam" }, devices = { Olive = { "OOOOOOO-1" }, Adam = { "AAAAAAA-1" } } }

-- M4: an invited computer held before its inviter's writing arrived leaves held once it does, though the owner-only roles file is there
local R = "/st"
files[R .. "/_band/band.json"] = { id = "studio-1", name = "St", owner = "Olive", admins = { "Adam" }, roles_at = 3,
  managers = { Olive = { "OOOOOOO-1" }, Adam = { "AAAAAAA-1" } } }
files[R .. "/_band/roles.json"] = { owner = "Olive", admins = { "Adam" }, roles_at = 2 }
pins_at(R, "studio-1", { owner = trust.INVITER, admins = {}, devices = { [trust.INVITER] = { "AAAAAAA-1" } }, held = true })
by_file = { ["_band/band.json"] = "AAAAAAA", ["_band/roles.json"] = "OOOOOOO" }
local owner = trust.roles(R, files[R .. "/_band/band.json"])
assert(owner == "Olive" and not trust.pins(R).held, "the inviter's band.json arrived: no longer held, Olive is owner (the roles file, from a computer held pins don't know, kept it held for good)")
by_file = {}

-- M5: an invited computer with no pins is held, and believes no settings, though band.json names no owner (a member took it out)
local J = "/j"
files[J .. "/_band/band.json"] = { id = "studio-j", name = "J", updates = "folder", call = "https://evil.example/x" }
ext["invited by /j"] = "AAAAAAA-INVITER"
writer = "MMMMMMM"
local t, sure = groups.trusted(J)
assert(t.updates == nil and t.call == nil and sure == false, "no owner in band.json, invited and not looked yet: nothing believed (it took Mallory's settings, updates too)")
assert(trust.held(J) == true, "and held, whatever band.json says")
assert(trust.mark_ok(J, "_band/removed/Olive.json", { at = 1, user = "Olive" }) == nil, "so a removal mark waits (anyone's was accepted)")
ext["invited by /j"] = nil
clock = clock + 10
assert(groups.trusted(J).updates == "folder", "not invited: a studio from before owners, as written, as before")

-- M7: a "not from a manager" answer is kept, and asked again after two minutes, not every 5 s
local T = "/t"
files[T .. "/_band/band.json"] = { id = "studio-2", owner = "Olive", call = "https://meet.example.org/a" }
pins_at(T, "studio-2", { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } })
writer, asks = "GGGGGGG", 0
for _ = 1, 120 do clock = clock + 5; groups.trusted(T) end -- (10 minutes of looks every 5 s)
assert(asks >= 4 and asks <= 6, "band.json from a computer not pinned as a manager's: about one ask per 2 minutes, not 120 (" .. asks .. ")")

-- M11: the roles file is written only on the owner's computer; a rename writes it too
local S = "/s"
files[S .. "/_band/band.json"] = { id = "studio-s", name = "S", owner = "Olive", admins = { "Adam" } }
pins_at(S, "studio-s", OLIVE)
ext["trusted settings /s"] = band.json_encode({})
writer = "OOOOOOO"
ext.user = "Adam"
groups.edit(S, function(j) j.sonobus = "a" end)
assert(files[S .. "/_band/roles.json"] == nil, "an admin's save: no roles file (only the owner's computer writes it)")
ext.user = "Olive"
groups.edit(S, function(j) j.sonobus = "b" end)
assert(files[S .. "/_band/roles.json"] and files[S .. "/_band/roles.json"].owner == "Olive", "the owner's save: the roles file")
band.rename(S, "Adam", "Adam2")
assert(files[S .. "/_band/roles.json"].admins[1] == "Adam2" and files[S .. "/_band/band.json"].admins[1] == "Adam2", "a rename reaches the roles file and band.json")

-- sec L1: a save nobody clicked for waits while nothing is verified; a click saves; the verified settings are kept against a crash
local Q = "/q"
files[Q .. "/_band/band.json"] = { id = "studio-q", name = "Q", owner = "Olive", call = "https://planted.example/x" }
pins_at(Q, "studio-q", { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } })
writer, ext.user = "GGGGGGG", "Olive"
clock = clock + 10
local _, _, checked = groups.trusted(Q)
assert(checked == false, "a member wrote band.json and nothing is kept here: nothing verified")
groups.set_tailnet(Q)
assert(not writes[Q .. "/_band/band.json"], "set_tailnet (no click): not saved (it wrote empty settings, or a member's, as a manager's)")
groups.set_debug(Q, true)
assert(writes[Q .. "/_band/band.json"] == 1, "a click: saved")
ext.bands = "/Q"
assert(table.concat(band.kept_keys(), "|"):find("trusted settings /q", 1, true), "the verified settings go into settings.json")

-- sec L2: the roles-file backfill: once per studio and session, a failure logged
local B = "/b"
files[B .. "/_band/band.json"] = { id = "studio-b", name = "B", owner = "Olive", sonobus = "s" }
pins_at(B, "studio-b", { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } })
ext["trusted settings /b"] = band.json_encode({})
band.bands = function() return { { root = B, name = "B", id = "studio-b" } } end
writer, ext.user, FAIL_ROLES, logged = "OOOOOOO", "Olive", true, {}
groups.tick(os.time()); clock = clock + 10; groups.tick(os.time())
assert(writes[B .. "/_band/band.json"] == 1, "a roles file that can't be written: band.json written once, not every tick (" .. tostring(writes[B .. "/_band/band.json"]) .. ")")
assert(table.concat(logged, "\n"):find("disk full", 1, true), "and the failure is logged (it was a silent pcall)")
FAIL_ROLES = nil
print("ok")
