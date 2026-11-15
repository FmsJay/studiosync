-- @description StudioSync: claim the selected tracks (only you change them)
-- The selected tracks become yours, as Home > Claims > Claim selected tracks does.
-- Bind it to a key (Actions list > "StudioSync - Claim selected tracks" > Add shortcut) or a toolbar button. The panel does it (it opens if it was closed),
-- exactly as its control there does.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if not band.binding(reaper.EnumProjects(-1)) then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
band.panel_do(dir, "claim")
