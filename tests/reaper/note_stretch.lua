-- Run inside REAPER (ReaScript). Notes on a stretch of a take (0.58.67): sync.mark_item gives every take's marker the stretch's length where
-- REAPER has take marker lengths (7.86), in the take's own time (a take played at double speed gets twice the length), and a note without one
-- stays a point. A scratch tab, closed without saving at the end.
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync" }) do package.loaded[m] = nil end
local sync = require("sync")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
if not reaper.SetTakeMarkerInfo then return "SKIP: this REAPER has no take marker lengths (7.86 and later)" end
reaper.Main_OnCommand(40859, 0)
local proj = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  reaper.InsertTrackAtIndex(0, false)
  local tr = reaper.GetTrack(proj, 0)
  local it = reaper.CreateNewMIDIItemInProj(tr, 4, 12) -- (an item from 4 s to 12 s)
  reaper.AddTakeToMediaItem(it) -- (a second take: a note shows on every take, as a print and its dry twin)
  sync.mark_item(it, 6, "Bee: rushed here", 2.5)
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    check(reaper.GetNumTakeMarkers(tk) == 1, "take " .. k .. " has the note")
    local pos, name = reaper.GetTakeMarker(tk, 0)
    check(math.abs(pos - 2) < 1e-6 and name == "Bee: rushed here", "at 2 s into the item (6 s in the song): " .. tostring(pos))
    check(math.abs(reaper.GetTakeMarkerInfo(tk, 0, "LENGTH") - 2.5) < 1e-6, "covering 2.5 s: " .. tostring(reaper.GetTakeMarkerInfo(tk, 0, "LENGTH")))
  end
  local tk = reaper.GetActiveTake(it)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", 2)
  reaper.DeleteTakeMarker(tk, 0)
  sync.mark_item(it, 6, "Sam: louder", 1)
  local last = reaper.GetNumTakeMarkers(tk) - 1
  check(math.abs(reaper.GetTakeMarkerInfo(tk, last, "LENGTH") - 2) < 1e-6, "at double speed the take's own time is twice as long")
  check(math.abs(reaper.GetTakeMarker(tk, last) - 4) < 1e-6, "and the note is where the song is at 6 s: 4 s into its source")
  local it2 = reaper.CreateNewMIDIItemInProj(tr, 20, 24)
  sync.mark_item(it2, 21, "Bee: nice")
  check(reaper.GetTakeMarkerInfo(reaper.GetActiveTake(it2), 0, "LENGTH") == 0, "a note without a stretch stays a point")
  local _, chunk = reaper.GetItemStateChunk(it2, "", false)
  check(chunk:find('TKM 1 "Bee: nice" 0\n', 1, true) ~= nil or chunk:find('TKM 1.0 "Bee: nice"', 1, true) ~= nil or chunk:find('TKM 1 "Bee: nice"', 1, true) ~= nil, "and is written as before")
end)
if not ok then check(false, "ERROR " .. tostring(err)) end
reaper.Main_OnCommand(40860, 0) -- (close the scratch tab)
out[#out + 1] = string.format("note_stretch: fails %d of %d", fails, #out)
return table.concat(out, "\n")
