-- Settings > Health and Updates (moved out of StudioSync - Panel.lua, 0.58.48: the panel was at Lua's 200 locals). What's set up and working,
-- red or yellow, and the upkeep. The panel hands over what it shares (H.init) and reads these each frame; what changes as you work (the tab in
-- front, your settings, the layout) is asked for at every call, never kept.
local band = require("band")
local sync, setup, services = require("sync"), require("setup"), require("services")
local theme = require("theme")
local GREEN, YELLOW, GREY, RED = theme.GREEN, theme.YELLOW, theme.GREY, theme.RED
local H = {}
local E, ctx, ImGui, ui, card, card_end, heading, next_to, action, logo, wordmark, section_activity, dir
function H.init(env)
  E, ctx, ImGui, ui, dir = env, env.ctx, env.ImGui, env.ui, env.dir
  card, card_end, heading, next_to, action = env.card, env.card_end, env.heading, env.next_to, env.action
  logo, wordmark, section_activity = env.logo, env.wordmark, env.section_activity
end

-- Maintenance: what's set up and working. Red: the band can't sync until it's fixed. Yellow: an extra, or worth a
-- look (dismissable). The sidebar shows the worst one still open.
local maint_st
H.maint_at = -math.huge
function H.maint_rows()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  if not maint_st or maint_st.for_proj ~= proj or reaper.time_precise() - H.maint_at > 10 then -- (another tab's said "Live sync is off" here: laptop, 0.34.9)
    H.maint_at, maint_st = reaper.time_precise(), setup.check(cfg, b, proj)
    maint_st.for_proj = proj
    -- MIDI tracks playing an instrument on another track that doesn't load here (lib/prints.lua prints.route)
    -- files two computers changed at the same moment: Syncthing keeps the one that lost beside it ("x.sync-conflict-..."), and StudioSync
    -- reads only the other, so what was in the loser was gone with nothing said (review, 0.58.52). Where people's shared files are:
    maint_st.conflicts = {}
    local sdir = band.song_dir(cfg, b.song)
    local dirs = { sdir, sdir .. "/chat", sdir .. "/chat/msgs", sdir .. "/chat/todo", sdir .. "/chat/links", cfg.root .. "/_band" }
    for _, room in ipairs(band.subdirs(sdir .. "/rooms")) do dirs[#dirs + 1] = sdir .. "/rooms/" .. room; dirs[#dirs + 1] = sdir .. "/rooms/" .. room .. "/claims" end
    for _, d in ipairs(dirs) do
      reaper.EnumerateFiles(d, -1) -- (re-read: REAPER keeps listings)
      for i = 0, math.huge do
        local f = reaper.EnumerateFiles(d, i)
        if not f then break end
        if f:find(".sync-conflict-", 1, true) then maint_st.conflicts[#maint_st.conflicts + 1] = d .. "/" .. f end
      end
    end
    maint_st.routed = {}
    local prints = require("prints")
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      local dest = prints.route(tr)
      if dest and not prints.track_plays(tr) then
        local fx = select(2, reaper.TrackFX_GetFXName(dest, math.max(0, reaper.TrackFX_GetInstrument(dest))))
        maint_st.routed[#maint_st.routed + 1] = { track = select(2, reaper.GetTrackName(tr)), dest = select(2, reaper.GetTrackName(dest)),
          fx = (fx:gsub("^%w+i?: ", ""):gsub(" %(.-%)$", "")) }
      end
    end
  end
  local s = maint_st
  -- (Live sync, read now: a check made while a dialog paused every script, closing a tab, say, kept "Live sync is
  -- off" up for its 10 s)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
  s.sync = beat ~= nil and reaper.time_precise() - beat < 5
  local rows = {
    { "audio", s.audio, "red", "Audio device is running", "REAPER's audio device is closed: pick one in Preferences > Audio > Device. Until it runs, some plug-ins (CLAP above all) don't take a knob you turn, so the others get it only once audio is back on." },
    { "folder", s.folder, "red", "Shared folder is syncing", "Syncthing isn't running: nothing reaches the studio or comes in." },
    { "sync", s.sync, "red", "Live sync is running", "Live sync is off in this tab: press Start at the top." },
    { "same", (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj))) or 0) == 0, "red", "Changes from the others come out the same here",
      "Some changes from the others came out different here than on their machine (the Console names them). Ask the driver to " ..
      "use Restore > Restore whole project to here, or close and reopen this project." },
    -- (red only when a bandmate is online and we can't reach them: working alone showed red, with "Something needs
    -- fixing" on the tab, though nothing did: review, 2026-10-31)
    { "connected", s.connected, (function()
        for _, r in ipairs(view and view.rows or {}) do if r.age and r.age < 60 then return "red" end end
        return "grey" end)(),
      s.peers and string.format("Connected to %d of %d collaborator machine(s)", s.peers, s.devices) or "Shared folder is a cloud drive",
      s.peers and "Syncthing is connected to nobody. No collaborator is online, so that's fine: your changes reach them later."
      or "Can't tell whether Syncthing is connected." },
    { "relay", (require("services").peers_relayed or 0) == 0, "yellow", "Connections to the others are direct (fast)",
      string.format("%d connection(s) go through a Syncthing relay, so takes and changes arrive slowly. On each computer, let Syncthing through the firewall " ..
        "(Windows: Windows Security > Firewall > Allow an app; Mac: System Settings > Network > Firewall), then restart Syncthing.", require("services").peers_relayed or 0) },
    { "sonobus", s.sonobus, "yellow", "SonoBus is ready (Real time mode)", "SonoBus isn't set up yet: Real time mode (Home) adds it." },
    (function()
      local c = s.conflicts or {}
      local first = c[1] and c[1]:match("([^/]+)%.sync%-conflict") or ""
      return { "conflicts", #c == 0, "yellow", "No files were changed by two computers at once",
        string.format("%d shared file(s) were changed on two computers at the same moment (the first: %s). Syncthing kept the other version beside it, named sync-conflict: look at both and keep what's right.", #c, first),
        action = c[1] and { "Show it", function() band.open_url((c[1]:match("^(.*)/[^/]+$"))) end, "Opens the folder it's in." } or nil }
    end)(),
    { "shared code", not band.from_shared(dir), "yellow", "StudioSync is installed on this computer",
      "StudioSync runs from the shared folder here, so anyone in the studio can change what runs on this computer. Installing it through ReaPack is safer (the README says how)." },
    -- (a saved token that won't unlock: lib/services.lua token_in. Review, 0.59.14)
    { "tailscale token", #services.token_unreadable() == 0, "yellow", "Your Tailscale access token can be read",
      "A Tailscale access token saved here can't be unlocked (REAPER moved to another computer or Windows user?), so guests' time isn't kept: enter it again under Settings > Advanced." },
    (function()
      local skipped = sync.skipped(proj)
      return { "skipped", #skipped == 0, "yellow", "Every change from the others landed here",
        string.format("%d change(s) from the others couldn't be applied here. The first, from %s: %s.", #skipped, skipped[1] and tostring(skipped[1].user) or "", skipped[1] and skipped[1].why or ""),
        action = { "Try again", function() band.log(sync.retry_skipped(proj) .. " change(s) from the others will be tried again") end,
          "Applies them again on Live sync's next pass. If they still fail, they come back here." } }
    end)(),
    (function() -- (two people whose tracks look the same colour: James, 0.59.32)
      local people = require("people")
      local cols = people.colours(cfg.root, { cfg.user })
      local pairs_, mine = people.alike(cols), false
      local said = {}
      for _, pr in ipairs(pairs_) do
        said[#said + 1] = pr[1] .. " and " .. pr[2]
        mine = mine or pr[1] == cfg.user or pr[2] == cfg.user
      end
      return { "colours", #pairs_ == 0, "yellow", "Everyone's colour is easy to tell apart",
        "These colours look alike, so their tracks are hard to tell apart: " .. table.concat(said, "; ") .. ". " ..
          (mine and "Pick another for yourself (right-click your name in Who's here), or let StudioSync pick." or "One of them can pick another: right-click their name in Who's here."),
        action = mine and { "Pick one for me", function()
          local c = people.distinct(cols, cfg.user)
          people.pick(cfg, c)
          band.log(string.format("your colour is now #%06X, the one farthest from everyone else's, in every studio you're in", c))
        end, "Gives you the colour from StudioSync's palette that's least like anyone else's. You can change it any time." } or nil }
    end)(),
    (function() -- (an older REAPER can read a newer one's tracks and items differently: review item 33)
      local tools = require("tools")
      local mine, other, newest = reaper.GetAppVersion():match("^[%d%.]+"), {}, tools.TESTED_REAPER
      for _, r in ipairs(view and view.rows or {}) do
        if r.reaper and r.reaper ~= mine then
          other[#other + 1] = r.name .. " " .. r.reaper
          if band.compare_versions(r.reaper, newest) > 0 then newest = r.reaper end
        end
      end
      -- (behind the others, or behind what StudioSync is tested on: the button's here, not only in Upkeep. James, 0.58.73)
      local behind = band.compare_versions(newest, mine) > 0
      local said = behind and string.format("REAPER %s here is older than %s%s. Something made in a newer REAPER can come out different in an older one.",
          mine, newest, #other > 0 and (" (" .. table.concat(other, ", ") .. ")") or ", which StudioSync is tested on")
        or "REAPER versions differ (you " .. mine .. "; " .. table.concat(other, ", ") .. "). Something made in a newer REAPER can come out " ..
          "different in an older one: the same version everywhere is safest."
      return { "reaper", #other == 0 and not behind, "yellow", "Everyone runs the same REAPER (" .. mine .. ")", said,
        action = behind and { "Update REAPER", function() band.log(tools.update_reaper()) end,
          "Opens the REAPER Update Utility (free, by FeedTheCat), fetching it first if it isn't here: it finds the newest REAPER and installs it." } or nil }
    end)(),
    (function() -- (a Mac bandmate never saw this in the old look. Mac, 0.42.27)
      local undo = require("undo")
      return { "keys", #undo.keys_left(dir) == 0, "yellow", undo.key_name() .. " never rolls back a collaborator's work",
        undo.key_name() .. " can roll back a collaborator's work: it isn't set to StudioSync's Undo yet." }
    end)(),
    { "tailscale", services.tailscale_up(), "yellow", "Tailscale is on", services.tailscale_installed() and "Tailscale is off or not signed in: open it and turn it on. Play along, Jam, private live audio, the listening page and a studio that syncs only through Tailscale need it; nothing else does." or "Tailscale isn't installed: run StudioSync's installer again, or get it from tailscale.com/download." },
  }
  if services.tailscale_up() then
    local stays = services.tailscale_stays()
    rows[#rows + 1] = { "tailscale stays", stays == true, "yellow", "Tailscale stays signed in here", "Tailscale signs this computer out on " .. tostring(stays) .. ": at login.tailscale.com/admin/machines, this computer > ... > Disable key expiry. " ..
      "So new computers stay signed in by themselves, whoever runs the studio's Tailscale network presses Settings > Advanced > Set up the tags (with its access token) once.",
      link = { "Open Tailscale's machines", "https://login.tailscale.com/admin/machines" } }
    -- (a studio on another of your Tailscale accounts: a computer is on one at a time, so this one's Play along, listening page and private
    -- live audio can't reach the others until it switches)
    local want = require("groups").tailnet(cfg.root)
    local now_name, now_suffix = services.tailnet_now()
    if want and now_suffix then
      local prof = want.suffix ~= now_suffix and services.tailscale_profile_for(want.name)
      rows[#rows + 1] = { "tailnet", want.suffix == now_suffix, "yellow", "On this studio's Tailscale network (" .. want.name .. ")",
        "This studio uses the Tailscale network " .. want.name .. ", but this computer is on " .. tostring(now_name) .. " right now, so Play along, the " ..
        "listening page and private live audio can't reach the others. Everything else still syncs. " ..
        (prof and ("Switching moves the whole computer: studios on " .. tostring(now_name) .. " lose those three until you switch back.")
          or "This computer isn't signed in to " .. want.name .. ": ask the studio's owner for a guest invitation, or sign in from Tailscale's menu."),
        action = prof and { "Switch to " .. want.name, function() services.tailscale_switch(prof.id) end,
          "Tailscale's own account switch, the same as picking it in Tailscale's menu. Takes a few seconds." } or nil }
    end
    -- (switched away from this computer's usual network: the way back stays in view until it's taken)
    local away = band.read_json(services.switch_marker())
    if type(away) == "table" and type(away.from_id) == "string" and type(away.from_tailnet) == "string" and now_name and now_name ~= away.from_tailnet then
      rows[#rows + 1] = { "switched away", false, "yellow", "", "This computer switched its Tailscale network from " .. away.from_tailnet .. " to " .. tostring(now_name) ..
        " (" .. tostring(away.at) .. "). Switch back when you're done, so whatever else reaches it over " .. away.from_tailnet .. " works again.",
        action = { "Switch back to " .. away.from_tailnet, function() services.tailscale_switch(away.from_id) end, "Tailscale's own account switch. Takes a few seconds." } }
    end
  end
  if ui.play_shown() then
    rows[#rows + 1] = { "server", s.server, "yellow", "Play along server address is set", "No Play along server yet: Connect on the Play/Jam page (Settings > Advanced > Show the Play/Jam tab) starts one on this computer." }
    if s.hosting then
      rows[#rows + 1] = { "ninjam", s.ninjam, "yellow", "NINJAM server is running here", "NINJAM server isn't running here: Connect on the Play/Jam page (Settings > Advanced > Show the Play/Jam tab) starts it." }
      rows[#rows + 1] = { "ninjam firewall", services.firewall_knows_ninjam(), "yellow", "Windows lets the NINJAM server accept connections", "Nobody can reach the NINJAM server on this computer until Windows allows it: answer Windows' box when it asks. If it was answered No: Windows Security > Firewall > Allow an app, ninjamsrv." }
    end
  end
  -- (a Mac showed its items OFFLINE while another app was in front, and nothing said why: 0.45.0)
  if reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("offlineinact", 0) ~= 0 then
    rows[#rows + 1] = { "offline when inactive", false, "yellow", "", "REAPER takes your media offline whenever another app is in front, so parts show OFFLINE then. StudioSync turned this off once and it's back on: turn off 'Set media items offline when application is not active' in Preferences > Media." }
  end
  if b then -- the interface at another rate than the project: recordings would come out at the interface's (lib/prep.lua)
    local ok, dev, want = pcall(require("prep").device_rate_off, proj, cfg, b)
    if ok and dev then
      rows[#rows + 1] = { "device rate", false, "yellow", "", string.format("Your audio interface runs at %d Hz and this project at %d Hz, so what you record " ..
        "comes out at %d Hz. Set the interface to %d Hz (Preferences > Audio > Device, or its own control panel) before recording.", dev, want, dev, want) }
    end
  end
  do -- prints rendering in front: the background renderer gave up (lib/bgrender.lua, 0.58.86)
    local st = require("prints").bg_state()
    if st and st.gave_up then
      rows[#rows + 1] = { "prints in front", false, "yellow", "", string.format("The background renderer failed %d times (%s), so prints render here in front, " ..
        "holding REAPER for a moment each.", st.failed or 0, st.why or "no reason given"),
        action = { "Try in the background again", function() require("prints").bg_retry() end, "Starts the hidden second REAPER again for the next print." } }
    end
  end
  if b then -- clocks off between computers, and track groups two people numbered alike (lib/presence.lua, 0.58.89)
    local presence = require("presence")
    pcall(presence.peers, cfg, b.song, b.room)
    for u, gap in pairs(presence.skew) do
      rows[#rows + 1] = { "clock " .. u, false, "yellow", "", string.format("%s's clock and this computer's are %d min apart (theirs %s). Who changed what first, " ..
        "who's here and holds go by the clock: on both, turn on setting the time automatically (Windows: Settings > Time & language; Mac: System Settings > General > Date & Time).",
        u, math.floor(math.abs(gap) / 60 + 0.5), gap > 0 and "behind" or "ahead") }
    end
    local okg, clashes = pcall(presence.track_groups, proj)
    for _, c in ipairs(okg and clashes or {}) do
      rows[#rows + 1] = { "group " .. c.group, false, "yellow", "", string.format("Track group %d has tracks made by %s. If nobody put them together on purpose, two of you " ..
        "made a group with the same number and the tracks now move together: give one a free number in the Track grouping matrix (View menu).", c.group, table.concat(c.makers, " and ")) }
    end
  end
  do -- a call app beside REAPER (lib/callapps.lua)
    local ok, words = pcall(require("callapps").health_words)
    if ok and words then rows[#rows + 1] = { "call app", false, "yellow", "", words } end
  end
  if view.newer then rows[#rows + 1] = { "update " .. view.newer, false, "yellow", "", "StudioSync " .. view.newer .. " is in use in the studio; you have " .. band.VERSION .. ": press Update below." } end
  pcall(require("drive").root, cfg) -- (what it says next is about the group it last looked at: this tab's, then. Mac, 0.51.12)
  local dmiss = reaper.GetExtState(band.SECTION, "drive_root") ~= "off" and require("drive").missing
  if dmiss then
    local dname = band.info(cfg.root).drive
    rows[#rows + 1] = { "drive", false, "yellow", "", require("drive").name(cfg) .. ": no shared " .. dname .. " folder in " .. dmiss .. ". " .. require("drive").share_hint(cfg, dname) }
  end
  for k, m in ipairs(s.routed or {}) do -- (by place too: two tracks of one name shared one Dismiss. Review, 0.59.14)
    rows[#rows + 1] = { "routed " .. m.track .. (k > 1 and (" #" .. k) or ""), false, "yellow", "", string.format("'%s' plays %s on '%s', which doesn't load on this computer: " ..
      "you hear the studio's print where there is one, and nothing where there isn't. Installing %s brings the notes back here.",
      m.track, m.fx, m.dest, m.fx) }
  end
  do -- (the scripts came by the shared folder, so ReaPack never updated the extension: no amber dot on a Mac. Mac review, 0.59.14)
    local have = reaper.GetExtState(band.SECTION, "menu extension")
    local want = require("tools").EXT_WANT
    if have ~= "" and band.compare_versions(have, want) < 0 then
      rows[#rows + 1] = { "menu ext", false, "yellow", "", "StudioSync's menu extension here is " .. have .. ", older than this StudioSync's " .. want ..
        ": restart REAPER. (StudioSync puts the new one in by itself from the copy it runs from; a ReaPack install gets it with Extensions > ReaPack > Synchronize packages.)" }
    end
  end
  -- (without them less works, quietly: onboarding review, 0.59.9)
  if not reaper.APIExists("CF_GetSWSVersion") then
    rows[#rows + 1] = { "sws", false, "yellow", "", "SWS isn't installed: reopening a project without REAPER's warning boxes is off. It's free: sws-extension.org, or Extensions > ReaPack > Browse packages." }
  end
  if not reaper.APIExists("JS_ReaScriptAPI_Version") then
    rows[#rows + 1] = { "js api", false, "yellow", "", "js_ReaScriptAPI isn't installed: counting the cloud copy's files and putting windows back where they were don't work. Extensions > ReaPack > Browse packages: js_ReaScriptAPI." }
  end
  local daway = reaper.GetExtState(band.SECTION, "drive_root") ~= "off" and require("drive").away
  if daway then
    local who = daway:match("GoogleDrive%-([^/]+)/") or daway:match("^(%a:)")
    rows[#rows + 1] = { "drive away", false, "yellow", "", require("drive").label(require("drive").service_of(daway)) .. ": the studio's folder (" .. tostring(who) .. ") isn't here now. Is that " ..
      "account signed out, or switched for another? Everything still syncs between you; the cloud copy catches up once it's back." ..
      (require("drive").other and ("\nThere's a folder of that name in " .. require("drive").label(require("drive").service_of(require("drive").other)) ..
        " too, left alone: to use that one, pick it in Settings > Cloud copy.") or "") }
  end
  return rows
end
function H.dismissed_set()
  local set = {}
  for id in reaper.GetExtState(band.SECTION, "dismissed"):gmatch("[^|]+") do set[id] = true end
  return set
end
function H.maint_level()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  local gone, worst = H.dismissed_set(), nil
  for _, r in ipairs(H.maint_rows()) do
    if not r[2] and r[3] ~= "grey" and not (r[3] == "yellow" and gone[r[1]]) then -- (grey: fine as it is, just said)
      if r[3] == "red" then return "red" end
      worst = "yellow"
    end
  end
  return worst
end
function H.dot(col)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = ImGui.GetTextLineHeight(ctx)
  ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + 5, y + h / 2 + 1, 5, col)
  ImGui.Dummy(ctx, 12, h)
end
function H.maint_health()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  local gone = H.dismissed_set()
  if card("health") then
    if not ui.short then heading("Set up and health", 17) end -- (short: the tab above says it)
    local rows, three = {}, wide and ImGui.BeginTable(ctx, "healthrows", 3, ImGui.TableFlags_SizingStretchSame)
    local all = H.maint_rows() -- (once: each build reads files and asks Syncthing. Review)
    for _, r in ipairs(all) do if not r[2] then rows[#rows + 1] = r end end -- (what needs you first: it was below the fold docked)
    for _, r in ipairs(all) do if r[2] then rows[#rows + 1] = r end end
    for _, r in ipairs(rows) do
      local ok = r[2]
      if ok or r[3] == "red" or not gone[r[1]] then
        if three then ImGui.TableNextColumn(ctx) end
        ImGui.PushID(ctx, r[1])
        H.dot(ok and GREEN or (r[3] == "red" and RED or r[3] == "grey" and GREY or YELLOW))
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, ok and r[4] or r[5])
        if not ok and r.link then
          if ImGui.SmallButton(ctx, r.link[1]) then band.open_url(r.link[2]) end
          ImGui.SetItemTooltip(ctx, r.link[2])
          ImGui.SameLine(ctx)
        end
        if not ok and r.copy then
          if ImGui.SmallButton(ctx, "Copy the line") then band.copy(r.copy, ctx, ImGui) end
          ImGui.SetItemTooltip(ctx, r.copy)
          ImGui.SameLine(ctx)
        end
        if not ok and r.action then
          if ImGui.SmallButton(ctx, r.action[1]) then r.action[2](); H.maint_at = 0 end
          ImGui.SetItemTooltip(ctx, r.action[3])
          ImGui.SameLine(ctx)
        end
        if not ok and r[1] == "keys" then
          if ImGui.SmallButton(ctx, "Set " .. require("undo").key_name()) then require("undo").bind_keys(dir); H.maint_at = 0 end
          ImGui.SetItemTooltip(ctx, "With your own edit on top of REAPER's undo list it undoes that, as ever. With a collaborator's change on top, it undoes your own last change, not theirs.")
          ImGui.SameLine(ctx)
        end
        if not ok and r[3] == "yellow" then
          if three then next_to("Dismiss") end -- (on a row of its own it pushed the button below a short docker's fold)
          if ImGui.SmallButton(ctx, "Dismiss") then
            gone[r[1]] = true
            local list = {}
            for id in pairs(gone) do list[#list + 1] = id end
            reaper.SetExtState(band.SECTION, "dismissed", table.concat(list, "|"), true)
          end
          ImGui.SetItemTooltip(ctx, "Hide this one (it stops lighting up the sidebar). 'Show dismissed' brings it back.")
        end
        ImGui.PopID(ctx)
      end
    end
    if three then ImGui.EndTable(ctx) end
    if next(gone) then
      if ImGui.SmallButton(ctx, "Show dismissed") then reaper.DeleteExtState(band.SECTION, "dismissed", true) end
      ImGui.SetItemTooltip(ctx, "Bring back the yellow lines you dismissed.")
    end
    if ImGui.Button(ctx, "Set up everything I can") then
      local notes = setup.all(cfg, b, proj, maint_st, function() band.start_live(dir) end, ui.play_shown())
      H.maint_at = -math.huge; E.reset_live_server()
      if #notes > 0 then band.log("Set up: " .. table.concat(notes, "; ")) end
    end
    ImGui.SetItemTooltip(ctx, "Starts Syncthing and Live sync, and adds SonoBus (off). The rest needs you.")
    card_end()
  end
end
function H.maint_upkeep()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  if card("upkeep") then
    heading("Upkeep and activity", 17)
    section_activity()
    if ImGui.Button(ctx, "Update StudioSync") then action("Update") end -- (beside Update REAPER: which one, said. James, 0.58.98)
    ImGui.SetItemTooltip(ctx, "StudioSync itself, to the newest version.")
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Update REAPER") then band.log(require("tools").update_reaper()) end
    ImGui.SetItemTooltip(ctx, "REAPER " .. reaper.GetAppVersion():gsub("/.*", "") .. " here. Opens the REAPER Update Utility (free, by FeedTheCat), which finds the newest\n" ..
      "REAPER and installs it; it's fetched first if it isn't here. Everyone on the same REAPER is safest.")
    card_end()
  end
end
function H.about()
  local b, cfg, proj, view, wide = E.b(), E.cfg(), E.proj(), E.view(), E.wide()
  local s = ui.short and 110 or 140 -- (short: the whole logo, not its feet)
  if not wide then ImGui.Dummy(ctx, 0, 12) end
  local w = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, (w - s - 170) / 2))
  logo(s)
  ImGui.SameLine(ctx, 0, 16)
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + (s - 52) / 2)
  ImGui.BeginGroup(ctx)
  wordmark(32)
  ImGui.TextDisabled(ctx, "version " .. band.VERSION)
  ImGui.EndGroup(ctx)
end

-- Home: playing together, who's here and what they're doing, and the session's switches.

return H
