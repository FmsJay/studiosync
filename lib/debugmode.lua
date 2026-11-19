-- Debug mode for a studio (James, 0.59.3: "a debug mode for anyone on my studios that saves all details to use later for debugging"). The
-- owner or an admin turns it on (band.json "debug", a trusted setting: lib/groups.lua); then every computer in the studio writes, every few
-- minutes, into <studio>/_debug/<name>/ (which Syncthing carries to everyone, so the owner has every computer's):
--   report.json   what this computer is and sees: versions, the project open, who drives, what's waiting to go out or come in, what was
--                 skipped, held or undone, the mirror's view of each track and item (ids, revisions, hashes), and the log's last lines
--   log-<date>.txt  today's whole log file (every script's lines and errors, lib/band.lua log_file)
--   errors.txt    the panel's and Live sync's errors (StudioSync home/errors.log), when there is one
--   project <song>.rpp  a copy of the project open, as it is here (unsaved changes too; the project itself keeps its name). 0.59.40
--   computer.json  REAPER, audio and MIDI devices, extensions, where StudioSync runs from, whether REAPER closed cleanly last time
--   crash <id>.txt  REAPER's crash reports from the system (Windows Error Reporting, a Mac's DiagnosticReports), not the memory dumps
-- Only the owner and admins download everyone's (lib/songsync.lua debug lines); the others keep their own. computer.json and the crash
-- reports come from Autostart, so they come with no studio project open, and after a crash.
-- Each file is written over each time: a few hundred KB per computer, not a growing pile. Nothing secret goes in (no keys or tokens).
local band = require("band")
local dm = {}

function dm.on(root) return root and require("groups").trusted(root).debug == true end
function dm.dir(root, user) return root .. "/_debug/" .. tostring(user):gsub("[^%w%-_ ]", "_") end

local function copy_text(from, to, max)
  local t = band.read(from)
  if not t then return false end
  if max and #t > max then t = "[... the start left out: " .. (#t - max) .. " bytes]\n" .. t:sub(-max) end
  return band.write_atomic(to, t)
end

-- The project as the mirror sees it: per track and item, its id, revision, last event and hash (lib/mirror.lua known). -> a list.
local function mirror_view(proj)
  local mirror = require("mirror")
  local out = {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local oid = mirror.track_oid(tr)
    local rev, h, evid = mirror.known(proj, oid)
    local row = { track = select(2, reaper.GetTrackName(tr)), oid = oid, rev = rev, hash = h, ev = evid, local_track = mirror.local_track(tr) or nil, items = {} }
    for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, k)
      local io = mirror.item_oid(it)
      local irev, ih, iev = mirror.known(proj, io)
      row.items[#row.items + 1] = { oid = io, rev = irev, hash = ih, ev = iev, pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
        len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), unsent = mirror.unsent[tostring(proj) .. io] and true or nil }
    end
    out[#out + 1] = row
  end
  return out
end

-- Everything for one report. `b`: the tab's binding (nil: no studio project open). Pure but for reading REAPER and the files named.
function dm.report(cfg, proj, b)
  local sync = require("sync")
  local r = { made = os.date("!%Y-%m-%dT%H:%M:%SZ"), user = cfg.user, studiosync = band.VERSION, reaper = reaper.GetAppVersion(), os = reaper.GetOS(),
    studio = band.info(cfg.root).name, activity = band.activity() }
  if b and proj then
    local ext = function(k) return select(2, reaper.GetProjExtState(proj, band.SECTION, k)) end
    r.project = { song = b.song, room = b.room, role = b.role, file = select(2, reaper.EnumProjects(-1)), tracks = reaper.CountTracks(proj),
      items = reaper.CountMediaItems(proj), hold = ext("hold") ~= "" or nil, local_mix = ext("local_mix") == "1" or nil, alone_last = ext("alone_last"),
      timeline = ext("timeline"), skipped = sync.skipped(proj), outbox = band.ext_json(band.SECTION, "outbox " .. tostring(proj)),
      put_back = band.ext_json(band.SECTION, "put back"), drift = reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj)) }
    local ok, n = pcall(sync.pending_events, proj, cfg, b.song, b.room)
    r.project.pending = ok and n or tostring(n)
    local ok2, who = pcall(function() local s = band.read_json(band.session_path(cfg, b.song)); local _, w = sync.authority(cfg, b.song, b.room, s); return w end)
    if ok2 and type(who) == "table" then r.project.driver, r.project.mode = who.driver, who.mode end
    local ok3, view = pcall(mirror_view, proj)
    r.project.mirror = ok3 and view or tostring(view)
  end
  local ok4, peers = pcall(function() return require("services").syncthing_peers_now() end)
  r.syncthing_peers = ok4 and peers or nil
  r.sync_problem = reaper.GetExtState(band.SECTION, "sync problem")
  return r
end

-- Write this computer's report, log and errors into the studio's _debug folder. -> the folder, or nil + why.
function dm.write(cfg, proj, b)
  local d = dm.dir(cfg.root, cfg.user)
  reaper.RecursiveCreateDirectory(d, 0)
  local ok, r = pcall(dm.report, cfg, proj, b)
  if not ok then r = { made = os.date("!%Y-%m-%dT%H:%M:%SZ"), user = cfg.user, error = tostring(r) } end
  band.write_json(d .. "/report.json", r)
  -- (the project itself, as it is here now, unsaved changes too, as a copy: the project keeps its own name and stays unsaved. Not while
  -- recording. James, 0.59.40: "all projects from other users ... lands on this pc")
  if b and proj and reaper.ValidatePtr2(0, proj, "ReaProject*") and reaper.GetPlayStateEx(proj) & 4 == 0 then
    pcall(reaper.Main_SaveProjectEx, proj, d .. "/project " .. tostring(b.song):gsub("[^%w%-_ ]", "_") .. ".rpp", 0)
  end
  copy_text(band.log_dir() .. "/studiosync-" .. os.date("%Y-%m-%d") .. ".log", d .. "/log-" .. os.date("%Y-%m-%d") .. ".txt", 4 * 1024 * 1024)
  copy_text(band.home() .. "/errors.log", d .. "/errors.txt", 1024 * 1024)
  -- (yesterday's log file goes once today's starts: only the last two days are kept here)
  for _, f in ipairs(band.files(d, ".txt")) do
    local y, m, dd = f:match("^log%-(%d%d%d%d)%-(%d%d)%-(%d%d)%.txt$")
    if y and os.time() - os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 }) > 2 * 86400 then os.remove(d .. "/" .. f) end
  end
  return d
end

-- ---- the computer itself (0.59.40): written by Autostart, so it comes even with no studio project open, after a crash above all ----
-- The system's crash reports for REAPER: Windows Error Reporting's Report.wer files (UTF-16 text, a few KB, naming the module and place it
-- crashed in), a Mac's DiagnosticReports. Not the memory dumps: gigabytes each. -> { { name, text } }, newest last where the names say.
function dm.crash_reports()
  local out = {}
  if band.WIN then
    for _, base in ipairs({ "C:/ProgramData/Microsoft/Windows/WER/ReportArchive", "C:/ProgramData/Microsoft/Windows/WER/ReportQueue" }) do
      for _, sub in ipairs(band.subdirs(base)) do
        if sub:lower():find("^appcrash_reaper%.exe") then
          local t = band.read(base .. "/" .. sub .. "/Report.wer")
          if t then out[#out + 1] = { name = sub:sub(-12), text = (t:gsub("%z", ""):gsub("^\255\254", "")) } end
        end
      end
    end
  elseif band.MAC then
    local dir = (os.getenv("HOME") or "") .. "/Library/Logs/DiagnosticReports"
    for _, f in ipairs(band.files(dir)) do
      if f:find("^REAPER") and (f:find("%.ips$") or f:find("%.crash$")) then
        local t = band.read(dir .. "/" .. f)
        if t then out[#out + 1] = { name = f:gsub("%.%w+$", ""), text = #t > 200000 and t:sub(1, 200000) or t } end
      end
    end
    table.sort(out, function(a, x) return a.name < x.name end) -- (named for their date: the newest last)
  end
  while #out > 8 do table.remove(out, 1) end
  return out
end
-- What this computer is set up with: REAPER and its audio and MIDI devices, extensions, where StudioSync runs from, and whether REAPER
-- closed cleanly last time.
function dm.setup()
  local res = reaper.GetResourcePath()
  local s = { made = os.date("!%Y-%m-%dT%H:%M:%SZ"), studiosync = band.VERSION, run_from = reaper.GetExtState(band.SECTION, "run from"), reaper = reaper.GetAppVersion(),
    os = reaper.GetOS(), resource = res, audio = {}, midi_in = {}, midi_out = {}, extensions = {}, last_unclean = reaper.GetExtState(band.SECTION, "last unclean exit"),
    audio_running = reaper.Audio_IsRunning() == 1 }
  for _, k in ipairs({ "MODE", "IDENT_IN", "IDENT_OUT", "BSIZE", "SRATE", "BPS" }) do s.audio[k] = select(2, reaper.GetAudioDeviceInfo(k)) end
  for i = 0, reaper.GetNumMIDIInputs() - 1 do local present, n = reaper.GetMIDIInputName(i, ""); if n ~= "" then s.midi_in[#s.midi_in + 1] = i .. ": " .. n .. (present and "" or " (not here)") end end
  for i = 0, reaper.GetNumMIDIOutputs() - 1 do local present, n = reaper.GetMIDIOutputName(i, ""); if n ~= "" then s.midi_out[#s.midi_out + 1] = i .. ": " .. n .. (present and "" or " (not here)") end end
  local ini = band.read(res .. "/reaper.ini") or ""
  s.midi_enabled = { ins = ini:match("\nmidiins=(%-?%d+)"), outs = ini:match("\nmidiouts=(%-?%d+)") } -- (as REAPER last wrote them: which are switched on)
  for _, f in ipairs(band.files(res .. "/UserPlugins")) do if f:find("^reaper_") then s.extensions[#s.extensions + 1] = f end end
  return s
end
function dm.write_computer(cfg)
  local d = dm.dir(cfg.root, cfg.user)
  reaper.RecursiveCreateDirectory(d, 0)
  local ok, s = pcall(dm.setup)
  band.write_json(d .. "/computer.json", ok and s or { error = tostring(s) })
  local okc, crashes = pcall(dm.crash_reports)
  if okc then
    for _, c in ipairs(crashes) do
      local path = d .. "/crash " .. c.name:gsub("[^%w%-_ ]", "_") .. ".txt"
      if not reaper.file_exists(path) then pcall(band.write_atomic, path, c.text) end
    end
  end
  copy_text(band.log_dir() .. "/studiosync-" .. os.date("%Y-%m-%d") .. ".log", d .. "/log-" .. os.date("%Y-%m-%d") .. ".txt", 4 * 1024 * 1024)
  copy_text(band.home() .. "/errors.log", d .. "/errors.txt", 1024 * 1024)
  return d
end
-- REAPER closing cleanly or not (Autostart: at its start, and as REAPER quits). A start that finds the mark still there means the last
-- session ended without its quit: a crash, or the process ended.
function dm.session_start()
  local was = reaper.GetExtState(band.SECTION, "running since")
  if was ~= "" then
    reaper.SetExtState(band.SECTION, "last unclean exit", was, true)
    band.log("REAPER didn't close cleanly last time (it crashed, or was ended): the session from " .. was .. ". Debug mode sends the crash report")
  end
  reaper.SetExtState(band.SECTION, "running since", os.date("%Y-%m-%d %H:%M:%S"), true)
end
function dm.session_end() reaper.DeleteExtState(band.SECTION, "running since", true) end
-- Autostart, every pass: each studio with debug mode on gets this computer's report every 5 minutes, the first a minute after REAPER starts.
local computer_at = reaper.time_precise() - 240
function dm.computer_tick(me)
  if reaper.time_precise() - computer_at < 300 or not me or me == "" then return end
  computer_at = reaper.time_precise()
  for _, x in ipairs(band.bands()) do
    if dm.on(x.root) then pcall(dm.write_computer, { root = x.root, user = me }) end
  end
end

-- Live sync calls this every pass: a report every 5 minutes while the studio's debug mode is on.
local last_at = -math.huge
function dm.tick(cfg, proj, b)
  if reaper.time_precise() - last_at < 300 then return end
  last_at = reaper.time_precise()
  if dm.on(cfg.root) then pcall(dm.write, cfg, proj, b) end
end

return dm
