-- Other scripts and extensions beside StudioSync (James, rt: lib/compat.lua). The pure parts: a change after a bandmate's landed, things that
-- keep going out by themselves, what differs between two timeline signatures, who has a port, Scripts/__startup.lua's risky lines and
-- moving StudioSync's start first, the scripts that start with REAPER, what a script's text does, duplicate extensions; then the guards and
-- detectors with a stand-in REAPER (the grid kept this computer's own, a ReaPersona switch put back, Health's rows) and a whole self-check
-- against a temporary resource folder.
package.path = "lib/?.lua;" .. package.path
local SEP = package.config:sub(1, 1)
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_compat_" .. os.time() .. "_" .. math.random(100000, 999999)
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '" 2>nul') or ("rm -rf '" .. T .. "'")) end
local function mkdir(p) os.execute(SEP == "\\" and ('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul') or ("mkdir -p '" .. p .. "'")) end
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end

local clock, gext, top, files = 1000, {}, "", {}
local grid = { 0.25, 0, 0 }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  GetResourcePath = function() return T end,
  Undo_CanUndo2 = function() return top end,
  GetSetProjectGrid = function(_, set, d, sw, amt) if set then grid = { d, sw, amt } end return 0, grid[1], grid[2], grid[3] end,
  file_exists = function(p) return read(p) ~= nil end,
  EnumerateFiles = function(dir, i) local l = files[dir]; return l and i >= 0 and l[i + 1] or nil end,
  EnumerateSubdirectories = function() return nil end,
  EnumProjects = function(i) if i == -1 or i == 0 then return "P1", T .. "/song.rpp" end end,
  ValidatePtr2 = function() return true end,
  APIExists = function() return false end,
  GetProjExtState = function() return 0, "" end,
  GetToggleCommandStateEx = function() return 0 end,
  GetSetProjectInfo = function() return 0 end,
  GetSetProjectInfo_String = function() return false, "" end,
  TrackFX_GetChainVisible = function() return -1 end,
  TrackFX_GetCount = function() return 0 end,
}, { __index = function() return function() end end })
local band = require("band")
local tools = require("tools")
local compat = require("compat")

-- ---- a change right after a bandmate's landed ----
local OURS = compat.OURS
assert(compat.after_land(nil, 10, OURS) == nil, "nothing landed: not that")
assert(compat.after_land({ at = 1, undo = "Move items" }, 10, OURS) == nil, "outside the window")
assert(compat.after_land({ at = 1, undo = "Move items" }, 3, OURS).by == false, "no undo point since StudioSync's own: a script, extension or plug-in")
assert(compat.after_land({ at = 1, undo = "Move items" }, 3, "Move items") == nil, "back to the point before ours: the person undid it")
assert(compat.after_land({ at = 1, undo = "x" }, 3, "StudioSync: put the studio's tempo map and markers back") == nil, "StudioSync's own follow-up")
assert(compat.after_land({ at = 1, undo = "x" }, 3, "Colour tracks") == nil, "StudioSync's own colouring, unprefixed")
assert(compat.after_land({ at = 1, undo = "x" }, 3, "Script: Auto-rename tracks.lua").by == "Script: Auto-rename tracks.lua", "named by REAPER's undo history")

-- ---- by itself, again and again ----
assert(compat.restless({ { top = "a" }, { top = "a" }, { top = "b" }, { top = "b" }, { top = "b" } }) == 3, "sends with no new undo point between")
assert(compat.restless({ { top = "a" } }) == 0 and compat.median({ 5, 1, 9 }) == 5 and compat.median({}) == nil, "one send; the median")

-- ---- two timeline signatures ----
local function sig(tempo, settings, markers)
  return band.json_encode({ tempo or { { bpm = 120, time = 0 } }, markers or {}, { title = "t", settings = settings }, 4 })
end
assert(compat.timeline_diff(sig(nil, { grid = { 0.25, 0, 0 } }), sig({ { bpm = 90, time = 0 } }, { grid = { 0.25, 0, 0 } })) == "timeline", "the tempo map")
assert(compat.timeline_diff(sig(nil, { grid = { 0.25, 0, 0 }, snap = 1 }), sig(nil, { grid = { 0.25, 0, 0 }, snap = 0 })) == "settings", "snap: the settings")
assert(compat.timeline_diff(sig(nil, { grid = { 0.25, 0, 0 } }), sig(nil, { grid = { 0.125, 0, 0 } })) == "grid", "only the grid's value")
assert(compat.timeline_diff(sig(nil, { grid = { 0.25, 0, 0 }, snap = 1 }), sig(nil, { snap = 1 })) == "grid presence", "only whether the grid is in it")
assert(compat.timeline_diff(sig(nil, { snap = 1 }), sig(nil, { snap = 1 })) == nil and compat.timeline_diff("", "x") == nil, "the same; one unreadable")

-- ---- who has the port ----
local ns = "0\n\n  Proto  Local Address          Foreign Address        State           PID\n  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1100\n" ..
  "  TCP    100.64.1.2:47281       0.0.0.0:0              LISTENING       4242\n  TCP    100.64.1.2:47281       100.64.1.9:5000        ESTABLISHED     4242\n"
assert(compat.port_owner(ns, 47281, true) == 4242 and compat.port_owner(ns, 47282, true) == nil, "netstat: the listener's process")
assert(compat.task_name('0\n"reaper.exe","4242","Console","1","500,000 K"\n') == "reaper.exe", "tasklist's name")
local ls = "0\nCOMMAND   PID  USER   FD   TYPE DEVICE SIZE/OFF NODE NAME\nREAPER  777 bo   31u  IPv4 0x1      0t0  TCP 100.64.1.2:47281 (LISTEN)\n"
assert(compat.port_owner(ls, 47281, false) == "REAPER" and compat.port_owner(ls, 4728, false) == nil, "lsof: the program; not a port that's a prefix of it")

-- ---- Scripts/__startup.lua ----
local guard = "-- BandSync render guard (x)\nif os.getenv(\"BANDSYNC_RENDER\") then return end\n-- /BandSync render guard\n"
local risky = compat.startup_risks(guard .. "-- dofile('commented.lua')\nlocal ok = pcall(dofile, x)\ndofile(\"C:/gone/drive.lua\")\nlocal m = require(\"thing\")\nreturn\n")
assert(#risky == 3 and risky[1][1] == 6 and risky[1][2] == 'dofile("C:/gone/drive.lua")' and risky[2][1] == 7 and risky[3][1] == 8, "a bare dofile, a require, a top-level return; not a pcall, a comment or the guard")
-- (the desktop's own file, 0.59.49.63: the agent bridge's block returns inside its functions, which was read as stopping the file)
local bridge = "do\n  local function read_lock()\n    local f = io.open(lockfile, \"r\")\n    if not f then return nil end\n    return { started = started, busy = busy }\n  end\n" ..
  "  local function lock_is_stale(lock, now)\n    return age >= 60\n  end\n  local ok, err = pcall(dofile, bridge_file)\nend\n"
assert(#compat.startup_risks(guard .. bridge) == 0, "a return inside a function never stops the file")
assert(compat.bind_port("100.106.240.32:47290", 47281) == "47290" and compat.bind_port("100.106.240.32", 47281) == "47281" and compat.bind_port(nil) == "47281", "the bind's port, else the link's")
assert(compat.scratch_detect(require("mirror")), "change detection, StudioSync's real hashing, sees the scratch edit (and asks nothing of SWS)")
local block = tools.startup_block({ "C:/S/StudioSync" }):gsub("\n$", "")
local text = guard .. "-- mine\ndofile(\"x.lua\")\n" .. block .. "\n-- after\nreaper.y()\n"
local moved = compat.block_first(text, tools.split_startup)
assert(moved and moved:sub(1, #guard) == guard, "the render guard stays first")
assert(moved:sub(#guard + 1, #guard + #block) == block, "then StudioSync's start")
assert(moved:find("-- mine\ndofile(\"x.lua\")\n-- after\nreaper.y()\n", 1, true) and #moved == #text, "the person's lines after it, every one: " .. moved)
assert(compat.block_first(moved, tools.split_startup) == nil, "first already")
assert(compat.block_first("-- nothing of ours\n", tools.split_startup) == nil, "no block")
assert(#compat.startup_risks(tools.split_startup(moved)) == 0, "nothing above it now")

-- ---- the scripts that start with REAPER ----
local kb = 'SCR 4 0 RSaaa "Custom: Adaptive grid menu.lua" "FTC Tools/Adaptive grid/Adaptive grid menu.lua"\n' ..
  'SCR 4 32060 RS7d3c_aaa "Custom: Adaptive grid menu.lua" "FTC Tools/Adaptive grid/Adaptive grid menu.lua"\n' ..
  'SCR 4 0 RSbbb "Custom: Chordbox.lua" Chordbox.lua\nSCR 4 0 RSccc "Custom: StudioSync - Panel.lua" "StudioSync/StudioSync - Panel.lua"\nSCR 4 0 RSddd "Custom: g.lua" g.lua\n'
local by = compat.kb_paths(kb)
assert(by.aaa == nil and by.RSaaa.path == "FTC Tools/Adaptive grid/Adaptive grid menu.lua" and by.RSaaa.section == "0" and by.RSbbb.path == "Chordbox.lua", "reaper-kb.ini's scripts")
local st = "reaper.Main_OnCommand(reaper.NamedCommandLookup('_RSaaa'), 0)\nlocal c = '_RSbbb'\nlocal s = '_RSccc'\npcall(dofile, [[C:/S/StudioSync/x.lua]])\ndofile(\"D:/own/thing.lua\")\n"
local list = compat.autostarted(st, kb, { "_RSddd" })
assert(#list == 4 and list[1].path:find("Adaptive grid menu") and list[2].name == "Chordbox.lua" and list[3].name == "g.lua" and list[4].path == "D:/own/thing.lua",
  "by command id, SWS's startup action and a dofile; never StudioSync's own")

-- ---- what a script's text does ----
local k = compat.scan_text('reaper.SetExtState("BandSync", "user", "x", true)\nreaper.GetExtState("BandSync", "user")\n')
assert(k.extstate and not k.grid, "writes StudioSync's ExtState")
assert(next(compat.scan_text('local v = reaper.GetExtState("BandSync", "user")\n-- reaper.SetExtState("BandSync", "x", "y")\n')) == nil, "a read or a comment: nothing")
assert(compat.scan_text('reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "", true)\n').pext, "writes StudioSync's ids")
assert(next(compat.scan_text('reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "", false)\n')) == nil, "reads them: nothing")
local loop = 'reaper.GetSetProjectGrid(0, 1, d, s, a)\nreaper.SetCurrentBPM(0, 120, true)\nreaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", c)\n'
assert(next(compat.scan_text(loop)) == nil, "run once by hand: its own business")
k = compat.scan_text(loop .. "reaper.defer(main)\n")
assert(k.grid and k.tempo and k.colour, "in a defer loop: grid, tempo, colours")
assert(compat.scan_text("reaper.GetSetProjectGrid(0, false)\n", true).grid == nil and compat.scan_text("reaper.SetProjectGrid(0, 0.25)\n", true).grid, "reading the grid isn't writing it")

-- ---- two copies of an extension ----
local d = compat.dll_dupes({ "reaper_studiosync-x64.dll", "reaper_studiosync-x64.dll.prev", "reaper_studiosync-x64 (2).dll", "reaper_imgui-x64.dll", "reaper_sws-x64.dll",
  "reaper_csurf_a.dll", "reaper_csurf_b.dll", "reaper_js_ReaScriptAPI64.dll" })
assert(#d == 1 and d[1].family == "reaper_studiosync" and #d[1].files == 2, "only loadable copies, only the extensions StudioSync uses")

-- ---- the grid, this computer's own ----
assert(compat.grid_local() == nil and band.capture_settings("P1").grid ~= nil, "shared as ever")
gext["FTC.AdaptiveGrid\0is_service_running"], gext["FTC.AdaptiveGrid\0main_mult"] = "yes", "2"
assert(compat.grid_local() == "FTC's Adaptive grid" and band.capture_settings("P1").grid == nil, "FTC's Adaptive grid runs: left out")
band.apply_settings("P1", { grid = { 1, 0, 0 } })
assert(grid[1] == 0.25, "and a bandmate's grid isn't put in over it")
gext["FTC.AdaptiveGrid\0main_mult"] = "0"
assert(compat.grid_local() == nil, "adaptive off (a fixed grid): shared again")
band.apply_settings("P1", { grid = { 1, 0, 0 } })
assert(grid[1] == 1, "a bandmate's grid lands again")

-- ---- a bandmate's change, changed again here ----
top = "Move items"
compat.landed("P1", "Taaa")
clock, top = 1002, OURS
compat.sent("P1", "Taaa", "Bass", "track")
assert(compat.events[#compat.events].k == "noundo" and compat.events[#compat.events].name == "Bass", "no undo point: something unnamed")
top = OURS; compat.landed("P1", "Taaa"); clock, top = 1003, "Script: recolour.lua"
compat.sent("P1", "Taaa", "Bass", "track")
assert(compat.events[#compat.events].k == "by" and compat.events[#compat.events].by == "Script: recolour.lua", "named by the undo history")
local n0 = #compat.events
clock, top = 1100, "Script: recolour.lua"
compat.sent("P1", "Taaa", "Bass", "track")
assert(#compat.events == n0, "long after it landed, an ordinary change: nothing")
for i = 1, 5 do clock = 1200 + i; compat.sent("P1", "Fbbb", "Keys plug-ins", "fx", "TR") end
assert(compat.events[#compat.events].k == "restless" and compat.events[#compat.events].name == "Keys plug-ins", "five sends in a minute with no undo point: restless")
n0 = #compat.events
reaper.TrackFX_GetChainVisible = function() return 0 end
for i = 1, 5 do clock = 1250 + i; compat.sent("P1", "Fzzz", "Synth plug-ins", "fx", "TR") end
assert(#compat.events == n0, "its plug-in window open: someone turning its knobs")
reaper.TrackFX_GetChainVisible = function() return -1 end
for i = 1, 5 do clock = 1300 + i; top = "Edit " .. i; compat.sent("P1", "Iccc", "an item", "item") end
assert(#compat.events == n0, "each with its own undo point: someone working")
for i = 1, 5 do clock = 1400 + i; compat.sent("P1", "Iddd", "a print", "item", nil, true) end
assert(#compat.events == n0, "StudioSync's own refreshed prints: never")

-- ---- the timeline's veto ----
clock = 2000
assert(compat.timeline_veto("P1", sig(nil, { grid = { 0.25, 0, 0 }, snap = 1 }), sig(nil, { snap = 1 })) == "quiet", "the grid turned this computer's own: no change")
gext["ReaPersona\0style"] = "pro_tools"
compat.tick("P2", {}, nil, clock, 0) -- (the baseline: Live sync's pass polls ReaPersona's persona)
clock = 2001; gext["ReaPersona\0style"] = "logic"
local v = compat.timeline_veto("P1", sig(nil, { snap = 1 }), sig(nil, { snap = 0 }))
assert(type(v) == "string" and v:find("ReaPersona") and compat.events[#compat.events].k == "persona" and compat.events[#compat.events].by == "logic", "a persona switch: put the studio's back")
clock = 2010
assert(compat.timeline_veto("P1", sig(nil, { snap = 1 }), sig(nil, { snap = 0 })) == nil, "later: your own change, sent as ever")
assert(compat.timeline_veto("P1", sig(nil, { snap = 1 }), sig({ { bpm = 99, time = 0 } }, { snap = 1 })) == nil, "a tempo change is never the persona's")
for i = 1, compat.GRID_N - 1 do clock = 2100 + i; assert(compat.timeline_veto("P1", sig(nil, { grid = { i, 0, 0 } }), sig(nil, { grid = { i + 1, 0, 0 } })) == nil, "a grid change goes out") end
clock = 2110
assert(compat.timeline_veto("P1", sig(nil, { grid = { 7, 0, 0 } }), sig(nil, { grid = { 8, 0, 0 } })) == "quiet", "the fifth grid change in a minute: a script")
assert(compat.grid_local() == "a script that changes the grid as you zoom" and band.capture_settings("P1").grid == nil, "latched for the session")
gext["BandSync\0compat grid local"] = nil

-- ---- Health's rows ----
local chk = { at = os.time(), items = {
  { id = "startup", ok = true, level = "red", text = "fine" },
  { id = "extension", level = "grey", text = "another row says it" },
  { id = "startup order", level = "yellow", text = "line 3", act = "move" },
}, clash = { { name = "Recolour.lua", start = true, kinds = { colour = compat.KINDS.colour } }, { name = "Gridbox.lua", start = true, kinds = { grid = compat.KINDS.grid } } } }
local moved_called = false
local rows = compat.rows_from(chk, nil, "Gridbox.lua", os.time(), { move = function() moved_called = true end, check = function() end })
local byid = {}
for _, r in ipairs(rows) do byid[r[1]] = r end
assert(byid["compat startup order"] and byid["compat startup order"][2] == false and byid["compat startup order"].action, "a failing check: its own row, with its button")
byid["compat startup order"].action[2]()
assert(moved_called and byid["compat extension"] == nil and byid["compat startup"] == nil, "grey: another row says it; a passing one: in the summary")
assert(byid["compat script Recolour.lua"][2] == false and byid["compat script Recolour.lua"][5]:find("recolours tracks"), "a script that clashes")
assert(byid["compat script Gridbox.lua"][2] == true, "a grid script while the grid is this computer's own: handled")
assert(byid["compat"][2] == false and byid["compat"].action[1] == "Check again", "the summary: a look needed, Check again")
assert(byid["compat grid"][2] == true and byid["compat grid"][4]:find("Gridbox"), "the grid row says why")
local ev = {}
for i = 1, 3 do ev[#ev + 1] = { t = os.time(), k = "by", by = "Script: x", name = "Bass" } end
ev[#ev + 1] = { t = os.time(), k = "noundo", name = "Drums" }
ev[#ev + 1] = { t = os.time(), k = "restless", name = "Keys plug-ins" }
ev[#ev + 1] = { t = os.time(), k = "persona", by = "logic" }
rows = compat.rows_from({ at = os.time(), items = { { id = "x", ok = true } }, clash = {} }, { med = 400, events = ev }, nil, os.time(), { check = function() end })
byid = {}
for _, r in ipairs(rows) do byid[r[1]] = r end
assert(byid["compat"][2] == true and byid["compat"].ok_action, "all fine: green, Check again on it")
assert(byid["compat by Script: x"] and byid["compat by Script: x"][5]:find("3 times"), "a named action three times")
assert(byid["compat noundo"] == nil, "something unnamed once: not yet")
assert(byid["compat restless Keys plug-ins"] and byid["compat persona"][5]:find("to logic"), "restless; the persona")
assert(byid["compat loop"] and byid["compat loop"][5]:find("400 ms"), "Live sync held")

-- ---- a whole self-check, against a temporary resource folder ----
clean(); mkdir(T .. "/Scripts"); mkdir(T .. "/UserPlugins"); mkdir(T .. "/StudioSync")
write(T .. "/Scripts/__startup.lua", 'dofile("D:/gone/thing.lua")\nreaper.Main_OnCommand(reaper.NamedCommandLookup("_RSeee"), 0)\n')
write(T .. "/Scripts/bad.lua", 'local function f()\n  reaper.SetExtState("BandSync", "user", "me", true)\n  reaper.defer(f)\nend\nf()\n')
write(T .. "/Scripts/handy.lua", 'reaper.SetProjExtState(0, "BandSync", "song", "")\n')
write(T .. "/reaper-kb.ini", 'SCR 4 0 RSeee "Custom: bad.lua" bad.lua\nSCR 4 0 RSfff "Custom: handy.lua" handy.lua\n')
files[T .. "/UserPlugins"] = { "reaper_studiosync-x64.dll", "reaper_studiosync-x64 (2).dll" }
package.loaded.direct = { ext_problem = function() return nil end, available = function() return true end, port = function() return 47281 end,
  status = function() return { listening = false, error = "can't listen on 100.64.1.2:47281 (another REAPER, or something else, has the port)" } end }
reaper.ExecProcess = function(cmd) if cmd:find("netstat", 1, true) then return ns end return '0\n"reaper.exe","4242"\n' end
reaper.SNM_GetIntConfigVar = function() return 1 end
reaper.BR_Win32_WritePrivateProfileString = function() return true end
local co = coroutine.create(function() return compat.run_check("P1", { root = T }, nil, T .. "/StudioSync", false) end)
local okc, res = coroutine.resume(co)
assert(okc and type(res) == "table", tostring(res))
local it = {}
for _, x in ipairs(res.items) do it[x.id] = x end
assert(it.startup.ok and tools.autostart_on(), "StudioSync's start was missing: put back")
assert(it["startup order"] and not it["startup order"].ok and it["startup order"].text:find("Line 1"), "the bare dofile above it is said")
assert(it["dll reaper_studiosync"] and it["dll reaper_studiosync"].level == "red", "two StudioSync extensions")
assert(it.port and not it.port.ok and it.port.text:find("reaper.exe") and it.port.text:find("Another REAPER"), "port 47281 taken by another REAPER")
assert(it.promptendrec and not it.promptendrec.ok, "REAPER's box after each recording pauses StudioSync: said")
assert(it.extstate.ok and it.detect.ok and it.extension.ok,"ExtState reads back, change detection sees the scratch edit, the extension is the one")
assert(#res.clash == 1 and res.clash[1].name == "bad.lua" and res.clash[1].kinds.extstate and res.clash[1].start, "the startup script writing StudioSync's ExtState")
assert(gext["BandSync\0compat check"] and gext["BandSync\0compat probe"] == nil, "published; the probe gone")
-- on demand: every script in the Actions list too
co = coroutine.create(function() return compat.run_check("P1", { root = T }, nil, T .. "/StudioSync", true) end)
okc, res = coroutine.resume(co)
assert(okc and #res.clash == 2 and res.clash[2].name == "handy.lua" and not res.clash[2].start and res.full, "a script run by hand writing it too")
-- the desktop's extension (0.59.49.63) gives its bind as the address alone: the port is the link's, and the check goes on
package.loaded.direct.status = function() return { listening = true, bind = "100.106.240.32" } end
co = coroutine.create(function() return compat.run_check("P1", { root = T }, nil, T .. "/StudioSync", false) end)
okc, res = coroutine.resume(co)
it = {}
for _, x in ipairs(res.items) do it[x.id] = x end
assert(okc and it.port and it.port.ok and it.port.text == "Port 47281 is StudioSync's (100.106.240.32)", okc and tostring(it.port and it.port.text) or tostring(res))
-- one check that raises is a grey item and a log line; the rest still run, and grey isn't "needs a look"
package.loaded.direct.status = function() error("an odd answer from the extension") end
co = coroutine.create(function() return compat.run_check("P1", { root = T }, nil, T .. "/StudioSync", false) end)
okc, res = coroutine.resume(co)
it = {}
for _, x in ipairs(res.items) do it[x.id] = x end
assert(okc and it.port and it.port.level == "grey" and it.port.text:find("odd answer") and it.extstate.ok and it.detect.ok and #res.clash == 1, "the port check failed alone")
local summary
for _, r in ipairs(compat.rows_from(res, nil, nil, os.time(), {})) do if r[1] == "compat" then summary = r end end
assert(summary and not summary[5]:find("odd answer") and not (function() for _, r in ipairs(compat.rows_from(res, nil, nil, os.time(), {})) do if r[1] == "compat port" then return true end end end)(), "no row of its own for a check that couldn't run")
-- Move StudioSync's start to the top
local before_len = #read(T .. "/Scripts/__startup.lua")
assert(compat.move_block_first() == true, "moved")
local after_text = read(T .. "/Scripts/__startup.lua")
assert(after_text:find("^%-%- BandSync autostart") and after_text:find('dofile("D:/gone/thing.lua")', 1, true) and #after_text >= before_len, "first, the person's lines kept")
assert(#compat.startup_risks(tools.split_startup(after_text)) == 0, "nothing above it")
-- REAPER's "open projects on startup", held while a plan is kept
local startup = require("startup")
assert(startup.keep_open_mode() == nil, "no plan: nothing to hold")
band.write_json(band.home() .. "/reopen.json", { tabs = {}, loadlastproj = 1 })
local set = {}
reaper.SNM_SetIntConfigVar = function(k, v) set[k] = v end
assert(startup.keep_open_mode() == 1 and set.loadlastproj == 2, "something set it back: held again")
assert(band.read_json(band.home() .. "/reopen.json").loadlastproj == 1, "their choice kept for after")
clean()
print("ok")
