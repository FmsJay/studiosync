-- History trim (James, 2026-11-01: "can trim history as long as major restore points are saved"). A room's events
-- folder keeps every change ever made; after a while that's thousands of files every machine reads. Trimmed:
-- changes older than `days` (60) that nothing needs any more. Kept, always:
--   each object's newest change (what the song is now, and what a machine that was away catches up to);
--   for each major restore point (kept ones: end of session, "yours before X's work done alone"; and every version
--   someone saved by hand), each object's newest change at or before it, so it still restores exactly;
--   handovers, notes and likes (who drove when decides old changes' authority; notes are people's words).
-- Minor points (the snapshot before a handover) may lose their exact past. Trimmed files leave the band folder (so
-- every machine's copy goes) into <band folder's parent>/StudioSync history archive/<song>/<room>/ on the machine that
-- trimmed, so nothing is lost for good.
local band = require("band")
local trim = {}
-- how old a change has to be before it may go: twice the age past which a clash isn't merged (mirror.MERGE_DAYS), so a version a
-- change still merges from is on every computer (review, 0.58.53: one trimmed on day 31 could still be a 25-day-old change's base)
trim.DAYS = 60

-- What one event is about: an object's oid, the timeline, or nil (kept regardless).
local function key_of(ev)
  if ev.type == "obj" and type(ev.oid) == "string" then return ev.oid end
  if ev.type == "timeline" then return "\0timeline" end
  if ev.type == "start" or ev.type == "stop" then return "\0transport" end -- (no state to restore: only age decides)
  return nil
end
local TRANSPORT = "\0transport"
local function later(a, b) -- the same order every machine uses (lib/mirror.lua newer: rev, then the clock, then the name), then id
  local mirror = require("mirror")
  local x, y = { rev = a.rev, time = mirror.order_of(a) }, { rev = b.rev, time = mirror.order_of(b) }
  if mirror.newer(x, y) ~= mirror.newer(y, x) then return mirror.newer(x, y) end
  return (a.id or "") > (b.id or "")
end
-- A point is major unless it's the snapshot taken before a handover.
function trim.major(p) return p.keep or not tostring(p.label or ""):match("^before .+ took over") end

-- The ids to take away. evs: { { id, type, oid, rev, time } }; points: { { time, keep, label } }; cutoff: ISO time
-- (only older changes go). Pure.
function trim.plan(evs, points, cutoff)
  local keep, newest = {}, {}
  for _, ev in ipairs(evs) do
    local k = key_of(ev)
    if k and k ~= TRANSPORT and (not newest[k] or later(ev, newest[k])) then newest[k] = ev end
  end
  for _, ev in pairs(newest) do keep[ev.id] = true end
  -- and what a merged version is rebuilt from (lib/mirror.lua event_file, 0.58.43): a change made apart from the newest (not on its line of
  -- bases), and the base each kept one started from
  local by_id = {}
  for _, ev in ipairs(evs) do by_id[ev.id] = ev end
  local behind = {} -- every id on a newest one's line of bases
  local todo = {}
  for _, w in pairs(newest) do todo[#todo + 1] = w.base_ev end
  while #todo > 0 do -- (a loop, not recursion: a long history is thousands deep)
    local id = table.remove(todo)
    if type(id) == "string" and not behind[id] then
      behind[id] = true
      for part in id:gmatch("[^()&]+") do
        if part ~= "m" and by_id[part] then behind[part] = true; todo[#todo + 1] = by_id[part].base_ev end
      end
    end
  end
  local rival = {} -- (the newest of them only: what a settle merges in. Every losing branch kept history growing for good. Review, 0.58.47)
  for _, ev in ipairs(evs) do
    local k = key_of(ev)
    local w = k and newest[k]
    if w and ev ~= w and ev.base_ev and w.base_ev and not ev.gone and not behind[ev.id] and (not rival[k] or later(ev, rival[k])) then rival[k] = ev end
  end
  for _, ev in pairs(rival) do keep[ev.id] = true end
  -- each kept one's base; a base that is a merge's id ("m(a&b)") is rebuilt from a and b and their bases, so those too. Only through merge
  -- ids: a plain base's own base isn't read (following every base_ev kept the whole history, since each change names the one before)
  local function need(id, depth)
    if type(id) ~= "string" or depth > 20 then return end
    if not id:find("^m%(") then keep[id] = true; return end
    for part in id:gmatch("[^()&]+") do
      if part ~= "m" then keep[part] = true; need(by_id[part] and by_id[part].base_ev, depth + 1) end
    end
  end
  local roots = {}
  for id in pairs(keep) do roots[#roots + 1] = id end
  for _, id in ipairs(roots) do need(by_id[id] and by_id[id].base_ev, 0) end
  for _, p in ipairs(points) do
    if trim.major(p) and p.time then
      local at = {}
      for _, ev in ipairs(evs) do
        local k = key_of(ev)
        if k and k ~= TRANSPORT and (ev.time or "") <= p.time and (not at[k] or later(ev, at[k])) then at[k] = ev end
      end
      for _, ev in pairs(at) do keep[ev.id] = true end
    end
  end
  local out = {}
  for _, ev in ipairs(evs) do
    if key_of(ev) and not keep[ev.id] and type(ev.time) == "string" and ev.time < cutoff then out[#out + 1] = ev.id end -- (no time: never taken for old)
  end
  table.sort(out)
  return out
end

-- The print files named by `refs` (state strings) in `room`'s media. Pure. -> { name = true } ("print-...", no extension)
function trim.print_refs(text, room, into)
  into = into or {}
  for r, name in text:gmatch('{media:([^}]+)}/(print%-[^"/]+)%.flac') do if not room or r == room then into[name] = true end end
  for name in text:gmatch('{media}/(print%-[^"/]+)%.flac') do into[name] = true end -- (the older form, the event's own room: counted either way. 0.58.93)
  return into
end
-- Prints only the changes that just went named (a print is a new file for every edit, and none ever left the media folder: review, 0.58.92)
-- follow them into the archive. One that any change still here names, in any room of the song, stays. -> the files moved
function trim.prints(cfg, song, room, evs, took, archive)
  local gone_ids, cand, still, moved = {}, {}, {}, {}
  for _, id in ipairs(took) do gone_ids[id] = true end
  for _, ev in ipairs(evs) do
    if type(ev.state) == "string" and gone_ids[ev.id] then trim.print_refs(ev.state, room, cand) end
  end
  if not next(cand) then return moved end
  local sync = require("sync")
  -- (what's still named, read from this room's folder as it is now: one that arrived during the trim, or couldn't be read as an event, named a
  -- print too. 0.58.93)
  local here = sync.room_dir(cfg, song, room) .. "/events"
  for _, f in ipairs(band.files(here, ".json")) do trim.print_refs(band.read(here .. "/" .. f) or "", nil, still) end
  local rooms_dir = sync.room_dir(cfg, song, room):gsub("/[^/]+$", "")
  for i = 0, math.huge do
    local r = reaper.EnumerateSubdirectories(rooms_dir, i)
    if not r then break end
    if r ~= room then -- (a side room's items may play the main room's prints)
      for _, f in ipairs(band.files(rooms_dir .. "/" .. r .. "/events", ".json")) do trim.print_refs(band.read(rooms_dir .. "/" .. r .. "/events/" .. f) or "", nil, still) end
    end
  end
  local media = sync.room_dir(cfg, song, room) .. "/media"
  reaper.RecursiveCreateDirectory(archive .. "/media", 0)
  for name in pairs(cand) do
    if not still[name] then
      for _, ext in ipairs({ ".flac", ".opus" }) do
        local from, to = media .. "/" .. name .. ext, archive .. "/media/" .. name .. ext
        if reaper.file_exists(from) and (os.rename(from, to) or (pcall(band.copy_atomic, from, to) and reaper.file_exists(to) and os.remove(from))) then
          moved[#moved + 1] = name .. ext
        end
      end
    end
  end
  table.sort(moved)
  return moved
end

-- Trim one room now. Returns how many went. `days`: how old a change has to be (trim.DAYS).
function trim.run(cfg, song, room, days)
  days = days or trim.DAYS
  local sync, recall = require("sync"), require("recall")
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local evs = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local ev = band.read_json(dir .. "/" .. f)
    if type(ev) == "table" and type(ev.id) == "string" and ev.id .. ".json" == f then evs[#evs + 1] = ev end
  end
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - days * 86400)
  local gone = trim.plan(evs, recall.list(cfg, song, room), cutoff)
  if #gone == 0 then return 0 end
  local root = cfg.root:gsub("[/\\]+$", "")
  -- (a shared folder at the top of a drive has no folder above it: the archive went inside it then, to every computer. StudioSync's own
  -- folder takes it instead. Review, 0.58.91)
  local parent = root:match("^(.*)[/\\][^/\\]+$")
  local archive = ((parent and parent ~= "") and parent or band.home())
    .. "/StudioSync history archive/" .. song .. "/" .. room
  reaper.RecursiveCreateDirectory(archive, 0)
  local n, took = 0, {}
  for _, id in ipairs(gone) do
    local from, to = dir .. "/" .. id .. ".json", archive .. "/" .. id .. ".json"
    -- (another drive: copied, then the original removed once the copy is there. copy_atomic returns nothing, so the original always stayed)
    if os.rename(from, to) or (pcall(band.copy_atomic, from, to) and reaper.file_exists(to) and os.remove(from)) then n, took[#took + 1] = n + 1, id end
  end
  local prints_gone = trim.prints(cfg, song, room, evs, took, archive)
  -- what went, for the band: the Google Drive copy still has these, and would bring them back (lib/drive.lua)
  if #took > 0 then
    local list = dir:gsub("/events$", "/trimmed")
    reaper.RecursiveCreateDirectory(list, 0)
    local stamp = cfg.user:gsub("[^%w%-_]", "_") .. "-" .. os.date("!%Y%m%d-%H%M%S")
    band.write_json(list .. "/" .. stamp .. ".json", took)
    if #prints_gone > 0 then band.write_json(list .. "/" .. stamp .. "-media.json", { media = prints_gone }) end
  end
  return n
end

return trim
