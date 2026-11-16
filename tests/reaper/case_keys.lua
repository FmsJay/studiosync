-- Run inside REAPER (ReaScript). REAPER hands project ExtState keys back upper-cased (EnumProjExtState), even before a save: what's applied
-- (sync.forget_trimmed) and who drove when (sync.driver_history) are kept as such keys, and were compared to file names and room names as
-- written. Every applied mark was cleared at each open (534 changes taken in again on the Mac each time) and every handover lost. 0.58.70.
-- A scratch folder and a scratch tab, saved into the scratch folder and closed.
local D = reaper.GetResourcePath() .. "/StudioSync/tests/case_" .. os.time()
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "rooms" }) do package.loaded[m] = nil end
local band, sync = require("band"), require("sync")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local cfg, song = { root = D, user = "James" }, "CaseLab"
local events = band.song_dir(cfg, song) .. "/rooms/main/events"
reaper.RecursiveCreateDirectory(events, 0)
local here_ids = { "Laptop-20261102-040529Z-00286-6675", "Chilio-Mac-20261102-012734Z-00001-4079" }
for _, id in ipairs(here_ids) do band.write_json(events .. "/" .. id .. ".json", { id = id }) end
local back = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0) -- new project tab
local tab = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  local _, k = (function() reaper.SetProjExtState(tab, "SSCaseProbe", "Mixed-Case", "1"); return reaper.EnumProjExtState(tab, "SSCaseProbe", 0) end)()
  out[#out + 1] = "(REAPER hands back '" .. tostring(k) .. "' for 'Mixed-Case')"
  for _, id in ipairs(here_ids) do reaper.SetProjExtState(tab, sync.APPLIED, id, "1") end
  reaper.SetProjExtState(tab, sync.APPLIED, "James-20261101-000000Z-00001-0001", "1") -- (its file trimmed away)
  local n = sync.forget_trimmed(tab, cfg, song)
  check(n == 1, "only the mark whose file is gone is forgotten: " .. tostring(n))
  check(sync.ext(tab, sync.APPLIED, here_ids[1]) == "1" and sync.ext(tab, sync.APPLIED, here_ids[2]) == "1", "the ones still in the folder stay applied")
  -- handovers kept in the project: read back whatever case REAPER gives them
  reaper.SetProjExtState(tab, sync.DRIVERS, "main/", "1")
  reaper.SetProjExtState(tab, sync.DRIVERS, "main/Laptop-20261102-050000Z-00001-1111", "2026-11-02T05:00:00Z|Laptop")
  reaper.SetProjExtState(tab, sync.DRIVERS, "side/James-20261102-060000Z-00001-2222", "2026-11-02T06:00:00Z|James")
  local list = sync.driver_history(tab, cfg, song .. " drivers", "main") -- (a key of its own: driver_history keeps what it read)
  check(list["LAPTOP-20261102-050000Z-00001-1111"] and list["LAPTOP-20261102-050000Z-00001-1111"].user == "Laptop", "the room's handover is read back")
  local n2 = 0
  for id in pairs(list) do if id ~= "(host)" then n2 = n2 + 1 end end
  check(n2 == 1, "and only that room's: " .. n2)
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
if reaper.ValidatePtr2(0, tab, "ReaProject*") then
  reaper.SelectProjectInstance(tab)
  reaper.Main_SaveProjectEx(tab, D .. "/end.rpp", 8)
  reaper.Main_OnCommand(40860, 0) -- close it
end
if back and reaper.ValidatePtr2(0, back, "ReaProject*") then reaper.SelectProjectInstance(back) end
out[#out + 1] = string.format("case_keys: fails %d of %d", fails, #out)
return table.concat(out, "\n")
