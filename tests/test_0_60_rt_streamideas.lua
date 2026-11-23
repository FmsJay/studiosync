-- The streaming ideas from the roadmap (James, rt; lib/streams.lua): a bandmate who joins mid-take gets it from its start (the same stream,
-- the peer added); punch-in assist (the punch range and pre-roll sent as link messages, shown as this computer's own markers till the take
-- ends); producer listen (this computer's level for takes as they come); and the recording-format hint (FLAC arrives in 2-5 s steps, so
-- "In time" at one bar is late: WAV here, or more bars). Pure parts first, then the recorder's and the receiver's sides with a stand-in REAPER.
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
band.log = function() end
local streams = require("streams")
local direct = require("direct")

-- ---- pure ----
assert(streams.start_pos(10, 10.02, 20) == 20, "auto-punch ahead: the take starts at the punch-in")
assert(streams.start_pos(10, 10.02, 4) == 10 and streams.start_pos(10, 30, 20) == 30 and streams.start_pos(10, 10.02, nil) == 10, "already past it, or no auto-punch: as before")
local nc = streams.newcomers({ "a:1", "b:1", "c:1" }, { ["a:1"] = true, ["c:1"] = true })
assert(#nc == 1 and nc[1] == "b:1" and #streams.newcomers({}, {}) == 0, "only the peers a take hasn't gone to")

local p = streams.punch_info(true, 20, 28, 20, 2)
assert(p.start == 20 and p.stop == 28 and p.preroll == 2, "auto-punch with pre-roll")
p = streams.punch_info(true, 20, 28, 23, 0)
assert(p.start == 23 and p.stop == 28 and p.preroll == nil, "started inside the selection: from there to the punch-out")
p = streams.punch_info(false, 20, 28, 10, 1.5)
assert(p.start == 10 and p.stop == nil and p.preroll == 1.5, "pre-roll alone: where recording begins and where playback does")
assert(streams.punch_info(false, 20, 28, 10, 0) == nil and streams.punch_info(true, 0, 0, 10, 0) == nil and streams.punch_info(true, 20, 28, 30, 0) == nil,
  "nothing beyond the take itself: no punch, an empty selection, or past the punch-out")

local d = { id = "Bo-20261119-120000Z-123p", user = "Bo", start = 20, stop = 28, preroll = 2 }
local v = streams.valid_punch(d, "James")
assert(v and v.start == 20 and v.stop == 28 and v.preroll == 2, "a good one")
assert(streams.valid_punch({ id = d.id, user = "Bo", start = 5 }, "James"), "start only")
for _, bad in ipairs({ { id = "../x" }, { user = "James" }, { user = "a/b" }, { start = -1 }, { start = "x" }, { stop = 10 }, { stop = "y" }, { preroll = 0 }, { preroll = 1e4 } }) do
  local t = {}
  for k, x in pairs(d) do t[k] = x end
  for k, x in pairs(bad) do t[k] = x end
  assert(streams.valid_punch(t, "James") == nil, "refused: " .. next(bad))
end
local marks = streams.punch_marks(v)
assert(#marks == 2 and marks[1].region and marks[1].pos == 20 and marks[1].rend == 28 and marks[2].pos == 18 and not marks[2].region, "a region for the punch, a marker for the pre-roll")
for _, m in ipairs(marks) do assert(band.is_local_mark(m.name), "never one of the band's markers: " .. m.name) end
marks = streams.punch_marks({ user = "Bo", start = 1, preroll = 4 })
assert(#marks == 2 and not marks[1].region and marks[1].pos == 1 and marks[2].pos == 0, "the start as a marker; the pre-roll never before 0")
assert(not band.is_local_mark("Bridge") and not band.is_local_mark("[punchline]"), "the band's own stay theirs")

assert(streams.listen_vol(0) == 1 and streams.listen_vol(-60) == 0 and math.abs(streams.listen_vol(-6) - 0.501187) < 1e-5, "dB to item volume; -60 is off")
assert(streams.listen_db() == 0, "0 dB unless set")
gext[band.SECTION .. "\0stream listen db"] = "-12.5"
assert(streams.listen_db() == -12.5, "this computer's level")
gext[band.SECTION .. "\0stream listen db"] = "40"
assert(streams.listen_db() == 6, "kept in range")
gext[band.SECTION .. "\0stream listen db"] = nil

assert(streams.fourcc(band.FLAC) == "flac" and streams.fourcc(streams.WAV24) == "wave" and streams.fourcc("ZXZhdw==") == "wave" and streams.fourcc("") == "", "the sink's kind")
assert(streams.flac_bars(1.85) == 3 and streams.flac_bars(0.5) == 10 and streams.flac_bars(4) == 2 and streams.flac_bars(0.01) == 16, "bars that cover a 5 s FLAC step")
assert(streams.format_hint("flac", "in_time", 1, 1.85):find("Use 3 bars", 1, true), "FLAC, in time, one bar: late, and what to do")
assert(streams.format_hint("flac", "in_time", 3, 1.85) == nil, "enough bars: nothing to say")
assert(streams.format_hint("wave", "in_time", 1, 1.85) == nil and streams.format_hint("flac", "as_it_comes", 1, 1.85) == nil, "WAV, or not in time: nothing")
assert(streams.record_wav() and streams.record_want() == streams.WAV24 and streams.format_ok("ZXZhdxgAAAA=") and not streams.format_ok(band.FLAC), "24-bit WAV by default, on every computer: any WAV config REAPER reads back")
gext[band.SECTION .. "\0record wav"] = "0"
assert(not streams.record_wav() and streams.record_want() == band.FLAC and streams.format_ok(band.FLAC) and not streams.format_ok(streams.WAV24), "FLAC only where this computer chose it")
gext[band.SECTION .. "\0record wav"] = "1"
assert(streams.record_wav(), "an old explicit WAV choice still reads as WAV")
gext[band.SECTION .. "\0record wav"] = nil

-- ---- the recorder: a punch, a take, and a late joiner ----
local tracks_here = { { name = "Bass", arm = 1, input = 1024, mode = 0, oid = "T-JAMES-1" } }
local rec_dir, made = {}, {}
local play_pos, cursor = 10, 10
local toggles = { [40076] = 1, [41819] = 1 }
for k, f in pairs({
  StudioSync_DirectMsg = function() return 1 end, StudioSync_DirectClock = function() return "{}" end, StudioSync_DirectStream = function() return 1 end,
  GetProjectPathEx = function() return "C:/Rec" end,
  CountTracks = function() return #tracks_here end,
  GetTrack = function(_, i) return tracks_here[i + 1] end,
  GetMediaTrackInfo_Value = function(tr, k) return k == "I_RECARM" and tr.arm or k == "I_RECINPUT" and tr.input or k == "I_RECMODE" and tr.mode or 0 end,
  GetTrackName = function(tr) return true, tr.name end,
  GetPlayPositionEx = function() return play_pos end,
  GetCursorPositionEx = function() return cursor end,
  GetSetProjectInfo = function() return 0 end,
  GetAudioDeviceInfo = function() return true, "48000" end,
  StudioSync_DirectFileTime = function(path) return made[path] or -1 end,
  GetToggleCommandStateEx = function(_, cmd) return toggles[cmd] or 0 end,
  GetSet_LoopTimeRange2 = function() return 20, 28 end,
  get_config_var_string = function(k) if k == "prerollmeas" then return true, "1.00000000" end return false, "" end,
  TimeMap_GetTimeSigAtTime = function() return 4, 4, 120 end, -- (120 BPM, 4/4: a bar is 2 s)
  TimeMap2_timeToQN = function(_, t) return t * 2 end,
  TimeMap2_QNToTime = function(_, qn) return qn / 2 end,
}) do rawset(reaper, k, f) end
package.loaded.mirror = { local_track = function() return false end, track_oid = function(tr) return tr.oid end }
local real_files = band.files
band.files = function(dir) if dir == "C:/Rec" then local t = {}; for i, f in ipairs(rec_dir) do t[i] = f end; table.sort(t); return t end; return real_files(dir) end
local peers = { "laptop.tail99.ts.net:47281" }
local started, ended, sent = {}, {}, {}
direct.peers = function() return peers end
direct.shared_now = function() return 1.7e9 end
direct.stream_start = function(_, path, song, room, ms, name, to) started[#started + 1] = { path = path, name = name, to = to }; return direct.stream_rel(song, name) end
direct.stream_end = function(_, rel) ended[#ended + 1] = rel; return true end
direct.send_live = function(_, kind, dd, song, room, id, to) sent[#sent + 1] = { kind = kind, d = dd, id = id, to = to } end
local real_time = os.time
local wall = 2000
os.time = function(t) if t then return real_time(t) end; return wall end
local me, b = { root = "R", user = "James" }, { song = "Song", room = "main" }
local function of_kind(kind) local t = {}; for _, s in ipairs(sent) do if s.kind == kind then t[#t + 1] = s end end; return t end

-- Record pressed at bar 6 (10 s) with the time selection 20-28 s, auto-punch and one bar of pre-roll
streams.send_tick(nil, me, b, true)
local pu = of_kind("punch")
assert(#pu == 1 and pu[1].d.start == 20 and pu[1].d.stop == 28 and pu[1].d.preroll == 2 and pu[1].d.user == "James" and pu[1].to[1] == peers[1], "the punch goes out as recording begins")
assert(streams.valid_punch(pu[1].d, "Bo"), "and the others take it")
assert(#started == 0, "no file yet: REAPER writes from the punch-in")
clock, play_pos = clock + 5, 15 -- (still before the punch-in: FIND_SECS hasn't begun)
rec_dir[#rec_dir + 1] = "Bass-old.flac"; made["C:/Rec/Bass-old.flac"] = 1000
streams.send_tick(nil, me, b, true)
assert(#started == 0, "an old file isn't taken")
clock, play_pos = clock + 5, 20.05
rec_dir[#rec_dir + 1] = "Bass-001.flac"; made["C:/Rec/Bass-001.flac"] = 2010
streams.send_tick(nil, me, b, true)
assert(#started == 1 and started[1].path == "C:/Rec/Bass-001.flac" and started[1].to[1] == peers[1], "found at the punch-in")
local tk = of_kind("take")
assert(#tk == 1 and tk[1].d.pos == 20, "the placeholder sits at the punch-in, not the cursor")
-- the Mac joins mid-take
peers = { "laptop.tail99.ts.net:47281", "mac.tail99.ts.net:47281" }
clock, play_pos = clock + 0.2, 20.25
streams.send_tick(nil, me, b, true)
assert(#started == 2 and started[2].path == started[1].path and started[2].name == started[1].name and #started[2].to == 1 and started[2].to[1] == peers[2],
  "the same stream again, for the newcomer alone: the extension sends it from byte 0")
tk = of_kind("take")
assert(#tk == 2 and tk[2].to[1] == peers[2] and tk[2].id == tk[1].id and tk[2].d == tk[1].d, "and the same take message, to it alone")
pu = of_kind("punch")
assert(#pu == 2 and pu[2].to[1] == peers[2] and pu[2].id == pu[1].id, "the punch too")
clock = clock + 0.2
streams.send_tick(nil, me, b, true)
assert(#started == 2 and #of_kind("take") == 2 and #of_kind("punch") == 2, "once each")
-- stop
clock = clock + 3
streams.send_tick(nil, me, b, false)
clock = clock + 0.6
streams.send_tick(nil, me, b, false)
assert(#ended == 1 and #of_kind("take_end") == 1, "the stream ends once for everyone")
local pe = of_kind("punch_end")
assert(#pe == 1 and pe[1].d.id == pu[1].id, "and the punch goes from their timelines")

-- MIDI only (no armed audio), pre-roll without auto-punch: the punch still goes, nothing streams
tracks_here, toggles, sent, started, ended = {}, { [41819] = 1 }, {}, {}, {}
cursor, play_pos, wall = 30, 28, 2100
clock = clock + 1
streams.send_tick(nil, me, b, true)
pu = of_kind("punch")
assert(#pu == 1 and pu[1].d.start == 30 and pu[1].d.stop == nil and pu[1].d.preroll == 2 and #started == 0, "where it records from, and the pre-roll")
clock = clock + 2
streams.send_tick(nil, me, b, false)
clock = clock + 0.6
streams.send_tick(nil, me, b, false)
assert(#of_kind("punch_end") == 1 and #of_kind("take_end") == 0, "its end, no take's")
-- no pre-roll, no auto-punch: no punch message at all
toggles, sent = {}, {}
clock = clock + 1
streams.send_tick(nil, me, b, true)
clock = clock + 1
streams.send_tick(nil, me, b, false)
clock = clock + 0.6
streams.send_tick(nil, me, b, false)
assert(#sent == 0, "a plain recording: nothing extra")

-- ---- the others' side: the punch on the timeline ----
local markers = { { rgn = false, pos = 4, rend = 0, name = "Verse", col = 0 } }
for k, f in pairs({
  AddProjectMarker2 = function(_, rgn, pos, rend, name, _, col) markers[#markers + 1] = { rgn = rgn, pos = pos, rend = rend, name = name, col = col }; return #markers - 1 end,
  CountProjectMarkers = function() return #markers end,
  EnumProjectMarkers3 = function(_, i) local m = markers[i + 1]; if not m then return 0 end; return i + 1, m.rgn, m.pos, m.rend, m.name, i + 1, m.col end,
  DeleteProjectMarkerByIndex = function(_, i) table.remove(markers, i + 1); return true end,
  ColorToNative = function(r, g, bb) return r | (g << 8) | (bb << 16) end,
  StudioSync_DirectStreams = function() return '{"out":[],"in":[]}' end,
}) do rawset(reaper, k, f) end
package.loaded.people = { colours = function() return { Bo = 0xFF8000 } end }
local PROJ = {}
assert(not streams.on_punch(PROJ, me, b, { id = "J-1", user = "James", start = 1 }), "never our own")
assert(streams.on_punch(PROJ, me, b, d) and not streams.on_punch(PROJ, me, b, d), "a punch, once")
assert(#markers == 3 and markers[2].rgn and markers[2].pos == 20 and markers[2].rend == 28 and markers[3].pos == 18, "the range and the pre-roll")
assert(markers[2].col == (0xFF | (0x80 << 8)) | 0x1000000, "in Bo's colour")
streams.on_punch_end(PROJ, { id = d.id })
assert(#markers == 1 and markers[1].name == "Verse" and next(streams.punches) == nil, "gone when the take ends; the band's markers stay")
streams.on_punch(PROJ, me, b, { id = "Bo-2", user = "Bo", start = 40 })
streams.on_punch(PROJ, me, b, { id = "Bo-3", user = "Bo", start = 50 })
assert(#markers == 2 and markers[2].pos == 50 and streams.punches["Bo-2"] == nil, "their next punch replaces one whose end never came")
clock = clock + streams.PUNCH_KEEP + 1
streams.receive_tick(PROJ, me, b, false)
assert(#markers == 1 and next(streams.punches) == nil, "and one with no end goes after PUNCH_KEEP")

print("ok")
