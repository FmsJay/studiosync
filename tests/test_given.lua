-- sync.authority: a claim an admin gave counts only from someone who may give it, written by their own computer (lib/trust.lua claim_ok,
-- 0.58.78) (lupa or Lua 5.4, from the repo root)
local claims = {
  ["claims/given-Kim-20261116-010000.json"] = { user = "Kim", by = "Bee", time = "2026-11-16T01:00:00Z", tracks = { "Bass" }, given = true },
  ["claims/given-Kim-20261116-020000.json"] = { user = "Kim", by = "Bee", time = "2026-11-16T02:00:00Z", tracks = { "Keys" }, given = true },
}
package.loaded.band = {
  files = function(dir) if not dir:match("claims$") then return {} end local t = {}; for k in pairs(claims) do t[#t + 1] = k:match("[^/]+$") end; table.sort(t); return t end,
  read_json = function(path) for k, v in pairs(claims) do if path:sub(-#k) == k then return v end end end,
  song_dir = function(_, song) return "root/" .. song end,
}
local asked = {}
package.loaded.groups = { may_manage = function(_, who) return who == "Bee" end }
-- Bee's computer wrote the first; someone else wrote the second, saying Bee gave it
package.loaded.trust = { claim_ok = function(root, rel, c) asked[#asked + 1] = root .. " " .. rel; return rel:find("010000", 1, true) ~= nil end }
package.path = "lib/?.lua;" .. package.path
local sync = require("sync")
local can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", { host = "James" })
assert(who.tracks.bass and who.tracks.bass.user == "Kim", "given from Bee's computer: Kim's")
assert(not who.tracks.keys and can("James", "Keys", 0), "given in Bee's name from another computer: nobody's")
assert(asked[1] == "root Saltmarsh/rooms/main/claims/given-Kim-20261116-010000.json", "asked by its path in the studio: " .. tostring(asked[1]))
claims["claims/given-Kim-20261116-010000.json"].by = "Mal"
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", { host = "James" })
assert(not who.tracks.bass, "from someone who may not give one: nobody's, as before")
-- whose a given claim is: the name's start and the person the file says (a name that starts with yours and a hyphen isn't you)
local lap = { user = "James-Laptop", by = "James", tracks = { "Drums" }, given = true }
assert(sync.given_for("given-James-Laptop-20261121-041500.json", lap, "James-Laptop"), "for James-Laptop: theirs")
assert(not sync.given_for("given-James-Laptop-20261121-041500.json", lap, "James"), "for James-Laptop: not James's, though the name starts the same")
assert(sync.given_for("given-James-20261121-041500.json", { user = "James", by = "Bee" }, "James"), "for James: James's")
assert(not sync.given_for("given-James-20261121-041500.json", { user = "Kim", by = "Bee" }, "James"), "a name for James that says Kim: nobody folds it")
assert(not sync.given_for("given-James-20261121-041500.json", nil, "James"), "unreadable: not folded")
print("ok")
