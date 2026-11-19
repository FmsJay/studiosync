-- The Restore page (moved out of StudioSync - Panel.lua, 0.58.49: the panel was at Lua's 200 locals): saved versions, every change with
-- what can be done with it, and History's filters. The panel hands over what it shares (R.init); what changes as you work (the tab in front,
-- your settings, the layout, the saved versions it reads every few seconds) is asked for at every call, never kept.
local band = require("band")
local sync, recall, mirror = require("sync"), require("recall"), require("mirror")
local theme = require("theme")
local GREEN, RED = theme.GREEN, theme.RED
local R = {}
local E, ctx, ImGui, ui, dir, action, next_to, combo, describe, local_time
function R.init(env)
  E, ctx, ImGui, ui, dir, action, next_to = env, env.ctx, env.ImGui, env.ui, env.dir, env.action, env.next_to
  combo, describe, local_time = env.combo, env.describe, env.local_time
end
local label, keep_it = "", false -- (the name for the next saved version, as it's typed; and whether it's kept for good)

-- History's "kind" filter: a set of event kinds, or a test on the change
local KINDS = {
  { "Every kind" }, { "Items (recordings, MIDI, moves, edits)", function(e) return e.obj == "item" and not e.gone end },
  { "Tracks (names, lanes, mute, folders)", function(e) return e.obj == "track" and not e.gone end },
  { "Plug-ins", function(e) return e.obj == "fx" end }, { "Automation, sends and track settings", function(e) return e.obj == "env" or e.obj == "recv" or e.obj == "misc" end },
  { "Deletes", function(e) return e.gone end },
  { "Brought back (undo, restore)", function(e) return e.restored ~= nil end },
  { "Notes and likes", { note = true, like = true } }, { "Tempo and arrangement", { timeline = true, shift = true } },
  { "Who drives (handovers)", { driver = true } }, { "Played or recorded together", { start = true, stop = true } },
}
local hf = { who = "", kind = 1, track = "", text = "" }
local entries, groups, hist_at = {}, {}, 0
-- (the tab and room the list is of: switching tabs left the old list up, and its buttons restored that room's history into this project,
-- for everyone. Review, 0.59.14)
local entries_key
local function check_key()
  local b, proj = E.b(), E.proj()
  local key = b and (tostring(proj) .. "|" .. tostring(b.song) .. "|" .. tostring(b.room)) or nil
  if key ~= entries_key then entries, groups, hf.open, hist_at, entries_key = {}, {}, nil, 0, key end
end
local function refresh_history()
  local b, cfg, proj, view, wide, points, can, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.points(), E.can(), E.who()
  check_key()
  entries = recall.entries(cfg, b.song, b.room)
  table.sort(entries, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  groups = recall.groups(entries, view.session and view.session.host)
end
-- What can be done with a change, under it once it's clicked: Undo (only that change), restore to it (the selected tracks, or the
-- whole project: driver only), or a look at it in a side room. (Buttons on every row were clutter, and a radio above the list picking
-- what every row does hid Undo behind it, and acted on whatever was clicked next: review D29, James 2026-11-03.)
-- i: History index (the state right after entries[i]); what: words for the confirm box; single: a change of its own.
-- Where a change happened, shown: its item selected with the edit cursor at it, or its track selected; scrolled into view and flashed in
-- the arrange view. -> nil, or why not. (James, 0.59.32: from "Since you were last here", a change you could read about but not find.)
function R.show_change(proj, e)
  local mirror = require("mirror")
  mirror.index_for(proj)
  local item = e.obj == "item" and not e.gone and mirror.find(proj, "item", e.oid)
  local track = item and reaper.GetMediaItem_Track(item)
    or (e.obj == "track" and not e.gone and mirror.find(proj, "track", e.oid))
    or (type(e.track) == "string" and e.track ~= "" and mirror.find(proj, "track", e.track)) or nil
  if not (item or track) then return e.gone and "it was deleted: Undo this change brings it back" or "it isn't in the project any more" end
  reaper.PreventUIRefresh(1)
  if item then
    reaper.SelectAllMediaItems(proj, false)
    reaper.SetMediaItemSelected(item, true)
    reaper.SetEditCurPos2(proj, reaper.GetMediaItemInfo_Value(item, "D_POSITION"), true, false)
  elseif tonumber(e.pos) then reaper.SetEditCurPos2(proj, tonumber(e.pos), true, false) end
  if track then
    reaper.SetOnlyTrackSelected(track)
    reaper.Main_OnCommandEx(40913, 0, proj) -- Track: Vertical scroll selected tracks into view
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  R.flash = { item = item, track = track, until_ = reaper.time_precise() + 2.5 }
end
-- The flash itself, from the panel's frame: the item or track blinks for a moment (its own selection, toggled), then stays selected.
function R.flash_tick()
  local f = R.flash
  if not f then return end
  local on = f.until_ <= reaper.time_precise() or math.floor(reaper.time_precise() * 4) % 2 == 0
  if f.item and reaper.ValidatePtr(f.item, "MediaItem*") then reaper.SetMediaItemSelected(f.item, on); reaper.UpdateItemInProject(f.item)
  elseif f.track and reaper.ValidatePtr(f.track, "MediaTrack*") then reaper.SetTrackSelected(f.track, on) end
  if f.until_ <= reaper.time_precise() then R.flash = nil end
end
-- History showing only what the others changed since `since` (UTC, as event times are): "Since you were last here"'s See what changed.
function R.show_since(since)
  hf = { who = "", kind = 1, track = "", text = "", since = since }
end
-- What going back to entries[i] brings: a saved version (`point`, its recall.list row) that holds the project's own map is restored to exactly
-- that (mirror.plan_known); one saved before 0.59.45, or a moment in History, by time as before. Round 1 review, 0.59.45 (one file read per
-- restore of a saved version).
local function plan_for(i, point, scope)
  local b, cfg = E.b(), E.cfg()
  local st = point and point.file and band.read_json(recall.dir(cfg, b.song, b.room) .. "/" .. point.file)
  if type(st) == "table" and type(st.known) == "table" and next(st.known) then
    local by_id, rdir = {}, sync.room_dir(cfg, b.song, b.room)
    for _, e in ipairs(entries) do if e.id then by_id[e.id] = e end end
    return mirror.plan_known(entries, st.known, function(id) return by_id[id] or mirror.event_file(rdir, id) end, scope)
  end
  return mirror.plan_restore(entries, i, scope)
end
local function back_button(i, what, single, point)
  local b, cfg, proj, view, wide, points, can, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.points(), E.can(), E.who()
  local e, mirror = entries[i], require("mirror")
  local opts = { can = can, mode = who and who.mode, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
  if single and e and e.kind == "obj" then
    if ImGui.SmallButton(ctx, "Go to it") then
      local why = R.show_change(proj, e)
      if why then band.msg("Can't show it: " .. why .. ".") end
    end
    ImGui.SetItemTooltip(ctx, "Selects what this changed (the item, or its track), scrolls to it and flashes it.")
    next_to("Undo this change")
  end
  if single then
    ImGui.BeginDisabled(ctx, not e or e.kind ~= "obj")
    if ImGui.SmallButton(ctx, "Undo this change") then
      local others, me = mirror.later_by_others(entries, i), false
      for k = #others, 1, -1 do if others[k] == cfg.user then table.remove(others, k); me = true end end
      if me then table.insert(others, 1, "You") end -- (it named you in the third person: laptop 0.34.4)
      local whose = #others == 1 and me and "your" or "their"
      if #others == 0 or reaper.MB(table.concat(others, ", ") .. " changed it after this: undoing it takes " .. whose .. " change back too. Undo anyway?",
          "StudioSync", 4) == 6 then
        band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_undo_moment(entries, i), opts)); hist_at = 0
      end
    end
    ImGui.EndDisabled(ctx)
    local together = #mirror.same_moment(entries, i)
    ImGui.SetItemTooltip(ctx, e and e.kind == "obj" and ((together > 1 and string.format("Undo this and the %d other change(s) made with it: ", together - 1) or "Undo only this change: ") ..
      describe(e) .. ". Everything else stays; the undo goes to the others as a new change.")
      or "This kind of change (tempo, a handover, a note) isn't undone on its own: restore the whole project to here instead.")
    next_to("Restore selected tracks to here")
  end
  -- (a version older than everything in History has nothing to rebuild it from: restored, every track and item went, for everyone. Review, 0.58.92)
  local before_history = i < 1
  ImGui.BeginDisabled(ctx, before_history)
  if ImGui.SmallButton(ctx, "Restore selected tracks to here") then
    local scope = mirror.selection_scope(proj)
    if not scope then band.msg("Select the tracks to put back first (click their names in REAPER).")
    elseif reaper.MB("Put the selected tracks (their items and plug-ins) back to how they were " .. what .. "?\n\nEverything else stays as it is now.", "StudioSync", 4) == 6 then
      band.log(mirror.revert(proj, cfg, b.song, b.room, plan_for(i, point, scope), opts)); hist_at = 0
    end
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, before_history and "This version is older than every change kept in History, so it can't be rebuilt from it." or
    ("The tracks selected in REAPER, as they were " .. what .. ". It goes to the others as new changes."))
  next_to("Restore whole project to here")
  local driving = view.driver == cfg.user
  ImGui.BeginDisabled(ctx, not driving or before_history)
  if ImGui.SmallButton(ctx, "Restore whole project to here") and reaper.MB("Make the whole project look like it did " .. what .. "?\n\n" ..
      "Everything since then is undone, for everyone. It's a change like any other, so you can come back the same way.", "StudioSync", 4) == 6 then
    sync.restore_timeline(proj, cfg, b.song, b.room, entries, i, view.session)
    band.log(mirror.revert(proj, cfg, b.song, b.room, plan_for(i, point), opts))
    E.refresh_now(); hist_at = 0
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, before_history and "This version is older than every change kept in History, so it can't be rebuilt from it." or
    driving and ("The whole project, as it was " .. what .. ". It goes to the others as new changes.") or "Only the driver can restore the whole project: ask them, or take control.")
  next_to("Open in side room")
  if ImGui.SmallButton(ctx, "Open in side room") then
    -- a look at that moment that touches nobody's work: a new room, put back to then. Archive it (Rooms) when you've heard it.
    local name = "Check " .. os.date("%H%M%S")
    local p, why = require("rooms").create(proj, cfg, b, name)
    if not p then band.msg(why) else
      local room_can = sync.authority(cfg, b.song, name, view.session)
      local plan = plan_for(i, point)
      sync.restore_timeline(p, cfg, b.song, name, entries, i, view.session, b.room)
      band.log("'" .. name .. "' is the project as it was " .. what .. ": " .. tostring(mirror.revert(p, cfg, b.song, name, plan, { at_once = true, can = room_can, mode = "claims", exact = true })))
      local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
      if not (beat and reaper.time_precise() - beat < 5) then band.start_live(dir) end
      reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
    end
  end
  ImGui.SetItemTooltip(ctx, "Opens the project as it was " .. what .. " in a new side room, to check it's the right one. Nothing changes for anyone else.")
end
-- Each person's own colour, as drawings and tracks show them.
local function person_colour(user)
  local cfg = E.cfg()
  local name = user:gsub(" %(.-%)$", "")
  local rgb = require("people").colours(cfg.root, { name })[name]
  return rgb and theme.readable((rgb << 8) | 0xFF) or theme.TEXT -- (a pale colour on Light, a dark one on Dark: made to read. 0.59.7)
end
-- What a change did, at a glance: taken out in red, brought back in green.
local function change_tint(e) return e.gone and RED or e.restored ~= nil and GREEN or nil end
-- One change or saved version: its time and words, the whole line a button that opens its options under it. One open at a time.
local function change_row(key, time, words, i, what, single, who_, tint, point)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local at = ImGui.CalcTextSize(ctx, time) + 8
  local _, h = ImGui.CalcTextSize(ctx, (who_ and (who_ .. ": ") or "") .. words, nil, nil, false, avail - at)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local open = hf.open == key
  if ImGui.Selectable(ctx, "##row", open, ImGui.SelectableFlags_None, avail, h) then hf.open, hf.show = not open and key or nil, true end
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.TextDisabled(ctx, time)
  ImGui.SameLine(ctx, 0, 8)
  if who_ then
    ImGui.PushFont(ctx, ui.bold, 15)
    ImGui.TextColored(ctx, person_colour(who_), who_ .. ":")
    ImGui.PopFont(ctx)
    ImGui.SameLine(ctx, 0, 5)
  end
  if tint then ImGui.PushStyleColor(ctx, ImGui.Col_Text, tint) end
  ImGui.TextWrapped(ctx, words)
  if tint then ImGui.PopStyleColor(ctx) end
  if open then
    ImGui.Indent(ctx, at)
    back_button(i, what, single, point)
    ImGui.Unindent(ctx, at)
    if hf.show then ImGui.SetScrollHereY(ctx, 1); hf.show = nil end -- (the last row's options opened out of sight, and it looked like nothing happened)
    ImGui.Spacing(ctx)
  end
end

-- Filtered: the matching changes as one list (newest first), each with its own button.
local function history_filtered(driving)
  local b, cfg, proj, view, wide, points, can, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.points(), E.can(), E.who()
  local want = KINDS[hf.kind][2]
  local text = hf.text:lower()
  local n = 0
  for i = #entries, 1, -1 do
    local e = entries[i]
    local line = describe(e)
    local lane = require("mirror").lane_words(entries, i) -- (in the search too: "lane" found nothing though every row said it: Mac, 0.45.0)
    local ok = not e.auto and (hf.who == "" or e.user == hf.who) and (not hf.since or ((e.time or "") > hf.since and e.user ~= cfg.user)) and (not want or (type(want) == "function" and want(e)) or (type(want) == "table" and want[e.kind]))
      and (hf.track == "" or (e.name or e.track or ""):lower() == hf.track:lower())
      and (text == "" or (line .. lane .. " " .. tostring(e.user)):lower():find(text, 1, true))
    local moment = ok and require("mirror").same_moment(entries, i) or { i }
    for _, j in ipairs(moment) do if j > i then ok = false end end -- (one row for one act, on the newest of them)
    if ok then line = line .. lane end
    if #moment > 1 then line = line .. string.format(" (%d changes at that moment, undone together)", #moment) end
    if ok then
      n = n + 1
      ImGui.PushID(ctx, i)
      change_row(e.id or i, local_time(e.time), line, i, string.format("right after %s's change at %s", e.user, local_time(e.time)), true, e.user, change_tint(e))
      ImGui.PopID(ctx)
    end
  end
  if n == 0 then ImGui.TextDisabled(ctx, "Nothing matches.") end
end
function R.section_recall()
  check_key()
  local b, cfg, proj, view, wide, points, can, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.points(), E.can(), E.who()
  if not ui.short then ImGui.SeparatorText(ctx, "Saved versions") end -- (short: the box's own words say it, and the list gets the row)
  -- (room for the button and Keep for good beside it: -250 cut it off. James, 0.59.3)
  local reserve = ImGui.CalcTextSize(ctx, "Save this version") + ImGui.CalcTextSize(ctx, "Save permanently") + ImGui.GetFrameHeight(ctx) + 70
  local own_line = ImGui.GetContentRegionAvail(ctx) - reserve < 160 -- (a narrow column: the box shrank to 1 px. Layout review, 0.59.14)
  ImGui.SetNextItemWidth(ctx, own_line and -1 or -reserve)
  local _, v = ImGui.InputTextWithHint(ctx, "##label", "name this version (e.g. 'chorus with double guitars')", label, ImGui.InputTextFlags_None)
  label = v
  if not own_line then ImGui.SameLine(ctx) end
  if ImGui.Button(ctx, "Save this version") then
    if keep_it then recall.back_up(proj, cfg, b, label ~= "" and label or nil) -- (kept for good, and the project on Drive: what Back up did)
    else recall.save(proj, cfg, b.song, b.room, label ~= "" and label or "saved by " .. cfg.user) end
    label = ""
    E.refresh_now()
  end
  ImGui.SameLine(ctx)
  local _, k = ImGui.Checkbox(ctx, "Save permanently##keepver", keep_it)
  keep_it = k
  ImGui.SetItemTooltip(ctx, "Never trimmed, and the project goes to " .. require("drive").name(cfg) .. " too if you use it.")
  ImGui.TextDisabled(ctx, "Render, stems, credits, templates and A/B: the Mixes tab.")
  local driving = view.driver == cfg.user
  -- (docked, the list takes the column's height instead of a short box inside it)
  if ImGui.BeginChild(ctx, "points", 0, wide and math.max(70, select(2, ImGui.GetContentRegionAvail(ctx)) - 4) or 110, ImGui.ChildFlags_Borders) then
    if #points == 0 then ImGui.TextDisabled(ctx, "None yet. Every handover saves one by itself.") end
    local before = select(2, reaper.GetProjExtState(proj, band.SECTION, "before_bandsync"))
    if before ~= "" and reaper.file_exists(before) then
      if ImGui.SmallButton(ctx, "Open it as it was before StudioSync") then reaper.Main_OnCommand(40859, 0); reaper.Main_openProject(before) end
      ImGui.SetItemTooltip(ctx, "Opens the copy saved when this project was first published, in a new tab (it isn't shared).")
    end
    for i, p in ipairs(points) do
      ImGui.PushID(ctx, i)
      local upto = 0 -- (mirror sessions: the point is a moment in History)
      for k, e in ipairs(entries) do if (e.time or "") <= (p.time or "") then upto = k end end
      change_row("version " .. i, local_time(p.time), string.format("%s%s%s", p.label, p.keep and " (kept)" or "", (p.takes or 0) > 0 and string.format("  ·  %d takes", p.takes) or ""), upto, "at '" .. p.label .. "'", nil, tostring(p.by), p.keep and GREEN or nil, p)
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
  R.section_kept()
end

-- Automation of yours that was refused and kept (lib/mirror.lua put_back, 0.59.39): put back on its track, where it goes out as your change if
-- it may by then, or let go. Read every few seconds: they're files in this computer's StudioSync folder.
local kept_at, kept = -math.huge, {}
local function kept_list()
  if reaper.time_precise() - kept_at < 3 then return kept end
  kept_at, kept = reaper.time_precise(), {}
  local dir = band.home() .. "/kept automation"
  for _, f in ipairs(band.files(dir, ".json")) do
    local k = band.read_json(dir .. "/" .. f)
    if type(k) == "table" and type(k.state) == "string" and type(k.track) == "string" then k.path = dir .. "/" .. f; kept[#kept + 1] = k end
  end
  table.sort(kept, function(a, x) return tostring(a.time) > tostring(x.time) end)
  return kept
end
function R.section_kept()
  local list = kept_list()
  if #list == 0 then return end
  local b, cfg, proj = E.b(), E.cfg(), E.proj()
  local room = b and sync.room_dir(cfg, b.song, b.room)
  ImGui.SeparatorText(ctx, "Kept automation")
  ImGui.TextDisabled(ctx, "Automation of yours that wasn't sent (it wasn't yours to change then).")
  for i, k in ipairs(list) do
    ImGui.PushID(ctx, "kept" .. i)
    local tr = k.room == room and mirror.find(proj, "track", k.track)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, string.format("%s  ·  %s%s", tostring(k.name or "a track"), local_time(k.time or ""), k.back and "  ·  put back" or ""))
    next_to("Put mine back")
    ImGui.BeginDisabled(ctx, not tr)
    if ImGui.SmallButton(ctx, "Put mine back") then
      local local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
      if mirror.apply(proj, { obj = "env", oid = k.oid, track = k.track, name = k.name, state = k.state }, nil, local_mix) then
        -- (the file stays, marked: it goes once the automation has gone out as yours (lib/mirror.lua), or with Let it go. Deleted here, a second
        -- refusal of the same automation kept nothing and it was lost. Round 1 review, 0.59.45)
        local path = k.path
        k.path, k.back = nil, true
        pcall(band.write_json, path, k)
        k.path, kept_at = path, -math.huge
        band.log("your automation on " .. tostring(k.name) .. " is back: it goes to the others as your change, if it's yours to change now (the kept copy stays until it has)")
      else band.msg("Not now: bring this project to the front, and stop recording, then try again.") end
    end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, tr and "Puts your automation back on the track. If the track is yours to change now, it goes to the others like any change; if not, it's kept again."
      or "Its track isn't in this project (it was kept from another one, or the track is gone).")
    next_to("Let it go")
    if ImGui.SmallButton(ctx, "Let it go") and reaper.MB("Forget this automation of yours on " .. tostring(k.name) .. "? It can't be brought back after.", "StudioSync", 4) == 6 then
      os.remove(k.path); kept_at = -math.huge
    end
    ImGui.PopID(ctx)
  end
end

function R.section_history()
  check_key()
  local b, cfg, proj, view, wide, points, can, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.points(), E.can(), E.who()
  local warm, read, total = recall.warm(cfg, b.song, b.room, 0.01)
  if not warm then return ImGui.TextDisabled(ctx, string.format("Reading the history: %d of %d changes...", read, total)) end
  if reaper.time_precise() - hist_at > 4 then hist_at = reaper.time_precise(); refresh_history() end
  if ui.short then ImGui.AlignTextToFramePadding(ctx); ImGui.TextDisabled(ctx, "Every change, newest first"); ImGui.SameLine(ctx)
  else ImGui.SeparatorText(ctx, "Every change, newest first") end
  ImGui.SetItemTooltip(ctx, "Click a change to undo it, restore to it, or open it in a side room.")
  local driving = view.driver == cfg.user
  if #groups == 0 then ImGui.TextDisabled(ctx, "Nothing has happened in this room yet: every change anyone makes shows here, with a way back.") end
  -- filters: who, what kind, which track, and words
  local users, tracks, seen = { "Everyone" }, { "Every track" }, {}
  for _, e in ipairs(entries) do
    if e.user and not seen["u" .. e.user] then seen["u" .. e.user] = true; users[#users + 1] = e.user end
    local tn = e.kind == "obj" and e.name or e.track -- (mirror changes carry the track's name; .track is its id)
    if tn and tn ~= "" and not seen["t" .. tn:lower()] then seen["t" .. tn:lower()] = true; tracks[#tracks + 1] = tn end
  end
  local kinds = {}
  for i, k in ipairs(KINDS) do kinds[i] = k[1] end
  local function filters()
    local v = combo("##hwho", hf.who == "" and "Everyone" or hf.who, users, "Only this person's changes.")
    if v then hf.who = v == "Everyone" and "" or v end
    next_to(170)
    v = combo("##hkind", KINDS[hf.kind][1], kinds, "Only this kind of change.")
    if v then for i, k in ipairs(kinds) do if k == v then hf.kind = i end end end
    next_to(170)
    v = combo("##htrack", hf.track == "" and "Every track" or hf.track, tracks, "Only changes on this track.")
    if v then hf.track = v == "Every track" and "" or v end
    next_to(150)
    ImGui.SetNextItemWidth(ctx, 150)
    local _, t = ImGui.InputTextWithHint(ctx, "##htext", "words in it", hf.text, ImGui.InputTextFlags_None)
    hf.text = t
    ImGui.SetItemTooltip(ctx, "Only changes whose description has these words (a take, a track, a note's text...).")
  end
  local filtered = hf.who ~= "" or hf.kind ~= 1 or hf.track ~= "" or hf.text ~= "" or hf.since ~= nil
  if hf.since then
    ImGui.TextColored(ctx, theme.ACCENT, "What the others changed since you were last here")
    ImGui.SetItemTooltip(ctx, "Click a change, then Go to it: StudioSync takes you there. Clear filters shows everything again.")
  end
  if wide or ImGui.GetContentRegionAvail(ctx) < 520 then -- (four rows of them came before the first change: design review)
    if ImGui.SmallButton(ctx, filtered and "Filter (on)..." or "Filter...") then ImGui.OpenPopup(ctx, "hfilters") end
    if ImGui.BeginPopup(ctx, "hfilters") then filters(); ImGui.EndPopup(ctx) end
  else filters() end
  if filtered then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Clear filters") then hf = { who = "", kind = 1, track = "", text = "" } end
    ImGui.SetItemTooltip(ctx, "Back to everything, grouped by who made it.")
  end
  -- (docked, no list box of its own: under the filters it had no height left, so the column itself scrolls instead)
  if wide or ImGui.BeginChild(ctx, "history", 0, math.max(300, select(2, ImGui.GetContentRegionAvail(ctx)) - 4)) then
    if filtered then
      history_filtered(driving)
      if not wide then ImGui.EndChild(ctx) end
      return
    end
    for gi = #groups, 1, -1 do
      local g = groups[gi]
      local shown = {} -- (prints StudioSync refreshed by itself are left out: no one made them)
      for i = g.first, g.last do if not entries[i].auto then shown[#shown + 1] = i end end
      if #shown == 0 then goto next_group end
      ImGui.PushID(ctx, gi)
      local n = #shown
      local who_ = g.user .. (g.solo and " (Solo edit)" or g.user == g.driver and " (driving)" or "")
      if n == 1 then -- (one change: the row itself, no list of one to open first)
        local i = shown[1]
        change_row(entries[i].id or i, local_time(entries[i].time), describe(entries[i]) .. require("mirror").lane_words(entries, i), i,
          string.format("right after %s's change at %s", entries[i].user, local_time(entries[i].time)), true, who_, change_tint(entries[i]))
        ImGui.PopID(ctx)
        goto next_group
      end
      local head = string.format("%s  ·  %s%s", who_, local_time(g.from), g.from ~= g.to and ("-" .. local_time(g.to):sub(7)) or "")
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, person_colour(g.user))
      ImGui.PushFont(ctx, ui.bold, 15)
      local open = ImGui.TreeNodeEx(ctx, "g", head, ui.short and ImGui.TreeNodeFlags_None or ImGui.TreeNodeFlags_SpanAvailWidth)
      ImGui.PopFont(ctx)
      ImGui.PopStyleColor(ctx)
      if not open then -- what it was about, wrapped under the line that opens it (short: beside it, or a group took two rows of six)
        if ui.short then ImGui.SameLine(ctx, 0, 10) else ImGui.Indent(ctx) end
        ImGui.TextDisabled(ctx, describe(entries[shown[#shown]]) .. (n > 1 and string.format("  (+%d more)", n - 1) or ""))
        if not ui.short then ImGui.Unindent(ctx) end
      end
      if open then
        for k = #shown, 1, -1 do -- (newest first, as the page says: opened, a group read the other way, and the wrong moment got restored)
          local i = shown[k]
          local moment, first = require("mirror").same_moment(entries, i), true
          for _, j in ipairs(moment) do if j > i then first = false end end -- (one row for one act, as in the filtered list)
          if first then
            ImGui.PushID(ctx, i)
            change_row(entries[i].id or i, local_time(entries[i].time):sub(7), describe(entries[i]) .. require("mirror").lane_words(entries, i) .. (#moment > 1 and string.format(" (%d changes at that moment, undone together)", #moment) or ""),
              i, string.format("right after %s's change at %s", entries[i].user, local_time(entries[i].time)), true, nil, change_tint(entries[i]))
            ImGui.PopID(ctx)
          end
        end
        ImGui.TreePop(ctx)
      end
      ImGui.PopID(ctx)
      ::next_group::
    end
    if not wide then ImGui.EndChild(ctx) end
  end
end

-- Drum map of the selected tracks. Changing it rewrites the StudioSync MIDI on those tracks into the new map,
-- so the notes keep hitting the same drums with the new instrument.
-- Plug-ins everyone in the band has, as a folder in REAPER's FX browser (lib/plugins.lua).

-- Read History again on the next look (an undo or redo from the top bar changed it).
function R.refresh_soon() hist_at = 0 end

-- The Mixes page (UX review, 0.58.62: rendering, stems, credits and A/B sat under Restore's saved versions, where nobody looked for them):
-- what you make from the project, as opposed to Restore's ways back.
function R.section_mixes()
  local b, cfg, proj = E.b(), E.cfg(), E.proj()
  ImGui.SeparatorText(ctx, "The mix")
  if ImGui.SmallButton(ctx, "Render current mix") then action("Final mix") end
  ImGui.SetItemTooltip(ctx, "Opens REAPER's Render window set up for the studio: the whole project as your master has it, 24-bit WAV at the project's sample rate,\n" ..
    "with a safety limiter, into the shared folder's mixes/ (and " .. require("drive").name(cfg) .. " if you use it). Check it and press Render; your own render settings are back after.\n" ..
    "Everyone's parts are in it, yours too. Only tracks that stay on this computer ('yours, not sent', StudioSync's helpers) are left out. Nothing is added to the project.")
  ImGui.SeparatorText(ctx, "Stems, for whoever mixes")
  if ImGui.SmallButton(ctx, "Export stems") then
    local out, n = require("extras").stems(proj, cfg, b)
    if out then
      band.log(string.format("%d stem(s) in %s, for everyone", n, out))
      pcall(function() require("page_chat").post(cfg, b, string.format("Stems for whoever mixes: %d file(s) in the shared folder's %s", n, out:match("[^/]+/stems/.*$") or out)) end)
    else band.msg(n) end
  end
  ImGui.SetItemTooltip(ctx, "Opens REAPER's Render window set up for stems: one file per shared track, the whole song, all starting together, 24-bit WAV at the\n" ..
    "project's sample rate, no normalizing or dither, into the shared folder's stems/ for everyone. Check it and press Render; your settings are back after.\n" ..
    "Tracks that stay on this computer are left out, silent ones skipped.")
  next_to("Dry stems")
  if ImGui.SmallButton(ctx, "Dry stems") then
    local out, n = require("extras").stems(proj, cfg, b, true)
    if out then band.log(string.format("%d dry stem(s) in %s, for everyone", n, out)) else band.msg(n) end
  end
  ImGui.SetItemTooltip(ctx, "The same, without each track's effects (instruments still play), only tracks with parts on them (not buses or folders): what a mixer\n" ..
    "usually asks for. Your effects are back as they were after.")
  ImGui.SeparatorText(ctx, "Finishing up")
  if ImGui.SmallButton(ctx, "Credits draft") then
    local path = require("extras").credits(cfg, b)
    band.log("credits draft written for everyone: " .. path)
    band.open_url(path)
  end
  ImGui.SetItemTooltip(ctx, "Who started which tracks, recorded which takes and made which changes, from the history: a draft to agree the splits on.\n" ..
    "Written to the shared folder (credits.txt), with the percentages left for you to fill in.")
  next_to("Save as studio template")
  if ImGui.SmallButton(ctx, "Save as studio template") then
    local ok, name = reaper.GetUserInputs("Save as studio template", 1, "Template name:,extrawidth=120", b.song)
    if ok then
      local path, why = require("extras").save_template(proj, cfg, name)
      if path then band.log("saved '" .. name .. "' as a template for everyone in the studio: Projects > New from template") else band.msg(why) end
    end
  end
  ImGui.SetItemTooltip(ctx, "This song's tracks, routing, plug-ins, colours and tempo, without its recordings: everyone in the studio can start a new song from it\n" ..
    "(Projects page, New from template). Each studio has its own templates.")
  next_to("Save a copy outside the studio")
  if ImGui.SmallButton(ctx, "Save a copy outside the studio") then
    local keep, wav = "As it is (FLAC, as recorded)", "With WAV files"
    local pick = band.pick({ "#A plain project of its own, with all its media", keep, wav })
    if pick == keep or pick == wav then require("export").ask(proj, b.song, pick == wav) end
  end
  ImGui.SetItemTooltip(ctx, "A separate plain REAPER project in a folder you pick, with every file it uses, that opens anywhere with no StudioSync. Nothing in the studio changes, and nothing you do to the copy goes to anyone.\n\n" ..
    "For an older version: click it below, Open in side room, then save the copy from that room.")
  ImGui.SeparatorText(ctx, "Compare two mixes (A/B)") -- (lib/extras.lua: same place, same loudness)
  require("extras").ab_draw(ctx, ImGui, cfg, b)
end

return R
