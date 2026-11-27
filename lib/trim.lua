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
  -- (a tempo map or a cue: as sync orders them, ev.order first. Review, 0.58.96: by the sender's clock, trim could keep an older map)
  if a.type ~= "obj" and b.type ~= "obj" then return (a.order or ((a.time or "") .. (a.id or ""))) > (b.order or ((b.time or "") .. (b.id or ""))) end
  local mirror = require("mirror")
  local x, y = { rev = a.rev, time = mirror.order_of(a) }, { rev = b.rev, time = mirror.order_of(b) }
  if mirror.newer(x, y) ~= mirror.newer(y, x) then return mirror.newer(x, y) end
  return (a.id or "") > (b.id or "")
end
-- A point is major unless it's the snapshot taken before a handover, or a song hub's rolling one (lib/hub.lua: every half hour of work, so
-- as majors they'd keep nearly every change; the kept end-of-session points stay major. James, rt).
function trim.major(p) return p.keep or not (tostring(p.label or ""):match("^before .+ took over") or p.label == "hub snapshot") end

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
  -- (the judge's support (lib/judge.lua, rt-sync2b): every change of an object that no other change builds on, its leaves, which is what the
  -- judge merges or weighs; and, where an object has more than one, its deletions, since an edit stays beaten only while the deletion that
  -- beat it is there. The newest rival alone lost a three-way merge's third change after 60 days (round 1 review, 0.59.45); edits only, a
  -- deletion that had beaten a newer edit went, and the edit came back everywhere. Changes something builds on still go, so losing branches
  -- don't keep history growing.)
  local based, leaves = {}, {}
  for _, ev in ipairs(evs) do
    if type(ev.base_ev) == "string" then for part in ev.base_ev:gmatch("[^()&]+") do based[part] = true end end
  end
  for _, ev in ipairs(evs) do
    local k = key_of(ev)
    if k and newest[k] and ev.type == "obj" and not based[ev.id] and not behind[ev.id] then
      if ev.base_ev or ev.gone then keep[ev.id] = true end -- (one with nothing under it never merges: only the newest of those counts)
      leaves[k] = (leaves[k] or 0) + 1
    end
  end
  for _, ev in ipairs(evs) do
    local k = key_of(ev)
    if k and ev.gone and (leaves[k] or 0) > 1 then keep[ev.id] = true end
  end
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
  -- (and every version a major saved version's own map names (p.known, recall.save): restoring it rebuilds exactly that. After the bases
  -- above, so a plain one doesn't keep its own base too; a merge keeps its sides and their bases, through need. Round 1 review, 0.59.45)
  for _, p in ipairs(points) do
    if trim.major(p) and type(p.known) == "table" then
      for _, id in pairs(p.known) do need(id, 0) end
    end
  end
  -- (each major point's newest change of each object at or before it: one walk through the changes in time order, the points in time order,
  -- keeping each object's newest so far and, at each point, only the objects whose newest moved since the point before (the others were kept
  -- there already). A loop over the changes for every point was 80-200 ms for a 2,500-change room with ~180 saved versions on REAPER's thread
  -- in the cloud copy's sweep (points x changes calls of `later`). rt-p2)
  local times = {}
  for _, p in ipairs(points) do if trim.major(p) and p.time then times[#times + 1] = p.time end end
  if #times > 0 then
    table.sort(times)
    local list = {}
    for _, ev in ipairs(evs) do local k = key_of(ev); if k and k ~= TRANSPORT then list[#list + 1] = ev end end
    table.sort(list, function(a, z) return (a.time or "") < (z.time or "") end)
    local at, moved, i = {}, {}, 1
    for _, t in ipairs(times) do
      while list[i] and (list[i].time or "") <= t do
        local ev = list[i]
        local k = key_of(ev)
        if not at[k] or later(ev, at[k]) then at[k], moved[k] = ev, true end
        i = i + 1
      end
      for k in pairs(moved) do keep[at[k].id] = true end
      moved = {}
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
-- The stage files of chained prints (lib/prints.lua: "stage-<oid>-<hash>-<k>-...") among `files` that belong to a print in `gone`
-- ({ name = true }, "print-<oid>-<hash>-<who>"): no change names them, so they go with the print they made. 0.59.49. Pure.
function trim.stage_files(files, gone)
  local pre = {}
  for name in pairs(gone) do
    local k = name:match("^print%-(.+%-%x%x%x%x%x%x%x%x)%-") or name:match("^print%-(.+%-%x%x%x%x%x%x%x%x)$")
    if k then pre[#pre + 1] = "stage-" .. k .. "-" end
  end
  local out = {}
  for _, f in ipairs(files) do
    for _, p in ipairs(pre) do if f:sub(1, #p) == p then out[#out + 1] = f; break end end
  end
  table.sort(out)
  return out
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
      -- (and what its copy was made with, which no change names: lib/rooms.lua note_prints. A side room from before that keeps every print. 0.59.10)
      local noted = false
      for _, f in ipairs(band.files(rooms_dir .. "/" .. r, ".json")) do
        if f:match("^plays%-") then
          noted = true
          local t = band.read_json(rooms_dir .. "/" .. r .. "/" .. f)
          for _, n in ipairs(type(t) == "table" and t or {}) do still[tostring(n)] = true end
        end
      end
      if not noted and r ~= "main" then return moved end
    end
  end
  local media = sync.room_dir(cfg, song, room) .. "/media"
  reaper.RecursiveCreateDirectory(archive .. "/media", 0)
  local files, gone = {}, {}
  for name in pairs(cand) do
    if not still[name] then
      gone[name] = true
      for _, ext in ipairs({ ".flac", ".opus" }) do files[#files + 1] = name .. ext end
    end
  end
  for _, f in ipairs(trim.stage_files(band.files(media), gone)) do files[#files + 1] = f end -- (and the stages they were made in: 0.59.49)
  for _, f in ipairs(files) do
    local from, to = media .. "/" .. f, archive .. "/media/" .. f
    if reaper.file_exists(from) and (os.rename(from, to) or (pcall(band.copy_atomic, from, to) and reaper.file_exists(to) and os.remove(from))) then
      moved[#moved + 1] = f
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
  -- (each major saved version with its map read from its file: the rows recall.list shares carry no map. Read only here, as trim is rare)
  local points = {}
  for i, p in ipairs(recall.list(cfg, song, room)) do
    points[i] = setmetatable({ known = trim.major(p) and recall.known(cfg, song, room, p.file) or nil }, { __index = p }) -- (its sidecar: Round 2, 0.59.46)
  end
  local gone = trim.plan(evs, points, cutoff)
  if #gone == 0 then return 0 end
  local root = cfg.root:gsub("[/\\]+$", "")
  -- (a shared folder at the top of a drive has no folder above it: the archive went inside it then, to every computer. StudioSync's own
  -- folder takes it instead. Review, 0.58.91)
  local parent = root:match("^(.*)[/\\][^/\\]+$")
  local archive = ((parent and parent ~= "") and parent or band.home())
    .. "/StudioSync history archive/" .. song .. "/" .. room
  reaper.RecursiveCreateDirectory(archive, 0)
  -- (what goes is listed first: a computer that saw the events gone before the list arrived copied them back from Drive. Review, 0.58.96)
  local list = dir:gsub("/events$", "/trimmed")
  local stamp = cfg.user:gsub("[^%w%-_]", "_") .. "-" .. os.date("!%Y%m%d-%H%M%S")
  if #gone > 0 then reaper.RecursiveCreateDirectory(list, 0); band.write_json(list .. "/" .. stamp .. ".json", gone) end
  local n, took = 0, {}
  for _, id in ipairs(gone) do
    local from, to = dir .. "/" .. id .. ".json", archive .. "/" .. id .. ".json"
    -- (another drive: copied, then the original removed once the copy is there. copy_atomic returns nothing, so the original always stayed)
    if os.rename(from, to) or (pcall(band.copy_atomic, from, to) and reaper.file_exists(to) and os.remove(from)) then n, took[#took + 1] = n + 1, id end
  end
  local prints_gone = trim.prints(cfg, song, room, evs, took, archive)
  -- what went, for the band: the Google Drive copy still has these, and would bring them back (lib/drive.lua)
  if #took > 0 and #prints_gone > 0 then band.write_json(list .. "/" .. stamp .. "-media.json", { media = prints_gone }) end
  return n
end

return trim
