-- 0.59.48 (Round 3 review, UI and Live sync side): Sync and exit in a tab Live sync syncs after a Save As, its hold question blocking the save,
-- no save and no Quit for a backup or a second tab, which tabs Quit saves, the per-room "local work" mark and live.recording_anywhere as
-- band's. Offline, with stubs (lupa or any Lua 5.4, from the repo root).
package.path = "lib/?.lua;" .. package.path
local clock, ext, saves, commands = 100, {}, 0, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
  ValidatePtr2 = function() return true end,
  GetProjExtState = function(_, _, k) return 1, ext["proj " .. k] or "" end,
  SetProjExtState = function(_, _, k, v) ext["proj " .. k] = v end,
  Main_SaveProject = function() saves = saves + 1 end,
  Main_OnCommand = function(c) commands[#commands + 1] = c end,
  EnumProjects = function() end,
  file_exists = function() return false end,
}, { __index = function() return function() return "" end end })
for _, m in ipairs({ "band", "leave", "live" }) do package.loaded[m] = nil end
local band = require("band")
band.log = function() end
local leave, live = require("leave"), require("live")

-- Sync and exit in a tab Live sync is syncing whose file isn't the registered one (after REAPER's Save As): not a backup, so it holds, saves and sends
local copy, elsewhere = true, false
package.loaded.rooms = { is_copy = function() return copy end }
band.synced_elsewhere = function() return elsewhere end
local cfg, b = { root = "R", user = "Me" }, { song = "Song", room = "main" }
assert(leave.is_backup("P0", cfg, b), "no Live sync in it, and not the project's file: a backup")
ext["live P0"] = tostring(clock - 2)
assert(not leave.is_backup("P0", cfg, b), "Live sync runs in it: not a backup, whatever its file's name")
leave.start("P0", cfg, b)
assert(not leave.job.problem and leave.job.step == "save", "Live sync runs in it: Sync and exit saves and sends, it isn't called a backup")
leave.tick()
assert(saves == 1, "saved")

-- The hold question blocks the save, even with Live sync running and nothing waiting to go out (lib/leave.lua's "hold?" step)
saves = 0
ext["proj hold"] = "1"
leave.start("P0", cfg, b)
band.set_ext_json(band.SECTION, "outbox P0", { at = clock + 1 })
for _ = 1, 5 do clock = clock + 3; ext["live P0"] = tostring(clock); leave.tick() end
assert(leave.job.step == "hold?" and saves == 0 and ext["proj hold"] == "1", "Hold my changes on: nothing saved or sent until the question is answered")
ext["proj hold"] = nil

-- The finished box: a backup or a second tab offers no Quit and saves nothing on Close; otherwise Close saves and Quit is there
local offered, press = {}, nil
local ImGui = setmetatable({
  BeginPopupModal = function() return true end,
  GetStyleVar = function() return 4, 4 end,
  GetContentRegionAvail = function() return 10000 end,
  CalcTextSize = function() return 10 end,
  IsKeyPressed = function() return false end,
  Button = function(_, l) offered[#offered + 1] = l; return l == press end,
}, { __index = function() return function() end end })
local function finished(problem)
  ext["live P0"] = nil
  copy = false
  leave.start("P0", cfg, b)
  leave.job.finished, leave.job.problem, leave.job.lines, leave.job.open = true, problem, { problem or "Saved." }, nil
end
saves, commands, offered, press = 0, {}, {}, "Close this project"
finished("This is a backup or autosave, not your project for it: nothing of it syncs. Close it as you like.")
leave.draw({}, ImGui, "D")
assert(#offered == 2 and offered[1] == "Close this project" and offered[2] == "Stay", "a backup: Close or Stay, no Quit")
assert(saves == 0 and commands[1] == 40860 and leave.job == nil, "a backup's Close closes without saving: REAPER asks its own question")
saves, commands, offered = 0, {}, {}
finished(nil)
leave.draw({}, ImGui, "D")
assert(#offered == 3 and offered[2] == "Quit REAPER" and saves == 1 and commands[1] == 40860, "all sent: Close saves first, and Quit is offered")

-- Which tabs Quit saves: a group project's own file; not a second copy syncing in another tab, a backup, or anything not StudioSync's
band.binding = function(p) if p ~= "Plain" then return { song = "Song", room = "main" } end end
copy, elsewhere = false, false
assert(leave.quit_saves("P1", "C:/x/Song.rpp", cfg), "the project's own file: saved")
assert(not leave.quit_saves("P1", "", cfg), "no file name: not saved (REAPER asks)")
assert(not leave.quit_saves("Plain", "C:/x/Other.rpp", cfg), "not StudioSync's: REAPER asks")
elsewhere = true
assert(not leave.quit_saves("P1", "C:/x/Song.rpp", cfg), "syncing in another tab: this second copy isn't saved over its file")
elsewhere, copy = false, true
assert(not leave.quit_saves("P1", "C:/x/Song-2.rpp", cfg), "a backup: not saved")
ext["live P1"] = tostring(clock)
assert(leave.quit_saves("P1", "C:/x/Song-2.rpp", cfg), "the same file with Live sync in it (saved under a new name): saved")
-- and Quit REAPER goes by it: the syncing tab is saved, its second copy isn't
local tabs = { { "P1", "C:/x/Song.rpp" }, { "P2", "C:/x/Song.rpp" } }
reaper.EnumProjects = function(i) local t = tabs[i + 1]; if t then return t[1], t[2] end end
band.synced_elsewhere = function(p) return p == "P2" and "P1" or nil end
copy = false
finished(nil)
ext["live P1"] = tostring(clock)
saves, commands, offered, press = 0, {}, {}, "Quit REAPER"
leave.draw({}, ImGui, "D")
assert(saves == 1 and commands[1] == 40004, "Quit: only the syncing tab is saved, not its second copy")
band.synced_elsewhere = function() return elsewhere end

-- The "local work" mark, per room: each tab adds or takes away only its own room; an old "1" stays
assert(live.mark_room("", "main", true) == "main", "main has some: marked")
assert(live.mark_room("main", "main", true) == nil, "already marked: nothing written")
assert(live.mark_room("main", "side", true) == "main|side", "a side room adds itself")
assert(live.mark_room("main|side", "main", false) == "side", "the main room's tab takes away only its own room: the side room's work still keeps the folder")
assert(live.mark_room("side", "side", false) == "", "the last room with work gone: no mark")
assert(live.mark_room("", "side", false) == nil, "nothing to take away: nothing written")
assert(live.mark_room("1", "main", false) == nil, "an old mark stays: it may be a side room's")
assert(live.mark_room("1", "main", true) == "1|main" and live.mark_room("1|main", "main", false) == "1", "an old mark stays beside the rooms")

-- live.recording_anywhere is band's (one copy), and false with an older band.lua that has none
band.recording_anywhere = function() return true end
assert(live.recording_anywhere() == true, "band's answer")
band.recording_anywhere = nil
assert(live.recording_anywhere() == false, "an older band.lua beside it: false, not an error")

print("ok")
