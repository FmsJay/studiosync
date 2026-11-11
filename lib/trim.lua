-- History trim (James, 2026-11-01: "can trim history as long as major restore points are saved"). A room's events
-- folder keeps every change ever made; after a while that's thousands of files every machine reads. Trimmed:
-- changes older than `days` that nothing needs any more. Kept, always:
--   each object's newest change (what the song is now, and what a machine that was away catches up to);
--   for each major restore point (kept ones: end of session, "yours before X's work done alone"; and every version
--   someone saved by hand), each object's newest change at or before it, so it still restores exactly;
--   handovers, notes and likes (who drove when decides old changes' authority; notes are people's words).
-- Minor points (the snapshot before a handover) may lose their exact past. Trimmed files leave the band folder (so
-- every machine's copy goes) into <band folder's parent>/StudioSync history archive/<song>/<room>/ on the machine that
-- trimmed, so nothing is lost for good.
local band = require("band")
local trim = {}

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
    if key_of(ev) and not keep[ev.id] and (ev.time or "") < cutoff then out[#out + 1] = ev.id end
  end
  table.sort(out)
  return out
end

-- Trim one room now. Returns how many went. `days`: how old a change has to be (30).
function trim.run(cfg, song, room, days)
  local sync, recall = require("sync"), require("recall")
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local evs = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local ev = band.read_json(dir .. "/" .. f)
    if type(ev) == "table" and type(ev.id) == "string" and ev.id .. ".json" == f then evs[#evs + 1] = ev end
  end
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - (days or 30) * 86400)
  local gone = trim.plan(evs, recall.list(cfg, song, room), cutoff)
  if #gone == 0 then return 0 end
  local root = cfg.root:gsub("[/\\]+$", "")
  local archive = (root:match("^(.*)[/\\][^/\\]+$") or root) .. "/StudioSync history archive/" .. song .. "/" .. room
  reaper.RecursiveCreateDirectory(archive, 0)
  local n, took = 0, {}
  for _, id in ipairs(gone) do
    local from, to = dir .. "/" .. id .. ".json", archive .. "/" .. id .. ".json"
    if os.rename(from, to) or (band.copy_atomic and band.copy_atomic(from, to) and os.remove(from)) then n, took[#took + 1] = n + 1, id end
  end
  -- what went, for the band: the Google Drive copy still has these, and would bring them back (lib/drive.lua)
  if #took > 0 then
    local list = dir:gsub("/events$", "/trimmed")
    reaper.RecursiveCreateDirectory(list, 0)
    band.write_json(list .. "/" .. cfg.user:gsub("[^%w%-_]", "_") .. "-" .. os.date("!%Y%m%d-%H%M%S") .. ".json", took)
  end
  return n
end

return trim
