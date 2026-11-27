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

-- a before b? (bytes: the digits' own order, whatever the locale)
function rank.less(a, b)
  for i = 1, math.min(#a, #b) do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then return x < y end
  end
  return #a < #b
end

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

return rank
