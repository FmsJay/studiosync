-- rt-edits (James, 2026-11-20): the laptop's Cross Test had Hold sync on since the night before, so none of its edits went out. A colour look
-- tried here (lib/colours.lua try_first) holds sending; REAPER restarted mid-try, and mirror.restore_unsent put the try's hold back as Hold my
-- changes from the crash-safe file (or the project had been saved mid-try with it on). Now a try's hold is "try"/"try1", only your own Hold is
-- stashed, a try from before a restart goes back to what Hold was before it, and Health and the handover check say Hold is on. Each block fails
-- with its fix reverted. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
local open, fns = {}, {}
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function() return false end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  time_precise = function() return clock end,
  EnumProjects = function(i) local p = i >= 0 and open[i + 1]; if p then return p, fns[p] end end,
  GetPlayStateEx = function() return 0 end,
  ValidatePtr2 = function() return true end,
  GetMasterTrack = function(p) return "master of " .. tostring(p) end,
  CountTracks = function() return 0 end, CountProjectMarkers = function() return 0 end,
  CountMediaItems = function() return 0 end,
  file_exists = function() return true end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })

local files, logged = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then local c = {}; for k, x in pairs(v) do c[k] = x end; return c end end
proxy.listing = function() return {} end
proxy.write_json = function(path, v) files[path] = v end
proxy.log = function(t) logged[#logged + 1] = t end
package.loaded.band = proxy
local real_remove = os.remove
os.remove = function(path) files[path] = nil; return true end
local mirror = require("mirror")
local sync = require("sync")
local colours = require("colours")
local SECTION = band.SECTION
local PATH = "C:/s/Song.bandsync-unsent.json"
local function hold(p) return select(2, reaper.GetProjExtState(p, SECTION, "hold")) end
local function said(s) for _, l in ipairs(logged) do if l:find(s, 1, true) then return true end end end

-- what's yours
assert(sync.hold_mine("1") and sync.hold_mine("try1") and not sync.hold_mine("try") and not sync.hold_mine("") and not sync.hold_mine(nil), "only your own Hold")

-- 1. a try holds sending, as "try", and marks itself live for this REAPER only; Keep and Put back end it as Hold was
open, fns.P1 = { "P1" }, "C:\\s\\Song.RPP"
colours.try_first("P1", function() end)
assert(hold("P1") == "try" and sync.hold_words("P1"):find("colour look", 1, true), "trying: held, and said as a try")
assert(reaper.GetExtState(SECTION, "colour try P1") == "1", "live in this REAPER")
colours.keep("P1")
assert(hold("P1") == "" and reaper.GetExtState(SECTION, "colour try P1") == "" and sync.hold_words("P1") == nil, "kept: nothing held")
reaper.SetProjExtState("P1", SECTION, "hold", "1")
colours.try_first("P1", function() end)
assert(hold("P1") == "try1", "Hold already on: try1")
colours.put_back("P1")
assert(hold("P1") == "1" and sync.hold_words("P1"):find("Hold my changes is on", 1, true), "put back: your Hold as it was")
reaper.SetProjExtState("P1", SECTION, "hold", "")

-- 2. the stash keeps only your own Hold: a try's isn't written as held (the bug: d.hold == true came back as Hold on)
colours.try_first("P1", function() end)
mirror.unsent["P1I-ME-1-5"] = true
clock = clock + mirror.STASH_SECS
mirror.stash_unsent("P1", { ["I-ME-1-5"] = { kind = "item", oid = "I-ME-1-5", track = "T-ME-1-1", state = "<ITEM\nH\n>\n", hash = "hh", pos = 1 } })
assert(files[PATH] and files[PATH].hold == false, "a try isn't stashed as Hold")
mirror.unsent = {}

-- 3. REAPER restarted mid-try, without saving: the reopened project has no hold, the file says off -> nothing held
gext = {} -- (REAPER quit: its ExtState that wasn't persisted is gone)
open, fns.P2 = { "P2" }, "C:\\s\\Song.RPP"
mirror.restore_unsent("P2", {}, "M", false)
assert(hold("P2") == "", "reopened after a restart mid-try: not held")

-- 4. saved mid-try (hold "try" in the file): the try is over, so its hold goes
open, fns.P3 = { "P3" }, "C:\\s\\Song.RPP"
files[PATH] = { objs = { ["I-ME-1-5"] = { kind = "item", track = "T-ME-1-1", state = "<ITEM\nH\n>\n", hash = "hh" } }, hold = false }
reaper.SetProjExtState("P3", SECTION, "hold", "try")
logged = {}
mirror.apply = function() return true, "h" end
mirror.restore_unsent("P3", {}, "M", false)
assert(hold("P3") == "" and said("colour look was being tried"), "saved mid-try: no hold, and said: " .. table.concat(logged, " | "))
--    and with your own Hold on before the try: it stays on, as you had it
open, fns.P4 = { "P4" }, "C:\\s\\Song.RPP"
files[PATH] = nil
reaper.SetProjExtState("P4", SECTION, "hold", "try1")
mirror.restore_unsent("P4", {}, "M", false)
assert(hold("P4") == "1", "saved mid-try with Hold already on: your Hold stays")

-- 5. Live sync started again while the panel still tries a look (the ExtState lasts until REAPER quits): the try's hold stays
open, fns.P5 = { "P5" }, "C:\\s\\Song.RPP"
colours.try_first("P5", function() end)
files[PATH] = { objs = {}, hold = false }
mirror.restore_unsent("P5", {}, "M", false)
assert(hold("P5") == "try", "a try still on in the panel stays held")
colours.put_back("P5")

-- 6. your own Hold, stashed and reopened: still put back, and said each opening (the crash-safe rule is kept)
open, fns.P6, fns.P7 = { "P6" }, "C:\\s\\Song.RPP", "C:\\s\\Song.RPP"
reaper.SetProjExtState("P6", SECTION, "hold", "1")
mirror.unsent["P6I-ME-1-5"] = true
clock = clock + mirror.STASH_SECS
mirror.stash_unsent("P6", { ["I-ME-1-5"] = { kind = "item", oid = "I-ME-1-5", track = "T-ME-1-1", state = "<ITEM\nH\n>\n", hash = "hh", pos = 1 } })
assert(files[PATH].hold == true, "your Hold is stashed")
mirror.unsent = {}
open = { "P7" }
logged = {}
mirror.restore_unsent("P7", {}, "M", false)
assert(hold("P7") == "1" and said("Hold my changes is on"), "your Hold comes back, said")
open, fns.P8 = { "P8" }, "C:\\s\\Song.RPP"
files[PATH] = nil
reaper.SetProjExtState("P8", SECTION, "hold", "1")
logged = {}
mirror.restore_unsent("P8", {}, "M", false)
assert(said("Hold my changes is on in this project"), "opened with Hold on: said once")

-- 7. Health's row and the handover check say it
assert(sync.hold_words("P8"):find("Send now", 1, true), "how to switch it off")
package.loaded.status = nil
local status = require("status")
status.gather = function() return { rows = {} } end
sync.pending_events = function() return 0 end
local probs = status.handover_check({ user = "Me" }, { song = "S", room = "main" }, "P8").problems
local found
for _, p in ipairs(probs) do if p == "you: Hold sync is on" then found = true end end
assert(found, "the handover check says Hold is on")
reaper.SetProjExtState("P8", SECTION, "hold", "try")
probs = status.handover_check({ user = "Me" }, { song = "S", room = "main" }, "P8").problems
found = nil
for _, p in ipairs(probs) do if p:find("trying a colour look", 1, true) then found = true end end
assert(found, "and a try as a try")
local src = io.open("lib/page_health.lua"):read("a")
assert(src:find("sync.hold_words(proj)", 1, true), "Health has a row for it")
os.remove = real_remove
print("ok rt-edits hold")
