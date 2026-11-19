-- 0.59.45 (Round 1 review): every guest, with a project list or not, is known by a guest mark naming this computer; a mark this computer
-- accepted still counts after its file is deleted by someone who may not; a guest's ignore block leaves out the studio's StudioSync and
-- other people's files; a guest doesn't move to the studio's copy; a left mark counts only with that person's own device. Lupa or Lua 5.4.
package.path = "lib/?.lua;" .. package.path
local ext = {}
reaper = setmetatable({
  time_precise = function() return 0 end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  file_exists = function() return true end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log = function() end
local marks, devices = {}, {}
band.files = function(d)
  local src = d:find("/_band/removed$") and marks or d:find("/_band/devices$") and devices or {}
  local t = {}
  for f in pairs(src) do t[#t + 1] = f end
  table.sort(t)
  return t
end
band.read_json = function(p)
  local f = p:match("[^/]+$")
  if p:find("/_band/removed/") then return marks[f] elseif p:find("/_band/devices/") then return devices[f] end
end
band.bands = function() return { { root = "/st" } } end
local deleted_by_manager = false
package.loaded.trust = { mark_ok = function() return true end, pins = function() return { owner = "Olive", admins = {}, devices = {} } end,
  held = function() return false end, deleted_by_manager = function() return deleted_by_manager end,
  device_ok = function(_, user, id) return devices[user .. ".json"] ~= nil and devices[user .. ".json"].device == id end }
package.loaded.groups = { may_remove = function() return true end, trusted = function() return { updates = "folder" } end }
package.loaded.access = { mine = function() return nil end }
local my_id = "GUESTID-XXXX"
package.loaded.services = { my_device_id = function() return my_id end }
local removal = require("removal")

assert(not removal.am_guest("/st"), "no mark: not a guest")
marks["guest GUESTID.json"] = { user = "Gus", device = my_id, by = "Olive", at = os.time() + 86400, guest = true }
assert(removal.am_guest("/st"), "a guest mark naming this computer: a guest, with no project list too (they synced and ran the studio's copy)")

-- the guest deletes their mark: this computer still goes by it
marks["guest GUESTID.json"] = nil
assert(removal.am_guest("/st"), "a mark accepted here and then deleted by someone who may not: still counts (a guest who deleted theirs was never unshared)")
assert(not removal.may_auto_admit("/st", "OTHER01-YYYY", os.time()), "and still holds back letting others in without a click while their time runs")
marks["guest GUESTID.json"] = { user = "Gus", device = my_id, by = "Olive", at = os.time() + 86400, guest = true }
assert(removal.am_guest("/st"))
marks["guest GUESTID.json"], deleted_by_manager = nil, true
assert(not removal.am_guest("/st"), "deleted from the owner's or an admin's computer: over")

-- the guest's ignore block
local songsync = require("songsync")
local text = songsync.merge("", { Lantern = true }, nil, nil, nil, { me = "Gus", device = my_id })
local function at(line) local n = 0; for l in (text .. "\n"):gmatch("(.-)\n") do n = n + 1; if l == line then return n end end end
assert(at("/_tools") and at("/_tools") < at("!/_*"), "a guest without a list doesn't sync the studio's copy of StudioSync")
assert(at("!/_band/holds/Gus.json") < at("/_band/holds") and at("/_band/holds") < at("!/_*"), "others' holds left out, their own kept")
assert(at("!/_band/guest-access/GUESTID.json") < at("/_band/guest-access") and at("/_band/guest-invites") and at("/_band/feedback"), "others' lists, invitations and feedback left out")
local listed = songsync.merge("", nil, nil, { Lantern = true }, nil, { me = "Gus", device = my_id })
local _, n = listed:gsub("\n/_tools\n", "")
assert(n == 1, "a guest with a list: one /_tools line")
assert(not songsync.merge("", { Lantern = true }):find("/_tools", 1, true), "a member's block as before")

-- a guest's computer doesn't move to the studio's copy
deleted_by_manager = false
marks["guest GUESTID.json"] = { user = "Gus", device = my_id, by = "Olive", at = os.time() + 86400, guest = true }
local ff = require("fromfolder")
assert(ff.wanted({ root = "/st" }) == nil, "a guest without a list: not theirs to run")
my_id = "MEMBER1-ZZZZ"
assert(ff.wanted({ root = "/st" }) == "/st", "a member's computer: the studio's copy")

-- the move back: a guest's computer running the studio's copy goes back to the copy it ran from before, after two looks a minute apart, once;
-- and a computer that has moved already isn't moved again every minute
local t = 100
reaper.time_precise = function() t = t + 61; return t end
reaper.file_exists = function(p) return not p:find("%.git") end
local moved = {}
package.loaded.tools = { set_autostart = function(_, d) moved[#moved + 1] = d; return true end }
band.sync_actions = function() end
my_id = "GUESTID-XXXX"
ext["run from"], ext["run from before"] = "/st/_tools/studiosync", "/rp"
ff.tick("/st/_tools/studiosync")
assert(#moved == 0, "one look isn't enough")
ff.tick("/st/_tools/studiosync")
assert(moved[1] == "/rp" and ext["run from"] == "/rp", "a guest's computer goes back to the copy it ran from (the move was one-way)")
ff.tick("/st/_tools/studiosync"); ff.tick("/st/_tools/studiosync"); ff.tick("/st/_tools/studiosync")
assert(#moved == 1, "and only once")
my_id, ext["run from"] = "MEMBER1-ZZZZ", "/st/_tools/studiosync"
ff.tick("/rp"); ff.tick("/rp")
assert(#moved == 1, "a member's computer that has moved already, waiting for REAPER's restart: not written again every minute")
-- a left mark: only with the leaver's own device, as their devices file says; never a guest's
devices["Kim.json"] = { user = "Kim", device = "KKKKKKK-1" }
marks["Kim.json"] = { user = "Kim", device = "KKKKKKK-2", by = "Kim", at = 1, left = true, guest = true }
ext = {}
assert(not removal.gone("/st").Kim, "a left mark with a made-up device: set aside")
marks["Kim.json"] = { user = "Kim", device = "KKKKKKK-1", by = "Kim", at = 1, left = true, guest = true }
assert(removal.gone("/st").Kim, "with their own device: they're out")
local g = removal.guests("/st", os.time())
for _, x in ipairs(g) do assert(x.user ~= "Kim", "a left mark isn't a guest's") end
print("ok")
