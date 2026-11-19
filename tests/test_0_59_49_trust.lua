-- 0.59.49 (Round 4 review), trust side: an invited computer whose band.json names no owner goes by the inviter, not "open"; a "no" cached
-- while held lasts only while held (claims, closed.json, guest lists); a no-click save that's skipped says so to its callers (the SonoBus
-- secret, the alerts channel), groups.tick logs only a secret it made, and a removal's rotation is tried again. Lupa or Lua 5.4, repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  EnumerateFiles = function() return nil end, EnumerateSubdirectories = function() return nil end,
  genGuid = function() clock = clock + 0.001; return string.format("{%08x-0000}", math.floor(clock * 1000)) end,
  EnumProjects = function() return nil end,
}, { __index = function() return function() return "" end end })
local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
band.log_file = function(s) logged[#logged + 1] = s end
local files, writes = {}, {}
local function copy(t) return t and band.json_decode(band.json_encode(t)) end
band.read_json = function(p) return copy(files[p]) end
band.read = function(p) return files[p] and band.json_encode(files[p]) or nil end
band.write_json = function(p, t) files[p] = copy(t); writes[p] = (writes[p] or 0) + 1 end
reaper.file_exists = function(p) return files[p] ~= nil end
local by_file, mine = {}, "MMMMMMM-MINE"
package.loaded.services = {
  modified_by = function(_, rel) return by_file[rel] or "GGGGGGG" end,
  my_device_id = function() return mine end, device_name = function(x) return tostring(x) end,
  is_device_id = function(x) return type(x) == "string" and x ~= "" end,
  tailnet_now = function() return nil end, days_quiet = function() return nil end, forget_folder = function() return true end,
}
local trust, groups, access = require("trust"), require("groups"), require("access")
local function pins_at(root, id, p) band.set_ext_json(band.SECTION, "role pins " .. id .. " " .. root, p, true) end
local HELD = { owner = trust.INVITER, admins = {}, devices = { [trust.INVITER] = { "IIIIIII-1" } }, held = true }
local OLIVE = { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } }
local function has_log(s) for _, l in ipairs(logged) do if l:find(s, 1, true) then return true end end return false end

-- sec L1: invited, no pins yet, and band.json without an owner (a member keeps it out): the inviter alone, not a studio open to everyone
local J = "/j"
files[J .. "/_band/band.json"] = { id = "studio-j", name = "J" }
ext["invited by /j"] = "IIIIIII-INVITER"
assert(groups.role(J, "Mallory") == "member" and not groups.may_manage(J, "Mallory"), "every name could manage (let people in, take edits in an admins room)")
files[J .. "/_band/devices/Mallory.json"] = { user = "Mallory", device = "ZZZZZZZ-1" }
by_file["_band/devices/Mallory.json"] = "MMMMMMM"
assert(trust.device_ok(J, "Mallory", "ZZZZZZZ-1") == false, "a devices file someone else wrote doesn't count as its computer's while held")
local K = "/k" -- (not invited: a studio from before owners stays open, as before)
files[K .. "/_band/band.json"] = { id = "studio-k", name = "K" }
assert(groups.role(K, "Mallory") == "open" and trust.device_ok(K, "Mallory", "ZZZZZZZ-1") == true, "a studio from before owners: open, as before")

-- sec L4: a "no" given against held pins is asked again once the real pins come
local C = "/c"
files[C .. "/_band/band.json"] = { id = "studio-c", name = "C", owner = "Olive", admins = {} }
pins_at(C, "studio-c", HELD)
by_file["_band/band.json"] = "GGGGGGG"
local claim = { by = "Olive", user = "Bea", time = 5, tracks = {} }
by_file["s/rooms/main/claims/given-Bea-1.json"] = "OOOOOOO"
assert(trust.claim_ok(C, "s/rooms/main/claims/given-Bea-1.json", claim) == false, "held: the owner's claim isn't from a computer held pins know")
files[C .. "/_band/closed.json"] = { by = "Olive", at = 7 }
by_file["_band/closed.json"] = "OOOOOOO"
assert(groups.closed_ok(C) == false, "held: the owner's closed.json isn't believed yet")
files[C .. "/_band/guest-access/GGGGGGG.json"] = { device = "GGGGGGG-GUEST", songs = { "Demo" }, at = 3, by = "Olive" }
by_file["_band/guest-access/GGGGGGG.json"] = "OOOOOOO"
local set, checked = access.get(C, "GGGGGGG-GUEST")
assert(checked and next(set) == nil, "held: the owner's guest list shows nothing")
pins_at(C, "studio-c", OLIVE) -- (the inviter's writing arrived: the real pins)
clock = clock + 10
assert(trust.claim_ok(C, "s/rooms/main/claims/given-Bea-1.json", claim) == true, "not held any more: the claim counts (the held \"no\" stood until REAPER restarted)")
assert(groups.closed_ok(C) == true, "and the closed.json")
set, checked = access.get(C, "GGGGGGG-GUEST")
assert(checked and set and set.Demo, "and the guest list")
by_file["s/rooms/main/claims/given-Bea-2.json"] = "GGGGGGG"
assert(trust.claim_ok(C, "s/rooms/main/claims/given-Bea-2.json", claim) == false and trust.claim_ok(C, "s/rooms/main/claims/given-Bea-2.json", claim) == false,
  "a \"no\" against real pins is kept as before")

-- code 2 / changes 4: a no-click save skipped while nothing is verified says so, and its callers act on it
local S = "/s"
files[S .. "/_band/band.json"] = { id = "studio-s", name = "S", owner = "Olive", admins = {} }
pins_at(S, "studio-s", OLIVE)
by_file["_band/band.json"] = "GGGGGGG" -- (last written from a computer not pinned as a manager's, and nothing verified kept here)
ext.user = "Olive"
local before = writes[S .. "/_band/band.json"] or 0
assert(groups.new_sonobus_secret(S) == false and (writes[S .. "/_band/band.json"] or 0) == before, "not made, and says so (it returned nothing)")
package.loaded.alerts = nil
local alerts = require("alerts")
assert(alerts.set(S, true, true) == false and (writes[S .. "/_band/band.json"] or 0) == before, "the removal's new alerts channel is quiet too (it was written as a manager's)")
band.bands = function() return { { root = S, name = "S", id = "studio-s" } } end
groups.tick(clock)
assert(not has_log("password of its own"), "groups.tick says the secret was made only when it was (said every removal tick)")
local removal = require("removal")
assert(removal.rotate(S) == false, "a removal's rotation, skipped: tried again (the removal was marked done)")
by_file["_band/band.json"] = "OOOOOOO" -- (verified now)
clock = clock + 200
assert(removal.rotate(S) == true and files[S .. "/_band/band.json"].sonobus, "verified: the secret changes")
groups.tick(clock)
clock = clock + 200
files[S .. "/_band/band.json"].sonobus = nil
groups.tick(clock)
assert(has_log("password of its own"), "and groups.tick says so once it's made")
print("ok")
