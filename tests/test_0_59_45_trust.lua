-- 0.59.45 (Round 1 review): a failed reload puts every module and the code check back, the whole-copy look backs off and wants its list,
-- a case-only rename keeps its files, reserved and other-alphabet names are refused, the startup block. Lupa or Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext, projects, playing = 1000, {}, {}, 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  EnumProjects = function(i) return projects[i + 1] end, GetPlayStateEx = function() return playing end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log, band.log_file = function() end, function() end

-- band.reload: the new code fails as it starts. Every lib module is as it was (nil for one the old code hadn't loaded yet), and the old code
-- check is back in package.searchers.
local src = {
  ["/c/lib/old_mod.lua"] = "return { v = 2 }", ["/c/lib/lazy_mod.lua"] = "return { v = 2 }",
  ["/c/Main.lua"] = "package.loaded.old_mod = { v = 2 }; package.loaded.lazy_mod = { v = 2 }\n" ..
    "BANDSYNC_CODE_SEARCHER = function() end; table.insert(package.searchers, 2, BANDSYNC_CODE_SEARCHER)\nerror('boom')",
}
reaper.EnumerateFiles = function(d, i) if d == "/c/lib" then return ({ "lazy_mod.lua", "old_mod.lua" })[i + 1] end end
local real_loadfile = loadfile
loadfile = function(p) if src[p] then return load(src[p], "@" .. p) end return nil, "no file " .. p end
package.loaded.old_mod = { v = 1 }
local old_check = function() end
BANDSYNC_CODE_SEARCHER = old_check
table.insert(package.searchers, 2, old_check)
local n_searchers = #package.searchers
local ok, why = band.reload("/c", "Main.lua")
assert(not ok and tostring(why):find("boom"), "the failure is said: " .. tostring(why))
assert(package.loaded.old_mod.v == 1, "a module loaded before is the old one again")
assert(package.loaded.lazy_mod == nil, "a module the old code hadn't loaded yet isn't left at the new version (it was bound to the discarded new code)")
assert(BANDSYNC_CODE_SEARCHER == old_check and package.searchers[2] == old_check and #package.searchers == n_searchers,
  "the old code check is back, and the failed start's is gone (modules not loaded yet were refused, or came from the new searcher)")
-- something recording: not tried, and not marked as failed
projects, playing = { "p1" }, 5
assert(not band.reload_or_say("/c", "Main.lua", "9.9") and ext[band.reload_failed_key("Main.lua")] == nil, "while recording: tried later, not marked failed")
projects, playing = {}, 0
assert(not band.reload_or_say("/c", "Main.lua", "9.9", "proj1") and ext["reload failed Main.lua proj1"] == "9.9" and ext["reload failed Main.lua"] == nil,
  "a failure is marked per instance when the caller says which (a Live sync tab)")
loadfile = real_loadfile

-- band.files_complete: a shared copy without lib/files.txt isn't whole; a look that failed isn't done again until the list or that file's size
-- changes, or a minute on
local files, sizes, reads = {}, {}, {}
local real_read, real_size = band.read, band.size
band.read = function(p) reads[p] = (reads[p] or 0) + 1; return files[p] end
band.size = function(p) return sizes[p] end
assert(band.files_complete("/s/_tools/studiosync", true) == false, "no lib/files.txt in a shared copy: not whole (a hand copy without it passed)")
local D = "/s/_tools/studiosync"
files[D .. "/lib/files.txt"] = "version 1.0\nlib/a.lua\t5\nlib/b.lua\t3\n"
files[D .. "/lib/a.lua"], files[D .. "/lib/b.lua"] = "12345", "1234" -- b is a byte longer than the list says
sizes[D .. "/lib/b.lua"] = 4
assert(band.files_complete(D) == false, "a file of the wrong length: not whole")
local before = reads[D .. "/lib/a.lua"]
clock = clock + 4
assert(band.files_complete(D) == false and reads[D .. "/lib/a.lua"] == before, "looked at again 4 s later: the files aren't read again (every 3 s, by every script)")
files[D .. "/lib/b.lua"], sizes[D .. "/lib/b.lua"] = "123", 3
clock = clock + 4
assert(band.files_complete(D) == true and reads[D .. "/lib/a.lua"] == before + 1, "the file that didn't match changed size: looked at again at once, whole now")
local E = "/s2/_tools/studiosync"
files[E .. "/lib/files.txt"], files[E .. "/lib/a.lua"], sizes[E .. "/lib/a.lua"] = "version 1.0\nlib/a.lua\t5\n", "1234", 4
clock = clock + 4
assert(band.files_complete(E) == false)
local r0 = reads[E .. "/lib/a.lua"]
clock = clock + 61
assert(band.files_complete(E) == false and reads[E .. "/lib/a.lua"] == r0 + 1, "a minute on, it's looked at again")
band.read, band.size = real_read, real_size

-- band.rename, "james" to "James" on a disk where that's one file (Windows, a Mac): the claims, the colour and the devices file stay
local fs = {}
local function k(p) return p:lower() end
band.read_json = function(p) return fs[k(p)] end
band.write_json = function(p, t) fs[k(p)] = t end
band.remove = function(p) fs[k(p)] = nil end
local real_remove = os.remove
os.remove = function(p) fs[k(p)] = nil end
reaper.file_exists = function(p) return fs[k(p)] ~= nil end
band.subdirs = function(d) if d == "/r" then return { "Song" } elseif d == "/r/Song/rooms" then return { "main" } end return {} end
fs[k("/r/_band/devices/james.json")] = { user = "james", device = "AAAAAAA-B" }
fs[k("/r/_band/colours/james.json")] = { user = "james", colour = 5 }
fs[k("/r/Song/rooms/main/claims/james.json")] = { user = "james", tracks = { "Gtr" } }
band.rename("/r", "james", "James")
assert(fs[k("/r/_band/devices/James.json")] and fs[k("/r/_band/devices/James.json")].user == "James", "the devices file stays, under the new name")
assert(fs[k("/r/_band/colours/James.json")] and fs[k("/r/_band/colours/James.json")].colour == 5, "the colour stays")
local c = fs[k("/r/Song/rooms/main/claims/James.json")]
assert(c and c.user == "James" and c.tracks[1] == "Gtr", "the claims stay (writing the new name then removing the old deleted them all)")
os.remove = real_remove

-- names: Windows' reserved names, and a name that cleans to nothing
assert(band.reserved("CON") and band.reserved("nul") and band.reserved("Com1") and band.reserved("lpt9") and band.reserved("aux.txt"), "reserved names refused")
assert(not band.reserved("Console") and not band.reserved("Comet") and not band.reserved("Lantern"), "ordinary names pass")
assert(band.name_problem("\208\159\209\145\209\130\209\128"):find("Latin letters"), "a name in another alphabet says why (it cleaned to nothing, silently)")
assert(band.name_problem("Jos\195\169") == nil and band.name_problem("") == nil, "a name that cleans to something, or nothing typed: no problem")
assert(band.name_problem("Aux"), "and a reserved one")
assert(band.clean("Nguy\225\187\133n") == "Nguyen" and band.clean("\200\153tefan") == "stefan", "Vietnamese and Romanian letters as the installers make them")

-- the startup block: it compiles, and each copy is in a pcall
local tools = require("tools")
local block = tools.startup_block({ "/a", "/home/last good" })
assert(load(block, "=block") and block:find("[[/home/last good/StudioSync - Autostart.lua]]", 1, true), "the block compiles")
-- run: the first copy fails as it loads; what it loaded goes, the last-good copy starts, and the failure is left for Autostart to say
local started, real_dofile, real_exists = nil, dofile, reaper.file_exists
reaper.file_exists = function() return true end
dofile = function(f) if f:find("^/a/") then package.loaded.from_bad_copy = true; error("bad copy") end started = f end
load(block, "=block")()
dofile, reaper.file_exists = real_dofile, real_exists
assert(started == "/home/last good/StudioSync - Autostart.lua" and package.loaded.from_bad_copy == nil and tostring(ext["startup failed"]):find("bad copy"),
  "a copy that fails to load: the next one starts, clean (a bare dofile stopped there, and everything after it in __startup.lua)")
-- and a block rewritten without a fallback keeps the one it had; one copy alone has none
local text = tools.startup_block({ "/s/_tools/studiosync", band.last_good_dir(), "/reapack" })
band.read = function() return "mine()\n" .. text end
local wrote
band.write_atomic = function(_, t) wrote = t end
tools.set_autostart(true, "/s/_tools/studiosync")
assert(wrote:find("[[/reapack/StudioSync - Autostart.lua]]", 1, true) and wrote:find("mine()", 1, true), "the fallback stays (the panel's toggle dropped it)")
band.read = function() return tools.startup_block({ "C:/Users/x/S/_tools/studiosync" }) end
assert(tools.autostart_on("C:\\Users\\X\\S\\_tools\\studiosync"), "the panel's backslashed folder is the block's (it missed, and wrote the block again bare)")
print("ok")
