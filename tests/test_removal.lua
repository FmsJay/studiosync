-- lib/removal.lua's pure half
package.path = "lib/?.lua;" .. package.path
reaper = reaper or { GetResourcePath = function() return "res" end }
local removal = require("removal")
assert(not removal.due({ at = 1000 }, 1000 + removal.GRACE - 1), "a minute to change your mind")
assert(removal.due({ at = 1000 }, 1000 + removal.GRACE), "then it happens")
local dev = { Sam = "A", Kim = "NEW" }
local of = function(u) return dev[u] end
local out = removal.out({ { user = "Sam", device = "A", at = 0 }, { user = "Kim", device = "OLD", at = 0 }, { user = "Pat", device = "P", at = 0 }, { user = "Lee", device = "L", at = 9e9 } }, of, 1000)
assert(out.Sam, "taken out: not listed")
assert(not out.Kim, "a new computer of theirs, let in since, isn't the one the mark names")
assert(out.Pat, "a computer that never said which it was goes by the mark")
assert(not out.Lee, "still in their minute: still listed")
print("ok")

-- a leaver's claims go free on one computer: the first other name, or anyone after an hour (0.58.47)
assert(removal.frees({ "Sam", "Bee", "James" }, "Sam", "Bee", 10), "Bee is first of the rest")
assert(not removal.frees({ "Sam", "Bee", "James" }, "Sam", "James", 10), "James waits for Bee")
assert(removal.frees({ "Sam", "Bee", "James" }, "Sam", "James", 3700), "after an hour, anyone")
assert(removal.frees({ "Sam" }, "Sam", "James", 10), "nobody else listed: whoever looks")
