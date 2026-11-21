-- Storage modes for the cloud copy (James, 2026-11-20: "different options for what's stored in cloud to keep it smaller if needed, just the
-- bare essentials to get a full project back without any restore or anything would be the lowest option"). The studio's owner or an admin
-- picks one (band.json "cloud_storage" = { mode, days, limit_mb }, a trusted setting: lib/groups.lua), and every computer goes by it:
--   essentials  the project as it stands: each object's newest change (and what a pending merge is rebuilt from: trim.plan with no saved
--               versions), the recordings those play (lanes that play only), plug-in chains, MIDI and tombstones. No older changes, saved
--               versions, takes, trash or end-of-session projects.
--   standard    essentials, plus the last `days` days: changes, saved versions (and the changes they restore to), what those play, takes
--               and end-of-session projects.
--   everything  all of it, as before (the default: a studio that never picks one keeps today's behaviour exactly).
-- And a size limit (MB) on top of any mode: past it, the oldest non-essential files go first; essentials never go (Health says when they alone
-- are over).
-- What the mode leaves out isn't sent up (drive.mirror asks cm.filter), and what's already in the cloud copy is removed from it, never from
-- anyone's computer. Each computer removes its own files (drive.mine's one-writer rule; on Google Drive someone else's file is only unlinked
-- from the folder), and the owner's computer anyone's once it has been unwanted an hour (a member who's gone). A removed file goes to the
-- service's own trash (Google Drive, Dropbox, OneDrive, Box and iCloud keep deleted files about 30 days), and a change to a smaller mode is
-- listed and confirmed first (Settings > Options > Cloud copy).
-- What each file is to the modes is judged from the cloud copy's own changes (cm.judge with the cloud's events): a newer change only on this
-- computer never makes the cloud's older one look unneeded before the newer is up. Recordings are judged from every change either side has
-- (keeping more is always safe).
local band = require("band")
local cm = {}
cm.DAYS, cm.EVERY, cm.OTHERS_WAIT = 14, 600, 3600 -- (Standard's window; a sweep of the cloud copy at most every 10 minutes; see above)
cm.RANK = { essentials = 1, standard = 2, everything = 3 }
cm.TIER = { essential = 1, recent = 2, other = 3 }
local TIER_NAME = { "essential", "recent", "other" }
cm.MODES = {
  { "essentials", "Essentials", "Just enough to get every project back as it stands now: its current state, the recordings it plays (lanes that " ..
    "play) and its plug-in chains. No history, saved versions, takes, trash or end-of-session projects." },
  { "standard", "Standard", "Essentials, plus the last few days: changes, saved versions, takes and end-of-session projects." },
  { "everything", "Everything", "All of it, as before: every change, saved version, take and recording." },
}

-- band.json's value, as anyone in the studio may have written it (groups.trusted keeps the last one a manager wrote): -> { mode, days,
-- limit_mb }. Pure.
function cm.clean(t)
  t = type(t) == "table" and t or {}
  local days, limit = tonumber(t.days) or cm.DAYS, tonumber(t.limit_mb) or 0
  if days ~= days then days = cm.DAYS end -- (NaN)
  if limit ~= limit then limit = 0 end
  days = math.max(1, math.min(365, math.floor(days)))
  limit = limit >= 1 and limit < 1e9 and math.floor(limit) or nil
  return { mode = cm.RANK[t.mode] and t.mode or "everything", days = days, limit_mb = limit }
end
function cm.settings(root)
  local ok, t = pcall(function() return require("groups").trusted(root).cloud_storage end)
  return cm.clean(ok and t or nil)
end
cm.settings_for = cm.settings -- (tests stand a studio's setting in here)
-- The owner's or an admin's choice for everyone (the panel checks who may first). Everything with no limit is no setting at all.
function cm.set(root, t)
  local c = cm.clean(t)
  return require("groups").edit(root, function(j) j.cloud_storage = (c.mode ~= "everything" or c.limit_mb) and c or nil end)
end
local function active(s) return s.mode ~= "everything" or s.limit_mb ~= nil end
function cm.allowed(tier, mode) return cm.TIER[tier] <= cm.RANK[mode] end

-- "20261120-013000Z" anywhere in a name -> "2026-11-20T01:30:00Z" (saved versions, takes, end-of-session projects are named so), else "". Pure.
function cm.stamp_time(name)
  local y, mo, d, h, mi, s = tostring(name):match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z")
  return y and (y .. "-" .. mo .. "-" .. d .. "T" .. h .. ":" .. mi .. ":" .. s .. "Z") or ""
end
function cm.cutoff(now, days) return os.date("!%Y-%m-%dT%H:%M:%SZ", now - days * 86400) end

-- What the modes need of one change: what trim.plan orders by, the recordings an item plays and its lane, a track's lanes. `room`: the room
-- whose folder it's in (an older change names its own room's media as "{media}"). -> a record, or false. Pure.
function cm.rec(ev, room)
  if type(ev) ~= "table" or type(ev.id) ~= "string" then return false end
  local function s(v) return type(v) == "string" and v or nil end
  local r = { id = ev.id, type = s(ev.type), oid = s(ev.oid), rev = tonumber(ev.rev), time = s(ev.time), user = s(ev.user), hlc = tonumber(ev.hlc),
    order = s(ev.order), base_ev = s(ev.base_ev), gone = ev.gone == true or nil, obj = s(ev.obj), track = s(ev.track) }
  if type(ev.state) == "string" then
    r.media = {}
    for rm, rel in ev.state:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do r.media[#r.media + 1] = { rm, rel } end
    for rel in ev.state:gmatch('FILE "{media}/([^"]+)"') do r.media[#r.media + 1] = { room, rel } end
    r.lane = tonumber(ev.state:match("BANDLANE (%d+)"))
  elseif type(ev.state) == "table" and r.obj == "track" then
    r.freemode, r.lanes, r.plays = tonumber(ev.state.freemode), tonumber(ev.state.lanes), s(ev.state.plays)
  end
  return r
end

-- Does a track play lane `lane`? A track not in fixed lanes, or with none marked playing, plays what it holds. Keeping more is safe, so
-- anything unclear counts as playing. Pure.
function cm.lane_plays(track, lane)
  if not (track and lane) or (track.freemode or 0) ~= 2 or (track.lanes or 0) < 2 or not track.plays then return true end
  local list, any = {}, false
  for v in (track.plays .. ","):gmatch("([^,]*),") do
    list[#list + 1] = tonumber(v) or 0
    if list[#list] ~= 0 then any = true end
  end
  return not any or list[lane + 1] == nil or list[lane + 1] ~= 0
end

local memo = setmetatable({}, { __mode = "k" }) -- (records list -> { [points/cutoff] = ids trim would take }: a song's rooms are judged per room)
-- (the sweep judges a few rooms' plans a pass, not all at once: trim.plan of a 2,500-change room is 40-90 ms, four a room, and the sweep's
-- room took 331 ms in one go on REAPER's thread on the desktop (more in a test). While `plan_until` is set, a plan not made yet isn't started
-- after it: cm.LATER, and the sweep carries on next pass from the plans already made. rt-drive2)
cm.LATER = setmetatable({}, { __tostring = function() return "cloud storage: carries on next pass" end })
local plan_until, plan_made -- (and whether this pass made one: one always may be, or a pass whose time went before it made none, ever. rt-drive2, round 4)
local progress = 0 -- (steps the sweep has made: drive.bg_step's back-off counts them as something happening)
function cm.progress() return progress end
local function dropped(evs, points, cutoff, tag)
  local m = memo[evs] or {}
  memo[evs] = m
  local k = tag .. "\0" .. cutoff
  if not m[k] then
    if plan_until and plan_made and reaper.time_precise() > plan_until then error(cm.LATER, 0) end
    -- (trim.plan only ever takes changes older than `cutoff`: with none, nothing, and no plan. Its saved versions' part was 80-200 ms a room
    -- in Standard's window, for no ids at all in a studio younger than the window)
    local old, ids = false, {}
    for _, e in ipairs(evs) do if type(e.time) == "string" and e.time < cutoff then old = true; break end end
    if old then for _, id in ipairs(require("trim").plan(evs, points, cutoff)) do ids[id] = true end end
    m[k], progress, plan_made = ids, progress + 1, true
  end
  return m[k]
end

-- How `room`'s files stand with the modes: judge(sub, file) -> tier ("essential", "recent", "other") and age (ISO time, "" unknown).
-- evs: the changes the room's own files are judged by (the cloud's, for what the cloud keeps); rooms: { [room] = records } of every room of the
-- song (recordings played from any); points: the room's saved versions { time, keep, label, known }; cutoff: Standard's window (ISO). Pure.
function cm.judge(room, evs, rooms, points, cutoff)
  local recent = {}
  for _, p in ipairs(points or {}) do if (p.time or "") >= cutoff then recent[#recent + 1] = p end end
  local ess, std = dropped(evs, {}, "~", "e"), dropped(evs, recent, cutoff, "s" .. #recent)
  local by_id = {}
  for _, e in ipairs(evs) do by_id[e.id] = e end
  local mtier, mage = {}, {}
  for r, list in pairs(rooms) do
    local e_ess, e_std = dropped(list, {}, "~", "e"), dropped(list, r == room and recent or {}, cutoff, "s" .. (r == room and #recent or 0))
    local tracks = {} -- (each track's newest change still standing: which lanes play)
    for _, e in ipairs(list) do
      if e.obj == "track" and e.oid and not e_ess[e.id] then
        local t = tracks[e.oid]
        if not t or (e.time or "") .. e.id > (t.time or "") .. t.id then tracks[e.oid] = e end
      end
    end
    for _, e in ipairs(list) do
      for _, m in ipairs(e.media or {}) do
        if m[1] == room then
          local f = m[2]
          if (e.time or "") > (mage[f] or "") then mage[f] = e.time end
          local t = (not e_ess[e.id] and not e.gone and cm.lane_plays(tracks[e.track], e.lane)) and 1 or (not e_std[e.id] and 2 or 3)
          mtier[f] = math.min(mtier[f] or 3, t)
        end
      end
    end
  end
  return function(sub, f)
    if sub == "events" then
      local e = by_id[(f:gsub("%.json$", ""))]
      if not e then return "essential", "" end -- (not read as a change of ours: left alone)
      return (not ess[e.id] and "essential" or not std[e.id] and "recent" or "other"), e.time or ""
    elseif sub == "media" then
      return TIER_NAME[mtier[f] or 3], mage[f] or ""
    elseif sub == "recall" or sub == "recall/known" or sub == "takes" then
      local age = cm.stamp_time(f)
      return (age ~= "" and age >= cutoff) and "recent" or "other", age
    elseif sub == "_trash" or sub == "_trash/media" then
      return "other", cm.stamp_time(f)
    end
    return "essential", "" -- (midi, deleted, trimmed, fx: small, and what the project is)
  end
end
-- Kept under settings `s`, given the size limit's cut (the last sweep's)? Pure.
function cm.keeps(tier, age, s, cut)
  if not cm.allowed(tier, s.mode) then return false end
  return tier == "essential" or not cut or age > cut
end

-- The size limit: items { {tier, age, bytes} } the cloud copy keeps under the mode; limit: bytes. -> the age at or before which non-essential
-- files go, oldest first (nil: none need to), and whether the essentials alone are over. Files of the same age go together. Pure.
function cm.limit_cut(items, limit)
  local total, ess = 0, 0
  for _, it in ipairs(items) do total = total + it[3]; if it[1] == "essential" then ess = ess + it[3] end end
  if not limit or total <= limit then return nil, false end
  local list = {}
  for _, it in ipairs(items) do if it[1] ~= "essential" then list[#list + 1] = it end end
  table.sort(list, function(a, z) return a[2] < z[2] end)
  local cut, i = nil, 1
  while total > limit and list[i] do
    cut = list[i][2]
    while list[i] and list[i][2] == cut do total = total - list[i][3]; i = i + 1 end
  end
  return cut, ess > limit
end

-- ---- reading: changes and saved versions are written once, so each file is read once ----
local recs, pts = {}, {} -- path -> record (or false)
-- (every cloud read and write here goes through `C`, lib/drivebg.lua: on REAPER's thread as before, or from the background worker's listings)
local function C() return require("drivebg").C end
-- A change file drive.lua has just parsed (`ev`, the file at `p` in room `room`'s events folder of the studio folder): its record kept, as
-- read_events would make it. drive.note_event is the other way round. rt-drive2, round 3
function cm.note(p, ev, room)
  if recs[p] == nil and room then
    local r = cm.rec(ev, room)
    if r and r.id .. ".json" == p:match("[^/]+$") then recs[p], progress = r, progress + 1 end
  end
end
-- (a folder being read over several passes keeps the listing it started from, and the studio folder's names: listing 2,500 changes on each
-- side every pass was most of a pass. Once through, it's listed again for what came meanwhile. rt-drive2)
local reading = {}
-- `twin`: the studio folder's events folder, whose copy of a cloud file is read instead (the same file).
local function read_events(dir, room, deadline, twin)
  local out = {}
  local rd = reading[dir]
  if not rd then
    rd = { files = C().files(dir, ".json") }
    if twin then rd.twin = {}; for _, f in ipairs(band.files(twin, ".json")) do rd.twin[f] = true end end
  end
  -- (some reading each call, however long the listing took: a big room's listing alone outlasted a planned pass's budget, and the sweep never
  -- got past it. rt-perfcut1, as drive.lua's read_events)
  if deadline then deadline = math.max(deadline, reaper.time_precise() + require("drive").READ_MIN) end
  for _, f in ipairs(rd.files) do
    local p = (rd.twin and rd.twin[f]) and (twin .. "/" .. f) or (dir .. "/" .. f)
    local r = recs[p]
    if r == nil then
      if deadline and reaper.time_precise() > deadline then reading[dir] = rd; return nil end
      local j = C().read_json(p)
      r = cm.rec(j, room)
      if r and r.id .. ".json" ~= f then r = false end
      if r then
        recs[p], progress = r, progress + 1 -- (one not readable yet may still be arriving: read again next time)
        if not C().cloud(p) then require("drive").note_event(p, j) end -- (the studio folder's: drive.lua's record from the same parse)
      end
    end
    if r then out[#out + 1] = r end
  end
  if reading[dir] then reading[dir] = nil; return read_events(dir, room, deadline, twin) end
  return out
end
local function read_points(dirs, deadline) -- (-> nil once `deadline` has passed with some unread: those read are kept)
  local out, seen, read_one = {}, {}, false -- (one read each call at least: rt-drive2, round 4)
  for _, dir in ipairs(dirs) do
    for _, f in ipairs(C().files(dir, ".json")) do
      if not seen[f] then
        seen[f] = true
        local p = dir .. "/" .. f
        if pts[p] == nil then
          if deadline and reaper.time_precise() > deadline and read_one then return nil end
          progress, read_one = progress + 1, true
          local j = C().read_json(p)
          pts[p] = type(j) == "table" and type(j.time) == "string" and { time = j.time, keep = j.keep, label = j.label, file = f } or false
          if pts[p] then
            local k = C().read_json(dir .. "/known/" .. f) -- (its map, as recall.known reads it: the sidecar, else the one inside)
            if type(k) ~= "table" then k = not j.behind and j.known or nil end
            pts[p].known = type(k) == "table" and k or nil
          end
        end
        if pts[p] then out[#out + 1] = pts[p] end
      end
    end
  end
  return out
end
local function set_of(list) local s = {}; for _, f in ipairs(list) do s[f] = true end; return s end
local function rooms_of(dir) return C().subdirs(dir) end
local function split(here) return here:gsub("\\", "/"):match("^(.*)/([^/]+)/rooms/([^/]+)$") end

-- ---- what a pass sends up ----
-- drive.mirror's filter for room folder `here`: fn(sub, file) -> whether the cloud copy keeps it; nil (Everything, no limit: as before); false
-- while the song's changes are still being read (`deadline`, time_precise): the pass carries on next time.
local filters = {}
function cm.filter(here, deadline)
  local root, song, room = split(here)
  if not root then return nil end
  local s = cm.settings_for(root)
  if not active(s) then return nil end
  local rooms_dir = root .. "/" .. song .. "/rooms"
  local rooms, sig = {}, { s.mode, s.days, cm.cut or "" }
  for _, r in ipairs(rooms_of(rooms_dir)) do
    local list = read_events(rooms_dir .. "/" .. r .. "/events", r, deadline)
    if not list then return false end
    rooms[r] = list
    sig[#sig + 1] = r .. "=" .. #list
  end
  local points = read_points({ here .. "/recall" })
  local cutoff = cm.cutoff(os.time(), s.days)
  sig[#sig + 1] = #points .. "|" .. cutoff:sub(1, 13) -- (the window moves: judged again each hour)
  local key = table.concat(sig, "|")
  local c = filters[here]
  if c and c.key == key then return c.fn end
  local judge, cut = cm.judge(room, rooms[room] or {}, rooms, points, cutoff), cm.cut
  local fn = function(sub, f) local t, age = judge(sub, f); return cm.keeps(t, age, s, cut) end
  filters[here] = { key = key, fn = fn }
  return fn
end

-- ---- the sweep: what the cloud copy holds, what each mode would, and what goes ----
cm.SUBS = { "events", "recall", "recall/known", "media", "takes", "_trash", "_trash/media", "midi", "deleted", "trimmed" }
cm.KIND = { events = "changes", recall = "saved versions", ["recall/known"] = "saved versions", media = "recordings", takes = "takes",
  _trash = "trash", ["_trash/media"] = "trash", midi = "settings", deleted = "settings", trimmed = "settings", fx = "settings", sessions = "end-of-session projects" }
local sizes, unwanted_since = {}, {}
local function size_of(local_path, cloud_path)
  local s = sizes[cloud_path]
  if s then return s end
  -- (planned: the worker's listing has its size, free; opening each file here was 3,000 opens, 200 ms, in a room's sweep. rt-drive2)
  if C().planned then s = C().size(cloud_path) end
  s = s or local_path and band.size(local_path) -- (the studio folder's copy: the same file, and opening a cloud drive's file may download it)
  if not s and C().planned then return 0 end
  if not s and reaper.JS_File_Stat then
    local okj, st, sz = pcall(reaper.JS_File_Stat, cloud_path)
    if okj and st == 0 then s = math.floor(tonumber(sz) or 0) end
  end
  s = s or band.size(cloud_path) or 0
  sizes[cloud_path] = s
  return s
end
local function new_sum(s)
  return { mode = s.mode, days = s.days, limit_mb = s.limit_mb, stored = { 0, 0 }, kinds = {}, would = { essentials = 0, standard = 0, everything = 0 },
    drop = { essentials = { 0, 0 }, standard = { 0, 0 } }, drop_kinds = { essentials = {}, standard = {} }, removed = { 0, 0 }, ess = 0, items = {} }
end
local function add(t, k, b) t[k] = t[k] or { 0, 0 }; t[k][1], t[k][2] = t[k][1] + 1, t[k][2] + b end
-- One file into the sums: `u` its tier judged with everything either side has (what each mode would store), `c` the cloud's own (nil: not in
-- the cloud copy). -> whether it goes from the cloud copy now.
local function count(sum, s, kind, bytes, u, c, age)
  for m, r in pairs(cm.RANK) do if cm.TIER[u] <= r then sum.would[m] = sum.would[m] + bytes end end
  if not c then return false end
  sum.stored[1], sum.stored[2] = sum.stored[1] + 1, sum.stored[2] + bytes
  add(sum.kinds, kind, bytes)
  if c == "essential" then sum.ess = sum.ess + bytes end
  for _, m in ipairs({ "essentials", "standard" }) do
    if not cm.allowed(c, m) then
      sum.drop[m][1], sum.drop[m][2] = sum.drop[m][1] + 1, sum.drop[m][2] + bytes
      add(sum.drop_kinds[m], kind, bytes)
    end
  end
  if cm.allowed(c, s.mode) then sum.items[#sum.items + 1] = { c, age, bytes } end
  return active(s) and not cm.keeps(c, age, s, cm.cut)
end
local function may_remove(mine, path, is_owner, now)
  if mine then return true end
  if not is_owner then return false end
  unwanted_since[path] = unwanted_since[path] or now
  return now - unwanted_since[path] >= cm.OTHERS_WAIT
end
local function remove(sum, path, bytes)
  if C().planned and not C().cloud(path) then return end -- (planned: only ever a file in the cloud folder)
  if C().remove(path, nil, false) then
    sum.removed[1], sum.removed[2] = sum.removed[1] + 1, sum.removed[2] + bytes
    sizes[path], unwanted_since[path] = nil, nil
    require("drive").listed[path:match("^(.*)/")] = nil
  end
end

-- One room of a song in the sweep. -> true when done, nil while it carries on next pass. Each pass does what fits in `deadline` (time_precise)
-- and keeps its place in sw.cur: the changes read, the saved versions, a trim plan or two, then the files counted (one room was 331 ms in one
-- go on REAPER's thread on the desktop: rt-drive2).
local function room_pass(sw, cfg, droot, song, room, deadline)
  local s, drive, now = sw.s, require("drive"), os.time()
  local lrooms, crooms = band.song_dir(cfg, song) .. "/rooms", droot .. "/" .. song .. "/rooms"
  local sg = sw.songs[song]
  if not sg then -- (every room of the song, both sides, once per sweep: recordings are played from any room)
    sg = { all = {}, cloud = {} }
    local names = set_of(rooms_of(lrooms))
    for _, r in ipairs(rooms_of(crooms)) do names[r] = true end
    for r in pairs(names) do
      local ld = lrooms .. "/" .. r .. "/events"
      local l = read_events(ld, r, deadline)
      local c = l and read_events(crooms .. "/" .. r .. "/events", r, deadline, ld)
      if not c then return nil end
      local byid, all = {}, {}
      for _, list in ipairs({ l, c }) do for _, e in ipairs(list) do if not byid[e.id] then byid[e.id] = true; all[#all + 1] = e end end end
      sg.all[r], sg.cloud[r] = all, c
    end
    C().check() -- (planned: every room's cloud changes read before any is judged by them)
    sw.songs[song] = sg
  end
  local here, there = lrooms .. "/" .. room, crooms .. "/" .. room
  local cur = sw.cur
  if not (cur and cur.song == song and cur.room == room) then
    local points = read_points({ here .. "/recall", there .. "/recall" }, deadline)
    if not points then return nil end
    C().check() -- (planned: the cloud's saved versions read before anything is judged by them)
    local all, cloud = sg.all[room] or {}, sg.cloud[room] or {}
    plan_until, plan_made = deadline, false
    local ok, ju, jc = pcall(function()
      local u = cm.judge(room, all, sg.all, points, sw.cutoff)
      -- (the cloud copy has every change of the room: judged the same, so its plans aren't made twice)
      return u, #cloud == #all and u or cm.judge(room, cloud, sg.all, points, sw.cutoff)
    end)
    plan_until = nil
    if not ok then if ju == cm.LATER then return nil end; error(ju, 0) end
    local every = {} -- (whose each recording is: the first change in any room that played it)
    for _, list in pairs(sg.all) do for _, e in ipairs(list) do every[#every + 1] = e end end
    local subs = {}
    for _, sub in ipairs(cm.SUBS) do subs[#subs + 1] = sub end
    local fxu = set_of(rooms_of(here .. "/fx"))
    for _, u in ipairs(rooms_of(there .. "/fx")) do fxu[u] = true end
    for u in pairs(fxu) do subs[#subs + 1] = "fx/" .. u end
    local listed = {} -- (planned: every folder listed and the saved versions read before anything is counted, so a sum never counts a room twice)
    for _, sub in ipairs(subs) do listed[sub] = C().files(there .. "/" .. sub) end
    C().check()
    local work = {} -- { sub, file, here, in the cloud copy }: counted a few hundred a pass
    for _, sub in ipairs(subs) do
      local L, inC, names = set_of(band.files(here .. "/" .. sub)), set_of(listed[sub]), {}
      for f in pairs(L) do names[f] = true end
      for f in pairs(inC) do names[f] = true end
      local sorted = {}
      for f in pairs(names) do if not drive.arriving(f) then sorted[#sorted + 1] = f end end
      table.sort(sorted)
      for _, f in ipairs(sorted) do work[#work + 1] = { sub, f, L[f], inC[f] } end
    end
    -- (hold: the cloud's changes not here yet while this computer has some: a copy still arriving, or not listed yet. Nothing removed then)
    cur = { song = song, room = room, ju = ju, jc = jc, owners = drive.media_owners(every, room), hold = #cloud == 0 and #all > 0, work = work, i = 1 }
    sw.cur = cur
  end
  local user, is_owner = cfg.user, sw.is_owner
  -- (a few files each pass, one at least: on the desktop the room's other units used the pass's time before the sweep's turn, so for minutes
  -- every turn of the sweep stopped before its first step, the round rested at 08:21:42 with "bringing ... up to date", and the sweep ended
  -- three minutes later. rt-drive2, round 4)
  local first = true
  while cur.work[cur.i] do
    if not first and reaper.time_precise() > deadline then return nil end
    first = false
    local sub, f, inL, inC = table.unpack(cur.work[cur.i])
    local cpath = there .. "/" .. sub .. "/" .. f
    local bytes = size_of(inL and (here .. "/" .. sub .. "/" .. f), cpath)
    C().check() -- (planned: a listing gone stale since is read again before this file counts)
    local kind = cm.KIND[sub] or cm.KIND[sub:match("^[^/]+")] or "settings"
    local tc, age
    if inC then tc, age = cur.jc(sub, f) end
    if count(sw.sum, s, kind, bytes, cur.ju(sub, f), tc, age) and not cur.hold then
      local mine = (sub == "media" or sub == "_trash/media") and cur.owners[f] == user or drive.mine(f, user)
      if may_remove(mine, cpath, is_owner, now) then remove(sw.sum, cpath, bytes) end
    end
    cur.i, progress = cur.i + 1, progress + 1
  end
  sw.cur = nil
  return true
end

-- A song's end-of-session projects in the cloud copy (<song>/sessions/*.rpp and the recordings they use, sessions/media/<user>/): history,
-- so Standard keeps the last `days` of them and Essentials none (lib/sessionfile.lua writes none then). -> true when done, nil while it carries
-- on next pass (each project's text is read for its recordings: a few a pass).
-- (each project's recordings, "user/file", found once: an end-of-session project is written once under its own name. The first sweep after a
-- start reads each a step; the next sweeps read none. Nostalgia's 13 were 19 MB, kept whole in Live sync's memory before. rt-drive2, round 5)
local rpp_keys = {}
local function sessions_pass(sw, droot, song, user, deadline)
  local s, sum, now = sw.s, sw.sum, os.time()
  local sdir = droot .. "/" .. song .. "/sessions"
  local cur = sw.cur
  if not (cur and cur.song == song and cur.sessions) then
    local rpps, media = C().files(sdir, ".rpp"), {} -- (planned: all asked for, then checked, before anything is counted)
    if C().planned then for _, f in ipairs(rpps) do if not rpp_keys[sdir .. "/" .. f] then require("drivebg").want_file(sdir .. "/" .. f) end end end
    for _, u in ipairs(C().subdirs(sdir .. "/media")) do media[#media + 1] = { u, C().files(sdir .. "/media/" .. u) } end
    C().check()
    cur = { song = song, sessions = true, rpps = rpps, media = media, used = {}, i = 1 } -- (used: "user/file" -> best tier, newest age)
    sw.cur = cur
  end
  local used = cur.used
  local first = true
  while cur.rpps[cur.i] do
    if not first and reaper.time_precise() > deadline then return nil end
    first = false
    local f = cur.rpps[cur.i]
    local age = cm.stamp_time(f)
    local tier = (age ~= "" and age >= sw.cutoff) and "recent" or "other"
    local p = sdir .. "/" .. f
    local keys = rpp_keys[p]
    if not keys then
      local text = C().read(p) -- (read here, one a step: 13 of them read at once were 100 ms)
      C().check()
      keys = {}
      require("sessionfile").each_file(text or "", function(path) local k = path:match("^media/(.+)$"); if k then keys[#keys + 1] = k end end)
      if text then rpp_keys[p] = keys end
    end
    for _, k in ipairs(keys) do
      local u = used[k] or { 3, "" }
      used[k] = { math.min(u[1], cm.TIER[tier]), age > u[2] and age or u[2] }
    end
    local bytes = size_of(nil, p)
    if count(sum, s, "sessions", bytes, tier, tier, age) and may_remove(f:find("Z-" .. user:gsub("[^%w%-_]", "_") .. "-", 1, true) ~= nil, p, sw.is_owner, now) then
      remove(sum, p, bytes)
      rpp_keys[p] = nil
    end
    cur.i, progress = cur.i + 1, progress + 1
  end
  for _, um in ipairs(cur.media) do
    local u = um[1]
    for _, f in ipairs(um[2]) do
      local p, k = sdir .. "/media/" .. u .. "/" .. f, u .. "/" .. f
      local tier, age = TIER_NAME[(used[k] or { 3 })[1]], (used[k] or { 3, "" })[2]
      local bytes = size_of(nil, p)
      if count(sum, s, "sessions", bytes, tier, tier, age) and may_remove(u == user:gsub("[^%w%-_]", "_"), p, sw.is_owner, now) then remove(sum, p, bytes) end
    end
  end
  sw.cur = nil
  return true
end

-- From Live sync's cloud pass: a room or two each time (`budget` seconds), a whole sweep of the studio's cloud copy at most every EVERY s.
-- Writes what it found to ExtState "cloud storage" (the panel and Health read it). -> the summary when a sweep finished.
local sw, swept_at = nil, -math.huge
cm.cut = nil -- (the last sweep's size-limit cut: non-essential files this old or older go)
function cm.tick(cfg, droot, now, budget)
  if not sw then
    if now - swept_at < cm.EVERY then return end
    local s = cm.settings_for(cfg.root)
    local list, songs, incloud = {}, {}, {}
    for _, d in ipairs(C().subdirs(droot)) do
      incloud[d] = true
      if d:sub(1, 1) ~= "_" and C().subdirs(droot .. "/" .. d .. "/rooms")[1] then songs[d] = true end
    end
    local okh, here = pcall(function() return require("songsync").here(cfg) end)
    for _, d in ipairs(okh and type(here) == "table" and here or {}) do songs[d] = true end
    local names = {}
    for d in pairs(songs) do names[#names + 1] = d end
    table.sort(names)
    for _, song in ipairs(names) do
      local rs = set_of(rooms_of(band.song_dir(cfg, song) .. "/rooms"))
      -- (a song with no folder in the cloud copy has no rooms or projects there: not asked for. The desktop's sweep waited on listings of
      -- songs only named here (Sunset Drive...), one job each, and the round rested at 10:51:08. rt-drive2, round 8)
      if incloud[song] then for _, r in ipairs(rooms_of(droot .. "/" .. song .. "/rooms")) do rs[r] = true end end
      local rl = {}
      for r in pairs(rs) do rl[#rl + 1] = r end
      table.sort(rl)
      for _, r in ipairs(rl) do list[#list + 1] = { song, r } end
      if incloud[song] then list[#list + 1] = { song } end -- (then its end-of-session projects)
    end
    C().check() -- (planned: the cloud copy's songs and rooms all listed first)
    local okr, role = pcall(function() return require("groups").role(cfg.root, cfg.user) end)
    -- (cutoff: one for the whole sweep, so a trim plan made on one pass is the one the next pass looks up)
    sw = { s = s, list = list, i = 1, songs = {}, sum = new_sum(s), is_owner = okr and role == "owner", cutoff = cm.cutoff(os.time(), s.days) }
  end
  local t0 = reaper.time_precise()
  while sw.list[sw.i] and reaper.time_precise() - t0 < (budget or 0.1) do
    local it = sw.list[sw.i]
    if it[2] then
      if not room_pass(sw, cfg, droot, it[1], it[2], t0 + (budget or 0.1)) then return end
    else
      if not sessions_pass(sw, droot, it[1], cfg.user, t0 + (budget or 0.1)) then return end
    end
    sw.i = sw.i + 1
  end
  if sw.list[sw.i] then return end
  local sum, s = sw.sum, sw.s
  local limit = s.limit_mb and s.limit_mb * 1024 * 1024 or nil
  cm.cut, sum.over = cm.limit_cut(sum.items, limit)
  sum.items, sum.cut, sum.at = nil, cm.cut, os.time()
  sw, swept_at = nil, now
  pcall(reaper.SetExtState, band.SECTION, "cloud storage", band.json_encode(sum), false)
  if sum.removed[1] > 0 then
    local label = require("drive").label(require("drive").service_of(droot))
    band.log(string.format("cloud storage (%s): %d file%s (%s) removed from the %s copy: in %s's trash for its usual time; nothing on any computer was touched",
      s.mode, sum.removed[1], sum.removed[1] == 1 and "" or "s", cm.mb(sum.removed[2]), label, label))
  end
  return sum
end
function cm.sweeping() return sw ~= nil end -- (drive.bg_step keeps a pass going while a sweep is)
-- Where the sweep is, in words, for drive.lua's "drive rest" record: nil when none. (rt-drive2, round 7)
function cm.where()
  if not sw then return nil end
  local it, cur = sw.list[sw.i] or {}, sw.cur
  local step = not cur and "reading or judging" or cur.sessions and ("projects " .. tostring(cur.i) .. "/" .. #cur.rpps) or ("files " .. tostring(cur.i) .. "/" .. #cur.work)
  return string.format("%s %s (%d of %d): %s", tostring(it[1]), tostring(it[2] or "sessions"), sw.i, #sw.list, step)
end
function cm.mb(b)
  b = tonumber(b) or 0
  if b >= 1024 ^ 3 then return string.format("%.1f GB", b / 1024 ^ 3) end
  return string.format("%.0f MB", math.max(b / 1024 ^ 2, b > 0 and 1 or 0))
end

-- Health's row for the cloud copy's storage, from the last sweep (`sum`: ExtState "cloud storage"), or nil (none yet). label: the service. Pure.
function cm.health_row(sum, label)
  if type(sum) ~= "table" or type(sum.stored) ~= "table" then return nil end
  local name = ({ essentials = "Essentials", standard = "Standard", everything = "Everything" })[sum.mode] or "Everything"
  local text = string.format("%s copy holds %s (%d files), %s%s", label, cm.mb(sum.stored[2]), sum.stored[1] or 0, name,
    sum.mode == "standard" and (" (" .. tostring(sum.days) .. " days)") or "")
  local w = sum.would or {}
  local more = string.format(". Each mode would store: Essentials %s, Standard %s, Everything %s.", cm.mb(w.essentials), cm.mb(w.standard), cm.mb(w.everything))
  if sum.limit_mb then more = more .. " Limit " .. cm.mb(sum.limit_mb * 1024 * 1024) .. (sum.cut and (": files from " .. sum.cut:sub(1, 10) .. " and before go first") or "") .. "." end
  if (sum.removed or {})[1] and sum.removed[1] > 0 then more = more .. string.format(" Last sweep removed %d (%s), into %s's trash.", sum.removed[1], cm.mb(sum.removed[2]), label) end
  if sum.over then
    return { "cloud storage", false, "yellow", label .. ": essentials alone are over the limit", text .. more ..
      " The essentials alone are over the studio's limit: nothing essential is ever removed, so raise the limit (Settings > Options > Cloud copy)." }
  end
  return { "cloud storage", true, "grey", text, text .. more .. " Settings > Options > Cloud copy picks what it keeps." }
end

-- The confirmation a change to a smaller mode shows: what goes from the cloud copy, by kind. -> text, or nil (nothing goes / no sweep yet). Pure.
function cm.drop_words(sum, mode, label)
  local d = type(sum) == "table" and sum.drop and sum.drop[mode]
  if not d or d[1] == 0 then return nil end
  local parts = {}
  for kind, v in pairs(sum.drop_kinds[mode] or {}) do parts[#parts + 1] = string.format("%s: %d (%s)", kind, v[1], cm.mb(v[2])) end
  table.sort(parts)
  return string.format("%d files (%s) go from the %s copy: %s. They go to %s's trash (kept there for its usual time, about 30 days). " ..
    "Nothing on anyone's computer is touched.", d[1], cm.mb(d[2]), label, table.concat(parts, "; "), label)
end

-- Settings > Studio: the owner and admins pick; everyone sees what the cloud copy holds.
local pending, days_edit -- (a smaller mode waiting for its confirmation; the days slider while it's dragged)
function cm.studio_ui(ctx, ImGui, cfg, may)
  local drive = require("drive")
  local label = drive.name(cfg)
  ImGui.SeparatorText(ctx, "Cloud storage")
  local s = cm.settings_for(cfg.root)
  local sum = band.json_decode(reaper.GetExtState(band.SECTION, "cloud storage"))
  local cur = cm.MODES[3]
  for _, m in ipairs(cm.MODES) do if m[1] == s.mode then cur = m end end
  ImGui.TextDisabled(ctx, "What the studio's " .. label .. " copy keeps. Smaller modes never touch anyone's computer: only the cloud copy holds less.")
  if may then
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, "Keeps##cloudmode", cur[2]) then
      for _, m in ipairs(cm.MODES) do
        if ImGui.Selectable(ctx, m[2], m[1] == s.mode) and m[1] ~= s.mode then
          if cm.RANK[m[1]] < cm.RANK[s.mode] then pending = m[1]
          else cm.set(cfg.root, { mode = m[1], days = s.days, limit_mb = s.limit_mb }); band.log("the cloud copy now keeps " .. m[2]) end
        end
        ImGui.SetItemTooltip(ctx, m[3])
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SetItemTooltip(ctx, cur[3] .. "\nOwner and admins.")
    if s.mode == "standard" then
      ImGui.SetNextItemWidth(ctx, 200)
      local _, d = ImGui.SliderInt(ctx, "days of history##clouddays", days_edit or s.days, 1, 90)
      -- (saved once the slider is let go: each save rewrites band.json for everyone)
      if ImGui.IsItemDeactivatedAfterEdit(ctx) then cm.set(cfg.root, { mode = s.mode, days = d, limit_mb = s.limit_mb }) end
      days_edit = ImGui.IsItemActive(ctx) and d or nil
    end
    local word = function(gb) return gb == 0 and "No size limit" or (gb .. " GB limit") end
    local now_gb = s.limit_mb and math.floor(s.limit_mb / 1024) or 0
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, "##cloudlimit", word(now_gb)) then
      for _, gb in ipairs({ 0, 1, 2, 5, 10, 20, 50, 100, 200 }) do
        if ImGui.Selectable(ctx, word(gb), gb == now_gb) and gb ~= now_gb then
          cm.set(cfg.root, { mode = s.mode, days = s.days, limit_mb = gb > 0 and gb * 1024 or nil })
          band.log("the cloud copy's size limit: " .. word(gb):lower())
        end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SetItemTooltip(ctx, "Past this, the oldest files that aren't essential go from the cloud copy first. Essentials are never removed.")
  else
    ImGui.Text(ctx, "Keeps: " .. cur[2] .. (s.mode == "standard" and (" (" .. s.days .. " days)") or "") ..
      (s.limit_mb and (", limit " .. cm.mb(s.limit_mb * 1024 * 1024)) or ""))
    ImGui.TextDisabled(ctx, "The owner or an admin picks.")
  end
  local row = cm.health_row(sum, label)
  if row then ImGui.TextWrapped(ctx, row[5]) else ImGui.TextDisabled(ctx, "Sizes show after Live sync's next look at the cloud copy (every 10 minutes).") end
  if pending then ImGui.OpenPopup(ctx, "Smaller cloud copy?") end
  if ImGui.BeginPopupModal(ctx, "Smaller cloud copy?", nil, ImGui.WindowFlags_AlwaysAutoResize) then
    local name = ({ essentials = "Essentials", standard = "Standard" })[pending] or tostring(pending)
    ImGui.PushTextWrapPos(ctx, 440)
    ImGui.Text(ctx, "Keep " .. name .. " in the cloud copy?")
    ImGui.Text(ctx, cm.drop_words(sum, pending, label) or ("The files " .. name .. " leaves out go from the " .. label ..
      " copy (to its trash, kept there about 30 days). Nothing on anyone's computer is touched."))
    ImGui.PopTextWrapPos(ctx)
    if ImGui.Button(ctx, "Keep " .. name) then
      cm.set(cfg.root, { mode = pending, days = s.days, limit_mb = s.limit_mb })
      band.log("the cloud copy now keeps " .. name .. ": what it leaves out goes from the cloud copy only")
      pending = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then pending = nil; ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
end

return cm
