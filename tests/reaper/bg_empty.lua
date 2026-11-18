-- Run inside REAPER (ReaScript). 0.59.19: a background print whose copy has nothing selected to render ends at once (its hidden REAPER
-- quits, saying so), and isn't counted toward giving up on the background; before, REAPER's "Nothing to render!" box held it out of
-- sight for 3 minutes, then blamed a plug-in. One scratch tab, saved and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "bgrender", "prints", "json" }) do package.loaded[m] = nil end
local band, bg = require("band"), require("bgrender")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.RecursiveCreateDirectory(D, 0)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  local it = reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  reaper.SetMediaItemSelected(it, false) -- (the copy goes with nothing selected)
  local _, failed_before = bg.counts()
  local name = "print-bgempty-" .. os.time()
  local started = bg.start("bgempty", name, { reaper.GetTrackGUID(tr) }, function()
    band.render({ RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = 0, RENDER_CHANNELS = 2, RENDER_TAILFLAG = 0, RENDER_ADDTOPROJ = 0 },
      { RENDER_PATTERN = name, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS })
  end, 2, true, "Test")
  check(started, "the background job starts")
  local t0, state = reaper.time_precise(), nil
  while reaper.time_precise() - t0 < 90 do
    local path
    path, state = bg.claim("bgempty", name, D .. "/bgempty")
    if path or (state ~= "running") then break end
    local w = reaper.time_precise(); while reaper.time_precise() - w < 0.5 do end
  end
  local took = reaper.time_precise() - t0
  check(state == "failed", "it ends as failed (renders in front), not stuck: " .. tostring(state))
  check(took < 45, string.format("and soon: %.0f s (it was 180)", took))
  local _, failed_after = bg.counts()
  check(failed_after == failed_before, "not counted toward giving up on the background")
  check(not bg.stuck[name], "not marked stuck (that keeps a part's print from rendering)")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
if reaper.ValidatePtr2(0, pa, "ReaProject*") then
  reaper.SelectProjectInstance(pa)
  reaper.Main_SaveProjectEx(pa, D .. "/bg_empty.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
