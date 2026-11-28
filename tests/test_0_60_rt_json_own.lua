-- rt-sync2j task 2.1: StudioSync's own json, whatever another script put in package.loaded first. Scripts/__startup.lua runs other scripts
-- in one Lua before Autostart, and the REAPER Daemon bridge's json (its null is plain nil) was package.loaded.json there: every deletion
-- failed sync.readable, and the desktop's log said "skipped a change from James that StudioSync can't read" for each at every restart
-- (rt-sync2h Recommendation 3: 242 deletions in "LV Checks" at 10:16 on 2026-11-28). Fails with lib/band.lua's plain require("json").
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({}, { __index = function() return function() end end })
-- another script's json, as the bridge's: no null, decode and encode of its own
package.loaded.json = { decode = function() return {} end, encode = function() return "{}" end }
local band = require("band")
assert(band.json.STUDIOSYNC and band.json.null ~= nil, "band.json is StudioSync's own, not the json already loaded")
assert(package.loaded.json.STUDIOSYNC == nil, "and the other script's json is left where it was (the bridge reloads with it)")
local del = band.json_decode('{"type":"obj","obj":"track","oid":"T-1","rev":4,"gone":true,"id":"LinuxBox-20261128-122422Z-00001-6897","items":["I-1"]}')
assert(type(del) == "table" and del.gone == true and del.items[1] == "I-1", "decoded by StudioSync's json")
local sync = require("sync")
assert(sync.readable(del), "a deletion reads (it has no state, and nil isn't JSON's null)")
local nulled = band.json_decode('{"type":"obj","obj":"item","oid":"I-1","rev":2,"state":null}')
assert(nulled.state == band.json.null and not sync.readable(nulled), "a state that is JSON's null still doesn't")
assert(sync.readable({ oid = "I-1", obj = "item", rev = 2, state = "<ITEM\n>" }), "an item with its state reads")
assert(require("signedwrites") and true, "signedwrites loads on band.json")
print("ok")
