-- Record several at once (James, 2026-11-19; docs/realtime-roadmap.md step 4): guitar and voice together, several MIDI instruments together,
-- audio and MIDI together. With a stand-in REAPER: which file is whose track (similar names, one name twice, files named by number only, a
-- track that isn't the band's, a synth recording its output), the streams and "take" messages for 3-4 tracks at once and their ends, the
-- placeholders on each track and each gone with its own real take; live MIDI for several tracks (each its own part, one name twice, one input
-- on several tracks, a track disarmed mid-take, record: none and output left out) and their views; smart take names for audio and MIDI at
-- once; the disk warning counting the tracks.
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

-- ---- 1. which file is whose (pure) ----
local function by(m, key) local t = {}; for _, p in ipairs(m) do t[p.track[key]] = p.file end; return t end
local g = by(streams.match({ { name = "Gtr", num = 1 }, { name = "Gtr 2", num = 2 } }, { "Gtr 2-001.flac" }), "name")
assert(g["Gtr 2"] == "Gtr 2-001.flac" and g.Gtr == nil, "Gtr 2's file alone in a look: Gtr 2's, not Gtr's")
g = by(streams.match({ { name = "Gtr", num = 1 }, { name = "Gtr 2", num = 2 } }, { "Gtr 2-001.flac", "Gtr-001.flac" }), "name")
assert(g.Gtr == "Gtr-001.flac" and g["Gtr 2"] == "Gtr 2-001.flac", "Gtr 2's file sorts first: still its own")
g = by(streams.match({ { name = "Gtr", num = 2 }, { name = "Gtr", num = 3 } }, { "03-Gtr-261119_1730.flac", "02-Gtr-261119_1730.flac" }), "num")
assert(g[2] == "02-Gtr-261119_1730.flac" and g[3] == "03-Gtr-261119_1730.flac", "one name twice: each the file with its number")
local m = streams.match({ { name = "Vox", num = 1 }, { name = "Vox", num = 2 } }, { "Vox-001.flac", "Vox-002.flac" })
assert(m[1].track.num == 1 and m[1].file == "Vox-001.flac" and m[2].file == "Vox-002.flac", "one name twice, no numbers: the top track the first file")
g = by(streams.match({ { name = "Gtr", num = 1 }, { name = "Vox", num = 2 }, { name = "Keys", num = 3 } }, { "3.flac", "1.flac", "2.flac" }), "num")
assert(g[1] == "1.flac" and g[2] == "2.flac" and g[3] == "3.flac", "files named by the track number only")
g = by(streams.match({ { name = "Wav", num = 1 }, { name = "Track 2", num = 2 } }, { "02-1730.wav", "Wav-1730.wav" }), "num")
assert(g[1] == "Wav-1730.wav" and g[2] == "02-1730.wav", "a track called Wav doesn't take every .wav")
g = by(streams.match({ { name = "Track 1", num = 1 }, { name = "12", num = 2 } }, { "01-251112_1203.flac", "02-251112_1203.flac" }), "num")
assert(g[1] == "01-251112_1203.flac" and g[2] == "02-251112_1203.flac", "a name of digits only isn't found in another file's date")
assert(streams.records_audio(1, 4096 + 33, 1) and streams.records_audio(1, -1, 3) and streams.records_audio(1, 4096, 10), "output to a file: audio, whatever the input")
assert(streams.records_audio(1, 2048, 14) and not streams.records_audio(1, 4096, 0) and not streams.records_audio(1, 0, 2) and not streams.records_audio(1, 0, 7), "forced multichannel input; not MIDI in, none, overdub")
assert(streams.records_midi(1, 4096 + 33, 0) and streams.records_midi(1, 4096, 7) and not streams.records_midi(1, 4096, 1) and not streams.records_midi(1, 4096, 2) and not streams.records_midi(1, 0, 0) and not streams.records_midi(0, 4096, 0), "MIDI: a MIDI input, not output or none")
assert(streams.rec_nch(0, 0) == 1 and streams.rec_nch(1024 + 2, 0) == 2 and streams.rec_nch(2048, 0, 6) == 6 and streams.rec_nch(4096, 1) == 2 and streams.rec_nch(0, 10, 8) == 8 and streams.rec_nch(1024, 5) == 1, "channels: mono, stereo, multichannel, by the mode")

-- ---- 2. the recorder: 4 tracks at once, with a stand-in REAPER ----
local function track(name, arm, input, mode, oid, extra)
  local t = { name = name, arm = arm, input = input, mode = mode, oid = oid, nchan = 2, items = {} }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end
local tracks_here = {
  track("Gtr", 1, 0, 0, "T-J-1"),
  track("Gtr 2", 1, 1024 + 2, 0, "T-J-2", { lcl = true }), -- (this computer's own: its file left alone)
  track("Vox", 1, 1024, 0, "T-J-3"),
  track("Synth", 1, 4096 + (63 << 5), 1, "T-J-4"), -- (a MIDI input, recording its sound: audio)
  track("Keys", 1, 4096 + (63 << 5) + 1, 0, "T-J-5"), -- (MIDI: not streamed)
  track("Multi", 1, 2048 + 4, 0, "T-J-6", { nchan = 6 }),
  track("Bass", 0, 0, 0, "T-J-7"), -- (not armed)
}
local rec_dir, made = { "old.flac" }, { ["C:/Rec/old.flac"] = 100 }
local sent, started, ended = {}, {}, {}
local play_pos, cursor = 8.05, 8
for k, v in pairs({
  GetProjectPathEx = function() return "C:/Rec" end,
  CountTracks = function() return #tracks_here end,
  GetTrack = function(_, i) return tracks_here[i + 1] end,
  GetMediaTrackInfo_Value = function(tr, k) return k == "I_RECARM" and tr.arm or k == "I_RECINPUT" and tr.input or k == "I_RECMODE" and tr.mode or k == "I_NCHAN" and tr.nchan or 0 end,
  GetTrackName = function(tr) return true, tr.name end,
  GetPlayPositionEx = function() return play_pos end, GetPlayPosition2Ex = function() return play_pos end,
  GetCursorPositionEx = function() return cursor end,
  GetSetProjectInfo = function() return 0 end,
  GetAudioDeviceInfo = function() return true, "48000" end,
  StudioSync_DirectFileTime = function(p) return made[p] or -1 end,
  StudioSync_DirectMsg = function() return 1 end, StudioSync_DirectClock = function() return "{}" end,
  StudioSync_DirectStream = function() return 1 end, StudioSync_DirectNow = function() return 1.7e9 end,
}) do rawset(reaper, k, v) end
package.loaded.mirror = { local_track = function(tr) return tr.lcl == true end, track_oid = function(tr) return tr.oid or "" end }
local real_files = band.files
band.files = function(dir) if dir == "C:/Rec" then local t = {}; for i, f in ipairs(rec_dir) do t[i] = f end; table.sort(t); return t end; return real_files(dir) end
direct.peers = function() return { "laptop.tail99.ts.net:47281" } end
direct.stream_start = function(_, path, song, room, ms, name) started[#started + 1] = { path = path, name = name }; return direct.stream_rel(song, name) end
direct.stream_end = function(_, rel) ended[#ended + 1] = rel; return true end
direct.send_live = function(_, kind, dd, song, room, id) sent[#sent + 1] = { kind = kind, d = dd, id = id } end
direct.shared_now = function() return 1.7e9 + 3 end
local me, b = { root = "R", user = "James" }, { song = "Song", room = "main" }
local real_time, wall = os.time, 2000
os.time = function(t) if t then return real_time(t) end; return wall end
local function add_file(f, t) rec_dir[#rec_dir + 1] = f; made["C:/Rec/" .. f] = t end
local function takes_sent()
  local t = {}
  for _, s in ipairs(sent) do if s.kind == "take" then t[s.d.track] = s.d end end
  return t
end
-- Record with 5 armed audio tracks: two files are there at the first look, the rest a moment later
add_file("Gtr 2-001.flac", 2000.2); add_file("Vox-001.flac", 2000.2)
streams.send_tick(nil, me, b, true)
assert(#started == 1 and started[1].path == "C:/Rec/Vox-001.flac", "first look: Vox's file streams; Gtr 2's (not the band's) isn't, nor is it taken for Gtr's")
add_file("Gtr-001.flac", 2000.4); add_file("Synth-001.flac", 2000.4); add_file("Multi-001.flac", 2000.4)
clock = clock + 0.2
streams.send_tick(nil, me, b, true)
local tk = takes_sent()
assert(#started == 4, "then the other three: " .. #started)
assert(tk["T-J-1"].file == "Gtr-001.flac" and tk["T-J-3"].file == "Vox-001.flac" and tk["T-J-4"].file == "Synth-001.flac" and tk["T-J-6"].file == "Multi-001.flac", "each track its own file")
assert(tk["T-J-2"] == nil and tk["T-J-5"] == nil and tk["T-J-7"] == nil, "not the local track, the MIDI one or the unarmed one")
assert(tk["T-J-1"].nch == 1 and tk["T-J-3"].nch == 2 and tk["T-J-4"].nch == 2 and tk["T-J-6"].nch == 6, "mono, stereo, stereo output, multichannel (the track's 6)")
assert(tk["T-J-1"].pos == 8 and tk["T-J-6"].pos == 8 and tk["T-J-1"].at == tk["T-J-3"].at, "all start where the recording did, on the same shared clock")
local ids = {}
for _, d in pairs(tk) do assert(not ids[d.id], "an id each"); ids[d.id] = true; assert(streams.valid_take(d, "Song", "main", "Bo", clock), "the others take each") end
tracks_here[3].arm = 0 -- (Vox disarmed mid-take: its stream goes on to the stop, the file is still REAPER's)
clock = clock + 0.2
streams.send_tick(nil, me, b, true)
assert(#started == 4, "nothing more")
clock = clock + 5
streams.send_tick(nil, me, b, false)
clock = clock + 0.6
streams.send_tick(nil, me, b, false)
local ends = 0
for _, s in ipairs(sent) do if s.kind == "take_end" then ends = ends + 1; assert(ids[s.d.id], "a take_end for a take sent") end end
assert(#ended == 4 and ends == 4, "stopped: every stream ended, every take told")
-- The next recording: files named "$tracknumber-..." with a track of digits only and an unnamed one
tracks_here = { track("Track 1", 1, 0, 0, "T-J-11"), track("12", 1, 0, 0, "T-J-12"), track("Bass", 1, 0, 0, "T-J-13") }
wall, sent, started = 2100, {}, {}
add_file("01-251112_1203.flac", 2100); add_file("02-251112_1203.flac", 2100); add_file("03-Bass-251112_1203.flac", 2100)
clock = clock + 1
streams.send_tick(nil, me, b, true)
tk = takes_sent()
assert(#started == 3 and tk["T-J-11"].file == "01-251112_1203.flac" and tk["T-J-12"].file == "02-251112_1203.flac" and tk["T-J-13"].file == "03-Bass-251112_1203.flac", "by number, the digits-only name not matched to a date")
clock = clock + 1; streams.send_tick(nil, me, b, false); clock = clock + 1; streams.send_tick(nil, me, b, false)
os.time = real_time

-- ---- 3. the others: three takes at once, three placeholders, each gone with its own real take ----
local items, guid_n = {}, 0
local removed = {}
os.remove = function(p) removed[p] = true; return true end
local TRS = { ["T-BO-1"] = { name = "Gtr" }, ["T-BO-2"] = { name = "Vox" }, ["T-BO-3"] = { name = "Synth" } }
local tr_list = { TRS["T-BO-1"], TRS["T-BO-2"], TRS["T-BO-3"] }
local function new_item(tr, file, pos, len)
  guid_n = guid_n + 1
  local it = { tr = tr, guid = "{G" .. guid_n .. "}", ext = {}, pos = pos, len = len, mute = 0, vol = 1, takes = {} }
  if file then it.takes[1] = { src = { file = file }, name = "" } end
  items[#items + 1] = it
  return it
end
local function track_items(tr) local t = {}; for _, it in ipairs(items) do if it.tr == tr then t[#t + 1] = it end end; return t end
local inn, exists, src_len = {}, {}, {}
for k, v in pairs({
  CountTracks = function() return #tr_list end, GetTrack = function(_, i) return tr_list[i + 1] end, UpdateArrange = function() end,
  CountTrackMediaItems = function(tr) return #track_items(tr) end,
  GetTrackMediaItem = function(tr, i) return track_items(tr)[i + 1] end,
  GetSetMediaItemInfo_String = function(it, k, v, set)
    if k == "GUID" then return true, it.guid end
    local key = k:match("^P_EXT:(.*)$")
    if set then it.ext[key] = v end
    return true, it.ext[key] or ""
  end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or k == "D_LENGTH" and it.len or k == "B_MUTE" and it.mute or k == "D_VOL" and it.vol or 0 end,
  GetMediaTrackInfo_Value = function() return 0 end,
  SetMediaItemInfo_Value = function(it, k, v) if k == "D_LENGTH" then it.len = v elseif k == "B_MUTE" then it.mute = v elseif k == "D_VOL" then it.vol = v end end,
  GetActiveTake = function(it) return it.takes[1] end,
  CountTakes = function(it) return #it.takes end,
  GetTake = function(it, i) return it.takes[i + 1] end,
  GetMediaItemTake_Source = function(t) return t.src end,
  SetMediaItemTake_Source = function(t, s) t.src = s end,
  PCM_Source_CreateFromFile = function(f) if exists[f] then return { file = f } end end,
  GetMediaSourceLength = function(s) return src_len[s.file] or 0 end,
  GetMediaSourceFileName = function(s) return s.file end,
  PCM_Source_BuildPeaks = function(_, mode) return 0 end,
  GetSetMediaItemTakeInfo_String = function(t, k, v, set) if set then t.name = v end; return true, t.name end,
  DeleteTrackMediaItem = function(_, it) for i, x in ipairs(items) do if x == it then table.remove(items, i) end end end,
  file_exists = function(p) return exists[p] == true end,
  StudioSync_DirectStreams = function() return band.json_encode({ out = {}, ["in"] = inn }) end,
}) do rawset(reaper, k, v) end
band.add_item = function(tr, path, pos, len) if not exists[path] then return nil end; return new_item(tr, path, pos, len) end
band.size = function(p) return p:find("/media/") and 70000 or nil end
package.loaded.mirror = { find = function(_, kind, oid) return kind == "track" and TRS[oid] or nil end }
local cfg = { root = "R", user = "James" }
local function msg(n, oid, name, file) return { id = "Bo-20261119-130000Z-123" .. n, user = "Bo", track = oid, name = name, file = file, pos = 16, at = 1.7e9 } end
local ms = { msg(1, "T-BO-1", "Gtr", "Gtr-001.flac"), msg(2, "T-BO-2", "Vox", "Vox-001.flac"), msg(3, "T-BO-3", "Synth", "Synth-001.flac") }
for k, d in ipairs(ms) do
  assert(streams.on_take(cfg, b, d), "take " .. k)
  local e = streams.book[d.id]
  inn[k] = { studio = "studio1", rel = e.rel, bytes = 60000, total = -1, done = false, ok = false }
  exists[e.path], src_len[e.path] = true, 2
end
clock = clock + 1
streams.receive_tick(nil, cfg, b, false)
assert(#items == 3, "three placeholders: " .. #items)
for k, d in ipairs(ms) do
  local mine = track_items(TRS[d.track])
  assert(#mine == 1 and mine[1].ext.band_stream == d.id and mine[1].pos == 16 and mine[1].takes[1].src.file == streams.book[d.id].path, "each on its own track, playing its own stream")
end
for k in ipairs(ms) do inn[k].done, inn[k].ok, inn[k].total, inn[k].bytes = true, true, 70000, 70000 end
for _, d in ipairs(ms) do streams.on_take_end({ id = d.id }) end
clock = clock + 1
streams.receive_tick(nil, cfg, b, false)
local real_vox = new_item(TRS["T-BO-2"], "R/Song/rooms/main/media/aa11-Vox-001.flac", 16, 2)
exists[real_vox.takes[1].src.file] = true
clock = clock + 1.1
streams.receive_tick(nil, cfg, b, false)
assert(streams.book[ms[2].id] == nil and streams.book[ms[1].id] and streams.book[ms[3].id], "Vox's real take: only Vox's placeholder goes")
assert(#track_items(TRS["T-BO-1"]) == 1 and #track_items(TRS["T-BO-3"]) == 1 and #track_items(TRS["T-BO-2"]) == 1, "the others still show")
for _, x in ipairs({ { "T-BO-1", "bb22-Gtr-001.flac" }, { "T-BO-3", "cc33-Synth-001.flac" } }) do
  local it = new_item(TRS[x[1]], "R/Song/rooms/main/media/" .. x[2], 16, 2)
  exists[it.takes[1].src.file] = true
end
clock = clock + 1.1
streams.receive_tick(nil, cfg, b, false)
assert(next(streams.book) == nil and #items == 3, "every real take in, no placeholder left over")
for _, it in ipairs(items) do assert(it.ext.band_stream == nil, "only the real takes") end
for _, d in ipairs(ms) do assert(removed["H/direct/studio1/.streams/Song/main~Bo~" .. d.file], "each streamed copy went") end

-- ---- 4. live MIDI: several MIDI tracks at once (the recorder) ----
local hist, seq = {}, 0 -- newest first, as MIDI_GetRecentInputEvent gives them
local function play(status, pitch, vel, pos) seq = seq + 1; table.insert(hist, 1, { seq = seq, buf = string.char(status, pitch, vel), dev = 0, pos = pos }) end
tracks_here = {
  track("Keys", 1, 4096 + (63 << 5) + 1, 0, "T-J-21"), -- (all devices, channel 1)
  track("Bass", 1, 4096 + (63 << 5) + 2, 0, "T-J-22"), -- (channel 2)
  track("Synth", 1, 4096 + (63 << 5), 0, "T-J-23"), -- (every channel: the same input as both above)
  track("Synth", 1, 4096 + (63 << 5), 7, "T-J-24"), -- (one name twice; MIDI overdub)
  track("Pad", 1, 4096 + (63 << 5), 1, "T-J-25"), -- (records its sound: streamed as audio, no MIDI view)
  track("Mon", 1, 4096 + (63 << 5), 2, "T-J-26"), -- (record: none)
  track("Vox", 1, 1024, 0, "T-J-27"), -- (audio, alongside)
}
for k, v in pairs({
  CountTracks = function() return #tracks_here end,
  GetTrack = function(_, i) return tracks_here[i + 1] end,
  GetMediaTrackInfo_Value = function(tr, k) return k == "I_RECARM" and tr.arm or k == "I_RECINPUT" and tr.input or k == "I_RECMODE" and tr.mode or 0 end,
  MIDI_GetRecentInputEvent = function(i) local e = hist[i + 1]; if not e then return 0 end; return e.seq, e.buf, 0, e.dev, e.pos end,
}) do rawset(reaper, k, v) end
package.loaded.sync = { room_dir = function() return "R/Song/rooms/main" end, base_name = function(n) return n end }
package.loaded.live = { TRACK_SUFFIX = " (live)", retire = function() end }
local links, written = {}, {}
direct.send_live = function(_, kind, dd) if kind == "midi" then links[#links + 1] = dd end end
direct.reaches_all = function() return true end
band.files = function() return {} end
band.write_json = function(p, c) written[#written + 1] = c end
local lm = require("livemidi")
play(0x91, 1, 1, -1) -- (before the recording: not taken)
lm.send_tick(nil, me, b, true)
play(0x90, 60, 100, 1.0); play(0x91, 40, 90, 1.1); play(0x80, 60, 0, 1.5)
clock = clock + 0.1
lm.send_tick(nil, me, b, true)
local function state()
  local notes = {}
  for _, l in ipairs(links) do for _, n in ipairs(l.c.notes) do notes[n.i] = n end end
  for _, c in ipairs(written) do for _, n in ipairs(c.notes) do notes[n.i] = n end end
  local parts = {}
  for _, n in pairs(notes) do parts[n.t] = parts[n.t] or {}; table.insert(parts[n.t], n) end
  return parts
end
local parts = state()
assert(parts.Keys and #parts.Keys == 1 and parts.Keys[1].p == 60 and parts.Keys[1].e == 1.5, "Keys: channel 1's note, ended")
assert(parts.Bass and #parts.Bass == 1 and parts.Bass[1].p == 40 and parts.Bass[1].e == nil, "Bass: channel 2's, still held")
assert(parts.Synth and #parts.Synth == 2 and parts["Synth (4)"] and #parts["Synth (4)"] == 2, "both Synth tracks, each its own part: " .. table.concat((function() local t = {}; for k in pairs(parts) do t[#t + 1] = k end; return t end)(), ","))
for _, n in ipairs(parts.Synth) do if n.p == 60 then assert(n.e == 1.5, "the note held on both Synth tracks ends on each") end end
for _, n in ipairs(parts["Synth (4)"]) do if n.p == 60 then assert(n.e == 1.5, "and on the second") end end
assert(parts.Pad == nil and parts.Mon == nil and parts.Vox == nil, "not output, none, or audio")
tracks_here[2].arm, play_pos = 0, 2.25 -- (Bass disarmed mid-take)
clock = clock + 0.1
lm.send_tick(nil, me, b, true)
play(0x91, 43, 90, 2.4)
play_pos = 2.5
clock = clock + 0.1
lm.send_tick(nil, me, b, true)
parts = state()
assert(#parts.Bass == 1 and parts.Bass[1].e == 2.25, "Bass disarmed: its held note ends there, nothing new on it")
local n43 = 0
for _, n in ipairs(parts.Synth) do if n.p == 43 then n43 = n43 + 1 end end
assert(n43 == 1, "the next channel-2 note still on Synth")
play_pos = 3
clock = clock + 0.1
lm.send_tick(nil, me, b, false)
parts = state()
assert(written[#written].done and #parts.Keys == 1 and #parts.Synth == 3 and #parts["Synth (4)"] == 3, "stopped: the last file, every part in it")

-- ---- 5. live MIDI: the others see a part per track ----
local tracks_made, midi_items = {}, {}
band.find_track = function(_, name) return tracks_made[name] end
band.new_track = function(_, name) tracks_made[name] = { name = name, ext = {} }; return tracks_made[name] end
for k, v in pairs({
  GetSetMediaTrackInfo_String = function(tr, k, v, set) if set then tr.ext[k] = v end; return true, tr.ext[k] or "" end,
  CountTrackMediaItems = function(tr) local n = 0; for _, it in ipairs(midi_items) do if it.tr == tr then n = n + 1 end end; return n end,
  GetTrackMediaItem = function(tr, j) local n = 0; for _, it in ipairs(midi_items) do if it.tr == tr then if n == j then return it end; n = n + 1 end end end,
  CreateNewMIDIItemInProj = function(tr, from, to) local it = { tr = tr, ext = {}, pos = from, len = to - from, takes = { { notes = {}, name = "" } } }; midi_items[#midi_items + 1] = it; return it end,
  GetSetMediaItemInfo_String = function(it, k, v, set) local key = k:match("^P_EXT:(.*)$"); if set then it.ext[key] = v end; return true, it.ext[key] or "" end,
  SetMediaItemInfo_Value = function(it, k, v) if k == "D_LENGTH" then it.len = v end end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or 0 end,
  GetActiveTake = function(it) return it.takes[1] end,
  GetSetMediaItemTakeInfo_String = function(t, k, v, set) if set then t.name = v end; return true, t.name end,
  MIDI_CountEvts = function(t) return true, #t.notes, 0, 0 end,
  MIDI_DeleteNote = function(t, k) table.remove(t.notes, k + 1) end,
  MIDI_GetPPQPosFromProjTime = function(_, s) return s * 960 end,
  MIDI_InsertNote = function(t, _, _, a, z, _, p, v) t.notes[#t.notes + 1] = { a = a, z = z, p = p, v = v } end,
}) do rawset(reaper, k, v) end
local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
local d = { f = "20261119-130000Z-L1.json", c = { user = "Bo", since = "20261119-130000Z", time = now_iso, at = 2,
  notes = { { i = 1, t = "Keys", s = 1, e = 1.5, p = 60, v = 100 }, { i = 2, t = "Bass", s = 1.1, p = 40, v = 90 }, { i = 3, t = "Keys", s = 1.6, p = 64, v = 80 } } } }
assert(lm.from_msg(nil, cfg, b, d, false), "a link message from Bo")
assert(#midi_items == 2, "two parts: two views")
local keys_it, bass_it
for _, it in ipairs(midi_items) do if it.ext.band_live:find(":Keys$") then keys_it = it elseif it.ext.band_live:find(":Bass$") then bass_it = it end end
assert(keys_it and bass_it and keys_it.tr == bass_it.tr and keys_it.tr.name == "Bo (live)", "on Bo's (live) track, each tagged with its part")
assert(#keys_it.takes[1].notes == 2 and #bass_it.takes[1].notes == 1 and bass_it.takes[1].notes[1].p == 40, "each part only its own notes")
assert(keys_it.takes[1].name:find("^Keys") and bass_it.takes[1].name:find("^Bass"), "named for their tracks")
assert(lm.from_msg(nil, cfg, b, { f = "20261119-130000Z-L2.json", c = { user = "Bo", since = "20261119-130000Z", time = now_iso, at = 3, notes = { { i = 2, t = "Bass", s = 1.1, e = 2.8, p = 40, v = 90 } } } }, false), "more")
assert(#midi_items == 2 and #keys_it.takes[1].notes == 2 and bass_it.takes[1].notes[1].z == 2.8 * 960, "grown in place: Bass's note ended, Keys untouched")

-- ---- 6. smart take names: audio and MIDI at once, top track first ----
package.loaded.groups = { smart_take_names = function() return true end, smart_lane_names = function() return false end }
band.capture_markers = function() return {} end
local recap = require("recap")
local function tk_(name, file, guid) return { name = name, file = file, guid = guid } end
tracks_here = {
  { arm = 1, items = { { pos = 4, takes = { tk_("Gtr-001.flac", "C:/Rec/Gtr-001.flac", "a1") } } } },
  { arm = 1, items = { { pos = 4, takes = { tk_("untitled MIDI item", "", "a2") } } } },
  { arm = 0, items = { { pos = 0, takes = { tk_("Pad-old.wav", "C:/Rec/Pad-old.wav", "a3") } } } }, -- (armed mid-take, recorded nothing new)
  { arm = 1, items = { { pos = 4, takes = { tk_("Vox-001.flac", "C:/Rec/Vox-001.flac", "a4") } } } },
}
for k, v in pairs({
  CountTracks = function() return #tracks_here end, GetTrack = function(_, i) return tracks_here[i + 1] end,
  GetMediaTrackInfo_Value = function(tr, k) return k == "I_RECARM" and tr.arm or 0 end,
  CountTrackMediaItems = function(tr) return #tr.items end, GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end,
  CountTakes = function(it) return #it.takes end, GetTake = function(it, k) return it.takes[k + 1] end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or 0 end,
  GetMediaItemTake_Source = function(t) return t end, GetMediaSourceType = function() return "FLAC" end,
  GetMediaSourceFileName = function(s) return s.file end,
  GetSetMediaItemTakeInfo_String = function(t, k, v, set) if k == "GUID" then return true, t.guid end; if set then t.name = v end; return true, t.name end,
}) do rawset(reaper, k, v) end
local had = recap.before_record(nil)
had.a1, had.a2, had.a4 = nil, nil, nil -- (as if those three are this recording's)
tracks_here[3].arm = 1
assert(recap.name_takes(nil, cfg, had) == 3, "three new takes")
assert(tracks_here[1].items[1].takes[1].name == "James - take 1" and tracks_here[2].items[1].takes[1].name == "James - take 2" and tracks_here[4].items[1].takes[1].name == "James - take 3", "one number each, top track first, the MIDI take too")
assert(tracks_here[3].items[1].takes[1].name == "Pad-old.wav", "a track armed mid-take keeps its old take's name")

-- ---- 7. the disk warning counts the tracks ----
local R = require("rthealth")
assert(R.fits_words(800, 2) == "about 24 minutes of 24-bit stereo at 48 kHz, 2 tracks at once" and R.fits_words(800) == "about 48 minutes of 24-bit stereo at 48 kHz", R.fits_words(800, 2))
tracks_here = { track("A", 1, 0, 0), track("B", 1, 1024, 0), track("C", 1, 4096, 1), track("D", 1, 4096, 0), track("E", 0, 0, 0) }
for k, v in pairs({
  GetMediaTrackInfo_Value = function(tr, k) return k == "I_RECARM" and tr.arm or k == "I_RECINPUT" and tr.input or k == "I_RECMODE" and tr.mode or 0 end,
  GetFreeDiskSpaceForRecordPath = function() return 9000 end,
}) do rawset(reaper, k, v) end
local logged = {}
band.log = function(t) logged[#logged + 1] = t end
package.loaded.presence = { all = function() return {} end }
R.record_check(nil, cfg, b)
assert(#logged == 1 and logged[1]:find("3 tracks at once", 1, true), "9 GB with 3 audio tracks armed: said, for 3 tracks: " .. tostring(logged[1]))
print("ok")
