-- Quick looks (rt-look, docs/rt/rt-look.md): Live sync's look builds on the last one, reads only the tracks that may have changed, and puts
-- only what changed through W.one. This proves every kind of change the full look caught is still caught: an item moved (selected or not), a
-- MIDI note, an item's own settings, a plug-in knob turned with no undo point, an envelope point dragged, a send added, lanes, track order,
-- a write StudioSync recorded itself (never sent back or put back), an undo, and two edits at once where only one is hinted (caught by the read
-- of every chunk within QUICK_ALL_SECS, and logged when the full look finds it first). After every look, what the quick look believes each
-- object reads as is what a full scan reads. A medium project from tools/bigproject.lua, served by tests/fixtures/bigreaper.lua.
package.path = "tools/?.lua;lib/?.lua;tests/fixtures/?.lua;" .. package.path
local G = require("bigproject")
local m = G.model({ tracks = 30, folders = 3, returns = 2, sends = 6, fx = 60, items = 400, midi = 6, notes = 200, ccs = 100, env_points = 40, regions = 5, markers = 3 })
local F = require("bigreaper").new(m)
reaper = F.reaper
local files, logged = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) return files[path] end
proxy.write_json = function(path, v) files[path] = v; return true end
proxy.listing = function(dir)
  local out = {}
  for p in pairs(files) do local d, f = p:match("^(.*)/([^/]*)$"); if d == dir then out[#out + 1] = f end end
  return out
end
proxy.log = function(t) logged[#logged + 1] = t end
proxy.size = function() return 960044 end
proxy.copy_atomic = function() end
rawset(reaper, "file_exists", function() return true end)
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
local cfg = { user = "James", root = "C:/fake/StudioSync" }
local b = { song = "Look", room = "main" }
local yes = function() return true end
local opts = { can = yes, mode = "open", quick = true }
local pk = tostring(F.proj)
local media = sync.room_dir(cfg, b.song, b.room) .. "/media"

local events_seen = {}
for p in pairs(files) do events_seen[p] = true end
-- One look as Live sync makes it. -> sent, { oid = true } of the changes that went out, the kind of look ("quick"/"full")
local function look()
  local s0 = mirror.look_stats.full
  local sent = mirror.watch(F.proj, cfg, b.song, b.room, opts)
  local out = {}
  for p, v in pairs(files) do
    if not events_seen[p] then
      events_seen[p] = true
      if p:find("/events/", 1, true) and type(v) == "table" and v.oid then out[v.oid] = true end
    end
  end
  return sent, out, mirror.look_stats.full > s0 and "full" or "quick"
end
-- What the quick look believes every object reads as is what a full scan reads now. (After one more look: a send can rewrite what it sent, its
-- file moved into the studio's media, and the look after reads that.)
local it2
local function same_as_full(what)
  F.clock = F.clock + 1
  look()
  local L = mirror.looks[pk]
  local objs = mirror.scan(F.proj, cfg.user, media, false)
  local n = 0
  for _, o in ipairs(objs) do
    n = n + 1
    assert(L.raw[o.oid] == o.hash, what .. ": the look's view of " .. o.oid .. " (" .. o.kind .. ") is what a full scan reads")
  end
  local m2 = 0
  for _ in pairs(L.raw) do m2 = m2 + 1 end
  assert(m2 == n, what .. ": the same objects (" .. m2 .. " vs " .. n .. ")")
end
local function track_of(it) return it.track end
local function oid_of_item(it) return select(2, F.raw.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false)):upper() end
local function oid_of_track(t) return select(2, F.raw.GetSetMediaTrackInfo_String(t, "P_EXT:band_oid", "", false)):upper() end
local function part(t, p) return p .. oid_of_track(t):sub(2) end
local select_items = {}
rawset(reaper, "CountSelectedMediaItems", function() return #select_items end)
rawset(reaper, "GetSelectedMediaItem", function(_, i) return select_items[i + 1] end)
local function chunk_reads() return F.calls.GetTrackStateChunk or 0 end
-- (a JS plug-in's knobs read through the API as its chunk holds them, as REAPER's do: a knob turned with no window open is told from a plug-in
-- changing its own data by them)
rawset(reaper, "TrackFX_GetParamNormalized", function(t, i, p)
  local fx = t.fx and t.fx[i + 1]
  local v = fx and fx.params and select(p + 1, table.unpack((function() local o = {} for x in fx.params:gmatch("%S+") do o[#o + 1] = x end return o end)()))
  return (tonumber(v) or 50) / 100
end)
-- (the model edited as REAPER would show it: a chunk StudioSync wrote (raw) gives way to the model's, which holds what it wrote)
local function item_edit(x, undo) x.raw, x.chunk = nil, nil; x.track.raw, x.track.chunk = nil, nil; if undo then F.cc = F.cc + 1 end end
local function track_edit(t, undo) t.raw, t.chunk = nil, nil; if undo then F.cc = F.cc + 1 end end

-- ---- mirror.normalize_item's MIDI fast path gives what it gave before (the previous body, here as it was) ----
do
  local LOCAL_SET = {}
  for _, k in ipairs({ "SEL", "IGUID", "IID", "GUID", "POOLEDEVTS", "POOLCOLOR", "CFGEDITVIEW", "CFGEDIT", "EVTFILTER", "KEYSNAP", "TRACKSEL", "GROUP", "VELLANE" }) do LOCAL_SET[k] = true end
  local function ext_travels(key) return key == "band_oid" or key:sub(1, 7) == "band_m_" end
  local TAKE_ENV_VIEW = { EGUID = true, VIS = true, LANEHEIGHT = true, ARM = true }
  local function normalize_before(chunk)
    local out, in_ext, fx = {}, false, {} -- (fx: the blocks open inside a take's <TAKEFX chain, empty outside it)
    local tenv = false -- (inside a take's envelope)
    for line in chunk:gmatch("[^\r\n]+") do
      local s = line:match("^%s*(.-)%s*$")
      local key = s:match("^(%S+)")
      if #fx == 0 and not tenv and key and key:match("^<%u+ENV%d*$") then tenv = true elseif tenv and s == ">" then tenv = false end
      local parent = fx[#fx]
      if #fx > 0 then
        if s:sub(1, 1) == "<" then fx[#fx + 1] = s:match("^<(%S+)") elseif s == ">" then fx[#fx] = nil end
      elseif s == "<TAKEFX" then fx[1] = "TAKEFX" end
      if mirror.chain_local(parent, key) then -- (a take plug-in's window opened or moved isn't a change)
      elseif in_ext then
        if s == ">" then in_ext = false; out[#out + 1] = s
        elseif key and ext_travels(key) then out[#out + 1] = s end
      elseif s == "<EXT" or s == "<EXTI" then -- (REAPER writes an item's P_EXT as <EXTI, a track's or take's as <EXT)
        in_ext = true; out[#out + 1] = s
      elseif key == "TAKE" then
        -- ("TAKE SEL" marks the active take, which travels as BANDTAKE. An empty take stays one, "TAKE NULL": as a bare "TAKE" it arrived as a
        -- real take with nothing in it, and the item never read back as it was sent. Review, 0.58.87)
        out[#out + 1] = s:match("^TAKE%s+NULL") and "TAKE NULL" or "TAKE"
      elseif s == "<SOURCE MIDIPOOL" then
        out[#out + 1] = "<SOURCE MIDI" -- (a pooled copy arrives as an item of its own: REAPER writes it as plain MIDI there)
      elseif s:match("^[ex]m? ") or s:match("^<x ") then
        out[#out + 1] = s:gsub("^(<?)(.)", function(lt, c) return lt .. c:upper() end, 1)
      elseif tenv and TAKE_ENV_VIEW[key] then -- (left out)
      elseif not (key and LOCAL_SET[key]) then
        out[#out + 1] = s
      end
    end
    -- an <EXT> block left empty by the filter is dropped
    return (table.concat(out, "\n"):gsub("<EXTI?\n>\n?", "")) .. "\n"
  end

  local n = 0
  for _, t in ipairs(m.tracks) do for _, x in ipairs(t.items) do
    local c = G.item_chunk(m, x)
    assert(mirror.normalize_item(c) == normalize_before(c), "normalize_item as before: " .. x.name); n = n + 1
  end end
  local odd = "<ITEM\nPOSITION 1\n<EXTI\nE 1 2 3\nband_oid I-X\n>\n  E 5 90 3c 60\nE 6 90 3c 60 \ne 7 90 3c 60\nE 8\n<SOURCE MIDI\nE 1 b0 01 40\nE\nE 2 b0\n>\n<TAKEFX\n<VST x\nE 9\n>\n>\n>\n"
  assert(mirror.normalize_item(odd) == normalize_before(odd), "normalize_item as before: indented, trailing space, selected, inside an EXT block and a take FX")
end

-- ---- the first look sends everything; past the plug-ins' loading minute, looks are quick ----
repeat F.clock = F.clock + 1 until select(1, look()) == 0 and not mirror.more
F.clock = F.clock + 70
look(); look()
local sent, out, kind = look()
assert(sent == 0 and kind == "quick", "nothing changed: a quick look, nothing sent (" .. sent .. ", " .. kind .. ")")
same_as_full("idle")
-- an idle look's hints find nothing, so it reads every chunk (anything with no undo point is still seen)
F.reset_counts(); look()
assert(chunk_reads() == #m.tracks + 1, "nothing hinted: every chunk read (" .. chunk_reads() .. ")")

-- ---- an item moved, not selected (a script's): the read of every chunk finds it ----
local audio
for _, t in ipairs(m.tracks) do if not audio and #t.items > 3 and not t.items[1].midi then audio = t end end
local it = audio.items[2]
F.move(it, 0.25)
sent, out, kind = look()
assert(kind == "quick" and out[oid_of_item(it)] and sent == 1, "an unselected item moved: caught by a quick look, alone")
same_as_full("item moved")

-- ---- an item moved while selected: only its track's chunk (and the master's) is read ----
F.clock = F.clock + 1; look() -- (the last look's send: its track was read once more)
select_items = { audio.items[3] }
F.move(audio.items[3], -0.1)
F.reset_counts()
sent, out, kind = look()
assert(out[oid_of_item(audio.items[3])] and sent == 1, "a selected item moved: sent")
assert(chunk_reads() == 2, "and only its track's chunk read, besides the master's (" .. chunk_reads() .. ")")
same_as_full("selected item moved")
select_items = {}

-- ---- a MIDI note's velocity (the piano roll) ----
local mit
for _, t in ipairs(m.tracks) do for _, x in ipairs(t.items) do if x.midi and not mit then mit = x end end end
F.clock = F.clock + 1; look()
F.midi_edit(mit, 7, 101)
sent, out = look()
assert(out[oid_of_item(mit)] and sent == 1, "one MIDI note changed: sent")
same_as_full("MIDI note")

-- ---- an item's own settings: its volume, then its mute ----
F.clock = F.clock + 1; look()
it2 = audio.items[4]
it2.vol = 0.123; item_edit(it2, true)
sent, out = look()
assert(out[oid_of_item(it2)] and sent == 1, "an item's volume: sent")
F.clock = F.clock + 1; look()
F.raw.SetMediaItemInfo_Value(it2, "B_MUTE", 1 - it2.mute); item_edit(it2)
sent, out = look()
assert(out[oid_of_item(it2)] and sent == 1, "an item's mute: sent")
same_as_full("item settings")

-- ---- a plug-in knob turned with no undo point (no change count), its window never open ----
F.clock = F.clock + 1; look()
local ft
for _, t in ipairs(m.tracks) do if not ft and t ~= audio and t.fx[1] and t.fx[1].kind == "JS" and #t.items > 0 then ft = t end end
ft.fx[1].params = ft.fx[1].params:gsub("^%S+", "7.77"); track_edit(ft) -- (no undo point: no change count)
sent, out = look()
assert(sent == 0 and math.abs(mirror.settle_due - (F.clock + mirror.SETTLE_SECS)) < 1e-9, "a chain changed with no undo point waits to settle, and says when it's due")
F.clock = mirror.settle_due + 0.001
sent, out = look()
assert(out[part(ft, "F")] and sent == 1 and not mirror.settle_due, "the knob turned with no undo point: sent once settled")
same_as_full("knob, no undo point")

-- ---- an envelope point dragged (same number of points) ----
F.clock = F.clock + 1; look()
audio.volenv[5][2] = 0.4321; track_edit(audio, true)
sent, out = look()
assert(out[part(audio, "E")], "an envelope point set with an undo point: sent by the first look, no settling (it took 4.2 s)")
same_as_full("envelope point")

-- ---- a send added: the return's receives ----
F.clock = F.clock + 1; look()
local ret = m.tracks[#m.tracks]
audio.sends[#audio.sends + 1] = ret.i
G.wire_receives(m); track_edit(ret, true)
sent, out = look()
assert(out[part(ret, "R")], "a send added: the return's receives sent")
same_as_full("send")

-- ---- lanes: fixed lanes on, three of them ----
F.clock = F.clock + 1; look()
F.raw.SetMediaTrackInfo_Value(audio, "I_FREEMODE", 2); F.raw.SetMediaTrackInfo_Value(audio, "I_NUMFIXEDLANES", 3)
sent, out = look()
assert(out[oid_of_track(audio)], "lanes: the track's settings sent")
same_as_full("lanes")

-- ---- StudioSync's own write with its record (a bandmate's change landing): neither sent back nor put back, and the look sees it as it is ----
F.clock = F.clock + 1; look()
local it3 = audio.items[1]
it3.vol = 0.9; item_edit(it3, true)
do
  local objs, by = mirror.scan(F.proj, cfg.user, media, false)
  local o = by[oid_of_item(it3)]
  local rev, _, evid, order = mirror.known(F.proj, o.oid)
  mirror.remember(F.proj, o.oid, (rev or 0) + 1, o.hash, evid, order)
  local _ = objs
end
sent, out = look()
assert(sent == 0 and not next(out), "a write recorded as it is: nothing sent or put back (" .. sent .. ")")
same_as_full("recorded write")

-- ---- track order: two tracks swapped (a full look: where every track sits changed) ----
F.clock = F.clock + 1; look()
local a_i, b_i = 5, 6
m.tracks[a_i], m.tracks[b_i] = m.tracks[b_i], m.tracks[a_i]
F.reindex(); F.changed()
sent, out, kind = look()
assert(kind == "full" and sent > 0, "tracks reordered: a full look, the move sent (" .. sent .. ", " .. kind .. ")")
F.clock = F.clock + 1; look()
same_as_full("track order")

-- ---- an undo: the next look is a full one ----
F.clock = F.clock + 1; look()
local redo = nil
rawset(reaper, "Undo_CanRedo2", function() return redo end)
redo = "Move items"
F.move(audio.items[2], -0.25)
sent, out, kind = look()
assert(kind == "full" and out[oid_of_item(audio.items[2])], "an undo: a full look, and what it put back goes out")
redo = nil
F.clock = F.clock + 1; look()

-- ---- two edits at once, only one hinted: the other is caught by the read of every chunk within QUICK_ALL_SECS ----
F.clock = F.clock + 1; look()
local bt
for _, t in ipairs(m.tracks) do if not bt and t ~= audio and t ~= ft and t.fx[1] and t.fx[1].kind == "JS" then bt = t end end
select_items = { audio.items[3] }
F.move(audio.items[3], 0.05)
bt.fx[1].params = bt.fx[1].params:gsub("^%S+", "3.33"); track_edit(bt)
sent, out, kind = look()
assert(kind == "quick" and out[oid_of_item(audio.items[3])] and not out[part(bt, "F")], "the hinted edit went; the other wasn't seen yet")
select_items = {}
local missed0 = mirror.look_stats.missed
F.clock = F.clock + mirror.QUICK_ALL_SECS
look(); F.clock = F.clock + 4
sent, out, kind = look()
assert(out[part(bt, "F")] and kind == "quick", "the other edit: caught by the read of every chunk")
assert(mirror.look_stats.missed == missed0, "and that's not a miss of the full look")

-- ---- ...and when the full look comes first, it's caught there and logged ----
F.clock = F.clock + 1; look()
local now0 = F.clock
select_items = { audio.items[3] }
F.move(audio.items[3], 0.05)
bt.fx[1].params = bt.fx[1].params:gsub("^%S+", "4.44"); track_edit(bt)
F.clock = mirror.looks[pk].full_at + mirror.QUICK_FULL_SECS
mirror.looks[pk].all_at = F.clock - 1 -- (every chunk was read a moment ago: the quick look would go by its hints alone)
local nlog = #logged
sent, out, kind = look()
assert(kind == "full" and mirror.look_stats.missed > missed0, "the full look: it found what the quick one would have missed")
local said = false
for i = nlog + 1, #logged do if logged[i]:find("the full look found", 1, true) then said = true end end
assert(said, "and said so in the log")
select_items = {}
F.clock = F.clock + 4; look()
local _ = now0

-- ---- a write StudioSync makes without a record (mirror.touch): read at the next look ----
F.clock = F.clock + 1; look()
it3.vol = 0.33; item_edit(it3) -- (no change count, no hint)
select_items = { audio.items[5] } -- (and a hinted track that didn't change: the hints find nothing, every chunk is read anyway)
mirror.touch(F.proj, audio)
F.reset_counts()
sent, out = look()
assert(out[oid_of_item(it3)], "a touched track: read, and its change goes")
select_items = {}
same_as_full("touched")

-- ---- many single edits in a row, each followed by one quick look: the look's view is always what a full scan reads ----
local r = 12345
local function rnd(n) r = (r * 48271) % 2147483647; return r % n + 1 end
for step = 1, 40 do
  F.clock = F.clock + 1
  local t = m.tracks[rnd(#m.tracks)]
  local k = rnd(6)
  if k == 1 and #t.items > 0 then F.move(t.items[rnd(#t.items)], 0.01 * rnd(9))
  elseif k == 2 and #t.items > 0 then local x = t.items[rnd(#t.items)]; x.vol = rnd(90) / 100; item_edit(x, true)
  elseif k == 3 then F.raw.SetMediaTrackInfo_Value(t, "D_VOL", rnd(100) / 100)
  elseif k == 4 and t.fx[1] and t.fx[1].kind == "JS" then t.fx[1].params = t.fx[1].params:gsub("^%S+", tostring(rnd(999) / 100)); track_edit(t)
  elseif k == 5 then t.volenv[rnd(#t.volenv)][2] = rnd(100) / 100; track_edit(t, true)
  elseif k == 6 then F.raw.GetSetMediaTrackInfo_String(t, "P_NAME", "Renamed " .. step, true) end
  look()
  same_as_full("edit " .. step .. " (kind " .. k .. ")")
end
print("rt-look: quick " .. mirror.look_stats.quick .. ", full " .. mirror.look_stats.full .. ", every chunk " .. mirror.look_stats.all_chunks .. ", missed " .. mirror.look_stats.missed)
print("ok rt look")
