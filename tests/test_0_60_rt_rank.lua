-- rt-sync2c phase 4 (docs/rt/rt-sync2.md section 3, docs/rt/rt-sync2c.md): a track's place as a rank (lib/rank.lua), carried in its version
-- as `rank`, and the studio's order sorted from the ranks (parts 2-6 come with the order itself). Lua 5.4, from the repo root.
--  1. (pure) rank.valid, rank.less (bytes, not the locale's collation), rank.between strictly between and short, rank.spread in order,
--     rank.order (ranked by rank then oid, an unranked track under the track its version names).
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local rank = require("rank")

-- ---- 1. pure --------------------------------------------------------------------------------------------------------------------------------
do
  assert(rank.valid("V") and rank.valid("0V") and rank.valid("zzzzzzz1"), "ranks")
  assert(not rank.valid("") and not rank.valid("A0") and not rank.valid("a-b") and not rank.valid(string.rep("a", 33)) and not rank.valid(nil) and not rank.valid(5),
    "not ranks: empty, ending in 0, other characters, too long, not text")
  assert(rank.less("9", "A") and rank.less("Z", "a") and rank.less("A", "AA") and not rank.less("a", "B"), "bytes: 0-9 < A-Z < a-z, whatever the locale")
  -- between: strictly between, valid, and short, for many pairs (a fixed pseudo-random walk of inserts)
  local seed = 12345
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
  local list = rank.spread(5)
  for i = 2, #list do assert(rank.less(list[i - 1], list[i]) and rank.valid(list[i]), "spread in order") end
  for _ = 1, 3000 do
    local k = rnd(#list + 1) -- (insert before list[k]; k = #list + 1: at the end)
    local a, b = list[k - 1], list[k]
    local r = rank.between(a, b)
    assert(r and rank.valid(r), "a rank between " .. tostring(a) .. " and " .. tostring(b))
    assert((a == nil or rank.less(a, r)) and (b == nil or rank.less(r, b)), "strictly between: " .. tostring(a) .. " < " .. r .. " < " .. tostring(b))
    table.insert(list, k, r)
  end
  local longest = 0
  for _, r in ipairs(list) do longest = math.max(longest, #r) end
  assert(longest <= rank.MAX, "3,000 random inserts stay within " .. rank.MAX .. " characters: " .. longest)
  assert(rank.between("V", "V") == nil and rank.between("W", "V") == nil and rank.between("x-", nil) == nil, "no rank between equal, reversed or invalid ones")
  for _, n in ipairs({ 1, 2, 61, 62, 100, 4000 }) do
    local sp = rank.spread(n)
    assert(#sp == n, "spread " .. n)
    for i = 1, n do assert(rank.valid(sp[i]) and (i == 1 or rank.less(sp[i - 1], sp[i])), "spread " .. n .. " in order at " .. i) end
  end
  -- order: by rank then oid; an unranked track right under the track it names, oldest first; one naming a track not here at the end
  local o = rank.order({
    { oid = "T-B-20261101000000-2", rank = "V" }, { oid = "T-A-20261101000000-1", rank = "V" }, { oid = "T-C-20261101000000-3", rank = "F" },
    { oid = "T-OLD-20261101000002-1", after = "T-C-20261101000000-3" }, { oid = "T-OLD-20261101000001-1", after = "T-C-20261101000000-3" },
    { oid = "T-GONE-20261101000003-1", after = "T-NOT-HERE" }, { oid = "T-TOP-20261101000004-1", after = "" } })
  assert(table.concat(o, ",") == "T-TOP-20261101000004-1,T-C-20261101000000-3,T-OLD-20261101000002-1,T-OLD-20261101000001-1,T-A-20261101000000-1,T-B-20261101000000-2,T-GONE-20261101000003-1",
    "rank.order: " .. table.concat(o, ","))
  print("rt-rank 1: ranks sort by bytes, between is strictly between and short, spread is in order, unranked tracks sit under their anchor")
end

print("ok rt-rank")
