-- rt-sync2f (docs/rt/rt-sync2f.md): times in beats (rt-sync2 section 2, phase 5). An item's and automation's times travel, and are hashed, in
-- the units their timebase keeps (lib/beats.lua), so a tempo change sends nothing but the timeline change, and a version lands on the same beat
-- on every computer whichever comes first, it or the map. Lua 5.4, from the repo root. Each part fails without its piece (the doc's knock-out
-- table):
--  1. (pure) lib/beats.lua: an item's canonical form by its timebase (2: place in quarter notes; 1: place and length in quarter notes, snap
--     offset and fades as fractions of the length, an audio take's rate as source seconds, a MIDI take's rate as it is; 0: its seconds), and
--     back; automation's points, automation items and their points; gradual tempos counted as REAPER's TimeMap2 counts them (against the
--     stand-in's own TimeMap2); and what a receiver writes reads back as it travelled when its length differs from the sender's in the 7th
--     digit (a fade isn't put back to a round value that reads as another fraction there: the long soak's 5022).
--  2. A tempo change (a step, a gradual one, the first tempo) sends nothing but the timeline, and claims nothing; an item set to time stays
--     where it was; a hand edit made with it still goes and still claims.
--  3. An edit made under the old map crossing a bandmate's tempo change (an item resized, faded, its snap offset and audio rate changed;
--     automation): every computer ends with the same item, on the same beats, whichever came first; gradual too.
--  4. A version from before (format 1, seconds, naming its map `tm`) reads into beats by its map (mirror.legacy_beats) and lands on its beat on
--     another map; one with no map keeps its seconds.
--  5. Updating sends nothing: a computer whose records hold hash version 11 hashes of format-1 versions finds every item and automation the
--     band's at its first look (W.one's re-anchor in beats), with or without a map on the version.
--  6. Format 2, hash version 12, level 12: a StudioSync on format 1 holds these changes as too new; the level is at least the hash version.
--  7. History's preview (histhear.rebuild) puts a version in beats in seconds on the map then, and places it there.
--  8. (found by this round's long soak, 9033) mirror.moved_since takes a move back only from the versions between: a walk by a merge's
--     winner that never reaches the version meant says nothing. (9040, Undo of a move onto a track a bandmate deleted since, is the scenario
--     tools/soak/scenarios/undo-gone-with-track.json.)
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path

local T = 1800000000
local real_time, real_date = os.time, os.date
os.time = function(t) if t then return real_time(t) end return T end
os.date = function(fmt, t) return real_date(fmt, t or T) end
local E = require("editreaper")
local F0 = E.new("C:/A/Song.rpp")
reaper = F0.reaper
local band = require("band")
local files, logged, hidden = {}, {}, {} -- (hidden: path -> true, a file not here yet)
band.read_json = function(path) local v = not hidden[path] and files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
band.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
band.log = function(s) logged[#logged + 1] = s end
local function list(dir) local out = {}; for p in pairs(files) do local f = not hidden[p] and p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
package.loaded.trust = { claim_ok = function() return true end }
local beats = require("beats")
local mirror = require("mirror")
local sync = require("sync")
require("prints").choose = function() end
local claimask = require("claimask")
require("direct").send_live = function() return true end
claimask.reachable = function() return nil end
claimask.present = function() return false end
local function near(a, b, tol) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tol or 1e-9) end
local function num(state, key) return tonumber(state:match("\n%s*" .. key .. " ([^\n%s]+)")) end

-- ---- 1. pure: lib/beats.lua ------------------------------------------------------------------------------------------------------------------
do
  local q120 = function(t) return t * 2 end
  local t120 = function(q) return q / 2 end
  local ITEM = table.concat({ "<ITEM", "POSITION 8", "SNAPOFFS 0.5", "LENGTH 2", "LOOP 1", "FADEIN 1 0.25 0.1 1 0 0 0", "FADEOUT 2 0.5 0 1 0 0 0",
    'NAME "x"', "SOFFS 1.5", "PLAYRATE 1 1 0 -1 0 0.0025", "<SOURCE WAVE", 'FILE "a.flac"', ">",
    "TAKE", 'NAME "m"', "SOFFS 0", "PLAYRATE 1.25 1 0 -1 0 0.0025", "<SOURCE MIDI", "HASDATA 1 960 QN", "E 0 90 3c 60", ">", ">", "BANDLANE 1", "" }, "\n")
  local c1 = beats.item(ITEM, 1, q120)
  assert(beats.mark(c1) == 1 and c1:find("^<ITEM\nBANDBEAT 1\nPOSITION 16.000000\n"), "mode 1: marked, its place on quarter note 16: " .. c1)
  assert(num(c1, "LENGTH") == 4 and num(c1, "SNAPOFFS") == 1, "its length in quarter notes, its snap offset in quarter notes from its start")
  assert(c1:find("\nFADEIN 1 0.500000000 0.200000000 1 0 0 0\n", 1, true) and c1:find("\nFADEOUT 2 1.000000000 0.000000000 1 0 0 0\n", 1, true),
    "fades and auto lengths in quarter notes (rt-sync2g: they were fractions of the length)")
  local rates = {}
  for v in c1:gmatch("\nPLAYRATE (%S+)") do rates[#rates + 1] = v end
  assert(rates[1] == "2.000000000" and rates[2] == "1.25", "an audio take's rate as source seconds (1 x 2 s), a MIDI take's as it is")
  assert(c1:find("\nSOFFS 1.5\n", 1, true) and c1:find("\nBANDLANE 1\n$"), "the source position and what follows the item stay")
  assert(beats.item(c1, 1, q120) == c1, "read twice: the same")
  assert(beats.item_seconds(c1, t120, q120) == ITEM, "and back to the seconds it came from, exactly")
  -- on another map (60 bpm): the same beats, twice as long, fades and snap with it, the audio take's rate halved
  local s60 = beats.item_seconds(c1, function(q) return q end)
  assert(num(s60, "POSITION") == 16 and num(s60, "LENGTH") == 4 and num(s60, "SNAPOFFS") == 1 and s60:find("\nFADEIN 1 0.5 0.2 1 0 0 0\n", 1, true), "on 60 bpm: " .. s60)
  rates = {}
  for v in s60:gmatch("\nPLAYRATE (%S+)") do rates[#rates + 1] = tonumber(v) end
  assert(rates[1] == 0.5 and rates[2] == 1.25, "the audio take's rate halved, the MIDI take's kept")
  local c2 = beats.item(ITEM, 2, q120)
  assert(beats.mark(c2) == 2 and num(c2, "POSITION") == 16 and num(c2, "LENGTH") == 2 and c2:find("\nFADEIN 1 0.25 0.1 ", 1, true), "mode 2: only the place")
  assert(beats.item(ITEM, 0, q120) == ITEM and beats.item_seconds(ITEM, t120) == ITEM, "mode 0, and a text with no mark: its seconds")
  -- a receiver whose length differs from the sender's in its 7th digit (places and lengths travel as quarter notes to 1e-6): what it writes
  -- reads back as it travelled, its fade not put back to a round 0.01 that reads as another fraction there (the long soak's 5022 and 5024)
  local c = beats.item("<ITEM\nPOSITION 0\nLENGTH 2.2\nFADEIN 1 0.01 0 1 0 0 0\nPLAYRATE 1 1 0 -1 0 0.0025\n>\n", 1, q120)
  for _, k in ipairs({ 1 + 2e-7, 1 - 2e-7, 1 + 9e-8, 1 }) do
    local back = beats.item_seconds(c, function(q) return q / 2 * k end, function(t) return t * 2 / k end) -- (a map a hair off the sender's)
    assert(beats.item(back, 1, function(t) return t * 2 / k end) == c, "read back as it travelled (" .. k .. "): " .. back)
  end
  assert(beats.item_seconds(c, t120, q120):find("\nFADEIN 1 0.01 0 1 0 0 0\n", 1, true), "and on the sender's own map, the round fade it had")
  -- automation: points, automation items (place, and in 1 length) and their points; text with no times carries no mark
  local ENV = table.concat({ "<VOLENV2", "ACT 1 -1", "PT 0 1 0", "PT 4 0.5 0", "PT 6.5 1 0 0 1", "POOLEDENVINST 1 2 2 0 1 0 0 0 0 0 0 1", ">",
    "BANDAI VOLENV2 2 2 0.25 1.5 0 1 0 0 4", "BANDAIPT VOLENV2 0 2.5 0.3 0 0", "BANDFXEN 1", "" }, "\n")
  local e1 = beats.env(ENV, 1, q120)
  assert(e1:find("^BANDBEAT 1\n<VOLENV2\nACT 1 %-1\nPT 0%.000000 1 0\nPT 8%.000000 0%.5 0\nPT 13%.000000 1 0 0 1\n"), "points in quarter notes, the rest of each line kept: " .. e1)
  assert(e1:find("\nPOOLEDENVINST 1 4.000000 4.000000 0 1 ", 1, true) and e1:find("\nBANDAI VOLENV2 4.000000 4.000000 0.25 1.5 ", 1, true)
    and e1:find("\nBANDAIPT VOLENV2 0 5.000000 0.3 0 0\n", 1, true), "automation items' place and length, and their points, in quarter notes")
  assert(beats.env_seconds(e1, t120) == ENV, "and back")
  assert(beats.env(ENV, 2, q120):find("\nBANDAI VOLENV2 4.000000 2 ", 1, true), "mode 2: an automation item's length in seconds")
  assert(beats.env("<VOLENV2\nACT 1 -1\n>\n", 1, q120) == "<VOLENV2\nACT 1 -1\n>\n" and beats.env(ENV, 0, q120) == ENV, "no times, or time: as it is")
  -- gradual tempos, as REAPER's TimeMap2 counts them: 120 to 80 over 16 s, then 80
  local ramp = { { time = 0, bpm = 120, linear = true }, { time = 16, bpm = 80 } }
  assert(near(beats.map_qn(ramp, 10), 10 * (120 - 2.5 * 10 / 2) / 60) and near(beats.map_qn(ramp, 20), 16 * 100 / 60 + 4 * 80 / 60), "quarter notes through and past a ramp")
  for _, q in ipairs({ 0, 3.3, 17.9, 26.6, 40 }) do assert(near(beats.map_qn(ramp, beats.map_time(ramp, q)), q, 1e-9), "time and quarter notes, each the other's inverse") end
  local F = E.new("C:/A/Ramp.rpp")
  reaper = F.reaper
  reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 120, 4, 4, true)
  reaper.SetTempoTimeSigMarker(F.proj, -1, 16, -1, -1, 80, 4, 4, false)
  local map = band.capture_tempo(F.proj)
  for _, t in ipairs({ 0.5, 7, 15.9, 16, 22.25 }) do
    assert(near(beats.map_qn(map, t), reaper.TimeMap2_timeToQN(F.proj, t), 1e-9), "the list maths agree with the stand-in's TimeMap2 at " .. t)
  end
  -- (the stand-in's own move of the markers after an edit: they keep their beats, a gradual change into one included, as REAPER keeps them.
  -- The long soak's 13005: the map came out of order)
  reaper.SetTempoTimeSigMarker(F.proj, -1, 24, -1, -1, 140, 4, 4, true)
  reaper.SetTempoTimeSigMarker(F.proj, -1, 30, -1, -1, 100, 4, 4, false)
  local q30 = reaper.TimeMap2_timeToQN(F.proj, 30)
  reaper.SetTempoTimeSigMarker(F.proj, 2, 24, -1, -1, 160, 4, 4, true) -- (the gradual change after 24 s now from 160)
  local _, t30 = reaper.GetTempoTimeSigMarker(F.proj, 3)
  assert(t30 > 24 and near(reaper.TimeMap2_timeToQN(F.proj, t30), q30, 1e-9) and near(beats.map_qn(band.capture_tempo(F.proj), t30), q30, 1e-9),
    "the marker after it keeps its beat (" .. t30 .. " s)")
  reaper = F0.reaper
  print("rt-sync2f 1: beats.lua's forms, and gradual tempos")
end

-- ---- computers (as tests/test_0_61_rt_floor.lua) -----------------------------------------------------------------------------------------------
local function studio(song)
  local S = { song = song, dir = "R/" .. song .. "/rooms/main", sess = { host = "James", markers = {} } }
  S.media = S.dir .. "/media"
  files[S.dir .. "/mode.json"] = { mode = "everyone", by = "James" }
  local function as(c) reaper = c.F.reaper end
  S.as = as
  S.hidden = hidden
  function S.computer(user)
    local c = { F = E.new("C:/" .. user .. "/" .. song .. ".rpp"), cfg = { user = user, root = "R" }, user = user, claimed = {} }
    require("undo").confirm = function() return true end
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or (files[p] ~= nil and not S.hidden[p]) end
    c.F.reaper.SetExtState(band.SECTION, "user", user, false)
    c.edited = -1
    return c
  end
  function S.look(c)
    as(c)
    c.F.clock = c.F.clock + 1
    local may, w = sync.authority(c.cfg, song, "main", S.sess)
    sync.driver_name, sync.room_mode = w.driver, w.mode
    sync.watch_timeline(c.F.proj, c.cfg, song, "main", may)
    mirror.watch(c.F.proj, c.cfg, song, "main", { can = may, owner_can = may, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of, quick = true,
      edited_at = c.edited, sent = function(_, name) c.claimed[name] = (c.claimed[name] or 0) + 1 end })
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
  function S.track(c, name) for _, t in ipairs(c.F.tracks) do if t.name == name then return t end end end
  function S.item(c, name) for _, t in ipairs(c.F.tracks) do for _, it in ipairs(t.items) do if it.text:find('NAME "' .. name .. '"', 1, true) then return it end end end end
  function S.events(pred) local out = {}; for p, v in pairs(files) do if p:find(S.dir .. "/events/", 1, true) and type(v) == "table" and pred(v) then out[#out + 1] = v end end; return out end
  -- every object's hash here (what travels, in beats)
  function S.state(c) as(c); local t = {}; for _, o in ipairs(mirror.scan(c.F.proj, c.user, S.media, false)) do t[o.oid] = o.hash end; return t end
  function S.same(x, y, what)
    local a, b = S.state(x), S.state(y)
    for k, v in pairs(a) do assert(b[k] == v, what .. ": " .. k .. " differs (" .. x.user .. " / " .. y.user .. ")") end
    for k in pairs(b) do assert(a[k], what .. ": " .. k .. " only on " .. y.user) end
    assert(band.json_encode(band.capture_tempo(x.F.proj)) == band.json_encode(band.capture_tempo(y.F.proj)), what .. ": the same tempo map")
  end
  return S
end
local ENV = "<VOLENV2\nEGUID {E1}\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 4 0.5 0\nPT 8 1 0\nPT 12 0.7 0\n>\n"
local function audio(S, pos, len, name, extra)
  return table.concat({ "<ITEM", "POSITION " .. pos, "SNAPOFFS 0", "LENGTH " .. len, "LOOP 1", "ALLTAKES 0", "FADEIN 1 0.01 0 1 0 0 0", "FADEOUT 1 0.01 0 1 0 0 0",
    "MUTE 0 0", "SEL 0", "IID 1", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0", extra or "",
    "GUID " .. E.guid(), "<SOURCE WAVE", 'FILE "' .. S.media .. "/" .. name .. '.flac"', ">", ">" }, "\n"):gsub("\n\n", "\n") .. "\n"
end
-- James's song: Drums (automation, two items), Gtr (an item), Bass (an item set to time); Bee and Cee have it
local function song(name)
  local S = studio(name)
  local A, B, C = S.computer("James"), S.computer("Bee"), S.computer("Cee")
  S.edit(A, function(F)
    local d = F.add_track("Drums", nil, ENV)
    F.add_item(d, audio(S, 0, 3.5, "Drums 0")); F.add_item(d, audio(S, 8, 3.5, "Drums 2"))
    F.add_item(F.add_track("Gtr"), audio(S, 10, 6, "Gtr"))
    F.add_item(F.add_track("Bass"), audio(S, 12, 3, "Bass", "BEAT 0"))
  end)
  S.recv(B); S.recv(C)
  S.same(A, B, name .. ": the song"); S.same(A, C, name .. ": the song")
  T = T + sync.AUTO_IDLE + 120 -- (making the song is nobody's work in progress any more)
  return S, A, B, C
end
local function obj_events(S, user, since) return S.events(function(v) return v.type == "obj" and v.user == user and v.time >= since end) end
local function pos(it) return tonumber(E.top_value(it.text, "POSITION")) end

-- ---- 2. a tempo change sends nothing but the timeline, and claims nothing ------------------------------------------------------------------
do
  local S, A, B, C = song("Beats2")
  for _, step in ipairs({
    -- (inside Gtr (10 s to 16 s), its fade out after it: REAPER keeps each fade's beats where it sits, not its share of the length. Live check
    -- sync2f f4 on 0.63.0: the fade out went 0.01 -> 0.0133 with the length 6 -> 7.33, and the item went out. rt-sync2g)
    { "a 90 bpm marker at 12 s, inside Gtr", function(F) reaper.SetTempoTimeSigMarker(F.proj, -1, 12, -1, -1, 90, 4, 4, false) end },
    { "a 100 bpm marker at 6 s", function(F) reaper.SetTempoTimeSigMarker(F.proj, -1, 6, -1, -1, 100, 4, 4, false) end },
    { "the first tempo to 132", function(F) reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 132, 4, 4, false) end },
    { "a gradual tempo, 132 to 90 over 6 s", function(F) reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 132, 4, 4, true) end } }) do
    T = T + 5
    local since = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local bass, gtr = pos(S.item(A, "Bass")), pos(S.item(A, "Gtr")) + num(S.item(A, "Gtr").text, "LENGTH")
    A.claimed = {}
    S.edit(A, step[2])
    assert(math.abs(pos(S.item(A, "Gtr")) + num(S.item(A, "Gtr").text, "LENGTH") - gtr) > 1e-3 and pos(S.item(A, "Bass")) == bass,
      step[1] .. ": REAPER moved Gtr's end (in beats), not Bass (set to time)")
    local sent = obj_events(S, "James", since)
    assert(#sent == 0, step[1] .. ": nothing but the timeline goes out (" .. #sent .. ": " .. tostring(sent[1] and sent[1].oid) .. ")")
    assert(#S.events(function(v) return v.type == "timeline" and v.user == "James" and v.time >= since end) == 1, step[1] .. ": the timeline goes out")
    assert(next(A.claimed) == nil, step[1] .. ": nothing claimed")
    S.recv(B); S.recv(C)
    S.same(A, B, step[1]); S.same(A, C, step[1])
    assert(#obj_events(S, "Bee", since) + #obj_events(S, "Cee", since) == 0, step[1] .. ": nor from the computers it landed on")
  end
  -- a hand edit made with a tempo change still goes, and still claims
  T = T + 5
  local since = os.date("!%Y-%m-%dT%H:%M:%SZ")
  S.edit(A, function(F) reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 90, 4, 4, false); F.set_text(S.item(A, "Gtr"), E.set_top(S.item(A, "Gtr").text, "MUTE", "1 0")) end)
  local sent = obj_events(S, "James", since)
  assert(#sent == 1 and sent[1].name == "Gtr" and A.claimed.Gtr == 1, "a mute made with the tempo change goes out and claims Gtr (" .. #sent .. ")")
  print("rt-sync2f 2: a tempo change sends nothing but the timeline and claims nothing; a hand edit with it still goes")
end

-- ---- 3. an edit crossing a bandmate's tempo change lands on the same beats everywhere, in either order -----------------------------------------
local function crossing(name, tempo)
  local S, A, B, C = song(name)
  -- James changes the tempo; before it reaches Bee, Bee edits Gtr (longer, faded, its snap offset and rate) and adds a Drums point
  T = T + 5
  S.edit(A, tempo)
  local map = S.events(function(v) return v.type == "timeline" and v.user == "James" end)
  table.sort(map, function(a, b) return a.id < b.id end)
  map = map[#map]
  local mpath = S.dir .. "/events/" .. map.id .. ".json"
  S.hidden[mpath] = true
  T = T + 1
  S.edit(B, function(F)
    local g = S.item(B, "Gtr")
    local t = E.set_top(E.set_top(E.set_top(g.text, "LENGTH", "7.5"), "FADEIN", "1 0.75 0 1 0 0 0"), "SNAPOFFS", "1.25")
    F.set_text(g, (t:gsub("\nPLAYRATE 1 ", "\nPLAYRATE 0.8 ", 1)))
    local d = S.track(B, "Drums")
    d.body = d.body:gsub("\nPT 12 0%.7 0", "\nPT 10 0.25 0\nPT 12 0.7 0", 1)
    F.changed()
  end)
  -- Cee gets Bee's edit before James's map; James gets it after his own map; Bee gets the map after her edit
  S.recv(C)
  assert(band.capture_tempo(C.F.proj)[1].bpm == 120 and #band.capture_tempo(C.F.proj) == 1, name .. ": Cee has the edit and not yet the map")
  S.hidden[mpath] = nil
  S.recv(A); S.recv(B); S.recv(C)
  S.same(A, B, name); S.same(A, C, name)
  for _, c in ipairs({ A, B, C }) do
    local g = S.item(c, "Gtr")
    S.as(c)
    local q0, q1 = reaper.TimeMap2_timeToQN(c.F.proj, pos(g)), reaper.TimeMap2_timeToQN(c.F.proj, pos(g) + num(g.text, "LENGTH"))
    assert(near(q0, 20, 1e-5) and near(q1 - q0, 15, 1e-5), name .. ", " .. c.user .. ": Gtr on quarter notes 20 to 35, as Bee made it (" .. q0 .. ", " .. q1 .. ")")
    local l = num(g.text, "LENGTH")
    local fade = tonumber(g.text:match("\nFADEIN %S+ (%S+)"))
    -- (the fade and snap offset keep their beats from the item's start, 1.5 and 2.5 quarter notes as Bee made them on 120 bpm: on a gradual
    -- map that's not their share of the length. rt-sync2g)
    local fq = reaper.TimeMap2_timeToQN(c.F.proj, pos(g) + fade) - q0
    local sq = reaper.TimeMap2_timeToQN(c.F.proj, pos(g) + num(g.text, "SNAPOFFS")) - q0
    assert(near(fq, 1.5, 1e-7) and near(sq, 2.5, 1e-7) and near(num(g.text, "PLAYRATE") * l, 0.8 * 7.5, 1e-6),
      name .. ", " .. c.user .. ": its fade, snap offset in beats and rate with its length (" .. fq .. ", " .. sq .. ", " .. num(g.text, "PLAYRATE") .. ")")
    local pt
    for t, v in S.track(c, "Drums").body:gmatch("\nPT (%S+) (%S+)") do if tonumber(v) == 0.25 then pt = tonumber(t) end end
    assert(pt and near(reaper.TimeMap2_timeToQN(c.F.proj, pt), 20, 1e-5), name .. ", " .. c.user .. ": Bee's point on quarter note 20")
  end
  S.as(A)
  return S
end
crossing("Beats3", function(F) reaper.SetTempoTimeSigMarker(F.proj, -1, 4, -1, -1, 100, 4, 4, false) end)
crossing("Beats3r", function(F) reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 120, 4, 4, true); reaper.SetTempoTimeSigMarker(F.proj, -1, 16, -1, -1, 80, 4, 4, false) end)
print("rt-sync2f 3: an edit crossing a tempo change, a step or gradual, lands on the same beats everywhere, its fades, snap offset and rate with it")

-- ---- 4. a version from before: read into beats by the map it names -------------------------------------------------------------------------
do
  local R = "R/Legacy4/rooms/main"
  local M120 = { { time = 0, bpm = 120, num = 4, denom = 4, linear = false } }
  local function put(id, state, extra)
    local ev = { type = "obj", obj = "item", oid = "I-L4", track = "T-L4", name = "Keys", id = id, user = "Old", rev = 1, hlc = 1, time = "2026-11-25T10:00:00Z",
      format = 1, hv = 11, state = state }
    for k, v in pairs(extra or {}) do ev[k] = v end
    files[R .. "/events/" .. id .. ".json"] = ev
    return id
  end
  local old = "<ITEM\nPOSITION 8\nLENGTH 2\nFADEIN 1 0.5 0 1 0 0 0\nNAME \"k\"\n>\n"
  local v = mirror.event_file(R, put("Old-20261125-100000Z-00001-0001", old, { tm = M120, tb = 1 }))
  assert(beats.mark(v.state) == 1 and num(v.state, "POSITION") == 16 and num(v.state, "LENGTH") == 4, "read into beats by its map (" .. v.state .. ")")
  local F = E.new("C:/A/Legacy4.rpp")
  reaper = F.reaper
  local tr = F.add_track("Keys")
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "T-L4", true)
  reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 60, 4, 4, false)
  assert(mirror.apply(F.proj, v, R .. "/media", false), "applied")
  local it = F.all_items()[1]
  assert(pos(it) == 16 and num(it.text, "LENGTH") == 4 and it.text:find("\nFADEIN 1 1 0 1 0 0 0\n", 1, true), "on its beat at 60 bpm, its fade with its length: " .. it.text)
  local w = mirror.event_file(R, put("Old-20261125-100000Z-00002-0002", old))
  assert(w.state == old, "no map named: its seconds stand")
  local e = mirror.event_file(R, put("Old-20261125-100000Z-00003-0003", "<VOLENV2\nPT 0 1 0\nPT 4 0.5 0\n>\n", { obj = "env", tm = M120, tb = 1 }))
  assert(e.state == "BANDBEAT 1\n<VOLENV2\nPT 0.000000 1 0\nPT 8.000000 0.5 0\n>\n", "automation likewise: " .. e.state)
  reaper = F0.reaper
  print("rt-sync2f 4: a version from before reads into beats by the map it names")
end

-- ---- 5. updating sends nothing ---------------------------------------------------------------------------------------------------------------
do
  local S, A = song("Beats5")
  T = T + 5
  -- James's records as a StudioSync before rt-sync2f left them: format-1 versions in seconds (most naming their map), hash version 11 hashes
  local beat_ids = {}
  S.as(A)
  local map = band.capture_tempo(A.F.proj)
  local n = 0
  for _, o in ipairs(mirror.scan(A.F.proj, "James", S.media, false)) do
    if (o.kind == "item" or o.kind == "env") and beats.mark(o.state) then
      n = n + 1
      local rev, _, evid = mirror.known(A.F.proj, o.oid)
      local ev = files[S.dir .. "/events/" .. evid .. ".json"]
      local secs = beats.write(A.F.proj, o.kind, ev.state)
      local old = { type = "obj", obj = o.kind, oid = o.oid, track = o.track, name = ev.name, user = "James", rev = rev, hlc = 1, time = "2026-11-25T10:00:00Z",
        id = "James-20261125-100000Z-0000" .. n .. "-0001", format = 1, hv = 11, state = secs, hash = mirror.hash(secs),
        tm = (n % 2 == 1) and map or nil, tb = (n % 2 == 1) and 1 or nil } -- (every other one from before versions named their map)
      files[S.dir .. "/events/" .. old.id .. ".json"] = old
      mirror.remember(A.F.proj, o.oid, rev, old.hash, old.id, mirror.order_of(old))
      beat_ids[#beat_ids + 1] = o.oid
    end
  end
  assert(n >= 4, "items and automation in beats here (" .. n .. ")")
  mirror.anchor_seen = {}
  local since = os.date("!%Y-%m-%dT%H:%M:%SZ")
  S.settle(A)
  local sent = obj_events(S, "James", since)
  assert(#sent == 0, "the first look after updating sends nothing (" .. #sent .. ": " .. tostring(sent[1] and sent[1].oid) .. ")")
  for _, oid in ipairs(beat_ids) do
    local _, h = mirror.known(A.F.proj, oid)
    local here
    for _, o in ipairs(mirror.scan(A.F.proj, "James", S.media, false)) do if o.oid == oid then here = o.hash end end
    assert(h == here, "and records each as the band's, hashed in beats (" .. oid .. ")")
  end
  print("rt-sync2f 5: updating sends nothing: hash version 11 records of format-1 versions are the band's, read in beats")
end

-- ---- 6. format 2, hash version 13 (rt-sync2g's fades), level 13 ------------------------------------------------------------------------------
do
  assert(band.FORMAT == 2 and mirror.HV == 13 and sync.LEVEL == 13 and sync.LEVEL >= mirror.HV, "format 2, hash version 13, level 13")
  local was = band.FORMAT
  band.FORMAT = 1 -- (a StudioSync from before: format 1)
  local too_new = sync.too_new({ type = "obj", obj = "item", format = 2, lv = 12 })
  band.FORMAT = was
  assert(too_new, "a StudioSync on format 1 holds a format-2 change as too new: it can't read beats")
  assert(not sync.too_new({ type = "obj", obj = "item", format = 1, time = "2026-11-25T10:00:00Z" }), "history in format 1 is read here")
  print("rt-sync2f 6: format 2, hash version 13, level 13")
end

-- ---- 7. History's preview puts a version in beats on the map then ---------------------------------------------------------------------------
do
  local hh = require("histhear")
  local now = '<REAPER_PROJECT 0.1 "7.86/win64" 1\n<TRACK {T1}\nNAME "Keys"\n<EXT\nband_oid T-H7\n>\n>\n>\n'
  local st = beats.item("<ITEM\nPOSITION 8\nLENGTH 2\nFADEIN 1 0.5 0 1 0 0 0\nNAME \"k\"\n>\n", 1, function(t) return t * 2 end)
  local then_map = { { time = 0, bpm = 60, num = 4, denom = 4, linear = false } }
  local out, info = hh.rebuild(now, { ["I-H7"] = { obj = "item", oid = "I-H7", track = "T-H7", id = "v1", state = st } }, { media = "R/H/media", then_map = then_map })
  assert(out:find("\nPOSITION 16\n", 1, true) and out:find("\nLENGTH 4\n", 1, true) and out:find("\nFADEIN 1 1 0 1 0 0 0\n", 1, true) and not out:find("BANDBEAT", 1, true),
    "in seconds on the map then: " .. out)
  assert(info.placed["I-H7"] and info.placed["I-H7"].tempo == then_map, "and placed under it")
  print("rt-sync2f 7: History's preview puts a version in beats in seconds on the map then")
end

-- ---- 8. (the long soak's 9033, found in this round's runs) a move is taken back only from the versions between ----------------------------------
do
  local R = "R/Moved8/rooms/main"
  local function put(ev)
    ev.type, ev.obj, ev.oid, ev.user, ev.state = "obj", "track", "T-M8", ev.user or "Cee", { name = "T", after = "" }
    files[R .. "/events/" .. ev.id .. ".json"] = ev
    return ev
  end
  put({ id = "Cee-20261125-100000Z-00001-0001", unfolder = "T-OLD", rev = 1, hlc = 1 }) -- (a move out of a folder long ago)
  put({ id = "Cee-20261125-100100Z-00002-0002", base_ev = "Cee-20261125-100000Z-00001-0001", rev = 2, hlc = 2 })
  put({ id = "James-20261125-100100Z-00001-0001", base_ev = "Cee-20261125-100000Z-00001-0001", rev = 2, hlc = 3, user = "James" }) -- (the version meant)
  put({ id = "James-20261125-100200Z-00002-0002", base_ev = "James-20261125-100100Z-00001-0001", rev = 3, hlc = 4, user = "James" })
  local m = mirror.merge_id("Cee-20261125-100100Z-00002-0002", "James-20261125-100200Z-00002-0002")
  local last = put({ id = "James-20261125-100300Z-00003-0003", base_ev = m, rev = 4, hlc = 5, user = "James", moved = nil })
  local x = mirror.event_file(R, last.id)
  assert(mirror.event_file(R, m) and mirror.event_file(R, m).id == m, "(the merge builds)")
  assert(mirror.moved_since(R, x, "James-20261125-100100Z-00001-0001", "unfolder") == nil,
    "a walk by the merge's winner that never reaches the version meant takes back nothing (was: the folder left long before it)")
  assert(mirror.moved_since(R, mirror.event_file(R, "Cee-20261125-100100Z-00002-0002"), "Cee-20261125-100000Z-00001-0001", "unfolder") == nil, "nothing moved between")
  put({ id = "Cee-20261125-100400Z-00003-0003", base_ev = "Cee-20261125-100100Z-00002-0002", rev = 3, hlc = 6, unfolder = "T-F" })
  assert(mirror.moved_since(R, mirror.event_file(R, "Cee-20261125-100400Z-00003-0003"), "Cee-20261125-100100Z-00002-0002", "unfolder") == "T-F", "a move between is taken back, as before")
  print("rt-sync2f 8: a move is taken back only from the versions between (the long soak's 9033)")
end

-- ---- 9. (rt-sync2g) updating from hash version 12 sends nothing: its snap offset and fades as shares of the length read into beats -----------
do
  local S, A = song("Beats9")
  T = T + 5
  S.as(A)
  -- (snap offsets and longer fades on every item first, as the band's: then James's records as hash version 12 left them)
  S.edit(A, function(F)
    for _, t in ipairs(F.tracks) do
      for _, it in ipairs(t.items) do F.set_text(it, E.set_top(E.set_top(it.text, "SNAPOFFS", "0.5"), "FADEOUT", "1 0.25 0.05 1 0 0 0")) end
    end
  end)
  local function v12(state) -- (today's form, uniform 120 bpm here, back in hash version 12's: spans in quarter notes as shares of the length)
    local lq = num(state, "LENGTH")
    return (state:gsub("\n(SNAPOFFS) (%S+)", function(k, v) return "\n" .. k .. " " .. beats.f9(tonumber(v) / lq) end)
      :gsub("\n(FADE%u+) (%S+) (%S+) (%S+)", function(k, sh, a, b) return "\n" .. k .. " " .. sh .. " " .. beats.f9(tonumber(a) / lq) .. " " .. beats.f9(tonumber(b) / lq) end))
  end
  local ids, n = {}, 0
  for _, o in ipairs(mirror.scan(A.F.proj, "James", S.media, false)) do
    if o.kind == "item" and beats.mark(o.state) == 1 then
      n = n + 1
      local rev, _, evid = mirror.known(A.F.proj, o.oid)
      local ev = files[S.dir .. "/events/" .. evid .. ".json"]
      local old = v12(ev.state)
      assert(old ~= ev.state, "(hash version 12's form differs: " .. o.oid .. ")")
      local id = "James-20261126-100000Z-0000" .. n .. "-0001"
      files[S.dir .. "/events/" .. id .. ".json"] = { type = "obj", obj = "item", oid = o.oid, track = o.track, name = ev.name, user = "James", rev = rev, hlc = 1,
        time = "2026-11-26T10:00:00Z", id = id, format = 2, hv = 12, lv = 12, state = old, hash = mirror.hash(old) }
      mirror.remember(A.F.proj, o.oid, rev, mirror.hash(old), id, mirror.order_of(files[S.dir .. "/events/" .. id .. ".json"]))
      ids[#ids + 1] = o.oid
    end
  end
  assert(n >= 3, "items in beats (position, length, rate) here (" .. n .. ")")
  mirror.anchor_seen = {}
  T = T + 5
  local since = os.date("!%Y-%m-%dT%H:%M:%SZ")
  S.settle(A)
  local sent = obj_events(S, "James", since)
  assert(#sent == 0, "the first look after updating from hash version 12 sends nothing (" .. #sent .. ": " .. tostring(sent[1] and sent[1].oid) .. ")")
  for _, oid in ipairs(ids) do
    local _, h = mirror.known(A.F.proj, oid)
    local here
    for _, o in ipairs(mirror.scan(A.F.proj, "James", S.media, false)) do if o.oid == oid then here = o.hash end end
    assert(h == here, "and records each as the band's, in today's form (" .. oid .. ")")
  end
  print("rt-sync2g 9: updating from hash version 12 sends nothing: its shares of the length read as quarter notes")
end

-- ---- 10. (rt-sync2g) stretch markers: REAPER's own on an auto-stretch item left out and made again; a take's own in beats, its rate kept ------
do
  -- (chunks as REAPER 7.86 wrote them, Windows and Linux alike: an auto-stretch item at 10 s, 6 s long, at 120 bpm, then with a 90 bpm marker
  -- at 12 s inside it (live check sync2f f4's numbers): REAPER scaled the rate with the length and added its own markers, flagged "0 1")
  local function qn120(t) return t * 2 end
  local function qn90at(at) return function(t) if t <= at then return t * 2 end return at * 2 + (t - at) * 1.5 end end
  local function tm90at(at) return function(q) if q <= at * 2 then return q / 2 end return at + (q - at * 2) / 1.5 end end
  local tail = "<SOURCE WAVE\nFILE \"a.wav\"\n>\n>\n"
  local auto0 = "<ITEM\nPOSITION 10\nSNAPOFFS 0\nLENGTH 6\nFADEIN 1 0.01 0 1 0 0 0\nFADEOUT 1 0.01 0 1 0 0 0\nBEAT 1\nIMPLIEDWARP 1\nPLAYRATE 1 1 0 -1 0 0.0025\n" .. tail
  local auto1 = "<ITEM\nPOSITION 10\nSNAPOFFS 0\nLENGTH 7.33333333333333\nFADEIN 1 0.01 0 1 0 0 0\nFADEOUT 1 0.01333333333333 0 1 0 0 0\nBEAT 1\nIMPLIEDWARP 1\n"
    .. "PLAYRATE 0.81818181818182 1 0 -1 0 0.0025\nSM 0 0 0 1 + 1.636363636 2 0 1 + 6 6 0 1\n" .. tail
  local c0, c1 = beats.item(auto0, 1, qn120), beats.item(auto1, 1, qn90at(12))
  assert(c0 == c1, "an auto-stretch item reads the same before and after a tempo change inside it (REAPER's own markers left out):\n" .. c0 .. "\n" .. c1)
  local h12 = beats.upgrade12("<ITEM\nBANDBEAT 1\nPOSITION 20.000000\nLENGTH 12.000000\nIMPLIEDWARP 1\nPLAYRATE 6.000000000 1 0 -1 0 0.0025\nSM 0 0 0 1 + 1.636363636 2 0 1\n" .. tail)
  assert(not h12:find("\nSM ", 1, true), "hash version 12's copy of REAPER's own markers on an auto-stretch item is left out as it's read: " .. h12)
  -- (a take with stretch markers of its own, at 10 s, 6 s long, a 90 bpm marker added at 10.5 s: REAPER kept the rate and each marker's beats.
  -- The first change also adds a marker at each end, so such an item goes out once: these are after it)
  local own0 = "<ITEM\nPOSITION 10\nSNAPOFFS 3\nLENGTH 6\nPLAYRATE 1 1 0 -1 0 0.0025\nSM 0 0 + 1 1 + 3 2.5 + 6 5.5\n" .. tail
  local own1 = "<ITEM\nPOSITION 10\nSNAPOFFS 3.83333333333333\nLENGTH 7.83333333333333\nPLAYRATE 1 1 0 -1 0 0.0025\n"
    .. "SM 0 0 + 1.166666667 1 + 3.833333333 2.5 + 7.833333333 5.5\n" .. tail
  local o0, o1 = beats.item(own0, 1, qn120), beats.item(own1, 1, qn90at(10.5))
  assert(o0 == o1, "a take's own stretch markers in beats and its rate as it is: the same after the tempo change:\n" .. o0 .. "\n" .. o1)
  assert(o0:find("\nPLAYRATE 1 1 ", 1, true) and o0:find("\nSM 0.000000 0 + 2.000000 1 + 6.000000 2.5 + 12.000000 5.5\n", 1, true), "(its rate kept, markers in quarter notes): " .. o0)
  assert(beats.item(beats.item_seconds(o1, tm90at(10.5), qn90at(10.5)), 1, qn90at(10.5)) == o1, "and back in seconds, read as it travelled")
  -- a landing of an auto-stretch item here: its chunk set, then C_AUTOSTRETCH off and on (REAPER makes its markers from the map)
  local F = E.new("C:/A/Warp10.rpp")
  reaper = F.reaper
  local tr = F.add_track("Gtr")
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "T-W10", true)
  local set = {}
  local real = reaper.SetMediaItemInfo_Value
  reaper.SetMediaItemInfo_Value = function(it, k, v) if k == "C_AUTOSTRETCH" then set[#set + 1] = v end; return real(it, k, v) end
  assert(mirror.apply(F.proj, { type = "obj", obj = "item", oid = "I-W10", track = "T-W10", name = "Gtr", id = "Bee-20261128-100000Z-00001-0001", user = "Bee",
    rev = 1, hlc = 1, time = "2026-11-28T10:00:00Z", format = 2, hv = mirror.HV, state = c1 }, "R/W10/media", false), "applied")
  assert(set[1] == 0 and set[2] == 1, "its auto-stretch set off and on after the chunk (" .. #set .. ")")
  set = {}
  assert(mirror.apply(F.proj, { type = "obj", obj = "item", oid = "I-W11", track = "T-W10", name = "Gtr", id = "Bee-20261128-100000Z-00002-0002", user = "Bee",
    rev = 1, hlc = 2, time = "2026-11-28T10:00:00Z", format = 2, hv = mirror.HV, state = o1 }, "R/W10/media", false), "applied")
  assert(#set == 0, "an item with stretch markers of its own: left as it landed")
  reaper.SetMediaItemInfo_Value = real
  reaper = F0.reaper
  print("rt-sync2g 10: stretch markers: REAPER's own on auto-stretch left out and made again; a take's own in beats, its rate kept")
end

-- ---- 11. (rt-fixlive2) automation a script wrote into an envelope REAPER hadn't taken in, then a tempo change: only the timeline goes out ----
-- (the live tool's env_add inserted points into what GetTrackEnvelopeByChunkName handed back for Drums' volume envelope, never shown: REAPER
-- 7.86 leaves it out of CountTrackEnvelopes and keeps its points in seconds at a tempo change, while the copies made from its chunk move.
-- The desktop then sent its automation after every tempo change, live checks sync2f f1 and f6. Fails without mirror.lua's realise_envs:
-- "nothing but the timeline goes out (1: E-...)")
do
  local S, A, B, C = song("Beats11")
  T = T + 5
  S.edit(A, function(F)
    local g = S.track(A, "Gtr")
    g.body = g.body .. "<VOLENV2\nEGUID {E11}\nACT 0 -1\nVIS 0 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nVOLTYPE 1\nPT 0 0.5 0\nPT 4 0.7 0\nPT 8 0.9 0\nPT 12 0.6 0\n>\n"
    g.phantom = { VOLENV2 = true }
    F.changed()
  end)
  S.recv(B); S.recv(C)
  S.same(A, B, "the script's automation")
  T = T + 5
  local since = os.date("!%Y-%m-%dT%H:%M:%SZ")
  S.edit(A, function(F) reaper.SetTempoTimeSigMarker(F.proj, -1, 2, -1, -1, 110, 4, 4, false) end)
  local sent = obj_events(S, "James", since)
  assert(#sent == 0, "nothing but the timeline goes out (" .. #sent .. ": " .. tostring(sent[1] and sent[1].oid) .. ")")
  S.recv(B); S.recv(C)
  S.same(A, B, "after the tempo change"); S.same(A, C, "after the tempo change")
  print("rt-fixlive2 11: a script's automation in an envelope REAPER hadn't taken in follows a tempo change; only the timeline goes out")
end


print("ok rt-sync2f")
