-- Run inside REAPER (ReaScript). The band's markers applied in place (0.58.91): a moved or renamed marker keeps its number, a region
-- keeps its, one that went is deleted and a new one gets the next free number. One scratch tab, closed at the end.
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
package.loaded.band = nil
local band = require("band")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0)
local p = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  reaper.AddProjectMarker2(p, false, 1, 0, "Verse", 3, 0)
  reaper.AddProjectMarker2(p, false, 5, 0, "Chorus", 7, 0)
  reaper.AddProjectMarker2(p, false, 9, 0, "Gone", 9, 0)
  reaper.AddProjectMarker2(p, true, 2, 4, "Solo", 2, 0)
  local list = band.capture_markers(p)
  for _, m in ipairs(list) do
    if m.name == "Chorus" then m.pos = 6 elseif m.name == "Verse" then m.name = "Intro" end
  end
  for i = #list, 1, -1 do if list[i].name == "Gone" then table.remove(list, i) end end
  list[#list + 1] = { region = false, pos = 12, ["end"] = 0, name = "New", color = 0 }
  band.apply_markers(p, list)
  local by = {}
  for i = 0, reaper.CountProjectMarkers(p) - 1 do
    local _, rgn, pos, _, name, num = reaper.EnumProjectMarkers3(p, i)
    by[name] = { num = num, pos = pos, rgn = rgn }
  end
  check(by.Chorus and by.Chorus.num == 7 and math.abs(by.Chorus.pos - 6) < 1e-9, "the moved marker keeps its number (7)")
  check(by.Intro and by.Intro.num == 3, "the renamed one keeps its number (3)")
  check(by.Solo and by.Solo.rgn and by.Solo.num == 2, "the region keeps its number (2)")
  check(by.Gone == nil, "the one that went is gone")
  check(by.New and by.New.num ~= 3 and by.New.num ~= 7, "the new one gets a free number (" .. tostring(by.New and by.New.num) .. ")")
  local again = band.capture_markers(p)
  check(#again == 4, "four in all")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
if reaper.ValidatePtr2(0, p, "ReaProject*") then
  reaper.SelectProjectInstance(p)
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/StudioSync/tests", 0)
  reaper.Main_SaveProjectEx(p, reaper.GetResourcePath() .. "/StudioSync/tests/markers_" .. os.time() .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
