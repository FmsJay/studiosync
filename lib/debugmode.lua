-- Debug mode for a studio (James, 0.59.3: "a debug mode for anyone on my studios that saves all details to use later for debugging"). The
-- owner or an admin turns it on (band.json "debug", a trusted setting: lib/groups.lua); then every computer in the studio writes, every few
-- minutes, into <studio>/_debug/<name>/ (which Syncthing carries to everyone, so the owner has every computer's):
--   report.json   what this computer is and sees: versions, the project open, who drives, what's waiting to go out or come in, what was
--                 skipped, held or undone, the mirror's view of each track and item (ids, revisions, hashes), and the log's last lines
--   log-<date>.txt  today's whole log file (every script's lines and errors, lib/band.lua log_file)
--   errors.txt    the panel's and Live sync's errors (StudioSync home/errors.log), when there is one
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
      timeline = ext("timeline"), skipped = sync.skipped(proj), outbox = band.json_decode(reaper.GetExtState(band.SECTION, "outbox " .. tostring(proj))),
      put_back = band.json_decode(reaper.GetExtState(band.SECTION, "put back")), drift = reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj)) }
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
  copy_text(band.log_dir() .. "/studiosync-" .. os.date("%Y-%m-%d") .. ".log", d .. "/log-" .. os.date("%Y-%m-%d") .. ".txt", 4 * 1024 * 1024)
  copy_text(band.home() .. "/errors.log", d .. "/errors.txt", 1024 * 1024)
  -- (yesterday's log file goes once today's starts: only the last two days are kept here)
  for _, f in ipairs(band.files(d, ".txt")) do
    local y, m, dd = f:match("^log%-(%d%d%d%d)%-(%d%d)%-(%d%d)%.txt$")
    if y and os.time() - os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 }) > 2 * 86400 then os.remove(d .. "/" .. f) end
  end
  return d
end

-- Live sync calls this every pass: a report every 5 minutes while the studio's debug mode is on.
local last_at = -math.huge
function dm.tick(cfg, proj, b)
  if reaper.time_precise() - last_at < 300 then return end
  last_at = reaper.time_precise()
  if dm.on(cfg.root) then pcall(dm.write, cfg, proj, b) end
end

return dm
