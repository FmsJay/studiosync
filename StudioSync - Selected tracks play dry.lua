-- @description StudioSync: selected tracks play dry (each part itself, through the track's plug-ins), on this computer only
-- Every part on the selected tracks plays its dry take: the notes or recording through the track's plug-ins, which come back on if a print had
-- them held off. Try other plug-ins there to hear the part differently (a change to the track's plug-ins goes to the band, as any change does).
-- Put it on the track's right-click menu: Options > Customize menus/toolbars > Track control panel context > Add > this action.
local CHOICE, WORDS = "dry", [[dry: each part itself, through the track's plug-ins (back on)]]
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now. 0.59.24)
local proj = reaper.EnumProjects(-1)
if not band.binding(proj) then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
local n = reaper.CountSelectedTracks(proj)
if n == 0 then return band.msg("Select the tracks first (right-click a track, or click its name).") end
local prints = require("prints")
reaper.Undo_BeginBlock2(proj)
for i = 0, n - 1 do prints.set_track_choice(proj, reaper.GetSelectedTrack(proj, i), CHOICE) end
reaper.Undo_EndBlock2(proj, "StudioSync: tracks play " .. (CHOICE ~= "" and CHOICE or "as chosen"), -1)
band.log(string.format("%d track%s play%s %s here (only on this computer)", n, n == 1 and "" or "s", n == 1 and "s" or "", WORDS))
