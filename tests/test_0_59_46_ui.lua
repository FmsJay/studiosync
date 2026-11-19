-- 0.59.46 (Round 2 review, UI and Live sync side): who has the project at Sync and exit (in the room now; a guest's computer), Sync and exit on a
-- backup copy or a second tab, its hold question and steps as a state machine, reloads that wait for a take, the status fingerprint, the auto-save's
-- "yours went out" flag. Offline, with stubs (lupa or any Lua 5.4, from the repo root).
package.path = "lib/?.lua;" .. package.path
local clock, ext, saves, playstate, logged = 100, {}, 0, {}, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
  ValidatePtr2 = function() return true end,
  GetProjExtState = function(_, _, k) return 1, ext["proj " .. k] or "" end,
  SetProjExtState = function(_, _, k, v) ext["proj " .. k] = v end,
  Main_SaveProject = function() saves = saves + 1 end,
  EnumProjects = function(i) if playstate[i + 1] then return "P" .. i end end,
  GetPlayStateEx = function(p) return playstate[tonumber(p:sub(2)) + 1] end,
  file_exists = function() return false end,
}, { __index = function() return function() return "" end end })
for _, m in ipairs({ "band", "leave", "live" }) do package.loaded[m] = nil end
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local leave, live = require("leave"), require("live")

-- Who has it (leave.holders): in the room now counts though their holds list doesn't name it yet; a guest's computer counts everyone online;
-- someone taken out never counts
local age = function() return 10 end
local h = leave.holders({ "Bob", "Cal" }, {}, "Song", 3 * 86400, age, { bob = true })
assert(#h == 1 and h[1] == "Bob", "Bob is in the room now: he has it, though no holds list names it yet")
h = leave.holders({ "Bob", "Cal" }, {}, "Song", 3 * 86400, age, {}, true)
assert(#h == 2, "on a guest's computer (no holds lists come there) everyone online counts")
h = leave.holders({ "Bob", "Cal" }, {}, "Song", 3 * 86400, age, { bob = true, cal = true }, false, { Cal = true })
assert(#h == 1 and h[1] == "Bob", "someone taken out doesn't count")

-- Sync and exit as it runs (leave.start, leave.tick), with the rest of StudioSync stubbed
local copy, elsewhere = false, false
package.loaded.rooms = { is_copy = function() return copy end }
band.synced_elsewhere = function() return elsewhere end
local rescans = 0
package.loaded.services = { rescan = function() rescans = rescans + 1 end }
local cfg, b = { root = "R", user = "Me" }, { song = "Song", room = "main" }
copy = true
leave.start("P0", cfg, b)
leave.tick()
assert(leave.job.finished and leave.job.lines[1]:find("backup or autosave", 1, true) and saves == 0, "a backup copy: nothing saved or sent, and it says why")
copy = false
ext["proj hold"] = "1"
leave.start("P0", cfg, b)
leave.tick(); leave.tick()
assert(leave.job.step == "hold?" and saves == 0, "Hold my changes on: nothing is saved or sent until the question is answered")
leave.job.kept_held, leave.job.step = true, "save"
leave.tick()
assert(saves == 1 and ext["proj hold"] == "1", "Keep holding: saved, and Hold my changes stays on")
clock = clock + 5
leave.tick() -- no Live sync heartbeat for the tab
assert(leave.job.sync_off and not leave.job.finished, "Live sync off: it waits with Start sync, it doesn't end")
elsewhere = true
clock = clock + 20
leave.tick(); leave.tick()
assert(leave.job.finished and leave.job.lines[1]:find("another tab", 1, true), "syncing in another tab: no Start sync, it says where")
elsewhere = false
ext["proj hold"] = nil
leave.start("P0", cfg, b)
leave.tick() -- save
ext["live P0"] = tostring(clock)
band.set_ext_json(band.SECTION, "outbox P0", { at = clock + 1 })
clock = clock + 3
ext["live P0"] = tostring(clock)
leave.tick()
assert(leave.job.step == "syncthing" and rescans == 1, "everything out: on to the hand-over")
-- holders, not who's online, decide the cloud copy
local copied = 0
package.loaded.drive = { root = function() return "D:/Drive" end, name = function() return "Dropbox" end,
  mirror = function() copied = copied + 1; return 1, false end }
package.loaded.sync = { room_dir = function() return "R/Song/rooms/main" end }
package.loaded.localcopy = { read_holds = function() return {} end, FRESH = 3 * 86400 }
package.loaded.presence = { here = function() return { "Bob" } end }
package.loaded.removal = { am_guest = function() return false end, gone = function() return {} end }
band.subdirs = function() return { "main" } end
leave.job.step, leave.job.st = "drive", { peers = { { name = "Bob", need = 0 }, { name = "Cal", need = 0 } }, need = 0 }
leave.tick(); leave.tick()
assert(copied == 0 and leave.job.finished and leave.job.lines[2] == "Everything is with Bob.", "Bob, in the room, has it: no cloud copy, and only Bob is named")

-- Reloads (live.reload): nothing tried, said or handed over while anything records; said only once it worked
local before, undone, tried = 0, 0, 0
band.reload_or_say = function() tried = tried + 1; return tried > 1 end
playstate = { 0, 5 } -- the second tab records
logged = {}
local ok, why = live.reload("D", "S.lua", "9", nil, function() before = before + 1 end, "reloaded", function() undone = undone + 1 end)
assert(not ok and why == "busy" and before == 0 and tried == 0 and #logged == 0, "while recording: nothing tried, done or said")
playstate = { 0, 1 }
ok = live.reload("D", "S.lua", "9", nil, function() before = before + 1 end, "reloaded", function() undone = undone + 1 end)
assert(not ok and before == 1 and undone == 1 and #logged == 0, "a failed start: put back, and no \"reloaded\"")
ok = live.reload("D", "S.lua", "9", nil, function() before = before + 1 end, "reloaded", function() undone = undone + 1 end)
assert(ok and logged[1] == "reloaded" and undone == 1, "said once the new code took over")
assert(live.recording_anywhere() == false, "nothing recording")

-- The status fingerprint follows every field (live.status_fingerprint)
local info = { driver = "A", mix = { v = 1 }, produce = "B", produce_via = "stamp", stamping = true, pending = 0, armed = {} }
local base = live.status_fingerprint(info)
for k, v in pairs(info) do
  local copy_ = {}
  for k2, v2 in pairs(info) do copy_[k2] = v2 end
  copy_[k] = type(v) == "number" and v + 1 or type(v) == "boolean" and not v or type(v) == "string" and v .. "x" or { changed = true }
  assert(live.status_fingerprint(copy_) ~= base, "a change of " .. k .. " is a change of status")
end

-- Auto-save: something of yours going out or waiting during the batch stops it (leave.mine_went_out)
local st = {}
leave.autosave(st, 120, false, true)
leave.mine_went_out(st, 0, 0)
assert(st.clean == true, "nothing of yours: still clean")
leave.mine_went_out(st, 0, 2)
assert(not leave.autosave(st, 0, false, true), "unsent changes of yours meanwhile: not saved over")
st = {}
leave.autosave(st, 120, false, true)
leave.mine_went_out(st, 3, 0)
assert(not leave.autosave(st, 0, false, true), "changes of yours sent meanwhile: not saved over")
print("ok")
