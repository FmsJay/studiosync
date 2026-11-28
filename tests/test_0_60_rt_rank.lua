-- rt-sync2c phase 4 (docs/rt/rt-sync2.md section 3, docs/rt/rt-sync2c.md): a track's place as a rank (lib/rank.lua), carried in its version
-- as `rank`, and the studio's order sorted from the ranks. Lua 5.4, from the repo root.
--  1. (pure) rank.valid, rank.less (bytes, not the locale's collation), rank.between strictly between and short, rank.spread in order,
--     rank.order (ranked by rank then oid, an unranked track under the track its version names).
--  2. A room's tracks get ranks once, on the studio's order (mirror.keep_order -> mirror.rank_room), as StudioSync's own act (no Undo step).
--  3. A move: the moved track gets a rank between its new neighbours'; the bandmate's computer sorts it there.
--  4. Two moves made at once, on two computers: both end on the same order. A late joiner sorts and lands on it too.
--  5. A move from a StudioSync before ranks (a version with no rank, `moved` set): every new computer puts it where its version says, unranked,
--     until its maker's computer sends a rank for that place. A new track made here gets a rank between the tracks around it.
--  6. (merge) a version without a rank, merged with one that moved the track, keeps the move's rank (a missing rank is no change).
--  7. An Undo or Restore of a version from before ranks keeps the track's place, on a track made anew as on one already there.
--  8. StudioSync's Undo of a move made before ranks sends the rank of the place it goes back to.
--  9. A rank an older StudioSync copied into a version (its Undo puts an old state back whole) isn't taken for the track's place.
-- 10. With old computers in the room: the order list follows the ranks (old computers go to the newest list), and an older StudioSync's move
--     merged with a new edit keeps its place.
-- 11. The order comes from the versions held, not from a rank left on a track (a version recorded without being put in place: sync.set_back).
-- 12. A receive pass that lands a track sorts the whole order by rank (sync.receive), not only the track that landed.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local rank = require("rank")

-- ---- 1. pure --------------------------------------------------------------------------------------------------------------------------------
do
  assert(rank.valid("V") and rank.valid("0V") and rank.valid("zzzzzzz1"), "ranks")
  assert(not rank.valid("") and not rank.valid("A0") and not rank.valid("a-b") and not rank.valid(string.rep("a", 33)) and not rank.valid(nil) and not rank.valid(5),
    "not ranks: empty, ending in 0, other characters, too long, not text")
  assert(rank.less("9", "A") and rank.less("Z", "a") and rank.less("A", "AA") and not rank.less("a", "B"), "bytes: 0-9 < A-Z < a-z, whatever the locale")
  -- between: strictly between, valid, and short, for many pairs (a fixed pseudo-random walk of inserts)
  local seed = 12345
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
  local list = rank.spread(5)
  for i = 2, #list do assert(rank.less(list[i - 1], list[i]) and rank.valid(list[i]), "spread in order") end
  for _ = 1, 3000 do
    local k = rnd(#list + 1) -- (insert before list[k]; k = #list + 1: at the end)
    local a, b = list[k - 1], list[k]
    local r = rank.between(a, b)
    assert(r and rank.valid(r), "a rank between " .. tostring(a) .. " and " .. tostring(b))
    assert((a == nil or rank.less(a, r)) and (b == nil or rank.less(r, b)), "strictly between: " .. tostring(a) .. " < " .. r .. " < " .. tostring(b))
    table.insert(list, k, r)
  end
  local longest = 0
  for _, r in ipairs(list) do longest = math.max(longest, #r) end
  assert(longest <= rank.MAX, "3,000 random inserts stay within " .. rank.MAX .. " characters: " .. longest)
  assert(rank.between("V", "V") == nil and rank.between("W", "V") == nil and rank.between("x-", nil) == nil, "no rank between equal, reversed or invalid ones")
  for _, n in ipairs({ 1, 2, 61, 62, 100, 4000 }) do
    local sp = rank.spread(n)
    assert(#sp == n, "spread " .. n)
    for i = 1, n do assert(rank.valid(sp[i]) and (i == 1 or rank.less(sp[i - 1], sp[i])), "spread " .. n .. " in order at " .. i) end
  end
  -- order: by rank then oid; an unranked track right under the track it names, oldest first; one naming a track not here at the end
  local o = rank.order({
    { oid = "T-B-20261101000000-2", rank = "V" }, { oid = "T-A-20261101000000-1", rank = "V" }, { oid = "T-C-20261101000000-3", rank = "F" },
    { oid = "T-OLD-20261101000002-1", after = "T-C-20261101000000-3" }, { oid = "T-OLD-20261101000001-1", after = "T-C-20261101000000-3" },
    { oid = "T-GONE-20261101000003-1", after = "T-NOT-HERE" }, { oid = "T-TOP-20261101000004-1", after = "" } })
  assert(table.concat(o, ",") == "T-TOP-20261101000004-1,T-C-20261101000000-3,T-OLD-20261101000002-1,T-OLD-20261101000001-1,T-A-20261101000000-1,T-B-20261101000000-2,T-GONE-20261101000003-1",
    "rank.order: " .. table.concat(o, ","))
  print("rt-rank 1: ranks sort by bytes, between is strictly between and short, spread is in order, unranked tracks sit under their anchor")
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
-- James and Bee with Drums, Bass, Gtr, Keys, ranked once on the studio's order
local function song(name)
  local S = studio(name)
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Gtr", "Keys" }) do F.add_track(n) end end)
  S.keep(A) -- (the first: the studio's order list)
  S.recv(B)
  S.keep(A) -- (on the list's order: the tracks get ranks)
  return S, A, B
end

-- ---- 2. a room's tracks get ranks once, on the studio's order ------------------------------------------------------------------------------
do
  local S, A, B = song("Rank2")
  for _, n in ipairs({ "Drums", "Bass", "Gtr", "Keys" }) do assert(S.rank(A, n), n .. " has a rank on James's") end
  assert(rank.less(S.rank(A, "Drums"), S.rank(A, "Bass")) and rank.less(S.rank(A, "Gtr"), S.rank(A, "Keys")), "in the studio's order")
  local ranked = S.events(function(v) return v.obj == "track" and v.state and v.state.rank and v.auto end)
  assert(#ranked == 4 and ranked[1].hv >= 9, "four versions with their ranks, StudioSync's own (auto: no Undo step of James's), hash version 9 or later (10: rt-sync2d): " .. #ranked)
  S.recv(B)
  assert(S.rank(B, "Keys") == S.rank(A, "Keys") and S.names(B) == "Drums, Bass, Gtr, Keys", "the same ranks on Bee's")
  S.keep(B)
  assert(#S.events(function(v) return v.obj == "track" and v.user == "Bee" end) == 0, "Bee's computer ranks nothing more: they all have one")
  print("rt-rank 2: a room's tracks are ranked once, on the studio's order, as StudioSync's own act")
end

-- ---- 3. a move gives the moved track a rank between its new neighbours ------------------------------------------------------------------------
do
  local S, A, B = song("Rank3")
  S.recv(B)
  T = T + 5
  S.move(A, "Keys", 1) -- (Keys to just above Bass)
  assert(S.names(A) == "Drums, Keys, Bass, Gtr", "moved on James's: " .. S.names(A))
  local kr = S.rank(A, "Keys")
  assert(rank.less(S.rank(A, "Drums"), kr) and rank.less(kr, S.rank(A, "Bass")), "Keys's rank is between Drums's and Bass's")
  local mv = S.events(function(v) return v.obj == "track" and v.name == "Keys" and v.moved ~= nil end)[1]
  assert(mv and mv.state.rank == kr and mv.state.after ~= nil, "the move goes out with the rank (and its after, for older computers)")
  S.recv(B)
  assert(S.names(B) == "Drums, Keys, Bass, Gtr", "Bee's sorts it there: " .. S.names(B))
  print("rt-rank 3: a moved track's rank goes between its new neighbours' and every computer sorts it there")
end

-- ---- 4. two moves at once; a late joiner --------------------------------------------------------------------------------------------------
do
  local S, A, B = song("Rank4")
  S.recv(B)
  T = T + 5
  S.move(A, "Keys", 0) -- (James: Keys to the top)
  S.move(B, "Drums", 4) -- (Bee, not having seen it: Drums to the bottom)
  S.recv(A); S.recv(B); S.keep(A); S.keep(B)
  assert(S.names(A) == S.names(B), "the same order on both: " .. S.names(A) .. " / " .. S.names(B))
  assert(S.names(A) == "Keys, Bass, Gtr, Drums", "both moves stand: " .. S.names(A))
  local C = S.computer("Cee") -- (a late joiner: every version, in whatever order receive takes them)
  S.recv(C); S.keep(C)
  assert(S.names(C) == S.names(A), "the late joiner sorts and is right: " .. S.names(C))
  print("rt-rank 4: two moves made at once end the same on both, and a late joiner sorts onto it")
end

-- ---- 5. a move from a StudioSync before ranks; a new track here ----------------------------------------------------------------------------
do
  local S, A, B = song("Rank5")
  S.recv(B)
  T = T + 5
  -- an old computer's move of Gtr to the top: a version built on the held one, `moved` and `after` set, no rank
  local held = S.events(function(v) return v.obj == "track" and v.name == "Gtr" end)
  table.sort(held, function(x, y) return x.rev < y.rev end)
  local h = held[#held]
  local st = band.json_decode(band.json_encode(h.state))
  st.rank, st.after = nil, ""
  local id = "Old-20270101-000000Z-00001-0001"
  files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = h.oid, id = id, user = "Old", name = "Gtr", rev = h.rev + 1, base = h.rev,
    base_ev = h.id, state = st, moved = S.track(A, "Bass") and h.state.after or "", time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (h.hlc or 0) + 1000 }
  S.recv(B)
  assert(S.names(B) == "Gtr, Drums, Bass, Keys" and not S.rank(B, "Gtr"), "the old computer's move lands at the top, with no rank: it sits under what its version names, as on the old computers: " .. S.names(B))
  S.keep(B)
  assert(S.names(B) == "Gtr, Drums, Bass, Keys", "keeping the order by rank keeps it there: " .. S.names(B))
  S.recv(A) -- (James made Gtr: once it has landed, his computer ranks it for that place, and sends it)
  assert(S.names(A) == "Gtr, Drums, Bass, Keys", "on James's too: " .. S.names(A))
  S.recv(B); S.keep(B)
  assert(S.rank(A, "Gtr") and S.rank(A, "Gtr") == S.rank(B, "Gtr") and rank.less(S.rank(A, "Gtr"), S.rank(A, "Drums")), "then one rank for that place on both, sent by its maker")
  assert(S.names(A) == "Gtr, Drums, Bass, Keys" and S.names(B) == S.names(A), "and there it stays: " .. S.names(A) .. " / " .. S.names(B))
  -- a new track on James's between Drums and Bass
  T = T + 5
  S.edit(A, function(F) F.add_track("Pad", 3) end)
  assert(S.names(A) == "Gtr, Drums, Pad, Bass, Keys", "Pad made on James's: " .. S.names(A))
  assert(rank.less(S.rank(A, "Drums"), S.rank(A, "Pad")) and rank.less(S.rank(A, "Pad"), S.rank(A, "Bass")), "with a rank between Drums's and Bass's")
  S.recv(B)
  assert(S.names(B) == "Gtr, Drums, Pad, Bass, Keys", "Bee's puts it there: " .. S.names(B))
  print("rt-rank 5: an older computer's move lands where it says, unranked until its maker ranks it; a new track gets a rank between its neighbours")
end

-- ---- 6. merge: a missing rank is no change ----------------------------------------------------------------------------------------------------
do
  local base = { name = "Gtr", rank = "V" }
  local mover = { name = "Gtr", rank = "F" } -- (a new computer moved it)
  local old = { name = "Guitar" } -- (an old computer renamed it: no rank in its version)
  local m1 = mirror.merge_track(base, old, mover)
  local m2 = mirror.merge_track(base, mover, old)
  assert(m1.rank == "F" and m1.name == "Guitar" and m2.rank == "F" and m2.name == "Guitar", "both stand, whichever wins: " .. tostring(m1.rank) .. " " .. tostring(m2.rank))
  assert(mirror.same_line({ name = "Gtr", rank = "F" }, { name = "Gtr" }) and not mirror.same_line({ name = "Gtr", rank = "F" }, { name = "Gtr", rank = "G" }),
    "a version with no rank reads as the same track; another rank doesn't")
  print("rt-rank 6: a version from before ranks says nothing of the place")
end

-- ---- 7. an Undo or Restore of a version from before ranks keeps the track's place, on a track made anew as on one already there ---------
do
  local S, A, B = song("Rank7")
  S.recv(B)
  T = T + 5
  -- James's Undo restores Gtr's first version (made before ranks: no rank in it), built on the one he holds
  local held = S.events(function(v) return v.obj == "track" and v.name == "Gtr" end)
  table.sort(held, function(x, y) return x.rev < y.rev end)
  local first, last = held[1], held[#held]
  assert(first.state.rank == nil and last.state.rank, "Gtr's first version has no rank, its last one has")
  local st = band.json_decode(band.json_encode(first.state))
  st.vol = "0.500000"
  local id = "James-20270101-000001Z-00002-0002"
  files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = last.oid, id = id, user = "James", name = "Gtr", rev = last.rev + 1, base = last.rev,
    base_ev = last.id, state = st, restored = first.id, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (last.hlc or 0) + 1000 }
  S.recv(B)
  local C = S.computer("Cee") -- (a late joiner: Gtr made anew from that version)
  S.recv(C)
  assert(S.rank(B, "Gtr") == last.state.rank and S.rank(C, "Gtr") == last.state.rank, "the rank it had, on Bee's and on the late joiner's: " ..
    tostring(S.rank(B, "Gtr")) .. " / " .. tostring(S.rank(C, "Gtr")) .. " (was: kept on one, none on the other, three orders)")
  S.keep(B); S.keep(C)
  assert(S.names(B) == S.names(C), "the same order: " .. S.names(B) .. " / " .. S.names(C))
  print("rt-rank 7: an Undo of a version from before ranks keeps the track's place everywhere")
end

-- ---- 8. StudioSync's Undo of a move made before the room had ranks sends the track's rank for the place it goes back to ---------------------
do
  local S = studio("Rank8")
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Gtr", "Keys" }) do F.add_track(n) end end)
  S.keep(A) -- (the studio's order list; no ranks yet)
  S.recv(B)
  T = T + 5
  S.move(A, "Gtr", 0) -- (a move made before ranks: its version has none)
  S.recv(B)
  S.keep(A) -- (now on the list's order: ranked)
  S.recv(B)
  assert(S.rank(A, "Gtr") and S.names(B) == "Gtr, Drums, Bass, Keys", "ranked after the move: " .. S.names(B))
  T = T + 5
  S.as(A)
  local undo = require("undo")
  local said = undo.step(A.F.proj, A.cfg, S.b, false, {})
  S.settle(A)
  assert(S.names(A) == "Drums, Bass, Gtr, Keys", "James's Undo takes the move back: " .. S.names(A) .. " (" .. tostring(said) .. ")")
  local ev = S.events(function(v) return v.obj == "track" and v.name == "Gtr" and v.undoes end)[1]
  assert(ev and ev.state.rank and ev.state.rank == S.rank(A, "Gtr"), "the Undo's version has the rank it has on James's (was: none, and every other computer made up its own)")
  S.recv(B); S.keep(A); S.keep(B)
  assert(S.names(B) == "Drums, Bass, Gtr, Keys" and S.rank(B, "Gtr") == S.rank(A, "Gtr"), "Bee's goes back there with the same rank: " .. S.names(B))
  print("rt-rank 8: an Undo of a move made before ranks sends the rank of the place it goes back to")
end

-- ---- 9. a rank an older StudioSync copied into a version isn't a place --------------------------------------------------------------------
do
  local S, A, B = song("Rank9")
  S.recv(B)
  T = T + 5
  S.move(B, "Keys", 0) -- (Bee: Keys to the top, with a new rank)
  S.recv(A)
  local mv = S.events(function(v) return v.obj == "track" and v.name == "Keys" and v.moved ~= nil end)[1]
  local first = S.events(function(v) return v.obj == "track" and v.name == "Keys" and v.auto end)[1] -- (the version that ranked it)
  assert(mv and first and S.names(A) == "Keys, Drums, Bass, Gtr", "Bee's move on both: " .. S.names(A))
  -- an older computer's Undo of something on Keys: the ranked version's state put back whole (its old rank in it), no `rk`, built on Bee's move
  local st = band.json_decode(band.json_encode(first.state))
  st.mute = 1
  local id = "Old-20270101-000002Z-00001-0003"
  files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = mv.oid, id = id, user = "Old", name = "Keys", rev = mv.rev + 1, base = mv.rev,
    base_ev = mv.id, state = st, restored = first.id, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (mv.hlc or 0) + 1000 }
  S.recv(A); S.recv(B); S.keep(A); S.keep(B)
  assert(S.names(A) == "Keys, Drums, Bass, Gtr" and S.names(B) == S.names(A), "Keys stays at the top on both (was: back at the copied rank's place): " .. S.names(A) .. " / " .. S.names(B))
  assert(S.rank(A, "Keys") == mv.state.rank and S.rank(B, "Keys") == mv.state.rank, "with Bee's rank")
  print("rt-rank 9: a rank an older StudioSync copied back isn't taken for the track's place")
end

-- ---- 10. old computers in the room: the order list follows the ranks, and an older StudioSync's move merged with a new edit keeps its place --
do
  local S, A, B = song("Rank10")
  S.recv(B)
  -- an older computer's list, the newest so far, in an order the ranks have moved past
  files[S.dir .. "/order/Old.json"] = { list = { S.track(A, "Keys").ext.band_oid, S.track(A, "Drums").ext.band_oid, S.track(A, "Bass").ext.band_oid, S.track(A, "Gtr").ext.band_oid },
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"), by = "Old" }
  T = T + 5
  S.keep(A)
  local best = mirror.read_order(S.dir)
  local names = {}
  for _, oid in ipairs(best.list) do for _, t in ipairs(A.F.tracks) do if t.ext.band_oid == oid then names[#names + 1] = t.name end end end
  assert(S.names(A) == "Drums, Bass, Gtr, Keys" and table.concat(names, ", ") == "Drums, Bass, Gtr, Keys" and best.by == "James",
    "James's computer keeps its ranks' order and says it in the list old computers follow (was: the old list stood): " .. table.concat(names, ", ") .. " by " .. tostring(best.by))
  -- an older computer's move of Bass to the top, made apart from Bee's rename of it: merged, the move keeps its place
  T = T + 5
  local held = S.events(function(v) return v.obj == "track" and v.name == "Bass" end)
  table.sort(held, function(x, y) return x.rev < y.rev end)
  local h = held[#held]
  S.edit(B, function() reaper.GetSetMediaTrackInfo_String(S.track(B, "Bass"), "P_NAME", "Bass 2", true) end)
  local st = band.json_decode(band.json_encode(h.state))
  st.after = ""
  local id = "Old-20270101-000003Z-00001-0004"
  files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "track", oid = h.oid, id = id, user = "Old", name = "Bass", rev = h.rev + 1, base = h.rev,
    base_ev = h.id, state = st, moved = h.state.after, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hlc = (h.hlc or 0) + 5000 }
  S.recv(A); S.recv(B); S.keep(A); S.keep(B)
  assert(S.names(A) == "Bass 2, Drums, Gtr, Keys" and S.names(B) == S.names(A), "both: the rename and the old computer's move (was: the move lost to the rank both had before): " ..
    S.names(A) .. " / " .. S.names(B))
  print("rt-rank 10: the order list follows the ranks for old computers, and an old computer's move merged with a new edit keeps its place")
end

-- ---- 11. the order comes from the versions held, not from the ranks left on the tracks ------------------------------------------------------
do
  local S, A, B = song("Rank11")
  S.recv(B)
  T = T + 5
  S.move(A, "Keys", 0) -- (James: Keys to the top)
  local mv = S.events(function(v) return v.obj == "track" and v.name == "Keys" and v.moved ~= nil end)[1]
  -- Bee's computer records James's version without putting it in place, as a claimer's answer to a rename does (sync.set_back): the rank
  -- left on her Keys is the old one
  S.as(B)
  mirror.set_back(B.F.proj, mv, "(test)")
  reaper.SetProjExtState(B.F.proj, sync.APPLIED, mv.id, "1") -- (and marks it done, as sync.receive's set_back does)
  S.keep(B); S.keep(A)
  assert(S.names(B) == "Keys, Drums, Bass, Gtr" and S.names(A) == S.names(B), "Bee's goes by the version she holds: " .. S.names(B) .. " / " .. S.names(A))
  assert(S.rank(B, "Keys") == mv.state.rank, "and the rank on her Keys is that version's again")
  print("rt-rank 11: the order comes from the versions held, not from a rank left on a track")
end

-- ---- 12. a pass that lands a track sorts the whole order by rank, not only the track that landed -----------------------------------------
do
  local S, A, B = song("Rank12")
  S.recv(B)
  -- Bee's tracks out of the studio's order with nobody's move behind it (as a half-applied catch-up or an older computer can leave them)
  S.as(B)
  for i, t in ipairs(B.F.tracks) do if t.name == "Keys" then table.insert(B.F.tracks, 1, table.remove(B.F.tracks, i)); break end end
  local list = {}
  for _, t in ipairs(B.F.tracks) do list[#list + 1] = t.ext.band_oid end
  mirror.order_seen[tostring(B.F.proj)] = table.concat(list, ",")
  assert(S.names(B) == "Keys, Drums, Bass, Gtr", "(out of order: " .. S.names(B) .. ")")
  T = T + 5
  S.edit(A, function() reaper.GetSetMediaTrackInfo_String(S.track(A, "Gtr"), "P_NAME", "Gtr 2", true) end)
  S.recv(B)
  assert(S.names(B) == "Drums, Bass, Gtr 2, Keys", "the pass that landed James's rename put Bee's order right (was: only Gtr placed, Keys left on top): " .. S.names(B))
  print("rt-rank 12: a pass that lands a track sorts the whole order by rank")
end

print("ok rt-rank")
