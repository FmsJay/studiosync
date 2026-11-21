-- rt-perfcut3: Live sync's idle base, measured per sub-tick on the desktop (start/link ~1.9 % of a core, the whole start lap ~3.2 %), cut:
--  1. the start lap's sub-ticks that only poll run at their own pace (SUB_EVERY), the link, controllers, live audio, Link, hops, the web UI
--     and the hub every tick as before;
--  2. the direct link's clock JSON decoded once while its estimates read the same (its "now" changed every call: decoded every tick);
--  3. this computer's Syncthing ID kept a few seconds (a file read and a JSON decode each call, 0.3 ms, every tick from keep_clock).
package.path = "lib/?.lua;" .. package.path
local function check(cond, what) if not cond then error(what, 2) end end
local f = assert(io.open("StudioSync - Live sync.lua", "rb"))
local src = f:read("a"):gsub("\r\n", "\n")
f:close()

-- ---- 1. the schedule, as the file has it ----
local a = src:find("local SUB_EVERY", 1, true)
local z = src:find("local function tick_body()", a, true)
check(a and z, "SUB_EVERY and sub_due sit before tick_body")
local SUB_EVERY, sub_due = assert(load(src:sub(a, z - 1) .. "\nreturn SUB_EVERY, sub_due", "sched", "t", { perf = { on = false } }))()
for name, every in pairs(SUB_EVERY) do check(every >= 0.1 and every <= 1, "10 Hz or slower, at least once a second: " .. name .. " " .. every) end
for _, name in ipairs({ "link", "controllers", "liveaudio", "ablink", "hops", "webui", "hub", "clip, together", "lock, follow file" }) do
  check(SUB_EVERY[name] == nil, "every tick, as before: " .. name)
end
-- 10 s of ticks ~31 ms apart: each paced sub-tick about 1 / its pace a second; one not in the table every tick
local at, runs, t = {}, {}, 1000
for _ = 1, 320 do
  t = t + 0.031
  for _, name in ipairs({ "follow", "claimask", "bounces", "needlist", "link" }) do if sub_due(at, name, t) then runs[name] = (runs[name] or 0) + 1 end end
end
check(runs.link == 320, "the link every tick: " .. tostring(runs.link))
check(runs.follow >= 75 and runs.follow <= 100, "follow ~10 a second: " .. runs.follow)
check(runs.claimask == runs.follow, "claimask at the same pace")
check(runs.bounces >= 30 and runs.bounces <= 40, "bounces ~4 a second: " .. runs.bounces)
check(runs.needlist >= 9 and runs.needlist <= 11, "needlist once a second: " .. runs.needlist)
check(sub_due(at, "needlist", t - 5), "a clock that went back runs it at once (and starts again from there)")
-- each paced sub-tick is gated where tick_body calls it, once, by its own name; the others are called unconditionally
local body = src:find("local function tick_body()", 1, true)
local start = src:find('\n  lap("start")', body, true)
local lap_src = src:sub(body, start)
for name in pairs(SUB_EVERY) do
  local n = select(2, lap_src:gsub('sub_due%(sub_at, "' .. name:gsub("%p", "%%%0") .. '", tnow%)', ""))
  check(n == 1, "gated once in tick_body's start lap: " .. name .. " " .. n)
end
for _, call in ipairs({ 'band.try("direct.live_tick"', 'band.try("controllers.tick"', 'band.try("liveaudio.tick"', 'band.try("ablink.tick"',
    'band.try("hops.tick"', 'band.try("webui.tick"', 'band.try("hub.tick"', "together.tick()" }) do
  local at2 = lap_src:find(call, 1, true)
  local line = at2 and lap_src:sub(1, at2):match("[^\n]*$")
  check(line and not line:find("if", 1, true), "called every tick: " .. call .. " " .. tostring(line))
end
check(lap_src:find("local tnow = reaper.time_precise()", 1, true), "one clock read for the schedule")

-- perf stats count a paced sub-tick's lap only when it ran ("ticks" shows its pace); off, nothing is noted (rt-perfcut3, after the desktop
-- read ~320 ticks for every start sub-step)
local sl = src:match("\n(local function sub_lap%(name%)[^\n]*)\n")
check(sl, "sub_lap is one line")
local function run_ticks(on)
  local perf, laps = { on = on }, {}
  local env = { perf = perf, lap = function(name) laps[name] = (laps[name] or 0) + 1 end }
  local lap_fn = assert(load(sl .. "\nreturn sub_lap", "sub_lap", "t", env))()
  local due = assert(load(src:sub(a, z - 1) .. "\nreturn sub_due", "sched2", "t", env))()
  local at2, t2 = {}, 2000
  for _ = 1, 320 do
    t2 = t2 + 0.031
    for _, name in ipairs({ "follow", "needlist", "link" }) do
      due(at2, name, t2)
      lap_fn("start/" .. name)
    end
  end
  return laps, perf
end
local laps_on, p_on = run_ticks(true)
check(laps_on["start/link"] == 320, "an unpaced step's lap every tick: " .. tostring(laps_on["start/link"]))
check(laps_on["start/follow"] >= 75 and laps_on["start/follow"] <= 100, "follow's lap only when it ran: " .. tostring(laps_on["start/follow"]))
check(laps_on["start/needlist"] >= 9 and laps_on["start/needlist"] <= 11, "needlist's once a second: " .. tostring(laps_on["start/needlist"]))
check(not p_on.skip, "nothing left over for the next tick")
local laps_off, p_off = run_ticks(false)
check(next(laps_off) == nil and not p_off.skip, "perf stats off: no laps, nothing noted")
-- each paced gate is followed by its own sub-lap before the next gate, so a skip can only drop its own lap
local gates = {}
for pos in lap_src:gmatch("()sub_due%(sub_at") do gates[#gates + 1] = pos end
check(#gates >= 8, "the paced gates: " .. #gates)
for i, pos in ipairs(gates) do
  local nxt_lap = lap_src:find('sub_lap("start/', pos, true)
  check(nxt_lap and (not gates[i + 1] or nxt_lap < gates[i + 1]), "a sub-lap right after paced gate " .. i)
end

-- ---- 2. the clock JSON: its "now" changes every call; decoded once while the estimates are the same ----
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Other" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetExePath = function() return "/R" end,
  GetResourcePath = function() return "/res" end,
  file_exists = function(p) return p == "/opt/st/syncthing" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local calls, est = 0, '"bo-pc.tail99.ts.net:47281":{"offset_ms":3.5,"rtt_ms":18,"spread_ms":1,"samples":16,"at":1795100000,"error":""}'
reaper.StudioSync_DirectStart = function() return 1 end
reaper.StudioSync_DirectSend = function() return 1 end
reaper.StudioSync_DirectStatus = function() return "{}" end
reaper.StudioSync_DirectMsg = function() return 1 end
reaper.StudioSync_DirectStream = function() return 1 end
reaper.StudioSync_DirectClock = function() calls = calls + 1; return string.format('{"now":%.6f,"peers":{%s}}', 1795100000 + calls * 0.031, est) end
reaper.StudioSync_DirectPeers = function() end
reaper.StudioSync_DirectNow = function() return 1795100000 end
package.loaded.services = { run_hidden = function() return "" end, tailscale_exe = function() return nil end, my_device_id = function() return "MMMMMMMMMMMM" end,
  is_device_id = function(id) return type(id) == "string" and #id > 10 end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end, sonobus_secret = function() return "s" end }
local direct = require("direct")
local real_decode, decodes = band.json_decode, 0
band.json_decode = function(s) if tostring(s):find('"peers"', 1, true) then decodes = decodes + 1 end; return real_decode(s) end
local cfg = { root = "S", user = "James" }
check(direct.keep_clock(cfg, "Song", "main") == true, "the link keeps the clock")
for _ = 1, 50 do direct.keep_clock(cfg, "Song", "main"); direct.shared_now() end
check(calls >= 100 and decodes == 1, "a clock whose now moves, its estimates not: decoded once in " .. calls .. " reads (" .. decodes .. ")")
est = est:gsub('"offset_ms":3.5', '"offset_ms":4.0')
local _, _, _, peer = direct.shared_now()
check(decodes == 2 and peer == nil, "a new estimate: decoded again")
band.json_decode = real_decode
package.loaded.services, package.loaded.direct = nil, nil

-- ---- 3. this computer's Syncthing ID, kept MY_ID_KEEP s once found ----
local reads, answer = 0, '{"myID":"AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"}'
gext["BandSync\0syncthing_path"] = "/opt/st/syncthing"
local real_read, real_wa = band.read, band.write_atomic
band.read = function(p) if tostring(p):find("bandsync%-st%-system%.txt$") then reads = reads + 1; return answer end; return nil end
band.write_atomic = function() return true end
local services = require("services")
local id = services.my_device_id()
check(services.is_device_id(id) and reads == 1, "the ID, from Syncthing's answer: " .. tostring(id) .. " " .. reads)
for _ = 1, 300 do clock = clock + 0.031; check(services.my_device_id() == id, "the same ID") end
check(reads == 1, "not read again within MY_ID_KEEP s: " .. reads)
clock = clock + services.MY_ID_KEEP
services.my_device_id()
check(reads == 2, "read again after it: " .. reads)
answer = '{"myID":"not-an-id"}'
clock = clock + services.MY_ID_KEEP
check(services.my_device_id() == nil, "no ID in the answer: nil")
check(services.my_device_id() == nil and reads == 4, "and nil isn't kept: asked again at once (" .. reads .. ")")
band.read, band.write_atomic = real_read, real_wa
print("ok perfcut3: polling sub-ticks paced, the link's clock decoded once per estimate, this computer's ID kept")
