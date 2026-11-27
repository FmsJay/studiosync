-- rt-setup (findings 2026-11-27 item 14: "Avoid crashes when loading a project, especially big ones where someone clicks around early").
-- lib/loadguard.lua on tools/bigproject.lua's big project (150 tracks, 4,000 items) served by tests/fixtures/bigreaper.lua: nothing while REAPER
-- loads or saves a project (GetCurrentProjectInLoadSave), the first look only once the tab has loaded and gone quiet (tracks still arriving,
-- someone clicking, the mouse held all hold it, up to MAX s), a load or another file opened into the tab under a running Live sync starts it
-- over (loadguard.reloaded). Then the wiring: Live sync's tick asks first and sets band audio's tempo following only once loaded; Autostart does
-- nothing while REAPER is busy and leaves a new tab alone for a look; REAPER's start opens the tabs only when it isn't busy and preloads the
-- front one only; no modal "Build any missing peaks" left (lib/peaks.lua does it a step a tick).
package.path = "tools/?.lua;lib/?.lua;tests/fixtures/?.lua;" .. package.path
local G = require("bigproject")
local m = G.model()
local F = require("bigreaper").new(m)
reaper = F.reaper
local loading_proj, name, mouse = F.proj, "Big", 0 -- (REAPER is loading this project; the tab's file name; the mouse button)
local arrived = 0 -- (tracks REAPER has made so far while it loads)
rawset(reaper, "GetCurrentProjectInLoadSave", function() return loading_proj end)
rawset(reaper, "GetProjectName", function() return name end)
rawset(reaper, "JS_Mouse_GetState", function() return mouse end)
local count = reaper.CountTracks
rawset(reaper, "CountTracks", function(p) return loading_proj and arrived or count(p) end)
local guard = require("loadguard")
local P = F.proj
local function at(t) F.clock = 1000 + t end
at(0)
local st, settled = guard.new(reaper.time_precise()), {}
local function tick() return guard.hold(st, P, function(n) settled[#settled + 1] = n end) end

-- REAPER loading the big project, tracks arriving: never looked at, however long it takes
for i = 1, 60 do at(i * 0.05); arrived = math.min(#m.tracks, i * 3); assert(tick(), "held while REAPER loads (tick " .. i .. ")") end
loading_proj = nil
-- loaded at 3 s: still held until it has been still for QUIET s after SETTLE s
at(3.0); assert(tick(), "held the moment loading ends")
at(3.5); F.cc = F.cc + 1; assert(tick(), "someone clicked early: an edit")
at(4.2); assert(tick(), "still within QUIET of the click")
at(4.6); mouse = 1; assert(tick(), "the mouse is held: not now")
at(4.7); mouse = 0
assert(#settled == 0, "nothing ran on the half-loaded project")
at(4.8); assert(not tick(), "loaded and quiet: the first look may go")
assert(#settled == 1 and settled[1] == 1 and not guard.reloaded(P), "settled once, the first time")
for i = 1, 20 do at(5 + i * 0.03); F.cc = F.cc + 1; assert(not tick(), "once loaded, edits don't hold it") end
assert(#settled == 1, "and it doesn't settle again")
-- a save (or another project loading) while Live sync runs: held through it, and over again after
at(6); loading_proj = P; assert(tick(), "held while saving or loading")
at(6.5); loading_proj = nil; assert(tick(), "held right after")
at(8.1); assert(not tick() and #settled == 2 and settled[2] == 2 and guard.reloaded(P), "settled again: reloaded says something loaded into the tab")
-- another file opened into the same tab (REAPER keeps the tab's pointer)
at(9); name = "Other"; assert(tick(), "a new file in the tab: held")
at(9.05); assert(tick(), "held while it settles")
at(10.6); assert(not tick() and #settled == 3, "and looked at once it has loaded")
-- someone clicking all the time doesn't hold it for ever
at(11); local st2 = guard.new(reaper.time_precise())
local held_for = 0
for i = 1, 400 do
  at(11 + i * 0.1); F.cc = F.cc + 1
  if not guard.hold(st2, P) then break end
  held_for = i * 0.1
end
assert(held_for >= guard.MAX - 0.2 and held_for <= guard.MAX + 0.2, "MAX s at most, clicking or not (" .. held_for .. ")")
-- what it asks REAPER once settled: only whether it's busy and the tab's name (two cheap calls a tick)
F.reset_counts()
for i = 1, 30 do at(60 + i * 0.03); guard.hold(st2, P) end
assert((F.calls.GetProjectStateChangeCount or 0) == 0, "no change count asked once settled")
-- no GetCurrentProjectInLoadSave (an older REAPER): never busy
rawset(reaper, "GetCurrentProjectInLoadSave", nil)
assert(guard.busy() == false, "an older REAPER: never busy")

-- ---- the wiring --------------------------------------------------------------------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb"), p); local d = f:read("a"); f:close(); return (d:gsub("\r\n", "\n")) end
local live, auto, start, sync = read("StudioSync - Live sync.lua"), read("StudioSync - Autostart.lua"), read("lib/startup.lua"), read("lib/sync.lua")
assert(live:find("tick = function()\n  if loading() then return reaper.defer(tick) end", 1, true), "Live sync's tick asks the guard before anything else")
assert(live:find("guard.hold(guard_st, proj, function(n)", 1, true) and live:find('band.try("sync.audio_follow_tempo", sync.audio_follow_tempo, proj)', 1, true),
  "band audio follows tempo once the tab has loaded")
assert(not live:find("\nsync.audio_follow_tempo(proj)", 1, true), "not on the half-loaded project as Live sync starts")
assert(auto:find('if require("loadguard").busy() then return end', 1, true), "Autostart does nothing while REAPER loads or saves")
assert(auto:find("band.binding(proj) and tab_settled(key, fn) then", 1, true), "a new tab is left alone for a look (live audio off, Live sync)")
assert(start:find('if require("loadguard").busy() then return reaper.defer(function() startup.on_start(by_hand_over) end) end', 1, true),
  "REAPER's start opens the tabs only when it isn't loading one itself")
assert(not live:find("Main_OnCommand(40047", 1, true) and not sync:find("Main_OnCommand(40047", 1, true), "no modal peak build left in Live sync or sync")

-- REAPER's start preloads only the tab in front: three band tabs reopened, one preload
local startup_preloads = {}
package.loaded.sync = { preload = function(p) startup_preloads[#startup_preloads + 1] = p end }
local band = require("band")
local plan = { loadlastproj = 1, tabs = { { path = "C:/s/A.rpp", band = true }, { path = "C:/s/B.rpp", band = true, front = true }, { path = "C:/s/C.rpp", band = true } } }
local tabs, front = { { p = { 1 }, fn = "" } }, 1
band.read_json = function(p) return p:find("reopen.json", 1, true) and plan or nil end
band.write_atomic, band.read, band.log = function() end, function() return nil end, function() end
band.binding = function(p) for _, t in ipairs(tabs) do if t.p == p and t.fn ~= "" then return { song = t.fn, room = "main", role = "guest" } end end end
band.settings = function() return { root = "C:/s", user = "James" } end
band.for_tab = function(c) return c end
local R = setmetatable({
  SNM_GetIntConfigVar = function() return 1 end, SNM_SetIntConfigVar = function() end, BR_Win32_WritePrivateProfileString = function() end,
  get_ini_file = function() return "x.ini" end, GetResourcePath = function() return "C:/R" end, GetExtState = function() return "" end, GetOS = function() return "Win64" end, file_exists = function() return true end, ExecProcess = function() end,
  EnumProjects = function(i) local t = tabs[i == -1 and front or i + 1]; if t then return t.p, t.fn end end,
  CountTracks = function() return 0 end, Main_OnCommand = function(id) if id == 40859 then tabs[#tabs + 1] = { p = { #tabs + 1 }, fn = "" }; front = #tabs end end,
  Main_openProject = function(path) tabs[front].fn = path end, SelectProjectInstance = function() end, time_precise = function() return 0 end,
}, { __index = function() return function() end end })
reaper = R
package.loaded.startup, package.loaded.loadguard = nil, nil
require("startup").on_start()
assert(#tabs == 3 and #startup_preloads == 1 and band.binding(startup_preloads[1]).song == "C:/s/B.rpp", "three tabs open, only the front one preloaded")
print("ok")
