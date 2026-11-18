-- 0.59.4 (lupa or Lua 5.4, from the repo root): tracks, items and regions each with their own way and palette.
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ GetOS = function() return "Win64" end, time_precise = function() return 0 end, GetExtState = function() return "" end },
  { __index = function() return function() end end })
for _, m in ipairs({ "band", "colours" }) do package.loaded[m] = nil end
local colours = require("colours")
local old = { scheme = "gradient", palette = "Ocean", from = "111111", to = "222222" }
local t, i, r = colours.part(old, "tracks"), colours.part(old, "items"), colours.part(old, "regions")
assert(t.scheme == "gradient" and t.palette == "Ocean", "tracks: the look itself")
assert(i.scheme == "section" and i.palette == "Ocean" and r.scheme == "sections" and r.palette == "Ocean", "a look from before: the old defaults, in the tracks' palette")
local new = { scheme = "gradient", palette = "Sunset", items = { scheme = "newest", palette = "Ember" }, regions = { scheme = "song", palette = "Your own", from = "000000", to = "FFFFFF" } }
i, r = colours.part(new, "items"), colours.part(new, "regions")
assert(i.scheme == "newest" and i.palette == "Ember", "items: their own")
assert(r.scheme == "song" and colours.stops_of(r)[1] == 0 and colours.stops_of(r)[2] == 0xFFFFFF, "regions: their own colours")
i = colours.part({ scheme = "gradient", items = { scheme = 5, palette = {} } }, "items")
assert(i.scheme == "section" and i.palette == "Sunset", "nonsense from band.json: the defaults")
assert(colours.part(nil, "regions").scheme == "sections", "no look at all")
for _, s in ipairs(colours.ITEM_SCHEMES) do assert(s[2] ~= "Along the song", "Chronologically now") end
print("ok")
