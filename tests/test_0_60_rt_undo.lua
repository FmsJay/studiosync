-- rt-undo: F5, found in the real REAPERs on 2026-11-20 (0.59.49.73, Cross Test: the desktop, the laptop and LinuxBox). REAPER's own Undo on
-- one computer, then another edit to the same things, left the others wrong for minutes:
--   * the laptop logged an undo's 11 changes and kept the 2 items from before it;
--   * LinuxBox applied a cut, and 5 s later "caught up on 11 changes that hadn't arrived here": the cut items were back;
--   * a track jumped above another on each computer at a different time.
-- Here: three computers, each with its own stand-in REAPER (tests/fixtures/editreaper.lua, as tests/test_0_60_rt_edits.lua), whose changes
-- reach the others twice, as in the studio: at once as a message over the direct link (sync.post -> sync.take_event, into the link's inbox)
-- and later as the file Syncthing brings. Each case fails on 0.59.49.73's code; docs/rt/rt-undo.md has the cause. Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local E = require("editreaper")
local f = E.f

local real_date, real_time = os.date, os.time
local now_t = real_time({ year = 2026, month = 11, day = 20, hour = 16, min = 0, sec = 0 })
os.date = function(fmt, t) return real_date(fmt, t or now_t) end
os.time = function(t) if t then return real_time(t) end; return now_t end
local function tick(n) now_t = now_t + (n or 2) end

local ROOT = "C:/fake/StudioSync"
local song, room = "Undo", "main"
-- every computer's disk by path. A studio event file is on a computer only once Syncthing has brought it there (`here`); its author has it at once.
local files, logged, here, cur = {}, {}, {}, nil
local function is_event(p) return p:sub(1, #ROOT + 1) == ROOT .. "/" and p:find("/events/[^/]+%.json$") ~= nil end
local function visible(p) return files[p] ~= nil and (not is_event(p) or (cur ~= nil and here[cur.cfg.user][p] == true)) end
local band = require("band")
local function copy(v) return band.json_decode(band.json_encode(v)) end
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) if visible(path) and type(files[path]) == "table" then return copy(files[path]) end end
proxy.write_json = function(path, v)
  files[path] = copy(v)
  if is_event(path) and cur then here[cur.cfg.user][path] = true end
  return true
end
local function listing(dir, ext)
  local out = {}
  for p in pairs(files) do
    local d, fn = p:match("^(.*)/([^/]*)$")
    if d == dir and (not ext or fn:sub(-#ext) == ext) and visible(p) then out[#out + 1] = fn end
  end
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
mirror.MERGE_SINCE = {} -- (the clock here is 2026-11-20, around when track merging began: merges as built since, in any time zone. rt-p1)
local sync = require("sync")
local direct = require("direct")
require("prints").choose = function() end
mirror.FX_SET_GAP = 0
-- the direct link: on, each computer's inbox its own folder, and every object change also a message to the others
direct.available = function() return true end
direct.inbox = function() return "INBOX/" .. cur.cfg.user end
direct.started[ROOT] = true
local wire = {}
direct.send_live = function(cfg, kind, ev, sg) if kind == "event" then wire[#wire + 1] = { from = cfg.user, song = sg, ev = copy(ev) } end; return true end

local yes = function() return true end
local MEDIA, RDIR
local function computer(user, path)
  local c = { F = E.new(path), cfg = { user = user, root = ROOT }, took = {} }
  here[user] = here[user] or {}
  c.F.reaper.GetMousePosition = function() return 0, 0 end -- (sync.put_back's tooltip: "James also changed ... theirs is in")
  c.F.reaper.file_exists = function(p)
    p = p:gsub("\\", "/")
    if p:find("%.json$") and (is_event(p) or p:sub(1, 6) == "INBOX/") then return visible(p) end
    return true
  end
  return c
end
local function as(c) reaper, cur = c.F.reaper, c end
-- the link's messages so far reach this computer (sync.take_event, as Live sync's "event" handler calls it)
local function link(c)
  as(c)
  local n = 0
  for _, m in ipairs(wire) do
    if m.from ~= c.cfg.user and m.song == song and not c.took[m.ev.id] then -- (Live sync hands over only this song's)
      c.took[m.ev.id] = true
      if sync.take_event(c.cfg, song, room, copy(m.ev)) then n = n + 1 end
    end
  end
  return n
end
-- Syncthing catches up on this computer: every event file is here, and the inbox copies of those go (direct.prune)
local function drive(c)
  for p in pairs(files) do
    if is_event(p) then
      here[c.cfg.user][p] = true
      local rel = p:sub(#ROOT + 2)
      files["INBOX/" .. c.cfg.user .. "/" .. rel] = nil
    end
  end
end

local function state(c)
  as(c)
  local objs = mirror.scan(c.F.proj, c.cfg.user, MEDIA, false)
  local out, order = {}, {}
  for _, o in ipairs(objs) do out[o.oid] = o.hash; if o.kind == "track" then order[#order + 1] = o.oid end end
  return out, table.concat(order, ",")
end
local function names(c) local l = {}; for _, t in ipairs(c.F.tracks) do l[#l + 1] = t.name end; return table.concat(l, ", ") end
local function n_items(c) return #c.F.all_items() end
local function same(x, y, what)
  local sx, ox = state(x)
  local sy, oy = state(y)
  assert(n_items(x) == n_items(y), what .. ": " .. y.cfg.user .. " has " .. n_items(y) .. " items, " .. x.cfg.user .. " has " .. n_items(x))
  for oid, h in pairs(sx) do assert(sy[oid] == h, what .. ": " .. oid .. " reads the same on " .. y.cfg.user .. " (" .. tostring(h) .. " vs " .. tostring(sy[oid]) .. ")") end
  for oid in pairs(sy) do assert(sx[oid], what .. ": " .. y.cfg.user .. " has nothing " .. x.cfg.user .. " hasn't (" .. oid .. ")") end
  assert(ox == oy, what .. ": the same track order (" .. names(x) .. " vs " .. names(y) .. " on " .. y.cfg.user .. ")")
end

local seen_files = {}
local function new_events()
  local out = {}
  for p, v in pairs(files) do
    if not seen_files[p] then
      seen_files[p] = true
      if is_event(p) and type(v) == "table" then out[#out + 1] = v end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end
local function look(c, quick)
  as(c)
  c.F.clock = c.F.clock + 1
  mirror.watch(c.F.proj, c.cfg, song, room, { can = yes, mode = "open", quick = quick })
  sync.watch_timeline(c.F.proj, c.cfg, song, room, yes)
  local sent, oids = new_events(), {}
  for _, ev in ipairs(sent) do if ev.oid then oids[ev.oid] = ev end end
  return oids, sent
end
local function settle(c, quick, into)
  for _ = 1, 20 do
    local o, s = look(c, quick)
    for oid, ev in pairs(o) do if into then into[oid] = ev end end
    if #s == 0 and not mirror.more then return end
  end
  error("never settled")
end
-- a pass of receiving (Live sync's), then the looks after it: nothing that landed is sent back
local function recv(c)
  as(c)
  local n = 0
  for _ = 1, 20 do
    c.F.clock = c.F.clock + 1
    local got = sync.receive(c.F.proj, c.cfg, song, room, yes)
    n = n + (tonumber(got) or 0)
    if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
  end
  for _ = 1, 3 do
    local o = look(c, true)
    for oid, ev in pairs(o) do error(c.cfg.user .. " sent back what landed: " .. oid .. " " .. tostring(ev.state):sub(1, 200)) end
  end
  return n
end

-- ---- the song: Cross Test's shape (Keys, Drums, Rec with takes on it and a volume envelope) ----
local function audio(pos, len, file, name)
  return table.concat({ "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 1", "ALLTAKES 0", "FADEIN 1 0.01 0 1 0 0 0", "FADEOUT 1 0.01 0 1 0 0 0",
    "MUTE 0 0", "SEL 0", "IID 1", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0",
    "GUID " .. E.guid(), "<SOURCE WAVE", 'FILE "' .. MEDIA .. "/" .. file .. '"', ">", ">" }, "\n") .. "\n"
end
local ENV = "<VOLENV2\nEGUID {E1}\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 4 0.5 0\nPT 8 1 0\n>\n"
local A, B, C, keys, drums, rec
local function build(name)
  song = name
  RDIR = sync.room_dir({ root = ROOT }, song, room)
  MEDIA = RDIR .. "/media"
  A, B, C = computer("James", "C:/A/" .. name .. ".rpp"), computer("Bee", "C:/B/" .. name .. ".rpp"), computer("Cee", "C:/C/" .. name .. ".rpp")
  as(A)
  local F = A.F
  keys = F.add_track("Keys")
  drums = F.add_track("Drums")
  rec = F.add_track("Rec", nil, ENV)
  F.add_item(keys, audio(7, 3.5, "keys.flac", "Keys 1"))
  F.add_item(drums, audio(2, 3.5, "drums.flac", "Drums 1"))
  for i = 1, 3 do F.add_item(rec, audio(3.5, 4 + i, "rec" .. i .. ".flac", "Rec " .. i)) end
  settle(A, true)
  A.F.clock = A.F.clock + 70
  settle(A, true)
  for _, c in ipairs({ B, C }) do
    link(c); drive(c); recv(c)
    c.F.clock = c.F.clock + 70
    settle(c, true)
    same(A, c, name .. ": the song as shared")
  end
end

-- REAPER's own Undo (action 40029): the project as it was before the edit, the same items with the same GUIDs and P_EXT, and a redo point.
-- StudioSync sees only that the project changed.
local function snapshot(c)
  local s = { order = { table.unpack(c.F.tracks) } }
  for i, t in ipairs(c.F.tracks) do
    local l = {}
    for _, it in ipairs(t.items) do l[#l + 1] = { guid = it.guid, chunk = c.F.item_chunk(it), lane = it.lane } end
    s[i] = { t = t, items = l, body = t.body }
  end
  return s
end
local function native_undo(c, s, name)
  as(c)
  for _, x in ipairs(s) do
    for i = #x.t.items, 1, -1 do c.F.remove_item(x.t.items[i]) end
    for _, it in ipairs(x.items) do local n = c.F.add_item(x.t, it.chunk); n.guid, n.lane = it.guid, it.lane end
    x.t.body = x.body
  end
  for i = #c.F.tracks, 1, -1 do c.F.tracks[i] = nil end
  for i, t in ipairs(s.order) do c.F.tracks[i] = t end
  c.F.changed()
  c.F.undo, c.F.redo = nil, name
end
-- "Edit: Cut items" on what's selected inside the region: Keys' item and Rec's takes
local function cut(c)
  as(c)
  for _, t in ipairs({ keys, rec }) do for i = #t.items, 1, -1 do c.F.remove_item(t.items[i]) end end
  c.F.undo, c.F.redo = "Cut items", nil
end

local failed = {}
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then print("rt-undo: " .. name) else failed[#failed + 1] = name .. "\n    " .. tostring(err):gsub("\n", "\n    ") end
end

-- 1. A native undo is a NEW change: each object it brings back goes out with a higher revision and a later clock than the edit it undoes,
--    built on that edit. (What the desktop sent on 2026-11-20 was right: every restore was rev + 1001 on its deletion.)
case("a native undo goes out as a new change, newer than the edit it takes back", function()
  build("Undo new")
  tick()
  local before = snapshot(A)
  cut(A)
  local gone = look(A, true)
  local n = 0
  for _, ev in pairs(gone) do assert(ev.gone, "the cut's changes are deletions"); n = n + 1 end
  assert(n == 4, "the cut sent 4 deletions (" .. n .. ")")
  tick()
  native_undo(A, before, "Cut items")
  local back = look(A, true)
  for oid, g in pairs(gone) do
    local r = back[oid]
    assert(r and not r.gone and type(r.state) == "string", "the undo sent " .. oid .. " again, as it is now")
    assert(r.rev > g.rev and r.hlc > g.hlc, "newer than the deletion: rev " .. r.rev .. " over " .. g.rev)
    assert(r.base_ev == g.id, "and built on it")
    assert(mirror.newer({ rev = r.rev, time = mirror.order_of(r) }, { rev = g.rev, time = mirror.order_of(g) }), "so it wins everywhere")
  end
end)

-- 2. The laptop at 16:13:57: the undo's changes came over the link and were applied; their files hadn't come through Syncthing. An item
--    landing over a deletion ends that receive pass with a heal (mirror.heal_due), which read only the shared folder: the folder's newest was
--    still the deletion, so the heal deleted the items again and recorded the deletion as held. The undo's events were already marked applied.
case("an undo that lands over the link stays, though its files aren't in the shared folder yet", function()
  build("Undo link")
  tick()
  local before = snapshot(A)
  cut(A)
  look(A, true)
  for _, c in ipairs({ B, C }) do link(c); recv(c); same(A, c, "the cut landed") end
  for _, c in ipairs({ B, C }) do drive(c); recv(c) end -- (Syncthing has brought the cut's files by now)
  tick(19)
  native_undo(A, before, "Cut items")
  look(A, true)
  assert(n_items(A) == 5, "the desktop has its items back")
  for _, c in ipairs({ B, C }) do
    assert(link(c) == 4, "the undo's 4 changes came over the link")
    assert(recv(c) == 4, "and were applied")
    same(A, c, "after the undo")
  end
  -- and when Syncthing's copies arrive, nothing moves
  for _, c in ipairs({ B, C }) do drive(c); recv(c); same(A, c, "after the undo's files arrived") end
end)

-- 3. LinuxBox at 16:11:18-16:11:23: a second edit to the same things (a cut again) came over the link and was applied. Then Live sync's own
--    heal ran (a caught-up bandmate's project had differed for a minute), read the folder, found the undo's versions there as the newest, and
--    put them back over the cut: "caught up on 11 changes that hadn't arrived here".
case("Live sync's heal doesn't put an older version back over a newer one that came over the link", function()
  build("Undo heal")
  tick()
  local before = snapshot(A)
  cut(A)
  look(A, true)
  tick(19)
  native_undo(A, before, "Cut items")
  look(A, true)
  link(C); drive(C); recv(C)
  same(A, C, "the cut and its undo, files and all")
  tick(19)
  cut(A) -- (the second edit)
  look(A, true)
  assert(link(C) == 4 and recv(C) == 4, "the second cut landed over the link")
  same(A, C, "after the second cut")
  as(C)
  local n = mirror.heal(C.F.proj, RDIR, false)
  assert(n == 0, "the heal found nothing to catch up on (" .. n .. ")")
  same(A, C, "after the heal")
  -- (and with the cut's inbox copies gone and its files still not here, a song not downloaded yet, say: what's held is never traded for
  -- something older)
  for p in pairs(files) do if p:sub(1, 10) == "INBOX/Cee/" then files[p] = nil end end
  as(C)
  n = mirror.heal(C.F.proj, RDIR, false)
  assert(n == 0, "nor with the newer change readable nowhere (" .. n .. ")")
  same(A, C, "after that heal")
  drive(C); recv(C)
  as(C)
  assert(mirror.heal(C.F.proj, RDIR, false) == 0, "nor once the files are here")
  same(A, C, "after the files arrived")
end)

-- 3b. Why the heal reads the link's inbox too, not only "never to an older version": a deletion that beats a newer edit made without seeing
--     it (mirror.gone_race). Cee holds Bee's edit from its file, then James's deletion comes over the link and wins. A heal that reads the
--     folder alone doesn't know the deletion, finds Bee's edit the room's newest, newer than the deletion by its clock, and puts the item back.
case("a heal knows a deletion that came over the link, against a newer edit in the shared folder", function()
  build("Undo race")
  tick()
  as(A)
  local it = keys.items[1]
  local oid = it.ext.band_oid:upper()
  A.F.remove_item(it)
  local gone = look(A, true)[oid]
  assert(gone and gone.gone, "the desktop deleted Keys' item")
  tick()
  as(B) -- (the laptop hasn't seen that: it moves the item)
  local bi = mirror.find(B.F.proj, "item", oid)
  B.F.set_text(bi, E.set_top(bi.text, "POSITION", f(9)))
  local edit = look(B, true)[oid]
  assert(edit and not edit.gone and mirror.newer({ rev = edit.rev, time = mirror.order_of(edit) }, { rev = gone.rev, time = mirror.order_of(gone) }),
    "the laptop's edit is the newer by revision and clock")
  here.Cee[RDIR .. "/events/" .. edit.id .. ".json"] = true -- (Syncthing brings the laptop's file to LinuxBox first)
  recv(C)
  as(C)
  assert(mirror.find(C.F.proj, "item", oid), "LinuxBox has the item, moved")
  link(C); recv(C) -- (then the desktop's deletion, over the link)
  as(C)
  assert(not mirror.find(C.F.proj, "item", oid), "the deletion wins over the edit that didn't see it")
  assert(mirror.heal(C.F.proj, RDIR, false) == 0 and not mirror.find(C.F.proj, "item", oid), "and a heal leaves it deleted, the deletion's file not here yet")
  for _, c in ipairs({ A, B, C }) do link(c); drive(c); recv(c) end
  same(A, B, "everything arrived"); same(A, C, "everything arrived")
  assert(n_items(A) == 4, "deleted everywhere")
end)

-- 4. The track order: Rec's newest change still says "under Keys", from before Drums went between them (a track that only sits elsewhere
--    isn't sent again). Its history holds a change made twice, once by each of two computers (the same edit seen by both), from before track
--    changes were merged, so the heal's settled version of it is a merge with another id and the same content. Each computer's heal put that
--    in place when it ran, and Rec jumped back under Keys: the laptop and LinuxBox at the first undo, the desktop a minute later.
case("a heal leaves a track where it is when its place isn't what changed", function()
  song = "Undo order"
  RDIR = sync.room_dir({ root = ROOT }, song, room)
  MEDIA = RDIR .. "/media"
  A, B = computer("James", "C:/A/order.rpp"), computer("Bee", "C:/B/order.rpp")
  as(A)
  keys = A.F.add_track("Keys")
  rec = A.F.add_track("Rec")
  settle(A, true)
  A.F.clock = A.F.clock + 70
  tick()
  as(A)
  reaper.GetSetMediaTrackInfo_String(rec, "P_NAME", "Rec A", true)
  local sent = look(A, true)
  local rec_oid = select(2, A.F.raw.GetSetMediaTrackInfo_String(rec, "P_EXT:band_oid", "", false)):upper()
  local e2 = sent[rec_oid]
  assert(e2 and e2.base_ev, "the rename went out, built on the track's first change")
  tick()
  as(A)
  drums = A.F.add_track("Drums", 2) -- (between them)
  settle(A, true)
  link(B); drive(B); recv(B)
  B.F.clock = B.F.clock + 70
  settle(B, true)
  same(A, B, "Keys, Drums, Rec A on both")
  assert(names(A) == "Keys, Drums, Rec A" and names(B) == names(A), "in that order (" .. names(B) .. ")")
  -- the same rename as a third computer sent it too, a moment earlier: everyone counted it done at the time
  local echo = copy(e2)
  echo.user, echo.id, echo.hlc = "Cee", "Cee-" .. e2.id:match("^James%-(.*)$"), e2.hlc - 1
  files[RDIR .. "/events/" .. echo.id .. ".json"] = echo
  seen_files[RDIR .. "/events/" .. echo.id .. ".json"] = true
  for _, c in ipairs({ A, B }) do
    drive(c)
    as(c)
    reaper.SetProjExtState(c.F.proj, sync.APPLIED, echo.id, "1")
  end
  as(B)
  local moves = B.F.calls.ReorderSelectedTracks or 0
  mirror.heal(B.F.proj, RDIR, false)
  assert(names(B) == "Keys, Drums, Rec A", "the laptop's heal left Rec A under Drums (" .. names(B) .. ")")
  assert((B.F.calls.ReorderSelectedTracks or 0) == moves, "and moved no track (a REAPER undo point of its own, on top of your list)")
  same(A, B, "the laptop healed, the desktop not yet")
  as(A)
  mirror.heal(A.F.proj, RDIR, false)
  same(A, B, "both healed")
  recv(A); recv(B)
  -- a real move still travels: Rec A dragged above Drums on the desktop
  tick()
  as(A)
  reaper.SetOnlyTrackSelected(rec)
  reaper.ReorderSelectedTracks(1, 0)
  look(A, true)
  assert(names(A) == "Keys, Rec A, Drums", "moved on the desktop (" .. names(A) .. ")")
  link(B); recv(B)
  assert(names(B) == "Keys, Rec A, Drums", "and on the laptop (" .. names(B) .. ")")
  -- and a heal still moves a track when the place is what it missed: Keys dragged to the bottom on the desktop, and the laptop back as it
  -- was before that landed, its record the version before the move ("at the top", where the move says "under Drums")
  tick()
  as(A)
  reaper.SetOnlyTrackSelected(keys)
  reaper.ReorderSelectedTracks(3, 0)
  look(A, true)
  assert(names(A) == "Rec A, Drums, Keys", "Keys moved on the desktop (" .. names(A) .. ")")
  link(B); recv(B)
  assert(names(B) == "Rec A, Drums, Keys", "and on the laptop (" .. names(B) .. ")")
  as(B)
  local keys_oid = select(2, A.F.raw.GetSetMediaTrackInfo_String(keys, "P_EXT:band_oid", "", false)):upper()
  local bk = mirror.find(B.F.proj, "track", keys_oid)
  local _, _, held = mirror.known(B.F.proj, keys_oid)
  local was = mirror.event_file(RDIR, mirror.event_file(RDIR, held).base_ev)
  reaper.SetOnlyTrackSelected(bk)
  reaper.ReorderSelectedTracks(0, 0)
  assert(names(B) == "Keys, Rec A, Drums", "(put back by hand)")
  mirror.remember(B.F.proj, keys_oid, was.rev, mirror.track_hash(mirror.track_state(B.F.proj, bk, false), false), was.id, mirror.order_of(was))
  drive(B)
  assert(mirror.heal(B.F.proj, RDIR, false) >= 1 and names(B) == "Rec A, Drums, Keys", "a missed move is caught up on (" .. names(B) .. ")")
end)

-- 5. Health's "Changes from the others come out the same here" went by one counter: a change that hashed differently here than on its
--    sender's computer the moment it was applied. Every change above hashed the same when applied (and again when the heal applied the older
--    one), so the row stayed green while the projects differed. Now Live sync also notes who has every change yet holds another project, or
--    another track order (mirror.apart_note), and the row is red once that has stood for mirror.APART_SECS.
case("Health's row knows when a caught-up bandmate's project isn't this one", function()
  build("Undo health")
  as(A)
  local p = A.F.proj
  local code = mirror.order_code(p)
  assert(type(code) == "string" and code ~= "", "a code for the track order")
  as(B)
  assert(mirror.order_code(B.F.proj) == code, "the same on a computer with the same order")
  reaper.SetOnlyTrackSelected(B.F.tracks[3])
  reaper.ReorderSelectedTracks(0, 0)
  assert(mirror.order_code(B.F.proj) ~= code, "and another once a track is elsewhere")
  as(A)
  local now = 5000
  assert(mirror.apart_for(p, now) == nil, "nothing noted: nobody's apart")
  -- nothing pending here, and Bee, caught up, holds another project
  mirror.apart_note(p, "r1", code, 0, { { user = "Bee", mirror = "r2", order = code, pending = 0 }, { user = "Cee", mirror = "r1", order = code, pending = 0 } }, now)
  assert(mirror.apart_for(p, now + 10) == nil, "differing for 10 s is an edit on its way")
  local who, secs, what = mirror.apart_for(p, now + mirror.APART_SECS + 1)
  assert(who == "Bee" and secs >= mirror.APART_SECS and what == "project", "after " .. mirror.APART_SECS .. " s it's said, with who (" .. tostring(who) .. ")")
  -- the same pair noted again keeps its start; another pair (an edit since) starts again
  mirror.apart_note(p, "r1", code, 0, { { user = "Bee", mirror = "r2", order = code, pending = 0 } }, now + 20)
  assert(mirror.apart_for(p, now + mirror.APART_SECS + 1) == "Bee", "the same difference keeps its start")
  mirror.apart_note(p, "r3", code, 0, { { user = "Bee", mirror = "r2", order = code, pending = 0 } }, now + 40)
  assert(mirror.apart_for(p, now + mirror.APART_SECS + 1) == nil, "a new difference starts again")
  -- only the track order differs
  mirror.apart_note(p, "r1", code, 0, { { user = "Bee", mirror = "r1", order = "other", pending = 0 } }, now + 100)
  who, secs, what = mirror.apart_for(p, now + 100 + mirror.APART_SECS)
  assert(who == "Bee" and what == "order", "a track order that differs is said too (" .. tostring(what) .. ")")
  -- not while changes are still on their way, either side, nor against a StudioSync that doesn't say its order
  mirror.apart_note(p, "r1", code, 0, { { user = "Bee", mirror = "r2", order = code, pending = 3 } }, now + 200)
  assert(mirror.apart_for(p, now + 999) == nil, "they're still receiving: not said")
  mirror.apart_note(p, "r1", code, function() return 2 end, { { user = "Bee", mirror = "r2", order = code, pending = 0 } }, now + 200)
  assert(mirror.apart_for(p, now + 999) == nil, "this computer is: not said")
  mirror.apart_note(p, "r1", code, function() return 0 end, { { user = "Bee", mirror = "r2", order = code, pending = 0 } }, now + 200)
  assert(mirror.apart_for(p, now + 999) == "Bee", "(asked as a function, as Live sync does: nothing pending, said)")
  mirror.apart_note(p, "r1", code, 0, { { user = "Bee", mirror = "r1", pending = 0 } }, now + 200)
  assert(mirror.apart_for(p, now + 999) == nil, "an older StudioSync says no order: not compared")
  local src = io.open("lib/page_health.lua"):read("a")
  assert(src:find('require("mirror").apart_for(proj', 1, true), "Health's row asks")
  src = io.open("StudioSync - Live sync.lua"):read("a")
  assert(src:find('require("mirror").apart_note, proj', 1, true) and src:find('t.order_code = require("mirror").order_code(proj)', 1, true)
    and src:find('order = s and s.sync == "mirror" and t.order_code or nil', 1, true), "Live sync notes it, and says its order in its status")
end)

assert(#failed == 0, #failed .. " case(s) failed:\n  " .. table.concat(failed, "\n  "))
print("ok rt-undo")
