-- rt-converge (docs/rt/rt-converge.md): the sync core converging under concurrent edits, the soak's bugs (docs/rt/rt-soak.md). Lua 5.4, from
-- the repo root. Each part fails with its fix taken out (checked against a copy of lib/ without it).
--  1. A version names the tempo map its seconds are on (`tm`): put in place on another map it lands on its beat (mirror.apply), versions made
--     under different maps merge on one map (mirror.event_file), and a hand edit after a bandmate's map isn't taken for the map's move
--     (mirror.map_moved): the soak's bugs 1, 5 and 7.
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

print("ok rt-converge")
