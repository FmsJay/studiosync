-- 0.59.37: three or more versions of an item made apart merge the same way whatever order they arrived in (mirror.merge_order).
package.path = "lib/?.lua;" .. package.path
local mirror = require("mirror")
local A = { id = "Al-20261118-100000Z-00001-1111", rev = 2, order = "1000|Al" }
local B = { id = "Bo-20261118-100001Z-00001-2222", rev = 2, order = "1001|Bo" }
local C = { id = "Cy-20261118-100002Z-00001-3333", rev = 2, order = "1002|Cy" }
local want = mirror.merge_order({ A, B, C })
assert(want == mirror.merge_id(C.id, mirror.merge_id(B.id, A.id)), "oldest first, each newer one winning: " .. want)
for _, perm in ipairs({ { A, C, B }, { B, A, C }, { B, C, A }, { C, A, B }, { C, B, A } }) do
  assert(mirror.merge_order(perm) == want, "the same merge whatever the order")
end
assert(mirror.merge_order({ B, A }) == mirror.merge_id(B.id, A.id), "two: the newer wins, as before")
local hi = { id = "Al-20261118-090000Z-00009-9999", rev = 5, order = "900|Al" }
assert(mirror.merge_order({ hi, C }) == mirror.merge_id(hi.id, C.id), "a higher revision wins over a later clock, as mirror.newer says")
local w, l = mirror.split_merge(want)
assert(w == C.id and mirror.split_merge(l) == B.id, "and it splits back the way it was built")
print("ok")
