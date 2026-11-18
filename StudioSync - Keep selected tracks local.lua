-- @description StudioSync: keep the selected tracks on this computer (or share them again)
-- New tracks that never go to the others (a reference, a guide); pressed again with only such tracks selected, it shares them.
-- Bind it to a key (Actions list > "StudioSync - Keep selected tracks local" > Add shortcut) or a toolbar button. The panel does it (it opens if it was closed),
-- exactly as its control there does.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now. 0.59.24)
if not band.binding(reaper.EnumProjects(-1)) then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
band.panel_do(dir, "keeplocal")
