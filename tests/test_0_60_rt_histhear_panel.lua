-- The panel's Restore page goes back to a moment in History by the same settled plan as the web page's restore and its preview
-- (lib/page_restore.lua plan_for -> lib/histhear.lua settle; rt-history): what sat on a track deleted before that moment isn't planned back,
-- and mirror.revert's own words no longer say it "couldn't change here yet". The real mirror.revert runs here, against a stand-in REAPER
-- with an empty project. (James, rt)
package.path = "lib/?.lua;" .. package.path
local here = {} -- oid -> true: what mirror's records say is in the project
local api = {
  time_precise = function() return 1000 end, GetOS = function() return "Win64" end, GetExtState = function() return "" end, SetExtState = function() end,
  GetExePath = function() return "C:/REAPER" end, GetResourcePath = function() return "C:/res" end,
  GetProjExtState = function(_, _, key) if here[key] then return 1, "1|h|x1|" end return 0, "" end,
  CountTracks = function() return 0 end, CountMediaItems = function() return 0 end,
  EnumProjExtState = function() return false end, EnumProjects = function() return nil end, file_exists = function() return false end,
  EnumerateFiles = function() return nil end, EnumerateSubdirectories = function() return nil end,
}
reaper = setmetatable({}, { __index = function(_, k)
  local f = api[k]
  if f then return f end
  if not tostring(k):find("^StudioSync_") then return function() return 0 end end
end })
local band = require("band")
local mirror = require("mirror")
local hh = require("histhear")
local R = require("page_restore")

local ITEM = "<ITEM\nPOSITION 0\nLENGTH 2\n>\n"
local es, k = {}, 0
local function e(time, x) k = k + 1; x.time, x.id, x.kind, x.user = "2026-11-12T" .. time .. "Z", "s" .. k, "obj", "Bo"; es[#es + 1] = x end
e("09:00:00", { obj = "track", oid = "T-B-1", rev = 1, name = "Old take 1", state = { name = "Old take 1", after = "" } })
e("09:00:10", { obj = "item", oid = "I-B-1", rev = 1, track = "T-B-1", state = ITEM })
e("09:00:20", { obj = "fx", oid = "F-B-1", rev = 1, track = "T-B-1", state = "<FXCHAIN\nBYPASS 0 0 0\n>\n" })
e("09:01:00", { obj = "track", oid = "T-B-1", rev = 2, gone = true, name = "Old take 1" }) -- (its item and plug-ins: no change of their own)
local moment = #es
e("09:05:00", { obj = "item", oid = "I-B-7", rev = 1, track = "T-HERE-7", state = ITEM }) -- (on a track History has nothing of, but here)
e("09:05:10", { obj = "item", oid = "I-B-9", rev = 1, track = "T-GONE-9", state = ITEM }) -- (on one that's neither)
here["T-HERE-7"] = true

local proj, cfg = {}, { root = "J:/S", user = "James" }
R.init({ b = function() return { song = "Song", room = "main" } end, cfg = function() return cfg end, proj = function() return proj end })
R.test.entries(es)

-- the plan the panel's buttons hand to mirror.revert, for a moment in History
local raw = mirror.plan_restore(es, moment)
assert(raw["T-B-1"] == false and raw["I-B-1"] and raw["F-B-1"], "mirror's plan names the deleted track's item and plug-ins")
local plan = R.test.plan_for(moment)
assert(plan["T-B-1"] == false and plan["I-B-1"] == false and plan["F-B-1"] == nil, "the panel's plan: the item went with its track, its plug-ins are left out")
local web = hh.settle(raw, function(oid) return hh.here(proj, oid) end)
for oid, v in pairs(web) do assert(plan[oid] == v, "the same plan as the web page's restore and the preview: " .. oid) end
for oid in pairs(plan) do assert(web[oid] ~= nil, "nothing more than theirs: " .. oid) end
local later = R.test.plan_for(#es)
assert(later["I-B-7"] and later["I-B-9"] == nil, "an item on a track that's here stays planned; on one neither here nor coming back, it's left out")
assert(R.test.plan_for(#es, nil, nil, true)["I-B-9"], "for a side room (another project), nothing is judged by what's in this one")
local scoped = R.test.plan_for(moment, nil, function(oid) return oid == "T-B-1" or oid == "I-B-1" end)
assert(scoped["I-B-1"] == false and scoped["T-B-1"] == false and scoped["F-B-1"] == nil, "the selected-tracks scope still applies, then settled")

-- what the panel then says: mirror.revert's own words, for the plan before and now
local opts = { can = function() return true end, mode = "open" }
local before = mirror.revert(proj, cfg, "Song", "main", raw, opts)
assert(before:find("couldn't change here yet", 1, true) and before:find("^0 change"), "mirror's plan as it was: changes that can never land, said every time: " .. before)
local said = mirror.revert(proj, cfg, "Song", "main", plan, opts)
assert(said == "0 change(s) brought back and sent to the others", "the settled plan: nothing waits: " .. said)

-- only the by-time plan changed: a saved version's own map (mirror.plan_known) is handed over as it is
local src = (function() local f = assert(io.open("lib/page_restore.lua", "rb")); local s = f:read("a"); f:close(); return s end)()
local _, n = src:gsub("mirror%.plan_restore%(", "")
assert(n == 1 and src:find("histhear.settle(mirror.plan_restore(entries, i, scope)", 1, true), "the page's one by-time plan goes through settle")
assert(src:find("return mirror.plan_known(entries, known,", 1, true), "a saved version with its own map is as before")
assert(src:find("plan_for(i, point, nil, true)", 1, true), "a side room's plan isn't judged by this project")

print("ok")
