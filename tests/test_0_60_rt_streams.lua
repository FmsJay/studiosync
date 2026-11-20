-- Roadmap step 2 (James, rt): interval streaming, NINJAM built in (lib/streams.lua). The pure parts: which new files in the record path are
-- the take's and whose track each is, the stream's name and the "take" message checked, a placeholder's length and how often it's made
-- again, the swap decision when the real take lands, what's given up on and pruned, the in-time lag, Health's line; then a placeholder's
-- life with a stand-in REAPER: made on the recorder's track when bytes come, never mirrored, grown, kept while mirror's stand-in waits for
-- the real audio, gone with its stream file once the real take is here. Live MIDI over the link: L-messages fold in, a note stays ended.
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

-- ---- which files are the take's ----
assert(streams.audio_ext("a.FLAC") and streams.audio_ext("x.wav") and not streams.audio_ext("x.wav.reapeaks") and not streams.audio_ext("x.mid") and not streams.audio_ext("x.rpp-bak"), "audio files only")
assert(streams.records_audio(1, 0, 0) and streams.records_audio(1, 1024 + 2, 0) and streams.records_audio(1, 0, 1), "armed audio input or output to a file")
assert(not streams.records_audio(0, 0, 0) and not streams.records_audio(1, -1, 0) and not streams.records_audio(1, 4096 + 33, 0) and not streams.records_audio(1, 0, 2) and not streams.records_audio(1, 0, 7), "not armed, no input, MIDI, none, MIDI overdub")
assert(streams.made_since(1000, 1000, true) and streams.made_since(997.5, 1000, true) and not streams.made_since(996, 1000, true), "made or written since Record (3 s tolerance)")
assert(not streams.made_since(nil, 1000, true) and streams.made_since(nil, 1000, false) and not streams.made_since(-1, 1000, true), "no file time (older extension): only what appears after the first look")
local tracks = { { name = "Gtr", num = 1 }, { name = "Gtr 2", num = 2 }, { name = "Bass", num = 3 } }
local m = streams.match(tracks, { "Bass-001.flac", "Gtr 2-001.flac", "Gtr-001.flac" })
local got = {}
for _, p in ipairs(m) do got[p.track.name] = p.file end
assert(#m == 3 and got.Gtr == "Gtr-001.flac" and got["Gtr 2"] == "Gtr 2-001.flac" and got.Bass == "Bass-001.flac", "by name, the longest first")
m = streams.match({ { name = "", num = 2 }, { name = "", num = 5 } }, { "05-201119_1530.wav", "02-201119_1530.wav" })
got = {}
for _, p in ipairs(m) do got[p.track.num] = p.file end
assert(got[2] == "02-201119_1530.wav" and got[5] == "05-201119_1530.wav", "by the track number at the start of the name")
m = streams.match({ { name = "Vox", num = 1 }, { name = "Keys", num = 2 } }, { "rec_0001.wav", "rec_0002.wav" })
assert(#m == 2 and m[1].track.name == "Vox" and m[1].file == "rec_0001.wav" and m[2].file == "rec_0002.wav", "as many as there are tracks: in order")
m = streams.match({ { name = "Vox", num = 1 }, { name = "Keys", num = 2 } }, { "rec_0001.wav", "rec_0002.wav", "rec_0003.wav" })
assert(#m == 0, "can't tell which is whose: none streamed (they come the normal way)")
m = streams.match({ { name = "Vox", num = 1 }, { name = "Keys", num = 2 } }, { "Keys-1.wav", "rec_0002.wav", "x.wav" })
assert(#m == 1 and m[1].track.name == "Keys", "the named one only, when the rest can't be told apart")
assert(streams.start_pos(10, 10.04) == 10 and streams.start_pos(10, 30) == 30, "from the cursor, else where the playhead is")
assert(math.abs(streams.start_pos(3.6923, 1.8462) - 3.6923) < 1e-9, "in a count-in the playhead is a bar before the cursor: the take starts at the cursor (beat 8 at 130 BPM)")

-- ---- the stream's name and the message ----
local nm = streams.stream_name("main", "Chilio_Mac", "Bass-001.flac")
assert(nm == "main~Chilio_Mac~Bass-001.flac" and direct.stream_rel("Cross Test", nm) == "Cross Test/" .. nm, "<room>~<user>~<file>, a name the link takes")
assert(streams.stream_name("main", "Bo", "a:b/c.wav") == "main~Bo~a_b_c.wav" and streams.stream_name("main", "Bo", "x.txt") == nil, "plain characters; audio only")
local long = streams.stream_name("main", "Bo", string.rep("x", 400) .. ".wav")
assert(#long == 200 and long:sub(-4) == ".wav" and long:sub(1, 8) == "main~Bo~", "trimmed to 200, its extension kept")
local d = { id = "Bo-20261119-120000Z-1231", user = "Bo", track = "T-BO-20261119-1", name = "Bass", file = "Bass-001.flac", pos = 12.5, at = 1.7e9 }
local e = streams.valid_take(d, "Song", "main", "James", clock)
assert(e and e.rel == "Song/main~Bo~Bass-001.flac" and e.pos == 12.5 and e.bytes == 0, "a good one")
for _, bad in ipairs({ { id = "../x" }, { user = "James" }, { user = "a/b" }, { track = "X-1" }, { file = "../../x.wav" }, { file = "x.exe" }, { pos = -1 }, { pos = "x" }, { pos = 0 / 0 } }) do
  local t = {}
  for k, v in pairs(d) do t[k] = v end
  for k, v in pairs(bad) do t[k] = v end
  assert(streams.valid_take(t, "Song", "main", "James", clock) == nil, "refused: " .. next(bad))
end
assert(streams.valid_take(d, ".hidden", "main", "James", clock) == nil, "a song name the link won't take")

-- ---- growing ----
e = streams.valid_take(d, "Song", "main", "James", 0)
streams.update(e, { bytes = 50000, total = -1, done = false, ok = false }, 1)
assert(e.bytes == 50000 and e.progress_at == 1 and not e.done, "bytes in")
assert(math.abs(streams.length(e, 0, 1.7e9 + 5) - 4.7) < 1e-6, "a growing FLAC REAPER can't measure: by the shared clock, less the link")
assert(streams.length(e, 3.2, nil) == 3.2 and streams.length(e, 0, nil) == 0.1, "a WAV REAPER measures; nothing known: a sliver")
e.len = 4.7
assert(streams.length(e, 3.2, nil) == 4.7, "never shorter while growing")
assert(streams.refresh_every(10) == 0.25 and streams.refresh_every(600) == 5, "4 a second, then rarer as it gets long")
e.shown, e.refreshed_at = 50000, 1
assert(not streams.refresh_due(e, 2), "nothing new: no refresh")
e.bytes = 60000
assert(not streams.refresh_due(e, 1.1) and streams.refresh_due(e, 1.3), "new bytes, at most every 0.25 s")
streams.update(e, { bytes = 70000, total = 70000, done = true, ok = true }, 9)
assert(e.done and e.done_at == 9 and e.ok and e.total == 70000, "done and checked")
assert(streams.refresh_due(e, 9) and streams.length(e, 4.2, nil) == 4.2, "done: once, at once, and exactly the file's length")
e.final = true
assert(not streams.refresh_due(e, 20), "then never again")

-- ---- the real take ----
assert(streams.swap_decision(e, nil) == "wait", "not here yet")
assert(streams.swap_decision(e, { size = 70000 }) == "repoint", "the same file: the placeholder just goes")
assert(streams.swap_decision(e, { size = 70001 }) == "swap", "not the same: the real take replaces it")
assert(streams.swap_decision({ done = false, total = 70000 }, { size = 70000 }) == "swap", "an unfinished stream: replaced")
assert(not streams.expired(e, 9 + 899) and streams.expired(e, 9 + 901), "given up 15 minutes after it finished")
e.held_at = 600
assert(not streams.expired(e, 9 + 901) and streams.expired(e, 600 + 901), "mirror's stand-in for the real take keeps it")
assert(streams.expired({ progress_at = 0 }, 301) and not streams.expired({ progress_at = 0 }, 299), "no bytes for 5 minutes")
local book = { a = { rel = "Song/main~Bo~keep.flac" } }
local gone = streams.prunable({ "main~Bo~keep.flac", "main~Bo~keep.flac.reapeaks", "main~Bo~old.flac", "main~Bo~old.flac.reapeaks", "main~Bo~coming.flac",
  "side~Bo~x.flac", "main~Bo~y.flac.part", "other.wav" }, book, { ["main~Bo~coming.flac"] = true }, "main")
assert(#gone == 2 and gone[1] == "main~Bo~old.flac" and gone[2] == "main~Bo~old.flac.reapeaks", "this room's, not kept, not arriving, not a part file; peaks with their file")

-- ---- in time ----
local st
local lag
lag, st = streams.in_time_lag({ type = "start", rec = true, follow = true, lead = "Bo", lag = 0 }, "James", "as_it_comes", 2, nil)
assert(lag == nil and st == nil, "as it comes: the cue as it is")
lag, st = streams.in_time_lag({ type = "start", rec = true, follow = true, lead = "Bo", lag = 0 }, "James", "in_time", 2, nil)
assert(lag == 2 and st.lead == "Bo", "their recording start: one interval behind")
lag, st = streams.in_time_lag({ type = "stop", follow = true, lead = "Al", lag = 0 }, "James", "in_time", 3, st)
assert(lag == nil and st.lead == "Bo", "someone else's stop: as it is")
lag, st = streams.in_time_lag({ type = "stop", follow = true, lead = "Bo", lag = 0 }, "James", "in_time", 3, st)
assert(lag == 2 and st == nil, "their stop: as far behind as the start")
lag = streams.in_time_lag({ type = "start", rec = true, follow = true, lead = "Bo", lag = 4 }, "James", "in_time", 2, nil)
assert(lag == 4, "a cue already further behind stays so")
assert(streams.in_time_lag({ type = "start", rec = true, follow = true, lead = "James" }, "James", "in_time", 2, nil) == nil, "our own")
assert(streams.in_time_lag({ type = "start", rec = true, follow = true, lead = "Bo", remote = true }, "James", "in_time", 2, nil) == nil, "a producer's remote start")
lag, st = streams.in_time_lag({ type = "start", follow = true, lead = "Bo" }, "James", "in_time", 2, { lead = "Bo", lag = 2 })
assert(lag == nil and st == nil, "a plain play: not a take, no lag")

-- ---- Health ----
assert(streams.health_text({ out = {}, inn = {} }) == nil, "nothing: no line")
local h = streams.health_text({ out = { { rel = "Song/main~James~Bass-001.flac", size = 1048576, finished = false, error = "", peers = { ["james-laptop.tail99.ts.net:47281"] = { sent = 65536, error = "" } } } },
  inn = { { rel = "Song/main~Bo~Keys-002.flac", bytes = 524288, done = false }, { done = true, ok = false } } })
assert(h:find("out James's Bass%-001%.flac: 1%.00 MB written, james%-laptop has 0%.06 MB") and h:find("in Bo's Keys%-002%.flac: 0%.50 MB so far") and h:find("1 didn't get through whole"), h)
h = streams.health_text({ out = { { rel = "Song/main~James~B.flac", size = 0, finished = false, error = "can't open the file to read it (Windows error 32: REAPER holds it without letting others read)", peers = {} } }, inn = {} })
assert(h:find("Windows error 32"), "a stream this computer can't read says why")

-- ---- a placeholder's life, with a stand-in REAPER ----
local items, guid_n, srcs = {}, 0, 0
local removed = {}
os.remove = function(p) removed[p] = true; return true end
local TR = { name = "Bass" }
local function new_item(tr, file, pos, len)
  guid_n = guid_n + 1
  local it = { tr = tr, guid = "{G" .. guid_n .. "}", ext = {}, pos = pos, len = len, mute = 0, takes = {} }
  if file then it.takes[1] = { src = { file = file }, name = "" } end
  items[#items + 1] = it
  return it
end
local function track_items(tr) local t = {}; for _, it in ipairs(items) do if it.tr == tr then t[#t + 1] = it end end; return t end
local src_len = { } -- file -> what REAPER would say its length is
local inn = {}
local exists = {}
local peaks_calls = 0
for k, v in pairs({
  CountTracks = function() return 1 end, GetTrack = function() return TR end, UpdateArrange = function() end,
  CountTrackMediaItems = function(tr) return #track_items(tr) end,
  GetTrackMediaItem = function(tr, i) return track_items(tr)[i + 1] end,
  GetSetMediaItemInfo_String = function(it, k, v, set)
    if k == "GUID" then return true, it.guid end
    local key = k:match("^P_EXT:(.*)$")
    if set then it.ext[key] = v end
    return true, it.ext[key] or ""
  end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or k == "D_LENGTH" and it.len or k == "B_MUTE" and it.mute or k == "I_RECARM" and 0 or 0 end,
  GetMediaTrackInfo_Value = function() return 0 end,
  SetMediaItemInfo_Value = function(it, k, v) if k == "D_LENGTH" then it.len = v elseif k == "B_MUTE" then it.mute = v end end,
  GetActiveTake = function(it) return it.takes[1] end,
  CountTakes = function(it) return #it.takes end,
  GetTake = function(it, i) return it.takes[i + 1] end,
  GetMediaItemTake_Source = function(tk) return tk.src end,
  SetMediaItemTake_Source = function(tk, s) tk.src = s end,
  PCM_Source_Destroy = function() end,
  PCM_Source_CreateFromFile = function(f) if exists[f] then srcs = srcs + 1; return { file = f } end end,
  GetMediaSourceLength = function(s) return src_len[s.file] or 0 end,
  GetMediaSourceFileName = function(s) return s.file end,
  PCM_Source_BuildPeaks = function(_, mode) peaks_calls = peaks_calls + 1; return mode == 0 and 50 or 0 end,
  GetSetMediaItemTakeInfo_String = function(tk, k, v, set) if set then tk.name = v end; return true, tk.name end,
  DeleteTrackMediaItem = function(_, it) for i, x in ipairs(items) do if x == it then table.remove(items, i) end end end,
  file_exists = function(p) return exists[p] == true end,
  StudioSync_DirectMsg = function() return 1 end, StudioSync_DirectClock = function() return "{}" end,
  StudioSync_DirectStream = function() return 1 end, StudioSync_DirectNow = function() return 1.7e9 end,
  StudioSync_DirectStreams = function() return band.json_encode({ out = {}, ["in"] = inn }) end,
}) do rawset(reaper, k, v) end
band.add_item = function(tr, path, pos, len) if not exists[path] then return nil end; return new_item(tr, path, pos, len) end
band.size = function(p) return p:find("shared") and 70000 or nil end
direct.shared_now = function() return 1.7e9 + 3 end
package.loaded.mirror = { find = function(_, kind, oid) return kind == "track" and oid == "T-BO-20261119-1" and TR or nil end }
local cfg, b = { root = "R", user = "James" }, { song = "Song", room = "main" }
assert(streams.on_take(cfg, b, d) and not streams.on_take(cfg, b, d), "a take, once")
local se = streams.book[d.id]
assert(se.path == "H/direct/studio1/.streams/Song/main~Bo~Bass-001.flac", "its file in the inbox's .streams, by the receiver's own name")
streams.receive_tick(nil, cfg, b, false)
assert(#items == 0, "nothing until bytes come")
inn[1] = { studio = "studio1", rel = se.rel, bytes = 60000, total = -1, done = false, ok = false }
exists[se.path] = true
clock = clock + 1
streams.receive_tick(nil, cfg, b, false)
local ph = items[1]
assert(ph and ph.tr == TR and ph.pos == 12.5, "on the recorder's track, where the take starts")
assert(ph.ext.band_arriving == "1" and ph.ext.band_stream == d.id, "never mirrored (mirror.scan skips band_arriving), and ours")
assert(ph.mute == 0 and ph.takes[1].name:find("Bo is recording"), "as it comes: plays; says what it is")
assert(math.abs(ph.len - 2.7) < 1e-6, "a FLAC REAPER can't measure yet: by the shared clock")
inn[1].bytes, src_len[se.path] = 90000, 3.5
clock = clock + 0.1
streams.receive_tick(nil, cfg, b, false)
assert(srcs == 0, "not before 0.25 s")
clock = clock + 0.2
streams.receive_tick(nil, cfg, b, false)
assert(ph.len == 3.5 and srcs == 1, "grown from a fresh source")
gext[band.SECTION .. "\0stream listen"] = "show"
clock = clock + 0.1
streams.receive_tick(nil, cfg, b, false)
assert(ph.mute == 1, "show only: muted")
gext[band.SECTION .. "\0stream listen"] = nil
streams.on_take_end({ id = d.id })
inn[1].bytes, inn[1].total, inn[1].done, inn[1].ok, src_len[se.path] = 70000, 70000, true, true, 4.25
clock = clock + 0.3
streams.receive_tick(nil, cfg, b, false)
assert(ph.len == 4.25 and se.final and ph.takes[1].name:find("streamed, the take follows"), "done: the whole file, its exact length")
assert(#items == 1, "kept until the real take is here")
local stand = new_item(TR, nil, 12.5, 4.25)
stand.ext.band_arriving = "1" -- (mirror's grey stand-in: the take's event is here, its audio isn't)
clock = clock + 1.1
streams.receive_tick(nil, cfg, b, false)
assert(#items == 2 and se.held_at == clock, "mirror's stand-in: still waiting, and kept past the 15 minutes")
for i, x in ipairs(items) do if x == stand then table.remove(items, i) end end
local real = new_item(TR, "R/Song/rooms/main/media/ab12cd-Bass-001.flac", 12.5, 4.25)
exists[real.takes[1].src.file] = true
clock = clock + 1.1
streams.receive_tick(nil, cfg, b, false)
assert(#items == 1 and items[1] == real and streams.book[d.id] == nil, "the real take landed with its audio: the placeholder went")
assert(removed[se.path] and removed[se.path .. ".reapeaks"], "and its streamed copy, peaks too")

-- A take whose placeholder you deleted: left alone, its file goes once it's complete
local d2 = { id = "Bo-20261119-120100Z-0002", user = "Bo", track = "T-BO-20261119-1", name = "Bass", file = "Bass-002.flac", pos = 20 }
streams.on_take(cfg, b, d2)
local e2 = streams.book[d2.id]
inn[2] = { studio = "studio1", rel = e2.rel, bytes = 60000, total = -1, done = false, ok = false }
exists[e2.path] = true
clock = clock + 1
streams.receive_tick(nil, cfg, b, false)
local ph2 = items[#items]
assert(ph2.ext.band_stream == d2.id, "made")
for i, x in ipairs(items) do if x == ph2 then table.remove(items, i) end end
clock = clock + 1
streams.receive_tick(nil, cfg, b, false)
assert(e2.dismissed and #items == 1, "deleted here: not made again")
inn[2].done, inn[2].ok, inn[2].total, inn[2].bytes = true, true, 60000, 60000
clock = clock + 1
streams.receive_tick(nil, cfg, b, false)
assert(streams.book[d2.id] == nil and removed[e2.path], "complete: its file goes")

-- A take too short for a placeholder (3 KB streamed): its copy still goes once the real take is in (laptop, rt: 2-3 KB copies stayed)
local d3 = { id = "Bo-20261119-120200Z-0003", user = "Bo", track = "T-BO-20261119-1", name = "Bass", file = "Bass_1153.flac", pos = 40 }
streams.on_take(cfg, b, d3)
local e3 = streams.book[d3.id]
inn[3] = { studio = "studio1", rel = e3.rel, bytes = 3379, total = 3379, done = true, ok = true }
exists[e3.path] = true
clock = clock + 1.1
streams.receive_tick(nil, cfg, b, false)
assert(streams.book[d3.id] and not e3.guid, "no placeholder, no real take yet: kept")
local real3 = new_item(TR, "R/Song/rooms/main/media/ff00-Bass_1153.flac", 40, 0.05)
exists[real3.takes[1].src.file] = true
clock = clock + 1.1
streams.receive_tick(nil, cfg, b, false)
assert(streams.book[d3.id] == nil and removed[e3.path], "the real take is in: the streamed copy goes")

-- A placeholder left from before a Live sync reload (the book starts empty): the next prune pass takes it off; the band's own items stay
local orphan = new_item(TR, "H/direct/studio1/.streams/Song/main~Bo~Bass-009.flac", 60, 2)
orphan.ext.band_stream, orphan.ext.band_arriving = "Bo-20261119-115900Z-0009", "1"
local n_before = #items
clock = clock + streams.PRUNE_EVERY + 1
streams.receive_tick(nil, cfg, b, false)
assert(#items == n_before - 1 and items[#items] ~= orphan and items[1] == real, "orphaned placeholder gone, the real takes kept")

-- ---- the recorder's side, with a stand-in REAPER ----
local rec_dir, tracks_here = { "old.flac" }, { { name = "Bass", arm = 1, input = 1024, mode = 0, oid = "T-JAMES-1" }, { name = "Keys", arm = 0, input = 0, mode = 0, oid = "T-JAMES-2" } }
local made = { ["C:/Rec/old.flac"] = 100 } -- path -> its file time
local sent, started, ended = {}, {}, {}
local play_pos, cursor = 8.05, 8
for k, v in pairs({
  GetProjectPathEx = function() return "C:/Rec" end,
  CountTracks = function() return #tracks_here end,
  GetTrack = function(_, i) return tracks_here[i + 1] end,
  GetMediaTrackInfo_Value = function(tr, k) return k == "I_RECARM" and tr.arm or k == "I_RECINPUT" and tr.input or k == "I_RECMODE" and tr.mode or 0 end,
  GetTrackName = function(tr) return true, tr.name end,
  GetPlayPositionEx = function() return play_pos end,
  GetCursorPositionEx = function() return cursor end,
  GetSetProjectInfo = function() return 0 end,
  GetAudioDeviceInfo = function() return true, "48000" end,
  StudioSync_DirectFileTime = function(p) return made[p] or -1 end,
}) do rawset(reaper, k, v) end
package.loaded.mirror = { local_track = function() return false end, track_oid = function(tr) return tr.oid end }
local real_files = band.files
band.files = function(dir) if dir == "C:/Rec" then local t = {}; for i, f in ipairs(rec_dir) do t[i] = f end; table.sort(t); return t end; return real_files(dir) end
direct.peers = function() return { "laptop.tail99.ts.net:47281" } end
direct.stream_start = function(_, path, song, room, ms, name) started[#started + 1] = { path = path, name = name, ms = ms }; return direct.stream_rel(song, name) end
direct.stream_end = function(_, rel) ended[#ended + 1] = rel; return true end
direct.send_live = function(_, kind, dd, song, room, id) sent[#sent + 1] = { kind = kind, d = dd, id = id } end
local me = { root = "R", user = "James" }
local real_time = os.time
local wall = 2000
os.time = function(t) if t then return real_time(t) end; return wall end
-- armed and Record pressed at once, with a one-bar count-in: no listing beforehand, the file made as the count-in starts
rec_dir[#rec_dir + 1] = "Bass-001.flac"; made["C:/Rec/Bass-001.flac"] = 2000.4
cursor, play_pos = 3.6923, 1.8462
streams.send_tick(nil, me, b, true)
assert(#started == 1 and started[1].path == "C:/Rec/Bass-001.flac" and started[1].name == "main~James~Bass-001.flac" and started[1].ms == 100, "the new file streams at once, under its link name")
local tk = sent[1]
assert(tk.kind == "take" and tk.d.track == "T-JAMES-1" and tk.d.file == "Bass-001.flac" and tk.d.pos == 3.6923 and tk.d.nch == 2 and tk.d.srate == 48000 and tk.d.fmt == "flac", "the take message: it starts at the cursor, not the count-in's playhead")
assert(math.abs(tk.d.at - (1.7e9 + 3 + (3.6923 - 1.8462))) < 1e-6, "at: the shared clock when the playhead reaches the take's start, still to come")
assert(streams.valid_take(tk.d, "Song", "main", "Bo", clock), "and the others take it")
clock = clock + 0.2
streams.send_tick(nil, me, b, true)
assert(#started == 1, "once")
clock = clock + 5
streams.send_tick(nil, me, b, false)
assert(#ended == 0, "stopped: the header REAPER writes at stop first")
clock = clock + 0.6
streams.send_tick(nil, me, b, false)
assert(#ended == 1 and ended[1] == "Song/main~James~Bass-001.flac" and sent[2].kind == "take_end" and sent[2].d.id == tk.d.id, "then the rest, and the others told")
-- the next take: the file only appears after the count-in, and an older one written long before isn't taken
wall, cursor, play_pos = 2100, 10, 8
rec_dir[#rec_dir + 1] = "Bass-000.flac"; made["C:/Rec/Bass-000.flac"] = 1500
clock = clock + 1
streams.send_tick(nil, me, b, true)
assert(#started == 1, "nothing new yet (and Bass-000 is old)")
clock = clock + 3.5
streams.send_tick(nil, me, b, true)
play_pos = 10.02
rec_dir[#rec_dir + 1] = "Bass-002.flac"; made["C:/Rec/Bass-002.flac"] = 2102
clock = clock + 0.15
streams.send_tick(nil, me, b, true)
assert(#started == 2 and started[2].path == "C:/Rec/Bass-002.flac", "made after a long count-in: still looked for, and found")
clock = clock + 1
streams.send_tick(nil, me, b, false); clock = clock + 1; streams.send_tick(nil, me, b, false)
tracks_here[1].arm = 0
rec_dir[#rec_dir + 1] = "Bass-003.flac"; made["C:/Rec/Bass-003.flac"] = 2200; wall = 2200
clock = clock + 1
streams.send_tick(nil, me, b, true)
assert(#started == 2, "nothing armed: nothing streams")
os.time = real_time

-- ---- live MIDI over the link ----
package.loaded.sync, package.loaded.live = package.loaded.sync or {}, package.loaded.live or {}
local lm = require("livemidi")
local mst = { seen = {}, notes = {} }
assert(lm.merge(mst, { "20261119-120000Z-L1.json" }, function() return { user = "Bo", since = "20261119-120000Z", at = 2, notes = { { i = 1, t = "Keys", s = 1, e = 1.5, p = 60, v = 90 } } } end), "a link message folds in")
assert(lm.merge(mst, { "20261119-120000Z-0001.json" }, function() return { user = "Bo", since = "20261119-120000Z", at = 1.2, notes = { { i = 1, t = "Keys", s = 1, p = 60, v = 90 } } } end), "the older file after it")
assert(mst.notes[1].e == 1.5 and mst.at == 2, "a note that ended stays ended; at never goes back")
print("ok")
