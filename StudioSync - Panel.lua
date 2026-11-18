-- @description StudioSync: control panel (sync, bandmates, who drives, who owns what, recall points)
-- One dockable window for everything StudioSync does in the project in front: start/stop Live sync, hold
-- it while you try things, see who has what, take control, claim tracks and regions, and save/restore
-- recall points. Needs ReaImGui (ReaPack: "ReaImGui: ReaScript binding for Dear ImGui").
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
band.WHO = "panel" -- (which script a line in the log file came from)
local sync = require("sync")
local recall = require("recall")
local status = require("status")
local tools = require("tools")
local together = require("together")

if not reaper.APIExists("ImGui_GetBuiltinPath") then
  return band.msg("The panel needs ReaImGui. Install it with ReaPack (Extensions > ReaPack > Browse packages: ReaImGui), then run this again.")
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = band.imgui()
if not ImGui then return end

local cfg = band.settings()
if not cfg then return end

if reaper.set_action_options then reaper.set_action_options(1) end -- running it again closes it (no task dialog)
local section, cmd = select(3, reaper.get_action_context())
if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 1); reaper.RefreshToolbar2(section, cmd) end
reaper.DeleteExtState(band.SECTION, "panel_open", true) -- (0.21.5 kept this; Autostart now opens the panel with any StudioSync session)
local restarting = false -- an update landed: a new panel took over, and its toolbar state is on
local closed_here = false -- closed by its own close button or menu (not stopped from outside, as the toolbar button stops it)
-- (the toolbar button on a minimized panel stopped it, so the box was gone and nothing opened: James, 0.58.98. It now asks Autostart to open it
-- again, full: running itself from here, while it stops, isn't reliable)
reaper.atexit(function()
  if package.loaded.colours then pcall(package.loaded.colours.put_back_all) end -- (a look being tried: put back, never left held)
  if cmd > 0 and not restarting then reaper.SetToggleCommandState(section, cmd, 0); reaper.RefreshToolbar2(section, cmd) end
  if not restarting and not closed_here and reaper.GetExtState(band.SECTION, "panel minimized") ~= "" then
    reaper.SetExtState(band.SECTION, "panel reopen", tostring(reaper.time_precise()), false)
  end
end)
-- Opened by hand (the toolbar button, an action), it opens full: only Autostart asks for the tiny box ("panel start small"), and a reload keeps
-- what it was. (It opened as the box or strip it was last left as. James, 0.58.98)
if STUDIOSYNC_PANEL_RELOAD then STUDIOSYNC_PANEL_RELOAD = nil
elseif reaper.GetExtState(band.SECTION, "panel start small") ~= "" then reaper.DeleteExtState(band.SECTION, "panel start small", false)
else reaper.DeleteExtState(band.SECTION, "panel minimized", true) end

local ctx = ImGui.CreateContext("StudioSync")
-- resizable from any edge (a window taller than the screen can still be shrunk from the top). The Window menu
-- (top bar) fills a screen or half of one. Settings can give it the system's frame instead of ReaImGui's (ExtState
-- panel_native = "on"; on Windows that's REAPER's tool-window frame: light caption, no maximize button)
local native = reaper.GetExtState(band.SECTION, "panel_native") == "on"
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsResizeFromEdges, 1)
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, native and 0 or 1)
-- When you click REAPER (James, 0.58.87: "the studiosync doesn't stay in front... default should be it's a separate window or minimizes"):
-- "" (and "box") shrinks to the tiny box when the focus goes elsewhere; "front" stays on top as before; "behind" a window of its own that goes
-- behind REAPER, only where ReaImGui can (ConfigVar_ViewportsNoDefaultParent: not in 0.10.0.5, which keeps every window above REAPER, and
-- the panel stopped on it). A floating panel only: docked, it's part of REAPER.
local behind = reaper.GetExtState(band.SECTION, "panel behind")
-- (asked through pcall: ReaImGui's compatibility layer throws for a name it doesn't have, even just to look)
local can_behind, no_parent = pcall(function() return ImGui.ConfigVar_ViewportsNoDefaultParent end)
can_behind = can_behind and no_parent ~= nil
if behind == "behind" and not can_behind then behind = "" end
if behind == "" then behind = "box" end
if can_behind then ImGui.SetConfigVar(ctx, no_parent, behind == "behind" and 1 or 0) end
local theme = require("theme")
local GREEN, YELLOW, GREY, RED = theme.GREEN, theme.YELLOW, theme.GREY, theme.RED
local function rgba(c) local k = 255 * theme.STATUS; return math.floor(c[1] * k) << 24 | math.floor(c[2] * k) << 16 | math.floor(c[3] * k) << 8 | 0xFF end

-- ---- the look: sidebar pages, cards, pills and switches.
local ui_font = ImGui.CreateFont("sans-serif")
ImGui.Attach(ctx, ui_font)
local ui = {} -- (what's new goes here: the panel's main chunk is at Lua's limit of 200 locals)
ui.bold = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Bold)
ImGui.Attach(ctx, ui.bold)
local ACCENT, CARD, NAV, MUTED, DARK = theme.ACCENT, theme.CARD, theme.NAV, theme.MUTED, theme.DARK
local function push_theme() theme.push(ctx, ImGui) end
local function pop_theme() theme.pop(ctx, ImGui) end

-- A rounded label: status at a glance. `height`: line it up with buttons (their frame height).
local function pill(text, bg, fg, height)
  return ui.pill_draw(text, bg, fg, height)
end
-- A pill after what's on the line, or on the next when it won't fit (people cards: review, 0.59.14).
local function pill_after(text, bg, fg, gap)
  ImGui.SameLine(ctx, 0, gap or 4)
  if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, text) + 16 then ImGui.NewLine(ctx) end
  pill(text, bg, fg)
end
function ui.pill_draw(text, bg, fg, height)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, h = ImGui.CalcTextSize(ctx, text)
  local ph = height or (h + 6)
  ImGui.Dummy(ctx, w + 16, ph)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w + 16, y + ph, bg, ph / 2)
  ImGui.DrawList_AddText(dl, x + 8, y + (ph - h) / 2, fg or DARK, text)
end
-- The sync status as a button of its own (James, 0.58.81): apart from the studio/project/room crumbs (a divider, and outlined rather than filled,
-- so a green "Synced" can't be taken for one more coloured crumb), and when sync is off a solid red that pulses, saying click to start: the
-- button itself starts it (there was a Start button beside it). `can_start`: off, and this tab may sync. -> clicked.
function ui.sync_button(label, colour, running, can_start, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddLine(dl, x - 9, y + 4, x - 9, y + h - 4, MUTED, 1) -- (the divider)
  local text = can_start and "Sync off  -  click to start" or label
  local tw, th = ImGui.CalcTextSize(ctx, text)
  local dot = h * 0.18
  local w = tw + 22 + dot * 2
  local clicked = ImGui.InvisibleButton(ctx, "##syncbtn", w, h)
  local hovered = ImGui.IsItemHovered(ctx)
  if can_start then
    local a = 0.72 + 0.28 * math.abs(math.sin(reaper.time_precise() * 2.6)) -- (a slow pulse: the nudge)
    local fill = (RED & 0xFFFFFF00) | math.floor(255 * (hovered and 1 or a))
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, fill, h / 2)
    ImGui.DrawList_AddRect(dl, x - 2, y - 2, x + w + 2, y + h + 2, (RED & 0xFFFFFF00) | math.floor(120 * (1 - a) + 30), h / 2 + 2, 0, 2)
    ImGui.DrawList_AddCircleFilled(dl, x + 10 + dot, y + h / 2, dot, 0xFFFFFFFF)
    ImGui.DrawList_AddText(dl, x + 14 + dot * 2, y + (h - th) / 2, 0xFFFFFFFF, text)
  else
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, hovered and CARD or (DARK & 0xFFFFFF00) | 0x55, h / 2)
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, colour, h / 2, 0, 1.5)
    ImGui.DrawList_AddCircleFilled(dl, x + 10 + dot, y + h / 2, dot, colour)
    ImGui.DrawList_AddText(dl, x + 14 + dot * 2, y + (h - th) / 2, theme.TEXT, text)
  end
  return clicked and can_start
end
-- An on/off switch: returns changed, new value.
local function switch(id, on)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = ImGui.GetFrameHeight(ctx) - 4
  local w = h * 1.8
  ImGui.SetCursorScreenPos(ctx, x, y + 2)
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  local now = on
  if clicked then now = not on end
  ImGui.DrawList_AddRectFilled(dl, x, y + 2, x + w, y + 2 + h, now and ACCENT or theme.SWITCH_OFF, h / 2) -- (off: light enough to see against a card)
  ImGui.DrawList_AddCircleFilled(dl, now and (x + w - h / 2) or (x + h / 2), y + 2 + h / 2, h / 2 - 3, 0xFFFFFFFF)
  return clicked, now
end
-- A switch with its label; tip shown on hover.
local function switch_row(id, label, on, tip)
  local ch, v = switch(id, on)
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.Text(ctx, label)
  ImGui.PopTextWrapPos(ctx)
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  return ch, v
end
local wide = false -- docked wide and short (see layout): everything a little tighter
local function heading(text, size)
  if ui.short then ImGui.AlignTextToFramePadding(ctx) end -- (level with the boxes and switches that start the other columns)
  ImGui.PushFont(ctx, nil, ui.short and 15 or wide and 17 or (size or 19))
  ImGui.Text(ctx, text)
  ImGui.PopFont(ctx)
end
-- A card: a rounded panel sized to what's in it. Returns true when its content should be drawn (then call card_end).
-- `h`: a fixed height, for cards laid side by side (a self-sizing one always took a row of its own).
local open_cards = 0 -- (cards still open when a frame errors: closed before End, or End itself fails and the panel dies)
local function card(id, w, h)
  local bare = ui.bare_cards -- (a card in a docked column is a box in a box, and the walls cost it 26 px each way)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, bare and 0 or CARD)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, bare and 0 or 14, bare and 0 or ui.short and 7 or 12)
  local open = ImGui.BeginChild(ctx, id, w or 0, h or 0, (h and 0 or ImGui.ChildFlags_AutoResizeY) | ImGui.ChildFlags_AlwaysUseWindowPadding,
    ImGui.WindowFlags_NoScrollbar)
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
  if open then ImGui.PushTextWrapPos(ctx, 0); open_cards = open_cards + 1 end
  return open
end
local function card_end() ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx); open_cards = open_cards - 1 end

-- Blue to orange, by way of violet: straight across, the middle goes grey. t = 0 to 1.
function ui.blue_orange(t, alpha)
  t = math.max(0, math.min(1, t)) * 2
  local from, to = t < 1 and { 0x1E, 0x9B, 0xFF } or { 0xC2, 0x6B, 0xD6 }, t < 1 and { 0xC2, 0x6B, 0xD6 } or { 0xFF, 0x8A, 0x1E }
  local f, c = t < 1 and t or t - 1, 0
  for i = 1, 3 do c = c << 8 | math.floor(from[i] + (to[i] - from[i]) * f + 0.5) end
  return c << 8 | (alpha or 255)
end
-- ReaImGui has no gradient fill, so `draw(colour)` is drawn once per pixel column, clipped to that column.
function ui.gradient(dl, x0, y0, x1, y1, from, to, draw)
  for x = math.floor(x0), math.ceil(x1) - 1 do
    ImGui.DrawList_PushClipRect(dl, x, y0, x + 1, y1, true)
    draw(ui.blue_orange((x + 0.5 - from) / (to - from)))
    ImGui.DrawList_PopClipRect(dl)
  end
end
-- A pill you can press: part of the blue-to-orange, t0 to t1 along it. Returns clicked.
function ui.crumb(text, t0, t1, h, tip)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local tw, th = ImGui.CalcTextSize(ctx, text)
  local w = tw + 16
  local clicked = ImGui.InvisibleButton(ctx, "##crumb" .. t0, w, h)
  local span = w / (t1 - t0)
  local from = x - t0 * span
  ui.gradient(dl, x, y, x + w, y + h, from, from + span, function(col) ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, col, h / 2) end)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, 0xFFFFFFC0, h / 2, 0, 1.5)
  end
  ImGui.DrawList_AddText(dl, x + 8, y + (h - th) / 2, 0x10131AFF, text) -- (dark on these colours in every theme: Light's white was hard to read)
  ImGui.SetItemTooltip(ctx, tip)
  return clicked
end
-- A window button: "line" (to a strip) or "box" (to the small square). Returns clicked.
function ui.window_icon(id, kind, s, tip)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, s, s)
  if ImGui.IsItemHovered(ctx) then ImGui.DrawList_AddRectFilled(dl, x - 2, y - 2, x + s + 2, y + s + 2, theme.BUTTON_HOVER, 4) end
  if kind == "line" then ImGui.DrawList_AddLine(dl, x + s * 0.2, y + s * 0.68, x + s * 0.8, y + s * 0.68, theme.TEXT, 2)
  else ImGui.DrawList_AddRect(dl, x + s * 0.3, y + s * 0.3, x + s * 0.7, y + s * 0.7, theme.TEXT, 2, 0, 1.5) end
  ImGui.SetItemTooltip(ctx, tip)
  return clicked
end
-- The logo: two linked faders, each a plain line with a portal opening from it towards the other fader, blue into orange.
-- Drawn, so it's sharp at any size (docs/logo has it as SVG). `s` = its height; it's 0.93 s wide. Drawn at the cursor, taking that space.
local FLAMES = { { -72, 26, 6, 2, .9 }, { -48, 26, 7, 2.2, .7 }, { -22, 30, 8, 2.6, .9 }, { 8, 28, 6.5, 2.1, .6 }, { 34, 28, 7.5, 2.4, .9 }, { 60, 22, 6, 2, .75 } } -- angle on the rim, how far round, how far out, width, opacity
local function logo(s)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local k = s / 60
  local function X(u) return x + (u - 4) * k end
  local function Y(v) return y + (v - 2) * k end
  local function tint(u, a) return ui.blue_orange((u - 12) / 40, a) end
  local line = ImGui.GetColor(ctx, ImGui.Col_Text)
  for _, flip in ipairs({ false, true }) do
    local own = flip and 1 or 0
    -- worked out for the left fader; the right one is it turned half way round the middle of the mark
    local function P(u, v) if flip then return X(64 - u), Y(64 - v) end return X(u), Y(v) end
    local function rim(deg, rx, ry) local t = math.rad(deg); return 18 + rx * math.cos(t), 32 + ry * math.sin(t) end
    local function half(rx, ry, col, thick) -- the half ellipse from the line
      ImGui.DrawList_PathClear(dl)
      local n = s >= 80 and 40 or 12 -- (more points the bigger it is: at 140 px on Settings its curves showed their corners. James, 0.58.23)
      for i = -n, n do ImGui.DrawList_PathLineTo(dl, P(rim(i * 90 / n, rx, ry))) end
      if thick then ImGui.DrawList_PathStroke(dl, col, ImGui.DrawFlags_None, thick) else ImGui.DrawList_PathFillConvex(dl, col) end
    end
    if s >= 40 then
      for _, f in ipairs(FLAMES) do -- all turning the same way round, so the portal spins
        if s >= 80 or f[5] >= 0.7 then -- (small, the faint ones only scribble)
          local x0, y0 = rim(f[1], 7.5, 25)
          local x1, y1 = rim(f[1] + f[2], 7.5 + f[3], 25 + f[3] * 0.3)
          local n = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
          local px, py, mx, my = -(y1 - y0) / n, (x1 - x0) / n, (x0 + x1) / 2, (y0 + y1) / 2
          local cx, cy = mx - px * f[4], my - py * f[4]
          local m = s >= 80 and 18 or 6
          -- one convex piece, a curve and its chord, filled in one go: drawn as quads side by side, their edges showed as hatching (James, 0.58.25)
          ImGui.DrawList_PathClear(dl)
          for i = 0, m do
            local t, u = i / m, 1 - i / m
            ImGui.DrawList_PathLineTo(dl, P(u * u * x0 + 2 * u * t * cx + t * t * x1, u * u * y0 + 2 * u * t * cy + t * t * y1))
          end
          ImGui.DrawList_PathFillConvex(dl, tint(flip and 64 - mx or mx, math.floor(f[5] * 255)))
        end
      end
    end
    for i = 0, 2 do half(11.5 - i * 1.6, 28 - i, ui.blue_orange(own, 0x24)) end -- its glow
    half(7.5, 25, ui.blue_orange(own, 0x90))
    half(3.2, 22, 0xFFFFFF60)
    half(7.5, 25, ui.blue_orange(own), math.max(1, 1.7 * k))
    local x1, y1 = P(18, 5)
    local x2, y2 = P(18, 59)
    ImGui.DrawList_AddLine(dl, x1, y1, x2, y2, line, math.max(1.5, 3 * k)) -- the fader's own line, on the outside
    if s >= 30 then -- its scale, long and short like a console's (too small, it's only fuzz)
      for n = 0, 8 do
        local v, big = 8 + n * 6, n % 2 == 0
        local ax, ay = P(15, v)
        local bx, by = P(big and 7 or 10.5, v)
        ImGui.DrawList_AddLine(dl, ax, ay, bx, by, big and line or (line & 0xFFFFFF00 | 0xBF), math.max(1, 1.5 * k))
      end
    end
  end
  local px, py
  local n = s >= 80 and 40 or 16
  for i = 0, n do -- the link: 18,20 to 46,44, as one S
    local t, u = i / n, 1 - i / n
    local bx = u * u * u * 18 + 3 * u * u * t * 32 + 3 * u * t * t * 32 + t * t * t * 46
    local by = u * u * u * 20 + 3 * u * u * t * 20 + 3 * u * t * t * 44 + t * t * t * 44
    if px then
      ImGui.DrawList_AddLine(dl, X(px), Y(py), X(bx), Y(by), tint(bx, 0x50), 5.5 * k)
      ImGui.DrawList_AddLine(dl, X(px), Y(py), X(bx), Y(by), tint(bx), 3.4 * k)
      if i < n then ImGui.DrawList_AddCircleFilled(dl, X(bx), Y(by), 1.7 * k, tint(bx)) end -- (the joints: dark pinholes between pieces, big)
    end
    px, py = bx, by
  end
  for _, c in ipairs({ { 8, 14 }, { 36, 38 } }) do -- the fader caps
    ui.gradient(dl, X(c[1]), Y(c[2]), X(c[1] + 20), Y(c[2] + 12), X(12), X(52), function(col)
      ImGui.DrawList_AddRectFilled(dl, X(c[1]), Y(c[2]), X(c[1] + 20), Y(c[2] + 12), col, 3.5 * k)
    end)
    ImGui.DrawList_AddRectFilled(dl, X(c[1] + 2), Y(c[2] + 5), X(c[1] + 18), Y(c[2] + 7), 0xFFFFFFFF, k)
  end
  ImGui.Dummy(ctx, s * 0.93, s)
end
-- The wordmark: Studio, then Sync in blue to orange.
local function wordmark(size)
  ImGui.PushFont(ctx, nil, size)
  local _, y = ImGui.GetCursorScreenPos(ctx) -- (each piece on the same baseline: SameLine goes back to the line's top)
  ImGui.Text(ctx, "Studio")
  ImGui.SameLine(ctx, 0, 0)
  local x = ImGui.GetCursorScreenPos(ctx)
  ImGui.SetCursorScreenPos(ctx, x, y)
  local w, h = ImGui.CalcTextSize(ctx, "Sync")
  local dl, font = ImGui.GetWindowDrawList(ctx), ImGui.GetFont(ctx)
  ui.gradient(dl, x, y, x + w, y + h, x, x + w, function(col) ImGui.DrawList_AddTextEx(dl, font, size, x, y, col, "Sync") end)
  ImGui.Dummy(ctx, w, h)
  ImGui.PopFont(ctx)
end
-- The panel as a small square ("1"), or a strip with words ("strip"), over REAPER (pill_window), kept across restarts.
function ui.set_minimized(on)
  -- (the focus starts afresh each way: minimized with its button, the panel kept "had the focus", opened again without it, and shrank straight
  -- back to the box: the box or strip seemed not to open, after the toolbar button above all. James, 0.58.98)
  ui.had_focus = nil
  if on then reaper.SetExtState(band.SECTION, "panel minimized", on == "strip" and "strip" or "1", true)
  else
    reaper.DeleteExtState(band.SECTION, "panel minimized", true)
    ui.focus_req, ui.opened_at = true, reaper.time_precise()
  end
end
-- Should the panel shrink to the box now the focus has gone? Only for a REAPER window it was in front of (James, 0.58.98: "clicking onto other
-- windows shouldn't minimize studiosync, only clicking onto another reaper window that would have been blocked by it"): another app, a
-- dialog or menu (StudioSync's own boxes made it vanish), a click on the panel itself, or a REAPER window it doesn't cover (it's on another
-- monitor) leave it open. Without js_ReaScriptAPI, any REAPER window counts, as before.
function ui.should_hide(rect)
  -- (where the mouse really is: ImGui's own position stays where it last was over the panel, so every click away read as one on it)
  local mx, my = reaper.GetMousePosition()
  if ImGui.PointConvertNative then mx, my = ImGui.PointConvertNative(ctx, mx, my) end
  if rect and mx >= rect[1] and mx <= rect[1] + rect[3] and my >= rect[2] and my <= rect[2] + rect[4] then return false end -- (a click on it)
  if not reaper.JS_Window_GetForeground then return true end
  local fg = reaper.JS_Window_GetForeground()
  if not fg then return false end
  local class = reaper.JS_Window_GetClassName and reaper.JS_Window_GetClassName(fg) or ""
  if class == "#32770" or class == "#32768" then return false end -- (a dialog box, a menu: Windows' own classes)
  local main = reaper.GetMainHwnd()
  local mine = fg == main or (reaper.JS_Window_GetParent and reaper.JS_Window_GetParent(fg) == main)
  if not mine then return false end -- (another app)
  local title = reaper.JS_Window_GetTitle and reaper.JS_Window_GetTitle(fg) or ""
  if title:find("StudioSync", 1, true) then return false end -- (one of its own windows)
  if not (rect and reaper.JS_Window_GetRect and ImGui.PointConvertNative) then return true end
  local ok, l, t, r, bt = reaper.JS_Window_GetRect(fg)
  if not ok then return true end
  local x1, y1 = ImGui.PointConvertNative(ctx, l, t)
  local x2, y2 = ImGui.PointConvertNative(ctx, r, bt)
  x1, x2 = math.min(x1, x2), math.max(x1, x2)
  y1, y2 = math.min(y1, y2), math.max(y1, y2)
  return x1 < rect[1] + rect[3] and x2 > rect[1] and y1 < rect[2] + rect[4] and y2 > rect[2] -- (it covers part of that window)
end
local reload_now, dock_req, dock_side -- (Settings: switching the window frame reopens the panel; Dock / Undock; the side its new docker goes to)
local placed_from, placed_how -- where the window was before the Window menu moved it (screen pixels), and how it's placed
local banner_docked -- (docked, the panel never covers the arrange view)
local place_req, win_rect -- a placement for the next frame (ReaImGui units); the window as ReaImGui last drew it
local WINDOW_MENU = { "Fill this screen", "Left half", "Right half", "Top half", "Bottom half", "Move to the next screen", "Back to before" }
local function place_window(how)
  if how == "Dock" or how == "Undock" then dock_req = how == "Dock" and -1 or 0; return end -- (asked for from a script)
  local sw, sh = how:match("^size (%d+) (%d+)$") -- (likewise)
  if sw and win_rect then place_req = { win_rect[1], win_rect[2], tonumber(sw), tonumber(sh) }; return end
  local h = reaper.JS_Window_Find and reaper.JS_Window_Find("StudioSync", true)
  if not h then return band.msg("Placing the window needs js_ReaScriptAPI (ReaPack: 'js_ReaScriptAPI').") end
  local _, l, t, r, btm = reaper.JS_Window_GetRect(h)
  -- moving the system window from outside only stretches what ReaImGui drew: ReaImGui sizes its windows itself, so
  -- the screen's pixels are turned into its units (they differ with display scaling) and it places the window
  local function req(x, y, w, hh)
    if not win_rect or r - l <= 0 then return end
    local sx, sy = (r - l) / win_rect[3], (btm - t) / win_rect[4]
    place_req = { win_rect[1] + (x - l) / sx, win_rect[2] + (y - t) / sy, w / sx, hh / sy }
  end
  if how == "Back to before" then
    if placed_from then req(table.unpack(placed_from)); placed_from = nil end
    placed_how = nil
    return
  end
  placed_how = how
  placed_from = placed_from or { l, t, r - l, btm - t }
  local L, T, R, B = reaper.JS_Window_GetViewportFromRect(l, t, r, btm, true) -- the screen it's on, without the taskbar
  if how == "Move to the next screen" then -- the screen to the right (else the left), filled
    local my = (T + B) // 2
    local nL, nT, nR, nB = reaper.JS_Window_GetViewportFromRect(R + 20, my, R + 21, my + 1, true)
    if nL == L then nL, nT, nR, nB = reaper.JS_Window_GetViewportFromRect(L - 21, my, L - 20, my + 1, true) end
    if nL == L then return band.msg("There's only one screen.") end
    L, T, R, B = nL, nT, nR, nB
    placed_how = "Fill this screen"
  end
  local W, H = R - L, B - T
  local x, y, w, hh = L, T, W, H
  if how == "Left half" then w = W // 2
  elseif how == "Right half" then x, w = L + W // 2, W - W // 2
  elseif how == "Top half" then hh = H // 2
  elseif how == "Bottom half" then y, hh = T + H // 2, H - H // 2 end
  req(x, y, w, hh)
end
-- An on/off option.
local function check(label, v, tip)
  local ch, nv = switch_row("##" .. label, label, v, tip)
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  return ch, nv
end
-- Next to the last item if `label`'s button still fits on this line, else on the next one (narrow or docked panels).
local function next_to(label) -- (or a width: a box's isn't its words')
  ImGui.SameLine(ctx)
  if ImGui.GetContentRegionAvail(ctx) < (type(label) == "number" and label or ImGui.CalcTextSize(ctx, label) + 36) then ImGui.NewLine(ctx) end
end

-- Tooltips for controls that don't set their own, by label (a control's own tooltip, set after it, wins).
local TIPS = {
  ["Start"] = "Start Live sync in this tab: your takes and changes go out, the studio's come in.",
  ["Update"] = "Get the newest StudioSync through ReaPack.",
  ["Take control now"] = "The driver isn't here: carry on as the driver (they can take it back when they return).",
  ["Release all claims"] = "Let go of all your claims: everything follows the driver again.",
  ["##label"] = "A name for this version, then Save this version.",
  ["Save this version"] = "Save how the session is now (takes, where they sit, what plays) as a version anyone can go back to.",
  ["Update the folder now"] = "Send your plug-in list and rebuild the FX browser folder 'StudioSync (everyone has)' now.",
  ["Play along (synced to the project)"] = "Hear each other in time with the project, at any distance (a bar or two late). Needs the studio's NINJAM server.",
  ["Real time (SonoBus, lowest delay)"] = "Hear each other right away, peer to peer (best on wired internet, not too far apart).",
  ["Jam (NINJAM intervals)"] = "Classic NINJAM: everyone hears everyone one interval late.",
  ["Leave"] = "Leave: SonoBus stops (it stays on its track, sending nothing) or ReaNINJAM disconnects.",
  ["##server"] = "The host's Tailscale name and NINJAM port, e.g. my-pc.tail1234.ts.net:2049.",
  ["Save for the studio"] = "Everyone's Connect uses this address.",
  ["Send my audio (my whole mix)"] = "Off: you listen without sending anything.",
  ["Connect"] = "Join the studio's live audio in the mode above.",
  ["Show it"] = "Open ReaNINJAM's own window. It runs out of sight otherwise: you don't need it.",
  ["Clear"] = "Empty this activity list.",
  ["Open the full console"] = "REAPER's script console, with everything StudioSync has said.",
  ["start from"] = "Where everyone starts: the edit cursor or a region.",
  ["count-in bars"] = "Bars of count-in before the start point.",
  ["Play together"] = "Everyone running Live sync starts playing from the same point at the same moment (5 s after you click).",
  ["Stop together"] = "Everyone stops.",
  ["##note"] = "A note for everyone: on the selected take, or at the cursor. Everyone sees it on the timeline and on the Restore page.",
  ["Note on selected take"] = "Post the note on the selected take (a take marker everyone sees).",
  ["Note at cursor"] = "Post the note at the edit cursor.",
  ["Like selected take"] = "Tell everyone you like the selected take.",
  ["##newroom"] = "A name for a new side room.",
  ["Go"] = "Go to the room they're asking you to.",
  ["Not now"] = "Hide this invitation.",
  ["Come see!"] = "Ask everyone with this project open to come to this room.",
}
ImGui.SetItemTooltip = function(c, text)
  if ImGui.BeginItemTooltip(c) then
    ImGui.PushTextWrapPos(c, ImGui.GetFontSize(c) * 26)
    ImGui.Text(c, text)
    ImGui.PopTextWrapPos(c)
    ImGui.EndTooltip(c)
  end
end
for _, name in ipairs({ "Button", "SmallButton", "Checkbox", "InputInt", "InputText", "InputTextWithHint", "BeginCombo", "RadioButton", "Selectable", "TreeNodeEx" }) do
  local f = ImGui[name]
  ImGui[name] = function(c, label, ...)
    local r = table.pack(f(c, label, ...))
    if ui.clipped then -- (asked for by tools/panel_sizes.py: what runs off the right of its window)
      local wx, ww = ImGui.GetWindowPos(c), ImGui.GetWindowSize(c)
      if ImGui.GetItemRectMax(c) > wx + ww + 0.5 then ui.clipped[tostring(label)] = true end
    end
    local t = type(label) == "string" and (TIPS[label] or TIPS[(label:gsub("##.*$", ""))])
    if t then ImGui.SetItemTooltip(c, t) end
    return table.unpack(r, 1, r.n)
  end
end

-- Actions run as REAPER actions (so they see their own action context), registered on first use.
local ids = {}
local function action(name)
  if not ids[name] or ids[name] == 0 then ids[name] = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - " .. name .. ".lua", true) end
  if ids[name] > 0 then reaper.Main_OnCommand(ids[name], 0)
  else band.log("couldn't register 'StudioSync - " .. name .. "' as an action (is the Scripts folder read-only?)") end -- (it did nothing, silently. 0.58.92)
end

local proj, b, view, can, who, points, last, err = nil, nil, nil, nil, nil, {}, 0, nil
local bars_said -- (an error in the bars above the page, said once)
local banner_text -- what the banner over REAPER says while someone else drives (set with the view, drawn by banner())
local label = ""
local function refresh()
  proj = reaper.EnumProjects(-1)
  b = band.binding(proj)
  -- the front tab's own band (two bands' songs can be open at once), on this computer's settings as they are now:
  -- an installer, or another panel, may have switched the band since this one started (laptop, 0.35.1)
  local now_root, now_user = reaper.GetExtState(band.SECTION, "sync_root"), reaper.GetExtState(band.SECTION, "user")
  cfg = band.for_tab(now_root ~= "" and now_user ~= "" and { root = now_root, user = now_user } or cfg, b)
  banner_text = nil -- (a tab that isn't a band session has no banner: it showed over a new empty tab)
  if not b then return end
  view = status.gather(cfg, b, proj)
  view.group = band.info(cfg.root).name
  can, who = sync.authority(cfg, b.song, b.room, view.session)
  require("people").mine(cfg) -- (your colour, the same in every studio you're in: lib/people.lua)
  local here = false -- the driver is someone else, and they're here
  for _, r in ipairs(view.rows) do if r.name == view.driver and r.age < 45 then here = true end end
  if here and view.driver ~= cfg.user and reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) == "" then
    local mine = 0
    for _, c in pairs(who.tracks) do if c.user == cfg.user then mine = mine + 1 end end
    for _, c in pairs(who.regions) do if c.user == cfg.user then mine = mine + 1 end end
    for _, t in ipairs(who.times or {}) do if t.user == cfg.user then mine = mine + 1 end end
    -- (open: no banner; "x and nil or y" can't say that in Lua, it gives y)
    if who.mode == "driver" then banner_text = "View only: " .. view.driver .. " is driving. Your changes are put back; what you record stays on this computer."
    elseif who.mode == "admins" and not require("groups").may_manage(cfg.root, cfg.user) then
      banner_text = mine > 0 and "Admins only: you can change what you've been given." or "View only: admins only here. Your changes are put back; what you record stays on this computer."
    elseif who.mode == "claims" then
      -- (tracks you made and nobody has claimed are yours to change too, so "view only" wasn't true: sync.maker_may)
      local made = false
      for i = 0, reaper.CountTracks(proj) - 1 do
        local tr = reaper.GetTrack(proj, i)
        local name = sync.base_name(select(2, reaper.GetTrackName(tr)))
        made = made or (not who.tracks[name:lower()] and require("mirror").is_creator(require("mirror").track_oid(tr), cfg.user))
      end
      banner_text = (mine > 0 or made) and (view.driver .. " is driving: you can change what you've claimed or made.")
        or ("View only: " .. view.driver .. " is driving. Claim a track (StudioSync, Home) to edit it.")
    end
  end
  points = recall.list(cfg, b.song, b.room)
end

-- History: re-read only while its tab is open, and not every frame.
local just_looked = {} -- backup tabs someone chose only to look at. (Not by pointer alone: REAPER gives a new tab a closed one's: Mac, 0.58.4)
local utc_offset -- shortcut: fixed at start, a DST change mid-session shows an hour off
do local t = os.date("!*t"); t.isdst = false; utc_offset = os.time() - os.time(t) end
local function local_time(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return "?" end
  return os.date("%m-%d %H:%M", os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }) + utc_offset)
end

-- The bar a time falls in, from the tempo map (the displayed position rounds 4.999 s up into the next bar).
local function bar_num(pos) return select(2, reaper.TimeMap2_timeToBeats(proj, pos)) + 1 end
-- "bar 2" / "bars 9-10" for a stretch of time; an end on a bar line doesn't include that bar
local function bar_span(from, to)
  local a, z = bar_num(from + 1e-6), bar_num(to - 1e-6)
  return a == z and ("bar " .. a) or ("bars " .. a .. "-" .. z)
end
local function bar_of(pos) -- "5", or "5 beat 3" off the bar line
  local bar, beat = reaper.format_timestr_pos(pos, "", 2):match("^(%d+)%.(%d+)")
  return beat == "1" and bar or (bar .. " beat " .. beat)
end

-- What a track is called for ownership: a "(MIDI)" copy track and a "(studio)" mirror belong to their part.
local function part_name(tr)
  local m = band.track_ext(tr, "band_midi_track")
  return m ~= "" and m or sync.base_name(select(2, reaper.GetTrackName(tr)))
end
local function claim(tracks, regions)
  local c, why = sync.my_claims(cfg, b.song, b.room)
  if not c then return band.msg(why) end
  c.tracks, c.regions = c.tracks or {}, c.regions or {}
  local function add(list, name)
    for _, n in ipairs(list) do if n:lower() == name:lower() then return end end
    list[#list + 1] = name
  end
  for _, n in ipairs(tracks) do add(c.tracks, n) end
  for _, n in ipairs(regions) do add(c.regions, n) end
  sync.set_claims(cfg, b.song, b.room, c)
end

local function section_sync()
  ImGui.SeparatorText(ctx, "Sync")
  local key = tostring(proj)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
  local running = beat and reaper.time_precise() - beat < 5
  ImGui.TextColored(ctx, running and GREEN or RED, running and "Live sync is running" or "Live sync is not running")
  if not running and band.synced_elsewhere(proj) then -- (a second copy of the song: syncing it would work on a stale one)
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, YELLOW, "this project is open and syncing in another tab: work there")
  elseif not running then -- (no Stop: a StudioSync project always syncs, or the band's copies drift apart)
    ImGui.SameLine(ctx)
    if not require("rooms").is_copy(proj, cfg, b) and ImGui.SmallButton(ctx, "Start") then reaper.DeleteExtState(band.SECTION, "stop " .. key, false); band.start_live(dir) end
  end
  if not tools.autostart_on(dir) and not tools.autostart_tried then -- always on: StudioSync projects start Live sync with REAPER
    tools.autostart_tried = true
    pcall(tools.toolbar_default) -- (and the toolbar button, on unless switched off: 0.58.82)
    if not tools.set_autostart(true, dir) then band.log("couldn't add StudioSync to Scripts/__startup.lua: Live sync won't start with REAPER") end
  end
  if view.newer then
    -- already on disk (an update, or a bandmate's folder install)? Then only this running panel is old
    -- (read once in 3 s, not every frame while a bandmate runs a newer version: review, 0.58.87)
    if not ui.disk_at or reaper.time_precise() - ui.disk_at > 3 then
      ui.disk_at, ui.disk_ver = reaper.time_precise(), (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
    end
    local disk = ui.disk_ver
    if disk == view.newer then
      ImGui.TextColored(ctx, YELLOW, "StudioSync " .. disk .. " is installed: close and reopen this panel to use it.")
    else
      ImGui.TextColored(ctx, YELLOW, "StudioSync " .. view.newer .. " is in use here; you have " .. band.VERSION .. ".")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Update##banner") then action("Update") end -- "##": same label as More's Update, its own ID
    end
  end
end


local drive_root, drive_at = nil, -math.huge
local MODE_INFO = { -- (the names on disk are older than these: sync.MODES)
  { "open", "Claims", "Anyone changes anything nobody else has claimed, the tempo map and markers too. What someone has claimed (a track,\n" ..
    "a region, a stretch of time) only they change, the driver too. If two change one thing at once, whoever changed it more wins,\nand the other person gets a Use mine button to put theirs back." },
  { "claims", "Driver + claims", "The driver changes anything, claimed or not. Everyone else changes what they've claimed. Other changes are put back." },
  { "driver", "Driver only", "Only the driver changes what the studio has. Everyone else's changes are put back (record as usual)." },
  { "everyone", "Everyone", "Anyone changes anything, claimed or not: claims don't hold. If two change one thing at once, whoever changed it more wins,\n" ..
    "and the other person gets a Use mine button to put theirs back." },
  { "admins", "Admins only", "Only the studio's owner and admins change what the studio has, and anyone on what an admin gave them (right-click their name). Other changes are put back." },
}
local function section_driver(beside) -- beside: drawn on the box's row (a short docker has no row to spare)
  local driving = view.driver == cfg.user
  local mode = who.mode or sync.DEFAULT_MODE
  local may_set = require("groups").may_manage(cfg.root, cfg.user) -- (the studio's owner and admins only: James, 0.58.82)
  local cur = MODE_INFO[1]
  for _, m in ipairs(MODE_INFO) do if m[1] == mode then cur = m end end
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Who controls")
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not may_set)
  -- (as wide as its longest choice: a fixed 170 cut the name off on a Mac, whose text draws wider. James, 0.58.73)
  local cw = 0
  for _, m in ipairs(MODE_INFO) do cw = math.max(cw, (ImGui.CalcTextSize(ctx, m[2]))) end
  ImGui.SetNextItemWidth(ctx, cw + ImGui.GetFrameHeight(ctx) + 16)
  if ImGui.BeginCombo(ctx, "##whocontrols", cur[2]) then
    for _, m in ipairs(MODE_INFO) do
      if ImGui.Selectable(ctx, m[2], m[1] == mode) and m[1] ~= mode then
        sync.set_mode(cfg, b.song, b.room, m[1], cfg.user)
        band.log("editing in '" .. b.room .. "' is now " .. m[2] .. ": " .. m[3])
        last = 0
      end
      ImGui.SetItemTooltip(ctx, m[3])
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, cur[3] .. (may_set and "" or "\nThe studio's owner or an admin picks this."))
  if not may_set then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "the owner or an admin picks") end
  if beside then beside() end
  if driving or reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) == "" then -- (alone, "James is driving" sat right above "you have full control": Mac, 0.57.6)
    local yours = ({ claims = "You're driving: you change anything, claimed or not.", driver = "You're driving: only you change things." })[mode] or "You're driving."
    ImGui.Text(ctx, driving and yours or (tostring(view.driver) .. " is driving."))
  end
  local away = reaper.GetExtState(band.SECTION, "driver_away " .. tostring(proj))
  if away ~= "" and not driving then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, YELLOW, away .. " is driving but isn't here, so only claimed tracks can change. Take control to carry on " ..
      "(they can take it back when they return).")
    ImGui.PopTextWrapPos(ctx)
    if ImGui.Button(ctx, "Take control now") then action("Take control") end
  end
  if reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) ~= "" then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, GREEN, "Nobody else is here: you have full control. Everything you change goes to the others, and reaches " ..
      "them when they're back. When someone joins, the rules above apply again.")
    ImGui.PopTextWrapPos(ctx)
  end
end
local function section_drive()
  local drive = require("drive")
  ImGui.SeparatorText(ctx, "Cloud copy")
  if reaper.time_precise() - drive_at > 30 then drive_at = reaper.time_precise(); drive_root = drive.root(cfg) end
  do -- which cloud drive (James, 0.58.79: Dropbox and others, not only Google Drive)
    local svc = drive.service()
    ImGui.SetNextItemWidth(ctx, 190)
    if ImGui.BeginCombo(ctx, "##driveservice", svc == "" and "Whichever is here" or drive.label(svc)) then
      if ImGui.Selectable(ctx, "Whichever is here", svc == "") then reaper.DeleteExtState(band.SECTION, "drive service", true); drive.forget(); drive_at = -math.huge end
      for _, s in ipairs(drive.SERVICES) do
        if ImGui.Selectable(ctx, s[2], svc == s[1]) then reaper.SetExtState(band.SECTION, "drive service", s[1], true); drive.forget(); drive_at = -math.huge end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SetItemTooltip(ctx, "The cloud drive the studio's copy lives in: Google Drive, Dropbox, OneDrive, iCloud Drive or Box, with its desktop app\n" ..
      "installed and signed in. Whichever is here: the first one with the studio's folder, Google Drive first. Everyone uses the one the studio's owner shared it in.")
  end
  local off = reaper.GetExtState(band.SECTION, "drive_root") == "off"
  local dch, don = check("Keep the studio's copy on " .. drive.name(cfg), drive_root ~= nil)
  if dch then reaper.SetExtState(band.SECTION, "drive_root", don and "" or "off", true); drive_at = -math.huge end
  local mch, mon = check("Make a cloud folder for each studio I start", drive.wanted(),
    "On, each studio you start gets its folder in your cloud drive. You share it with the others there. Off: nothing's made, and you can make one here later.")
  if mch then reaper.SetExtState(band.SECTION, "drive make", mon and "" or "off", true) end
  ImGui.SetItemTooltip(ctx, drive_root and ("Each room is copied to " .. drive_root .. " (every few minutes, while stopped): what someone " ..
    "does alone reaches the studio whenever they next open the project, and every end-of-session saved version is kept there.")
    or off and "Off on this machine." or ("No " .. drive.name(cfg) .. " folder found here (is its desktop app installed and signed in?)."))
  if drive_root then -- (which account's Drive it is, in view: with several signed in it matters; Mac, 0.34.5)
    ImGui.TextDisabled(ctx, "Copies to " .. drive.name(cfg) .. ": " .. (drive_root:match("GoogleDrive%-([^/]+)/") or drive_root:match("^(%a:)") or drive_root))
    ImGui.SetItemTooltip(ctx, drive_root)
  end
  local missing = not drive_root and not off and drive.missing
  if missing then
    local folder = band.info(cfg.root).drive
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, YELLOW, "No " .. folder .. " folder in " .. missing .. ". " .. drive.share_hint(cfg, folder) .. " You started this studio? " ..
      "Make a folder called " .. folder .. " there and share it with everyone, able to edit.")
    ImGui.PopTextWrapPos(ctx)
    if require("groups").role(cfg.root, cfg.user) == "owner" and ImGui.SmallButton(ctx, "Make it now") then
      local made = drive.make(folder)
      band.log(made and ("made " .. folder .. " in your " .. drive.name(cfg) .. ": share it with the others there, able to edit") or "no cloud drive found here")
      drive_at = -math.huge
    end
  end
end
-- Two computers' fingerprints differ for 10-15 s after any edit (each publishes its own every few seconds, and the
-- print follows the notes), and red then read as a failed sync (James, 2026-11-01). Red once they've stayed apart 30 s.
local apart = {} -- bandmate -> { key = their fingerprint and ours, since = when that pair first showed }
local function settled_apart(p, mine)
  local key, a = p.mirror .. mine, apart[p.name]
  if not a or a.key ~= key then a = { key = key, since = reaper.time_precise() }; apart[p.name] = a end
  return reaper.time_precise() - a.since >= 30
end
local tabs_at = 0 -- where the page tabs start: the widest the bar beside them has been
-- Every claim there is, or one person's: { full words, what kind if it's mine (for releasing it), what, user, short words }.
function ui.claims_of(user)
  local owned, here = {}, {} -- (a claim on a track that isn't there isn't listed: its owner drops it, sync.drop_gone_claims)
  for i = 0, reaper.CountTracks(proj) - 1 do here[sync.base_name(select(2, reaper.GetTrackName(reaper.GetTrack(proj, i)))):lower()] = true end
  local function add(full, kind, what, u, short)
    if not user or u == user then owned[#owned + 1] = { full, u == cfg.user and kind, what, user = u, short = short } end
  end
  for name, c in pairs(who.tracks) do
    if here[name] then add(string.format("track %s: %s", c.name or name, c.user), "tracks", c.name or name, c.user, c.name or name) end
  end
  for name, c in pairs(who.regions) do add(string.format("region %s: %s", c.name or name, c.user), "regions", c.name or name, c.user, "region " .. (c.name or name)) end
  for _, t in ipairs(who.times or {}) do add(string.format("%s: %s", bar_span(t.from, t.to), t.user), "times", t, t.user, bar_span(t.from, t.to)) end
  table.sort(owned, function(x, y) return x[1] < y[1] end)
  return owned
end
-- chips: yours blue with an x that releases it, others' grey; they wrap like words
function ui.claim_chips(owned, short)
  local function release(o) -- let go of just this one
    local c, why = sync.my_claims(cfg, b.song, b.room)
    if not c then return band.msg(why) end
    local keep = {}
    for _, n in ipairs(c[o[2]] or {}) do
      local same = o[2] == "times" and math.abs(n.from - o[3].from) < 1e-6 and math.abs(n.to - o[3].to) < 1e-6
        or o[2] ~= "times" and n:lower() == o[3]:lower()
      if not same then keep[#keep + 1] = n end
    end
    c[o[2]] = keep
    sync.set_claims(cfg, b.song, b.room, c)
  end
  local avail, used = ImGui.GetContentRegionAvail(ctx), 0
  local h = ImGui.GetFrameHeight(ctx) - 2
  for i, o in ipairs(owned) do
    local words = short and o.short or o[1]
    local w = ImGui.CalcTextSize(ctx, words) + 18 + (o[2] and 16 or 0)
    if i > 1 and used + w + 6 <= avail then ImGui.SameLine(ctx, 0, 6) else used = 0 end
    used = used + w + 6
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local dl = ImGui.GetWindowDrawList(ctx)
    ImGui.InvisibleButton(ctx, "##chip" .. i, w, h)
    local hovered = ImGui.IsItemHovered(ctx)
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, o[2] and theme.CHIP_MINE or theme.CHIP_OTHER, h / 2)
    ImGui.DrawList_AddText(dl, x + 9, y + (h - ImGui.GetTextLineHeight(ctx)) / 2, theme.TEXT, words)
    if o[2] then
      local over_x = hovered and select(1, ImGui.GetMousePos(ctx)) >= x + w - 22
      local cx, cy, r = x + w - 12, y + h / 2, 3.5
      local col = over_x and RED or MUTED
      ImGui.DrawList_AddLine(dl, cx - r, cy - r, cx + r, cy + r, col, 1.6)
      ImGui.DrawList_AddLine(dl, cx - r, cy + r, cx + r, cy - r, col, 1.6)
      if over_x and ImGui.IsItemClicked(ctx, 0) then release(o) end
      ImGui.SetItemTooltip(ctx, over_x and "Release it: it follows the driver again." or "Yours: only you change it, whoever drives.")
    else
      ImGui.SetItemTooltip(ctx, "Theirs: only they change it, whoever drives.")
    end
  end
end
-- Someone about to leave (lib/removal.lua): a minute to change your mind.
function ui.leaving_row(p)
  local groups, removal = require("groups"), require("removal")
  local m = p.user ~= cfg.user and removal.mark(cfg.root, p.user)
  if not m then return end
  ImGui.TextColored(ctx, YELLOW, string.format("Leaving the studio in %d s", math.max(0, removal.GRACE - (os.time() - (tonumber(m.at) or 0)))))
  if groups.may_manage(cfg.root, cfg.user) then
    next_to("Keep them")
    if ImGui.SmallButton(ctx, "Keep them##" .. p.user) then removal.keep(cfg.root, p.user) end
    ImGui.SetItemTooltip(ctx, "Changed your mind: nothing has happened yet.")
  end
end
-- Right-click a name: what you may do about them.
function ui.person_menu(p)
  local groups, removal = require("groups"), require("removal")
  local me = cfg.user
  if not ImGui.BeginPopupContextItem(ctx, "person " .. p.user) then return end
  ImGui.TextDisabled(ctx, p.user)
  if p.user == me then
    if ImGui.Selectable(ctx, "Change my name, colour...") then ui.go_settings("You") end
    ImGui.EndPopup(ctx)
    return
  end
  local mine, theirs, any = groups.role(cfg.root, me), groups.role(cfg.root, p.user), false
  if mine == "owner" then
    any = true
    if ImGui.Selectable(ctx, theirs == "admin" and "Make member..." or "Make admin...") then
      local on = theirs ~= "admin"
      if reaper.MB(on and ("Make " .. p.user .. " an admin of " .. tostring(view.group) .. "?\n\nThey can let people in, rename the studio, remove members and give claims. Only you can close it.")
          or ("Make " .. p.user .. " a member again?\n\nThey can't let people in, rename the studio or remove anyone any more."), "StudioSync", 4) == 6 then
        groups.set_admin(cfg.root, me, p.user, on)
        band.log(p.user .. (on and " is an admin now: they can let people in, rename the studio, remove members and give claims" or " is a member again"))
      end
    end
    if ImGui.Selectable(ctx, "Make owner...") and reaper.MB("Make " .. p.user .. " the owner of " .. tostring(view.group) .. "?\n\nYou stay on as an admin. Only they can give it back.", "StudioSync", 4) == 6 then
      groups.hand_over(cfg.root, me, p.user)
      band.log(p.user .. " owns " .. tostring(view.group) .. " now, and you're an admin")
    end
  end
  if view.driver == me and p.state ~= "offline" then
    any = true
    if ImGui.Selectable(ctx, "Hand over driving...") and reaper.MB("Make " .. p.user .. " the driver?", "StudioSync", 4) == 6 then
      sync.hand_over(proj, cfg, b.song, b.room, p.user); last = 0
    end
  end
  if groups.may_manage(cfg.root, me) then
    any = true
    if ImGui.BeginMenu(ctx, "Give them control of") then
      local n = reaper.CountSelectedTracks(proj)
      local give = function(words, tracks, regions, times)
        if reaper.MB("Give " .. p.user .. " " .. words .. " to change?\n\nIf someone else has it claimed, it moves to " .. p.user .. ".", "StudioSync", 4) == 6 then
          sync.give_claims(cfg, b.song, b.room, p.user, tracks, regions, times)
          band.log("gave " .. p.user .. " " .. words)
          last = 0
        end
      end
      if ImGui.MenuItem(ctx, n == 1 and "Selected track" or "Selected tracks", nil, false, n > 0) then
        local list = {}
        for i = 0, n - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
        give(table.concat(list, ", "), list)
      end
      local rg = ui.selected_regions()
      if ImGui.MenuItem(ctx, #rg > 1 and "Selected regions" or "Selected region", nil, false, #rg > 0) then give("the region " .. table.concat(rg, ", "), {}, rg) end
      ImGui.SetItemTooltip(ctx, #rg > 0 and table.concat(rg, ", ") or "Click a region in the ruler first.")
      local from, to = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
      if ImGui.MenuItem(ctx, "Time selection", nil, false, to - from >= 0.01) then give(bar_span(from, to), {}, {}, { { from = from, to = to } }) end
      ImGui.SetItemTooltip(ctx, to - from >= 0.01 and bar_span(from, to) or "Drag across the ruler first.")
      ImGui.EndMenu(ctx)
    end
  end
  if groups.may_remove(cfg.root, me, p.user) and not removal.mark(cfg.root, p.user) then
    any = true
    if ImGui.Selectable(ctx, "Remove from the studio...") and reaper.MB("Take " .. p.user .. " out of " .. tostring(view.group) .. "?\n\n" ..
        "Within a few minutes every computer in the studio stops syncing with theirs. Their claims go free. What they made stays in the songs and on Restore.\n\n" ..
        "They keep the copy they already have: that can't be taken back. If they also have the studio's Google Drive folder, remove them there too.\n\n" ..
        "You have a minute to change your mind, and you can invite them again later.", "StudioSync", 4) == 6 then
      local ok, why = removal.remove(cfg.root, p.user, me)
      if ok then band.log(p.user .. " leaves the studio in a minute: Keep them on their card stops it") else reaper.MB(why, "StudioSync", 0) end
    end
  end
  if not any then ImGui.TextDisabled(ctx, "Nothing here for you: the owner and admins manage the studio.") end
  ImGui.EndPopup(ctx)
end
-- A name, with its role beside it. Right-clicking it opens the menu.
local swatch_at, swatch_of = -math.huge, {}
function ui.person_name(p, size)
  -- (their colour beside their name: tracks take people's colours, and nothing said whose was whose. UX review, 0.59.14)
  if reaper.time_precise() - swatch_at > 2 then swatch_at, swatch_of = reaper.time_precise(), {} end
  local who_name = tostring(p.user or p.name)
  if swatch_of[who_name] == nil then swatch_of[who_name] = require("people").colours(cfg.root, { who_name })[who_name] or false end
  if swatch_of[who_name] then
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local hh = ImGui.GetTextLineHeight(ctx)
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x, y + hh * 0.2, x + hh * 0.6, y + hh * 0.8, (swatch_of[who_name] << 8) | 0xFF, 2)
    ImGui.Dummy(ctx, hh * 0.6, hh)
    ImGui.SameLine(ctx, 0, 5)
  end
  ImGui.PushFont(ctx, ui.bold, size or 15)
  ImGui.Text(ctx, p.name)
  ImGui.PopFont(ctx)
  ImGui.SetItemTooltip(ctx, p.user == cfg.user and "You. Right-click: your name and colour." or "Right-click: their role, what they can change, or take them out.")
  ui.person_menu(p)
  local role = require("groups").role(cfg.root, p.user)
  if role == "owner" or role == "admin" then
    ImGui.SameLine(ctx, 0, 6)
    ImGui.TextDisabled(ctx, role)
  end
end
-- Solo someone (was "Listen", beside a "hear" switch that read the same: James, 0.58.82): only them in your ears, their whole mix, or
-- (following them) what they play, on top of your own copy of the song. lib/hear.lua.
function ui.listen_button(p)
  local hear = require("hear")
  local key = "listen " .. tostring(proj)
  local on = reaper.GetExtState(band.SECTION, key) == p.user
  if on then ImGui.PushStyleColor(ctx, ImGui.Col_Button, ACCENT) end
  if ImGui.SmallButton(ctx, (on and "Soloed" or "Solo") .. "##listen" .. p.user) then
    local ok, why = hear.listen(proj, cfg, b, not on and p.user or nil)
    if ok == nil then band.msg(tostring(why))
    else band.log(on and ("stopped listening to " .. p.user) or ("listening to " .. p.user .. ": they get asked by their computer, a few seconds' wait")) end
  end
  if on then ImGui.PopStyleColor(ctx) end
  ImGui.SetItemTooltip(ctx, on and ("You hear only " .. p.user .. ". Click to hear everyone again.") or
    ("Solo " .. p.user .. ": only them in your ears, through SonoBus (Mute leaves the others on and turns one person off). With Follow off you get their whole mix;\n" ..
    "with Follow on you get what they're playing or recording, over your own copy of the song, so it's in better quality and you can watch it land."))
end
-- Under a person in Who's here (James, 2026-11-02): what they're working in or last worked in, opening to all they've claimed.
function ui.person_claims(user, last_track)
  local list = ui.claims_of(user)
  if (last_track or "") ~= "" then -- (a track that's gone isn't where anyone's working: Mac, 0.50.4)
    local there = false
    for i = 0, reaper.CountTracks(proj) - 1 do there = there or select(2, reaper.GetTrackName(reaper.GetTrack(proj, i))) == last_track end
    if not there then last_track = "" end
  end
  if #list == 0 and (last_track or "") == "" then return end
  local head = (last_track or "") ~= "" and ('Working in "' .. last_track .. '"') or list[1].short
  if #list > 0 then head = head .. string.format("  (%d claim%s)", #list, #list == 1 and "" or "s") end
  if ui.short then next_to(ImGui.CalcTextSize(ctx, head) + 34) end -- (beside the name: a line each cost three people half the column)
  if #list == 0 then return ImGui.TextDisabled(ctx, head) end
  local open = ImGui.TreeNodeEx(ctx, "claims " .. user, "", ImGui.TreeNodeFlags_None)
  ImGui.SameLine(ctx, 0, 0)
  ImGui.TextWrapped(ctx, head) -- (a tree node's own label doesn't wrap: a long track name ran off the card)
  if open then
    ImGui.PushID(ctx, user)
    ui.claim_chips(list, true)
    ImGui.PopID(ctx)
    ImGui.TreePop(ctx)
  end
end
-- The regions clicked in the ruler, by name. (A REAPER too old to say: the one at the edit cursor.)
function ui.selected_regions()
  local out = {}
  if reaper.GetRegionOrMarkerInfo_Value then
    for i = 0, reaper.GetNumRegionsOrMarkers(proj) - 1 do
      local m = reaper.GetRegionOrMarker(proj, i, "")
      if reaper.GetRegionOrMarkerInfo_Value(proj, m, "B_ISREGION") == 1 and reaper.GetRegionOrMarkerInfo_Value(proj, m, "B_UISEL") == 1 then
        local _, name = reaper.GetSetRegionOrMarkerInfo_String(proj, m, "P_NAME", "", false)
        if name ~= "" and not name:find("^%[claimed") then out[#out + 1] = name end
      end
    end
  else
    local _, ri = reaper.GetLastMarkerAndCurRegion(proj, reaper.GetCursorPositionEx(proj))
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers3(proj, ri)
    if ri >= 0 and isrgn and name ~= "" then out[1] = name end
  end
  return out
end
local function section_claims()
  local owned = ui.claims_of()
  if view.driver == cfg.user then -- the driver lets go of claims held by someone who isn't here (left the band, away)
    local away = {}
    for _, o in ipairs(owned) do
      if o.user ~= cfg.user then
        local here = false
        for _, r in ipairs(view.rows) do if r.name == o.user and r.state ~= "offline" then here = true end end
        if not here then away[o.user] = true end
      end
    end
    for who_ in pairs(away) do
      if ImGui.SmallButton(ctx, "Release " .. who_ .. "'s claims##rel" .. who_) and reaper.MB(who_ .. " isn't here. Release everything " .. who_ ..
          " has claimed, so it follows you (the driver) again? They're told when they're back, and can claim again.", "StudioSync", 4) == 6 then
        sync.release_claims(cfg, b.song, b.room, who_)
        band.log("released " .. who_ .. "'s claims: what they had follows the driver now")
      end
      ImGui.SetItemTooltip(ctx, who_ .. " isn't here: their claims keep those parts locked for everyone until released.")
    end
  end
  local locked = who.mode == "admins" and not require("groups").may_manage(cfg.root, cfg.user)
  if locked then return ImGui.TextDisabled(ctx, "Admins only here: an admin can give you tracks to work on.") end
  if ImGui.Button(ctx, "Claim selected tracks") then
    local list = {}
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
    if #list == 0 then band.msg("Select the tracks you want to own first.") else claim(list, {}) end
  end
  ImGui.SetItemTooltip(ctx, "The tracks you've selected become yours: only you can change them, whoever's driving.")
  if not ui.advanced() then return end -- (regions and time: advanced controls. Keeping tracks local is in Settings > Advanced: James, 0.59.3)
  next_to("Claim selected region")
  if ImGui.Button(ctx, "Claim selected region") then
    local list = ui.selected_regions()
    if #list == 0 then band.msg("Click a named region in the ruler first.") else claim({}, list) end
  end
  ImGui.SetItemTooltip(ctx, "Click a region in the ruler, then this. What's in that region is yours: only you can change it, whoever's driving. The rest of the song isn't touched.")
  next_to("Claim time selection")
  if ImGui.Button(ctx, "Claim time selection") then
    local from, to = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
    if to - from < 0.01 then band.msg("Drag across the timeline to select the stretch of time you want to own first.") else
      local c, why = sync.my_claims(cfg, b.song, b.room)
      if not c then return band.msg(why) end
      c.times = c.times or {}
      c.times[#c.times + 1] = { from = from, to = to, at = os.date("!%Y-%m-%dT%H:%M:%SZ") } -- its own date (newest wins)
      sync.set_claims(cfg, b.song, b.room, c)
    end
  end
  ImGui.SetItemTooltip(ctx, "Drag across the ruler to select some time, then this. Whatever starts inside it is yours to change, whoever's driving (a track someone claimed still wins).\n" ..
    "Everyone sees it as a region named [claimed: you].")
  next_to("Release all claims")
  if ImGui.Button(ctx, "Release all claims") and reaper.MB("Release all your claims (tracks, regions and time)? Everything you claimed follows the driver again.",
      "StudioSync", 4) == 6 then
    local c = sync.my_claims(cfg, b.song, b.room) or {} -- (printing duties stay: "Stop printing them" lets those go)
    sync.set_claims(cfg, b.song, b.room, { tracks = {}, regions = {}, times = {}, prints = c.prints })
  end
end

-- A change in words, its positions as bars ("to bar 9 beat 3", not "to 20.50 s", which also broke mid-number when wrapped).
local function describe(e)
  return (recall.describe(e):gsub("( [at][to]?) (%d+%.%d+) s", function(w, n) return w .. " bar " .. bar_of(tonumber(n)) end))
end
-- The Restore page: lib/page_restore.lua (set up with ui.env, below).
local restore = require("page_restore")
local function combo(label, cur, list, tip)
  ImGui.SetNextItemWidth(ctx, 170)
  local pick
  if ImGui.BeginCombo(ctx, label, cur) then
    for _, v in ipairs(list) do if ImGui.Selectable(ctx, v, v == cur) then pick = v end end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, tip)
  return pick
end
local plugins = require("plugins")
local plug_info
local function section_plugins()
  heading("Plug-ins everyone has", 17)
  local about = "Each machine sends the studio its list of plug-ins (names only) when Live sync starts. What all of you have " ..
    "goes in the FX browser folder '" .. plugins.FOLDER .. "': use those and the project sounds the same on every machine. " ..
    "JSFX (REAPER's own effects, and ReaPack's) work on Windows and Mac alike."
  if ui.short then -- (the paragraph filled the column, and its button was below the fold)
    ImGui.SetItemTooltip(ctx, about)
    ImGui.TextDisabled(ctx, "A folder in the FX browser of what all of you have.")
    ImGui.SetItemTooltip(ctx, about)
  else
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextDisabled(ctx, about)
    ImGui.PopTextWrapPos(ctx)
  end
  if plug_info then ImGui.Text(ctx, plug_info) end
  if ImGui.Button(ctx, "Update the folder now") then
    local ok, n, why, members = pcall(function() plugins.publish(cfg); return plugins.update_folder(cfg) end)
    plug_info = not ok and ("Error: " .. tostring(n)) or n and string.format("%d plug-ins everyone has (lists from %s). Reopen the FX browser to see them.",
      n, table.concat(members or {}, ", ")) or why
  end
end

-- Live: hear each other while it happens, through ReaNINJAM and the band's NINJAM server.
local live = require("live")
local services = require("services")

local setup = require("setup")
-- The Play/Jam page: lib/page_play.lua (set up with ui.env, below).
local page_play = require("page_play")

-- Real time: SonoBus joins the band's group by itself (StudioSync writes it into SonoBus's state).
local sb_link
local function sonobus_open()
  local link, m, i = setup.sonobus(cfg, b, proj, true)
  if not link then return band.msg(m) end
  sb_link = link
  reaper.TrackFX_Show(m, i, 3)
end

-- Real time mode: the one switch for playing together. Real time (SonoBus, set up for the band's group) plus side by side
-- with no lag: whoever presses play, stop or record, everyone follows at the same spot and hears it at once; what
-- they record shows on your timeline as they play (MIDI notes) and lands as a take when they stop.
local function same_room_on()
  local sb_on, sm, si = live.sonobus_online(proj)
  return sb_on and live.rt_flag(proj), sm, si -- (its own flag: lib/live.lua rt_flag)
end
local function set_same_room(v)
  local _, sm, si = same_room_on()
  if v then
    -- (one or the other: both send your mix, so with both on everyone heard you twice, live and again bars later, and following
    -- each other wants 0 bars behind for one and an interval for the other. James, 0.59.4)
    if b and live.ninjam_master(proj) and not page_play.time_sync(false) then return end -- (Time-sync, or Jam from Play/Jam) -- (it didn't go off: not both. Review, 0.59.8)
    reaper.SetProjExtState(proj, band.SECTION, "rt talk only", "")
    local link, why = setup.sonobus(cfg, b, proj, true)
    if not link then return band.msg(why) end
    sb_link = link
    reaper.SetProjExtState(proj, band.SECTION, "rt", "1")
    reaper.SetProjExtState(proj, band.SECTION, "side", "0")
    reaper.SetExtState(band.SECTION, "live began " .. tostring(proj), "1", false) -- (Live sync starting later leaves it on: review, 0.59.9)
    band.log("Real time mode on: you hear everyone, and play, stop and record go to everyone")
  else
    reaper.SetProjExtState(proj, band.SECTION, "rt", "0")
    require("page_hear").set_their_time(proj, false) -- (your backing on time again: the delay was for Their time)
    if sm and select(2, reaper.GetProjExtState(proj, band.SECTION, "call")) == "1" then
      reaper.SetProjExtState(proj, band.SECTION, "rt talk only", "1") -- (the call stays: SonoBus now carries only the talk mic. 0.59.6)
      live.rt_sends(proj)
    elseif sm and not live.sonobus_wanted(proj) then reaper.TrackFX_SetOffline(sm, si, true) end -- (a listener, Solo, producing: it stays)
    reaper.SetProjExtState(proj, band.SECTION, "side", "")
    band.log("Real time mode off: changes still sync, but you don't hear each other live")
  end
end
-- The call (Chat > Call): Talk to everyone through SonoBus, on its own, whatever Real time mode and Time-sync are doing (James, 0.59.6:
-- "they just shouldn't be mutually exclusive... real-time mode on and talk/call on separately"). Without Real time mode, SonoBus carries
-- only the talk mic.
function ui.call_on() return select(2, reaper.GetProjExtState(proj, band.SECTION, "call")) == "1" end
-- Who else is in the call, by their status (the call window's list).
function ui.call_people()
  local out = {}
  for _, r in ipairs(view and view.rows or {}) do
    if r.call and r.state ~= "offline" and r.name ~= cfg.user then out[#out + 1] = r.name end
  end
  return out
end
function ui.set_call(v)
  local _, sm, si = same_room_on()
  if not v then
    reaper.SetProjExtState(proj, band.SECTION, "call", "")
    if live.talking(proj) then live.talk(proj, false) end
    if not same_room_on() then
      reaper.SetProjExtState(proj, band.SECTION, "rt talk only", "")
      if sm and not live.sonobus_wanted(proj) then reaper.TrackFX_SetOffline(sm, si, true) end -- (review, 0.59.9)
    end
    return band.log("the call is off")
  end
  if not same_room_on() then reaper.SetProjExtState(proj, band.SECTION, "rt talk only", "1") end
  local link, why = setup.sonobus(cfg, b, proj, true)
  if not link then reaper.SetProjExtState(proj, band.SECTION, "rt talk only", ""); return band.msg(why) end
  sb_link = link
  reaper.SetExtState(band.SECTION, "live began " .. tostring(proj), "1", false)
  reaper.SetProjExtState(proj, band.SECTION, "call", "1")
  live.rt_sends(proj)
  band.log("the call is on: press Talk to speak to everyone")
end
local SAME_ROOM_TIP = "Hear each other live, and play, stop and record together (My time and Their time go through SonoBus, Time-sync through NINJAM).\nWhat someone records lands as a take when they stop. Edits sync either way."

local setup_at, st = 0, {}
-- What StudioSync did lately (sends, what arrived, what was put back and why): it used to pop the console up
local function section_activity()
  local lines = band.activity()
  local newest = lines[1] and lines[1]:sub(7) or "nothing yet"
  if #newest > 64 then newest = newest:sub(1, 61) .. "..." end -- cut short visibly, not mid-word with nothing after
  -- "###": the label changes with every line, the header (and whether it's open) stays the same one
  if ImGui.CollapsingHeader(ctx, "Activity (" .. newest .. ")###activity") then
    if ImGui.BeginChild(ctx, "activity", 0, 140, ImGui.ChildFlags_Borders) then
      for _, l in ipairs(lines) do ImGui.TextWrapped(ctx, l) end
      ImGui.EndChild(ctx)
    end
    if ImGui.SmallButton(ctx, "Clear") then reaper.DeleteExtState(band.SECTION, band.LOG_KEY, false) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Open the full console") then reaper.ShowConsoleMsg("") end
  end
end



-- ---- Together: start/stop at once, notes and likes, live ideas, and the tools (lib/tools.lua) ----------------
local note_text = ""
-- -> an id for the selected take (an older take id), its item, its take, and the item's mirror id. A part in mirror sync (a take in lanes, a
-- MIDI part) has no take id, only the item's: likes and notes went nowhere on them, the button greyed out. James, 0.58.98.
local function sel_take()
  local it = reaper.GetSelectedMediaItem(proj, 0)
  local tk = it and reaper.GetActiveTake(it)
  if not tk then return nil end
  local id = band.take_id(tk) or (band.take_ext(tk, "band_dry") ~= "" and band.take_ext(tk, "band_dry")) or nil
  local oid = require("mirror").item_oid(it)
  if not id and oid ~= "" then id = "item " .. oid end
  return id, it, tk, oid ~= "" and oid or nil
end
local notes_at, notes = 0, {}
local ideas_at, ideas = 0, {}
-- The Chat page's Notes tab (`kind` "note") or Likes tab ("like"): they were one card beside the chat (James, 0.58.79: separate tabs).
local function section_notes(kind)
  local id, it = sel_take()
  local place = id and "Note on selected take" or "Note at cursor"
  local entered = false
  if kind == "note" then
    if ui.short then ImGui.SetNextItemWidth(ctx, -(ImGui.CalcTextSize(ctx, place) + 30)) -- (the button beside it: two rows pushed the notes themselves out of a short docker)
    else ImGui.SetNextItemWidth(ctx, -1) end
    local t
    entered, t = require("page_chat").input(ctx, ImGui, "##note", "a note for everyone, Enter to post (e.g. 'try the chorus an octave up')", note_text)
    note_text = t
  end
  local whose = id and not id:match("^item ") and (id:match("^(.-)%-%d+%-%d+Z") or "?"):gsub("_", " ") .. "'s take" or "the part"
  local whereto = id and string.format("Selected: %s on %s, bar %s", whose, sync.track_name(it), bar_of(reaper.GetMediaItemInfo_Value(it, "D_POSITION"))) .. (reaper.SetTakeMarkerInfo and ". With a time selection over it, the note covers that stretch" or "")
    or (kind == "note" and "No take selected: notes go at the edit cursor." or "Select a take to like it.")
  if kind == "like" then whereto = whereto:gsub("%. With a time selection.*$", "") end
  if ui.short then ImGui.SetItemTooltip(ctx, whereto); if kind == "note" then ImGui.SameLine(ctx) end else ImGui.TextDisabled(ctx, whereto) end
  local function mark(kind, text)
    local pos = reaper.GetCursorPositionEx(proj)
    -- (a time selection over the selected take: the note covers it, shaded across those bars where REAPER has take marker lengths, 7.86.
    -- James, 0.58.67: "see if the REAPER update can help build the other features")
    local len
    local s0, s1 = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
    if it and kind == "note" and s1 > s0 then
      local i0 = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local a, z = math.max(s0, i0), math.min(s1, i0 + reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
      if z > a then pos, len = a, z - a end
    end
    -- (a like at the cursor landed past the part when the cursor wasn't over it: at its start then)
    if it and not len then
      local i0 = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      if pos < i0 or pos > i0 + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") then pos = i0 end
    end
    local oid = id and id:match("^item (.+)$")
    local ev = { type = kind, text = text, take = not oid and id or nil, item = oid, pos = pos, len = len, track = it and sync.base_name(select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))) or nil }
    sync.post(cfg, b.song, b.room, ev)
    if it then sync.mark_item(it, pos, (kind == "like" and "+1 " or "") .. cfg.user .. (text and (": " .. text) or ""), len) end -- as everyone else gets it
    notes_at = 0
  end
  if kind == "note" then
    ImGui.BeginDisabled(ctx, note_text == "")
    if (ImGui.Button(ctx, place) or entered) and note_text ~= "" then mark("note", note_text); note_text = "" end
    ImGui.EndDisabled(ctx)
  else
    ImGui.BeginDisabled(ctx, not id)
    if ImGui.Button(ctx, "Like selected take") then mark("like", nil) end
    ImGui.EndDisabled(ctx)
  end
  if reaper.time_precise() - notes_at > 4 then
    -- (only notes: it read every change there is on the first click, 4500 files on Sunset Drive, and froze REAPER: James, 0.42.28)
    notes_at, notes = reaper.time_precise(), recall.notes(cfg, b.song, b.room)
    ui.resolved = {} -- (which notes someone has ticked off: <Song>/chat/resolved/<note id>.json. Asked for most in other tools: 0.58.47)
    for _, f in ipairs(band.files(band.song_dir(cfg, b.song) .. "/chat/resolved", ".json")) do ui.resolved[f:sub(1, -6)] = true end
  end
  -- (docked, the list takes the column's height, as the versions do; a 90 px box left the rest of a tall column empty)
  -- (the list takes the tab's height)
  if ImGui.BeginChild(ctx, "notes" .. kind, 0, math.max(70, select(2, ImGui.GetContentRegionAvail(ctx)) - 4), ImGui.ChildFlags_Borders) then
    local shown_n, only = 0, require("page_chat").only()
    for i, e in ipairs(notes) do
      if e.type ~= kind or (only ~= "" and e.user ~= only) then goto next_note end
      shown_n = shown_n + 1
      if shown_n > 30 then break end
      ImGui.PushID(ctx, i)
      local done = ui.resolved and ui.resolved[e.id]
      if e.type == "note" then
        local ch, v = ImGui.Checkbox(ctx, "##resolved", done == true)
        if ch then
          local rdir = band.song_dir(cfg, b.song) .. "/chat/resolved"
          if v then reaper.RecursiveCreateDirectory(rdir, 0); band.write_json(rdir .. "/" .. e.id .. ".json", { by = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
          else os.remove(rdir .. "/" .. e.id .. ".json") end
          ui.resolved[e.id] = v or nil
        end
        ImGui.SetItemTooltip(ctx, done and "Resolved. Untick to open it again, for everyone." or "Resolved: tick it off, for everyone.")
        ImGui.SameLine(ctx)
      end
      if ImGui.SmallButton(ctx, "Go") then
        local it2 = e.take and band.find_take(proj, e.take)
        reaper.SetEditCurPos2(proj, e.pos or (it2 and reaper.GetMediaItemInfo_Value(it2, "D_POSITION")) or 0, true, false)
      end
      ImGui.SetItemTooltip(ctx, "Put the edit cursor there.")
      ImGui.SameLine(ctx)
      local words = string.format("%s  %s: %s%s", local_time(e.time):sub(7), e.user, describe(e), e.take and e.pos and (" (bar " .. bar_of(e.pos) .. ")") or "")
      if done then ImGui.TextDisabled(ctx, words) else ImGui.TextWrapped(ctx, words) end
      ImGui.PopID(ctx)
      ::next_note::
    end
    if shown_n == 0 then
      ImGui.TextDisabled(ctx, kind == "note" and "No notes yet: put the edit cursor where you mean and add one, and everyone sees it at that spot."
        or "No likes yet: select a take you like and press Like selected take. Whoever played it sees it on the take.")
    end
    ImGui.EndChild(ctx)
  end
end

local function section_ideas()
  if reaper.time_precise() - ideas_at > 2 then ideas_at, ideas = reaper.time_precise(), tools.ideas(proj) end
  if next(ideas) == nil then return end
  ImGui.SeparatorText(ctx, "Live ideas (what you heard in Play along, until the real takes arrive)")
  for who_, n in pairs(ideas) do
    ImGui.Text(ctx, string.format("%s: %d", who_, n))
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Dismiss##" .. who_) then tools.dismiss_ideas(proj, who_); ideas_at = 0 end
  end
  if ImGui.Button(ctx, "Keep selected") then band.log(tools.keep_ideas(proj) .. " idea(s) kept as your own items"); ideas_at = 0 end
  ImGui.SetItemTooltip(ctx, "The selected placeholders stay for good (no take replaces them). Send them with Send selected to main if the studio should have them.")
end

local rooms = require("rooms")
-- The Rooms page: lib/page_rooms.lua (set up with ui.env, below).
local page_rooms = require("page_rooms")
local live_running = page_rooms.live_running

-- Docked wide and short (a bottom docker), a page's parts stand side by side as columns, each scrolling up and down on
-- its own, and the page scrolls sideways when they don't all fit; otherwise they come one under the other.
local function layout(parts, bare) -- { { fn, width } }; bare: what's in them is one card each, and the column is the card
  if not wide then -- (each through ui.page_body: one column's error ended the whole panel. Review, 0.58.47)
    for _, part in ipairs(parts) do ui.page_body(part[1]) end
    return
  end
  local avail, h = ImGui.GetContentRegionAvail(ctx)
  local total = 0
  for _, part in ipairs(parts) do total = total + (part[2] or 340) end
  -- (a docker part of the width: whole columns sat off the right, Claims among them. As many as fit at 0.8, the rest stacked in the last.
  -- Layout review, 0.59.14)
  if #parts > 1 and total * 0.8 + 10 * (#parts - 1) > avail then
    local cols, used = {}, 0
    for _, part in ipairs(parts) do
      local pw = (part[2] or 340) * 0.8
      if #cols == 0 or used + 10 + pw <= avail then cols[#cols + 1] = { part }; used = used + (#cols > 1 and 10 or 0) + pw
      else table.insert(cols[#cols], part) end
    end
    if #cols < #parts then
      local merged = {}
      for _, col in ipairs(cols) do
        local w = 0
        for _, sp in ipairs(col) do w = math.max(w, sp[2] or 340) end
        merged[#merged + 1] = { #col == 1 and col[1][1] or function() for k, sp in ipairs(col) do if k > 1 then ui.spacer() end; sp[1]() end end, w }
      end
      parts, total = merged, 0
      for _, part in ipairs(parts) do total = total + (part[2] or 340) end
    end
  end
  local scale = math.max(0.72, (avail - 10 * (#parts - 1)) / total) -- (fixed widths left the right of a wide docker empty: design review; a narrower one had them run off the right: Mac, 0.57.7)
  for i, part in ipairs(parts) do
    if i > 1 then ImGui.SameLine(ctx, 0, 10) end
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.COLUMN)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, ui.short and 6 or 10)
    ImGui.BeginGroup(ctx)
    local open = ImGui.BeginChild(ctx, "col" .. i, math.floor((part[2] or 340) * scale), h, ImGui.ChildFlags_AlwaysUseWindowPadding)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)
    local more = false
    if open then
      ImGui.PushTextWrapPos(ctx, 0)
      ui.bare_cards = bare
      ui.page_body(part[1])
      ui.bare_cards = nil
      ImGui.PopTextWrapPos(ctx)
      -- (a fade at the foot says there's more; a line of words cost every column its height, whether it hid anything or not: design review)
      more = ImGui.GetScrollMaxY(ctx) - ImGui.GetScrollY(ctx) > ImGui.GetTextLineHeight(ctx)
      if more then
        local cx, cy = ImGui.GetWindowPos(ctx)
        local cw, ch = ImGui.GetWindowSize(ctx)
        local solid = theme.COLUMN
        ImGui.DrawList_AddRectFilledMultiColor(ImGui.GetWindowDrawList(ctx), cx, cy + ch - 22, cx + cw, cy + ch, solid & 0xFFFFFF00, solid & 0xFFFFFF00, solid, solid)
      end
      ImGui.EndChild(ctx)
    end
    ImGui.EndGroup(ctx)
  end
end

-- Settings > Health and Updates: lib/page_health.lua (set up with ui.env once that's made, below).
local health = require("page_health")
local function maint_health() return health.maint_health() end
local function dot(col) return health.dot(col) end

-- Talk and its mic (Chat's Call tab only: James, 0.59.6)
function ui.talk_controls(on)
  if on and b then -- talkback: speak to the others without arming a track that records
    local live = require("live")
    local talking = live.talking(proj)
    require("page_hear").fit(ctx, ImGui, talking and "Talking" or "Talk")
    if talking then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF) end
    if ImGui.SmallButton(ctx, (talking and "Talking" or "Talk") .. "##talkback") then live.talk(proj, not talking) end
    if talking then ImGui.PopStyleColor(ctx) end
    local inputs = live.talk_inputs()
    local cur = live.talk_input()
    local mic = "input " .. (cur + 1)
    for _, i in ipairs(inputs) do if i[1] == cur then mic = i[2] end end
    ImGui.SetItemTooltip(ctx, "Your microphone to the others, without arming a track: it's never recorded, and it goes quiet only while a track here\n" ..
      "records from that same mic. No other call app needed. Mic: " .. mic .. " (Mic, beside it, picks another; only on this computer). Click again to stop.")
    -- the call mic, picked here (0.58.98: it was the first input, changed only on the hidden 'StudioSync Talk' track)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Mic##talkmic") then ImGui.OpenPopup(ctx, "talkmic") end
    ImGui.SetItemTooltip(ctx, "Which input Talk uses: your call mic (" .. mic .. ").")
    if ImGui.BeginPopup(ctx, "talkmic") then
      ImGui.TextDisabled(ctx, "Talk uses (this computer only):")
      for _, i in ipairs(inputs) do
        if ImGui.Selectable(ctx, i[2] .. "##mic" .. i[1], i[1] == cur) then live.set_talk_input(proj, i[1]); band.log("Talk uses " .. i[2] .. " now") end
      end
      if #inputs == 0 then ImGui.TextDisabled(ctx, "No audio inputs: pick your interface in REAPER's Preferences > Audio > Device.") end
      ImGui.EndPopup(ctx)
    end
  end
end
-- Chat's Call tab (James, 0.59.2: "a separate call or comms channel folded into the chat tab"): the studio's call link, talking through
-- Real time mode with your call mic, and each person's volume and mute (SonoBus's own window has them, per person, separate from what's recorded).
function ui.call_tab()
  heading("Call", 17)
  local call = require("alerts").call_link(cfg.root)
  if call then
    if ImGui.Button(ctx, "Join the studio's call") then band.open_url(call) end
    ImGui.SetItemTooltip(ctx, "Opens " .. call .. " in its own app or browser, with video if it has it. Mute its microphone while you play: Real time mode carries the music.")
  else
    ImGui.TextDisabled(ctx, "No call link for the studio yet (Discord, Zoom, Meet...): the owner or an admin sets it in Settings > Studio.")
    if ImGui.SmallButton(ctx, "Set it up##calllink") then ui.go_settings("Studio") end
  end
  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Talk inside StudioSync")
  -- (its own switch: it was Real time mode's, and switching it on turned Time-sync off. James, 0.59.6)
  local on = b and ui.call_on()
  ImGui.BeginDisabled(ctx, not b)
  local ch, v = switch_row("##callsw", "Join the call", on, "Talk to everyone with your talk mic (press Talk), whatever Real time mode and Time-sync are doing.\n" ..
    "Without Real time mode it carries only your talk mic, never your playing.")
  ImGui.EndDisabled(ctx)
  if ch then ui.set_call(v) end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Pop out##callpop") then require("callwin").set_open(true) end -- (James, 0.59.14)
  ImGui.SetItemTooltip(ctx, "The call in a small window of its own: mute and unmute, hold to talk, your mic, volumes, deafen and who's in. It stays while the panel is shrunk.")
  if on then
    ui.talk_controls(true)
    ImGui.Spacing(ctx)
    if ImGui.SmallButton(ctx, "Each person's volume and mute") then sonobus_open() end
    ImGui.SetItemTooltip(ctx, "SonoBus's own window: a level and a mute for each person you hear, only for you, and nothing to do with what's recorded.")
    ImGui.TextDisabled(ctx, "Talk is never recorded. It goes quiet only while a track here records from your talk mic; then they hear that take as usual. To record a vocal, arm its track.")
  else
    ImGui.TextDisabled(ctx, b and "On: talk to everyone with Talk, no other app needed, and set each person's volume." or "Open a studio project to talk.")
  end
end
-- Real time mode's three ways (James, 0.59.4: "my time, their time for SonoBus and then time sync for NINJAM, each stating what they do").
-- One at a time: SonoBus and NINJAM both carry your mix, so with both on everyone hears you twice. The last one picked comes back with the switch.
local RT_KINDS = {
  { "my", "My time", "You hear everyone the moment it arrives, a little late (the network). For playing and talking together." },
  { "their", "Their time", "Your backing is delayed so the others line up with it. For listening along, not for playing." },
  { "timesync", "Time-sync", "Everyone plays to their own copy of the song and hears the others exactly in time, %s late. For playing along to a take. Talk: Chat > Call." },
}
function ui.rt_kind()
  if page_play.time_sync_on() then return "timesync" end
  if same_room_on() then return require("page_hear").their_time_on(proj) and "their" or "my" end
  return nil
end
function ui.set_rt_kind(kind) -- nil: off
  local now = ui.rt_kind()
  if kind == now then return end
  if kind == "timesync" then
    if not b then return band.msg("Time-sync needs a studio project open.") end
    if same_room_on() then set_same_room(false) end
    page_play.time_sync(true)
  elseif kind then
    if not same_room_on() then set_same_room(true) end
    if same_room_on() then require("page_hear").set_their_time(proj, kind == "their") end -- (not if it didn't come on: review, 0.59.8)
  elseif now == "timesync" then page_play.time_sync(false)
  else set_same_room(false) end
  -- (kept once it's on: a Time-sync that failed, with no Tailscale, was kept, tried again at every press of the switch, and My time never came
  -- back from Home. Onboarding review, 0.59.9)
  if kind and ui.rt_kind() == kind then reaper.SetProjExtState(proj, band.SECTION, "rt kind", kind) end
end
-- The Real time switch (Home, the radial menu): the way picked last, or My time when that one doesn't come on.
function ui.rt_switch(v)
  if not v then return ui.set_rt_kind(nil) end
  local last = select(2, reaper.GetProjExtState(proj, band.SECTION, "rt kind"))
  local want = last ~= "" and (b or last ~= "timesync") and last or "my"
  ui.set_rt_kind(want)
  if want ~= "my" and not ui.rt_kind() then ui.set_rt_kind("my") end
end
local function home_play()
  local kind = ui.rt_kind()
  local on, sb = kind ~= nil, kind == "my" or kind == "their"
  local ch, v = switch_row("##rt", "Real time mode", on, SAME_ROOM_TIP)
  if ch then
    ui.rt_switch(v)
    kind = ui.rt_kind(); on, sb = kind ~= nil, kind == "my" or kind == "their"
  end
  if on then
    local bars = b and page_play.interval_bars() or 1
    ImGui.Indent(ctx, 26)
    for _, k in ipairs(RT_KINDS) do
      -- (NINJAM goes over Tailscale: without it, Time-sync came on and nothing arrived. Onboarding review, 0.59.9)
      local no_ts = k[1] == "timesync" and b and not require("services").tailscale_up()
      ImGui.BeginDisabled(ctx, k[1] == "timesync" and (not b or no_ts) and kind ~= k[1])
      if ImGui.RadioButton(ctx, k[2] .. "##rtkind", kind == k[1]) and kind ~= k[1] then ui.set_rt_kind(k[1]) end
      ImGui.EndDisabled(ctx)
      local says = no_ts and "Time-sync needs the studio's private network (Tailscale): ask whoever runs the studio for a guest invitation. Health shows it."
        or k[3]:format(string.format("%d bar%s", bars, bars == 1 and "" or "s"))
      if ui.short then ImGui.SetItemTooltip(ctx, says) else ImGui.TextDisabled(ctx, says) end
    end
    ImGui.Unindent(ctx, 26)
  end
  if sb or ui.call_on() then -- (only while SonoBus is on: it said "Configure SonoBus" with nothing live. UX review, 0.59.14)
    require("page_hear").fit(ctx, ImGui, "Each person's volume") -- (beside, or below in a narrow column)
    if ImGui.SmallButton(ctx, "Each person's volume") then sonobus_open() end
    ImGui.SetItemTooltip(ctx, "Opens SonoBus's own window: volume and mute for each collaborator, buffer and quality. You don't need it to play together.")
  end
  if b then -- (James, 0.58.87: an easier way to bring in someone with only the SonoBus app: one message, and SonoBus Guest on)
    require("page_hear").fit(ctx, ImGui, "Invite someone without REAPER")
    if ImGui.SmallButton(ctx, "Invite someone without REAPER") then
      local link, why = setup.sonobus(cfg, b, proj, true)
      if not link then band.msg(why) else
        sb_link = link
        if not sb then set_same_room(true) end
        require("guest").set(proj, true)
        local info = band.info(cfg.root)
        tools.show_invite("Join me live in " .. tostring(info.name) .. " (" .. tostring(b.song) .. ") with SonoBus: you'll hear the song and me, and I'll hear and record you.\n\n" ..
          "1. Install SonoBus, free: https://sonobus.net (Windows, Mac, iPhone, Android, Linux).\n" ..
          "2. Open this link, and SonoBus joins us by itself:\n" .. link .. "\n" ..
          "3. Wear headphones (speakers come back into your mic as an echo), and plug in your mic or instrument.\n" ..
          "Nothing else to install, no account needed.", info, ctx, ImGui)
        band.log("a SonoBus guest invitation is on your clipboard; Real time mode and SonoBus Guest are on, so they'll hear the song and you")
      end
    end
    ImGui.SetItemTooltip(ctx, "For someone with only the SonoBus app (no REAPER, no StudioSync): a message with SonoBus's download and a link that joins your\n" ..
      "studio's live audio. Turns on Real time mode and SonoBus Guest, so they hear your mix and what they play records here.")
  end
  if sb then -- (the help for it was in Settings > Advanced, with nothing here pointing at it: UX review, 0.58.52)
    require("page_hear").fit(ctx, ImGui, "Can't hear?")
    if ImGui.SmallButton(ctx, "Can't hear?") then ui.go_settings("Advanced") end
    ImGui.SetItemTooltip(ctx, "What to try when you can't hear someone, or they can't hear you (Settings > Advanced).")
  end
  local call = require("alerts").call_link(cfg.root)
  if call then -- (the studio's own call: Discord, Zoom, Meet, whatever they use. Its own app, so it never slows REAPER or the sync)
    require("page_hear").fit(ctx, ImGui, "Video call")
    if ImGui.SmallButton(ctx, "Video call") then band.open_url(call) end -- (was "Call": read as the talk line in Chat > Call. UX review, 0.59.14)
    ImGui.SetItemTooltip(ctx, "Opens the studio's call (" .. call .. ") in its own app or browser, with video if it has it.\n" ..
      "Mute its microphone while you play: Real time mode already carries the music, and two copies echo.")
  end
  if not ui.short and not on then -- (a tall docker has the room)
    ImGui.TextDisabled(ctx, "Off: changes still sync, but you don't hear each other live or follow each other's play and stop.")
  end
  if sb then require("page_hear").realtime(ctx, ImGui, proj, true) end
  local silent = reaper.GetExtState(band.SECTION, "rt silent " .. tostring(proj))
  if silent ~= "" then ImGui.TextColored(ctx, YELLOW, silent) end
  local trouble = reaper.GetExtState(band.SECTION, "rt trouble " .. tostring(proj))
  if trouble ~= "" then ImGui.TextColored(ctx, YELLOW, trouble) end
  local who_listens = reaper.GetExtState(band.SECTION, "listeners " .. tostring(proj))
  if who_listens ~= "" then ImGui.TextColored(ctx, ACCENT, who_listens .. " is listening to you") end
end
-- Little icons after someone's name: Real time mode (bars), Time-sync (a clock), in the call (a phone, which opens Chat > Call). James,
-- 0.59.8: "indicators to see who has it on... and who's in call... little icons to keep things clean". From their status (lib/status.lua).
function ui.live_icons(p)
  if p.state == "offline" or not (p.live or p.call) then return end
  local h = ImGui.GetTextLineHeight(ctx)
  local function slot(id, tip, col, draw, click)
    ImGui.SameLine(ctx, 0, 6)
    if ImGui.GetContentRegionAvail(ctx) < h then ImGui.NewLine(ctx) end -- (cut off at the card's edge, the phone with it: review, 0.59.14)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    if ImGui.InvisibleButton(ctx, id, h, h) and click then click() end
    local c = ImGui.IsItemHovered(ctx) and theme.TEXT or col
    draw(ImGui.GetWindowDrawList(ctx), x, y, c)
    ImGui.SetItemTooltip(ctx, tip)
    if click and ImGui.IsItemHovered(ctx) then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand) end
  end
  local who = p.user == cfg.user and "You're" or (p.user .. " is")
  if p.live == "rt" then
    slot("##rt" .. p.user, who .. " in Real time mode (live through SonoBus)", ACCENT, function(dl, x, y, c)
      for k, f in ipairs({ 0.45, 0.85, 0.6 }) do
        local bx = x + h * (0.12 + 0.28 * (k - 1))
        ImGui.DrawList_AddRectFilled(dl, bx, y + h * (0.95 - f), bx + h * 0.18, y + h * 0.95, c, 1)
      end
    end)
  elseif p.live == "ts" then
    slot("##ts" .. p.user, who .. " in Time-sync (in time with the song, through NINJAM)", ACCENT, function(dl, x, y, c)
      local cx, cy, r = x + h / 2, y + h / 2, h * 0.4
      ImGui.DrawList_AddCircle(dl, cx, cy, r, c, 0, 1.6)
      ImGui.DrawList_AddLine(dl, cx, cy, cx, cy - r * 0.7, c, 1.6)
      ImGui.DrawList_AddLine(dl, cx, cy, cx + r * 0.55, cy, c, 1.6)
    end)
  end
  if p.call then
    slot("##call" .. p.user, who .. " in the call. Click: Chat > Call", GREEN, function(dl, x, y, c)
      local cx, cy, r = x + h / 2, y + h / 2, h * 0.34
      ImGui.DrawList_PathArcTo(dl, cx, cy, r, math.pi * 0.6, math.pi * 1.4)
      ImGui.DrawList_PathStroke(dl, c, ImGui.DrawFlags_None, h * 0.16)
      for _, a in ipairs({ math.pi * 0.6, math.pi * 1.4 }) do
        ImGui.DrawList_AddCircleFilled(dl, cx + r * math.cos(a), cy + r * math.sin(a), h * 0.15, c)
      end
    end, function() ui.go_chat("Call") end)
  end
end
-- Your live audio for your card: each look scans every track's plug-ins, so it's looked at every quarter second (review, 0.59.10).
local live_seen = { at = -math.huge }
function ui.live_now()
  local t = reaper.time_precise()
  if t - live_seen.at > 0.25 or live_seen.proj ~= proj then
    live_seen = { at = t, proj = proj, kind = ui.rt_kind(), call = ui.call_on() and live.sonobus_online(proj) or nil }
  end
  return live_seen.kind, live_seen.call
end
local function home_who()
  require("page_hear").producer(ctx, ImGui, proj, cfg, b, view and view.rows or {}) -- (at the top: at 560 wide it was past all three people. Mac, 0.58.5)
  if not wide then home_play() end -- (real time mode first: it's what a session starts with, and it was under every person's card. UX review, 0.58.62)
  heading("Who's here")
  next_to("Invite a collaborator")
  local services = require("services")
  local my_id = services.my_device_id()
  ImGui.BeginDisabled(ctx, not my_id)
  if ImGui.SmallButton(ctx, "Invite a collaborator") then tools.invite(my_id, band.info(cfg.root), ctx, ImGui) end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, my_id and tools.INVITE_TIP or "Waiting for Syncthing (it has to be running).")
  if my_id then -- (how long they stay is picked there: James, 0.58.82; with a Tailscale token, Settings > Advanced, they join that too)
    next_to("Invite a guest")
    tools.guest_invite_button(ctx, ImGui, my_id, cfg.root)
  end
  tools.guests_list(ctx, ImGui, cfg.root, require("groups").may_manage(cfg.root, cfg.user))
  local people, armed = {}, {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if require("live").armed(tr) then armed[#armed + 1] = select(2, reaper.GetTrackName(tr)) end
  end
  local ps = reaper.GetPlayStateEx(proj)
  local my_kind, my_call = ui.live_now()
  people[1] = { name = cfg.user .. " (you)", user = cfg.user, state = "here", armed = armed, recording = ps & 4 == 4, playing = ps & 1 == 1,
    driving = view.driver == cfg.user, last_track = select(2, reaper.GetProjExtState(proj, band.SECTION, "last_track")),
    live = my_kind == "timesync" and "ts" or my_kind and "rt" or nil, call = my_call }
  -- (away people hidden on request: James, 0.59.3. ExtState "who hide away")
  local hide_away, away = reaper.GetExtState(band.SECTION, "who hide away") ~= "", 0
  for _, r in ipairs(view.rows) do
    if hide_away and r.state == "offline" then away = away + 1 else
      people[#people + 1] = { name = r.name, user = r.name, state = r.state, armed = r.armed, recording = r.recording, playing = r.playing,
        driving = r.name == view.driver, version = r.version, mirror = r.mirror, last_track = r.last_track, live = r.live, call = r.call }
    end
  end
  do
    local any_away = away > 0
    for _, r in ipairs(view.rows) do any_away = any_away or r.state == "offline" end
    if any_away then
      local ch, v = ImGui.Checkbox(ctx, (hide_away and string.format("Show who's away (%d)", away) or "Show who's away") .. "##whoaway", not hide_away)
      if ch then reaper.SetExtState(band.SECTION, "who hide away", v and "" or "1", true) end
      ImGui.SetItemTooltip(ctx, "Off: only the people here now have cards. Their claims and parts are the same either way.")
    end
  end
  if ui.short then
    for _, p in ipairs(people) do
      dot(p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SameLine(ctx, 0, 4)
      ui.person_name(p)
      if p.recording then pill_after("recording", RED, nil, 6) elseif p.driving then pill_after("driving", ACCENT, 0xFFFFFFFF, 6) end
      ui.live_icons(p)
      if p.state == "syncing" then ImGui.SameLine(ctx, 0, 6); ImGui.TextColored(ctx, YELLOW, "getting changes") end -- (the bar just says "Sending")
      if p.mirror and view.my_mirror and p.state == "synced" then -- (as on the cards: the docked list said nothing, match or not)
        ImGui.SameLine(ctx, 0, 6)
        if p.mirror == view.my_mirror then ImGui.TextColored(ctx, GREEN, "same project")
        elseif settled_apart(p, view.my_mirror) then ImGui.TextColored(ctx, RED, "project differs")
        else ImGui.TextDisabled(ctx, "settling") end
      end
      if p.state ~= "here" and p.state ~= "offline" then
        next_to("Following"); tools.follow_button(p.name)
        if ui.advanced() or require("producer").who(proj) == p.user then
          next_to("Soloed"); ui.listen_button(p); next_to("Producing")
          require("page_hear").produce_button(ctx, ImGui, proj, cfg, b, p.user)
        end
      end
      if p.state ~= "here" then pcall(function() require("page_hear").person(ctx, ImGui, proj, p.name) end) end -- (hear them live or not)
      ui.person_claims(p.user, p.last_track)
      ui.leaving_row(p)
    end
    if #view.rows == 0 then ImGui.TextDisabled(ctx, "Nobody else is in this room yet. Invite a collaborator (above) copies a message to send them; once they're in, they show here.") end
    return
  end
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 214, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
  w = math.floor((avail - gap * (per - 1)) / per) -- (they fill the page: a strip was left empty on the right)
  for i, p in ipairs(people) do
    if (i - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    if card("who " .. p.name, w) then -- (grows with what they have armed)
      ui.person_name(p, 16)
      -- (in words: "synced", "here" and "no receipt" were the code's names for them. UX review, 0.58.52)
      local words = ({ here = "you", synced = "up to date", syncing = "getting changes", offline = "away", ["no receipt"] = "not opened here yet" })[p.state] or p.state
      pill(words, p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SetItemTooltip(ctx, ({ here = "This machine.", ["synced"] = "Has every change.", ["syncing"] = "Still getting changes (yours or the studio's).",
        offline = "Not seen for over a minute.", ["no receipt"] = "Has sent takes, but never ran Live sync here." })[p.state] or p.state)
      if p.recording then pill_after("recording", RED)
      elseif p.playing and p.state ~= "offline" then pill_after("playing", ACCENT, 0xFFFFFFFF) end
      if p.driving then pill_after("driving", ACCENT, 0xFFFFFFFF); ImGui.SetItemTooltip(ctx, "They drive: play, stop and the place in the song follow them. Who changes what: Who can edit.") end
      ui.live_icons(p)
      if p.armed and #p.armed > 0 then ImGui.TextDisabled(ctx, "armed: " .. table.concat(p.armed, ", "))
      elseif not wide then ImGui.TextDisabled(ctx, "nothing armed") end -- (docked, the line went to saying nothing)
      -- (only while they're here: offline, it's what they had the last time they had this song open, days ago maybe. Mac test, 0.58.69)
      if p.version and p.version ~= band.VERSION and p.state ~= "offline" then
        local older = band.compare_versions(p.version, band.VERSION) < 0
        ImGui.TextColored(ctx, YELLOW, (older and "Older StudioSync (" or "Newer StudioSync (") .. p.version .. (older and "): ask them to update" or "): update yours"))
      end
      if p.mirror and view.my_mirror and p.state == "synced" then -- (while changes are still on their way it's bound to differ)
        if p.mirror == view.my_mirror then ImGui.TextColored(ctx, GREEN, "same project as yours")
        elseif not settled_apart(p, view.my_mirror) then ImGui.TextDisabled(ctx, "settling")
        else ImGui.TextColored(ctx, RED, "project differs from yours"); ImGui.SetItemTooltip(ctx, "They have every change, yet their project isn't the same as yours: " ..
          "Settings > Health says more, and the Console names what came out different.") end
      end
      if p.state ~= "here" and p.state ~= "offline" then
        tools.follow_button(p.name)
        if ui.advanced() or require("producer").who(proj) == p.user then
          ImGui.SameLine(ctx, 0, 4); ui.listen_button(p); ImGui.SameLine(ctx, 0, 4)
          require("page_hear").produce_button(ctx, ImGui, proj, cfg, b, p.user)
        end
      end
      if p.state ~= "here" then pcall(function() require("page_hear").person(ctx, ImGui, proj, p.name) end) end -- (hear them live or not)
      ui.person_claims(p.user, p.last_track)
      ui.leaving_row(p)
      -- (a right-click anywhere on the card, not only on the name: James, 0.59.3)
      if ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_ChildWindows) and ImGui.IsMouseClicked(ctx, 1) and not ImGui.IsAnyItemHovered(ctx) then
        ImGui.OpenPopup(ctx, "person " .. p.user)
      end
      card_end()
    end
  end
  if #view.rows == 0 then ImGui.TextDisabled(ctx, "Nobody else is in this room yet. Invite a collaborator (above) copies a message to send them; once they're in, they show here.") end
end
-- Local mixing: your faders and pan stay yours (not sent, not overwritten). Off again: adopt the band's mix, or
-- send yours.
function ui.keep_local()
  local list = {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = reaper.GetSelectedTrack(proj, i) end
  if #list == 0 then return band.msg("Select the tracks you want to keep on this computer first.") end
  local n, shared, kept, helpers = require("mirror").keep_local(proj, list)
  if helpers > 0 and n == 0 and shared == 0 then return band.log("those are StudioSync's own tracks on this computer: they never go out anyway") end
  if n > 0 then band.log(kept and (n .. " track(s) stay on this computer: nothing on them goes to the others") or (n .. " track(s) shared with the others again")) end
  if shared > 0 then band.msg(shared .. " of them already went to the others (or are a folder whose tracks aren't all selected), so they stay shared: made local they'd vanish for everyone.\n\n" ..
    "To keep a copy of your own, duplicate the track and keep the copy local.") end
end
-- (ui.set_local_mix: the switch, and the bindable action through "panel do")
function ui.set_local_mix(v)
  if v then reaper.SetProjExtState(proj, band.SECTION, "local_mix", "1"); require("mirror").begin_local_mix(proj); band.log("Local mixing is on: your faders and pan stay yours")
  else
    -- (named choices: as Yes/No, "No" sent your faders and pan to every bandmate: review, 2026-10-31)
    local take, send = "Use the studio's mix (your faders and pan follow theirs again)", "Send my faders and pan to everyone (the tracks I may change)"
    local r = band.pick({ "#Local mixing off: whose mix?", take, send, "Cancel (keep Local mixing on)" })
    if r == take or r == send then
      require("mirror").end_local_mix(proj, cfg, b.song, b.room, r == take)
      reaper.SetProjExtState(proj, band.SECTION, "local_mix", "")
    end
  end
end
local function local_mix_row()
  local on = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
  local ch, v = switch_row("##localmix", "Local mixing (your faders and pan stay yours)", on, "Nobody else's faders and pan reach you, and yours don't go out. Also as the action StudioSync - Local mixing.")
  if ch then ui.set_local_mix(v) end
end
-- A gap between two parts sharing a column.
function ui.spacer() ImGui.Dummy(ctx, 0, 2); ImGui.Separator(ctx); ImGui.Dummy(ctx, 0, 2) end
-- What StudioSync just did, in whatever height is left under something short (Settings > Console keeps all of it).
function ui.feed(apart) -- apart: a line between it and what's above
  if select(2, ImGui.GetContentRegionAvail(ctx)) < 90 then return end
  if apart then ui.spacer() end
  local h = select(2, ImGui.GetContentRegionAvail(ctx))
  heading("What just happened", 17)
  if ImGui.BeginChild(ctx, "feed", 0, h - ImGui.GetFrameHeightWithSpacing(ctx) - 4) then
    ImGui.PushTextWrapPos(ctx, 0)
    local lines = band.activity()
    if #lines == 0 then ImGui.TextDisabled(ctx, "Nothing yet: what you and the others do in this project shows here as it happens.") end
    for _, l in ipairs(lines) do ImGui.TextDisabled(ctx, l) end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndChild(ctx)
  end
end
-- Colours (James, 0.59.3: "colors should go under look"): the track colours you see here, and colouring the project.
function ui.settings_colours()
  if card("colours") then
    heading("Colours", 17)
    require("people").track_options(ctx, ImGui) -- whose colours tracks show here
    if b and can then require("colours").draw(ctx, ImGui, proj, cfg, function(name, tr) -- (a track you made is yours, as mirror.watch has it: Mac, 0.57.6)
      return can(cfg.user, name) or sync.maker_may(require("mirror").track_oid(tr), cfg.user, name, nil, who and who.mode)
    end, view.driver == cfg.user or (who and (who.mode == "open" or who.mode == "everyone")))
    elseif not b then ImGui.TextDisabled(ctx, "Colouring a project: open a studio project.") end
    card_end()
  end
end
-- Who drives, in Who can edit (James, 0.58.99: Take control and Always follow the driver sat with the people, away from who controls what).
function ui.driver_rows()
  if view.driver ~= cfg.user then -- (on its own line: beside the switch it moved it about. James, 0.59.3)
    if ImGui.SmallButton(ctx, "Take control") then action("Take control") end
    ImGui.SetItemTooltip(ctx, tostring(view.driver) .. " is driving. Take control to make what nobody has claimed follow you (tell them first).")
  end
  local on = reaper.GetExtState(band.SECTION, "follow driver") ~= ""
  local ch, v = switch_row("##followdriver", "Always follow the driver", on, "Your playhead, view and mix follow the driver: they press play, you play along, hearing what they hear. Only they record.")
  if ch then
    reaper.SetExtState(band.SECTION, "follow driver", v and "1" or "", true)
    if v then reaper.DeleteExtState(band.SECTION, "follow " .. tostring(proj), false) end
  end
end
-- The selected tracks dry, wet or auto here (James, 0.59.3: "an easy way to switch a track between wet and dry from the panel"; 0.59.4: "dry wet
-- auto like the other setting, and move it to advanced"). Only on this computer. Lit: what the first selected track does now.
function ui.track_plays_row()
  local prints = require("prints")
  local sel = reaper.GetSelectedTrack(proj, 0)
  local cur = sel and prints.track_choice(proj, sel) or nil
  if cur == "" then cur = ({ notes = "dry", sound = "wet" })[prints.mode()] or "auto" end -- (never set: as Parts play says)
  ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, "Selected tracks play:")
  for _, c in ipairs({ { "dry", "Dry" }, { "wet", "Wet" }, { "auto", "Auto" } }) do
    next_to(c[2]) -- (a narrow column cut Wet and lost Auto: review, 0.59.14)
    local here = sel and cur == c[1]
    if here then ImGui.PushStyleColor(ctx, ImGui.Col_Button, theme.SELECTED) end
    if ImGui.SmallButton(ctx, c[2] .. "##trackplays") then
      local n = reaper.CountSelectedTracks(proj)
      if n == 0 then band.msg("Select the tracks first.") else
        for i = 0, n - 1 do prints.set_track_choice(proj, reaper.GetSelectedTrack(proj, i), c[1]) end
        band.log(string.format("%d track%s: %s here", n, n == 1 and "" or "s", c[1]))
      end
    end
    if here then ImGui.PopStyleColor(ctx) end
    ImGui.SetItemTooltip(ctx, ({ dry = "Each part plays itself through the track's plug-ins (they come back on): try other effects here.",
      wet = "Each part plays the studio's print, exactly what was heard; the track's plug-ins are held off so nothing goes through them twice.",
      auto = "Through the track's plug-ins when every one of them loads here, else the studio's print." })[c[1]] ..
      "\nOnly on this computer. Also as actions, for the track's right-click menu: StudioSync - Selected tracks play dry / wet / as chosen.")
  end
  -- (one take a part, the one it plays, unless this is on: Live sync sets REAPER's Show all takes in lanes for each studio project. 0.59.13)
  local both = reaper.GetExtState(band.SECTION, "show both takes") == "1"
  local bch, bv = ImGui.Checkbox(ctx, "Show dry and wet takes##bothtakes", both)
  if bch then reaper.SetExtState(band.SECTION, "show both takes", bv and "1" or "", true) end
  ImGui.SetItemTooltip(ctx, "Off: each part shows only the take it plays (as Dry, Wet or Auto picks), so a big project stays compact.\n" ..
    "On: the dry take and the studio's print both show in each part, one above the other. Only on this computer.")
end
local function home_session()
  if card("session") then
    heading("Who can edit", 17)
    ImGui.SetItemTooltip(ctx, "Who changes what")
    section_driver()
    ui.driver_rows()
    local_mix_row()
    section_claims()
    card_end()
  end
end

local function home_rules()
  if ui.short then -- (the box and Local mixing share a row, and "Who controls" is the column's title)
    section_driver(function() next_to(ImGui.CalcTextSize(ctx, "Control your own mix") + ImGui.GetFrameHeight(ctx) * 2); local_mix_row() end)
    return ui.driver_rows()
  end
  heading("Who can edit", 17)
  ImGui.SetItemTooltip(ctx, "Who changes what")
  section_driver()
  ui.driver_rows()
  local_mix_row()
end
local function home_claims()
  heading("Claims", 17)
  section_claims()
end
-- What the others did here since you last had it open (lib/extras.lua), above Home until you say OK.
-- Tracks showing what came meanwhile (lib/people.lua, Show what's new) stay in their colours until this OK.
function ui.away()
  local a = require("extras").away(cfg, b)
  local where = b.song .. "/" .. b.room
  local held = require("people").held(where)
  if not (a.parts and #a.parts > 0) and held == 0 then return end
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx))
  if ImGui.SmallButton(ctx, "OK##away") then require("extras").away_seen(b); require("people").seen(where) end
  ImGui.SetItemTooltip(ctx, "Hide it until there's something new" .. (held > 0 and ", and put the tracks showing what changed back in the studio's colours." or "."))
  ImGui.SameLine(ctx)
  local parts = a.parts and #a.parts > 0 and table.concat(a.parts, "  ·  ") or ""
  if held > 0 then parts = parts .. (parts ~= "" and "  ·  " or "") .. held .. (held == 1 and " track shows" or " tracks show") .. " who changed it" end
  ImGui.TextColored(ctx, ACCENT, "Since you were last here" .. (a.since and (" (" .. require("chooser").ago(a.since, os.date("!*t")) .. ")") or "") .. ": " .. parts)
end
-- live ideas (what came over Real time or Time-sync, to keep or drop): on Home while either is on (James, 0.59.3: not in Chat)
local function home_ideas()
  if same_room_on() or page_play.time_sync_on() then
    if reaper.time_precise() - ideas_at > 2 then ideas_at, ideas = reaper.time_precise(), tools.ideas(proj) end
    if next(ideas) ~= nil and card("home ideas") then section_ideas(); card_end() end
  end
end
local function page_home()
  ui.away()
  if ui.short then -- (Real time had to be scrolled to, under the people: design review)
    -- (hearing or producing someone, Real time's column has rows and rows of controls: it takes the width from the others, so they all fit without scrolling)
    local busy = same_room_on() or require("producer").who(proj)
    -- (the ideas under Real time in its column: below the columns, which fill the page, they were out of reach. Layout review, 0.59.14)
    local play = function() home_play(); home_ideas() end
    layout(busy and { { play, 440 }, { home_who, 500 }, { home_rules, 300 }, { home_claims, 200 } }
      or { { play, 280 }, { home_who, 540 }, { home_rules, 340 }, { home_claims, 280 } })
  elseif wide then -- (a tall docker: the people as cards, and nothing left alone in a tall column)
    layout({ { function() home_play(); home_ideas(); ui.feed(true) end, 480 }, { home_who, 760 }, { function() home_rules(); ui.spacer(); home_claims() end, 480 } })
  else layout({ { home_who, 360 }, { home_session, 400 } }); home_ideas() end
  ui.hide_row()
end
-- Home's "Hide when not in use" (James, 0.58.98): the same as Settings > Look > When you click REAPER, shrinks to the tiny box or stays
-- in front. A floating panel only; the panel reopens to switch (ReaImGui sets a window's parent as it opens).
function ui.hide_row()
  if win_rect and win_rect.docked then return end
  ImGui.Spacing(ctx)
  local ch, v = ImGui.Checkbox(ctx, "Hide the panel when not in use##hiderow", behind == "box")
  ImGui.SetItemTooltip(ctx, "On: clicking a REAPER window it covers shrinks it to the tiny box; click the box, or the toolbar button, to bring it back.\n" ..
    "Other apps, dialog boxes and windows it doesn't cover (on another monitor) leave it open. Off: it stays in front.")
  if ch then
    reaper.SetExtState(band.SECTION, "panel behind", v and "box" or "front", true)
    reaper.SetExtState(band.SECTION, "panel page", "Home", false)
    reload_now = true
  end
end

local function settings_look()
  if card("look") then
    heading("Look", 17)
    do
      local pick = combo("Theme##theme", theme.name, theme.NAMES, "How the panel looks on this computer. It reopens to change.")
      if pick and pick ~= theme.name then
        reaper.SetExtState(band.SECTION, "theme", pick, true)
        -- (back where you were: it went to Home, a second trip here each time when comparing them: Mac, 0.45.0)
        reaper.SetExtState(band.SECTION, "panel page", "Settings", false); reaper.SetExtState(band.SECTION, "setup tab", "Look", false)
        reload_now = true
      end
    end
    if theme.name == "Custom" then -- your own theme: four colours, the rest worked out (it reopens when you let go of a colour)
      local c = theme.custom()
      for _, k in ipairs(theme.CUSTOM_KEYS) do
        require("colours").edit3(ctx, ImGui, k[2] .. "##themecustom" .. k[1], c[k[1]], function(v) -- (a steady wheel, and set when you let go: 0.59.7)
          c[k[1]] = v; theme.set_custom(c)
          reaper.SetExtState(band.SECTION, "panel page", "Settings", false); reaper.SetExtState(band.SECTION, "setup tab", "Look", false)
          reload_now = true
        end)
        ImGui.SameLine(ctx)
      end
      if ImGui.SmallButton(ctx, "Start again from Dark##themecustom") then
        reaper.DeleteExtState(band.SECTION, "theme custom", true)
        reaper.SetExtState(band.SECTION, "panel page", "Settings", false); reaper.SetExtState(band.SECTION, "setup tab", "Look", false)
        reload_now = true
      end
      ImGui.SetItemTooltip(ctx, "Your theme's four colours back to the Dark theme's.")
    end
    local ch, v = switch_row("##native", "System window frame", native,
      "On: the system's window frame instead of the panel's own title bar (no docking by dragging the title then: use Dock).\n" ..
      "Off (the default): the panel's own dark title bar; right-click it or use Dock to dock. The panel reopens to switch.\n" ..
      "Either way, the Window button fills a screen or half of one.")
    if ch then
      reaper.SetExtState(band.SECTION, "panel_native", v and "on" or "", true); reload_now = true
      reaper.SetExtState(band.SECTION, "panel page", "Settings", false); reaper.SetExtState(band.SECTION, "setup tab", "Look", false) -- (it went to Home)
    end
    local bon = reaper.GetExtState(band.SECTION, "banner") ~= "off"
    ch, v = switch_row("##banner", "Banner over REAPER while someone else drives", bon,
      "A slim note at the foot of REAPER's timeline saying what you can change (it never takes a click).")
    if ch then reaper.SetExtState(band.SECTION, "banner", v and "" or "off", true) end
    do -- when REAPER is clicked (0.58.87): behind it, in front, or the tiny box. ReaImGui sets a window's parent as it opens: the panel reopens
      local choices = { { "box", "Shrinks to the tiny box" }, { "front", "Stays in front" } }
      if can_behind then table.insert(choices, 2, { "behind", "Goes behind it" }) end
      local cur = choices[1]
      for _, c in ipairs(choices) do if c[1] == behind then cur = c end end
      ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, "When you click REAPER, the panel"); ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 190)
      if ImGui.BeginCombo(ctx, "##behind", cur[2]) then
        for _, c in ipairs(choices) do
          if ImGui.Selectable(ctx, c[2], c[1] == behind) and c[1] ~= behind then
            reaper.SetExtState(band.SECTION, "panel behind", c[1], true)
            reaper.SetExtState(band.SECTION, "panel page", "Settings", false); reaper.SetExtState(band.SECTION, "setup tab", "Look", false)
            reload_now = true
          end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.SetItemTooltip(ctx, "Floating only (docked, it's part of REAPER). Shrinks to the tiny box: the moment you click away; click the box, or the toolbar\n" ..
        "button, to bring it back where it was. Stays in front: on top of REAPER always." .. (can_behind and " Goes behind it: a window of its own, like any app's." or
        "\n(Going behind REAPER needs a newer ReaImGui: this one keeps its windows above REAPER.)"))
    end
    do -- a StudioSync button on REAPER's main toolbar (lib/tools.lua): on unless switched off, as Helgobox's (0.58.82)
      ch, v = switch_row("##tbbtn", "StudioSync button on REAPER's toolbar", tools.toolbar_button(),
        "A button at the end of REAPER's main toolbar that opens the panel, in the toolbar's own style (lit while the panel is open).\n" ..
        "On whatever main toolbar you have, customized or not, without changing your toolbar's own setup; a change shows within a second. Only on this computer.")
      if ch then
        local ok, why = tools.set_toolbar_button(v)
        if ok then band.log(v and "the StudioSync button joins the main toolbar" or "the StudioSync button leaves the main toolbar (one you added by hand stays: right-click it > Customize toolbar to remove it)")
        else band.msg(why) end
      end
      local blocked = tools.toolbar_button() and tools.toolbar_button_blocked()
      if blocked then ImGui.TextColored(ctx, YELLOW, blocked) end
    end
    card_end()
  end
end
local function settings_sync()
  if card("sync") then
    if b then section_sync() end
    -- MIDI wet/dry, this machine's choice (lib/prints.lua): never changes what anyone else hears
    -- (Dry and Wet read as an effect's mix knob, and as MIDI only: it's every part, audio too. UX review, 0.58.62)
    ImGui.SeparatorText(ctx, "Parts play (MIDI and audio)")
    -- (the selected tracks' own Dry / Wet / Auto: Settings > Advanced, 0.59.4)
    local prints = require("prints")
    -- (Dry / Wet / Auto, as the selected tracks' choice says it: "Through my plug-ins / As printed" was a second set of words. UX review, 0.59.14)
    for _, m in ipairs({ { "auto", "Auto", "Dry when every plug-in the part plays through loads here, else wet (the studio's print)." },
        { "notes", "Dry (my plug-ins)", "Always the part itself through your own plug-ins: a MIDI part's notes through your instruments, a recording through\n" ..
          "your amp sims and effects, so you can change the sound. A plug-in you don't have plays nothing." },
        { "sound", "Wet (studio's print)", "Always the studio's print: the part rendered through the track's plug-ins by whoever changed it, exactly what they heard." } }) do
      if m[1] ~= "auto" then next_to(m[2]) end -- (longer words now: onto the next line when they don't fit)
      if ImGui.RadioButton(ctx, m[2] .. "##midiplays", prints.mode() == m[1]) then
        reaper.SetExtState(band.SECTION, "midi_plays", m[1], true)
        if b then for i = 0, reaper.CountMediaItems(proj) - 1 do prints.choose(reaper.GetMediaItem(proj, i)) end end
      end
      ImGui.SetItemTooltip(ctx, m[3])
    end
    prints.options(ctx, ImGui) -- rendering in the background
    require("midiview").options(ctx, ImGui)
    local lch, lv = ImGui.Checkbox(ctx, "Live set: pause syncing while playing##liveset", reaper.GetExtState(band.SECTION, "live set") == "on")
    if lch then reaper.SetExtState(band.SECTION, "live set", lv and "on" or "", true) end
    ImGui.SetItemTooltip(ctx, "For playing a set: while REAPER plays, nothing is sent or taken in, so syncing can't make REAPER stutter.\n" ..
      "Everything catches up as soon as you stop. Only on this computer.")
    card_end()
  end
end
local call_draft, call_draft_for -- (the call link being typed, Settings > Studio; the studio it's for: another's showed. Review, 0.59.14)
-- Settings > Studio: what the studio shares beyond the projects, one card each, every card saying in a line what it's for and where it stands.
-- (they were four headings at the bottom of the Google Drive card, where nobody would look for them: 0.58.57)
local function studio_admin() return require("groups").role(cfg.root, cfg.user) ~= "member" end
local function needs_tailscale()
  local services = require("services")
  if services.tailscale_up() then return false end
  ImGui.TextColored(ctx, YELLOW, services.tailscale_installed() and "Needs Tailscale: open it and sign in." or "Needs Tailscale (tailscale.com/download, or run StudioSync's installer again).")
  return true
end
local function off_tailnet() -- (on another of your Tailscale accounts than the studio's: said here, and Health has the switch)
  local want = require("groups").tailnet(cfg.root)
  local name, suffix = require("services").tailnet_now()
  if want and suffix and want.suffix ~= suffix then
    ImGui.TextColored(ctx, YELLOW, "This computer is on the Tailscale network " .. tostring(name) .. ", and this studio uses " .. want.name .. ". Settings > Health can switch.")
    return true
  end
end
local function studio_alerts()
  if not card("studio alerts") then return end
  local alerts = require("alerts")
  ImGui.SeparatorText(ctx, "Phone alerts")
  ImGui.TextDisabled(ctx, "A notification on everyone's phone when someone sends a message, records, or renders a mix, even with REAPER closed.")
  local channel = alerts.channel(cfg.root)
  if studio_admin() then
    local ach, aon = check("On for this studio", channel ~= nil,
      "Each alert is one line through ntfy.sh (no audio, no project). Anyone who knew the studio's channel name could read them, so it's long and random.\n" ..
      "Turning it off and on makes a new channel: everyone subscribes again.")
    -- (off deletes the channel, and on makes a new one: every phone stops getting alerts until it subscribes again. Review, 0.59.14)
    if ach and not aon and reaper.MB("Turn phone alerts off for the studio?\n\nTurning them on again makes a new channel: everyone has to subscribe again.", "StudioSync", 4) ~= 6 then ach = false end
    if ach then alerts.set(cfg.root, aon) end
  end
  if channel then
    ImGui.Text(ctx, "On your phone:")
    ImGui.TextWrapped(ctx, "1. Install ntfy (free, Android or iPhone).  2. Tap +.  3. Paste this channel:")
    ImGui.TextColored(ctx, GREEN, channel)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Copy##alerts") then band.copy(channel, ctx, ImGui) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Send a test##alerts") then
      band.log(alerts.send(cfg, "test", "StudioSync: test", cfg.user .. " sent a test alert. If this reached your phone, alerts work.") and
        "a test alert went to the studio's channel" or "a test was sent less than a minute ago: wait a moment")
    end
  elseif not studio_admin() then
    ImGui.TextDisabled(ctx, "Off. The studio's owner or an admin turns them on here.")
  end
  card_end()
end
local function studio_call()
  if not card("studio call") then return end
  local alerts = require("alerts")
  ImGui.SeparatorText(ctx, "Studio call")
  ImGui.TextDisabled(ctx, "Talk and see each other in the app your band already uses (Discord, Zoom, Meet): everyone gets a Call button beside Real time mode.")
  local call = alerts.call_link(cfg.root)
  if studio_admin() then
    if call_draft_for ~= cfg.root then call_draft, call_draft_for = nil, cfg.root end
    call_draft = call_draft or call or ""
    ImGui.SetNextItemWidth(ctx, -110)
    local _, v = ImGui.InputTextWithHint(ctx, "##calllink", "paste the call's link (https://...)", call_draft)
    call_draft = v
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Save##calllink") then
      if call_draft == "" or alerts.call_ok(call_draft) then
        alerts.set_call(cfg.root, call_draft)
        band.log(call_draft == "" and "the studio's call link is gone" or "the studio's call link is set: everyone gets a Call button beside Real time mode")
      else band.msg("That isn't a plain https:// link. Copy it again from Discord, Zoom or Meet (no spaces, & or %).") end
    end
    ImGui.SetItemTooltip(ctx, "Discord: right-click the voice channel > Copy Link. Zoom or Meet: the meeting's invite link.")
  end
  if call then
    if not studio_admin() then ImGui.TextWrapped(ctx, "Call button opens: " .. call) end
    if ImGui.SmallButton(ctx, "Open the call##calllink") then band.open_url(call) end
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, "Mute its microphone while you play: Real time mode carries the music.")
  elseif not studio_admin() then
    ImGui.TextDisabled(ctx, "None yet. The studio's owner or an admin adds one here.")
  end
  card_end()
end
local function studio_listen()
  if not card("studio listen") then return end
  local listen = require("listen")
  ImGui.SeparatorText(ctx, "Listening page")
  ImGui.TextDisabled(ctx, "A web page of every song's mixes, to play on a phone or any browser without REAPER. Only devices on your Tailscale network reach it, while this computer is on.")
  local sharing = listen.sharing(cfg.root)
  if sharing then
    ImGui.TextWrapped(ctx, "Shared from this computer. Send the others this address:")
    ImGui.TextColored(ctx, GREEN, sharing)
    if ImGui.SmallButton(ctx, "Copy##listen") then band.copy(sharing, ctx, ImGui) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Open##listen") then band.open_url(sharing) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Stop sharing##listen") then listen.share(cfg, false) end
    off_tailnet()
  elseif not needs_tailscale() and not off_tailnet() then
    if ImGui.SmallButton(ctx, "Share the listening page") then
      local address, why = listen.share(cfg, true)
      if address then band.log("the listening page is shared: " .. address .. " (Copy it here to send it)") else band.msg(why) end
    end
    ImGui.SetItemTooltip(ctx, "A small server of StudioSync's own serves the page and the mixes (nothing else) on this computer, and Tailscale passes the others to it.\n" ..
      "It stops when REAPER closes; it comes back with REAPER while sharing is on.")
  end
  if not require("alerts").channel(cfg.root) then
    ImGui.TextDisabled(ctx, "Comments under each mix need phone alerts on (above): they land in the song's chat with the moment they're about.")
  end
  card_end()
end
local function studio_private_audio()
  if not card("studio audio") then return end
  local groups, services = require("groups"), require("services")
  ImGui.SeparatorText(ctx, "Private live audio")
  local shost = groups.sonobus_server(cfg.root)
  ImGui.TextDisabled(ctx, shost and "On: Real time mode's audio travels inside Tailscale's encryption." or
    "Off: Real time mode finds everyone through SonoBus's public server, and the audio itself isn't encrypted.")
  if shost then
    local mine = services.my_tailscale_name() == shost
    ImGui.TextWrapped(ctx, mine and "This computer is where the band meets: keep SonoBus's own app open here (Start menu: SonoBus) while you play."
      or ("The band meets through " .. shost .. ". Whoever's computer that is keeps SonoBus's own app open while you play."))
    off_tailnet()
  end
  if studio_admin() then
    if not shost and not needs_tailscale() and not off_tailnet() and ImGui.SmallButton(ctx, "Host it on this computer") then
      local name = services.tailscale_address()
      if name and name:find("%.ts%.net$") then
        groups.set_sonobus_server(cfg.root, name .. ":10999")
        groups.set_tailnet(cfg.root) -- (everyone on this network reaches it: Health tells those on another)
        band.log("private live audio is on: everyone's SonoBus meets through this computer next time Real time mode connects. Keep SonoBus's own app open here (Start menu: SonoBus)")
      else band.msg("Tailscale has its names turned off on this network (MagicDNS): turn them on at login.tailscale.com/admin/dns.") end
    end
    if not shost then
      ImGui.SetItemTooltip(ctx, "This computer becomes where the band meets: open SonoBus's own app here (not the plug-in) and keep it open while you play.\n" ..
        "Everyone's SonoBus then finds the others by their Tailscale addresses, so the audio goes inside Tailscale's encryption.")
    end
    if shost and ImGui.SmallButton(ctx, "Turn off (back to SonoBus's public server)") then
      groups.set_sonobus_server(cfg.root, nil)
      band.log("private live audio is off: SonoBus's public server again, next time Real time mode connects")
    end
  end
  card_end()
end
-- Sync only through the studio's Tailscale network (services.pin_tailnet, 0.58.80): with a studio on each network, switching networks
-- switches which studio syncs.
local function studio_tailscale_sync()
  if not card("studio tailscale") then return end
  local groups, services = require("groups"), require("services")
  ImGui.SeparatorText(ctx, "Sync through Tailscale")
  local t, on = groups.tailnet(cfg.root), groups.tailscale_only(cfg.root)
  if not t then
    ImGui.TextDisabled(ctx, "This studio has no Tailscale network yet: the button below gives it the one this computer is on (so does a guest invitation, private live audio or the listening page).")
  else
    ImGui.TextDisabled(ctx, on and ("On: everyone syncs with each other only at their Tailscale names on " .. t.name .. ", so the studio syncs while you're on that network.")
      or ("Off: Syncthing finds everyone its own way (Tailscale, your network or the internet). The studio's network is " .. t.name .. "."))
    if studio_admin() then
      local ch, v = ImGui.Checkbox(ctx, "Sync only through Tailscale##tsonly", on)
      -- (a confirm, as Use <network> has: on, it stops syncing for anyone not on that network. Review, 0.59.14)
      if ch and v and reaper.MB("Sync only through Tailscale (" .. t.name .. ")?\n\nAnyone in the studio who isn't on that Tailscale network stops syncing until they join it.",
          "StudioSync", 4) ~= 6 then ch = false end
      if ch then
        groups.set_tailscale_only(cfg.root, v)
        band.log(v and ("the studio syncs only through Tailscale (" .. t.name .. ") from now: each computer's name there takes a minute to reach the others")
          or "the studio syncs however Syncthing finds everyone again")
      end
      ImGui.SetItemTooltip(ctx, "Everyone needs Tailscale signed in to " .. t.name .. ". A computer whose name there isn't known yet is still found Syncthing's own way,\n" ..
        "until it has been on that network with StudioSync running. In two studios on two networks, switching networks switches which one syncs.")
    end
    off_tailnet()
  end
  -- (setting the studio's network directly, 0.58.94: before, only a guest invitation, private live audio or the listening page set it)
  local here_name, here = services.tailnet_now()
  if studio_admin() and here_name and here and (not t or t.suffix ~= here) then
    if ImGui.SmallButton(ctx, "Use " .. here_name .. " for this studio##usenet") then
      local go = not t or reaper.MB("This studio uses the Tailscale network " .. t.name .. " now. Move it to " .. here_name .. "?\n\n" ..
        "Everyone then needs Tailscale signed in to " .. here_name .. " for this studio: Health offers them the switch." ..
        (on and "\nSync only through Tailscale stays on, so whoever isn't on it stops syncing this studio until they switch." or "") ..
        "\nPrivate live audio or a listening page set up on " .. t.name .. " needs setting up again here.", "StudioSync", 1) == 1
      if go and groups.set_tailnet(cfg.root) then
        band.log("this studio uses the Tailscale network " .. here_name .. " from now" .. (on and ": it syncs only through it" or ""))
      end
    end
    ImGui.SetItemTooltip(ctx, "This computer is on " .. here_name .. ". The studio's guests, private live audio and listening page use its network,\n" ..
      "and with Sync only through Tailscale on, so does its file sharing.")
  end
  card_end()
end
-- Debug mode (James, 0.59.3): every computer in the studio saves its report, log and errors into _debug every 5 minutes (lib/debugmode.lua).
local function studio_debug()
  if not card("studio debug") then return end
  local groups, dm = require("groups"), require("debugmode")
  ImGui.SeparatorText(ctx, "Debug mode")
  local on = dm.on(cfg.root)
  ImGui.TextDisabled(ctx, on and ("On: every computer in the studio saves what it sees (versions, the project as it has it, what's waiting or was skipped, " ..
    "its log and errors) into the studio's _debug folder every 5 minutes, for working out what went wrong.") or
    "Off. On, every computer in the studio saves a report, its log and errors into the studio's _debug folder every 5 minutes.")
  if studio_admin() then
    local ch, v = ImGui.Checkbox(ctx, "Debug mode for everyone##studiodebug", on)
    if ch then
      groups.set_debug(cfg.root, v)
      band.log(v and "debug mode is on for the studio: reports go into _debug every 5 minutes" or "debug mode is off for the studio")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Each computer's files are written over each time (a few hundred KB each), and hold no keys or passwords.")
  end
  if ImGui.SmallButton(ctx, "Save a report now##debugnow") then
    local d = dm.write(cfg, proj, b)
    band.log("debug report saved: " .. tostring(d))
  end
  ImGui.SetItemTooltip(ctx, "This computer's report, log and errors into the studio's _debug folder now (with debug mode off too).")
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Open the _debug folder") then
    local d = cfg.root .. "/_debug"
    reaper.RecursiveCreateDirectory(d, 0)
    band.open_url(d)
  end
  card_end()
end
local function settings_studio()
  ImGui.TextDisabled(ctx, "For everyone in " .. band.info(cfg.root).name .. ". Only the owner and admins change these; everyone can use them.")
  layout({ { studio_alerts, 360 }, { studio_call, 360 }, { studio_private_audio, 360 }, { studio_tailscale_sync, 360 }, { studio_debug, 360 } }, true)
end
local function settings_drive()
  if card("drive") then
    section_drive()
    card_end()
  end
end
-- You: the same on this computer whatever's open.
function ui.settings_you()
  if card("you") then
    if not ui.short then heading("You", 17) end
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, "You're " .. cfg.user)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Change name") then
      local ok, name = reaper.GetUserInputs("StudioSync: your name", 1, "Your name (collaborators see it),extrawidth=120", cfg.user)
      name = ok and band.clean(name) or ""
      local mine, taken = require("services").my_device_id(), nil
      for _, g in ipairs(band.bands()) do
        local d = band.read_json(g.root .. "/_band/devices/" .. name:gsub("[^%w%-_ ]", "") .. ".json")
        if type(d) == "table" and d.device and mine and d.device ~= mine and name:lower() ~= cfg.user:lower() then taken = g.name end
      end
      if taken then band.msg("Another computer in " .. taken .. " is already called " .. name .. ". Pick a name of your own (say, " .. name .. "-Laptop)."); name = "" end
      if name ~= "" and name ~= cfg.user then
        reaper.SetExtState(band.SECTION, "user", name, true)
        band.rename_everywhere(cfg.user, name, cfg.root)
        cfg.user = name
      end
    end
    ImGui.SetItemTooltip(ctx, "Your name in StudioSync, everywhere (Who's here, claims, who drives). Your tracks stay yours, and\n" ..
      "the studio's machines learn the new name. Changes you made before keep the old one in Restore.")
    local function studios()
      local n = #require("page_groups").live_groups()
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, string.format("You're in %d studio%s", n, n == 1 and "" or "s"))
      ImGui.SameLine(ctx)
      -- (by asking: `page` is declared further down, so setting it here set a global and the button did nothing. tools/free_names.py, 0.58.48)
      if ImGui.SmallButton(ctx, "Your studios") then reaper.SetExtState(band.SECTION, "panel page", "Groups", false); require("page_groups").root = nil end
      ImGui.SetItemTooltip(ctx, "All of them: switch between them, invite people, rename, close or leave. The studio pill at the top goes there too.")
    end
    if wide then ImGui.SameLine(ctx, 0, 32); studios() end -- (docked: on your name's row, or it was below the fold)
    require("people").colour_options(ctx, ImGui, cfg)
    if not wide then ImGui.Spacing(ctx); studios() end
    ui.persona_row()
    card_end()
  end
end
-- Coming from another DAW: ReaPersona (REAPER set up to feel like it, by the same people). The installer asks; someone who joined with a
-- join code never met that question, so it's here too. (0.58.96, James: collaborators coming from another DAW)
local persona_at, persona_file = -math.huge, nil
function ui.persona_row()
  if reaper.time_precise() - persona_at > 5 then -- (looked for every few seconds, not every frame)
    persona_at, persona_file = reaper.time_precise(), nil
    local base = reaper.GetResourcePath() .. "/Scripts/ReaPersona"
    for _, f in ipairs({ base .. "/ReaPersona.lua", base .. "/Workflow/ReaPersona.lua", base .. "/ReaPersona/ReaPersona.lua" }) do
      if not persona_file and reaper.file_exists(f) then persona_file = f end
    end
  end
  ImGui.Spacing(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Coming from another DAW?")
  ImGui.SameLine(ctx)
  if persona_file then
    if ImGui.SmallButton(ctx, "Open ReaPersona") then
      local id = reaper.AddRemoveReaScript(true, 0, persona_file, true)
      if id > 0 then reaper.Main_OnCommand(id, 0) end
    end
    ImGui.SetItemTooltip(ctx, "ReaPersona makes REAPER's shortcuts, mouse and look feel like the app you know: Pro Tools, Logic, Ableton, FL Studio,\n" ..
      "Cubase, Nuendo, Studio One, GarageBand and more. Free, by the same people; switch back to plain REAPER any time.")
  elseif reaper.APIExists("ReaPack_AddSetRepository") then
    if ImGui.SmallButton(ctx, "Get ReaPersona") then
      local ok, err = reaper.ReaPack_AddSetRepository("ReaPersona", "https://raw.githubusercontent.com/FmsJay/ReaPersona/main/index.xml", true, 1)
      reaper.ReaPack_ProcessQueue(true)
      local sync = reaper.NamedCommandLookup("_REAPACK_SYNC")
      if ok and sync ~= 0 then reaper.Main_OnCommand(sync, 0) end
      band.log(ok and "ReaPersona is on its way: ReaPack brings it in a minute, then this button says Open ReaPersona" or ("couldn't add ReaPersona to ReaPack: " .. tostring(err)))
    end
    ImGui.SetItemTooltip(ctx, "ReaPersona makes REAPER's shortcuts, mouse and look feel like the app you know (Pro Tools, Logic, Ableton, FL Studio and more).\n" ..
      "Free, by the same people, through ReaPack like StudioSync; switch back to plain REAPER any time.")
  else
    ImGui.TextDisabled(ctx, "ReaPersona (REAPER that feels like your old app) comes through ReaPack: install ReaPack first (reapack.com).")
  end
end

-- What most people never need: Hold my changes causes more clashes than it saves, and prints happen by themselves.
function ui.settings_advanced()
  if card("advanced") then
    if not ui.short then heading("Advanced", 17) end
    if b then
      ui.track_plays_row() -- (from Who can edit and Options: James, 0.59.4)
      if ImGui.SmallButton(ctx, "Keep selected tracks local") then ui.keep_local() end -- (moved off Home: confusing beside claims. James, 0.59.3)
      ImGui.SetItemTooltip(ctx, "New tracks of your own that never go to the others: a reference mix, a guide, a scratch idea. Only tracks that haven't gone out yet\n" ..
        "(a shared one would vanish for everyone). Pressed again with only such tracks selected, it shares them.")
      local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
      local ch, v = switch_row("##hold", "Hold my changes", hold, "Try things: your changes go out once, when you switch this off. Anything someone else changes on the same parts meanwhile clashes with yours.")
      if ch then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
      require("prints").printing_ui(ctx, ImGui, cfg, b, proj, who)
      if ui.short then next_to("Prepare this project") end
      if ImGui.Button(ctx, "Prepare this project") then action("Prepare session") end
      ImGui.SetItemTooltip(ctx, "Takes into lanes, FLAC (recording and existing WAVs), clear track names, media in the project folder, tidy-up: a checklist first. A shared project's changes go to everyone.")
    end
    local cha, va = switch_row("##showadv", "Show advanced controls", ui.advanced(), "Side rooms, claiming regions and time, Solo and Produce, and the Plugins page.\nOff, each still shows when it's needed: a side room, a missing plug-in, someone you're producing.")
    if cha then reaper.SetExtState(band.SECTION, "show advanced", va and "1" or "0", true); ui.extra_at = -math.huge end
    local ch0, v0 = switch_row("##showplay", "Show the Play/Jam tab", ui.play_shown(), "Starting together, Play along and Jam. Play along and Jam go through NINJAM, which needs a server the others can reach.\nReal time mode, Follow and Solo don't need any of it.")
    if ch0 then reaper.SetExtState(band.SECTION, "show play", v0 and "1" or "", true) end
    local ch1, v1 = switch_row("##allactions", "Every StudioSync action in REAPER's Actions list", band.all_actions(),
      "For keyboard shortcuts and toolbar buttons: Hold my changes, Claim selected tracks, Local mixing, Take control and the rest.\n" ..
      "Off, the Actions list keeps what opens StudioSync (and Undo/Redo); one a key or a toolbar already uses stays either way.")
    if ch1 then
      reaper.SetExtState(band.SECTION, "all actions", v1 and "1" or "", true)
      local listed, out = band.sync_actions(dir)
      band.log(string.format("the Actions list has %d StudioSync action(s) now%s", listed, out > 0 and (" (" .. out .. " taken out)") or ""))
    end
    do -- Tailscale's API: guests until a day you pick, and the policy lines (lib/services.lua). Whoever runs the Tailscale network makes the token.
      local services = require("services")
      ImGui.Spacing(ctx)
      -- (one token per network, 0.58.94: someone running two studios' networks keeps a token for each)
      local nets = services.tailscale_token_nets()
      local here = select(2, services.tailnet_now())
      local function add_button(label)
        if ImGui.SmallButton(ctx, "Make a token") then band.open_url("https://login.tailscale.com/admin/settings/keys") end
        ImGui.SetItemTooltip(ctx, "Tailscale's Keys page, signed in to the account that runs the network: Generate access token. It lasts 1 to 90 days; copy it, then add it here.")
        next_to(label)
        if ImGui.SmallButton(ctx, label) then
          local ok, t = reaper.GetUserInputs("StudioSync: Tailscale access token", 1, "Token (tskey-api-...),extrawidth=260", "")
          t = ok and t:match("^%s*(tskey%-api%-[%w%-]+)%s*$")
          if t then
            local net, why = services.add_tailscale_token(t)
            band.log(net and ("Tailscale access token for " .. net .. " saved on this computer") or ("couldn't save the token: " .. tostring(why)))
          elseif ok then band.log("that isn't a Tailscale access token: it starts tskey-api-") end
        end
        ImGui.SetItemTooltip(ctx, "Kept for the Tailscale network it belongs to (Tailscale says which), so each studio's guests go on that studio's network.")
      end
      if #nets == 0 then
        ImGui.TextDisabled(ctx, "Run the studio's Tailscale network? An access token lets StudioSync put guests on your Tailscale network too, and set up its tags for you.")
        add_button("Add the token")
      else
        for _, net in ipairs(nets) do
          ImGui.AlignTextToFramePadding(ctx)
          ImGui.Text(ctx, net == "" and "Tailscale access token saved (StudioSync checks which network it's for the first time it's used)"
            or ("Tailscale access token for " .. net .. (net == here and " (this computer is on it)" or "")))
          next_to("Forget")
          if ImGui.SmallButton(ctx, "Forget##tstok" .. net) then
            services.set_tailscale_token("", net)
            band.log("Tailscale access token" .. (net ~= "" and (" for " .. net) or "") .. " forgotten on this computer")
          end
        end
        add_button("Add a token for another network")
        next_to("Set up the tags")
        if ImGui.SmallButton(ctx, "Set up the tags") then
         if services.tailscale_token(here) == "" then
          local have = {}
          for _, n in ipairs(services.tailscale_token_nets()) do if n ~= "" then have[#have + 1] = n end end
          band.msg(here and ("This computer is on " .. here .. ", and there's no access token for it here" .. (#have > 0 and (" (only for " .. table.concat(have, ", ") .. ")") or "") ..
            ".\n\nSwitch Tailscale to the network your token is for, or add a token for this one.") or "Tailscale isn't on here: turn it on (or sign in) first.")
         else
          local ok, how = services.tailscale_add_tags(function()
            return reaper.MB("Your Tailscale network lets every computer on it reach every other one, guests included.\n\n" ..
              "StudioSync can change that one rule so guests reach only its file sharing (Syncthing) and jams (NINJAM) on your computers. " ..
              "Your own computers and your collaborators' stay as they are.\n\nIf a later StudioSync needs more than that, its notes will say so.\n\nLimit what guests can reach?", "StudioSync", 4) == 6
          end, here)
          band.log(not ok and ("couldn't set up the tags: " .. tostring(how))
            or (how == "limited" or how == "has it") and "Tailscale's policy has StudioSync's tags, and guests reach only its file sharing and jams on your computers"
            or how == "own rules" and "Tailscale's policy has StudioSync's tags. It has rules of its own, so StudioSync left those alone: guests reach whatever they allow"
            or "Tailscale's policy has StudioSync's tags; guests can still reach whatever your policy allows")
         end
        end
        ImGui.SetItemTooltip(ctx, "Adds the tagOwners lines to the Tailscale network's policy: computers StudioSync's installer signs in then stay signed in,\n" ..
          "and guest invitations put guests on Tailscale too. On Tailscale's starting policy it also offers to limit guests to StudioSync's file sharing and jams.\n" ..
          "It works on the network this computer is on now" .. (here and (" (" .. here .. ")") or "") .. ", with that network's token.")
      end
    end
    card_end()
  end
end
function ui.settings_buffer()
  if card("rt buffer") then
    heading("Real time buffer", 17)
    ImGui.TextDisabled(ctx, "How much sound SonoBus keeps in hand, on this computer. More holds steadier and arrives later.")
    local sonobus = require("sonobus")
    local cur = reaper.GetExtState(band.SECTION, "rt buffer")
    cur = cur ~= "" and cur or "steady"
    for i, o in ipairs(sonobus.BUFFERS) do
      if ui.short and i > 1 then next_to(o[2]) end
      if ImGui.RadioButton(ctx, o[2], cur == o[1]) and cur ~= o[1] then
        reaper.SetExtState(band.SECTION, "rt buffer", o[1], true)
        if b and same_room_on() then setup.sonobus(cfg, b, proj, true) end
      end
    end
    ImGui.SetItemTooltip(ctx, "If Their time won't stay lined up, or it crackles, go up one. Over the internet nothing's instant: Real time on Wi-Fi landed about 200-300 ms behind in our tests.")
    heading("What you send", 15) -- (James, 0.58.87: uncompressed through SonoBus. lib/sonobus.lua sonobus.QUALITY)
    local q = reaper.GetExtState(band.SECTION, "rt quality")
    q = q ~= "" and q or "opus"
    for _, o in ipairs(sonobus.QUALITY) do
      if ImGui.RadioButton(ctx, o[2] .. "##rtq", q == o[1]) and q ~= o[1] then
        reaper.SetExtState(band.SECTION, "rt quality", o[1], true)
        if b and same_room_on() then setup.sonobus(cfg, b, proj, true) end
      end
    end
    ImGui.SetItemTooltip(ctx, "The sound you send each person over SonoBus. Uncompressed is exactly what you play, at the cost of more internet: 24-bit is about\n" ..
      "2.3 Mbit/s to each person (Opus 96, SonoBus's own, about 0.2). Fine on a home connection for a few people; if it starts to drop out, go back one.\n" ..
      "For a finished take, Swap in their own file (SonoBus Guest) or the take that syncs is the real thing anyway.")
    card_end()
  end
end
function ui.settings_cant_hear()
  if card("cant hear") then
    heading("Can't hear each other?", 17)
    ImGui.TextDisabled(ctx, "Real time goes straight between your computers: SonoBus's public server only introduces you. StudioSync tells you when SonoBus can't join at all, or when someone's playing and nothing's arriving. Then, in this order:")
    ImGui.BulletText(ctx, "Configure SonoBus (Home) shows each person and how their connection is doing. Disconnect and connect again.")
    ImGui.BulletText(ctx, "Wired internet, rather than Wi-Fi.")
    ImGui.BulletText(ctx, "Forward a UDP port on your router to this computer. SonoBus's options can fix the port it uses.")
    ImGui.BulletText(ctx, "A strict router or a work network can stop computers reaching each other directly. A VPN between you gets around that: Tailscale comes with StudioSync. Ask whoever runs the studio to invite you to its Tailscale network, and sign in from that invitation.")
    ImGui.BulletText(ctx, "On a Mac: System Settings > Privacy & Security > Microphone, with REAPER switched on. Without it, Talk and Real time send silence.")
    if ImGui.SmallButton(ctx, "Get Tailscale") then
      if reaper.CF_ShellExecute then reaper.CF_ShellExecute("https://tailscale.com/download") else band.msg("tailscale.com/download") end
    end
    require("callapps").card(ctx, ImGui, b and function() ui.go_page("Home") end) -- (Discord and the like beside REAPER: lib/callapps.lua)
    card_end()
  end
end
local function page_setup()
  if not ImGui.BeginTabBar(ctx, "setup", ImGui.TabBarFlags_FittingPolicyScroll) then return end -- (scrolls when narrow: squeezed, the names read "Hea... Con...")
  -- (the tabs stay put: only what's under them scrolls)
  local function body(id, fn)
    if ImGui.BeginChild(ctx, id, 0, 0, 0, wide and ImGui.WindowFlags_HorizontalScrollbar or 0) then
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetScrollY(ctx, 0) end -- (the red row and the newest lines were out of sight, where it had last been left: Mac, 0.57.7)
      ImGui.PushTextWrapPos(ctx, 0)
      ui.page_body(fn) -- (an error in a Settings tab left its child and tab open, and End killed the panel. Review, 0.59.14)
      ImGui.PopTextWrapPos(ctx)
      ImGui.EndChild(ctx)
    end
  end
  local go_tab = reaper.GetExtState(band.SECTION, "setup tab")
  if go_tab ~= "" then reaper.DeleteExtState(band.SECTION, "setup tab", false) end
  local function tab(name) return ImGui.BeginTabItem(ctx, name, nil, go_tab == name and ImGui.TabItemFlags_SetSelected or 0) end
  if b and tab("Health") then body("s health", function() maint_health(); if wide then ui.feed() end end); ImGui.EndTabItem(ctx) end
  if tab("You") then body("s you", ui.settings_you); ImGui.EndTabItem(ctx) end
  -- (the look in a tab of its own: Options was long. James, 0.58.99)
  if tab("Look") then body("s look", function() layout({ { settings_look, 360 }, { ui.settings_colours, 460 } }, true) end); ImGui.EndTabItem(ctx) end
  if tab("Options") then
    body("s options", function() layout({ { settings_sync, 420 }, { settings_drive, 360 } }, true) end)
    ImGui.EndTabItem(ctx)
  end
  if tab("Studio") then body("s studio", settings_studio); ImGui.EndTabItem(ctx) end
  if tab("Advanced") then body("s advanced", function() layout({ { ui.settings_advanced, 360 }, { ui.settings_buffer, 420 }, { ui.settings_cant_hear, 640 } }, true) end); ImGui.EndTabItem(ctx) end
  if tab("Console") then
    -- StudioSync's own log, newest first (REAPER's console only shows it while open)
    if ImGui.SmallButton(ctx, "Clear") then reaper.DeleteExtState(band.SECTION, band.LOG_KEY, false) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Copy") then band.copy(table.concat(band.activity(), "\n"), ctx, ImGui) end
    ImGui.SetItemTooltip(ctx, "Copy the whole log, to paste it in a message when something went wrong.")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Log files") then reaper.RecursiveCreateDirectory(band.log_dir(), 0); band.open_url(band.log_dir()) end
    ImGui.SetItemTooltip(ctx, "The folder with a log file per day (the last " .. band.LOG_DAYS .. " days): everything here, and every error with where it\n" ..
      "happened, written as it goes, so it's still there after a restart or a crash.")
    if ImGui.BeginChild(ctx, "console", 0, 0, ImGui.ChildFlags_Borders) then
      for _, l in ipairs(band.activity()) do ImGui.TextWrapped(ctx, l) end
      ImGui.EndChild(ctx)
    end
    ImGui.EndTabItem(ctx)
  end
  if tab("Updates") then body("s updates", function() layout({ { health.maint_upkeep, 1000 }, { health.about, 400 } }, true) end); ImGui.EndTabItem(ctx) end
  ImGui.EndTabBar(ctx)
end

local PAGES = {
  { "Projects", "This studio's projects, in their folders: open one, share one, file them, or free up space." },
  { "Home", "Who's here and what they're doing, real time mode, following and listening, and who changes what." },
  { "Rooms", "The project's rooms: make a side room to try things, have everyone come and see, and bring work back." },
  { "Play/Jam", "Start together, Play along and Jam (NINJAM). Settings > Advanced shows or hides this tab." },
  { "Chat", "Messages, to-dos, notes and links for this room, this project or the whole studio." },
  { "Restore", "Every change, and three ways back: the whole project, the selected tracks, or one change." },
  { "Mixes", "Render the mix, export stems, compare two mixes, a credits draft, studio templates, a copy outside the studio, and the listening page." },
  { "Plugins", "Every plug-in in this project, who doesn't have it, and the studio's stand-ins for it." },
  { "Settings", "You, options, health (red: needs fixing, yellow: worth a look), the console and updates." },
}
local LOBBY = { Groups = true, Projects = true, Settings = true } -- (what there is with no group project in front. Groups isn't a tab: the group pill goes there)
function ui.play_shown() return reaper.GetExtState(band.SECTION, "show play") == "1" end
-- Advanced controls (Settings > Advanced): side rooms, region and time claims, Solo and Produce, the Plugins page. Off, a first studio shows
-- what everyone needs; each still shows when it has something to say (a side room exists, a plug-in is missing, you're producing someone).
-- Whoever already had a studio before 0.58.47 starts with them on, so nothing they use disappears. (UX review, 0.58.47)
function ui.advanced()
  local v = reaper.GetExtState(band.SECTION, "show advanced")
  if v == "" then
    v = #band.bands() > 0 and "1" or "0"
    reaper.SetExtState(band.SECTION, "show advanced", v, true)
  end
  return v == "1"
end
ui.extra_at, ui.extra = -math.huge, {}
local function extras() -- (whether Rooms and Plugins have something to say: looked at every 5 s)
  if b and reaper.time_precise() - ui.extra_at > 5 then
    ui.extra_at = reaper.time_precise()
    ui.extra.rooms = b.room ~= "main" or #require("rooms").list(cfg, b.song) > 1
    local ok, miss = pcall(require("page_plugins").missing, proj, cfg)
    ui.extra.plugins = ok and miss
  end
  return ui.extra
end
function ui.pages()
  local out = {}
  for _, p in ipairs(PAGES) do
    local shown = (p[1] ~= "Play/Jam" or ui.play_shown()) and (ui.advanced() or (p[1] ~= "Rooms" or extras().rooms) and (p[1] ~= "Plugins" or extras().plugins))
    if b and p[1] ~= "Projects" and shown or not b and LOBBY[p[1]] then out[#out + 1] = p end
  end
  return out
end
local OLD_PAGES = { History = "Restore", Together = "Home", Live = "Home", Setup = "Settings", Maintenance = "Settings", Play = "Play/Jam" } -- (links from older versions)
local page = "Home"
local level, level_at = nil, -math.huge
local function nav_dot(p)
  if p == "Settings" and level then return level == "red" and RED or YELLOW end
end
-- The Dock button: left-click picks a side; right-click arms drag-to-dock (green) so moving the window around never
-- docks it by accident (unarmed, dragging docks only with Shift held). On the session's top bar and the start screen.
-- Follow a bandmate's view (lib/presence.lua): Live sync moves this arrange view to theirs, a few seconds behind.
tools.follow_button = function(name)
  local key = "follow " .. tostring(proj)
  local on = reaper.GetExtState(band.SECTION, key) == name
  if on then ImGui.PushStyleColor(ctx, ImGui.Col_Button, ACCENT) end
  if ImGui.SmallButton(ctx, (on and "Following" or "Follow") .. "##follow" .. name) then
    if on then reaper.DeleteExtState(band.SECTION, key, false) else
      reaper.SetExtState(band.SECTION, key, name, false)
      reaper.SetExtState(band.SECTION, "follow driver", "", true)
    end
  end
  if on then ImGui.PopStyleColor(ctx) end
  ImGui.SetItemTooltip(ctx, on and ("You follow " .. name .. ": their play, pause, stop and record, their view, and their mix. Click to stop: your own mix comes back.")
    or ("Follow " .. name .. ": your playhead goes with theirs (play, pause, stop, jumps; when they record you play along), your view goes where theirs is,\n" ..
      "and you hear their mix (faders, pan, what they've soloed; mutes are everyone's already). Your own mix comes back when you stop."))
end

-- Floating, one button for where the window goes: Dock and Full screen were two more, and the row wrapped. Right-click arms drag-to-dock, as Dock's did.
-- The page eases to where the wheel sends it, instead of jumping a few lines a notch (James, 0.58.23), drawn where it is on the way: it shook,
-- a jump ahead and a step back each notch (0.59.10). lib/smooth.lua. Dragging the scrollbar is left alone. Right after the page's BeginChild,
-- and ui.smooth_scroll_end before its EndChild (the content drawn higher keeps its height).
ui.scrolls = {}
function ui.smooth_scroll(key)
  local was = ui.scrolls[key]
  local st, off, set = require("smooth").step(was, ImGui.GetScrollY(ctx), ImGui.GetScrollMaxY(ctx) - math.max(0, was and was.off or 0), ImGui.IsMouseDown(ctx, 0))
  ui.scrolls[key] = st
  if off ~= 0 then ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + off) end
  if set then ImGui.SetScrollY(ctx, set) end
end
function ui.smooth_scroll_end(key)
  local st = ui.scrolls[key]
  if st and st.off < 0 then ImGui.Dummy(ctx, 1, -st.off) end
end
function ui.window_button(small)
  local armed = reaper.GetExtState(band.SECTION, "dock armed") ~= ""
  if armed then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF) end
  local clicked = (small and ImGui.SmallButton or ImGui.Button)(ctx, "Window")
  if armed then ImGui.PopStyleColor(ctx) end
  if ImGui.IsItemClicked(ctx, 1) then
    if armed then reaper.DeleteExtState(band.SECTION, "dock armed", false) else reaper.SetExtState(band.SECTION, "dock armed", "1", false) end
  end
  ImGui.SetItemTooltip(ctx, armed and "Drag-to-dock is on: drag the window onto a REAPER docker. Right-click to turn it off."
    or "Dock it, fill the screen it's on or half of it. Right-click: turn on drag-to-dock (or hold Shift while dragging).")
  if clicked then ui.window_menu() end
end
function ui.window_menu()
  local full = placed_how == "Fill this screen"
  local list = { "Dock at the bottom", "Dock at the left", "Dock at the right", full and "Exit full screen" or "Fill this screen" }
  for _, w in ipairs(WINDOW_MENU) do if w ~= "Fill this screen" then list[#list + 1] = w end end
  local pick = band.pick(list)
  local side = pick and ({ ["Dock at the bottom"] = 0, ["Dock at the left"] = 1, ["Dock at the right"] = 3 })[pick]
  if side then tools.dock_at(side)
  elseif pick == "Exit full screen" then place_window("Back to before")
  elseif pick then place_window(pick) end
end
-- Into REAPER's docker on that side (0 bottom, 1 left, 3 right): an empty one goes there if there's none.
tools.dock_at = function(pos)
  local found
  for i = 0, 15 do if reaper.DockGetPosition(i) == pos then found = i; break end end
  if found then dock_req = ~found -- (ReaImGui: dock id -1 is REAPER docker 0, -2 docker 1, ...)
  else
    local free = require("tools").free_docker()
    dock_req = ~free
    dock_side = { docker = free, action = pos == 1 and 41599 or 41601, since = reaper.time_precise() } -- Docker: Show in left / right of main window
  end
end
tools.dock_menu = function(docked, small)
  local armed = reaper.GetExtState(band.SECTION, "dock armed") ~= ""
  if armed then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF) end
  if (small and ImGui.SmallButton or ImGui.Button)(ctx, docked and "Undock" or "Dock") then
    if docked then dock_req = 0 else ImGui.OpenPopup(ctx, "dockside") end
  end
  if armed then ImGui.PopStyleColor(ctx) end
  if not docked and ImGui.IsItemClicked(ctx, 1) then
    if armed then reaper.DeleteExtState(band.SECTION, "dock armed", false) else reaper.SetExtState(band.SECTION, "dock armed", "1", false) end
  end
  ImGui.SetItemTooltip(ctx, docked and "Back to a window of its own." or (armed and "Drag-to-dock is on: drag the window onto a REAPER docker. Right-click to turn it off."
    or "Click: dock at the bottom, left or right of REAPER. Right-click: turn on drag-to-dock (or hold Shift while dragging)."))
  if ImGui.BeginPopup(ctx, "dockside") then
    for _, side in ipairs({ { "Bottom", 0 }, { "Left", 1 }, { "Right", 3 } }) do
      if ImGui.Selectable(ctx, side[1]) then tools.dock_at(side[2]) end
    end
    ImGui.EndPopup(ctx)
  end
end

-- Docked, or in the system's frame (no title bar of ours to put them on): to a strip, and to the small square.
function ui.window_buttons(at_row, y0, fh)
  local s = fh - 6
  at_row("  ")
  ImGui.SetCursorPosY(ctx, y0 + 3)
  if ui.window_icon("##tostrip", "line", s, "Minimize to a strip over REAPER. Click it and the panel opens where it was.") then ui.set_minimized("strip") end
  ImGui.SameLine(ctx, 0, 4); ImGui.SetCursorPosY(ctx, y0 + 3)
  if ui.window_icon("##tobox", "box", s, "Shrink to a tiny box over REAPER. Click it and the panel opens where it was.") then ui.set_minimized(true) end
end
-- A page asked for from elsewhere (a new room opens on Rooms; a project just opened, on Home).
function ui.asked_page()
  local want = reaper.GetExtState(band.SECTION, "panel page")
  if want ~= "" then reaper.DeleteExtState(band.SECTION, "panel page", false); page = OLD_PAGES[want] or want end
end
-- The panel goes with the tab in front: a group project opens on Home, anything else on Projects. (A project's own pages stay as you left them
-- when another group project comes to the front.)
function ui.front_changed()
  local now = b and tostring(proj) or ""
  if ui.front == now then return end
  local had = ui.front
  ui.front = now
  if had == nil then return end
  require("page_groups").root = nil
  if not b then page = "Projects"
  elseif had == "" or page == "Groups" or page == "Projects" then page = "Home" end
end
function ui.go_page(p) page = p end
function ui.go_chat(tab) page = "Chat"; require("page_chat").want_tab = tab end -- (Chat at one of its tabs: the phone on a card. 0.59.8)
function ui.go_settings(tab)
  page = "Settings"
  reaper.SetExtState(band.SECTION, "setup tab", tab, false)
end
-- Something stopped syncing, said by Autostart (with the panel closed it brings back the tiny box to say so).
function ui.page_body(fn)
  local cards = open_cards
  local ok, e = pcall(fn)
  if ok then return end
  err = tostring(e)
  for _ = cards + 1, open_cards do ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx) end
  open_cards = cards
end
function ui.sync_problem()
  local words = reaper.GetExtState(band.SECTION, "sync problem")
  if words == "" then return end
  ImGui.SetCursorPosX(ctx, 16)
  ImGui.TextColored(ctx, RED, words)
end
local function frame_app()
  local ww, wh = ImGui.GetWindowSize(ctx)
  local compact = wh < 440 or ww > wh * 2.4 -- a bottom dock: a row of pages instead of a sidebar
  if reaper.time_precise() - level_at > 2 then level_at, level = reaper.time_precise(), health.maint_level() end
  -- top bar: one row, every piece the height of a button
  local fh = ImGui.GetFrameHeight(ctx)
  wide = compact and ww > wh * 2
  -- docked at REAPER's left or right (narrow and tall): pages as a row of tabs, one column, never the sidebar
  local dock_id = ImGui.GetWindowDockID(ctx)
  local side = dock_id < 0 and reaper.DockGetPosition(~dock_id) -- (ReaImGui dock id -1 is REAPER's docker 0)
  if side == 1 or side == 3 or ww < 680 then compact, wide = true, false end -- (680: the sidebar took a quarter of a 600 px panel. Layout review, 0.59.14)
  -- (a docker as low as the mixer lets it go, 235 px here: every row above the page gets tight, and what's said in a line of words moves
  -- to a tooltip when it would push out what you press. Taller, the pages have room and rearrange: see page_home)
  ui.short = wide and wh < 320
  if ui.short then ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, 3); fh = ImGui.GetFrameHeight(ctx) end
  local function nav_item(p, w, h)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    if ImGui.Selectable(ctx, (compact and "" or "  ") .. p[1] .. "##nav", p[1] == page, ImGui.SelectableFlags_None, w, h) then page = p[1] end
    local c = nav_dot(p[1])
    ImGui.SetItemTooltip(ctx, p[2] .. (c and (level == "red" and "\n\nSomething needs fixing before the studio can sync: open it to see what."
      or "\n\nSomething is worth a look (or an extra isn't set up): open it to see, or dismiss it there.") or ""))
    if c then
      local iw = ImGui.GetItemRectSize(ctx)
      ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + iw - 10, y + h / 2, 4.5, c)
    end
    if p[1] == page and not compact then ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x - 8, y + 6, x - 4, y + h - 6, ACCENT, 2) end
  end
  local y0 = ImGui.GetCursorPosY(ctx) + (ui.short and -4 or 8)
  ImGui.SetCursorPos(ctx, 16, y0)
  if ui.crumb(view.group or "", 0, 1 / 3, fh, "The studio this project belongs to. Click: all your studios.") then page = "Groups"; require("page_groups").root = nil end
  local function at_row(label) -- next to the last piece, or on a new line when `label`'s piece doesn't fit
    ImGui.SameLine(ctx, 0, 8)
    if label and ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, label) + 24 then
      ImGui.SetCursorPos(ctx, 16, y0 + fh + 6)
      y0 = y0 + fh + 6
    else
      ImGui.SetCursorPosY(ctx, y0)
    end
  end
  local key = tostring(proj)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
  local running = beat and reaper.time_precise() - beat < 5
  at_row(b.song)
  if ui.crumb(b.song, 1 / 3, 2 / 3, fh, "The project in this tab. Click: this studio's projects.") then page = "Projects"; require("page_groups").root = cfg.root end
  if ui.advanced() or extras().rooms then -- (one room: nothing to say)
    at_row(b.room)
    if ui.crumb(b.room, 2 / 3, 1, fh, "The room this tab is in. Click: the Rooms page.") then page = "Rooms" end
  end
  -- what sync is actually doing, not just whether it runs ("Sync on" was green with nothing reaching anyone: review)
  local label, colour, tip = "Sync off", RED, "Live sync is off in this tab."
  if running then
    local online, behind, lines = 0, {}, {}
    for _, r in ipairs(view.rows) do
      local here = r.state ~= "offline" and r.state ~= "no receipt"
      if here then online = online + 1 end
      if here and r.state == "syncing" then behind[#behind + 1] = r.name end
      lines[#lines + 1] = r.name .. ": " .. (not here and "not here (gets your changes when back)" or r.state == "syncing" and "still getting changes" or "has everything")
    end
    if (view.my_pending or 0) > 0 then label, colour = string.format("Receiving %d", view.my_pending), YELLOW
    elseif #behind > 0 then label, colour = "Sending", YELLOW -- (who to: Who's here; names here crowded the bar, James)
    elseif online == 0 then label, colour = "Sync on", GREEN -- (Who's here says nobody else is: James)
    else label, colour = "Synced", GREEN end
    tip = "Live sync is running in this tab: your takes and changes go out, the studio's come in." .. (#lines > 0 and ("\n\n" .. table.concat(lines, "\n")) or "")
  end
  local driver_gone = reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) ~= "" or reaper.GetExtState(band.SECTION, "driver_away " .. tostring(proj)) ~= "" -- (Mac, 0.58.5: "James drives" beside "you have full control")
  local drives = view.driver == cfg.user and "you drive" or view.driver and (view.driver .. (driver_gone and " drives (away)" or " drives")) or "nobody drives yet"
  ui.status = { label = label, colour = colour, tip = tip, drives = drives }
  local is_copy = not running and rooms.is_copy(proj, cfg, b)
  local elsewhere = not running and not is_copy and band.synced_elsewhere(proj)
  local can_start = not running and not is_copy and not elsewhere
  at_row(can_start and "Sync off  -  click to start" or label)
  if ImGui.GetCursorPosX(ctx) > 17 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + 20) end -- (apart from the coloured crumbs: those say where you are, this how sync is going)
  if ui.sync_button(label, colour, running, can_start, fh) then
    reaper.DeleteExtState(band.SECTION, "stop " .. key, false)
    band.start_live(dir)
  end
  ImGui.SetItemTooltip(ctx, can_start and "Live sync is off in this tab: nothing goes out or comes in. Click to start it." or tip)
  if select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= "" then -- (Hold my changes was invisible once on: review)
    local n = tonumber(reaper.GetExtState(band.SECTION, "held " .. key)) or 0
    local held = n > 0 and string.format("Holding %d change%s", n, n == 1 and "" or "s") or "Holding your changes"
    at_row(held); pill(held, YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "Hold my changes is on: what you change stays here until you send it.")
    at_row("Send now")
    if ImGui.SmallButton(ctx, "Send now##hold") then reaper.SetProjExtState(proj, band.SECTION, "hold", "") end
    ImGui.SetItemTooltip(ctx, "Switch Hold my changes off: everything you changed goes to the others.")
  end
  do -- two people armed on one track: both record onto it at once (review item 33)
    local mine, both = {}, {}
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      if require("live").armed(tr) then mine[select(2, reaper.GetTrackName(tr))] = true end
    end
    for _, r in ipairs(view.rows) do
      if r.state ~= "offline" then
        for _, t in ipairs(r.armed or {}) do if mine[t] then both[#both + 1] = r.name .. " (" .. t .. ")" end end
      end
    end
    if #both > 0 then
      local armed = "Armed together: " .. table.concat(both, ", ")
      at_row(armed); pill(armed, YELLOW, DARK, fh)
      ImGui.SetItemTooltip(ctx, "You and they both have this track armed: if you both record, two takes land on it at once.\n" ..
        "Fine for trying parts; otherwise agree who records it, or record onto a track of your own.")
    end
  end
  if is_copy then
    at_row("older copy")
    pill("older copy", YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "A backup or autosave of this project, not your working copy of it. Nothing goes in or out of it.")
  elseif elsewhere then -- (a second copy of the song: syncing it would work on a stale one)
    at_row("open in another tab")
    pill("open in another tab", YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "This project is already open and syncing in another tab: work there. This tab is a second copy, not synced.")
  end -- (Start was a button here: the sync button starts it now. Stop is in Settings: nobody needs it at hand)
  at_row(drives)
  ImGui.SetCursorPosY(ctx, y0 + (fh - ImGui.GetTextLineHeight(ctx)) / 2) -- (not AlignTextToFramePadding: it carries along the row, and the page tabs sat low: design review)
  ImGui.TextDisabled(ctx, drives)
  do -- (what driving means in the mode the studio is in: it said claims-and-driver in the default, where anyone changes what's unclaimed. UX review, 0.59.14)
    local m = (who and who.mode) or sync.DEFAULT_MODE
    local said = MODE_INFO[1][3]
    for _, x in ipairs(MODE_INFO) do if x[1] == m then said = x[3] end end
    ImGui.SetItemTooltip(ctx, "The driver's play, stop and place in the song go to everyone. Who changes what:\n" .. said)
  end
  -- (no buttons for these: Ctrl+Z and Ctrl+Shift+Z do it, and Edit > Undo: Live sync steps in. The radial menu still asks for them here.)
  local function undo_redo(redo) -- (lib/undo.lua: the same as the StudioSync - Undo / Redo actions, but always asks)
    local res, why = require("undo").step(proj, cfg, b, redo, { ask = true, describe = describe })
    if res then band.log(res) elseif why then band.msg(why) end
    restore.refresh_soon()
  end
  local tabs_below = false
  if wide then -- the pages, in the bar
    -- (a docker that isn't the whole width, the mixer beside it: they ran off the right, Settings with them. Then under the bar, as when
    -- narrow. Layout review, 0.59.14)
    local tw = 24
    for _, p in ipairs(ui.pages()) do tw = tw + ImGui.CalcTextSize(ctx, p[1]) + 30 + (nav_dot(p[1]) and 12 or 0) end
    local wl = { "Feedback", "Sync and exit" }
    if ImGui.IsWindowDocked(ctx) or native then wl[#wl + 1] = "Window"; wl[#wl + 1] = "Undock" end
    local wneed = 2 * (fh - 6) + 28
    for _, l in ipairs(wl) do wneed = wneed + ImGui.CalcTextSize(ctx, l) + 28 end
    ImGui.SameLine(ctx, 0, 0)
    tabs_below = ImGui.GetContentRegionAvail(ctx) < tw + wneed
  end
  if wide and not tabs_below then -- the pages, in the bar
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 0) -- (a selectable grows by the spacing: the highlight stood taller than the pills)
    for i, p in ipairs(ui.pages()) do
      ImGui.SameLine(ctx, 0, i == 1 and 24 or 2)
      -- (they stay put: going by the status beside them, they slid when "In sync" became "Receiving 13", under the mouse)
      if i == 1 then tabs_at = math.max(math.min(tabs_at, ww * 0.4), ImGui.GetCursorPosX(ctx)); ImGui.SetCursorPosX(ctx, tabs_at) end
      ImGui.SetCursorPosY(ctx, y0)
      nav_item(p, ImGui.CalcTextSize(ctx, p[1]) + 28 + (nav_dot(p[1]) and 12 or 0), fh)
    end
    ImGui.PopStyleVar(ctx, 2)
    if wh < y0 + fh + 60 then
      local words = "Too short to show a page: drag the line above the docker's tabs up."
      ImGui.SameLine(ctx, 0, 16)
      ImGui.SetCursorPosY(ctx, y0 + 3)
      if ImGui.GetContentRegionAvail(ctx) <= ImGui.CalcTextSize(ctx, words) + 240 then words = "Too short: drag it up" end -- (pressing a page showed nothing, with no hint: Mac, 0.57.7)
      if ImGui.GetContentRegionAvail(ctx) > ImGui.CalcTextSize(ctx, words) + 240 then ImGui.TextColored(ctx, YELLOW, words) else ImGui.Dummy(ctx, 0, 0) end
    end
  end
  local docked = ImGui.IsWindowDocked(ctx)
  -- the window's own buttons sit at the right end of the bar (when they fit there), apart from the session's
  local bar_min = docked or native -- (no title bar of ours to put it on: else it sits by the close button)
  -- (Window and Dock: on the title bar when the panel has its own, else here, and never folded into "...": they went missing at some sizes. James, 0.58.23)
  local labels = bar_min and { "Feedback", "Sync and exit", "Window", docked and "Undock" or "Dock" } or { "Feedback", "Sync and exit" }
  local need = bar_min and 2 * (fh - 6) + 28 or 0 -- (the two window icons: as a word's width, the second fell off the right edge)
  for _, l in ipairs(labels) do need = need + ImGui.CalcTextSize(ctx, l) + 28 end
  ImGui.SameLine(ctx, 0, 8)
  local room = ImGui.GetContentRegionAvail(ctx)
  local toast_place
  if ww >= 520 and room - need > 160 then -- (the bar has room: a blank line under it cost a short docker 30 px for something shown 6 s at a time)
    local tx = ImGui.GetCursorScreenPos(ctx)
    local _, ty = ImGui.GetWindowPos(ctx)
    toast_place = { x = tx + 8, y = ty + y0 + (fh - ImGui.GetTextLineHeight(ctx)) / 2, w = room - need - 16 }
  else -- (no room in the bar: over the top of the page while it's being said. A blank row for it cost every page 30 px, for something shown 6 s at a time)
    toast_place = { x = ImGui.GetWindowPos(ctx) + 16, w = ww - 32, over = true }
  end
  if ww < 600 then -- (narrow: a short "Leave", as "Window" wrapped alone onto a row of its own: design review. Not "...": leaving is the one
    -- thing everyone has to find. UX review, 0.58.47)
    at_row("Feedback")
    require("feedback").button(ctx, ImGui)
    at_row("Exit")
    if ImGui.Button(ctx, "Exit##leave") then require("leave").start(proj, cfg, b) end
    ImGui.SetItemTooltip(ctx, "Sync and exit: saves, gets everything you've done out to the others, says who has it, then lets you close the project or quit REAPER.")
  else
    if room > need + 12 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + room - need); ImGui.SetCursorPosY(ctx, y0)
    else at_row("Feedback") end
    require("feedback").button(ctx, ImGui) -- (bug reports, feedback, feature requests: James, 0.58.79)
    at_row("Sync and exit")
    if ImGui.Button(ctx, "Sync and exit") then require("leave").start(proj, cfg, b) end
    ImGui.SetItemTooltip(ctx, "Leaving? Saves, gets everything you've done out to the others, says who has it, then lets you close the project or quit REAPER.")
  end
  if bar_min then
    at_row("Window")
    ui.window_button()
    at_row(docked and "Undock" or "Dock")
    tools.dock_menu(docked)
  end
  if bar_min then ui.window_buttons(at_row, y0, fh) end
  ImGui.SetCursorPos(ctx, 16, y0 + fh + (ui.short and 2 or 5)) -- (closer to the page: more of it shows, docked above all. James, 0.58.23)
  -- narrow: the pages first, so a row arriving under them can't slide them from under the mouse (design review)
  if (compact and not wide) or tabs_below then
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    for i, p in ipairs(ui.pages()) do
      local w = ImGui.CalcTextSize(ctx, p[1]) + 28 + (nav_dot(p[1]) and 12 or 0)
      if i > 1 then
        ImGui.SameLine(ctx, 0, 2)
        if ImGui.GetContentRegionAvail(ctx) < w then ImGui.NewLine(ctx); ImGui.SetCursorPosX(ctx, 16) end -- (a narrow panel lost Plugins and Setup off the right)
      end
      nav_item(p, w, fh)
    end
    ImGui.PopStyleVar(ctx)
    ImGui.SetCursorPosX(ctx, 16)
  end
  -- what StudioSync just did, under the bar for a few seconds (actions used to report only to the Console)
  local log = band.activity()
  local newest = log[1]
  if newest ~= tools.toast_newest then
    local before = tools.toast_newest
    tools.toast_newest = newest
    -- (a routine count doesn't push out what's being said: a first comp's warning lasted an instant, Mac 0.42.27. Both can arrive
    -- between two frames, the count on top, so this looks through all that's new: Mac, 0.45.0)
    -- (routine counts don't pop up: they flashed by all session. UX review, 0.59.14)
    local routine = function(l)
      for _, r in ipairs({ "change(s) went to the others", "went to the others", "from the others (", "Google Drive copy up to date", "caught up on ",
          "Syncthing's studio folder tuned", "Syncthing is answering" }) do
        if l:find(r, 1, true) then return true end
      end
    end
    local say = newest
    for _, l in ipairs(log) do
      if l == before then break end
      if not routine(l) then say = l; break end
    end
    local saying = tools.toast_at and reaper.time_precise() - tools.toast_at < 6
    local kept = band.json_decode(reaper.GetExtState(band.SECTION, "put back"))
    local in_bar = kept and kept.text and say and say:find(kept.text, 1, true) -- (the bar says it and stays: Mac, 0.57.6)
    if not in_bar and not (saying and say and routine(say)) then
      tools.toast_line, tools.toast_at = say, tools.toast_seen and reaper.time_precise() or -math.huge
    end
  end
  tools.toast_seen = true -- (opening the panel doesn't replay the old newest line)
  local saying = tools.toast_line and reaper.time_precise() - tools.toast_at < 6 and tools.toast_line or nil
  if toast_place and toast_place.over then
    local tx, ty = toast_place.x, select(2, ImGui.GetWindowPos(ctx)) + y0 + fh + 8
    toast_place.y = ty
    if saying then ImGui.DrawList_AddRectFilled(ImGui.GetForegroundDrawList(ctx), tx - 6, ty - 3, tx + toast_place.w + 6, ty + ImGui.GetTextLineHeight(ctx) + 5, theme.BG, 4) end
  end
  tools.toast_show(ctx, ImGui, saying, toast_place)
  local bars_at = ImGui.GetCursorPosY(ctx)
  ImGui.SetNextWindowSizeConstraints(ctx, 0, 0, 100000, (wide or wh < 440) and (ImGui.GetFrameHeightWithSpacing(ctx) * 3 + 2) or wh * 0.25) -- (3 rows: review, 0.59.14)
  local bars_open = ImGui.BeginChild(ctx, "bars", 0, 0, ImGui.ChildFlags_AutoResizeY)
  if bars_open then ImGui.Indent(ctx, 16) end
  -- (they read files bandmates write: one malformed file threw inside this child, and End then found it open and the whole panel died. Review, 0.58.92)
  local bars_ok, bars_err = pcall(function()
  tools.removed_bar(ctx, ImGui)
  ui.sync_problem()
  require("leave").draw(ctx, ImGui)
  tools.invite_popup(ctx, ImGui)
  page_rooms.invites()
  tools.join_requests(ctx, ImGui) -- (someone asking to join the band folder)
  if b and can then -- (an edit touching a claim, before the rest: lib/suggest.lua)
    require("suggest").bar(ctx, ImGui, proj, cfg, sync.room_dir(cfg, b.song, b.room), can, select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1")
  end
  for p in pairs(just_looked) do if not reaper.ValidatePtr(p, "ReaProject*") then just_looked[p] = nil end end
  if b and rooms.is_copy(proj, cfg, b) and not band.live_here(proj) then -- (lib/rooms.lua: a backup or autosave, opened by hand)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, YELLOW)
    ImGui.TextWrapped(ctx, "This is a backup or autosave of '" .. b.song .. "', not your project for it. Nothing goes in or out of it.")
    ImGui.PopStyleColor(ctx)
    if just_looked[proj] ~= tostring(reaper.GetTrack(proj, 0)) then
      if ImGui.SmallButton(ctx, "Open as a side room") then
        local p, what = rooms.from_backup(proj, cfg, b)
        if not p then band.msg(what) else
          band.log("this backup is now the side room '" .. what .. "': Bring into main offers what nobody has, Send selected anything else")
          if not live_running(p) then band.start_live(dir) end
          reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
          page_rooms.reset()
          local copy = proj
          reaper.defer(function() -- (its own tab goes: two of a room's tabs, and rooms.tab can't tell which is which)
            if reaper.ValidatePtr(copy, "ReaProject*") and reaper.IsProjectDirty(copy) == 0 then
              local front = reaper.EnumProjects(-1)
              reaper.SelectProjectInstance(copy)
              reaper.Main_OnCommand(40860, 0)
              if front ~= copy then reaper.SelectProjectInstance(front) end
            elseif reaper.ValidatePtr(copy, "ReaProject*") then -- (closing would ask to save: it's in the room now, and pressing again here would make another room)
              just_looked[copy] = tostring(reaper.GetTrack(copy, 0))
              band.log("the backup's tab stays open, as it has changes: they're in the room now. Close it without saving when you like")
            end
          end)
        end
      end
      ImGui.SetItemTooltip(ctx, "A side room with this copy in it, yours to drive. Nobody else's project changes. From there, Bring into main offers what nobody has, and Send selected sends anything you pick.")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Just look") then just_looked[proj] = tostring(reaper.GetTrack(proj, 0)) end
      ImGui.SetItemTooltip(ctx, "Leave it as it is, for looking or for copying things out of by hand.")
    elseif (rooms.file_of(proj) or "") == "" then
      ImGui.TextDisabled(ctx, "If this really is your project, save it under a name first: File > Save project as.")
    else
      if ImGui.SmallButton(ctx, "Make this my project") and reaper.MB("Sync this copy as your project for '" .. b.song .. "'?\n\n" ..
          "What the studio has changed since comes in over it, and any edits in it on your own tracks go to everyone.", "StudioSync", 4) == 6 then
        band.start_live(dir)
      end
      ImGui.SetItemTooltip(ctx, "For when this really is your project (the folder moved, say). Otherwise use a side room.")
    end
  end
  tools.put_back_bar(ctx, ImGui, b and b.song, b and can and function(mine) -- (an edit of yours that was undone, and why: stays until dismissed)
    band.log(tostring(require("mirror").use_mine(proj, cfg, b.song, b.room, mine, { can = can, mode = who and who.mode,
      local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" })))
  end, function(name) return can(cfg.user, name) end, b and function(name) claim({ name }, {}) end)
  tools.print_problem_bar(ctx, ImGui)
  end)
  if bars_open then ImGui.Unindent(ctx, 16); ImGui.EndChild(ctx) end
  -- (said once in the console; the rest of the panel goes on: `err` swapped the whole panel for the error page, and refresh cleared it, so it
  -- was said again every 1.5 s. 0.58.93)
  if not bars_ok and bars_said ~= tostring(bars_err) then bars_said = tostring(bars_err); reaper.ShowConsoleMsg("StudioSync panel: " .. bars_said .. "\n") end
  local _, bars_h = ImGui.GetItemRectSize(ctx)
  if bars_h < 6 then ImGui.SetCursorPosY(ctx, bars_at) end -- (nothing in them: no gap. An empty child is still 4 px tall, and 8 more of spacing)
  ui.asked_page()
  local want
  want = reaper.GetExtState(band.SECTION, "panel do") -- a choice from the radial menu
  if want == "" then want = require("api").take_request() or "" end -- (a script's, through the API: lib/api.lua)
  if want ~= "" then
    reaper.DeleteExtState(band.SECTION, "panel do", false)
    if want == "undo" or want == "redo" then undo_redo(want == "redo")
    elseif want == "realtime" and b then -- (as the switch does: the way picked last, or off. Review, 0.59.8)
      ui.rt_switch(not ui.rt_kind())
    elseif want == "chat" then page = "Chat"
    elseif want:match("^history") then page = "Restore"
    -- (the bindable actions, power-user review 0.58.62: each does what its control on the panel does)
    elseif want == "hold" then
      local on = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) == ""
      reaper.SetProjExtState(proj, band.SECTION, "hold", on and "1" or "")
      band.log(on and "Hold my changes is on: what you change stays here until you switch it off" or "Hold my changes is off: what you changed goes to the others")
    elseif want == "localmix" then ui.set_local_mix(select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) ~= "1")
    elseif want == "claim" and who and who.mode == "admins" and not require("groups").may_manage(cfg.root, cfg.user) then
      band.msg("Admins only here: an admin can give you tracks to work on.") -- (as the panel hides its button: Review, 0.58.67)
    elseif want == "claim" then
      local list = {}
      for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
      if #list == 0 then band.msg("Select the tracks you want to own first.") else claim(list, {}); band.log("claimed " .. table.concat(list, ", ")) end
    elseif want == "keeplocal" then ui.keep_local()
    elseif want == "takecontrol" then dofile(dir .. "/StudioSync - Take control.lua")
    elseif want:match("^timesync") and b then -- ("timesync" flips it; "timesync on" / "timesync off": a script's, or an action. 0.59.1)
      local on = want == "timesync on" or (want == "timesync" and not page_play.time_sync_on())
      if on ~= page_play.time_sync_on() then page_play.time_sync(on) end
    elseif want:match("^chat ") and b then require("page_chat").post(cfg, b, (want:sub(6, 505):gsub("%c", " "))) end -- (a script's: one line, 500 characters. Security review, 0.58.67)
  end
  if ui.short then ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 1) end
  ImGui.Separator(ctx)
  if ui.short then ImGui.PopStyleVar(ctx, 2) end -- (and the frame padding from the top of the bar)
  if not compact then
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, NAV)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 10)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0, 0.5)
    if ImGui.BeginChild(ctx, "nav", 150, 0, ImGui.ChildFlags_AlwaysUseWindowPadding) then
      ImGui.PushFont(ctx, nil, 16)
      for _, p in ipairs(ui.pages()) do nav_item(p, 0, 36) end
      ImGui.PopFont(ctx)
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleVar(ctx, 2)
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx, 0, 0)
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, ui.short and 4 or 12)
  -- (rows coming or going above it move the page under the mouse: its buttons wait a moment too, or a Remove or Restore could take a click aimed elsewhere)
  local settling = require("suggest").settling()
  ImGui.BeginDisabled(ctx, settling)
  if wide then -- (two full-size buttons filled a short column: design review)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, ui.short and 3 or 4)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 5)
  end
  local was_wide = wide
  local scroll_key = page -- (the page may change below: its end goes with its start)
  if ImGui.BeginChild(ctx, "page", 0, 0, ImGui.ChildFlags_AlwaysUseWindowPadding, wide and ImGui.WindowFlags_HorizontalScrollbar or 0) then
    ui.smooth_scroll(scroll_key)
    ImGui.PushTextWrapPos(ctx, 0) -- text wraps to the page, whatever its width
    if page == "Play/Jam" and not ui.play_shown() then page = "Home" end
    if page == "Groups" then ui.page_body(function() require("page_groups").draw_groups(ui.env) end)
    elseif page == "Projects" then ui.page_body(function() require("page_groups").draw_projects(ui.env) end)
    elseif page == "Home" then ui.page_body(page_home)
    elseif page == "Rooms" then
      ui.page_body(function() -- (it reads bandmates' room files: one malformed one ended the panel. Review, 0.59.14)
        page_rooms.refresh()
        local room_view = page_rooms.view()
        if ui.short and not (room_view.meta and room_view.meta.parent) then layout({ { page_rooms.squares, 900 } })
        else layout({ { page_rooms.squares, 900 }, { page_rooms.actions, 300 } }) end
      end)
    elseif page == "Play/Jam" then
      if wide then layout({ { page_play.section_together, 380 }, { function() page_play.section_live("mode") end, 420 }, { function() page_play.section_live("rest") end, 520 } })
      else layout({ { page_play.section_together, 380 }, { page_play.section_live, 480 } }) end
    elseif page == "Chat" then
      local chat_tabs = { { "All", function() -- (everything, newest first, with Go for what's on the timeline: James, 0.58.81)
          if reaper.time_precise() - notes_at > 4 then notes_at, notes = reaper.time_precise(), recall.notes(cfg, b.song, b.room) end
          require("page_chat").all_tab(ctx, ImGui, cfg, b, notes)
        end, true }, { "Notes", function() section_notes("note") end }, { "Likes", function() section_notes("like") end }, { "Call", function() ui.call_tab() end } }
      local function chat_page() require("page_chat").draw(ctx, ImGui, cfg, b, chat_tabs) end
      layout({ { chat_page, 900 } }) -- (live ideas are on Home with Real time mode or Time-sync: James, 0.59.3)
    elseif page == "Restore" then layout({ { restore.section_recall, 400 }, { restore.section_history, 600 } })
    elseif page == "Mixes" then layout({ { restore.section_mixes, 440 }, { studio_listen, 360 } })
    elseif page == "Plugins" then
      layout({ { function() require("page_plugins").draw(ctx, ImGui, proj, cfg) end, 760 }, { function() require("page_plugins").drums(ctx, ImGui, proj, cfg) end, 420 }, { section_plugins, 420 } })
    elseif page == "Settings" then page_setup() end
    ImGui.PopTextWrapPos(ctx)
    ui.smooth_scroll_end(scroll_key)
    ImGui.EndChild(ctx)
  end
  if was_wide then ImGui.PopStyleVar(ctx, 2) end
  ImGui.EndDisabled(ctx)
  ImGui.PopStyleVar(ctx)
end

local start_songs -- (the start screen's song list, read every few seconds)
-- With no group project in front: your groups, a group's projects, and settings.
function ui.frame_lobby()
  ui.status = nil
  ui.asked_page()
  local pg = require("page_groups")
  local none = #pg.live_groups() == 0
  if none and page ~= "Settings" then page = "Groups"
  elseif not LOBBY[page] then page = "Projects" end
  local fh = ImGui.GetFrameHeight(ctx)
  wide, ui.short = false, false
  local y0 = ImGui.GetCursorPosY(ctx) + 8
  ImGui.SetCursorPos(ctx, 16, y0)
  local root = pg.root or cfg.root
  if not none and not require("groups").is_old(root) then
    if ui.crumb(band.info(root).name, 0, 1, fh, "The studio you're working in. Click: all your studios.") then page = "Groups" end
    ImGui.SameLine(ctx, 0, 12)
    ImGui.SetCursorPosY(ctx, y0)
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
  for i, p in ipairs(ui.pages()) do
    if p[1] ~= "Groups" and not (none and p[1] == "Projects") then
      if i > 1 then ImGui.SameLine(ctx, 0, 2) end
      ImGui.SetCursorPosY(ctx, y0)
      if ImGui.Selectable(ctx, p[1] .. "##nav", p[1] == page, ImGui.SelectableFlags_None, ImGui.CalcTextSize(ctx, p[1]) + 28, fh) then page = p[1] end
      ImGui.SetItemTooltip(ctx, p[2])
    end
  end
  ImGui.PopStyleVar(ctx)
  ImGui.SameLine(ctx, 0, 8)
  ImGui.SetCursorPosY(ctx, y0)
  local docked = ImGui.IsWindowDocked(ctx)
  local room = ImGui.GetContentRegionAvail(ctx)
  local need = ImGui.CalcTextSize(ctx, "Feedback") + 28 + ((docked or native) and (ImGui.CalcTextSize(ctx, "Window") + ImGui.CalcTextSize(ctx, docked and "Undock" or "Dock") + 64 + 68) or 0)
  if room > need then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + room - need); ImGui.SetCursorPosY(ctx, y0)
  else ImGui.SetCursorPos(ctx, 16, y0 + fh + 6); y0 = y0 + fh + 6 end
  local function at_row() ImGui.SameLine(ctx, 0, 8); ImGui.SetCursorPosY(ctx, y0) end
  require("feedback").button(ctx, ImGui)
  if docked or native then -- (the panel's own title bar has them otherwise)
    at_row()
    ui.window_button()
    at_row()
    tools.dock_menu(docked)
  end
  if docked or native then ui.window_buttons(at_row, y0, fh) end
  ImGui.SetCursorPos(ctx, 16, y0 + fh + 8)
  local log = band.activity()
  if log[1] ~= tools.toast_newest then tools.toast_line, tools.toast_at = tools.toast_seen and log[1] or nil, reaper.time_precise(); tools.toast_newest = log[1] end
  tools.toast_seen = true
  tools.toast_show(ctx, ImGui, tools.toast_line and reaper.time_precise() - (tools.toast_at or 0) < 6 and tools.toast_line or nil)
  tools.removed_bar(ctx, ImGui)
  ui.sync_problem()
  tools.join_requests(ctx, ImGui)
  tools.invite_popup(ctx, ImGui)
  do -- (a script's request with no studio project in front: said and dropped, not done to whichever project opens next. Review, 0.58.67)
    local r = require("api").take_request()
    if r then band.log("a script asked StudioSync for '" .. r:sub(1, 40) .. "', but no studio project is in front: nothing done") end
  end
  ImGui.Separator(ctx)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, 12)
  local setup_key = "setup " .. tostring(page)
  if ImGui.BeginChild(ctx, "page", 0, 0, ImGui.ChildFlags_AlwaysUseWindowPadding) then
    ui.smooth_scroll(setup_key)
    ImGui.PushTextWrapPos(ctx, 0)
    if page == "Groups" then ui.page_body(function() pg.checklist(ui.env); pg.draw_groups(ui.env) end)
    elseif page == "Projects" then ui.page_body(function() pg.checklist(ui.env); pg.draw_projects(ui.env) end)
    else page_setup() end
    ImGui.PopTextWrapPos(ctx)
    ui.smooth_scroll_end(setup_key)
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleVar(ctx)
end
ui.env = { ctx = ctx, ImGui = ImGui, card = card, card_end = card_end, heading = heading, action = action,
  cfg = function() return cfg end, wide = function() return wide end, go = function(p) page = p end, project = function() return b and b.song end,
  reload_cfg = function() cfg = band.settings(); start_songs = nil; drive_at = -math.huge; last = 0 end }
-- (what lib/page_health.lua shares: the panel's helpers, and what changes as you work, asked for at each call)
for k, v in pairs({ ui = ui, dir = dir, next_to = next_to, logo = logo, wordmark = wordmark, section_activity = section_activity,
    b = function() return b end, proj = function() return proj end, view = function() return view end,
    reset_live_server = function() page_play.reset_server() end }) do ui.env[k] = v end
health.init(ui.env)
for k, v in pairs({ combo = combo, describe = describe, local_time = local_time, points = function() return points end,
    can = function() return can end, who = function() return who end, refresh_now = function() last = 0 end }) do ui.env[k] = v end
restore.init(ui.env)
page_rooms.init(ui.env)
for k, v in pairs({ same_room_on = same_room_on, set_same_room = set_same_room, sonobus_open = sonobus_open, bar_of = bar_of, check = check,
    sb_link = function() return sb_link end }) do ui.env[k] = v end
page_play.init(ui.env)
local function frame()
  if b and cfg then recall.warm(cfg, b.song, b.room, 0.004, page ~= "Restore" and page ~= "Chat") end -- (relisted only where it's shown: 0.59.14, review)
  if reaper.time_precise() - last > 1.5 or reaper.EnumProjects(-1) ~= proj then
    last = reaper.time_precise()
    local ok, e = pcall(refresh)
    err = not ok and tostring(e) or nil
  end
  ui.front_changed()
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 10); ImGui.Indent(ctx, 16) -- (the window has no padding of its own)
  if err then
    ImGui.TextColored(ctx, RED, "Something went wrong in the panel: " .. err)
    if ImGui.SmallButton(ctx, "Copy it") then band.copy("StudioSync " .. band.VERSION .. ": " .. err, ctx, ImGui) end
    ImGui.SetItemTooltip(ctx, "Copy the message, to send it to whoever looks after StudioSync.")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Try again") then err, last = nil, 0 end
    return
  end
  ImGui.Unindent(ctx, 16)
  if not b then return ui.frame_lobby() end
  return frame_app()
end

-- A running script keeps the code it started with, so after an update this panel showed none of the new buttons
-- until someone closed and reopened it (Mac, 2026-10-28). Once the installed version has changed (and held for two
-- looks, so a half-finished update isn't loaded), it loads the new code in place: same window, new panel.
local seen_disk, disk_at = nil, 0
local function updated()
  if reaper.time_precise() - disk_at < 3 then return false end
  disk_at = reaper.time_precise()
  local disk = (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
  local ready = disk and disk ~= band.VERSION and disk == seen_disk and band.update_ok(dir, disk) -- (from a shared folder, once you said yes: Autostart asks)
  seen_disk = disk
  return ready
end

-- While someone else drives and is here, a slim banner at the foot of REAPER's arrange view says what you can change.
-- It takes no clicks (no inputs, no focus). Placed in ReaImGui's units from the screen's pixels of REAPER's main
-- window and its arrange view. Settings can turn it off (ExtState banner = "off").
local function banner()
  if not banner_text or reaper.GetExtState(band.SECTION, "banner") == "off" or not reaper.JS_Window_FindChildByID then return end
  local main = reaper.GetMainHwnd()
  local arrange = reaper.JS_Window_FindChildByID(main, 1000)
  if not arrange then return end
  local _, ml, mt, mr, mb = reaper.JS_Window_GetRect(main)
  local _, al, at, ar, ab = reaper.JS_Window_GetRect(arrange)
  local vp = ImGui.GetMainViewport(ctx)
  local vx, vy = ImGui.Viewport_GetPos(vp)
  local vw, vh = ImGui.Viewport_GetSize(vp)
  if mr - ml <= 0 or vw <= 0 then return end
  local sx, sy = (mr - ml) / vw, (mb - mt) / vh
  local cx, by = vx + ((al + ar) / 2 - ml) / sx, vy + (ab - mt) / sy
  -- the panel floating over that spot (the banner was drawn on top of it): no banner then, the panel says it all
  if win_rect and not banner_docked and cx > win_rect[1] - 200 and cx < win_rect[1] + win_rect[3] + 200
      and by > win_rect[2] and by - 70 < win_rect[2] + win_rect[4] then return end
  -- (40 up: lower, it sat on the bottom docker's splitter and caught the drag meant for it)
  ImGui.SetNextWindowPos(ctx, cx, by - 40, ImGui.Cond_Always, 0.5, 1)
  ImGui.SetNextWindowBgAlpha(ctx, 0.88)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 6)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, theme.BANNER)
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_NoInputs | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav |
    ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoSavedSettings
  if ImGui.Begin(ctx, "StudioSync banner", nil, f) then
    ImGui.TextColored(ctx, YELLOW, banner_text)
    ImGui.End(ctx)
  end
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx, 2)
end

-- Minimized: a tiny box over REAPER, its edge saying whether sync runs and a count for what's waiting (the words are its tooltip), or a strip with
-- the words on it; from the title bar's two buttons (its X really closes); a click brings the panel back where it was (floating or docked). Dragged, it stays
-- where it's dropped, pinned to REAPER's window so it goes along when REAPER moves. Right-click to lock it there, close the panel or remove it.
-- shortcut: it's kept inside REAPER's window: past it, a screen unplugged (or a virtual one gone) could lose the button for good.
-- Returns false when the panel should close.
local function pill_window()
  local front = reaper.EnumProjects(-1)
  local fb = band.binding(front)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(front)))
  local live_on = beat and reaper.time_precise() - beat < 5
  local unread = fb and require("page_chat").unread(cfg, fb) or 0
  local strip = reaper.GetExtState(band.SECTION, "panel minimized") == "strip"
  local S = tonumber(reaper.GetExtState(band.SECTION, "pill size")) or 28
  local vx, vy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx))
  local vw, vh = ImGui.Viewport_GetWorkSize(ImGui.GetMainViewport(ctx))
  local locked = reaper.GetExtState(band.SECTION, "pill lock") ~= ""
  local mx, my = ImGui.GetMousePos(ctx)
  -- (each has its own place: James keeps them in different spots)
  local kx, ky = strip and "strip dx" or "pill dx", strip and "strip dy" or "pill dy"
  local W = strip and (ui.strip_w or 320) or S
  local px, py = vx + (tonumber(reaper.GetExtState(band.SECTION, kx)) or (vw - W - 24)), vy + (tonumber(reaper.GetExtState(band.SECTION, ky)) or 64)
  if ui.pill_drag and ui.pill_drag.moved then px, py = ui.pill_drag.x + mx - ui.pill_drag.mx, ui.pill_drag.y + my - ui.pill_drag.my
  else px, py = math.max(vx, math.min(px, vx + vw - W)), math.max(vy, math.min(py, vy + vh - S)) end
  ImGui.SetNextWindowPos(ctx, px, py)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, strip and 14 or S / 4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, strip and 8 or 0, strip and 4 or 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 0)
  local keep = true
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_NoMove |
    ImGui.WindowFlags_NoSavedSettings | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav
  if ImGui.Begin(ctx, "StudioSync pill", nil, f) then
    local x, y = ImGui.GetCursorScreenPos(ctx)
    if strip then ui.strip_w = ImGui.GetWindowSize(ctx) end
    local problem = reaper.GetExtState(band.SECTION, "sync problem")
    if problem ~= "" then live_on = false end
    local words = "StudioSync  ·  " .. (problem ~= "" and problem or live_on and (ui.status and ui.status.label or "Sync on") or "Sync off") .. (view and view.driver and ("  ·  " .. (view.driver == cfg.user and "you drive" or (view.driver .. " drives"))) or "") ..
      (unread > 0 and string.format("  ·  %d new message%s", unread, unread == 1 and "" or "s") or "")
    local waiting = unread
    local pb = band.json_decode(reaper.GetExtState(band.SECTION, "put back"))
    if pb and pb.text then
      words = words .. string.format("  ·  %d edit%s not sent", pb.n or 1, (pb.n or 1) == 1 and "" or "s")
      waiting = waiting + (pb.n or 1)
    end
    local pp = band.json_decode(reaper.GetExtState(band.SECTION, "print problem"))
    if pp and pp.text and not (pp.at and os.time() - pp.at > 1800) then -- (a print that didn't come out: lib/prints.lua prints.problem. 0.59.12)
      words = words .. string.format("  ·  %d print problem%s", pp.n or 1, (pp.n or 1) == 1 and "" or "s")
      waiting = waiting + (pp.n or 1)
    end
    if b then
      local asks = #require("suggest").rows(sync.room_dir(cfg, b.song, b.room), cfg.user)
      if asks > 0 then words = words .. string.format("  ·  %d suggestion%s", asks, asks == 1 and "" or "s") end
      waiting = waiting + asks
    end
    local clicked
    if strip then
      logo(18)
      ImGui.SameLine(ctx, 0, 6)
      dot(live_on and GREEN or RED)
      ImGui.SameLine(ctx, 0, 6)
      clicked = ImGui.SmallButton(ctx, words .. "##pill")
    else clicked = ImGui.InvisibleButton(ctx, "##pill", S, S) end
    local hovered = ImGui.IsItemHovered(ctx)
    -- (anywhere on it, its edges too: only the button in its middle did, and an edge is where a hand goes first)
    -- (the flag: pressed, the button is the active item, and a plain IsWindowHovered says no, so it never moved: Mac, 0.45.0)
    if ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_AllowWhenBlockedByActiveItem) and ImGui.IsMouseClicked(ctx, 0) and not locked and not ui.pill_drag then ui.pill_drag = { mx = mx, my = my, x = px, y = py } end
    local dragged = false
    if ui.pill_drag then
      -- (a few pixels are a click with an unsteady hand, not a move)
      ui.pill_drag.moved = ui.pill_drag.moved or math.abs(mx - ui.pill_drag.mx) + math.abs(my - ui.pill_drag.my) > 4
      dragged = ui.pill_drag.moved
      if not ImGui.IsMouseDown(ctx, 0) then
        if dragged then
          reaper.SetExtState(band.SECTION, kx, tostring(px - vx), true); reaper.SetExtState(band.SECTION, ky, tostring(py - vy), true)
        end
        ui.pill_drag = nil
      end
    end
    if clicked and not dragged then ui.set_minimized(false) end
    local how = locked and "Click: open the panel. Locked where it is (right-click to unlock)." or "Click: open the panel. Drag: move it, and it stays there. Right-click: lock it, and more."
    ImGui.SetItemTooltip(ctx, words .. (pb and pb.text and ("\nUndone: " .. pb.text) or "") .. "\n" .. how)
    if ImGui.BeginPopupContextItem(ctx, "pillmenu") then
      if ImGui.Selectable(ctx, "Open the panel") then ui.set_minimized(false) end
      if ImGui.Selectable(ctx, "Call window", require("callwin").is_open()) then require("callwin").set_open(not require("callwin").is_open()) end -- (0.59.14)
      if ImGui.Selectable(ctx, "Lock position", locked) then reaper.SetExtState(band.SECTION, "pill lock", locked and "" or "1", true) end
      if ImGui.Selectable(ctx, strip and "Make it a tiny box" or "Make it a strip") then ui.set_minimized(strip and true or "strip") end
      if not strip and ImGui.BeginMenu(ctx, "Size") then
        for _, sz in ipairs({ { "Small", 22 }, { "Medium", 28 }, { "Large", 40 }, { "Big", 56 } }) do
          if ImGui.MenuItem(ctx, sz[1], nil, S == sz[2]) then reaper.SetExtState(band.SECTION, "pill size", tostring(sz[2]), true) end
        end
        ImGui.EndMenu(ctx)
      end
      if fb and ImGui.Selectable(ctx, "Sync and exit...") then ui.set_minimized(false); require("leave").start(front, band.for_tab(cfg, fb), fb) end
      if ImGui.Selectable(ctx, "Close the panel") then ui.set_minimized(false); keep = false end
      ImGui.EndPopup(ctx)
    end
    local dl = ImGui.GetWindowDrawList(ctx)
    if not strip then
    local L = S * 0.76
    if hovered then ImGui.DrawList_AddRectFilled(dl, x, y, x + S, y + S, theme.BUTTON, S / 4) end
    ImGui.SetCursorScreenPos(ctx, x + (S - L * 0.93) / 2, y + (S - L) / 2)
    logo(L)
    ImGui.DrawList_AddRect(dl, x + 1, y + 1, x + S - 1, y + S - 1, live_on and GREEN or RED, S / 4, 0, 2)
    -- (sync off is a slash too, not only a red edge: red and green read alike to a colour-blind eye. UX review, 0.59.14)
    if not live_on then ImGui.DrawList_AddLine(dl, x + S * 0.22, y + S * 0.78, x + S * 0.78, y + S * 0.22, RED, math.max(2, S / 12)) end
    end
    if not strip and waiting > 0 then -- what's waiting, in the corner
      -- (small, to the box's size: in the panel's own text size the number covered half the box. James, 0.58.82)
      local n = waiting > 9 and "9+" or tostring(waiting)
      local fs = math.max(8, math.floor(S * 0.32 + 0.5))
      ImGui.PushFont(ctx, nil, fs)
      local tw, th = ImGui.CalcTextSize(ctx, n)
      ImGui.PopFont(ctx)
      local r = math.max(th * 0.5, tw * 0.5 + 1.5)
      local cx, cy = x + S - r, y + r
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, r, RED)
      ImGui.DrawList_AddTextEx(dl, nil, fs, cx - tw / 2, cy - th / 2, 0xFFFFFFFF, n)
    end
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, 3)
  return keep
end

local frame_seen
local loop
-- (an error stops the panel, as ever, but first goes to the log file with where it happened: REAPER's own box was all there was. 0.58.86)
local function guarded(fn) return function() local ok, err = xpcall(fn, debug.traceback); if not ok then band.log_error("the panel", err); error(err, 0) end end end
local frame_said -- (the last frame error said in the console)
local min_look_at = -math.huge -- (shrunk to its box: when the project in front last changed under it)
local function loop_body()
  if updated() or reload_now then -- reload in place: relaunching itself as an action is ignored (or asks to terminate instances)
    band.log("the panel reloaded for StudioSync " .. tostring(seen_disk))
    restarting = true
    STUDIOSYNC_PANEL_RELOAD = true -- (the next one keeps the box or strip as it is)
    pcall(require("colours").put_back_all) -- (a look being tried doesn't outlive the panel's Lua)
    for _, f in ipairs(band.files(dir .. "/lib", ".lua")) do package.loaded[f:sub(1, -5)] = nil end
    return dofile(dir .. "/StudioSync - Panel.lua")
  end
  -- (frames that never end, as for a panel opened while ReaPack's Transaction report is up, pile every frame's drawing up: 7.4 GB in 12 minutes
  -- till Linux killed REAPER. So nothing is drawn while the count stands still; it moves on every pass otherwise. Linux stress test, 0.58.77)
  local fc = ImGui.GetFrameCount(ctx)
  if fc == frame_seen then
    reaper.SetExtState(band.SECTION, "panel alive", tostring(reaper.time_precise()), false)
    return reaper.defer(loop)
  end
  frame_seen = fc
  ImGui.SetNextWindowSize(ctx, 560, 640, ImGui.Cond_FirstUseEver)
  local wx, wy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx)) -- first time: inside REAPER, below its menus
  ImGui.SetNextWindowPos(ctx, wx + 60, wy + 90, ImGui.Cond_FirstUseEver)
  -- no collapse arrow: collapsed and opened again, the window came back tiny on macOS (dock it, or close it instead)
  push_theme(); ImGui.PushFont(ctx, ui_font, 15)
  -- (the app's pages scroll inside; the window itself never does, so the top bar stays put)
  local flags = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse
    | (native and ImGui.WindowFlags_NoTitleBar or 0) -- (the system frame has the title; docked, REAPER's tab does)
  if dock_req then ImGui.SetNextWindowDockID(ctx, dock_req); dock_req = nil end
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_DockingWithShift, reaper.GetExtState(band.SECTION, "dock armed") ~= "" and 0 or 1)
  if reaper.GetExtState(band.SECTION, "panel clipped") == "?" or ui.clipped then -- (the test reads it back, then clears it to stop)
    if ui.clipped and reaper.GetExtState(band.SECTION, "panel clipped") == "" then ui.clipped = nil
    else
      if ui.clipped then reaper.SetExtState(band.SECTION, "panel clipped", band.json_encode(ui.clipped), false) end
      ui.clipped = {}
    end
  end
  local ask = reaper.GetExtState(band.SECTION, "panel place") -- (the Window menu, asked for from a script)
  if ask ~= "" then reaper.DeleteExtState(band.SECTION, "panel place", false); place_window(ask) end
  if place_req then
    ImGui.SetNextWindowPos(ctx, place_req[1], place_req[2])
    ImGui.SetNextWindowSize(ctx, place_req[3], place_req[4])
    place_req = nil
  end
  local minimized = reaper.GetExtState(band.SECTION, "panel minimized") ~= ""
  local visible, open = false, true
  -- (the system frame is the panel's: the box and strip went out with one too. James, 0.58.98)
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, (native and not minimized) and 0 or 1)
  -- (shrunk, nothing refreshed: the box and the banner went on describing the tab before. Review, 0.59.14)
  if minimized and reaper.EnumProjects(-1) ~= proj and reaper.time_precise() - min_look_at > 1 then min_look_at = reaper.time_precise(); pcall(refresh) end
  if minimized then open = pill_window()
  else
    if ui.focus_req then ui.focus_req = nil; ImGui.SetNextWindowFocus(ctx) end
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowTitleAlign, 0.5, 0.5) -- (the logo has the left corner)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0) -- (the little triangle in a docked window's corner is drawn in this colour as it begins)
    -- the name only where it clears Window and Dock: under 500 px wide it ran beneath them (0.58.28)
    visible, open = ImGui.Begin(ctx, (ui.title_w or 0) >= 500 and "StudioSync###StudioSync" or "###StudioSync", true, flags)
    ui.title_w = ImGui.GetWindowWidth(ctx)
    ImGui.PopStyleColor(ctx)
    ImGui.PopStyleVar(ctx)
  end
  if visible then
    local wx, wy = ImGui.GetWindowPos(ctx)
    local ww, wh = ImGui.GetWindowSize(ctx)
    local was_docked = win_rect and win_rect.docked
    win_rect = { wx, wy, ww, wh, docked = ImGui.IsWindowDocked(ctx) }
    local now_t = reaper.time_precise()
    -- (a box StudioSync opened held the panel while it was up, and the focus came back to REAPER, not here: not a click away. 0.58.98)
    if ui.frame_t and now_t - ui.frame_t > 0.5 then ui.had_focus = nil end
    ui.frame_t = now_t
    if behind == "box" and not win_rect.docked and now_t - (ui.opened_at or 0) > 1.5 then -- (the focus gone from every StudioSync window, after it had it)
      local focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow)
      if focused then ui.had_focus = true
      elseif ui.had_focus and not ImGui.IsAnyItemActive(ctx) and ui.should_hide(win_rect) then
        ui.set_minimized(true) -- (kept while another app has the focus: a click on REAPER under it afterwards still shrinks it. Review, 0.58.98)
      end
    end
    banner_docked = win_rect.docked
    if was_docked and not banner_docked then -- out of a docker: back to the usual size, not the docker's long thin shape
      local vx, vy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx))
      place_req = { vx + 60, vy + 90, 560, 640 }
    end
    if dock_side then
      -- the action moves whichever docker has the focus, so only once this window is really in its new one, and has the focus:
      -- on the first docked frame it isn't yet, and it moved the Mixer's docker instead
      -- (ReaImGui's own word for where it is: on a Mac the window JS_Window_Find hands back isn't always one DockIsChildOfDock
      -- takes, and that threw: Mac, 0.42.27)
      local me = ImGui.GetWindowDockID(ctx) == ~dock_side.docker and reaper.JS_Window_Find and reaper.JS_Window_Find("StudioSync", true)
      if me then
        pcall(reaper.JS_Window_SetFocus, me)
        -- (no asking whether the focus took: on a Mac it never reads as ours, and this ended with nothing said. move_docker looks afterwards
        -- and puts back whatever else moved: Mac, 0.45.0)
        local where = dock_side.action == 41599 and "left" or "right"
        if require("tools").move_docker(dock_side.docker, where == "left" and 1 or 3) then
          band.msg("StudioSync is docked at the " .. where .. " of REAPER.\n\nREAPER opens a new docker there very narrow, " ..
            "and a script can't widen it: drag its inner edge across. REAPER remembers the width after that.")
        else
          band.msg("REAPER wouldn't move StudioSync's docker to the " .. where .. ", so the panel is at the bottom and everything else is where it was.\n\n" ..
            "To try by hand: right-click the 'StudioSync' tab at the foot of the docker, and look for the docker's position there.")
        end
        dock_side = nil
      elseif reaper.time_precise() - dock_side.since > 3 then
        dock_side = nil
        band.log("the panel didn't settle into its new docker, so it stays where it is")
      end
    end
    open_cards = 0
    local ok, e = pcall(frame) -- an error in our logic must still reach End
    if not ok then -- (and End must find no card open: 0.33.2's broken lib file failed inside one, and End killed the panel)
      err = tostring(e)
      if frame_said ~= err then frame_said = err; reaper.ShowConsoleMsg("StudioSync panel: " .. err .. "\n") end -- (once: it reopened the console every 1.5 s. Review, 0.59.14)
      for _ = 1, open_cards do ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx) end
      open_cards = 0
    end
    -- a focused panel keeps the keys from REAPER, so Ctrl+Z did nothing after a click here. (Cmd on a Mac. Not while typing: a text box has its own undo)
    if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) and not ImGui.IsAnyItemActive(ctx)
      and ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl) and ImGui.IsKeyPressed(ctx, ImGui.Key_Z, false) then
      action(ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) and "Redo" or "Undo")
    end
    if banner_docked then reaper.DeleteExtState(band.SECTION, "dock armed", false) -- docked: drag-to-dock did its job
    elseif not native then
      -- the top corners resize too (Dear ImGui only has grips at the bottom); the grips sit over the frame's corners
      ImGui.PushClipRect(ctx, wx, wy, wx + ww, wy + wh, false)
      for k, x in ipairs({ wx, wx + ww - 12 }) do
        ImGui.SetCursorScreenPos(ctx, x, wy)
        ImGui.InvisibleButton(ctx, "##grip" .. k, 12, 12)
        if ImGui.IsItemHovered(ctx) or ImGui.IsItemActive(ctx) then
          ImGui.SetMouseCursor(ctx, k == 1 and ImGui.MouseCursor_ResizeNWSE or ImGui.MouseCursor_ResizeNESW)
        end
        if ImGui.IsItemActive(ctx) then
          local dx, dy = ImGui.GetMouseDragDelta(ctx, 0)
          ImGui.ResetMouseDragDelta(ctx, 0)
          if dx ~= 0 or dy ~= 0 then
            place_req = k == 1 and { wx + dx, wy + dy, math.max(300, ww - dx), math.max(200, wh - dy) }
              or { wx, wy + dy, math.max(300, ww + dx), math.max(200, wh - dy) }
          end
        end
      end
      do -- the logo in the corner; beside the close button (which closes), minimize to a strip and the tiny box
        local s, pad = ImGui.GetFontSize(ctx), ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
        local tbh = ImGui.GetFrameHeight(ctx)
        if not ImGui.GetWindowDockID or ImGui.GetWindowDockID(ctx) == 0 then
          ImGui.SetCursorScreenPos(ctx, wx + 7, wy + 2)
          logo(tbh - 4)
          local st = ui.status
          if st then
            ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), wx + 7 + (tbh - 4) * 0.93 + 9, wy + tbh / 2, 4.5, st.colour)
            -- (over the logo and the dot only: the whole title bar showed it, in the way while moving the window. James, 0.58.98)
            if ImGui.IsMouseHoveringRect(ctx, wx + 4, wy, wx + 7 + (tbh - 4) * 0.93 + 16, wy + tbh) and ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_RootAndChildWindows) then
              if ImGui.BeginTooltip(ctx) then
                ImGui.PushTextWrapPos(ctx, ImGui.GetFontSize(ctx) * 32)
                ImGui.Text(ctx, st.tip .. "\n\n" .. st.drives)
                ImGui.PopTextWrapPos(ctx)
                ImGui.EndTooltip(ctx)
              end
            end
          end
        end
        local by = wy + (tbh - s) / 2
        do -- Window and Dock, left of the two icons: always there, whatever the panel's width (James, 0.58.23)
          local fpx = select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding))
          local w2 = ImGui.CalcTextSize(ctx, "Dock") + fpx * 2
          local w1 = ImGui.CalcTextSize(ctx, "Window") + fpx * 2
          local right = wx + ww - pad - s * 3 - 24
          ImGui.SetCursorScreenPos(ctx, right - w2, wy + (tbh - ImGui.GetTextLineHeight(ctx)) / 2)
          tools.dock_menu(false, true)
          ImGui.SetCursorScreenPos(ctx, right - w2 - 6 - w1, wy + (tbh - ImGui.GetTextLineHeight(ctx)) / 2)
          ui.window_button(true)
        end
        ImGui.SetCursorScreenPos(ctx, wx + ww - pad - s * 2 - 8, by)
        if ui.window_icon("##minimize", "line", s, "Minimize to a strip over REAPER. Click it and the panel opens where it was.") then ui.set_minimized("strip") end
        ImGui.SetCursorScreenPos(ctx, wx + ww - pad - s * 3 - 14, by)
        if ui.window_icon("##tobox", "box", s, "Shrink to a tiny box over REAPER. Click it and the panel opens where it was.") then ui.set_minimized(true) end
      end
      ImGui.PopClipRect(ctx)
    end
    ImGui.Dummy(ctx, 0, 0) -- (a frame that ended just after setting the cursor, as while a tab closes: End kills the panel for that)
    ImGui.End(ctx)
  end
  require("feedback").draw(ctx, ImGui, cfg, proj) -- (its own window, while open: lib/feedback.lua)
  -- (the call in its own window, while open, the panel full or shrunk to its box: lib/callwin.lua. James, 0.59.14)
  if require("callwin").is_open() then
    pcall(require("callwin").draw, { ctx = ctx, ImGui = ImGui, proj = proj, b = b, call_on = ui.call_on, set_call = ui.set_call,
      sonobus_open = sonobus_open, people = ui.call_people, call_link = function() return cfg and require("alerts").call_link(cfg.root) end })
  end
  ImGui.PopFont(ctx); pop_theme()
  banner()
  reaper.SetExtState(band.SECTION, "panel alive", tostring(reaper.time_precise()), false) -- (so Autostart never opens a second one)
  if open then return reaper.defer(loop) end
  closed_here = true
  band.log_file("the panel closed")
  if reaper.GetExtState(band.SECTION, "sync problem") == "" then -- (it keeps syncing: Live sync is its own script, one per tab)
    local mx, my = reaper.GetMousePosition()
    reaper.TrackCtl_SetToolTip("StudioSync keeps syncing with the panel closed.\nIf sync stops, the tiny box comes back in red to say so.", mx + 14, my + 14, true)
    -- (Autostart takes it away in 5 s: a timer of its own here kept the panel's script running, and the toolbar button pressed meanwhile only
    -- stopped that, so the panel didn't open. James, 0.58.99)
    reaper.SetExtState(band.SECTION, "tooltip until", tostring(reaper.time_precise() + 5), false)
  end
end
loop = guarded(loop_body)
band.log_file("the panel opened (StudioSync " .. band.VERSION .. ", REAPER " .. reaper.GetAppVersion() .. ")")
reaper.defer(loop)
