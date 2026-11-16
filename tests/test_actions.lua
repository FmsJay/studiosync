-- Which StudioSync scripts stay in REAPER's Actions list (lib/band.lua band.shown_action, 0.58.71)
reaper = reaper or { GetResourcePath = function() return "res" end }
package.path = "lib/?.lua;" .. package.path
local band = require("band")
for _, n in ipairs({ "Panel", "Undo", "Redo", "Live sync", "Draw" }) do assert(band.shown_action(n, false, false), n .. " stays: it opens StudioSync, or runs as an action") end
assert(not band.shown_action("Hold my changes", false, false), "the rest leave the list")
assert(band.shown_action("Hold my changes", false, true), "unless a key, a toolbar or a menu uses it")
assert(band.shown_action("Measure guest delay", true, false), "or you asked for every one")
print("ok")
