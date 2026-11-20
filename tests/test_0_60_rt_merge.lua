-- rt-merge (James, 2026-11-20: "2 people can edit a midi item at the same time, adding different notes and such. But in cases where editing at
-- the same time wouldn't make sense then do the 3s or warn only"): two computers (the desktop, James; the laptop, Bee) edit the same thing at
-- the same moment, each sending before the other's change lands, in the chunk-faithful stand-in REAPER (tests/fixtures/editreaper.lua). Both
-- must end the same, with:
--   MIDI notes merged note by note (different notes both stay; the same note changed by both: the winner's, the loser told);
--   envelope points merged point by point; item and track settings setting by setting;
--   the same setting changed by both: the later stands everywhere, the other told (with Use mine);
--   a deletion against an edit: the deletion, everywhere;
--   one Ctrl+Z after a merge, on each side: only that person's change goes back;
--   a bandmate editing the same item: your edit goes out, said, never put back (the 15 s hold is gone).
-- docs/rt/rt-merge.md. Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local E = require("editreaper")
local f = E.f

local real_date, real_time = os.date, os.time
local now_t = real_time({ year = 2026, month = 11, day = 20, hour = 15, min = 0, sec = 0 })
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
proxy.session_path = function() return "SESSION" end
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
require("direct").send_live = function() return true end
require("prints").choose = function() end
mirror.FX_SET_GAP = 0
local undo = require("undo")
local ROOT = "C:/fake/StudioSync"
local song, room = "Merge", "main"
local yes = function() return true end
local MEDIA

local function computer(user, path)
  local c = { F = E.new(path), cfg = { user = user, root = ROOT } }
  c.F.reaper.MB = function() return 6 end -- (Undo asks when a bandmate changed it since: yes)
  c.F.reaper.GetMousePosition = function() return 0, 0 end -- (sync.put_back's tip goes by the mouse)
  return c
end
local A, B
local function as(c) reaper = c.F.reaper end
local function state(c)
  as(c)
  local out = {}
  for _, o in ipairs(mirror.scan(c.F.proj, c.cfg.user, MEDIA, false)) do out[o.oid] = o.hash end
  return out
end
local function same(what)
  local sa, sb = state(A), state(B)
  for oid, h in pairs(sa) do assert(sb[oid] == h, what .. ": " .. oid .. " reads the same on both (" .. tostring(h) .. " vs " .. tostring(sb[oid]) .. ")") end
  for oid in pairs(sb) do assert(sa[oid], what .. ": the laptop has nothing the desktop hasn't (" .. oid .. ")") end
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
local rules = {} -- user -> { can, claimed, soft }: Claims mode with a bandmate's auto-claim (the last section); nothing: anyone may
local function look(c, held)
  as(c)
  c.F.clock = c.F.clock + 1
  local r = rules[c.cfg.user] or {}
  mirror.watch(c.F.proj, c.cfg, song, room, { can = r.can or yes, is_claimed = r.claimed, mode = "open", quick = true, held = held, soft = r.soft })
  local oids = {}
  for _, ev in ipairs(new_events()) do if ev.oid then oids[ev.oid] = ev end end
  return oids
end
local function settle(c, into)
  for _ = 1, 20 do
    local o = look(c)
    local n = 0
    for oid, ev in pairs(o) do n = n + 1; if into then into[oid] = ev end end
    if n == 0 and not mirror.more and not mirror.unsettled then return end
    mirror.unsettled = nil
  end
  error("never settled")
end
local function recv(c)
  as(c)
  for _ = 1, 20 do
    c.F.clock = c.F.clock + 1
    local r = rules[c.cfg.user] or {}
    sync.soft = r.soft and { room = room, fn = r.soft } or nil
    local got = sync.receive(c.F.proj, c.cfg, song, room, r.can or yes)
    if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
  end
  for _ = 1, 3 do
    for oid, ev in pairs(look(c)) do error(c.cfg.user .. " sent back what landed: " .. oid .. " " .. tostring(ev.state):sub(1, 300)) end
  end
end
-- both edit, both send, then each takes the other's in
local function at_once(edit_a, edit_b)
  tick()
  as(A); edit_a()
  as(B); edit_b()
  tick()
  local sa, sb = {}, {}
  settle(A, sa)
  settle(B, sb)
  tick()
  recv(A)
  recv(B)
  return sa, sb
end

-- ---- the song ----
local function audio(pos, len, file, name)
  return table.concat({ "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 1", "ALLTAKES 0", "FADEIN 1 0.01 0 1 0 0 0", "FADEOUT 1 0.01 0 1 0 0 0",
    "MUTE 0 0", "SEL 0", "IID 1", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0", "GUID " .. E.guid(),
    "<SOURCE WAVE", 'FILE "' .. MEDIA .. "/" .. file .. '"', ">", ">" }, "\n") .. "\n"
end
local NOTES = { "E 0 90 3c 60", "E 480 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 960 b0 7b 00" }
local function midi(pos, len, name)
  local t = { "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 0", "ALLTAKES 0", "FADEIN 1 0 0 1 0 0 0", "FADEOUT 1 0 0 1 0 0 0", "MUTE 0 0", "SEL 0",
    "IID 2", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0", "GUID " .. E.guid(),
    "<SOURCE MIDI", "HASDATA 1 960 QN", "CCINTERP 32" }
  for _, n in ipairs(NOTES) do t[#t + 1] = n end
  for _, l in ipairs({ "GUID " .. E.guid(), "IGNTEMPO 0 120 4 4", ">", ">" }) do t[#t + 1] = l end
  return table.concat(t, "\n") .. "\n"
end
local ENV = "<VOLENV2\nEGUID {E1}\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 4 0.5 0\nPT 8 1 0\nPT 12 0.7 0\n>\n"
local drums, bass, keys, gtr
local function build(name)
  song = name
  MEDIA = sync.room_dir({ root = ROOT }, song, room) .. "/media"
  A, B = computer("James", "C:/A/" .. name .. ".rpp"), computer("Bee", "C:/B/" .. name .. ".rpp")
  local F = A.F
  drums = F.add_track("Drums", nil, ENV)
  bass = F.add_track("Bass")
  keys = F.add_track("Keys")
  gtr = F.add_track("Gtr")
  for i = 0, 3 do F.add_item(drums, audio(i * 4, 3.5, "drums" .. i .. ".flac", "Drums " .. i)) end
  for i = 0, 3 do F.add_item(bass, audio(i * 4 + 0.5, 3, "bass" .. i .. ".flac", "Bass " .. i)) end
  F.add_item(keys, midi(0, 4, "Keys A"))
  F.add_item(gtr, audio(2, 6, "gtr.flac", "Gtr"))
  settle(A)
  A.F.clock = A.F.clock + 70
  settle(A)
  recv(B)
  B.F.clock = B.F.clock + 70
  settle(B)
  same(name .. ": the song as shared")
end

-- ---- each computer's copy of a thing, and edits to it ----
local function oid_of(it) return it.ext.band_oid end
local function item_on(c, it) as(c); return c == A and it or mirror.find(c.F.proj, "item", oid_of(it)) end
local function track_on(c, t) as(c); return c == A and t or mirror.find(c.F.proj, "track", t.ext.band_oid) end
local function item_named(t, name) for _, it in ipairs(t.items) do if it.text:find('NAME "' .. name .. '"', 1, true) then return it end end end
local function set(c, it, key, v) c.F.set_text(it, E.set_top(it.text, key, v)) end
local function with_notes(c, it, notes)
  local t, n = it.text:gsub("\n%s*E [^\n]*", ""):gsub("(CCINTERP 32)", function(a) return a .. "\n" .. table.concat(notes, "\n") end, 1)
  assert(n == 1, "notes replaced")
  c.F.set_text(it, t)
end
local function events_of(it) local t = {}; for l in it.text:gmatch("\n%s*(E [^\n]+)") do t[#t + 1] = l end; return table.concat(t, " / ") end
local function told(pattern) for _, l in ipairs(logged) do if l:find(pattern) then return l end end end

-- ================================================================================================================================
build("Merge one")

-- MIDI: each adds a different note
do
  local a = item_named(keys, "Keys A")
  local b = item_on(B, a)
  at_once(function()
    with_notes(A, a, { "E 0 90 3c 60", "E 240 90 43 60", "E 120 80 43 00", "E 120 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 960 b0 7b 00" })
  end, function()
    with_notes(B, b, { "E 0 90 3c 60", "E 480 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 240 90 45 60", "E 240 80 45 00", "E 480 b0 7b 00" })
  end)
  same("two notes added at once")
  local want = "E 0 90 3c 60 / E 240 90 43 60 / E 120 80 43 00 / E 120 80 3c 00 / E 0 90 40 50 / E 480 80 40 00 / E 240 90 45 60 / E 240 80 45 00 / E 480 b0 7b 00"
  assert(events_of(a) == want, "both notes, in time order, the end where it was:\n" .. events_of(a))
  assert(events_of(item_on(B, a)) == want, "the same on the laptop:\n" .. events_of(item_on(B, a)))
  assert(not a.text:find("version", 1, true), "no extra take: nothing clashed")
  print("rt-merge: two people add different notes to one MIDI item at once: both stay")

  -- one Ctrl+Z on each side after the merge: only that person's note goes
  tick(); as(A)
  assert(undo.step(A.F.proj, A.cfg, { song = song, room = room }, false, {}), "desktop's undo")
  settle(A); tick(); recv(B)
  same("desktop undid its note")
  assert(events_of(a) == "E 0 90 3c 60 / E 480 80 3c 00 / E 0 90 40 50 / E 480 80 40 00 / E 240 90 45 60 / E 240 80 45 00 / E 480 b0 7b 00",
    "the desktop's note went, the laptop's stayed:\n" .. events_of(a))
  tick(); as(B)
  assert(undo.step(B.F.proj, B.cfg, { song = song, room = room }, false, {}), "laptop's undo")
  settle(B); tick(); recv(A)
  same("laptop undid its note")
  assert(events_of(a) == table.concat(NOTES, " / "), "both undone: the notes as they were:\n" .. events_of(a))
  print("rt-merge: one Ctrl+Z on each side after a note merge takes back only that person's note")

  -- the same note, changed by both: the winner's, the other told
  logged = {}
  at_once(function() with_notes(A, a, { "E 0 90 3c 70", "E 480 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 960 b0 7b 00" }) end,
    function() with_notes(B, item_on(B, a), { "E 0 90 3c 20", "E 480 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 960 b0 7b 00" }) end)
  same("one note's velocity changed by both")
  local v = events_of(a):match("^E 0 90 3c (%x%x)")
  assert(v == "70" or v == "20", "one of the two velocities: " .. events_of(a))
  local loser = v == "70" and "Bee" or "James"
  assert(told("changed the same thing as you on an item on Keys: theirs stands where you both changed it"), "the loser is told, with Use mine:\n" .. table.concat(logged, "\n"))
  assert(not a.text:find("version", 1, true), "no extra take for a note clash")
  print("rt-merge: the same note changed by both: the later stands everywhere (" .. loser .. " told)")
end

-- envelope points: one adds a point, the other changes another, and a deletion against an addition
do
  local bd = track_on(B, drums)
  at_once(function()
    drums.body = drums.body:gsub("PT 8 1 0\n", "PT 6 0.8 0\nPT 8 1 0\n"):gsub("PT 4 0%.5 0\n", ""); A.F.changed()
  end, function()
    bd.body = bd.body:gsub("PT 12 0%.7 0", "PT 12 0.3 0"):gsub("PT 8 1 0\n", "PT 8 1 0\nPT 10 0.9 0\n"); B.F.changed()
  end)
  same("envelope points at once")
  local pts = {}
  for p in drums.body:gmatch("PT ([^\n]+)") do pts[#pts + 1] = p end
  assert(table.concat(pts, ",") == "0 1 0,6 0.8 0,8 1 0,10 0.9 0,12 0.3 0", "every point both made, in time order, the deleted one gone: " .. table.concat(pts, ","))
  print("rt-merge: envelope points: added, changed and deleted on two computers at once, all kept")
end

-- item settings: one moves an item, the other turns it down; then Ctrl+Z on each side
local before = state(A)
do
  local a = item_named(bass, "Bass 0")
  at_once(function() set(A, a, "POSITION", "1.5") end, function() set(B, item_on(B, a), "VOLPAN", "0.5 0 1 -1") end)
  same("one moved it, the other turned it down")
  local b = item_on(B, a)
  for _, x in ipairs({ a, b }) do
    assert(tonumber(E.top_value(x.text, "POSITION")) == 1.5 and E.top_value(x.text, "VOLPAN"):match("^0%.5 "), "both stand: " .. x.text)
  end
  print("rt-merge: an item moved on one computer and turned down on the other: both stand")
  tick(); as(A)
  assert(undo.step(A.F.proj, A.cfg, { song = song, room = room }, false, {}), "desktop's undo of the move")
  settle(A); tick(); recv(B)
  same("desktop undid its move")
  assert(tonumber(E.top_value(a.text, "POSITION")) == 0.5 and E.top_value(a.text, "VOLPAN"):match("^0%.5 "), "the move went back, the laptop's volume stayed: " .. a.text)
  tick(); as(B)
  assert(undo.step(B.F.proj, B.cfg, { song = song, room = room }, false, {}), "laptop's undo of the volume")
  settle(B); tick(); recv(A)
  same("laptop undid its volume")
  local after = state(A)
  assert(after[oid_of(a)] == before[oid_of(a)], "both undone: the item as it was")
  print("rt-merge: one Ctrl+Z on each side after an item merge takes back only that person's change")
end

-- track settings: one renames a track, the other turns it down
do
  at_once(function() reaper.GetSetMediaTrackInfo_String(keys, "P_NAME", "Keys Rhodes", true) end,
    function() reaper.SetMediaTrackInfo_Value(track_on(B, keys), "D_VOL", 0.5) end)
  same("one renamed the track, the other turned it down")
  for _, t in ipairs({ keys, track_on(B, keys) }) do assert(t.name == "Keys Rhodes" and math.abs(t.vol - 0.5) < 1e-6, "both stand: " .. t.name .. " " .. t.vol) end
  print("rt-merge: a track renamed on one computer and turned down on the other: both stand")
end

-- the same setting changed by both at once: both moved one item
do
  logged = {}
  local a = item_named(gtr, "Gtr")
  at_once(function() set(A, a, "POSITION", "3") end, function() set(B, item_on(B, a), "POSITION", "5") end)
  same("both moved one item")
  local p = tonumber(E.top_value(a.text, "POSITION"))
  assert(p == 3 or p == 5, "one of the two places: " .. tostring(p))
  assert(told("changed the same thing as you on an item on Gtr: theirs stands"), "the other is told:\n" .. table.concat(logged, "\n"))
  print("rt-merge: both moved one item: the later place stands everywhere, the other told (Use mine)")
end

-- a deletion against an edit: the deletion, everywhere
do
  local a = item_named(drums, "Drums 3")
  local oid = oid_of(a)
  at_once(function() A.F.remove_item(a) end, function() set(B, item_on(B, a), "VOLPAN", "0.25 0 1 -1") end)
  same("deleted on one, edited on the other")
  assert(not mirror.find(A.F.proj, "item", oid) and not (function() as(B); return mirror.find(B.F.proj, "item", oid) end)(), "gone on both")
  print("rt-merge: an item deleted on one computer while the other edits it: deleted everywhere")
end

-- a bandmate editing the same item: your edit goes out, said once, never put back
do
  logged = {}
  tick()
  local a = item_named(bass, "Bass 2")
  as(A)
  set(A, a, "MUTE", "1 0")
  tick()
  local sent = look(A, function(oid) if oid == oid_of(a) then return "Bee" end end)
  assert(sent[oid_of(a)], "sent though Bee is editing it")
  assert(E.top_value(a.text, "MUTE") == "1 0", "not put back")
  assert(told("^Bee is editing that item on Bass too: both changes go in"), "said:\n" .. table.concat(logged, "\n"))
  assert(not told("Not sent"), "no refusal")
  tick(); recv(B)
  same("the edit made while Bee was on it")
  print("rt-merge: an edit to what a bandmate is editing goes out, with a word, never put back")
end

-- Claims mode: the desktop's edit auto-claimed the track (Cross Test, 0.59.49.70: the laptop's note, a different one, was asked for, waited
-- 30 s and was put back). Now an edit that merges with the claimer's change goes out and lands at once; the same note is still asked for.
do
  local a = item_named(keys, "Keys A")
  local K = keys.name
  tick(); as(A)
  with_notes(A, a, { "E 0 90 3c 60", "E 240 90 43 60", "E 120 80 43 00", "E 120 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 960 b0 7b 00" })
  tick(); settle(A); tick(); recv(B)
  -- Keys is James's auto-claim now, on both computers
  local function claimed(name) return name == K end
  local function can(user, name) return user == "James" or name ~= K end
  local function soft(name, _, user) if name == K and user ~= "James" then return "James" end end
  rules.James = { can = can, claimed = claimed, soft = soft }
  rules.Bee = { can = can, claimed = claimed, soft = function(name, pos) return soft(name, pos, "Bee") end }
  logged = {}
  tick(); as(B)
  local b = item_on(B, a)
  with_notes(B, b, { "E 0 90 3c 60", "E 240 90 43 60", "E 120 80 43 00", "E 120 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 240 90 45 60", "E 240 80 45 00", "E 480 b0 7b 00" })
  tick()
  local sent = {}
  settle(B, sent)
  assert(sent[oid_of(a)], "the laptop's different note went out though Keys is James's auto-claim:\n" .. table.concat(logged, "\n"))
  tick(); recv(A)
  same("a note added on a bandmate's auto-claimed track")
  assert(events_of(a):find("90 45 60", 1, true) and events_of(a):find("90 43 60", 1, true), "both notes on the desktop: " .. events_of(a))
  print("rt-merge: Claims mode: a different note on a bandmate's auto-claimed part goes out and lands at once")
  -- the same note: still theirs to give (refused here: no ask in this test, so put back)
  tick(); as(B)
  b = item_on(B, a)
  with_notes(B, b, { "E 0 90 3c 60", "E 240 90 43 7f", "E 120 80 43 00", "E 120 80 3c 00", "E 0 90 40 50", "E 480 80 40 00", "E 240 90 45 60", "E 240 80 45 00", "E 480 b0 7b 00" })
  tick()
  sent = {}
  settle(B, sent)
  assert(not sent[oid_of(a)] and not events_of(item_on(B, a)):find("43 7f", 1, true), "the desktop's own note, changed: not sent, put back")
  print("rt-merge: Claims mode: the claimer's own note changed by someone else is still theirs to give")
  -- the claimer's side: a crossing edit that merges lands at once (not held a minute as refused)
  rules.James, rules.Bee = nil, nil
end

-- pure: the merges themselves
do
  -- a note added past the other side's end (both moved the end: a clash, the winner's, but never before a note)
  local b = "<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 90 3c 60\nE 480 80 3c 00\nE 480 b0 7b 00\n>"
  local w = "<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 90 3c 60\nE 480 80 3c 00\nE 240 b0 7b 00\n>" -- (shortened)
  local l = "<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 90 3c 60\nE 480 80 3c 00\nE 240 90 40 60\nE 480 80 40 00\nE 240 b0 7b 00\n>" -- (a note to the end)
  local m, clash = mirror.merge_midi(b, w, l)
  assert(m == "<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 90 3c 60\nE 480 80 3c 00\nE 240 90 40 60\nE 480 80 40 00\nE 0 b0 7b 00\n>" and clash, m)
  -- selection isn't a change; ticks per quarter differ: no note merge
  assert(select(2, mirror.merge_midi(b, (b:gsub("E 0 90", "e 0 90")), (b:gsub("E 480 80 3c 00", "E 240 80 3c 00")))) == false, "selection isn't a clash")
  assert(mirror.merge_midi(b, (b:gsub("960", "480")), b) == nil, "different PPQ: not merged note by note")
  assert(mirror.merge_midi("<SOURCE WAVE\nFILE \"a\"\n>", b, b) == nil, "audio: not MIDI")
  -- tracks: lanes go together
  local base = { name = "K", vol = "1.000000", lanes = 2, plays = "1,0", lanenames = "a,b" }
  local tw = { name = "K", vol = "1.000000", lanes = 3, plays = "1,0,0", lanenames = "a,b,c" }
  local tl = { name = "K", vol = "1.0", lanes = 2, plays = "0,1", lanenames = "a,b" }
  local t, both = mirror.merge_track(base, tw, tl)
  assert(t.lanes == 3 and t.plays == "1,0,0" and t.lanenames == "a,b,c" and table.concat(both, ",") == "lanenames,lanes,plays", "both changed lanes: the winner's lanes, whole")
  assert(mirror.merge_track(base, tw, base).lanes == 3 and select(2, mirror.merge_track(base, base, { name = "K", vol = 1 }))[1] == nil, "1 and 1.000000 are one")
  -- automation: an envelope one side added, the other side's points
  local e1 = "<VOLENV2\nACT 1 -1\nPT 0 1 0\n>\n"
  local m2 = mirror.merge_env(e1, e1 .. "<PANENV2\nACT 1 -1\nPT 0 0 0\n>\n", "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.5 0\n>\n")
  assert(m2 == "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.5 0\n>\n<PANENV2\nACT 1 -1\nPT 0 0 0\n>\n", m2)
  local m3, c3 = mirror.merge_env(e1, "<VOLENV2\nACT 1 -1\nPT 0 0.2 0\n>\n", "<VOLENV2\nACT 1 -1\nPT 0 0.9 0\n>\n")
  assert(m3:find("PT 0 0.2 0", 1, true) and #c3 == 1, "the same point both changed: the winner's")
  print("rt-merge: merge_midi, merge_track and merge_env on their own")
  -- a big part: 4,000 notes, one added on each side, merged in well under a pass
  local ev = { "<SOURCE MIDI", "HASDATA 1 960 QN" }
  for i = 1, 4000 do ev[#ev + 1] = string.format("E %d 90 %02x 60", i == 1 and 0 or 120, 36 + i % 48); ev[#ev + 1] = string.format("E 120 80 %02x 00", 36 + i % 48) end
  local big = table.concat(ev, "\n") .. "\nE 960 b0 7b 00\n>"
  local bw = big:gsub("\nE 960 b0 7b 00", "\nE 0 90 7f 60\nE 60 80 7f 00\nE 900 b0 7b 00")
  local bl = big:gsub("HASDATA 1 960 QN\nE 0 90 25 60", "HASDATA 1 960 QN\nE 0 90 7e 60\nE 0 90 25 60\nE 60 80 7e 00", 1)
  local t0 = os.clock()
  local bm = mirror.merge_midi(big, bw, bl)
  local took = os.clock() - t0
  assert(bm and bm:find("90 7f 60", 1, true) and bm:find("90 7e 60", 1, true), "both notes in the big part")
  assert(took < 1, "4,000 notes merged in " .. took .. " s")
  print(string.format("rt-merge: a 4,000-note part merged in %.0f ms", took * 1000))
end
print("ok rt-merge")
