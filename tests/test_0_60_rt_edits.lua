-- rt-edits (James, 2026-11-20: "make sure support for any edits we haven't tried ... anything else that needs to be tested or proven"): the
-- edit matrix. Each edit is made on the desktop (James) as REAPER leaves the project after it, in a chunk-faithful stand-in REAPER
-- (tests/fixtures/editreaper.lua), and must be:
--   1. detected: by Live sync's quick look (one pass) and, in the second round, by a full look;
--   2. sent, and applied on the laptop (Bee) so that every object reads the same there (mirror.scan's hashes, track order);
--   3. one Ctrl+Z on the desktop (lib/undo.lua's step, what REAPER's Ctrl+Z on a StudioSync point turns into, and the bound key): everything
--      the edit changed goes back on both, and the laptop's own edit made since (a track renamed) stays;
--   4. caught up by a late joiner (Cee) that opens the song afterwards and reads every event.
-- Timeline edits (markers renumbered, the region render matrix, the tempo map) go through sync.watch_timeline and sync.apply the same way.
-- What can't be proven offline is in docs/rt/rt-edits.md's REAPER checklist. Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local E = require("editreaper")
local f = E.f

-- each step a new second (events of one second are one act for Undo: mirror.same_moment)
local real_date, real_time = os.date, os.time
local now_t = real_time({ year = 2026, month = 11, day = 20, hour = 12, min = 0, sec = 0 })
os.date = function(fmt, t) return real_date(fmt, t or now_t) end
os.time = function(t) if t then return real_time(t) end; return now_t end
local function tick(n) now_t = now_t + (n or 2) end

-- the studio's shared folder (Syncthing's copy), in memory
local files, logged = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
proxy.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
local hidden = {} -- path -> true: not here yet, for whoever lists now
local function listing(dir, ext)
  local out = {}
  for p in pairs(files) do local d, fn = p:match("^(.*)/([^/]*)$"); if d == dir and (not ext or fn:sub(-#ext) == ext) and not hidden[p] then out[#out + 1] = fn end end
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
local direct = require("direct")
direct.send_live = function() return true end
require("prints").choose = function() end -- (which take plays, notes or a print: this computer's own, never part of what travels)
mirror.FX_SET_GAP = 0
local ROOT = "C:/fake/StudioSync"
local song, room = "Edits", "main"
local yes = function() return true end
local MEDIA = sync.room_dir({ root = ROOT }, song, room) .. "/media"

local function computer(user, path) return { F = E.new(path), cfg = { user = user, root = ROOT } } end
local A, B -- (the desktop and the laptop of the song being edited: build() below)
local function as(c) reaper = c.F.reaper end

-- ---- what a computer holds: every object's hash, in order, and the timeline ----
local function state(c)
  as(c)
  local objs = mirror.scan(c.F.proj, c.cfg.user, MEDIA, false)
  local out, order = {}, {}
  for _, o in ipairs(objs) do out[o.oid] = o.hash; if o.kind == "track" then order[#order + 1] = o.oid end end
  return out, table.concat(order, ","), objs
end
local function timeline(c) -- (times to a nanosecond: what REAPER moved for a tempo map and what a map's event says differ in the 14th digit)
  as(c)
  local function r(x) return type(x) == "number" and math.floor(x * 1e9 + 0.5) / 1e9 or x end
  local t, m = band.capture_tempo(c.F.proj), band.capture_markers(c.F.proj)
  for _, x in ipairs(t) do x.time, x.bpm = r(x.time), r(x.bpm) end
  for _, x in ipairs(m) do x.pos, x["end"] = r(x.pos), r(x["end"]) end
  return band.json_encode({ t, m })
end
local function same(x, y, what)
  local sx, ox, objx = state(x)
  local sy, oy, objy = state(y)
  local function shown(objs, oid)
    for _, o in ipairs(objs) do if o.oid == oid then return type(o.state) == "table" and mirror.track_line(o.state) .. " after " .. tostring(o.state.after) or tostring(o.state) end end
  end
  for oid, h in pairs(sx) do
    assert(sy[oid] == h, what .. ": " .. oid .. " reads the same on " .. y.cfg.user .. " (" .. tostring(h) .. " vs " .. tostring(sy[oid]) .. ")\n" .. tostring(shown(objx, oid)) .. "\n" .. tostring(shown(objy, oid)))
  end
  for oid in pairs(sy) do assert(sx[oid], what .. ": " .. y.cfg.user .. " has nothing " .. x.cfg.user .. " hasn't (" .. oid .. ")") end
  assert(ox == oy, what .. ": the same track order")
  assert(timeline(x) == timeline(y), what .. ": the same tempo map and markers\n" .. timeline(x) .. "\n" .. timeline(y))
end

-- ---- a pass of Live sync: a look (quick, or full), the timeline's look, then what came in ----
local seen_files = {}
for p in pairs(files) do seen_files[p] = true end
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
local function look(c, quick)
  as(c)
  c.F.clock = c.F.clock + 1
  local q0, f0 = mirror.look_stats.quick, mirror.look_stats.full
  -- (as Live sync's P.look: the tempo map and markers first, "a tempo change moves the items", then the look at the items)
  sync.watch_timeline(c.F.proj, c.cfg, song, room, yes)
  mirror.watch(c.F.proj, c.cfg, song, room, { can = yes, mode = "open", quick = quick })
  local sent, oids = new_events(), {}
  for _, ev in ipairs(sent) do if ev.oid then oids[ev.oid] = ev end end
  return oids, sent, (mirror.look_stats.full > f0 and "full") or (mirror.look_stats.quick > q0 and "quick") or "none"
end
local function settle(c, quick, into) -- (looks until nothing more goes: a project's first look, plug-ins loading; what went, into `into`)
  for _ = 1, 20 do
    local o, s = look(c, quick)
    for oid, ev in pairs(o) do if into then into[oid] = ev end end
    if #s == 0 and not mirror.more then return end
  end
  error("never settled")
end
local function recv(c)
  as(c)
  local n = 0
  for _ = 1, 20 do
    c.F.clock = c.F.clock + 1
    local got = sync.receive(c.F.proj, c.cfg, song, room, yes)
    n = n + (tonumber(got) or 0)
    if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
  end
  -- (what landed is taken in by the next look as the band's, never sent back)
  for _ = 1, 3 do -- (and a track that landed before the one above it is put in its place by the looks after: W.one puts the band's back)
    local o = look(c, true)
    for oid, ev in pairs(o) do error(c.cfg.user .. " sent back what landed: " .. oid .. " " .. tostring(ev.state):sub(1, 200)) end
  end
  return n
end

-- ---- the song as the desktop shares it ----
local F
local function audio(pos, len, file, name, extra)
  local t = { "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 1", "ALLTAKES 0", "FADEIN 1 0.01 0 1 0 0 0", "FADEOUT 1 0.01 0 1 0 0 0",
    "MUTE 0 0", "SEL 0", "IID 1", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS " .. f((extra and extra.soffs) or 0), "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0",
    "GUID " .. E.guid(), "<SOURCE WAVE", 'FILE "' .. MEDIA .. "/" .. file .. '"', ">" }
  if extra and extra.takes then
    for _, tk in ipairs(extra.takes) do
      for _, l in ipairs({ tk.sel and "TAKE SEL" or "TAKE", 'NAME "' .. tk.name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0", "GUID " .. E.guid(),
        "<SOURCE WAVE", 'FILE "' .. MEDIA .. "/" .. tk.file .. '"', ">" }) do t[#t + 1] = l end
    end
  end
  t[#t + 1] = ">"
  return table.concat(t, "\n") .. "\n"
end
local NOTES = { "E 0 90 3c 60", "E 480 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 960 b0 7b 00" }
local function midi(pos, len, name, pool, notes)
  local t = { "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 0", "ALLTAKES 0", "FADEIN 1 0 0 1 0 0 0", "FADEOUT 1 0 0 1 0 0 0", "MUTE 0 0", "SEL 0",
    "IID 2", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0", "GUID " .. E.guid(),
    pool and "<SOURCE MIDIPOOL" or "<SOURCE MIDI", "HASDATA 1 960 QN", "CCINTERP 32" }
  if pool then t[#t + 1] = "POOLEDEVTS " .. pool end
  for _, n in ipairs(notes or NOTES) do t[#t + 1] = n end
  for _, l in ipairs({ "GUID " .. E.guid(), "IGNTEMPO 0 120 4 4", "CFGEDITVIEW 0 0.12 64 12 0 -1 0 0 0 0.5", ">", ">" }) do t[#t + 1] = l end
  return table.concat(t, "\n") .. "\n"
end
local ENV = "<VOLENV2\nEGUID {E1}\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 4 0.5 0\nPT 8 1 0\nPT 12 0.7 0\n>\n"
local drums, bass, keys, gtr, vox
-- (the markers come with the song's file and session.json, not as an event: every computer opens with them)
local function seed_markers(x) x.add_marker(true, 0, 8, "Verse"); x.add_marker(true, 8, 16, "Chorus"); x.add_marker(false, 4, 4, "Cue") end
-- A song of its own (each round edits a fresh one): the desktop shares it, the laptop takes it in.
local function build(name)
  song = name
  MEDIA = sync.room_dir({ root = ROOT }, song, room) .. "/media"
  A, B = computer("James", "C:/A/" .. name .. ".rpp"), computer("Bee", "C:/B/" .. name .. ".rpp")
  F = A.F
  drums = F.add_track("Drums", nil, ENV)
  bass = F.add_track("Bass")
  keys = F.add_track("Keys")
  gtr = F.add_track("Gtr")
  vox = F.add_track("Vox") -- (recorded into lanes below; a track in lanes with a take-stack item would have them made lanes: prints.takes_to_lanes)
  for i = 0, 3 do F.add_item(drums, audio(i * 4, 3.5, "drums" .. i .. ".flac", "Drums " .. i)) end
  for i = 0, 3 do F.add_item(bass, audio(i * 4 + 0.5, 3, "bass" .. i .. ".flac", "Bass " .. i)) end
  F.add_item(keys, midi(0, 4, "Keys A"))
  F.add_item(keys, midi(8, 4, "Keys B"))
  F.add_item(gtr, audio(2, 6, "gtr.flac", "Gtr"))
  seed_markers(F)
  seed_markers(B.F)
  as(A)
  files[proxy.session_path(A.cfg, song)] = band.json_decode(band.json_encode({ sync = "mirror", host = "James", tempo = band.capture_tempo(F.proj), markers = band.capture_markers(F.proj) }))
  settle(A, true)
  A.F.clock = A.F.clock + 70 -- (past the plug-ins' loading minute: looks are quick from here)
  settle(A, true)
  recv(B)
  B.F.clock = B.F.clock + 70
  settle(B, true)
  same(A, B, name .. ": the song as shared")
end

-- ---- helpers for the edits ----
local function items(t) return t.items end
local function item_named(t, name) for _, it in ipairs(t.items) do if it.text:find('NAME "' .. name .. '"', 1, true) then return it end end end
local function pos(it) return tonumber(E.top_value(it.text, "POSITION")) end
local function len(it) return tonumber(E.top_value(it.text, "LENGTH")) end
local function set(it, key, v) F.set_text(it, E.set_top(it.text, key, v)) end
-- REAPER's copy of an item (paste, duplicate, Ctrl+drag, split's right part): its chunk and P_EXT as they were, a new GUID, then moved
local function copy(it, to_track, at, extra)
  local c = F.add_item(to_track or it.track, (F.item_chunk(it):gsub("\nIGUID [^\n]*", ""):gsub("\nGUID [^\n]*", function() return "\nGUID " .. E.guid() end)))
  if at then set(c, "POSITION", f(at)) end
  if extra then extra(c) end
  F.sort_items(c.track)
  return c
end
local function shift_env(t, from, by, upto) -- (envelope points move with items)
  local out = {}
  for l in t.body:gmatch("[^\n]+") do
    local a, rest = l:match("^PT (%S+)(.*)$")
    if a and tonumber(a) >= from and (not upto or tonumber(a) < upto) then l = "PT " .. f(tonumber(a) + by) .. rest end
    out[#out + 1] = l
  end
  t.body = table.concat(out, "\n") .. "\n"
  F.changed()
end
local function add_env_points(t, from, upto, by) -- (copies of the points in [from, upto) placed `by` later: paste with points)
  local pts, out = {}, {}
  for l in t.body:gmatch("[^\n]+") do
    local a, rest = l:match("^PT (%S+)(.*)$")
    if a and tonumber(a) >= from and tonumber(a) < upto then pts[#pts + 1] = "PT " .. f(tonumber(a) + by) .. rest end
    if l == ">" and #pts > 0 then for _, p in ipairs(pts) do out[#out + 1] = p end; pts = {} end
    out[#out + 1] = l
  end
  t.body = table.concat(out, "\n") .. "\n"
  F.changed()
end
local function marker(name) for _, m in ipairs(F.markers) do if m.name == name then return m end end end
local function select_only(list) for _, it in ipairs(F.all_items()) do set(it, "SEL", "0") end; for _, it in ipairs(list) do set(it, "SEL", "1") end end

-- ---- the matrix ----
-- Each: name, edit() (on the desktop, `F` its REAPER), and what must go out: `min` objects at least; `timeline` = a timeline event too.
-- `undo` = false where nothing of the edit is an object Undo puts back (timeline only).
local cases = {
  { name = "copy a region with its items, envelope points moving with items", min = 3, timeline = true, edit = function()
    local r = marker("Verse")
    for _, t in ipairs({ drums, bass }) do
      local l = {}
      for _, it in ipairs(items(t)) do if pos(it) >= r.pos and pos(it) < r.rend then l[#l + 1] = it end end
      for _, it in ipairs(l) do copy(it, nil, pos(it) + 16) end
    end
    add_env_points(drums, r.pos, r.rend, 16)
    F.add_marker(true, 16, 24, "Verse")
  end },
  { name = "copy a region with its items, envelope points staying", min = 1, timeline = true, edit = function()
    local r = marker("Chorus")
    for _, it in ipairs({ table.unpack(items(keys)) }) do if pos(it) >= r.pos and pos(it) < r.rend then copy(it, nil, pos(it) + 24) end end
    F.add_marker(true, 32, 40, "Chorus")
  end },
  { name = "cut a region with its items (ripple off)", min = 2, timeline = true, edit = function()
    local r
    for _, m in ipairs(F.markers) do if m.region and m.name == "Verse" and m.pos == 16 then r = m end end
    for _, t in ipairs({ drums, bass }) do
      for i = #t.items, 1, -1 do local it = t.items[i]; if pos(it) >= r.pos and pos(it) < r.rend then F.remove_item(it) end end
    end
    for i, m in ipairs(F.markers) do if m == r then table.remove(F.markers, i) end end
    F.changed()
  end },
  { name = "cut items with ripple per track", min = 3, edit = function()
    local it = item_named(bass, "Bass 1")
    local gap = len(it)
    local at = pos(it)
    F.remove_item(it)
    for _, x in ipairs(items(bass)) do if pos(x) > at then set(x, "POSITION", f(pos(x) - gap)) end end
  end },
  { name = "ripple editing on all tracks: delete an item, everything after moves (markers and points too)", min = 3, timeline = true, edit = function()
    local it = item_named(drums, "Drums 2")
    local at, gap = pos(it), 4
    F.remove_item(it)
    for _, t in ipairs({ drums, bass, keys, gtr }) do for _, x in ipairs(items(t)) do if pos(x) > at then set(x, "POSITION", f(pos(x) - gap)) end end end
    shift_env(drums, at + 0.001, -gap)
    for _, m in ipairs(F.markers) do if m.pos > at then m.pos = m.pos - gap; if m.region then m.rend = m.rend - gap else m.rend = m.pos end end end
    F.sort_markers(); F.changed()
  end },
  { name = "duplicate items", min = 2, edit = function()
    local a, b = item_named(drums, "Drums 0"), item_named(drums, "Drums 1")
    copy(a, nil, 40); copy(b, nil, 44)
  end },
  { name = "duplicate a time selection (pieces of items)", min = 2, edit = function()
    local it = item_named(gtr, "Gtr")
    copy(it, nil, 48, function(c) set(c, "LENGTH", "2"); set(c, "SOFFS", "1") end)
  end },
  { name = "split at the time selection", min = 3, edit = function()
    local it = item_named(gtr, "Gtr")
    local p, l = pos(it), len(it)
    set(it, "LENGTH", "2")
    copy(it, nil, p + 2, function(c) set(c, "LENGTH", "2"); set(c, "SOFFS", "2") end)
    copy(it, nil, p + 4, function(c) set(c, "LENGTH", f(l - 4)); set(c, "SOFFS", "4") end)
  end },
  { name = "heal splits", min = 3, edit = function()
    local l = {}
    for _, it in ipairs(items(gtr)) do if pos(it) < 40 then l[#l + 1] = it end end
    table.sort(l, function(a, b) return pos(a) < pos(b) end)
    set(l[1], "LENGTH", "6")
    for i = 2, #l do F.remove_item(l[i]) end
  end },
  { name = "glue items", min = 3, edit = function()
    local a, b = item_named(bass, "Bass 2"), item_named(bass, "Bass 3")
    local p, e = pos(a), pos(b) + len(b)
    local g = F.add_item(bass, audio(p, e - p, "bass-glued-001.flac", "Bass 2 glued"))
    g.ext = { band_oid = a.ext.band_oid } -- (REAPER keeps the first item's P_EXT on the glued one)
    F.remove_item(a); F.remove_item(b); F.sort_items(bass)
  end },
  { name = "an item's take envelope", min = 1, edit = function()
    local it = item_named(drums, "Drums 0")
    F.set_text(it, it.text:gsub("\n>\n$", "\n<VOLENV\nEGUID {TE1}\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 1 0.25 0\n>\n>\n"))
  end },
  { name = "loop recording: one item with three takes", min = 1, edit = function()
    F.add_item(gtr, audio(56, 4, "gtr-rec1.flac", "Gtr rec 1", { takes = { { name = "Gtr rec 2", file = "gtr-rec2.flac" }, { name = "Gtr rec 3", file = "gtr-rec3.flac", sel = true } } }))
  end },
  { name = "loop recording into lanes", min = 4, edit = function()
    vox.vals.I_FREEMODE, vox.vals.I_NUMFIXEDLANES = 2, 3
    for k = 0, 2 do
      local it = F.add_item(vox, audio(64, 4, "vox-lane" .. k .. ".flac", "Vox lane " .. k))
      it.lane = k
    end
    F.changed()
  end },
  -- (REAPER check, 0.59.49.74: "Time selection: Copy contents" on a track in lanes leaves the items REAPER already had (their GUIDs, so their
  -- ids) at the copy's place, and new items, the same in every way, where they were. Undo was right; Redo brought back 4 of the 8: bringing a
  -- new one back, mirror.sits_there found "the same thing already on that lane" in its twin, which the same Redo was about to move away.)
  { name = "a time selection's contents copied on a track in lanes (the items REAPER had end up at the copy)", min = 6, timeline = true, edit = function()
    for _, it in ipairs({ table.unpack(items(vox)) }) do
      local c = copy(it, nil, pos(it))
      c.lane = it.lane
      set(it, "POSITION", f(pos(it) + 20))
    end
    F.add_marker(true, 84, 88, "Take two")
  end },
  { name = "recording with a time selection, auto-punch (the take trimmed to it)", min = 1, edit = function()
    F.add_item(bass, audio(70, 2, "bass-punch.flac", "Bass punch", { soffs = 1.5 }))
  end },
  { name = "markers and regions renumbered", min = 0, timeline = true, undo = false, edit = function()
    table.sort(F.markers, function(a, b) return a.pos < b.pos end)
    local n = { [true] = 0, [false] = 0 }
    for _, m in ipairs(F.markers) do n[m.region] = n[m.region] + 1; m.num = n[m.region] + 10 end
    F.changed()
  end },
  { name = "the region render matrix", min = 0, timeline = true, undo = false, edit = function()
    reaper.SetRegionRenderMatrix(F.proj, marker("Chorus").num, bass, 1)
    reaper.SetRegionRenderMatrix(F.proj, marker("Chorus").num, F.master, 1)
  end },
  -- (REAPER moves what's in beats when the map changes: the fixture does too, as measured on Cross Test. The moved items and points go out
  -- with the map, and every other computer must end where the desktop is whichever arrives first: REAPER check F6, below.)
  { name = "a tempo marker added under items in beats (REAPER moves what's after it), one item set to time staying", min = 1, timeline = true, edit = function()
    local last = bass.items[#bass.items]
    set(last, "BEAT", "0")
    local was = pos(last)
    reaper.SetTempoTimeSigMarker(F.proj, -1, 6, -1, -1, 100, 4, 4, false)
    assert(pos(last) == was and pos(last) > 6, "the item in time stayed")
  end },
  { name = "the first tempo changed under items in beats (REAPER moves them all)", min = 1, timeline = true, edit = function()
    local it = keys.items[#keys.items]
    local was = pos(it)
    reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 132, 4, 4, false)
    assert(math.abs(pos(it) - was) > 0.01, "REAPER moved the items in beats")
  end },
  { name = "a track template inserted (from a shared track: its items carry the studio's ids)", min = 2, full = true, edit = function()
    local t = F.add_track("Drums (template)", 3)
    local c = F.track_chunk(drums):gsub("<TRACK [^\n]*", "<TRACK " .. E.guid()):gsub("NAME \"Drums\"", "NAME \"Drums (template)\""):gsub("\nIGUID [^\n]*", "")
    F.set_track_chunk(t, c)
  end },
  -- (REAPER check, 0.59.49.72: MoveMediaItemToTrack and nothing else was never sent. The item keeps its GUID, P_EXT and chunk, only its track
  -- changes; W.one's "is this the band's version, read anew?" checks compared the band's item with the one here on the track it's on NOW, so
  -- it was taken for unchanged. This case moved and repositioned it before, which hid that.)
  { name = "an item moved to another track, nothing else changed", min = 1, edit = function()
    local it = item_named(bass, "Bass 0")
    local was = F.item_chunk(it)
    reaper.MoveMediaItemToTrack(it, gtr)
    assert(F.item_chunk(it) == was and it.track == gtr, "the move changes only its track, as REAPER's does")
    local oid = it.ext.band_oid
    local _, h, evid = mirror.known(F.proj, oid)
    local last = mirror.event_file(sync.room_dir(A.cfg, song, room), evid)
    assert(mirror.edited_here(F.proj, oid, h, last, MEDIA, false), "and reads as edited here (Restore and Undo leave an unsent move alone)")
  end },
  { name = "an item dragged to another track and along it", min = 1, edit = function()
    local it = item_named(drums, "Drums 1")
    reaper.MoveMediaItemToTrack(it, bass)
    set(it, "POSITION", "80")
  end },
  { name = "pooled MIDI copies, then the pool edited", min = 2, edit = function()
    local src = item_named(keys, "Keys A")
    F.set_text(src, src.text:gsub("<SOURCE MIDI\n", "<SOURCE MIDIPOOL\n"):gsub("CCINTERP 32\n", "CCINTERP 32\nPOOLEDEVTS {POOL1}\n"))
    copy(src, nil, 84)
    -- (one edit in the pool: every pooled copy's chunk shows it)
    for _, it in ipairs(items(keys)) do if it.text:find("{POOL1}", 1, true) then F.set_text(it, (it.text:gsub("E 0 90 40 50", "E 0 90 43 70"))) end end
  end },
  { name = "an empty item, then one with notes", min = 2, edit = function()
    F.add_item(gtr, "<ITEM\nPOSITION 90\nSNAPOFFS 0\nLENGTH 2\nLOOP 1\nALLTAKES 0\nMUTE 0 0\nSEL 0\nIID 9\n>\n")
    F.add_item(gtr, "<ITEM\nPOSITION 93\nSNAPOFFS 0\nLENGTH 2\nLOOP 1\nALLTAKES 0\nMUTE 0 0\nSEL 0\nIID 10\n<NOTES\n|Bridge: drop out here\n>\nIMGRESOURCEFLAGS 0\n>\n")
  end },
  { name = "items grouped (each computer's own), then moved together", min = 2, edit = function()
    local a, b = item_named(drums, "Drums 0"), item_named(bass, "Bass 2 glued") or item_named(bass, "Bass 2")
    reaper.SetMediaItemInfo_Value(a, "I_GROUPID", 7); reaper.SetMediaItemInfo_Value(b, "I_GROUPID", 7)
    -- (both selected, as REAPER leaves a dragged group ("selecting one grouped item selects group", its default): the quick look reads both
    -- tracks at once, so they're one act. A script moving unselected items in the middle of two tracks goes in two looks: rt-look's limit)
    select_only({ a, b })
    set(a, "POSITION", f(pos(a) + 0.25)); set(b, "POSITION", f(pos(b) + 0.25))
  end },
}

-- ---- the timeline's extras this proves: the render matrix and marker numbers read as REAPER has them ----
local function matrix_of(c)
  as(c)
  local out = {}
  for _, m in ipairs(c.F.markers) do
    if m.region then
      local l = {}
      for _, t in ipairs(c.F.matrix[m.num] or {}) do l[#l + 1] = t.is_master and "MASTER" or t.name end
      table.sort(l)
      out[#out + 1] = m.name .. "@" .. f(m.pos) .. "=" .. table.concat(l, "+")
    end
  end
  return table.concat(out, " ")
end
local function numbers_of(c)
  local out = {}
  for _, m in ipairs(c.F.markers) do out[#out + 1] = (m.region and "R" or "M") .. m.num .. ":" .. m.name end
  return table.concat(out, " ")
end

local undo = require("undo")
-- One Undo (or Redo) on the desktop whose writes cross a clock second: its third change is written in the next one. (REAPER check,
-- 0.59.49.75: an Undo that wrote 3 changes at 02:00:13 and 18 at 02:00:14 was redone as "the act has 18 changes", and two items and three
-- automation points stayed missing on every computer; Undo then stepped to an older change. An Undo's changes were grouped by their second.)
local function press(redo)
  local real_post, n = sync.post, 0
  sync.post = function(...)
    n = n + 1
    if n == 3 then tick(1) end
    return real_post(...)
  end
  local ok, res, why = pcall(undo.step, A.F.proj, A.cfg, { song = song, room = room }, redo, {})
  sync.post = real_post
  if not ok then error(res, 0) end
  return res, why
end
local renames = 0
local function run(mode)
  local quick = mode == "quick"
  for _, case in ipairs(cases) do
    local what = mode .. " | " .. case.name
    if os.getenv("RT_EDITS_TRACE") then io.stderr:write(what, "\n") end
    tick()
    local before = state(A)
    local tl_before = timeline(A)
    as(A)
    case.edit()
    tick()
    local oids, sent, kind = look(A, quick)
    local n = 0
    for _ in pairs(oids) do n = n + 1 end
    local tl = false
    for _, ev in ipairs(sent) do if ev.type == "timeline" then tl = true end end
    -- (everything the edit changed, by a full scan after it, went out: in that one look, but for what StudioSync itself made of it in the same
    -- look (takes into lanes: prints.takes_to_lanes), which goes in the next)
    settle(A, quick, oids)
    local now_st, _, now_objs = state(A)
    local missed, skip = {}, {}
    -- (not sent, by design: a track that only sits elsewhere now (the receiver works its place out as the new track lands; "same" below checks
    -- the order), and a new track's empty parts)
    for _, o in ipairs(now_objs) do if (o.kind == "track" and before[o.oid]) or (o.kind ~= "track" and o.kind ~= "item" and o.state == "") then skip[o.oid] = true end end
    for oid, h in pairs(now_st) do if before[oid] ~= h and not oids[oid] and not skip[oid] then missed[#missed + 1] = oid end end
    for oid in pairs(before) do if not now_st[oid] and not oids[oid] then missed[#missed + 1] = oid .. " (gone)" end end
    if n < math.min(case.min, 1) or #missed > 0 then
      local l = {}
      for oid, ev in pairs(oids) do l[#l + 1] = oid .. (ev.gone and " gone" or "") end
      error(what .. ": detected and sent (" .. n .. " objects, " .. kind .. " look): " .. table.concat(l, ", ") .. "; missed: " .. table.concat(missed, ", ") ..
        "\n" .. table.concat(logged, "\n", math.max(1, #logged - 5)))
    end
    if case.timeline then assert(tl, what .. ": the timeline went out") end
    -- (tracks added or removed: a full look, by design: docs/rt/rt-look.md)
    if quick then assert(kind == (case.full and "full" or "quick"), what .. ": by a " .. (case.full and "full" or "quick") .. " look (" .. kind .. ")") end
    -- (the quick look's view is what a full scan reads)
    if quick then
      local L = mirror.looks[tostring(A.F.proj)]
      for oid, h in pairs(state(A)) do assert(L.raw[oid] == h, what .. ": the quick look's view of " .. oid .. " is a full scan's") end
    end
    tick()
    recv(B)
    same(A, B, what .. ": applied the same on the laptop")
    local tl_edit = timeline(A)
    if case.name:find("render matrix", 1, true) then assert(matrix_of(A) == matrix_of(B), what .. ": " .. matrix_of(A) .. " vs " .. matrix_of(B)) end
    if case.name:find("renumbered", 1, true) then assert(numbers_of(A) == numbers_of(B), what .. ": " .. numbers_of(A) .. " vs " .. numbers_of(B)) end
    -- the laptop's own edit meanwhile, then one Ctrl+Z on the desktop
    if case.undo ~= false then
      tick()
      as(B)
      renames = renames + 1
      local bg = mirror.find(B.F.proj, "track", select(2, A.F.raw.GetSetMediaTrackInfo_String(gtr, "P_EXT:band_oid", "", false)))
      reaper.GetSetMediaTrackInfo_String(bg, "P_NAME", "Gtr " .. renames, true)
      look(B, true)
      tick()
      recv(A)
      same(A, B, what .. ": the laptop's rename came over")
      tick()
      as(A)
      local res, why = press(false)
      assert(res, what .. ": undone (" .. tostring(why) .. ")")
      settle(A, quick)
      tick()
      recv(B)
      same(A, B, what .. ": undone the same on the laptop")
      -- (and its tempo map, regions and markers: a copied region stayed on every computer after the undo. REAPER check F3)
      assert(timeline(A) == tl_before, what .. ": one Ctrl+Z put the tempo map and markers back\n" .. tl_before .. "\n" .. timeline(A))
      local after = state(A)
      local gtr_oid = select(2, A.F.raw.GetSetMediaTrackInfo_String(gtr, "P_EXT:band_oid", "", false)):upper()
      for oid, h in pairs(before) do
        if oid ~= gtr_oid then assert(after[oid] == h, what .. ": one Ctrl+Z put " .. oid .. " back (" .. tostring(h) .. " vs " .. tostring(after[oid]) .. ")") end
      end
      for oid in pairs(after) do assert(before[oid], what .. ": one Ctrl+Z took away what the edit made (" .. oid .. ")") end
      assert(gtr.name == "Gtr " .. renames, what .. ": the laptop's rename stays (" .. tostring(gtr.name) .. ")")
      -- (the Redo's bring-backs, asked one by one: each new item's place holds its twin now, which the same Redo moves away. Whichever order
      -- the plan is walked in, the twin doesn't count)
      if case.name:find("copied on a track in lanes", 1, true) then
        as(A)
        local twins = 0
        for _, ev in pairs(oids) do
          if ev.obj == "item" and ev.base == 0 and type(ev.state) == "string" and ev.state:find("BANDLANE", 1, true) then
            twins = twins + 1
            assert(mirror.sits_there(A.F.proj, ev) == true, what .. ": its twin sits on that lane (what Redo took for 'already there')")
            assert(mirror.sits_there(A.F.proj, ev, oids) == false, what .. ": a twin the plan moves away isn't 'already there'")
          end
        end
        assert(twins == 3, what .. ": three new items to bring back (" .. twins .. ")")
      end
      -- redo, so the next case builds on it (and redo is one key too)
      tick()
      as(A)
      local redone, why_not = press(true)
      assert(redone, what .. ": redone (" .. tostring(why_not) .. ")")
      settle(A, quick)
      tick()
      recv(B)
      same(A, B, what .. ": redone the same on the laptop")
      assert(timeline(A) == tl_edit, what .. ": and redo brought the tempo map and markers back\n" .. tl_edit .. "\n" .. timeline(A))
      -- (and every object the edit left: all three computers agreed on a Redo that had lost half a track's items, so nothing flagged it)
      local redone_st = state(A)
      for oid, h in pairs(now_st) do
        if oid ~= gtr_oid then assert(redone_st[oid] == h, what .. ": Redo brought " .. oid .. " back as the edit left it (" .. tostring(h) .. " vs " .. tostring(redone_st[oid]) .. ")") end
      end
      for oid in pairs(redone_st) do assert(now_st[oid], what .. ": Redo made nothing the edit hadn't (" .. oid .. ")") end
      -- and Undo steps back to the same edit again, then Redo forward (after a partial Redo, Undo went to an older change)
      tick()
      as(A)
      res, why = press(false)
      assert(res, what .. ": undone a second time (" .. tostring(why) .. ")")
      settle(A, quick)
      tick()
      recv(B)
      same(A, B, what .. ": undone a second time, the same on the laptop")
      local again = state(A)
      for oid, h in pairs(before) do
        if oid ~= gtr_oid then assert(again[oid] == h, what .. ": the second Undo put " .. oid .. " back (" .. tostring(h) .. " vs " .. tostring(again[oid]) .. ")") end
      end
      for oid in pairs(again) do assert(before[oid], what .. ": the second Undo took away what the edit made (" .. oid .. ")") end
      assert(timeline(A) == tl_before, what .. ": and its tempo map and markers")
      tick()
      as(A)
      redone, why_not = press(true)
      assert(redone, what .. ": redone a second time (" .. tostring(why_not) .. ")")
      settle(A, quick)
      tick()
      recv(B)
      same(A, B, what .. ": redone a second time, the same on the laptop")
      redone_st = state(A)
      for oid, h in pairs(now_st) do
        if oid ~= gtr_oid then assert(redone_st[oid] == h, what .. ": the second Redo brought " .. oid .. " back (" .. tostring(h) .. " vs " .. tostring(redone_st[oid]) .. ")") end
      end
      for oid in pairs(redone_st) do assert(now_st[oid], what .. ": the second Redo made nothing the edit hadn't (" .. oid .. ")") end
      assert(timeline(A) == tl_edit, what .. ": and its tempo map and markers")
    end
  end
end
for _, mode in ipairs({ "quick", "full" }) do
  build("Edits " .. mode)
  run(mode)
  -- a late joiner opens the song now and catches up from the events
  local C = computer("Cee", "C:/C/Edits " .. mode .. ".rpp")
  seed_markers(C.F)
  tick()
  recv(C)
  same(A, C, mode .. ": the late joiner caught up")
  print("rt-edits: " .. #cases .. " edits through a " .. mode .. " look, undone and redone: the same on the laptop and on a late joiner")
end

-- ---- REAPER check, 0.59.49.69: a render-matrix tick and a renumbering on the desktop ----
-- In REAPER the desktop sent both within a second; the laptop's Cross Test had Hold on, its "seen" timeline in TIMELINE_FORMAT 4, and every map
-- and marker from the band waited. Hold my changes is gone (rt-nohold): here both edits are made with no change count moved, go through Live
-- sync's pass (quick look, then the timeline's look), and the laptop, its "seen" written by the older StudioSync, takes them.
do
  local function region1(c) for _, m in ipairs(c.F.markers) do if m.region then return m end end end
  tick()
  as(A)
  local r = region1(A)
  A.F.matrix[r.num] = { keys } -- (straight into the matrix: the project's change count doesn't move)
  local oids, sent = look(A, true)
  local tev
  for _, ev in ipairs(sent) do if ev.type == "timeline" then tev = ev end end
  assert(tev, "the render matrix went out in Live sync's next pass")
  local found
  for _, m in ipairs(tev.markers) do if m.region and m.num == r.num and type(m.render) == "table" and m.render[1] then found = m.render[1] end end
  assert(found == select(2, A.F.raw.GetSetMediaTrackInfo_String(keys, "P_EXT:band_oid", "", false)), "with the track's id")
  tick()
  local old = r.num
  r.num, A.F.matrix[7], A.F.matrix[old] = 7, A.F.matrix[old], nil -- (renumbered; the row goes with the region)
  oids, sent = look(A, true)
  tev = nil
  for _, ev in ipairs(sent) do if ev.type == "timeline" then tev = ev end end
  assert(tev and (function() for _, m in ipairs(tev.markers) do if m.region and m.num == 7 then return true end end end)(), "the renumbering went out too")
  -- the laptop, its "seen" written by the older StudioSync
  as(B)
  local SEC = band.SECTION
  local seen = band.json_decode(select(2, reaper.GetProjExtState(B.F.proj, SEC, "timeline")))
  for _, m in ipairs(seen[2]) do m.num, m.render = nil, nil end
  seen[4] = 4
  reaper.SetProjExtState(B.F.proj, SEC, "timeline", band.json_encode(seen))
  tick()
  B.F.clock = B.F.clock + 1
  sync.receive(B.F.proj, B.cfg, song, room, yes)
  assert(numbers_of(B) == numbers_of(A), "the laptop took the renumbering: " .. numbers_of(A) .. " vs " .. numbers_of(B))
  assert(matrix_of(B) == matrix_of(A), "and the render matrix: " .. matrix_of(A) .. " vs " .. matrix_of(B))
  print("rt-edits: the render matrix and a renumbering go in Live sync's next pass, and land on a laptop with an older-format timeline")
end

-- ---- one act, one Undo step, however many looks find it: a script's edit to unselected items on two tracks is found one track now and the
-- other some seconds later, and a plug-in chain goes once it has held still. Each look made its own act, so Undo took two presses ----
do
  build("Edits acts")
  local function quick(c, edited_at) -- (Live sync's look, told when this person last edited)
    as(c)
    c.F.clock = c.F.clock + 1
    sync.watch_timeline(c.F.proj, c.cfg, song, room, yes)
    mirror.watch(c.F.proj, c.cfg, song, room, { can = yes, mode = "open", quick = true, edited_at = edited_at })
    return new_events()
  end
  local function muted(it) return E.top_value(it.text, "MUTE") == "1 0" end
  local b0, ka = item_named(bass, "Bass 0"), item_named(keys, "Keys A")
  -- one edit (at t_edit) on two tracks; the look finds Bass's now and Keys's four seconds later, with no edit in between
  tick()
  as(A)
  local t_edit = A.F.clock
  set(b0, "MUTE", "1 0")
  local first = quick(A, t_edit)
  assert(#first == 1 and first[1].act, "(the first track's change goes)")
  tick(3)
  A.F.clock = A.F.clock + 4
  set(ka, "MUTE", "1 0") -- (as the look comes to it only now)
  local second = quick(A, t_edit)
  assert(#second == 1 and second[1].act == first[1].act, "what a later look finds with no edit since is the same act")
  tick()
  recv(B)
  tick()
  as(A)
  assert(press(false), "one Undo")
  assert(not muted(b0) and not muted(ka), "takes back both tracks' changes")
  settle(A, true)
  tick()
  recv(B)
  same(A, B, "an act found by two looks, undone in one step")
  -- an edit of yours after the first look is another act: Undo takes back only that
  tick()
  as(A)
  local t1 = A.F.clock
  set(b0, "MUTE", "1 0")
  first = quick(A, t1)
  tick(3)
  A.F.clock = A.F.clock + 4
  local t2 = A.F.clock
  set(ka, "MUTE", "1 0")
  second = quick(A, t2)
  assert(#first == 1 and #second == 1 and second[1].act ~= first[1].act, "an edit made after the look is an act of its own")
  tick()
  as(A)
  assert(press(false), "one Undo")
  assert(muted(b0) and not muted(ka), "takes back only the later edit")
  -- and not a minute later: what turns up then isn't the old act's
  settle(A, true)
  tick()
  as(A)
  set(ka, "MUTE", "1 0")
  first = quick(A, t2)
  A.F.clock = A.F.clock + mirror.ACT_KEEP + 5
  set(b0, "MUTE", "0 0")
  second = quick(A, t2)
  assert(#first == 1 and #second == 1 and second[1].act ~= first[1].act, "nor over a minute after that look")
  -- (backlog 1.10, rt-p1) a heavy song's timed full looks come up to QUICK_FULL_MAX apart: what the next one finds is still the act's, then not
  settle(A, true)
  tick()
  as(A)
  local L = mirror.looks[tostring(A.F.proj)]
  local took = L.full_took
  L.full_took = mirror.QUICK_FULL_MAX * mirror.QUICK_FULL_SHARE -- (a full look this long: the next one five minutes on)
  local t3 = A.F.clock
  set(ka, "MUTE", "0 0")
  first = quick(A, t3)
  A.F.clock = A.F.clock + mirror.ACT_KEEP + 5
  set(b0, "MUTE", "1 0")
  second = quick(A, t3)
  assert(#first == 1 and #second == 1 and second[1].act == first[1].act, "a heavy song: found a minute on, before its next full look: the same act")
  A.F.clock = A.F.clock + mirror.QUICK_FULL_MAX + mirror.ACT_KEEP
  set(ka, "MUTE", "1 0")
  local third = quick(A, t3)
  assert(#third == 1 and third[1].act ~= first[1].act, "and not past that full look")
  L = mirror.looks[tostring(A.F.proj)]
  L.full_took = took
  settle(A, true)
  tick()
  recv(B)
  same(A, B, "acts")
  print("rt-edits: what later looks find with no edit of yours since is the same act, one Undo step")
end

-- ---- Undo steps back an act that is only a timeline change (fix G's limit): a marker added and nothing else was stepped over, and Undo took
-- back the edit before it ----
do
  build("Edits marker undo")
  local function has(c, name) for _, m in ipairs(c.F.markers) do if m.name == name then return true end end return false end
  local function both(what, want)
    settle(A, true)
    tick()
    recv(B)
    assert(has(A, "Solo") == want and has(B, "Solo") == want, what .. " (desktop " .. tostring(has(A, "Solo")) .. ", laptop " .. tostring(has(B, "Solo")) .. ")")
    same(A, B, what)
  end
  -- an edit first, then a marker by itself
  tick()
  as(A)
  set(item_named(bass, "Bass 1"), "MUTE", "1 0")
  tick()
  both("(an item muted)", false)
  tick()
  as(A)
  A.F.add_marker(false, 9, 9, "Solo")
  tick()
  both("(a marker added, nothing else)", true)
  tick()
  as(A)
  local res, why = press(false)
  assert(res, "Undo takes the marker back (" .. tostring(why) .. ")")
  assert(E.top_value(item_named(bass, "Bass 1").text, "MUTE") == "1 0", "and not the edit before it")
  tick()
  both("the marker undone", false)
  tick()
  as(A)
  res, why = press(true)
  assert(res, "Redo brings it back (" .. tostring(why) .. ")")
  tick()
  both("the marker redone", true)
  tick()
  as(A)
  assert(press(false), "Undo again")
  tick()
  both("the marker undone again", false)
  -- the next Undo is the edit before it
  tick()
  as(A)
  res, why = press(false)
  assert(res and E.top_value(item_named(bass, "Bass 1").text, "MUTE") ~= "1 0", "the next Undo steps back the edit before the marker (" .. tostring(res or why) .. ")")
  tick()
  both("the edit before it undone", false)
  -- and a marker sent with an act's items still goes back with them, as one step
  tick()
  as(A)
  A.F.add_marker(false, 9, 9, "Solo")
  set(item_named(bass, "Bass 2"), "MUTE", "1 0")
  tick()
  both("(a marker and an item in one act)", true)
  tick()
  as(A)
  assert(press(false), "one Undo")
  assert(not has(A, "Solo") and E.top_value(item_named(bass, "Bass 2").text, "MUTE") ~= "1 0", "takes back the marker and the item together")
  tick()
  both("a marker and an item undone together", false)
  tick()
  as(A)
  assert(press(true), "one Redo")
  assert(has(A, "Solo") and E.top_value(item_named(bass, "Bass 2").text, "MUTE") == "1 0", "brings both back")
  tick()
  both("a marker and an item redone together", true)
  -- (round 5) a marker of yours a bandmate took away since: Undo has nothing to take back, says so once, and the next press is the change
  -- before it (every press stopped there)
  local function lone(c) for _, m in ipairs(c.F.markers) do if m.name == "Lone" then return m end end end
  tick()
  as(A)
  set(item_named(bass, "Bass 3"), "MUTE", "1 0")
  tick()
  both("(an item muted)", true)
  tick()
  as(A)
  A.F.add_marker(false, 11, 11, "Lone")
  tick()
  both("(a lone marker)", true)
  as(B)
  local m = lone(B)
  reaper.DeleteProjectMarker(B.F.proj, m.num, false)
  tick()
  settle(B, true)
  tick()
  recv(A)
  assert(not lone(A), "(the laptop took it away, everywhere)")
  tick()
  as(A)
  res, why = press(false)
  assert(not res and tostring(why):find("changed since", 1, true), "nothing to take back of it: says so (" .. tostring(res or why) .. ")")
  tick()
  as(A)
  res, why = press(false)
  assert(res and E.top_value(item_named(bass, "Bass 3").text, "MUTE") ~= "1 0" and not lone(A), "the next Undo is the change before it (" .. tostring(res or why) .. ")")
  tick()
  both("the change before it undone", true)
  -- and a Restore's timeline isn't a change Undo steps back: the change before it is
  tick()
  as(A)
  set(item_named(bass, "Bass 0"), "MUTE", "1 0")
  tick()
  both("(another item muted)", true)
  tick()
  as(A)
  local all = require("recall").entries(A.cfg, song, room)
  assert(sync.restore_timeline(A.F.proj, A.cfg, song, room, all, 1, proxy.read_json(proxy.session_path(A.cfg, song))), "(a Restore puts an older timeline back)")
  tick()
  as(A)
  res, why = press(false)
  assert(res and E.top_value(item_named(bass, "Bass 0").text, "MUTE") ~= "1 0", "Undo after a Restore steps back the change before it, not the Restore (" .. tostring(res or why) .. ")")
  print("rt-edits: Undo and Redo step an act that is only a marker or tempo change")
end

-- ---- a marker or tempo change made right after updating, before Live sync's first look in the new version (fix E's limit): the note of
-- the last look is in the older format, which read as a first look, so the change was taken in and never sent ----
do
  build("Edits update")
  local SEC = band.SECTION
  local function older(c) -- (the last look's note, as the version before wrote it: format 5, markers without numbers or render rows)
    as(c)
    local seen = band.json_decode(select(2, reaper.GetProjExtState(c.F.proj, SEC, "timeline")))
    for _, m in ipairs(seen[2]) do m.num, m.render = nil, nil end
    seen[4] = 5
    reaper.SetProjExtState(c.F.proj, SEC, "timeline", band.json_encode(seen))
  end
  local function timelines(sent) local t = {}; for _, ev in ipairs(sent) do if ev.type == "timeline" then t[#t + 1] = ev end end return t end
  local function has(c, name) for _, m in ipairs(c.F.markers) do if m.name == name then return true end end return false end
  -- nothing changed across the update: the first look in the new version is still not an edit
  older(B)
  tick()
  local _, sent = look(B, true)
  assert(#timelines(sent) == 0, "the first look after updating isn't taken for an edit")
  as(B)
  assert(band.json_decode(select(2, reaper.GetProjExtState(B.F.proj, SEC, "timeline")))[4] == sync.TIMELINE_FORMAT, "(and the note is in this version's format now)")
  -- a marker added between the older version's last look and this one's first: it goes out
  older(B)
  B.F.add_marker(false, 21, 21, "After update")
  tick()
  _, sent = look(B, true)
  local went = timelines(sent)
  assert(#went == 1, "a marker added right after updating goes out at the first look (" .. #went .. ")")
  tick()
  recv(A)
  assert(has(A, "After update"), "and reaches the desktop")
  same(A, B, "a marker added across the update")
  -- a tempo change likewise
  older(B)
  as(B)
  reaper.SetTempoTimeSigMarker(B.F.proj, 0, 0, -1, -1, 96, 4, 4, false)
  tick()
  local all = {}
  for _ = 1, 3 do _, sent = look(B, true); for _, ev in ipairs(timelines(sent)) do all[#all + 1] = ev end end
  assert(#all == 1 and all[1].tempo[1].bpm == 96, "a tempo change made right after updating goes out too (" .. #all .. ")")
  tick()
  recv(A)
  as(A)
  assert(band.capture_tempo(A.F.proj)[1].bpm == 96, "and reaches the desktop")
  print("rt-edits: a marker or tempo change made right after updating goes out at the new version's first look")
end

-- ---- REAPER check F6, 0.59.49.73: a tempo change left the receivers different ----
-- A 100 bpm marker at 8 s on the desktop: REAPER moved what's in beats after it, and the desktop sent the map and the moved items and points.
-- The laptop got the map first and ended the same. LinuxBox got the items and points first (they go as messages on the link; the map came as
-- a file), put them where the new map has them, and then its REAPER moved them again when the map landed: lengths scaled twice (4.615 s on the
-- desktop, 5.815 s there), and nothing put them right. Now each change made while REAPER moves things for a map says which map (`tl`), and a
-- receiver lands it only once it holds that map; the map goes as a message too.
do
  build("Edits tempo")
  local X, Y, Z = computer("Linus", "C:/X/Edits tempo.rpp"), computer("Yan", "C:/Y/Edits tempo.rpp"), computer("Zed", "C:/Z/Edits tempo.rpp")
  -- (Zed's REAPER writes items its own way, as LinuxBox's does: the same items, another text, so other hashes. Its records are its own readings.)
  Z.F.dialect = function(c) return (c:gsub("\nCHANMODE 0\n", "\nCHANMODE 0 0\n")) end
  for _, c in ipairs({ X, Y }) do seed_markers(c.F); tick(); recv(c); same(A, c, "tempo order: " .. c.cfg.user .. " has the song") end
  seed_markers(Z.F); tick(); recv(Z)
  -- every item and point where the desktop has it, by place and length (Zed's text differs, so not by hash), and the same timeline
  local function same_timing(what)
    local function places(c)
      local _, _, objs = state(c)
      local out = {}
      for _, o in ipairs(objs) do
        if o.kind == "item" then out[o.oid] = o.track .. " " .. tostring(o.state:match("POSITION [^\n]*")) .. " " .. tostring(o.state:match("LENGTH [^\n]*"))
        elseif o.kind == "env" then out[o.oid] = o.state end
      end
      return out
    end
    local pa, pz = places(A), places(Z)
    for oid, v in pairs(pa) do assert(pz[oid] == v, what .. ": " .. oid .. " is where the desktop has it (" .. tostring(v) .. " vs " .. tostring(pz[oid]) .. ")") end
    for oid in pairs(pz) do assert(pa[oid], what .. ": nothing the desktop hasn't (" .. oid .. ")") end
    assert(timeline(A) == timeline(Z), what .. ": the same tempo map and markers")
  end
  same_timing("tempo order: Zed has the song")
  local edir = sync.room_dir(A.cfg, song, room) .. "/events"
  local function len_of(c, name) for _, t in ipairs(c.F.tracks) do for _, it in ipairs(t.items) do if it.text:find('NAME "' .. name .. '"', 1, true) then return tonumber(E.top_value(it.text, "LENGTH")) end end end end
  local function tempo_edit(what, edit)
    tick()
    as(A)
    edit()
    tick()
    local oids, sent = look(A, true)
    settle(A, true, oids)
    local map
    for _, ev in ipairs(sent) do if ev.type == "timeline" then map = ev end end
    assert(map and next(oids), what .. ": the map and what REAPER moved went out")
    for oid, ev in pairs(oids) do assert(type(ev.tl) == "string" and ev.tl:find(map.id, 1, true), what .. ": " .. oid .. " says which map it was made under") end
    tick()
    recv(B) -- (the laptop: the map first, as its file sorts)
    same(A, B, what .. ": the laptop, map first")
    -- LinuxBox: the items and points are here, the map's file isn't yet
    local before = state(X)
    hidden[edir .. "/" .. map.id .. ".json"] = true
    as(X)
    X.F.clock = X.F.clock + 1
    sync.receive(X.F.proj, X.cfg, song, room, yes)
    for oid, h in pairs(state(X)) do assert(before[oid] == h, what .. ": nothing lands on LinuxBox before its map (" .. oid .. ")") end
    hidden[edir .. "/" .. map.id .. ".json"] = nil
    tick()
    recv(X)
    same(A, X, what .. ": LinuxBox, the items and points first")
    -- a fourth, as LinuxBox got it: the map lands alone, looks run, the items and points trickle in with more looks between, and its REAPER
    -- writes items its own way. What its REAPER moved when the map landed is never its edit: nothing goes out and nothing is refused or put
    -- back, at any look. (REAPER checks: 0.59.49.74, both receivers sent their own copies, "...as you did, at the same time: both changes are
    -- kept"; 0.59.49.75, LinuxBox still asked the track's claimer to let it "edit" and put eight "edits" back at each tempo step, as the
    -- compare was with the sender's text.)
    local list = {}
    for _, ev in pairs(oids) do list[#list + 1] = ev; hidden[edir .. "/" .. ev.id .. ".json"] = true end
    table.sort(list, function(a, b) return a.id < b.id end)
    local function quiet(when)
      local refused = 0
      local opts = { can = function() refused = refused + 1; return false end, mode = "open", quick = true } -- (it may edit nothing: an edit would be refused)
      as(Z)
      Z.F.clock = Z.F.clock + 1
      sync.watch_timeline(Z.F.proj, Z.cfg, song, room, yes)
      local back0 = select(2, mirror.watch(Z.F.proj, Z.cfg, song, room, opts)) or 0
      local zsent = new_events()
      assert(#zsent == 0 and back0 == 0, what .. ", " .. when .. ": what REAPER moved as the map landed isn't that computer's edit (" .. #zsent .. " sent, " .. back0 .. " put back)")
    end
    as(Z)
    Z.F.clock = Z.F.clock + 1
    sync.receive(Z.F.proj, Z.cfg, song, room, yes)
    quiet("the map alone")
    quiet("a second look")
    for i, ev in ipairs(list) do
      hidden[edir .. "/" .. ev.id .. ".json"] = nil
      if i == #list // 2 or i == #list then
        as(Z)
        Z.F.clock = Z.F.clock + 1
        sync.receive(Z.F.proj, Z.cfg, song, room, yes)
        quiet(i == #list and "all of them here" or "half the items here")
      end
    end
    same_timing(what .. ": the map first, looks, then the items and points a few at a time")
    return map, oids
  end
  local l0 = len_of(A, "Gtr")
  local map, oids = tempo_edit("a 100 bpm marker at 6 s", function() reaper.SetTempoTimeSigMarker(F.proj, -1, 6, -1, -1, 100, 4, 4, false) end)
  local l1 = len_of(A, "Gtr")
  assert(math.abs(l1 - l0 * 1.2) < 1e-6 or l1 > l0, "REAPER stretched the item across the marker (" .. l0 .. " -> " .. l1 .. ")")
  -- the way it went wrong, on a fourth computer: the same changes as 0.59.49.73 sent them (no map named), the map's file after them
  for oid in pairs(oids) do
    -- (nor the map itself, `tm`: since rt-converge a version carries it and lands on its beat whenever it comes, tests/test_0_60_rt_converge.lua)
    for path, ev in pairs(files) do if type(ev) == "table" and ev.oid == oid and ev.tl then ev.tl, ev.tm = nil, nil end end
  end
  hidden[edir .. "/" .. map.id .. ".json"] = true
  sync.ev_cache = {} -- (the stand-in computers share one memory of the files read and still waiting: Yan reads them afresh, without the stamp)
  as(Y)
  Y.F.clock = Y.F.clock + 1
  sync.receive(Y.F.proj, Y.cfg, song, room, yes)
  hidden[edir .. "/" .. map.id .. ".json"] = nil
  Y.F.clock = Y.F.clock + 1
  sync.receive(Y.F.proj, Y.cfg, song, room, yes)
  local l2 = len_of(Y, "Gtr")
  assert(l2 > l1 + 0.1, "without the stamp the stand-in REAPER does what REAPER did: the length scaled twice (" .. l1 .. " on the desktop, " .. l2 .. " there)")
  -- the first tempo, then both put back: the same on the laptop and on LinuxBox each time
  tempo_edit("the first tempo to 110", function() reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 110, 4, 4, false) end)
  tempo_edit("the first tempo back", function() reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 120, 4, 4, false) end)
  tempo_edit("the marker taken out", function() reaper.DeleteTempoTimeSigMarker(F.proj, 1) end)
  assert(math.abs(len_of(A, "Gtr") - l0) < 1e-9 and math.abs(len_of(X, "Gtr") - l0) < 1e-9, "and back where it all began")
  -- a change whose map never comes still lands, after sync.MAP_WAIT
  tick()
  as(A)
  local it = A.F.tracks[1].items[1]
  A.F.set_text(it, E.set_top(E.set_top(it.text, "MUTE", "1 0"), "SEL", "1"))
  local o2 = look(A, true)
  local stuck = o2[it.ext.band_oid]
  assert(stuck, "an edit went out")
  files[edir .. "/" .. stuck.id .. ".json"].tl = "9999-01-01T00:00:00ZNobody-1"
  as(X)
  X.F.clock = X.F.clock + 1
  sync.receive(X.F.proj, X.cfg, song, room, yes)
  assert(state(X)[stuck.oid] ~= state(A)[stuck.oid], "it waits for its map")
  as(X)
  X.F.clock = X.F.clock + sync.MAP_WAIT + 1
  sync.receive(X.F.proj, X.cfg, song, room, yes)
  assert(state(X)[stuck.oid] == state(A)[stuck.oid], "and lands without it after " .. sync.MAP_WAIT .. " s")
  print("rt-edits: tempo changes end the same whichever comes first, the map or what REAPER moved for it")
end

-- ---- REAPER check F7, 0.59.49.73: the desktop had lost the Verse region ----
-- Its REAPER restarted and reopened a project file from the day before (Cross Test.rpp was never saved since). The file had noted its timeline
-- in an older TIMELINE_FORMAT, which read as a first look, so the "opened behind the song" look at session.json was skipped; the autosave after
-- shows the newest map's stamp, its event marked done, and no region. Its next marker edit would have dropped the region for everyone.
do
  build("Edits reopen")
  tick()
  local saved = A.F.save() -- (the file on the desktop's disk: never saved again)
  as(A)
  F.add_marker(true, 20, 28, "Bridge")
  tick()
  look(A, true)
  tick()
  recv(B)
  same(A, B, "reopen: the Bridge region is the studio's")
  local SEC = band.SECTION
  local function has(c, name) for _, m in ipairs(c.F.markers) do if m.name == name then return true end end return false end
  local function reopen() return { F = E.open(A.F.path, saved), cfg = A.cfg } end
  local function no_timeline(sent, what) for _, ev in ipairs(sent) do assert(ev.type ~= "timeline", what) end end
  local function said(text) for _, l in ipairs(logged) do if l:find(text, 1, true) then return true end end end
  -- (the studio's newest timeline is the desktop's own, in the file it keeps of the last one it sent: rooms/main/timeline/James.json)
  local sp = sync.timeline_path(A.cfg, song, room, A.cfg.user)
  assert(type(files[sp]) == "table" and type(files[sp].order) == "string" and sync.studio_timeline(A.cfg, song, room).timeline_order == files[sp].order,
    "the desktop's timeline file has the map's stamp")
  -- 1. noted in an older format, the studio's timeline newer: the studio's at its first look, before anything of its own may go
  local D = reopen()
  as(D)
  local seen = band.json_decode(select(2, reaper.GetProjExtState(D.F.proj, SEC, "timeline")))
  seen[4] = 5
  for _, m in ipairs(seen[2]) do m.num, m.render = nil, nil end
  reaper.SetProjExtState(D.F.proj, SEC, "timeline", band.json_encode(seen))
  assert(not has(D, "Bridge"), "the reopened file is from before the region")
  D.F.add_marker(false, 50, 50, "Mine") -- (and a marker added the moment it opened)
  tick()
  logged = {}
  local _, sent = look(D, true)
  assert(has(D, "Bridge"), "an older file reopened after an update takes the studio's timeline at its first look")
  -- (the marker added as it opened is kept on top of the studio's, and goes out with the studio's region in it: never the stale file's list.
  -- It was dropped and the log didn't say. Backlog 1)
  assert(has(D, "Mine"), "a marker added as the project opened is kept when the studio's newer timeline replaces the file's")
  assert(said("the studio's newer tempo map and markers landed before your own change had gone out. Kept on top of theirs: 1 marker(s) or region(s) you added"),
    "and the log says so")
  local went = {}
  for _, ev in ipairs(sent) do if ev.type == "timeline" then went[#went + 1] = ev end end
  assert(#went == 1, "it goes out once (" .. #went .. ")")
  local in_it = {}
  for _, m in ipairs(went[1].markers) do in_it[m.name] = true end
  assert(in_it.Bridge and in_it.Mine and in_it.Verse, "with the studio's region and yours")
  tick()
  recv(D)
  tick()
  recv(B)
  assert(has(B, "Mine") and has(B, "Bridge"), "the laptop gets it and keeps the region")
  same(D, B, "reopen 1: as the studio, with the marker")
  -- 2. as the desktop's autosave was: the newest map's stamp, its event marked done, none of its markers
  local D2 = reopen()
  as(D2)
  reaper.SetProjExtState(D2.F.proj, sync.NEWEST, "timeline", files[sp].order)
  for path, ev in pairs(files) do
    if type(ev) == "table" and ev.type == "timeline" and path:find("/" .. song .. "/", 1, true) then reaper.SetProjExtState(D2.F.proj, sync.APPLIED, ev.id, "1") end
  end
  reaper.SetProjExtState(D2.F.proj, SEC, "timeline", sync.timeline_sig(D2.F.proj))
  tick()
  _, sent = look(D2, true)
  assert(has(D2, "Bridge"), "a project that counts the newest map as here but doesn't hold it gets it")
  no_timeline(sent, "and that isn't a change of its own")
  tick()
  recv(D2)
  same(D2, B, "reopen 2: as the studio")
  _, sent = look(D2, true)
  no_timeline(sent, "once: nothing more")
  -- 3. no timeline file here yet, a marker added before its first catch-up is done: nothing of the timeline goes out until it has caught up
  local D3 = reopen()
  as(D3)
  local keep = files[sp]
  files[sp] = nil
  sync.loading[tostring(D3.F.proj)] = true
  tick()
  look(D3, true)
  D3.F.add_marker(false, 60, 60, "Mine too")
  tick()
  _, sent = look(D3, true)
  no_timeline(sent, "a stale file's markers don't go out with your edit before it has caught up")
  D3.F.clock = D3.F.clock + 1
  logged = {}
  sync.receive(D3.F.proj, D3.cfg, song, room, yes)
  sync.loading[tostring(D3.F.proj)] = nil
  files[sp] = keep
  assert(has(D3, "Bridge"), "caught up: the studio's region is here")
  -- (the newer timeline landed whole and the marker went with it, unsaid. Backlog 1)
  assert(has(D3, "Mine too"), "and the marker added in those first seconds is still here")
  assert(said("newer tempo map and markers landed before your own change had gone out. Kept on top of theirs: 1 marker(s) or region(s) you added"),
    "the log says it was kept")
  tick()
  _, sent = look(D3, true)
  tick()
  recv(B)
  assert(has(B, "Bridge") and has(B, "Mine too"), "the laptop still has the region, and gets the marker")
  same(D3, B, "reopen 3: as the studio, with the marker")
  print("rt-edits: a project reopened behind the studio's timeline takes it before anything of its own goes out")
end

-- ---- REAPER check, 0.59.49.75: an Undo was short because a bandmate had auto-claimed the track since ----
-- "19 brought back (2 not yours to change)": the laptop held an auto-claim on XT Drums A, made after the desktop's copy had gone out, so the
-- copy's item there stayed on every computer. An auto-claim doesn't block an edit that merges (364c039); taking back your own change, when the
-- newest version of the thing is still yours, has nothing of the claimer's in it, so it goes through, here and on the computers that receive
-- it. A lasting claim still refuses.
do
  build("Edits claim")
  local claimask = require("claimask")
  local function has(c, name) for _, t in ipairs(c.F.tracks) do for _, x in ipairs(t.items) do if x.text:find('NAME "' .. name .. '"', 1, true) then return true end end end return false end
  local function session() return proxy.read_json(proxy.session_path(A.cfg, song)) end
  tick()
  as(A)
  F.add_item(bass, audio(50, 2, "bass-extra.flac", "Bass extra"))
  tick()
  look(A, true)
  settle(A, true)
  tick()
  recv(B)
  assert(has(B, "Bass extra"), "the desktop's new item is on the laptop")
  -- the laptop auto-claims Bass after that
  local iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local cpath = sync.claims_path(B.cfg, song, room, "Bee")
  files[cpath] = { user = "Bee", time = iso, tracks = { "Bass" }, regions = {}, since = { ["tracks:bass"] = iso }, auto = { ["tracks:bass"] = iso } }
  as(A)
  A.F.clock = A.F.clock + 100
  local can, who = sync.authority(A.cfg, song, room, session())
  assert(can("James", "Bass", 50) == false and claimask.soft(who, "Bass", 50, "James") == "Bee", "Bass is the laptop's now, by an auto-claim")
  tick()
  local res, why = press(false)
  assert(res and not has(A, "Bass extra"), "one Undo takes the desktop's own item back past the auto-claim (" .. tostring(res or why) .. ")")
  assert(not tostring(res):find("not yours", 1, true), "none refused: " .. tostring(res))
  -- the laptop goes by the same claims: the deletion lands at once, not after the minute a refused change waits
  as(B)
  B.F.clock = B.F.clock + 100
  local can_b, who_b = sync.authority(B.cfg, song, room, session())
  local gone
  for _, ev in ipairs(new_events()) do if ev.gone and ev.user == "James" then gone = ev end end
  assert(gone and gone.undoes and can_b("James", gone.name, gone.pos) == false, "the deletion is an Undo's, of something on a track the laptop claims")
  sync.soft = { room = room, fn = function(name, pos, user) return claimask.soft(who_b, name, pos, user) end }
  sync.receive(B.F.proj, B.cfg, song, room, can_b)
  assert(not has(B, "Bass extra"), "it lands on the laptop at once")
  sync.soft = nil
  -- a lasting claim refuses, as ever: an item of the desktop's muted while Bass was free, then Bass claimed for good, then Undo
  files[cpath] = nil
  as(A)
  A.F.clock = A.F.clock + 100
  tick()
  local mine = item_named(bass, "Bass 0")
  set(mine, "MUTE", "1 0")
  set(mine, "SEL", "1")
  tick()
  look(A, true)
  settle(A, true)
  files[cpath] = { user = "Bee", time = iso, tracks = { "Bass" }, regions = {}, since = { ["tracks:bass"] = iso } }
  A.F.clock = A.F.clock + 100
  can, who = sync.authority(A.cfg, song, room, session())
  assert(can("James", "Bass", 0.5) == false and claimask.soft(who, "Bass", 0.5, "James") == nil, "a lasting claim now")
  tick()
  res, why = press(false)
  assert(E.top_value(mine.text, "MUTE") == "1 0" and tostring(res or why):find("not yours", 1, true), "Undo on a lastingly claimed track is refused: " .. tostring(res or why))
  files[cpath] = nil
  print("rt-edits: an Undo of your own change goes past a bandmate's auto-claim made since; a lasting claim still refuses")
end

-- ---- the studio's timeline, one file per computer (James, 2026-11-20: no file that several computers write) ----
-- session.json's timeline was written by whichever computer changed it: two within a second or two left a session.sync-conflict copy, and the
-- hub set session.json aside as written by another computer than its sharer's. Now each computer keeps the last timeline it sent in
-- rooms/<room>/timeline/<user>.json; the newest stamp is the studio's. session.json's is still read, and still written while a build that
-- only reads that is here.
do
  build("Edits files")
  local sj = proxy.session_path(A.cfg, song)
  local rdir = sync.room_dir(A.cfg, song, room)
  local function tfile(user, r) return files[sync.timeline_path(A.cfg, song, r or room, user)] end
  local sj0 = band.json_encode(files[sj])
  assert(type(tfile("James")) == "table" and type(tfile("Bee")) == "table", "each computer's own file says it reads these, from its first look")
  assert(sync.studio_timeline(A.cfg, song, room) and sync.studio_timeline(A.cfg, song, room).timeline_order == nil, "nothing sent yet: session.json's own, unstamped")
  -- the desktop changes the timeline: its own file, session.json untouched
  as(A)
  F.add_marker(false, 40, 40, "One")
  tick()
  look(A, true)
  local mine = tfile("James")
  assert(mine.user == "James" and type(mine.order) == "string" and #mine.markers == 4 and #mine.tempo == 1, "the desktop's timeline is in its own file")
  assert(band.json_encode(files[sj]) == sj0, "and session.json isn't written: everyone here reads the files")
  assert(sync.studio_timeline(A.cfg, song, room).timeline_order == mine.order, "the studio's newest is the desktop's")
  tick()
  recv(B)
  -- the laptop changes it next: its own file; the newest stamp wins
  as(B)
  B.F.add_marker(false, 42, 42, "Two")
  tick()
  look(B, true)
  local theirs = tfile("Bee")
  assert(theirs.user == "Bee" and theirs.order > mine.order and #theirs.markers == 5, "the laptop's is in the laptop's file")
  assert(band.json_encode(tfile("James")) == band.json_encode(mine), "the desktop's file is the desktop's alone")
  local st = sync.studio_timeline(A.cfg, song, room)
  assert(st.timeline_order == theirs.order and st.by == "Bee" and #st.markers == 5, "the newest stamp is the studio's timeline")
  assert(band.json_encode(files[sj]) == sj0, "session.json still untouched")
  tick()
  recv(A)
  same(A, B, "files: the same timeline")
  -- someone on a build that only reads session.json is here (they have no file): session.json's timeline is written too, as before
  files[rdir .. "/status/Old-Mac.json"] = { user = "Old-Mac", time = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  as(A)
  A.F.clock = math.max(A.F.clock, B.F.clock) + 100 -- (past presence's one-second memory of who's here, which the stand-in computers share)
  assert(sync.timeline_old_readers(A.cfg, song, room) == true, "an older build is here")
  F.add_marker(false, 44, 44, "Three")
  tick()
  look(A, true)
  assert(files[sj].timeline_order == tfile("James").order and #files[sj].markers == 6 and type(files[sj].first_timeline) == "table",
    "with an older build here the timeline goes into session.json too")
  -- and what that build writes there, newer than any file, is read as the studio's
  local keep = band.json_encode(files[sj])
  files[sj].timeline_order, files[sj].markers = "9998-01-01T00:00:00ZOld-Mac-1", {}
  st = sync.studio_timeline(A.cfg, song, room)
  assert(st.timeline_order == "9998-01-01T00:00:00ZOld-Mac-1" and #st.markers == 0, "session.json's timeline is still read when it's the newest")
  files[sj] = band.json_decode(keep)
  files[rdir .. "/status/Old-Mac.json"] = nil
  A.F.clock = A.F.clock + 100
  assert(sync.timeline_old_readers(A.cfg, song, room) == false, "gone again")
  -- a side room's timeline has files of its own and never goes into session.json (it was read there as the main room's)
  keep = band.json_encode(files[sj])
  sync.session_timeline(A.cfg, song, { { time = 0, bpm = 90, num = 4, denom = 4, linear = false } }, {}, "9997-01-01T00:00:00ZJames-1", nil, "side")
  assert(band.json_encode(files[sj]) == keep and tfile("James", "side").order == "9997-01-01T00:00:00ZJames-1", "a side room's goes to the side room's file only")
  assert(sync.studio_timeline(A.cfg, song, "side").tempo[1].bpm == 90 and sync.studio_timeline(A.cfg, song, room).timeline_order == tfile("James").order,
    "each room reads its own")
  -- a file that says it's someone else's than its name is left out
  files[rdir .. "/timeline/Mallory.json"] = { user = "James", order = "9999-12-31T00:00:00ZMallory-1", tempo = { { time = 0, bpm = 60, num = 4, denom = 4, linear = false } }, markers = {} }
  assert(sync.studio_timeline(A.cfg, song, room).timeline_order == tfile("James").order, "a file not named for who it says it is isn't read")
  files[rdir .. "/timeline/Mallory.json"] = nil
  tick()
  recv(B)
  same(A, B, "files: the same timeline at the end")
  print("rt-edits: the studio's timeline is one file per computer; session.json's only while an older build is here")
end

-- ---- REAPER check, 0.59.49.74: the marker-colour echo ----
-- The desktop made a marker with the default colour. Both computers have SWS's auto marker colouring on with the rule "any marker": the
-- laptop's SWS coloured the marker a moment after it landed (22955745 where 0 came), the laptop read that as its own timeline change and sent
-- it; the desktop's SWS did the same to its own. Three timeline changes in two seconds, two computers writing session.json. Now SWS's auto
-- marker and region colouring are off while a studio song is in front, as its auto track colouring always was (band.sws_colours).
do
  build("Edits sws")
  local function timelines(sent) local n = 0; for _, ev in ipairs(sent) do if ev.type == "timeline" then n = n + 1 end end; return n end
  local function colour_of(c, name) for _, m in ipairs(c.F.markers) do if m.name == name then return m.color end end end
  for _, c in ipairs({ A, B }) do
    as(c)
    c.F.sws["_SWSAUTOCOLOR_ENABLE"], c.F.sws["_S&MAUTOCOLOR_MKR_ENABLE"], c.F.sws["_S&MAUTOCOLOR_RGN_ENABLE"] = false, true, true
    reaper.SetProjExtState(c.F.proj, band.SECTION, "song", song) -- (a studio song, in front)
  end
  -- as it went: the laptop's SWS colours what landed, and the laptop sends that as a change of its own
  as(A)
  band.sws_colours()
  assert(A.F.sws["_S&MAUTOCOLOR_MKR_ENABLE"] == false and reaper.GetExtState(band.SECTION, "sws marker colour off") == "1", "the desktop: SWS's marker colouring off, and noted as StudioSync's doing")
  F.add_marker(false, 30, 30, "Echo")
  tick()
  local _, sent = look(A, true)
  assert(timelines(sent) == 1, "the marker went out")
  as(B)
  B.F.clock = B.F.clock + 1
  sync.receive(B.F.proj, B.cfg, song, room, yes)
  assert(colour_of(B, "Echo") == 0, "it landed with the default colour")
  assert(B.F.sws_tick() >= 1 and colour_of(B, "Echo") == 22955745, "the laptop's SWS, still on, colours it: the stand-in does what SWS did")
  _, sent = look(B, true)
  assert(timelines(sent) == 1, "and the laptop sends that back as its own timeline change: the echo")
  tick()
  recv(A)
  -- with the switch: nothing colours it, nothing comes back
  as(B)
  band.sws_colours()
  assert(B.F.sws["_S&MAUTOCOLOR_MKR_ENABLE"] == false and B.F.sws["_S&MAUTOCOLOR_RGN_ENABLE"] == false, "the laptop: SWS's marker and region colouring off")
  as(A)
  F.add_marker(false, 34, 34, "Quiet")
  tick()
  _, sent = look(A, true)
  assert(timelines(sent) == 1, "the second marker went out")
  for _ = 1, 3 do
    for _, c in ipairs({ B, A }) do
      as(c)
      c.F.clock = c.F.clock + 1
      sync.receive(c.F.proj, c.cfg, song, room, yes)
      c.F.sws_tick()
      band.sws_colours()
      _, sent = look(c, true)
      assert(timelines(sent) == 0, c.cfg.user .. ": a timeline read back after it landed is what was applied, nothing is sent back")
    end
  end
  assert(colour_of(A, "Quiet") == 0 and colour_of(B, "Quiet") == 0, "and it keeps the default colour on both")
  same(A, B, "sws: the same timeline")
  -- another project comes to the front: SWS's switches go back as the person had them, and only those StudioSync turned off
  as(B)
  reaper.SetProjExtState(B.F.proj, band.SECTION, "song", "")
  band.sws_colours()
  assert(B.F.sws["_S&MAUTOCOLOR_MKR_ENABLE"] == true and B.F.sws["_S&MAUTOCOLOR_RGN_ENABLE"] == true and B.F.sws["_SWSAUTOCOLOR_ENABLE"] == false,
    "back on for other projects; what was off stays off")
  assert(reaper.GetExtState(band.SECTION, "sws marker colour off") == "", "and no longer noted")
  print("rt-edits: SWS's marker colouring no longer echoes a timeline change back")
end
-- ---- the transport: Play together carries the leader's loop and repeat (each REAPER looped by its own before: a loop rehearsal came apart at
-- the first loop end). "Play (skip time selection)" and region playlists aren't carried: docs/rt/rt-edits.md ----
do
  local together = require("together")
  local bb = { song = song, room = room }
  local function start_ev()
    together.start(A.F.proj, A.cfg, bb, 8, false, 0)
    local ev
    for _, e in ipairs(new_events()) do if e.type == "start" then ev = e end end
    return ev
  end
  as(A)
  reaper.GetSet_LoopTimeRange2(A.F.proj, true, true, 8, 16, false)
  reaper.GetSetRepeatEx(A.F.proj, 1)
  local ev = start_ev()
  assert(ev and type(ev.loop) == "table" and ev.loop[1] == 8 and ev.loop[2] == 16, "Play together carries the loop")
  as(B)
  B.F.repeat_on, B.F.loop = 0, { 0, 0 }
  together.apply_loop(B.F.proj, ev.loop)
  assert(B.F.repeat_on == 1 and B.F.loop[1] == 8 and B.F.loop[2] == 16, "the laptop loops the same")
  as(A)
  reaper.GetSetRepeatEx(A.F.proj, 0)
  ev = start_ev()
  assert(ev and ev.loop == false, "repeat off: says so")
  as(B)
  together.apply_loop(B.F.proj, ev.loop)
  assert(B.F.repeat_on == 0, "and the laptop's repeat goes off")
  B.F.repeat_on = 1
  together.apply_loop(B.F.proj, nil)
  assert(B.F.repeat_on == 1, "an older StudioSync's start leaves yours")
  local src = io.open("StudioSync - Live sync.lua"):read("a")
  assert(src:find("together.apply_loop(proj, ev.loop)", 1, true), "Live sync puts a band start's loop in place")
end

-- ---- an old start or stop isn't replayed into the log (REAPER check, 0.59.49.74: after each restart the desktop, reopened from an old file,
-- logged "James-Laptop: record together at 1.84..." and "stop together" again; nothing played) ----
do
  local edir = sync.room_dir(A.cfg, song, room) .. "/events"
  local function cue(id, age, pos)
    files[edir .. "/" .. id .. ".json"] = { id = id, type = "start", user = "Bee", lead = "Bee", rec = true, pos = pos, countin = 0, format = 1,
      time = real_date("!%Y-%m-%dT%H:%M:%SZ", now_t - age), at = now_t - age + 2 }
  end
  local function said(text) for _, l in ipairs(logged) do if l:find(text, 1, true) then return true end end end
  as(A)
  local key = "transport " .. tostring(A.F.proj)
  reaper.DeleteExtState(band.SECTION, key, false)
  logged = {}
  cue("Bee-20261120-100000Z-00001-0001", 600, 1.84)
  A.F.clock = A.F.clock + 1
  sync.receive(A.F.proj, A.cfg, song, room, yes)
  assert(not said("record together") and reaper.GetExtState(band.SECTION, key) == "", "a start from ten minutes ago: marked done, not said, nothing set to play")
  assert(select(2, reaper.GetProjExtState(A.F.proj, sync.APPLIED, "Bee-20261120-100000Z-00001-0001")) == "1", "and not looked at again")
  cue("Bee-20261120-235959Z-00002-0002", 1, 3)
  A.F.clock = A.F.clock + 1
  sync.receive(A.F.proj, A.cfg, song, room, yes)
  assert(said("Bee: record together at 3") and reaper.GetExtState(band.SECTION, key) ~= "", "a start made just now is taken as ever")
end
-- ---- track order (backlog 1, rt-undo's limits): Undo and Restore moved a track under the track its older version names; nothing put the
-- order right during a session; heal could make a merge of two old changes long after every computer had settled on the newer ----
do
  build("Edits order")
  local C = computer("Cee", "C:/C/Edits order.rpp")
  seed_markers(C.F)
  tick()
  recv(C)
  same(A, C, "order: a third computer has the song")
  local rdir = sync.room_dir(A.cfg, song, room)
  local function track(c, name)
    as(c)
    for i = 0, reaper.CountTracks(c.F.proj) - 1 do
      local tr = reaper.GetTrack(c.F.proj, i)
      if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) == name then return tr end
    end
  end
  local function names(c) local t = {}; for _, x in ipairs(c.F.tracks) do t[#t + 1] = x.name end return table.concat(t, " ") end
  local function to_all(what)
    settle(A, true)
    tick()
    recv(B)
    tick()
    recv(C)
    assert(names(B) == names(A) and names(C) == names(A), what .. ": the same order everywhere (" .. names(A) .. " / " .. names(B) .. " / " .. names(C) .. ")")
    same(A, B, what)
  end
  local function heal(c, idle) as(c); return mirror.order_heal(c.F.proj, c.cfg, song, room, c.F.clock, idle or 60) end
  for _, c in ipairs({ A, B, C }) do assert(heal(c) == 0, "(the order is right as each opens)") end

  -- 1. Undo of a mute leaves the track where it sits: a track added above it since isn't in its older version's "sits under"
  as(A)
  A.F.add_track("New", 3)
  tick()
  to_all("a track added under Bass")
  assert(names(A) == "Drums Bass New Keys Gtr Vox", "(New sits between Bass and Keys: " .. names(A) .. ")")
  as(A)
  reaper.SetMediaTrackInfo_Value(track(A, "Keys"), "B_MUTE", 1)
  tick()
  to_all("Keys muted")
  tick()
  as(A)
  assert(press(false), "the mute is undone")
  assert(reaper.GetMediaTrackInfo_Value(track(A, "Keys"), "B_MUTE") == 0, "(Keys plays again)")
  assert(names(A) == "Drums Bass New Keys Gtr Vox", "Undo of a mute leaves the track where it sits (" .. names(A) .. ")")
  tick()
  to_all("the mute undone")
  -- a move of yours says where the track sat, so Undo puts it back there and Redo moves it again
  tick()
  as(A)
  reaper.SetOnlyTrackSelected(track(A, "Keys"))
  reaper.ReorderSelectedTracks(0, 0)
  local went = look(A, true)
  local keys_ev
  for _, ev in pairs(went) do if ev.name == "Keys" and ev.obj == "track" then keys_ev = ev end end
  assert(keys_ev and keys_ev.moved == mirror.track_oid(track(A, "New")), "a moved track's change names the track it sat under")
  tick()
  to_all("Keys moved to the top")
  assert(names(A) == "Keys Drums Bass New Gtr Vox", "(Keys is first: " .. names(A) .. ")")
  tick()
  as(A)
  assert(press(false), "the move is undone")
  assert(names(A) == "Drums Bass New Keys Gtr Vox", "Undo of a move puts the track back where it sat, under New (" .. names(A) .. ")")
  tick()
  to_all("the move undone")
  tick()
  as(A)
  assert(press(true), "and redone")
  assert(names(A) == "Keys Drums Bass New Gtr Vox", "Redo moves it again (" .. names(A) .. ")")
  tick()
  to_all("the move redone")

  -- 2. an order that came apart is put right during the session (REAPER check, 0.59.49.76): the desktop reopened an older file, and one
  -- change of a track carried that file's place. LinuxBox moved the track; the laptop didn't (here: its tab was behind)
  for _, c in ipairs({ A, B, C }) do heal(c) end
  local studio = names(B)
  as(A)
  for i, t in ipairs(A.F.tracks) do if t.name == "Gtr" then table.insert(A.F.tracks, table.remove(A.F.tracks, i)); break end end -- (the older file's order: nobody moved it)
  for _, t in ipairs(A.F.tracks) do t.sel = nil end
  mirror.order_seen[tostring(A.F.proj)] = nil -- (as a file just opened: its order is the file's, nobody's move)
  reaper.SetMediaTrackInfo_Value(track(A, "Gtr"), "B_MUTE", 1) -- (and a change of the track goes out, as the older StudioSync's colour did)
  tick()
  went = {}
  settle(A, true, went)
  A.F.clock = A.F.clock + 70
  settle(A, true, went)
  local n = 0
  for _, ev in pairs(went) do n = n + 1; assert(ev.name == "Gtr" and ev.moved == nil, "(only Gtr's change goes, not as a move)") end
  assert(n == 1, "(one change: " .. n .. ")")
  local stale_file = A.F.save()
  tick()
  recv(C)
  -- (since rt-converge a change that isn't a move no longer moves its track where it lands (mirror.says_move): the third computer keeps the
  -- studio's order. For the order heal's own rules below its order is put apart as the desktop's was, as a move landed with no list behind it)
  assert(names(C) == studio, "(a computer that's here keeps its order: the change says no move: " .. names(C) .. ")")
  as(C)
  for i, t in ipairs(C.F.tracks) do if t.name == "Gtr" then table.insert(C.F.tracks, table.remove(C.F.tracks, i)); break end end
  mirror.order_landed[tostring(C.F.proj)] = C.F.clock
  assert(names(C) == names(A) and names(C) ~= studio, "(the third computer's order apart: " .. names(C) .. ")")
  local real_enum = B.F.reaper.EnumProjects
  B.F.reaper.EnumProjects = function(i) if i == -1 then return {}, "" end return real_enum(i) end -- (the laptop's tab is behind)
  recv(B)
  B.F.reaper.EnumProjects = real_enum
  assert(names(B) == studio, "(a tab that's behind keeps its order: " .. names(B) .. ")")
  -- the others say their order every few seconds; Live sync notes who is apart, and for how long
  local function apart(c, other)
    as(other)
    local code = mirror.order_code(other.F.proj)
    as(c)
    local root = mirror.root(c.F.proj)
    -- (with a bandmate on an older StudioSync beside them, caught up, whose project code differs and who says no order: the order heal goes by
    -- the order alone. It waited on "order" while that bandmate made the note "project", 6 minutes and more: REAPER recheck, 0.59.49.79, round 6)
    mirror.apart_note(c.F.proj, root, mirror.order_code(c.F.proj), 0, { { user = other.cfg.user, mirror = root, order = code, pending = 0 },
      { user = "Old", mirror = "an older code", pending = 0 } }, c.F.clock)
  end
  apart(C, B)
  assert(heal(C) == 0 and names(C) ~= studio, "not at once: the codes differ for some seconds after any edit")
  C.F.clock = C.F.clock + mirror.APART_SECS + 1
  apart(C, B)
  assert(heal(C) == 0, "nor within two minutes of a bandmate's move landing here: its mover's order list may still be on its way")
  C.F.clock = C.F.clock + mirror.ORDER_WAIT
  apart(C, B)
  assert(heal(C, 3) == 0, "never 3 s after an edit of yours")
  C.F.playing = 1
  assert(heal(C) == 0, "never while playing or recording")
  C.F.playing = 0
  local real_enum_c = C.F.reaper.EnumProjects
  C.F.reaper.EnumProjects = function(i) if i == -1 then return {}, "" end return real_enum_c(i) end
  assert(heal(C) == 0, "never in a tab that's behind")
  C.F.reaper.EnumProjects = real_enum_c
  logged = {}
  assert(heal(C) == 1 and names(C) == studio, "stopped, in front, idle and apart for 30 s: the track goes back onto the studio's order (" .. names(C) .. ")")
  assert(logged[1] and logged[1]:find("1 track(s) put in the studio's order", 1, true), "and the log says so")
  local _, sent = look(C, true)
  assert(#sent == 0, "that isn't a move of this person's: nothing goes out (" .. #sent .. ")")
  -- the desktop too, whose file it was
  A.F.clock = A.F.clock + mirror.APART_SECS + 1
  apart(A, B)
  A.F.clock = A.F.clock + mirror.APART_SECS + 1
  apart(A, B)
  assert(heal(A) == 1 and names(A) == studio, "and on the computer whose file had the old order (" .. names(A) .. ")")
  _, sent = look(A, true)
  assert(#sent == 0, "nothing goes out there either (" .. #sent .. ")")
  tick()
  recv(B)
  same(A, B, "order healed: the laptop")
  same(A, C, "order healed: the third computer")
  -- and a project opened from a file with another order is put right once it has caught up, without waiting for anyone to be apart
  local D = { F = E.open(A.F.path, stale_file), cfg = A.cfg }
  tick()
  recv(D)
  assert(names(D) ~= studio, "(the reopened file has its own order: " .. names(D) .. ")")
  D.F.undos = {} -- (REAPER's undo points from here: round 5)
  assert(heal(D) == 1 and names(D) == studio, "a project opened with another order is put right once it has caught up (" .. names(D) .. ")")
  -- a heal isn't the person's act: one undo point, StudioSync's, which StudioSync's Undo steps over (REAPER's "Change track order" on top was
  -- taken for their own edit by Ctrl+Z, and REAPER undid the heal)
  assert(#D.F.undos == 1 and D.F.undos[1] == "StudioSync: the studio's track order" and not undo.native(D.F.undos[1]),
    "the order heal leaves one StudioSync undo point, no \"Change track order\" (" .. table.concat(D.F.undos, " / ") .. ")")

  -- 3. heal doesn't make a merge of two old changes on a computer that holds the newer of them: before tracks merged, every computer took
  -- the newer and counted the other done, and a heal a day later changed the track everywhere
  local since = mirror.MERGE_SINCE
  mirror.MERGE_SINCE = {} -- (this song's clock is 2026-11-20, around when track merging began: as built since, whatever the time zone. rt-p1)
  tick()
  as(A)
  reaper.SetMediaTrackInfo_Value(track(A, "Vox"), "B_MUTE", 1)
  as(B)
  reaper.SetMediaTrackInfo_Value(track(B, "Vox"), "D_PAN", 0.5)
  look(A, true)
  tick()
  look(B, true) -- (the newer of the two, made apart: the laptop holds it)
  local vox = mirror.track_oid(track(B, "Vox"))
  local newest, all = mirror.room_newest(rdir)
  assert(newest[vox].user == "Bee" and mirror.settled(rdir, newest[vox], all[vox]).id ~= newest[vox].id, "(heal settles on a merge of the two)")
  tick(mirror.MERGE_NEWS_SECS + 60)
  as(B)
  local held = select(3, mirror.known(B.F.proj, vox))
  B.F.undos = {}
  mirror.heal(B.F.proj, rdir, false)
  assert(#B.F.undos == 0, "a heal that changes nothing leaves no undo point")
  assert(select(3, mirror.known(B.F.proj, vox)) == held and reaper.GetMediaTrackInfo_Value(track(B, "Vox"), "B_MUTE") == 0,
    "a merge nobody made isn't made an hour later on a computer that holds the newer change")
  -- a computer that holds neither is behind: it still gets what heal settles on
  as(C)
  C.F.undos = {}
  mirror.heal(C.F.proj, rdir, false)
  assert(#C.F.undos == 1 and C.F.undos[1]:find("^StudioSync") and not undo.native(C.F.undos[1]), "a catch-up leaves one StudioSync undo point (" .. table.concat(C.F.undos, " / ") .. ")")
  assert(select(3, mirror.known(C.F.proj, vox)) ~= held and reaper.GetMediaTrackInfo_Value(track(C, "Vox"), "D_PAN") == 0.5
    and reaper.GetMediaTrackInfo_Value(track(C, "Vox"), "B_MUTE") == 1, "a computer that has neither change still catches up, on the merge")
  -- 4. the same pair made before track merging began (backlog 1.1, rt-p1): no computer merged it then, so heal doesn't either. It settles on
  -- the newer, as every receive did; a merge here would change the track everywhere, a day late
  mirror.MERGE_SINCE = { track = os.date("!%Y%m%d-%H%M%S", now_t + 86400), env = os.date("!%Y%m%d-%H%M%S", now_t + 86400) }
  newest, all = mirror.room_newest(rdir)
  assert(mirror.settled(rdir, newest[vox], all[vox]).id == newest[vox].id, "a pair from before track merging: heal settles on the newer")
  assert(not mirror.mergeable(newest[vox]) and not mirror.split_merge(mirror.judge(B.F.proj, vox, rdir).v.id), "and the judge merges nothing")
  mirror.MERGE_SINCE = since
  print("rt-edits: Undo leaves a track where it sits unless a move is undone; a track order that came apart is put right mid-session; no late merges")
end
-- ---- a claimed track renamed by a computer whose StudioSync doesn't ask (one from before 0.59.49.74): only the sender judged a rename, and
-- receivers took it by its new name, which nobody has claimed (backlog 1). Now every receiver judges it by the name the track has there:
-- the others hold it, and the claimer's computer answers with the track as it is, so the old name comes back on the renamer's too ----
do
  build("Edits rename")
  local C = computer("Cee", "C:/C/Edits rename.rpp")
  seed_markers(C.F)
  tick()
  recv(C)
  same(A, C, "rename: a third computer has the song")
  local function said(text) for _, l in ipairs(logged) do if l:find(text, 1, true) then return true end end end
  local function session() return proxy.read_json(proxy.session_path(A.cfg, song)) end
  local function track(c, name)
    as(c)
    for i = 0, reaper.CountTracks(c.F.proj) - 1 do
      local tr = reaper.GetTrack(c.F.proj, i)
      if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) == name then return tr end
    end
  end
  local function rename(c, from, to) reaper.GetSetMediaTrackInfo_String(track(c, from), "P_NAME", to, true) end
  local function claims(c) -- (the room's claims as that computer reads them now)
    as(c)
    c.F.clock = c.F.clock + 100
    return sync.authority(c.cfg, song, room, session())
  end
  local function receive(c, can) as(c); c.F.clock = c.F.clock + 1; logged = {}; sync.receive(c.F.proj, c.cfg, song, room, can) end
  -- the desktop holds Bass, by an auto-claim
  local iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
  files[sync.claims_path(A.cfg, song, room, "James")] = { user = "James", time = iso, tracks = { "Bass", "Keys" }, regions = {},
    since = { ["tracks:bass"] = iso, ["tracks:keys"] = iso }, auto = { ["tracks:bass"] = iso } }
  -- the laptop's StudioSync doesn't ask: its rename goes out (look() sends whatever changed, as that version did)
  rename(B, "Bass", "Bass 2")
  tick()
  assert(next((look(B, true))), "(the older StudioSync sends the rename)")
  tick()
  -- a third computer holds it, as any change its sender may not make
  local can_c = claims(C)
  assert(can_c("Bee", "Bass", 0) == false and can_c("Bee", "Bass 2", 0) == true, "(Bass is the desktop's; nobody has claimed the new name)")
  receive(C, can_c)
  assert(track(C, "Bass") and not track(C, "Bass 2"), "a bandmate's computer doesn't take a rename of a claimed track by its new name")
  -- the claimer's computer doesn't take it either, and answers
  local can_a, who_a = claims(A)
  receive(A, can_a)
  assert(track(A, "Bass") and not track(A, "Bass 2"), "the claimer's track keeps its name")
  assert(said("Bee renamed Bass, which you've claimed, to Bass 2"), "and its log says what happened")
  as(A)
  A.F.clock = A.F.clock + 1
  mirror.watch(A.F.proj, A.cfg, song, room, { can = can_a, mode = "open", quick = true, is_claimed = who_a.is_claimed, owner_of = who_a.owner_of })
  local back
  for _, ev in ipairs(new_events()) do if ev.obj == "track" and ev.user == "James" then back = ev end end
  assert(back and back.name == "Bass" and tostring(back.note):find("Bee's rename to Bass 2 is put back", 1, true), "the track goes out as it is here, saying why")
  -- the renamer's computer takes that as any change: the old name is back there, and its log has the line
  tick()
  logged = {}
  recv(B)
  assert(track(B, "Bass") and not track(B, "Bass 2"), "the name is back on the computer that renamed it")
  assert(said("James has claimed Bass: Bee's rename to Bass 2 is put back"), "and that computer's log says why")
  receive(C, can_c)
  assert(track(C, "Bass") and not track(C, "Bass 2"), "the third computer never showed the new name")
  tick()
  recv(C)
  same(A, B, "rename put back: the renamer")
  same(A, C, "rename put back: the third computer")
  -- the claimer's own rename lands at once
  rename(A, "Bass", "Bass DI")
  tick()
  as(A)
  A.F.clock = A.F.clock + 1
  mirror.watch(A.F.proj, A.cfg, song, room, { can = can_a, mode = "open", quick = true, is_claimed = who_a.is_claimed, owner_of = who_a.owner_of })
  new_events()
  tick()
  receive(C, can_c)
  assert(track(C, "Bass DI"), "the claimer's own rename lands at once")
  tick()
  recv(B)
  -- a rename from long ago (the claimer was away): it lands after the minute a refused change waits, and isn't taken back
  rename(B, "Keys", "Keys 2")
  tick()
  assert(next((look(B, true))), "(another rename, of a lastingly claimed track)")
  tick(sync.RENAME_BACK + 60)
  files[sync.claims_path(A.cfg, song, room, "James")].auto = {}
  can_a = claims(A)
  assert(can_a("Bee", "Keys", 0) == false, "(Keys is still the desktop's)")
  receive(A, can_a)
  assert(track(A, "Keys") and not said("put back"), "an old rename waits its minute")
  A.F.clock = A.F.clock + 61
  receive(A, can_a)
  assert(track(A, "Keys 2"), "then lands: a name everyone has had for a while isn't taken back")
  files[sync.claims_path(A.cfg, song, room, "James")] = nil
  print("rt-edits: a claimed track renamed by a StudioSync that doesn't ask keeps its name everywhere")
end
-- ---- a timeline change of yours that hasn't gone out when a bandmate's lands is made again on top of theirs (backlog 1): the timeline
-- travels whole, so theirs replaced yours and nothing said so ----
do
  build("Edits unsent")
  local function said(text) for _, l in ipairs(logged) do if l:find(text, 1, true) then return true end end end
  local function count(c, name) local n = 0; for _, m in ipairs(c.F.markers) do if m.name == name then n = n + 1 end end return n end
  local function mark(c, name) for _, m in ipairs(c.F.markers) do if m.name == name then return m end end end
  local function lands(c) -- (a bandmate's change arrives between two looks)
    as(c)
    c.F.clock = c.F.clock + 1
    logged = {}
    sync.receive(c.F.proj, c.cfg, song, room, yes)
  end
  local function round(what)
    tick()
    look(B, true)
    tick()
    recv(A)
    tick()
    recv(B)
    same(A, B, what)
  end
  -- a marker added on the laptop, a region added on the desktop: both stay
  B.F.add_marker(false, 30, 30, "Lap")
  as(A)
  A.F.add_marker(true, 32, 40, "Outro")
  tick()
  look(A, true)
  tick()
  lands(B)
  assert(count(B, "Outro") == 1 and count(B, "Lap") == 1, "the bandmate's region lands and your unsent marker stays")
  assert(said("James's newer tempo map and markers landed before your own change had gone out"), "the log says so")
  round("an unsent marker under a bandmate's timeline")
  assert(count(A, "Lap") == 1 and count(A, "Outro") == 1, "and it reaches the desktop, with the region kept")
  -- a marker moved and one removed on the laptop, the desktop adds another: the move isn't doubled, the removed one stays gone
  mark(B, "Cue").pos = 5; mark(B, "Cue").rend = 5
  for i, m in ipairs(B.F.markers) do if m.name == "Lap" then table.remove(B.F.markers, i); break end end
  B.F.clock = B.F.clock + 1
  as(A)
  A.F.add_marker(false, 44, 44, "End")
  tick()
  look(A, true)
  tick()
  lands(B)
  assert(count(B, "Cue") == 1 and mark(B, "Cue").pos == 5 and count(B, "Lap") == 0 and count(B, "End") == 1, "a move stays one marker, a removal stays removed")
  round("an unsent move and removal under a bandmate's timeline")
  assert(count(A, "Cue") == 1 and mark(A, "Cue").pos == 5 and count(A, "Lap") == 0, "on the desktop too")
  -- the bandmate changes the tempo map, you had added a marker: it's kept at its beat
  B.F.add_marker(false, 8, 8, "Beat")
  local qn = B.F.qn_of(8)
  as(A)
  reaper.SetTempoTimeSigMarker(A.F.proj, 0, 0, -1, -1, 100, 4, 4, false)
  tick()
  settle(A, true)
  tick()
  lands(B)
  assert(count(B, "Beat") == 1 and math.abs(B.F.qn_of(mark(B, "Beat").pos) - qn) < 1e-6, "your marker is kept where REAPER moved it for the map")
  round("an unsent marker under a bandmate's tempo change")
  -- you change the tempo map, the bandmate's marker lands: your map is kept on top, their marker too
  as(B)
  reaper.SetTempoTimeSigMarker(B.F.proj, 0, 0, -1, -1, 90, 4, 4, false)
  as(A)
  A.F.add_marker(false, 2, 2, "Two")
  tick()
  look(A, true)
  tick()
  lands(B)
  as(B)
  assert(band.capture_tempo(B.F.proj)[1].bpm == 90 and count(B, "Two") == 1, "your tempo map is kept and their marker lands")
  assert(said("Kept on top of theirs: your tempo map (theirs is replaced)"), "the log says whose map stands")
  tick()
  settle(B, true)
  tick()
  recv(A)
  as(A)
  assert(band.capture_tempo(A.F.proj)[1].bpm == 90 and count(A, "Two") == 1, "and goes to the desktop")
  assert(timeline(A) == timeline(B), "the same tempo map and markers on both")
  -- a note from an older version whose tempo map reads differently: nothing is made again, and the log says the timeline was replaced
  as(B)
  local seen = band.json_decode(select(2, reaper.GetProjExtState(B.F.proj, band.SECTION, "timeline")))
  seen[4], seen[1][1].bpm = 5, 77
  reaper.SetProjExtState(B.F.proj, band.SECTION, "timeline", band.json_encode(seen))
  as(A)
  A.F.add_marker(false, 3, 3, "Three")
  tick()
  look(A, true)
  tick()
  lands(B)
  assert(count(B, "Three") == 1 and said("replaced this project's"), "what can't be told apart is replaced, and the log says so")
  print("rt-edits: a marker or tempo change of yours that hadn't gone out is kept on top of a bandmate's timeline that lands")
end
-- ---- a track's colour never flips by itself (REAPER check, 0.59.49.75: XT Drums A's colour went out from the desktop and back from the
-- laptop at each restart, "something with no undo point changed XT Drums A right after a bandmate's change landed", and each one auto-claimed
-- the track, which then held back an Undo). The colour hold put an old colour back over one that had just landed ----
do
  build("Edits colour")
  local FLAG = 0x1000000
  local function track_of(c, name)
    as(c)
    for i = 0, reaper.CountTracks(c.F.proj) - 1 do
      local tr = reaper.GetTrack(c.F.proj, i)
      if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) == name then return tr end
    end
  end
  local function raw(c, name) local tr = track_of(c, name); return reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") end
  -- the desktop takes a track out, then colours another; the laptop gets both in one pass (as it does catching up after a restart)
  as(A)
  reaper.DeleteTrack(track_of(A, "Gtr"))
  settle(A, true)
  tick()
  as(A)
  reaper.SetMediaTrackInfo_Value(track_of(A, "Drums"), "I_CUSTOMCOLOR", FLAG | 0x3040C0)
  settle(A, true)
  tick()
  recv(B) -- (errors if the laptop sends anything back in the looks after)
  assert(not track_of(B, "Gtr"), "the track went on the laptop")
  assert(raw(B, "Drums") == FLAG | 0x3040C0, "the colour that landed after a track went stays (" .. tostring(raw(B, "Drums")) .. ")")
  as(B)
  assert(reaper.GetExtState(band.SECTION, "colour hold") == "", "no colour hold where nothing recolours tracks by itself")
  same(A, B, "a track out and a colour in one pass")
  -- "no colour" is one thing however REAPER holds it: 16576 with the flag off (every Cross Test track) and 0 are the same, and aren't written
  assert(mirror.colour_key(16576) == 0 and mirror.colour_key(0) == 0 and mirror.colour_key(nil) == 0 and mirror.colour_key(FLAG | 16576) == FLAG | 16576,
    "a colour with the flag off is none")
  assert(mirror.track_line({ name = "x", color = 16576 }, false, true) == mirror.track_line({ name = "x", color = 0 }, false, true), "and reads as none")
  -- (tracks shared by a build that hashed the stored number: nothing goes out again for them after the update)
  local real_key = mirror.colour_key
  mirror.colour_key = function(c) return math.tointeger(tonumber(c) or 0) or tonumber(c) or 0 end
  as(A)
  reaper.SetMediaTrackInfo_Value(track_of(A, "Keys"), "I_CUSTOMCOLOR", 16576)
  local went = look(A, true)
  assert(next(went), "(the older build sent the stored number)")
  tick()
  recv(B)
  assert(raw(B, "Keys") == 16576, "(and the older build wrote it)")
  mirror.colour_key = real_key
  tick()
  local _, a_sent = look(A, true)
  local _, b_sent = look(B, true)
  assert(#a_sent == 0 and #b_sent == 0, "tracks an older build shared don't go out again (" .. #a_sent .. ", " .. #b_sent .. ")")
  same(A, B, "after the update")
  -- one computer holds none as 0, the other as 16576: neither sends, and a change that lands leaves the stored number alone
  as(B)
  reaper.SetMediaTrackInfo_Value(track_of(B, "Keys"), "I_CUSTOMCOLOR", 0)
  _, b_sent = look(B, true)
  assert(#b_sent == 0, "none stored another way isn't a change (" .. #b_sent .. " sent)")
  as(A)
  reaper.GetSetMediaTrackInfo_String(track_of(A, "Keys"), "P_NAME", "Keys 2", true)
  went = look(A, true)
  assert(next(went), "a rename goes")
  tick()
  recv(B)
  assert(track_of(B, "Keys 2") and raw(B, "Keys 2") == 0, "none over none writes nothing (" .. tostring(track_of(B, "Keys 2") and raw(B, "Keys 2")) .. ")")
  same(A, B, "none, stored two ways")
  -- where SWS's auto track colouring is on, the hold still holds, but never over a colour StudioSync set since
  as(B)
  local real_own = mirror.own_colours -- (its answer is kept a second by one clock; the computers here each have their own)
  mirror.own_colours = function() return true end
  local bass_b, drums_b = track_of(B, "Bass"), track_of(B, "Drums")
  local bass_was = raw(B, "Bass")
  mirror.hold_colours(B.F.proj, mirror.track_colours(B.F.proj))
  reaper.SetMediaTrackInfo_Value(bass_b, "I_CUSTOMCOLOR", FLAG | 0x0000FF) -- (SWS's rule recolours it)
  reaper.SetMediaTrackInfo_Value(drums_b, "I_CUSTOMCOLOR", FLAG | 0x00FF00) -- (the band's new colour lands)
  mirror.held_colour(drums_b)
  mirror.hold_colours()
  assert(raw(B, "Bass") == bass_was, "what SWS recoloured is put back")
  assert(raw(B, "Drums") == FLAG | 0x00FF00, "what StudioSync set stays")
  mirror.own_colours = function() return false end
  reaper.SetMediaTrackInfo_Value(bass_b, "I_CUSTOMCOLOR", FLAG | 0x0000FF)
  mirror.hold_colours()
  assert(raw(B, "Bass") == FLAG | 0x0000FF and reaper.GetExtState(band.SECTION, "colour hold") == "", "and the hold ends when SWS's colouring goes off")
  mirror.own_colours = real_own
  print("rt-edits: a track's colour that landed is never put back, and no colour is no colour however it's stored")
end
-- ---- one note or automation point moved by both people is one thing: the later move stands, never two copies (backlog 1, rt-merge's limits).
-- A move reads as one taken away and one added, so each side's copy was kept ----
do
  local function midi(...)
    local t = { "<SOURCE MIDI", "HASDATA 1 960 QN" }
    for _, l in ipairs({ ... }) do t[#t + 1] = l end
    t[#t + 1] = ">"
    return table.concat(t, "\n")
  end
  local function count(text, what) local n = 0; for _ in text:gmatch(what) do n = n + 1 end return n end
  -- a C (3c) at 0 and an E (40) at 960, each 480 long
  local base = midi("E 0 90 3c 60", "E 480 80 3c 00", "E 480 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  -- both moved the C: the winner to 240, the loser to 120
  local w = midi("E 240 90 3c 60", "E 480 80 3c 00", "E 240 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  local l = midi("E 120 90 3c 60", "E 480 80 3c 00", "E 360 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  local m, clash = mirror.merge_midi(base, w, l)
  assert(m == w and clash, "a note both moved is one note, where the later move put it, and a clash:\n" .. tostring(m))
  -- the winner changed its pitch, the loser moved it in time: one note, with both (rt-p1: a pitch change no longer counts as a move)
  local wp = midi("E 0 90 3e 60", "E 480 80 3e 00", "E 480 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  local both_ways = midi("E 120 90 3e 60", "E 480 80 3e 00", "E 360 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  m, clash = mirror.merge_midi(base, wp, l)
  assert(m == both_ways and not clash, "a pitch change and a move in time: one note, transposed and moved:\n" .. tostring(m))
  m, clash = mirror.merge_midi(base, l, wp)
  assert(m == both_ways and not clash, "and the other way round:\n" .. tostring(m))
  -- both transposed it: one note, the later one's pitch, a clash
  local lp = midi("E 0 90 3b 60", "E 480 80 3b 00", "E 480 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  m, clash = mirror.merge_midi(base, wp, lp)
  assert(m == wp and clash, "both transposed it: the later pitch:\n" .. tostring(m))
  -- the winner changed it in place (velocity), the loser moved it: one note, moved, with the winner's velocity (rt-p1)
  local wv = midi("E 0 90 3c 30", "E 480 80 3c 00", "E 480 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  m, clash = mirror.merge_midi(base, wv, l)
  assert(m == midi("E 120 90 3c 30", "E 480 80 3c 00", "E 360 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00") and not clash,
    "changed by one, moved by the other: one note, with both:\n" .. tostring(m))
  -- the winner removed it, the loser moved it: the later removal stands
  local wd = midi("E 960 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  m, clash = mirror.merge_midi(base, wd, l)
  assert(m == wd and clash, "removed by the later one, moved by the other: gone:\n" .. tostring(m))
  -- the loser moved one note, the winner another: both moves stand, no clash
  local we = midi("E 0 90 3c 60", "E 480 80 3c 00", "E 720 90 40 60", "E 480 80 40 00", "E 240 b0 7b 00") -- (the E to 1200)
  m, clash = mirror.merge_midi(base, we, l)
  assert(count(m, "90 3c 60") == 1 and count(m, "90 40 60") == 1 and m:find("E 120 90 3c 60", 1, true) and not clash, "different notes moved: both moves:\n" .. tostring(m))
  m, clash = mirror.merge_midi(base, w, base)
  assert(m == w and not clash, "(only the winner moved it)")
  -- moved and resized at once (round 5): the loser's C to 120 and 240 long, the winner's to 240. One note: the later place, the other's
  -- length (rt-p1: what only one of them changed is theirs)
  local lr = midi("E 120 90 3c 60", "E 240 80 3c 00", "E 600 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00")
  m, clash = mirror.merge_midi(base, w, lr)
  assert(m == midi("E 240 90 3c 60", "E 240 80 3c 00", "E 480 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00") and clash,
    "moved and resized by one, moved by the other: one note, the later place, the other's length:\n" .. tostring(m))
  local wr = midi("E 240 90 3c 60", "E 720 80 3c 00", "E 0 90 40 60", "E 480 80 40 00", "E 480 b0 7b 00") -- (the winner moved and resized it too)
  m, clash = mirror.merge_midi(base, wr, lr)
  assert(m == wr and clash, "moved and resized by both: one note, the later one's:\n" .. tostring(m))
  m, clash = mirror.merge_midi(base, lr, w)
  assert(m == lr and clash, "and the other way round:\n" .. tostring(m))
  -- not a move: the loser took the C away and drew a D of another velocity. Both stand beside the winner's moved C, as before
  local ld = midi("E 960 90 40 60", "E 480 80 40 00", "E 0 90 3e 30", "E 240 80 3e 00", "E 240 b0 7b 00")
  m = mirror.merge_midi(base, w, ld)
  assert(count(m, "90 3c 60") == 1 and count(m, "90 3e 30") == 1 and count(m, "90 40 60") == 1, "a note taken away and another drawn aren't paired:\n" .. tostring(m))
  -- automation: a point both moved is one point
  local function env(...) return "<VOLENV2\nACT 1 -1\n" .. table.concat({ ... }, "\n") .. "\n>\n" end
  local eb = env("PT 0 1 0", "PT 4 0.5 0", "PT 8 1 0")
  local ew = env("PT 0 1 0", "PT 5 0.4 0", "PT 8 1 0")
  local el = env("PT 0 1 0", "PT 3 0.6 0", "PT 8 1 0")
  local me, both = mirror.merge_env(eb, ew, el)
  assert(me == ew and #both == 1, "a point both moved is one point, the later one's, and a clash:\n" .. tostring(me))
  -- the winner changed its value, the loser moved it: one point
  local ev = env("PT 0 1 0", "PT 4 0.2 0", "PT 8 1 0")
  me, both = mirror.merge_env(eb, ev, el)
  assert(me == ev and #both >= 1, "a point changed by one and moved by the other is one point:\n" .. tostring(me))
  -- the loser moved one point and the winner changed another: both stand
  local e2 = env("PT 0 1 0", "PT 4 0.5 0", "PT 8 0.3 0")
  me, both = mirror.merge_env(eb, e2, el)
  assert(me == env("PT 0 1 0", "PT 3 0.6 0", "PT 8 0.3 0") and #both == 0, "different points: both changes:\n" .. tostring(me))
  print("rt-edits: a note or automation point both people moved is one thing, the later one's")
end

-- ---- (round 5) Claims: deleting several claimed things at once asks their claimer, as an edit to one does (W.refuse). It went to the older
-- suggestion path: put back at once, a suggestion written, nobody asked ----
do
  build("Edits ask")
  local claimed = { Bass = true, Drums = true } -- (Bee's)
  local answer, asked = true, {}
  local function claims_look(released)
    as(A)
    A.F.clock = A.F.clock + 1
    mirror.watch(A.F.proj, A.cfg, song, room, { can = function(_, name) return released or not claimed[name] end, mode = "open", quick = true,
      is_claimed = function(name) return not released and claimed[name] == true end, owner_of = function(name) return claimed[name] and "Bee" or "James" end,
      ask = function(name) if not released and claimed[name] then asked[name] = true; return answer end end })
    return new_events()
  end
  local function suggestions() local n = 0; for p in pairs(files) do if p:find("/suggestions/", 1, true) then n = n + 1 end end return n end
  local function track_named(name) for _, t in ipairs(A.F.tracks) do if t.name == name then return t end end end
  local function count_items(t) return t and #t.items or 0 end
  -- two of Bass's items and the Drums track (its automation with it), at once
  tick()
  as(A)
  reaper.DeleteTrackMediaItem(bass, item_named(bass, "Bass 1"))
  reaper.DeleteTrackMediaItem(bass, item_named(bass, "Bass 2"))
  reaper.DeleteTrack(drums)
  local went = claims_look()
  assert(#went == 0 and asked.Bass and asked.Drums, "deleting someone's claimed things asks them (asked Bass " .. tostring(asked.Bass) .. ", Drums " .. tostring(asked.Drums) .. ", " .. #went .. " sent)")
  assert(count_items(bass) == 2 and not track_named("Drums") and suggestions() == 0, "held while asking: still gone here, nothing put back, no suggestion")
  went = claims_look()
  assert(#went == 0 and count_items(bass) == 2 and not track_named("Drums"), "and on the next look, while the ask waits")
  -- Keep (or no answer): put back, with the words
  answer = "Not sent: Bee kept it. Your edit is put back"
  logged = {}
  went = claims_look()
  assert(#went == 0 and count_items(bass) == 4 and track_named("Drums") and suggestions() == 0, "Keep: everything is back, nothing went out, no suggestion")
  local said = false
  for _, l in ipairs(logged) do said = said or l:find("Bee kept it", 1, true) ~= nil end
  assert(said, "and the log says why")
  settle(A, true)
  same(A, B, "a kept claim: as it was everywhere")
  -- asked again, then released: the deletion goes to everyone
  tick()
  as(A)
  drums = track_named("Drums")
  reaper.DeleteTrackMediaItem(bass, item_named(bass, "Bass 1"))
  reaper.DeleteTrack(drums)
  answer = true
  went = claims_look()
  assert(#went == 0, "(held again)")
  went = claims_look(true)
  local gone = 0
  for _, ev in ipairs(went) do if ev.gone then gone = gone + 1 end end
  assert(gone >= 2, "released: the deletions go (" .. gone .. ")")
  tick()
  recv(B)
  same(A, B, "deletions held for an ask, then released")
  print("rt-edits: deleting several claimed things at once asks their claimer; Keep puts them back, Release sends them")
end

-- ---- (round 5) A claim given to a member and released by them from their panel stays released; a release from the driver (released/) and
-- the folded claim agree ----
do
  build("Edits given")
  local groups, trust = require("groups"), require("trust")
  local real_mm, real_ok = groups.may_manage, trust.claim_ok
  groups.may_manage = function(_, who) return who == "James" end -- (James is the studio's admin)
  trust.claim_ok = function() return true end -- (written by his own computer, as Syncthing says)
  for _, x in ipairs({ A, B }) do x.F.reaper.file_exists = function(p) if p:find("/claims/", 1, true) then return files[p] ~= nil end return true end end
  local real_remove = os.remove
  os.remove = function(p) if files[p] ~= nil then files[p] = nil; return true end return real_remove(p) end -- (the shared folder's)
  local function holder(c, name) as(c); local _, who = sync.authority(c.cfg, song, room, nil); local t = who.tracks[name:lower()]; return t and t.user end
  local function fold() as(B); logged = {}; sync.follow_claims(B.F.proj, B.cfg, song, room) end
  local function given_files() local t = {}; for p, v in pairs(files) do if p:find("/claims/given-", 1, true) then t[p] = v end end return t end
  local function bee_has(name) as(B); for _, n in ipairs(sync.my_claims(B.cfg, song, room).tracks or {}) do if n == name then return true end end return false end
  -- James gives Bee Keys; her Live sync folds it in, dated as given
  as(A)
  sync.give_claims(A.cfg, song, room, "Bee", { "Keys" })
  local given_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local copies = given_files()
  assert(next(copies) and holder(A, "Keys") == "Bee", "(Keys is Bee's at once)")
  tick()
  fold()
  assert(bee_has("Keys") and not next(given_files()), "(folded into Bee's own claims, the given file gone)")
  assert(sync.my_claims(B.cfg, song, room).since["tracks:keys"] == given_at, "folded in with the date it was given, not the day's")
  -- Bee lets go of it from her panel (the chip's release: her claims less Keys)
  tick()
  as(B)
  local c = sync.my_claims(B.cfg, song, room)
  local keep = {}
  for _, n in ipairs(c.tracks) do if n ~= "Keys" then keep[#keep + 1] = n end end
  c.tracks = keep
  sync.set_claims(B.cfg, song, room, c)
  assert(holder(B, "Keys") ~= "Bee", "released")
  -- a computer that still reads the given file (Syncthing hasn't told it of the removal yet, or it holds the link's copy for its minute)
  for p, v in pairs(copies) do files[p] = v end
  assert(holder(A, "Keys") ~= "Bee", "stays released where the given file is still read")
  fold()
  assert(not bee_has("Keys") and holder(B, "Keys") ~= "Bee" and not next(given_files()), "and folding that file again doesn't bring it back")
  -- given again later: a new gift counts
  tick()
  as(A)
  sync.give_claims(A.cfg, song, room, "Bee", { "Keys" })
  assert(holder(A, "Keys") == "Bee", "a new gift after the release counts")
  tick()
  fold()
  assert(bee_has("Keys"), "and is folded in")
  -- the driver releases Bee's claims after a gift and before her computer folds it: it doesn't count again from the fold
  tick()
  as(A)
  sync.give_claims(A.cfg, song, room, "Bee", { "Gtr" })
  tick()
  sync.release_claims(A.cfg, song, room, "Bee")
  assert(holder(A, "Gtr") ~= "Bee" and holder(A, "Keys") ~= "Bee", "(the release covers what was given before it)")
  tick()
  fold()
  assert(holder(A, "Gtr") ~= "Bee" and holder(B, "Gtr") ~= "Bee" and not bee_has("Gtr"), "the release and the folded claim agree: Gtr isn't Bee's")
  -- (backlog 1.8, James's default (b), rt-p1) a claim given and released from Bee's panel before her computer folded it in (only the direct
  -- link's copy here): her own claims had nothing to remove, so it stayed hers. The chip's release now lets it go as well
  tick()
  as(A)
  sync.give_claims(A.cfg, song, room, "Bee", { "Bass" })
  assert(holder(B, "Bass") == "Bee" and not bee_has("Bass"), "(given, read by Bee's computer, not folded into her own claims yet)")
  tick()
  as(B)
  c = sync.my_claims(B.cfg, song, room)
  c.let_go = { [sync.claim_key("tracks", "Bass")] = true } -- (as the panel's chip release does: StudioSync - Panel.lua ui.claim_chips)
  sync.set_claims(B.cfg, song, room, c)
  assert(holder(A, "Bass") ~= "Bee" and holder(B, "Bass") ~= "Bee", "released from the panel before the fold: not Bee's anywhere")
  tick()
  fold()
  assert(not bee_has("Bass") and holder(B, "Bass") ~= "Bee", "and the fold that comes later doesn't bring it back")
  local fh = assert(io.open("StudioSync - Panel.lua", "rb"))
  local panel = fh:read("a")
  fh:close()
  assert(panel:match("local function release%(o%).-c%.let_go = { %[sync%.claim_key%(o%[2%], o%[3%]%) or \"\"%] = true }.-sync%.set_claims%(cfg, b%.song, b%.room, c%)"),
    "the panel's chip release lets the claim go though it's only given")
  groups.may_manage, trust.claim_ok, os.remove = real_mm, real_ok, real_remove
  print("rt-edits: a given claim released by its member stays released; a driver's release and a later fold agree")
end

-- ---- (round 6) REAPER recheck, 0.59.49.79: a whole-song Restore across a tempo change said "3 change(s) brought back ... (10 left as they are:
-- you've changed them here since ...)": the map went in first, REAPER moved the beat-based items, and the revert took them for unsent edits;
-- the next look sent those 10 as the person's own act, so StudioSync's Undo took them back instead of the Restore ----
do
  build("Edits restore tempo")
  local recall = require("recall")
  local session = function() return proxy.read_json(proxy.session_path(A.cfg, song)) end
  local upto = #recall.entries(A.cfg, song, room) -- (the song as shared: the point to go back to)
  tick()
  as(A)
  set(item_named(bass, "Bass 1"), "MUTE", "1 0")
  tick()
  settle(A, true)
  tick()
  as(A)
  reaper.SetTempoTimeSigMarker(A.F.proj, -1, 2, -1, -1, 90, 4, 4, false) -- (90 bpm from 2 s: REAPER moves what's after it)
  tick()
  settle(A, true)
  tick()
  recv(B)
  same(A, B, "(a tempo change from 2 s)")
  local moved_from = pos(item_named(drums, "Drums 2"))
  assert(math.abs(moved_from - 8) > 0.5, "(REAPER moved the items after the tempo change: " .. moved_from .. ")")
  -- Restore the whole song to before both, as the Restore page does: the map first, then the objects
  tick()
  as(A)
  local entries = recall.entries(A.cfg, song, room)
  assert(sync.restore_timeline(A.F.proj, A.cfg, song, room, entries, upto, session()), "(the map then goes back)")
  local act = "James-20261120120000-r1"
  local res = mirror.revert(A.F.proj, A.cfg, song, room, mirror.plan_restore(entries, upto), { can = yes, mode = "open", at_once = true, act = act })
  assert(not tostring(res):find("left as they are", 1, true), "what REAPER moved for the map is the Restore's, not edits of yours made since (" .. tostring(res) .. ")")
  assert(math.abs(pos(item_named(drums, "Drums 2")) - 8) < 1e-6 and E.top_value(item_named(bass, "Bass 1").text, "MUTE") ~= "1 0", "the song is as it was")
  local restored = new_events()
  local _, sent = look(A, true)
  assert(#sent == 0, "nothing more goes out as the person's own edit after it (" .. #sent .. ")")
  for _, ev in ipairs(restored) do if ev.type == "obj" then assert(ev.act == act and ev.restored, "every change the Restore sent is one act (" .. tostring(ev.oid) .. ")") end end
  tick()
  recv(B)
  same(A, B, "a whole-song Restore across a tempo change")
  -- Undo this change on any of its rows takes all of it back, as one step (nothing of the person's own is mixed in)
  local all = recall.entries(A.cfg, song, room)
  local j, n = nil, 0
  for i, e in ipairs(all) do if e.act == act then j = j or i; n = n + 1 end end
  local _, ids = mirror.plan_undo_moment(all, j)
  assert(n > 0 and #ids == n, "Undo this change on a row of the Restore covers all " .. n .. " of its changes (" .. #ids .. ")")
  -- (rt-history2's limit) an item last changed before a tempo change, restored to a point after it, goes onto its beat on the map in place
  local tf = { { time = 0, bpm = 120 } }
  local tt = { { time = 0, bpm = 60 } }
  local item = "<ITEM\nPOSITION 8\nLENGTH 2\nNAME \"x\"\n>"
  local r = mirror.retime(item, tf, tt, 1)
  assert(r:find("\nPOSITION 16\n", 1, true) and r:find("\nLENGTH 4\n", 1, true), "beats (position, length, rate): its beat and length in beats kept (" .. r .. ")")
  r = mirror.retime(item, tf, tt, 2)
  assert(r:find("\nPOSITION 16\n", 1, true) and r:find("\nLENGTH 2\n", 1, true), "beats (position only)")
  assert(mirror.retime(item:gsub("\n>", "\nBEAT 0\n>"), tf, tt, 1) == item:gsub("\n>", "\nBEAT 0\n>"), "an item set to time stays")
  assert(mirror.retime(item, tf, tt, 0) == item, "a project in time stays")
  assert(mirror.retime(item, tf, { { time = 0, bpm = 60, linear = true } }, 1) == item, "(a gradual tempo change isn't converted: left as stored)")
  -- end to end: the desktop's tempo goes to 60 from the start, Gtr (at 2 s, beat 4, under 120) is deleted, then put back from its version made
  -- under 120: on beat 4 under 60, at 4 s
  local v_gtr
  for _, e in ipairs(recall.entries(A.cfg, song, room)) do if e.kind == "obj" and e.name == "Gtr" and e.obj == "item" and not e.gone then v_gtr = v_gtr or e end end
  tick()
  as(A)
  reaper.SetTempoTimeSigMarker(A.F.proj, 0, 0, -1, -1, 60, 4, 4, false)
  for i = reaper.CountTempoTimeSigMarkers(A.F.proj) - 1, 1, -1 do reaper.DeleteTempoTimeSigMarker(A.F.proj, i) end
  tick()
  settle(A, true)
  tick()
  as(A)
  reaper.DeleteTrackMediaItem(gtr, gtr.items[1])
  tick()
  settle(A, true)
  as(A)
  res = mirror.revert(A.F.proj, A.cfg, song, room, { [v_gtr.oid] = v_gtr }, { can = yes, mode = "open", at_once = true,
    map_of = function(ev) return ev.id == v_gtr.id and tf or nil end })
  assert(gtr.items[1] and math.abs(pos(gtr.items[1]) - 4) < 1e-6 and math.abs(len(gtr.items[1]) - 12) < 1e-6,
    "a take restored from a version made under another map lands on its beat (" .. tostring(gtr.items[1] and pos(gtr.items[1])) .. ", " .. tostring(res) .. ")")
  tick()
  settle(A, true)
  tick()
  recv(B)
  same(A, B, "a take put back onto its beat")
  -- (rt-p1b) automation restored from a version made under another map: its points onto their beats too (mirror.retime_env), not its seconds
  local v_env, d_oid = nil, select(2, A.F.raw.GetSetMediaTrackInfo_String(drums, "P_EXT:band_oid", "", false)):upper()
  for _, e in ipairs(recall.entries(A.cfg, song, room)) do if e.kind == "obj" and e.obj == "env" and not e.gone and tostring(e.track):upper() == d_oid then v_env = v_env or e end end
  assert(v_env and type(v_env.state) == "string" and v_env.state:find("\nPT 4 0.5 0\n", 1, true), "Drums' first automation version, made under 120")
  tick()
  as(A)
  res = mirror.revert(A.F.proj, A.cfg, song, room, { [v_env.oid] = v_env }, { can = yes, mode = "open", at_once = true,
    map_of = function(ev) return ev.id == v_env.id and tf or nil end })
  local pts = {}
  for t in select(2, reaper.GetEnvelopeStateChunk(reaper.GetTrackEnvelope(drums, 0), "", false)):gmatch("\nPT (%S+)") do pts[#pts + 1] = tonumber(t) end
  assert(#pts == 4 and pts[2] == 8 and pts[3] == 16 and pts[4] == 24, "the points of a version made under 120 sit on their beats under 60 (" .. table.concat(pts, " ") .. ", " .. tostring(res) .. ")")
  tick()
  settle(A, true)
  tick()
  recv(B)
  same(A, B, "automation put back onto its beats")
  print("rt-edits: a Restore across a tempo change is whole, sends nothing more as yours, and Undo takes it back as one; a take lands on its beat")
end
-- ---- (round 6) and an Undo that carries a timeline change: what REAPER moves for the map outside the act (a bandmate's item added since) isn't
-- the person's edit either ----
do
  build("Edits undo tempo")
  tick()
  as(A)
  reaper.SetTempoTimeSigMarker(A.F.proj, -1, 2, -1, -1, 90, 4, 4, false)
  tick()
  settle(A, true)
  tick()
  recv(B)
  as(B)
  local bgtr
  for _, t in ipairs(B.F.tracks) do if t.name == "Gtr" then bgtr = t end end
  B.F.add_item(bgtr, audio(20, 2, "late.flac", "Late"))
  tick()
  settle(B, true)
  tick()
  recv(A)
  same(A, B, "(a bandmate's item after the tempo change)")
  tick()
  as(A)
  local res, why = press(false)
  assert(res, "the tempo change is undone (" .. tostring(why) .. ")")
  new_events()
  local _, sent = look(A, true)
  local names = {}
  for _, ev in ipairs(sent) do names[#names + 1] = tostring(ev.name or ev.type) end
  assert(#sent == 0, "what REAPER moved for the map, outside the act, doesn't go out as yours (" .. table.concat(names, ", ") .. ")")
  tick()
  recv(B)
  same(A, B, "an Undo of a tempo change, with a bandmate's item since")
  print("rt-edits: an Undo that puts a tempo map back sends nothing more as yours")
end
-- ---- (round 7) REAPER recheck, 0.59.49.80: the desktop's own 90 bpm marker sent 11 items as yours and auto-claimed all three tracks. They
-- travel (made under their map, `tl`), but a move that is only the tempo map's isn't work on a track: no auto-claim ----
do
  build("Edits tempo claim")
  local claimed = {}
  local function claims_look()
    as(A)
    A.F.clock = A.F.clock + 1
    sync.watch_timeline(A.F.proj, A.cfg, song, room, yes)
    mirror.watch(A.F.proj, A.cfg, song, room, { can = yes, mode = "open", quick = true, sent = function(_, name) claimed[name] = (claimed[name] or 0) + 1 end })
    return new_events()
  end
  tick()
  as(A)
  reaper.SetTempoTimeSigMarker(A.F.proj, -1, 2, -1, -1, 90, 4, 4, false)
  local items = 0
  for _ = 1, 6 do for _, ev in ipairs(claims_look()) do if ev.obj == "item" then items = items + 1; assert(ev.tl, "(made under its map)") end end end
  local names = {}
  for n in pairs(claimed) do names[#names + 1] = n end
  assert(items >= 5 and #names == 0, "what only the tempo map moved goes out (" .. items .. " items) and claims nothing (" .. table.concat(names, ", ") .. ")")
  -- a real edit in the same seconds still claims its track
  tick()
  as(A)
  set(item_named(bass, "Bass 3"), "MUTE", "1 0")
  claims_look()
  assert(claimed.Bass == 1, "an edit made just after the tempo change still claims its track")
  -- (backlog 1.10, rt-p1) and so does an item moved by hand in those seconds: off the beat the map would have kept it on
  tick()
  as(A)
  local d1 = item_named(drums, "Drums 1")
  set(d1, "POSITION", f(tonumber(E.top_value(d1.text, "POSITION")) + 0.5))
  claims_look()
  assert(claimed.Drums == 1, "an item moved by hand just after the tempo change claims its track (" .. tostring(claimed.Drums) .. ")")
  tick()
  recv(B)
  same(A, B, "a tempo change that claimed nothing")
  print("rt-edits: a move that is only the tempo map's travels and claims nothing")
end

-- ---- (round 6) REAPER recheck, 0.59.49.79: one Keep logged "Not sent: LinuxBox kept XT Rec A" 10 times; the put-back of a kept deleted track
-- left REAPER's "Remove tracks" on top of the undo list; a second delete 46 s after a Keep was put back without a word of why ----
do
  build("Edits keep")
  local claimask = require("claimask")
  claimask._reset()
  local real_present = claimask.present
  claimask.present = function() return true end
  local b = { song = song, room = room }
  local who = { mode = "open", tracks = { drums = { user = "Bee", name = "Drums" } }, is_claimed = function(name) return name == "Drums" end }
  local back_n = 0
  local function claims_look(full)
    as(A)
    A.F.clock = A.F.clock + 1
    back_n = select(2, mirror.watch(A.F.proj, A.cfg, song, room, { can = function(_, name) return name ~= "Drums" end, mode = "open", quick = not full,
      is_claimed = who.is_claimed, owner_of = function(name) return name == "Drums" and "Bee" or "James" end,
      ask = function(name, p) return claimask.hold(A.cfg, b, who, name, p) end }))
    -- (as Live sync publishes after each look: this tab's unsent objects, read by Restore, Undo and the panel)
    local ids, key = {}, tostring(A.F.proj)
    for k in pairs(mirror.unsent) do if k:sub(1, #key) == key then ids[#ids + 1] = k:sub(#key + 1) end end
    table.sort(ids)
    reaper.SetExtState(band.SECTION, "unsent " .. key, table.concat(ids, ","), false)
    return new_events()
  end
  local function track_named(name) for _, t in ipairs(A.F.tracks) do if t.name == name then return t end end end
  local function lines(pat) local n = 0; for _, l in ipairs(logged) do if l:find(pat, 1, true) then n = n + 1 end end return n end
  -- (Drums in two named lanes. A stand-in for REAPER's lanes on a track made again before its items: a lane named while the track has no
  -- items keeps no name, so the kept track came back without them. Round 7)
  as(A)
  reaper.SetMediaTrackInfo_Value(drums, "I_NUMFIXEDLANES", 2)
  reaper.GetSetMediaTrackInfo_String(drums, "P_LANENAME:0", "Kit", true)
  reaper.GetSetMediaTrackInfo_String(drums, "P_LANENAME:1", "Room", true)
  tick()
  settle(A, true)
  tick()
  recv(B)
  same(A, B, "(Drums in named lanes)")
  local real_s = A.F.reaper.GetSetMediaTrackInfo_String
  A.F.reaper.GetSetMediaTrackInfo_String = function(tr, k, v, set)
    if set and k:find("^P_LANENAME:") and #tr.items == 0 then return true, "" end
    return real_s(tr, k, v, set)
  end
  tick()
  as(A)
  reaper.DeleteTrack(drums)
  assert(#claims_look() == 0 and not track_named("Drums"), "(deleting Bee's track asks her; held meanwhile)")
  assert(#claims_look() == 0 and reaper.GetExtState(band.SECTION, "unsent " .. tostring(A.F.proj)) ~= "", "(still held, and published as unsent)")
  local ask
  for _, a in pairs(claimask._out()) do ask = a end
  assert(ask and ask.state == "asked", "(one ask)")
  claimask.on_answer(A.cfg, b, { id = ask.id, from = "Bee", to = "James", answer = "keep" })
  logged, A.F.undos = {}, {}
  claims_look()
  local t = track_named("Drums")
  assert(t and #t.items == 4, "Keep: the track is back with its items")
  assert(lines("Not sent: Bee kept Drums") == 1, "the Keep's words are said once for its put-back, not once per thing (" .. lines("Not sent: Bee kept Drums") .. ")")
  assert(#A.F.undos == 1 and A.F.undos[1] == "StudioSync: put back what wasn't sent" and not undo.native(A.F.undos[1]),
    "the put-back is one StudioSync undo point on top, at once, so Ctrl+Z doesn't take it for your own edit (" .. table.concat(A.F.undos, " / ") .. ")")
  -- (round 7) the looks after see nothing left to put back: no second put-back, no cooldown line nobody's edit caused
  logged, A.F.undos = {}, {}
  claims_look(true)
  claims_look()
  assert(back_n == 0 and #logged == 0 and #A.F.undos == 0, "the full look after puts nothing back again (" .. back_n .. ": " .. table.concat(logged, " | ") .. ")")
  assert(select(2, real_s(track_named("Drums"), "P_LANENAME:1", "", false)) == "Room", "and its lanes have their names")
  settle(A, true)
  same(A, B, "a kept track: as it was everywhere")
  -- deleted again 46 s after the Keep: put back without asking (the cooldown), and told why and when it can ask
  A.F.clock = A.F.clock + 40
  tick()
  as(A)
  drums = track_named("Drums")
  reaper.DeleteTrack(drums)
  logged, A.F.undos = {}, {}
  claims_look()
  assert(track_named("Drums"), "(within a minute of the Keep: put back, not asked)")
  local said
  for _, l in ipairs(logged) do if l:find("kept Drums", 1, true) and l:find("s ago", 1, true) and l:find("edit it again in", 1, true) then said = l end end
  assert(said and lines("kept Drums") == 1, "and said once why, with when it can be asked again (" .. table.concat(logged, " | ") .. ")")
  assert(#A.F.undos == 1, "(one point)")
  A.F.reaper.GetSetMediaTrackInfo_String = real_s
  claimask.present = real_present
  claimask._reset()
  print("rt-edits: a Keep's put-back is said once, is one StudioSync undo point, and a delete in the minute after is told why")
end

-- ---- (round 6) REAPER recheck, 0.59.49.79: a heal's undo point and its log line didn't pair: a "caught up on 1 change" with no point (its
-- block was inside the receive's), a "changes that hadn't arrived here" point with no line, and an empty point when what it would bring waits ----
do
  build("Edits heal point")
  local rdir = sync.room_dir(A.cfg, song, room)
  local function skip_on_b(sent) -- (what went from the desktop is counted done on the laptop, never applied: as a skipped change)
    assert(#sent > 0, "(something went)")
    for _, ev in ipairs(sent) do as(B); sync.setext(B.F.proj, sync.APPLIED, ev.id, "1") end
  end
  tick()
  as(A)
  set(item_named(bass, "Bass 2"), "MUTE", "1 0")
  skip_on_b(select(2, look(A, true)))
  -- a heal is one undo point, its own; a receive pass never heals (heal_due, its heal at the end of a pass, went with the judge: rt-sync2b),
  -- and one with nothing new opens no point (the line "caught up on ..." is Live sync's, beside its heal)
  as(B)
  B.F.undos, logged = {}, {}
  B.F.clock = B.F.clock + 1
  sync.receive(B.F.proj, B.cfg, song, room, yes)
  assert(#B.F.undos == 0, "a receive with nothing new opens no point (" .. table.concat(B.F.undos, " / ") .. ")")
  assert(mirror.heal(B.F.proj, rdir, false) == 1 and #B.F.undos == 1 and B.F.undos[1] == "StudioSync: changes that hadn't arrived here",
    "one point, the heal's (" .. table.concat(B.F.undos, " / ") .. ")")
  same(A, B, "(healed)")
  -- automation that can't land while recording: no point opened for it
  tick()
  as(A)
  F = A.F
  shift_env(drums, 4, 0.5, 8)
  skip_on_b(select(2, look(A, true)))
  as(B)
  B.F.playing, B.F.undos = 5, {}
  assert(mirror.heal(B.F.proj, rdir, false) == 0 and #B.F.undos == 0, "what waits opens no point (" .. table.concat(B.F.undos, " / ") .. ")")
  B.F.playing = 0
  assert(mirror.heal(B.F.proj, rdir, false) == 1 and #B.F.undos == 1, "and lands, with its point, once stopped")
  same(A, B, "(automation healed)")
  print("rt-edits: a heal's undo point and its log line pair up")
end
-- ---- (rt-p1b, P6 item 2) a comp piece's change names the lane it came from (from_lane), for History's time lapse ----
do
  build("Edits comp")
  tick()
  as(A)
  F = A.F
  vox.vals.I_FREEMODE, vox.vals.I_NUMFIXEDLANES, vox.vals["C_LANEPLAYS:0"], vox.vals["C_LANEPLAYS:1"], vox.vals["C_LANEPLAYS:2"] = 2, 3, 1, 0, 0
  for k = 1, 2 do F.add_item(vox, audio(10, 8, "vox-take" .. k .. ".flac", "Vox take " .. k)).lane = k end
  F.changed()
  local got = {}
  settle(A, true, got)
  for _, ev in pairs(got) do assert(ev.obj ~= "item" or ev.from_lane == nil, "a source take names no lane (its lane doesn't play)") end
  tick()
  -- REAPER's comp area over 12-15 s from take 2: a piece in the playing lane, the same file, 2 s into it
  local piece = F.add_item(vox, audio(12, 3, "vox-take2.flac", "Vox take 2", { soffs = 2 }))
  piece.lane = 0
  local other = F.add_item(vox, audio(30, 2, "vox-take1.flac", "Vox take 1", { soffs = 1 })) -- (take 1's audio, off its alignment: not a piece of it)
  other.lane = 0
  F.changed()
  got = {}
  settle(A, true, got)
  local pe, oe = got[piece.ext.band_oid], got[other.ext.band_oid]
  assert(pe and pe.from_lane == 2, "the comp piece's change names lane 2 (index) it came from (" .. tostring(pe and pe.from_lane) .. ")")
  assert(oe and oe.from_lane == nil, "an item in the playing lane that isn't a stretch of another lane's names none")
  recv(B)
  same(A, B, "comp pieces")
  print("rt-edits: a comp piece's change names its source lane")
end
print("ok rt-edits")
