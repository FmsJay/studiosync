-- Following someone takes on their mix (lib/presence.lua, 0.58.82): what differs, and who's being followed (lupa or Lua 5.4)
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local presence = require("presence")
local have = { a = { v = 1, p = 0, s = 0 }, b = { v = 0.5, p = -0.25, s = 0 } }
local ch = presence.mix_changes(have, { a = { v = 1, p = 0, s = 2 }, b = { v = 0.25, p = -0.25, s = 0 }, gone = { v = 1, p = 0, s = 1 } })
assert(#ch == 2, "only what differs, on tracks this project has: " .. #ch)
assert(ch[1][1] == "a" and ch[1][2] == "I_SOLO" and ch[1][3] == 2, "a's solo")
assert(ch[2][1] == "b" and ch[2][2] == "D_VOL" and ch[2][3] == 0.25, "b's fader")
assert(#presence.mix_changes(have, { a = { v = 1.00001, p = 0.0002, s = 0 } }) == 0, "a hair's difference isn't a change")
assert(#presence.mix_changes(have, nil) == 0, "nothing to follow: no changes")
local peers = { { user = "Sam", follow = "James" }, { user = "Bee", follow_driver = true } }
assert(presence.followed(peers, "James", "Al"), "followed by name")
assert(presence.followed({ peers[2] }, "James", "James") and not presence.followed({ peers[2] }, "James", "Al"), "Always follow the driver counts while you drive")
assert(not presence.followed({}, "James", "James"), "nobody: not followed")
print("ok")
