-- Live sync redraws only after a pass that changed something (James, rt): the pass's writers that have no undo point say when they wrote.
-- Pings (lib/presence.lua): a marker added or taken away; following someone's mix: a fader moved. (Paint: tests/test_0_60_rt_colours.lua.)
package.path = "lib/?.lua;" .. package.path
local marks = {}
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetOS = function() return "Win64" end,
  ColorToNative = function(r, g, b) return (r << 16) | (g << 8) | b end,
  CountProjectMarkers = function() return #marks end,
  EnumProjectMarkers3 = function(_, i) local m = marks[i + 1]; return 1, false, m.pos, 0, m.name end,
  AddProjectMarker2 = function(_, _, pos, _, name) marks[#marks + 1] = { pos = pos, name = name } end,
  DeleteProjectMarkerByIndex = function(_, i) table.remove(marks, i + 1) end,
  GetProjExtState = function() return 0, "" end,
}, { __index = function() return function() end end })
local band = require("band")
band.log = function() end
local presence = require("presence")
local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
local peers = { { user = "Bo", ping = { pos = 12, at = now } } }
assert(presence.pings("P", peers) == true and #marks == 1, "a new ping: a marker, and said")
assert(presence.pings("P", peers) == false and #marks == 1, "the same ping again: nothing written")
assert(presence.pings("P", { { user = "Bo" } }) == true and #marks == 0, "gone: the marker taken away, and said")
assert(presence.follow_mix("P", {}, "Bo", {}) == nil, "following someone not here: nothing written")
print("ok")
