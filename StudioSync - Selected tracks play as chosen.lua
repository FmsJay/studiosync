-- @description StudioSync: selected tracks play as chosen in Settings (Auto, through my plug-ins, or as printed), on this computer only
-- Takes away the selected tracks' own dry or wet choice: they play as Settings > Options > Parts play says, like every other track.
local CHOICE, WORDS = "", [[as Settings > Options > Parts play says]]
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local proj = reaper.EnumProjects(-1)
if not band.binding(proj) then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
local n = reaper.CountSelectedTracks(proj)
if n == 0 then return band.msg("Select the tracks first (right-click a track, or click its name).") end
local prints = require("prints")
reaper.Undo_BeginBlock2(proj)
for i = 0, n - 1 do prints.set_track_choice(proj, reaper.GetSelectedTrack(proj, i), CHOICE) end
reaper.Undo_EndBlock2(proj, "StudioSync: tracks play " .. (CHOICE ~= "" and CHOICE or "as chosen"), -1)
band.log(string.format("%d track%s play%s %s here (only on this computer)", n, n == 1 and "" or "s", n == 1 and "s" or "", WORDS))
