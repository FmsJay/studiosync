-- @description StudioSync: start Live sync with REAPER (run from Scripts/__startup.lua; the panel's toggle adds it)
-- Watches the open projects. A StudioSync session whose Live sync was running when REAPER closed (and that nobody
-- stopped) gets Live sync started again, so a restart doesn't silently drop you out of the band, in front or not.
-- It also runs the installer's setup step when the installer leaves a request (<resource>/StudioSync/install-request):
-- on macOS any Apple Event reaching REAPER while ReaPack's report window is open crashes it (2026-10-28), so an
-- installer talking to a running REAPER leaves a file here instead of "open -a REAPER".
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
band.note_start(dir) -- (was all of this copy here as it started? band.started_partial. Full review, 0.59.44)
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now. 0.59.24)
band.WHO = "autostart" -- (which script a line in the log file came from)
-- (every lib module now, under the code you said yes to: one first needed later was refused once a newer version's file had arrived.
-- James's decision, Round 2 review, 0.59.46)
if band.preload then band.try("band.preload", band.preload, dir) end
-- (band functions newer than the entry script's own start: a part-arrived copy can pair this file with an older band.lua, and the update
-- check then failed on every pass and never reached the reload that mends it. Round 2 review, 0.59.46)
local function disk_version() return band.version_on_disk and band.version_on_disk(dir) or (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"') end
local function failed_key() return band.reload_failed_key and band.reload_failed_key("StudioSync - Autostart.lua") or "reload failed StudioSync - Autostart.lua" end

do -- the Actions list as it should be for this version: an update through the shared folder brings new scripts, which REAPER doesn't
  -- know until they're registered (laptop, 2026-10-31: the radial menu wasn't there); and only what opens StudioSync, unless you asked for
  -- them all (band.sync_actions, 0.58.71)
  band.sync_actions(dir, true)
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  if kb then
    local text = kb:read("a")
    kb:close()
    local function read(p) local f = io.open(p, "r"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
    local old = band.old_actions(text, band.norm(reaper.GetResourcePath()) .. "/Scripts", reaper.file_exists, read)
    for i, a in ipairs(old) do reaper.AddRemoveReaScript(false, a.section, a.path, i == #old) end
  end
end

do -- (the startup block tried a copy that failed to load and started this one instead: lib/tools.lua startup_block. Round 1 review, 0.59.45)
  local failed = reaper.GetExtState(band.SECTION, "startup failed")
  if failed ~= "" then
    reaper.DeleteExtState(band.SECTION, "startup failed", false)
    band.log("StudioSync couldn't start from " .. failed .. ". Running from " .. dir .. " instead")
  end
end
band.try("band.restore_settings", band.restore_settings) -- (what a crash lost, back from settings.json: lib/band.lua, 0.58.89)
band.try("tools.toolbar_default", require("tools").toolbar_default) -- (StudioSync's button on the main toolbar from the first restart after installing: 0.58.82)
-- (the startup block as it's written now: an older block (a bare dofile) was never rewritten, so the last-good fallback was on no computer. Round 2
-- review, 0.59.46. Once per load of this file, a reload too: run only at REAPER's start, a computer that updated in place kept the old block
-- until the very start the safety net is for. One read of __startup.lua, a no-op on a current block. Round 3 review, 0.59.48)
do
  local okt, tools = pcall(require, "tools")
  if okt and tools.upgrade_startup and select(2, band.try("tools.upgrade_startup", tools.upgrade_startup)) == true then band.log("StudioSync's start in Scripts/__startup.lua is written as it is now: it falls back to the last copy that started fine") end
end

if reaper.GetExtState(band.SECTION, "open panel at start") == "1" then -- (the installer's restart for ReaPersona's shortcuts: back in the panel. 0.58.64)
  reaper.DeleteExtState(band.SECTION, "open panel at start", true)
  local id = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - Panel.lua", true)
  if id > 0 then reaper.defer(function() if reaper.GetToggleCommandState(id) ~= 1 then reaper.Main_OnCommand(id, 0) end end) end
end

local REQUEST = band.home() .. "/install-request"
local tried = {} -- project key -> when we last started it (don't hammer a Live sync that refuses to run)
local at, seen_disk = reaper.time_precise(), nil -- (0 read as a gap, and held the first look back 30 s after REAPER opened. Onboarding review, 0.59.9)
local keys_set = BANDSYNC_AUTOSTART_STARTED == true -- (carried over an update's reload: the startup steps ran again, reopening tabs and switching the front one. Review, 0.58.47)
-- Something stopped syncing: the panel says so in red, and with the panel closed the tiny box comes back to say it. (Said once: closing the box again keeps it closed.)
local function say_problem(words)
  local was = reaper.GetExtState(band.SECTION, "sync problem")
  if (words or "") == was then return end
  if not words then return reaper.DeleteExtState(band.SECTION, "sync problem", false) end
  reaper.SetExtState(band.SECTION, "sync problem", words, false)
  band.log(words)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  if not (beat and reaper.time_precise() - beat < 10) then
    reaper.SetExtState(band.SECTION, "panel minimized", "1", true)
    local id = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - Panel.lua", true)
    if id > 0 and reaper.GetToggleCommandState(id) ~= 1 then
      reaper.SetExtState(band.SECTION, "panel start small", "1", false) -- (opened by hand it opens full: this is the one that asks for the box)
      reaper.Main_OnCommand(id, 0)
    end
  end
end
local st_at, st_up = -math.huge, true
local BEHIND, loop_began = 8, reaper.time_precise()
local songsync_at -- (when the studios' ignore files were last kept in step)
local held_until = -math.huge -- (after REAPER held every script, Live sync's beat is old too: it isn't stopped, it's catching up)
local loop
local partial_retried = false -- (the "reload failed" key cleared once this copy, started part-arrived, is whole)
-- An update: the new code takes over in place (once the version on disk has held for two looks), as Live sync does; before 0.21.3 a running
-- Autostart kept its old rules until REAPER restarted. -> "stop" when it reloaded (the new code runs its own loop).
local function update_check()
  local disk = disk_version()
  -- (asked only while nothing plays or records anywhere: the box holds every script, so every tab's Live sync stopped mid-take until someone
  -- answered, and the band saw this computer as away. Review, 0.58.87)
  if disk and disk ~= band.VERSION and disk == seen_disk and not band.update_ok(dir, disk) and reaper.GetExtState(band.SECTION, "update asked") ~= disk
      and reaper.GetPlayState() == 0 and band.files_complete(dir) then -- (and only once every file has arrived: lib/band.lua)
    -- (once per version and REAPER session: persisted, the log line below ("asks again when it next starts") wasn't true. Round 3 review, 0.59.48)
    reaper.SetExtState(band.SECTION, "update asked", disk, false)
    local trusted = select(2, pcall(require("fromfolder").trusted_copy, dir)) == true
    if trusted then -- (the studio updates through its folder: taken without asking. lib/fromfolder.lua, 0.59.32)
      reaper.SetExtState(band.SECTION, "update ok", disk, true)
      band.log("StudioSync " .. disk .. " arrived in the studio's folder: switching to it (the studio updates through its folder)")
    elseif reaper.MB("StudioSync " .. disk .. " has arrived in the shared folder (this computer runs StudioSync from there).\n\n" ..
        "Anyone in the studio can put a new version there. Only say Yes if you expected an update from your studio.\n\nSwitch to it now?", "StudioSync", 4) == 6 then
      reaper.SetExtState(band.SECTION, "update ok", disk, true)
    else band.log("StudioSync " .. disk .. " in the shared folder wasn't switched to (you said no). StudioSync asks again when REAPER next starts: ask your studio about it") end
  end
  -- (a version that failed to start on a part-arrived copy is tried once more when the copy is whole: the failure held it back until REAPER
  -- restarted. Once, as it turns whole, not every look. Round 3 review, 0.59.48)
  if not partial_retried and band.started_partial(dir) then
    partial_retried = true
    reaper.DeleteExtState(band.SECTION, failed_key(), false)
  end
  if disk and ((disk ~= band.VERSION and disk == seen_disk and band.update_ok(dir, disk)) or band.started_partial(dir))
      and reaper.GetExtState(band.SECTION, failed_key()) ~= disk then
    if band.reload_or_say(dir, "StudioSync - Autostart.lua", disk) then return "stop" end -- (safe: band.reload. 0.59.44)
  end
  seen_disk = disk
end
-- (an error goes to the log file with where it happened, once per version and message, and Autostart carries on, its update check first:
-- an error stopped it, and with it every computer's way to the fixed version, as only Autostart takes an update. 0.58.86; Round 1 review, 0.59.45)
local erred, checked_at = {}, -math.huge
local function guarded(fn)
  return function()
    local ok, res = xpcall(fn, debug.traceback)
    if not ok then
      local k = band.VERSION .. "\0" .. (tostring(res):match("^[^\n]*") or "")
      if not erred[k] then erred[k] = true; band.log_error("autostart", res) end
      -- (every 2 s at most, as the loop's own look: an error before its 2 s gate ran it on every defer. Round 2 review, 0.59.46)
      if reaper.time_precise() - checked_at >= 2 then
        checked_at = reaper.time_precise()
        local okc, r2 = xpcall(update_check, debug.traceback)
        if okc and r2 == "stop" then return end
      end
    elseif res == "stop" then return end
    reaper.defer(loop)
  end
end
local good_at -- (when this copy is kept as the last that started fine: band.save_last_good)
local function loop_body()
  -- the toolbar button stopped a minimized panel: it opens again, full (Panel's atexit asks; 0.58.98). Looked at every pass: a click wants it now
  local tip = tonumber(reaper.GetExtState(band.SECTION, "tooltip until")) -- (the panel's closing words: taken away here, 0.58.99)
  if tip and reaper.time_precise() > tip then reaper.DeleteExtState(band.SECTION, "tooltip until", false); reaper.TrackCtl_SetToolTip("", 0, 0, true) end
  local reopen = tonumber(reaper.GetExtState(band.SECTION, "panel reopen"))
  if reopen then
    reaper.DeleteExtState(band.SECTION, "panel reopen", false)
    if reaper.time_precise() - reopen < 5 then
      reaper.DeleteExtState(band.SECTION, "panel minimized", true)
      local id = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - Panel.lua", true)
      if id > 0 and reaper.GetToggleCommandState(id) ~= 1 then reaper.Main_OnCommand(id, 0) end
    end
  end
  if reaper.time_precise() - at < 2 then return end -- every 2 s is plenty (guarded defers it again)
  -- (a gap here means a box held all of REAPER, this too: a Record Warning left two minutes, and every Live sync's beat was old. Restarted then,
  -- each replaced one saved a kept "end of session" in the middle of a session. Mac, 0.58.45. So a look after a gap waits half a minute)
  if reaper.time_precise() - at > 10 then held_until = reaper.time_precise() + 30 end
  at = reaper.time_precise()
  -- the hidden REAPER that renders prints (lib/bgrender.lua) opens a copy from bandsync-render: nothing to do there
  for i = 0, 64 do
    local p, fn = reaper.EnumProjects(i)
    if not p then break end
    if (fn or ""):find("bandsync-render", 1, true) then return "stop" end
  end
  if not keys_set then -- (Ctrl+Z never rolls back a bandmate's work: lib/undo.lua. Not in the hidden renderer, above)
    keys_set, BANDSYNC_AUTOSTART_STARTED = true, true
    band.try("undo.auto_keys", require("undo").auto_keys, dir)
    -- (Syncthing started here, once, when this computer is in a studio: only Live sync started it, and a version whose Live sync failed as it
    -- started left a restarted Windows or Mac computer without it, so the fix couldn't arrive. Not a login item. James's decision, Round 2 review, 0.59.46)
    if #band.bands() > 0 then band.try("services.ensure_syncthing", require("services").ensure_syncthing) end
    local ok, why = pcall(require("startup").on_start) -- (the band's songs, opened without REAPER's boxes: lib/startup.lua)
    if not ok then band.log("couldn't open the studio's projects by itself: " .. tostring(why)) end
    band.try("services.stop_old_relay", require("services").stop_old_relay) -- (a Mac's ReaNINJAM relay from an older StudioSync, left running: lib/services.lua)
    -- (did REAPER close cleanly last time? If not, debug mode sends this computer's part now, with the crash report. lib/debugmode.lua)
    local okd, unclean = pcall(require("debugmode").session_start)
    if okd and unclean then band.try("debugmode.computer_all", require("debugmode").computer_all, reaper.GetExtState(band.SECTION, "user")) end
    band.try("debugmode.tell", require("debugmode").tell, reaper.GetExtState(band.SECTION, "user")) -- (debug mode on here? Said once)
    reaper.atexit(function()
      band.try("debugmode.computer_all", require("debugmode").computer_all, reaper.GetExtState(band.SECTION, "user")) -- (debug mode: as REAPER quits)
      band.try("debugmode.session_end", require("debugmode").session_end)
      band.try("undo.auto_keys", require("undo").auto_keys, dir)
      band.try("startup.on_quit", require("startup").on_quit)
      band.try("services.tidy_temp", require("services").tidy_temp)
    end)
  end
  band.try("startup.note", require("startup").note)
  band.try("band.keep_settings", band.keep_settings)
  if reaper.time_precise() - (songsync_at or -math.huge) > 30 then -- (each studio's ignore file kept in step: a guest's projects, lib/access.lua)
    songsync_at = reaper.time_precise()
    local me = reaper.GetExtState(band.SECTION, "user")
    for _, x in ipairs(band.bands()) do
      -- (only where this computer is a guest with a list, or its ignore file still has a guest's block to undo: elsewhere it's written
      -- only when a project is opened or kept, as before)
      local okm, set = pcall(require("access").mine, x.root)
      -- (and where its debug lines aren't as they should be: only the owner and admins download everyone's reports. 0.59.40)
      local okd, dbg_ok = pcall(require("songsync").debug_ok, { root = x.root, user = me })
      -- (and wherever this computer is a guest, a list or not: its ignore file leaves out the studio's copy of StudioSync and other people's
      -- files that name projects. The marks are read here every 30 s, their verdicts kept. Round 1 review, 0.59.45)
      local okg, guest = pcall(require("removal").am_guest, x.root)
      -- (and a guest's lines still there once they're a member: Round 2 review, 0.59.46)
      local ign = band.read(x.root .. "/.stignore") or ""
      if (okd and not dbg_ok) or (okm and set) or (okg and guest) or ign:find("\n(?d)/*\n", 1, true) or ign:find("\n/_tools\n", 1, true) then
        band.try("songsync.apply", require("songsync").apply, { root = x.root, user = me })
      end
    end
  end
  band.try("band.sws_colours", band.sws_colours) -- (SWS auto-colouring off while a band song is in front, back on otherwise)
  band.try("removal.tick", require("removal").tick) -- (someone taken out of a group, and which computer is whose: lib/removal.lua)
  band.try("fromfolder.tick", require("fromfolder").tick, dir) -- (a studio that updates through its folder: lib/fromfolder.lua, 0.59.24)
  band.try("fromfolder.extension_tick", require("fromfolder").extension_tick, dir) -- (the menu extension from the copy it runs from: 0.59.27)
  band.try("listen.tick", require("listen").tick) -- (the listening page, where this computer shares it)
  -- (guests off Tailscale when their time is up, with or without the panel open: it ran only in the panel. Security review, 0.58.87)
  band.try("services.tailscale_sweep_guests", require("services").tailscale_sweep_guests)
  if update_check() == "stop" then return "stop" end
  -- (this copy, once it has run a minute without an error, is kept as the last that started fine: the startup block falls back to it. Once per
  -- version: about 2 MB copied then, nothing on other passes. James's decision, Round 1 review, 0.59.45)
  -- (Round 2 review, 0.59.46: only the version running and whole, which save_last_good checks (nil: not now, tried again a minute later), and
  -- not while anything records.)
  good_at = good_at or reaper.time_precise()
  if good_at ~= true and reaper.time_precise() - good_at > 60 and not next(erred) and band.save_last_good and not band.recording_anywhere() then
    local okg, res = band.try("band.save_last_good", band.save_last_good, dir)
    -- (a copy that failed (a full disk) is tried again in a minute too: it left the last-good folder half copied until REAPER restarted.
    -- Round 3 review, 0.59.48)
    good_at = (not okg or res == nil) and reaper.time_precise() or true
  end
  -- a StudioSync session that opens (or is open when REAPER starts) opens the panel, once per opening: closing the panel
  -- keeps it closed until another StudioSync session opens. (Marks aren't persisted, and survive an Autostart reload.)
  local opened = false
  for i = 0, 512 do
    local proj, fn = reaper.EnumProjects(i)
    if not proj then break end
    local mark = "panel for " .. tostring(proj) .. " " .. fn:lower()
    if fn ~= "" and reaper.GetExtState(band.SECTION, mark) == "" and band.binding(proj) then
      reaper.SetExtState(band.SECTION, mark, "1", false)
      opened = true
    end
  end
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  if opened and not (beat and reaper.time_precise() - beat < 10) then
    local id = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - Panel.lua", true)
    if id > 0 and reaper.GetToggleCommandState(id) ~= 1 then
      -- (opened with a session: as you last left it, the box or strip kept. Review, 0.58.98)
      if reaper.GetExtState(band.SECTION, "panel minimized") ~= "" then reaper.SetExtState(band.SECTION, "panel start small", "1", false) end
      reaper.Main_OnCommand(id, 0)
    end
  end
  local helper = band.read(REQUEST)
  if helper then
    os.remove(REQUEST)
    helper = helper:match("^%s*(.-)%s*$")
    if reaper.file_exists(helper) then
      local ok, err = pcall(dofile, helper)
      if not ok then band.log("the installer's setup step failed: " .. tostring(err)) end
    end
  end
  local problem
  if band.binding(reaper.EnumProjects(-1)) then
    if reaper.time_precise() - st_at > 20 then
      st_at = reaper.time_precise()
      local ok, up = pcall(require("services").running, "syncthing")
      st_up = not ok or up
    end
    if not st_up then problem = "Syncthing isn't running on this computer: nothing reaches the studio or comes in. Restart REAPER, or " .. require("live").PLACES.setup_all .. " starts it (with a project open)." end
  end
  local front = reaper.EnumProjects(-1)
  local started_behind, running_behind = false, 0
  for i = 0, 512 do
    local p = reaper.EnumProjects(i)
    if not p then break end
    local beat = p ~= front and tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
    if beat and reaper.time_precise() - beat < 30 then running_behind = running_behind + 1 end
  end
  for i = 0, 512 do
    local proj, fn = reaper.EnumProjects(i)
    if not proj then break end
    local key = tostring(proj)
    if fn ~= "" and band.autosync(fn) and band.binding(proj) then -- (the ExtState, the old key, or autosync.json: band.autosync)
      -- A tab just opened: its live audio off now, as Live sync does when it starts there ("live began <tab>", this REAPER session). A song
      -- saved with ReaNINJAM in it opens with its windows up, and a tab behind waited up to half a minute for its Live sync (James, 0.59.19).
      if reaper.GetExtState(band.SECTION, "live began " .. key) == "" then
        reaper.SetExtState(band.SECTION, "live began " .. key, "1", false)
        local ok, was = pcall(require("live").all_off, proj)
        if ok and was then band.log("live audio starts off when a project opens: Real time mode (and Time-sync) and the call are off. Switch them on on Home and in Chat > Call") end
      end
      local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
      -- (30 s, not 5: a dialog left open a few seconds pauses every script, and isn't a Live sync that stopped)
      local alive = beat and reaper.time_precise() - beat < 30 or reaper.time_precise() < held_until
      -- The tab in front first, three tries, then it says so once. Tabs behind it follow, one a look and none of them brought forward: flipping
      -- them to the front never stopped with 38 tabs open and REAPER couldn't be clicked (PC, 2026-10-30), and left alone, their bandmates saw
      -- this person as offline until they switched to the tab (Mac, 0.57.6). One try each, and at most BEHIND of them.
      -- (by tab and file: REAPER reuses a closed tab's address, and a new project there was "wouldn't start again" from the first look. Review, 0.59.14)
      local n = tried[key .. "|" .. fn] or { at = -1e9, n = 0 }
      tried[key .. "|" .. fn] = n
      -- (another REAPER on this computer syncs this song: not started here, and said why. 0.59.18)
      local away = tonumber(reaper.GetExtState(band.SECTION, "elsewhere " .. key))
      if alive then n.n = 0
      elseif away and reaper.time_precise() - away < 120 then
        if proj == front then problem = problem or "This song is syncing in another REAPER on this computer: work there, or close it there first." end
      elseif proj == front and n.n < 3 and reaper.time_precise() - n.at > 30 then
        n.at, n.n = reaper.time_precise(), n.n + 1
        band.log("starting Live sync again for " .. fn)
        if not band.start_live(dir) then band.log("Live sync has no free slot for " .. fn .. ": close some StudioSync tabs (17 at most run at once)") end
        if n.n == 3 then band.log("Live sync didn't stay running for " .. fn .. " after 3 tries: click " .. require("live").PLACES.sync_off) end
      elseif proj ~= front and n.n == 0 and not started_behind and running_behind < BEHIND and reaper.time_precise() - loop_began > 20 then
        n.at, n.n, started_behind = reaper.time_precise(), 1, true
        reaper.SetExtState(band.SECTION, "live start for", key, false)
        band.log("starting Live sync again for " .. fn .. " (behind the tab in front)")
        band.start_live(dir)
        reaper.DeleteExtState(band.SECTION, "live start for", false)
      elseif proj == front and n.n >= 3 then
        problem = problem or "Live sync stopped in this project and wouldn't start again: your changes aren't going out. Click the red Sync off button at the top of the panel."
      end
    end
  end
  say_problem(problem)
end
loop = guarded(loop_body)
reaper.defer(loop)
