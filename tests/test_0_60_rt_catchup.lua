-- Roadmap step 3, the second half, the light way (James, rt): catch-up over the link. Syncthing's need list read into the media the link takes,
-- which wants are due (here already, on their way, asked lately, a few at a time), which peer is asked, the "media_want" checked, what the
-- side that has the file agrees to send; then both sides with a stand-in REAPER, extension and Syncthing.
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
local ME = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA"
local BO = "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB"
local CY = "CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC"
assert(services.is_device_id(ME) and services.is_device_id(BO), "stand-in device ids look real")

-- ---- Syncthing's need list -> the media the link takes ----
local need = {
  progress = { { name = "Song\\rooms\\main\\media\\big.wav", size = 9000, modifiedBy = "BBBBBBB" } }, -- (Windows' separators)
  queued = { { name = "Song/rooms/main/media/plugin files/ir.wav", size = 300 } },
  rest = {
    { name = "Song/rooms/side/media/small.flac", size = 100, modifiedBy = "CCCCCCC" },
    { name = "Song/rooms/main/media/gone.wav", size = 50, deleted = true },
    { name = "Song/rooms/main/media/notes.txt", size = 10 },
    { name = "Song/rooms/main/events/e1.json", size = 10 },
    { name = "Song/rooms/main/media/sub/x.wav", size = 10 },
    { name = "Song/rooms/main/media/empty.wav", size = 0 },
    { name = "Other/rooms/main/media/o.wav", size = 10 },
    { name = "Song/song.rpp", size = 10 },
    { name = "Song/rooms/main/media/big.wav", size = 9000 }, -- (the same file twice: once)
    "junk", { size = 5 },
  },
}
local wants = streams.catchup_wants(need, "Song")
assert(#wants == 3, "only this song's audio in a room's media (and plugin files/): " .. #wants)
assert(wants[1].key == "Song/side/small.flac" and wants[1].room == "side" and wants[1].size == 100 and wants[1].by == "CCCCCCC", "smallest first, who changed it")
assert(wants[2].file == "plugin files/ir.wav" and wants[2].room == "main" and wants[2].by == nil, "a plug-in's file copy")
assert(wants[3].file == "big.wav" and wants[3].by == "BBBBBBB", "backslashes read as folders")
assert(#streams.catchup_wants(nil, "Song") == 0 and #streams.catchup_wants({ rest = "x" }, "Song") == 0, "no answer, a bad one: nothing")
assert(#streams.catchup_wants(band.json_decode('{"progress":[],"queued":[],"rest":[{"name":"Song/rooms/main/media/a.wav","size":7}],"page":1,"perpage":65536}'), "Song") == 1,
  "Syncthing's JSON as it comes")

-- ---- which are due ----
local asked, book = {}, {}
local function none() return false end
local due = streams.catchup_due(wants, asked, none, book, "Song", clock)
assert(#due == 3, "all three, nothing asked yet")
asked["Song/side/small.flac"] = { at = clock - 10, tries = 1 }
book["Song/~media~main~plugin files~ir.wav"] = { rel = "x" }
due = streams.catchup_due(wants, asked, function(w) return w.file == "big.wav" end, book, "Song", clock)
assert(#due == 0, "asked lately, on its way, here already: none")
due = streams.catchup_due(wants, asked, none, {}, "Song", clock + streams.WANT_EVERY)
assert(#due == 3, "asked again after WANT_EVERY")
local many = {}
for i = 1, 10 do many[i] = { room = "main", file = "f" .. i .. ".wav", size = i, key = "Song/main/f" .. i .. ".wav" } end
assert(#streams.catchup_due(many, {}, none, {}, "Song", clock) == streams.CATCHUP_BATCH, "a few at a time")

-- ---- which peer ----
local peers, dev_of = { "mac.ts.net:47281", "desk.ts.net:47281" }, { ["mac.ts.net:47281"] = CY, ["desk.ts.net:47281"] = BO }
assert(streams.catchup_peer(peers, dev_of, "BBBBBBB", 0) == "desk.ts.net:47281", "the one that changed it last, first")
assert(streams.catchup_peer(peers, dev_of, "ZZZZZZZ", 0) == "desk.ts.net:47281", "nobody here changed it: the first in order")
assert(streams.catchup_peer(peers, dev_of, "BBBBBBB", 1) == "mac.ts.net:47281" and streams.catchup_peer(peers, dev_of, nil, 2) == "desk.ts.net:47281", "then in turn")
assert(streams.catchup_peer({}, {}, "BBBBBBB", 0) == nil, "nobody here: nobody")

-- ---- the ask checked ----
local d = { id = "Bo-20261119-120000Z-11234", user = "Bo", dev = BO, room = "main", file = "big.wav", size = 9000 }
local w = streams.valid_want(d, "Song", ME)
assert(w and w.name == "~media~main~big.wav" and w.key == "Song/main/big.wav" and w.dev == BO, "a good one")
for _, bad in ipairs({ { id = "../x" }, { dev = ME }, { dev = "not-a-device" }, { user = "a/b" }, { room = "../x" }, { file = "../../x.wav" },
    { file = "x.exe" }, { file = "sub/x.wav" }, { size = 0 }, { size = 1.5 }, { size = "x" } }) do
  local t = {}
  for k, v in pairs(d) do t[k] = v end
  for k, v in pairs(bad) do t[k] = v end
  assert(streams.valid_want(t, "Song", ME) == nil, "refused: " .. next(bad))
end
assert(streams.valid_want(d, ".hidden", ME) == nil, "a song name the link won't take")

-- ---- what the side that has it agrees to send ----
local served = {}
assert(streams.serve_decision(w, 9000, served, 0, clock) == true, "the same size here, not sent lately, not busy")
assert(select(2, streams.serve_decision(w, nil, served, 0, clock)) == "not this version here", "not here")
assert(select(2, streams.serve_decision(w, 8000, served, 0, clock)) == "not this version here", "another version here")
assert(select(2, streams.serve_decision(w, 9000, served, streams.SERVE_MAX, clock)) == "busy", "a few at a time")
served[BO .. "\0" .. w.key] = clock - 60
assert(select(2, streams.serve_decision(w, 9000, served, 0, clock)) == "sent to it lately", "once per asker per SERVE_EVERY")
assert(streams.serve_decision(w, 9000, served, 0, clock - 60 + streams.SERVE_EVERY) == true, "and again after")
local wc = streams.valid_want({ id = "Cy-1", user = "Cy", dev = CY, room = "main", file = "big.wav", size = 9000 }, "Song", ME)
assert(streams.serve_decision(wc, 9000, served, 0, clock) == true, "another asker: its own limit")

-- ---- both sides, with stand-ins ----
local cfg, b = { user = "James", root = "R" }, { song = "Song", room = "main" }
local sent, started, ended, disk, outs = {}, {}, {}, {}, {}
local need_text, need_asks = nil, 0
direct.live_available = function() return true end
direct.ensure = function() return true end
local here, here_dev = {}, {}
direct.peers = function() return here, here_dev end
direct.send_live = function(_, kind, dd, song, room, id, to) sent[#sent + 1] = { kind = kind, d = dd, song = song, room = room, id = id, to = to } end
direct.stream_start = function(_, path, song, room, ms, name, to) started[#started + 1] = { path = path, name = name, to = to }; return direct.stream_rel(song, name) end
direct.stream_end = function(_, rel) ended[#ended + 1] = rel; return true end
direct.streams = function() return { out = outs, inn = {} } end
services.my_device_id = function() return ME end
services.need = function(folder, every) need_asks = need_asks + 1; assert(folder == "studio1" and every == streams.CATCHUP_EVERY); return need_text end
band.size = function(p) return disk[p] end
band.subdirs = function(dir) return (dir == "R/Song/rooms/main" or dir == "R/Song/rooms/side") and { "events" } or {} end

-- the asker
assert(streams.catchup_tick(cfg, b) == 0 and need_asks == 0, "nobody here: Syncthing isn't even asked")
here, here_dev = { "desk.ts.net:47281" }, { ["desk.ts.net:47281"] = BO }
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfg, b) == 0 and need_asks == 1, "no answer yet: nothing asked for")
clock = clock + 1
assert(streams.catchup_tick(cfg, b) == 0 and need_asks == 1, "looks at most every CATCHUP_LOOK")
need_text = band.json_encode({ rest = { { name = "Song/rooms/main/media/big.wav", size = 9000, modifiedBy = "BBBBBBB" },
  { name = "Song/rooms/main/media/have.wav", size = 5 }, { name = "Song/rooms/nope/media/n.wav", size = 5 } } })
disk["R/Song/rooms/main/media/have.wav"] = 5
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfg, b) == 1, "the one it hasn't got, in a room it has")
local m = sent[1]
assert(m.kind == "media_want" and m.d.dev == ME and m.d.user == "James" and m.d.room == "main" and m.d.file == "big.wav" and m.d.size == 9000 and m.id == m.d.id, "the ask")
assert(m.song == "Song" and m.room == "main" and #m.to == 1 and m.to[1] == "desk.ts.net:47281", "to one peer alone")
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfg, b) == 0, "not again within WANT_EVERY")
local was_ensure = direct.ensure
direct.ensure = function() return false end
clock = clock + streams.WANT_EVERY
assert(streams.catchup_tick(cfg, b) == 0, "the studio's direct setting off: nothing")
direct.ensure = was_ensure
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfg, b) == 1 and sent[2].d.file == "big.wav", "asked again after WANT_EVERY")

-- the side that has it (this computer, asked by Bo's)
sent = {}
disk["R/Song/rooms/main/media/big.wav"] = 9000
assert(streams.on_media_want(cfg, b, d), "sent")
assert(#started == 1 and started[1].path == "R/Song/rooms/main/media/big.wav" and started[1].name == "~media~main~big.wav" and started[1].to[1] == "desk.ts.net:47281", "streamed to the asker alone")
assert(ended[1] == "Song/~media~main~big.wav", "begun and ended at once")
assert(#sent == 1 and sent[1].kind == "media" and sent[1].d.file == "big.wav" and sent[1].d.size == 9000 and sent[1].d.room == "main" and sent[1].to[1] == "desk.ts.net:47281", "the usual media message, to it alone")
local e = streams.valid_media(sent[1].d, "Song", "Bo", clock)
assert(e and e.rel == "Song/~media~main~big.wav", "the asker's receiver takes it as any media message")
d.id = "Bo-2"
assert(not streams.on_media_want(cfg, b, d) and #started == 1, "not twice to the same asker within SERVE_EVERY")
local dc = { id = "Cy-1", user = "Cy", dev = CY, room = "main", file = "big.wav", size = 9000 }
assert(not streams.on_media_want(cfg, b, dc), "an asker the link doesn't know here: never")
here[2], here_dev["mac.ts.net:47281"] = "mac.ts.net:47281", CY
outs[1], outs[2], outs[3] = { rel = "Song/~media~main~a.wav", finished = false }, { rel = "Song/~media~main~b.wav", finished = false }, { rel = "Song/~media~main~c.wav", finished = false }
assert(not streams.on_media_want(cfg, b, dc), "busy: a few at a time")
outs[3].finished = true
assert(streams.on_media_want(cfg, b, dc) and started[2].to[1] == "mac.ts.net:47281", "room again: the other asker, to it alone")
dc.id, dc.file = "Cy-2", "other.wav"
assert(not streams.on_media_want(cfg, b, dc), "a file not here")
dc.id, dc.file, dc.size = "Cy-3", "big.wav", 1234
assert(not streams.on_media_want(cfg, b, dc), "another version here: Syncthing sorts it out")

-- ---- nobody on the link, but a cloud copy: Live sync's cloud pass is asked for (James, rt) ----
here, here_dev = {}, {}
need_text = band.json_encode({ rest = { { name = "Song/rooms/main/media/cloudonly.wav", size = 77 }, { name = "Song/rooms/main/media/nowhere.wav", size = 5 } } })
local asks_before, sent_before = need_asks, #sent
clock = clock + streams.CLOUD_EVERY
streams.cloud_root, streams.cloud_due = nil, nil
assert(streams.catchup_tick(cfg, b) == 0 and need_asks == asks_before, "no peer, no cloud copy: Syncthing isn't even asked")
streams.cloud_root = "C"
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfg, b) == 0 and not streams.cloud_due, "the cloud copy hasn't got them: no pass for nothing")
disk["C/Song/rooms/main/media/cloudonly.wav"] = 77
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfg, b) == 0 and streams.cloud_due == true and #sent == sent_before, "it's in the cloud copy: a cloud pass, nothing on the link")
streams.cloud_due = nil
clock = clock + streams.CATCHUP_LOOK
assert(streams.catchup_tick(cfg, b) == 0 and not streams.cloud_due, "asked at most every CLOUD_EVERY")
streams.cloud_root = nil
print("ok")
