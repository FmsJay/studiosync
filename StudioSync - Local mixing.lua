-- @description StudioSync: Local mixing on or off (your faders and pan stay yours)
-- Switches Control your own mix (Home) on or off; switching it off asks whose mix to keep, as the switch does.
-- Bind it to a key (Actions list > "StudioSync - Local mixing" > Add shortcut) or a toolbar button. The panel does it (it opens if it was closed),
-- exactly as its control there does.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if not band.binding(reaper.EnumProjects(-1)) then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
band.panel_do(dir, "localmix")
