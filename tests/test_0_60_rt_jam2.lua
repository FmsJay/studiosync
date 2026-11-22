-- Jam, rt-p12 (backlog 1.15, 3.15; lib/jam.lua, docs/rt/rt-p12.md): a run goes only to the computers that say "Jam on" (jam_hear), not to
-- everyone; one who says so mid-run is added to the stream from its start and told where its stretches sit at once (so they hear the next
-- interval, not the next play); Opus when this device runs at 48 kHz and everyone it goes to can read it, else the 16-bit WAV (a listener
-- that can't, a 44.1 kHz device, or Opus refused once); a receiver turns an Opus copy into a WAV through the extension's decoder, places from
-- that WAV, takes its end from the decoder, and drops the job and the WAV when the run is forgotten.
package.path = "lib/?.lua;" .. package.path
local clock, gext, pext = 1000, {}, {}
local dev_rate = "48000"
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetProjExtState = function(_, s, k) return 1, pext[s .. "\0" .. k] or "" end,
  SetProjExtState = function(_, s, k, v) pext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetAudioDeviceInfo = function(k) if k == "SRATE" then return true, dev_rate end return false, "" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
local jam = require("jam")
local direct = require("direct")

-- ---- who a run goes to ----
local L = { Bob = { at = 995, opus = true }, Cy = { at = 999, opus = false }, Old = { at = 990, opus = true } }
local users = { ["bob:1"] = "Bob", ["cy:1"] = "Cy", ["dee:1"] = "Dee", ["old:1"] = "Old" }
local p, o, all = jam.audience({ "bob:1", "cy:1", "dee:1", "old:1" }, users, L, 1000)
assert(#p == 2 and p[1] == "bob:1" and p[2] == "cy:1", "only those who said Jam on within HEAR_FOR s (not Dee, who never did; not Old, 10 s ago)")
assert(o["bob:1"] == true and o["cy:1"] == false and all == false, "who reads Opus; not all of them do")
p, o, all = jam.audience({ "bob:1" }, users, L, 1000)
assert(#p == 1 and all == true, "all of them read Opus")
p, o, all = jam.audience({ "x:1", "y:1" }, {}, L, 1000)
assert(#p == 2 and all == false, "nobody's person known (an older list): everyone, the WAV, as before")
assert(jam.why_not(true, true, 2, 0):find("nobody here has Jam on") and jam.why_not(true, true, 2, 1) == nil and jam.why_not(true, true, 2) == nil, "why nothing goes out: nobody listening")
assert(jam.on_hear({ user = "Ann" }, {}, { user = "Bob", opus = true }) and jam.listeners.Bob.opus == true, "a Jam on taken")
assert(not jam.on_hear({ user = "Ann" }, {}, { user = "Ann" }) and not jam.on_hear({ user = "Ann" }, {}, { user = "a/b" }) and not jam.on_hear({ user = "Ann" }, {}, "x"), "its own, a bad name: refused")
jam.listeners.Bob = nil

-- ---- stand-ins (as tests/test_0_60_rt_jam.lua's) ----
local tracks, items = {}, {}
local play = { state = 0, pos = 0 }
local inn = {}
local arrived = {}
local sent, started, removed = {}, {}, {}
local cap = { on = false, frames = 0, segs = {}, state = "none" }
local dec = {} -- path -> { state, frames }; calls
local dec_calls = {}
for k, f in pairs({
  CountTracks = function() return #tracks end, GetTrack = function(_, i) return tracks[i + 1] end,
  ValidatePtr2 = function(_, x) if type(x) ~= "table" then return true end; for _, t in ipairs(tracks) do if t == x then return true end end; for _, t in ipairs(items) do if t == x then return true end end; return x.proj == true end,
  GetSetMediaTrackInfo_String = function(tr, k2, v, set) local key = k2:match("^P_EXT:(.*)$") or k2; if set then tr.ext[key] = v end; return true, tr.ext[key] or "" end,
  GetMediaTrackInfo_Value = function(tr, k2) return tr.v[k2] or 0 end, SetMediaTrackInfo_Value = function(tr, k2, x) tr.v[k2] = x end,
  DeleteTrack = function(tr) for i, x in ipairs(tracks) do if x == tr then table.remove(tracks, i) end end end,
  AddMediaItemToTrack = function(tr) local it = { tr = tr, v = {}, ext = {} }; items[#items + 1] = it; return it end,
  AddTakeToMediaItem = function(it) it.take = { v = {} }; return it.take end,
  GetActiveTake = function(it) return it.take end,
  GetMediaItemTake_Source = function(tk) return tk.src end, SetMediaItemTake_Source = function(tk, s) tk.src = s end,
  SetMediaItemInfo_Value = function(it, k2, x) it.v[k2] = x end, GetMediaItemInfo_Value = function(it, k2) return it.v[k2] or 0 end,
  SetMediaItemTakeInfo_Value = function(tk, k2, x) tk.v[k2] = x end,
  GetSetMediaItemInfo_String = function(it, k2, v, set) local key = k2:match("^P_EXT:(.*)$"); if set then it.ext[key] = v end; return true, it.ext[key] or "" end,
  DeleteTrackMediaItem = function(_, it) for i, x in ipairs(items) do if x == it then table.remove(items, i) end end end,
  PCM_Source_CreateFromFile = function(path) return arrived[path] and { path = path, len = arrived[path] / 1000 } or nil end,
  GetMediaSourceLength = function(s) return s.len end,
  GetPlayStateEx = function() return play.state end, GetPlayPosition2Ex = function() return play.pos end,
  TimeMap2_timeToBeats = function(_, t) return (t % 2) * 2, math.floor(t / 2), 4 end,
  TimeMap2_beatsToTime = function(_, beats, m) return 2 * (m or 0) + beats / 2 end,
  TimeMap2_timeToQN = function(_, t) return 2 * t end, TimeMap2_QNToTime = function(_, q) return q / 2 end,
  GetInputOutputLatency = function() return 0, 0 end,
  EnumProjects = function() return { proj = true } end,
  StudioSync_DirectMsg = function() return 1 end, StudioSync_DirectClock = function() return "{}" end,
  StudioSync_DirectStream = function() return 1 end, StudioSync_DirectNow = function() return 1.7e9 end,
  StudioSync_DirectStreams = function() return band.json_encode({ out = {}, ["in"] = inn }) end,
  StudioSync_JamStart = function(path) cap = { on = true, path = path, frames = 0, segs = {}, state = "writing" }; return 1 end,
  StudioSync_JamStop = function() cap.on, cap.state = false, "done" end,
  StudioSync_JamStatus = function() return band.json_encode({ on = cap.on, state = cap.state, srate = 48000, frames = cap.frames, segs = cap.segs }) end,
  StudioSync_JamDecode = function(src, dst, mode)
    dec_calls[#dec_calls + 1] = { src = src, dst = dst, mode = mode }
    if mode == 2 then dec[src] = nil; return '{"state":"none","frames":0}' end
    local d = dec[src] or { state = "decoding", frames = 0 }
    dec[src] = d
    return band.json_encode(d)
  end,
}) do rawset(reaper, k, f) end
package.loaded.mirror = { add_local_track = function(_, name, tag) local tr = { name = name, ext = { band_local = tag }, v = {} }; tracks[#tracks + 1] = tr; return tr end }
package.loaded.liveaudio = { ducks = {}, S = { sending = { play = true } }, mix = function() return {} end, me = function() return { volume = 1 } end,
  play_gain = function() return 1 end, hear_plan = function() return 1, false end, apply = function() end }
direct.peers = function() return { "bob:1", "cy:1" }, {}, { ["bob:1"] = "Bob", ["cy:1"] = "Cy" } end
direct.stream_start = function(_, path, song, _, _, name, to) started[#started + 1] = { path = path, name = name, to = to }; return song .. "/" .. name end
direct.stream_end = function() return true end
direct.send_live = function(_, kind, dd, _, _, _, to) sent[#sent + 1] = { kind = kind, d = band.json_decode(band.json_encode(dd)), to = to } end
band.files = function() return {} end
os.remove = function(path) removed[#removed + 1] = path; return true end
local proj = { proj = true }
local ann, bob = { root = "R", user = "Ann" }, { root = "R", user = "Bob" }
local b = { song = "Song", room = "main" }
jam.set(proj, true)

-- ---- Ann sends: nobody has Jam on, then Bob, then Cy mid-run ----
play.state, play.pos = 1, 0
jam.send_tick(proj, ann, b, clock)
assert(not cap.on and jam.S.why:find("nobody here has Jam on"), "nobody listening: no capture, and why (it went to everyone before)")
jam.on_hear(ann, b, { user = "Bob", opus = true })
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(cap.on and cap.path:find("%.opus$"), "Bob reads Opus and the device runs at 48 kHz: the capture is Ogg Opus")
cap.frames, cap.segs = 960, { { 0, 0, 0 } }
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(#started == 1 and #started[1].to == 1 and started[1].to[1] == "bob:1" and started[1].name:find("%.opus$"), "streamed to Bob alone, as an .opus")
assert(#sent == 1 and sent[1].kind == "jam" and sent[1].d.file:find("%.opus$") and sent[1].to[1] == "bob:1" and #sent[1].to == 1, "the jam message to Bob alone")
jam.on_hear(ann, b, { user = "Cy", opus = true }) -- (Cy turns Jam on mid-run)
clock = clock + 0.2
jam.send_tick(proj, ann, b, clock)
assert(#started == 2 and #started[2].to == 1 and started[2].to[1] == "cy:1" and started[2].path == started[1].path, "Cy added to the same stream (the link sends a peer added later from the start)")
assert(#sent == 2 and #sent[2].to == 2, "where its stretches sit goes at once, to both (not a second later, not at the next play)")
clock = clock + 0.2
jam.send_tick(proj, ann, b, clock)
assert(#started == 2, "once")
-- the run ends; Cy now on an older extension (no Opus): the next run is the WAV
play.state = 0
jam.send_tick(proj, ann, b, clock)
assert(not cap.on and sent[#sent].kind == "jam_end", "stopped: the run ends")
jam.on_hear(ann, b, { user = "Cy" })
play.state = 1
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(cap.on and cap.path:find("%.wav$"), "one of them can't read Opus: the WAV")
play.state = 0
jam.send_tick(proj, ann, b, clock)
-- a 44.1 kHz device: the WAV
jam.on_hear(ann, b, { user = "Cy", opus = true })
dev_rate = "44100"
play.state = 1
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(cap.on and cap.path:find("%.wav$"), "a device at 44.1 kHz: the WAV (Opus is 48 kHz)")
play.state = 0
jam.send_tick(proj, ann, b, clock)
-- Opus refused by the extension once: the WAV from then on
dev_rate = "48000"
play.state = 1
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(cap.on and cap.path:find("%.opus$"), "Opus again")
cap.state = "failed"
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(not cap.on, "failed: the run ends")
clock = clock + 0.1
jam.send_tick(proj, ann, b, clock)
assert(cap.on and cap.path:find("%.wav$"), "and the next is the WAV")
play.state = 0
jam.send_tick(proj, ann, b, clock)
-- a listener gone quiet for HEAR_FOR s: off the run
clock = clock + jam.HEAR_FOR + 1
play.state = 1
jam.send_tick(proj, ann, b, clock)
assert(not cap.on and jam.S.why:find("Jam on"), "nobody said Jam on lately: nothing goes")
play.state = 0

-- ---- Bob hears an Opus run: through the decoder's WAV ----
local m = { run = "Ann-20261121-120000Z-001", user = "Ann", file = "jam-20261121-120000Z-001.opus", srate = 48000, bars = 1, segs = { { 0, 0, 0 } } }
assert(jam.on_msg(bob, b, m), "Bob takes an Opus run")
local e = jam.book[m.run]
assert(e.opus and e.wav == e.path .. ".wav", "placed from the WAV beside the copy")
inn[1] = { studio = "studio1", rel = e.rel, bytes = 5000, done = false }
dec[e.path] = { state = "decoding", frames = 1500 * 48 }
arrived[e.wav] = 1500
play.state, play.pos = 1, 0.7
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
assert(dec_calls[#dec_calls].src == e.path and dec_calls[#dec_calls].dst == e.wav and dec_calls[#dec_calls].mode == 0, "the decoder goes on with it")
assert(e.frames == 1500 * 48, "frames from the decoder, not the copy's bytes")
assert(#items == 1 and items[1].take.src.path == e.wav and items[1].v.D_POSITION == 2, "bar 1 at bar 2, from the decoded WAV")
inn[1].done = true
jam.on_end({ run = m.run })
dec[e.path] = { state = "done", frames = 2000 * 48 }
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
assert(dec_calls[#dec_calls].mode == 1 and e.end_frame == 2000 * 48, "the stream done and the run ended: finish, and the end is the decoder's")
play.state = 0
clock = clock + jam.QUIET + 1
jam.receive_tick(proj, bob, b, clock)
assert(jam.book[m.run] == nil and dec_calls[#dec_calls].mode == 2 and removed[#removed] == e.wav, "forgotten: the job dropped and its WAV gone")
-- a bad copy: said once
assert(jam.on_msg(bob, b, { run = "Ann-2", user = "Ann", file = "jam-2.opus", srate = 48000, bars = 1, segs = { { 0, 0, 0 } } }), "another")
local e2 = jam.book["Ann-2"]
inn[2] = { studio = "studio1", rel = e2.rel, bytes = 100, done = false }
dec[e2.path] = { state = "failed", frames = 0, error = "not an Opus copy" }
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
clock = clock + 0.2
jam.receive_tick(proj, bob, b, clock)
local said = 0
for _, l in ipairs(logs) do if l:find("can't be read here: not an Opus copy", 1, true) then said = said + 1 end end
assert(said == 1, "a copy that can't be read: said once")
-- an older extension here (no decoder): an Opus run isn't taken (their live Play stays heard)
local keep = reaper.StudioSync_JamDecode
rawset(reaper, "StudioSync_JamDecode", nil)
assert(not jam.on_msg(bob, b, { run = "Ann-3", user = "Ann", file = "jam-3.opus", srate = 48000, bars = 1, segs = { { 0, 0, 0 } } }), "no decoder: not taken")
rawset(reaper, "StudioSync_JamDecode", keep)

-- ---- Jam on here: said every HEAR_EVERY s, to everyone here ----
sent = {}
clock = clock + 5
jam.tick(proj, bob, b, false)
local hear
for _, s in ipairs(sent) do if s.kind == "jam_hear" then hear = s end end
assert(hear and hear.d.user == "Bob" and hear.d.opus == true and #hear.to == 2, "Bob says Jam on (and that he reads Opus) to everyone here")
local n = #sent
clock = clock + 0.5
jam.tick(proj, bob, b, false)
assert(#sent == n, "not again for HEAR_EVERY s")
print("ok jam2: only to those with Jam on, a latecomer from the start, Opus when all read it, the decoder's WAV placed")
