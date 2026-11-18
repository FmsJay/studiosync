-- @description StudioSync: change the shared folder and your name
-- (A new name moves who drives and your claims over everywhere, and your tracks stay yours: see band.rename.)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now. 0.59.24)

local cfg = band.settings(true)
if cfg then band.msg("Saved. Shared folder: " .. cfg.root .. "\nYour name: " .. cfg.user) end
