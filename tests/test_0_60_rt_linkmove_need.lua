-- Catch-up's list of missing media from a bandmate over the direct link (lib/needlist.lua, docs/rt/rt-linkmove.md), beside Syncthing's own
-- need list (lib/streams.lua catchup_tick, tests/test_0_60_rt_catchup.lua, whose stand-ins these are). Two computers played in turn, Ann's
-- (holds the song's media) and Bee's (back after a while, one file here): off until switched on; Bee asks, Ann lists her settled media,
-- Bee's wants fill and the usual "media_want" goes with no word from Syncthing; an unchanged list isn't sent twice; a bad list is refused.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
local streams = require("streams")
local direct = require("direct")
local services = require("services")
local needlist = require("needlist")
local ANN = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA"
local BEE = "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB"
local EVE = "EEEEEEE-EEEEEEE-EEEEEEE-EEEEEEE-EEEEEEE-EEEEEEE-EEEEEEE-EEEEEEE"

-- each computer's disk: path -> size; mtime: path -> os.time
local disk, mtime = {}, {}
local function put(root, room, file, size, age)
  local p = root .. "/Song/rooms/" .. room .. "/media/" .. file
  disk[p], mtime[p] = size, os.time() - (age or 3600)
end
put("RA", "main", "a.wav", 100); put("RA", "main", "b.wav", 200); put("RA", "side", "c.flac", 50)
put("RA", "main", "tool.exe", 10)            -- (not a file the link takes)
put("RA", "main", "fresh.wav", 999, 5)       -- (written 5 s ago: maybe still being recorded)
put("RB", "main", "a.wav", 100)
band.size = function(p) return disk[p] end
band.subdirs = function(dir)
  if dir == "RA/Song/rooms" or dir == "RB/Song/rooms" then return { "main", "side" } end
  return dir:match("^R[AB]/Song/rooms/[^/]+$") and { "events" } or {}
end
local was_files = band.files
band.files = function(dir, ext)
  local base = dir:match("^(R[AB]/Song/rooms/[^/]+/media)$")
  if not base then return was_files(dir, ext) end
  local out = {}
  for p in pairs(disk) do local f = p:sub(1, #base + 1) == base .. "/" and p:sub(#base + 2); if f and not f:find("/", 1, true) then out[#out + 1] = f end end
  table.sort(out)
  return out
end
reaper.StudioSync_DirectFileTime = function(p) return mtime[p] or -1 end

-- the link: who's here from each computer, and what was sent
local me, here, here_dev, sent, started = BEE, {}, {}, {}, {}
direct.live_available = function() return true end
direct.ensure = function() return true end
direct.peers = function() return here, here_dev end
direct.send_live = function(_, kind, dd, song, room, id, to) sent[#sent + 1] = { kind = kind, d = dd, song = song, room = room, id = id, to = to } end
direct.stream_start = function(_, path, song, _, _, name, to) started[#started + 1] = { path = path, name = name, to = to }; return direct.stream_rel(song, name) end
direct.stream_end = function() return true end
direct.streams = function() return { out = {}, inn = {} } end
services.my_device_id = function() return me end
local need_asks = 0
services.need = function() need_asks = need_asks + 1; return nil end -- (Syncthing has nothing to say yet: not connected, or not asked)
local cfgA, cfgB, b = { user = "Ann", root = "RA" }, { user = "Bee", root = "RB" }, { song = "Song", room = "main" }
local function as(who)
  if who == "Ann" then me, here, here_dev = ANN, { "bee.ts.net:47281" }, { ["bee.ts.net:47281"] = BEE }
  else me, here, here_dev = BEE, { "ann.ts.net:47281" }, { ["ann.ts.net:47281"] = ANN } end
end
local function last() return sent[#sent] end

-- ---- off until switched on ----
as("Bee")
assert(needlist.tick(cfgB, b) == 0 and #sent == 0, "off: nothing is asked")
assert(needlist.on_ask(cfgA, b, { user = "Bee", dev = BEE }) == 0 and needlist.on_list(cfgB, b, { dev = ANN, digest = "1|1", part = 1, of = 1, files = {} }) == false, "off: nothing answered or taken")
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfgB, b) == 0, "and catch-up goes by Syncthing's list alone, as before")
gext[band.SECTION .. "\0" .. needlist.EXT] = "1"

-- ---- Bee asks, Ann lists, Bee's wants fill ----
assert(needlist.tick(cfgB, b) == 1 and last().kind == "need_ask" and last().d.dev == BEE and last().d.seen == nil and last().to[1] == "ann.ts.net:47281", "Bee's computer asks the bandmate here")
assert(needlist.tick(cfgB, b) == 0, "once per EVERY while who's here stays the same")
local ask = last().d
as("Ann")
assert(needlist.on_ask(cfgA, b, ask) == 1 and last().kind == "need_list" and last().to[1] == "bee.ts.net:47281", "Ann's computer answers the asker alone")
local list = last().d
assert(list.dev == ANN and list.digest == "3|350" and list.part == 1 and list.of == 1 and #list.files == 3, "her settled media the link takes: " .. #list.files .. " " .. list.digest)
assert(list.files[1][1] == "main" and list.files[1][2] == "a.wav" and list.files[1][3] == 100 and list.files[3][1] == "side" and list.files[3][2] == "c.flac",
  "room, file, size (not the .exe, not the file written 5 s ago)")
assert(needlist.on_ask(cfgA, b, ask) == 0, "not again to the same asker within ANSWER_EVERY")
as("Bee")
list = band.json_decode(band.json_encode(list)) -- (as it comes off the link)
assert(needlist.on_list(cfgB, b, list) == 2, "the two Bee's computer lacks are wanted")
local function here_b(w) return disk["RB/Song/rooms/" .. w.room .. "/media/" .. w.file] ~= nil end
local wants = needlist.pending({}, "Song", here_b)
assert(#wants == 2 and wants[1].file == "c.flac" and wants[1].room == "side" and wants[1].size == 50 and wants[2].file == "b.wav" and wants[2].by == ANN, "smallest first, and who listed them")
local syncthings = { { room = "main", file = "b.wav", size = 200, key = "Song/main/b.wav" } }
assert(#needlist.pending(syncthings, "Song", here_b) == 2 and #syncthings == 1, "one Syncthing names too is wanted once; its list isn't changed")
assert(needlist.pending(syncthings, "Other", here_b) == syncthings, "another song's catch-up: Syncthing's list as it is")

-- the usual catch-up asks for them, with no word from Syncthing
clock = clock + streams.CATCHUP_LOOK
local before = #sent
assert(streams.catchup_tick(cfgB, b) == 2 and need_asks >= 1, "catch-up asks for both, though Syncthing has said nothing")
local w1, w2 = sent[before + 1], sent[before + 2]
assert(w1.kind == "media_want" and w1.d.file == "c.flac" and w1.d.room == "side" and w1.d.size == 50 and w1.d.dev == BEE and w1.to[1] == "ann.ts.net:47281", "the same media_want as ever, to the one who listed it")
assert(w2.d.file == "b.wav" and w2.d.size == 200, "and the other")
as("Ann")
assert(streams.on_media_want(cfgA, b, w2.d) and started[1].path == "RA/Song/rooms/main/media/b.wav" and started[1].to[1] == "bee.ts.net:47281", "Ann's computer streams it back, by its own checks")
as("Bee")
put("RB", "main", "b.wav", 200) -- (it landed and was put in place: streams.media_tick)
wants = needlist.pending({}, "Song", here_b)
assert(#wants == 1 and wants[1].file == "c.flac", "what's here now is no longer wanted")

-- ---- an unchanged list isn't sent again; a changed one is ----
clock = clock + needlist.EVERY
assert(needlist.tick(cfgB, b) == 1 and last().d.seen == "3|350", "the next ask says which list Bee's computer has been through")
ask = last().d
as("Ann")
before = #sent
assert(needlist.on_ask(cfgA, b, ask) == 0 and #sent == before, "nothing new on Ann's computer: no answer")
put("RA", "main", "d.wav", 70)
clock = clock + needlist.ANSWER_EVERY
assert(needlist.on_ask(cfgA, b, ask) == 1 and last().d.digest == "4|420", "a new file there: the list goes again")
-- a long list goes in parts, and counts as seen only once every part came
local was_per = needlist.PER_MSG
needlist.PER_MSG = 3
clock = clock + needlist.ANSWER_EVERY
before = #sent
assert(needlist.on_ask(cfgA, b, ask) == 2 and #sent == before + 2 and #sent[before + 1].d.files == 3 and #sent[before + 2].d.files == 1 and sent[before + 2].d.of == 2, "four files, three a message: two parts")
as("Bee")
assert(needlist.on_list(cfgB, b, sent[before + 2].d) == 0, "the second part alone (c.flac, wanted already)")
clock = clock + needlist.EVERY
needlist.tick(cfgB, b)
assert(last().d.seen == "3|350", "not seen whole yet: the older list is still the one named")
assert(needlist.on_list(cfgB, b, sent[before + 1].d) == 1, "the first part: d.wav wanted")
clock = clock + needlist.EVERY
needlist.tick(cfgB, b)
assert(last().d.seen == "4|420", "both parts in: seen")
needlist.PER_MSG = was_per

-- ---- refused ----
local good = { dev = ANN, digest = "1|5", part = 1, of = 1, files = { { "main", "x.wav", 5 } } }
local function with(t) local c = {}; for k, v in pairs(good) do c[k] = v end; for k, v in pairs(t) do c[k] = v end; return c end
assert(needlist.on_list(cfgB, b, with({ dev = EVE })) == false, "a list from a computer that isn't here on the link")
assert(needlist.on_list(cfgB, b, with({ dev = BEE })) == false, "or this computer's own")
assert(needlist.on_list(cfgB, b, with({ digest = "x" })) == false and needlist.on_list(cfgB, b, with({ part = 3, of = 2 })) == false and needlist.on_list(cfgB, b, with({ of = 1000 })) == false, "a digest or part that isn't one")
local many = {}
for i = 1, needlist.PER_MSG + 1 do many[i] = { "main", "m" .. i .. ".wav", 5 } end
assert(needlist.on_list(cfgB, b, with({ files = many })) == false, "more files than a message holds")
assert(needlist.on_list(cfgB, b, with({ files = { { "main", "../x.wav", 5 }, { "main", "sub/y.wav", 5 }, { "main", "tool.exe", 5 }, { "main", "z.wav", 0 }, { "main", "z.wav", 1.5 },
  { "..", "z.wav", 5 }, { "main", "a.wav", 100 }, "junk", { "main" } } })) == 0, "names the link won't take, sizes that aren't, a file already here: none wanted")
as("Ann")
assert(needlist.on_ask(cfgA, b, { user = "Eve", dev = EVE }) == 0 and needlist.on_ask(cfgA, b, { user = "Ann", dev = ANN }) == 0 and needlist.on_ask(cfgA, b, "junk") == 0, "an ask from a computer that isn't here, or this one: no answer")

-- ---- a file deleted here isn't fetched back from a bandmate who still holds it ----
as("Bee")
put("RB", "main", "old.wav", 30)
clock = clock + needlist.EVERY
needlist.tick(cfgB, b) -- (each ask looks at what's here: old.wav is)
disk["RB/Song/rooms/main/media/old.wav"] = nil -- (deleted, here or by Syncthing carrying someone's delete)
assert(needlist.on_list(cfgB, b, with({ files = { { "main", "old.wav", 30 }, { "main", "new.wav", 31 } } })) == 1, "Ann's computer still lists it: only the one never held here is wanted")
assert(needlist.wants["Song/main/old.wav"] == nil and needlist.wants["Song/main/new.wav"] ~= nil, "the deleted one stays deleted")

-- ---- wants don't wait for ever ----
as("Bee")
clock = clock + needlist.KEEP + 1
assert(#needlist.pending({}, "Song", here_b) == 0, "a want never fetched in an hour goes (Syncthing brings it as ever)")
needlist.tick(cfgB, b)
assert(last().kind == "need_ask" and last().d.seen == nil, "and that list is asked for again")

print("ok link need list")
