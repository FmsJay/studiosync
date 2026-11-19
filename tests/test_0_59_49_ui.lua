-- 0.59.49 (Round 4 review, UI and Live sync side): the old "1" local-work mark is the main room's, Stop keeps only still-unsent entries,
-- follow_file skips backup and autosave names, Sync and exit finds a second tab before saving, its box opens again when it went, and an error
-- in the feedback window still closes it. Offline, with stubs (lupa or any Lua 5.4, from the repo root).
package.path = "lib/?.lua;" .. package.path
local clock, ext, saves = 100, {}, 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
  ValidatePtr2 = function() return true end,
  GetProjExtState = function(_, _, k) return 1, ext["proj " .. k] or "" end,
  SetProjExtState = function(_, _, k, v) ext["proj " .. k] = v end,
  Main_SaveProject = function() saves = saves + 1 end,
  EnumProjects = function() end,
  file_exists = function() return false end,
}, { __index = function() return function() return "" end end })
for _, m in ipairs({ "band", "leave", "live", "feedback" }) do package.loaded[m] = nil end
local band = require("band")
local logged = {}
band.log = function(t) logged[#logged + 1] = t end
band.log_error = function() end
local leave, live = require("leave"), require("live")

-- The old "1" mark counts as the main room's: the main tab's clean stop takes it away; a side room leaves it (James, Round 4)
assert(live.mark_room("1", "main", false) == "", "main stops with no work: the old mark goes")
assert(live.mark_room("1|side", "main", false) == "side", "main takes away the old mark only: the side room's stays")
assert(live.mark_room("1", "main", true) == nil, "main has some: the old mark already says so")
assert(live.mark_room("1", "side", false) == nil and live.mark_room("1", "side", true) == "1|side", "a side room never touches it")

-- At Stop, only the unsent entries that still differ from their known state stay (James, Round 4)
local here = { ["I-same"] = "h1", ["I-edited"] = "h9", ["T-same"] = "t1" } -- the object's hash now
local known = { ["I-same"] = "h1", ["I-edited"] = "h1", ["T-same"] = "t1", ["F-chain"] = "f1", ["I-gone"] = "h2" }
local mirror = { unsent = { ["P1I-same"] = true, ["P1I-edited"] = true, ["P1F-chain"] = true, ["P1I-gone"] = true, ["P1I-new"] = true, ["P2I-same"] = true } }
function mirror.known(_, oid) return 1, known[oid], "ev" end
function mirror.find(_, _, oid) return here[oid] and oid or nil end
function mirror.edited_here(proj, oid, h)
  if mirror.unsent[tostring(proj) .. oid] then return true end -- (as mirror.edited_here: its flag answers first)
  return here[oid] ~= h
end
local kept = live.still_unsent("P1", "I-same,I-edited,T-same,F-chain,I-gone,I-new", mirror, "M", false)
assert(kept == "I-edited,F-chain,I-gone,I-new", "kept: the edited item, a chain (no hash to compare), one gone here, one never sent; got " .. kept)
assert(mirror.unsent["P1I-same"] == nil and mirror.unsent["P2I-same"], "this tab's flags cleared, another tab's left")
assert(live.still_unsent("P1", "", mirror) == "", "nothing unsent: nothing kept")

-- follow_file never adopts a backup or autosave name
for _, f in ipairs({ "C:/S/Demo-autosave.rpp", "C:/S/Backups/Demo.rpp", "C:\\S\\backups\\Demo.rpp", "C:/S/Demo-2026-11-19_1530.rpp",
    "C:/S/Demo_20261119.rpp", "C:/S/Demo.rpp-bak", "C:/S/Demo.RPP-BAK" }) do
  assert(live.backup_name(f), "a backup or autosave: " .. f)
end
for _, f in ipairs({ "C:/S/Demo.rpp", "C:/S/Demo v2.rpp", "C:/S/Demo-02.rpp", "D:\\Songs\\Demo (verse).RPP" }) do
  assert(not live.backup_name(f), "a Save As: " .. f)
end

-- Sync and exit on a second tab of a project syncing in another: found before anything's saved or asked, even with Hold on
package.loaded.rooms = { is_copy = function() return false end }
local elsewhere = "P0"
band.synced_elsewhere = function() return elsewhere end
local cfg, b = { root = "R", user = "Me" }, { song = "Song", room = "main" }
ext["proj hold"] = "1"
leave.start("P2", cfg, b)
assert(leave.job.step == "done" and leave.job.problem == leave.SECOND_COPY, "a second tab: done at once, with the second-copy problem (no Hold question)")
assert(leave.job.problem:find("answer No when REAPER asks", 1, true), "it says to close it without saving")
leave.tick(); leave.tick()
assert(saves == 0 and leave.job.finished, "nothing saved over the syncing tab's file")
elsewhere = nil
leave.start("P2", cfg, b)
assert(leave.job.step == "hold?" and not leave.job.problem, "not a second tab: Hold asks as before")
ext["proj hold"] = nil

-- The box opens again whenever the job is live and it isn't open (shrunk to the box, it went and never came back)
local opened, popup_open = 0, false
local ImGui = setmetatable({
  OpenPopup = function() opened = opened + 1 end,
  IsPopupOpen = function() return popup_open end,
  BeginPopupModal = function() return false end,
}, { __index = function() return function() end end })
leave.start("P2", cfg, b)
leave.draw({}, ImGui, "D")
assert(opened == 1, "opened the first time")
popup_open = true
leave.draw({}, ImGui, "D")
assert(opened == 1, "open: not opened again")
popup_open = false
leave.draw({}, ImGui, "D")
assert(opened == 2, "gone while the job is live: opened again")
leave.job = nil
leave.draw({}, ImGui, "D")
assert(opened == 2, "no job: nothing opened")

-- An error in the feedback window's Send still ends its disabled block and its window
local feedback = require("feedback")
local depth, disabled = 0, 0
local FB = setmetatable({
  Begin = function() depth = depth + 1; return true, true end,
  End = function() depth = depth - 1 end,
  BeginDisabled = function() disabled = disabled + 1 end,
  EndDisabled = function() disabled = disabled - 1 end,
  Button = function(_, l) return l == "Send##fbsend" end,
  InputTextWithHint = function() return false, "It froze" end,
  InputTextMultiline = function() return false, "when I pressed Play" end,
  Checkbox = function(_, _, v) return false, v end,
  GetContentRegionAvail = function() return 400, 300 end,
  CalcTextSize = function() return 10 end,
  GetFrameHeight = function() return 20 end,
  GetFrameHeightWithSpacing = function() return 24 end,
  IsItemHovered = function() return false end,
  BeginCombo = function() return false end,
}, { __index = function() return function() end end })
feedback.button({}, setmetatable({ Button = function() return true end }, { __index = function() return function() end end }))
feedback.save = function() error("disk full") end
feedback.draw({}, FB, { root = "" }, nil)
assert(depth == 0 and disabled == 0, "the window and its disabled block are closed after the error")
assert(logged[#logged]:find("disk full", 1, true), "the error is said")
local n = #logged
feedback.draw({}, FB, { root = "" }, nil)
assert(#logged == n and depth == 0 and disabled == 0, "the same error again: said once")

print("ok")
