-- 0.59.49 (Round 4 review), install side: no hand-off inside a reload; the startup block with no end line is left alone, and a blank line
-- after it is kept on LF files; the installer's own placement (its copies of split_startup and place_block) run, not searched for; a failed
-- folder add says Syncthing's reason under "still starting"; a new studio whose add timed out keeps its folder and id for the next press;
-- band.live_here takes its window. Lupa or Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end, GetOS = function() return "Win64" end, GetResourcePath = function() return "/res" end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  EnumerateFiles = function() return nil end, EnumerateSubdirectories = function() return nil end,
}, { __index = function() return function() return "" end end })
local band = require("band")
local logged = {}
band.log, band.log_file = function(s) logged[#logged + 1] = s end, function() end
local function read_src(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return (s:gsub("\r", "")) end

-- install 1: inside band.reload (the approval global set, false or a version) a script doesn't hand off to the copy it moved to
local ff = require("fromfolder")
local started = 0
ext["run from"] = "/st/_tools/studiosync"
reaper.file_exists = function(p) return not p:find("%.git") end
reaper.AddRemoveReaScript = function() return 7 end
reaper.Main_OnCommand = function() started = started + 1 end
local SRC = "@/rp/StudioSync - Panel.lua"
_G.STUDIOSYNC_RELOAD_APPROVED = false
assert(ff.handoff(SRC) == false and started == 0, "a reload's new chunk doesn't hand off (the old loop stopped mid-session and its exit steps ran)")
_G.STUDIOSYNC_RELOAD_APPROVED = "1.2.3"
assert(ff.handoff(SRC) == false and started == 0, "nor with a version approved")
_G.STUDIOSYNC_RELOAD_APPROVED = nil
assert(ff.handoff(SRC) == true and started == 1, "a fresh start of an old copy's action still hands off")
ext["run from"] = nil

-- xplat 2 and 3: tools' placement; a start line with no end line leaves the file alone; LF files keep the blank line after the block
local tools = require("tools")
local startup
local real_read, real_write = band.read, band.write_atomic
band.read = function(p) if p:find("__startup.lua", 1, true) then return startup end return real_read(p) end
band.write_atomic = function(p, t) if p:find("__startup.lua", 1, true) then startup = t end end
startup = "mine()\n-- BandSync autostart\ndofile([[/s/StudioSync - Autostart.lua]])\n\nafter()\n" -- (cut off: no end line)
local was = startup
local ok, why = tools.set_autostart(true, "/rp")
assert(ok == false and startup == was and tostring(why):find("no end line", 1, true), "no end line: left alone (everything after it, after() too, was dropped)")
assert(#logged == 1 and tools.set_autostart(false) == false and #logged == 1, "said once in the log, and off leaves it alone too")
startup = "mine()\n-- BandSync autostart\nold()\n-- /BandSync autostart\n\n\nafter()\n"
assert(tools.set_autostart(true, "/rp") and startup:find("-- /BandSync autostart\n\n\nafter()", 1, true), "LF: both blank lines kept (one went at each rewrite)")
assert(tools.set_autostart(true, "/rp2") and startup:find("-- /BandSync autostart\n\n\nafter()", 1, true), "and again")
startup = "mine()\r\n-- BandSync autostart\r\nold()\r\n-- /BandSync autostart\r\n\r\nafter()\r\n"
assert(tools.set_autostart(true, "/rp") and startup:find("-- /BandSync autostart\n\r\nafter()", 1, true), "CRLF: the block's own line break replaced, the blank line kept")
assert(tools.set_autostart(false) and startup == "mine()\r\n\r\nafter()\r\n", "off: the block and its line break go, the rest stays as it was: " .. startup)
band.read, band.write_atomic = real_read, real_write

-- code 1/5: the installer's copies are lib/tools.lua's word for word, and run here as the installer has them
local inst, tsrc = read_src("installer/studiosync_setup.lua"), read_src("lib/tools.lua")
local function body(text, name) return assert(text:match("function " .. name .. "(%([^)]*%)\n.-\nend\n)"), name) end
local MARKS = 'local MARK_A, MARK_Z = "-- BandSync autostart", "-- /BandSync autostart"\n'
local split = assert(load(MARKS .. "return function" .. body(inst, "split_startup"), "=installer split_startup"))()
local place = assert(load("return function" .. body(inst, "place_block"), "=installer place_block"))()
assert(body(inst, "split_startup") == body(tsrc, "tools%.split_startup") and body(inst, "place_block") == body(tsrc, "tools%.place_block"),
  "the installer's placement is lib/tools.lua's, word for word")
assert(inst:find("before, after = split_startup(cur)", 1, true) and inst:find("wf:write(place_block(before, after, block))", 1, true), "and the installer uses them")
local B = "-- BandSync autostart\nnew()\n-- /BandSync autostart\n"
local function installed(text) local b, a = split(text); return b and place(b, a, B) end
assert(installed("one()\n-- BandSync autostart\nold()\n-- /BandSync autostart\n\ntwo()\n") == "one()\n" .. B .. "\ntwo()\n", "in place, the blank line after it kept")
assert(installed("one()") == "one()\n" .. B, "no block: appended")
assert(installed("one()\n-- BandSync autostart\nold()\ntwo()\n") == nil, "no end line: left alone (it appended a second block after the broken one)")

-- xplat 7 / install 5: "still starting" carries Syncthing's own words; a timed-out add keeps its folder and id for the next press
local services = require("services")
services.my_device_id = function() return nil end
local said = services.add_failed("1\nerror: open config: permission denied\n")
assert(said:find(services.STILL_STARTING, 1, true) == 1 and said:find("permission denied", 1, true), "Syncthing's reason shown under still starting: " .. said)
assert(services.add_failed("") == services.STILL_STARTING, "no words: just still starting")
services.syncthing_path = function() return "st" end
band.bands = function() return {} end
band.write_json = function() end
local calls, answer = {}, {}
reaper.ExecProcess = function(cmd) calls[#calls + 1] = cmd; for k, v in pairs(answer) do if cmd:find(k, 1, true) then return v end end return "0\n" end
local subdirs = {}
reaper.EnumerateSubdirectories = function(_, i) return subdirs[i + 1] end
local function rmdirs() local n = 0; for _, c in ipairs(calls) do if c:find("rmdir", 1, true) then n = n + 1 end end return n end
local cfg = { root = "/music/StudioSync Home", user = "Olive" }
local PEND = "new studio /music/studiosync demo"
answer = { ["folders add"] = "259\n" } -- (no answer in time)
assert(services.new_band(cfg, "Demo") == nil and rmdirs() == 0 and ext[PEND], "timed out: the folder stays (Syncthing may still add it), its id kept")
local id = ext[PEND]
subdirs = { ".stfolder" } -- (Syncthing did add it, a moment later)
clock = clock + 61
answer = { ["folders add"] = "1\nfolder already exists\n", ["label get"] = "0\nStudioSync Demo\n" }
local root = services.new_band(cfg, "Demo")
assert(root == "/music/StudioSync Demo" and ext[PEND] == nil and rmdirs() == 0, "the next press takes it up, by the same id (it made a second folder)")
local adds = {}
for _, c in ipairs(calls) do local i = c:match("folders add %-%-id (%S+)"); if i then adds[#adds + 1] = i end end
assert(#adds == 2 and adds[1] == id and adds[2] == id, "the same id both times: " .. table.concat(adds, ", "))
subdirs, calls = {}, {}
answer = { ["folders add"] = "1\nbad path\n" }
assert(services.new_band(cfg, "Other") == nil and rmdirs() == 1 and ext["new studio /music/studiosync other"] == nil, "Syncthing said no: the empty folder goes, as before")

-- code 3: band.live_here takes its window
local proj = "P1"
ext["live P1"] = tostring(clock - 10)
assert(not band.live_here(proj) and band.live_here(proj, 30) and band.live_here(proj, 11) and not band.live_here(proj, 10), "5 s by default, or the window given")
print("ok")
