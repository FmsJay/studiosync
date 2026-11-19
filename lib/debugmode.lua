-- Debug mode for a studio (James, 0.59.3: "a debug mode for anyone on my studios that saves all details to use later for debugging"). The
-- owner or an admin turns it on (band.json "debug", a trusted setting: lib/groups.lua); then every computer in the studio writes into
-- <studio>/_debug/<name>/ (which Syncthing carries to the owner and admins) at the end of each session, when a bug report is sent, and when
-- REAPER starts after it didn't close cleanly (a crash never reaches an end). Not every few minutes: nothing needs it sooner, and each copy of
-- a big project held REAPER up. James, 0.59.43:
--   report.json   what this computer is and sees: versions, the project open, who drives, what's waiting to go out or come in, what was
--                 skipped, held or undone, the mirror's view of each track and item (ids, revisions, hashes), and the log's last lines
--   log-<date>.txt  today's whole log file (every script's lines and errors, lib/band.lua log_file)
--   errors.txt    the panel's and Live sync's errors (StudioSync home/errors.log), when there is one
--   project <song>.rpp  a copy of the project open, as it is here (unsaved changes too; the project itself keeps its name). 0.59.40
--   computer.json  REAPER, audio and MIDI devices, extensions, where StudioSync runs from, whether REAPER closed cleanly last time
--   crash <id>.txt  REAPER's crash reports from the system (Windows Error Reporting, a Mac's DiagnosticReports), not the memory dumps
-- Only the owner and admins download everyone's (lib/songsync.lua debug lines); the others keep their own. computer.json and the crash
-- reports come from Autostart (as REAPER quits, and at the start after a crash), so they come with no studio project open too.
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
    local file = ""
    for i = 0, 512 do local p, f = reaper.EnumProjects(i); if not p then break end; if p == proj then file = f end end -- (this one's, not the tab in front: 0.59.44)
    r.project = { song = b.song, room = b.room, role = b.role, file = file, tracks = reaper.CountTracks(proj),
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
function dm.write(cfg, proj, b, why)
  local d = dm.dir(cfg.root, cfg.user)
  reaper.RecursiveCreateDirectory(d, 0)
  local ok, r = pcall(dm.report, cfg, proj, b)
  if not ok then r = { made = os.date("!%Y-%m-%dT%H:%M:%SZ"), user = cfg.user, error = tostring(r) } end
  r.why = why -- (what it was made for: "end of session", "bug report", ...)
  band.write_json(d .. "/report.json", r)
  -- (the project itself, as it is here now, unsaved changes too, as a copy: the project keeps its own name and stays unsaved. Not while
  -- recording. James, 0.59.40: "all projects from other users ... lands on this pc")
  if b and proj and reaper.ValidatePtr2(0, proj, "ReaProject*") and reaper.GetPlayStateEx(proj) & 4 == 0 then
    pcall(band.save_copy, proj, d .. "/project " .. tostring(b.song):gsub("[^%w%-_ ]", "_") .. ".rpp") -- (its unsaved mark kept: Round 1 review, 0.59.45)
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
-- (Windows names its folders by hashes, so the eight kept were the last by name, not the newest: on the desktop, eight from 11-03 and none of
-- the 11-15..18 crashes. Now by each report's own EventTime, read from its first few hundred bytes; hangs too; the full text only for the
-- newest. `have(name)`: true when that one was sent already (not read again). Full review, 0.59.44)
local function head(path, n)
  local f = io.open(path, "rb")
  if not f then return nil end
  local t = f:read(n)
  f:close()
  return t
end
function dm.crash_reports(have)
  local out = {}
  if band.WIN then
    local pd = (os.getenv("ProgramData") or "C:/ProgramData"):gsub("\\", "/")
    local found = {}
    for _, base in ipairs({ pd .. "/Microsoft/Windows/WER/ReportArchive", pd .. "/Microsoft/Windows/WER/ReportQueue" }) do
      for _, sub in ipairs(band.subdirs(base)) do
        local low = sub:lower()
        if low:find("^appcrash_reaper%.exe") or low:find("^apphang_reaper%.exe") then
          local h = head(base .. "/" .. sub .. "/Report.wer", 600)
          local at = h and tonumber((h:gsub("%z", "")):match("EventTime=(%d+)"))
          if at then found[#found + 1] = { name = sub:sub(-12), path = base .. "/" .. sub .. "/Report.wer", at = at } end
        end
      end
    end
    table.sort(found, function(a, x) return a.at > x.at end)
    for i = 1, math.min(8, #found) do
      local c = found[i]
      local t = not (have and have(c.name)) and band.read(c.path)
      out[#out + 1] = { name = c.name, text = t and (t:gsub("%z", ""):gsub("^\255\254", "")) or nil, at = c.at }
    end
    return out
  elseif band.MAC then
    -- (only the newest eight read, and those not sent already: every one was read whole first. And by the date in the name: "REAPER-" sorted
    -- before "REAPER_" whatever the date. Round 1 review, 0.59.45)
    local dir = (os.getenv("HOME") or "") .. "/Library/Logs/DiagnosticReports"
    local found = {}
    for _, f in ipairs(band.files(dir)) do
      if f:find("^REAPER") and (f:find("%.ips$") or f:find("%.crash$")) then found[#found + 1] = { name = f:gsub("%.%w+$", ""), f = f, at = f:gsub("^REAPER[^%d]*", "") } end
    end
    table.sort(found, function(a, x) return a.at < x.at end) -- (named for their date: the newest last)
    for i = math.max(1, #found - 7), #found do
      local c = found[i]
      local t = not (have and have(c.name)) and head(dir .. "/" .. c.f, 200000)
      out[#out + 1] = { name = c.name, text = t or nil }
    end
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
  local function crash_path(name) return d .. "/crash " .. name:gsub("[^%w%-_ ]", "_") .. ".txt" end
  local okc, crashes = pcall(dm.crash_reports, function(name) return reaper.file_exists(crash_path(name)) end)
  if okc then
    local keep = {}
    for _, c in ipairs(crashes) do
      local path = crash_path(c.name)
      keep[path:match("[^/]+$")] = true
      if c.text and not reaper.file_exists(path) then pcall(band.write_atomic, path, c.text) end
    end
    -- (only the newest eight stay: older ones went on piling up. 0.59.44)
    for _, f in ipairs(band.files(d, ".txt")) do if f:find("^crash ") and not keep[f] then os.remove(d .. "/" .. f) end end
  end
  copy_text(band.log_dir() .. "/studiosync-" .. os.date("%Y-%m-%d") .. ".log", d .. "/log-" .. os.date("%Y-%m-%d") .. ".txt", 4 * 1024 * 1024)
  copy_text(band.home() .. "/errors.log", d .. "/errors.txt", 1024 * 1024)
  return d
end
-- REAPER closing cleanly or not (Autostart: at its start, and as REAPER quits). A start that finds the mark still there means the last
-- session ended without its quit: a crash, or the process ended.
-- -> true when the last session ended without its quit.
function dm.session_start()
  local was = reaper.GetExtState(band.SECTION, "running since")
  if was ~= "" then
    reaper.SetExtState(band.SECTION, "last unclean exit", was, true)
    band.log("REAPER didn't close cleanly last time (it crashed, or was ended): the session from " .. was .. ". Debug mode sends the crash report")
  end
  reaper.SetExtState(band.SECTION, "running since", os.date("%Y-%m-%d %H:%M:%S"), true)
  return was ~= ""
end
function dm.session_end() reaper.DeleteExtState(band.SECTION, "running since", true) end
-- This computer's part, for each studio with debug mode on (Autostart: as REAPER quits, and at the start after a crash; a bug report).
function dm.computer_all(me)
  if not me or me == "" then return end
  pcall(dm.tell, me) -- (told before anything is collected: Round 1 review, 0.59.45)
  for _, x in ipairs(band.bands()) do
    if dm.on(x.root) then pcall(dm.write_computer, { root = x.root, user = me }) end
  end
end
-- Each computer is told once that debug mode is on in a studio (Autostart, at its start): it was said only on the admin's own computer, and
-- the people whose reports it sends never knew. Told again if it's switched off and on. Full review, 0.59.44.
-- The words for it, for the log and the panel's Debug pill.
function dm.notice(name)
  return "Debug mode is on in " .. tostring(name) .. ": at the end of each session, with each bug report and after a crash, " ..
    "this computer saves a report, a copy of this project as you have it (unsent and local work too), its setup, its log and REAPER's crash " ..
    "reports into the studio's _debug folder, for the owner and admins. The owner or an admin can switch it off in Settings > Studio" -- (Round 2 review, 0.59.46: what the copy holds)
end
-- (Round 1 review, 0.59.45: also from dm.collect and dm.computer_all, before anything is written, so debug mode switched on mid-session is told
-- before that session's end sends anything; Autostart's start alone told it only at the next start.)
function dm.tell(me)
  for _, x in ipairs(band.bands()) do
    local key = "debug told " .. tostring(band.info(x.root).id)
    local on = dm.on(x.root)
    if on and reaper.GetExtState(band.SECTION, key) == "" then
      reaper.SetExtState(band.SECTION, key, "1", true)
      band.log(dm.notice(band.info(x.root).name))
    elseif not on and reaper.GetExtState(band.SECTION, key) ~= "" then
      reaper.DeleteExtState(band.SECTION, key, true)
    end
  end
end
-- A project's part, if its studio has debug mode on (Live sync: its session ending; a bug report). `why`: what it's for.
function dm.collect(cfg, proj, b, why)
  if cfg and cfg.root and dm.on(cfg.root) then pcall(dm.tell, cfg.user); pcall(dm.write, cfg, proj, b, why) end
end
-- For the panel's "Debug" pill: the studio in front (cfg.root) first, else any studio here with debug mode on. -> its name and the notice, or
-- nil. Looked at every 5 s at most (the panel asks each frame). Round 1 review, 0.59.45.
local any_at, any_name = -math.huge, nil
function dm.on_any(cfg)
  local now = reaper.time_precise()
  if now - any_at >= 5 or now < any_at then
    any_at, any_name = now, nil
    if cfg and cfg.root and cfg.root ~= "" and dm.on(cfg.root) then any_name = band.info(cfg.root).name
    else for _, x in ipairs(band.bands()) do if dm.on(x.root) then any_name = x.name; break end end end
  end
  if any_name then return any_name, dm.notice(any_name) end
end

return dm
