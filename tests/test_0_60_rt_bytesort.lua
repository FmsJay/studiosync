-- rt-sync2e (docs/rt/rt-sync2e.md, rt-sync2c Recommendation 5): every order the judge decides by compares ids, clocks and names byte by byte
-- (lib/rank.lua rank.less), never with Lua's string `<`, which follows the C library's collation and so the computer's locale. Lua 5.4, from
-- the repo root.
--  1. rank.bytes_less is byte order ("B" before "a", "-" before letters, a prefix first); rank.native_ok turns down a collation that isn't
--     (case-insensitive, or one passing over "-"), and rank.less agrees with bytes whichever it uses here.
--  2. The judge's ties go through rank.less: the newer of two versions alike but for their makers' names or their ids, and a merge's order
--     (checked by loading lib/judge.lua with rank.less reversed: a judge still using `<` doesn't move).
package.path = "lib/?.lua;" .. package.path
local rank = require("rank")

-- ---- 1. byte order, and the check of Lua's own `<` ----------------------------------------------------------------------------------------------
do
  local B = rank.bytes_less
  assert(B("B", "a") and not B("a", "B"), "bytes: upper case before lower")
  assert(B("I-A-1", "IA") and B("ab", "abc") and not B("abc", "abc") and not B("abc", "ab"), "bytes: '-' before letters; a prefix first; equal is not less")
  assert(B("Bee-20270115-080000Z-00001-0001", "Bee-20270115-080000Z-00001-0002") and B("x1234567890abcdefA", "x1234567890abcdefa"), "past the first 8 bytes alike")
  assert(rank.native_ok(function(x, y) return x:lower() < y:lower() end) == false, "a case-insensitive collation isn't byte order")
  assert(rank.native_ok(function(x, y) return (x:gsub("%-", "")) < (y:gsub("%-", "")) end) == false, "nor one that passes over '-'")
  assert(rank.native_ok(function(x, y) return B(x, y) end) == true, "byte order is")
  math.randomseed(7)
  local chars = "-_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz|"
  local function word() local t = {}; for i = 1, math.random(0, 12) do local k = math.random(#chars); t[i] = chars:sub(k, k) end; return table.concat(t) end
  for _ = 1, 5000 do local a, b = word(), word(); assert(rank.less(a, b) == B(a, b), "rank.less is byte order: " .. a .. " / " .. b) end
  print("rt-sync2e bytes 1: byte order, and Lua's own `<` used only where it is byte order (here: " .. tostring(rank.native) .. ")")
end

-- ---- 2. the judge's ties go through rank.less ---------------------------------------------------------------------------------------------------
do
  local real = rank.less
  rank.less = function(a, b) return rank.bytes_less(b, a) end -- (a "locale" ordering everything backwards)
  package.loaded.judge = nil
  local J = require("judge")
  local a = { rev = 2, time = "1800000000000|a", user = "a" }
  local b = { rev = 2, time = "1800000000000|B", user = "B" }
  assert(J.newer(b, a) == true and J.newer(a, b) == false, "the same clock, the makers' names decide, through rank.less (was: `<`)")
  local x = { id = "B-20270115-080000Z-00001-0001", rev = 1, hlc = 1 }
  local y = { id = "a-20270115-080000Z-00001-0001", rev = 1, hlc = 1 }
  assert(J.later(x, y) == true and J.later(y, x) == false, "versions alike but for their ids: the id decides, through rank.less")
  local m = J.merge_order({ { id = "B-1", rev = 1, order = "1800000000000|z" }, { id = "a-1", rev = 1, order = "1800000000000|z" } })
  assert(m == "m(B-1&a-1)", "a merge's order among versions alike but for their ids, through rank.less: " .. tostring(m))
  rank.less = real
  package.loaded.judge = nil
  J = require("judge")
  assert(J.newer(a, b) == true, "with byte order, 'a' is the later name")
  assert(J.merge_order({ { id = "B-1", rev = 1, order = "1800000000000|z" }, { id = "a-1", rev = 1, order = "1800000000000|z" } }) == "m(a-1&B-1)", "and the merge's order is byte order (B-1 the older, a-1 winning over it)")
  print("rt-sync2e bytes 2: the judge's ties go through rank.less")
end

print("ok rt-sync2e: orders that decide anything are byte order")
