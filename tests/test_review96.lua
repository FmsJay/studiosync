-- 0.58.96's fixes from the full review (lupa or Lua 5.4, from the repo root): deleting your copy keeps a song's inbox, a guest let in
-- again loses their guest mark, and a listener is seen from any script.
package.path = "lib/?.lua;" .. package.path
local ext = {}
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  time_precise = function() return 0 end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
}, { __index = function() return function() end end })

-- the local copy: what's deleted leaves the song's listing, the inbox included (Syncthing would take a dropped-in recording off everyone)
local tree = { ["S"] = { files = { "session.json", "song.rpp" }, dirs = { "inbox", "mixes", "rooms" } }, ["S/inbox"] = { files = { "take.wav" }, dirs = {} },
  ["S/mixes"] = { files = { "mix.flac" }, dirs = {} }, ["S/rooms"] = { files = {}, dirs = {} } }
package.loaded.band = { files = function(d) return (tree[d] or {}).files or {} end, subdirs = function(d) return (tree[d] or {}).dirs or {} end,
  read_json = function() return nil end }
local copy = require("localcopy")
local files = copy.contents("S")
local has = {}
for _, f in ipairs(files) do has[f] = true end
assert(has["mixes/mix.flac"] and has["song.rpp"], "the song's own files go")
assert(not has["inbox/take.wav"] and not has["session.json"], "the inbox and the listing stay: " .. table.concat(files, ", "))

-- a guest let in again as a member: their mark (named by their computer) goes too
local marks, removed = { ["guest ABCDEFG.json"] = { user = "Sam", device = "ABCDEFG-XXXX", guest = true }, ["Kim.json"] = { user = "Kim", device = "KKKKKKK-YYYY" } }, {}
package.loaded.band = { files = function() local t = {}; for f in pairs(marks) do t[#t + 1] = f end; return t end,
  read_json = function(p) return marks[p:match("[^/]+$")] end, remove = function(p) removed[#removed + 1] = p:match("[^/]+$"); marks[p:match("[^/]+$")] = nil end }
package.loaded.removal = nil
local removal = require("removal")
removal.let_in("R", "ABCDEFG-XXXX")
assert(#removed == 1 and removed[1] == "guest ABCDEFG.json" and marks["Kim.json"], "the guest's mark goes, nobody else's: " .. table.concat(removed, ", "))

-- someone listening: seen from the panel's own Lua as well as Live sync's
package.loaded.band = { SECTION = "BandSync" }
package.loaded.hear = nil
local hear = require("hear")
local P = {}
assert(not hear.has_listeners(P), "nobody yet")
ext["listeners " .. tostring(P)] = "1"
assert(hear.has_listeners(P), "Live sync said someone listens: Solo off in the panel leaves SonoBus on")
print("ok")
