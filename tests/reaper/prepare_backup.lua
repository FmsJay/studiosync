-- Run inside REAPER (ReaScript). Prepare session's backup (0.58.92): an unsaved project gets one too, in StudioSync's own folder (it was
-- promised one and got none). A scratch tab; the backup it makes is removed afterwards.
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "prep", "mirror" }) do package.loaded[m] = nil end
local band, prep = require("band"), require("prep")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0) -- New project tab
local p = reaper.EnumProjects(-1)
local made
local ok, err = pcall(function()
  check(select(2, reaper.EnumProjects(-1)) == "", "the scratch tab is unsaved")
  local before = {}
  for _, f in ipairs(band.files(band.home() .. "/backups", ".rpp")) do before[f] = true end
  local done = prep.apply(p, nil, nil, {}, nil)
  for _, f in ipairs(band.files(band.home() .. "/backups", ".rpp")) do if not before[f] then made = band.home() .. "/backups/" .. f end end
  check(made ~= nil and made:find("Untitled - before StudioSync", 1, true) ~= nil, "a backup of the unsaved project is in StudioSync's folder: " .. tostring(made))
  local said = false
  for _, l in ipairs(done or {}) do said = said or l:find("Backup copy saved", 1, true) ~= nil end
  check(said, "and the result says so")
  check(select(2, reaper.EnumProjects(-1)) == "", "the tab itself stays unsaved (the backup is a copy)")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
if made then os.remove(made) end
if reaper.ValidatePtr2(0, p, "ReaProject*") then -- (saved under the tests folder first, as the other suites do: closing a changed tab asks)
  local D = reaper.GetResourcePath() .. "/StudioSync/tests"
  reaper.RecursiveCreateDirectory(D, 0)
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, D .. "/prepare_backup.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
  os.remove(D .. "/prepare_backup.rpp")
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
