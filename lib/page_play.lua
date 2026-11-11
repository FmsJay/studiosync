-- The Play/Jam page (moved out of StudioSync - Panel.lua, 0.58.51: the panel was at Lua's 200 locals): starting together, Play along and
-- Jam over NINJAM, and the server. The panel hands over what it shares (M.init); what changes as you work is asked for at every call.
local band = require("band")
local sync, live, services, setup, together = require("sync"), require("live"), require("services"), require("setup"), require("together")
local theme = require("theme")
local GREEN, YELLOW, RED, ACCENT = theme.GREEN, theme.YELLOW, theme.RED, theme.ACCENT
local M = {}
local E, ctx, ImGui, ui, dir, heading, next_to, card, card_end, action
local same_room_on, set_same_room, sonobus_open, bar_of, check
function M.init(env)
  E, ctx, ImGui, ui, dir, heading, next_to = env, env.ctx, env.ImGui, env.ui, env.dir, env.heading, env.next_to
  card, card_end, action = env.card, env.card_end, env.action
  same_room_on, set_same_room, sonobus_open, bar_of, check = env.same_room_on, env.set_same_room, env.sonobus_open, env.bar_of, env.check
end

local live_mode, live_send, live_server = "synced", true, nil
local srv_at, srv_up, srv_by, srv_addr = 0, false, nil, nil
local LIVE_MODES = { { "synced", "Play along (synced to the project)" }, { "listen", "Real time (SonoBus, lowest delay)" }, { "jam", "Jam (NINJAM intervals)" } }
local countin, lag_bars, bars = 1, 0, 1
local server_at = 0
-- Reach the server: curl connects, and with nothing to say it runs out of time (28) or ends clean (0); it can't connect otherwise. (Blocks up to 3 s: only on a click.)
local function test_server(addr)
  local b, cfg, proj, view, wide, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.who()
  if services.answers(addr) then return { true, "Reached it." } end
  return { false, "Can't reach it: is the server running, and can this computer reach that address?" }
end
function M.section_live(part) -- part: "mode" or "rest" (docked, side by side), nil for all of it
  local b, cfg, proj, view, wide, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.who()
  local lfile = band.song_dir(cfg, b.song) .. "/live.json"
  -- the host may fill the address in after this panel opened (it arrives through the shared folder): re-read it
  -- every few seconds while it's still empty here
  if not live_server or (live_server == "" and reaper.time_precise() - server_at > 3) then
    if not live_server then -- first look: the mode this project was last in (it used to reset to Play along)
      local saved = select(2, reaper.GetProjExtState(proj, band.SECTION, "live_mode"))
      if saved ~= "" then live_mode = saved end
    end
    server_at, live_server = reaper.time_precise(), (band.read_json(lfile) or {}).server or ""
  end
  if part ~= "rest" then
    ImGui.SeparatorText(ctx, "Mode")
    for _, m in ipairs(LIVE_MODES) do
      if ImGui.RadioButton(ctx, m[2], live_mode == m[1]) then live_mode = m[1]; reaper.SetProjExtState(proj, band.SECTION, "live_mode", m[1]) end
    end
    ImGui.TextWrapped(ctx, ({
      synced = "Play to the project; the others hear you in time with it, a bar or two behind you. What you play also shows up on their timeline as an idea until your real take arrives.",
      listen = "Hear each other right away, with no server to run. Best on wired internet, with collaborators not too far away; otherwise use Play along.",
      jam = "Everyone plays at once and hears the others one cycle late (classic NINJAM).",
    })[live_mode])
    if live_mode == "synced" then -- (the number Play along needs: listeners a whole interval behind)
      local ok_cfg, bpi = pcall(function() return tonumber((band.read(services.ninjam_dir() .. "/bandsync.cfg") or ""):match("DefaultBPI%s+(%d+)")) end)
      bpi = ok_cfg and bpi or 4
      local _, _, _, num = reaper.TimeMap_GetTimeSigAtTime(proj, reaper.GetCursorPositionEx(proj))
      local one = math.max(1, math.ceil(bpi / math.max(1, num or 4)))
      ImGui.TextDisabled(ctx, string.format("One NINJAM interval is %d beats, so %d bar%s here.", bpi, one, one == 1 and "" or "s"))
      if ImGui.SmallButton(ctx, "Put listeners one interval behind") then
        ui.want_lag = one -- (their boxes are further down)
        if not same_room_on() then reaper.SetProjExtState(proj, band.SECTION, "side", tostring(one)) end
      end
      ImGui.SetItemTooltip(ctx, "So what they hear of you lines up with their copy of the project. Sets Follow each other and Start together's 'bars later' below.")
    end
    ImGui.Spacing(ctx)
  end
  if part == "mode" then return end
  if same_room_on() then -- (my time / their time, a guest: moved here from Home)
    ImGui.SeparatorText(ctx, "Real time: how you hear the others")
    require("page_hear").realtime(ctx, ImGui, proj)
    ImGui.Spacing(ctx)
  end
  if live_mode == "listen" then
    local sm, si = live.fx(proj, false, live.SONOBUS)
    local on = sm and not reaper.TrackFX_GetOffline(sm, si)
    if ImGui.Button(ctx, on and "Open SonoBus##sb" or "Connect##sb") then sonobus_open() end
    ImGui.SetItemTooltip(ctx, "Turns on SonoBus, already set to join your studio: it sends what you play and brings the others in.")
    if on then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Leave##sb") then reaper.TrackFX_SetOffline(sm, si, true) end
      ImGui.TextColored(ctx, GREEN, "SonoBus is on and connected to your studio, until you Leave.")
    elseif sm then
      ImGui.TextDisabled(ctx, "SonoBus is ready on your master track (off: it sends nothing until you Connect).")
    end
    if E.sb_link() then
      if ImGui.SmallButton(ctx, "Copy join link") then band.copy(E.sb_link(), ctx, ImGui) end
      ImGui.SetItemTooltip(ctx, "For joining from SonoBus's own app (outside REAPER): its paste button fills the studio in.")
    end
    return
  end
  ImGui.SeparatorText(ctx, "Server")
  ImGui.TextDisabled(ctx, "Play along and Jam go through a NINJAM server on one computer, which the others have to be able to reach. The server only lets in addresses from Tailscale, which StudioSync's installer sets up: everyone signs in to the one account.")
  ImGui.SetNextItemWidth(ctx, 220)
  local changed, v = ImGui.InputTextWithHint(ctx, "##server", "its address:2049", live_server, ImGui.InputTextFlags_None)
  if changed then live_server = v end
  next_to("Save for the studio")
  if ImGui.SmallButton(ctx, "Save for the studio") then
    local data = band.read_json(lfile) or {} -- keep whatever else is in it
    data.server, data.by = live_server, nil -- (typed in: a server somewhere, not this computer's to run)
    band.write_json(lfile, data)
  end
  ImGui.SetItemTooltip(ctx, "Only for a server of your own: StudioSync runs one by itself otherwise, on whichever computer needs it first.")
  next_to("Test it")
  ImGui.BeginDisabled(ctx, live_server == "")
  if ImGui.SmallButton(ctx, "Test it") then ui.server_said = test_server(live_server) end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, "Tries to reach the server from this computer.")
  if ui.server_said then ImGui.TextColored(ctx, ui.server_said[1] and GREEN or YELLOW, ui.server_said[2]) end
  do
    if reaper.time_precise() - srv_at > 3 then -- tasklist is slow: not every frame
      local now = band.read_json(lfile) or {}
      srv_at, srv_up, srv_by, srv_addr = reaper.time_precise(), services.running("ninjamsrv"), now.by, now.server
    end
    ImGui.TextDisabled(ctx, srv_up and "Server: running on this computer" or (live_server ~= "" and srv_by and srv_by ~= cfg.user) and ("Server: on " .. srv_by .. "'s computer") or "Server: Connect starts one on this computer")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Host it here") then
      local server, why = services.ninjam_for(cfg, lfile, true, true)
      if server then live_server = server else band.msg(why) end
    end
    ImGui.SetItemTooltip(ctx, "Runs the server on this computer and points the studio at it. Handy when the computer that had it is staying off.")
    if srv_up then
      next_to("Stop server") -- (cut to "Stop ser" at 560 wide: Mac, 0.58.20)
      -- (the running check's answer is a few seconds old: it read "running" for 8 s after. PC, 0.58.18)
      if ImGui.SmallButton(ctx, "Stop server") then services.stop_ninjam(lfile); srv_up, srv_at = false, reaper.time_precise() + 15 end
      ImGui.SetItemTooltip(ctx, "Stops the server on this computer, 10 s after everyone on it has been told to disconnect. It otherwise runs until the computer restarts. It starts again when someone needs it.")
    end
  end
  local _, s = ImGui.Checkbox(ctx, "Send my audio (my whole mix)", live_send)
  live_send = s
  ImGui.Spacing(ctx)
  local master, idx = live.fx(proj, false)
  if not master then
    if ImGui.Button(ctx, "Connect") then
      local why
      if live_server == ((band.read_json(lfile) or {}).server or "") then -- (or an address typed in just now, not saved: that one)
        local server, said = services.ninjam_for(cfg, lfile, true)
        if server then live_server = server else why = said end
      end
      if why then band.msg(why) else
      local sdir = (reaper.GetProjectName(proj) ~= "" and reaper.GetProjectPathEx(proj) or reaper.GetResourcePath()):gsub("\\", "/") .. "/bandsync_live"
      reaper.RecursiveCreateDirectory(sdir, 0)
      reaper.SetProjExtState(proj, band.SECTION, "live_dir", sdir)
      local ok, e = live.configure(cfg, live_server, live_mode, live_send, sdir)
      if not ok then band.msg(e) else
        local m2, i2 = live.fx(proj, true)
        if m2 then
          reaper.TrackFX_Show(m2, i2, 3)
          live.keep_hidden(proj)
          reaper.SetExtState(band.SECTION, "ninjam connect " .. tostring(proj), "1", false) -- (Live sync presses Connect: lib/producer.lua)
        else band.msg("Couldn't add ReaNINJAM to the master track.") end
      end
      end
    end
    ImGui.SetItemTooltip(ctx, "Adds ReaNINJAM to your master track with everything filled in, and connects it. If nobody's running a server, this computer does.")
  else
    -- (it may sit on any track: say which)
    local where = master == reaper.GetMasterTrack(proj) and "your master track" or ("track '" .. select(2, reaper.GetTrackName(master)) .. "'")
    ImGui.TextColored(ctx, GREEN, "ReaNINJAM is on " .. where .. ".")
    require("page_hear").ninjam_line(ctx, ImGui)
    local there, host = srv_addr or "", reaper.GetExtState(band.SECTION, "ninjam host")
    if there ~= "" and host ~= "" and there ~= host then -- (Produce follows by itself: lib/producer.lua. Here it's your Jam: yours to move)
      ImGui.TextColored(ctx, YELLOW, "The studio's server has moved to " .. there .. ": press Leave, then Connect.")
    end
    next_to("NINJAM click on/off")
    if ImGui.SmallButton(ctx, "NINJAM click on/off") then
      if not live.toggle_click() then band.msg("Open ReaNINJAM's window first (Show it).") end
    end
    ImGui.SetItemTooltip(ctx, "NINJAM's own metronome ticks the whole time you're connected (at the server's tempo, not the project's).\n" ..
      "StudioSync turns it off for Play along and Real time; this flips it if it's on anyway.")
    local cm = live.channel_mode()
    if live_mode == "synced" and cm and cm ~= "session" then
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.TextColored(ctx, YELLOW, "It's sending in " .. (cm == "normal" and "Normal" or "Voice Chat") .. " mode, so Play along won't line up: " ..
        "in its window, click the mode button under your channel and pick \"Session mode channel\" (or restart REAPER).")
      ImGui.PopTextWrapPos(ctx)
    end
    local shown = reaper.GetExtState(band.SECTION, "ninjam shown " .. tostring(proj)) ~= ""
    if ImGui.Button(ctx, shown and "Hide it" or "Show it") then -- also takes it off other song tabs (one ReaNINJAM per REAPER) and loads it
      if shown then reaper.DeleteExtState(band.SECTION, "ninjam shown " .. tostring(proj), false); live.keep_hidden(proj) else
        local m2, i2 = live.fx(proj, true)
        if m2 then live.show_windows(proj, m2, i2) end
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Leave") and not live.close_boxes() then
      reaper.DeleteExtState(band.SECTION, "ninjam shown " .. tostring(proj), false)
      live.closing()
      reaper.TrackFX_Delete(master, idx)
    end -- (lib/live.lua: a second press, with one of its boxes up)
  end
  ImGui.TextDisabled(ctx, "(?) about changing mode or server")
  ImGui.SetItemTooltip(ctx, "ReaNINJAM reads its mode once per REAPER session: after changing it, restart REAPER. The server follows by itself. " ..
    "Play along ideas appear when the listener disconnects (ReaNINJAM writes what it heard only then).")
end

local function go(ev) -- post it for the band, and fire it here through our own Live sync
  local b, cfg, proj, view, wide, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.who()
  ev.at = math.floor(os.time()) + together.LEAD
  sync.post(cfg, b.song, b.room, ev)
  ev.user = cfg.user
  reaper.SetExtState(band.SECTION, "transport " .. tostring(proj), band.json_encode(ev), false)
end
local start_from, click_on, side_bars_edit = 0, true, 2 -- start_from: 0 = edit cursor, n = the nth region
local function regions()
  local b, cfg, proj, view, wide, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.who()
  local out, i = {}, 0
  while true do
    local ok, isrgn, p, e, name = reaper.EnumProjectMarkers3(proj, i)
    if ok == 0 then break end
    if isrgn then out[#out + 1] = { name = name ~= "" and name or ("region " .. (#out + 1)), pos = p } end
    i = i + 1
  end
  return out
end
function M.section_together()
  local b, cfg, proj, view, wide, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.who()
  together.tick()
  if ui.want_lag then lag_bars, side_bars_edit, ui.want_lag = ui.want_lag, ui.want_lag, nil end
  local key = tostring(proj)
  -- Side by side: everyone's normal transport buttons drive everyone
  ImGui.SeparatorText(ctx, "Side by side")
  -- kept in the project (until 0.11.3 it was per tab and lost when the tab was closed and reopened)
  local side = select(2, reaper.GetProjExtState(proj, band.SECTION, "side"))
  local ch, on = check("Follow each other: press play, stop and record as usual", side ~= "")
  if ch then
    reaper.SetProjExtState(proj, band.SECTION, "side", on and tostring(side_bars_edit) or "")
  end
  ImGui.SetItemTooltip(ctx, "Whoever presses play, stop or record (or jumps somewhere while playing), everyone in side by side follows.\n" ..
    "The one who records records; the others hear it. Edits land as usual, every half second.")
  ImGui.SetNextItemWidth(ctx, 118)
  local rt = same_room_on() -- (Real time mode is following at 0 bars: changing it here would quietly switch Real time off)
  ImGui.BeginDisabled(ctx, rt)
  local lc, lv = ImGui.InputInt(ctx, "bars behind whoever plays", side_bars_edit)
  if lc then
    side_bars_edit = math.max(0, lv)
    if side ~= "" then reaper.SetProjExtState(proj, band.SECTION, "side", tostring(side_bars_edit)) end
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, rt and "Real time mode is on (Home): everyone follows at the same spot, 0 bars behind. Switch it off there to follow later." or
    "With Play along: 1-2 bars, so you hear them in time with the project.\nWith Real time: 0, everyone at the same spot.")
  if side ~= "" then
    local n = tonumber(side) or 0
    local live_mode_note = live.fx(proj, false) and "Play along / Jam is connected." or (live.fx(proj, false, live.SONOBUS) and "Real time is on."
      or "To hear each other, connect on Play.")
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextDisabled(ctx, string.format("On: you follow %s behind whoever plays. %s", n == 0 and "right along" or (n .. (n == 1 and " bar" or " bars")), live_mode_note))
    local cm = live.fx(proj, false) and live.channel_mode()
    if cm and cm ~= "session" then
      ImGui.TextColored(ctx, YELLOW, "ReaNINJAM is sending in " .. (cm == "normal" and "Normal" or "Voice Chat") ..
        " mode: the others won't hear you in time with the project. In its window, click the mode button under your channel and pick \"Session mode channel\".")
    end
    ImGui.PopTextWrapPos(ctx)
  end

  ImGui.SeparatorText(ctx, "Start together")
  M.start_together(true)
end
-- Everyone starts at one moment, from one spot. `play_along`: with the Play tab's "bars later for listeners".
function M.start_together(play_along)
  local b, cfg, proj, view, wide, who = E.b(), E.cfg(), E.proj(), E.view(), E.wide(), E.who()
  together.tick()
  local key = tostring(proj)
  local rg = regions()
  local names = { "the edit cursor (bar " .. bar_of(reaper.GetCursorPositionEx(proj)) .. ")" }
  for _, r in ipairs(rg) do names[#names + 1] = r.name .. " (bar " .. bar_of(r.pos) .. ")" end
  if start_from > #rg then start_from = 0 end
  ImGui.SetNextItemWidth(ctx, math.max(120, math.min(260, ImGui.GetContentRegionAvail(ctx) - 90)))
  if ImGui.BeginCombo(ctx, "start from", names[start_from + 1]) then
    for i, n in ipairs(names) do if ImGui.Selectable(ctx, n, start_from == i - 1) then start_from = i - 1 end end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetNextItemWidth(ctx, 118)
  local _, c = ImGui.InputInt(ctx, "count-in bars", countin); countin = math.max(0, c)
  ImGui.SameLine(ctx)
  local _, ck = ImGui.Checkbox(ctx, "click", click_on); click_on = ck
  ImGui.SetItemTooltip(ctx, "The metronome plays during the count-in, then goes back off.")
  if play_along then
    ImGui.SetNextItemWidth(ctx, 118)
    local _, l = ImGui.InputInt(ctx, "bars later for listeners", lag_bars); lag_bars = math.max(0, l)
    ImGui.SetItemTooltip(ctx, "Play along only: the others start this many bars after you\n(one NINJAM interval), so what they hear of you lines up.\nLeave 0 for everything else.")
  end
  local pos = start_from > 0 and rg[start_from].pos or reaper.GetCursorPositionEx(proj)
  local function start(rec)
    go({ type = "start", rec = rec or nil, pos = pos, countin = together.bars_before(proj, pos, countin), click = click_on or nil,
      lag = together.bars_after(proj, pos, play_along and lag_bars or 0), lead = cfg.user })
  end
  if ImGui.Button(ctx, "Play together") then start(false) end
  next_to("Record together")
  if ImGui.Button(ctx, "Record together") then start(true) end
  ImGui.SetItemTooltip(ctx, "Everyone records on the tracks they have armed.")
  next_to("Stop together")
  if ImGui.Button(ctx, "Stop together") then go({ type = "stop" }) end
  local due = tonumber(reaper.GetExtState(band.SECTION, "together_at " .. key))
  if due and due - together.now() > 0 then
    ImGui.TextColored(ctx, YELLOW, string.format("Starting in %.1f s...", due - together.now()))
  else
    ImGui.TextDisabled(ctx, string.format("From bar %s, %d s after the click, on every computer with this project open.", bar_of(pos), together.LEAD))
  end
  local last_go = reaper.GetExtState(band.SECTION, "together " .. key)
  if last_go ~= "" then ImGui.TextDisabled(ctx, "Last: " .. last_go) end
end

-- Look the server up again on the next draw (Settings > Health's Set up everything I can may have started one).
function M.reset_server() live_server = nil end

return M
