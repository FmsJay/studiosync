-- Run inside REAPER (ReaScript). The panel's pages that live in their own files (the split, 0.58.48): each drawn for one frame in a real
-- ReaImGui window, with the panel's helpers stood in for, on the project in front. What this catches is what a move can break: a name the
-- moved code no longer sees, which Lua only finds when the line runs. (Looks are checked by eye in the panel.)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"
for _, m in ipairs({ "band", "page_health", "page_restore", "page_rooms", "page_play" }) do package.loaded[m] = nil end
local band = require("band")
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
local cfg = b and band.for_tab(band.settings(), b)
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
if not (b and cfg) then return "SKIP: the project in front isn't a studio project" end
local ctx = ImGui.CreateContext("StudioSync page test")
local view = { rows = {}, driver = cfg.user }
local env = {
  ctx = ctx, ImGui = ImGui, dir = lib:gsub("/lib/$", ""), ui = { play_shown = function() return false end, short = false, feed = function() end },
  card = function() return true end, card_end = function() end, heading = function(t) ImGui.Text(ctx, t) end,
  next_to = function() ImGui.SameLine(ctx) end, action = function() end, logo = function() end, wordmark = function() end,
  section_activity = function() end, cfg = function() return cfg end, wide = function() return false end, b = function() return b end,
  proj = function() return proj end, view = function() return view end, reset_live_server = function() end, go = function() end,
  combo = function(label, cur) ImGui.Text(ctx, tostring(label)); return cur end, describe = function(e) return require("recall").describe(e) end,
  local_time = function(iso) return tostring(iso) end, points = function() return require("recall").list(cfg, b.song, b.room) end,
  can = function() return function() return true end end, who = function() return { mode = "claims" } end, refresh_now = function() end,
}
ImGui.SetNextWindowSize(ctx, 900, 600)
local visible = ImGui.Begin(ctx, "StudioSync page test", true)
if visible then
  local ok_mods, health = pcall(require, "page_health")
  if ok_mods and health then
    health.init(env)
    for _, f in ipairs({ "maint_rows", "maint_level", "maint_health", "maint_upkeep", "about" }) do
      local ok, e = pcall(health[f])
      check(ok, "Health: " .. f .. (ok and "" or (": " .. tostring(e))))
    end
    check(type(health.maint_rows()) == "table" and #health.maint_rows() > 5, "Health's rows are built (" .. #health.maint_rows() .. ")")
  else check(false, "page_health loads: " .. tostring(health)) end
  local ok_r, restore = pcall(require, "page_restore")
  if ok_r and restore then
    restore.init(env)
    for _, f in ipairs({ "section_recall", "section_history" }) do
      local ok, e = pcall(restore[f])
      check(ok, "Restore: " .. f .. (ok and "" or (": " .. tostring(e))))
    end
  else check(false, "page_restore loads: " .. tostring(restore)) end
  ImGui.End(ctx)
end
out[#out + 1] = string.format("page_modules: fails %d of %d", fails, #out)
return table.concat(out, "\n")
