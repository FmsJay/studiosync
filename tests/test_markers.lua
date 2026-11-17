-- Markers kept by number when the band's change (lib/band.lua match_markers, 0.58.91). Lupa or Lua 5.4.
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
local have = { { region = false, pos = 1, name = "Verse" }, { region = false, pos = 5, name = "Chorus" }, { region = true, pos = 1, name = "Verse" }, { region = false, pos = 9, name = "Gone" } }
local want = { { region = false, pos = 6, name = "Chorus" }, { region = false, pos = 1, name = "Intro" }, { region = true, pos = 1, name = "Verse" }, { region = false, pos = 12, name = "New" } }
local m, used = band.match_markers(have, want)
assert(m[1] == 2, "Chorus moved: the same marker")
assert(m[2] == 1, "Verse renamed Intro at the same spot: the same marker")
assert(m[3] == 3, "a region matches a region, not the marker at its spot")
assert(m[4] == nil and not used[4], "a new one is added, the gone one deleted")
print("ok")
