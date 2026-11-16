-- lib/trust.lua's pure half: whose changes to roles, removals and closing are believed (0.58.69)
reaper = setmetatable({ GetOS = function() return "Win64" end }, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local trust = require("trust")
local services = require("services")

local owner, admins = trust.roles_of({ owner = "James", admins = { "Sam", "Bee", 3 } })
assert(owner == "James" and table.concat(admins, ",") == "Bee,Sam", "the roles, comparable: names only, sorted")
local devs = { James = "2MOGZMD-AAAAAAA", Bee = "BEEBEEB-BBBBBBB", Kim = "KIMKIMK-CCCCCCC" }
local pins = trust.repin(nil, "James", { "Bee" }, function(u) return devs[u] end)
assert(pins.devices.James[1] == devs.James and pins.devices.Bee[1] == devs.Bee and not pins.devices.Kim, "pinned: the computers of whoever's in charge")
assert(trust.same(pins, "James", { "Bee" }) and not trust.same(pins, "Kim", { "Bee" }), "a change of owner is a change")

assert(trust.from_manager(pins, "2MOGZMD", "KIMKIMK-CCCCCCC"), "from the owner's computer: believed")
assert(trust.from_manager(pins, "BEEBEEB", nil), "from an admin's: believed")
assert(not trust.from_manager(pins, "KIMKIMK", "2MOGZMD-AAAAAAA"), "from a member's: set aside")
assert(trust.from_manager(pins, "KIMKIMK", "KIMKIMK-CCCCCCC"), "your own computer's change: its panel checked first")
assert(not trust.from_manager(pins, nil, "x") and not trust.from_manager(pins, "", "x"), "Syncthing said nothing: not believed")

-- Kim made an admin by James: Kim's computer pinned from then on; someone pinned keeps theirs even if their devices file says otherwise now
devs.James = "EVILEVI-DDDDDDD"
local p2 = trust.repin(pins, "James", { "Bee", "Kim" }, function(u) return devs[u] end)
assert(p2.devices.Kim[1] == "KIMKIMK-CCCCCCC" and p2.devices.James[1] == "2MOGZMD-AAAAAAA", "new admin pinned; a rewritten devices file moves nobody")
assert(not trust.from_manager(p2, "EVILEVI", nil), "and the computer it names now isn't believed")
-- Bee no longer an admin: their computer isn't a manager's any more
local p3 = trust.repin(p2, "James", { "Kim" }, function(u) return devs[u] end)
assert(not trust.from_manager(p3, "BEEBEEB", nil), "an admin no longer: not believed")

-- what Syncthing's cli debug file prints: the global record's modifiedBy, not the local one
local out = '0\n{ "availability": [], "global": { "deleted": false, "modifiedBy": "2MOGZMD", "platform": { "Darwin": null }, "version": [ "2MOGZMD:1" ] },\n "local": { "modifiedBy": "KIMKIMK" } }'
assert(services.parse_modified_by(out) == "2MOGZMD", "global modifiedBy")
assert(services.parse_modified_by("1\nfolder not found") == nil and services.parse_modified_by(nil) == nil, "no answer: nil")
assert(services.parse_modified_by('0\n{ "global": { "modifiedBy": "", "version": [] } }') == "", "a folder or file Syncthing doesn't hold: empty (believed as before)")
-- (0.58.76) the REST database API's answers: a file it doesn't hold, a folder it doesn't have; a refusal is no answer
assert(services.parse_modified_by("no such object in the index\n") == "" and services.parse_modified_by("no such folder\n") == "", "REST: not held")
assert(services.parse_modified_by("Debugging disabled") == nil, "a refusal: no answer, asked again later")
print("ok")
