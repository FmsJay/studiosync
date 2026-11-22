-- rt-converge (docs/rt/rt-converge.md): the sync core converging under concurrent edits, the soak's bugs (docs/rt/rt-soak.md). Lua 5.4, from
-- the repo root. Each part fails with its fix taken out (checked against a copy of lib/ without it).
--  1. A version names the tempo map its seconds are on (`tm`): put in place on another map it lands on its beat (mirror.apply), versions made
--     under different maps merge on one map (mirror.event_file), and a hand edit after a bandmate's map isn't taken for the map's move
--     (mirror.map_moved): the soak's bugs 1, 5 and 7.
--  2. A received change is judged by the claims as they stood when it was made (sync.authority's `at`): bug 3.
--  3. A track change moves its track only when its place is what it changes (mirror.receive): bug 6.
--  4. A track that comes back brings its items back on every computer (mirror.apply's note, mirror.heal): bug 4.
--  5. Two holders of one track, by its old name and its new, don't answer each other's rename for ever (sync.receive): bug 2.
--  6. An item's deletion lands though the item had moved off its deleted track here (mirror.receive).
--  7. What was refused doesn't stay on this computer alone, asked about every 90 s (W.put_back).
--  8. Undo then Redo brings the song back (mirror.revert, lib/undo.lua): bug 9 and the soak's undo probe.
--  9. The studio's track order is the order everyone landed: new tracks as they were made, and every move reaches the order list
--     (mirror.wanted_order, mirror.order_after_band, W.send).
-- 10. An edit beaten by a deletion stays beaten when the deletion is taken back, in whatever order they arrive (mirror.beaten_by).
-- 11. Undo and Redo of an act with a marker or tempo change go by the timeline's own order (sync.undo_timeline).
-- 12. No choice follows Lua's table order: heal and Undo work through their objects in one order (mirror.heal, mirror.revert): bug 8.
-- 13. A plug-in knob turned here that no look has seen holds the band's chain back (mirror.receive): rt-r2's P1-4 and P1-1.
-- 14. REAPER's own Undo of a track deletion brings the track back for everyone (mirror.watch, settle_ids): rt-r2's P1-6.
-- 15. (a pin) which plug-in changes ask the bandmate who holds the track while they edit: rt-r2's P1-5.
-- 16. A track's lanes that only read differently here, with no edit behind the look, don't go out (W.one): LinuxBox2's lane names.
-- 17. A merge isn't built while a version it rests on is still on its way (mirror.event_file, mirror.merge_for).
-- 18. An item moved onto a track a bandmate deleted that moment goes with the track on every computer (mirror.receive).
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
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
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
local function near(a, b) return math.abs(a - b) < 1e-9 end
local function num(state, key) return tonumber(state:match("\n%s*" .. key .. " ([%d%.%-e]+)")) end
local function midi(pos, len, notes)
  return table.concat({ "<ITEM", "POSITION " .. pos, "SNAPOFFS 0", "LENGTH " .. len, "LOOP 0", "FADEIN 1 0 0 1 0 0 0", "FADEOUT 1 0 0 1 0 0 0", 'NAME "K"',
    "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "<SOURCE MIDI", "HASDATA 1 960 QN", notes or "E 0 90 3c 60\nE 480 80 3c 00", "E 960 b0 7b 00", ">", ">" }, "\n") .. "\n"
end
local M120 = { { time = 0, bpm = 120, num = 4, denom = 4, linear = false } }
local M106 = { { time = 0, bpm = 106, num = 4, denom = 4, linear = false } }

-- ---- 1a. pure: a version on another map, and what counts as a map -----------------------------------------------------------------------------
do
  local ev = { obj = "item", state = midi(8, 4), tm = M120, tb = 1 }
  local st, moved = mirror.state_on(ev, M106, 1)
  assert(moved and near(num(st, "POSITION"), 8 * 120 / 106) and near(num(st, "LENGTH"), 4 * 120 / 106), "made at 120, placed at 106: the same beats")
  local same, moved2 = mirror.state_on(ev, { { time = 0, bpm = 120 } }, 1)
  assert(same == ev.state and moved2 == false, "the same map: as it is")
  assert(select(2, mirror.state_on({ obj = "item", state = midi(8, 4) }, M106, 1)) == false, "a version from before (no map): as it is")
  assert(select(2, mirror.state_on(ev, M106, 0)) == false, "the time timebase: nothing moves")
  for _, bad in ipairs({ "x", {}, { "x" }, { { time = "0", bpm = 120 } }, { { time = 0, bpm = 0 } }, { { time = 0 } }, { { time = -1, bpm = 120 } } }) do
    assert(not mirror.map_ok(bad) and select(2, mirror.state_on({ obj = "item", state = midi(8, 4), tm = bad }, M106, 1)) == false, "not a map: taken as it is, never an error")
  end
  local long = {}
  for i = 1, mirror.MAP_MAX + 1 do long[i] = { time = i - 1, bpm = 120 } end
  assert(not mirror.map_ok(long), "a map past MAP_MAX isn't carried")
  local env = { obj = "env", state = "<VOLENV2\nPT 0 1 0\nPT 8 0.5 0\n>", tm = M120, tb = 1 }
  local es, em = mirror.state_on(env, M106, 1)
  assert(em and near(tonumber(es:match("PT (%S+) 0.5")), 8 * 120 / 106), "automation's points the same way")
  assert(mirror.snap_to("POSITION 9.0566037735849\nLENGTH 4\n", "POSITION 9.05660377358491\nLENGTH 5\n") == "POSITION 9.05660377358491\nLENGTH 4\n",
    "a place that differs past its 7th decimal is written as the other writes it; a real difference stays")
  print("rt-converge 1a: a version onto another map (pure)")
end

-- ---- 1b. mirror.apply puts a version on the map in place; map_tag names it; map_moved is exact ------------------------------------------------
local R = "R/Song/rooms/main"
do
  local F = F0
  local tr = F.add_track("Keys")
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "T-A-1", true)
  local ev = { type = "obj", obj = "item", oid = "I-A-1", track = "T-A-1", name = "Keys", rev = 1, id = "A-20270115-080000Z-00001-0001", user = "A",
    time = iso(T), state = midi(8, 4) }
  mirror.map_tag(F.proj, ev)
  assert(mirror.map_ok(ev.tm) and #ev.tm == 1 and ev.tm[1].bpm == 120 and ev.tb == 1, "a version going out names the map in place and the timebase")
  local tev = mirror.map_tag(F.proj, { obj = "track", state = { name = "x" } })
  assert(tev.tm == nil, "a track's settings have no place in time: no map")
  -- the map changes here before the version lands (it was made just before the map reached its maker)
  reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 106, 4, 4, false)
  local ok, h = mirror.apply(F.proj, ev, R .. "/media", false)
  assert(ok and mirror.retimed_here == true, "applied, and moved for the map")
  local it = F.all_items()[1]
  assert(near(num(it.text, "POSITION"), 8 * 120 / 106) and near(num(it.text, "LENGTH"), 4 * 120 / 106),
    "a version made under the old map lands on its beat under the new one (was: at its old seconds, for good)")
  mirror.remember(F.proj, "I-A-1", 1, h, ev.id, mirror.order_of(ev))
  files[R .. "/events/" .. ev.id .. ".json"] = ev
  -- the same version put back (W.put_back applies the last event): still on its beat
  ok = mirror.apply(F.proj, ev, R .. "/media", false)
  assert(ok and near(num(F.all_items()[1].text, "POSITION"), 8 * 120 / 106), "a put-back of that version lands on today's map too (bug 5)")
  -- is a difference only the map's move?
  local here = F.all_items()[1].text
  assert(mirror.map_moved(F.proj, ev, here) == true, "where the map put it: the map's move")
  mirror.tempo_changed(F.proj) -- (a bandmate's map just landed: the 15 s window, with no map from before known)
  local by_hand = here:gsub("POSITION [^\n]+", "POSITION 15.98")
  assert(mirror.map_moved(F.proj, ev, by_hand) == false, "moved by hand inside the 15 s after a bandmate's map: an edit, not the map's move (bug 1)")
  -- (as a look reads it: the item's normalized state against the band's version of it)
  local media = R .. "/media"
  local last = mirror.map_tag(F.proj, { obj = "item", state = mirror.item_state(F.all_items()[1], media) })
  reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 90, 4, 4, false) -- (another map lands: REAPER moves the item)
  mirror.tempo_changed(F.proj)
  local moved_state = mirror.item_state(F.all_items()[1], media)
  assert(moved_state ~= last.state and mirror.only_map_moved(F.proj, { kind = "item", state = moved_state }, last) == true, "REAPER's move for the map: taken in, nobody's edit")
  assert(mirror.only_map_moved(F.proj, { kind = "item", state = (moved_state:gsub("POSITION [^\n]+", "POSITION 15.98")) }, last) == false,
    "moved by hand on top, inside the window: a look asks about it or sends it")
  reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 106, 4, 4, false)
  -- a version made under the map in place: no map moved it, whatever the window says
  local ev2 = mirror.map_tag(F.proj, { obj = "item", state = here })
  assert(mirror.map_moved(F.proj, ev2, by_hand) == false and mirror.map_moved(F.proj, ev2, (here:gsub("FADEIN 1 0", "FADEIN 1 0.5"))) == false,
    "under the map it was made on, a move or a fade is an edit")
  -- a version from before (no map named): as before, inside the window anything that only moved is the map's
  assert(mirror.map_moved(F.proj, { state = midi(8, 4) }, by_hand) == true, "no map named: the old rule")
  print("rt-converge 1b: a version lands on its beat under the map in place; a hand edit after a map isn't the map's move")
end

-- ---- 1c. versions made under different maps merge on one map ----------------------------------------------------------------------------------
do
  local hlc = math.floor(T * 1000)
  local function put(id, user, state, base, tm, n)
    local ev = { type = "obj", obj = "item", oid = "I-M", id = id, user = user, state = state, base_ev = base, rev = n, hlc = hlc + n, time = iso(T), tm = tm, tb = 1 }
    files[R .. "/events/" .. id .. ".json"] = ev
    return ev
  end
  local base = put("A-20270115-080001Z-00001-0001", "A", midi(8, 4), nil, M120, 1)
  -- Cee set the tempo to 106: REAPER moved the item there, and it went out as only that
  local w = put("Cee-20270115-080003Z-00001-0002", "Cee", midi(string.format("%.14g", 8 * 120 / 106), string.format("%.14g", 4 * 120 / 106)), base.id, M106, 3)
  -- Bee, who hadn't the map yet, moved the item to 20 s
  local l = put("Bee-20270115-080002Z-00001-0003", "Bee", midi(20, 4), base.id, M120, 2)
  local m = mirror.event_file(R, mirror.merge_id(w.id, l.id))
  assert(m and mirror.same_map(m.tm, M106), "the merge is on the winner's map, and says so")
  assert(near(num(m.state, "POSITION"), 20 * 120 / 106) and near(num(m.state, "LENGTH"), 4 * 120 / 106),
    "Bee's move stands, on its beat under the new map (was: lost to the map's own move, read as Cee's edit): " .. tostring(num(m.state, "POSITION")))
  assert(#(m.clashed or {}) == 0, "and nobody 'changed the same thing'")
  -- the other way round: the hand edit wins the order, the map's move is the loser
  local m2 = mirror.event_file(R, mirror.merge_id(l.id, w.id))
  assert(m2 and mirror.same_map(m2.tm, M120) and near(num(m2.state, "POSITION"), 20) and #(m2.clashed or {}) == 0, "on the old map, the move alone")
  local on106 = mirror.state_on(m2, M106, 1)
  assert(near(num(on106, "POSITION"), 20 * 120 / 106), "which lands at the same place under the new map as the other merge does")
  print("rt-converge 1c: versions made under different tempo maps merge on one map")
end

-- ---- 2. a change is judged by the claims as they stood when it was made -----------------------------------------------------------------------
do
  local cfg = { root = "R", user = "Dee" }
  files["R/Song/rooms/main/mode.json"] = { mode = "open", by = "James" }
  files[R .. "/claims/Cee.json"] = { user = "Cee", time = iso(T), tracks = { "Bass" }, since = { ["tracks:bass"] = iso(T) },
    times = { { from = 10, to = 20, at = iso(T) } } }
  local can, who = sync.authority(cfg, "Song", "main", { host = "James", markers = {} })
  assert(who.mode == "open" and who.is_claimed("Bass"), "Claims mode; Cee holds Bass now")
  assert(can("James", "Bass") == false, "today, Bass isn't James's to change")
  assert(can("James", "Bass", nil, nil, nil, iso(T - 3600)) == true, "but his change from an hour before Cee's claim is judged by the claims then: allowed")
  assert(can("James", "Bass", nil, nil, nil, iso(T + 5)) == false, "one made after the claim: refused, as before")
  assert(can("James", "Bass", nil, nil, nil, iso(T)) == true, "one made in the claim's own second: the claim hadn't reached its maker, so it doesn't hold it back a minute (rt-r2's 61 s)")
  assert(can("James", "Keys", 12, nil, nil, iso(T - 5)) == true and can("James", "Keys", 12, nil, nil, iso(T + 5)) == false, "a claimed stretch of time the same way")
  assert(who.is_claimed("Bass", nil, iso(T - 1)) == nil and who.owner_of("Bass", nil, nil, iso(T + 1)) == "Cee", "is_claimed and owner_of take the time too")
  sync.room_mode = "open"
  local ev = { type = "obj", obj = "track", oid = "T-JAMES-1", user = "James", name = "Bass", time = iso(T - 3600), state = { name = "Bass" } }
  assert(sync.obj_allowed(ev, can) == true, "sync.receive's judgement of a change (obj_allowed) goes by its own time")
  ev.time = iso(T + 5)
  assert(sync.obj_allowed(ev, can) == false, "and still refuses one made under the claim")
  print("rt-converge 2: a received change is judged by the claims of its own time")
end

-- ---- computers: the chunk-faithful stand-in REAPER, each look and receive wired as Live sync wires them (one Lua: caches are shared) ----------
local claimask = require("claimask")
local wire = {}
require("direct").send_live = function(cfg, kind, d) wire[#wire + 1] = { kind = kind, d = d, from = cfg.user }; return true end
claimask.reachable = function() return nil end
local here_now = {}
claimask.present = function(_, _, u) return here_now[u] == true end
local function studio(song, mode)
  local S = { song = song, dir = "R/" .. song .. "/rooms/main", sess = { host = "James", markers = {} }, b = { song = song, room = "main" }, by_user = {} }
  files[S.dir .. "/mode.json"] = { mode = mode, by = "James" }
  local function as(c) reaper = c.F.reaper end
  S.as = as
  function S.computer(user)
    local c = { F = E.new("C:/" .. user .. "/" .. song .. ".rpp"), cfg = { user = user, root = "R" }, user = user }
    c.F.reaper.MB = function() return 6 end
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or files[p] ~= nil end
    c.F.reaper.SetExtState(band.SECTION, "user", user, false)
    c.edited = -1
    S.by_user[user] = c
    return c
  end
  local function link()
    while #wire > 0 do
      local m = table.remove(wire, 1)
      if m.kind == "claim" then sync.live_claim(song, "main", m.d) end
    end
  end
  function S.look(c)
    as(c)
    c.F.clock = c.F.clock + 1
    local may, w = sync.authority(c.cfg, song, "main", S.sess)
    sync.driver_name, sync.room_mode = w.driver, w.mode
    if S.timeline then sync.watch_timeline(c.F.proj, c.cfg, song, "main", may) end -- (markers and tempo first, as Live sync looks)
    mirror.watch(c.F.proj, c.cfg, song, "main", { can = may, owner_can = may, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of, quick = true,
      edited_at = c.edited, soft = function(name, pos) return claimask.soft(w, name, pos, c.cfg.user) end,
      ask = function(name, pos) return claimask.hold(c.cfg, S.b, w, name, pos) end, sent = claimask.on_sent })
    claimask.flush(c.cfg, S.b, w, false)
    link()
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
  function S.recv(c, no_look)
    as(c)
    sync.ev_cache = {} -- (the stand-in computers share one memory of the files read and still waiting)
    for _ = 1, 20 do
      c.F.clock = c.F.clock + 1
      local may, w = sync.authority(c.cfg, song, "main", S.sess)
      sync.room_mode = w.mode
      sync.soft = { room = "main", fn = function(name, pos, user) return claimask.soft(w, name, pos, user) end }
      local got = sync.receive(c.F.proj, c.cfg, song, "main", may)
      if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
    end
    link()
    if not no_look then S.settle(c) end
  end
  function S.names(c) local t = {}; for _, tr in ipairs(c.F.tracks) do t[#t + 1] = tr.name end; return table.concat(t, ", ") end
  function S.track(c, name) for _, t in ipairs(c.F.tracks) do if t.name == name then return t end end end
  function S.items(c, name) local t = S.track(c, name); return t and #t.items or -1 end
  function S.events(pred) local out = {}; for p, v in pairs(files) do if p:find(S.dir .. "/events/", 1, true) and type(v) == "table" and pred(v) then out[#out + 1] = v end end; return out end
  return S
end
local function told(pattern) for _, l in ipairs(logged) do if l:find(pattern) then return l end end end

-- ---- 3. a track change moves its track only when its place is what it changes (the soak's bug 6) -----------------------------------------------
do
  local S = studio("Conv3", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Keys", "Gtr" }) do F.add_track(n) end end)
  S.recv(B)
  assert(S.names(B) == "Drums, Bass, Keys, Gtr", "the song on both (" .. S.names(B) .. ")")
  -- Bee drags Gtr to the top; James, who hasn't that yet, renames Drums
  S.edit(B, function(F) reaper.SetOnlyTrackSelected(S.track(B, "Gtr")); reaper.ReorderSelectedTracks(0, 0) end)
  assert(S.names(B) == "Gtr, Drums, Bass, Keys", "moved on Bee's (" .. S.names(B) .. ")")
  S.edit(A, function(F) reaper.GetSetMediaTrackInfo_String(S.track(A, "Drums"), "P_NAME", "T108", true) end)
  S.recv(A); S.recv(B)
  assert(S.names(A) == "Gtr, T108, Bass, Keys", "James has Bee's move and his own rename (" .. S.names(A) .. ")")
  assert(S.names(B) == S.names(A), "and Bee the same: the rename, which says nothing of the track's place, didn't put Drums back on top there (" .. S.names(B) .. ")")
  -- a real move still lands, also one back under the track the record names
  S.edit(A, function(F) reaper.SetOnlyTrackSelected(S.track(A, "Keys")); reaper.ReorderSelectedTracks(0, 0) end)
  S.recv(B)
  assert(S.names(B) == "Keys, Gtr, T108, Bass" and S.names(A) == S.names(B), "a move lands (" .. S.names(B) .. ")")
  -- a computer whose order has drifted (an older file's order: nobody moved anything) changes a fader: the track's place there isn't news
  S.as(B)
  table.insert(B.F.tracks, table.remove(B.F.tracks, 1)) -- (Keys at the bottom on Bee's, by no move of hers)
  mirror.order_seen[tostring(B.F.proj)] = nil
  S.edit(B, function(F) reaper.SetMediaTrackInfo_Value(S.track(B, "Keys"), "D_VOL", 0.5) end)
  local sent = S.events(function(v) return v.obj == "track" and v.name == "Keys" and v.user == "Bee" end)
  assert(#sent == 1 and sent[1].moved == nil and sent[1].state.after ~= "", "Bee's fader change names the place Keys has on her computer, and says no move")
  S.recv(A)
  assert(S.names(A) == "Keys, Gtr, T108, Bass", "James's Keys stays where the studio has it (was: it went to the bottom, as the change's place said): " .. S.names(A))
  -- a move that's held for an ask isn't in the studio's order list (Claims: the track is James's while he edits; Cee renames and moves it)
  local S2 = studio("Conv3c", "open")
  local J, C = S2.computer("James"), S2.computer("Cee")
  here_now = { James = true, Cee = true }
  S2.edit(J, function(F) for _, n in ipairs({ "Drums", "Bass", "Keys" }) do F.add_track(n) end end)
  S2.recv(C)
  T = T + sync.AUTO_IDLE + 120
  S2.edit(J, function(F) reaper.SetMediaTrackInfo_Value(S2.track(J, "Keys"), "D_VOL", 0.5) end)
  S2.recv(C)
  files[S2.dir .. "/order/Cee.json"] = nil
  T = T + 2
  S2.as(C)
  C.F.clock = C.F.clock + 1
  reaper.GetSetMediaTrackInfo_String(S2.track(C, "Keys"), "P_NAME", "K2", true)
  reaper.SetOnlyTrackSelected(S2.track(C, "K2"))
  reaper.ReorderSelectedTracks(0, 0)
  C.edited = C.F.clock
  S2.look(C)
  assert(#S2.events(function(v) return v.obj == "track" and v.user == "Cee" end) == 0, "Cee's rename and move of James's track wait for his answer: nothing went out")
  assert(files[S2.dir .. "/order/Cee.json"] == nil, "and the studio's order list doesn't say a move nobody has (was: written before the move was judged)")
  mirror.unsettled = nil
  print("rt-converge 3: a rename doesn't move its track; a move does; a drifted place isn't a move; a held move isn't in the order list")
end

-- ---- 4. a returning track's items come back on every computer (the soak's bug 4) ----------------------------------------------------------------
do
  local S = studio("Conv4", "everyone")
  local A, B, C = S.computer("James"), S.computer("Bee"), S.computer("Cee")
  S.edit(A, function(F) F.add_track("Bass"); F.add_track("Keys") end)
  S.recv(B); S.recv(C)
  -- Bee records a take on Bass (nothing else is on it: no other change is skipped while the track is gone); it reaches Cee, not James, who
  -- deletes Bass that moment
  S.edit(B, function(F) F.add_item(S.track(B, "Bass"), midi(5, 2)) end)
  S.recv(C)
  assert(S.items(C, "Bass") == 1, "Bee's take is on Cee's")
  local seen = {}
  for p in pairs(files) do seen[p] = true end
  S.edit(A, function(F) reaper.DeleteTrack(S.track(A, "Bass")) end)
  local gone
  for p, v in pairs(files) do if not seen[p] and type(v) == "table" and v.obj == "track" and v.gone then gone = v end end
  assert(gone, "James's deletion of Bass went out")
  S.recv(B); S.recv(C); S.recv(A)
  assert(not S.track(A, "Bass") and not S.track(B, "Bass") and not S.track(C, "Bass"), "Bass is gone everywhere")
  assert(S.track(B, "Bass (yours, not sent)") and S.items(B, "Bass (yours, not sent)") == 1, "Bee's own fresh take is kept on a track of Bee's own, as before")
  -- the deletion is taken back (an Undo's or a Restore's version of the track, built on the deletion)
  local first = S.events(function(v) return v.oid == gone.oid and not v.gone end)[1]
  local back = band.json_decode(band.json_encode(first))
  back.id, back.rev, back.base, back.base_ev, back.hlc, back.user = "James-20270115-080000Z-00099-0099", gone.rev + 1, gone.rev, gone.id, gone.hlc + 5, "James"
  files[S.dir .. "/events/" .. back.id .. ".json"] = back
  for _, c in ipairs({ A, B, C }) do S.recv(c) end
  for _, c in ipairs({ A, B, C }) do S.recv(c) end
  assert(S.track(A, "Bass") and S.track(B, "Bass") and S.track(C, "Bass"), "Bass is back everywhere")
  assert(S.items(A, "Bass") == 1, "on James's, with Bee's take, whose change he had skipped while the track was gone (as before): " .. S.items(A, "Bass"))
  assert(S.items(C, "Bass") == 1, "on Cee's too, where the take had landed before the deletion and went with the track (was: gone for good): " .. S.items(C, "Bass"))
  assert(S.items(B, "Bass") == 1, "and on Bee's own, who recorded it (was: only on the track of Bee's own): " .. S.items(B, "Bass"))
  print("rt-converge 4: a track that comes back brings its items back on every computer")
end

-- ---- 5. two holders of one track don't answer each other's rename for ever (the soak's bug 2) ------------------------------------------------
do
  local S = studio("Conv5", "open")
  local A, C = S.computer("James"), S.computer("Cee")
  here_now = { James = true, Cee = true }
  S.edit(A, function(F) F.add_track("Gtr"); F.add_track("Keys") end)
  S.recv(C)
  T = T + sync.AUTO_IDLE + 120 -- (sharing the song is nobody's work in progress any more)
  local seen = {}
  for p in pairs(files) do seen[p] = true end
  local function new_events(c)
    local out = {}
    for p, v in pairs(files) do if not seen[p] and p:find(S.dir .. "/events/", 1, true) and type(v) == "table" then seen[p] = true; out[#out + 1] = v end end
    return out
  end
  -- James renames Gtr; Cee, who hasn't the rename yet, turns its fader down in the same second: each auto-claims the track, by another name
  S.edit(A, function(F) reaper.GetSetMediaTrackInfo_String(S.track(A, "Gtr"), "P_NAME", "T180", true) end)
  S.edit(C, function(F) reaper.SetMediaTrackInfo_Value(S.track(C, "Gtr"), "D_VOL", 0.25) end)
  local w = select(2, sync.authority(A.cfg, S.song, "main", S.sess))
  assert(w.tracks.t180 and w.tracks.t180.user == "James" and w.tracks.gtr and w.tracks.gtr.user == "Cee", "two holders of one track: James by T180, Cee by Gtr")
  new_events()
  logged = {}
  for round = 1, 6 do
    S.recv(A); S.recv(C)
    T = T + 61 -- (a refused change's minute)
    for _, c in ipairs({ A, C }) do c.F.clock = c.F.clock + 61 end
  end
  local sent = new_events()
  assert(#sent <= 2, "the two computers settle it in a round, not by answering each other for good (" .. #sent .. " more changes went out)")
  assert(S.track(A, "T180") and S.track(C, "T180") or S.track(A, "Gtr") and S.track(C, "Gtr"), "one name on both (" .. S.names(A) .. " / " .. S.names(C) .. ")")
  local ta, tc = S.track(A, "T180") or S.track(A, "Gtr"), S.track(C, "T180") or S.track(C, "Gtr")
  S.as(A); local va = reaper.GetMediaTrackInfo_Value(ta, "D_VOL")
  S.as(C); local vc = reaper.GetMediaTrackInfo_Value(tc, "D_VOL")
  assert(va == vc, "and one fader (" .. va .. " / " .. vc .. ")")
  assert(S.track(A, "T180") and va == 0.25, "James's rename and Cee's fader both: her change renamed nothing, so it's merged in (" .. S.names(A) .. ", " .. va .. ")")
  assert(not told("renamed T180, which you've claimed"), "and James isn't told Cee renamed his track, nor answers her: " .. (told("renamed T180") or ""))
  print("rt-converge 5: a rename and an edit that cross, each holder by another name: settled, no rename war")
end

-- ---- 6. an item moved off a track before the track was deleted elsewhere: its deletion lands (the soak's seed 37) ------------------------------
do
  local S = studio("Conv6", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) F.add_item(F.add_track("Gtr"), midi(1, 2)); F.add_track("Drums") end)
  S.recv(B)
  -- Bee moves the item to Drums; James, who hasn't that yet, deletes Gtr with the item on it
  S.edit(B, function(F) reaper.MoveMediaItemToTrack(S.track(B, "Gtr").items[1], S.track(B, "Drums")) end)
  assert(S.items(B, "Drums") == 1, "moved on Bee's")
  S.edit(A, function(F) reaper.DeleteTrack(S.track(A, "Gtr")) end)
  S.recv(A); S.recv(B); S.recv(A); S.recv(B)
  assert(not S.track(A, "Gtr") and not S.track(B, "Gtr"), "Gtr is gone on both")
  assert(S.items(A, "Drums") == 0, "James's deletion beats the move made without seeing it: no item on his Drums (" .. S.items(A, "Drums") .. ")")
  assert(S.items(B, "Drums") == 0, "nor on Bee's, where the item wasn't on the deleted track any more (was: recorded gone and left in the project): " .. S.items(B, "Drums"))
  print("rt-converge 6: an item's deletion lands though the item had moved off its deleted track here")
end

-- ---- 7. what was refused doesn't stay on this computer alone (the soak's seeds 26 and 37: asked about every 90 s for good) -----------------------
do
  local S = studio("Conv7", "open")
  local A = S.computer("James")
  here_now = { James = true } -- (Cee isn't here: an edit of her claim is put back at once, with why)
  S.edit(A, function(F) F.add_item(F.add_track("Keys"), midi(1, 2)); F.add_track("Drums") end)
  T = T + sync.AUTO_IDLE + 120
  files[S.dir .. "/claims/Cee.json"] = { user = "Cee", time = iso(T), tracks = { "Keys" }, since = { ["tracks:keys"] = iso(T) } }
  T = T + 5
  -- automation drawn on Keys, which had none: not James's to add
  logged = {}
  local keys = S.track(A, "Keys")
  S.edit(A, function(F) keys.body = keys.body .. "<VOLENV2\nEGUID {E-1}\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 4 0.5 0\n>\n"; F.changed() end)
  assert(told("Cee has claimed Keys and isn't here to release it"), "refused, with why")
  assert(not keys.body:find("VOLENV2", 1, true), "and taken off again: what you see is what the band has (was: it stayed on this computer, asked about every 90 s)")
  local n = 0
  for _, v in pairs(files) do if type(v) == "table" and v.obj == "env" then n = n + 1 end end
  assert(n == 0, "nothing went out")
  -- an item the band deleted, here again (REAPER's own Undo of the deletion landing): not James's to bring back
  local item = keys.items[1]
  local oid = item.ext.band_oid
  local rev, _, evid = mirror.known(A.F.proj, oid)
  local first = files[S.dir .. "/events/" .. evid .. ".json"]
  local gone = { type = "obj", obj = "item", oid = oid, gone = true, rev = rev + 1001, base = rev, base_ev = evid, user = "Cee", name = "Keys", track = first.track,
    id = "Cee-20270115-090000Z-00001-0007", time = iso(T), hlc = first.hlc + 5000, format = first.format }
  files[S.dir .. "/events/" .. gone.id .. ".json"] = gone
  local text = item.text
  S.recv(A)
  assert(#keys.items == 0, "Cee's deletion landed")
  logged = {}
  S.edit(A, function(F) local it = F.add_item(keys, text); it.ext.band_oid = oid end)
  assert(#keys.items == 0 and S.items(A, "Keys (yours, not sent)") == 1, "put back: off Keys, kept on a track of James's own (was: 'couldn't put back', and it stayed on Keys)")
  assert(not told("couldn't put back"), "and nothing says the studio's version hasn't arrived: " .. (told("couldn't put back") or ""))
  print("rt-converge 7: refused automation on a track that had none is taken off; a deleted item brought back here goes to a track of your own")
end

-- ---- 8. Undo then Redo brings the song back (the soak's bug 9 and its undo probe) ------------------------------------------------------------
do
  local undo = require("undo")
  local S = studio("Conv8", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) local k = F.add_track("Keys"); F.add_item(k, midi(1, 2)); F.add_item(k, midi(8, 2)) end)
  S.recv(B)
  local function step(c, redo)
    S.as(c)
    c.F.clock = c.F.clock + 1
    T = T + 2
    local res, why = undo.step(c.F.proj, c.cfg, S.b, redo, {})
    S.settle(c)
    return tostring(res or why)
  end
  local function pos_of(c, i) return num(S.track(c, "Keys").items[i].text, "POSITION") end
  -- a. Bee deletes James's item, undoes that, and redoes it: gone again
  T = T + 2
  S.edit(B, function(F) reaper.DeleteTrackMediaItem(S.track(B, "Keys"), S.track(B, "Keys").items[2]) end)
  assert(S.items(B, "Keys") == 1, "deleted on Bee's")
  local u = step(B, false)
  assert(S.items(B, "Keys") == 2, "Bee's Undo brought it back (" .. u .. ")")
  local r = step(B, true)
  assert(S.items(B, "Keys") == 1, "and her Redo took it away again (was: '0 change(s) brought back (kept what collaborators added since)'): " .. r)
  S.recv(A)
  assert(S.items(A, "Keys") == 1, "on James's too")
  -- b. James mutes the item while Bee moves it: merged on both. James then lengthens it, undoes that, and redoes it
  T = T + 2
  S.edit(A, function(F) reaper.SetMediaItemInfo_Value(S.track(A, "Keys").items[1], "B_MUTE", 1) end)
  S.edit(B, function(F) reaper.SetMediaItemInfo_Value(S.track(B, "Keys").items[1], "D_POSITION", 3) end)
  S.recv(A); S.recv(B)
  local function shape(c) local it = S.track(c, "Keys").items[1]; S.as(c); return string.format("%g %g %g", pos_of(c, 1), reaper.GetMediaItemInfo_Value(it, "B_MUTE"), num(it.text, "LENGTH")) end
  assert(shape(A) == "3 1 2" and shape(B) == "3 1 2", "both changes are in, on both (" .. shape(A) .. " / " .. shape(B) .. ")")
  T = T + 40 -- (another edit, not a nudge of the last)
  A.F.clock = A.F.clock + 40
  S.edit(A, function(F) reaper.SetMediaItemInfo_Value(S.track(A, "Keys").items[1], "D_LENGTH", 5) end)
  assert(shape(A) == "3 1 5", "lengthened (" .. shape(A) .. ")")
  u = step(A, false)
  assert(shape(A) == "3 1 2", "James's Undo takes back the length alone: Bee's move and his mute, merged in before it, stay (was: one of the two went too): " .. shape(A))
  r = step(A, true)
  assert(shape(A) == "3 1 5", "and his Redo brings the length back on top of both (" .. shape(A) .. ")")
  S.recv(B)
  assert(shape(B) == "3 1 5", "on Bee's too (" .. shape(B) .. ")")
  -- c. an Undo that takes nothing back leaves nothing to redo (Claims mode: the change it reaches isn't James's to change any more)
  local S2 = studio("Conv8c", "open")
  local J = S2.computer("James")
  here_now = { James = true }
  S2.edit(J, function(F) F.add_item(F.add_track("Keys"), midi(1, 2)); F.add_track("Drums") end)
  local function step2(redo)
    S2.as(J)
    J.F.clock = J.F.clock + 1
    T = T + 2
    local res, why = undo.step(J.F.proj, J.cfg, S2.b, redo, {})
    S2.settle(J)
    return tostring(res or why)
  end
  T = T + 2
  S2.edit(J, function(F) reaper.SetMediaItemInfo_Value(S2.track(J, "Keys").items[1], "D_POSITION", 4) end)
  T = T + 40
  J.F.clock = J.F.clock + 40
  S2.edit(J, function(F) F.add_item(S2.track(J, "Drums"), midi(6, 2)) end)
  assert(S2.items(J, "Drums") == 1, "a new item on Drums")
  u = step2(false)
  assert(S2.items(J, "Drums") == 0, "undone (" .. u .. ")")
  T = T + 120
  files[S2.dir .. "/claims/Cee.json"] = { user = "Cee", time = iso(T), tracks = { "Keys" }, since = { ["tracks:keys"] = iso(T) } }
  T = T + 5
  u = step2(false)
  assert(u:find("^0 change") and u:find("not yours to change"), "the next Undo reaches the move on Keys, Cee's now: nothing taken back (" .. u .. ")")
  r = step2(true)
  assert(r:find("took nothing back") and S2.items(J, "Drums") == 0, "and the Redo after it redoes nothing (was: it redid the Undo before, and the item was back): " .. r)
  -- d. an Undo of your edit doesn't bring back what a bandmate deleted since
  local S4 = studio("Conv8d", "everyone")
  local P, Q = S4.computer("James"), S4.computer("Bee")
  S4.edit(P, function(F) F.add_item(F.add_track("Keys"), midi(1, 2)) end)
  S4.recv(Q)
  T = T + 2
  S4.edit(Q, function(F) reaper.SetMediaItemInfo_Value(S4.track(Q, "Keys").items[1], "D_POSITION", 5) end)
  S4.recv(P)
  T = T + 2
  S4.edit(P, function(F) reaper.DeleteTrackMediaItem(S4.track(P, "Keys"), S4.track(P, "Keys").items[1]) end)
  S4.recv(Q)
  assert(S4.items(Q, "Keys") == 0, "James deleted the item Bee had moved: gone on Bee's")
  S4.as(Q)
  Q.F.clock = Q.F.clock + 1
  T = T + 2
  u = tostring(undo.step(Q.F.proj, Q.cfg, S4.b, false, {}))
  S4.settle(Q)
  assert(S4.items(Q, "Keys") == 0 and u:find("deleted by a bandmate since"), "Bee's Undo of her move leaves his deletion (was: the item came back for everyone, as it was before her move): " .. u)
  print("rt-converge 8: a Redo takes away what your own Undo brought back; Undo and Redo of a change built on a merge keep the merge; no Redo after an Undo of nothing; an Undo doesn't revive what a bandmate deleted")
end

-- ---- 9. the studio's track order is the order everyone landed (the soak's late joiner, "track order differs") ----------------------------------
do
  -- a. pure: of two tracks added under one, the later sits right under it, as it landed on every computer that was here
  local function w(list, here, after) return table.concat(mirror.wanted_order(list, here, after), " ") end
  local x, y, z = "T-BEE-20270101000001-10001", "T-CEE-20270101000002-10002", "T-BEE-20270101000003-20003"
  assert(w({ "A", "B" }, { "A", x, y, "B" }, { [x] = "A", [y] = "A" }) == "A " .. y .. " " .. x .. " B", "the later one first (was: by id, the earlier first)")
  assert(w({ "A", "B" }, { "B", y, x, "A" }, { [x] = "A", [y] = "A" }) == "A " .. y .. " " .. x .. " B", "whatever the order here")
  assert(w({ "A" }, { "A", x, y, z }, { [x] = "A", [y] = "A", [z] = x }) == "A " .. y .. " " .. x .. " " .. z, "and one under an earlier new one, where it landed")
  -- b. a track dragged just after a bandmate's new track landed is this person's move: it goes out as one, with the order list
  local S = studio("Conv9", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) for _, n in ipairs({ "Drums", "Bass", "Keys" }) do F.add_track(n) end end)
  S.recv(B)
  S.edit(A, function(F) F.add_track("New") end)
  S.recv(B, true) -- (James's track lands on Bee's; no look yet)
  T = T + 2
  S.edit(B, function(F) reaper.SetOnlyTrackSelected(S.track(B, "Keys")); reaper.ReorderSelectedTracks(0, 0) end)
  assert(S.names(B) == "Keys, Drums, Bass, New", "moved on Bee's (" .. S.names(B) .. ")")
  local moves = S.events(function(v) return v.obj == "track" and v.user == "Bee" and v.moved ~= nil end)
  assert(#moves == 1, "Bee's move went out as a move (was: taken for the band's doing, as a track of theirs had landed since the last look): " .. #moves)
  local ol = files[S.dir .. "/order/Bee.json"]
  assert(ol and ol.list[1] == moves[1].oid, "and the studio's order list has it")
  S.recv(A)
  assert(S.names(A) == S.names(B), "on James's too (" .. S.names(A) .. ")")
  -- c. a move of a bandmate's auto-claimed track goes out and merges (Claims): the order list follows that too
  local S3 = studio("Conv9c", "open")
  local J, C = S3.computer("James"), S3.computer("Cee")
  here_now = { James = true, Cee = true }
  S3.edit(J, function(F) for _, n in ipairs({ "Drums", "Bass", "Keys" }) do F.add_track(n) end end)
  S3.recv(C)
  T = T + sync.AUTO_IDLE + 120
  S3.edit(J, function(F) reaper.SetMediaTrackInfo_Value(S3.track(J, "Keys"), "D_VOL", 0.5) end) -- (James works on Keys: his while he edits)
  S3.recv(C)
  assert(select(2, sync.authority(C.cfg, S3.song, "main", S3.sess)).tracks.keys.user == "James", "Keys is James's auto-claim")
  T = T + 2
  files[S3.dir .. "/order/Cee.json"] = nil
  S3.edit(C, function(F) reaper.SetOnlyTrackSelected(S3.track(C, "Keys")); reaper.ReorderSelectedTracks(0, 0) end)
  assert(#S3.events(function(v) return v.obj == "track" and v.user == "Cee" and v.moved ~= nil end) == 1, "Cee's move of Keys went out (it merges with James's fader)")
  assert(files[S3.dir .. "/order/Cee.json"], "and the studio's order list follows it (was: only when every moved track was the mover's outright)")
  print("rt-converge 9: new tracks in the order they landed; a move after a bandmate's track landed, or of an auto-claimed track, reaches the order list")
end

-- ---- 10. a computer catching up drops an edit that a deletion beat, as those that were here did -----------------------------------------------
do
  local undo = require("undo")
  local S = studio("Conv10", "everyone")
  local A, C = S.computer("James"), S.computer("Cee")
  S.edit(A, function(F) F.add_item(F.add_track("Keys"), midi(1, 2)) end)
  S.recv(C)
  -- James deletes the item; Cee, who hasn't that yet, mutes it; James takes his deletion back
  T = T + 2
  S.edit(A, function(F) reaper.DeleteTrackMediaItem(S.track(A, "Keys"), S.track(A, "Keys").items[1]) end)
  T = T + 2
  S.edit(C, function(F) reaper.SetMediaItemInfo_Value(S.track(C, "Keys").items[1], "B_MUTE", 1) end)
  T = T + 2
  S.as(A)
  A.F.clock = A.F.clock + 1
  assert(tostring(undo.step(A.F.proj, A.cfg, S.b, false, {})):find("^1 change"), "James's Undo of the deletion")
  S.settle(A)
  S.recv(A); S.recv(C); S.recv(A); S.recv(C)
  local function muted(c) S.as(c); return reaper.GetMediaItemInfo_Value(S.track(c, "Keys").items[1], "B_MUTE") end
  assert(S.items(A, "Keys") == 1 and S.items(C, "Keys") == 1 and muted(A) == 0 and muted(C) == 0,
    "the item is back, as James had it: Cee's mute, made without seeing the deletion, went with it (on both, as before)")
  -- a late joiner reads all four changes at once
  local D = S.computer("Dee")
  S.recv(D)
  assert(S.items(D, "Keys") == 1 and muted(D) == 0, "and a late joiner ends the same (was: the mute merged back in, there alone): " .. muted(D))
  print("rt-converge 10: catching up, an edit a deletion beat stays dropped though a restore made the deletion older news")
end

-- ---- 11. Undo and Redo of an act with a marker go by the timeline's own order, not History's rows (the soak's seed 31) --------------------------
do
  local undo = require("undo")
  local S = studio("Conv11", "everyone")
  S.timeline = true
  local B, C = S.computer("Bee"), S.computer("Cee")
  S.edit(C, function(F) F.add_item(F.add_track("Keys"), midi(1, 2)) end)
  S.recv(B)
  local function marks(c) S.as(c); local t = {}; for _, m in ipairs(band.capture_markers(c.F.proj)) do t[#t + 1] = m.name end; return table.concat(t, ",") end
  -- Cee adds a marker; Bee, in the same second by the clocks, has it land and then adds her own with a note (one act)
  S.edit(C, function(F) F.add_marker(false, 2, 2, "C1") end)
  S.recv(B)
  assert(marks(B) == "C1", "Cee's marker is on Bee's (" .. marks(B) .. ")")
  S.edit(B, function(F)
    F.add_marker(false, 7, 7, "B1")
    local it = S.track(B, "Keys").items[1]
    F.set_text(it, (it.text:gsub("E 960 b0 7b 00", "E 100 90 40 60\nE 100 80 40 00\nE 760 b0 7b 00")))
  end)
  assert(marks(B) == "C1,B1", "Bee's marker (" .. marks(B) .. ")")
  local tl = S.events(function(v) return v.type == "timeline" end)
  table.sort(tl, function(a, b) return a.time .. a.id < b.time .. b.id end)
  assert(#tl == 2 and tl[1].user == "Bee" and tl[2].user == "Cee" and (tl[1].order or "") > tl[2].time .. tl[2].id,
    "the case: Bee's timeline change is the newer by the timeline's order, and sits before Cee's in History's rows (one clock second)")
  local function step(redo)
    S.as(B)
    B.F.clock = B.F.clock + 1
    T = T + 2
    local res, why = undo.step(B.F.proj, B.cfg, S.b, redo, {})
    S.settle(B)
    return tostring(res or why)
  end
  local u = step(false)
  assert(marks(B) == "C1", "Bee's Undo takes her marker back with the note (" .. u .. "; " .. marks(B) .. ")")
  local r = step(true)
  assert(marks(B) == "C1,B1", "and her Redo brings it back (was: compared against Cee's timeline, nothing to bring back): " .. r .. "; " .. marks(B))
  S.recv(C)
  assert(marks(C) == "C1,B1", "on Cee's too (" .. marks(C) .. ")")
  print("rt-converge 11: the Redo of an Undo brings its marker back though a bandmate's timeline change sorts after it in History")
end

-- ---- 12. no choice follows Lua's table order (the soak's bug 8: two runs of one seed wrote different things) -----------------------------------
do
  local undo = require("undo")
  local S = studio("Conv12", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  local names = { "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8" }
  S.edit(A, function(F) for i, n in ipairs(names) do F.add_item(F.add_track(n), midi(i, 1)) end end)
  -- a. heal lands a whole song in one go, in one order: tracks under the tracks they sit under, then what's on them
  S.as(B)
  local n = mirror.heal(B.F.proj, S.dir, false)
  assert(S.names(B) == table.concat(names, ", "), "every track where it belongs after one heal (was: as Lua walked its table, a track before the one above it went to the top): " .. S.names(B))
  for _, nm in ipairs(names) do assert(S.items(B, nm) == 1, "and its item on it (was: an item before its track waited for the next heal): " .. nm) end
  assert(n >= 16, "all of them: " .. n)
  -- b. an Undo's changes go out in one order: by id, whichever way Lua walks the plan
  T = T + 2
  local seen = {}
  for p in pairs(files) do seen[p] = true end
  S.edit(A, function(F) for _, t in ipairs(A.F.tracks) do reaper.SetMediaItemInfo_Value(t.items[1], "B_MUTE", 1) end end)
  for p in pairs(files) do seen[p] = true end
  S.as(A)
  A.F.clock = A.F.clock + 1
  T = T + 2
  assert(tostring(undo.step(A.F.proj, A.cfg, S.b, false, {})):find("^8 change"), "the eight mutes undone as one act")
  local sent = {}
  for p, v in pairs(files) do if not seen[p] and type(v) == "table" and v.obj == "item" then sent[#sent + 1] = v end end
  table.sort(sent, function(a, b) return a.id < b.id end) -- (ids count up as changes go out)
  assert(#sent == 8, "eight restores went out: " .. #sent)
  for i = 2, #sent do assert(sent[i - 1].oid < sent[i].oid, "in the order of their ids (was: the plan table's own order, another every run)") end
  print("rt-converge 12: heal and Undo work through their objects in one order on every computer and every run")
end

-- (plug-ins through the API, read from the chain's text as REAPER's would read: one knob per plug-in, the number in its state line. The
-- stand-in has none, and with no knobs mirror takes a chain edit for REAPER re-encoding the chain. As tools/soak/node.lua.)
local function fx_api(c)
  local function blocks(tr)
    local list, cur, d = {}, nil, 0
    for l in (tr.body or ""):gmatch("[^\n]+") do
      if l == "<FXCHAIN" then d = 1
      elseif d == 1 and l:match("^BYPASS ") then cur = { l }; list[#list + 1] = cur
      elseif d >= 1 then
        if cur and not (d == 1 and l == ">") then cur[#cur + 1] = l end
        if l:sub(1, 1) == "<" then d = d + 1 elseif l == ">" then d = d - 1 end
      end
    end
    return list
  end
  local R = c.F.reaper
  rawset(R, "TrackFX_GetCount", function(tr) return #blocks(tr) end)
  rawset(R, "TrackFX_GetNumParams", function(tr, i) return blocks(tr)[i + 1] and 1 or 0 end)
  rawset(R, "TrackFX_GetParamNormalized", function(tr, i) local b = blocks(tr)[i + 1]; return b and (tonumber((b[3] or ""):match("^QUFB(%d+)")) or 0) / 1000 or 0 end)
  rawset(R, "TrackFX_GetFXName", function(tr, i) local b = blocks(tr)[i + 1]; return b ~= nil, b and b[2]:match('^<%u+ "([^"]*)"') or "" end)
  rawset(R, "TrackFX_GetPreset", function() return false, "" end)
  rawset(R, "TrackFX_GetOpen", function() return false end)
  rawset(R, "TrackFX_GetEnabled", function(tr, i) return blocks(tr)[i + 1] ~= nil end)
  rawset(R, "TrackFX_GetOffline", function() return false end)
  rawset(R, "TrackFX_GetFXGUID", function(tr, i) for _, l in ipairs(blocks(tr)[i + 1] or {}) do local g = l:match("^FXID (%S+)"); if g then return g end end end)
end
local function chain(eq, comp, comp_first)
  local a = { "BYPASS 0 0 0", '<VST "VST: ReaEQ (Cockos)" reaeq.dll 0 "" 1919247729<56535472656571726561657100000000> ""', "QUFB" .. eq .. "AAAA", ">", "FLOATPOS 0 0 0 0", "FXID {EQ-1}", "WAK 0 0" }
  local b = { "BYPASS 0 0 0", '<VST "VST: ReaComp (Cockos)" reacomp.dll 0 "" 1919247213<56535472636D70726561636F6D7000> ""', "QUFB" .. comp .. "AAAA", ">", "FLOATPOS 0 0 0 0", "FXID {CO-1}", "WAK 0 0" }
  local first, second = comp_first and b or a, comp_first and a or b
  return "<FXCHAIN\nSHOW 0\nLASTSEL 0\nDOCKED 0\n" .. table.concat(first, "\n") .. "\n" .. table.concat(second, "\n") .. "\n>\n"
end

-- ---- 13. a knob turned here that no look has seen holds the band's chain back (rt-r2's P1-4 and P1-1: the edit gone everywhere, no line) --------
do
  local S = studio("Conv13", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  fx_api(A); fx_api(B)
  S.edit(A, function(F) F.add_track("Keys", nil, chain(100, 200)) end)
  A.F.clock = A.F.clock + 70
  S.settle(A)
  S.recv(B)
  B.F.clock = B.F.clock + 70 -- (past the minute a landed chain may still be loading)
  S.settle(B)
  local function knobs(c) local t = S.track(c, "Keys"); return (t.body:gsub("\n", " "):gsub(".-QUFB(%d+)AAAA", "%1 ", 2):match("^(%d+ %d+)")) end
  local function comp_first(c) local b = S.track(c, "Keys").body; return b:find("ReaComp", 1, true) < b:find("ReaEQ", 1, true) end
  assert(knobs(B) == "100 200", "the chain is on Bee's (" .. tostring(knobs(B)) .. ")")
  -- Bee turns the EQ's knob from a script: REAPER's change count doesn't move, so no look has seen it yet when James's reorder arrives
  T = T + 2
  S.as(B)
  S.track(B, "Keys").body = chain(150, 200)
  S.edit(A, function(F) S.track(A, "Keys").body = chain(100, 200, true); F.changed() end)
  A.F.clock = A.F.clock + 2
  S.settle(A)
  assert(#S.events(function(v) return v.obj == "fx" and v.user == "James" end) == 2, "James's reorder went out")
  S.recv(B, true) -- (it arrives; Bee's computer hasn't looked since her knob)
  assert(knobs(B) == "150 200" and not comp_first(B), "Bee's knob is still there: James's chain waits for her edit to go out (was: it replaced the chain, her value gone everywhere, no line)")
  B.edited = B.F.clock
  S.settle(B)
  assert(#S.events(function(v) return v.obj == "fx" and v.user == "Bee" end) == 1, "the look after it sends her knob")
  for _ = 1, 3 do B.F.clock = B.F.clock + 6; A.F.clock = A.F.clock + 6; S.recv(B); S.recv(A) end -- (two chains on one track land 5 s apart: FX_SET_GAP)
  assert(comp_first(A) and comp_first(B), "James's order on both")
  assert(knobs(A) == "200 150" and knobs(B) == "200 150", "with Bee's EQ value, merged by plug-in (" .. tostring(knobs(A)) .. " / " .. tostring(knobs(B)) .. ")")
  -- and the check doesn't hold a chain back for good: plug-ins Bee adds to a bare track in the project's first minute, then changed by James
  -- (the knobs it compares with are those the chain last went out or landed with, not the bare track's from the project's first look)
  local S2 = studio("Conv13b", "everyone")
  local J, Q = S2.computer("James"), S2.computer("Bee")
  fx_api(J); fx_api(Q)
  S2.edit(J, function(F) F.add_track("Keys") end)
  S2.recv(Q)
  T = T + 2
  S2.edit(Q, function(F) S2.track(Q, "Keys").body = chain(100, 200); F.changed() end)
  Q.F.clock = Q.F.clock + 2
  S2.settle(Q)
  S2.recv(J)
  assert(S2.track(J, "Keys").body:find("QUFB100AAAA", 1, true), "Bee's new plug-ins are on James's")
  T = T + 2
  S2.edit(J, function(F) S2.track(J, "Keys").body = chain(170, 200); F.changed() end)
  J.F.clock = J.F.clock + 2
  S2.settle(J)
  for _ = 1, 3 do Q.F.clock = Q.F.clock + 6; S2.recv(Q) end
  assert(S2.track(Q, "Keys").body:find("QUFB170AAAA", 1, true), "James's knob lands on Bee's (a check against the first look's knobs held it back for good)")
  print("rt-converge 13: a knob turned from a script isn't lost to a bandmate's chain landing before the next look")
end

-- ---- 14. REAPER's own Undo of a track deletion brings the track back for everyone (rt-r2's P1-6: read as a reopen, deleted again, errors) ------
do
  local S = studio("Conv14", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  fx_api(A); fx_api(B)
  S.edit(A, function(F) F.add_item(F.add_track("Gtr", nil, chain(100, 200)), midi(1, 2)); F.add_track("Keys") end)
  A.F.clock = A.F.clock + 70
  S.settle(A)
  S.recv(B)
  local gtr = S.track(A, "Gtr")
  local guid, body, item_guid, item_text = gtr.guid, gtr.body, gtr.items[1].guid, gtr.items[1].text
  -- (REAPER brings a deleted track back as its undo point had it: the same GUIDs, and no StudioSync id on it or its item)
  local function undo_delete(c)
    local t = c.F.add_track("Gtr", 1, body)
    t.guid, t.ext = guid, {}
    local it = c.F.add_item(t, item_text)
    it.guid, it.ext = item_guid, {}
    return t
  end
  T = T + 2
  S.edit(A, function(F) reaper.DeleteTrack(gtr) end)
  S.recv(B)
  assert(not S.track(A, "Gtr") and not S.track(B, "Gtr"), "James deleted Gtr: gone on both")
  logged = {}
  T = T + 2
  S.edit(A, function(F) undo_delete(A) end)
  A.F.clock = A.F.clock + 2
  S.settle(A)
  assert(S.track(A, "Gtr") and S.items(A, "Gtr") == 1, "REAPER's Undo of the deletion: the track stays back on James's (was: deleted again as 'the band deleted it since')")
  assert(not told("opened without its last save"), "and isn't taken for a file opened without its last save: " .. (told("opened without") or ""))
  for _ = 1, 2 do B.F.clock = B.F.clock + 6; S.recv(B) end
  assert(S.track(B, "Gtr") and S.items(B, "Gtr") == 1, "it's back on Bee's too, with its item")
  assert(S.track(B, "Gtr").body:find("ReaComp", 1, true), "and its plug-ins")
  -- a file really opened without its last save, with a track the band deleted since: the track goes again, and what was on it is passed over
  T = T + 2
  S.edit(B, function(F) reaper.DeleteTrack(S.track(B, "Gtr")) end)
  S.recv(A)
  assert(not S.track(A, "Gtr"), "Bee deleted it: gone on James's")
  local dead = {}
  local count = A.F.reaper.TrackFX_GetCount
  rawset(A.F.reaper, "TrackFX_GetCount", function(tr) assert(not dead[tr], "bad argument #1 to 'TrackFX_GetCount' (MediaTrack expected)"); return count(tr) end)
  local del = A.F.reaper.DeleteTrack
  rawset(A.F.reaper, "DeleteTrack", function(tr) dead[tr] = true; return del(tr) end)
  S.as(A)
  mirror.order_seen[tostring(A.F.proj)] = nil -- (the project's first look again: it was opened afresh)
  logged = {}
  undo_delete(A)
  A.F.changed()
  S.settle(A)
  assert(told("opened without its last save") and not S.track(A, "Gtr"), "an older file's copy of a track the band deleted: gone again, as before")
  assert(not told("mirror sync skipped"), "and nothing of the track is looked at once it's gone (was: its plug-ins read through the dead track, an error each): " .. (told("mirror sync skipped") or ""))
  print("rt-converge 14: Ctrl+Z after a track delete sends the track back; a reopened file's deleted track goes without errors")
end

-- ---- 15. (a pin, no fix: rt-r2's P1-5) which plug-in changes ask a bandmate who holds the track while they edit --------------------------------
do
  local hlc = math.floor(T * 1000)
  local function put(id, user, state, base, age)
    local ev = { type = "obj", obj = "fx", oid = "F-P15", id = id, user = user, state = state, base_ev = base, hlc = hlc - age * 1000, time = iso(T - age), mg = 1 }
    files[R .. "/events/" .. id .. ".json"] = ev
    return ev
  end
  local function c(eq, comp) return (chain(eq, comp):gsub("\n$", "")) end
  -- the chain was Cee's, an hour ago; James changes the EQ now, which makes the track his while he edits
  local added = put("Cee-20270115-070000Z-00001-0151", "Cee", c(100, 200), nil, 3600)
  local eq = put("James-20270115-080000Z-00001-0152", "James", c(150, 200), added.id, 5)
  assert(mirror.clashes(R, "fx", c(150, 250), eq, "James") == false, "a change to another plug-in of the chain than James changed: no ask, it merges by plug-in")
  assert(mirror.clashes(R, "fx", c(170, 200), eq, "James") == true, "a change to the plug-in he changed: asked")
  -- as rt-r2 ran it: James added both plug-ins two minutes before
  local added2 = put("James-20270115-075800Z-00001-0153", "James", c(100, 200), nil, 120)
  local eq2 = put("James-20270115-080000Z-00002-0154", "James", c(150, 200), added2.id, 5)
  assert(mirror.clashes(R, "fx", c(150, 250), eq2, "James") == true,
    "the other plug-in is his recent work too when he added the chain within the claim's ten minutes: asked (why P1-5 asked in rt-r2)")
  print("rt-converge 15: (pin) another plug-in than the claimer changed merges without an ask; one they added lately asks")
end

-- ---- 16. lanes that only read differently here, with no edit behind the look, don't go out (LinuxBox2's lane names, left by rt-fix6a) -----------
do
  local S = studio("Conv16", "everyone")
  local A, B = S.computer("James"), S.computer("Bee")
  local function lanes(c, names, plays)
    local tr = S.track(c, "Rec")
    reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
    reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", #names)
    for i, n in ipairs(names) do
      reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. (i - 1), n, true)
      reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. (i - 1), plays[i])
    end
  end
  local function lanes_of(c) S.as(c); return mirror.track_state(c.F.proj, S.track(c, "Rec"), false).lanenames end
  S.edit(A, function(F) F.add_track("Rec"); lanes(A, { "1", "Verse take 2", "Verse take 3" }, { 0, 0, 1 }) end)
  S.recv(B)
  assert(lanes_of(B) == "1,Verse take 2,Verse take 3", "the band's lane names on Bee's (" .. lanes_of(B) .. ")")
  local function bee_sent() return #S.events(function(v) return v.obj == "track" and v.user == "Bee" end) end
  -- Bee's REAPER reads the lanes its own way, some seconds after opening: nobody edited
  T = T + 2
  S.as(B)
  logged = {}
  lanes(B, { "1", "2", "3" }, { 2, 0, 2 })
  S.settle(B)
  assert(bee_sent() == 0, "it doesn't go out (was: sent, and the band's lane names were replaced by 1, 2, 3 on every computer)")
  assert(told("lanes read differently here"), "and it's said once")
  S.recv(A)
  assert(lanes_of(A) == "1,Verse take 2,Verse take 3", "James keeps the band's lane names")
  -- a lane Bee renames herself has an edit behind it: that goes out
  T = T + 40
  B.F.clock = B.F.clock + 40
  S.edit(B, function(F) lanes(B, { "1", "2", "Chorus" }, { 2, 0, 2 }) end)
  assert(bee_sent() == 1, "Bee's own rename of a lane goes out")
  S.recv(A)
  assert(lanes_of(A) == "1,2,Chorus", "and lands on James's (" .. lanes_of(A) .. ")")
  print("rt-converge 16: lanes that read differently with nobody editing aren't sent; a lane renamed by hand is")
end

-- ---- 17. a merge isn't built while a version it rests on is still on its way (the soak's seed 43: one merge id, two contents) ------------------
do
  local hlc = math.floor(T * 1000)
  local function put(id, user, notes, base, n)
    local ev = { type = "obj", obj = "item", oid = "I-M17", id = id, user = user, state = midi(8, 4, notes), base_ev = base, rev = n, hlc = hlc + n, time = iso(T) }
    files[R .. "/events/" .. id .. ".json"] = ev
    return ev
  end
  local function events_of(st) local t = {}; for l in st:gmatch("[^\n]+") do if l:match("^E ") then t[#t + 1] = l end end; return table.concat(t, " / ") end
  local root = put("James-20270115-100000Z-00001-1701", "James", "E 0 90 43 60\nE 480 80 43 00\nE 0 b0 07 64", nil, 1)
  -- Bee draws a controller value, Cee changes it; James, apart from them, changes the first value and then undoes that
  local bee = put("Bee-20270115-100002Z-00001-1702", "Bee", "E 0 90 43 60\nE 480 80 43 00\nE 0 b0 07 64\nE 307 b0 07 70", root.id, 2)
  local cee = put("Cee-20270115-100006Z-00001-1703", "Cee", "E 0 90 43 60\nE 480 80 43 00\nE 0 b0 07 64\nE 307 b0 07 72", bee.id, 3)
  local j1 = put("James-20270115-100003Z-00002-1704", "James", "E 0 90 43 60\nE 480 80 43 00\nE 0 b0 07 6e", root.id, 2)
  local j2 = put("James-20270115-100004Z-00003-1705", "James", "E 0 90 43 60\nE 480 80 43 00\nE 0 b0 07 64", j1.id, 3)
  local mid = mirror.merge_id(cee.id, j2.id)
  -- James's first change hasn't reached this computer yet (his undo came over the link, ahead of Syncthing's copy of what it was built on)
  local j1_path = R .. "/events/" .. j1.id .. ".json"
  local held = files[j1_path]
  files[j1_path] = nil
  mirror.base_missing = nil
  local early = mirror.event_file(R, mid)
  assert(early == nil and mirror.base_missing == true, "no merge while a version one side rests on isn't here (was: put together from 'the older of their two bases', and kept)")
  files[j1_path] = held
  local m = mirror.event_file(R, mid)
  assert(m and events_of(m.state) == events_of(cee.state), "once it's here: the merge every computer builds, Cee's value over a base James's undo left as it was (" .. events_of(m and m.state or "") .. ")")
  print("rt-converge 17: a merge waits for the versions it rests on, and is the same on every computer")
end

-- ---- 18. an item moved onto a track a bandmate deleted that moment goes with the track on every computer (the soak's seed 103) ----------------
do
  local S = studio("Conv18", "everyone")
  local A, B, C = S.computer("James"), S.computer("Bee"), S.computer("Cee")
  S.edit(A, function(F) F.add_item(F.add_track("Keys"), midi(1, 2)); F.add_track("Tmp") end)
  S.recv(B); S.recv(C)
  -- Bee deletes Tmp; Cee, who hasn't that yet, moves the item onto it
  T = T + 2
  local seen = {}
  for p in pairs(files) do seen[p] = true end
  S.edit(B, function(F) reaper.DeleteTrack(S.track(B, "Tmp")) end)
  local gone
  for p, v in pairs(files) do if not seen[p] and type(v) == "table" and v.obj == "track" and v.gone then gone = v end end
  S.edit(C, function(F) reaper.MoveMediaItemToTrack(S.track(C, "Keys").items[1], S.track(C, "Tmp")) end)
  assert(S.items(C, "Tmp") == 1, "moved on Cee's")
  for _ = 1, 2 do S.recv(A); S.recv(B); S.recv(C) end
  assert(not S.track(A, "Tmp") and not S.track(B, "Tmp") and not S.track(C, "Tmp"), "Tmp is gone everywhere")
  assert(S.items(C, "Keys") == 0, "on Cee's the item went with the track it was moved to, as before")
  assert(S.items(A, "Keys") == 0 and S.items(B, "Keys") == 0,
    "and on the others too (was: it stayed on Keys there, where Cee's move never landed): " .. S.items(A, "Keys") .. " / " .. S.items(B, "Keys"))
  -- the track comes back (its deletion undone): the item with it, where Cee put it, on all three
  local first = S.events(function(v) return v.oid == gone.oid and not v.gone end)[1]
  local back = band.json_decode(band.json_encode(first))
  back.id, back.rev, back.base, back.base_ev, back.hlc, back.user = "Bee-20270115-110000Z-00099-0018", gone.rev + 1, gone.rev, gone.id, gone.hlc + 5, "Bee"
  files[S.dir .. "/events/" .. back.id .. ".json"] = back
  for _ = 1, 2 do S.recv(A); S.recv(B); S.recv(C) end
  assert(S.items(A, "Tmp") == 1 and S.items(B, "Tmp") == 1 and S.items(C, "Tmp") == 1, "back with its track on all three: " .. S.items(A, "Tmp") .. S.items(B, "Tmp") .. S.items(C, "Tmp"))
  print("rt-converge 18: an item moved onto a track deleted that moment goes with it everywhere, and comes back with it")
end

print("ok rt-converge")
