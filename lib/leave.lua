-- Sync and exit: leaving a session with everything out. Saves, waits for Live sync to have sent what's changed (prints too), has Syncthing look and
-- waits until it's handed over, then says plainly who has it. Only then close the project or quit REAPER. A slice each frame, from the panel.
-- (Syncthing's own numbers count someone ignoring a project as having it, so only someone whose fresh _band/holds list names the project counts as
-- having it: a guest without it, or a computer that deleted its copy, read as "Everything's with Bob. Safe" and the cloud copy was skipped. Round 1
-- review, 0.59.45. Someone who's offline gets it when they're back, from whoever's on, or from the cloud drive: so when nobody who has it is on, the
-- cloud drive gets a last copy.)
local band = require("band")
local leave = {}

local function folder_id(cfg) return band.info(cfg.root).id end
local names = {}

-- Who's online and what they still need of this folder, and what this computer still needs: { peers = { { name, need } }, need }. Slow: called every couple of seconds.
function leave.ask_syncthing(cfg)
  local services = require("services")
  local id = folder_id(cfg)
  local conn = band.json_decode(services.ask("/rest/system/connections", 3) or "")
  local folder = band.json_decode(services.ask("/rest/config/folders/" .. id, 3) or "")
  local status = band.json_decode(services.ask("/rest/db/status?folder=" .. id, 3) or "")
  if type(conn) ~= "table" or type(conn.connections) ~= "table" or type(status) ~= "table" or type(folder) ~= "table" then return nil end
  local out = { peers = {}, need = status.needBytes or 0, state = status.state }
  for _, d in ipairs(folder.devices or {}) do -- (only who this group's folder is shared with: someone in another group of yours read as "sending 0.0 MB")
    local dev = d.deviceID
    if conn.connections[dev] and conn.connections[dev].connected then
      local comp = band.json_decode(services.ask("/rest/db/completion?folder=" .. id .. "&device=" .. dev, 3) or "")
      if type(comp) == "table" and not comp.error and comp.remoteState ~= "notSharing" then
        -- (their name in the group, as Who's here says it; what Syncthing calls that computer only if they haven't said: Mac, 0.51.9)
        if not names[dev] then
          for _, f in ipairs(band.files(cfg.root .. "/_band/devices", ".json")) do
            local d = band.read_json(cfg.root .. "/_band/devices/" .. f)
            if type(d) == "table" and d.device == dev and d.user then names[dev] = d.user end
          end
          names[dev] = names[dev] or services.device_name(dev) -- (slow: once)
        end
        out.peers[#out.peers + 1] = { name = names[dev], need = comp.needBytes or 0 }
      end
    end
  end
  return out
end

-- Of the peers online, who has this project: their holds list (said again within copy.FRESH) names it, or they're in this room now (`here`: lower-cased
-- names from presence.here; a holds list names a newly opened song only when its turn comes, up to minutes later). On a guest's computer
-- (`guest`), which doesn't get the others' holds lists, every peer online counts, as before 0.59.45. Someone taken out (`gone`) never counts.
-- names: the peers' names; lists: localcopy.read_holds; age: band.age. -> names. Pure. (Round 1 review, 0.59.45; here and guest, Round 2 review, 0.59.46:
-- a guest's exit always read "Nobody else who has this project is online")
function leave.holders(names, lists, song, fresh, age, here, guest, gone)
  local has = {}
  for _, l in ipairs(lists or {}) do
    if type(l.songs) == "table" and l.songs[song] and type(l.time) == "string" and age(l.time) < fresh then has[tostring(l.user):lower()] = true end
  end
  for n in pairs(here or {}) do has[n] = true end
  local out = {}
  for _, n in ipairs(names) do
    if (guest or has[tostring(n):lower()]) and not (gone and gone[n]) then out[#out + 1] = n end
  end
  return out
end

-- The finished box's words. j: what happened (problem, unheld, kept_held, holders, drove, drive_left, need, stopped: the step Stop waiting
-- left, sync_off, drive: the cloud drive's name, words). -> lines, and the shut-down line (nil: none). Pure. (Round 1 review, 0.59.45: after
-- Keep holding it said "Everything's with Bob" and then "Not safe: leave this computer on", which never sends held work; after Stop waiting
-- mid-send, "leave this computer on" though quitting REAPER stops the sending.)
leave.NOT_SAFE = "Not safe to shut down yet: leave this computer on, or the others get the rest next time you're both online."
function leave.finish(j)
  local drive = j.drive or "the cloud drive"
  if j.problem then return { j.problem }, j.shut end
  if j.stopped == "send" then
    if j.sync_off then
      return { "Live sync isn't running in this tab, so what you changed since it stopped hasn't gone out." },
        "Not safe to shut down yet: start sync (" .. require("live").PLACES.sync_off .. ") and let it send."
    end
    return { "Not everything has gone out yet: " .. tostring(j.words) .. "." }, "Keep this project open: your changes are still being sent."
  end
  if j.stopped then return { "Not everything has gone out yet: " .. tostring(j.words) .. "." }, leave.NOT_SAFE end
  local lines, unsafe, only_here = { "Saved." }, false, false
  if j.unheld then lines[#lines + 1] = "Hold my changes was on: what you held went out." end
  local names = j.holders or {}
  local all = j.kept_held and "Everything else" or "Everything"
  if #names > 0 then lines[#lines + 1] = all .. " is with " .. table.concat(names, ", ") .. "."
  elseif j.drove then
    lines[#lines + 1] = j.drive_left and ("Nobody else who has this project is online. " .. drive .. " has some of it and the rest is still copying: it carries on while this computer's on.")
      or ("Nobody else who has this project is online. " .. drive .. " has it, so they get it from there or from this computer.")
    unsafe = j.drive_left == true
  else
    lines[#lines + 1] = "Nobody else who has this project is online, and this studio has no " .. (j.drive and (j.drive .. " copy") or "cloud copy") .. " here: it reaches them when this computer and theirs are on at the same time."
    only_here = true
  end
  if (j.need or 0) > 0 then lines[#lines + 1] = string.format("There's %.1f MB on its way to you.", j.need / 1048576) end
  local held = "What you're holding is saved in this project and goes out when you switch Hold my changes off."
  if unsafe then
    if j.kept_held then lines[#lines + 1] = held end
    return lines, leave.NOT_SAFE
  end
  if only_here then
    if j.kept_held then lines[#lines + 1] = held end
    return lines, nil
  end
  return lines, j.kept_held and ("Safe to shut down. " .. held) or "Safe to shut down."
end

-- Auto-save after a lot came in (Live sync): only if the project had nothing unsaved of your own when the batch began, and nothing of yours
-- went out during it (James, Round 1 review, 0.59.45: the save took "close without saving" away from your own unsaved work).
-- st: { n, clean }, kept by the caller; n: changes applied this pass; dirty: the project had unsaved changes just before they were applied;
-- stopped: nothing playing. The caller sets st.clean = false when something of yours goes out. -> true to save now. Pure.
-- Something of yours went out (`sent`) or waits to (`waiting`): no auto-save over this batch. (Round 1 review, 0.59.45; extracted to be tested, Round 2)
function leave.mine_went_out(st, sent, waiting)
  if (sent or 0) > 0 or (waiting or 0) > 0 then st.clean = false end
end
function leave.autosave(st, n, dirty, stopped)
  if n > 0 then
    if (st.n or 0) == 0 then st.clean = not dirty end
    st.n = (st.n or 0) + n
    return false
  end
  if (st.n or 0) >= 100 and stopped then
    local save = st.clean == true
    st.n, st.clean = 0, nil
    return save
  end
  return false
end

-- Everything out? Pure. -> done, what's still going in words.
function leave.settled(st)
  if not st then return false, "Waiting for Syncthing to answer" end
  if st.state ~= "idle" then return false, "Syncthing is looking through the folder" end
  local out = {}
  for _, p in ipairs(st.peers) do
    if p.need > 0 then out[#out + 1] = string.format("%.1f MB to %s", p.need / 1048576, p.name) end
  end
  if #out > 0 then return false, "Sending " .. table.concat(out, ", ") end
  return true
end

function leave.start(proj, cfg, b)
  -- (with Hold my changes on, it asks first: it sent what you held on the click, before anything was asked, and Cancel couldn't take it back.
  -- Full review, 0.59.44)
  local held = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
  leave.job = { proj = proj, cfg = cfg, b = b, step = held and "hold?" or "save", since = reaper.time_precise(), words = "Saving", open = true }
  -- (a backup or autosave never syncs: no saving, sending or Start sync for it. Its Start sync sent an old copy's state to everyone with no
  -- question. Round 2 review, 0.59.46)
  local okc, copy = pcall(require("rooms").is_copy, proj, cfg, b)
  if okc and copy then
    leave.job.step, leave.job.problem = "done", "This is a backup or autosave, not your project for it: nothing of it syncs. Close it as you like."
  end
end
-- Live sync off in the send step: start it for that tab (as the sync pill does; by name, so it needn't come to the front), then back to sending.
local function start_sync(j, dir)
  reaper.DeleteExtState(band.SECTION, "stop " .. tostring(j.proj), false)
  reaper.SetExtState(band.SECTION, "live start for", tostring(j.proj), false)
  band.start_live(dir)
  reaper.DeleteExtState(band.SECTION, "live start for", false)
  j.sync_off, j.started_at, j.words = nil, reaper.time_precise(), "Starting Live sync"
end

local function save_tab(j)
  if j.send_held and select(2, reaper.GetProjExtState(j.proj, band.SECTION, "hold")) ~= "" then
    reaper.SetProjExtState(j.proj, band.SECTION, "hold", "") -- (what you held goes out: you said so)
    j.unheld = true
  end
  reaper.Main_SaveProject(j.proj, false)
  -- a restore point for this session (Live sync's own, as when it goes quiet for 20 minutes)
  reaper.SetExtState(band.SECTION, "end session " .. tostring(j.proj), "Sync and exit", false)
end

-- Live sync has looked since we saved, and has nothing waiting (it says so each pass: "outbox").
local function sent(j, now)
  local key = tostring(j.proj)
  local box = band.ext_json(band.SECTION, "outbox " .. key)
  if type(box) ~= "table" then return false end
  return (tonumber(box.at) or 0) > j.saved_at + 0.5 and not box.more and now - j.saved_at > 2, box
end

function leave.tick()
  local j = leave.job
  if not j or j.finished then return end
  local now = reaper.time_precise()
  if not reaper.ValidatePtr2(0, j.proj, "ReaProject*") then leave.job = nil; return end
  if j.step == "hold?" then return end -- (the box asks)
  if j.step == "save" then
    save_tab(j)
    j.saved_at, j.step, j.words = now, "send", "Sending your changes to the studio"
  elseif j.step == "send" then
    local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(j.proj)))
    -- (not the end: the box offers Start sync and waits. It said "Press Start" with no Start to press, behind a modal box. Round 1 review, 0.59.45)
    if not beat or now - beat > 10 then
      -- (open and syncing in another tab: this one is a second copy; starting it only said "Starting Live sync..." for 15 s and asked again.
      -- Round 2 review, 0.59.46)
      if band.synced_elsewhere(j.proj) then
        j.step, j.problem = "done", "This project is open and syncing in another tab: this one is a second copy, and nothing in it syncs. Use Sync and exit there."
        return
      end
      if not j.started_at or now - j.started_at > 15 then j.sync_off, j.words = true, "Live sync isn't running in this tab" end
      return
    end
    j.sync_off = nil
    local ok, box = sent(j, now)
    if ok then
      require("services").rescan(folder_id(j.cfg))
      j.step, j.at, j.words, j.scan_at = "syncthing", -math.huge, "Handing over to the others", now
    elseif box and box.more then j.words = "Sending your changes (" .. tostring(box.more) .. ")"
    end
  elseif j.step == "syncthing" then
    if now - j.at < 3 or now - j.scan_at < 2 then return end
    j.at = now
    j.st = leave.ask_syncthing(j.cfg)
    local done, words = leave.settled(j.st)
    j.words = words or j.words
    if done then j.step = "drive" end
  elseif j.step == "drive" then
    local drive = require("drive")
    local droot = drive.root(j.cfg)
    j.drive = j.drive or drive.name(j.cfg)
    if not j.holders then
      local names = {}
      for _, p in ipairs(j.st.peers) do names[#names + 1] = p.name end
      local ok, lists = pcall(require("localcopy").read_holds, j.cfg.root)
      local here = {}
      local okh, in_room = pcall(require("presence").here, j.cfg, j.b.song, j.b.room, 90)
      for _, u in ipairs(okh and in_room or {}) do here[tostring(u):lower()] = true end
      local okg, guest = pcall(require("removal").am_guest, j.cfg.root)
      local okr, gone = pcall(require("removal").gone, j.cfg.root)
      j.holders = leave.holders(names, ok and lists or {}, j.b.song, require("localcopy").FRESH or (3 * 86400), band.age, here, okg and guest == true,
        okr and type(gone) == "table" and gone or nil)
    end
    if droot and #j.holders == 0 then
      j.words = "Nobody else who has this project is online: copying to " .. j.drive
      local sync = require("sync")
      local more = false
      for _, room in ipairs(band.subdirs(band.song_dir(j.cfg, j.b.song) .. "/rooms")) do
        local ok, _, m = pcall(drive.mirror, sync.room_dir(j.cfg, j.b.song, room), droot .. "/" .. j.b.song .. "/rooms/" .. room, 0.1, j.cfg.user)
        if ok and m then more = true end
      end
      j.drove = true
      if more and now - j.since < 600 then return end
      j.drive_left = more
    end
    j.step = "done"
  elseif j.step == "done" then
    j.finished = true
    j.need = j.st and j.st.need or 0
    j.lines, j.shut = leave.finish(j)
  end
end

-- Buttons in a row that wrap to the next line when the next one won't fit (the panel's next_to): at a larger text size the box's last
-- buttons ran off its right edge. -> the label pressed, or nil.
local function buttons(ctx, ImGui, labels)
  local hit
  local pad = select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)) * 2 + 8
  for i, l in ipairs(labels) do
    if i > 1 then
      ImGui.SameLine(ctx)
      if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, l) + pad then ImGui.NewLine(ctx) end
    end
    if ImGui.Button(ctx, l) then hit = l end
  end
  return hit
end

function leave.draw(ctx, ImGui, dir)
  local j = leave.job
  if not j then return end
  leave.tick()
  j = leave.job
  if not j then return end
  if j.open then j.open = nil; ImGui.OpenPopup(ctx, "Sync and exit") end
  -- (as wide as the text size makes the words, so the buttons fit: a fixed 440 clipped Cancel at 130%. Round 1 review, 0.59.45)
  local scale = math.max(0.8, math.min(1.6, tonumber(reaper.GetExtState(band.SECTION, "text size")) or 1))
  ImGui.SetNextWindowSize(ctx, math.floor(440 * scale), 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, 12)
  local shown = ImGui.BeginPopupModal(ctx, "Sync and exit", nil, ImGui.WindowFlags_NoResize)
  ImGui.PopStyleVar(ctx)
  if shown then
    ImGui.PushTextWrapPos(ctx, 0)
    local esc = ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) -- (Esc: Cancel, or Stay once it's done)
    if j.step == "hold?" then
      ImGui.Text(ctx, "Hold my changes is on: what you've changed since hasn't gone to the others.")
      -- (the timer starts once answered: "If you go now..." and the cloud copy's 10 minutes ran while the question waited. Round 1 review, 0.59.45)
      local hit = buttons(ctx, ImGui, { "Send what I'm holding", "Keep holding", "Cancel" })
      if hit == "Send what I'm holding" then j.send_held, j.step, j.since = true, "save", reaper.time_precise()
      elseif hit == "Keep holding" then j.kept_held, j.step, j.since = true, "save", reaper.time_precise()
      elseif hit == "Cancel" or esc then leave.job = nil; ImGui.CloseCurrentPopup(ctx) end
    elseif not j.finished then
      if j.sync_off then
        ImGui.TextColored(ctx, require("theme").YELLOW, "Live sync isn't running in this tab, so what you changed since it stopped hasn't gone out.")
        ImGui.TextDisabled(ctx, "Not safe to shut down yet: Start sync sends it.")
      else
        ImGui.Text(ctx, j.words .. "...")
        ImGui.TextDisabled(ctx, string.format("%d s", math.floor(reaper.time_precise() - j.since)))
        if reaper.time_precise() - j.since > 60 then
          ImGui.TextDisabled(ctx, j.step == "send" and "Your changes are still going out: keep this project open." or "If you go now, whoever's online gets the rest next time you're both on.")
        end
      end
      local hit = buttons(ctx, ImGui, j.sync_off and dir and { "Start sync", "Stop waiting", "Cancel" } or { "Stop waiting", "Cancel" })
      if hit == "Start sync" then start_sync(j, dir)
      elseif hit == "Stop waiting" then
        j.finished, j.stopped = true, j.step
        j.lines, j.shut = leave.finish(j)
      elseif hit == "Cancel" or esc then leave.job = nil; ImGui.CloseCurrentPopup(ctx) end
    else
      for _, l in ipairs(j.lines or {}) do ImGui.Text(ctx, l) end
      ImGui.Spacing(ctx)
      if j.shut then ImGui.TextDisabled(ctx, j.shut) end
      local hit = buttons(ctx, ImGui, { "Close this project", "Quit REAPER", "Stay" })
      if hit == "Close this project" then
        leave.job = nil
        ImGui.CloseCurrentPopup(ctx)
        reaper.SelectProjectInstance(j.proj) -- (the project it was for, not whichever tab is in front now: the box doesn't stop tab changes)
        reaper.Main_SaveProject(j.proj, false) -- (a change can land while this box is up: REAPER would ask again)
        reaper.Main_OnCommand(40860, 0) -- Close current project tab
      elseif hit == "Quit REAPER" then
        leave.job = nil
        ImGui.CloseCurrentPopup(ctx)
        for i = 0, 512 do -- (every group project: anything else may be someone's to decide, and REAPER asks about those)
          local p, f = reaper.EnumProjects(i)
          if not p then break end
          if f ~= "" and band.binding(p) then reaper.Main_SaveProject(p, false) end
        end
        reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
      elseif hit == "Stay" or esc then leave.job = nil; ImGui.CloseCurrentPopup(ctx) end
    end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndPopup(ctx)
  end
end

return leave
