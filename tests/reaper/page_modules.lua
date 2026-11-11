-- Run inside REAPER (ReaScript). The panel's pages that live in their own files (the split, 0.58.48 on): each part drawn for one frame in a
-- real ReaImGui window of its own, with the panel's helpers stood in for, on the project in front. What this catches is what a move can break:
-- a name the moved code no longer sees, which Lua only finds when the line runs. (Looks are checked by eye in the panel.)
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
  ctx = ctx, ImGui = ImGui, dir = lib:gsub("/lib/$", ""), ui = { play_shown = function() return false end, short = false, feed = function() end, gradient = function() end, bold = nil },
  card = function() return true end, card_end = function() end, heading = function(t) ImGui.Text(ctx, t) end,
  next_to = function() ImGui.SameLine(ctx) end, action = function() end, logo = function() end, wordmark = function() end,
  section_activity = function() end, cfg = function() return cfg end, wide = function() return false end, b = function() return b end,
  proj = function() return proj end, view = function() return view end, reset_live_server = function() end, go = function() end,
  combo = function(label, cur) ImGui.Text(ctx, tostring(label)); return cur end, describe = function(e) return require("recall").describe(e) end,
  local_time = function(iso) return tostring(iso) end, points = function() return require("recall").list(cfg, b.song, b.room) end,
  can = function() return function() return true end end, who = function() return { mode = "claims" } end, refresh_now = function() end,
  same_room_on = function() return false end, set_same_room = function() end, sonobus_open = function() end, bar_of = function(p) return tostring(p) end,
  check = function(label, v) return ImGui.Checkbox(ctx, label, v) end, sb_link = function() return nil end,
}
-- One part, inside a child of its own in a window of its own: an error halfway through leaves only that child open, which is closed here
-- (else ImGui raised its own error box when the script ended, and that held REAPER: 0.58.50).
local broken = false
local function draw(name, fn)
  if broken then return check(false, name .. ": not drawn, an earlier part broke the frame") end
  ImGui.SetNextWindowSize(ctx, 900, 600)
  if not ImGui.Begin(ctx, "StudioSync page test: " .. name, true) then return check(true, name .. " (window hidden)") end
  local open = ImGui.BeginChild(ctx, "part", 0, 0)
  local ok, e = true, nil
  if open then ok, e = pcall(fn) end
  local closed = open and pcall(ImGui.EndChild, ctx)
  if not ok then -- (a part that failed halfway left its own children open: closed one by one until only the window is left)
    for _ = 1, 20 do if not pcall(ImGui.EndChild, ctx) then break end end
  end
  local ended = pcall(ImGui.End, ctx)
  broken = not ended
  check(ok and not broken, name .. (ok and "" or (": " .. tostring(e))) .. (broken and " (left something open: the frame broke)" or ""))
end
local function page(mod, parts, extra)
  local okm, m = pcall(require, mod)
  if not (okm and m) then return check(false, mod .. " loads: " .. tostring(m)) end
  m.init(env)
  for _, f in ipairs(parts) do draw(mod .. "." .. f, m[f]) end
  if extra then extra(m) end
end
page("page_health", { "maint_rows", "maint_level", "maint_health", "maint_upkeep", "about" },
  function(m) check(#m.maint_rows() > 5, "Health's rows are built (" .. #m.maint_rows() .. ")") end)
page("page_restore", { "section_recall", "section_history" })
page("page_rooms", { "refresh", "squares", "actions", "invites" },
  function(m) check(type(m.view()) == "table" and m.view().room == b.room, "Rooms shows this tab's room") end)
-- (not start_together: it would start the band's transport for real)
page("page_play", { "section_together", "section_live" })
out[#out + 1] = string.format("page_modules: fails %d of %d", fails, #out)
return table.concat(out, "\n")
