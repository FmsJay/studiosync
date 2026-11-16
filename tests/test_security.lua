-- The 0.58.78 security fixes, over a small in-memory REAPER, folder and Syncthing (lupa or Lua 5.4, from the repo root): the band.json id kept,
-- devices files that count only from the computer they name, the inviter as the only source of roles on a first look, given claims from the
-- giver's computer, the introducer switched off once let in with later members met through the studio, and the listening page served from a
-- copy outside the studio's folder.
local ext, fs, clock = {}, {}, 1000
local function dir_list(dir, want_dirs)
  local out, seen = {}, {}
  for p in pairs(fs) do
    local rest = p:sub(1, #dir + 1) == dir .. "/" and p:sub(#dir + 2)
    local name = rest and rest:match("^([^/]+)")
    if name and not seen[name] and ((rest:find("/", 1, true) ~= nil) == want_dirs) then seen[name] = true; out[#out + 1] = name end
  end
  table.sort(out)
  return out
end
local cmds = {}
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  time_precise = function() return clock end,
  file_exists = function(p) return fs[p] ~= nil end,
  EnumerateFiles = function(d, i) return i >= 0 and dir_list(d, false)[i + 1] or nil end,
  EnumerateSubdirectories = function(d, i) return i >= 0 and dir_list(d, true)[i + 1] or nil end,
  GetResourcePath = function() return "/res" end,
  ExecProcess = function(c) cmds[#cmds + 1] = c; return "0\n" end,
}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
band.read = function(p) return fs[p] end
band.write_atomic = function(p, s) fs[p] = s end
band.home = function() return "/res/StudioSync" end
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
local function said(s) for _, l in ipairs(logs) do if l:find(s, 1, true) then return true end end return false end
local services = require("services")
local by_file = {} -- "<root>|<rel>" -> what Syncthing says modified it
services.modified_by = function(folder, rel)
  for k, v in pairs(by_file) do if k:match("|(.*)$") == rel and folder == band.info(k:match("^(.-)|")).id then return v end end
end
local function id(c) return (c:rep(7) .. "-"):rep(7) .. c:rep(7) end
local MY, JAMES, BEE, KIM, MAL, STRANGER, INVW = id("M"), id("J"), id("B"), id("K"), id("X"), id("S"), id("W")
services.my_device_id = function() return MY end
services.device_name = function(d) return tostring(d):sub(1, 7) end
local trust, removal = require("trust"), require("removal")
local function put(path, t) band.write_json(path, t) end
local function wrote(root, rel, dev) by_file[root .. "|" .. rel] = dev and dev:sub(1, 7) or nil end
reaper.SetExtState(band.SECTION, "user", "Me", true)

-- the pure parts
assert(trust.wrote_itself(JAMES, JAMES:sub(1, 7)) and trust.wrote_itself(JAMES, "") and not trust.wrote_itself(JAMES, "XXXXXXX") and not trust.wrote_itself(JAMES, nil), "a devices file counts from the computer it names")
local pins = { owner = "James", admins = { "Bee" }, devices = { James = { JAMES }, Bee = { BEE } } }
assert(trust.from_user(pins, BEE:sub(1, 7), "Bee") and not trust.from_user(pins, JAMES:sub(1, 7), "Bee") and not trust.from_user(pins, "", "Bee"), "a claim from the giver's own computer")
local p = trust.repin(nil, "James", { "Bee" }, function() return MAL end, { James = { JAMES, "junk" }, Bee = {} })
assert(p.devices.James[1] == JAMES and #p.devices.James == 1 and p.devices.Bee[1] == MAL, "listed computers first (only real IDs); a devices file only for someone not listed")
assert(trust.repin(p, "James", { "Bee" }, function() return KIM end, { James = { KIM } }).devices.James[1] == JAMES, "a list moves nobody already pinned")
local m = trust.managers_of(pins, "James", { "Bee" }, "Bee", KIM)
assert(m.James[1] == JAMES and m.Bee[1] == BEE and m.Bee[2] == KIM and trust.managers_of(nil, "Kim", {}, "Me", MY) == nil, "managers: the pinned computers, and this one for its own person")
assert(trust.version({ roles_at = 1 }, "J", { "B" }) ~= trust.version({ roles_at = 2 }, "J", { "B" }), "the same roles written again are a new writing")

-- 1. the band.json id stands as first known; band.bands pins it, and says when band.json names another
local R0 = "/s/Zero"
put(R0 .. "/_band/band.json", { name = "Zero", id = "studiosync-zero-0001" })
fs[R0 .. "/Song/session.json"] = "{}"
reaper.SetExtState(band.SECTION, "sync_root", R0, true)
band.bands()
put(R0 .. "/_band/band.json", { name = "Zero", id = "studiosync-evil-0002" })
assert(band.info(R0).id == "studiosync-zero-0001", "a rewritten id isn't followed")
band.bands()
assert(said("names another Syncthing folder"), "and it says so")
band.pin_id("/s/Zero/", "studiosync-joined-0003")
assert(band.info(R0).id == "studiosync-joined-0003", "a join (or the installer) sets it for good, whatever the slashes")
reaper.SetExtState(band.SECTION, "sync_root", "", true)

-- 2. devices files: only the computer they name
local R1 = "/s/One"
put(R1 .. "/_band/band.json", { name = "One", id = "studiosync-one-0001", owner = "James", admins = { "Bee" } })
put(R1 .. "/_band/devices/James.json", { user = "James", device = JAMES }); wrote(R1, "_band/devices/James.json", JAMES)
put(R1 .. "/_band/devices/Bee.json", { user = "Bee", device = KIM }); wrote(R1, "_band/devices/Bee.json", MAL)
assert(trust.device_ok(R1, "James", JAMES) == true and trust.device_ok(R1, "Bee", KIM) == false, "Bee's file naming Kim's computer, written by someone else: set aside")
assert(said("names a computer (KKKKKKK) that didn't write it"), "and said")
assert(removal.device_of(R1, "James") == JAMES and removal.device_of(R1, "Bee") == nil, "so taking Bee out can't cut Kim off")
local p1 = trust.pin(R1, "James", { "Bee" })
assert(p1.devices.James[1] == JAMES and not p1.devices.Bee, "and Kim's computer isn't pinned as Bee's")
put(R1 .. "/_band/devices/Kim.json", { user = "Kim", device = KIM })
assert(trust.device_ok(R1, "Kim", KIM) == nil and removal.device_of(R1, "Kim") == nil, "Syncthing not saying yet: not yet")
local Ropen = "/s/Open"
put(Ropen .. "/_band/devices/Ann.json", { user = "Ann", device = "ANNDEVICE" })
assert(removal.device_of(Ropen, "Ann") == "ANNDEVICE", "a studio from before owners isn't asked (anyone there may take anyone out)")
fs[R1 .. "/_band/devices/James.json"] = nil
removal.publish(R1, "Bee", BEE)
assert(band.read_json(R1 .. "/_band/devices/Bee.json").device == BEE, "Bee's own computer writes over a file naming another")

-- 3. the first look of an invited computer
local R2 = "/s/Two"
trust.set_inviter(R2 .. "\\", JAMES)
assert(trust.inviter(R2) == JAMES, "the inviter, whatever the slashes")
put(R2 .. "/_band/band.json", { name = "Two", id = "studiosync-two-0001", owner = "James", admins = { "Bee" }, managers = { James = { JAMES }, Bee = { BEE } }, roles_at = 1 })
put(R2 .. "/_band/devices/James.json", { user = "James", device = JAMES }); wrote(R2, "_band/devices/James.json", JAMES)
put(R2 .. "/_band/devices/Bee.json", { user = "Bee", device = MAL }); wrote(R2, "_band/devices/Bee.json", MAL) -- (Mal says it's Bee's)
local o, a = trust.roles(R2, band.read_json(R2 .. "/_band/band.json"))
assert(o == "James" and #a == 0 and not trust.pins(R2) and trust.held(R2), "Syncthing not saying yet: the inviter alone, nothing pinned")
assert(trust.mark_ok(R2, "_band/removed/x.json", { at = 1 }) == nil and trust.claim_ok(R2, "S/rooms/main/claims/given-x.json", { by = "James", time = "t" }) == nil, "marks and claims wait for it")
clock = clock + 31
wrote(R2, "_band/band.json", JAMES)
o, a = trust.roles(R2, band.read_json(R2 .. "/_band/band.json"))
assert(o == "James" and a[1] == "Bee" and not trust.held(R2), "written by the inviter: believed")
assert(trust.pins(R2).devices.Bee[1] == BEE, "Bee's computer from the inviter's list, not the file Mal wrote claiming Bee's name")

local R3 = "/s/Three"
trust.set_inviter(R3, JAMES)
put(R3 .. "/_band/band.json", { name = "Three", id = "studiosync-three-0001", owner = "Mal", admins = {}, roles_at = 1 })
put(R3 .. "/_band/devices/James.json", { user = "James", device = JAMES }); wrote(R3, "_band/devices/James.json", JAMES)
wrote(R3, "_band/band.json", MAL)
local before = #logs
o, a = trust.roles(R3, band.read_json(R3 .. "/_band/band.json"))
assert(o == "James" and #a == 0 and trust.held(R3), "roles Mal wrote aren't believed on a first look: the inviter is in charge")
assert(said("isn't the one that invited you"), "said")
o = trust.roles(R3, band.read_json(R3 .. "/_band/band.json"))
assert(o == "James" and #logs == before + 1, "and stays so, said once")
put(R3 .. "/_band/band.json", { name = "Three", id = "studiosync-three-0001", owner = "Mal", admins = {}, roles_at = 2 })
wrote(R3, "_band/band.json", MY)
assert(trust.roles(R3, band.read_json(R3 .. "/_band/band.json")) == "James", "held: this computer's own writing back of them doesn't count")
put(R3 .. "/_band/band.json", { name = "Three", id = "studiosync-three-0001", owner = "Pat", admins = { "James" }, managers = { Pat = { KIM } }, roles_at = 3 })
wrote(R3, "_band/band.json", JAMES)
o, a = trust.roles(R3, band.read_json(R3 .. "/_band/band.json"))
assert(o == "Pat" and a[1] == "James" and not trust.held(R3) and trust.pins(R3).devices.Pat[1] == KIM, "the inviter's writing arrives: believed, the owner's computer from its list")

local R4 = "/s/Four"
trust.set_inviter(R4, JAMES)
put(R4 .. "/_band/band.json", { name = "Four", id = "studiosync-four-0001", owner = "Mal" })
wrote(R4, "_band/band.json", MAL)
assert(trust.roles(R4, band.read_json(R4 .. "/_band/band.json")) == trust.INVITER, "no name known for the inviter: nobody's name is in charge")
local Rold = "/s/Old"
put(Rold .. "/_band/band.json", { name = "Old", id = "studiosync-old-0001", owner = "Kim" })
assert(trust.roles(Rold, band.read_json(Rold .. "/_band/band.json")) == "Kim" and trust.pins(Rold), "joined before 0.58.78 (no inviter known): the first look takes what's there, as before")

-- 4. claims given by an admin (R2: James owner, Bee admin)
local c = { by = "Bee", time = "2026-11-16T01:00:00Z" }
wrote(R2, "S/rooms/main/claims/given-Kim-1.json", BEE)
assert(trust.claim_ok(R2, "S/rooms/main/claims/given-Kim-1.json", c) == true, "from Bee's computer: counts")
wrote(R2, "S/rooms/main/claims/given-Kim-2.json", MAL)
assert(trust.claim_ok(R2, "S/rooms/main/claims/given-Kim-2.json", c) == false and said("said to be given by Bee"), "from Mal's, saying Bee gave it: set aside")
wrote(R2, "S/rooms/main/claims/given-Kim-3.json", MY)
assert(trust.claim_ok(R2, "S/rooms/main/claims/given-Kim-3.json", c) == true, "this computer's own")
assert(trust.claim_ok(Ropen, "S/rooms/main/claims/given-x.json", c) == true, "a studio from before owners: anyone may give")

-- 5. meeting someone already in the studio, and the introducer flag
put(R2 .. "/_band/devices/Kim.json", { user = "Kim", device = KIM }); wrote(R2, "_band/devices/Kim.json", KIM)
put(R2 .. "/_band/devices/Fake.json", { user = "Fake", device = STRANGER }); wrote(R2, "_band/devices/Fake.json", MAL)
package.loaded.groups = { may_remove = function() return true end, is_old = function() return false end, tick = function() end }
assert(removal.known(R2, KIM, 0) == "Kim", "Kim's own file: met")
assert(removal.known(R2, STRANGER, 0) == nil and removal.known(R2, INVW, 0) == nil, "a stranger someone else wrote in, or nobody: not")
put(R2 .. "/_band/removed/Kim.json", { user = "Kim", device = KIM, by = "James", at = 1 }); wrote(R2, "_band/removed/Kim.json", JAMES)
assert(removal.known(R2, KIM, 0) == nil, "taken out: not met again")
put(R2 .. "/_band/removed/Kim.json", { user = "Kim", device = KIM, by = "James", at = 5000, guest = true })
assert(removal.known(R2, KIM, 100) == "Kim" and removal.known(R2, KIM, 5000 + removal.GRACE) == nil, "a guest: met during their day, not after")
fs[R2 .. "/_band/removed/Kim.json"] = nil

local RW = "/s/Wait"
local bands = { { root = R2, id = band.info(R2).id, name = "Two" }, { root = RW, id = "studiosync-wait-0001", name = "Wait", waiting = true } }
band.bands = function() return bands end
local offs, adds = {}, {}
services.introducers_off = function(keep) offs[#offs + 1] = keep; return true end
services.pending_devices = function() return { { id = KIM, name = "x", address = "" } } end
services.add_device = function(d, name, folder) adds[#adds + 1] = d .. " " .. name .. " " .. folder; return true end
local function tick() clock = clock + 31; removal.tick(clock) end
tick()
assert(#offs == 0, "a studio waiting with no inviter known: every introducer stays")
assert(adds[1] == KIM .. " Kim " .. band.info(R2).id and #adds == 1, "Kim, asking, is met in the studio their file is in")
trust.set_inviter(RW, INVW)
tick()
assert(#offs == 1 and offs[1][INVW] and not offs[1][JAMES], "introducers off, but the waiting studio's inviter's")
tick()
assert(#offs == 1 and #adds == 1, "not asked again while nothing changed; Kim met once")
bands[2].waiting = nil
tick()
assert(#offs == 2 and next(offs[2]) == nil, "let in there too: all off")

-- services.introducers_off against a stand-in Syncthing
package.loaded.services = nil
services = require("services")
services.syncthing_path = function() return "st" end
services.device_name = function(d) return d:sub(1, 7) end
reaper.ExecProcess = function(cmd)
  cmds[#cmds + 1] = cmd
  if cmd:find("devices list", 1, true) then return "0\n" .. JAMES .. "\n" .. KIM .. "\n" end
  if cmd:find(JAMES .. " introducer get", 1, true) then return "0\ntrue\n" end
  if cmd:find(KIM .. " introducer get", 1, true) then return "0\nfalse\n" end
  return "0\n"
end
cmds = {}
assert(services.introducers_off({}))
local set = {}
for _, cm in ipairs(cmds) do if cm:find("introducer set false", 1, true) then set[#set + 1] = cm end end
assert(#set == 1 and set[1]:find(JAMES, 1, true), "only the one that was an introducer")
cmds = {}
services.introducers_off({ [JAMES] = true })
for _, cm in ipairs(cmds) do assert(not cm:find("introducer set", 1, true), "a kept one stays") end

-- 6. the listening page: written to this computer's own folder, and the server pointed at that copy
package.loaded.alerts = { channel = function() end, server = function() end }
services.port_open = function() return false end
services.ts_exec = function() return "0\n" end
services.TMP = "/tmp"
package.loaded.services = services
local listen = require("listen")
fs = {}
put("/s/L/_band/band.json", { name = "L", id = "studiosync-l-0001" })
listen.tick_one({ root = "/s/L", user = "Me" })
local lid = band.info("/s/L").id
assert(fs["/res/StudioSync/listen-" .. lid .. ".html"]:find("<!doctype html>", 1, true), "the page, in this computer's StudioSync folder")
assert(not fs["/s/L/_band/listen.html"], "not in the studio's folder")
local bat = fs["/tmp/bandsync-listen-" .. lid .. ".cmd"]
assert(bat and bat:find('-Page "/res/StudioSync/listen-' .. lid .. '.html"', 1, true) and bat:find('-Root "/s/L"', 1, true), "the server serves that copy as the page")
assert(bat:find("listen-" .. lid .. ".alive", 1, true), "and its heartbeat has a new name, so a server from before quits")
print("ok")
