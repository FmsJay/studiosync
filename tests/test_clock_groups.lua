-- Clocks off between computers, and track groups two people numbered alike (lib/presence.lua, 0.58.89). Lupa or Lua 5.4.
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local presence = require("presence")
assert(presence.clock_gap(5, 1) == nil, "a few seconds on the way: fine")
assert(presence.clock_gap(600, 2) == 598, "ten minutes old on arrival: their clock is behind")
assert(presence.clock_gap(-300, 0) == -300, "from the future: theirs is ahead")
assert(presence.clock_gap(600, 60) == nil, "not a fresh change: nothing to tell")
local c = presence.group_clashes({ { "james", 1 << 4, 0 }, { "chilio", 1 << 4, 0 }, { "james", 1 << 1, 0 }, { "james", 1 << 1, 1 } })
assert(#c == 1 and c[1].group == 5 and c[1].makers[1] == "chilio" and c[1].makers[2] == "james", "group 5 holds two people's tracks; 2 and 33 only James's")
assert(#presence.group_clashes({ { "james", 0, 1 << 2 }, { "chilio", 0, 1 << 2 } }) == 1 and presence.group_clashes({ { "james", 0, 1 << 2 }, { "chilio", 0, 1 << 2 } })[1].group == 35, "the high half counts from 33")
print("ok")
