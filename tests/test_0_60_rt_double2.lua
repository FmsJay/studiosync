-- The full-quality copy, rt-p12 (backlog 1.14, 3.15; lib/double.lua, docs/rt/rt-p12.md). Pure parts: the drift fit (a frame and its clock each
-- second -> the device's real rate as the item's play rate), a stretch played at another play rate as one item (its play rate the inverse,
-- the pitch kept), the anchor's place the furthest project end any computer reported (whoever started first), MIDI tracks taken and their
-- events placed. Then three runs with stand-ins for REAPER and the extension: MIDI only, live with no transport (a MIDI item where the notes
-- were played, each event in place); the transport at twice the speed (one item, play rate 0.5); five minutes live on an interface 50 ppm
-- fast (the item's play rate 1.00005, every moment within a tenth of a millisecond of where it was played, not 15 ms off by the end).
package.path = "lib/?.lua;" .. package.path
local SR = 1000
local T0 = 1.8e9 + 1000
local T = T0
local ext = {}
local W = { playing = false, pos = 0, len = 0, tracks = {}, keep = nil, hist = {}, seq = 0, started = 0 }
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end
reaper = setmetatable({
  time_precise = function() return T end,
  GetOS = function() return "Win64" end,
  GetExePath = function() return "C:/REAPER" end,
  GetExtState = function(s, k) return ext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "\0" .. k] = nil end,
  GetProjExtState = function() return 1, "" end,
  GetPlayStateEx = function() return W.playing and 1 or 0 end,
  GetPlayPosition2Ex = function() return W.pos end,
  CountTracks = function() return #W.tracks end,
  GetTrack = function(_, i) return W.tracks[i + 1] end,
  GetTrackGUID = function(tr) return tr.guid end,
  GetTrackName = function(tr) return true, tr.name end,
  GetMediaTrackInfo_Value = function(tr, k)
    if k == "I_RECARM" then return tr.arm elseif k == "I_RECINPUT" then return tr.input elseif k == "I_RECMODE" then return tr.mode end
    return tr.info[k] or 0
  end,
  SetMediaTrackInfo_Value = function(tr, k, v) tr.info[k] = v end,
  GetSetMediaTrackInfo_String = function(tr, k, v, set) if set then tr.info[k] = v end return true, tr.info[k] or "" end,
  GetInputOutputLatency = function() return 0, 0 end,
  GetAudioDeviceInfo = function(k) if k == "SRATE" then return true, tostring(SR) end return false, "" end,
  StudioSync_DirectNow = function() return T end,
  GetProjectLength = function() return W.len end,
  TimeMap2_timeToBeats = function(_, t) return 0, math.floor(t / 2), 4 end, -- (2 s bars)
  TimeMap2_beatsToTime = function(_, beats, meas) return meas * 2 + beats * 0.5 end,
  GetProjectPathEx = function() return "P" end,
  PCM_Source_CreateFromFile = function(p) return { path = p } end,
  AddMediaItemToTrack = function(tr) local it = { tr = tr, info = { I_FIXEDLANE = 0 } }; tr.items[#tr.items + 1] = it; return it end,
  AddTakeToMediaItem = function(it) it.take = { info = {}, s = {}, it = it }; return it.take end,
  SetMediaItemInfo_Value = function(it, k, v) it.info[k] = v end,
  GetMediaItemInfo_Value = function(it, k) return it.info[k] or 0 end,
  SetMediaItemTakeInfo_Value = function(tk, k, v) tk.info[k] = v end,
  GetSetMediaItemTakeInfo_String = function(tk, k, v, set) if set then tk.s[k] = v end return true, tk.s[k] or "" end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end,
  ValidatePtr2 = function() return true end,
  CreateNewMIDIItemInProj = function(tr, a, z)
    local it = { tr = tr, info = { D_POSITION = a, D_LENGTH = z - a, I_FIXEDLANE = 0 }, evts = {} }
    it.take = { info = {}, s = {}, it = it }
    tr.items[#tr.items + 1] = it
    return it
  end,
  GetActiveTake = function(it) return it.take end,
  MIDI_GetPPQPosFromProjTime = function(tk, t) return (t - tk.it.info.D_POSITION) * 960 end, -- (960 ticks a second here)
  MIDI_InsertEvt = function(tk, _, _, ppq, msg) tk.it.evts[#tk.it.evts + 1] = { ppq = ppq, msg = msg }; return true end,
  MIDI_Sort = function(tk) tk.sorted = true end,
  -- REAPER's recent MIDI input: index 0 the newest (it latches), ts samples before now, pos the project position while playing (else -1)
  MIDI_GetRecentInputEvent = function(i)
    local e = W.hist[#W.hist - i]
    if not e then return 0 end
    return e.seq, e.buf, math.floor((e.at - T) * SR + 0.5), e.dev or 0, e.pos or -1, e.loop or 0
  end,
  StudioSync_KeepStart = function(spec) W.keep = { on = true, spec = spec, segs = {}, stamps = {}, frames = 0 }; W.started = T; return 1 end,
  StudioSync_KeepStop = function() if W.keep then W.keep.on = false end end,
  StudioSync_KeepStatus = function()
    local k = W.keep or { on = false, segs = {}, stamps = {}, frames = 0 }
    return require("band").json_encode({ on = k.on, state = k.on and "writing" or "done", srate = SR, frames = k.frames, files = 1, segs = k.segs, stamps = k.stamps })
  end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
band.log = function() end
band.set_take_source = function(tk, src) tk.src = src end
band.read_json = function() return {} end
band.session_path = function() return "S" end
package.loaded.sync = { authority = function() return function() return true end end }
package.loaded.groups = { takes_to_lanes = function() return false end }
package.loaded.mirror = { local_track = function() return false end, touch = function() end }
package.loaded.calibrate = { offset = function() return 0 end }
local live = true
package.loaded.liveaudio = { S = setmetatable({}, { __index = function(_, k) if k == "sending" then return live and {} or nil end end }) }
package.loaded.jam = { on = function() return false end }
local direct = require("direct")
direct.shared_now = function() return T end
direct.live_available = function() return true end
direct.peers = function() return { "bob:1" } end
direct.send_live = function() end
local double = require("double")

-- ---- the drift fit ----
local pts = {}
for s = 0, 300 do pts[#pts + 1] = { n = math.floor(s * 48000 * (1 + 20e-6) + 0.5), t = T0 + s + ((s % 3) - 1) * 0.002 } end -- (20 ppm fast, 2 ms jitter)
local r = double.fit(pts, 48000)
assert(near(r, 1 + 20e-6, 2e-6), "20 ppm fast: its play rate from the fit, through the jitter: " .. r)
assert(double.fit({ pts[1], pts[2], pts[3], pts[4] }, 48000) == 1, "under FIT_SPAN s: too little to go by")
assert(double.fit({ { n = 0, t = 0 }, { n = 48000 * 20, t = 10 }, { n = 48000 * 40, t = 20 } }, 48000) == 1, "twice the rate: a clock jump, not a crystal")
assert(double.fit({ { n = 0, t = 0 }, { n = 480000, t = 10 }, { n = 960000, t = 20 } }, 48000) == 1, "on time: 1")
assert(double.fit({ { n = 0, t = 0 }, { n = 480002, t = 10 }, { n = 960004, t = 20 } }, 48000) == 1, "4 ppm over 20 s moves the end 0.08 ms: left at 1")

-- ---- where a stretch lands: drift, play rates ----
local o = { sr = 1000, frames = 300015, rec = 0.025, inp = 0.012, anchor = { t = 5000, pos = 20 },
  stamps = { { n = 100005, t = 5100.012 }, { n = 200010, t = 5200.012 }, { n = 300015, t = 5300.012 } } }
local p = double.place({ { n0 = 0, t0 = 5000.012, playing = false } }, o)
assert(#p == 1 and near(p[1].rate, 1.00005, 2e-6) and near(p[1].len, 300, 2e-3) and near(p[1].pos, 20), "live, 50 ppm fast: its play rate from the stamps, its length in shared seconds")
local q = double.place({ { n0 = 0, t0 = 5000.012, playing = false } }, { sr = 1000, frames = 300015, rec = 0.025, inp = 0.012, anchor = { t = 5000, pos = 20 } })
assert(q[1].rate == 1 and near(q[1].len, 300.015), "without stamps (an older extension): as before")
p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = 8.05, rate = 2 } }, { sr = 1000, frames = 10000, rec = 0.025, inp = 0.012 })
assert(#p == 1 and near(p[1].rate, 0.5) and near(p[1].len, 20) and near(p[1].pos, 8.0) and p[1].offs == 0,
  "played at twice the speed: one item, play rate 0.5, 10 s of audio over 20 s of song, the latency taken off at the song's speed")
p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = 0.5, rate = 0.5 } }, { sr = 1000, frames = 4000, rec = 0, inp = 0 })
assert(#p == 1 and near(p[1].rate, 2) and near(p[1].len, 2) and near(p[1].pos, 0.5), "at half speed: play rate 2")
p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = -1, rate = 2 } }, { sr = 1000, frames = 4000, rec = 0, inp = 0 })
assert(#p == 1 and near(p[1].pos, 0) and near(p[1].offs, 0.5) and near(p[1].len, 7), "before the start, trimmed at the stretch's own speed (1 s of song is 0.5 s of audio)")
p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = 4, rate = 2 }, { n0 = 1000, t0 = 5001, playing = true, p0 = 6, rate = 2 } }, { sr = 1000, frames = 2000, rec = 0, inp = 0 })
assert(#p == 1 and near(p[1].len, 4), "split for nothing at the same rate: one item")

-- ---- the anchor: the furthest end ----
local ann = { t = 100, pos = 0, user = "Ann", past = true, endp = 0 }
local bob = { t = 105, pos = 14, user = "Bob", past = true, endp = 14 }
local cy = { t = 103, pos = 6, user = "Cy", past = true, endp = 6 }
local a1 = double.pick(double.pick(ann, bob), cy)
local a2 = double.pick(ann, double.pick(bob, cy))
local a3 = double.pick(double.pick(cy, ann), bob)
for _, a in ipairs({ a1, a2, a3 }) do assert(a.t == 100 and a.user == "Ann" and a.endp == 14 and double.anchor_pos(a) == 14, "Ann's start, Bob's end, in any order") end
local playing_start = { t = 99, pos = 30, user = "Dee" }
assert(double.anchor_pos(double.pick(a1, playing_start)) == 30, "the earliest started with the transport: its own song position")
local v = double.valid({ run = "Ann-1", user = "Ann", anchor = { t = 1.8e9, pos = 3, user = "Ann", past = true, endp = 14 } }, "Bob")
assert(v and v.anchor.past == true and v.anchor.endp == 14, "the message carries it")
assert(double.valid({ run = "Ann-1", user = "Ann", anchor = { t = 1.8e9, pos = 3, user = "Ann", endp = -1 } }, "Bob") == nil and
  double.valid({ run = "Ann-1", user = "Ann", anchor = { t = 1.8e9, pos = 3, user = "Ann", endp = "x" } }, "Bob") == nil, "a bad end: refused")
assert(double.valid({ run = "Ann-1", user = "Ann", anchor = { t = 1.8e9, pos = 3, user = "Ann" } }, "Bob").anchor.endp == nil, "an older computer's anchor: as before")

-- ---- MIDI ----
assert(double.midi_takes({ dev = 63, chan = 0 }, 5, 0x93) and double.midi_takes({ dev = 5, chan = 4 }, 0x10005, 0x93) and not double.midi_takes({ dev = 5, chan = 1 }, 5, 0x93) and
  not double.midi_takes({ dev = 4, chan = 0 }, 5, 0x90), "a track takes its device and channel (63, 0: any)")
local g = double.midi_place({
  { guid = "k", msg = "\144\60\100", playing = false, t = 103 }, { guid = "k", msg = "\128\60\0", playing = false, t = 103.5 },
  { guid = "k", msg = "\144\62\100", playing = true, pos = 8, loop = 0 }, { guid = "k", msg = "\128\62\0", playing = true, pos = 9, loop = 0 },
  { guid = "k", msg = "\144\64\100", playing = true, pos = 8.2, loop = 1 },
  { guid = "k", msg = "\144\65\100", playing = true, pos = 4, loop = 1 }, -- (played again from earlier)
  { guid = "k", msg = "\144\66\100", playing = false, t = 50 }, -- (before the project's start: dropped)
}, { t = 100, pos = 0, user = "Ann", past = true, endp = 20 })
assert(#g == 4, "a stretch each: live, played, the loop's next pass, played again from earlier: " .. #g)
assert(near(g[1].pos, 23) and near(g[1].len, 0.5 + double.MIDI_TAIL) and near(g[1].evts[2].at, 23.5), "live: the anchor's place plus the time since it")
assert(g[2].pos == 8 and g[2].evts[2].at == 9 and g[3].pos == 8.2 and g[4].pos == 4, "with the transport: REAPER's own position for each")

-- ---- runs with stand-ins ----
local function track(guid, name, input, mode) local t = { guid = guid, name = name, arm = 1, input = input, mode = mode or 0, info = {}, items = {} }; W.tracks[#W.tracks + 1] = t; return t end
local cfg, b = { user = "Ann", root = "R" }, { song = "Song", room = "main" }
local function tick(n) for _ = 1, n or 1 do T = T + 0.125; double.tick("P", cfg, b, true) end end
local function play_midi(buf, at, pos) W.seq = W.seq + 1; W.hist[#W.hist + 1] = { seq = W.seq, buf = buf, at = at, dev = 2, pos = pos } end
ext[band.SECTION .. "\0" .. double.KEY] = "1"
-- 1. MIDI only, live: the notes where they were played, past the project's end
local keys = track("gk", "Keys", 4096 + 63 * 32)
W.len = 10 -- (a bar past it: bar 8, 14 s)
play_midi("\144\59\90", T - 5) -- (before the copy: never in it)
tick()
local t_start = T
assert(W.keep == nil, "MIDI only: no audio capture")
play_midi("\144\60\100", t_start + 1.0)
play_midi("\176\64\127", t_start + 1.2) -- (the sustain pedal: kept too)
play_midi("\128\60\0", t_start + 1.5)
T = t_start + 1.6
tick()
play_midi("\248", t_start + 1.7) -- (MIDI clock: not a channel message, not kept)
tick()
live = false
tick()
assert(#keys.items == 1, "one MIDI item when the jam stops")
local it = keys.items[1]
assert(near(it.info.D_POSITION, 15, 1e-5) and near(it.info.D_LENGTH, 0.5 + double.MIDI_TAIL, 1e-5), "a bar past the song (14 s) plus 1 s in: " .. it.info.D_POSITION)
assert(#it.evts == 3 and it.evts[1].msg == "\144\60\100" and it.evts[2].msg == "\176\64\127" and near(it.evts[2].ppq, 0.2 * 960, 0.01) and near(it.evts[3].ppq, 480, 0.01) and it.take.sorted,
  "each event at its place, the pedal too, nothing from before the copy, no clock")
assert(it.take.s.P_NAME:find("%(full quality%)$"), "named as the others")
local st = band.json_decode(ext[band.SECTION .. "\0" .. double.STATE])
assert(st.state == "done" and st.text:find("1 part added, lined up %(yours: Keys%)"), "said: " .. tostring(st.text))
keys.arm = 0
-- 2. the transport at twice the speed: one item, play rate 0.5, the pitch kept
local gtr = track("gg", "Gtr", 0)
live = true
W.playing, W.pos = true, 4
tick()
assert(W.keep and W.keep.on, "the audio capture runs")
W.keep.segs, W.keep.frames = { { 0, 0, W.started, 1, 4.0, 2.0 } }, 5 * SR
tick()
W.playing = false
tick()
assert(#gtr.items == 1, "one item, not one a block")
it = gtr.items[1]
assert(near(it.info.D_POSITION, 4) and near(it.info.D_LENGTH, 10) and near(it.take.info.D_PLAYRATE, 0.5) and it.take.info.B_PPITCH == 1, "5 s played over 10 s of song: play rate 0.5, pitch kept")
-- 3. five minutes live, an interface 50 ppm fast: the stamps' fit sets its play rate
gtr.items = {}
W.len = 0
W.keep = nil
tick()
local s0 = W.started
local fast = 1 + 50e-6
local stamps = {}
for s = 0, 300 do stamps[#stamps + 1] = { s, math.floor(s * SR * fast + 0.5), s0 + s } end
W.keep.segs, W.keep.stamps, W.keep.frames = { { 0, 0, s0, 0, 0, 1 } }, stamps, math.floor(300 * SR * fast)
tick()
live = false
tick()
assert(#gtr.items == 1, "one item")
it = gtr.items[1]
assert(near(it.take.info.D_PLAYRATE, fast, 2e-6) and not it.take.info.B_PPITCH, "its play rate from the fit (a drift's: no pitch processing)")
local function landed_at(n) return it.info.D_POSITION + (n / SR - (it.take.info.D_STARTOFFS or 0)) / it.take.info.D_PLAYRATE end
local first = landed_at(0)
for _, s in ipairs({ 60, 150, 299 }) do
  local n = math.floor(s * SR * fast + 0.5)
  assert(near(landed_at(n) - first, n / (SR * fast), 1e-4), string.format("at %d s: %.6f, within 0.1 ms of where it was played (15 ms off by the end before)", s, landed_at(n) - first)) -- (frame n was played n / (SR * fast) s in)
end
print("ok double2: drift fit, play rates, the furthest end, MIDI tracks")
