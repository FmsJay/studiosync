-- The API's pure half: the state other scripts read, and the event list (lupa or Lua 5.4, from the repo root)
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local api = require("api")
local band = require("band")
local s = api.state_of({ song = "Sunset Drive", room = "main", me = "James", driver = "Bee", mode = "claims", alone = false, others = { "Sam", "Bee" },
  tracks = { ["bass"] = { user = "Sam", name = "Bass" }, ["keys"] = { user = "James", name = "Keys" }, ["gtr"] = { user = "James", name = "Gtr" } },
  hold = true, local_mix = false, held = "3" })
assert(s.api == api.VERSION and s.version == band.VERSION, "says which API and which StudioSync")
assert(s.driver == "Bee" and s.driving == false and s.mode == "claims", "who drives, and that it isn't you")
assert(table.concat(s.here, ",") == "Bee,Sam", "who's here, sorted")
assert(table.concat(s.claims.James, ",") == "Gtr,Keys" and s.claims.Sam[1] == "Bass", "claims by person, by their track names")
assert(s.hold == true and s.local_mix == false and s.held == 3, "hold, local mixing, and how many changes are held")
assert(band.json_decode(band.json_encode(s)).claims.James[2] == "Keys", "and it travels as JSON")
assert(api.state_of({ me = "A", driver = "A" }).driving and api.state_of({}).mode == "claims", "driving yourself; claims when no mode is known")
-- events: numbered, oldest dropped past the limit
local list, seq = {}, nil
for i = 1, 5 do list, seq = api.push(list, seq, { kind = "sent", n = i }, 3, "T" .. i) end
assert(seq == 5 and #list == 3 and list[1].seq == 3 and list[3].n == 5 and list[3].time == "T5", "the newest three, numbered on")
-- every verb is one the panel carries out
local verbs = table.concat(api.VERBS, " ")
for _, v in ipairs({ "hold", "claim", "localmix", "keeplocal", "takecontrol", "chat", "undo", "redo" }) do assert(verbs:find(v, 1, true), v) end
print("ok")
