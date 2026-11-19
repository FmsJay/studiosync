-- 0.59.46 (Round 2 review): no move to the studio's copy before Syncthing says which computer this is; never back to an older copy (the
-- last-good copy instead); debug mode told before anything is collected; only Tailscale-only studios check devices files; the Recycle Bin
-- check counts only the job. Lupa or Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local t, ext = 100, {}
reaper = setmetatable({
  time_precise = function() t = t + 61; return t end, GetOS = function() return "Win64" end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  file_exists = function(p) return not p:find("%.git") end, GetResourcePath = function() return "/res" end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log = function() end
band.bands = function() return { { root = "/st", name = "St" } } end
band.files_complete = function() return true end
band.sync_actions = function() end
local my_id
local trusted = { updates = "folder" }
package.loaded.services = { my_device_id = function() return my_id end }
package.loaded.groups = { trusted = function() return trusted end, may_remove = function() return true end }
package.loaded.access = { mine = function() return nil end }
package.loaded.removal = { am_guest = function() return false end }
local moved = {}
package.loaded.tools = { set_autostart = function(_, d) moved[#moved + 1] = d; return true end }
local versions = { ["/st/_tools/studiosync"] = band.VERSION }
band.version_on_disk = function(d) return versions[d] end
local ff = require("fromfolder")

-- not before Syncthing has said which computer this is
my_id = nil
ff.tick("/rp")
assert(#moved == 0, "no device ID yet: no move (a guest was moved to the studio's copy at the first look, then back)")
my_id = "MEMBER1-ZZZZ"
ff.tick("/rp")
assert(moved[1] == "/st/_tools/studiosync", "once it's known: moved")

-- updates turned off: back only to a copy at least as new; else the last-good copy
moved, trusted = {}, {}
ext["run from"], ext["run from before"] = "/st/_tools/studiosync", "/rp"
versions["/rp"], versions[band.last_good_dir()] = "0.50.0", band.VERSION
ff.tick("/st/_tools/studiosync"); ff.tick("/st/_tools/studiosync")
assert(moved[1] == band.last_good_dir() and ext["run from"] == band.last_good_dir(), "the copy it ran from is older: the last-good copy, not a downgrade")
moved, ext["run from"], ext["run from before"] = {}, "/st/_tools/studiosync", "/rp"
versions[band.last_good_dir()] = nil
ff.tick("/st/_tools/studiosync"); ff.tick("/st/_tools/studiosync")
assert(#moved == 0, "and no last-good copy either: it stays where it is")

-- debug mode: told before anything is collected
package.loaded.debugmode = nil
local dm = require("debugmode")
trusted = { debug = true }
local order = {}
dm.tell = function() order[#order + 1] = "tell" end
dm.write = function() order[#order + 1] = "write" end
dm.collect({ root = "/st", user = "Gus" }, nil, nil, "end of session")
assert(order[1] == "tell" and order[2] == "write", "told, then collected (switched on mid-session, the first collection went out before)")

-- the Recycle Bin check counts only the job against the bin's size
local src = io.open("lib/localcopy.lua", "rb"):read("a")
assert(src:find("$sum[$dl] -le $cap", 1, true) and not src:find("$sum[$dl] + $b.bytes", 1, true), "only this job: a full bin refused every delete")
print("ok")
