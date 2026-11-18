-- Rooms: a song's main room, and side rooms people make to try their own edits (or work on something else) and
-- have everyone come and see. Each room is its own project tab, so going between them is a tab switch: nothing
-- reloads. A side room starts as a copy of the room it came from, as it was then:
--   rooms/<room>/room.json   { parent = "main", by, time, base = <its first recall point: the parent as it was> }
-- What's good goes back to the parent with "Bring into" (lib/mirror.lua plan_bring / post_into: every side-room change that
-- doesn't clash, the clashes listed to pick). (The take-based plan/merge that lived here went in 0.58.97: nothing used it.)
local band = require("band")
local sync = require("sync")
local rooms = {}

function rooms.meta(cfg, song, room) return band.read_json(sync.room_dir(cfg, song, room) .. "/room.json") end

local function file_of(proj)
  for i = 0, math.huge do
    local p, f = reaper.EnumProjects(i)
    if not p then return nil end
    if p == proj then return f end
  end
end

-- This machine's tab of song/room (never a Solo edit copy), or nil.
function rooms.tab(song, room)
  for i = 0, math.huge do
    local p, f = reaper.EnumProjects(i)
    if not p then return nil end
    local b = f ~= "" and band.binding(p) -- (no file name: a backup left open, which carries the room it was saved from)
    if b and b.song == song and b.room == room and b.role ~= "solo" then return p end
  end
end

-- The song's rooms, main first, then rooms the host gathers (older StudioSync), then side rooms oldest first:
-- { name, parent, by, time }
function rooms.list(cfg, song)
  local out = {}
  for _, name in ipairs(band.subdirs(band.song_dir(cfg, song) .. "/rooms")) do
    local m = rooms.meta(cfg, song, name) or {}
    out[#out + 1] = { name = name, parent = m.parent, by = m.by, time = m.time or "", binned = m.binned }
  end
  table.sort(out, function(a, z)
    if (a.name == "main") ~= (z.name == "main") then return a.name == "main" end
    if (a.parent == nil) ~= (z.parent == nil) then return a.parent == nil end
    return (a.time .. a.name) < (z.time .. z.name)
  end)
  return out
end

-- Binning a side room takes it off the list, nothing more: its folder and history stay, and it can be brought back (laptop,
-- 0.42.9: no way to get rid of an idea that didn't work). `who`: who binned it, or nil to bring it back.
function rooms.bin(cfg, song, room, who)
  local m = rooms.meta(cfg, song, room)
  if not m then return end
  m.binned = who
  band.write_json(sync.room_dir(cfg, song, room) .. "/room.json", m)
end

-- Who's in a room: { {user, here, me} }. Bandmates from their status receipts (under 45 s old; `here` = it's the
-- tab in front of them), you from your own tabs.
function rooms.people(cfg, song, room)
  local out = {}
  local dir = sync.room_dir(cfg, song, room) .. "/status"
  for _, f in ipairs(band.files(dir, ".json")) do
    local st = band.read_json(dir .. "/" .. f)
    if type(st) == "table" and type(st.user) == "string" and st.user ~= cfg.user and type(st.time) == "string"
        and band.age(st.time) < 45 then
      out[#out + 1] = { user = st.user, here = st.front ~= false } -- (receipts before 0.16 don't say)
    end
  end
  table.sort(out, function(a, z) return a.user < z.user end)
  local p = rooms.tab(song, room)
  if p then table.insert(out, 1, { user = cfg.user, here = p == reaper.EnumProjects(-1), me = true }) end
  return out
end

-- Live plug-ins carry this machine's identity: a second connected SonoBus (or ReaNINJAM) in another tab would
-- join the band twice. A new room's tab starts with them offline; Same room there turns SonoBus on.
local function live_offline(proj)
  for t = -1, reaper.CountTracks(proj) - 1 do
    local tr = t < 0 and reaper.GetMasterTrack(proj) or reaper.GetTrack(proj, t)
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, name = reaper.TrackFX_GetFXName(tr, i, "")
      if name:find("SonoBus", 1, true) or name:find("ReaNINJAM", 1, true) then reaper.TrackFX_SetOffline(tr, i, true) end
    end
  end
end

-- Go to a room: its tab if open here; else the tab it had here before (its file, reopened); else a new tab made
-- from this machine's tab of the room it came from, saved next to it (same media paths, nothing copied).
-- `from` is the tab asking (any room of the song). Returns the tab, or nil + why. Doesn't start Live sync there.
function rooms.open(from, cfg, b, name, copy_dir)
  local p = rooms.tab(b.song, name)
  if p then reaper.SelectProjectInstance(p); return p end
  local m = rooms.meta(cfg, b.song, name)
  local src = not copy_dir and m and m.parent and rooms.tab(b.song, m.parent) or from -- (copy_dir: made from `from` itself, a backup, wherever the room's own tab is)
  local src_file = file_of(src) or ""
  if src_file == "" and not copy_dir then return nil, "Save this project first." end
  local path = (copy_dir or src_file:gsub("\\", "/"):match("^(.*)/")) .. "/" .. b.song .. " - " .. name:gsub("[^%w%-_ ]", "") .. " (room).rpp"
  local fresh = not reaper.file_exists(path)
  if fresh then reaper.Main_SaveProjectEx(src, path, 0) end -- a copy; the open project keeps its own file
  reaper.Main_OnCommand(40859, 0) -- File: New project tab
  require("startup").open_quietly(function() reaper.Main_openProject("noprompt:" .. path) end)
  p = reaper.EnumProjects(-1)
  if file_of(p) ~= path and (file_of(p) or ""):gsub("\\", "/") ~= path then return nil, "REAPER didn't open " .. path end
  if fresh then
    local nb = {}
    for k, v in pairs(band.binding(src) or b) do nb[k] = v end
    -- a host gathers the rooms of older StudioSync into its project: a side room's tab never does
    nb.room, nb.role = name, nb.role == "host" and "guest" or nb.role
    band.bind(p, nb)
    for _, k in ipairs({ "alone_last", "side", "hold" }) do reaper.SetProjExtState(p, band.SECTION, k, "") end
    live_offline(p)
    reaper.Main_SaveProject(p, false)
    pcall(rooms.note_prints, path, cfg, b.song, name)
  end
  return p
end
-- The prints a side room's new copy plays (its items came from the room it was made from, and no change of its own names their prints): kept
-- in the room's folder per computer, so the history trim leaves them (lib/trim.lua). Left item of the 0.58.98 review, done 0.59.10.
function rooms.note_prints(path, cfg, song, name)
  local seen, list = {}, {}
  for n in (band.read(path) or ""):gmatch("[/\\](print%-[^/\\\"]+)%.flac") do if not seen[n] then seen[n] = true; list[#list + 1] = n end end
  table.sort(list)
  local dir = sync.room_dir(cfg, song, name)
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/plays-" .. tostring(cfg.user):gsub("[^%w%-_]", "_") .. ".json", list)
end

-- Why a room name can't be used, or nil. Pure. (Windows can't make folders called CON, NUL, COM1... at all.)
function rooms.bad_name(name)
  if not name:match("^[%w][%w %-_]*$") or #name > 30 then return "Room names: up to 30 letters, numbers, spaces, - or _." end
  local l = name:lower():gsub("%s+$", "")
  if l == "con" or l == "prn" or l == "aux" or l == "nul" or l:match("^com%d$") or l:match("^lpt%d$") then
    return "'" .. name .. "' is a name Windows keeps for itself: pick another."
  end
end

-- Make a side room from the room in tab `proj` (binding b), as it is now, and go there. You drive it. copy_dir: see rooms.open.
function rooms.create(proj, cfg, b, name, copy_dir)
  name = (name or ""):match("^%s*(.-)%s*$")
  local err = rooms.bad_name(name)
  if err then return nil, err end
  for _, r in ipairs(rooms.list(cfg, b.song)) do
    if r.name:lower() == name:lower() then return nil, "There's already a room called '" .. r.name .. "'." end
  end
  local dir = sync.room_dir(cfg, b.song, name)
  for _, sub in ipairs({ "takes", "events", "recall", "_trash" }) do reaper.RecursiveCreateDirectory(dir .. "/" .. sub, 0) end
  local base = require("recall").save(proj, cfg, b.song, name, "made from " .. b.room, true)
  sync.set_driver(cfg, b.song, name, cfg.user)
  band.write_json(dir .. "/room.json", { parent = b.room, by = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), base = base,
    tempo = band.capture_tempo(proj), markers = band.capture_markers(proj) }) -- (its history starts here: sync.restore_timeline)
  return rooms.open(proj, cfg, b, name, copy_dir)
end

-- ---- a backup or autosave opened by hand --------------------------------------------------------------------
-- It carries the song's binding but isn't this computer's project for it. Started as it was, the studio's newer versions came in over it and
-- what nobody had went straight out to everyone, with no say (James, 0.57.7). So it isn't synced: it can become a side room, or be looked at.
-- As a side room its unsent edits go out to that room alone, which is what Bring into main then offers; anything older is there to Send selected.
function rooms.own_files(cfg, song) -- this computer's usual places for the song, lower case with forward slashes. Pure but for the settings.
  local out = {}
  local sid = band.studio_key(cfg.root)
  for _, d in ipairs({ band.home() .. "/" .. song .. "/", sid ~= "" and (band.home() .. "/" .. sid .. "/" .. song .. "/") or nil }) do
    local here = d:gsub("\\", "/"):lower()
    out[#out + 1] = here .. song:lower() .. ".rpp"
    out[#out + 1] = here .. song:lower() .. " - " .. tostring(cfg.user):lower() .. ".rpp"
  end
  return out
end
rooms.file_of = file_of
function rooms.is_copy(proj, cfg, b)
  if not b or b.role == "solo" then return false end
  local f = file_of(proj) or ""
  if f == "" then return true end -- (REAPER opens an .rpp-bak with no file name, "[Unsaved]": only a backup is bound and has none. Mac, 0.58.3)
  if band.autosync(f) then return false end
  local low = f:gsub("\\", "/"):lower()
  if low:find(" (room).rpp", 1, true) then return false end
  if low == band.project_file(band.for_tab(cfg, b).root, b.song):gsub("\\", "/"):lower() then return false end
  for _, own in ipairs(rooms.own_files(cfg, b.song)) do if low == own then return false end end
  return true
end
function rooms.from_backup(proj, cfg, b)
  local stem = "backup " .. os.date("%m%d-%H%M")
  local name, n = stem, 1
  local taken = {}
  for _, r in ipairs(rooms.list(cfg, b.song)) do taken[r.name:lower()] = true end
  while taken[name:lower()] do n = n + 1; name = stem .. " " .. n end
  local file = band.project_file(band.for_tab(cfg, b).root, b.song):gsub("\\", "/"):match("^(.*)/")
  local dir = file or (band.home() .. "/" .. b.song):gsub("\\", "/")
  reaper.RecursiveCreateDirectory(dir, 0)
  local from = { }
  for k, v in pairs(b) do from[k] = v end
  from.room = from.room or "main"
  local p, why = rooms.create(proj, cfg, from, name, dir)
  return p, why or name
end

-- ---- come see ---------------------------------------------------------------------------------------------
-- One file per person (<song>/invites/<user>.json), replaced by their next invite.
function rooms.invite(cfg, song, room)
  local dir = band.song_dir(cfg, song) .. "/invites"
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/" .. (cfg.user:gsub("[^%w%-_]", "_")) .. ".json",
    { from = cfg.user, room = room, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
end

-- Bandmates' invites from the last 15 minutes: { {from, room, time} }
function rooms.invites(cfg, song)
  local dir, out = band.song_dir(cfg, song) .. "/invites", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local v = band.read_json(dir .. "/" .. f)
    if type(v) == "table" and type(v.from) == "string" and v.from ~= cfg.user and type(v.room) == "string"
        and type(v.time) == "string" and band.age(v.time) < 900 then out[#out + 1] = v end
  end
  return out
end

return rooms
