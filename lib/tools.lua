-- The panel's tools: keep/dismiss live ideas, and starting Live sync with REAPER. (Dry mode, take back, print audio
-- and the take-based undo went with mirror sync in 0.30: Restore and the top bar's Undo/Redo replace them.)
local band = require("band")
local tools = {}

-- ---- live ideas (placeholders from Play along) ---------------------------------------------------------------
function tools.ideas(proj)
  local by = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local who = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it))):gsub(" %(live%)$", "")
      by[who] = (by[who] or 0) + 1
    end
  end
  return by
end
-- Keep: the selected placeholders become ordinary items of ours (no take will ever replace them).
function tools.keep_ideas(proj)
  local n = 0
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      for _, k in ipairs({ "band_live", "band_live_since", "band_live_heard" }) do band.set_item_ext(it, k, "") end
      n = n + 1
    end
  end
  return n
end
-- Dismiss: every placeholder (of `who`, or everyone's) goes.
function tools.dismiss_ideas(proj, who)
  local n = 0
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local tr = reaper.GetMediaItem_Track(it)
      if not who or select(2, reaper.GetTrackName(tr)):gsub(" %(live%)$", "") == who then
        reaper.DeleteTrackMediaItem(tr, it)
        n = n + 1
      end
    end
  end
  return n
end

-- ---- Live sync with REAPER: a block in Scripts/__startup.lua runs StudioSync - Autostart.lua -------------------
local MARK_A, MARK_Z = "-- BandSync autostart", "-- /BandSync autostart"
local function startup_path() return reaper.GetResourcePath() .. "/Scripts/__startup.lua" end
function tools.autostart_on(dir)
  local text = band.read(startup_path()) or ""
  return text:find(MARK_A, 1, true) ~= nil and (not dir or text:find(dir .. "/StudioSync - Autostart.lua", 1, true) ~= nil) -- (dir: and it's this copy)
end
function tools.set_autostart(on, dir)
  local text = band.read(startup_path())
  if not text and reaper.file_exists(startup_path()) then return false, "couldn't read " .. startup_path() end -- (written with only ours, the rest was gone)
  text = text or ""
  local a = text:find(MARK_A, 1, true)
  if a then
    local z = text:find(MARK_Z, a, true)
    text = text:sub(1, a - 1) .. (z and text:sub(z + #MARK_Z + 1) or "")
  end
  if on then
    text = text .. (text ~= "" and not text:match("\n$") and "\n" or "") ..
      MARK_A .. "\ndofile([[" .. dir .. "/StudioSync - Autostart.lua]])\n" .. MARK_Z .. "\n"
  end
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/Scripts", 0)
  return pcall(band.write_atomic, startup_path(), text) -- (write_atomic returns nothing: it raises when it can't)
end

-- The hidden REAPER that renders wet takes (lib/bgrender.lua) would run everything in Scripts/__startup.lua too (on
-- James's PC: Chordbox, Adaptive grid, Gridbox, the Reaper Daemon bridge, StudioSync's Autostart). A guard at the top
-- of that file stops it there: the render REAPER is started with BANDSYNC_RENDER set. Added once; the rest of the
-- file is the person's and stays as it is.
local GUARD_A, GUARD_Z = "-- BandSync render guard", "-- /BandSync render guard"
function tools.render_guard()
  local text = band.read(startup_path()) or ""
  if text:find(GUARD_A, 1, true) then return true end
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/Scripts", 0)
  return pcall(band.write_atomic, startup_path(), GUARD_A .. " (the hidden REAPER that renders StudioSync's wet takes stops here)\n" ..
    "if os.getenv(\"BANDSYNC_RENDER\") then return end\n" .. GUARD_Z .. "\n" .. text)
end

-- A machine asking to join the band folder (the host's Syncthing has it waiting; one on the band's Tailscale is let in
-- by Live sync by itself). On every page of the panel, at the top.
-- What StudioSync just did, for a few seconds. Exactly one line is held for it: a toast that wrapped moved the page under the mouse and back (Mac, 0.51.9),
-- so a longer one lies over the page, on its own background, and what's under it stays put and clickable.
function tools.toast_show(ctx, ImGui, line, place)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, lh = (ImGui.GetContentRegionAvail(ctx)), ImGui.GetTextLineHeight(ctx)
  if place then x, y, w = place.x, place.y, place.w else ImGui.Dummy(ctx, 0, lh) end
  if not line then return end
  local theme, text = require("theme"), line:sub(7)
  local dl = ImGui.GetForegroundDrawList(ctx)
  local _, th = ImGui.CalcTextSize(ctx, text, nil, nil, false, w)
  if th > lh + 1 then ImGui.DrawList_AddRectFilled(dl, x - 6, y - 3, x + w + 6, y + th + 5, theme.BG, 4) end
  ImGui.DrawList_AddTextEx(dl, nil, ImGui.GetFontSize(ctx), x, y, theme.TOAST, text, w)
end

local let_at, let_device, asked_at, asking = {}, {}, -math.huge, {} -- (let_at, who was just let in: Syncthing's own list says they're asking for up to 20 s more, and the row stayed)
-- An invitation onto the clipboard: Home's and the Studios page's say the same now (they said "Let them in shows here" and "on Home", and it
-- shows at the top of the panel on any page. UX review, 0.58.52).
tools.INVITE_TIP = "Copies a message to send them: one line for a Mac and one for Windows that installs everything, already paired with this computer " ..
  "(and a join code if they already have StudioSync).\nWhen they've run it, their request appears at the top of this panel: press Let them in."
function tools.invite(my_id, info, ctx, ImGui)
  tools.show_invite(require("services").invite_text(my_id, info), info, ctx, ImGui)
  band.log("an invitation to " .. tostring(info.name) .. " is on your clipboard: paste it to your collaborator. When they've run it, their request appears at the top of this panel")
end
-- The invitation, shown as well as copied: a toast was all there was, and someone who copied something else meanwhile had to make another
-- (and didn't know what it said). Beginner review, 0.58.62.
local shown_invite
function tools.show_invite(text, info, ctx, ImGui)
  band.copy(text, ctx, ImGui)
  shown_invite = { text = text, name = tostring(info and info.name or "the studio"), open = true }
end
function tools.invite_popup(ctx, ImGui)
  local j = shown_invite
  if not j then return end
  if j.open then j.open = nil; ImGui.OpenPopup(ctx, "Invitation") end
  ImGui.SetNextWindowSize(ctx, 520, 0)
  if ImGui.BeginPopupModal(ctx, "Invitation", nil, ImGui.WindowFlags_NoResize) then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.Text(ctx, "It's on your clipboard: paste it into a message to each person you're inviting to " .. j.name .. ". It's the same for everyone.")
    ImGui.PopTextWrapPos(ctx)
    ImGui.InputTextMultiline(ctx, "##invitation", j.text, -1, ImGui.GetTextLineHeight(ctx) * 9, ImGui.InputTextFlags_ReadOnly)
    ImGui.TextDisabled(ctx, "When they've run it, their request shows at the top of this panel: press Let them in.")
    if ImGui.Button(ctx, "Copy again") then band.copy(j.text, ctx, ImGui); band.log("the invitation is on your clipboard again") end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Done") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then shown_invite = nil; ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
end

-- Inviting a guest (James, 0.58.82): how long they stay is picked here, a choice or a date typed in, and the invitation leaves a note in the studio
-- (removal.add_invite) so whoever lets them in gives them that long. With a Tailscale token their computer also joins the Tailscale network till then.
local guest_pick = { days = 7, date = "" }
function tools.guest_invite_button(ctx, ImGui, my_id, root, label)
  local services, removal = require("services"), require("removal")
  if ImGui.SmallButton(ctx, (label or "Invite a guest") .. "##guestinv" .. root) then guest_pick.root = root; ImGui.OpenPopup(ctx, "guestinvite" .. root) end
  ImGui.SetItemTooltip(ctx, services.GUEST_TIP .. (services.tailscale_token() ~= "" and services.GUEST_TS_TIP or ""))
  if not ImGui.BeginPopup(ctx, "guestinvite" .. root) then return end
  local now = os.time()
  ImGui.Text(ctx, "Their access ends:")
  for _, c in ipairs(removal.GUEST_FOR) do
    if ImGui.RadioButton(ctx, c[1] .. "##gfor", guest_pick.date == "" and guest_pick.days == c[2]) then guest_pick.days, guest_pick.date = c[2], "" end
    ImGui.SameLine(ctx)
  end
  ImGui.NewLine(ctx)
  ImGui.SetNextItemWidth(ctx, 120)
  local _, v = ImGui.InputTextWithHint(ctx, "##gdate", "or a day: YYYY-MM-DD", guest_pick.date)
  guest_pick.date = v
  local ends = guest_pick.date ~= "" and removal.parse_day(guest_pick.date, now) or (guest_pick.date == "" and now + guest_pick.days * removal.DAY) or nil
  ImGui.SameLine(ctx)
  if ends then ImGui.TextDisabled(ctx, "until " .. removal.when(ends, now)) else ImGui.TextColored(ctx, require("theme").YELLOW, "not a day to come") end
  ImGui.BeginDisabled(ctx, not ends or not my_id)
  if ImGui.Button(ctx, "Copy the invitation##guest") then
    local me = reaper.GetExtState(band.SECTION, "user")
    local info = band.info(root)
    local made = removal.add_invite(root, ends, me, now)
    local ok = true
    if services.tailscale_token() ~= "" then ok = services.copy_guest_invite(my_id, info, ctx, ImGui, root, ends)
    else tools.show_invite(services.invite_text(my_id, info), info, ctx, ImGui) end
    if ok then band.log("a guest invitation to " .. tostring(info.name) .. " is on your clipboard: when they've run it, Let them in gives them until " .. removal.when(ends, now))
    else removal.end_invite(root, made, now) end
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Cancel##guest") then ImGui.CloseCurrentPopup(ctx) end
  ImGui.EndPopup(ctx)
end
-- Guests in a studio, with when each one's time is up, End now and Longer (owner and admins: a mark from anyone else doesn't count).
local guests_at, guests_of = {}, {} -- (read every 2 s, not every frame: the marks are files)
function tools.guests_list(ctx, ImGui, root, may)
  local removal = require("removal")
  local now = os.time()
  if not guests_at[root] or reaper.time_precise() - guests_at[root] > 2 then guests_at[root], guests_of[root] = reaper.time_precise(), removal.guests(root, now) end
  for _, g in ipairs(guests_of[root]) do
    ImGui.TextDisabled(ctx, string.format("Guest: %s, until %s", g.user, removal.when(g.ends, now)))
    if may then
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "End now##gend" .. g.device) and reaper.MB(g.user .. "'s time as a guest ends now: every computer stops syncing with theirs within a minute, in every studio" ..
          " of yours they're a guest in, and Tailscale lets them go too. Their copy stays with them.\n\nEnd it?", "StudioSync", 4) == 6 then
        for _, x in ipairs(band.bands()) do removal.guest_ends(x.root, g.device, now) end
        guests_at[root] = nil
        band.log(g.user .. "'s time as a guest is over: nothing syncs with their computer from a minute from now")
      end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Longer##glong" .. g.device) then ImGui.OpenPopup(ctx, "glonger" .. g.device) end
      if ImGui.BeginPopup(ctx, "glonger" .. g.device) then
        for _, c in ipairs(removal.GUEST_FOR) do
          if ImGui.Selectable(ctx, "+ " .. c[1]) then
            local ends = math.max(g.ends, now) + c[2] * removal.DAY
            removal.guest_ends(root, g.device, ends)
            guests_at[root] = nil
            band.log(g.user .. " is a guest until " .. removal.when(ends, now) .. " now")
          end
        end
        ImGui.EndPopup(ctx)
      end
    end
  end
end

local function let_in(d, me, ends)
  local services = require("services")
  local ok, why
  if d.folder then
    ok, why = services.share_folder(d.folder, d.id)
    if ok then
      require("removal").let_in(d.root, d.id) -- (taken out before, and back)
      -- (the roles written out again from here, the computer they were invited by: their first look believes no other. lib/trust.lua, Security review, 0.58.78)
      pcall(require("groups").edit, d.root, function() end)
      if ends then -- (and out again when their time is up, on every computer: the invitation's, else a day)
        local inv = require("removal").invite_for(require("removal").invites(d.root), os.time())
        require("removal").guest(d.root, d.id, d.name, me, os.time(), type(ends) == "number" and ends or (inv and inv.ends), inv and inv.made)
      end
      do -- a kept version of what's open, from before they arrived
        local recall = require("recall")
        local base = { root = reaper.GetExtState(band.SECTION, "sync_root"), user = me }
        for i = 0, math.huge do
          local p = reaper.EnumProjects(i)
          if not p then break end
          local tb = band.binding(p)
          if tb and band.for_tab(base, tb).root == d.root and not require("rooms").is_copy(p, base, tb) then -- (a backup left open isn't the song)
            pcall(recall.save, p, { root = d.root, user = me }, tb.song, tb.room, "before " .. tostring(d.name) .. " joined", true)
          end
        end
      end
    end
  else
    ok, why = services.add_device(d.id, d.name)
    if ok then let_device[d.id] = ends or true end
  end
  if ok then let_at[d.id .. (d.folder or "")] = reaper.time_precise() end
  band.log(ok and (d.folder and ("let '" .. tostring(d.name) .. "' into " .. d.band .. ": the projects reach them now") or ("let '" .. tostring(d.name) .. "' connect: the studio they were invited to follows in a moment"))
    or ("couldn't add '" .. tostring(d.name) .. "': " .. tostring(why)))
end
local invites_at, invites_of = {}, {} -- (a studio's guest invitations, read every 2 s)
function tools.join_requests(ctx, ImGui)
  local me = reaper.GetExtState(band.SECTION, "user")
  if reaper.time_precise() - asked_at > 2 then asked_at, asking = reaper.time_precise(), require("services").join_asks(me) end
  if not asking[1] then return end
  local skip = band.json_decode(reaper.GetExtState(band.SECTION, "join skipped")) or {}
  for _, d in ipairs(asking) do
    if not skip[d.id] and reaper.time_precise() - (let_at[d.id .. (d.folder or "")] or -math.huge) > 40 and d.folder and let_device[d.id] then
      local ends = let_device[d.id] ~= true and let_device[d.id] or nil -- (as a guest, if that's how the first press let them connect)
      let_device[d.id] = nil -- (the one press covers the studio they were invited to; another one later asks again)
      let_in(d, me, ends)
    elseif not skip[d.id] and reaper.time_precise() - (let_at[d.id .. (d.folder or "")] or -math.huge) > 40 then
      -- (buttons first: the words pushed them off a narrow panel)
      ImGui.SetCursorPosX(ctx, math.max(ImGui.GetCursorPosX(ctx), 16)) -- (no project open, there is no margin here: Mac, 0.52.5)
      if ImGui.SmallButton(ctx, "Let " .. tostring(d.name) .. " in##" .. d.id .. (d.folder or "")) then let_in(d, me) end
      ImGui.SetItemTooltip(ctx, "Only if you know this computer: anyone who has your Syncthing ID can ask.")
      ImGui.SameLine(ctx)
      -- (until what the guest invitation said, else a day: James, 0.58.82)
      local removal = require("removal")
      if d.folder and (not invites_at[d.root] or reaper.time_precise() - invites_at[d.root] > 2) then invites_at[d.root], invites_of[d.root] = reaper.time_precise(), removal.invites(d.root) end
      local inv = d.folder and removal.invite_for(invites_of[d.root] or {}, os.time())
      local ends = inv and inv.ends or os.time() + removal.DAY
      if ImGui.SmallButton(ctx, "Guest until " .. removal.when(ends, os.time()) .. "##" .. d.id .. (d.folder or "")) then let_in(d, me, ends) end
      ImGui.SetItemTooltip(ctx, "A guest: let in now, and every computer stops syncing with theirs " .. removal.when(ends, os.time()) ..
        (inv and " (as the guest invitation said)" or "") .. ". Their copy stays with them. Guests in Who's here can end it early or give them longer.")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Not my collaborator##" .. d.id) then
        skip[d.id] = true
        reaper.SetExtState(band.SECTION, "join skipped", band.json_encode(skip), false)
        require("services").dismiss_pending(d.id) -- (only hidden, it came back at every restart)
      end
      ImGui.SetItemTooltip(ctx, "Dismiss this request. Nothing is shared with it. It only comes back if that computer asks again.")
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").YELLOW)
      local out, from
      for _, x in ipairs(d.folder and { { root = d.root, name = d.band } } or band.bands()) do
        out = out or require("removal").who_was(x.root, d.id)
        from = from or (out and x.name)
      end
      ImGui.TextWrapped(ctx, out and string.format("%s was taken out of %s, and their computer is still asking. Leave it unless you've invited them back.", out, from)
        or d.folder and string.format("%s's computer wants to join %s.", tostring(d.name), d.band)
        or string.format("%s's computer is asking to join a studio of yours. It says which once it's let in.", tostring(d.name)))
      ImGui.PopStyleColor(ctx)
      ImGui.SetItemTooltip(ctx, string.format("Syncthing device %s, from %s.", d.id:sub(1, 7), tostring(d.address)))
    end
  end
end

-- Your newest undone edit (sync.put_back), in a yellow bar under the top bar until you dismiss it: the six-second
-- message line was easy to miss, and the next log line replaced it (review, 2026-10-31).
-- A docker with nothing in it, to put in a new place: REAPER lists what's in each in its ini file ("name=size docker"), and says
-- bottom for one it has never placed. Beyond the first two, as those are the ones people use.
function tools.free_docker()
  local used, inside = {}, false
  for line in (band.read(reaper.get_ini_file()) or ""):gmatch("[^\r\n]+") do
    if line:sub(1, 1) == "[" then inside = line == "[REAPERdockpref]"
    elseif inside then
      local n = line:match("=[%-%d%.]+ (%d+)")
      if n then used[tonumber(n)] = true end
    end
  end
  -- (and one with no side saved: one left at the left from an earlier try took the panel there on Dock > Right: Mac, 0.42.30)
  for i = 2, 14 do if not used[i] and reaper.DockGetPosition(i) == 0 then return i end end
  return 1
end

-- The docker action moves whichever docker REAPER counts as having the focus, and on a Mac that can be the Mixer's though the
-- panel's has the focus by every check. So look afterwards: anything else that moved goes straight back. -> true when `docker` is
-- on `side` (0 bottom, 1 left, 2 top, 3 right, the order of the actions).
local DOCKER_SIDE = { [0] = 41598, [1] = 41599, [2] = 41600, [3] = 41601 }
function tools.move_docker(docker, side)
  local before = {}
  for i = 0, 15 do before[i] = reaper.DockGetPosition(i) end
  reaper.Main_OnCommand(DOCKER_SIDE[side], 0)
  for i = 0, 15 do
    if i ~= docker and reaper.DockGetPosition(i) ~= before[i] and DOCKER_SIDE[before[i]] then reaper.Main_OnCommand(DOCKER_SIDE[before[i]], 0) end
  end
  return reaper.DockGetPosition(docker) == side
end

-- Said on the computer of someone taken out of a group, until they're let back in (lib/removal.lua).
function tools.removed_bar(ctx, ImGui)
  local text = reaper.GetExtState(band.SECTION, "removed from")
  if text == "" then return end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").YELLOW)
  ImGui.TextWrapped(ctx, text)
  ImGui.PopStyleColor(ctx)
end

function tools.put_back_bar(ctx, ImGui, song, use_mine, may, claim)
  local pb = band.json_decode(reaper.GetExtState(band.SECTION, "put back"))
  if not (pb and pb.text) then return end
  if pb.song and song and pb.song ~= song then return end -- (another song's, in another tab: laptop, 0.42.4)
  if pb.at and os.time() - pb.at > 600 then return end -- (old news: it's still in Setup > Console. Mac, 0.42.4)
  if ImGui.SmallButton(ctx, "OK##putback") then reaper.DeleteExtState(band.SECTION, "put back", false) end -- (first: a panel docked short showed the text, and no way to dismiss it)
  ImGui.SetItemTooltip(ctx, "Hide this. Every edit that wasn't sent is also in Settings > Console.")
  if claim and type(pb.claim) == "string" then -- (the way out, right here: it was on another card. UX review, 0.58.47)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Claim " .. pb.claim .. "##putback") then
      claim(pb.claim)
      reaper.DeleteExtState(band.SECTION, "put back", false)
      band.log(pb.claim .. " is yours now: edit it again and it goes to everyone")
    end
    ImGui.SetItemTooltip(ctx, "Makes " .. pb.claim .. " yours: only you can change it, whoever's driving. Then make your edit again.")
  end
  local mine = type(pb.mine) == "table" and pb.mine[1] and pb.mine
  if mine and use_mine then -- (a clash yours lost: straight back from here, not by way of the Restore page: James)
    ImGui.SameLine(ctx)
    local yours = true
    for _, m in ipairs(mine) do yours = yours and may(m.name or "") end
    ImGui.BeginDisabled(ctx, not yours)
    if ImGui.SmallButton(ctx, #mine > 1 and string.format("Use mine (%d)##putback", #mine) or "Use mine##putback") then
      use_mine(mine)
      reaper.DeleteExtState(band.SECTION, "put back", false)
    end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, yours and "Puts yours back, for everyone, as a new change. Theirs stays on the Restore page."
      or "It's theirs to change: they've claimed it, or it's the driver's. Ask them, or use the suggestion they'll see if you change it again.")
  end
  local said = mine and tostring(pb.text) or (tostring(pb.text) .. ((pb.n or 1) > 1 and string.format("  (%d edits not sent)", pb.n) or ""))
  -- (beside the buttons when it fits, as in a short docker that's all the room there is. Wrapped beside them it ran under its own OK: Mac, 0.57.6)
  ImGui.SameLine(ctx)
  if ImGui.CalcTextSize(ctx, said) + 16 > ImGui.GetContentRegionAvail(ctx) then ImGui.NewLine(ctx) end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").YELLOW)
  ImGui.PushTextWrapPos(ctx, ImGui.GetWindowWidth(ctx) - 16)
  ImGui.Text(ctx, said)
  ImGui.PopTextWrapPos(ctx)
  ImGui.PopStyleColor(ctx)
end

-- Update REAPER (James, 2026-11-15): FeedTheCat's REAPER Update Utility (MIT, the FTC Tools ReaPack repository) finds the newest REAPER
-- and installs it. Run when it's here (ReaPack's copy, or the one fetched before); otherwise its one file is fetched, the version FTC's
-- ReaPack index names now (pinned to a commit there), into StudioSync's folder, and run. ReaPack's browser used to open on it instead,
-- which wasn't clear about what to press (James, Mac, 0.58.73). Nothing fetched: REAPER's download page. -> what happened, in words.
tools.UPDATER_INDEX = "https://raw.githubusercontent.com/iliaspoulakis/Reaper-Tools/master/index.xml"
tools.TESTED_REAPER = "7.86" -- (what the installers fetch, and every suite ran on: Health asks to update from anything older)
-- The newest version's file in FTC's index. Pure.
function tools.updater_url(xml)
  local block = tostring(xml or ""):match('<reapack name="REAPER Update Utility%.lua".-</reapack>')
  local last
  for v in (block or ""):gmatch("<version.-</version>") do last = v end
  local url = last and last:match("<source[^>]*>(https://[^<]+)</source>")
  return url and (url:gsub("&amp;", "&")) or nil
end
function tools.fetch_updater(dest) -- (dest: where its one file goes. -> true, or nil + why)
  local curl = reaper.GetOS():find("^Win") and "curl.exe" or "/usr/bin/curl" -- (a full path on a Mac: REAPER runs a bare name there as nothing)
  reaper.RecursiveCreateDirectory(dest:match("^(.*)/"), 0)
  local tmp = dest .. ".index.xml"
  reaper.ExecProcess(curl .. ' -s -L --max-time 20 -o "' .. tmp .. '" "' .. tools.UPDATER_INDEX .. '"', 25000)
  local url = tools.updater_url(band.read(tmp))
  os.remove(tmp)
  if not url then return nil, "its list wasn't reachable" end
  reaper.ExecProcess(curl .. ' -s -L --max-time 30 -o "' .. dest .. '.part" "' .. url .. '"', 35000)
  local got = band.read(dest .. ".part") or ""
  if #got < 1000 or not got:find("reaper", 1, true) then os.remove(dest .. ".part"); return nil, "the download didn't arrive" end
  os.remove(dest)
  if not os.rename(dest .. ".part", dest) then return nil, "it couldn't be put in place" end
  return true
end
function tools.update_reaper()
  local theirs = reaper.GetResourcePath() .. "/Scripts/FTC Tools/Various/REAPER Update Utility.lua"
  local ours = band.home():gsub("\\", "/") .. "/REAPER Update Utility/REAPER Update Utility.lua"
  local script = reaper.file_exists(theirs) and theirs or reaper.file_exists(ours) and ours or nil
  local why
  if not script then
    local ok
    ok, why = tools.fetch_updater(ours)
    if ok then script = ours end
  end
  local id = script and reaper.AddRemoveReaScript(true, 0, script, true) or 0
  if id ~= 0 then reaper.Main_OnCommand(id, 0); return "REAPER Update Utility opened: it finds the newest REAPER and installs it" end
  band.open_url("https://www.reaper.fm/download.php")
  return "couldn't open the REAPER Update Utility (" .. tostring(why or "not registered") .. "): REAPER's download page opened"
end

-- ---------------------------------------------------------------- a StudioSync button on REAPER's main toolbar (James, 0.58.81: "like Helgobox's
-- 'add button to toolbar'"). The menu extension (extension/reaper_menu.cpp, 1.0.2 on) adds it each time REAPER builds the default main toolbar,
-- when ExtState "toolbar button" is "1", with toolbar_studiosync.png from REAPER's Data/toolbar_icons (copied there from lib/toolbar_icons,
-- in REAPER's toolbar style: grey, lighter grey under the mouse, StudioSync's blue while the panel is open). REAPER builds the toolbar as it
-- starts, so a change shows after a restart; a main toolbar someone customized isn't built from the default, so it isn't added there.
tools.TOOLBAR_EXT = "1.0.4"
function tools.toolbar_button() return reaper.GetExtState(band.SECTION, "toolbar button") == "1" end
-- On unless you switched it off, as Helgobox's is (James, 0.58.82): "" is never chosen (StudioSync - Autostart and the panel switch it on then),
-- "0" off. The menu extension reads "1" only.
function tools.toolbar_default()
  if reaper.GetExtState(band.SECTION, "toolbar button") == "" then return tools.set_toolbar_button(true) end
end
local function copy_file(from, to)
  local f = io.open(from, "rb")
  if not f then return false end
  local data = f:read("a")
  f:close()
  local g = io.open(to, "wb")
  if not g then return false end
  g:write(data)
  g:close()
  return true
end
-- -> true, or nil and why.
function tools.set_toolbar_button(on)
  if on then
    local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") or ""
    local res = reaper.GetResourcePath() .. "/Data/toolbar_icons"
    for _, sub in ipairs({ "", "/150", "/200" }) do
      reaper.RecursiveCreateDirectory(res .. sub, 0)
      if not copy_file(lib .. "/toolbar_icons" .. sub .. "/toolbar_studiosync.png", res .. sub .. "/toolbar_studiosync.png") and sub == "" then
        return nil, "The button's image isn't in StudioSync's lib/toolbar_icons folder: update StudioSync, then try again."
      end
    end
  end
  reaper.SetExtState(band.SECTION, "toolbar button", on and "1" or "0", true)
  return true
end
-- Why it won't show, or nil: the menu extension is missing or older than 1.0.3, or REAPER is older than 7.11 (no way to add a button then).
-- (A customized toolbar is no bar since 1.0.3: the extension adds the button to whatever main toolbar there is. 0.58.83)
function tools.toolbar_button_blocked()
  local have = reaper.GetExtState(band.SECTION, "menu extension")
  if have == "" or band.compare_versions(have, tools.TOOLBAR_EXT) < 0 then
    return "Shows once StudioSync's menu extension " .. tools.TOOLBAR_EXT .. " is loaded: restart REAPER (after Extensions > ReaPack > Synchronize packages, if it isn't installed yet)."
  end
  if reaper.GetExtState(band.SECTION, "menu extension toolbar") == "0" then
    return "This REAPER is too old to add a toolbar button (7.11 or newer can): add 'StudioSync: open the panel' to the toolbar yourself " ..
      "(right-click the toolbar > Customize toolbar > Add), and it gets StudioSync's image."
  end
end

return tools
