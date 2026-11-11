-- The Rooms page (moved out of StudioSync - Panel.lua, 0.58.50: the panel was at Lua's 200 locals): the side rooms as squares, making one,
-- bringing work back into main, and invitations to come and see. The panel hands over what it shares (M.init); what changes as you work is
-- asked for at every call.
local band = require("band")
local sync, rooms = require("sync"), require("rooms")
local theme = require("theme")
local GREEN, YELLOW, ACCENT, CARD = theme.GREEN, theme.YELLOW, theme.ACCENT, theme.CARD
local M = {}
local E, ctx, ImGui, ui, dir, heading, next_to
function M.init(env)
  E, ctx, ImGui, ui, dir, heading, next_to = env, env.ctx, env.ImGui, env.ui, env.dir, env.heading, env.next_to
end

local room_view, room_at, new_room, merge, dismissed = nil, -math.huge, "", nil, {}
function M.live_running(p)
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
  return beat and reaper.time_precise() - beat < 5
end
local function go_room(name)
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  local p, why = rooms.open(proj, cfg, b, name)
  if not p then return band.msg(why) end
  if not M.live_running(p) then band.start_live(dir) end -- runs for the tab in front: the room's
  reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
  room_at, merge = -math.huge, nil
end
function M.refresh()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  if reaper.time_precise() - room_at < 2 and room_view and room_view.room == b.room then return end
  room_at = reaper.time_precise()
  room_view = { room = b.room, list = {}, binned = {}, people = {}, meta = rooms.meta(cfg, b.song, b.room) }
  for _, r in ipairs(rooms.list(cfg, b.song)) do
    table.insert((r.binned and r.name ~= b.room) and room_view.binned or room_view.list, r)
  end
  for _, r in ipairs(room_view.list) do room_view.people[r.name] = rooms.people(cfg, b.song, r.name) end
end

-- Bring this side room into the room it came from: what changed here and there since it was made, compared.
-- Bringing this side room into its parent (mirror sync): what only this room changed since it was made comes in,
-- what both changed stays as the parent has it (listed).
local function look_merge(parent)
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  local m = room_view.meta or {}
  local mirror = require("mirror")
  local since = m.time
  if not since then merge = { why = "This room has no start time (made with an older StudioSync)." }; return end
  local bring, clash = mirror.plan_bring(mirror.room_newest(sync.room_dir(cfg, b.song, b.room), since),
    mirror.room_newest(sync.room_dir(cfg, b.song, parent), since), mirror.room_newest(sync.room_dir(cfg, b.song, parent)))
  merge = { bring = bring, clash = clash, parent = parent }
end

local function section_merge()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  if merge.why then ImGui.TextColored(ctx, YELLOW, merge.why); return end
  local parent = merge.parent
  if #merge.bring == 0 and #merge.clash == 0 then ImGui.TextDisabled(ctx, "No new changes here for '" .. parent .. "'. For anything older, or deleted there: select it and use Send selected."); return end
  ImGui.Text(ctx, string.format("%d change(s) to bring into '%s'", #merge.bring, parent))
  local describe = require("recall").describe
  for _, ev in ipairs(merge.bring) do ImGui.BulletText(ctx, describe({ kind = "obj", obj = ev.obj, name = ev.name, rev = ev.rev, gone = ev.gone, pos = ev.pos })) end
  if #merge.clash > 0 then
    ImGui.TextColored(ctx, YELLOW, string.format("%d also changed in '%s' since this room was made: '%s' keeps its own", #merge.clash, parent, parent))
    for _, ev in ipairs(merge.clash) do ImGui.BulletText(ctx, describe({ kind = "obj", obj = ev.obj, name = ev.name, rev = 2, pos = ev.pos })) end
  end
  local driver = sync.driver(cfg, b.song, parent, view.session)
  local may = driver == cfg.user
  ImGui.BeginDisabled(ctx, not may or #merge.bring == 0)
  if ImGui.Button(ctx, "Bring into " .. parent) and reaper.MB("Bring these changes into '" .. parent .. "'?\n\n" ..
      "They go to everyone there as new changes, so Restore there can undo them.", "StudioSync", 4) == 6 then
    -- (by that room's claims, as Send selected: it took James's claimed Drums into main: laptop, 0.42.9)
    local list, refused = require("mirror").allowed_into(cfg, b.song, parent, merge.bring, view.session)
    local ok, res = pcall(require("mirror").post_into, cfg, b.song, b.room, parent, list, rooms.tab(b.song, parent))
    band.log(ok and string.format("brought %d change(s) from '%s' into '%s'%s", res, b.room, parent, refused > 0 and string.format(" (%d not yours to change there, left out)", refused) or "")
      or ("bringing in failed: " .. tostring(res)))
    merge = nil
  end
  ImGui.EndDisabled(ctx)
  if not may then
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, tostring(driver) .. " drives '" .. parent .. "': they bring it in (or take control there)")
  end
end

local function come_see()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  if ImGui.Button(ctx, "Come see!") then
    rooms.invite(cfg, b.song, b.room)
    band.log("asked everyone to come and see '" .. b.room .. "'")
  end
  ImGui.SetItemTooltip(ctx, "Everyone with this project open gets 'come and see " .. b.room .. "' at the top of their panel, with a Go button.")
end
function M.squares()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  M.refresh()
  if ImGui.Button(ctx, "Create side room") then new_room = ""; ImGui.OpenPopup(ctx, "New side room") end
  ImGui.SetItemTooltip(ctx, "A copy of this room as it is now, in its own tab. Collaborators can join it from here.")
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, 14)
  local naming = ImGui.BeginPopupModal(ctx, "New side room", nil, ImGui.WindowFlags_AlwaysAutoResize)
  ImGui.PopStyleVar(ctx)
  if naming then
    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 300)
    -- (no EnterReturnsTrue: with it the name came back only on Return, so pressing Create lost what was typed: Mac, 0.45.0)
    local _, v = ImGui.InputTextWithHint(ctx, "##newroom", "a name (e.g. 'chorus ideas')", new_room)
    new_room = v
    local go = ImGui.Button(ctx, "Create") or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then ImGui.CloseCurrentPopup(ctx) end
    if go then
      local p, why = rooms.create(proj, cfg, b, new_room)
      if not p then band.msg(why) else
        band.log("made the side room '" .. new_room .. "' from '" .. b.room .. "' (you drive it)")
        new_room = ""
        if not M.live_running(p) then band.start_live(dir) end
        reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
        room_at = -math.huge
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
  if ui.short and not (room_view.meta and room_view.meta.parent) then ImGui.SameLine(ctx); come_see() end -- (a column of its own for one button: empty, in a short docker)
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, "Try ideas in a side room, then bring back what works. (?)")
  ImGui.SetItemTooltip(ctx, "Each room is its own project tab: click its square to go there. It opens once, then it's a tab switch, and it's still there next " ..
    "session.\n\nCreate side room: a copy of the room you're in, as it is now; you drive it. Try your own edits there, or work on " ..
    "something else.\n\nCome see!: everyone with the project open is asked to join you.\n\nSend selected to main: the items you pick " ..
    "come over as new takes. Bring into main: everything changed in the side room comes over, except where main changed the same " ..
    "thing too (those stay as main has them); main's driver does this, and Restore can undo it.")
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 178, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
  if wide then per = math.min(per, math.max(#room_view.list, 3)) end -- (a wide docker fitted ten thin ones: a few rooms left most of it empty)
  w = math.floor((avail - gap * (per - 1)) / per) -- (they fill the page, as the people's cards do)
  for i, r in ipairs(room_view.list) do
    if (i - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    local here = r.name == b.room
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, CARD) -- a card in either look
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 10)
    local open = ImGui.BeginChild(ctx, "room " .. r.name, w, 0, ImGui.ChildFlags_Borders | ImGui.ChildFlags_AlwaysUseWindowPadding | ImGui.ChildFlags_AutoResizeY,
      ImGui.WindowFlags_NoScrollbar)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)
    if open then
      if not r.parent then -- the main room stands out: the outline, in the logo's colours
        local cx, cy = ImGui.GetWindowPos(ctx)
        local cw, ch = ImGui.GetWindowSize(ctx)
        local dl = ImGui.GetWindowDrawList(ctx)
        ImGui.PushClipRect(ctx, cx, cy, cx + cw, cy + ch, true) -- (true: with the column's own edges, or it ran past them)
        ui.gradient(dl, cx, cy, cx + cw, cy + ch, cx, cx + cw, function(col) ImGui.DrawList_AddRect(dl, cx + 1, cy + 1, cx + cw - 1, cy + ch - 1, col, 8, 0, 2) end)
        ImGui.PopClipRect(ctx)
      end
      if here then ImGui.TextColored(ctx, GREEN, r.name .. "  (this tab)") else ImGui.Text(ctx, r.name) end
      -- (short: a line for where it came from and a line for everyone in it, or three people ran off the foot of the square)
      local function beside(words) if ui.short then next_to(ImGui.CalcTextSize(ctx, words)) end end
      local came = r.parent and ("side room of " .. r.parent) or "main room"
      beside(came)
      ImGui.TextDisabled(ctx, came)
      local people = room_view.people[r.name] or {}
      if #people == 0 then ImGui.TextDisabled(ctx, "nobody") end
      for i, p in ipairs(people) do
        local who_ = p.user .. (p.me and " (you)" or "") .. (p.here and "" or ": tab open")
        if i > 1 then beside(who_) end
        if p.here then ImGui.TextColored(ctx, GREEN, who_) else ImGui.TextDisabled(ctx, who_) end
      end
      if r.parent and not here then
        beside("Archive")
        ImGui.BeginDisabled(ctx, #people > 0)
        if ImGui.SmallButton(ctx, "Archive") and reaper.MB("Take '" .. r.name .. "' off the list for everyone?\n\nNothing is deleted: it can be brought back from this page.", "StudioSync", 4) == 6 then
          rooms.bin(cfg, b.song, r.name, cfg.user); E.refresh_now()
        end
        ImGui.EndDisabled(ctx)
        ImGui.SetItemTooltip(ctx, #people > 0 and "Someone has it open: it can be archived once its tabs are closed." or "Takes this idea off the list for everyone. Nothing is deleted.")
      end
      -- the square itself goes there
      local hover = not here and ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_ChildWindows) and not ImGui.IsAnyItemHovered(ctx)
      if hover then
        ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
        local cx, cy = ImGui.GetWindowPos(ctx)
        local cw, ch = ImGui.GetWindowSize(ctx)
        ImGui.DrawList_AddRect(ImGui.GetWindowDrawList(ctx), cx, cy, cx + cw, cy + ch, ACCENT, 10, 0, 2)
        ImGui.SetTooltip(ctx, "Go to " .. r.name)
      end
      local go = hover and ImGui.IsMouseClicked(ctx, 0)
      ImGui.EndChild(ctx)
      if go then go_room(r.name) end
    end
  end
  if #room_view.binned > 0 and ImGui.TreeNodeEx(ctx, "archived", string.format("Archived rooms (%d)", #room_view.binned), ImGui.TreeNodeFlags_SpanAvailWidth) then
    for _, r in ipairs(room_view.binned) do
      if ImGui.SmallButton(ctx, "Bring back##" .. r.name) then rooms.bin(cfg, b.song, r.name, nil); E.refresh_now() end
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, r.name .. "  (archived by " .. tostring(r.binned) .. ")")
    end
    ImGui.TreePop(ctx)
  end
end
function M.actions()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  if not room_view then return end
  if not wide then ImGui.Separator(ctx) end
  local parent = room_view.meta and room_view.meta.parent
  come_see()
  if not parent then -- (a tall docker: what's in the tooltip, in the room there is)
    if wide then
      ImGui.TextDisabled(ctx, "Asks everyone with this project open to join you in this room.")
      ImGui.Spacing(ctx)
      heading("How rooms work")
      ImGui.TextDisabled(ctx, "Each room is its own project tab: click its square to go there. It opens once, then it's a tab switch.")
      ImGui.TextDisabled(ctx, "A side room is a copy of the room you're in, as it is now, and you drive it. Try your own edits there, or work on something else.")
      ImGui.TextDisabled(ctx, "From a side room, send over the items you pick, or bring in everything that changed. Restore can undo it.")
    end
    return
  end
  next_to("Send selected to " .. parent)
  if ImGui.Button(ctx, "Send selected to " .. parent) then
    local list = require("mirror").selected(proj, cfg, b.song, b.room, parent)
    local chosen = #list
    local refused
    list, refused = require("mirror").allowed_into(cfg, b.song, parent, list, view.session)
    if chosen == 0 then band.msg("Select the items to send first (they go to '" .. parent .. "' as they are here).")
    elseif #list == 0 then band.msg("None of those are yours to change in '" .. parent .. "': someone has claimed them, or " .. parent .. "'s driver owns them. Claim them there first.")
    elseif reaper.MB(string.format("Send the %d selected item(s) to '%s', as they are here? (Any of their tracks '%s' doesn't have yet go too.)",
        reaper.CountSelectedMediaItems(proj), parent, parent), "StudioSync", 4) == 6 then
      band.log(string.format("sent %d change(s) from '%s' to '%s'%s", require("mirror").post_into(cfg, b.song, b.room, parent, list, rooms.tab(b.song, parent)), b.room, parent,
        refused > 0 and string.format(" (%d not yours to change there, left out)", refused) or ""))
    end
  end
  ImGui.SetItemTooltip(ctx, "The easy way back: the selected items go to '" .. parent .. "' as they are here (new changes there, so Restore there can undo them).")
  next_to("Bring into " .. parent .. "...")
  if ImGui.Button(ctx, merge and "Look again" or ("Bring into " .. parent .. "...")) then look_merge(parent) end
  ImGui.SetItemTooltip(ctx, "Compares this room, '" .. parent .. "' and how this room started: everything changed here comes over, " ..
    "except what '" .. parent .. "' changed too since (it keeps its own; use Send selected for those). New recordings come too.")
  if merge then section_merge() end
end



-- Bandmates asking you to come and see their room (any tab of the song).
local invites, invites_at = {}, -math.huge
function M.invites()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  if reaper.time_precise() - invites_at > 3 then invites_at = reaper.time_precise(); invites = rooms.invites(cfg, b.song) end
  for _, v in ipairs(invites) do
    local key = v.from .. v.time
    if v.room ~= b.room and not dismissed[key] then
      ImGui.PushID(ctx, key)
      if ImGui.SmallButton(ctx, "Go") then dismissed[key] = true; go_room(v.room) end -- (buttons first: long words pushed them off a narrow panel)
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Not now") then dismissed[key] = true end
      ImGui.SameLine(ctx)
      ImGui.TextColored(ctx, YELLOW, v.from .. " asks you to come and see '" .. v.room .. "'")
      ImGui.PopID(ctx)
    end
  end
end

-- What the page is showing (the room, its list, where it came from), and a fresh look on the next refresh.
function M.view() return room_view end
function M.reset() room_at, merge = -math.huge, nil end

return M
