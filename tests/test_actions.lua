-- Which StudioSync scripts stay in REAPER's Actions list (lib/band.lua band.shown_action, 0.58.71)
reaper = reaper or { GetResourcePath = function() return "res" end }
package.path = "lib/?.lua;" .. package.path
local band = require("band")
for _, n in ipairs({ "Panel", "Undo", "Redo", "Live sync", "Draw", "Radial menu" }) do assert(band.shown_action(n, false, false), n .. " stays: it opens StudioSync, runs as an action, or is there to get a key") end
assert(not band.shown_action("Claim selected tracks", false, false), "the rest leave the list")
assert(band.shown_action("Claim selected tracks", false, true), "unless a key, a toolbar or a menu uses it")
assert(band.shown_action("Measure guest delay", true, false), "or you asked for every one")
print("ok")
