-- History's "hear it as it was" made faithful to its moment (rt-history2; lib/histhear.lua, lib/webhistory.lua, lib/webui/history.js and
-- histhear.js, one line in extension/webui.cpp): the preview and Restore take the tempo map and markers of that moment (the one the studio put
-- in place last, not today's, nor session.json's stale one); the preview moves what follows the tempo the way REAPER does when a map lands,
-- each item from the map it was made under; tracks moved since go back where they sat; the master's automation then; .opus goes out as
-- audio/ogg; the time lapse follows the preview's position and shows markers, tempo changes and track moves when they happened. (James, rt)
package.path = "lib/?.lua;" .. package.path
local now = 1000
local vfs = {}
local api = {
  time_precise = function() return now end, GetOS = function() return "Win64" end, GetExtState = function() return "" end, SetExtState = function() end,
  GetExePath = function() return "C:/REAPER" end, GetResourcePath = function() return "C:/res" end, GetPlayStateEx = function() return 0 end,
  file_exists = function(p) return vfs[p] ~= nil end, RecursiveCreateDirectory = function() return 1 end, GetProjExtState = function() return 0, "" end,
  genGuid = function() return "{11111111-2222-3333-4444-555555555555}" end, CountTracks = function() return 0 end,
}
reaper = setmetatable({}, { __index = function(_, k)
  if api[k] then return api[k] end
  if not tostring(k):find("^StudioSync_") then return function() return 0 end end
end })
local band = require("band")
local mirror = require("mirror")
local hh = require("histhear")
local wh = require("webhistory")
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end

-- ---- a history with three tempo maps: A (120 bpm), B (60 bpm, the moment's), C (90 bpm, today's) ------------------------------------------
local A = { { time = 0, bpm = 120, num = 4, denom = 4, linear = false } }
local B = { { time = 0, bpm = 60, num = 4, denom = 4, linear = false } }
local C = { { time = 0, bpm = 90, num = 4, denom = 4, linear = false } }
local MK_B = { { region = false, pos = 2, ["end"] = 2, name = "Verse", num = 1 }, { region = true, pos = 4, ["end"] = 12, name = "Chorus", num = 1 } }
local entries, n = {}, 0
local function ev(time, e)
  n = n + 1
  e.time, e.id, e.user = "2026-11-10T" .. time .. "Z", "e" .. n, e.user or "James"
  e.kind = e.kind or "obj"; e.type = e.kind
  entries[#entries + 1] = e
  return e
end
local function item(oid, pos, beat) return "<ITEM\nPOSITION " .. pos .. "\nLENGTH 1\n" .. (beat and ("BEAT " .. beat .. "\n") or "") .. "<EXT\nband_oid " .. oid .. "\n>\n<SOURCE WAVE\nFILE \"{media}/" .. oid .. ".wav\"\n>\n>\n" end
local function track(name, after) return { name = name, after = after, vol = "1", pan = "0", mute = 0, phase = 0, depth = 0, nchan = "2" } end
ev("08:59:00", { obj = "track", oid = "T-1", rev = 1, name = "Keys", state = track("Keys", "") })
ev("08:59:10", { obj = "track", oid = "T-2", rev = 1, name = "Bass", state = track("Bass", "T-1") })
ev("08:59:20", { obj = "track", oid = "T-3", rev = 1, name = "Drums", state = track("Drums", "T-2") })
ev("09:00:00", { kind = "timeline", tempo = A, markers = {}, order = "2026-11-10T09:00:00Zt1" })
ev("09:05:00", { obj = "item", oid = "I-Y", rev = 1, track = "T-1", state = item("I-Y", 4) })            -- (unchanged since: REAPER moved it as maps landed)
ev("09:06:00", { obj = "item", oid = "I-W", rev = 1, track = "T-1", state = item("I-W", 5, 0) })         -- (timebase time: never moves)
ev("09:10:00", { obj = "item", oid = "I-X", rev = 1, track = "T-1", state = item("I-X", 4) })            -- (made under A: 4 s is beat 8)
ev("09:20:00", { kind = "timeline", tempo = B, markers = MK_B, order = "2026-11-10T09:20:00Zt2" })
ev("09:30:00", { obj = "item", oid = "I-Z", rev = 1, track = "T-1", state = item("I-Z", 3) })            -- (made under B)
local POINT = wh.epoch("2026-11-10T09:30:00Z")
ev("10:00:00", { kind = "timeline", tempo = C, markers = {}, order = "2026-11-10T10:00:00Zt3" })
ev("10:10:00", { obj = "item", oid = "I-X", rev = 2, gone = true, track = "T-1" })
ev("10:20:00", { obj = "item", oid = "I-Z", rev = 2, track = "T-1", state = item("I-Z", 7) })
ev("10:30:00", { obj = "track", oid = "T-3", rev = 2, name = "Drums", moved = "T-2", state = track("Drums", "") }) -- (Drums dragged to the top)
ev("10:40:00", { obj = "env", oid = "E-MASTER", rev = 1, track = "T-MASTER", state = "<VOLENV2\nACT 1 -1\nPT 0 0.25 0\n>\n" })
local held = { ["T-1"] = "e1", ["T-2"] = "e2", ["T-3"] = "e14", ["I-Y"] = "e5", ["I-W"] = "e6", ["I-Z"] = "e13", ["E-MASTER"] = "e15" }
local upto = hh.upto(entries, POINT)
assert(upto == 9, "the point: " .. upto)
-- the project now: Drums on top (moved since), Y where REAPER put it for map C (beat 8 at 90 bpm), Z moved since, W in time, X gone
local NOW_RPP = table.concat({
  '<REAPER_PROJECT 0.1 "7.86/win64" 1',
  '  TEMPO 90 4 4',
  '  <TRACK {G3}', '    NAME Drums', '    <EXT', '      band_oid T-3', '    >', '  >',
  '  <TRACK {G1}', '    NAME Keys', '    <EXT', '      band_oid T-1', '    >',
  '    ' .. item("I-Y", 16 / 3):gsub("\n$", ""):gsub("\n", "\n    "),
  '    ' .. item("I-Z", 7):gsub("\n$", ""):gsub("\n", "\n    "),
  '    ' .. item("I-W", 5, 0):gsub("\n$", ""):gsub("\n", "\n    "),
  '  >',
  '  <TRACK {G2}', '    NAME Bass', '    <EXT', '      band_oid T-2', '    >', '  >',
  '>', '' }, "\n")

-- ---- 1. which map stood then -----------------------------------------------------------------------------------------------------------
local tl = hh.timeline_at(entries, upto, {})
assert(tl and tl.how == "then" and tl.tempo == B and tl.markers == MK_B, "the map then: B, with its markers")
assert(hh.timeline_at(entries, #entries, {}).tempo == C, "at the end: today's")
assert(hh.timeline_at(entries, 3, {}) == nil, "before the first change kept, with none of the song's first map: not known")
assert(hh.timeline_at(entries, 3, { first = { tempo = A, markers = {} } }).how == "first", "with the song's first map kept: that one")
assert(hh.timeline_at({ entries[1] }, 1, {}).how == "today", "History with no tempo change at all: today's stood then too")
do -- (the studio goes by the order a change was given, not its file time: a computer whose clock ran ahead made an earlier map)
  local es = { { kind = "timeline", time = "2026-11-10T10:05:00Z", id = "a", tempo = A, markers = {}, order = "2026-11-10T10:30:00Za" },
    { kind = "timeline", time = "2026-11-10T10:10:00Z", id = "b", tempo = B, markers = {}, order = "2026-11-10T10:10:00Zb" } }
  assert(hh.timeline_at(es, 2, {}).tempo == A, "the map the studio put in place last stands, though another's file time is later")
end
local map_of = hh.map_of(entries)
assert(map_of(entries[7]).tempo == A and map_of(entries[9]).tempo == B and map_of(entries[5]).tempo == A, "each version's map: the newest before it")
assert(map_of({ time = "2026-11-10T09:31:00Z", id = "z", tl = "2026-11-10T09:00:00Zt1" }).tempo == A, "a change naming its map (tl) goes by that")
assert(map_of(entries[1]) == nil, "before any map kept: none")
local first = hh.first_map({ root = "J:/S" }, { song = "S", room = "main" }, { tempo = C, first_timeline = { tempo = A, markers = {} } })
assert(first and first.tempo == A, "the song's first map: session.json's first_timeline")
assert(hh.first_map({ root = "J:/S" }, { song = "S", room = "main" }, { tempo = C }) == nil, "never session.json's own tempo: not kept up to date since 0ae5fbf")

-- ---- 2. the copy: tracks back where they sat, items each from its own map, the master's automation then ---------------------------------
local plan = hh.settle(mirror.plan_restore(entries, upto), function(oid) return held[oid] ~= nil end)
local out, info = hh.rebuild(NOW_RPP, plan, { media = "J:/S/rooms/main/media", now = held, moves = hh.moves_since(entries, upto), map_of = map_of })
local order = {}
for oid in out:gmatch("band_oid (T%-%d)") do order[#order + 1] = oid end
assert(table.concat(order, ",") == "T-1,T-2,T-3" and info.moved == 1, "track order then: Drums back under Bass, where it sat before the move: " .. table.concat(order, ","))
assert(info.placed["I-X"].tempo == A and info.placed["I-Z"].tempo == B and info.placed["I-Y"] == nil, "items put in from History carry the map they were made under")
assert(info.master and info.master.env:find("<VOLENV2", 1, true) == nil and info.master.fxen == 1, "the master's automation then: none (it came later)")
do
  local mp = { ["E-MASTER"] = { id = "m1", obj = "env", track = "T-MASTER", state = "<VOLENV2\nACT 1 -1\nPT 0 0.5 0\nPT 4 1 0\n>\nBANDFXEN 0\n" } }
  local _, mi = hh.rebuild(NOW_RPP, mp, {})
  assert(mi.master.env:find("^<VOLENV2\nVIS 1 1 1\nACT 1 %-1\nPT 0 0%.5 0") and not mi.master.env:find("BANDFXEN", 1, true) and mi.master.fxen == 0 and mi.skipped == 0,
    "the master's automation as mirror.apply puts it in (view lines, its FX button apart): " .. mi.master.env)
end
-- moves: newest first, each back under where it sat before it
do
  local es = { { kind = "obj", obj = "track", oid = "T-A", moved = "", id = "1" }, { kind = "obj", obj = "track", oid = "T-B", moved = "T-A", id = "2" } }
  local m = hh.moves_since(es, 0)
  assert(#m == 2 and m[1].oid == "T-B" and m[1].from == "T-A" and m[2].from == "", "the newest move first")
end
info.tl = hh.tempo_plan(info.placed, tl, C)
assert(info.tl.tempo == B and #info.tl.maps == 2 and info.tl.groups["I-X"] and info.tl.groups["I-Z"] and info.tl.groups["I-Y"] == nil, "prep's tempo plan")
assert(hh.tempo_plan({}, { how = "today" }, C) == nil and hh.tempo_plan({}, nil, C) == nil, "the map then unknown or unchanged: nothing to do")
assert(hh.tempo_plan({}, { tempo = C, markers = {} }, C).tempo == nil, "the same map as today's: nothing moves (markers still set)")

-- ---- 3. prep in a background REAPER that moves what follows the tempo, as REAPER does ------------------------------------------------------
-- (square tempo segments, project timebase beats; an item's BEAT -1 follows the project's)
local function qn(map, t)
  local q, list = 0, #map > 0 and map or { { time = 0, bpm = 120 } }
  for i, m in ipairs(list) do
    local z = list[i + 1] and math.min(t, list[i + 1].time) or t
    if z > m.time then q = q + (z - m.time) * m.bpm / 60 end
    if not list[i + 1] or t <= list[i + 1].time then break end
  end
  return q
end
local function secs(map, q)
  local list = #map > 0 and map or { { time = 0, bpm = 120 } }
  local at = 0
  for i, m in ipairs(list) do
    local nxt = list[i + 1]
    local span = nxt and (nxt.time - m.time) * m.bpm / 60 or math.huge
    if q - at <= span then return m.time + (q - at) * 60 / m.bpm end
    at = at + span
  end
end
local function job_reaper(text, master_chunk)
  local P = { tempo = {}, items = {}, markers = {}, log = {}, master = { chunk = master_chunk, v = {} } }
  for _, m in ipairs(C) do P.tempo[#P.tempo + 1] = { time = m.time, bpm = m.bpm } end
  for blk in text:gmatch("<ITEM\n(.-\n%s*)>") do
    local oid = blk:match("band_oid (%S+)")
    if oid then P.items[#P.items + 1] = { oid = oid, pos = tonumber(blk:match("POSITION (%S+)")), mode = tonumber(blk:match("BEAT (%S+)") or "-1") } end
  end
  local function changed(was)
    for _, it in ipairs(P.items) do if it.mode ~= 0 then it.pos = secs(P.tempo, qn(was, it.pos)) end end
  end
  local function copy() local c = {}; for i, m in ipairs(P.tempo) do c[i] = m end; return c end
  P.api = {
    GetSetProjectInfo_String = function() end, GetSetProjectInfo = function() end, CountTracks = function() return 0 end,
    CountMediaItems = function() return #P.items end, GetMediaItem = function(_, i) return P.items[i + 1] end,
    GetSetMediaItemInfo_String = function(it) return true, it.oid end,
    GetMediaItemInfo_Value = function(it, k) assert(k == "C_BEATATTACHMODE"); return it.mode end,
    SetMediaItemInfo_Value = function(it, k, v) if k == "C_BEATATTACHMODE" then it.mode = v end end,
    CountTempoTimeSigMarkers = function() return #P.tempo end,
    DeleteTempoTimeSigMarker = function(_, i) local was = copy(); table.remove(P.tempo, i + 1); changed(was) end,
    SetTempoTimeSigMarker = function(_, idx, t, mp, bp, bpm, num, den, lin)
      assert(idx == -1 and mp == -1 and bp == -1 and type(lin) == "boolean", "a new tempo marker, as band.apply_tempo adds them")
      local was = copy(); P.tempo[#P.tempo + 1] = { time = t, bpm = bpm }; table.sort(P.tempo, function(a, z) return a.time < z.time end); changed(was)
    end,
    UpdateTimeline = function() end,
    CountProjectMarkers = function() return #P.markers end,
    DeleteProjectMarkerByIndex = function(_, i) table.remove(P.markers, i + 1) end,
    AddProjectMarker2 = function(_, rgn, pos, rend, name, want, col) P.markers[#P.markers + 1] = { region = rgn, pos = pos, ["end"] = rend, name = name, want = want } end,
    GetMasterTrack = function() return P.master end,
    GetTrackStateChunk = function(m) return m.chunk ~= nil, m.chunk end,
    SetTrackStateChunk = function(m, c) m.chunk = c end,
    SetMediaTrackInfo_Value = function(t, k, v) t.v[k] = v end,
  }
  P.markers = { { region = false, pos = 9, name = "today's marker" } }
  return P
end
local function run(prep, P)
  local was = reaper
  reaper = P.api
  local ok, err = pcall(assert(load(prep)), {})
  reaper = was
  assert(ok, err)
end
local P = job_reaper(out)
run(hh.prep(info), P)
local by = {}
for _, it in ipairs(P.items) do by[it.oid] = it end
assert(#P.tempo == 1 and P.tempo[1].bpm == 60, "the copy renders on the map then (B)")
assert(near(by["I-X"].pos, 8), "an item made under A (4 s = beat 8) sits at beat 8 on B: " .. tostring(by["I-X"].pos))
assert(near(by["I-Y"].pos, 8), "an item unchanged since, on today's map in the copy, moved back onto B as REAPER moves it: " .. tostring(by["I-Y"].pos))
assert(near(by["I-Z"].pos, 3), "an item made under B stays where it was: " .. tostring(by["I-Z"].pos))
assert(near(by["I-W"].pos, 5) and by["I-W"].mode == 0 and by["I-Y"].mode == -1 and by["I-X"].mode == -1, "a time-based item doesn't move; every item's own timebase is back")
assert(#P.markers == 2 and P.markers[1].name == "Verse" and P.markers[2].region == true and P.markers[2]["end"] == 12, "the markers then, today's gone")
-- the master's automation, swapped into the background REAPER's master chunk
do
  local MC = "<TRACK\nNAME \"\"\n<VOLENV2\nEGUID {X}\nACT 1 -1\nPT 0 1 0\n>\n<FXCHAIN\nBYPASS 0 0 0\n>\n>\n"
  local mp = { ["E-MASTER"] = { id = "m1", obj = "env", track = "T-MASTER", state = "<PANENV2\nACT 1 -1\nPT 0 -0.5 0\n>\nBANDFXEN 0\n" } }
  local _, mi = hh.rebuild(NOW_RPP, mp, {})
  local Q = job_reaper(out, MC)
  run(hh.prep(mi), Q)
  local c = Q.master.chunk
  assert(not c:find("VOLENV2", 1, true) and c:find("<PANENV2\nVIS 1 1 1\nACT 1 -1\nPT 0 -0.5 0\n>\n<FXCHAIN", 1, true) and c:find("^<TRACK") and c:find(">\n$")
    and Q.master.v.I_FXEN == 0, "the master's automation then, before its plug-ins; its FX button as it was: " .. c)
  local _, none = hh.rebuild(NOW_RPP, { ["E-MASTER"] = { id = "m2", obj = "env", track = "T-MASTER", state = "" } }, {})
  local R = job_reaper(out, MC)
  run(hh.prep(none), R)
  assert(not R.master.chunk:find("ENV", 1, true) and R.master.chunk:find("<FXCHAIN", 1, true) and R.master.v.I_FXEN == 1, "no automation then: none in the copy")
end

-- ---- 4. the live path: Listen writes all of it into the job --------------------------------------------------------------------------------
local TMP = "C:/T/bandsync-render"
local launched = {}
package.loaded.bgrender = { TMP = TMP, time_limit = function(s) return 180 + s * 4 end, launch_job = function(dir) launched[#launched + 1] = dir; vfs[dir .. "/pid.txt"] = "1" end,
  end_job = function() return true end }
package.loaded.recall = { entries = function() return entries end }
package.loaded.dawview = { shown = function() return true end }
local restored_tl = {}
package.loaded.sync = { room_dir = function() return "J:/S/rooms/main" end, authority = function() return function() return true end, { driver = "James", mode = "claims" } end,
  id_user = function(u) return u end, restore_timeline = function(_, _, _, _, es, u, session) restored_tl[#restored_tl + 1] = { es = es, upto = u, session = session } end,
  timeline_sig = function() return band.json_encode({ C, {}, {}, 2 }) end }
band.files = function() return {} end
band.subdirs = function() return {} end
band.read = function(p) return vfs[p] end
band.write_atomic = function(p, d) vfs[p] = d end
band.session_path = function() return "J:/S/session.json" end
band.log = function() end
api.Main_SaveProjectEx = function(_, path) vfs[path] = NOW_RPP end
api.GetProjExtState = function(_, sec, key) local v = sec == mirror.SEC and held[key]; if v then return 1, "1|h|" .. v .. "|" end return 0, "" end
api.CountTempoTimeSigMarkers = function() return 1 end
api.GetTempoTimeSigMarker = function() return true, 0, 0, 0, 90, 4, 4, false end
local real_remove = os.remove
os.remove = function(p) vfs[p] = nil; return true end
local proj, cfg, b = {}, { root = "J:/S", user = "James" }, { song = "Song", room = "main" }
local got = {}
wh.action(proj, cfg, b, { topic = "history", hear = { t = POINT } })
now = now + 5
wh.tick(proj, cfg, b, function(k, v) got[k] = v end, now)
assert(#launched == 1, "Listen starts a job")
local prep = vfs[launched[1] .. "/prep.lua"]
local P2 = job_reaper(vfs[launched[1] .. "/job.rpp"])
run(prep, P2)
local by2 = {}
for _, it in ipairs(P2.items) do by2[it.oid] = it end
assert(P2.tempo[1].bpm == 60 and near(by2["I-X"].pos, 8) and near(by2["I-Y"].pos, 8) and near(by2["I-Z"].pos, 3) and #P2.markers == 2, "the job Listen writes: the map, places and markers then")
assert(table.concat((function() local o = {}; for x in vfs[launched[1] .. "/job.rpp"]:gmatch("band_oid (T%-%d)") do o[#o + 1] = x end; return o end)(), ",") == "T-1,T-2,T-3",
  "and the track order then")
assert(got.hhear["then"].tempo == "then", "the page is told the map is the one then")
assert(hh.RECIPE >= 3, "the recipe is raised: an older build's kept preview (today's map) is never served for this")

-- ---- 5. Restore: the map the studio had then; never session.json's stale one -----------------------------------------------------------------
local reverted
mirror.revert = function(_, _, _, _, pl, opts) reverted = { plan = pl, opts = opts }; return "done" end
api.CountTracks = function() return 0 end
hh.S.tracks_at, hh.S.driver = nil, true
hh.restore(proj, cfg, b, { t = POINT })
assert(hh.S.ask and hh.S.ask.words:find("tempo map and markers back as they were", 1, true), "the words say the tempo map goes back too: " .. hh.S.ask.words)
hh.restore(proj, cfg, b, { id = hh.S.ask.id, yes = true })
assert(reverted and #restored_tl == 1 and restored_tl[1].es[1].tempo == B and restored_tl[1].upto == 1, "the restore puts map B back, the one then")
do -- the later-by-time change that wasn't the studio's map then isn't the one put back
  local es = { entries[1], { kind = "timeline", time = "2026-11-10T08:59:30Z", id = "x1", tempo = A, markers = {}, order = "2026-11-10T09:59:00Zx1" },
    { kind = "timeline", time = "2026-11-10T08:59:40Z", id = "x2", tempo = B, markers = {}, order = "2026-11-10T08:59:40Zx2" } }
  package.loaded.recall.entries = function() return es end
  restored_tl, reverted = {}, nil
  hh.restore(proj, cfg, b, { t = wh.epoch("2026-11-10T09:00:00Z") })
  hh.restore(proj, cfg, b, { id = hh.S.ask.id, yes = true })
  assert(#restored_tl == 1 and restored_tl[1].es[1].tempo == A, "the map with the higher order (the studio's then), not the later file")
  -- before the first change History keeps, session.json holding only a later map: left as it is, and said so
  vfs["J:/S/session.json"] = band.json_encode({ tempo = B, markers = {} })
  restored_tl = {}
  hh.restore(proj, cfg, b, { t = wh.epoch("2026-11-10T08:59:00Z") + 5 })
  assert(hh.S.ask.words:find("aren't kept in History", 1, true), "the words say the map then isn't known: " .. hh.S.ask.words)
  hh.restore(proj, cfg, b, { id = hh.S.ask.id, yes = true })
  assert(#restored_tl == 0, "a map that may not be the one then is never put in (session.json's own is any map since)")
  vfs["J:/S/session.json"] = band.json_encode({ tempo = B, markers = {}, first_timeline = { tempo = C, markers = {} } })
  hh.restore(proj, cfg, b, { t = wh.epoch("2026-11-10T08:59:00Z") + 5 })
  hh.restore(proj, cfg, b, { id = hh.S.ask.id, yes = true })
  assert(#restored_tl == 1 and #restored_tl[1].es == 0 and restored_tl[1].session.first_timeline.tempo[1].bpm == 90, "the song's first map, when kept")
  package.loaded.recall.entries = function() return entries end
end
os.remove = real_remove

-- ---- 6. the time lapse: track moves, markers and tempo at their moments ------------------------------------------------------------------
assert(wh.detail('{"type":"obj","obj":"track","state":{"after":"T-2","name":"x"}}', { obj = "track" }).after == "T-2", "a track's place is read from its event's text")
local inf = {}
for _, e in ipairs(entries) do if e.obj == "track" then inf[e] = { after = e.state.after } end end
local h = wh.build(entries, function(e) return inf[e] end, { places = { ["T-3"] = 0, ["T-1"] = 1, ["T-2"] = 2 }, frames = 50 })
local ord, mk, tp, moved_kind
for _, f in ipairs(h.frames) do
  if f.o then ord = ord or {}; ord[#ord + 1] = table.concat(f.o, ",") end
  if f.mk and #f.mk > 0 then mk = f.mk end
  if f.tp then tp = tp or {}; tp[#tp + 1] = math.floor(f.tp[1][2]) end
  for _, m in ipairs(f.m or {}) do if h.tracks[m[1] + 1][1] == "Drums" then moved_kind = m[3] end end
end
local id = {}
for i, t in ipairs(h.tracks) do id[t[1]] = i - 1 end
local made_in_order = false
for _, o in ipairs(ord or {}) do if o == table.concat({ id.Keys, id.Bass, id.Drums }, ",") then made_in_order = true end end
assert(made_in_order and ord[#ord] == table.concat({ id.Drums, id.Keys, id.Bass }, ","),
  "the lanes' order as it stood: made in order, then Drums dragged to the top (the master's automation isn't a lane): " .. table.concat(ord or {}, " | "))
assert(moved_kind == 1, "a move counts as an edit, not a mix move")
assert(mk and mk[1][1] == 2 and mk[1][2] == "Verse" and #mk == 1, "markers (not regions) at their moments")
assert(tp and table.concat(tp, ",") == "120,60,90", "tempo changes at their moments: " .. table.concat(tp or {}, ","))

-- ---- 7. the page: follows the preview; .opus as audio ------------------------------------------------------------------------------------
local hj, hhj = read("lib/webui/history.js"), read("lib/webui/histhear.js")
assert(hj:find("playhead", 1, true) and hhj:find("H.playhead", 1, true) and hhj:find("currentTime", 1, true), "the lapse follows the preview's position")
assert(hj:find("fr.mk", 1, true) and hj:find("fr.tp", 1, true) and hj:find("fr.o", 1, true), "the page draws markers, tempo and the order as they stood")
assert(not hhj:find("innerHTML", 1, true) and not hj:find("innerHTML", 1, true), "names go in as text")
local cpp = read("extension/webui.cpp")
local ot = cpp:match("const char %*offer_type%(.-octet%-stream")
assert(ot and ot:find('{ "opus", "audio/ogg" }', 1, true), "the server says an .opus is audio/ogg (Safari plays it then; Chromium and Firefox sniffed it)")
-- ---- rt-p6 (backlog 1.12): the master's automation items in the preview, and automation made under another tempo map ------------------------------------
do
  local MC = "<TRACK\nNAME \"\"\n<VOLENV2\nEGUID {X}\nACT 1 -1\nPT 0 1 0\n>\n<FXCHAIN\nBYPASS 0 0 0\n>\n>\n"
  -- made at 09:15 under A (120 bpm: 4 s is beat 8); the moment's map is B (60 bpm: beat 8 is 8 s). An item 2 s in, 2 s long: beats 4 to 8.
  local state = "<VOLENV2\nACT 1 -1\nPT 0 0.5 0\nPT 4 1 0\n>\nBANDAI VOLENV2 2 2 0 1 0 1 0 0 4\nBANDAIPT VOLENV2 0 0 0.3 0 0\nBANDAIPT VOLENV2 0 1 0.9 0 0\n"
  local mp = { ["E-MASTER"] = { id = "m1", obj = "env", track = "T-MASTER", time = "2026-11-10T09:15:00Z", state = state } }
  local _, mi = hh.rebuild(NOW_RPP, mp, { map_of = map_of })
  assert(mi.ai.MASTER and mi.ai.MASTER:find("^BANDAI VOLENV2 2 2 0 1") and select(2, mi.ai.MASTER:gsub("BANDAIPT", "")) == 2, "the master's automation items are kept for prep: " .. tostring(mi.ai.MASTER))
  assert(mi.envplaced.MASTER and mi.envplaced.MASTER.tempo == A, "and the map the automation was made under")
  mi.tl = hh.tempo_plan(mi.placed, tl, C, mi.envplaced)
  assert(mi.tl.envs.MASTER == 1 and mi.tl.maps[1] == A and mi.tl.tempo == B, "prep's plan moves it onto the map then")
  assert(next(hh.tempo_plan({}, { tempo = C, markers = {} }, C, { MASTER = { tempo = C } }).envs) == nil, "automation made under today's map: not moved")
  -- a background REAPER with envelope points and automation items (as the API keeps them)
  local Q = job_reaper(out, MC)
  local env = { pts = { { t = 0, v = 0.5 }, { t = 4, v = 1 } }, ais = {} }
  local a = Q.api
  a.CountTracks = function() return 0 end
  a.CountTrackEnvelopes = function() return 1 end
  a.GetTrackEnvelope = function() return env end
  a.GetTrackEnvelopeByChunkName = function(_, name) assert(name == "<VOLENV2"); return env end
  a.CountAutomationItems = function(e) return #e.ais end
  a.InsertAutomationItem = function(e, pool, pos, len) e.ais[#e.ais + 1] = { pool = pool, D_POSITION = pos, D_LENGTH = len, pts = { { t = 0, v = 0 } } }; return #e.ais - 1 end
  a.GetSetAutomationItemInfo = function(e, i, k, v, set) local x = e.ais[i + 1]; if set then x[k] = v else return x[k] or 0 end end
  a.CountEnvelopePointsEx = function(e, i) return #e.ais[(i & 0xFFFF) + 1].pts end
  a.DeleteEnvelopePointEx = function(e, i, p) table.remove(e.ais[(i & 0xFFFF) + 1].pts, p + 1) end
  a.InsertEnvelopePointEx = function(e, i, t, v) local x = e.ais[(i & 0xFFFF) + 1]; x.pts[#x.pts + 1] = { t = t, v = v }; return true end
  a.Envelope_SortPointsEx = function() end
  a.CountEnvelopePoints = function(e) return #e.pts end
  a.GetEnvelopePoint = function(e, i) local p = e.pts[i + 1]; return true, p.t, p.v, 0, 0, false end
  a.SetEnvelopePoint = function(e, i, t) e.pts[i + 1].t = t; return true end
  a.Envelope_SortPoints = function() end
  a.TimeMap2_timeToQN = function(_, t) return qn(Q.tempo, t) end
  a.TimeMap2_QNToTime = function(_, q) return secs(Q.tempo, q) end
  run(hh.prep(mi), Q)
  assert(#env.ais == 1 and env.ais[1].pool == 0 and env.ais[1].D_PLAYRATE == 1 and #env.ais[1].pts == 2 and near(env.ais[1].pts[2].v, 0.9), "the master's automation item is rebuilt (rate, points)")
  assert(near(env.pts[1].t, 0) and near(env.pts[2].t, 8), "a point 4 s into A (beat 8) is 8 s into B: " .. env.pts[2].t)
  assert(near(env.ais[1].D_POSITION, 4) and near(env.ais[1].D_LENGTH, 4), "the item's beats 4-8 on A are 4-8 s on B: " .. env.ais[1].D_POSITION .. " + " .. env.ais[1].D_LENGTH)
  -- on today's map (no move): the points stay
  local tn = hh.tempo_plan({}, tl, C, { MASTER = { tempo = C } })
  mi.tl = tn
  local Q2 = job_reaper(out, MC)
  env = { pts = { { t = 0, v = 0.5 }, { t = 4, v = 1 } }, ais = {} }
  for k, f in pairs(a) do if Q2.api[k] == nil then Q2.api[k] = f end end
  Q2.api.TimeMap2_timeToQN = function(_, t) return qn(Q2.tempo, t) end
  Q2.api.TimeMap2_QNToTime = function(_, q) return secs(Q2.tempo, q) end
  run(hh.prep(mi), Q2)
  assert(near(env.pts[2].t, 4), "made under today's map: its seconds stay")
  -- a track's own automation: kept and placed the same way
  local tp = { ["E-1"] = { id = "m2", obj = "env", track = "T-1", time = "2026-11-10T09:15:00Z", state = state } }
  local _, ti = hh.rebuild(NOW_RPP, tp, { map_of = map_of })
  assert(ti.ai["T-1"] and ti.envplaced["T-1"] and ti.envplaced["T-1"].tempo == A, "a track's automation: its items and its map are kept too")
end
-- rt-p6 (backlog 3.13): the time lapse's comp areas: items on a lane that plays with the others (plays "2") are drawn dashed and counted
assert(hj:find("p[a[6]] === '2'", 1, true) and hj:find("g.setLineDash([2, 2]); g.lineWidth = 1; g.strokeRect(x + 0.5", 1, true) and hj:find("add('Comp pieces', String(s.nc))", 1, true)
  and hj:find("nc: compNow()", 1, true), "history.js: comp areas drawn and counted")
local fr = wh.detail('{"freemode":2,"plays":"0,2,2"}', { obj = "track" })
assert(fr.plays == "0,2,2", "a comp's lanes reach the frames as they are (the page reads the 2s)")
print("ok")
