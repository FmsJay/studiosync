-- rt-sync2d (docs/rt/rt-sync2.md section 3, James's decision 4; docs/rt/rt-sync2d.md): folders as parent + rank. A track's folder travels as
-- its parent's oid in its version (hashed: hv 10), `pk` saying it is meant; REAPER's depths are worked out from the studio's tree (rank.tree),
-- never taken from a version. Lua 5.4, from the repo root. Each part fails without its piece:
--  1. (pure) rank.tree: parent, then rank, depth first; a parent not said is the one its depth gives it; a parent not here is the top level;
--     a loop of parents is broken by the newest version. rank.depths: REAPER's depths for the tree, and for an order that can't hold it.
--  2. A track put in a folder sends its parent (pk, hv 10); the bandmate's computer puts it in that folder, depths from the tree.
--  3. A folder change landing in pieces (the child's version before the folder's): the tree puts the child in the folder at once, and the
--     depths StudioSync works out there aren't sent as anyone's edit.
--  4. Two computers each put the other's track in its own (a loop): both end on the same valid tree (rank.tree breaks it by the newest
--     version; the computer that finds it then says each track's folder as the tree has it, mirror.rank_room).
--  5. An older StudioSync's version (no pk) says its folder by depth: its stale `parent` isn't taken.
--  6. A room with ranks and no parents yet gets them once, each track by its maker, from the tree (two computers would write the same).
--  7. StudioSync's Undo of a folder move takes it back out; an Undo of a rename made after a folder move keeps the folder.
--  8. An item landing on a folder track doesn't put the folder's old depth back (the soak's seed 2 at 40 edits).
--  9. (merge) a track's folder is its parent and depth together: one side's parent never goes with the other's depth.
-- 10. A version whose folder or rank is off the tree (a stale depth, a rank out of the tree's order) is shown as the tree has it and never
--     said again, not even by a computer holding the same versions as a caught-up bandmate (rt-floor: that write-back was for StudioSyncs
--     older than folders, below the version floor now).
-- 11. Such a version (StudioSync's own, `auto`) on a bandmate's track your Undo brought back doesn't keep it from your Redo (the soak's 5016).
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local rank = require("rank")

-- ---- 1. pure --------------------------------------------------------------------------------------------------------------------------------
do
  local order, par = rank.tree({
    { oid = "K", rank = "a" }, { oid = "B", rank = "V", parent = "" }, { oid = "G", rank = "X", parent = "B" }, { oid = "D", rank = "F", parent = "" },
    { oid = "C", rank = "Y", parent = "NOT-HERE" } })
  assert(table.concat(order, ",") == "D,B,G,C,K" and par.G == "B" and par.C == "" and par.K == "", "parent then rank, depth first: " .. table.concat(order, ","))
  -- a child whose rank sorts it after a later top-level track still sits under its folder
  order, par = rank.tree({ { oid = "A", rank = "F", parent = "" }, { oid = "Z", rank = "V", parent = "" }, { oid = "c", rank = "z", parent = "A" } })
  assert(table.concat(order, ",") == "A,c,Z", "a child under its folder whatever its rank: " .. table.concat(order, ","))
  -- not said: by depth in the rank order
  order, par = rank.tree({ { oid = "A", rank = "F", depth = 1 }, { oid = "b", rank = "G", depth = 0 }, { oid = "c", rank = "H", depth = -1 }, { oid = "d", rank = "I" } })
  assert(par.b == "A" and par.c == "A" and par.d == "", "a folder not said is the one its depth gives it")
  -- a loop: A in B, B in A; B's version is the newer: B goes to the top level
  order, par = rank.tree({ { oid = "A", rank = "F", parent = "B", newest = "0001" }, { oid = "B", rank = "V", parent = "A", newest = "0002" } })
  assert(par.B == "" and par.A == "B" and table.concat(order, ",") == "B,A", "the newest leaves the loop: " .. table.concat(order, ","))
  order, par = rank.tree({ { oid = "A", rank = "F", parent = "B", newest = "0003" }, { oid = "B", rank = "V", parent = "A", newest = "0002" } })
  assert(par.A == "" and par.B == "A" and table.concat(order, ",") == "A,B", "either way round")
  order, par = rank.tree({ { oid = "A", rank = "F", parent = "A" } })
  assert(par.A == "", "its own parent: the top level")
  -- depths
  local d, got = rank.depths({ "D", "B", "G", "H", "K" }, { D = "", B = "", G = "B", H = "G", K = "" })
  assert(d.D == 0 and d.B == 1 and d.G == 1 and d.H == -2 and d.K == 0 and got.H == "G", "canonical depths")
  d, got = rank.depths({ "G", "B" }, { G = "B", B = "" })
  assert(d.G == 0 and d.B == 0 and got.G == "", "an order that can't hold it: the track at the top level")
  assert(rank.depth_parents({ "A", "b", "c", "d" }, { A = 1, b = 0, c = -1, d = 0 }).c == "A", "depth_parents")
  print("rt-folders 1: the tree from parents and ranks, loops broken by the newest, depths from the tree")
end

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

-- ---- 2. a track put in a folder sends its parent; the bandmate's computer puts it there --------------------------------------------------------
do
  local S, A, B = song("Fold2")
  assert(tree(S, B) == "Drums 0, Bass 0, Gtr 0, Keys 0", "the song: " .. tree(S, B))
  T = T + 5
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 1 }, { "Gtr", -1 }, { "Keys", 0 } }) end) -- (Gtr dragged into Bass)
  local g = S.events(function(v) return v.obj == "track" and v.name == "Gtr" and v.state.parent ~= "" end)[1]
  assert(g and g.pk == 1 and g.hv == mirror.HV and g.state.parent == S.track(A, "Bass").ext.band_oid, "Gtr's version names Bass as its folder, meant (pk), hash version " .. mirror.HV)
  S.recv(B)
  assert(tree(S, B) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0", "in Bass's folder on Bee's: " .. tree(S, B))
  T = T + 5
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 0 }, { "Gtr", 0 }, { "Keys", 0 } }) end) -- (and out again)
  S.recv(B)
  assert(tree(S, B) == "Drums 0, Bass 0, Gtr 0, Keys 0", "out again on Bee's: " .. tree(S, B))
  print("rt-folders 2: a track put in a folder sends its parent, and lands in that folder")
end

-- ---- 3. a folder change landing in pieces: the tree, and nobody's edit -----------------------------------------------------------------------
do
  local S, A, B = song("Fold3")
  T = T + 5
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 1 }, { "Gtr", 0 }, { "Keys", -1 } }) end) -- (Gtr and Keys into Bass)
  -- Bee gets Keys's version first: the folder's own (Bass's depth) and Gtr's are still on their way
  local held = {}
  for path, v in pairs(files) do
    if path:find(S.dir .. "/events/", 1, true) and type(v) == "table" and v.obj == "track" and v.user == "James" and (v.name == "Bass" or v.name == "Gtr") and v.pk then held[path] = v; files[path] = nil end
  end
  assert(next(held), "Bass's and Gtr's versions held back")
  local before = #S.events(function(v) return v.user == "Bee" end)
  S.recv(B)
  assert(tree(S, B):find("Keys %-1 <Bass"), "Keys in Bass's folder at once, from the tree: " .. tree(S, B))
  assert(#S.events(function(v) return v.user == "Bee" end) == before, "and Bee sends nothing for the depths StudioSync worked out there")
  for path, v in pairs(held) do files[path] = v end
  S.recv(B)
  assert(tree(S, B) == "Drums 0, Bass 1, Gtr 0 <Bass, Keys -1 <Bass", "all of it on Bee's: " .. tree(S, B))
  assert(#S.events(function(v) return v.user == "Bee" end) == before, "still nothing from Bee")
  print("rt-folders 3: a folder change landing in pieces is put in place from the tree, and isn't sent back as an edit")
end

-- ---- 4. a loop of parents: James puts Bass in Gtr while Bee puts Gtr in Bass -------------------------------------------------------------
do
  local S, A, B = song("Fold4")
  T = T + 5
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Gtr", 1 }, { "Bass", -1 }, { "Keys", 0 } }) end)
  T = T + 5
  S.edit(B, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 1 }, { "Gtr", -1 }, { "Keys", 0 } }) end) -- (Bee's, made later)
  S.recv(A); S.recv(B); S.keep(A); S.keep(B); S.recv(A); S.recv(B)
  assert(tree(S, A) == tree(S, B), "the same tree on both: " .. tree(S, A) .. " / " .. tree(S, B))
  local t = tree(S, A)
  assert(t == "Drums 0, Gtr 1, Bass -1 <Gtr, Keys 0" or t == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0", "one of the two in the other, a valid tree: " .. t)
  print("rt-folders 4: a loop of parents from two moves at once ends as one valid tree everywhere")
end

-- ---- 5. an older StudioSync's version says its folder by depth, not by its stale parent --------------------------------------------------
do
  local S, A, B = song("Fold5", true)
  local function last(name) local best; for _, v in ipairs(S.events(function(v) return v.obj == "track" and v.name == name end)) do if not best or v.rev > best.rev then best = v end end; return best end
  -- an older computer puts Gtr and Keys in Bass: it sends Bass (depth 1) and Keys (depth -1); Gtr's own depth (0) didn't change, so it isn't
  -- sent; and its `parent` fields say "" (what an older StudioSync's REAPER read before the change, say)
  local n = 0
  for _, x in ipairs({ { "Bass", 1 }, { "Keys", -1 } }) do
    local v = last(x[1])
    local st = band.json_decode(band.json_encode(v.state))
    st.depth, st.parent, st.rank = x[2], "", nil
    n = n + 1
    local id = "Old-20270101-00000" .. n .. "Z-00001-0003"
    files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = v.oid, id = id, user = "Old", name = x[1], rev = v.rev + 1, base = v.rev,
      base_ev = v.id, state = st, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (v.hlc or 0) + 1000 }
  end
  S.recv(A); S.recv(B); S.keep(A); S.keep(B)
  assert(tree(S, A) == "Drums 0, Bass 1, Gtr 0 <Bass, Keys -1 <Bass" and tree(S, B) == tree(S, A), "in Bass's folder by its depth, on both: " .. tree(S, A) .. " / " .. tree(S, B))
  print("rt-folders 5: an older StudioSync's folder is read from depths, not from its stale parent")
end

-- ---- 6. a room with ranks and no parents yet gets them once, each track by its maker ------------------------------------------------------
do
  local S = studio("Fold6")
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Gtr", "Keys" }) do F.add_track(n) end end)
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 1 }, { "Gtr", -1 }, { "Keys", 0 } }) end) -- (a folder from before parents)
  S.keep(A); S.recv(B); S.keep(A); S.recv(B) -- (ranked: no parents said yet)
  assert(#S.events(function(v) return v.pk end) == 0, "no parent said yet")
  S.keep(B)
  assert(#S.events(function(v) return v.pk end) == 0, "Bee made none of the tracks: Bee says none")
  S.keep(A)
  local said = S.events(function(v) return v.pk and v.auto and v.user == "James" end)
  local g = S.events(function(v) return v.pk and v.name == "Gtr" end)[1]
  assert(#said == 4 and g and g.state.parent == S.track(A, "Bass").ext.band_oid and told("given their folder"), "James's tracks say their folders, once, StudioSync's own: " .. #said)
  S.keep(A)
  assert(#S.events(function(v) return v.pk end) == 4, "once")
  S.recv(B)
  assert(tree(S, B) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0" and #S.events(function(v) return v.user == "Bee" and v.pk end) == 0, "Bee's the same, nothing sent: " .. tree(S, B))
  print("rt-folders 6: a room's folders are said once, each track by its maker, from the tree")
end

-- ---- 7. StudioSync's Undo of a folder move; an Undo after one keeps the folder ------------------------------------------------------------
do
  local S, A, B = song("Fold7")
  local undo = require("undo")
  T = T + 5
  S.edit(A, function() reaper.GetSetMediaTrackInfo_String(S.track(A, "Gtr"), "P_NAME", "Lead", true) end) -- (Gtr renamed Lead)
  T = T + 5
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 1 }, { "Lead", -1 }, { "Keys", 0 } }) end) -- (then put in Bass)
  S.recv(B)
  assert(tree(S, B) == "Drums 0, Bass 1, Lead -1 <Bass, Keys 0", "the move on Bee's: " .. tree(S, B))
  T = T + 5
  S.as(A)
  local said = undo.step(A.F.proj, A.cfg, S.b, false, {})
  S.settle(A); S.keep(A)
  S.recv(B)
  assert(tree(S, A) == "Drums 0, Bass 0, Lead 0, Keys 0" and tree(S, B) == tree(S, A), "Undo takes the folder move back, on both: " .. tree(S, A) .. " / " .. tree(S, B) .. " (" .. tostring(said) .. ")")
  T = T + 5
  S.as(A)
  said = undo.step(A.F.proj, A.cfg, S.b, false, {})
  S.settle(A); S.keep(A)
  assert(tree(S, A) == "Drums 0, Bass 0, Gtr 0, Keys 0", "the next Undo takes the rename back and leaves the folder as it is: " .. tree(S, A) .. " (" .. tostring(said) .. ")")
  -- a folder move, then a rename: the rename's Undo keeps the folder
  T = T + 5
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 1 }, { "Gtr", -1 }, { "Keys", 0 } }) end)
  T = T + 5
  S.edit(A, function() reaper.GetSetMediaTrackInfo_String(S.track(A, "Gtr"), "P_NAME", "Lead", true) end)
  T = T + 5
  S.as(A)
  said = undo.step(A.F.proj, A.cfg, S.b, false, {})
  S.settle(A); S.keep(A); S.recv(B)
  assert(tree(S, A) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0" and tree(S, B) == tree(S, A), "the rename taken back, Gtr still in Bass on both: " .. tree(S, A) .. " / " .. tree(S, B) .. " (" .. tostring(said) .. ")")
  -- an Undo that puts back a version from before an older StudioSync's folder change: the folder the tree gives the track now stands
  S, A, B = song("Fold7b")
  T = T + 5
  S.edit(A, function() reaper.GetSetMediaTrackInfo_String(S.track(A, "Gtr"), "P_NAME", "Lead", true) end) -- (James renames Gtr)
  S.recv(B)
  local function last(name) local best; for _, v in ipairs(S.events(function(v) return v.obj == "track" and v.name == name end)) do if not best or v.rev > best.rev then best = v end end; return best end
  local n = 0
  for _, x in ipairs({ { "Bass", 1, "" }, { "Lead", -1, "Bass" } }) do -- (then an older computer puts Lead in Bass: depths, no pk)
    local v = last(x[1])
    local st = band.json_decode(band.json_encode(v.state))
    st.depth, st.rank, st.parent = x[2], nil, x[3] == "" and "" or S.track(A, x[3]).ext.band_oid
    n = n + 1
    local id = "Old-20270101-00000" .. n .. "Z-00001-0003"
    files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = v.oid, id = id, user = "Old", name = x[1], rev = v.rev + 1, base = v.rev,
      base_ev = v.id, state = st, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (v.hlc or 0) + 1000 }
  end
  S.recv(A); S.recv(B)
  assert(tree(S, A) == "Drums 0, Bass 1, Lead -1 <Bass, Keys 0" and tree(S, B) == tree(S, A), "the older computer's folder on both: " .. tree(S, A))
  T = T + 5
  S.as(A)
  said = undo.step(A.F.proj, A.cfg, S.b, false, {})
  S.settle(A); S.keep(A); S.recv(B); S.keep(B)
  assert(tree(S, A) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0" and tree(S, B) == tree(S, A), "the rename taken back, Gtr still in Bass (was: its old version's folder, out of Bass): " .. tree(S, A) .. " / " .. tree(S, B) .. " (" .. tostring(said) .. ")")
  local u = S.events(function(v) return v.obj == "track" and v.undoes and v.state.name == "Gtr" end)[1]
  assert(u and u.pk == 1 and u.state.parent == S.track(A, "Bass").ext.band_oid and u.state.depth == -1, "the Undo's version says the folder and depth it has now")
  print("rt-folders 7: StudioSync's Undo takes a folder move back, and keeps the folder when it takes back something else")
end

-- ---- 8. an item landing on a folder track doesn't put the folder's old depth back -------------------------------------------------------
do
  local S, A, B = song("Fold8")
  T = T + 5
  S.edit(A, function(F) arrange(F, { { "Drums", 0 }, { "Bass", 1 }, { "Gtr", -1 }, { "Keys", 0 } }) end)
  for path, v in pairs(files) do -- (Bass's own version, its depth 1, still on its way to Bee)
    if path:find(S.dir .. "/events/", 1, true) and type(v) == "table" and v.obj == "track" and v.name == "Bass" and v.pk then files[path] = nil end
  end
  S.recv(B)
  assert(tree(S, B) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0", "Gtr in Bass from the tree: " .. tree(S, B))
  T = T + 1
  S.edit(A, function(F) F.add_item(S.track(A, "Bass"), table.concat({ "<ITEM", "POSITION 2", "LENGTH 1", 'NAME "bass take"', "<SOURCE MIDI",
    "HASDATA 1 960 QN", "E 960 b0 7b 00", ">", ">" }, "\n") .. "\n") end)
  S.recv(B)
  assert(#S.track(B, "Bass").items == 1 and tree(S, B) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0", "the take lands and the folder stays (was: Bass's old depth back, Gtr out of it): " .. tree(S, B))
  print("rt-folders 8: an item landing on a folder track leaves the folder from the tree")
end

-- ---- 9. a track's folder merges as one: parent and depth together -------------------------------------------------------------------------
do
  local merge = require("mirror_merge")
  local base = { name = "Gtr", parent = "", depth = 0, mute = 0 }
  local w = { name = "Gtr", parent = "", depth = -1, mute = 1 } -- (the winner: its depth closes a folder above, and a mute)
  local l = { name = "Gtr", parent = "B", depth = 0, mute = 0 } -- (the loser: put in B)
  local out = merge.merge_track(base, w, l)
  assert(out.parent == "" and out.depth == -1 and out.mute == 1, "both changed the folder: the winner's parent and depth (was: B with -1)")
  out = merge.merge_track(base, { name = "Gtr", parent = "", depth = 0, mute = 1 }, l)
  assert(out.parent == "B" and out.depth == 0 and out.mute == 1, "only the loser changed it: the loser's, with the winner's mute")
  print("rt-folders 9: a track's parent and depth merge together")
end

-- ---- 10. a version off the tree is shown as the tree has it, and not said again (rt-floor) ------------------------------------------------
do
  local S, A, B = song("Fold10")
  local function last(name) local best; for _, v in ipairs(S.events(function(v) return v.obj == "track" and v.name == name end)) do if not best or v.rev > best.rev then best = v end end; return best end
  -- James's versions (pk) say Gtr is in Bass with a rank that sorts it first, and a depth (-2) no tree gives it: what a merge of two
  -- folder changes could leave
  local v, b = last("Gtr"), last("Bass")
  local st = band.json_decode(band.json_encode(v.state))
  st.parent, st.depth, st.rank = b.oid, -2, "1"
  local id = "James-20270101-000001Z-00001-0009"
  files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = v.oid, id = id, user = "James", name = "Gtr", rev = v.rev + 1, base = v.rev,
    base_ev = v.id, state = st, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (v.hlc or 0) + 1000, rk = 1, pk = 1, hv = 11 }
  local function auto() return #S.events(function(x) return x.auto end) end
  local presence = require("presence")
  local peers = presence.peers
  local before = auto()
  S.recv(B); S.recv(A); S.keep(B); S.keep(A)
  assert(tree(S, B) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0" and tree(S, A) == tree(S, B), "Gtr in Bass from the tree on both: " .. tree(S, B) .. " / " .. tree(S, A))
  S.as(B)
  local code = mirror.root(B.F.proj)
  presence.peers = function() return { { user = "James", mirror = code, pending = 0 } } end -- (James, caught up, holds what Bee holds)
  S.keep(B); S.keep(A)
  presence.peers = peers
  assert(auto() == before and last("Gtr").id == id, "nobody says it again, its maker included (was: Bee said Gtr and Bass again with the tree's depths and ranks): " .. (auto() - before))
  assert(tree(S, B) == "Drums 0, Bass 1, Gtr -1 <Bass, Keys 0" and tree(S, A) == tree(S, B), "and both still show the tree")
  print("rt-folders 10: a version off the tree is shown as the tree has it and not said again")
end

-- ---- 11. StudioSync's own version on a track your Undo brought back doesn't keep it from your Redo --------------------------------------------
do
  local S, A, B = song("Fold11")
  local undo = require("undo")
  T = T + 5
  S.edit(B, function(F) F.add_track("Bee1") end) -- (Bee's track)
  S.recv(A)
  T = T + 5
  S.edit(A, function() reaper.DeleteTrack(S.track(A, "Bee1")) end) -- (James deletes it)
  T = T + 5
  S.as(A); undo.step(A.F.proj, A.cfg, S.b, false, {}); S.settle(A) -- (and undoes that: back)
  assert(S.track(A, "Bee1"), "James's Undo brings Bee1 back")
  -- a bandmate's computer says Bee1's folder again from the tree (StudioSync's own act, auto), built on James's Undo
  local u = S.events(function(v) return v.obj == "track" and v.name == "Bee1" and v.user == "James" and not v.gone end)
  table.sort(u, function(x, y) return x.rev < y.rev end)
  local v = u[#u]
  local st = band.json_decode(band.json_encode(v.state))
  st.depth = 0
  local id = "Bee-20270101-000001Z-00001-0011"
  files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = v.oid, id = id, user = "Bee", name = "Bee1", rev = v.rev + 1, base = v.rev,
    base_ev = v.id, state = st, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (v.hlc or 0) + 1000, rk = 1, pk = 1, hv = 10, auto = true }
  S.recv(A)
  T = T + 5
  S.as(A)
  local said = undo.step(A.F.proj, A.cfg, S.b, true, {})
  S.settle(A)
  assert(not S.track(A, "Bee1"), "James's Redo deletes Bee1 again (was: kept as a bandmate's change since): " .. tostring(said))
  print("rt-folders 11: StudioSync's own version on a track doesn't keep it from your Redo")
end

print("ok rt-folders")
