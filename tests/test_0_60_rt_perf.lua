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
  GetResourcePath = function() return "C:/res" end,
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

-- ---- the direct link's JSON answers, decoded once while they read the same (lib/direct.lua) ----
local function peer_json(name, rtt) return string.format('"%s.tail99.ts.net:47281":{"ok":true,"ms":12,"error":"","at":1795100000,"sent":123456,' ..
  '"rate":4100000,"rate_at":1795100000,"rtt_ms":%d,"window":8}', name, rtt) end
local status_raw = '{"listening":true,"bind":"0.0.0.0:47281","error":"","received":42,"rejected":0,"last_reject":"","peers":{' ..
  table.concat({ peer_json("bo-pc", 18), peer_json("chilis-mac", 44), peer_json("james-laptop", 9) }, ",") .. '}}'
local clock_raw = '{"peers":{"bo-pc.tail99.ts.net:47281":{"offset_ms":3.5,"rtt_ms":18,"samples":16,"error":""}}}'
reaper.StudioSync_DirectStart = function() return 1 end
reaper.StudioSync_DirectSend = function() return 1 end
reaper.StudioSync_DirectStatus = function() return status_raw end
reaper.StudioSync_DirectMsg = function() return 1 end
reaper.StudioSync_DirectStream = function() return 1 end
reaper.StudioSync_DirectClock = function() return clock_raw end
reaper.StudioSync_DirectPeers = function() end
reaper.StudioSync_DirectNow = function() return 1795100000 end
package.loaded.services = { run_hidden = function() return "" end, tailscale_exe = function() return nil end, my_device_id = function() return "MMMMMMMMMMMM" end,
  is_device_id = function(id) return type(id) == "string" and #id > 10 end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end, sonobus_secret = function() return "s" end }
local direct = require("direct")
local real_decode, decodes = band.json_decode, 0
band.json_decode = function(s) if s == status_raw or s == clock_raw then decodes = decodes + 1 end; return real_decode(s) end -- (the link's answers only)
local cfg = { root = "S", user = "James" }
local s1, s2 = direct.status(cfg), direct.status(cfg)
assert(decodes == 1, "the same status twice: decoded once (" .. decodes .. ")")
assert(#s1.peers == 3 and #s2.peers == 3 and s1.peers[1].peer == s2.peers[1].peer and s2.received == 42, "and the same answer")
status_raw = status_raw:gsub('"rtt_ms":44', '"rtt_ms":45')
local s3 = direct.status(cfg)
assert(decodes == 2 and s3.peers[2].rtt_ms == 45, "a changed status: decoded again, and read as it is now")
-- the clock: keep_clock (each tick) and every shared_now (Link, streams, cues) share one decode, and "direct reference" is written on change
local writes, real_set = 0, reaper.SetExtState
reaper.SetExtState = function(sec, k, v, p) if k == "direct reference" then writes = writes + 1 end; return real_set(sec, k, v, p) end
decodes = 0
assert(direct.keep_clock(cfg, "Song", "main") == true, "the link keeps the clock")
for _ = 1, 50 do
  local now, dev, err, peer = direct.shared_now()
  assert(now == 1795100000 and dev == "MMMMMMMMMMMM" and err == 0 and peer == nil, "this computer is the reference (nobody else's device known)")
end
assert(decodes == 1, "the clock decoded once for keep_clock and 50 shared_now (" .. decodes .. ")")
assert(writes == 1 and gext["BandSync\0direct reference"] == "\tMMMMMMMMMMMM", "\"direct reference\" written once, not 51 times (" .. writes .. ")")
clock_raw = clock_raw:gsub('"offset_ms":3.5', '"offset_ms":4.0')
direct.shared_now()
assert(decodes == 2 and writes == 1, "a new estimate: decoded again; the same reference: not written again")
reaper.SetExtState, band.json_decode = real_set, real_decode
-- timed: decoding this status (3 peers, ~600 bytes) against direct.status reading the decoded one (the rest of direct.status included)
local N = 2000
local t0 = os.clock()
for _ = 1, N do band.json_decode(status_raw) end
local t_decode = (os.clock() - t0) / N * 1e6
t0 = os.clock()
for _ = 1, N do direct.status(cfg) end
local t_status = (os.clock() - t0) / N * 1e6
print(string.format("timing: decoding the status %.1f us; direct.status with it decoded once %.1f us", t_decode, t_status))

-- ---- Health's rows, built at most once a second (lib/page_health.lua: the Health tab asks every frame) ----
package.loaded.sync, package.loaded.setup, package.loaded.theme = {}, {}, { GREEN = 1, YELLOW = 2, GREY = 3, RED = 4 }
local H = require("page_health")
local tab, song = "P1", { song = "Song" }
H.init({ b = function() return song end, cfg = function() return { root = "S" } end, proj = function() return tab end, view = function() return {} end,
  wide = function() return false end })
local builds = 0
H.build_rows = function() builds = builds + 1; return { { "x", true, "red", "fine", "not" } } end
clock = 2000
local r1, r2 = H.maint_rows(), H.maint_rows()
assert(builds == 1 and r1 == r2, "two frames: built once")
clock = 2000.5; H.maint_rows()
assert(builds == 1, "half a second on: the same rows")
clock = 2001.01; H.maint_rows()
assert(builds == 2, "a second on: built again")
H.maint_at = 0; H.maint_rows()
assert(builds == 3, "a button changed something (H.maint_at): built again at once")
tab = "P2"; H.maint_rows()
assert(builds == 4, "another tab in front: built again")
song = { song = "Other" }; H.maint_rows()
assert(builds == 5, "another song: built again")
clock = 1990; H.maint_rows()
assert(builds == 6, "the clock went back: built again")

print("ok rt perf")
