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
proxy.session_path = function() return "SESSION" end
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
local function timeline(c)
  as(c)
  local m = band.capture_markers(c.F.proj)
  return band.json_encode({ band.capture_tempo(c.F.proj), m })
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
  mirror.watch(c.F.proj, c.cfg, song, room, { can = yes, mode = "open", quick = quick })
  sync.watch_timeline(c.F.proj, c.cfg, song, room, yes)
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
  { name = "a tempo change under items in time (audio stays where it is)", min = 0, timeline = true, undo = false, edit = function()
    reaper.SetTempoTimeSigMarker(F.proj, -1, 32, -1, -1, 100, 4, 4, false)
  end },
  { name = "a tempo change under items in beats (REAPER moves them)", min = 1, timeline = true, edit = function()
    reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, 132, 4, 4, false)
    for _, it in ipairs(items(keys)) do set(it, "POSITION", f(pos(it) * 120 / 132)); set(it, "LENGTH", f(len(it) * 120 / 132)) end
  end },
  { name = "a track template inserted (from a shared track: its items carry the studio's ids)", min = 2, full = true, edit = function()
    local t = F.add_track("Drums (template)", 3)
    local c = F.track_chunk(drums):gsub("<TRACK [^\n]*", "<TRACK " .. E.guid()):gsub("NAME \"Drums\"", "NAME \"Drums (template)\""):gsub("\nIGUID [^\n]*", "")
    F.set_track_chunk(t, c)
  end },
  { name = "an item moved to another track", min = 1, edit = function()
    local it = item_named(bass, "Bass 0")
    reaper.MoveMediaItemToTrack(it, gtr)
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
local renames = 0
local function run(mode)
  local quick = mode == "quick"
  for _, case in ipairs(cases) do
    local what = mode .. " | " .. case.name
    if os.getenv("RT_EDITS_TRACE") then io.stderr:write(what, "\n") end
    tick()
    local before = state(A)
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
      local res, why = undo.step(A.F.proj, A.cfg, { song = song, room = room }, false, {})
      assert(res, what .. ": undone (" .. tostring(why) .. ")")
      settle(A, quick)
      tick()
      recv(B)
      same(A, B, what .. ": undone the same on the laptop")
      local after = state(A)
      local gtr_oid = select(2, A.F.raw.GetSetMediaTrackInfo_String(gtr, "P_EXT:band_oid", "", false)):upper()
      for oid, h in pairs(before) do
        if oid ~= gtr_oid then assert(after[oid] == h, what .. ": one Ctrl+Z put " .. oid .. " back (" .. tostring(h) .. " vs " .. tostring(after[oid]) .. ")") end
      end
      for oid in pairs(after) do assert(before[oid], what .. ": one Ctrl+Z took away what the edit made (" .. oid .. ")") end
      assert(gtr.name == "Gtr " .. renames, what .. ": the laptop's rename stays (" .. tostring(gtr.name) .. ")")
      -- redo, so the next case builds on it (and redo is one key too)
      tick()
      as(A)
      assert(undo.step(A.F.proj, A.cfg, { song = song, room = room }, true, {}), what .. ": redone")
      settle(A, quick)
      tick()
      recv(B)
      same(A, B, what .. ": redone the same on the laptop")
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

-- ---- REAPER check, 0.59.49.69: a render-matrix tick and a renumbering on the desktop, the laptop held ----
-- In REAPER the desktop sent both within a second, but the laptop's Cross Test had Hold on (the colour try's, from before the fix). Live sync
-- doesn't look at the timeline while held, so its "seen" stayed in TIMELINE_FORMAT 4; the new fields read as a change of its own, and every map
-- and marker from the band waited for good (sync.timeline_waits). Here: both edits made with no change count moved, through Live sync's pass
-- (quick look, then the timeline's look); then the laptop, held with an older-format "seen", takes them; a real held marker edit still waits.
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
  -- the laptop, held, its "seen" written by the older StudioSync
  as(B)
  local SEC = band.SECTION
  reaper.SetProjExtState(B.F.proj, SEC, "hold", "1")
  local seen = band.json_decode(select(2, reaper.GetProjExtState(B.F.proj, SEC, "timeline")))
  for _, m in ipairs(seen[2]) do m.num, m.render = nil, nil end
  seen[4] = 4
  reaper.SetProjExtState(B.F.proj, SEC, "timeline", band.json_encode(seen))
  tick()
  B.F.clock = B.F.clock + 1
  sync.receive(B.F.proj, B.cfg, song, room, yes)
  assert(numbers_of(B) == numbers_of(A), "held, the laptop took the renumbering: " .. numbers_of(A) .. " vs " .. numbers_of(B))
  assert(matrix_of(B) == matrix_of(A), "and the render matrix: " .. matrix_of(A) .. " vs " .. matrix_of(B))
  -- a held edit of its own to the markers still holds the band's back
  region1(B).name = "Verse (held)"
  B.F.changed()
  tick()
  as(A)
  A.F.add_marker(false, 30, 30, "Outro")
  look(A, true)
  as(B)
  B.F.clock = B.F.clock + 1
  sync.receive(B.F.proj, B.cfg, song, room, yes)
  local outro = false
  for _, m in ipairs(B.F.markers) do if m.name == "Outro" then outro = true end end
  assert(not outro and region1(B).name == "Verse (held)", "a held marker edit of yours still holds the band's timeline back")
  reaper.SetProjExtState(B.F.proj, SEC, "hold", "")
  print("rt-edits: the render matrix and a renumbering go in Live sync's next pass, and land on a held laptop with an older-format timeline")
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
print("ok rt-edits")
