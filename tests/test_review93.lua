-- Tests for what 0.58.92 fixed without a test (lupa or Lua 5.4, from the repo root): Live sync's decisions, Drive's ownership and arriving
-- files, the local-copy re-check, a guest's project list failing closed, and the Syncthing back-off with the key off the command line.
package.path = "lib/?.lua;" .. package.path
local clock, ext, calls = 1000, {}, {}
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  RecursiveCreateDirectory = function() return 1 end,
}, { __index = function() return function() end end })

-- Live sync (lib/together.lua)
local together = require("together")
local past, hit = 0, false
past, hit = together.count_reading(past, 6.42, 6.4) -- (at the leader's stop, once)
assert(past == 1 and not hit, "one reading at the stop isn't enough")
past, hit = together.count_reading(past, 6.11, 6.4) -- (a glitch back)
assert(past == 0 and not hit, "a reading short of it starts the count again")
past, hit = together.count_reading(past, 6.45, 6.4); past, hit = together.count_reading(past, 6.46, 6.4)
assert(hit, "two in a row stop it")
assert(together.leave_alone(true, true, false, true, nil, false), "your own take isn't cut by someone else's cue")
assert(not together.leave_alone(true, true, false, true, true, false), "a take started together may be stopped together")
assert(not together.leave_alone(true, true, false, false, nil, false), "not recording: their cue is followed")
assert(together.leave_alone(true, true, false, false, nil, true), "a record cue doesn't pull you off another tab that's playing")
assert(not together.leave_alone(true, true, true, true, nil, false), "a producer's remote start still applies")
assert(not together.leave_alone(false, true, false, true, nil, false), "not due yet: nothing to leave")
assert(together.heartbeat_due(true, true, 1016, 1000), "a take: the status is written every 15 s")
assert(not together.heartbeat_due(true, true, 1010, 1000) and not together.heartbeat_due(false, true, 1100, 1000), "not before, and not when not recording")

-- Drive (lib/drive.lua)
package.loaded.band = { files = function() return {} end }
local drive = require("drive")
local longer = drive.longer_names({ { user = "James" }, { user = "James-Laptop" }, { user = "Mac" }, { user = "James-Laptop" }, { user = "Jamesy" } }, "James")
assert(#longer == 1 and longer[1] == "James-Laptop", "James-Laptop is a longer name of James's; Jamesy isn't")
assert(drive.mine("James-20261117-120000Z-1-a.json", "James", longer), "James's own event")
assert(not drive.mine("James-Laptop-20261117-120000Z-1-a.json", "James", longer), "the laptop's event isn't James's")
assert(drive.mine("James-Laptop-20261117-120000Z-1-a.json", "James-Laptop", {}), "it's the laptop's")
assert(drive.mine("20261117-003604Z-James-20_quiet_minutes.json", "James", longer), "James's restore point")
assert(not drive.mine("20261117-014458Z-James-Laptop-before_x.json", "James", longer), "the laptop's restore point isn't James's")
assert(drive.arriving(".syncthing.take.flac.tmp") and drive.arriving("~syncthing~take.flac.tmp") and not drive.arriving("print-I-A-1-abc-James.flac"),
  "Syncthing's arriving files are known, real ones aren't")

-- the local-copy delete, asked again once you've said yes (lib/localcopy.lua)
package.loaded.band = { files = function() return {} end, read_json = function() return nil end }
local copy = require("localcopy")
assert(not copy.still_confirmed({ "Laptop" }, {}), "the laptop it was confirmed on stopped holding it: kept here")
assert(copy.still_confirmed({ "Laptop" }, { "Laptop" }), "still held there: it goes")
assert(copy.still_confirmed({ "Google Drive" }, {}), "Drive had it all: it goes")

-- a guest's project list (lib/access.lua): fails closed, and keeps the last list while Syncthing doesn't answer
local files, verdict, me = {}, nil, "GUESTID1234"
package.loaded.band = { SECTION = "StudioSync", read_json = function(p) return files[p] end, json_encode = function(t) return table.concat(t, "\n") end,
  json_decode = function(s) if s == "" then return nil end; local t = {}; for x in s:gmatch("[^\n]+") do t[#t + 1] = x end; return t end }
package.loaded.band.ext_json = function(sec, key) return package.loaded.band.json_decode(reaper.GetExtState(sec, key)) end
package.loaded.band.set_ext_json = function(sec, key, v, p) reaper.SetExtState(sec, key, package.loaded.band.json_encode(v), p) end
package.loaded.trust = { from_manager_file = function() return verdict end, pins = function() return {} end, held = function() return false end }
package.loaded.services = { my_device_id = function() return me end }
package.loaded.access = nil
local access = require("access")
local function shows(song) access.forget(); return access.shows(access.mine("R"), song) end
local gfile = "R/_band/guest-access/GUESTID.json"
local function written(at, songs) files[gfile] = { device = me, songs = songs, by = "James", at = at } end
written(1, { "Song A" })
verdict = nil
assert(not shows("Song A") and not shows("Song B"), "not checked yet, nothing checked before: nothing shows (it showed everything)")
written(2, { "Song A" }); verdict = false
assert(not shows("Song A") and not shows("Song B"), "written by someone not in charge: nothing shows")
written(3, { "Song A" }); verdict = true
assert(shows("Song A") and not shows("Song B"), "checked: only their projects")
written(4, { "Song A", "Song B" }); verdict = nil
assert(shows("Song A") and not shows("Song B"), "a new list not checked yet: the last checked one, not nothing (0.58.93)")
verdict = true
assert(shows("Song B"), "once checked, the new one")
verdict = false
assert(shows("Song B"), "a verdict once given is kept for that writing (no blocking call every 5 s)")
local raw = access.read("R", me)
assert(raw and raw["Song A"] and raw["Song B"], "the people in charge see the list as written")
me = nil
assert(shows("Song A") and shows("Song B") and not shows("Song C"), "Syncthing not answering: the last list this computer had")
me = "MEMBERID999"
assert(shows("Song B"), "a computer with no list sees everything")

-- the Syncthing back-off, and the API key off the command line (lib/services.lua)
local dir = ((os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")) .. "/ss_r93_" .. os.time() .. "_" .. math.random(100000, 999999) -- (two runs in one second shared it: Round 3 review, 0.59.48)
os.execute(package.config:sub(1, 1) == "\\" and ('mkdir "' .. dir:gsub("/", "\\") .. '"') or ("mkdir -p '" .. dir .. "'"))
local f = assert(io.open(dir .. "/config.xml", "wb"))
f:write('<configuration><gui enabled="true" tls="false"><address>127.0.0.1:8384</address><apikey>SECRETKEY123</apikey></gui></configuration>')
f:close()
ext.syncthing_path, ext.syncthing_home = "C:/st/syncthing.exe", dir
package.loaded.band, package.loaded.services, package.loaded.trust = nil, nil, nil
local logged, kept = {}, {}
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
-- (services writes its curl config into the real temp folder: kept in memory here, or the real one held this test's key. 0.58.93)
local real_read, real_write = band.read, band.write_atomic
band.read = function(p) if p:find("bandsync%-") then return kept[p] end; return real_read(p) end
band.write_atomic = function(p, s) if p:find("bandsync%-") then kept[p] = s; return true end; return real_write(p, s) end
reaper.file_exists = function() return true end
local hang = true
reaper.ExecProcess = function(c, ms)
  calls[#calls + 1] = c
  if hang then clock = clock + ms / 1000; return nil end
  return "0\nok"
end
local services = require("services")
services.device_name("ABCDEFG")
assert(#calls == 1, "the first call is made")
services.device_name("ABCDEFG"); services.device_name("ABCDEFG")
assert(#calls == 1, "after a call ran into its limit, the next ones aren't made (each froze REAPER for its own limit)")
assert(logged[1] and logged[1]:find("leaves it alone for a minute", 1, true), "and it's said once: " .. tostring(logged[1]))
services.set_folder_label("lab", "StudioSync Lab")
assert(#calls == 2 and calls[2]:find(" label set ", 1, true), "a change still goes while questions wait (0.58.93)")
clock = clock + 61
hang = false
services.device_name("ABCDEFG")
assert(#calls == 3, "a minute on, Syncthing is asked again")
reaper.ExecProcess = function(c) calls[#calls + 1] = c; return "259\n" end -- (Windows' answer when the limit ran out: measured, 0.58.93)
services.device_name("ABCDEFG"); services.device_name("ABCDEFG")
assert(#calls == 4, "REAPER's 'still running' answer counts as a timeout too")
clock = clock + 61
reaper.ExecProcess = function(c) calls[#calls + 1] = c; return "0\nok" end
calls = {}
services.ask("/rest/system/version")
assert(calls[1] and calls[1]:find(" -K ", 1, true), "the API call reads its key from a config file: " .. tostring(calls[1]))
assert(not calls[1]:find("SECRETKEY123", 1, true), "the key isn't on the command line")
local cfgfile = calls[1]:match('%-K "([^"]+)"')
assert(cfgfile and kept[cfgfile] == 'header = "X-API-Key: SECRETKEY123"\n', "it's in the config file curl reads: " .. tostring(cfgfile and kept[cfgfile]))
band.read, band.write_atomic = real_read, real_write
os.remove(dir .. "/config.xml")
os.execute(package.config:sub(1, 1) == "\\" and ('rmdir "' .. dir:gsub("/", "\\") .. '"') or ("rmdir '" .. dir .. "'"))
print("ok")
