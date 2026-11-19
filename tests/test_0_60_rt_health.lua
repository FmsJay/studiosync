-- Health's Syncthing folder rows and the disk space guard (James, rt: lib/rthealth.lua). The pure parts: what fits in the space left, the
-- disk row's colour, bandmates low on disk from their status files, Syncthing's errors in plain words, a stuck bandmate, and each folder row's
-- colour and words; then the gathering with a stand-in REAPER and Syncthing.
package.path = "lib/?.lua;" .. package.path
local clock, gext, free = 1000, {}, 50000
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetFreeDiskSpaceForRecordPath = function() return free end,
}, { __index = function() return function() end end })
local band = require("band")
local R = require("rthealth")

-- ---- what fits ----
assert(R.fits_words(800) == "about 48 minutes of 24-bit stereo at 48 kHz", R.fits_words(800))
assert(R.fits_words(10) == "less than a minute of 24-bit stereo at 48 kHz", "a few MB")
assert(R.fits_words(17) == "about 1 minute of 24-bit stereo at 48 kHz", "one minute, singular")
assert(R.fits_words(50000):find("^about 50 hours"), R.fits_words(50000))
assert(R.size_words(800) == "800 MB" and R.size_words(4300) == "4.2 GB" and R.size_words(2048) == "2 GB", R.size_words(2048))

-- ---- this computer's disk ----
assert(R.disk_row(nil) == nil and R.disk_row(-1) == nil, "REAPER couldn't tell: no row")
local r = R.disk_row(50000)
assert(r[1] == "disk" and r[2] == true and r[4]:find("48.8 GB free"), "plenty: green")
r = R.disk_row(4000)
assert(r[2] == false and r[3] == "yellow" and r[5]:find("low on disk") and r[5]:find("about"), "under 5 GB: yellow, with what fits")
r = R.disk_row(900)
assert(r[2] == false and r[3] == "red", "under 1 GB: red")

-- ---- bandmates low on disk ----
local now = os.date("!*t")
local fresh = os.date("!%Y-%m-%dT%H:%M:%SZ")
local sts = {
  { user = "Mac", time = fresh, free_mb = 800 },
  { user = "Bo", time = fresh, free_mb = 90000 },
  { user = "Old", time = "2020-01-01T00:00:00Z", free_mb = 10 },
  { user = "Me", time = fresh, free_mb = 10 },
  { user = "NoField", time = fresh },
  { user = "Junk", time = fresh, free_mb = "x" },
}
local rows = R.peer_disk_rows(sts, "Me", now)
assert(#rows == 1 and rows[1][1] == "disk Mac" and rows[1][3] == "yellow" and rows[1].short == "Mac is low on disk (800 MB)", "only a fresh bandmate under 5 GB")
assert(rows[1][5]:find("^Mac is low on disk %(800 MB%): about 48 minutes"), rows[1][5])
assert(#R.peer_disk_rows(nil, "Me", now) == 0, "no statuses")

-- ---- plain words ----
assert(R.plain("open /x/y.wav: no space left on device") == "the disk is full", "disk full")
assert(R.plain("CreateFile: Access is denied.") == "Syncthing isn't allowed to write there", "Windows permission")
assert(R.plain("folder marker missing (this indicates potential data loss)"):find("stfolder"), "marker")
assert(R.plain("some new thing") == "some new thing" and #R.plain(string.rep("x", 200)) == 80, "anything else as said, cut short")

-- ---- stuck ----
local track = {}
assert(R.still_for(track, "k", 50, 0) == 0 and R.still_for(track, "k", 50, 700) == 700, "no progress: the time counts")
assert(R.still_for(track, "k", 60, 800) == 0, "moved: from now")
assert(R.still_for(track, "k", 100, 900) == 0 and R.still_for(track, "k", 100, 2000) == 0, "complete is never stuck")

-- ---- a folder's row ----
assert(R.folder_row("Chilio", "studiosync-x", nil, nil, {}) == nil, "before Syncthing answers: no row")
local idle = { state = "idle", needFiles = 0, needBytes = 0 }
local done = { completion = 100, needItems = 0, remoteState = "valid" }
r = R.folder_row("Chilio", "studiosync-x", idle, { errors = nil }, { { name = "Mac", connected = true, comp = done } })
assert(r[1] == "syncthing studiosync-x" and r[2] == true, "idle, everyone complete: green")
assert(r[4] == "Syncthing, Chilio: up to date here; 1 of 1 other computer connected; everyone connected has everything.", r[4])
r = R.folder_row("Chilio", "x", { state = "syncing", needFiles = 3, needBytes = 3 * 1048576 }, {}, { { name = "Mac", connected = true, comp = done } })
assert(r[2] == false and r[3] == "grey" and r[5]:find("syncing, still needs 3 files %(3 MB%)"), r[5])
local part = { completion = 98.6, needItems = 3, remoteState = "valid" }
r = R.folder_row("Chilio", "x", idle, {}, { { name = "Mac", connected = true, comp = part, still = 30 } })
assert(r[3] == "grey" and r[5]:find("Mac: 98%% %(3 files to go%)"), "a bandmate catching up: grey, with how far " .. r[5])
r = R.folder_row("Chilio", "x", idle, {}, { { name = "Mac", connected = true, comp = part, still = 1200 } })
assert(r[3] == "yellow" and r[5]:find("no progress for 20 min"), "stuck a long time: yellow")
r = R.folder_row("Chilio", "x", idle, {}, { { name = "Mac", connected = false, comp = part, still = 99999 } })
assert(r[2] == true and r[4]:find("Mac: 98%% %(3 files to go, offline%)") and r[4]:find("0 of 1"), "offline behind: still green here, and said")
r = R.folder_row("Chilio", "x", idle, {}, { { name = "Bo", connected = true, comp = { completion = 0, remoteState = "notSharing" } } })
assert(r[2] == true, "a computer not sharing it: not counted as behind")
r = R.folder_row("Chilio", "x", { state = "idle", needFiles = 0, pullErrors = 4 },
  { errors = { { path = "Song/media/Bass.wav", error = "no space left on device" }, { path = "Song\\x.rpp", error = "permission denied" }, { path = "c", error = "z" } } }, {})
assert(r[2] == false and r[3] == "yellow", "errors: yellow")
assert(r[5]:find("problems: Bass.wav: the disk is full; x.rpp: Syncthing isn't allowed to write there; 2 more"), r[5])
r = R.folder_row("Chilio", "x", { state = "error", error = "folder path missing" }, {}, {})
assert(r[3] == "yellow" and r[5]:find("stopped by an error") and r[5]:find("isn't there"), "the folder stopped")

-- ---- gathered (stand-in Syncthing) ----
local services = require("services")
local MAC = "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
local ME = "ZZZZZZZ-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
local answers = {
  ["/rest/system/connections"] = band.json_encode({ connections = { [MAC] = { connected = true } } }),
  ["/rest/config/devices"] = band.json_encode({ { deviceID = MAC, name = "Mac" }, { deviceID = ME, name = "Desk" } }),
  ["/rest/config/folders/studio1"] = band.json_encode({ devices = { { deviceID = MAC }, { deviceID = ME } } }),
  ["/rest/db/status?folder=studio1"] = band.json_encode({ state = "idle", needFiles = 0 }),
  ["/rest/folder/errors?folder=studio1"] = '{"folder":"studio1","errors":null,"page":1}',
  ["/rest/db/completion?folder=studio1&device=" .. MAC] = band.json_encode({ completion = 97, needItems = 5, remoteState = "valid" }),
}
local asked = {}
services.st_bg = function(name, path) asked[#asked + 1] = path; return answers[path] end
services.my_device_id = function() return ME end
band.bands = function() return { { root = "S", name = "Chilio", id = "studio1" }, { root = "W", name = "New", id = "studio2", waiting = true } } end
package.loaded.presence = { all = function() return { { user = "Mac", time = fresh, free_mb = 700 } } end }
rows = R.rows({ root = "S", user = "Me" }, { song = "A", room = "main" }, 0)
local by = {}
for _, x in ipairs(rows) do by[x[1]] = x end
assert(by["syncthing studio1"] and by["syncthing studio1"][5]:find("Mac: 97%% %(5 files to go%)") and by["syncthing studio1"][5]:find("1 of 1 other"), "the folder, with the Mac's completion (my own ID left out)")
assert(not by["syncthing studio2"], "a studio still waiting to be let in: no row")
assert(by.disk and by.disk[2] == true, "this computer's disk")
assert(by["disk Mac"] and by["disk Mac"][5]:find("700 MB"), "the Mac low on disk")
local n = #asked
R.rows({ root = "S", user = "Me" }, { song = "A", room = "main" }, 0)
assert(#asked == n, "held 10 s: nothing asked again within it")

-- ---- record start ----
local logged = {}
band.log = function(t) logged[#logged + 1] = t end
free = 900
R.record_check(0, { root = "S", user = "Me" }, { song = "A", room = "main" })
assert(#logged == 2 and logged[1]:find("^recording with 900 MB free") and logged[2]:find("^Mac is low on disk %(700 MB%)"), table.concat(logged, " | "))
logged = {}
free = 90000
package.loaded.presence = { all = function() return {} end }
R.record_check(0, { root = "S", user = "Me" }, { song = "A", room = "main" })
assert(#logged == 0, "plenty everywhere: nothing said")

print("ok rt health")
