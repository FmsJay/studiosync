-- 0.59.32's pure parts: look-alike colours (Health), every copy of the undo scripts (Health's keys check), and Their time's timing median.
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({}, { __index = function() return function() return "" end end })
local people = require("people")
assert(people.distance(0xFF0000, 0xFF0000) == 0, "the same colour is no distance")
assert(people.distance(0xFF0000, 0x00FF00) > 500, "red and green are far apart")
assert(people.distance(0xFF5A5A, 0xFF5C58) < people.ALIKE, "two reds a shade apart look alike")
local p = people.PALETTE
for i = 1, #p do for j = i + 1, #p do assert(people.distance(p[i], p[j]) >= people.ALIKE, "the palette's own colours never count as alike") end end
local a = people.alike({ Al = 0xFF5A5A, Bo = 0xFF5D57, Cy = 0x4CC2FF })
assert(#a == 1 and a[1][1] == "Al" and a[1][2] == "Bo", "Al and Bo look alike; Cy doesn't")
assert(#people.alike({ Al = 0xFF5A5A, Cy = 0x4CC2FF }) == 0, "nobody alike")
local c = people.distinct({ Al = 0xFF5A5A, Bo = 0xFF5D57, Cy = 0x4CC2FF }, "Bo")
assert(people.distance(c, 0xFF5A5A) >= people.ALIKE and people.distance(c, 0x4CC2FF) >= people.ALIKE, "a pick for Bo is unlike Al and Cy")

local undo = require("undo")
local copies = undo.copies(table.concat({
  'SCR 4 0 RSaaa "Custom: StudioSync - Undo.lua" "D:\\old\\StudioSync - Undo.lua"',
  'SCR 4 0 RSbbb "Custom: StudioSync - Undo.lua" "D:\\Smiley\\_tools\\studiosync\\StudioSync - Undo.lua"',
  'SCR 4 32060 RS7d3c_aaa "Custom: StudioSync - Undo.lua" "D:\\old\\StudioSync - Undo.lua"',
  'SCR 4 0 RSccc "Custom: StudioSync - Redo.lua" "D:\\old\\StudioSync - Redo.lua"',
  'SCR 4 0 RSddd "Custom: Something else.lua" "D:\\x.lua"' }, "\n"))
assert(#copies.Undo0 == 2 and copies.Undo0[1] == "_RSaaa" and copies.Undo0[2] == "_RSbbb", "both copies of Undo in the main section")
assert(#copies.Undo32060 == 1 and copies.Undo32060[1] == "_RS7d3c_aaa", "the MIDI editor's")
assert(#copies.Redo0 == 1 and copies.Redo0[1] == "_RSccc" and not copies.Redo32060, "Redo's")

local L = require("latency")
assert(L.median({}) == nil, "nothing timed")
assert(L.median({ 0.30, 0.29, 0.31 }) == 0.30, "the middle one")
assert(L.median({ 0.30, 0.29, 0.31, 1.9, 0.30 }) == 0.30, "a burst caught across a seek is left out")
print("ok")
