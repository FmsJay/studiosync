-- rt-floor (docs/rt/rt-floor.md): the studio's version floor, and what went with it. Lua 5.4, from the repo root. Each part fails without
-- its piece (the doc's knock-out table):
--  1. (pure) sync.held_by_floor / sync.too_new: a change made below the floor (a lower `lv`, or none since the floor was first recorded) is
--     held; at or above it, or history from before floors, isn't; with no floor read, nothing is.
--  2. sync.floor: the first read records this computer's level in <root>/_band/floor; a higher level recorded there is the floor (and this
--     computer is below it, and writes nothing); a computer with a lower level never lowers it (only goes up); `since` is the first record's.
--  3. Below the floor: an edit or a deletion sends nothing (no event file, sync.post refuses), says "update StudioSync", and is kept as unsent, so the
--     band's change to that track waits; another track's change still lands (it keeps receiving); Undo is refused.
--  4. Updated (its level reaches the floor): the edit kept unsent goes out on the next look, at the new level. No work lost.
--  5. At the floor: an edit goes out as ever, carrying `lv`.
--  6. A change made below the floor (lv 10; or no lv since the floor) is held on a computer at the floor: not applied, not marked done, not
--     counted as still to come; a change from before floors (no lv, older than the floor) lands.
--  7. hv 11: a ranked track's hashed line has no depth (the tree decides it); a track with no rank keeps it.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local rank = require("rank")

-- ---- computers (as tests/test_0_60_rt_reopen.lua) ------------------------------------------------------------------------------------------
local T = 1800000000
local real_time, real_date = os.time, os.date
os.time = function(t) if t then return real_time(t) end return T end
os.date = function(fmt, t) return real_date(fmt, t or T) end
local E = require("editreaper")
local F0 = E.new("C:/A/Song.rpp")
reaper = F0.reaper
local band = require("band")
local files, logged = {}, {}
local function told(pattern) for _, l in ipairs(logged) do if l:find(pattern) then return l end end end
band.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
band.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
band.log = function(s) logged[#logged + 1] = s end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
package.loaded.trust = { claim_ok = function() return true end }
local mirror = require("mirror")
local sync = require("sync")
require("prints").choose = function() end
local claimask = require("claimask")
require("direct").send_live = function() return true end
claimask.reachable = function() return nil end
claimask.present = function() return false end
local function studio(song)
  local S = { song = song, dir = "R/" .. song .. "/rooms/main", sess = { host = "James", markers = {} }, b = { song = song, room = "main" } }
  files[S.dir .. "/mode.json"] = { mode = "everyone", by = "James" }
  local function as(c) reaper = c.F.reaper end
  S.as = as
  function S.computer(user)
    local c = { F = E.new("C:/" .. user .. "/" .. song .. ".rpp"), cfg = { user = user, root = "R" }, user = user }
    require("undo").confirm = function() return true end
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or files[p] ~= nil end
    c.F.reaper.SetExtState(band.SECTION, "user", user, false)
    c.edited = -1
    return c
  end
  function S.look(c)
    as(c)
    c.F.clock = c.F.clock + 1
    local may, w = sync.authority(c.cfg, song, "main", S.sess)
    sync.driver_name, sync.room_mode = w.driver, w.mode
    mirror.watch(c.F.proj, c.cfg, song, "main", { can = may, owner_can = may, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of, quick = true,
      edited_at = c.edited, sent = claimask.on_sent })
    as(c)
  end
  function S.settle(c)
    for _ = 1, 20 do
      local n = 0
      for _ in pairs(files) do n = n + 1 end
      S.look(c)
      local m = 0
      for _ in pairs(files) do m = m + 1 end
      if m == n and not mirror.more and not mirror.unsettled then return end
      mirror.unsettled = nil
    end
    error("never settled")
  end
  function S.edit(c, fn) as(c); c.F.clock = c.F.clock + 1; fn(c.F); c.edited = c.F.clock; S.settle(c) end
  function S.recv(c)
    as(c)
    sync.ev_cache = {}
    for _ = 1, 20 do
      c.F.clock = c.F.clock + 1
      local may, w = sync.authority(c.cfg, song, "main", S.sess)
      sync.room_mode = w.mode
      local got = sync.receive(c.F.proj, c.cfg, song, "main", may)
      if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
    end
    S.settle(c)
  end
  function S.keep(c) as(c); local n = mirror.keep_order(c.F.proj, c.cfg, song, "main"); S.settle(c); return n end
  function S.names(c) local t = {}; for _, tr in ipairs(c.F.tracks) do t[#t + 1] = tr.name end; return table.concat(t, ", ") end
  function S.track(c, name) for _, t in ipairs(c.F.tracks) do if t.name == name then return t end end end
  function S.rank(c, name) as(c); local t = S.track(c, name); return t and mirror.rank_of(t) end
  function S.events(pred) local out = {}; for p, v in pairs(files) do if p:find(S.dir .. "/events/", 1, true) and type(v) == "table" and pred(v) then out[#out + 1] = v end end; return out end
  function S.move(c, name, to) -- (the track dragged to just above the track at `to`, 0-based, as REAPER's ReorderSelectedTracks)
    S.edit(c, function() reaper.SetOnlyTrackSelected(S.track(c, name)); reaper.ReorderSelectedTracks(to, 0); reaper.SetTrackSelected(S.track(c, name), false) end)
  end
  return S
end
-- James and Bee with Drums, Bass, Gtr, Keys, ranked on the studio's order, and each track saying its folder (unsaid: not yet)
local function song(name, unsaid)
  local S = studio(name)
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Gtr", "Keys" }) do F.add_track(n) end end)
  S.keep(A); S.recv(B); S.keep(A); S.recv(B)
  if not unsaid then S.keep(A); S.recv(B) end
  return S, A, B
end
-- each track's depth and parent here, as "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0"
local function tree(S, c)
  S.as(c)
  local t = {}
  for _, tr in ipairs(c.F.tracks) do
    local p = reaper.GetParentTrack(tr)
    t[#t + 1] = tr.name .. " " .. tostring(math.floor(tr.depth or 0)) .. (p and " <" .. p.name or "")
  end
  return table.concat(t, ", ")
end
-- the tracks as REAPER leaves them after a drag: names in order with their depths
local function arrange(F, spec)
  local by = {}
  for _, t in ipairs(F.tracks) do by[t.name] = t end
  for i, x in ipairs(spec) do F.tracks[i] = by[x[1]]; by[x[1]].depth = x[2] end
  F.changed()
end


local function track_events(S, pred) return S.events(function(v) return v.obj == "track" and pred(v) end) end
local function level(n, c) sync.LEVEL = n; return sync.floor(c.cfg, true) end -- (this computer runs a StudioSync of level n)
local LEVEL = sync.LEVEL

-- ---- 1. pure ---------------------------------------------------------------------------------------------------------------------------------
do
  local was = sync.floor_now
  sync.floor_now = nil
  assert(not sync.held_by_floor({ type = "obj", lv = 1, time = "2030-01-01T00:00:00Z" }), "no floor read: nothing held")
  sync.floor_now = { level = 11, since = "2026-11-27T12:00:00Z", below = false }
  assert(sync.held_by_floor({ type = "obj", lv = 10 }) and sync.too_new({ type = "obj", lv = 10, format = 1 }), "a lower level: held (and too_new says so)")
  assert(not sync.held_by_floor({ type = "obj", lv = 11 }) and not sync.held_by_floor({ type = "obj", lv = 12 }), "at or above: not held")
  assert(sync.held_by_floor({ type = "timeline", time = "2026-11-27T12:00:00Z" }), "no level, made since the floor: held")
  assert(not sync.held_by_floor({ type = "obj", time = "2026-11-27T11:59:59Z" }) and not sync.too_new({ type = "obj", time = "2026-11-27T11:59:59Z", format = 1 }),
    "no level, made before the floor (history): lands")
  sync.floor_now = was
  print("rt-floor 1: what's held: a lower level, or none since the floor")
end

-- ---- 2. the floor in the studio's folder: recorded, raised, only up ---------------------------------------------------------------------------
do
  local S = studio("Floor2")
  local A, B = S.computer("James"), S.computer("Bee")
  local dir = sync.floor_dir(A.cfg)
  for p in pairs(files) do if p:find(dir, 1, true) then files[p] = nil end end
  local f = level(11, A)
  assert(f.level == 11 and not f.below and files[dir .. "/11-James.json"] and files[dir .. "/11-James.json"].since == os.date("!%Y-%m-%dT%H:%M:%SZ"), "James's level recorded")
  local first = f.since
  T = T + 60
  f = level(11, B)
  assert(f.level == 11 and not f.below and not files[dir .. "/11-Bee.json"] and f.since == first, "Bee at the same level: nothing more written, the same since")
  f = level(12, B)
  assert(f.level == 12 and not f.below and files[dir .. "/12-Bee.json"] and f.since == first, "Bee updated: the floor goes up to 12; since stays the first floor's")
  f = level(11, A)
  assert(f.level == 12 and f.below, "James at 11 is below it now")
  f = level(10, A)
  assert(f.level == 12 and f.below, "a lower level never lowers it")
  local n = 0
  for p in pairs(files) do if p:find(dir, 1, true) then n = n + 1 end end
  assert(n == 2, "and writes nothing: " .. n)
  for p in pairs(files) do if p:find(dir, 1, true) then files[p] = nil end end
  sync.LEVEL = LEVEL
  print("rt-floor 2: the floor is recorded in the studio's folder, goes up with the newest level, and never down")
end

-- ---- 3, 4. below the floor: nothing goes out, the edit is kept; updated: it goes -------------------------------------------------------------
do
  local S = studio("Floor3")
  local A, B = S.computer("James"), S.computer("Bee")
  level(11, A)
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Gtr", "Keys" }) do F.add_track(n) end end)
  S.keep(A); S.recv(B); S.keep(A); S.recv(B); S.keep(A); S.recv(B)
  assert(S.names(B) == "Drums, Bass, Gtr, Keys", "the song on Bee's: " .. S.names(B))
  -- the studio's floor goes to 12 (Bee updated); James's StudioSync is still 11
  level(12, B)
  level(11, A)
  assert(sync.below_floor(), "James is below the floor")
  local before = #S.events(function() return true end)
  logged = {}
  T = T + 5
  S.edit(A, function() reaper.GetSetMediaTrackInfo_String(S.track(A, "Gtr"), "P_NAME", "Lead", true) end)
  assert(#S.events(function() return true end) == before, "James's rename sends nothing")
  assert(told("update StudioSync") and told("older than the studio"), "and says why: update StudioSync")
  S.as(A)
  assert(mirror.unsent[tostring(A.F.proj) .. S.track(A, "Lead").ext.band_oid], "the rename is kept as a change of James's not sent yet")
  assert(sync.post(A.cfg, "Floor3", "main", { type = "note", text = "x" }) == nil and #S.events(function() return true end) == before, "sync.post refuses")
  local drums = S.track(A, "Drums").ext.band_oid
  T = T + 5
  S.edit(A, function() reaper.DeleteTrack(S.track(A, "Drums")) end)
  assert(#S.events(function() return true end) == before and mirror.unsent[tostring(A.F.proj) .. drums], "a deletion too: nothing sent, kept unsent")
  local said = mirror.revert(A.F.proj, A.cfg, "Floor3", "main", {}, {})
  assert(tostring(said):find("update StudioSync"), "Undo is refused: " .. tostring(said))
  -- Bee (at the floor) renames Gtr too, and renames Keys: Keys lands on James's; Gtr waits behind James's unsent rename
  level(12, B)
  T = T + 5
  S.edit(B, function()
    reaper.GetSetMediaTrackInfo_String(S.track(B, "Gtr"), "P_NAME", "Gtr 2", true)
    reaper.GetSetMediaTrackInfo_String(S.track(B, "Keys"), "P_NAME", "Keys 2", true)
  end)
  local k = track_events(S, function(v) return v.user == "Bee" and v.name == "Keys 2" end)[1]
  assert(k and k.lv == 12, "Bee's change goes out at level 12")
  level(11, A)
  S.recv(A)
  assert(S.track(A, "Keys 2"), "Bee's rename of Keys lands on James's: below the floor it still receives: " .. S.names(A))
  assert(S.track(A, "Lead") and not S.track(A, "Gtr 2"), "James's own rename stays (Bee's change to that track waits behind it): " .. S.names(A))
  print("rt-floor 3: below the floor nothing goes out, the edit is kept unsent and said, and the band's other changes still land")
  -- James updates: his kept rename goes out on the next look, at level 12
  level(12, A)
  assert(not sync.below_floor(), "James at the floor")
  T = T + 5
  S.settle(A)
  local g = track_events(S, function(v) return v.user == "James" and type(v.state) == "table" and v.state.name == "Lead" end)[1]
  assert(g and g.lv == 12, "the rename goes out once James updates, at level 12")
  assert(track_events(S, function(v) return v.user == "James" and v.oid == drums and v.gone and v.lv == 12 end)[1], "and the deletion")
  print("rt-floor 4: updated, the change kept below the floor goes out: no work lost")
  sync.LEVEL = LEVEL
end

-- ---- 5, 6. at the floor: as ever; a change made below it is held, history lands ----------------------------------------------------------------
do
  local S = studio("Floor5")
  local A, B = S.computer("James"), S.computer("Bee")
  for p in pairs(files) do if p:find(sync.floor_dir(A.cfg), 1, true) then files[p] = nil end end
  level(11, A)
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Gtr", "Keys" }) do F.add_track(n) end end)
  S.keep(A); S.recv(B); S.keep(A); S.recv(B)
  local e = S.events(function(v) return v.user == "James" end)
  assert(#e > 0, "James's tracks went out")
  for _, v in ipairs(e) do assert(v.lv == 11, "each change carries its level") end
  print("rt-floor 5: at the floor an edit goes out as ever, with its level")
  level(11, B)
  local function last(name) local best; for _, v in ipairs(track_events(S, function(v) return v.name == name end)) do if not best or v.rev > best.rev then best = v end end; return best end
  -- Cee (below the floor: lv 10) renames Keys; Old (a StudioSync before floors: no lv) renames Bass now; and a change of Drums from before the floor
  local function put(user, name, newname, lv, time)
    local v = last(name)
    local st = band.json_decode(band.json_encode(v.state))
    st.name = newname
    local id = user .. "-20270101-000001Z-00001-00" .. #newname
    files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = v.oid, id = id, user = user, name = newname, rev = v.rev + 1, base = v.rev,
      base_ev = v.id, state = st, time = time, hlc = (v.hlc or 0) + 1000, rk = 1, pk = 1, hv = 11, lv = lv, format = 1 }
    return id
  end
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local c = put("Cee", "Keys", "Keys C", 10, now)
  local o = put("Old", "Bass", "Bass Old", nil, now)
  put("Hist", "Drums", "Drums H", nil, "2001-01-01T00:00:00Z")
  logged = {}
  S.recv(B)
  S.as(B)
  assert(S.track(B, "Keys") and not S.track(B, "Keys C"), "Cee's change (below the floor) isn't applied: " .. S.names(B))
  assert(S.track(B, "Bass") and not S.track(B, "Bass Old"), "nor Old's (no level, made since the floor): " .. S.names(B))
  assert(S.track(B, "Drums H"), "a change from before the floor lands: " .. S.names(B))
  assert(select(2, reaper.GetProjExtState(B.F.proj, sync.APPLIED, c)) == "" and select(2, reaper.GetProjExtState(B.F.proj, sync.APPLIED, o)) == "",
    "held, not dropped: neither is marked done")
  assert(sync.pending_events(B.F.proj, B.cfg, "Floor5", "main") == 0, "and not counted as still to come")
  assert(told("their changes wait"), "and the log says whose wait")
  print("rt-floor 6: a change made below the floor is held at the floor; history from before it lands")
  sync.LEVEL = LEVEL
end

-- ---- 7. hv 11: no depth in a ranked track's line ------------------------------------------------------------------------------------------------
do
  assert(mirror.HV == 11 and sync.LEVEL >= mirror.HV, "hv 11, and the level not below it")
  local t = { name = "Gtr", parent = "B", depth = -1, rank = "V" }
  local u = { name = "Gtr", parent = "B", depth = 0, rank = "V" }
  assert(mirror.track_hash(t) == mirror.track_hash(u), "a ranked track's depth isn't in its hash")
  t.rank, u.rank = nil, nil
  assert(mirror.track_hash(t) ~= mirror.track_hash(u), "an unranked track's still is")
  print("rt-floor 7: a ranked track's hash leaves its depth to the tree")
end

print("ok rt-floor")
