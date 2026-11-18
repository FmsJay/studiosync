-- @description StudioSync: selected tracks play wet (the studio's prints), on this computer only
-- Every part on the selected tracks plays the studio's print, exactly what whoever changed it heard; the track's plug-ins are held off here so
-- nothing goes through them twice. Put it on the track's right-click menu: Options > Customize menus/toolbars > Track control panel context.
local CHOICE, WORDS = "wet", [[wet: the studio's print, the track's plug-ins held off]]
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
