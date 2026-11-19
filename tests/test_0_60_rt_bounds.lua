-- Tables that grew all session, bounded (James, rt): streams' once-per-file tables drop entries over an hour old (a streamed take only once its
-- stream is gone too), and sync's refused_at forgets an hour-old refusal. Anything recent is kept as it was. (Live sync's seen_ev and fired:
-- in the script, checked in REAPER.)
package.path = "lib/?.lua;" .. package.path
local clock = 1000
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local streams = require("streams")

-- ---- streams.forget_old ----
local t = { old = clock - 3601, recent = clock - 3599, legacy = true }
streams.forget_old(t, clock, function(at) return at end)
assert(t.old == nil and t.recent and t.legacy, "over an hour: gone; within it, or not a time: kept")
local streamed = { a = { rel = "S/a", at = clock - 7200 }, b = { rel = "S/b", at = clock - 7200 }, c = { rel = "S/c", at = clock - 10 } }
local going = { ["S/b"] = true }
streams.forget_old(streamed, clock, function(s) return not going[s.rel] and s.at end)
assert(streamed.a == nil and streamed.b and streamed.c, "a streamed take goes once its stream is gone and it's an hour old")
local asked = { k = { at = clock - 4000, tries = 3 }, j = { at = clock - 5, tries = 1 } }
streams.forget_old(asked, clock, function(a) return a.at end)
assert(asked.k == nil and asked.j.tries == 1, "catch-up asks: an hour-old one forgotten, a recent one's count kept")

-- ---- sync.refused_since ----
local sync = require("sync")
local first = sync.refused_since("ev1")
clock = clock + 30
assert(sync.refused_since("ev1") == first, "the first time it was refused is kept")
clock = clock + 3700
local again = sync.refused_since("ev2") -- (any call sweeps, at most every 10 minutes)
assert(again == clock and sync.refused_since("ev1") == clock, "an hour on, ev1's refusal was forgotten: its minute starts again")

-- ---- the stream trace rolls at TRACE_MAX, one older copy kept ----
local log = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/studiosync_trace_test.log" -- (os.tmpname is the drive's root on Windows)
os.remove(log); os.remove(log .. ".1")
require("direct").trace_path = function() return log end
streams.TRACE_MAX = 200
for i = 1, 20 do streams.trace("line " .. i .. " of the test, padded to some length") end
local function size(p) local f = io.open(p, "rb"); if not f then return nil end local n = f:seek("end"); f:close(); return n end
assert(size(log) <= 200 + 80 and size(log .. ".1") and size(log .. ".1") > 200, "rolled: " .. tostring(size(log)) .. " and " .. tostring(size(log .. ".1")))
local f = io.open(log, "rb"); local last = f:read("a"); f:close()
assert(last:find("line 20 ", 1, true), "the newest line is in the current file")
os.remove(log); os.remove(log .. ".1")
print("ok")
