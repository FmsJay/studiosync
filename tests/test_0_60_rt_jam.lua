-- Jam (James, 2026-11-20; lib/jam.lua, docs/rt/rt-jam.md): classic NINJAM play-along built into In time. The pure parts: which interval a
-- bar is in, where each stretch of a bandmate's stream plays here (one interval on, on the bar, through tempo changes, a start mid-interval, a
-- loop, a stream that ended), the message checked, the latency taken off, Health's words. Then a round trip with stand-ins: Ann's capture
-- (the extension's) streamed with its segments, Bob and Cy hearing it on their own hidden tracks an interval late, items made a little ahead
-- and made again as the rest arrives, a late and a lost interval counted, mute and level from live audio's cue mix, their live Play ducked;
-- and three players at once. Also: In time's lag is off while jamming and a take's placeholder stays muted (lib/streams.lua).
package.path = "lib/?.lua;" .. package.path
local clock, gext, pext = 1000, {}, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetProjExtState = function(_, s, k) return 1, pext[s .. "\0" .. k] or "" end,
  SetProjExtState = function(_, s, k, v) pext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
band.log = function() end
local jam = require("jam")
local streams = require("streams")
local direct = require("direct")
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end

-- ---- intervals and where a stretch plays ----
assert(jam.interval_of(0, 1) == 0 and jam.interval_of(3.999, 2) == 1 and jam.interval_of(4, 2) == 2 and jam.interval_of(4 - 1e-12, 2) == 2, "by N bars; a boundary read a hair short counts as the next")
assert(jam.frames(44) == 0 and jam.frames(44 + 4 * 1000 + 3) == 1000 and jam.frames(nil) == 0, "whole 16-bit stereo frames past the header")
-- 120 BPM in 4/4: a bar is 2 s. sr 1000 keeps the frame numbers readable.
local steady = { bar_of = function(t) return t / 2 end, time_of = function(m) return 2 * m end }
local function ch(segs, o) o.sr, o.n = o.sr or 1000, o.n or 1; o.bar_of, o.time_of = o.bar_of or steady.bar_of, o.time_of or steady.time_of; return jam.chunks(segs, o) end
local c = ch({ { n0 = 0, p0 = 0 } }, { w0 = 3.9, w1 = 5.5 })
assert(#c == 2 and c[1].dest == 2 and c[1].f_a == 0 and c[1].len == 2 and c[2].dest == 4 and c[2].f_a == 2000 and c[2].f_b == 4000, "bar 1 plays at bar 2, bar 2 at bar 3: one interval on")
assert(c[1].key ~= c[2].key, "each its own key")
c = ch({ { n0 = 0, p0 = 0 } }, { n = 2, w0 = 0, w1 = 7 })
assert(#c == 1 and c[1].dest == 4 and c[1].len == 4 and c[1].f_b == 4000, "two bars an interval: bars 1-2 at bars 3-4")
c = ch({ { n0 = 0, p0 = 1 } }, { w0 = 0, w1 = 4.5 })
assert(#c == 2 and near(c[1].dest, 3) and near(c[1].len, 1) and c[1].f_a == 0 and near(c[2].dest, 4) and c[2].f_a == 1000, "started mid-bar: its half bar keeps its place in the next bar")
-- a tempo change: bars 1-2 at 120 (2 s), from bar 3 at 240 (1 s)
local bars_at = { 0, 2, 4, 5, 6, 7, 8 }
local ramp = {
  bar_of = function(t) for i = #bars_at - 1, 1, -1 do if t >= bars_at[i] then return i - 1 + (t - bars_at[i]) / (bars_at[i + 1] - bars_at[i]) end end return 0 end,
  time_of = function(m) local i = math.floor(m); local a = bars_at[i + 1] or (8 + (i - 6)); local b2 = bars_at[i + 2] or (a + 1); return a + (m - i) * (b2 - a) end,
}
c = ch({ { n0 = 0, p0 = 0 } }, { bar_of = ramp.bar_of, time_of = ramp.time_of, w0 = 4.05, w1 = 5.5 })
assert(#c == 2 and c[1].dest == 4 and c[1].len == 1 and c[1].f_a == 2000, "bar 2 (2 s at 120) starts on bar 3, cut at its end (1 s at 240)")
assert(c[2].dest == 5 and c[2].f_a == 4000 and c[2].len == 1, "bar 3 (1 s) starts exactly on bar 4: every interval on its bar after the change")
-- a loop: four bars, then back to bar 1 (a new segment at frame 8000)
c = ch({ { n0 = 0, p0 = 0 }, { n0 = 8000, p0 = 0 } }, { have = 9000, w0 = 1.5, w1 = 3 })
assert(#c == 1 and c[1].dest == 2 and c[1].f_a == 8000, "the second pass's bar 1 at bar 2, not the first pass's: the newer stretch wins")
c = ch({ { n0 = 0, p0 = 0 }, { n0 = 8000, p0 = 0 } }, { have = 9000, w0 = 7.5, w1 = 9.5 })
assert(#c == 2 and c[1].dest == 6 and c[1].f_a == 4000 and c[2].dest == 8 and c[2].f_a == 6000 and c[2].f_b == 8000,
  "still in the first pass here: its bars 3 and 4, not the second pass's, which haven't been played yet")
c = ch({ { n0 = 0, p0 = 0 } }, { have = 1000, w0 = 1.9, w1 = 4.5 })
assert(#c == 2 and not c[1].nodata and c[2].nodata, "an interval none of which is here yet is still listed (so a lost one is counted)")
-- a seek mid-bar ends a stretch early: its interval is shorter
c = ch({ { n0 = 0, p0 = 0 }, { n0 = 3000, p0 = 20 } }, { w0 = 4.05, w1 = 4.5 })
assert(#c == 1 and c[1].dest == 4 and c[1].f_b == 3000 and c[1].len == 1, "bar 2 only to the seek")
-- a stream that ended: nothing past its last frame
c = ch({ { n0 = 0, p0 = 0 } }, { end_frame = 2500, w0 = 0, w1 = 20 })
assert(#c == 2 and c[2].dest == 4 and c[2].f_b == 2500 and near(c[2].len, 0.5), "the end: half a bar")
c = ch({ { n0 = 0, p0 = 0 } }, { w0 = 600, w1 = 601 })
assert(#c == 1 and c[1].dest == 600, "far into a long stretch: straight there, not every interval since")

-- ---- the message ----
local d = { run = "Ann-20261120-120000Z-001", user = "Ann", file = "jam-20261120-120000Z-001.wav", srate = 48000, bars = 2, segs = { { 0, 0, 3.75 }, { 1, 96000, 12.5 } } }
local v = jam.valid(d, "Song", "main", "Bob")
assert(v and v.rel == "Song/main~Ann~jam-20261120-120000Z-001.wav" and v.bars == 2 and v.segs[1].n0 == 96000 and v.segs[0].p0 == 3.75, "a good one: its name worked out here")
for _, bad in ipairs({ { run = "../x" }, { user = "Bob" }, { user = "a/b" }, { file = "x.exe" }, { file = "../x.wav" }, { srate = 10 }, { bars = 0 }, { bars = 17 }, { bars = 1.5 },
  { segs = { { 0, -1, 0 } } }, { segs = { { 0, 0, 0 / 0 } } }, { segs = { { 0.5, 0, 0 } } }, { segs = "x" } }) do
  local t = {}
  for k, x in pairs(d) do t[k] = x end
  for k, x in pairs(bad) do t[k] = x end
  assert(jam.valid(t, "Song", "main", "Bob") == nil, "refused: " .. next(bad))
end
local many = {}
for i = 1, 33 do many[i] = { i, i, i } end
assert(jam.valid({ run = d.run, user = "Ann", file = d.file, srate = 48000, bars = 1, segs = many }, "Song", "main", "Bob") == nil, "at most 32 segments")
local os_ = jam.out_segs({ { 0, 0, 10.0 }, { 1, 480, 2.0 } }, 0.012)
assert(#os_ == 2 and near(os_[1][3], 9.988) and os_[2][2] == 480, "the latency taken off: where the player heard the song")
local raw = {}
for i = 1, 20 do raw[i] = { i - 1, i * 10, i } end
assert(#jam.out_segs(raw, 0) == jam.SEGS and jam.out_segs(raw, 0)[1][1] == 20 - jam.SEGS, "the newest only")

-- ---- Health's words ----
local t, ok = jam.health_text({ sending = true, peers = 2 }, { { user = "Ann", bars = 1, heard = 12, late = 1, missed = 0 }, { user = "Cy", bars = 1, heard = 0, late = 0, missed = 0 } }, 1, "0")
assert(ok and t:find("every 1 bar") and t:find("to 2") and t:find("Ann %(12 intervals, 1 late%)") and t:find("Cy %(waiting"), "what goes out, who's heard and how late")
t, ok = jam.health_text({ why = "live audio's Play isn't going" }, { { user = "Ann", bars = 2, heard = 3, late = 0, missed = 1 } }, 1, "2")
assert(not ok and t:find("send nothing") and t:find("every 2 bars, not 1") and t:find("1 missed") and t:find("isn't at 0 bars"), "problems said")
assert(jam.why_not(false, true, 1):find("newer") and jam.why_not(true, false, 1):find("Play") and jam.why_not(true, true, 0):find("nobody") and jam.why_not(true, true, 2) == nil, "why nothing goes out")

-- ---- settings: Jam turns In time on and Follow each other at 0, and puts Follow back ----
pext[band.SECTION .. "\0side"] = "2"
jam.set({}, true)
assert(jam.on() and streams.mode() == "in_time" and pext[band.SECTION .. "\0side"] == "0", "on: In time, everyone follows at 0 bars")
assert(streams.in_time_lag({ type = "start", rec = true, follow = true, lead = "Ann" }, "Bob", "in_time", 2, nil) == nil, "In time's lag is off while jamming")
jam.set({}, false)
assert(not jam.on() and pext[band.SECTION .. "\0side"] == "2", "off: Follow each other as it was")
assert(streams.in_time_lag({ type = "start", rec = true, follow = true, lead = "Ann" }, "Bob", "in_time", 2, nil) == 2, "and In time's lag back")

-- ---- a round trip with stand-ins: Ann sends, Bob (and Cy) hear ----
local tracks, items, ducked, applied = {}, {}, {}, 0
local play = { state = 0, pos = 0 }
local inn, out = {}, {}
local arrived = {} -- path -> frames there
local sent = {} -- { kind, d, to }
local streams_started = {}
local cap = { on = false, frames = 0, segs = {}, state = "none" }
local function track_items(tr) local r = {}; for _, it in ipairs(items) do if it.tr == tr then r[#r + 1] = it end end; return r end
for k, f in pairs({
  CountTracks = function() return #tracks end, GetTrack = function(_, i) return tracks[i + 1] end,
  ValidatePtr2 = function(_, p) if type(p) ~= "table" then return true end; for _, x in ipairs(tracks) do if x == p then return true end end; for _, x in ipairs(items) do if x == p then return true end end; return p.proj == true end,
  GetSetMediaTrackInfo_String = function(tr, k, v, set) local key = k:match("^P_EXT:(.*)$") or k; if set then tr.ext[key] = v end; return true, tr.ext[key] or "" end,
  GetMediaTrackInfo_Value = function(tr, k) return tr.v[k] or 0 end, SetMediaTrackInfo_Value = function(tr, k, x) tr.v[k] = x end,
  DeleteTrack = function(tr) for i, x in ipairs(tracks) do if x == tr then table.remove(tracks, i) end end; for i = #items, 1, -1 do if items[i].tr == tr then table.remove(items, i) end end end,
  AddMediaItemToTrack = function(tr) local it = { tr = tr, v = {}, ext = {} }; items[#items + 1] = it; return it end,
  AddTakeToMediaItem = function(it) it.take = { v = {} }; return it.take end,
  GetActiveTake = function(it) return it.take end,
  GetMediaItemTake_Source = function(tk) return tk.src end, SetMediaItemTake_Source = function(tk, s) tk.src = s end,
  SetMediaItemInfo_Value = function(it, k, x) it.v[k] = x end, GetMediaItemInfo_Value = function(it, k) return it.v[k] or 0 end,
  SetMediaItemTakeInfo_Value = function(tk, k, x) tk.v[k] = x end,
  GetSetMediaItemInfo_String = function(it, k, v, set) local key = k:match("^P_EXT:(.*)$"); if set then it.ext[key] = v end; return true, it.ext[key] or "" end,
  DeleteTrackMediaItem = function(_, it) for i, x in ipairs(items) do if x == it then table.remove(items, i) end end end,
  PCM_Source_CreateFromFile = function(p) return arrived[p] and { path = p, len = arrived[p] / 1000 } or nil end,
  GetMediaSourceLength = function(s) return s.len end,
  GetPlayStateEx = function() return play.state end, GetPlayPosition2Ex = function() return play.pos end,
  TimeMap2_timeToBeats = function(_, t) return (t % 2) * 2, math.floor(t / 2), 4 end,
  TimeMap2_beatsToTime = function(_, beats, m) return 2 * (m or 0) + beats / 2 end,
  TimeMap2_timeToQN = function(_, t) return 2 * t end, TimeMap2_QNToTime = function(_, q) return q / 2 end,
  GetInputOutputLatency = function() return 0, 0 end,
  EnumProjects = function() return { proj = true } end,
  StudioSync_DirectMsg = function() return 1 end, StudioSync_DirectClock = function() return "{}" end,
  StudioSync_DirectStream = function() return 1 end, StudioSync_DirectNow = function() return 1.7e9 end,
  StudioSync_DirectStreams = function() return band.json_encode({ out = out, ["in"] = inn }) end,
  StudioSync_JamStart = function(p) cap = { on = true, path = p, frames = 0, segs = {}, state = "writing" }; return 1 end,
  StudioSync_JamStop = function() cap.on, cap.state = false, "done" end,
  StudioSync_JamStatus = function() return band.json_encode({ on = cap.on, state = cap.state, srate = 1000, frames = cap.frames, segs = cap.segs }) end,
}) do rawset(reaper, k, f) end
package.loaded.mirror = { add_local_track = function(_, name, tag) local tr = { name = name, ext = { band_local = tag }, v = {} }; tracks[#tracks + 1] = tr; return tr end }
local la_mix, la_me = {}, { volume = 1 }
package.loaded.liveaudio = { ducks = ducked, S = { sending = { play = true } }, mix = function() return la_mix end, me = function() return la_me end,
  play_gain = function(want, s) return (want and want.play or 1) * (s.volume or 1) end,
  hear_plan = function(want, s) return 1, s.deaf == true or (want and want.mute == true) or false end, apply = function() applied = applied + 1 end }
direct.peers = function() return { "bob:47281", "cy:47281" } end
direct.stream_start = function(_, path, song, room, _, name, to) streams_started[#streams_started + 1] = { path = path, name = name, to = to }; return song .. "/" .. name end
direct.stream_end = function() return true end
direct.send_live = function(_, kind, dd) sent[#sent + 1] = { kind = kind, d = band.json_decode(band.json_encode(dd)) } end
band.files = function() return {} end
os.remove = function() return true end
local proj = { proj = true }
local ann, bob, cy = { root = "R", user = "Ann" }, { root = "R", user = "Bob" }, { root = "R", user = "Cy" }
local b = { song = "Song", room = "main" }
gext[band.SECTION .. "\0stream bars"] = "2"
jam.set(proj, true)
-- Ann plays: a run starts, the stream once the first audio is written, a "jam" message with the segment
play.state, play.pos = 1, 0
jam.send_tick(proj, ann, b, clock)
assert(cap.on and cap.path:find("^H/direct/studio1/%.jam/jam%-.*%.wav$"), "Ann's capture into the link's own folder, never the shared one")
assert(#streams_started == 0, "the link waits for the first audio")
cap.frames, cap.segs = 100, { { 0, 0, 0 } }
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(#streams_started == 1 and streams_started[1].name:find("^main~Ann~jam%-") and #streams_started[1].to == 2, "streamed to Bob and Cy under <room>~<user>~<file>")
assert(#sent == 1 and sent[1].kind == "jam" and sent[1].d.bars == 2 and #sent[1].d.segs == 1, "a jam message: its interval and segment")
clock = clock + 0.5
jam.send_tick(proj, ann, b, clock)
assert(#sent == 1, "not again until a second has gone, with nothing new")
cap.segs[2] = { 1, 4000, 0 } -- (a loop back to the start after 4 s)
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(#sent == 2 and #sent[2].d.segs == 2, "a new segment goes at once")
-- Bob hears it. Two bars an interval (Ann's): bars 1-2 (0-4 s) play at bars 3-4 (4-8 s).
local m1 = sent[1].d
m1.segs = { { 0, 0, 0 } }
assert(jam.on_msg(bob, b, m1) and jam.book[m1.run], "Bob takes it")
local e = jam.book[m1.run]
assert(e.path == "H/direct/studio1/.streams/Song/main~Ann~" .. m1.file, "its copy in the inbox's .streams (the receiver's own name for it)")
inn[1] = { studio = "studio1", rel = e.rel, bytes = 44 + 4 * 2500, done = false }
arrived[e.path] = 2500
play.pos = 2.4
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
assert(#tracks == 1 and tracks[1].name == "Jam: Ann" and tracks[1].ext.band_local == "jam" and tracks[1].v.B_SHOWINTCP == 0 and tracks[1].v.B_SHOWINMIXER == 0, "a hidden track of Bob's own for Ann")
assert(#items == 0, "her first interval's slot (4 s) isn't within 1.5 s yet")
assert(ducked.Ann and ducked.Ann > clock and applied == 1, "her live Play is silent here while she jams (applied at once)")
play.pos = 2.6
clock = clock + 0.1
jam.receive_tick(proj, bob, b, clock)
local it = items[1]
assert(#items == 1 and it.v.D_POSITION == 4 and it.v.D_LENGTH == 4 and it.take.v.D_STARTOFFS == 0 and it.v.B_LOOPSRC == 0, "bars 1-2 at bar 3, never looped")
assert(it.ext.band_arriving == "1" and it.ext.band_jam:find(m1.run, 1, true), "never mirrored, and Jam's")
assert(near(it.take.src.len, 2.5), "made from what has arrived")
-- the rest arrives as she plays; made again once it's whole, or as the playhead nears what's there
inn[1].bytes, arrived[e.path] = 44 + 4 * 3500, 3500
play.pos = 3.0
clock = clock + 0.3
jam.receive_tick(proj, bob, b, clock)
assert(near(it.take.src.len, 2.5), "not made again yet: whole later, and the playhead far from its end")
inn[1].bytes, arrived[e.path] = 44 + 4 * 4100, 4100
clock = clock + 0.3
jam.receive_tick(proj, bob, b, clock)
assert(items[1] == it and near(it.take.src.len, 4.1), "her whole interval: made again in place")
-- level and mute: live audio's cue mix
la_mix.Ann = { play = 0.5, mute = false }
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
assert(near(tracks[1].v.D_VOL, 0.5) and (tracks[1].v.B_MUTE or 0) == 0, "her Play level")
la_mix.Ann.mute = true
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
assert(tracks[1].v.B_MUTE == 1, "muted in the cue mix: muted here")
la_mix.Ann = nil
la_me.deaf = true
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
assert(tracks[1].v.B_MUTE == 1, "deafened: silent")
la_me.deaf = nil
-- a late interval: bars 3-4 (frames 4000-8000) haven't all come when their slot (8-12 s) is played into
play.pos = 6.7
inn[1].bytes, arrived[e.path] = 44 + 4 * 5000, 5000
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
local it2
for _, x in ipairs(items) do if x.v.D_POSITION == 8 then it2 = x end end
assert(it2 and it2.take.v.D_STARTOFFS == 4 and #items == 2, "the next interval made ahead from what's there")
play.pos = 8.1
clock = clock + 0.1
jam.receive_tick(proj, bob, b, clock)
assert(#items == 1 and items[1] == it2, "the played one gone")
play.pos = 9.2 -- (1 s of it has arrived: 4000-5000; the playhead is past)
clock = clock + 0.3
jam.receive_tick(proj, bob, b, clock)
assert(e.late == 1, "heard a gap: counted late once")
clock = clock + 0.3
jam.receive_tick(proj, bob, b, clock)
assert(e.late == 1, "once")
-- a lost interval: nothing of bars 5-6 ever comes (frames 8000-12000), its slot at 12 s passes
inn[1].bytes, arrived[e.path] = 44 + 4 * 8000, 8000
play.pos = 12.3
clock = clock + 0.3
jam.receive_tick(proj, bob, b, clock)
assert(e.missed == 1 and #items == 0, "its start hadn't come by its slot: missed, nothing made")
assert(jam.heard()[1].user == "Ann" and jam.heard()[1].heard == 2 and jam.heard()[1].missed == 1, "who's heard, and how")
local rows = jam.health_rows(bob, b, proj)
assert(#rows == 1 and rows[1][1] == "jam" and rows[1][5]:find("you hear Ann"), "Health's row")
local bi = jam.beat_info()
assert(bi.bars == 2 and bi.who[1] == "Ann", "the Beat page: the interval and who's heard")
-- three players: Cy jams too; Bob hears both, each on their own track
local mc = { run = "Cy-20261120-120001Z-002", user = "Cy", file = "jam-cy.wav", srate = 1000, bars = 2, segs = { { 0, 0, 12 } } }
assert(jam.on_msg(bob, b, mc), "Cy's run")
local ec = jam.book[mc.run]
inn[2] = { studio = "studio1", rel = ec.rel, bytes = 44 + 4 * 3000, done = false }
arrived[ec.path] = 3000
play.pos = 15
clock = clock + 0.3
jam.receive_tick(proj, bob, b, clock)
local names = {}
for _, tr in ipairs(tracks) do names[#names + 1] = tr.name end
table.sort(names)
assert(#tracks == 2 and names[1] == "Jam: Ann" and names[2] == "Jam: Cy", "a track each")
local on_cy
for _, x in ipairs(items) do if x.tr.name == "Jam: Cy" then on_cy = x end end
assert(on_cy and on_cy.v.D_POSITION == 16 and on_cy.take.v.D_STARTOFFS == 0, "Cy's bars 7-8 (from 12 s) at bars 9-10")
assert(ducked.Cy and ducked.Ann, "both live Plays silent here")
-- stopping: every item goes; Ann's run ends with its stream
play.state = 0
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
assert(#items == 0, "stopped: nothing left on the tracks")
jam.send_tick(proj, ann, b, clock)
assert(not cap.on and sent[#sent].kind == "jam_end", "Ann stopped: her capture ends, and the others are told")
jam.on_end({ run = m1.run })
inn[1].done = true
clock = clock + jam.QUIET + 1
jam.receive_tick(proj, bob, b, clock)
assert(jam.book[m1.run] == nil, "her run, ended and played out, is forgotten")
-- Mute me / no Play: nothing goes out, and Health says why
package.loaded.liveaudio.S.sending = { play = false }
play.state = 1
jam.send_tick(proj, ann, b, clock)
assert(not cap.on and jam.S.why:find("Play"), "Play not going: no run, and why")
-- In time's placeholder stays muted while jamming (a take recorded while jamming is heard through Jam)
assert(streams.mode() == "in_time" and jam.on(), "still jamming")
-- Jam off: its tracks go, nothing is taken in
jam.set(proj, false)
clock = clock + 1
jam.tick(proj, bob, b, true)
assert(#tracks == 0 and next(jam.book) == nil and not jam.on_msg(bob, b, mc), "off: the tracks go, nothing more is taken")
print("ok jam: intervals on the bar through tempo changes, loops and seeks; a round trip with two and three players; late, lost, mute")
