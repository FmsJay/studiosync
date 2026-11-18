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
-- 0.59.6: regions chronologically by where they start; Talk quiet only while its own mic records
local cm = colours.plan_marks({ { name = "B", region = true, pos = 20 }, { name = "A", region = true, pos = 0 }, { name = "C", region = true, pos = 40 } }, "song", st)
assert(cm[2] == 0x000000 and cm[3] == 0xFFFFFF and cm[1] ~= cm[2] and cm[1] ~= cm[3], "listed out of order: coloured by where they are")
package.loaded.live = nil
local live = require("live")
assert(live.uses_input(3, 3) and not live.uses_input(3, 4), "mono input 4")
assert(live.uses_input(1024 + 2, 3) and live.uses_input(1024 + 2, 2) and not live.uses_input(1024 + 2, 4), "a stereo pair takes in both")
assert(live.uses_input(2048 + 0, 5, 6) and not live.uses_input(2048 + 0, 6, 6), "multichannel: as many as the track has")
assert(not live.uses_input(4096 + 63 * 32, 0) and not live.uses_input(-1, 0), "MIDI, or no input")
-- 0.59.7: the wheel gets HSV (a steady hue); text colours made to read on the theme
for _, c in ipairs({ 0xFF0000, 0x00FF00, 0x2F7BFF, 0x808080, 0x000000, 0xFFFFFF, 0xF7B2C4 }) do
  local back = colours.rgb_of_hsv(colours.hsv_int(c))
  for sh = 0, 16, 8 do assert(math.abs(((back >> sh) & 255) - ((c >> sh) & 255)) <= 2, string.format("%06X round trip: %06X", c, back)) end
end
local h = colours.to_hsv(0x00FF00)
assert(math.abs(h - 1 / 3) < 0.01, "green's hue")
package.loaded.theme = nil
local theme = require("theme")
assert(theme.contrast(0x000000, 0xFFFFFF) > 20 and theme.contrast(0x777777, 0x777777) == 1, "contrast")
local pale = theme.readable(0x2A2D33FF) -- (Dark: a near-background colour)
assert(theme.contrast(pale >> 8, theme.BG >> 8) >= 4.5, "made to read")
assert(theme.readable(0xFF8A3DFF) == 0xFF8A3DFF, "a colour that already reads stays")
print("ok")
