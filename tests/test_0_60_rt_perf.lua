-- The efficiency pass (James, rt: "better or more efficient"; docs/realtime-roadmap.md "Efficiency pass"): the tick-timing summary
-- tests/reaper/rt_perf.lua reads, and each cache the pass added gives the same answers as the work it saves, timed where that's pure.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")

-- ---- the tick-timing summary (lib/rthealth.lua) ----
local R = require("rthealth")
assert(R.summary({}) == nil and R.summary(nil) == nil, "no ticks: nothing to say")
local xs = {}
for i = 1, 100 do xs[i] = i / 1000 end -- 1..100 ms, shuffled below
for i = 100, 2, -1 do local j = (i * 37) % i + 1; xs[i], xs[j] = xs[j], xs[i] end
local s = R.summary(xs)
assert(s.n == 100 and s.med == 50 and s.p95 == 95 and s.max == 100, string.format("median %s, p95 %s, max %s", s.med, s.p95, s.max))
assert(xs[1] ~= 0.001 or xs[2] ~= 0.002, "the caller's list isn't sorted in place")
s = R.summary({ 0.0123 })
assert(s.n == 1 and s.med == 12.3 and s.p95 == 12.3 and s.max == 12.3, "one tick")

print("ok rt perf")
