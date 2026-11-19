-- 0.59.46 (Round 2 review): the startup block is put on computers that had an older one, says when nothing started, and is the installer's
-- too; the last-good copy is only the running version, whole; band.version_on_disk finds the version; a reload while recording is "busy";
-- every module is preloaded; the kept marks survive a crash; a folder's listing is kept while its time stands. Lupa or Lua 5.4, repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext, projects, playing = 1000, {}, {}, 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  EnumProjects = function(i) return projects[i + 1] end, GetPlayStateEx = function() return playing end, GetResourcePath = function() return "/res" end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log, band.log_file = function() end, function() end

-- band.version_on_disk reads the real copy's version from the start of lib/band.lua (it reads 512 bytes: a longer header hid every update)
assert(band.version_on_disk(".") == band.VERSION, "the version on disk, from the first 512 bytes: " .. tostring(band.version_on_disk(".")))

-- the startup block: the installer writes exactly what lib/tools.lua writes
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return (s:gsub("\r", "")) end
local function body(text, name) return assert(text:match("function " .. name .. "%(dirs%)\n(.-\nend\n)"), name) end
assert(body(read("lib/tools.lua"), "tools%.startup_block") == body(read("installer/studiosync_setup.lua"), "startup_block"),
  "the installer's block is lib/tools.lua's, word for word (two hand copies drifted)")
assert(read("installer/studiosync_setup.lua"):find('local block = startup_block({ sdir, home .. "/last good" })', 1, true), "and the installer uses it")

-- an older block counts as off for a copy, and Autostart writes it again as it is now, its copies in order
local tools = require("tools")
local startup
band.read = function(p) if p:find("__startup.lua", 1, true) then return startup end end
band.write_atomic = function(p, t) if p:find("__startup.lua", 1, true) then startup = t end end
reaper.file_exists = function() return true end
startup = "mine()\n-- BandSync autostart\ndofile([[/s/_tools/studiosync/StudioSync - Autostart.lua]])\n-- /BandSync autostart\nafter()\n"
assert(tools.autostart_on() and not tools.autostart_on("/s/_tools/studiosync"), "a bare dofile: on, but not as it should be for this copy")
assert(tools.upgrade_startup() == true, "rewritten")
assert(startup:find("pcall(dofile, f)", 1, true) and startup:find("[[/s/_tools/studiosync/StudioSync - Autostart.lua]]", 1, true)
  and startup:find("last good/StudioSync - Autostart.lua", 1, true) and startup:find("mine()", 1, true) and startup:find("after()", 1, true),
  "with each copy in a pcall and the last-good copy, its own copy first, the person's lines kept")
assert(tools.autostart_on("/s/_tools/studiosync") and tools.upgrade_startup() == false, "then it's on, and left alone")
startup = "-- BandSync autostart\nfor _, f in ipairs({ [[/s/_tools/studiosync/StudioSync - Autostart.lua]], [[/rp/StudioSync - Autostart.lua]] }) do " ..
  "if reaper.file_exists(f) then dofile(f) break end end\n-- /BandSync autostart\n"
assert(tools.upgrade_startup() and startup:find("[[/rp/StudioSync - Autostart.lua]]", 1, true), "the two-path loop keeps its fallback")
-- nothing started: said in REAPER's console
local said, real_dofile = nil, dofile
reaper.ShowConsoleMsg = function(s) said = s end
dofile = function() error("bad") end
load(tools.startup_block({ "/a", "/b" }), "=block")()
dofile = real_dofile
assert(said and said:find("StudioSync didn't start", 1, true) and said:find("/b/", 1, true), "every copy failed: the last failure is said (nothing was)")

-- the last-good copy: only the version running, and whole
local disk, whole, copied = "9.9", false, {}
band.version_on_disk = function(d) return d:find("last good", 1, true) and "1.0" or disk end
band.from_shared = function() return true end
band.files_complete = function() return whole end
band.copy_atomic = function(_, to) copied[#copied + 1] = to end
band.files = function(d) if d:find("/lib$") then return { "a.lua" } end return { "StudioSync - Autostart.lua" } end
reaper.RecursiveCreateDirectory = function() end
assert(band.save_last_good("/s/_tools/studiosync") == nil and #copied == 0, "not the version running (one still arriving at the minute): not now")
disk = band.VERSION
assert(band.save_last_good("/s/_tools/studiosync") == nil and #copied == 0, "the version running but not all arrived: not now")
whole = true
assert(band.save_last_good("/s/_tools/studiosync") == true and #copied > 0, "the version running, whole: kept")

-- a reload while anything records is "busy", and nothing is marked
projects, playing = { "p" }, 5
local ok, why = band.reload_or_say("/c", "Main.lua", "9.9")
assert(not ok and why == "busy" and ext[band.reload_failed_key("Main.lua")] == nil, "busy: the caller announces nothing and tries later")
assert(band.recording_anywhere() == true)
projects, playing = {}, 0

-- preload: every lib module loaded now
local mods = { "zz_one", "zz_two" }
band.files = function() return { "zz_one.lua", "zz_two.lua" } end
package.preload.zz_one = function() return { one = true } end
package.preload.zz_two = function() error("broken") end
assert(band.preload("/c") == 1 and package.loaded.zz_one and package.loaded.zz_two == nil, "loaded at the start; a broken one is left for its first use")
local _ = mods

-- the kept marks and a guest's list are among what a crash can't lose
ext.bands = "/S/Studio"
assert(table.concat(band.kept_keys(), "|"):find("marks kept /s/studio", 1, true) and table.concat(band.kept_keys(), "|"):find("guest list /S/Studio", 1, true),
  "kept marks and the guest list go into settings.json")

-- a folder's listing is kept while its time stands, read again when it moves
local stat, lists = "2020.01.01 00:00:00", 0
reaper.JS_File_Stat = function() return 0, 0, "", stat end
reaper.EnumerateFiles = function(_, i) if i == -1 then lists = lists + 1 end return nil end
band.raw_listing("/ev")
clock = clock + 1
band.raw_listing("/ev")
assert(lists == 1, "the folder's time hasn't moved: the listing is kept (it was read two to four times a poll)")
stat = "2020.01.01 00:00:09"
clock = clock + 1
band.raw_listing("/ev")
assert(lists == 2, "it moved: read again")

-- the clipboard: said, not shown
local logged
band.log = function(s) logged = s end
reaper.CF_SetClipboard = function() end
band.copy("ntfy-secret-channel")
assert(not logged:find("secret", 1, true), "copied text isn't logged")
print("ok")
