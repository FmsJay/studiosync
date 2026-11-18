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
-- colours set by name: folders, sections, item kinds
local tracks = { { name = "Drums", family = 1, folder = "Drums" }, { name = "Kick", family = 1, folder = "Drums" }, { name = "Gtr", family = 2, folder = "Guitars" } }
local st = { 0x000000, 0xFFFFFF }
local fb = colours.folder_bases(tracks, st, { guitars = 0x123456 })
assert(fb[1] == 0x000000 and fb[2] == 0x123456, "a folder's own colour by its name, the rest along the palette")
local fp = colours.plan(tracks, "folders", { stops = st, folders = { guitars = 0x123456 } })
assert(fp[3] == 0x123456 and fp[1] == 0x000000 and fp[2] ~= fp[1], "folders: its tracks shades of it")
local other = { n = 0, map = {} }
assert(colours.section_colour("verse", st, { verse = 0xABCDEF }, other) == 0xABCDEF, "a section's own colour")
assert(colours.section_colour("chorus", st, {}, other) ~= colours.section_colour("verse", st, {}, other), "the common ones keep theirs")
assert(colours.section_colour("weird", st, nil, other) == colours.section_colour("weird", st, nil, other), "another, the same each time")
local mk = colours.plan_marks({ { name = "Verse 1", region = true }, { name = "Chorus", region = true } }, "sections", st, { verse = 0x010203 })
local ip = colours.plan_items({ { section = "Verse 2" }, { section = "Chorus 1" } }, "section", { stops = st, sections = { verse = 0x010203 } })
assert(mk[1] == 0x010203 and ip[1] == 0x010203 and ip[2] == mk[2], "items by section in the regions' colours")
local kp = colours.plan_items({ { kind = "midi" }, { kind = "audio" }, { kind = "print" } }, "kind", { stops = st, kinds = { audio = 0x0000FF } })
assert(kp[1] == 0x000000 and kp[2] == 0x0000FF and kp[3] ~= kp[1], "a kind's own colour")
print("ok")
