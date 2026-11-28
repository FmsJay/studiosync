-- A track's place as a rank (docs/rt/rt-sync2.md section 3, docs/rt/rt-sync2c.md phase 4): a short code that sorts, kept on the track
-- (P_EXT:band_rank) and carried in its version as the setting `rank`, so the order of the studio's tracks is worked out from their versions
-- alone, the same way on every computer: a late joiner sorts and is right. A move gives the moved track a rank between its new neighbours';
-- two moves made at once each stand or the newer does (the judge merges `rank` as any setting). Pure: no REAPER, no clock, no module state.
-- Ranks are fractions in base 62 written with the digits 0-9A-Za-z, most significant first ("V" is about a half), never ending in "0" (so
-- each fraction has one spelling). Compared byte by byte, never with Lua's string `<`, which follows the C library's collation (a locale
-- that sorts case-insensitively would order "a" and "B" differently on another computer).
local rank = {}

rank.MAX = 32 -- characters at most (rt-sync2 section 13: a bandmate's rank longer than this, or with other characters, isn't one)
local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local VAL = {}
for i = 1, #DIGITS do VAL[DIGITS:byte(i)] = i - 1 end

function rank.valid(r)
  return type(r) == "string" and #r >= 1 and #r <= rank.MAX and not r:find("[^0-9A-Za-z]") and r:sub(-1) ~= "0"
end

-- a before b, byte by byte (the digits' own order, whatever the locale). The common start is skipped 8 bytes at a time: ids share long ones.
local byte, sub, min = string.byte, string.sub, math.min
function rank.bytes_less(a, b)
  if a == b then return false end
  local i, n = 1, min(#a, #b)
  while i + 7 <= n and sub(a, i, i + 7) == sub(b, i, i + 7) do i = i + 8 end
  for j = i, n do
    local x, y = byte(a, j), byte(b, j)
    if x ~= y then return x < y end
  end
  return #a < #b
end
-- Does `lt` (Lua's `<` by default) order strings byte by byte? It follows the C library's collation: bytes in the "C" locale a program starts
-- in, but a locale REAPER or a script sets can put "a" before "B" or pass over "-". Asked of every pair of printable characters, and of each
-- one before a letter (one passed over reads "-b" after "a"). -> true or false. Pure.
function rank.native_ok(lt)
  lt = lt or function(x, y) return x < y end
  local ch = {}
  for c = 32, 126 do ch[c] = string.char(c) end
  for c = 32, 126 do
    if lt(ch[c] .. "b", "a") ~= (c < 97) then return false end
    for d = 32, 126 do if lt(ch[c], ch[d]) ~= (c < d) then return false end end
  end
  return true
end
-- a before b? Lua's own `<` where it is byte order on this computer (checked once, as this file loads: ~25x faster on a sort of 4,000 ids),
-- else bytes_less. Everything that orders ids, clocks or names to decide something uses this (lib/judge.lua, rt-sync2e).
rank.native = rank.native_ok()
rank.less = rank.native and function(a, b) return a < b end or rank.bytes_less

-- A rank strictly between a and b (nil a: the start, nil b: the end), as short as it can be. -> nil when a isn't before b, or the answer
-- would pass MAX characters (rank.spread the tracks again).
function rank.between(a, b)
  if a ~= nil and not rank.valid(a) or b ~= nil and not rank.valid(b) then return nil end
  if a and b and not rank.less(a, b) then return nil end
  a = a or ""
  local out, hi = {}, b
  for i = 1, rank.MAX do
    local da = VAL[a:byte(i) or 48]
    local db = hi and VAL[hi:byte(i) or 48] or 62 -- (past b's end its digits are 0; with no upper bound left, 62: one more than "z")
    if db - da >= 2 then
      out[#out + 1] = DIGITS:sub(da + (db - da) // 2 + 1, da + (db - da) // 2 + 1)
      return table.concat(out)
    end
    out[#out + 1] = DIGITS:sub(da + 1, da + 1)
    if db - da == 1 then hi = nil end -- (below b from here on, whatever follows)
  end
  return nil
end

-- n ranks evenly spaced, in order: a room's tracks given ranks by place (two computers doing it on the same order write the same ranks).
function rank.spread(n)
  local w = 1
  while 62 ^ w <= 2 * n do w = w + 1 end
  local span, out = 62 ^ w, {}
  for i = 1, n do
    local x, d = math.floor(i * span / (n + 1)), {}
    for k = w, 1, -1 do d[k] = DIGITS:sub(x % 62 + 1, x % 62 + 1); x = x // 62 end
    out[i] = (table.concat(d):gsub("0+$", ""))
  end
  return out
end

-- When a track was made, from its oid (K-USER-<yyyymmddhhmmss>-<n>): unranked tracks land oldest first, as mirror.wanted_order lands them.
local function made(oid)
  local when, n = tostring(oid):match("%-(%d+)%-(%d+)$")
  return when or "", tonumber(n) or 0
end

-- The studio's track order. tracks: { { oid, rank, after } } in any order. Ranked tracks by (rank, oid); a track with no rank (made by a
-- StudioSync before ranks) right under the track its version sat under (`after`), oldest first, else at the end. -> a list of oids.
function rank.order(tracks)
  local ranked, unranked = {}, {}
  for _, t in ipairs(tracks) do
    if rank.valid(t.rank) then ranked[#ranked + 1] = t else unranked[#unranked + 1] = t end
  end
  table.sort(ranked, function(x, y)
    if x.rank ~= y.rank then return rank.less(x.rank, y.rank) end
    return rank.less(x.oid, y.oid)
  end)
  local out = {}
  for i, t in ipairs(ranked) do out[i] = t.oid end
  table.sort(unranked, function(x, y)
    local wx, nx = made(x.oid)
    local wy, ny = made(y.oid)
    if wx ~= wy then return rank.less(wx, wy) end
    if nx ~= ny then return nx < ny end
    return rank.less(x.oid, y.oid)
  end)
  repeat
    local landed, k = false, 1
    while k <= #unranked do
      local t, at = unranked[k], nil
      if (t.after or "") == "" then at = 0 else for i, x in ipairs(out) do if x == t.after then at = i; break end end end
      if at then table.insert(out, at + 1, t.oid); table.remove(unranked, k); landed = true else k = k + 1 end
    end
  until not landed
  for _, t in ipairs(unranked) do out[#out + 1] = t.oid end -- (what it sat under isn't here)
  return out
end

-- Folders as parent + rank (docs/rt/rt-sync2.md section 3, James's decision 4; docs/rt/rt-sync2d.md). Each track names the folder it is in
-- (`parent`: an oid, or "" for the top level); REAPER's depths are worked out from the tree, never taken as the truth.
-- The parent each track's depth gives it in `order` (REAPER's I_FOLDERDEPTH: 1 opens a folder, -n closes n after the track). -> oid -> parent.
function rank.depth_parents(order, depth)
  local par, stack = {}, {}
  for _, oid in ipairs(order) do
    par[oid] = stack[#stack] or ""
    local d = tonumber(depth[oid]) or 0
    if d == 1 then stack[#stack + 1] = oid elseif d < 0 then for _ = 1, -d do stack[#stack] = nil end end
  end
  return par
end

-- The studio's tree. tracks: { { oid, rank, after, parent, depth, newest } } in any order. `parent` nil: not said (a version from a StudioSync
-- before parents, or one not given one yet): the parent its version's depth gives it in the rank order, as REAPER's depths have always said
-- it, not the `parent` its version read: a track wasn't sent again when only that changed (a folder closed further down), so it's stale.
-- A parent not here, or the track itself, is the top level. A loop of parents (two moves at once, each into the other) is broken by the
-- track whose version is the newest (`newest`, compared byte by byte; then the larger oid) going to the top level: the move made last, the
-- one that can't have seen the other. -> the order (a depth-first walk, each level in rank order), and oid -> parent.
function rank.tree(tracks)
  local flat = rank.order(tracks)
  local by, depth = {}, {}
  for _, t in ipairs(tracks) do by[t.oid] = t; depth[t.oid] = t.depth end
  local inferred, par = rank.depth_parents(flat, depth), {}
  for _, oid in ipairs(flat) do
    local p = by[oid].parent
    if p == nil then p = inferred[oid] end
    par[oid] = (p ~= oid and by[p]) and p or ""
  end
  for _, oid in ipairs(flat) do -- (loops: a walk up that comes back round)
    local seen, x = {}, oid
    while x ~= "" and not seen[x] do seen[x] = true; x = par[x] end
    if x ~= "" then
      local y, last = par[x], x
      while true do
        local a, b = tostring(by[y].newest or ""), tostring(by[last].newest or "")
        if a ~= b and rank.less(b, a) or a == b and rank.less(last, y) then last = y end
        if y == x then break end
        y = par[y]
      end
      par[last] = ""
    end
  end
  local kids = { [""] = {} }
  for _, oid in ipairs(flat) do kids[oid] = kids[oid] or {}; local p = par[oid]; kids[p] = kids[p] or {}; table.insert(kids[p], oid) end
  local out = {}
  local function walk(p) for _, x in ipairs(kids[p]) do out[#out + 1] = x; walk(x) end end
  walk("")
  return out, par
end

-- REAPER depths that make `order` hold the tree `par` (oid -> parent). Where the order can't (a track whose parent isn't open above it, as
-- REAPER reads folders: the order not sorted yet), that track goes to the top level. -> oid -> depth, and oid -> the parent REAPER will read.
function rank.depths(order, par)
  local stack, level, got = {}, {}, {}
  for i, oid in ipairs(order) do
    local p = par[oid] or ""
    local k = 0
    for j = #stack, 1, -1 do if stack[j] == p then k = j; break end end
    if p ~= "" and k == 0 and order[i - 1] == p then stack[#stack + 1] = p; k = #stack end -- (the track above opens its folder)
    for j = #stack, k + 1, -1 do stack[j] = nil end
    level[oid], got[oid] = #stack, stack[#stack] or ""
  end
  local out = {}
  for i, oid in ipairs(order) do out[oid] = (order[i + 1] and level[order[i + 1]] or 0) - level[oid] end
  return out, got
end

return rank
