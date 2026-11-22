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
-- (compared in one spelling: REAPER gives the panel its folder with backslashes on Windows and lib/fromfolder.lua writes forward slashes, so
-- the panel missed it and wrote the block again without its fallback. Round 1 review, 0.59.45)
-- (and with `dir`, only the block as written now (CURRENT is in it): an older one counted as on, so the safety net below was never put on any
-- computer that had a block. Round 2 review, 0.59.46)
local CURRENT = "StudioSync didn't start: "
function tools.autostart_on(dir)
  local text = band.read(startup_path()) or ""
  return text:find(MARK_A, 1, true) ~= nil and (not dir or (text:find(CURRENT, 1, true) ~= nil
    and band.norm(text):lower():find(band.norm(dir):lower() .. "/studiosync - autostart.lua", 1, true) ~= nil)) -- (dir: and it's this copy)
end
-- A block from before (a bare dofile, the two-path loop, or one without the last word below) written again as it's written now, keeping its
-- copies in order: Autostart, once per REAPER start. -> true when it rewrote it. Round 2 review, 0.59.46.
function tools.upgrade_startup()
  local text = band.read(startup_path()) or ""
  local a = text:find(MARK_A, 1, true)
  if not a or text:find(CURRENT, 1, true) then return false end
  local first = text:sub(a):match("%[%[([^%]]-)/StudioSync %- Autostart%.lua%]%]")
  if not first then return false end
  return tools.set_autostart(true, band.norm(first)) == true
end
-- The block itself: each copy tried in turn, each in a pcall (a bare dofile of a copy that failed as it loaded stopped there, and with it
-- whatever came after it in __startup.lua), what a failed one loaded taken back out, and the failure left for Autostart to log ("startup
-- failed"). `dirs`: the copies' folders, in order. Pure. (Round 1 review, 0.59.45: the copy it runs from, this computer's last-good copy, then
-- the one it ran from before. installer/studiosync_setup.lua writes the same.)
-- (and when none of them started, the last failure is said in REAPER's console: nothing said anything, where a bare dofile at least raised
-- REAPER's error. Round 2 review, 0.59.46)
function tools.startup_block(dirs)
  local list = {}
  for _, d in ipairs(dirs) do list[#list + 1] = "[[" .. d .. "/StudioSync - Autostart.lua]]" end
  return MARK_A .. "\n" ..
    "do local was, path, finders, started, last = {}, package.path, { table.unpack(package.searchers) }, false, nil\n" ..
    "  for k in pairs(package.loaded) do was[k] = true end\n" ..
    "  for _, f in ipairs({ " .. table.concat(list, ", ") .. " }) do\n" ..
    "    if reaper.file_exists(f) then\n" ..
    "      local ok, err = pcall(dofile, f)\n" ..
    "      if ok then started = true break end\n" ..
    "      last = f .. \": \" .. tostring(err):sub(1, 300)\n" ..
    "      reaper.SetExtState(\"BandSync\", \"startup failed\", last, false)\n" ..
    "      for k in pairs(package.loaded) do if not was[k] then package.loaded[k] = nil end end\n" ..
    "      for i = #package.searchers, 1, -1 do package.searchers[i] = nil end\n" ..
    "      for i, s in ipairs(finders) do package.searchers[i] = s end\n" ..
    "      package.path = path\n" ..
    "    end\n" ..
    "  end\n" ..
    "  if not started and last then reaper.ShowConsoleMsg(\"" .. CURRENT .. "\" .. last .. \"\\n\") end\n" ..
    "end\n" .. MARK_Z .. "\n"
end
-- __startup.lua with `block` where the old one was (`before` and `after` it; `after` nil: there was none, so at the end). Pure.
-- installer/studiosync_setup.lua has the same. (Round 3 review, 0.59.48)
function tools.place_block(before, after, block)
  if not after then return before .. (before ~= "" and not before:match("\n$") and "\n" or "") .. block end
  return before .. block .. after:gsub("^\r?\n", "", 1)
end
-- __startup.lua around StudioSync's block: what's before it, and after its end line (from the line break that ends it: cut one character
-- later too, a blank line after the block went at each rewrite of a file with LF line endings). -> before, after (nil: no block), or nil when
-- there's a start line with no end line: left alone (everything after it, the person's own lines too, went). Pure. The installer has the same.
-- (Round 4 review, 0.59.49)
function tools.split_startup(text)
  local a = text:find(MARK_A, 1, true)
  if not a then return text, nil end
  local z = text:find(MARK_Z, a, true)
  if not z then return nil end
  return text:sub(1, a - 1), text:sub(z + #MARK_Z)
end
local broken_said = false
-- `fallback`: a copy to start instead when `dir` isn't there any more (a studio's folder this computer ran from, left since: lib/fromfolder.lua).
-- None given: the block's own fallback stays (the panel's toggle wrote the block again without it). The last-good copy always goes second.
function tools.set_autostart(on, dir, fallback)
  local text = band.read(startup_path())
  if not text and reaper.file_exists(startup_path()) then return false, "couldn't read " .. startup_path() end -- (written with only ours, the rest was gone)
  text = text or ""
  local good = band.last_good_dir()
  local before, after = tools.split_startup(text) -- (the file around the block: the new block goes where the old one was)
  if not before then
    if not broken_said then broken_said = true; band.log("StudioSync's block in " .. startup_path() .. " has no end line (" .. MARK_Z .. "): the file is left alone. Remove the block by hand, then switch Start with REAPER on again") end
    return false, "StudioSync's block in " .. startup_path() .. " has no end line: left alone"
  end
  local a = text:find(MARK_A, 1, true)
  if a and not fallback then -- (a block's fallback is any copy after its first: a block with one copy has none)
    local i = 0
    for p in text:sub(a, (text:find(MARK_Z, a, true))):gmatch("%[%[([^%]]-)/StudioSync %- Autostart%.lua%]%]") do
      local n = band.norm(p):lower()
      i = i + 1
      if i > 1 and not fallback and n ~= band.norm(dir or ""):lower() and n ~= good:lower() then fallback = p end
    end
  end
  if on then
    local dirs = { dir }
    if band.norm(dir):lower() ~= good:lower() then dirs[#dirs + 1] = good end
    if fallback and band.norm(fallback):lower() ~= band.norm(dir):lower() and band.norm(fallback):lower() ~= good:lower() then dirs[#dirs + 1] = fallback end
    -- (in place, appended only when there was none: moved to the end, any startup line above it that raised (a script on a drive that isn't
    -- mounted) stopped Autostart, Syncthing's start and the update path with it. Round 3 review, 0.59.48)
    text = tools.place_block(before, after, tools.startup_block(dirs))
  else
    text = before .. (after or ""):gsub("^\r?\n", "", 1) -- (the block's own line break: split_startup leaves it on `after`)
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
  line = tools.toast_words(line) -- (an error from inside the sync, in words: UX review, 0.59.14)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, lh = (ImGui.GetContentRegionAvail(ctx)), ImGui.GetTextLineHeight(ctx)
  if place then x, y, w = place.x, place.y, place.w else ImGui.Dummy(ctx, 0, lh) end
  if not line then return end
  local theme, text = require("theme"), line:sub(7)
  local dl = ImGui.GetForegroundDrawList(ctx)
  -- (one line: wrapped, it painted over the first rows of the page, open lists too, for 6 s. Layout review, 0.59.14)
  if ImGui.CalcTextSize(ctx, text) > w then
    local lo, hi = 0, #text
    while lo < hi do local mid = (lo + hi + 1) // 2; if ImGui.CalcTextSize(ctx, text:sub(1, mid) .. "...") <= w then lo = mid else hi = mid - 1 end end
    text = text:sub(1, lo):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "") .. "..."
  end
  ImGui.DrawList_AddText(dl, x, y, theme.TOAST, text)
end

local let_at, let_device, asked_at, asking = {}, {}, -math.huge, {} -- (let_at, who was just let in: Syncthing's own list says they're asking for up to 20 s more, and the row stayed)
-- An invitation onto the clipboard: Home's and the Studios page's say the same now (they said "Let them in shows here" and "on Home", and it
-- shows at the top of the panel on any page. UX review, 0.58.52).
tools.INVITE_TIP = "Copies a message to send them: one line for a Mac and one for Windows that installs everything, already paired with this computer " ..
  "(and a join code if they already have StudioSync).\nWhen they've run it, their request appears at the top of this panel: press Let them in."
function tools.invite(my_id, info, ctx, ImGui)
  tools.show_invite(require("services").invite_text(my_id, info), info, ctx, ImGui, { id = my_id })
  band.log("an invitation to " .. tostring(info.name) .. " is on your clipboard: paste it to your collaborator. When they've run it, their request appears at the top of this panel")
end
-- The invitation, shown as well as copied: a toast was all there was, and someone who copied something else meanwhile had to make another
-- (and didn't know what it said). Beginner review, 0.58.62.
local shown_invite
-- `parts` ({ id, key }): an invitation to a studio, which can be put for someone new, someone with StudioSync, or either (James, 0.58.98:
-- "have the share let you choose if the person you're inviting has it or not"). Without it (SonoBus's), the text as it is.
-- (and, where the link can hear it, a signed invitation instead of the plain join code: pasted, it lets them in by itself, with no Let them in.
-- `parts.guest` or a Tailscale guest key: for a guest. lib/joins.lua, James, rt)
function tools.show_invite(text, info, ctx, ImGui, parts)
  if parts and parts.token == nil then
    local ok, token = pcall(require("joins").make_for, info, (parts.guest or parts.key) and "guest" or "member")
    parts.token = ok and token or false
    if parts.token then text = require("services").invite_text(parts.id, info, parts.key, nil, parts.token) end
  end
  band.copy(text, ctx, ImGui)
  shown_invite = { text = text, info = info, parts = parts, who = "both", name = tostring(info and info.name or "the studio"), open = true }
end
-- (in this order: James, 0.58.98. "new" named for what it does, setting up REAPER too: James, 0.59.24)
local WHO = { { "new", "New: sets up REAPER and everything" }, { "has", "Has StudioSync" }, { "both", "Not sure" } }
function tools.invite_popup(ctx, ImGui)
  local j = shown_invite
  if not j then return end
  if j.open then j.open = nil; ImGui.OpenPopup(ctx, "Invitation") end
  -- (resizable, and the text wraps: it was a fixed 520 px box. James, 0.58.98)
  ImGui.SetNextWindowSize(ctx, 560, 420, ImGui.Cond_Appearing)
  ImGui.SetNextWindowSizeConstraints(ctx, 380, 260, 1600, 1200)
  if ImGui.BeginPopupModal(ctx, "Invitation", nil) then
    if j.parts then
      ImGui.Text(ctx, "Who is it for?")
      for _, w in ipairs(WHO) do
        -- (beside the last while it fits, else on the next line: the third was cut off at the window's first width)
        local need = ImGui.CalcTextSize(ctx, w[2]) + ImGui.GetFrameHeight(ctx) + 14
        if select(1, ImGui.GetItemRectMax(ctx)) + need < select(1, ImGui.GetWindowPos(ctx)) + ImGui.GetWindowWidth(ctx) - 16 then ImGui.SameLine(ctx) end
        if ImGui.RadioButton(ctx, w[2] .. "##who" .. w[1], j.who == w[1]) and j.who ~= w[1] then
          j.who = w[1]
          j.text = require("services").invite_text(j.parts.id, j.info, j.parts.key, w[1] ~= "both" and w[1] or nil, j.parts.token or nil)
          band.copy(j.text, ctx, ImGui)
        end
      end
    end
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.Text(ctx, "It's on your clipboard: paste it into a message to each person you're inviting to " .. j.name .. "." ..
      (j.who == "new" and " For someone new, with or without REAPER: it installs REAPER (if it isn't there), StudioSync and everything it uses." or j.who == "has" and " For someone who has StudioSync: a join code to paste in its panel." or " It works whether they have StudioSync or not."))
    ImGui.PopTextWrapPos(ctx)
    local foot = ImGui.GetFrameHeightWithSpacing(ctx) + ImGui.GetTextLineHeightWithSpacing(ctx) * 2.5
    ImGui.InputTextMultiline(ctx, "##invitation", j.text, -1, math.max(ImGui.GetTextLineHeight(ctx) * 4, select(2, ImGui.GetContentRegionAvail(ctx)) - foot),
      ImGui.InputTextFlags_ReadOnly)
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextDisabled(ctx, j.parts and j.parts.token and "Its invitation line, pasted in their StudioSync within 2 days, lets them in by itself (once). From the install lines, their request shows at the top of this panel: press Let them in."
      or "When they've run it, their request shows at the top of this panel: press Let them in.")
    ImGui.PopTextWrapPos(ctx)
    if ImGui.Button(ctx, "Copy again") then band.copy(j.text, ctx, ImGui); band.log("the invitation is on your clipboard again") end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Done") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then shown_invite = nil; ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
end

-- Inviting a guest (James, 0.58.82): how long they stay is picked here, a choice or a date typed in, and the invitation leaves a note in the studio
-- (removal.add_invite) so whoever lets them in gives them that long. With a Tailscale token their computer also joins the Tailscale network till then.
local guest_pick = { days = 7, date = "", all = true, songs = {} }
-- Opens the same window for a guest without Tailscale (lib/livex.lua guest_button, rt-sonox): no Tailscale key in their invitation, whatever
-- token this computer has; they're reached through the connection without Tailscale. Call it where the Invite a guest button is drawn.
function tools.open_guest_invite(ctx, ImGui, root, no_ts)
  if guest_pick.root ~= root then guest_pick.songs = {} end
  guest_pick.root, guest_pick.name, guest_pick.no_ts = root, tostring(band.info(root).name), no_ts or nil
  ImGui.OpenPopup(ctx, "Invite a guest###guestinvite" .. root)
end
function tools.guest_invite_button(ctx, ImGui, my_id, root, label)
  local services, removal = require("services"), require("removal")
  if ImGui.SmallButton(ctx, (label or "Invite a guest") .. "##guestinv" .. root) then
    if guest_pick.root ~= root then guest_pick.songs = {} end -- (ticks from another studio's list went into this one's invitation. Review, 0.58.96)
    guest_pick.root, guest_pick.name, guest_pick.no_ts = root, tostring(band.info(root).name), nil; ImGui.OpenPopup(ctx, "Invite a guest###guestinvite" .. root)
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, services.GUEST_TIP .. (services.has_token_for(services.studio_net(root)) and services.GUEST_TS_TIP or "")) end
  -- (a window of its own you can resize, the words wrapped: a fixed popup cut its text off. James, 0.58.98)
  ImGui.SetNextWindowSize(ctx, 440, 0, ImGui.Cond_Appearing)
  ImGui.SetNextWindowSizeConstraints(ctx, 320, 180, 1400, 1200)
  if not ImGui.BeginPopupModal(ctx, "Invite a guest###guestinvite" .. root, true) then return end
  local now = os.time()
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.Text(ctx, "Invite a guest to " .. tostring(guest_pick.name or "the studio") .. ": they're let in until the day you pick, then every computer stops syncing with theirs (their copy stays with them).")
  if guest_pick.no_ts then ImGui.TextDisabled(ctx, "Without Tailscale: nothing joins their computer to your Tailscale network; they hear and are heard through StudioSync's connection without Tailscale.") end
  ImGui.PopTextWrapPos(ctx)
  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Their access ends:")
  for i, c in ipairs(removal.GUEST_FOR) do
    if i > 1 then
      -- (beside the last one while it fits the window's width, else on the next line)
      local w = ImGui.CalcTextSize(ctx, c[1]) + ImGui.GetFrameHeight(ctx) + 12
      local right = select(1, ImGui.GetWindowPos(ctx)) + ImGui.GetWindowWidth(ctx) - 16
      if select(1, ImGui.GetItemRectMax(ctx)) + w < right then ImGui.SameLine(ctx) end
    end
    if ImGui.RadioButton(ctx, c[1] .. "##gfor", guest_pick.date == "" and guest_pick.days == c[2]) then guest_pick.days, guest_pick.date = c[2], "" end
  end
  ImGui.SetNextItemWidth(ctx, 120)
  local _, v = ImGui.InputTextWithHint(ctx, "##gdate", "or a day: YYYY-MM-DD", guest_pick.date)
  guest_pick.date = v
  local ends = guest_pick.date ~= "" and removal.parse_day(guest_pick.date, now) or (guest_pick.date == "" and now + guest_pick.days * removal.DAY) or nil
  ImGui.SameLine(ctx)
  if ends then ImGui.TextDisabled(ctx, "until " .. removal.when(ends, now)) else ImGui.TextColored(ctx, require("theme").YELLOW, "Type a future date as YYYY-MM-DD") end
  -- (which projects they see: all, or only those ticked. lib/access.lua, 0.58.89)
  ImGui.Text(ctx, "They see:")
  if ImGui.RadioButton(ctx, "Every project##gall", guest_pick.all) then guest_pick.all = true end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Only these##gsome", not guest_pick.all) then guest_pick.all = false end
  ImGui.SetItemTooltip(ctx, "The others stay in the studio, out of their sight: StudioSync doesn't list them on their computer and doesn't download them there.\n" ..
    "Hidden rather than locked: someone who knows Syncthing could undo that on their own computer.")
  local some = 0
  if not guest_pick.all then
    local list = band.songs({ root = root, user = "" })
    -- (a long list scrolls in its own box, the buttons stay in sight)
    if ImGui.BeginChild(ctx, "##gsongs", 0, math.min(#list, 8) * ImGui.GetFrameHeightWithSpacing(ctx) + 8, ImGui.ChildFlags_Borders) then
      for _, s in ipairs(list) do
        local ch, v = ImGui.Checkbox(ctx, s .. "##gsong", guest_pick.songs[s] == true)
        if ch then guest_pick.songs[s] = v or nil end
        if guest_pick.songs[s] then some = some + 1 end
      end
      ImGui.EndChild(ctx)
    end
  end
  ImGui.BeginDisabled(ctx, not ends or not my_id or (not guest_pick.all and some == 0))
  if ImGui.Button(ctx, "Copy the invitation##guest") then
    local me = reaper.GetExtState(band.SECTION, "user")
    local info = band.info(root)
    local songs
    if not guest_pick.all then songs = {}; for s in pairs(guest_pick.songs) do songs[#songs + 1] = s end; table.sort(songs) end
    local made = removal.add_invite(root, ends, me, now, songs)
    local ok = true
    if not guest_pick.no_ts and services.has_token_for(services.studio_net(root)) then ok = services.copy_guest_invite(my_id, info, ctx, ImGui, root, ends)
    else tools.show_invite(services.invite_text(my_id, info), info, ctx, ImGui, { id = my_id, guest = true }) end
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
-- When `user`'s time as a guest of this studio is up, in words, or nil: they aren't one. (Who's here's clock icon, 0.59.32)
function tools.guest_until(root, user)
  local removal = require("removal")
  if not guests_at[root] or reaper.time_precise() - guests_at[root] > 2 then guests_at[root], guests_of[root] = reaper.time_precise(), removal.guests(root, os.time()) end
  for _, g in ipairs(guests_of[root]) do if g.user == user then return removal.when(g.ends, os.time()) end end
end
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
        -- (only where you're in charge: elsewhere your mark is set aside, and the trusted one was gone. Review, 0.58.96)
        for _, x in ipairs(band.bands()) do if require("groups").may_manage(x.root, reaper.GetExtState(band.SECTION, "user")) then removal.guest_ends(x.root, g.device, now) end end
        guests_at[root] = nil
        band.log(g.user .. "'s time as a guest is over: nothing syncs with their computer from a minute from now")
      end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Projects##gproj" .. g.device) then ImGui.OpenPopup(ctx, "gprojects" .. g.device) end
      ImGui.SetItemTooltip(ctx, "Which projects " .. g.user .. " sees (the others stay hidden on their computer): every one, or only those ticked.")
      if ImGui.BeginPopup(ctx, "gprojects" .. g.device) then
        local acc = require("access")
        local set = acc.read(root, g.device) -- (as written: the checked reading showed nothing ticked while a check waited. 0.58.93)
        if ImGui.RadioButton(ctx, "Every project##gpa" .. g.device, set == nil) and set then acc.clear(root, g.device); band.log(g.user .. " sees every project now") end
        ImGui.SameLine(ctx)
        if ImGui.RadioButton(ctx, "Only these##gps" .. g.device, set ~= nil) and not set then acc.set(root, g.device, {}, reaper.GetExtState(band.SECTION, "user")) end
        if set then
          for _, s in ipairs(band.songs({ root = root, user = "" })) do
            local ch, v = ImGui.Checkbox(ctx, s .. "##gpsong" .. g.device, set[s] == true)
            if ch then
              set[s] = v or nil
              local list = {}
              for x in pairs(set) do list[#list + 1] = x end
              acc.set(root, g.device, list, reaper.GetExtState(band.SECTION, "user"))
              band.log(v and (g.user .. " can see " .. s .. " now") or (s .. " is hidden from " .. g.user .. " now"))
            end
          end
        end
        ImGui.EndPopup(ctx)
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
    -- (a guest's project list is written before the folder is shared, so it's there in what reaches them first: written after, they saw every
    -- project until it arrived. Review, 0.58.95)
    local inv = ends and require("removal").invite_for(require("removal").invites(d.root), os.time())
    if ends and inv and type(inv.songs) == "table" then require("access").set(d.root, d.id, inv.songs, me) end
    ok, why = services.share_folder(d.folder, d.id)
    if ok then
      require("removal").let_in(d.root, d.id) -- (taken out before, and back)
      -- (the roles written out again from here, the computer they were invited by: their first look believes no other. lib/trust.lua, Security review, 0.58.78)
      pcall(require("groups").edit, d.root, function() end)
      if ends then -- (and out again when their time is up, on every computer: the invitation's, else a day)
        require("removal").guest(d.root, d.id, d.name, me, os.time(), (inv and inv.ends) or (type(ends) == "number" and ends) or nil, inv and inv.made)
        -- (the projects the invitation gave them, if it named some: they see only those, written above. lib/access.lua)
        if not (inv and type(inv.songs) == "table") then require("access").clear(d.root, d.id) end -- (invited for every project: a list from a visit before no longer applies. 0.58.93)
      else
        require("access").clear(d.root, d.id) -- (let in as a member: a project list left from a guest visit no longer applies)
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
    if ok then let_device[d.id] = ends and "guest" or true end -- (the invitation's time is found once their studio is known)
  end
  -- (and its computer's own ask, which Syncthing's list may show a little longer: an invitation lets it in with no press. lib/joins.lua)
  if ok then let_at[d.id .. (d.folder or "")], let_at[d.id] = reaper.time_precise(), reaper.time_precise() end
  band.log(ok and (d.folder and ("let '" .. tostring(d.name) .. "' into " .. d.band .. ": the projects reach them now") or ("let '" .. tostring(d.name) .. "' connect: the studio they were invited to follows in a moment"))
    or ("couldn't add '" .. tostring(d.name) .. "': " .. tostring(why)))
  return ok, why
end
tools.let_in = let_in -- (lib/joins.lua: someone with a signed invitation is let in the same way, with no press)
local invites_at, invites_of = {}, {} -- (a studio's guest invitations, read every 2 s)
function tools.join_requests(ctx, ImGui)
  band.try("joins.tick", require("joins").tick) -- (invitations: an ask over the link let in, a joiner's ask sent again. At most once a second)
  local me = reaper.GetExtState(band.SECTION, "user")
  if reaper.time_precise() - asked_at > 2 then asked_at, asking = reaper.time_precise(), require("services").join_asks(me) end
  if not asking[1] then return end
  local skip = band.ext_json(band.SECTION, "join skipped") or {}
  for _, d in ipairs(asking) do
    if not skip[d.id] and reaper.time_precise() - (let_at[d.id .. (d.folder or "")] or -math.huge) > 40 and d.folder and let_device[d.id] then
      -- (as a guest, if that's how the first press let them connect: "guest", the invitation's time found now that their studio is known.
      -- A day was stored at the first press, before the studio was known, so "1 month" ended after a day. Review, 0.58.96)
      local ends = let_device[d.id] ~= true and let_device[d.id] or nil
      let_device[d.id] = nil -- (the one press covers the studio they were invited to; another one later asks again)
      let_in(d, me, ends)
    elseif not skip[d.id] and reaper.time_precise() - (let_at[d.id .. (d.folder or "")] or -math.huge) > 40 then
      -- (buttons first: the words pushed them off a narrow panel)
      ImGui.SetCursorPosX(ctx, math.max(ImGui.GetCursorPosX(ctx), 16)) -- (no project open, there is no margin here: Mac, 0.52.5)
      if ImGui.SmallButton(ctx, "Let " .. tostring(d.name) .. " in##" .. d.id .. (d.folder or "")) then let_in(d, me) end
      ImGui.SetItemTooltip(ctx, "Only if you know who this is: anyone with your invitation can ask.")
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
      if ImGui.SmallButton(ctx, "Not my collaborator##" .. d.id .. (d.folder or "")) then -- (one computer asking for two studios: two the same. Review, 0.59.14)
        skip[d.id] = true
        band.set_ext_json(band.SECTION, "join skipped", skip, false)
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
      ImGui.TextWrapped(ctx, out and string.format("%s was taken out of %s, and their computer is still asking. Ignore this unless you've invited them back.", out, from)
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

-- A print that didn't come out (lib/prints.lua prints.problem), until dismissed or half an hour old.
function tools.print_problem_bar(ctx, ImGui)
  local pp = band.ext_json(band.SECTION, "print problem")
  if not (pp and pp.text) or (pp.at and os.time() - pp.at > 1800) then return end
  if ImGui.SmallButton(ctx, "OK##printproblem") then reaper.DeleteExtState(band.SECTION, "print problem", false) end
  ImGui.SetItemTooltip(ctx, "Hide this. Every print problem is also in Settings > Console.")
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Try again##printproblem") then -- (Live sync clears what it gave up on, at its next pass: lib/prints.lua)
    reaper.SetExtState(band.SECTION, "prints retry", tostring(os.time()), false)
    reaper.DeleteExtState(band.SECTION, "print problem", false)
  end
  ImGui.SetItemTooltip(ctx, "Tries every print that failed again, now.")
  local said = tostring(pp.text) .. ((pp.n or 1) > 1 and string.format("  (%d print problems lately)", pp.n) or "")
  ImGui.SameLine(ctx)
  if ImGui.CalcTextSize(ctx, said) + 16 > ImGui.GetContentRegionAvail(ctx) then ImGui.NewLine(ctx) end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").YELLOW)
  ImGui.PushTextWrapPos(ctx, ImGui.GetWindowWidth(ctx) - 16)
  ImGui.Text(ctx, said)
  ImGui.PopTextWrapPos(ctx)
  ImGui.PopStyleColor(ctx)
end
-- What the toast shows for a line from the log: an error from inside the sync, in words, the details left in Settings > Console. Pure.
function tools.toast_words(l)
  if not l then return l end
  for _, p in ipairs({ "^mirror sync: ", "^sync error: ", "^inbox: ", "^suggestions: ", "^tempo/markers: ", "^live sync error" }) do
    if l:find(p) then return "Something went wrong while syncing: Settings > Console has the details (Copy, and send it to whoever set you up)." end
  end
  return l
end
function tools.put_back_bar(ctx, ImGui, song, use_mine, may, claim)
  local pb = band.ext_json(band.SECTION, "put back")
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
tools.EXT_WANT = "1.0.38" -- (1.0.38: live audio reads each stream from its own buffer, Jam WAV header; 1.0.37: live audio clock steps and per-stream rate correction; 1.0.36: hub watch stalls and Wi-Fi listeners, Jam over Opus (StudioSync_JamDecode), selective acks, StudioSync_NatIce, StudioSync_DirectLan; 1.0.35: hopnet, upload spool, live audio fixes; 1.0.34: Play skip noted; 1.0.33: verify files on a thread; 1.0.32: hub watch stalls, .opus type; 1.0.31: no-Tailscale link freezes fixed; 1.0.30: audio reaches the extension in REAPER; 1.0.29: listening links, jam copy, join welcome; 1.0.28: hub fix, room lists, Jam; 1.0.27: clock hold, Hop 0.2.0; 1.0.26: NAT relay fixes; 1.0.25: share sound, NAT relay, video thumbnails; 1.0.24: the direct link without Tailscale; 1.0.23: latency-first live audio buffers; 1.0.22: steadier live audio clock and buffers; 1.0.21: live audio drift correction and underrun fixes; 1.0.20: direct link lanes (direct.behind), sockets not inherited, hub load as thread CPU; 1.0.19: StudioSync_LiveAudioHub, StudioSync_WebUIOffer, NAT transport; 1.0.18: live hops over a real internet link; 1.0.17: Linux docked web UI draws, phone link cookie; 1.0.16: StudioSync_LiveAudioPlay/PeerPlay, StudioSync_WebUISaveUpload, Linux docked web UI; 1.0.15: adaptive jitter buffer, StudioSync_LiveAudioPeerBuffer, hop stall recovery; 1.0.14: live audio send control, docked view media permission; 1.0.13: Hop loopback, docked web UI, live audio; the menu extension this StudioSync goes with: tools/make_index.py EXT_VERSION. Health says when it's older. 1.0.8: the direct link's, lib/direct.lua WANT. James, 0.60.0-rt; 1.0.10: streamed takes cross a slow way; 1.0.11: stream trace, rt; 1.0.12: frames in flight, send anything, link speed, rt)
function tools.toolbar_button() return reaper.GetExtState(band.SECTION, "toolbar button") == "1" end
-- On unless you switched it off, as Helgobox's is (James, 0.58.82): "" is never chosen (StudioSync - Autostart and the panel switch it on then),
-- "0" off. The menu extension reads "1" only.
-- (ICON: the image's version. 2: grey until the panel is open, coloured while it is (James, 0.58.99); copied again once when it changes)
tools.TOOLBAR_ICON = "4" -- (4: the amber-dot images, menu extension 1.0.6. 0.59.10)
function tools.toolbar_default()
  local on = reaper.GetExtState(band.SECTION, "toolbar button")
  if on == "" or (on == "1" and reaper.GetExtState(band.SECTION, "toolbar icon") ~= tools.TOOLBAR_ICON) then
    reaper.SetExtState(band.SECTION, "toolbar icon", tools.TOOLBAR_ICON, true)
    return tools.set_toolbar_button(true)
  end
end
local function copy_file(from, to) return (pcall(band.copy_atomic, from, to)) end
-- -> true, or nil and why.
function tools.set_toolbar_button(on)
  if on then
    local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") or ""
    local res = reaper.GetResourcePath() .. "/Data/toolbar_icons"
    for _, sub in ipairs({ "", "/150", "/200" }) do
      reaper.RecursiveCreateDirectory(res .. sub, 0)
      copy_file(lib .. "/toolbar_icons" .. sub .. "/toolbar_studiosync_on.png", res .. sub .. "/toolbar_studiosync_on.png") -- (REAPER's image while it's on: coloured. 0.59.3)
      for _, w in ipairs({ "toolbar_studiosync_warn.png", "toolbar_studiosync_warn_on.png" }) do copy_file(lib .. "/toolbar_icons" .. sub .. "/" .. w, res .. sub .. "/" .. w) end -- (something stopped syncing: 0.59.10)
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
    return "This REAPER is too old to add a toolbar button (7.11 or newer can): add 'StudioSync' to the toolbar yourself " ..
      "(right-click the toolbar > Customize toolbar > Add), and it gets StudioSync's image."
  end
end

return tools
