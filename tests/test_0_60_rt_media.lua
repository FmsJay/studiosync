-- Roadmap step 3, the online half (James, rt): media files over the direct link (lib/streams.lua). The pure parts: which files a change newly
-- names, the stream's name on the link (never a path from a message), the "media" message checked, the place-it decision, what the prune takes;
-- then the sender and the receiver with a stand-in REAPER and extension: sent once and only when fresh, put in place by one rename or a
-- background copy, never over a file that's there, the inbox copy gone after.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end }) -- (the extension's: absent for now)
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
local streams = require("streams")
local direct = require("direct")

-- ---- what a change newly names ----
local st = 'FILE "{media:main}/ab12-Bass.wav"\nFILE "{media}/cd34-Gtr.flac"\nFILE "/Users/x/y.wav"'
local new = streams.media_new(st, nil, { { path = "C:/IR/hall.wav", copy = "plugin files/ef56-hall.wav" } }, nil)
assert(#new == 3, "a new item: all its shared media and plug-in copies (not a path outside the studio)")
assert(new[1].room == nil and new[1].file == "cd34-Gtr.flac" and new[2].file == "plugin files/ef56-hall.wav" and new[3].room == "main" and new[3].file == "ab12-Bass.wav", "{media} is this room's")
new = streams.media_new(st, 'FILE "{media:main}/ab12-Bass.wav"\nFILE "{media}/cd34-Gtr.flac"', { { copy = "plugin files/ef56-hall.wav" } }, { { copy = "plugin files/ef56-hall.wav" } })
assert(#new == 0, "moved or trimmed: nothing it played before goes again")
new = streams.media_new('FILE "{media:main}/print-T1-99.wav"', 'FILE "{media:main}/print-T1-98.wav"')
assert(#new == 1 and new[1].file == "print-T1-99.wav", "a print made again: the new one")
assert(#streams.media_new({ vol = 1 }, nil) == 0 and #streams.media_new(nil, nil, "x") == 0, "a track's state (a table), nothing: none")

-- ---- the name on the link ----
assert(streams.media_name("main", "ab12-Bass.wav") == "~media~main~ab12-Bass.wav", "~media~<room>~<file>")
assert(direct.stream_rel("Cross Test", streams.media_name("main", "ab12-Bass.wav")) == "Cross Test/~media~main~ab12-Bass.wav", "a name the link takes")
assert(streams.media_name("Side B", "plugin files/ef56-hall.wav") == "~media~Side B~plugin files~ef56-hall.wav", "a plug-in copy")
for _, bad in ipairs({ { "main", "../x.wav" }, { "main", "sub/x.wav" }, { "main", "x.rpp" }, { "main", "x.txt" }, { "../main", "x.wav" }, { "a/b", "x.wav" },
    { ".hidden", "x.wav" }, { "main", ".x.wav" }, { "main", "plugin files/../x.wav" }, { "main", string.rep("x", 200) .. ".wav" }, { nil, "x.wav" }, { "main", nil } }) do
  assert(streams.media_name(bad[1], bad[2]) == nil, "refused: " .. tostring(bad[1]) .. " " .. tostring(bad[2]))
end
assert(not streams.media_name("main", "x.wav"):find("^main~"), "never a take stream's <room>~ prefix (streams.prunable would take it)")
assert(#streams.prunable({ "~media~main~x.wav" }, {}, {}, "main") == 0, "the take prune leaves media copies alone")

-- ---- the message ----
local d = { id = "Bo-20261119-120000Z-11234", user = "Bo", room = "main", file = "ab12-Bass.wav", size = 4096 }
local e = streams.valid_media(d, "Song", "James", clock)
assert(e and e.rel == "Song/~media~main~ab12-Bass.wav" and e.size == 4096 and e.key == "Song/main/ab12-Bass.wav", "a good one")
for _, bad in ipairs({ { id = "../x" }, { user = "James" }, { user = "a/b" }, { room = "../x" }, { file = "../../x.wav" }, { file = "x.exe" }, { size = 0 }, { size = -1 },
    { size = 1.5 }, { size = "x" }, { size = 17 * 2 ^ 30 } }) do
  local t = {}
  for k, v in pairs(d) do t[k] = v end
  for k, v in pairs(bad) do t[k] = v end
  assert(streams.valid_media(t, "Song", "James", clock) == nil, "refused: " .. next(bad))
end
assert(streams.valid_media(d, ".hidden", "James", clock) == nil, "a song name the link won't take")

-- ---- place it or not ----
local function ent(t) local x = { size = 100, made = 0, progress_at = 0 }; for k, v in pairs(t) do x[k] = v end; return x end
assert(streams.place_decision(ent({ done = true, ok = true, total = 100 }), nil, 100, 10) == "place", "complete, hash-checked, the size announced, nothing there")
assert(streams.place_decision(ent({ done = true, ok = true, total = 100 }), 100, 100, 10) == "have", "Syncthing's copy is there: left alone")
assert(streams.place_decision(ent({ done = true, ok = true, total = 100 }), 7, 100, 10) == "have", "a different file there: never written over")
assert(streams.place_decision(ent({ done = true, ok = false, total = 100 }), nil, 100, 10) == "wait", "the hash didn't match (the extension asks again)")
assert(streams.place_decision(ent({ done = true, ok = true, total = 90 }), nil, 90, 10) == "wait", "not the size announced")
assert(streams.place_decision(ent({ done = true, ok = true, total = 100 }), nil, 90, 10) == "wait", "the inbox copy isn't all there")
assert(streams.place_decision(ent({}), nil, nil, 10) == "wait" and streams.place_decision(ent({}), nil, nil, streams.DONE_KEEP + 1) == "drop", "nothing for a long time: Syncthing brings it")

-- ---- the prune ----
local book = { ["Song/~media~main~a.wav"] = { rel = "Song/~media~main~a.wav" } }
local names = { "~media~main~a.wav", "~media~main~b.wav", "~media~main~c.wav", "~media~main~d.wav", "~media~main~e.wav.part", "main~Bo~take.wav", "~media~main~f.wav" }
local inn = { ["~media~main~c.wav"] = { done = false, at = 0 }, ["~media~main~d.wav"] = { done = true, at = 990 }, ["~media~main~f.wav"] = { done = true, at = 900 } }
local p = streams.media_prunable(names, book, inn, 1000)
table.sort(p)
assert(#p == 2 and p[1] == "~media~main~b.wav" and p[2] == "~media~main~f.wav", "not an entry's, not arriving, not just finished, not a take's: " .. table.concat(p, ","))

-- ---- the sender, with a stand-in extension ----
local started, ended, msgs, ftime = {}, {}, {}, {}
reaper.StudioSync_DirectFileTime = function(path) return ftime[path] or -1 end
direct.live_available = function() return true end
direct.stream_start = function(cfg, path, song, room, ms, name) started[#started + 1] = { path = path, name = name, room = room }; return direct.stream_rel(song, name) end
direct.stream_end = function(cfg, rel) ended[#ended + 1] = rel; return true end
direct.send_live = function(cfg, kind, dd, song, room, id) msgs[#msgs + 1] = { kind = kind, d = dd, room = room, id = id } end
local real_size = band.size
local sizes = {}
band.size = function(path) return sizes[path] end
local cfg = { user = "James", root = "R" }
local now = os.time()
ftime["R/Song/rooms/side/media/new.wav"], sizes["R/Song/rooms/side/media/new.wav"] = now - 5, 5000
ftime["R/Song/rooms/main/media/old.wav"], sizes["R/Song/rooms/main/media/old.wav"] = now - 4000, 9000
local ev = { state = 'FILE "{media}/new.wav"\nFILE "{media:main}/old.wav"\nFILE "{media}/gone.wav"\nFILE "{media}/x.rpp"' }
assert(streams.offer_media(cfg, "Song", "side", "R/Song/rooms/side/media", ev, nil) == 1, "one went")
assert(#started == 1 and started[1].path == "R/Song/rooms/side/media/new.wav" and started[1].name == "~media~side~new.wav" and started[1].room == "side", "the fresh one, from this room's media")
assert(ended[1] == "Song/~media~side~new.wav", "begun and ended at once: it's complete")
assert(#msgs == 1 and msgs[1].kind == "media" and msgs[1].d.room == "side" and msgs[1].d.file == "new.wav" and msgs[1].d.size == 5000 and msgs[1].d.id == msgs[1].id, "the message says where it belongs")
assert(streams.offer_media(cfg, "Song", "side", "R/Song/rooms/side/media", ev, nil) == 0 and #started == 1, "once per script")
streams.placed["Song/main/fresh.wav"] = true
ftime["R/Song/rooms/main/media/fresh.wav"], sizes["R/Song/rooms/main/media/fresh.wav"] = now, 10
assert(streams.offer_media(cfg, "Song", "side", "R/Song/rooms/side/media", { state = 'FILE "{media:main}/fresh.wav"' }, nil) == 0, "never one put in place from the link")
local was = reaper.StudioSync_DirectFileTime
reaper.StudioSync_DirectFileTime = nil
ftime["R/Song/rooms/side/media/n2.wav"], sizes["R/Song/rooms/side/media/n2.wav"] = now, 10
assert(streams.offer_media(cfg, "Song", "side", "R/Song/rooms/side/media", { state = 'FILE "{media}/n2.wav"' }, nil) == 0, "an extension without file times: Syncthing")
reaper.StudioSync_DirectFileTime = was
do -- a take streamed as it was recorded: only which stream it is goes, not its bytes again
  local mf = { [band.norm("R/Song/rooms/side/media/aa-take.flac"):lower()] = band.norm("C:/Rec/take.flac") }
  local sd = { [band.norm("C:/Rec/take.flac"):lower()] = { file = "take.flac", rel = "Song/side~James~take.flac" } }
  local s = streams.streamed_copy("R/Song/rooms/side/media/aa-take.flac", mf, sd, { { rel = "Song/side~James~take.flac" } })
  assert(s and s.file == "take.flac", "the copy of a streamed take")
  assert(streams.streamed_copy("R/Song/rooms/side/media/aa-take.flac", mf, sd, {}) == nil, "the stream gone: its bytes go as media")
  assert(streams.streamed_copy("R/Song/rooms/side/media/other.flac", mf, sd, { { rel = "Song/side~James~take.flac" } }) == nil, "not a copy of one")
end
direct.stream_start = function() error("boom") end
assert(streams.offer_media(cfg, "Song", "side", "R/Song/rooms/side/media", { state = 'FILE "{media}/n2.wav"' }, nil) == 0, "never raises")

-- ---- the receiver, with a stand-in extension and disk ----
local disk, renamed, copies, removed = {}, {}, {}, {}
band.size = function(path) return disk[path] end
band.subdirs = function(dir) return dir == "R/Song/rooms/main" and { "events" } or {} end
band.files = function() return {} end
band.copy_background = function(from, to) copies[#copies + 1] = { from, to } end
reaper.file_exists = function(path) return disk[path] ~= nil end
local real_rename, real_remove = os.rename, os.remove
local cross_disk = false
os.rename = function(a, z)
  if cross_disk and a:sub(1, 2) == "H/" then return nil end
  if disk[a] == nil or disk[z] ~= nil then return nil end
  disk[z], disk[a] = disk[a], nil
  renamed[#renamed + 1] = { a, z }
  return true
end
os.remove = function(path) removed[#removed + 1] = path; disk[path] = nil; return true end
local instreams = {}
direct.streams = function() return { out = {}, inn = instreams } end
local b = { song = "Song", room = "main" }
assert(streams.on_media(cfg, b, d), "taken")
assert(not streams.on_media(cfg, b, d), "once")
assert(not streams.on_media(cfg, b, { id = "Bo-2", user = "Bo", room = "elsewhere", file = "x.wav", size = 1 }), "a room this computer doesn't have: never")
local en = streams.media["Song/~media~main~ab12-Bass.wav"]
assert(en.inbox == "H/direct/studio1/.streams/Song/~media~main~ab12-Bass.wav" and en.target == "R/Song/rooms/main/media/ab12-Bass.wav", "inbox and target worked out here")
assert(en.tmp == "R/Song/rooms/main/media/.syncthing.ab12-Bass.wav.direct.tmp", "a temp name Syncthing ignores, not its own download's")
clock = clock + 1
instreams[1] = { rel = en.rel, bytes = 2048, total = -1, done = false, ok = false, at = os.time() }
disk[en.inbox] = 2048
assert(streams.media_tick(cfg, b) == 0 and streams.media[en.rel], "still arriving")
clock = clock + 1
instreams[1] = { rel = en.rel, bytes = 4096, total = 4096, done = true, ok = true, at = os.time() }
disk[en.inbox] = 4096
assert(streams.media_tick(cfg, b) == 1, "put in place")
assert(disk[en.target] == 4096 and disk[en.inbox] == nil and #renamed == 1 and not streams.media[en.rel] and streams.placed["Song/main/ab12-Bass.wav"], "one rename, the inbox copy gone")
-- Syncthing got there first: left as it is, the inbox copy goes
d.id, d.file = "Bo-3", "two.wav"
assert(streams.on_media(cfg, b, d))
local e2 = streams.media["Song/~media~main~two.wav"]
disk[e2.target], disk[e2.inbox] = 999, 4096
instreams[1] = { rel = e2.rel, bytes = 4096, total = 4096, done = true, ok = true, at = os.time() }
clock = clock + 1
assert(streams.media_tick(cfg, b) == 0 and disk[e2.target] == 999 and disk[e2.inbox] == nil and not streams.media[e2.rel], "never written over; inbox copy gone")
-- another disk: copied in the background to the temp name, then renamed in
d.id, d.file = "Bo-4", "three.wav"
assert(streams.on_media(cfg, b, d))
local e3 = streams.media["Song/~media~main~three.wav"]
cross_disk, disk[e3.inbox] = true, 4096
instreams[1] = { rel = e3.rel, bytes = 4096, total = 4096, done = true, ok = true, at = os.time() }
clock = clock + 1
assert(streams.media_tick(cfg, b) == 0 and #copies == 1 and copies[1][1] == e3.inbox and copies[1][2] == e3.tmp and e3.copying, "copied in the background")
clock = clock + 1
assert(streams.media_tick(cfg, b) == 0 and streams.media[e3.rel], "not there yet")
disk[e3.tmp] = 4096
clock = clock + 1
assert(streams.media_tick(cfg, b) == 1 and disk[e3.target] == 4096 and disk[e3.tmp] == nil and disk[e3.inbox] == nil, "in place, temp and inbox copy gone")
-- the shared copy of a take that streamed here as it was recorded: copied from the take's stream copy, which stays for the take's own swap
cross_disk, copies = false, {}
d.id, d.file, d.take = "Bo-5", "cc-take.flac", "take.flac"
assert(streams.on_media(cfg, b, d))
d.take = nil
local e4 = streams.media["Song/~media~main~cc-take.flac"]
assert(e4.keep_inbox and e4.src_rel == "Song/main~Bo~take.flac" and e4.inbox == "H/direct/studio1/.streams/Song/main~Bo~take.flac", "the take's stream copy")
disk[e4.inbox] = 4096
instreams[1] = { rel = e4.src_rel, bytes = 4096, total = 4096, done = true, ok = true, at = os.time() }
clock = clock + 1
assert(streams.media_tick(cfg, b) == 0 and #copies == 1 and copies[1][1] == e4.inbox and copies[1][2] == e4.tmp, "copied, never moved")
disk[e4.tmp] = 4096
clock = clock + 1
assert(streams.media_tick(cfg, b) == 1 and disk[e4.target] == 4096 and disk[e4.inbox] == 4096, "in place; the take's copy stays")
-- the prune pass removes leftovers in the song's .streams folder
band.files = function() return { "~media~main~left.wav", "main~Bo~take.wav" } end
removed = {}
clock = clock + streams.PRUNE_EVERY + 1
streams.media_tick(cfg, b)
assert(#removed == 1 and removed[1] == "H/direct/studio1/.streams/Song/~media~main~left.wav", "only the media leftover")
os.rename, os.remove, band.size = real_rename, real_remove, real_size

-- ---- Syncthing's leftover temp download beside a file we placed first ----
do
  local T = "R/Song/rooms/main/media"
  local sizes = { [T .. "/a.wav"] = 100, [T .. "/~syncthing~a.wav.tmp"] = 100, [T .. "/.syncthing.b.wav.tmp"] = 40, [T .. "/b.wav"] = 100,
    [T .. "/~syncthing~c.wav.tmp"] = 100, [T .. "/c.wav"] = 100 }
  local times = { [T .. "/~syncthing~a.wav.tmp"] = 5000 - 90, [T .. "/.syncthing.b.wav.tmp"] = 5000 - 90, [T .. "/~syncthing~c.wav.tmp"] = 5000 - 10 }
  local gone = {}
  local list = { { target = T .. "/a.wav", size = 100, at = 100 }, { target = T .. "/b.wav", size = 100, at = 100 },
    { target = T .. "/c.wav", size = 100, at = 100 }, { target = T .. "/old.wav", size = 100, at = 100 - 1000 } }
  local keep = streams.tidy_syncthing_temps(list, 200, 5000, function(p) return sizes[p] end, function(p) return times[p] or -1 end,
    function(p) gone[#gone + 1] = p end)
  assert(#gone == 1 and gone[1] == T .. "/~syncthing~a.wav.tmp", "only a whole-size temp untouched for a minute: " .. table.concat(gone, ", "))
  assert(#keep == 3, "an entry past TEMP_WATCH is dropped")
end

-- ---- Health's line names a media file plainly ----
local text = streams.health_text({ out = {}, inn = { { rel = "Song/~media~main~ab12-Bass.wav", bytes = 1048576, done = false } } })
assert(text and text:find("in media ab12-Bass.wav: 1.00 MB so far", 1, true), text)
print("ok")
