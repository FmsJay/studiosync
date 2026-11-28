-- The judge (docs/rt/rt-sync2.md section 1, phase 2 in docs/rt/rt-sync2b.md): what one object is, worked out from that object's own versions
-- and nothing else, the same way on every computer. Receiving, catching up, heal, Restore, History playback, the join bootstrap, history trim
-- and media in use all ask it.
--
--   judge.settled(vs, read, opt) -> s
--     vs    every readable version of one object found here ({ id, rev, hlc or time + user, base_ev, gone, track, state on demand, ... })
--     read  id -> a version or a merged version ("m(a&b)", rebuilt from its sides: lib/mirror.lua event_file), or nil and true when a version
--           the merge needs isn't here
--     opt   { mergeable = fn(version) -> may it merge (mirror.mergeable), days = MERGE_DAYS, give_up = true: every missing version counts as
--           trimmed (a restore's "use what's here", a receive that has waited long enough for one) }
--     s     { v = the version every computer ends on (a change, a merge, or nil when vs is empty or the answer is incomplete), gone,
--             complete (false while a version the answer needs isn't here; missing = their ids, sorted), leaves, beaten (ids, sorted) }
--
-- The rule: (1) ancestry through base_ev and both sides of a merge; (2) the leaves are the versions nothing here builds on; (3) a leaf that
-- isn't a deletion is beaten when some deletion here isn't in its ancestry (it was made without seeing it), for every kind of object; (4) one
-- edit leaf is the answer; (5) several are merged, oldest first, each newer one winning (merge_order), when every one may merge, builds on
-- something and they're within MERGE_DAYS of each other; (6) otherwise the newest leaf (rev, then clock, then name, then id); (7) more than
-- MAX_LEAVES leaves: the newest, unmerged. Walks stop after MAX_STEPS. A version missing from a walk makes the answer incomplete, unless its
-- id dates it more than MERGE_DAYS before the newest version here (trimmed, not on its way).
--
-- Pure: no REAPER calls, no clock, no module state. Every iteration that decides anything goes in id order (never `pairs`).
local judge = { MAX_LEAVES = 64, MAX_STEPS = 400, MERGE_DAYS = 30 }
-- Ids, clocks and names compared byte by byte, never with Lua's `<`: that follows the C library's collation, which a computer's locale can
-- change ("B" before "a" in bytes, after it in most languages), and every computer has to order versions alike. rt-sync2e
local less = require("rank").less
judge.less = less

-- (UTC by arithmetic: os.time works in local time, and a time zone offset taken once was an hour out across a daylight saving change. Review, 0.58.47)
local function utc_secs(y, mo, d, h, mi, s)
  y = mo <= 2 and y - 1 or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (mo + (mo > 2 and -3 or 9)) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  return days * 86400 + h * 3600 + mi * 60 + s
end
judge.utc_secs = utc_secs
-- What equal revisions are settled by, an "order": "<ms>|<user>" since 0.58.43, a hybrid logical clock (milliseconds, never behind any change
-- this computer has seen, so a clock that's minutes off can't win ties it shouldn't: docs/clashes.md), or "<YYYY-MM-DDTHH:MM:SSZ><user>" from
-- before. -> milliseconds (UTC), the rest.
function judge.order_parts(o)
  o = o or ""
  local ms, rest = o:match("^(%d+)|(.*)$")
  if ms then return tonumber(ms), rest end
  local y, mo, d, h, mi, s, after = o:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z(.*)$")
  if y then return utc_secs(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)) * 1000, after end
  return 0, o
end
function judge.order_of(ev)
  if tonumber(ev.hlc) then return string.format("%d|%s", tonumber(ev.hlc), ev.user or "") end
  return (ev.time or "") .. (ev.user or "")
end
-- Which of two revisions of one object wins: higher rev, then the later order, then the larger user name (so every machine picks the same
-- one). `time` holds an order (or a plain time, with `user` beside it).
function judge.newer(a, b)
  if not b then return true end
  if not a then return false end
  if (a.rev or 0) ~= (b.rev or 0) then return (a.rev or 0) > (b.rev or 0) end
  local am, au = judge.order_parts(a.time)
  local bm, bu = judge.order_parts(b.time)
  if am ~= bm then return am > bm end
  return less(bu .. (b.user or ""), au .. (a.user or ""))
end
-- The newer of two versions (as newer, then the larger id: a total order, so a pick never depends on the order a list came in).
local function later(a, b)
  local x, y = { rev = a.rev, time = judge.order_of(a) }, { rev = b.rev, time = judge.order_of(b) }
  local ab, ba = judge.newer(x, y), judge.newer(y, x)
  if ab ~= ba then return ab end
  return less(b.id or "", a.id or "")
end
judge.later = later
local function newest(list)
  local top
  for _, x in ipairs(list) do if not top or later(x, top) then top = x end end
  return top
end
judge.newest = newest

-- When versions were made, from their ids ("<user>-YYYYMMDD-HHMMSSZ-...": a merged one names several): the earliest and the latest, in seconds.
function judge.id_span(id)
  local lo, hi
  for y, mo, d, h, mi, s in tostring(id or ""):gmatch("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z") do
    local t = utc_secs(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
    lo, hi = math.min(lo or t, t), math.max(hi or t, t)
  end
  return lo, hi
end

-- A merged version has the id "m(<winner>&<loser>)" (either may be one itself). It's nowhere on disk: every computer rebuilds it the same way
-- from the two sides and the version both came from.
function judge.merge_id(winner, loser) return "m(" .. winner .. "&" .. loser .. ")" end
function judge.split_merge(id)
  if type(id) ~= "string" or id:sub(1, 2) ~= "m(" or id:sub(-1) ~= ")" then return nil end
  local inner, depth = id:sub(3, -2), 0
  for i = 1, #inner do
    local c = inner:sub(i, i)
    if c == "(" then depth = depth + 1 elseif c == ")" then depth = depth - 1
    elseif c == "&" and depth == 0 then return inner:sub(1, i - 1), inner:sub(i + 1) end
  end
end
-- What a version builds on, nearest first (both sides of a merge).
local function parents(x) local w, l = judge.split_merge(x.id); return w and { w, l } or { x.base_ev } end
judge.parents = parents

-- Does version `v` build on the version with id `of` (or is it that one)? Followed through base_ev and both sides of a merge. Not by revision
-- number: one edit's quick nudges share a number. A plain change's clock is later than everything it builds on, so the walk stops below `of`'s
-- clock. -> true, false, or nil when it can't tell (a version on the way isn't here: its id goes in `missing`, unless trimmed(id) says it was
-- trimmed). A walk too long to finish counts as building on it.
function judge.descends(read, v, of, of_hlc, missing, trimmed)
  if not v or not of then return false end
  of_hlc = tonumber(of_hlc)
  local todo, seen, steps, lost = { v }, {}, 0, false
  while #todo > 0 do
    steps = steps + 1
    if steps > judge.MAX_STEPS then return true end
    local x = table.remove(todo)
    if x.id == of then return true end
    local w, l = judge.split_merge(x.id)
    if not seen[x.id or ""] and (w or not (of_hlc and tonumber(x.hlc) and tonumber(x.hlc) < of_hlc)) then
      seen[x.id or ""] = true
      for _, id in ipairs(w and { w, l } or { x.base_ev }) do
        if id == of then return true end
        local y = id and read(id)
        if y then todo[#todo + 1] = y
        elseif id and not (trimmed and trimmed(id)) then
          lost = true
          if missing then missing[id] = true end
        end
      end
    end
  end
  if lost then return nil end
  return false
end
-- Two versions made apart: neither builds on the other. -> true, false, or nil (can't tell yet).
function judge.apart(read, a, b)
  if not (a and b) or a.id == b.id then return false end
  local ab, ba = judge.descends(read, a, b.id, b.hlc), judge.descends(read, b, a.id, a.hlc)
  if ab or ba then return false end
  if ab == nil or ba == nil then return nil end
  return true
end
-- The version two versions both build on, nearest to them: everything one builds on, then the first of those the other reaches. -> its id, or
-- nil (and true when none was found and a version one of them builds on couldn't be read here: it may only be on its way).
function judge.common_base(read, a, b)
  local behind, todo, steps, missing = {}, { a }, 0, false
  while #todo > 0 and steps < judge.MAX_STEPS do
    steps = steps + 1
    for _, id in ipairs(parents(table.remove(todo, 1))) do
      if not behind[id] then
        behind[id] = true
        local y = read(id)
        if y then todo[#todo + 1] = y else missing = true end
      end
    end
  end
  local seen
  todo, steps, seen = { b }, 0, {}
  while #todo > 0 and steps < judge.MAX_STEPS do
    steps = steps + 1
    for _, id in ipairs(parents(table.remove(todo, 1))) do
      if behind[id] then return id end
      if not seen[id] then
        seen[id] = true
        local y = read(id)
        if y then todo[#todo + 1] = y else missing = true end
      end
    end
  end
  return nil, missing
end
-- Versions made apart, as one merged version's id, the same whatever order they're given in: oldest first, each newer one winning over what
-- came before. `leaves`: { { id, rev, order } }.
function judge.merge_order(leaves)
  local t = {}
  for i, x in ipairs(leaves) do t[i] = x end
  table.sort(t, function(a, b)
    if a.id == b.id then return false end
    local an, bn = judge.newer({ rev = a.rev, time = a.order }, { rev = b.rev, time = b.order }), judge.newer({ rev = b.rev, time = b.order }, { rev = a.rev, time = a.order })
    if an ~= bn then return bn end -- (a older than b: first)
    return less(a.id, b.id)
  end)
  local acc = t[1] and t[1].id
  for i = 2, #t do acc = judge.merge_id(t[i].id, acc) end
  return acc
end
-- Two versions, one started from a version over MERGE_DAYS older than the newer of them: someone away that long (lib/trim.lua takes such old
-- versions away). Never merged, decided from the ids alone: the newer stands.
function judge.too_old_to_merge(a, b, days)
  local _, newest_a = judge.id_span(a.id)
  local _, newest_b = judge.id_span(b.id)
  local base_a, base_b = judge.id_span(a.base_ev), judge.id_span(b.base_ev)
  local new, base = math.max(newest_a or 0, newest_b or 0), math.min(base_a or math.huge, base_b or math.huge)
  return new - base > (days or judge.MERGE_DAYS) * 86400
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out, less)
  return out
end
local function ids_of(list)
  local out = {}
  for i, x in ipairs(list) do out[i] = x.id end
  table.sort(out, less)
  return out
end

function judge.settled(vs, read, opt)
  opt = opt or {}
  local s = { complete = true, missing = {}, leaves = {}, beaten = {} }
  local list, by = {}, {}
  for _, v in ipairs(vs or {}) do
    if type(v) == "table" and type(v.id) == "string" and not by[v.id] then by[v.id] = v; list[#list + 1] = v end
  end
  if #list == 0 then return s end
  table.sort(list, function(a, b) return less(a.id, b.id) end)
  local function rd(id) local x = by[id]; if x then return x end; return (read(id)) end
  local days, hi = opt.days or judge.MERGE_DAYS, 0
  for _, v in ipairs(list) do local _, h = judge.id_span(v.id); if h and h > hi then hi = h end end
  local function trimmed(id)
    if opt.give_up then return true end
    local _, h = judge.id_span(id)
    return h ~= nil and hi - h > days * 86400
  end
  local miss = {}
  local function incomplete()
    s.complete, s.missing = false, sorted_keys(miss)
    return s
  end
  -- (2) the leaves: nothing here names them as what it builds on (a merge named as a base names its sides too)
  local ref = {}
  local function flat(id, depth)
    if type(id) ~= "string" or ref[id] or depth > 40 then return end
    ref[id] = true
    local w, l = judge.split_merge(id)
    if w then flat(w, depth + 1); flat(l, depth + 1) end
  end
  for _, v in ipairs(list) do for _, p in ipairs(parents(v)) do flat(p, 0) end end
  local cand = {}
  for _, v in ipairs(list) do if not ref[v.id] then cand[#cand + 1] = v end end
  if #cand == 0 then cand = { newest(list) } end -- (every one named by another: a loop of bases, which no StudioSync writes)
  if #cand > judge.MAX_LEAVES then -- (7) a flood: the newest, unmerged
    s.leaves, s.v = ids_of(cand), newest(cand)
    s.gone = s.v.gone == true
    return s
  end
  -- ... and one another builds on through a version that isn't in vs (read from the folder, or missing)
  if #cand > 1 then
    local keep = {}
    for i, x in ipairs(cand) do
      local under, unsure = false, false
      for j, y in ipairs(cand) do
        if i ~= j and not under then
          local d = judge.descends(rd, y, x.id, x.hlc, miss, trimmed)
          if d then under = true elseif d == nil then unsure = true end
        end
      end
      if not under then
        if unsure then return incomplete() end
        keep[#keep + 1] = x
      end
    end
    cand = keep
  end
  s.leaves = ids_of(cand)
  -- (3) a deletion beats every version that didn't see it, whatever its rev or clock: one rule for every kind of object
  local gones, edits, dels = {}, {}, {}
  for _, v in ipairs(list) do if v.gone then gones[#gones + 1] = v end end
  for _, x in ipairs(cand) do
    if x.gone then dels[#dels + 1] = x
    else
      local beaten, unsure = false, false
      for _, g in ipairs(gones) do
        if not beaten then
          local d = judge.descends(rd, x, g.id, g.hlc, miss, trimmed)
          if d == false then beaten = true elseif d == nil then unsure = true end
        end
      end
      if beaten then s.beaten[#s.beaten + 1] = x.id
      elseif unsure then return incomplete()
      else edits[#edits + 1] = x end
    end
  end
  table.sort(s.beaten, less)
  if #edits == 0 then -- (every leaf a deletion, or beaten by one: gone)
    s.v = newest(#dels > 0 and dels or gones)
    s.gone = true
    return s
  end
  if #edits == 1 then s.v = edits[1]; return s end
  -- (5) several edit leaves: merged, oldest first, each newer one winning where both changed the same thing
  local ok = opt.mergeable ~= nil
  local new_t, base_t = 0, math.huge
  for _, x in ipairs(edits) do
    if ok and not (x.base_ev and opt.mergeable(x)) then ok = false end
    local _, h = judge.id_span(x.id)
    local b = judge.id_span(x.base_ev)
    new_t, base_t = math.max(new_t, h or 0), math.min(base_t, b or math.huge)
  end
  if ok and new_t - base_t > days * 86400 then ok = false end -- (6) too far apart to merge: the newest
  if ok then
    local ls = {}
    for i, x in ipairs(edits) do ls[i] = { id = x.id, rev = x.rev, order = judge.order_of(x) } end
    local v, lost = read(judge.merge_order(ls))
    if v then s.v = v; return s end
    -- (what they both build on isn't here yet: wait for it, unless every missing version counts as trimmed)
    if lost and not opt.give_up then return incomplete() end
  end
  s.v = newest(edits) -- (6) what can't be merged: the newest leaf
  return s
end

-- Every version the answer needs to be rebuilt elsewhere (the join bootstrap, history trim): the leaves, beaten ones included, and the
-- deletions among vs when there are several leaves (a beaten edit stays beaten only while the deletion that beat it is there). Sorted ids.
function judge.support(vs, s)
  local keep = {}
  for _, id in ipairs(s.leaves or {}) do keep[id] = true end
  for _, id in ipairs(s.beaten or {}) do keep[id] = true end
  if #(s.leaves or {}) > 1 then for _, v in ipairs(vs) do if v.gone then keep[v.id] = true end end end
  return sorted_keys(keep)
end

return judge
