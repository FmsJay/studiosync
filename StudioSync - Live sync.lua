-- @description StudioSync: live sync for this project (runs in the background whenever a StudioSync project is open)
-- Keeps this project identical to the band's (mirror sync, docs/mirror-design.md): every track, item and plug-in
-- chain you may change goes out a moment after you change it; the band's changes come in; a change you may not make
-- (someone else's claim, or the driver's) is put back. Also plays/records together and runs the live modes.
-- Never touches a track while it records.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
band.note_start(dir) -- (was all of this copy here as it started? band.started_partial. Full review, 0.59.44)
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now. 0.59.24)
-- (every module loaded now, as approved: one first needed mid-session after its file changed was refused by the code check. James, Round 2 review, 0.59.46)
if band.preload then band.try("band.preload", band.preload, dir) end
-- (the modules this chunk needs as it starts, through band.try: one refused by the code check mid-arrival gave REAPER's error box on an
-- unattended start. Round 4 review, 0.59.49)
for _, m in ipairs({ "sync", "live", "together", "songsync", "recall", "drive", "livemidi", "direct", "streams" }) do
  if not band.try("require " .. m, require, m) then return end
end
local sync = require("sync")
sync.autosave = sync.autosave or {} -- (lib/leave.lua leave.autosave: how much came in since the last auto-save, and whether it may save)
local live = require("live")
local together = require("together")
local direct = require("direct") -- (the direct link: lib/direct.lua. James, 0.60.0-rt)
local transport -- a pending start/stop (lib/together.lua)
local clip_said -- when we last warned about the master clipping
local due_in = math.huge -- seconds until a pending start/stop fires

-- (what an update's reload hands over, taken before anything can return early, so none of it reaches the next Live sync started here. 0.58.93)
local reload_proj, reload_ended = BANDSYNC_LIVE_PROJ, BANDSYNC_ENDED_AT
BANDSYNC_LIVE_PROJ, BANDSYNC_ENDED_AT = nil, nil
local cfg = band.settings()
if not cfg then return end
local proj = reload_proj or reaper.EnumProjects(-1) -- (set when an update reloads us: our tab, not the front one)
do -- (Autostart asks for a tab behind the front one by name: starting it never has to bring it forward)
  local asked = reaper.GetExtState(band.SECTION, "live start for")
  if asked ~= "" then
    reaper.DeleteExtState(band.SECTION, "live start for", false)
    for i = 0, 512 do
      local p = reaper.EnumProjects(i)
      if not p then break end
      if tostring(p) == asked then proj = p; break end
    end
  end
end
-- A side-by-side stop fires when our playhead reaches the leader's stop position, on two readings in a row: the
-- play position can read a few hundred ms off for a moment (seen on the laptop: 6.418 -> 6.112 -> 6.446 in 2 ms).
local past = 0
local function reached(t, theirs)
  if not (t.type == "stop" and t.follow and theirs and t.pos and reaper.GetPlayStateEx(proj) & 1 == 1) then past = 0; return false end
  local hit
  past, hit = together.count_reading(past, reaper.GetPlayPosition2Ex(proj), t.pos)
  return hit
end
local b = band.binding(proj)
if not b then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
cfg = band.for_tab(cfg, b) -- (this tab's own band, whichever band this computer is working in now)
require("sync").current_song = b.song -- (whose notices these are: a tab's own)
band.WHO = "live " .. b.song -- (which script a line in the log file came from)
if not b.root then reaper.SetProjExtState(proj, band.SECTION, "root", cfg.root); b.root = cfg.root end -- (a tab from before bands: its band, from now on)
-- one Live sync per song tab: triggering this action again while it runs does nothing (no "terminate instances?"
-- box); another tab's runs from a launcher action of its own (band.start_live), and starting it again for this tab
-- only says so
if reaper.set_action_options then reaper.set_action_options(2) end
local beat0 = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
if beat0 and reaper.time_precise() - beat0 < 5 then return band.log("Live sync is already running for '" .. b.song .. "'") end
if band.synced_elsewhere(proj) then
  return band.log("'" .. b.song .. "' is already syncing in another tab: work there (this tab is a second copy of the project, and isn't synced)")
end
-- One REAPER per song and room on this computer (review, 0.59.18: the same song open in two REAPERs synced from both, each taking the
-- other's changes for its own). Each REAPER has an id for its session (ExtState "instance id", not persisted: one per process), and the
-- REAPER syncing a song keeps <home>/locks/<song> <room>.json fresh. Another REAPER's fresh lock: not here, and Autostart is told why.
-- (here, with the other refusals: before anything is set up or written for the song. 0.59.19)
local instance = reaper.GetExtState(band.SECTION, "instance id")
if instance == "" then instance = string.format("%d-%d", os.time(), math.random(1, 1e9)); reaper.SetExtState(band.SECTION, "instance id", instance, false) end
local lock_file = band.home() .. "/locks/" .. (b.song .. " " .. b.room):gsub("[^%w%-_ ]", "_") .. ".json"
do
  local lk = band.read_json(lock_file)
  if type(lk) == "table" and lk.instance ~= instance and tonumber(lk.at) and os.time() - tonumber(lk.at) < 20 then
    reaper.SetExtState(band.SECTION, "elsewhere " .. tostring(proj), tostring(reaper.time_precise()), false)
    return band.log("'" .. b.song .. "' is syncing in another REAPER on this computer: work there, or close it there first. This one doesn't sync it")
  end
  reaper.DeleteExtState(band.SECTION, "elsewhere " .. tostring(proj), false)
end
local lock_at = -math.huge
local function keep_lock()
  if reaper.time_precise() - lock_at < 5 then return end
  lock_at = reaper.time_precise()
  reaper.RecursiveCreateDirectory(band.home() .. "/locks", 0)
  pcall(band.write_json, lock_file, { instance = instance, at = os.time() })
end
-- the newest Live sync for a tab owns it: while a dialog is open every script pauses, its heartbeat goes stale, and
-- Autostart may start another one for the tab; when the dialog closes the older one sees it was replaced and stops
-- (2026-10-29, laptop: tabs could end up with two Live syncs after a long dialog)
local my_token = string.format("%.6f-%d", reaper.time_precise(), math.random(1, 1e9))
reaper.SetExtState(band.SECTION, "live owner " .. tostring(proj), my_token, false)
local host = b.role == "host"
band.try("songsync.want", require("songsync").want, cfg, b.song) -- (a song syncing in a tab here comes in full: per-song sync)
band.try("band.stay_online", band.stay_online)
local s0 = band.read_json(band.session_path(cfg, b.song)) or {}
-- Is this binding still this session's? REAPER opens another project into the same tab and keeps its pointer, so a different song, room or
-- studio can be in `proj` now. (Raw roots compared first: same_studio only when they differ, as this runs every tick.) Round 4 review, 0.59.49
local function same_session(now_b)
  return now_b ~= nil and now_b.role == b.role and now_b.song == b.song and now_b.room == b.room
    and (now_b.root == b.root or band.same_studio(now_b.root, b.root))
end
local function still_ours() return reaper.ValidatePtr2(0, proj, "ReaProject*") and same_session(band.binding(proj)) end
-- (no take baseline: the old take sync's send half is gone, and nothing read it. Round 1 review, 0.59.45)
sync.audio_follow_tempo(proj) -- band audio follows tempo changes piece by piece (REAPER auto-stretch), never drifting

-- Side by side (panel, Together): press play/stop/record as usual; every machine with it on follows, `lag`
-- seconds behind whoever pressed (0 with Listen live; a bar or two with Play along, so you hear them in time with
-- the song). Non-persistent ExtState "side <proj>" = lag in bars ("" = off).
local side = { playing = false, pos = 0, t = 0, quiet_until = 0 }
local function side_bars()
  local v = select(2, reaper.GetProjExtState(proj, band.SECTION, "side")) -- saved with the song: a reopened tab keeps it
  local old = reaper.GetExtState(band.SECTION, "side " .. tostring(proj)) -- (set per tab before 0.11.3: carried over once)
  if old ~= "" then
    reaper.DeleteExtState(band.SECTION, "side " .. tostring(proj), false)
    if v == "" then v = old; reaper.SetProjExtState(proj, band.SECTION, "side", old) end
  end
  return v ~= "" and (tonumber(v) or 0) or nil
end
-- A count-in click: the metronome on until the song reaches `upto` (then back as it was).
local click
local function click_until(upto)
  if reaper.GetToggleCommandStateEx(0, 40364) ~= 1 then
    reaper.Main_OnCommand(40364, 0) -- Options: Toggle metronome
    click = upto
  end
end


-- the shared folder only moves while Syncthing runs: start it if it isn't (a cloud-drive root needs nothing)
local tune_left, tune_at = 0, 0 -- the folder's live-use settings, tried again while a Syncthing we just started comes up
local st_started -- when we started Syncthing: a fresh look 20 s on says whether it really runs
for _, d in ipairs(band.subdirs(cfg.root)) do
  if d == ".stfolder" then -- Syncthing marks the folders it shares with this
    local services = require("services")
    local ok, why = services.ensure_syncthing()
    if ok == "started" then band.log("started Syncthing"); st_started = reaper.time_precise() elseif not ok then band.log("Syncthing: " .. why) end
    -- (tuned once per REAPER session per folder, not at every tab's start and every update's reload of each: up to a dozen Syncthing calls
    -- of up to 8 s each, with REAPER waiting. Syncthing keeps what's set. A stamp that isn't kept between sessions. 0.59.14, review)
    local tuned_key = "syncthing tuned " .. tostring(band.info(cfg.root).id)
    if ok and reaper.GetExtState(band.SECTION, tuned_key) == "" then -- quick hand-off for live use (lib/services.lua): the live MIDI view a couple of seconds behind
      local set, err = services.tune_band_folder(band.info(cfg.root).id)
      if set then reaper.SetExtState(band.SECTION, tuned_key, "1", false) end
      if set and #set > 0 then band.log("Syncthing's studio folder tuned for live use: " .. table.concat(set, ", "))
      elseif not set then
        -- just started, it doesn't answer for a few seconds (2026-10-29, laptop): try again for a few minutes
        tune_left, tune_at = 10, reaper.time_precise()
        if ok ~= "started" then band.log("Syncthing: " .. tostring(err)) end
      end
    end
  end
end

-- which plug-ins this machine has goes to the band, and the FX browser's "StudioSync (everyone has)" folder follows
-- what everyone has (lib/plugins.lua); a failure here must never stop syncing
-- (once per REAPER session per studio: every tab's start, and every update's reload of each, went through the ~1,100 installed plug-ins twice
-- and rewrote the FX browser's files. Until the folder is made (lists still to come), each start tries again; the panel's "Update the folder
-- now" does it any time. A stamp that isn't kept between sessions. 0.59.14, review)
local plugins_key = "plugins done " .. cfg.root
if reaper.GetExtState(band.SECTION, plugins_key) == "" then
  local plugins = require("plugins")
  local ok, n, why = pcall(function() plugins.publish(cfg); return plugins.update_folder(cfg) end)
  if ok and n then reaper.SetExtState(band.SECTION, plugins_key, "1", false) end
  if ok and n then band.log(string.format("%d plug-ins everyone in the studio has: FX browser folder '%s'", n, plugins.FOLDER))
  elseif not ok then band.log("plug-in list: " .. tostring(n)) end
end

local _, _, section, cmd = reaper.get_action_context()
local function toggle(v)
  if cmd > 0 then reaper.SetToggleCommandState(section, cmd, v); reaper.RefreshToolbar2(section, cmd) end
end
toggle(1)

-- End of session: a restore point kept for good (Empty old trash never removes its audio), so the band's history
-- shows where every session ended. Saved when Live sync stops and after 20 minutes without a change (REAPER might
-- be closed hard), only when something changed since the last one.
local recall = require("recall")
local function event_count() return #band.listing(sync.room_dir(cfg, b.song, b.room) .. "/events", ".json") end -- (shared, unsorted: 0.59.14, review)
local ended_at_n = reload_ended or event_count() -- (after an update's reload, the count the session had: no end-of-session save was made. 0.58.92)
local quiet = { n = ended_at_n, since = reaper.time_precise(), checked = 0 }
local function end_of_session(why)
  local n = event_count()
  if n == ended_at_n or not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end
  -- (20 quiet minutes isn't the end of anything: it looked like one in the middle of a session, first in the list: laptop, 0.42.5)
  recall.save(proj, cfg, b.song, b.room, why:find("20 minutes", 1, true) and "20 quiet minutes" or "end of session", true)
  ended_at_n = n -- (only once it's saved: marked first, a failed save was never tried again. Round 1 review, 0.59.45)
  band.log("saved an end-of-session version (" .. why .. "): it's kept for good (Restore > Saved versions)")
  local droot = require("drive").root(cfg) -- and the project itself, for anyone to open from Drive (lib/sessionfile.lua)
  if droot then
    local ok, out, err = pcall(require("sessionfile").export, proj, cfg, b, droot, sync.room_dir(cfg, b.song, b.room))
    local dname = require("drive").label(require("drive").service_of(droot)) -- (not always Google Drive: Round 1 review, 0.59.45)
    band.log(ok and out and ("end-of-session project saved to " .. dname .. ": " .. out:match("[^/]+$")) or
      ("couldn't save the end-of-session project to " .. dname .. ": " .. tostring(ok and err or out)))
  end
  -- history older than 60 days that nothing needs (lib/trim.lua): the room's driver trims it, at most once a day,
  -- right after this kept version is saved
  local key = "trimmed " .. b.song .. "/" .. b.room
  -- (in 20 quiet minutes only: it reads every change the room has, and on the way out REAPER hung on closing. Review, 0.58.92)
  if why:find("20 minutes", 1, true) and sync.driver(cfg, b.song, b.room, s0) == cfg.user and reaper.GetExtState(band.SECTION, key) ~= os.date("!%Y-%m-%d") then
    reaper.SetExtState(band.SECTION, key, os.date("!%Y-%m-%d"), true)
    local ok, gone = pcall(require("trim").run, cfg, b.song, b.room)
    if ok and gone > 0 then band.log(string.format("trimmed %d change(s) older than 60 days that no saved version needs (kept in 'StudioSync history archive')", gone))
    elseif not ok then band.log("couldn't trim old history: " .. tostring(gone)) end
  end
end
local reloaded -- this instance handed over to the updated code (which saves the end of session itself)
-- The studio's debug mode (lib/debugmode.lua) collects this project, telling the person first; a failure is logged. (Round 1 review, 0.59.45)
local function debug_collect(why) band.try("debugmode.collect", require("debugmode").collect, cfg, proj, b, why) end
-- Work only this computer has in this tab: unsent changes, items held back, or your own tracks with something on them (Delete my copy leaves
-- the project's folder alone while any room of the song has some: lib/localcopy.lua).
local function own_work()
  local mirror = require("mirror")
  local key = tostring(proj)
  for k in pairs(mirror.unsent) do if k:sub(1, #key) == key then return true end end
  if next(mirror.held_back and mirror.held_back[key] or {}) ~= nil then return true end
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local tag = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "", false))
    if (tag == "kept" or tag == "yours") and reaper.CountTrackMediaItems(tr) > 0 then return true end
  end
  return false
end
-- This tab's room on the song's "local work" mark (kept between sessions), or off it (live.mark_room. Round 3 review, 0.59.48)
local function mark_room(on)
  local k = band.local_work_key(cfg.root, b.song)
  local v = live.mark_room(reaper.GetExtState(band.SECTION, k), b.room, on)
  if v == "" then reaper.DeleteExtState(band.SECTION, k, true) elseif v then reaper.SetExtState(band.SECTION, k, v, true) end
end
reaper.atexit(function()
  if click and reaper.GetToggleCommandStateEx(0, 40364) == 1 then reaper.Main_OnCommand(40364, 0) end -- (stopped mid count-in: the click left on. 0.58.92)
  -- (only while the tab still holds this session: another project opened into it was saved as this song's "end of session" version, exported
  -- with its media to the studio's cloud drive, and read for the local-work mark. Otherwise the last look's answer, and nothing saved.
  -- Round 4 review, 0.59.49)
  local ok_ours, ours = band.try("still_ours", still_ours)
  ours = ok_ours and ours
  if not reloaded and ours then band.try("end_of_session", end_of_session, "Live sync stopped") end -- (logged when it fails: Round 1 review, 0.59.45)
  if not reloaded then
    -- (this tab's room taken off the "local work" mark only when a look ran and a last check, now, finds nothing: a take recorded since the last
    -- look was missed, and Delete my copy then binned the folder holding its only copy. Round 3 review, 0.59.48)
    local own = sync.local_work
    if own ~= nil and ours then
      local ok, now_own = band.try("own_work", own_work)
      own = not ok or now_own
    end
    if own ~= nil then band.try("mark_room", mark_room, own) end
    -- (and its unsent list keeps only what still differs from its known state: Restore, Undo and the panel's other protections go on covering
    -- held edits still in the project, and Bring into main stops waiting on the rest. All of it goes when the tab holds something else now.
    -- James, Round 4 review, 0.59.49)
    local key = "unsent " .. tostring(proj)
    local ids = ours and reaper.GetExtState(band.SECTION, key) or ""
    reaper.DeleteExtState(band.SECTION, key, false)
    if ids ~= "" then
      local ok, kept = band.try("still_unsent", live.still_unsent, proj, ids, require("mirror"), sync.room_dir(cfg, b.song, b.room) .. "/media", sync.local_mix)
      if ok and kept ~= "" then reaper.SetExtState(band.SECTION, key, kept, false) end
      if not ok then reaper.SetExtState(band.SECTION, key, ids, false) end -- (couldn't tell: all kept, the safe side)
    end
  end
  if not reloaded and ours then debug_collect("end of session") end
  -- (this REAPER's lock for the song goes with it: restarted within 20 s, the new REAPER read it as another one syncing the song and waited
  -- two minutes, saying so. Chilio's Mac, 0.59.29)
  if not reloaded then
    local lk = band.read_json(lock_file)
    if type(lk) == "table" and lk.instance == instance then os.remove(lock_file) end
  end
  -- (the studio's shared preferences out, yours back: unless another song is in front, whose Live sync goes on, or this one reloads. James, rt)
  if not reloaded then
    local front = reaper.EnumProjects(-1)
    if front == proj or not (front and band.binding(front)) then band.try("shared prefs", require("sharedprefs").tick, nil, true) end
  end
  toggle(0)
end)

-- Google Drive copy of the room (lib/drive.lua): what we did alone reaches the band whenever they next open the
-- song, and what they did alone reaches us. A pass every 3 minutes (sooner while a big copy is still going), only
-- while stopped: copying a long FLAC can hold up REAPER's screen for a moment.
local drive = require("drive")
local drive_at, drive_more, drive_said = -math.huge, false, nil
local drive_posted, drive_soon_at = 0, nil -- (changes seen going out; when the cloud pass they bring is due)

local last, recording, stopped_at = 0, false, 0
local status_info -- (the status as last written: tick_body says "recording" with it, as the pass that writes it waits while recording)
local paint_at = -math.huge -- when tracks were last coloured for who's working on them
local format_at = -math.huge -- when the recording format was last checked
local followed = false -- someone follows this computer: its mix goes in the status (lib/presence.lua)
-- (opening it: its first catch-up goes faster, then its peaks. lib/sync.lua. Published as "loading <proj>" now, not at the first receive: a panel
-- save in between was mapped though still behind. Round 4 review, 0.59.49)
if sync.begin_loading then sync.begin_loading(proj) else sync.loading[tostring(proj)] = true end
local claims_at = -math.huge -- when our claims on gone tracks were last looked for (sync.drop_gone_claims)
local last_status, status_json = 0, ""
local rt_at = 0 -- when Real time mode's sends were last matched to what's armed
local heal_since, healed_at = nil, -math.huge -- since when a caught-up bandmate's project has differed (mirror.heal)
local mirror_took = 0 -- how long the last full look took
local mirror_cc, mirror_at, mirror_due = -1, -math.huge, false -- the project's change count at the last full look, and when

local last_driver
local drawings_at = -math.huge -- (when this last looked whether the room has drawings to show)
local inbox_at = -math.huge -- (and the song's inbox for dropped audio)
-- Where a tick's time goes, part by part: the last tick over 0.15 s is kept in "slow tick <proj>" (not saved), to find what holds REAPER up on a big song
local laps, lap_t = {}, 0
local function lap(name) local t = reaper.time_precise(); laps[#laps + 1] = string.format("%s %.0f", name, (t - lap_t) * 1000); lap_t = t end
-- Tick timings for tests/reaper/rt_perf.lua (James, rt: before and after an efficiency pass, on each computer): collected only while ExtState
-- "perf stats" is "1" (looked at every 10 s), and published every 10 s as "tick stats <proj>". Off, it costs one comparison a tick.
local perf = { on = false, at = -math.huge, ticks = {}, passes = {}, worst = 0, worst_laps = "" }
local last_session -- a session.json caught mid-sync reads as nothing: keep the last good one
local joined = {} -- machines this Live sync has already let in
-- Are we in the middle of editing? (the project changed in the last 2 s, or the mouse button is down): the band's
-- changes wait for a pause, so none lands mid-drag. Never more than 10 s, so a long edit can't hold them up for good.
-- (A drag counts as no change until the drop: laptop, 2026-10-31, a band change applied 2 s into a drag undid it.)
local function mouse_down() return reaper.JS_Mouse_GetState ~= nil and reaper.JS_Mouse_GetState(1) & 1 == 1 end
local change_count, changed_at, held_since = -1, -math.huge, nil
local direct_in_at = -math.huge -- (when an event file last came over the direct link: the quiet window is 0.4 s then. James, rt)
local direct_held = false -- (one came over the link and no receive has run since: a pass as the quiet window ends, sync.receive_now. James, rt)
local polled_at, pass_took = -math.huge, 0 -- (when the last pass started, and how long it took: sync.look_now. James, rt)
-- Only your edits count: noted at the start of each tick, and whatever the tick itself changed (looks, receives, heal, prints attaching,
-- paint) taken in at its end. Nothing else runs in between, so a count that moved meanwhile was StudioSync's. (Noted only in receive, any
-- write of ours since the last look read as "you editing" and held a direct-link change 2 s. James, rt)
local function note_change()
  local c = reaper.GetProjectStateChangeCount(proj)
  if c ~= change_count then change_count, changed_at = c, reaper.time_precise() end
end
local function took_in() change_count = reaper.GetProjectStateChangeCount(proj) end
local function editing()
  local busy
  busy, held_since = sync.editing_now(reaper.time_precise(), changed_at, held_since, sync.quiet_for(reaper.time_precise(), direct_in_at), mouse_down())
  return busy
end
-- Something to redo (you just pressed undo): the band's changes wait up to 30 s, as any undo point of theirs would
-- take your redo away (laptop, block K: Ctrl+Z, then Ctrl+Shift+Z did nothing). A new action of yours ends the wait.
local redo_seen, redo_at = nil, 0
local undo_top = reaper.Undo_CanRedo2(proj) -- what was on top of REAPER's redo list at the last look
local function redo_pending()
  local r = reaper.Undo_CanRedo2(proj)
  if r ~= redo_seen then redo_seen, redo_at = r, reaper.time_precise() end
  return r ~= nil and reaper.time_precise() - redo_at < 30
end

-- poll's parts (split, 0.59.40), in the order a pass runs them. t: what this pass worked out about the session (P.who) and
-- the rooms it takes changes from (P.receive).
local P = {}
function P.syncthing()
  if st_started and reaper.time_precise() - st_started > 20 then
    st_started = nil
    if not require("services").running("syncthing", true) then
      band.log("Syncthing didn't start, so nothing reaches the studio or comes in: start Syncthing yourself (Start menu, or its tray icon), " ..
        "then Live sync carries on by itself")
    end
  end
  if tune_left > 0 and reaper.time_precise() - tune_at > 30 then
    tune_left, tune_at = tune_left - 1, reaper.time_precise()
    local set, err = require("services").tune_band_folder(band.info(cfg.root).id)
    if set then
      reaper.SetExtState(band.SECTION, "syncthing tuned " .. tostring(band.info(cfg.root).id), "1", false) -- (once a session: see the start)
      tune_left = 0
      band.log(#set > 0 and ("Syncthing's studio folder tuned for live use: " .. table.concat(set, ", ")) or "Syncthing is answering")
    elseif tune_left == 0 then
      band.log("Syncthing: " .. tostring(err) .. " (" .. live.PLACES.health .. " shows whether the shared folder syncs)")
    end
  end
end
function P.who(t)
  local s = band.read_json(band.session_path(cfg, b.song)) or last_session
  last_session = s
  local can, who = sync.authority(cfg, b.song, b.room, s)
  local driver = who.driver
  -- someone else drives and is here (their status receipt is fresh): then the room's mode decides what we may change
  sync.driver_name, sync.room_mode = driver, who.mode -- (put-back messages say who and why)
  -- Alone = full control: with no bandmate in the room, everything we change goes out, whoever drives or claimed it
  -- (what Solo edit was for, without a separate copy of the song). Once anyone is here, the band's rules are back.
  -- (gone for 90 s before you're alone, back at once: a dialog left open on their machine pauses its status for a
  -- while, and each pause handed the laptop full control for a moment, 2026-10-31)
  local others = sync.present(cfg, b.song, b.room, sync.alone and 45 or 90)
  local alone = #others == 0
  if alone ~= sync.alone then
    if alone or sync.alone ~= nil then
      band.log(alone and "nobody else is here: you have full control (what you change still goes to the others, and reaches them when they're back)"
        or (table.concat(others, ", ") .. " joined: the studio's rules are back (" .. tostring(driver) .. " drives)"))
    end
    sync.alone = alone
    reaper.SetExtState(band.SECTION, "alone " .. tostring(proj), alone and "1" or "", false)
  end
  local my_can = alone and function() return true end or can
  -- the driver stepped away while others are still here: say so once (anyone here can Take control; the panel shows it)
  local driver_away = not alone and driver and driver ~= cfg.user
  if driver_away then for _, o in ipairs(others) do if o == driver then driver_away = false end end end
  -- (given a moment: everyone leaving together read "anyone can Take control", then at once "you have full control": Mac, 0.58.5)
  sync.away_at = driver_away and (sync.away_at or reaper.time_precise()) or nil
  if driver_away and reaper.time_precise() - sync.away_at < 10 then driver_away = sync.driver_away end
  if driver_away ~= sync.driver_away then
    if driver_away then band.log(tostring(driver) .. " is driving but isn't here" .. live.driving(who.mode).away .. " (Take control: StudioSync panel, Home)") end
    sync.driver_away = driver_away
    reaper.SetExtState(band.SECTION, "driver_away " .. tostring(proj), driver_away and tostring(driver) or "", false)
  end
  if last_driver and driver ~= last_driver then pcall(require("api").event, "driver", { from = last_driver, to = driver, song = b.song }) end -- (the API: lib/api.lua)
  if last_driver and driver ~= last_driver then -- handovers are announced, never silent
    band.log(driver == cfg.user and "you're driving now" or (tostring(driver) .. " is driving now" ..
      (last_driver == cfg.user and (": you're no longer driving (" .. live.driving(who.mode).lost .. ")") or ""))) -- (by mode: Round 1 review, 0.59.45)
  end
  last_driver = driver
  -- Hold sync: keep working without sending anything; releasing it sends the net result once
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
  sync.timeline_mine = my_can(cfg.user, nil, nil) and not hold -- (may a Link app's tempo become the song's: lib/ablink.lua. James, rt)
  -- the API (lib/api.lua): the state for other scripts, and what changed since the last look
  pcall(function()
    local api = require("api")
    local was = sync.api_seen or {}
    local now_here = {}
    for _, o in ipairs(others) do now_here[o] = true end
    if sync.api_seen then
      local joined, left = {}, {}
      for o in pairs(now_here) do if not was[o] then joined[#joined + 1] = o end end
      for o in pairs(was) do if not now_here[o] then left[#left + 1] = o end end
      if #joined + #left > 0 then api.event("people", { joined = joined, left = left, song = b.song }) end
      if hold ~= sync.api_hold then api.event("hold", { on = hold, song = b.song }) end
    end
    sync.api_seen, sync.api_hold = now_here, hold
    api.publish(proj, { song = b.song, room = b.room, me = cfg.user, driver = driver, mode = who.mode, alone = alone, others = others, tracks = who.tracks,
      hold = hold, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1", held = reaper.GetExtState(band.SECTION, "held " .. tostring(proj)) })
  end)
  t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold = s, can, who, driver, others, alone, my_can, hold
end
function P.look(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  -- mirror sync (docs/mirror-design.md): the whole project travels object by object. What changed here goes out
  -- before the band's changes come in, so an edit still unsent is never overwritten unseen
  sync.local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
  if not (s and s.sync == "mirror") then -- made with the older take sync: left alone until it's published again
    if not sync.old_said then sync.old_said = true; band.log("'" .. b.song .. "' was made with an older StudioSync: publish it again (StudioSync - Publish session) to sync it") end
  else
    if not hold then
      local tok, terr = pcall(sync.watch_timeline, proj, cfg, b.song, b.room, my_can) -- (before the items: a tempo change moves them)
      if not tok then band.log("tempo/markers: " .. tostring(terr)) end
    end
    lap("timeline")
    -- (with Hold my changes on, the look still runs, sending nothing: it marks what you changed, so the band's
    -- changes to those wait for yours instead of replacing them; mirror.unsent)
    -- a full look reads every track and item: only when REAPER says the project changed, or the band's changes just
    -- came in, and at least every 10 s anyway (anything REAPER doesn't count as a change still gets seen)
    local cc = reaper.GetProjectStateChangeCount(proj)
    -- (not mid-drag: watch would skip it, and the change it skipped mustn't count as seen)
    -- (every second while a print renders in the background: it goes in once done, not up to 10 s later: laptop, 0.40.0)
    -- (and no oftener than a look's own time allows: at 2000 items each takes 1 s, which would be REAPER's whole time)
    local waiting = now - mirror_at > math.max(1, mirror_took * 5) and (require("bgrender").waiting() or require("prints").waiting() or require("mirror").unsettled) -- (or a part waiting its turn, or a plug-in chain to settle)
    -- (at 3,000 items a look holds REAPER up for over a second, even with nothing happening: at most a fifth of its time, unless there's more to send)
    local room_to_look = mirror_due or now - mirror_at > mirror_took * 5
    -- (the look nothing asked for, for what REAPER doesn't count: further apart on a big song, where each holds REAPER up longer)
    if room_to_look and (cc ~= mirror_cc or mirror_due or waiting or now - mirror_at > math.max(10, mirror_took * 60)) and not mouse_down() then
      local presence = require("presence")
      local held = function(oid) return presence.holder(presence.peers(cfg, b.song, b.room), oid) end -- (edit holds)
      local here = {} -- (bandmates in the song now: one of them may print what its author can't, lib/prints.lua)
      for _, st in ipairs(presence.peers(cfg, b.song, b.room)) do here[st.user] = true end
      local ok, sent = pcall(require("mirror").watch, proj, cfg, b.song, b.room, { can = my_can, owner_can = can, mode = who.mode, local_mix = sync.local_mix, is_claimed = who.is_claimed, owner_of = who.owner_of,
        held = held, hold = hold, here = here, printers = who.printers })
      if not ok then band.log("mirror sync: " .. tostring(sent))
      elseif sent > 0 then band.log(sent .. " change(s) went to " .. (b.room == "main" and "the others" or ("the room '" .. b.room .. "'"))); pcall(require("api").event, "sent", { n = sent, song = b.song, room = b.room }) end
      mirror_took = reaper.time_precise() - now
      -- (the look's own writes aren't you editing: the tick takes them in at its end, took_in. Round 1 review, 0.59.45; James, rt)
      mirror_cc, mirror_at, mirror_due = reaper.GetProjectStateChangeCount(proj), now, false
      local mirror = require("mirror")
      local n, key, ids = 0, tostring(proj), {}
      for k in pairs(mirror.unsent) do if k:sub(1, #key) == key then n = n + 1; ids[n] = k:sub(#key + 1) end end
      if hold then reaper.SetExtState(band.SECTION, "held " .. key, tostring(n), false) end -- (how many are waiting, for the panel's "Holding N changes")
      -- (this tab's unsent objects, for Restore, Undo and Bring into main, which run in the panel or the Undo script: mirror.edited_here couldn't see
      -- an unsent plug-in chain or automation there, and went over them. Written when the set changes. Round 2 review, 0.59.46)
      table.sort(ids)
      local unsent_ids = table.concat(ids, ",")
      if unsent_ids ~= sync.unsent_said then sync.unsent_said = unsent_ids; reaper.SetExtState(band.SECTION, "unsent " .. key, unsent_ids, false) end
      require("leave").mine_went_out(sync.autosave, ok and sent or 0, n) -- (something of yours: no auto-save over it, P.receive)
      -- Delete my copy leaves this project's folder alone while it holds work only this computer has (unsent changes, items held back, or your own
      -- tracks with something on them): lib/localcopy.lua reads this. Kept between sessions: set the first time there's such work, taken away only
      -- when this room's Live sync stops with none (at exit), so a song not opened since a restart is covered too. (Round 1 review, 0.59.45;
      -- persisted, Round 2 review, 0.59.46; per room, Round 3 review, 0.59.48: own_work, mark_room)
      local own = n > 0 or own_work()
      sync.local_work = own
      if own then mark_room(true) end
      lap("look")
    end
  end
end
function P.outbox_inbox(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  do -- Sync and exit (lib/leave.lua): what's still waiting to go out, and a kept version of the session when it asks
    local leaving = reaper.GetExtState(band.SECTION, "end session " .. tostring(proj))
    if leaving ~= "" then
      reaper.DeleteExtState(band.SECTION, "end session " .. tostring(proj), false)
      band.try("end_of_session", end_of_session, leaving)
      debug_collect("sync and exit")
      mirror_due = true
    end
    local mirror = require("mirror")
    local more = mirror.more and "changes" or require("bgrender").waiting() and "prints rendering" or require("prints").waiting() and "prints waiting" or nil
    -- (and what waits its turn: a big recording still copying into the studio's folder, plug-ins or automation settling, a copy that failed.
    -- Sync and exit said "safe to close up" over a take that was only on this computer. Not what Hold my changes keeps. Full review, 0.59.44)
    more = more or mirror.waiting(tostring(proj), hold) -- (one rule, held-back copies included: Round 1 review, 0.59.45)
    band.set_ext_json(band.SECTION, "outbox " .. tostring(proj), { at = mirror_at, more = more }, false)
  end
  -- what's drawn in a room shows without anyone asking, unless this person hid them: nobody would see a drawing until they
  -- pressed Show drawings on the Chat page (James, 2026-11-02: "other people can see the drawings too, right?")
  if now - drawings_at > 10 and reaper.GetExtState(band.SECTION, "draw hidden") == "" and reaper.JS_Window_FindChildByID and reaper.APIExists("ImGui_GetBuiltinPath") then
    drawings_at = now
    if band.files(sync.room_dir(cfg, b.song, b.room) .. "/drawings", ".json")[1] then band.start_draw(dir) end
  end
  -- audio dropped into <Song>/inbox from anywhere goes into the song, on one computer only: the driver's, or yours when you're alone (lib/extras.lua)
  if now - inbox_at > 10 and not hold and b.room == "main" and (driver == cfg.user or alone) and s and s.sync == "mirror" then
    inbox_at = now
    local iok, put = pcall(require("extras").inbox, proj, cfg, b)
    if not iok then band.log("inbox: " .. tostring(put))
    elseif #put > 0 then band.log("from the song's inbox: " .. table.concat(put, ", ") .. " (it goes to everyone like any change)"); mirror_due = true end
  end

  do -- (a suggestion arrived or was answered: lib/suggest.lua)
    local nok, nerr = pcall(require("suggest").notices, proj, cfg, sync.room_dir(cfg, b.song, b.room))
    if not nok then band.log("suggestions: " .. tostring(nerr)) end
  end
end
function P.receive(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  -- the host's project gathers the rooms bandmates record into (StudioSync before side rooms), never a side room:
  -- that's its own tab, brought in when someone chooses to (lib/rooms.lua)
  local rooms = { b.room }
  if host then
    rooms = {}
    for _, r in ipairs(require("rooms").list(cfg, b.song)) do if not r.parent then rooms[#rooms + 1] = r.name end end
  end
  for _, room in ipairs(rooms) do
    local room_can = room == b.room and can or sync.authority(cfg, b.song, room, s)
    local n = 0
    -- (and not before the look has seen your last change: sync.seen_mine)
    -- (not before this tab's first look: with the mouse held on the first pass, the band's changes landed over edits not yet marked
    -- as ours. Review, 0.58.87)
    local dirty = false
    if (mirror_at > -math.huge or not (s and s.sync == "mirror")) and sync.seen_mine(reaper.GetProjectStateChangeCount(proj), mirror_cc, now, mirror_at) and not editing() and not redo_pending() then
      dirty = reaper.IsProjectDirty(proj) ~= 0
      n = sync.receive(proj, cfg, b.song, room, room_can)
      direct_held = false
      -- (receive's own changes aren't you editing: the tick takes them in at its end, took_in. Round 1 review, 0.59.45; James, rt)
    end
    -- a lot came in and it's over: saved, so the next open starts from here and doesn't take it all in again with REAPER held up; only when
    -- nothing unsaved was yours before it came (James, Round 1 review, 0.59.45: lib/leave.lua leave.autosave)
    if require("leave").autosave(sync.autosave, n, dirty, reaper.GetPlayStateEx(proj) == 0) then sync.need_save = true end
    if n > 0 then band.log(string.format("%d change%s from the others (%s)", n, n == 1 and "" or "s", room)); mirror_due = true; pcall(require("api").event, "received", { n = n, song = b.song, room = room }) end
  end
  lap("receive")
  t.rooms = rooms
end
function P.heal(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  -- a bandmate who has every change has had a different project from ours for a minute, and we're caught up too:
  -- something never landed here. Bring it in line with the band's newest version (at most every 5 minutes).
  if s and s.sync == "mirror" and not hold then
    local mine, differs, same = require("mirror").root(proj), false, false
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do
      if st.mirror and st.pending == 0 and st.mirror ~= mine then differs = true end
      if st.mirror and st.pending == 0 and st.mirror == mine then same = true end
    end
    -- the same project as everyone again: an old "came out different" is history, not news (it kept Health red after
    -- the Mac matched: 0.34.4)
    if same and not differs and reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj)) ~= "" then
      reaper.DeleteExtState(band.SECTION, "mirror drift " .. tostring(proj), false)
      reaper.DeleteExtState(band.SECTION, "mirror drift last", false)
    end
    if differs and sync.pending_events(proj, cfg, b.song, b.room) == 0 then heal_since = heal_since or now else heal_since = nil end
    if now - claims_at > 10 then claims_at = now; pcall(sync.drop_gone_claims, proj, cfg, b.song, b.room) end
    if heal_since and now - heal_since > 60 and now - healed_at > 300 and reaper.EnumProjects(-1) == proj then
      healed_at, heal_since = now, nil
      local ok, n = pcall(require("mirror").heal, proj, sync.room_dir(cfg, b.song, b.room), sync.local_mix)
      if not ok then band.log("couldn't bring the project in line with the studio: " .. tostring(n))
      elseif n > 0 then band.log(string.format("caught up on %d change%s that hadn't arrived here", n, n == 1 and "" or "s")); mirror_due = true end
    end
  end

  lap("in line")
end
function P.joins(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  -- new band machines: on the host of a computer in one band, a machine asking over the band's Tailscale (only band
  -- machines are on it) is let in at once; with several bands, never on its own. The rest ask in the panel (tools.join_requests).
  -- (and only while this computer is on the studio's own Tailscale network: switched to another one, or behind an internet provider's own
  -- 100.64/10 addresses, anyone asking from such an address was let in. Review, 0.59.14)
  local studio_net = host and require("groups").tailnet(cfg.root)
  if host and #band.bands() <= 1 and require("groups").may_manage(cfg.root, cfg.user) and studio_net and studio_net.suffix == select(2, require("services").tailnet_now()) then
    local services = require("services")
    local removal = require("removal")
    for _, d in ipairs(services.pending_devices()) do
      if services.on_tailnet(d.address) and joined[d.id] ~= true and now - (joined[d.id] or -math.huge) > 60 then
        -- (never someone taken out, nor anyone while a guest invitation is open: a guest is on the studio's Tailscale too and was let in here
        -- as a full member, with no end and no project list, and someone removed came straight back. Those ask in the panel. Review, 0.58.92)
        local may, out = removal.may_auto_admit(cfg.root, d.id, os.time())
        if not may then
          joined[d.id] = true
          band.log(string.format("'%s' (%s) is asking to join: let them in from the panel%s", d.name, d.id:sub(1, 7), out and (" (" .. out .. " was taken out)") or ""))
        else
          local ok, why = services.add_device(d.id, d.name, band.info(cfg.root).id)
          joined[d.id] = ok or now -- (a failed add is tried again in a minute, not never)
          if ok then require("access").clear(cfg.root, d.id) end -- (a band computer: no project list from a guest visit before. 0.58.93)
          band.log(ok and string.format("'%s' (%s) joined the studio folder: it asked over the studio's Tailscale", d.name, d.id:sub(1, 7))
            or ("couldn't add '" .. d.name .. "': " .. tostring(why)))
        end
      end
    end
  end
end
function P.live_clips(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  -- live (ReaNINJAM synced mode): received clips land as placeholders until the real takes replace them
  local live_dir = select(2, reaper.GetProjExtState(proj, band.SECTION, "live_dir"))
  if live_dir == "" and reaper.GetProjectName(proj) ~= "" then live_dir = reaper.GetProjectPathEx(proj):gsub("\\", "/") .. "/bandsync_live" end -- set up by hand: the usual place
  -- (not while producing: they're heard live, and a play-through's clips have no take to replace them, so the next pass plays them twice over)
  if live_dir ~= "" and live.fx(proj, false) and not require("producer").who(proj) and reaper.GetExtState(band.SECTION, "produced by " .. tostring(proj)) == "" then
    live.note_clips(proj, live_dir) -- when each clip arrived, so only takes recorded then replace it
    local added, retired = live.place_clips(proj, live_dir), live.retire(proj)
    if added + retired > 0 then reaper.Undo_OnStateChange2(proj, "StudioSync: live placeholders") end -- one undo point, only when something changed
    if added > 0 then band.log(added .. " live clip(s) placed as placeholders") end
    if retired > 0 then band.log(retired .. " placeholder(s) replaced by the real takes") end
  end

  lap("joins, live clips")
end
function P.save_drive(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  if sync.need_save then -- a delete went out: the project is saved, so a crash can't bring the take back here
    sync.need_save = nil
    for i = 0, 512 do
      local p, fn = reaper.EnumProjects(i)
      if not p then break end
      if p == proj and fn ~= "" then -- (an unsaved project would ask where)
        reaper.Main_SaveProject(proj, false)
        -- (said, not silent: a save nobody asked for took "close without saving" away unannounced. Review, 0.58.53)
        band.log("saved the project: a lot of the others' changes came in, so the next open starts from here (every version is on the Restore page)")
      end
    end
  end
  if now - quiet.checked > 60 then
    quiet.checked = now
    band.try("removal.tick", require("removal").tick) -- (Autostart does this too, where it's on)
    band.try("listen.tick", require("listen").tick)
    local n = event_count()
    if n ~= quiet.n then quiet.n, quiet.since = n, now
    elseif now - quiet.since > 1200 then band.try("end_of_session", end_of_session, "20 minutes with no changes") end
  end
  local droot = drive.root(cfg)
  require("streams").cloud_root = droot -- (catch-up asks for a cloud pass when nobody on the link has what Syncthing still needs)
  -- every 3 minutes (each pass while a big copy is still going): Drive limits how often one account may change files. A pass copies for 0.1 s,
  -- and not in a pass that looked: 1.5 s every 10 s held REAPER up that long each time while a big song's room went across (3,150 changes,
  -- 2026-11-10). Half a minute after your changes went out, or when catch-up wants the cloud copy, sooner (drive.pass_due: the cloud copy
  -- as the studio's backup and its always-on member where there's no hub. James, rt)
  if (sync.posted or 0) ~= drive_posted then drive_posted, drive_soon_at = sync.posted or 0, drive_soon_at or (now + drive.SOON) end
  if droot and reaper.GetPlayStateEx(proj) == 0 and mirror_at ~= now and drive.pass_due(now, drive_at, drive_more, drive_soon_at, require("streams").cloud_due) then
    drive_at, drive_soon_at, require("streams").cloud_due = now, nil, nil
    local moved, more, err = 0, false, nil
    for _, room in ipairs(rooms) do
      local ok, n, m = pcall(drive.mirror, sync.room_dir(cfg, b.song, room), droot .. "/" .. b.song .. "/rooms/" .. room, 0.1, cfg.user)
      if ok then moved, more = moved + n, more or m
      else err = tostring(n); if drive_said ~= err then drive_said = err; band.log(drive.label(drive.service_of(droot)) .. " copy: " .. err) end end
    end
    if not more then -- then the other songs here, one a pass: each keeps a copy a bandmate can open from Drive
      local ok, n, m = pcall(drive.upkeep, cfg, droot, require("songsync").here(cfg), b.song, 0.1)
      if ok then moved, more = moved + n, more or m
      else err = tostring(n); if drive_said ~= err then drive_said = err; band.log(drive.label(drive.service_of(droot)) .. " copy: " .. err) end end
    end
    -- (media brought from the cloud copy: Syncthing told at once and its temp download tidied, as for the link's. lib/streams.lua)
    for _, path in ipairs(drive.landed) do
      local s = require("streams")
      s.placed_at[#s.placed_at + 1] = { target = path, size = band.size(path) or -1, at = now }
      band.try("services.rescan", function() require("services").rescan(band.info(cfg.root).id, path:sub(#cfg.root + 2)) end)
    end
    drive.landed = {}
    reaper.SetExtState(band.SECTION, "drive status", band.json_encode({ at = os.time(), moved = moved, more = more or nil, err = err }), false)
    band.try("sessionfile.catch_up", require("sessionfile").catch_up, b.song, 0.1) -- your recordings the end-of-session projects use
    band.try("drive.tools_pass", drive.tools_pass, cfg, droot, now) -- the studio's signed update files, both ways (lib/drive.lua. James, rt)
    -- (the service's own name, not always Google Drive: Round 1 review, 0.59.45. The panel keeps "copy up to date (" out of its toasts)
    if more and not drive_more then band.log(drive.label(drive.service_of(droot)) .. ": bringing the studio's copy of this room up to date (carries on between passes)") end
    if moved > 0 and not more then band.log(string.format("%s copy up to date (%d file%s this pass)", drive.label(drive.service_of(droot)), moved, moved == 1 and "" or "s")) end
    drive_more = more
  end
  lap("save, drive")
end
function P.presence(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  sync.draw_claims(proj, who.times) -- who claimed which stretch of time, as regions (this machine only)
  do -- bandmates' pings show here; following someone keeps the view on theirs (lib/presence.lua)
    local presence = require("presence")
    local peers = presence.peers(cfg, b.song, b.room)
    presence.pings(proj, peers)
    local follow = reaper.GetExtState(band.SECTION, "follow " .. tostring(proj))
    if follow == "" and reaper.GetExtState(band.SECTION, "follow driver") ~= "" and driver ~= cfg.user then follow = driver or "" end
    if follow ~= "" then presence.follow(proj, peers, follow) end
    presence.follow_mix(proj, peers, follow, { cfg = cfg, song = b.song, room = b.room }) -- (and their mix, till you stop: 0.58.82)
    followed = presence.followed(peers, cfg.user, driver)
    -- tracks in the colour of who's working on them, if this machine wants that (lib/people.lua; shown here only)
    if now - paint_at > 1 then paint_at = now; require("people").paint(proj, cfg, peers, who.tracks, b.song .. "/" .. b.room) end
    if now - format_at > 10 and reaper.GetPlayStateEx(proj) == 0 then -- (stopped: not mid-take, nor while playing. Review, 0.58.87) -- (everyone records 24-bit FLAC at the project's rate: lib/prep.lua; never mid-recording)
      format_at = now
      local ok, said = pcall(require("prep").keep_format, proj, cfg, b)
      if ok and said then band.log(said .. " (the studio records the same way on every computer)") end
      -- a new project in the studio's (or its own) look, on the driver's computer only: the rest receive the colours (lib/colours.lua, 0.58.98)
      -- (the driver's, or yours working alone; not while sending is held: a look may be being tried in the panel. Review, 0.58.98)
      if (driver == cfg.user or alone) and not hold then
        pcall(require("colours").auto, proj, cfg, function(name, tr) return my_can(cfg.user, name) or sync.maker_may(require("mirror").track_oid(tr), cfg.user, name, nil, who.mode) end)
      end
    end
  end

  lap("claims, presence")
end
function P.status(t)
  local s, can, who, driver, others, alone, my_can, hold, now, rooms = t.s, t.can, t.who, t.driver, t.others, t.alone, t.my_can, t.hold, t.now, t.rooms
  -- status receipt for the Status window: written when it changes, else every 15 s as a heartbeat
  -- pending + hold let "Take control" wait until everyone has caught up before switching
  local armed = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if require("live").armed(tr) then armed[#armed + 1] = select(2, reaper.GetTrackName(tr)) end
  end
  local info = { driver = driver, role = b.role, song = b.song, hold = hold or nil,
    pending = sync.pending_events(proj, cfg, b.song, b.room), armed = armed, side = side_bars(),
    playing = reaper.GetPlayStateEx(proj) & 1 == 1 or nil, recording = reaper.GetPlayStateEx(proj) & 4 == 4 or nil,
    front = reaper.EnumProjects(-1) == proj, mirror = s and s.sync == "mirror" and require("mirror").root(proj) or nil,
    -- (the view and the cursor only while someone follows you, their one reader (presence.follow): each scroll or click rewrote this file and
    -- Syncthing sent it to everyone. Being followed puts them in at once, as the follower's own status shows it. 0.59.14, review)
    editing = require("presence").editing(proj), view = followed and require("presence").view(proj) or nil, ping = require("presence").my_ping(proj),
    last_track = reaper.GetExtState(band.SECTION, "last_track " .. tostring(proj)), last_at = tonumber(reaper.GetExtState(band.SECTION, "last_at " .. tostring(proj))),
    follow = reaper.GetExtState(band.SECTION, "follow " .. tostring(proj)), follow_driver = reaper.GetExtState(band.SECTION, "follow driver") ~= "" or nil,
    listen = reaper.GetExtState(band.SECTION, "listen " .. tostring(proj)),
    produce = require("producer").who(proj), produce_via = require("producer").who(proj) and require("producer").via(proj) or nil, stamping = reaper.GetExtState(band.SECTION, "stamping " .. tostring(proj)) ~= "" or nil,
    produce_ctl = require("producer").who(proj) and require("producer").ctl(proj) or nil, measure = require("latency").asking(proj),
    lets = require("producer").lets_for(proj) } -- (whoever produces me may start and stop my transport: their panel shows its buttons)
  if info.follow == "" then info.follow = nil end
  if followed then info.mix = require("presence").my_mix(proj) end -- (someone follows you: they hear your mix. lib/presence.lua)
  if followed and not info.playing then info.cursor = math.floor(reaper.GetCursorPositionEx(proj) * 1000 + 0.5) / 1000 end -- (followers' cursors go here: lib/presence.lua)
  -- (what live audio you're in, for the little icons on your card: Real time mode or Time-sync, and the call. James, 0.59.8)
  info.live = live.realtime_on(proj) and "rt" or (live.ninjam_master(proj) and select(2, reaper.GetProjExtState(proj, band.SECTION, "live_mode")) ~= "jam" and "ts") or nil
  info.call = select(2, reaper.GetProjExtState(proj, band.SECTION, "call")) == "1" and (live.sonobus_online(proj)) or nil
  do
    local sm, si = live.fx(proj, false, live.SONOBUS)
    info.rt = sm and not reaper.TrackFX_GetOffline(sm, si) or nil
    if info.rt then -- (which SonoBus group, and who you can't hear: lib/hear.lua hear.check, on their computers)
      local g, who = reaper.GetExtState(band.SECTION, "rt group " .. tostring(proj)), reaper.GetExtState(band.SECTION, "rt silent who " .. tostring(proj))
      if g ~= "" then info.rt = g end
      if who ~= "" then info.rt_silent = who end
    end
  end
  if info.listen == "" then info.listen = nil end
  -- (every field, keys sorted: a hand-made list missed the mix, who you produce and how, so followers got those 15 s late; and no holdings,
  -- which only the old take sync filled. Round 1 review, 0.59.45)
  local fingerprint = live.status_fingerprint(info)
  if fingerprint ~= status_json or now - last_status > 15 then
    status_json, last_status, status_info = fingerprint, now, info
    sync.write_status(proj, cfg, b.song, b.room, info)
  end

  lap("status")
  if s then band.check_version(s.bandsync, "'" .. b.song .. "'") end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  lap("redraw")
end

local function poll()
  P.syncthing()
  local t = {}
  P.who(t)
  t.now = reaper.time_precise()
  lap("who")
  P.look(t)
  P.outbox_inbox(t)
  P.receive(t)
  P.heal(t)
  P.joins(t)
  P.live_clips(t)
  P.save_drive(t)
  P.presence(t)
  P.status(t)
end

-- The panel stops us with a flag (re-running the action would raise REAPER's task-control dialog), and sees
-- we're alive from a heartbeat; both live in non-persistent ExtState so the project isn't marked modified.
local key = tostring(proj)
-- Start/stop events: looked for every 0.25 s by name alone (a file listing), read only when new.
local fired, seen_ev, quick_at = {}, {}, 0
-- The newest cue wins: an older one (a second copy arriving through the regular poll, say) is ignored.
local cue_at = -math.huge
local together_take -- (this tab's recording was started together, so a stop together may end it)
local produce_lag, stamp_seen -- (producing someone: how far behind this pass really runs; the stream's start already acted on)
local in_time -- (Parts play "In time": { lead, lag } while you play along one interval behind someone's take. lib/streams.lua in_time_lag)
-- Whose play, pause and stop this tab follows: "follow <proj>" holds a name, "follow driver" (kept) means whoever drives. Real time mode's
-- side by side follows everyone. (lib/presence.lua moves the view along too.)
local function follows(name)
  local who_ = reaper.GetExtState(band.SECTION, "follow " .. key)
  if who_ ~= "" then return who_ == name end
  return reaper.GetExtState(band.SECTION, "follow driver") ~= "" and sync.driver_name == name
end
local in_time_with -- (in time with whose take: lib/streams.lua in_time_lag. James, rt)
local function take_cue(ev)
  -- (on the studio's shared clock when it came with one: fired at this computer's clock + (start_at - shared now). James, 0.60.0-rt)
  if ev and not ev.remote and tonumber(ev.start_at) then
    local sn = direct.shared_now()
    if sn then ev.at = together.local_at(tonumber(ev.start_at), sn, together.now()) end
  end
  -- (listening in time, NINJAM style: a bandmate's recording start you follow plays here one interval behind theirs, and their stop as far
  -- behind, so what they play lands on your grid. lib/streams.lua. James, rt)
  if ev and not (ev.id and fired[ev.id]) then
    local streams = require("streams")
    local lag
    lag, in_time_with = streams.in_time_lag(ev, cfg.user, streams.mode(), tonumber(ev.pos) and together.bars_after(proj, tonumber(ev.pos), streams.bars()) or 0, in_time_with)
    if lag then ev.lag = lag end
  end
  if not ev or (ev.id and fired[ev.id]) or (not ev.remote and (ev.at or 0) < cue_at) then return end
  if ev.remote then -- a producer starting or stopping someone's transport (lib/producer.lua): only theirs, with their say-so
    if not require("producer").remote_ok(ev, cfg.user, require("producer").lets_for(proj), reaper.GetExtState(band.SECTION, "produced by " .. key), together.now()) then return end
    -- (from where they asked, however late it arrived: a take starts where it was meant to. Fired as it lands, not at their clock's moment, and it
    -- doesn't hold back the band's own cues: a producer whose clock ran ahead made this one wait, and everything after it. Review, 0.58.45)
    ev.behind, ev.at = true, math.min(tonumber(ev.at) or together.now(), together.now())
    if ev.rec then -- (nothing armed: REAPER's Record Warning box comes up and holds every script, this one too, until someone answers. Mac, 0.58.45)
      local armed = false
      for i = 0, reaper.CountTracks(proj) - 1 do armed = armed or require("live").armed(reaper.GetTrack(proj, i)) end
      if not armed then
        if ev.id then fired[ev.id] = true end
        return band.log(tostring(ev.lead) .. " asked to record you, but nothing is armed here: arm a track, and they can press Record again")
      end
    end
    if ev.loop then -- (their loop comes with it: lib/producer.lua producer.remote)
      if type(ev.loop) == "table" and tonumber(ev.loop[1]) and tonumber(ev.loop[2]) then
        reaper.GetSet_LoopTimeRange2(proj, true, true, tonumber(ev.loop[1]), tonumber(ev.loop[2]), false)
        reaper.GetSetRepeatEx(proj, 1)
      end
    elseif ev.loop == false then reaper.GetSetRepeatEx(proj, 0) end
    transport = ev
    return
  elseif ev.follow and not side_bars() and not follows(ev.lead) then return end
  cue_at, transport = ev.at or cue_at, ev
end

-- The cue watch's work, kept small (Round 1 review, 0.59.45: a bandmate's burst of 300 files was read and decoded in one tick, 0.1-1.5 s, four
-- times a second, also while recording):
--  - the folder is listed again only when its modified time moved, or moved under 2 s ago (it's to the second: two changes in one second read
--    the same), or a file was left unread last time, or 2 s have passed since the last listing (exFAT and FAT don't move a folder's time for a
--    new file: the cue watch went blind there. Round 2 review, 0.59.46). Without js_ReaScriptAPI, or when the folder can't be read that way,
--    it's listed every time.
--  - a small file that still doesn't decode after CUE_TRIES reads is left to receive (it made the watch list every tick again, for good).
--  - a file over 4 KB isn't a cue (they're 250-400 bytes): skipped unread, receive reads it.
--  - at most CUE_READS files a tick; the rest next tick. What's read goes into receive's own cache (sync.ev_cache), so it isn't read twice.
local CUE_READS, CUE_BYTES, CUE_TRIES = 20, 4096, 20
local dir_m, dir_m_at, cue_left, listed_at, cue_bad = nil, -math.huge, true, -math.huge, {}
local function folder_moved(dir)
  local now = reaper.time_precise()
  if cue_left or not reaper.JS_File_Stat or now - listed_at >= 2 then return true end
  local status, _, _, m = reaper.JS_File_Stat(dir)
  if status ~= 0 or not m then return true end
  if m ~= dir_m then dir_m, dir_m_at = m, now end
  return now - dir_m_at < 2
end
local function small_event(path) -- -> the event (nil if unreadable, or caught mid-write), and true when the file is too big to be a cue
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local n = fh:seek("end")
  if not n or n > CUE_BYTES then fh:close(); return nil, n ~= nil end
  fh:seek("set")
  local s = fh:read("a")
  fh:close()
  local ev = band.json_decode(s or "")
  return type(ev) == "table" and ev or nil
end
local function quick_transport()
  local dir = sync.room_dir(cfg, b.song, b.room) .. "/events"
  if not folder_moved(dir) then return nil end
  local found, reads = nil, 0
  local cache = sync.ev_cache and (sync.ev_cache[dir] or {})
  if cache then sync.ev_cache[dir] = cache end
  cue_left, listed_at = false, reaper.time_precise()
  -- (read now, as before, but shared: the poll's own looks at the folder within 0.2 s use this read. 0.59.14, review)
  -- (with what came over the direct link, from its inbox: lib/direct.lua. James, 0.60.0-rt)
  local names, from = direct.merge(cfg, dir, band.raw_listing(dir, true))
  for _, f in ipairs(names) do
    if not seen_ev[f] then
      if f:sub(-5) ~= ".json" or sync.is_mine(f, cfg.user) then seen_ev[f] = true
      elseif reads >= CUE_READS then cue_left = true; break
      else
        reads = reads + 1
        local ev, big = small_event(from and from[f] or dir .. "/" .. f)
        cue_bad[f] = not (ev or big) and (cue_bad[f] or 0) + 1 or nil
        if ev or big or cue_bad[f] >= CUE_TRIES then seen_ev[f], cue_bad[f] = true, nil else cue_left = true end -- (one caught mid-write is read again next time, not skipped: review, 0.58.92)
        if ev and cache then cache[f] = ev end
        if ev and (ev.type == "start" or ev.type == "stop") and not fired[ev.id] and together.now() - (ev.at or 0) < 30 then found = ev end
      end
    end
  end
  return found
end
do -- what's already there is history, not a cue
  local dir, i = sync.room_dir(cfg, b.song, b.room) .. "/events", 0
  reaper.EnumerateFiles(dir, -1)
  while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end; seen_ev[f] = true; i = i + 1 end
end
-- StudioSync - Autostart.lua restarts us for this project after REAPER restarts, until the person stops us
-- (our tab's file, not the front one's: an update reloads every tab's Live sync while one tab is in front)
local our_file = ""
for i = 0, 512 do
  local p, f = reaper.EnumProjects(i)
  if not p then break end
  if p == proj then our_file = f or "" end
end
local autokey = band.autosync_key(our_file)
if autokey ~= "autosync " then band.set_autosync(our_file, true) end
-- The tab saved under another name (REAPER's Save As, or "Save new version of project"): the new file is the one that syncs, starts with REAPER,
-- and (the main room's) opens from Projects. It read as a backup, and Sync and exit skipped holding, saving and sending. Looked at every 5 s.
-- (Round 3 review, 0.59.48)
local file_at = -math.huge
local function follow_file(now)
  if now - file_at < 5 then return end
  file_at = now
  local f = require("rooms").file_of(proj) or ""
  if f == "" or f == our_file then return end
  -- (never a backup or autosave opened in place: it became the room's file, synced past rooms.is_copy and opened from Projects from then on. Only
  -- a Save As of this same room gets here: the tick stops on another song, room or studio. Round 4 review, 0.59.49)
  if live.backup_name(f) then return end
  our_file = f
  band.set_autosync(f, true)
  if b.room == "main" then band.set_project_file(cfg.root, b.song, (f:gsub("\\", "/"))) end
  band.log("'" .. b.song .. "' is saved as " .. f:gsub("\\", "/"):match("[^/]*$") .. " now: that file syncs from here on")
end
-- A project just opened (not this Live sync reloaded): its live audio starts off. ReaNINJAM came back with it, windows up and connecting,
-- and SonoBus would join by itself (James, 0.59.8). "live began <tab>" lasts this REAPER session, and goes when the tab closes.
if reload_proj ~= proj and reaper.GetExtState(band.SECTION, "live began " .. tostring(proj)) == "" then -- (a reload for an update carries on as it was)
  reaper.SetExtState(band.SECTION, "live began " .. tostring(proj), "1", false)
  local ok, was = pcall(live.all_off, proj)
  if ok and was then band.log("live audio starts off when a project opens: Real time mode (and Time-sync) and the call are off. Switch them on on Home and in Chat > Call") end
end
reaper.SetExtState(band.SECTION, "live began " .. tostring(proj), "1", false)
local plugins_looked -- (when bandmates' plug-in lists were last looked at: tick_body)
local tick
local livemidi = require("livemidi")
local midi_view_at, midi_view_err = 0, nil
local undo_since, undo_said -- when you undid one of StudioSync's own changes (tick_body waits a while)
-- What comes over the direct link, by kind (lib/direct.lua live_tick; James, 0.60.0-rt). Each also comes as a file, the record: whichever is
-- first is taken, once (a cue's file is history once its message is in; live MIDI files by name; presence and claims by their time).
local live_handlers = {
  presence = function(st) require("presence").from_msg(cfg, b.song, b.room, st, "presence") end,
  heartbeat = function(st) require("presence").from_msg(cfg, b.song, b.room, st, "heartbeat") end,
  claim = function(c) sync.live_claim(b.song, b.room, c) end,
  cue = function(ev)
    if type(ev) ~= "table" or type(ev.id) ~= "string" or (ev.type ~= "start" and ev.type ~= "stop") or type(ev.at) ~= "number" or sync.is_mine(ev.id, cfg.user) then return end
    seen_ev[ev.id .. ".json"] = true
    if not fired[ev.id] and together.now() - ev.at < 30 then take_cue(ev) end
  end,
  midi = function(d) livemidi.from_msg(proj, cfg, b, d, reaper.GetPlayStateEx(proj) & 4 ~= 0) end,
  -- (a bandmate's take as they record it: lib/streams.lua. James, rt)
  take = function(d) require("streams").on_take(cfg, b, d) end,
  take_end = function(d) require("streams").on_take_end(d) end,
  -- (where a bandmate punches in and their pre-roll, shown on this timeline till their recording ends: lib/streams.lua on_punch. James, rt)
  punch = function(d) require("streams").on_punch(proj, cfg, b, d) end,
  punch_end = function(d) require("streams").on_punch_end(proj, d) end,
  -- (a media file a bandmate just put in the shared folder, coming over the link: lib/streams.lua on_media. James, rt)
  media = function(d) require("streams").on_media(cfg, b, d) end,
  -- (a bandmate catching up asks for a media file its Syncthing still needs; sent back if it's here: lib/streams.lua on_media_want. James, rt)
  media_want = function(d) require("streams").on_media_want(cfg, b, d) end,
  -- (a bandmate's Ableton Link state: their Link apps and ours line up on the bar. lib/ablink.lua. James, rt)
  ablink = function(d) require("ablink").on_msg(cfg, b, proj, d) end,
}
live_handlers.start, live_handlers.stop = live_handlers.cue, live_handlers.cue
local function tick_body() -- returns true to keep going
  if sync.tip_at and reaper.time_precise() - sync.tip_at > 6 then sync.tip_at = nil; reaper.TrackCtl_SetToolTip("", 0, 0, true) end
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then -- project closed: stop, and say so
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    -- (the tab's own settings go too: a new tab can get the same address, and took its follow, produce or listen. Review, 0.58.96)
    for _, k in ipairs({ "follow", "listen", "listen had", "listeners", "send whole mix", "alone", "held", "produce", "transport", "together",
        "sonobus for listeners", "outbox", "live owner", "ping", "slow tick", "last here", "draw", "live began", "takelanes",
        -- (and these: a new tab at the same address showed a count-in, a producer, a SonoBus trouble or a drift that were the closed tab's. Review, 0.59.14)
        "end session", "produced by", "producer controls", "timing", "produce ctl", "last_at", "stamping", "together_at", "rt group", "rt silent", "rt silent who", "rt trouble", "driver_away", "mirror drift",
        "ninjam shown", "ninjam off", "ninjam start", "ninjam connect", "ninjam host", "unsent", "last_track", "tick stats" }) do reaper.DeleteExtState(band.SECTION, k .. " " .. key, false) end -- (unsent, last_track: Round 2 review, 0.59.46)
    return band.log("live sync stopped: '" .. b.song .. "'" .. (b.room ~= "main" and (", side room '" .. b.room .. "',") or "") .. " was closed (it starts again by itself when you reopen it)")
  end
  local now_b = band.binding(proj)
  -- became a solo working copy (or unbound), or another room's or studio's file of the song opened into this tab: not ours any more. (Room and
  -- studio too: it went on syncing the old room into it, and adopted that file as the room's. Round 4 review, 0.59.49)
  if not same_session(now_b) then
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    reaper.DeleteExtState(band.SECTION, "live began " .. key, false) -- (another song opened in this tab: its live audio starts off. 0.59.9)
    return band.log("live sync stopped: this tab is now " .. (now_b and now_b.role == "solo" and "a Solo edit working copy" or "no longer this session"))
  end
  if reaper.GetExtState(band.SECTION, "live owner " .. key) ~= my_token then -- a newer Live sync took this tab over
    reloaded = true -- (it carries on the session: this one ending isn't the session's end, so no kept "end of session" from here)
    return band.log("a newer Live sync took over '" .. b.song .. "' (room " .. b.room .. "): this one stops") -- (plain words: Round 1 review, 0.59.45)
  end
  reaper.SetExtState(band.SECTION, "live " .. key, tostring(reaper.time_precise()), false)
  keep_lock() -- (this REAPER syncs this song: 0.59.18)
  follow_file(reaper.time_precise())
  -- A bandmate's plug-in list changed (they installed some, or the pack): the "everyone has" folder made again here, not only at the next
  -- start. Looked at every 2 minutes, by whichever tab of the studio looks first. (James, 0.59.24: "make sure the studiosync plugins are
  -- refreshed for users to see what everyone has")
  if reaper.time_precise() - (plugins_looked or -math.huge) > 120 then
    plugins_looked = reaper.time_precise()
    local sig = {}
    for _, f in ipairs(band.files(cfg.root .. "/plugins", ".json")) do sig[#sig + 1] = f .. "@" .. tostring(band.size(cfg.root .. "/plugins/" .. f)) end
    sig = table.concat(sig, "|")
    local seen_key = "plugins seen " .. cfg.root
    if reaper.GetExtState(band.SECTION, seen_key) ~= sig then
      local had = reaper.GetExtState(band.SECTION, seen_key) ~= ""
      reaper.SetExtState(band.SECTION, seen_key, sig, false)
      if had then
        local ok, n = pcall(require("plugins").update_folder, cfg)
        if ok and n then band.log(string.format("a bandmate's plug-ins changed: %d everyone has now (FX browser folder '%s'; REAPER shows it after a restart, StudioSync's Find a plug-in now)", n, require("plugins").FOLDER)) end
      end
    end
  end
  -- Each part shows only the take it plays, dry or wet (James, 0.59.13: "having a wet and dry take might take up too much space... only show
  -- one or the other"), unless Settings > Advanced shows both (ExtState "show both takes"). REAPER's Show all takes in lanes (action 40435) is
  -- the project's own: set once in front, and again only when the setting changes, so Ctrl+L still works. A band song's takes are only ever
  -- dry and wet: its comps are lanes.
  if reaper.EnumProjects(-1) == proj then
    local want = reaper.GetExtState(band.SECTION, "show both takes") == "1" and 1 or 0
    if reaper.GetExtState(band.SECTION, "takelanes " .. key) ~= tostring(want) then
      if reaper.GetToggleCommandStateEx(0, 40435) ~= want then reaper.Main_OnCommand(40435, 0) end
      reaper.SetExtState(band.SECTION, "takelanes " .. key, tostring(want), false)
    end
  end
  -- the studio's shared preferences while its song is in front; yours back when no song is (another song's Live sync does its studio's.
  -- lib/sharedprefs.lua. James, rt)
  do
    local front = reaper.EnumProjects(-1)
    if front == proj then band.try("shared prefs", require("sharedprefs").tick, cfg.root)
    elseif not (front and band.binding(front)) then band.try("shared prefs", require("sharedprefs").tick, nil) end
  end
  if cmd > 0 then reaper.SetExtState(band.SECTION, "live cmd " .. cmd, tostring(reaper.time_precise()), false) end -- (band.start_live)
  -- the band's takes add up on your master: say so when it clips (at most every 30 s)
  if reaper.EnumProjects(-1) == proj and reaper.GetPlayState() & 1 == 1 then
    local m = reaper.GetMasterTrack(proj)
    local peak = math.max(reaper.Track_GetPeakInfo(m, 0), reaper.Track_GetPeakInfo(m, 1))
    if peak >= 0.999 and reaper.time_precise() - (clip_said or -1e9) > 30 then
      clip_said = reaper.time_precise()
      local at = reaper.format_timestr_pos(reaper.GetPlayPosition2Ex(proj), "", 2):match("^(%d+)") or "?"
      band.log("your master is clipping at bar " .. at .. ": turn it (or the loudest tracks) down")
    end
  end
  together.tick()
  -- (the direct link: an event file that arrived brings a receive pass and a cue look now, not in up to 2 s; messages go where they belong)
  local dok, arrived = band.try("direct.live_tick", direct.live_tick, cfg, b.song, b.room, live_handlers)
  if dok and (arrived or 0) > 0 then cue_left, quick_at, last, direct_in_at, direct_held = true, -math.huge, -math.huge, reaper.time_precise(), true end
  band.try("ablink.tick", require("ablink").tick, cfg, b, proj) -- (this computer's Ableton Link session, when it's on here. James, rt)
  band.try("webui.tick", require("webui").tick, proj, cfg, b, live_handlers) -- (the web UI: who's here, claims and chat for the browser, its chat sends. lib/webui.lua, James, rt)
  local tjson = reaper.GetExtState(band.SECTION, "transport " .. key) -- a start/stop from the panel or the band
  if tjson ~= "" then
    reaper.DeleteExtState(band.SECTION, "transport " .. key, false)
    take_cue(band.json_decode(tjson))
  end
  lap("start")
  -- (a start/stop can't wait for the 2 s poll. Only while someone else is here, though: alone, nobody can send one, and listing the
  -- whole events folder four times a second in every tab was most of an idle Live sync's work. Review, 0.58.91)
  local quick_every = #require("presence").peers(cfg, b.song, b.room) > 0 and 0.25 or 2
  if not transport and reaper.time_precise() - quick_at > quick_every then
    quick_at = reaper.time_precise()
    take_cue(quick_transport())
    local producing = require("producer").who(proj)
    if not transport and producing and require("producer").via(proj) == "stamp" then -- (the stream says it's started before the shared folder can)
      local st = require("stamp").status()
      if not st.active then stamp_seen = nil
      elseif not stamp_seen then
        local cue = require("producer").fast_cue(st, stamp_seen, producing, together.now(), require("producer").lag(proj), reaper.GetPlayStateEx(proj) & 1 == 1)
        stamp_seen = st.count
        if cue then transport, cue_at = cue, cue.at end
      end
    end
  end
  lap("cue check")
  if transport then
    local tnow = together.now()
    local theirs = transport.lead and transport.lead ~= cfg.user
    local behind = transport.follow and theirs and require("producer").behind(proj, transport.lead)
    if behind then -- (a lag this computer chose; a stop comes as far behind as the pass really was)
      transport.behind, transport.lag = true, transport.type == "stop" and math.max(behind, produce_lag or 0) or behind
    elseif not transport.lag_set then -- (In time: one interval behind a take you follow, its stop as far behind. Asked once per cue)
      local s = require("streams")
      local lag
      lag, in_time = s.in_time_lag(transport, cfg.user, s.mode(), together.bars_after(proj, transport.pos or 0, s.bars()), in_time)
      if lag then transport.lag = lag end
      transport.lag_set = true
    end
    local fire = transport.type == "stop" and ((transport.at or 0) + (theirs and (transport.lag or 0) or 0)) or together.plan(transport, cfg.user, nil)
    if transport.type == "stop" and transport.follow and theirs and transport.pos then fire = fire + 2 end -- the position decides; time is a backstop
    if transport.type == "start" and tnow < fire then reaper.SetExtState(band.SECTION, "together_at " .. key, tostring(fire), false) end
    due_in = fire - tnow -- the regular poll can take 100-200 ms: it waits while a start/stop is close
    -- (never into the middle of your own take: a recording you started yourself isn't cut by someone else's start or stop, and a record cue
    -- doesn't take you away from another tab that's playing or recording. Review, 0.58.91)
    local recording = reaper.GetPlayStateEx(proj) & 4 == 4
    if not recording then together_take = nil end -- (a take started together that has since stopped)
    local front = reaper.EnumProjects(-1)
    -- (and any cue while the tab in front records: a play cue for a following tab behind it could stop that take. Review, 0.58.96)
    local busy_elsewhere = front ~= proj and ((transport.type == "start" and transport.rec and reaper.GetPlayStateEx(front) ~= 0) or reaper.GetPlayStateEx(front) & 4 == 4)
    -- (asked once a pass: reached() counts readings, and asked twice in one pass a single glitch counted as two. Review, 0.58.92)
    local due = tnow >= fire or reached(transport, theirs)
    if tnow - fire > 30 then -- arrived long after the fact (offline, sync stalled): don't start a song out of nowhere
      band.log(string.format("missed a %s from %s (%.0f s ago)", transport.type, tostring(transport.user), tnow - fire))
      transport = nil
    elseif together.leave_alone(due, theirs, transport.remote, recording, together_take, busy_elsewhere) then
      band.log(string.format("%s %s together, but %s: left as it is", tostring(transport.user or transport.lead), transport.type == "stop" and "stopped" or "started",
        recording and "you're recording here" or "another tab is playing here"))
      if transport.id then fired[transport.id] = true end
      reaper.DeleteExtState(band.SECTION, "together_at " .. key, false)
      transport = nil
    elseif due then -- a follower stops where the leader stopped
      if transport.type == "stop" then
        local at_pos = reaper.GetPlayPosition2Ex(proj)
        reaper.OnStopButtonEx(proj)
        band.log(string.format("stopped together (%s) at %.3f s, %s", tostring(transport.user), at_pos,
          tnow >= fire and "by time" or string.format("by position (theirs: %.3f s)", transport.pos)))
        reaper.SetExtState(band.SECTION, "together " .. key, os.date("%H:%M:%S ") .. "stopped together (" .. tostring(transport.user) .. ")", false)
        if transport.pause and transport.pos then -- (paused: you're where they paused, paused too)
          reaper.SetEditCurPos2(proj, transport.pos, false, false)
          reaper.OnPauseButtonEx(proj)
        end
      else
        local _, from = together.plan(transport, cfg.user, tnow) -- a few ms (or seconds) late: as far in as time has gone
        if transport.behind then produce_lag = tnow - (transport.at or tnow) end
        if reaper.GetPlayStateEx(proj) ~= 0 then reaper.OnStopButtonEx(proj) end
        reaper.SetEditCurPos2(proj, from, false, false)
        if transport.click and (transport.countin or 0) > 0 then click_until(transport.pos or from) end
        together_take = transport.rec and not (transport.follow and theirs) -- (a take started together may be stopped together)
        if together_take then -- side by side: the one who records records, the rest listen
          if front ~= proj then band.log("recording together: switched to '" .. b.song .. "', as REAPER records only in the tab in front") end
          reaper.SelectProjectInstance(proj)
          reaper.Main_OnCommand(1013, 0) -- Transport: Record (the active project)
          if reaper.GetPlayStateEx(proj) & 4 == 0 then together_take = nil end -- (REAPER's Record Warning cancelled it: no take started together. 0.58.93)
        else
          reaper.OnPlayButtonEx(proj)
        end
        local said = transport.remote and string.format("%s from %.2f s: %s started it (they're producing you)", transport.rec and "recording" or "playing", from, tostring(transport.lead))
          or transport.rec and transport.follow and theirs
          and string.format("playing along with %s's recording from %.2f s (%.0f ms after the planned moment)", tostring(transport.user), from, (tnow - fire) * 1000)
          or string.format("%s together from %.2f s (%s; %.0f ms after the planned moment)", transport.rec and "recording" or "playing",
            from, tostring(transport.user or transport.lead), (tnow - fire) * 1000)
        if reaper.GetPlayStateEx(proj) & 1 == 0 then -- (REAPER said no: its Record Warning answered Cancel, say. "recording from" was logged with nothing running: Mac, 0.58.45)
          said = "REAPER didn't start (" .. (transport.rec and "record" or "play") .. " from " .. string.format("%.2f", from) .. " s was cancelled)"
        end
        band.log(said)
        reaper.SetExtState(band.SECTION, "together " .. key, os.date("%H:%M:%S ") .. said, false) -- the panel shows it
      end
      if transport.id then fired[transport.id] = true end -- the regular poll applies the same event again later
      reaper.DeleteExtState(band.SECTION, "together_at " .. key, false)
      -- what we just did isn't a press to pass on; but a producer's press is: the producer follows us, and their song started or stopped with
      -- nothing told it (review, 0.58.45)
      if not transport.remote then side.quiet_until = reaper.time_precise() + 1 end
      transport = nil
    end
  end
  if click and (reaper.GetPlayStateEx(proj) & 1 == 0 or reaper.GetPlayPosition2Ex(proj) >= click) then
    if reaper.GetToggleCommandStateEx(0, 40364) == 1 then reaper.Main_OnCommand(40364, 0) end
    click = nil
  end
  local lagbars = side_bars()
  local someone_follows = false -- (a cue file per press only when somebody's there to read it)
  if not lagbars then
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do
      someone_follows = someone_follows or st.follow == cfg.user or (st.follow_driver and sync.driver_name == cfg.user)
    end
  end
  if lagbars or someone_follows then
    local ps = reaper.GetPlayStateEx(proj)
    local playing, pos, tp = ps & 1 == 1, reaper.GetPlayPosition2Ex(proj), reaper.time_precise()
    if tp >= side.quiet_until then
      local jumped = playing and side.playing and math.abs(pos - (side.pos + (tp - side.t))) > 0.5 -- a seek while playing
      if playing ~= side.playing or jumped then
        local ev = playing and { type = "start", pos = pos, countin = 0, rec = ps & 4 == 4 or nil }
          or { type = "stop", pos = side.pos + (tp - side.t), pause = ps & 2 == 2 or nil } -- where the song was when you stopped
        ev.at, ev.lead, ev.follow = together.now(), cfg.user, true
        ev.start_at = together.start_at(0) -- (the same moment on the shared clock: the others' lag counts from it. James, 0.60.0-rt)
        ev.lag = together.bars_after(proj, pos, lagbars or 0)
        sync.post(cfg, b.song, b.room, ev)
        fired[ev.id], cue_at = true, math.max(cue_at, ev.at)
        reaper.SetExtState(band.SECTION, "together " .. key, os.date("%H:%M:%S ") .. (playing and string.format("you %s from %.2f s: the others follow %.1f s behind",
          ev.rec and "recorded" or "played", pos, ev.lag) or "you stopped: the others stop too"), false)
      end
    end
    side.playing, side.pos, side.t = playing, pos, tp
  end
  local st = reaper.GetPlayStateEx(proj)
  if st & 4 ~= 0 then
    if not recording then band.try("rthealth.record_check", require("rthealth").record_check, proj, cfg, b) end -- (low disk here or on a bandmate: a line, never a box. James, rt)
    if not recording and status_info then
      status_info.playing, status_info.recording, status_info.cursor = true, true, nil
      sync.write_status(proj, cfg, b.song, b.room, status_info)
      status_json = nil -- (and the first pass after it says it's over)
    end
    recording = true
  elseif recording then
    recording, stopped_at = false, reaper.time_precise()
    together_take = nil -- (the take started together is over: a redo of your own isn't someone else's to stop. Review, 0.58.92)
    band.try("alerts.send", require("alerts").send, cfg, "take", "StudioSync: " .. b.song, cfg.user .. " just recorded something in " .. b.song) -- (phone alerts, if the studio has them)
    band.try("api.event", require("api").event, "take", { song = b.song, room = b.room })
  end
  local now = reaper.time_precise()
  -- (a long take: the 15 s status write is in poll, which waits while recording, so after 45 s the others read you as gone and took full
  -- control mid-take. Review, 0.58.92)
  lap("transport")
  -- Real time mode: only what's armed feeds SonoBus (lib/live.lua rt_sends), checked about once a second
  if now - rt_at > 1 then
    rt_at = now
    local ok, e = pcall(require("hear").answer_listeners, proj, cfg, b)
    if not ok then band.log("listen: " .. tostring(e)) end
    band.try("hear.watch_silence", require("hear").watch_silence, proj, cfg, require("presence").peers(cfg, b.song, b.room), now)
    band.try("hear.check", require("hear").check, proj, cfg, require("presence").peers(cfg, b.song, b.room), now)
    band.try("live.rt_sends", live.rt_sends, proj); band.try("live.join_check", live.join_check, proj); band.try("sync.follow_claims", sync.follow_claims, proj, cfg, b.song, b.room)
    local okp, ep = pcall(require("producer").tick, proj, cfg, b, require("presence").peers(cfg, b.song, b.room))
    if not okp then band.log("producer: " .. tostring(ep)) end
  end
  -- live MIDI view (lib/livemidi.lua): our notes go out as we play them; bandmates' show up as they play theirs
  if reaper.EnumProjects(-1) == proj then livemidi.send_tick(proj, cfg, b, st & 4 ~= 0) end -- (input goes to the tab in front)
  if st & 4 == 0 and now - midi_view_at > 0.5 then
    midi_view_at = now
    local ok, e = pcall(livemidi.receive_tick, proj, cfg, b)
    if not ok and midi_view_err ~= tostring(e) then midi_view_err = tostring(e); band.log("live MIDI view: " .. tostring(e)) end
  end
  -- takes streamed as they're recorded (lib/streams.lua): ours go out, bandmates' grow on their tracks
  -- (and media files over the link put in the shared folder: a pass at once, so the items waiting for them land now. James, rt)
  local _, media_placed = band.try("streams.tick", require("streams").tick, proj, cfg, b, st & 4 ~= 0, reaper.EnumProjects(-1) == proj)
  if (tonumber(media_placed) or 0) > 0 then last = -math.huge end
  lap("listen, midi view")
  local every = reaper.GetPlayStateEx(proj) & 1 == 1 and 2 -- playing: a pass can stall REAPER ~0.5 s (seen on the laptop)
    or (lagbars or now - stopped_at < 8 or require("bgrender").waiting() or require("prints").waiting()) and 0.5 or 2 -- side by side, just after a recording, or with a print on its way: look often
  local redo = reaper.Undo_CanRedo2(proj)
  -- REAPER's own undo (Edit > Undo, or a key not set to StudioSync's) just rolled back a change StudioSync made, a collaborator's or the group's:
  -- that would undo their work too. Put it back, and undo your own last change instead, as Ctrl+Z does.
  if redo and (redo:find("^StudioSync") or redo:find("^BandSync")) and redo ~= undo_top then
    reaper.Undo_DoRedo2(proj)
    local ok, res, why = pcall(function() return require("undo").step(proj, cfg, b, false, {}) end)
    if not ok then band.log("undo: " .. tostring(res)) elseif res then band.log(res) elseif why then band.log(why) end
    redo = reaper.Undo_CanRedo2(proj)
  end
  undo_top = redo
  if redo and (redo:find("^StudioSync") or redo:find("^BandSync")) then -- you just undid one of StudioSync's changes: keep undoing if you like
    undo_since = undo_since or now
    if not undo_said then undo_said = true; band.log("you undid a StudioSync change: Live sync waits 30 s (or until you do something else) so you can keep undoing") end
  else
    undo_since, undo_said = nil, nil
  end
  local undoing = undo_since and now - undo_since < 30
  -- (Live set, panel Settings: nothing is looked at or applied while playing, as while recording, so a pass can't hold REAPER up mid-song)
  local live_set = reaper.GetPlayStateEx(proj) & 1 == 1 and reaper.GetExtState(band.SECTION, "live set") == "on"
  -- (while poll waits, a take, Live set playing or the undo wait, its 15 s status write waits too: after 45 s the others read you as gone and
  -- took full control. Review, 0.58.92-93)
  -- (and while the tab in front records: a big tab behind ran full looks, receives and cloud passes mid-take. REAPER records only in the tab in
  -- front, so that's GetPlayState's. The 15 s status heartbeat carries on. Round 1 review, 0.59.45)
  local rec_any = recording or live.recording_anywhere()
  if together.heartbeat_due(rec_any or undoing or live_set, status_info ~= nil, now, last_status) then last_status = now; pcall(sync.write_status, proj, cfg, b.song, b.room, status_info) end
  -- (or 0.1 s after an edit of yours settles: it goes out now, not at the next 2 s pass; and as the quiet window ends, for what came over the
  -- link meanwhile. sync.look_now, sync.receive_now. James, rt)
  local mouse = mouse_down()
  if not rec_any and not undoing and not live_set and (now - last > every or sync.look_now(changed_at, polled_at, pass_took, now, mouse)
      or sync.receive_now(direct_held, changed_at, sync.quiet_for(now, direct_in_at), polled_at, pass_took, now, mouse))
      and not (transport and due_in < 1.5) then
    last = reaper.time_precise()
    polled_at = last
    local ok, err = pcall(poll)
    if not ok then band.log("sync error: " .. tostring(err)) end
    pass_took = reaper.time_precise() - polled_at
    if perf.on then perf.passes[#perf.passes + 1] = pass_took end
    -- more of the band's changes waiting than one pass applies: the next pass in 0.3 s, not 2 s (320 moved items
    -- took 73 s to land at 2 s a pass; laptop, 0.34.4). Each pass still applies at most a quarter second.
    -- (and when a burst of ours is still going out: mirror.watch sends a quarter second of it per pass)
    if require("mirror").more then mirror_due = true end
    if sync.backlog or require("mirror").more then last = reaper.time_precise() - every + 0.3 end
  end
  return true
end
-- A running script keeps the code it started with: after an update, running the action again only said "already
-- running", so an old Live sync carried on through two updates (laptop, 2026-10-28: 0.13.3 skipped mix events as
-- unknown and marked them applied). Once the installed version has changed (and held for two looks, so a half-copied
-- update isn't loaded), the new code takes over in place, for this same tab.
local seen_disk, disk_at, partial_seen = nil, 0, false
local function updated()
  if reaper.time_precise() - disk_at < 5 then return false end
  disk_at = reaper.time_precise()
  -- (with fallbacks for an older band.lua beside this file, as Autostart has them: a part-arrived copy pairs them, and tick() runs outside the
  -- xpcall, so the update check failed on every tick, or gave REAPER's error box at the tab's start, and never reached the reload that mends it.
  -- Round 3 review, 0.59.48)
  local disk = band.version_on_disk and band.version_on_disk(dir) or (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"') -- (its first bytes, not 85 KB: Round 1 review, 0.59.45)
  local ready = disk and disk ~= band.VERSION and disk == seen_disk and band.update_ok(dir, disk) -- (from a shared folder, once you said yes: Autostart asks)
  seen_disk = disk
  -- (this tab's own mark as well as the shared one: one tab failing held every tab back. Round 1 review, 0.59.45)
  local failed = band.reload_failed_key and band.reload_failed_key("StudioSync - Live sync.lua", key) or ("reload failed StudioSync - Live sync.lua " .. key)
  local partial = disk and band.started_partial(dir) -- (started on a part-arrived copy, whole now: 0.59.44)
  -- (once whole, a failure on the part-arrived copy doesn't hold the whole version back: its mark goes, once. Round 3 review, 0.59.48)
  if partial and not partial_seen then partial_seen = true; reaper.DeleteExtState(band.SECTION, failed, false) end
  return (ready or partial) and reaper.GetExtState(band.SECTION, failed) ~= disk
end
-- The last 10 s of tick timings, while "perf stats" is on: { at, song, room, ticks, passes = { n, med, p95, max } (ms), worst (the slowest
-- tick's laps) }. (tests/reaper/rt_perf.lua reads it. James, rt)
local function perf_publish(now)
  perf.at = now
  if perf.on and #perf.ticks > 0 then
    local R = require("rthealth")
    band.set_ext_json(band.SECTION, "tick stats " .. key, { at = os.time(), song = b.song, room = b.room, ticks = R.summary(perf.ticks),
      passes = R.summary(perf.passes), worst = perf.worst_laps }, false)
  end
  perf.on, perf.ticks, perf.passes, perf.worst, perf.worst_laps = reaper.GetExtState(band.SECTION, "perf stats") == "1", {}, {}, 0, ""
end
-- an error anywhere in a tick (a malformed cue from someone's machine, say) is logged, and Live sync carries on
local said_at, sws_at = -math.huge, -math.huge
tick = function()
  -- (the tab may have just been closed: check before asking about it, or REAPER stops us with an error box)
  -- (and not during a count-in or a start or stop still to come: the reload lost them, leaving the metronome on and "together_at" set. Review, 0.59.14)
  -- (nothing while anything records: lib/live.lua live.reload says nothing and hands nothing over then; it logged "reloaded" every 5 s through a
  -- take. Said only once the new code took over. Round 2 review, 0.59.46)
  if reaper.ValidatePtr2(0, proj, "ReaProject*") and reaper.GetPlayStateEx(proj) & 4 == 0 and not click and not transport and updated()
    and live.reload(dir, "StudioSync - Live sync.lua", seen_disk, key, function()
      reloaded = true
      reaper.DeleteExtState(band.SECTION, "live " .. key, false)
      BANDSYNC_LIVE_PROJ, BANDSYNC_ENDED_AT = proj, ended_at_n
    end, "live sync for '" .. b.song .. "' reloaded for StudioSync " .. tostring(seen_disk), function()
      reloaded, BANDSYNC_LIVE_PROJ, BANDSYNC_ENDED_AT = false, nil, nil -- (it couldn't start: this one carries on. 0.59.44)
      -- (and owns its tab again: the failed start had taken the token, so on the next tick this one read "a newer Live sync took over" and stopped.
      -- Round 1 review, 0.59.45)
      reaper.SetExtState(band.SECTION, "live owner " .. key, my_token, false)
    end) then return end
  local t0 = reaper.time_precise()
  local open = reaper.ValidatePtr2(0, proj, "ReaProject*") -- (asked about only while open: the error box above)
  if open then note_change() end -- (your edits since the last tick, before anything of ours: took_in below)
  laps, lap_t = {}, t0
  if reaper.time_precise() - sws_at > 1 then
    sws_at = reaper.time_precise()
    band.try("band.sws_colours", band.sws_colours) -- (lib/band.lua)
    band.try("mirror.note_open_fx", require("mirror").note_open_fx, proj)
    -- (with no audio device REAPER builds no peaks by itself: a bandmate's take stayed a blank box: Mac, 0.57.6)
    if sync.landed_media and reaper.Audio_IsRunning() ~= 1 and reaper.EnumProjects(-1) == proj then
      sync.landed_media = nil
      reaper.Main_OnCommand(40047, 0) -- Peaks: Build any missing peaks
    end
  end
  lap("colours, open fx")
  local ok, go = xpcall(tick_body, debug.traceback)
  if not ok then
    band.log_error("live sync", go) -- (every time, with where, in the log file: the Console says it once in 30 s)
    if reaper.time_precise() - said_at > 30 then said_at = reaper.time_precise(); band.log("live sync error: " .. tostring(go):match("^[^\n]*")) end
    go = true
  end
  if open and reaper.ValidatePtr2(0, proj, "ReaProject*") then took_in() end -- (what this tick changed was StudioSync's, not you editing)
  local took = reaper.time_precise() - t0
  if took > 0.15 then
    lap("rest")
    reaper.SetExtState(band.SECTION, "slow tick " .. key, string.format("%.0f ms at %s: %s", took * 1000, os.date("%H:%M:%S"), table.concat(laps, ", ")), false)
  end
  if perf.on then
    perf.ticks[#perf.ticks + 1] = took
    if took > perf.worst then perf.worst, perf.worst_laps = took, table.concat(laps, ", ") end
  end
  if t0 - perf.at >= 10 then perf_publish(t0) end
  if go then reaper.defer(tick) end
end

band.log(string.format("live sync for '%s' (%s, room %s, driver %s)", b.song, b.role, b.room, tostring(sync.driver(cfg, b.song, b.room, s0))))
tick()
