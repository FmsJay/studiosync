-- Time-sync's delay (0.59.1, lupa or Lua 5.4 from the repo root): a whole NINJAM interval (the server's beats at the server's tempo) and a
-- second's margin, in bars at the song's tempo: more bars in a fast song.
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ GetOS = function() return "Win64" end, GetExtState = function() return "" end, time_precise = function() return 0 end },
  { __index = function() return function() end end })
local M = require("page_play")
local bars, secs = M.bars_behind(100, 4, 120, 4)
assert(math.abs(secs - 2.4) < 1e-9 and bars == 2, "120 bpm 4/4: a 2.4 s interval and a second is 2 bars of 2 s: " .. bars)
assert(M.bars_behind(100, 4, 180, 4) == 3, "180 bpm: bars are 1.33 s, so 3")
assert(M.bars_behind(100, 4, 60, 4) == 1, "60 bpm: one 4 s bar is enough")
assert(M.bars_behind(100, 4, 200, 3) == 4, "200 bpm in 3/4: 0.9 s bars, 4 of them")
assert(M.bars_behind(100, 8, 120, 4) == 3, "a longer interval on the server: more bars")
print("ok")
