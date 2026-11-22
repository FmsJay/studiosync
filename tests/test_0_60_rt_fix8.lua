-- rt-fix8 (2026-11-21), rt-r3 check 5: a Stop pressed on the leader from a pause stopped the followers 2.00 s later, by the time backstop
-- (they had paused 0.06-0.18 s past the leader's position and never "reached" it). A stop from a pause now carries from_pause, and a
-- follower that is paused too stops at once with its cursor where the leader stayed. (Linux's startup.hand_over: tests/test_startup.lua.)
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ GetOS = function() return "Other" end, time_precise = function() return 100 end }, { __index = function() return function() end end })
local together = require("together")
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local live = read("StudioSync - Live sync.lua")

local stop = { type = "stop", follow = true, pos = 11.958, from_pause = true }
assert(together.paused_stop(stop, true, 2), "a stop from a pause, here paused (play state 2): due at once")
assert(together.paused_stop(stop, true, 3), "(paused with the play bit still set: the same)")
assert(not together.paused_stop(stop, true, 1), "still playing here: it waits to reach the position")
assert(not together.paused_stop(stop, true, 0), "already stopped here: nothing to stop")
assert(not together.paused_stop(stop, false, 2), "your own stop is never due this way")
assert(not together.paused_stop({ type = "stop", follow = true, pos = 11.958 }, true, 2), "a stop from playing (no from_pause) goes by position as before")
assert(not together.paused_stop({ type = "start", follow = true, pos = 1, from_pause = true }, true, 2), "only stops")
assert(not together.paused_stop({ type = "stop", pos = 11.958, from_pause = true }, true, 2), "only a side-by-side one (follow)")
assert(not together.paused_stop({ type = "stop", follow = true, from_pause = true }, true, 2), "with a position to stay at")

-- Live sync: the press carries it (only when the stop came from a pause), reached() asks first, the cursor goes to the leader's position
assert(live:find("from_pause = (not playing and side.paused) or nil", 1, true), "the stop pressed from a pause says so")
assert(live:find("if together.paused_stop(t, theirs, reaper.GetPlayStateEx(proj)) then past = 0; return true end", 1, true), "reached() takes a paused follower at once")
assert(live:find("if transport.from_pause and transport.pos then reaper.SetEditCurPos2(proj, transport.pos, false, false) end", 1, true), "the cursor where they stayed")
assert(live:find("reaper.OnStopButtonEx(proj)\r\n        if transport.from_pause", 1, true) or live:find("reaper.OnStopButtonEx(proj)\n        if transport.from_pause", 1, true), "after the stop")

print("ok: rt-fix8 (a stop from a pause stops a paused follower at once)")
