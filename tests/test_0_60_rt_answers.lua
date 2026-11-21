-- rt-answers (James's decisions, 2026-11-21), items 1 and 2: the panel's Restore page (lib/page_restore.lua) in the chunk-faithful stand-in
-- REAPER of rt-edits (tests/fixtures/editreaper.lua), which moves beat-based items on a tempo change as REAPER does.
--   1. "Undo this change" on a whole-song Restore's row puts today's tempo map back first (the Restore's timeline change carries its act),
--      and the items land under it: nothing more goes out as yours, and the laptop ends the same.
--   2. The page's Restore puts a restored take back on its beat under the map in place (mirror.revert's opts.map_of), as History's does.
-- The harness is a trimmed copy of tests/test_0_60_rt_edits.lua's. Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local E = require("editreaper")
local f = E.f

local real_date, real_time = os.date, os.time
local now_t = real_time({ year = 2026, month = 11, day = 21, hour = 12, min = 0, sec = 0 })
os.date = function(fmt, t) return real_date(fmt, t or now_t) end
os.time = function(t) if t then return real_time(t) end; return now_t end
local function tick(n) now_t = now_t + (n or 2) end

local files, logged = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
proxy.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
local function listing(dir, ext)
  local out = {}
  for p in pairs(files) do local d, fn = p:match("^(.*)/([^/]*)$"); if d == dir and (not ext or fn:sub(-#ext) == ext) then out[#out + 1] = fn end end
  table.sort(out)
  return out
end
proxy.listing = function(dir) return listing(dir) end
proxy.files = listing
proxy.log = function(t) logged[#logged + 1] = t end
proxy.size = function() return 960044 end
proxy.copy_atomic = function() return true end
proxy.session_path = function(_, s) return "SESSION/" .. tostring(s) .. ".json" end
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
local recall = require("recall")
require("direct").send_live = function() return true end
require("prints").choose = function() end
mirror.FX_SET_GAP = 0
local ROOT = "C:/fake/StudioSync"
local song, room = "Answers", "main"
local yes = function() return true end
local MEDIA

local function computer(user, path) return { F = E.new(path), cfg = { user = user, root = ROOT } } end
local A, B, F
local function as(c) reaper = c.F.reaper end
local function state(c)
  as(c)
  local out, order = {}, {}
  for _, o in ipairs(mirror.scan(c.F.proj, c.cfg.user, MEDIA, false)) do out[o.oid] = o.hash; if o.kind == "track" then order[#order + 1] = o.oid end end
  return out, table.concat(order, ",")
end
local function timeline(c)
  as(c)
  local function r(x) return type(x) == "number" and math.floor(x * 1e9 + 0.5) / 1e9 or x end
  local t, m = band.capture_tempo(c.F.proj), band.capture_markers(c.F.proj)
  for _, x in ipairs(t) do x.time, x.bpm = r(x.time), r(x.bpm) end
  for _, x in ipairs(m) do x.pos, x["end"] = r(x.pos), r(x["end"]) end
  return band.json_encode({ t, m })
end
local function same(x, y, what)
  local sx, ox = state(x)
  local sy, oy = state(y)
  for oid, h in pairs(sx) do assert(sy[oid] == h, what .. ": " .. oid .. " reads the same on " .. y.cfg.user) end
  for oid in pairs(sy) do assert(sx[oid], what .. ": " .. y.cfg.user .. " has nothing more (" .. oid .. ")") end
  assert(ox == oy, what .. ": the same track order")
  assert(timeline(x) == timeline(y), what .. ": the same tempo map and markers\n" .. timeline(x) .. "\n" .. timeline(y))
end
local seen_files = {}
local function new_events()
  local out = {}
  for p, v in pairs(files) do
    if not seen_files[p] then
      seen_files[p] = true
      if p:find("/events/", 1, true) and type(v) == "table" then out[#out + 1] = v end
    end
  end
  return out
end
local function look(c)
  as(c)
  c.F.clock = c.F.clock + 1
  sync.watch_timeline(c.F.proj, c.cfg, song, room, yes)
  mirror.watch(c.F.proj, c.cfg, song, room, { can = yes, mode = "open", quick = true })
  return new_events()
end
local function settle(c)
  for _ = 1, 20 do if #look(c) == 0 and not mirror.more then return end end
  error("never settled")
end
local function recv(c)
  as(c)
  for _ = 1, 20 do
    c.F.clock = c.F.clock + 1
    local got = sync.receive(c.F.proj, c.cfg, song, room, yes)
    if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
  end
  for _ = 1, 3 do for _, ev in ipairs(look(c)) do error(c.cfg.user .. " sent back what landed: " .. tostring(ev.oid)) end end
end
local function audio(pos, len, file, name)
  return table.concat({ "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 1", "ALLTAKES 0", "FADEIN 1 0.01 0 1 0 0 0",
    "FADEOUT 1 0.01 0 1 0 0 0", "MUTE 0 0", "SEL 0", "IID 1", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025",
    "CHANMODE 0", "GUID " .. E.guid(), "<SOURCE WAVE", 'FILE "' .. MEDIA .. "/" .. file .. '"', ">", ">" }, "\n") .. "\n"
end
local drums, bass, gtr
local TEMPO0 -- (the map the song was shared with: 120 bpm)
local function build(name)
  song = name
  MEDIA = sync.room_dir({ root = ROOT }, song, room) .. "/media"
  A, B = computer("James", "C:/A/" .. name .. ".rpp"), computer("Bee", "C:/B/" .. name .. ".rpp")
  F = A.F
  drums, bass, gtr = F.add_track("Drums"), F.add_track("Bass"), F.add_track("Gtr")
  for i = 0, 3 do F.add_item(drums, audio(i * 4, 3.5, "drums" .. i .. ".flac", "Drums " .. i)) end
  for i = 0, 3 do F.add_item(bass, audio(i * 4 + 0.5, 3, "bass" .. i .. ".flac", "Bass " .. i)) end
  F.add_item(gtr, audio(2, 6, "gtr.flac", "Gtr"))
  as(A)
  TEMPO0 = band.capture_tempo(F.proj)
  files[proxy.session_path(A.cfg, song)] = band.json_decode(band.json_encode({ sync = "mirror", host = "James", tempo = TEMPO0, markers = {},
    first_timeline = { tempo = TEMPO0, markers = {} } }))
  settle(A)
  A.F.clock = A.F.clock + 70
  settle(A)
  recv(B)
  B.F.clock = B.F.clock + 70
  settle(B)
  same(A, B, name .. ": the song as shared")
end
local function item_named(t, name) for _, it in ipairs(t.items) do if it.text:find('NAME "' .. name .. '"', 1, true) then return it end end end
local function pos(it) return tonumber(E.top_value(it.text, "POSITION")) end
local function len(it) return tonumber(E.top_value(it.text, "LENGTH")) end
local function set(it, key, v) F.set_text(it, E.set_top(it.text, key, v)) end
local function tempo_to(bpm) -- (one tempo from the start, every other marker gone)
  as(A)
  reaper.SetTempoTimeSigMarker(A.F.proj, 0, 0, -1, -1, bpm, 4, 4, false)
  for i = reaper.CountTempoTimeSigMarkers(A.F.proj) - 1, 1, -1 do reaper.DeleteTempoTimeSigMarker(A.F.proj, i) end
end

-- the panel's Restore page, on the desktop
as(computer("Nobody", "C:/N/x.rpp")) -- (the page's theme reads REAPER as it loads)
local R = require("page_restore")
local session = function() return proxy.read_json(proxy.session_path(A.cfg, song)) end
R.init({ b = function() return { song = song, room = room } end, cfg = function() return A.cfg end, proj = function() return A.F.proj end,
  view = function() return { session = session(), driver = "James" } end })
local function page_entries() -- (as the page reads them: lib/page_restore.lua refresh_history)
  local list = recall.entries(A.cfg, song, room)
  table.sort(list, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  R.test.entries(list)
  return list
end

-- ---- 1. a whole-song Restore across a tempo change, then "Undo this change" on one of its rows ----
do
  build("Answers undo restore")
  local upto = #page_entries() -- (the song as shared: the point to go back to)
  tick()
  as(A)
  set(item_named(bass, "Bass 1"), "MUTE", "1 0")
  tick()
  settle(A)
  tick()
  as(A)
  reaper.SetTempoTimeSigMarker(A.F.proj, -1, 2, -1, -1, 90, 4, 4, false) -- (90 bpm from 2 s: REAPER moves what's after it)
  tick()
  settle(A)
  tick()
  recv(B)
  same(A, B, "(a mute, then a tempo change from 2 s)")
  local today, moved_to = timeline(A), pos(item_named(drums, "Drums 2"))
  assert(math.abs(moved_to - 8) > 0.5, "(REAPER moved the items after the tempo change)")
  -- Restore whole project to here, as the button does
  tick()
  page_entries()
  as(A)
  local res = R.test.restore_whole(upto, nil, { can = yes, mode = "open" })
  local sent, act = new_events(), nil
  for _, ev in ipairs(sent) do if ev.type == "obj" then act = act or ev.act; assert(ev.act and ev.act == act, "(the Restore is one act)") end end
  local tl
  for _, ev in ipairs(sent) do if ev.type == "timeline" then tl = ev end end
  assert(act and tl and tl.restored and tl.act == act, "the Restore's tempo map goes out under its act (" .. tostring(tl and tl.act) .. " / " .. tostring(act) .. ")")
  assert(timeline(A) ~= today and math.abs(pos(item_named(drums, "Drums 2")) - 8) < 1e-6, "the song is as it was: the map then, the items then (" .. tostring(res) .. ")")
  assert(#look(A) == 0, "(nothing more goes out after the Restore)")
  tick()
  recv(B)
  same(A, B, "(the Restore)")
  -- "Undo this change" on one of the Restore's rows: today's map first, then the items under it
  tick()
  local list = page_entries()
  local j
  for i, e in ipairs(list) do if e.kind == "obj" and e.act == act and e.restored then j = i end end
  assert(j, "(a row of the Restore)")
  as(A)
  local opts = { can = yes, mode = "open" }
  res = R.test.undo_change(j, opts)
  assert(timeline(A) == today, "Undo this change on a whole-song Restore's row puts today's tempo map back (" .. tostring(res) .. ")\n" .. timeline(A) .. "\n" .. today)
  assert(opts.retimed, "(and what REAPER moved for it isn't an edit of yours)")
  assert(math.abs(pos(item_named(drums, "Drums 2")) - moved_to) < 1e-6 and E.top_value(item_named(bass, "Bass 1").text, "MUTE") == "1 0",
    "the items are as today, under today's map (Drums 2 at " .. pos(item_named(drums, "Drums 2")) .. ")")
  local undo_tl
  for _, ev in ipairs(new_events()) do if ev.type == "timeline" then undo_tl = ev end end
  assert(undo_tl and undo_tl.restored, "its map goes out as a Restore's, so StudioSync's Undo and Redo pass over it")
  local mine = mirror.last_mine(page_entries(), "James")
  assert(not (mine and page_entries()[mine].restored), "(StudioSync's Undo doesn't take a Restore's change for yours)")
  assert(#look(A) == 0, "nothing more goes out as your edit after it")
  tick()
  recv(B)
  same(A, B, "Undo this change on a whole-song Restore")
  print("rt-answers: Undo this change on a whole-song Restore's row puts today's tempo map back, then the items under it")
end

-- ---- 2. the page's Restore puts a take back on its beat under the map in place ----
-- Gtr at 2 s (beat 4) under 120; the tempo goes to 60 (REAPER moves it to 4 s, which goes out made under 60); Gtr is deleted; the tempo goes
-- back to 120. Restoring the Gtr track to the point after the change puts it on beat 4 under today's 120: 2 s, not its stored 4 s.
do
  build("Answers beat")
  tick()
  tempo_to(60)
  tick()
  settle(A)
  assert(math.abs(pos(gtr.items[1]) - 4) < 1e-6, "(REAPER moved Gtr onto beat 4 under 60: " .. pos(gtr.items[1]) .. ")")
  local point = #page_entries()
  tick()
  as(A)
  reaper.DeleteTrackMediaItem(gtr, gtr.items[1])
  tick()
  settle(A)
  tick()
  tempo_to(120)
  tick()
  settle(A)
  tick()
  recv(B)
  same(A, B, "(Gtr deleted, the tempo back at 120)")
  page_entries()
  as(A)
  local gtr_oid
  for _, o in ipairs(mirror.scan(A.F.proj, "James", MEDIA, false)) do if o.kind == "track" and type(o.state) == "table" and o.state.name == "Gtr" then gtr_oid = o.oid end end
  local scope = require("histhear").scope({ gtr_oid })
  local res = R.test.restore_tracks(point, nil, scope, { can = yes, mode = "open" })
  local it = gtr.items[1]
  assert(it and math.abs(pos(it) - 2) < 1e-6 and math.abs(len(it) - 6) < 1e-6,
    "Restore selected tracks puts the take on its beat under today's map (" .. tostring(it and pos(it)) .. ", " .. tostring(it and len(it)) .. ", " .. tostring(res) .. ")")
  tick()
  settle(A)
  tick()
  recv(B)
  same(A, B, "a take restored onto its beat")
  -- and the whole-song Restore hands the same map_of to mirror.revert
  local real, got = mirror.revert, nil
  mirror.revert = function(_, _, _, _, _, o) got = o; return "" end
  page_entries()
  R.test.restore_whole(point, nil, { can = yes, mode = "open" })
  mirror.revert = real
  local v
  for _, e in ipairs(page_entries()) do if e.kind == "obj" and e.name == "Gtr" and e.obj == "item" and not e.gone and e.tl then v = v or e end end -- (the one REAPER's move to 60 sent)
  assert(got and got.map_of and v and got.map_of(v) and got.map_of(v)[1].bpm == 60, "the whole-song Restore says which map each version was made under")
  print("rt-answers: the page's Restore puts a take on its beat under the map in place")
end
print("ok rt-answers")
