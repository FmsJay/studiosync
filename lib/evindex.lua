-- The index (docs/rt/rt-sync2.md section 1, phase 2 in docs/rt/rt-sync2b.md): every version of every object in a room's events, the folder
-- and the direct link's inbox, kept light (each file read once a session, its state read from the file when something asks for it:
-- mirror.light_event, as History keeps events), and which items and parts each track holds, so a track coming back or going brings its
-- contents to the judge in the same pass. sync.receive adds what it reads; heal and a track's contents load the rest once.
local evindex = {}
local less, cmp = require("rank").less, require("rank").cmp -- (ids byte by byte: the same order on every computer. lib/judge.lua, rt-sync2e)
local rooms = {} -- room dir -> { by = { oid -> { id -> version } }, on = { track oid -> { oid -> true } }, file = { file -> version } }

local function room(dir)
  local r = rooms[dir]
  if not r then r = { by = {}, on = {}, file = {} }; rooms[dir] = r end
  return r
end
-- A version of an object, as read (light or whole): indexed by its oid and by the track it names. `f`: its file, so a trimmed one goes.
function evindex.add(dir, ev, f)
  if type(ev) ~= "table" or ev.type ~= "obj" or type(ev.oid) ~= "string" or type(ev.id) ~= "string" then return end
  local r = room(dir)
  local t = r.by[ev.oid]
  if not t then t = {}; r.by[ev.oid] = t end
  if not t[ev.id] then t[ev.id] = ev end
  if f then r.file[f] = t[ev.id] end
  local on = type(ev.track) == "string" and ev.track or (ev.oid:match("^[FERM](%-.+)$") and ("T" .. ev.oid:sub(2)))
  if on then
    local c = r.on[on]
    if not c then c = {}; r.on[on] = c end
    c[ev.oid] = true
  end
end
-- Every event file of the room (and the link's inbox) read: what's new since the last load is read (light), and what has left the folder
-- (history trim) leaves the index. Cost: one listing of each, and one read of each file a session. -> the room's index.
function evindex.load(dir)
  local band, mirror = require("band"), require("mirror")
  local r = room(dir)
  local names, inbox, listed = band.files(dir .. "/events", ".json"), {}, {}
  local inbox_names = require("direct").inbox_names -- (a test's stand-in link may have none)
  for _, f in ipairs(inbox_names and inbox_names(dir .. "/events") or {}) do inbox[f] = true end
  local function take(f, from_inbox)
    if listed[f] then return end
    listed[f] = true
    if r.file[f] == nil then
      local ev = mirror.light_event(dir, f, from_inbox)
      if type(ev) == "table" then evindex.add(dir, ev, f) end
    end
  end
  for _, f in ipairs(names) do take(f, false) end
  for f in pairs(inbox) do take(f, true) end
  for f, ev in pairs(r.file) do
    if not listed[f] then
      r.file[f] = nil
      local t = r.by[ev.oid]
      if t then t[ev.id] = nil; if next(t) == nil then r.by[ev.oid] = nil end end
    end
  end
  r.loaded = true
  return r
end
-- An object's versions in the index (in no order: the judge sorts).
function evindex.versions(dir, oid)
  local out, t = {}, room(dir).by[oid]
  for _, v in pairs(t or {}) do out[#out + 1] = v end
  return out
end
-- Every object of the room, sorted.
function evindex.oids(dir)
  local out = {}
  for oid in pairs(room(dir).by) do out[#out + 1] = oid end
  table.sort(out, cmp)
  return out
end
-- What a track holds or has held: every item a version of which names it, and its parts (F/E/R/M with its id), sorted parts first. The whole
-- room is loaded first (once a session), so nothing read before this script started is left out.
function evindex.contents(dir, toid)
  local r = rooms[dir]
  if not (r and r.loaded) then r = evindex.load(dir) end
  local out = {}
  for oid in pairs(r.on[toid] or {}) do if r.by[oid] and oid ~= toid then out[#out + 1] = oid end end
  local rank = { F = 1, E = 1, R = 1, M = 1 }
  table.sort(out, function(a, b)
    local ra, rb = rank[a:sub(1, 1)] or 2, rank[b:sub(1, 1)] or 2
    if ra ~= rb then return ra < rb end
    return less(a, b)
  end)
  return out
end
function evindex.forget(dir) rooms[dir] = nil end -- (tests)

return evindex
