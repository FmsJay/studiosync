-- A take envelope shown, hidden, armed or resized here isn't an edit; its points are (lib/mirror.lua normalize_item, 0.58.91). Lupa or Lua 5.4.
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local mirror = require("mirror")
local function item(vis, h, pt)
  return "<ITEM\n  POSITION 1\n  NAME x\n  <VOLENV\n    EGUID {A}\n    ACT 1 -1\n    VIS " .. vis .. " 1 1\n    LANEHEIGHT " .. h .. " 0\n    ARM 0\n    DEFSHAPE 0 -1 -1\n    PT 0 " .. pt .. " 0\n  >\n  <SOURCE WAVE\n    FILE \"a.wav\"\n  >\n>\n"
end
assert(mirror.normalize_item(item(1, 0, 1)) == mirror.normalize_item(item(0, 80, 1)), "shown or hidden, any height: the same item")
assert(mirror.normalize_item(item(1, 0, 1)) ~= mirror.normalize_item(item(1, 0, 0.5)), "a point moved is a change")
assert(mirror.normalize_item(item(1, 0, 1)):find("ACT 1 -1", 1, true), "the envelope itself still travels")
print("ok")
