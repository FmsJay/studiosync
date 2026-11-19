-- Run inside REAPER (ReaScript), with Live sync running in one or more StudioSync tabs. How long Live sync's tick and pass take, before and
-- after an efficiency pass (James, rt; docs/realtime-roadmap.md "Efficiency pass"), on each computer.
--   1st run: switches Live sync's timings on (ExtState "perf stats", not saved: off again when REAPER restarts) and says to wait.
--   Then leave REAPER as you want it measured (idle with the others here, playing, recording, the Health tab open...) for 20 s or more and run
--   it again: every Live sync publishes its last 10 s each 10 s ("tick stats <tab>"), and this reports each tab's median, p95 and slowest
--   tick (the whole tick, every ~30 ms) and pass (the 0.5-2 s look-and-receive inside it), with the slowest tick's laps.
--   It also times a few things on the tab in front right here (mirror.root, Health's track-group look, the direct link's status), which
--   don't need Live sync.
-- Set OFF = true to switch the timings off again. Reads and times only: nothing in any project changes.
local OFF = false
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
local band = require("band")
local SEC, out = band.SECTION, {}
local function say(s) out[#out + 1] = s end

if OFF then reaper.DeleteExtState(SEC, "perf stats", false); return "perf stats off" end
if reaper.GetExtState(SEC, "perf stats") ~= "1" then
  reaper.SetExtState(SEC, "perf stats", "1", false)
  return "perf stats switched on: Live sync starts collecting within 10 s. Leave REAPER as you want it measured for 20 s or more, then run this again."
end

-- ---- what Live sync published ----
local function line(name, s)
  if type(s) ~= "table" then return string.format("  %-6s none yet", name) end
  return string.format("  %-6s n %4d   median %6.1f ms   p95 %6.1f ms   slowest %7.1f ms", name, s.n or 0, s.med or 0, s.p95 or 0, s.max or 0)
end
local tabs = 0
for i = 0, 512 do
  local p = reaper.EnumProjects(i)
  if not p then break end
  local raw = reaper.GetExtState(SEC, "tick stats " .. tostring(p))
  local st = raw ~= "" and band.json_decode(raw)
  if type(st) == "table" then
    tabs = tabs + 1
    say(string.format("%s / %s (tab %d, %d s ago):", tostring(st.song), tostring(st.room), i + 1, os.time() - (tonumber(st.at) or 0)))
    say(line("tick", st.ticks))
    say(line("pass", st.passes))
    if (st.worst or "") ~= "" then say("  slowest tick's laps (ms): " .. st.worst) end
  end
end
if tabs == 0 then say("No Live sync has published yet: is it running in a tab? (each publishes every 10 s once \"perf stats\" is on)") end

-- ---- timed here, on the tab in front ----
local proj = reaper.EnumProjects(-1)
local function time(n, fn)
  local t0 = reaper.time_precise()
  for _ = 1, n do fn() end
  return (reaper.time_precise() - t0) / n * 1000
end
say("")
say(string.format("Here, on the tab in front (%d tracks, %d items):", reaper.CountTracks(proj), reaper.CountMediaItems(proj)))
local ok, e = pcall(function()
  local mirror = require("mirror")
  say(string.format("  mirror.root (Live sync's status and heal: once a pass now, was twice)   %.2f ms", time(20, function() mirror.root(proj) end)))
end)
if not ok then say("  mirror.root: " .. tostring(e)) end
ok, e = pcall(function()
  local presence = require("presence")
  say(string.format("  presence.track_groups (Health's rows: once a second now, was each frame)   %.2f ms", time(20, function() presence.track_groups(proj) end)))
end)
if not ok then say("  presence.track_groups: " .. tostring(e)) end
ok, e = pcall(function()
  local direct = require("direct")
  if not reaper.StudioSync_DirectStatus then return say("  direct link: the extension isn't here") end
  local raw = reaper.StudioSync_DirectStatus()
  say(string.format("  the direct link's status JSON (%d bytes): decoding it %.3f ms", #raw, time(200, function() band.json_decode(raw) end)))
  local cfg = band.settings()
  if cfg then say(string.format("  direct.status (decoded once while it's unchanged now)   %.3f ms", time(200, function() direct.status(cfg) end))) end
end)
if not ok then say("  direct link: " .. tostring(e)) end
say("")
say("(perf stats stay on until REAPER restarts; set OFF = true at the top to switch them off)")
return table.concat(out, "\n")
