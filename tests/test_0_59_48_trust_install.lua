-- 0.59.48 (Round 3 review), install side: a new band.lua beside the old file list isn't whole; the startup block is replaced where it is;
-- a computer moved back to its last-good copy moves on once the copy it ran from before is updated; Delete my copy reads only this studio's
-- project key; an odd folder time doesn't raise; Syncthing still starting is said; a missing Syncthing is looked for every 5 s at most;
-- Autostart's startup-block upgrade and last-good retry. Lupa or Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end, GetOS = function() return "Win64" end, GetResourcePath = function() return "/res" end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  EnumerateFiles = function() return nil end, EnumerateSubdirectories = function() return nil end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log, band.log_file = function() end, function() end
local real = { read = band.read, size = band.size, version_on_disk = band.version_on_disk, write_atomic = band.write_atomic }
local function read_src(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return (s:gsub("\r", "")) end

-- M9: a new band.lua landing beside the old lib/files.txt isn't whole, in a script that had seen the old version whole
local disk = { ["/c/lib/band.lua"] = 'local band = { VERSION = "1.0" }' }
disk["/c/lib/files.txt"] = "version 1.0\nlib/band.lua\t" .. #disk["/c/lib/band.lua"] .. "\n"
band.read = function(p) return disk[p] end
band.size = function(p) return disk[p] and #disk[p] or nil end
band.version_on_disk = function(d) return (disk[d .. "/lib/band.lua"] or ""):match('VERSION = "([^"]+)"') end
assert(band.files_complete("/c", true), "1.0, whole")
disk["/c/lib/band.lua"] = 'local band = { VERSION = "1.1" }' -- (the same length: only the version line changed, as 0.59.43's did)
clock = clock + 5
assert(not band.files_complete("/c"), "a 1.1 band.lua beside the 1.0 list: not whole (it read as whole, and the reload ran the mix)")
band.read, band.size, band.version_on_disk = real.read, real.size, real.version_on_disk

-- M10: the startup block is replaced where it is, the lines around it kept in order; appended only when there's none
local tools = require("tools")
local startup
band.read = function(p) if p:find("__startup.lua", 1, true) then return startup end return real.read(p) end
band.write_atomic = function(p, t) if p:find("__startup.lua", 1, true) then startup = t end end
reaper.file_exists = function() return true end
startup = "-- user stuff\r\nchordbox()\r\n-- BandSync autostart\r\ndofile([[/s/_tools/studiosync/StudioSync - Autostart.lua]])\r\n-- /BandSync autostart\r\nadaptive()\r\n"
assert(tools.upgrade_startup() == true, "the old block rewritten")
local a, m, z = startup:find("chordbox()", 1, true), startup:find("-- BandSync autostart", 1, true), startup:find("adaptive()", 1, true)
assert(a and m and z and a < m and m < z, "in place, between the lines it sat between (it went to the end, behind anything that could raise)")
assert(startup:find("-- /BandSync autostart\nadaptive()", 1, true) and select(2, startup:gsub("BandSync autostart", "")) == 2, "one block, no blank line left behind")
assert(load(startup:gsub("chordbox%(%)", ""):gsub("adaptive%(%)", ""), "=startup"), "and it still compiles")
startup = "mine()\n"
assert(tools.set_autostart(true, "/rp") and startup:find("^mine%(%)\n%-%- BandSync autostart"), "no block yet: appended")
assert(tools.set_autostart(false) and not startup:find("BandSync", 1, true) and startup:find("mine()", 1, true), "off: the block goes, the rest stays")
local inst = read_src("installer/studiosync_setup.lua")
assert(inst:find("cur .. block .. after", 1, true), "the installer replaces it in place too")
band.read, band.write_atomic = real.read, real.write_atomic

-- M12: moved back to the last-good copy, it moves on to the copy it ran from before once that's at least as new
package.loaded.fromfolder = nil
reaper.file_exists = function(p) return not p:find("%.git") end -- (no copy is a developer's checkout)
local lg = band.last_good_dir()
local versions = { [lg] = band.VERSION, ["/rp"] = "0.50.0" }
local saved_bands, saved_vod, saved_fc, saved_sa = band.bands, band.version_on_disk, band.files_complete, band.sync_actions
band.bands = function() return { { root = "/st", name = "St" } } end
band.version_on_disk = function(d) return versions[d] end
band.files_complete, band.sync_actions = function() return true end, function() end
local moved = {}
package.loaded.services = { my_device_id = function() return "MEMBER1-ZZZZ" end }
package.loaded.groups = { trusted = function() return {} end }
package.loaded.access = { mine = function() return nil end }
package.loaded.removal = { am_guest = function() return false end }
package.loaded.tools = { set_autostart = function(_, d) moved[#moved + 1] = d; return true end }
local ff = require("fromfolder")
ext["run from"], ext["run from before"] = "/st/_tools/studiosync", "/rp"
clock = clock + 61; ff.tick("/st/_tools/studiosync"); clock = clock + 61; ff.tick("/st/_tools/studiosync")
assert(moved[1] == lg and ext["run from before"] == "/rp", "the copy it ran from is older: to the last-good copy, and the one before is remembered (it was deleted)")
for _ = 1, 3 do clock = clock + 61; ff.tick(lg) end
assert(#moved == 1, "still older: it waits on the last-good copy, no move")
versions["/rp"] = band.VERSION
clock = clock + 61; ff.tick(lg); clock = clock + 61; ff.tick(lg)
assert(moved[2] == "/rp" and ext["run from"] == "/rp" and ext["run from before"] == nil, "updated through ReaPack: on to it (it stayed on the last-good copy for good)")
band.bands, band.version_on_disk, band.files_complete, band.sync_actions = saved_bands, saved_vod, saved_fc, saved_sa
for _, k in ipairs({ "services", "groups", "access", "removal", "tools", "fromfolder" }) do package.loaded[k] = nil end

-- data L1: Delete my copy reads only this studio's project key, and forgets the song-name-only one only when it's this studio's
local R = "/st2"
band.info = function() return { id = "studio-2", name = "St2" } end
ext["project file Demo"] = "/home/StudioSync/Demo/Demo.rpp" -- (another studio's, from before keys were per studio)
assert(band.project_file(R, "Demo", true) == "" and band.project_file(R, "Demo") == "/home/StudioSync/Demo/Demo.rpp", "scoped: not the other studio's file")
band.forget_project_file(R, "Demo")
assert(ext["project file Demo"] ~= nil, "and that one's key isn't forgotten")
assert(read_src("lib/localcopy.lua"):find("band.project_file(j.root, song, true)", 1, true), "Delete my copy asks for this studio's key only")

-- xplat3: a folder time os.time can't represent doesn't raise inside a listing
reaper.JS_File_Stat = function() return 0, 0, "", "1601.01.01 00:00:00" end
assert(pcall(band.raw_listing, "/ev"), "a zeroed folder time: no error")
reaper.JS_File_Stat = nil

-- services: Syncthing still starting is said; a missing Syncthing is looked for at most every 5 s
local services = require("services")
services.my_device_id = function() return nil end
assert(services.add_failed("1\ndial tcp 127.0.0.1:8384: connect refused") == services.STILL_STARTING, "no answer yet: still starting, not the raw error")
services.my_device_id = function() return "ID" end
assert(services.add_failed("1\nfolder exists"):find("didn't add the studio's folder: folder exists", 1, true), "an answer: Syncthing's own reason")
local finds = 0
services.find_syncthing = function() finds = finds + 1; return nil end
services.syncthing_path(); clock = clock + 1; services.syncthing_path()
assert(finds == 1, "missing: not looked for again within 5 s (the lobby asked every frame)")
clock = clock + 5; services.syncthing_path()
assert(finds == 2, "and again after")

-- Autostart: the startup block upgraded at every load of the script, a reload too (not only at REAPER's start); a failed last-good copy retried
local auto = read_src("StudioSync - Autostart.lua")
assert(auto:find("tools.upgrade_startup", 1, true) < auto:find("local keys_set", 1, true), "upgrade_startup runs at the chunk's load, outside the start-only block")
assert(auto:find("good_at = (not okg or res == nil) and reaper.time_precise() or true", 1, true), "a failed copy is tried again in a minute")
assert(read_src("lib/drive.lua"):find('"recall", "recall/known"', 1, true), "saved versions' maps go to the cloud copy too")
print("ok")
