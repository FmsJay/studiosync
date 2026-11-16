-- people.assign is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
package.loaded.band = package.loaded.band or {}
local people = require("people")
local P = people.PALETTE
local c = people.assign({}, { "Mac", "James", "Laptop" })
assert(c.James == P[1] and c.Laptop == P[2] and c.Mac == P[3], "defaults in name order, so every machine agrees")
c = people.assign({ Laptop = P[1] }, { "Mac", "James", "Laptop" })
assert(c.Laptop == P[1] and c.James == P[2] and c.Mac == P[3], "a picked colour is nobody else's default")
c = people.assign({ Mac = 0x123456 }, { "James", "James" })
assert(c.Mac == 0x123456 and c.James == P[1], "any colour can be picked; a name listed twice gets one")
local many = {}
for i = 1, #P + 2 do many[#many + 1] = "P" .. string.format("%02d", i) end
c = people.assign({}, many)
assert(c.P01 == P[1] and c[many[#P + 1]] ~= nil, "more people than colours: everyone still gets one")
print("ok")

-- what's new: brief while you're here, held for what came while you were away (0.58.79)
assert(people.fade(0) == 1 and people.fade(19) == 1, "full at first")
assert(people.fade(70) > 0.4 and people.fade(70) < 0.6, "half way")
assert(people.fade(120) == 0 and people.fade(90000) == 0, "gone after two minutes")
assert(people.compact("2026-11-16T14:11:05Z") == "20261116-141105Z", "the stamp form")
local last, opened = "20261116-100000Z", "20261116-140000Z"
local s, held = people.strength("20261116-120000Z", 7200, last, opened, "")
assert(s == 1 and held, "came while you were away: full, held")
s, held = people.strength("20261116-120000Z", 7200, last, opened, "20261116-140500Z")
assert(s == 0 and not held, "after OK: back to the studio's colour")
s, held = people.strength("20261116-140010Z", 10, last, opened, "20261116-140500Z")
assert(s == 1 and not held, "a change while you're here: brief")
s, held = people.strength("20261116-090000Z", 20000, last, opened, "")
assert(s == 0 and not held, "older than your last visit: nothing")
s = people.strength("20261116-120000Z", 7200, "", opened, "")
assert(s == 0, "never here before: nothing held")
print("ok")
