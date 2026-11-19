-- Song forks (James, rt: "branch an arrangement, keep or merge back"). A fork is a side room (lib/rooms.lua) with its origin noted. A room
-- already is a branch: its own tab, its history starting where it was made, the media shared through the room folders (nothing copied), and
-- Bring into / Send selected for the way back (lib/mirror.lua). So a fork adds only what a branch needs on top of that: where it came from (a
-- room, and the saved version it was made from, if any), how it and its original differ, bringing back only the changes picked, and adopting
-- it as the main version, the old main kept as a fork of its own.
--   rooms/<fork>/room.json  { parent, by, time, base, ..., fork = { from, version, label }, adopted = { by, time, kept } }
-- A fork made from a saved version is "Open in side room" with a name (lib/page_restore.lua): the room made from now, then put back to then.
local forks = {}

-- Where a fork came from, in words, for its square. `r`: a rooms.list row. Pure.
function forks.origin_words(r)
  local f = type(r.fork) == "table" and r.fork or {}
  local words = "fork of " .. tostring(f.from or r.parent or "main")
  if f.label then words = words .. ", from '" .. f.label .. "'" end
  if type(r.adopted) == "table" then words = words .. "; adopted as " .. tostring(f.from or r.parent) .. " by " .. tostring(r.adopted.by) end
  return words
end

-- The original's changes since the fork was made that didn't come from the fork itself (`newest`: mirror.room_newest of the original,
-- since the fork's time). -> a list. Pure.
function forks.theirs(newest, fork_name)
  local out = {}
  for _, ev in pairs(newest or {}) do if ev.from_room ~= fork_name then out[#out + 1] = ev end end
  return out
end

-- The comparison, track by track: what only the fork changed (`bring`), what both changed (`clash`), what only the original changed
-- (`theirs`). Events name their track as `name` (the track's name). -> { { name, fork, both, theirs } } by name. Pure.
function forks.by_track(bring, clash, theirs)
  local rows, at = {}, {}
  local function add(list, field)
    for _, ev in ipairs(list or {}) do
      local name = (ev.name or "") ~= "" and ev.name or "(unnamed track)"
      local r = at[name]
      if not r then r = { name = name, fork = 0, both = 0, theirs = 0 }; at[name] = r; rows[#rows + 1] = r end
      r[field] = r[field] + 1
    end
  end
  add(bring, "fork"); add(clash, "both"); add(theirs, "theirs")
  table.sort(rows, function(a, z) return a.name:lower() < z.name:lower() end)
  return rows
end

-- The changes to bring when only some are ticked (`chosen`: oid -> true). A ticked item or plug-in chain on a track the original hasn't got
-- (`parent_has`: oid -> true) brings that track along, or it would wait for its track for good; a ticked new track brings its own parts
-- (plug-ins, automation, sends), not its items. The order stays bring's (tracks first). Pure.
function forks.pick(bring, chosen, parent_has)
  local want, tracks = {}, {}
  for _, ev in ipairs(bring) do if ev.obj == "track" then tracks[ev.oid] = ev end end
  for _, ev in ipairs(bring) do
    if chosen[ev.oid] then
      want[ev.oid] = true
      if ev.obj ~= "track" and ev.track and tracks[ev.track] and not (parent_has or {})[ev.track] then want[ev.track] = true end
    end
  end
  for _, ev in ipairs(bring) do
    if ev.obj ~= "track" and ev.obj ~= "item" and ev.track and chosen[ev.track] and not (parent_has or {})[ev.track] then want[ev.oid] = true end
  end
  local out = {}
  for _, ev in ipairs(bring) do if want[ev.oid] then out[#out + 1] = ev end end
  return out
end

-- A name for the old main version when a fork is adopted: "<parent> before <fork>", within rooms' 30 letters and not taken (`taken`: lower-case
-- names -> true). Pure.
function forks.keep_name(parent, fork, taken)
  local function fit(s, room) return (s:sub(1, room):gsub("[%s%-_]+$", "")) end
  local stem = fit(parent .. " before " .. fork, 30)
  local name, n = stem, 1
  while taken[name:lower()] do
    n = n + 1
    name = fit(stem, 30 - #tostring(n) - 1) .. " " .. n
  end
  return name
end

-- What adopting does to the original: every object made exactly as the fork has it (`known`: the fork's own map, oid -> event id, as
-- recall.save keeps it); what the original has and the fork doesn't goes. Both rooms' histories are looked through, as an object can be the
-- original's (untouched since the fork) or the fork's own. `lookup(id)` -> the event. -> a plan for mirror.revert. Pure.
function forks.adopt_plan(parent_entries, fork_entries, known, lookup)
  local all = {}
  for _, e in ipairs(parent_entries) do all[#all + 1] = e end
  for _, e in ipairs(fork_entries) do all[#all + 1] = e end
  return require("mirror").plan_known(all, known, lookup)
end

-- Make a fork of the room in tab `proj` (binding b) as it is now, and go there. -> its tab, or nil + why.
function forks.create(proj, cfg, b, name)
  local newest = require("recall").list(cfg, b.song, b.room)[1]
  return require("rooms").create(proj, cfg, b, name, nil, { fork = { from = b.room, version = newest and newest.file } })
end

-- Adopt the fork in tab `proj` as the main version: its original (open here, driven by you) is kept as it is now as a fork of its own, then
-- made exactly as the fork has it, for everyone, as new changes there (so Restore there can go back). -> the kept fork's name and what
-- happened, or nil + why.
function forks.adopt(proj, cfg, b, session)
  local band, sync, rooms, recall, mirror = require("band"), require("sync"), require("rooms"), require("recall"), require("mirror")
  local meta = rooms.meta(cfg, b.song, b.room)
  local parent = meta and meta.parent
  if not parent then return nil, "This is the main room: there's nothing to adopt it into." end
  local ptab = rooms.tab(b.song, parent)
  if not ptab then return nil, "Open '" .. parent .. "' here first (its square on the Rooms page), then come back here to adopt." end
  local driver = sync.driver(cfg, b.song, parent, session)
  if driver ~= cfg.user then return nil, tostring(driver) .. " drives '" .. parent .. "': they adopt it, or take control there first." end
  local known = mirror.known_map(proj) -- (read before any tab switch: this fork as it stands here)
  local taken = {}
  for _, r in ipairs(rooms.list(cfg, b.song)) do taken[r.name:lower()] = true end
  local keep = forks.keep_name(parent, b.room, taken)
  local pb = band.binding(ptab) or { song = b.song, room = parent }
  local kept, why = rooms.create(ptab, cfg, pb, keep, nil, { fork = { from = parent, label = "before '" .. b.room .. "' was adopted" } })
  if not kept then return nil, "Couldn't keep '" .. parent .. "' as it is first, so nothing was changed: " .. tostring(why) end
  reaper.SelectProjectInstance(ptab)
  local pentries, fentries = recall.entries(cfg, b.song, parent), recall.entries(cfg, b.song, b.room)
  local pdir, fdir = sync.room_dir(cfg, b.song, parent), sync.room_dir(cfg, b.song, b.room)
  local by_id = {}
  for _, e in ipairs(pentries) do if e.id then by_id[e.id] = e end end
  for _, e in ipairs(fentries) do if e.id then by_id[e.id] = e end end
  local plan = forks.adopt_plan(pentries, fentries, known, function(id) return by_id[id] or mirror.event_file(pdir, id) or mirror.event_file(fdir, id) end)
  sync.restore_timeline(ptab, cfg, b.song, parent, fentries, #fentries, session, b.room)
  local can, who = sync.authority(cfg, b.song, parent, session)
  local said = mirror.revert(ptab, cfg, b.song, parent, plan, { can = can, mode = who and who.mode, driver = who and who.driver, is_claimed = who and who.is_claimed,
    local_mix = select(2, reaper.GetProjExtState(ptab, band.SECTION, "local_mix")) == "1" })
  meta.adopted = { by = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), kept = keep }
  band.write_json(fdir .. "/room.json", meta)
  return keep, said
end

return forks
