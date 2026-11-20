-- The hub's second slice (lib/hub.lua; docs/realtime-roadmap.md "More big ideas" 1): a file a person writes for themselves alone (their
-- handovers of a song's hub, session.json's sharer) counts only when Syncthing says their own computer wrote it (trust.own_file_ok), and the
-- direct link's view of each bandmate here (direct.reach) that failover in seconds goes by. Lupa or Lua 5.4, from the repo root. (James, rt)
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
band.info = function() return { id = "studio-1", name = "St" } end
local files = {}
band.read_json = function(p) return files[p] end
band.read = function(p) return files[p] and band.json_encode(files[p]) or nil end
local by_file, mine = {}, "MMMMMMM-MINE"
package.loaded.services = {
  modified_by = function(_, rel) return by_file[rel] end,
  my_device_id = function() return mine end, device_name = function(x) return tostring(x) end,
  is_device_id = function(x) return type(x) == "string" and x ~= "" end,
}
local trust = require("trust")
local R = "/st"
local REL = "Song/hub/Bo.json"
local old = os.time() - 3600

-- a studio from before owners (no pins, not invited): believed, as everywhere
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Desk", at = old } } }
assert(trust.own_file_ok(R, REL, "Bo", old) == true, "a studio from before owners: believed")

-- with roles pinned: Bo's devices file names Bo's computer, which wrote it itself
band.set_ext_json(band.SECTION, "role pins studio-1 /st", { owner = "Olive", admins = {}, devices = { Olive = { "OOOOOOO-1" } } }, true)
files[R .. "/_band/band.json"] = { id = "studio-1", owner = "Olive", admins = {} }
files[R .. "/_band/devices/Bo.json"] = { user = "Bo", device = "BBBBBBB-1" }
by_file["_band/devices/Bo.json"] = "BBBBBBB"
by_file[REL] = "BBBBBBB"
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Desk", at = old + 1 } } }
assert(trust.own_file_ok(R, REL, "Bo", old + 1) == true, "written by Bo's own computer: counts")

-- rewritten from another computer (Mal's), in Bo's name: set aside, and said once
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Mal", at = old + 2 } } }
by_file[REL] = "LLLLLLL"
local n = #logged
assert(trust.own_file_ok(R, REL, "Bo", old + 2) == false, "Bo's file written by another computer: set aside")
assert(#logged == n + 1 and logged[#logged]:find("set aside", 1, true), "and said")
assert(trust.own_file_ok(R, REL, "Bo", old + 2) == false and #logged == n + 1, "the verdict kept for that writing, said once")

-- a moment old: Syncthing may not have scanned it yet (it still names whoever wrote it before): not known yet, asked again
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Mal", at = os.time() - 10 } } }
assert(trust.own_file_ok(R, REL, "Bo", os.time() - 10) == nil, "a fresh writing from another computer: not yet, not 'no'")

-- Syncthing holds no record: believed; this computer writes only its own person's
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Ann", at = old + 3 } } }
by_file[REL] = ""
assert(trust.own_file_ok(R, REL, "Bo", old + 3) == true, "no record in Syncthing: believed, as everywhere")
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Ann", at = old + 4 } } }
by_file[REL] = "MMMMMMM"
ext.user = "Bo"
assert(trust.own_file_ok(R, REL, "Bo", old + 4) == true, "written here, and this is Bo's computer: counts")
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Ann", at = old + 5 } } }
ext.user = "Kim"
assert(trust.own_file_ok(R, REL, "Bo", old + 5) == false, "written here in someone else's name: set aside")

-- Syncthing didn't answer, or can't say yet whose computer Bo's is: not known yet
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Ann", at = old + 6 } } }
by_file[REL] = nil
assert(trust.own_file_ok(R, REL, "Bo", old + 6) == nil, "Syncthing didn't answer: not yet")
clock = clock + 31
by_file[REL] = "BBBBBBB"
files[R .. "/_band/devices/Bo.json"] = { user = "Bo", device = "BBBBBBB-1", at = 2 } -- (a new writing of it: asked again)
by_file["_band/devices/Bo.json"] = nil
assert(trust.own_file_ok(R, REL, "Bo", old + 6) == nil, "whose computer Bo's is not known yet: not yet")
-- a devices file naming a computer that didn't write it: nobody's own file counts through it
clock = clock + 31
by_file["_band/devices/Bo.json"] = "LLLLLLL"
files[R .. "/" .. REL] = { user = "Bo", transfers = { { to = "Ann", at = old + 7 } } }
assert(trust.own_file_ok(R, REL, "Bo", old + 7) == false, "Bo's devices file was forged: Bo's own file can't be checked against it")

-- ---- direct.reach: user -> the link's last answer, for those here ----
local direct = require("direct")
assert(next(direct.reach({ root = R }, "Song", "main")) == nil, "no extension: nothing")
reaper.StudioSync_DirectMsg, reaper.StudioSync_DirectClock, reaper.StudioSync_DirectStream = function() end, function() return "{}" end, function() end
reaper.StudioSync_DirectStatus = function()
  return band.json_encode({ peers = { ["lap:47281"] = { ok = true, at = 500 }, ["desk:47281"] = { ok = false, at = 600 }, ["desk2:47281"] = { ok = true, at = 590 } } })
end
direct.peers = function() return { "lap:47281", "desk:47281", "desk2:47281", "new:47281" }, {}, { ["lap:47281"] = "Lap", ["desk:47281"] = "Desk", ["desk2:47281"] = "Desk", ["new:47281"] = "New" } end
local r = direct.reach({ root = R }, "Song", "main")
assert(r.Lap.ok and r.Lap.at == 500, "Lap answered")
assert(r.Desk.ok and r.Desk.at == 590, "a person on two links: either answering is enough")
assert(r.New == nil, "one the link hasn't tried yet: not in it (the status files decide)")
print("ok hub trust")
