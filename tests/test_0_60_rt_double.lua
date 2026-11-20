-- Keep a full-quality copy, the double-ender (lib/double.lua, docs/rt/rt-double.md; roadmap "More big ideas" 7). The pure parts: which
-- armed tracks are copied, the extension's spec, where each stretch lands (by the song's bars with the transport, by the shared clock without,
-- each computer's latency and REAPER's input offset taken off, before the start trimmed, a dropped block's gap kept), the jam's anchor, the
-- message checked, the words. Then whole jams with stand-ins for REAPER, the extension and the link, each computer its own copy of the module:
-- three playing live with clocks hundreds of seconds apart and different latencies, one dropping off mid-jam (its part up to then lands on its
-- own, the others' projects untouched), a new file mid-jam, and every clap lined up afterwards; then three jamming with the transport (Jam),
-- one looping over a take already there (a new lane that doesn't play), "3 parts added, lined up", and nothing in any project mid-jam.
package.path = "lib/?.lua;" .. package.path
local E = 1.8e9 -- (seconds since 1970, as the shared clock reads)
local T = E + 1000.0 -- the studio's shared clock (and every computer's time_precise)
local worlds, cur = {}, nil
local function W() return worlds[cur] end
local SR = 1000 -- (sample rate: a frame is a millisecond)
local function songpos(w, t) return w.song.pos + (t - w.song.at) end
local function inp_s(w) return (w.lat[1] + w.manual) / SR end
local function rec_s(w) return (w.lat[1] + w.lat[2] + w.manual) / SR end
local function seg_now(w) -- (the extension's audio thread: a new stretch, stamped with this computer's link clock as the hook is called)
  local k = w.keep
  k.segs[#k.segs + 1] = { #k.segs, math.floor((T - k.start) * SR + 0.5), T + inp_s(w) + w.skew, w.playing and 1 or 0, w.playing and (songpos(w, T) + rec_s(w)) or 0 }
end
local function frames(w) local k = w.keep; return k.on and math.floor((T - k.start) * SR + 0.5) or k.frames end
reaper = setmetatable({
  time_precise = function() return T end,
  GetOS = function() return "Win64" end,
  GetExePath = function() return "C:/REAPER" end,
  GetExtState = function(s, k) return W().ext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) W().ext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) W().ext[s .. "\0" .. k] = nil end,
  GetProjExtState = function() return 1, "" end,
  GetPlayStateEx = function() return W().playing and 1 or 0 end,
  CountTracks = function() return #W().tracks end,
  GetTrack = function(_, i) return W().tracks[i + 1] end,
  GetTrackGUID = function(tr) return tr.guid end,
  GetTrackName = function(tr) return true, tr.name end,
  GetMediaTrackInfo_Value = function(tr, k)
    if k == "I_RECARM" then return tr.arm elseif k == "I_RECINPUT" then return tr.input elseif k == "I_RECMODE" then return tr.mode end
    return tr.info[k] or 0
  end,
  SetMediaTrackInfo_Value = function(tr, k, v) tr.info[k] = v end,
  GetSetMediaTrackInfo_String = function(tr, k, v, set) if set then tr.info[k] = v end return true, tr.info[k] or "" end,
  GetInputOutputLatency = function() return W().lat[1], W().lat[2] end,
  StudioSync_DirectNow = function() return T + W().skew end,
  GetProjectLength = function() return W().len end,
  TimeMap2_timeToBeats = function(_, t) return 0, math.floor(t / 2), 4 end, -- (2 s bars)
  TimeMap2_beatsToTime = function(_, beats, meas) return meas * 2 + beats * 0.5 end,
  GetProjectPathEx = function() return "P/" .. W().name end,
  PCM_Source_CreateFromFile = function(p) return { path = p } end,
  AddMediaItemToTrack = function(tr) local it = { tr = tr, info = { I_FIXEDLANE = 0 } }; tr.items[#tr.items + 1] = it; W().added = W().added + 1; return it end,
  AddTakeToMediaItem = function(it) it.take = { info = {}, s = {} }; return it.take end,
  SetMediaItemInfo_Value = function(it, k, v) it.info[k] = v end,
  GetMediaItemInfo_Value = function(it, k) return it.info[k] or 0 end,
  SetMediaItemTakeInfo_Value = function(tk, k, v) tk.info[k] = v end,
  GetSetMediaItemTakeInfo_String = function(tk, k, v, set) if set then tk.s[k] = v end return true, tk.s[k] or "" end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end,
  ValidatePtr2 = function() return true end,
  -- the extension (extension/direct_audio.cpp's StudioSync_Keep*), driven by the shared clock
  StudioSync_KeepStart = function(spec)
    local w = W()
    if w.keep and w.keep.on then return 0 end
    local files = {}
    for chs, path in spec:gmatch("([^\t\n]+)\t([^\n]+)\n") do files[#files + 1] = { chs = chs, path = path }; w.file_start[path] = T end
    w.keep = { on = true, state = "writing", start = T, files = files, segs = {}, frames = 0 }
    w.specs[#w.specs + 1] = spec
    seg_now(w)
    return 1
  end,
  StudioSync_KeepStop = function() local w = W(); if w.keep and w.keep.on then w.keep.frames = frames(w); w.keep.on, w.keep.state = false, "done" end end,
  StudioSync_KeepStatus = function()
    local w = W()
    local k = w.keep or { on = false, state = "none", segs = {}, frames = 0 }
    return require("band").json_encode({ on = k.on, state = k.state, srate = SR, frames = w.keep and frames(w) or 0, files = #(k.files or {}), segs = k.segs })
  end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
local logs = {}
band.log = function(s) logs[#logs + 1] = (cur or "") .. ": " .. s end
band.set_take_source = function(tk, src) tk.src = src end
band.read_json = function() return {} end
band.session_path = function() return "S" end
local lanes_on = true
package.loaded.sync = { authority = function() return function(_, name) return name ~= "Locked" end end }
package.loaded.groups = { takes_to_lanes = function() return lanes_on end }
local touched = {}
package.loaded.mirror = { local_track = function(tr) return tr.loc == true end, touch = function(_, tr) touched[tr] = true end }
package.loaded.calibrate = { offset = function() return W().manual end }
package.loaded.liveaudio = { S = setmetatable({}, { __index = function(_, k) if k == "sending" then return W().live and {} or nil end end }) }
package.loaded.jam = { on = function() return W().jam == true end }
local direct = require("direct")
local queue = {}
direct.shared_now = function() return T end
direct.live_available = function() return true end
direct.peers = function() return W().peers end
direct.send_live = function(_, kind, d, _, _, id, to) queue[#queue + 1] = { from = cur, kind = kind, d = band.json_encode(d), id = id, to = to } end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end
local function load_double() package.loaded.double = nil; return require("double") end
local double = load_double()

-- ---- which tracks are copied ----
local list, skipped = double.inputs({
  { guid = "a", name = "Gtr", arm = 1, input = 1024 + 2, mode = 0 },   -- stereo 3/4
  { guid = "b", name = "Vox", arm = 1, input = 0, mode = 0 },          -- mono 1
  { guid = "c", name = "Keys", arm = 1, input = 4096 + 63 * 32, mode = 0 }, -- MIDI
  { guid = "d", name = "Synth", arm = 1, input = 1, mode = 1 },        -- its output
  { guid = "e", name = "Loop", arm = 1, input = 512, mode = 0 },       -- ReaRoute
  { guid = "f", name = "Multi", arm = 1, input = 2048, mode = 0 },     -- multichannel
  { guid = "g", name = "Off", arm = 0, input = 0, mode = 0 },          -- not armed
  { guid = "h", name = "Mono", arm = 1, input = 5, mode = 12 },        -- forced mono
})
assert(#list == 3 and list[1].ch[1] == 2 and list[1].ch[2] == 3 and #list[2].ch == 1 and list[2].ch[1] == 0 and list[3].ch[1] == 5, "stereo as its pair, mono as its input")
assert(#skipped == 4 and skipped[1].name == "Keys" and skipped[1].why:find("MIDI") and skipped[2].name == "Synth" and skipped[3].why:find("ReaRoute") and skipped[4].why:find("multichannel"), "what isn't copied, and why")
local lots = {}
for i = 1, 20 do lots[i] = { guid = tostring(i), name = "T" .. i, arm = 1, input = 1024, mode = 0 } end
local l2, s2 = double.inputs(lots)
assert(#l2 == 16 and #s2 == 4, "at most 16 tracks in one copy")
assert(double.spec(list, { "a.wav", "b.wav", "c.wav" }) == "2,3\ta.wav\n0\tb.wav\n5\tc.wav\n", "the extension's spec")
assert(double.spec(list, { "a.wav", "b\tx.wav", "c.wav" }) == nil and double.spec({}, {}) == nil, "a path that can't go in it: nothing")
assert(double.inputs_key(list) ~= double.inputs_key({ list[1], list[2] }), "another set of inputs: another key")

-- ---- where a stretch lands ----
local o = { sr = 1000, frames = 10000, rec = 0.025, inp = 0.012, anchor = { t = 5000, pos = 20 } }
local p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = 8.025 } }, o)
assert(#p == 1 and near(p[1].pos, 8) and p[1].offs == 0 and near(p[1].len, 10), "with the transport: its song position less input + output latency and the offset")
p = double.place({ { n0 = 0, t0 = 5003.012, playing = false } }, o)
assert(#p == 1 and near(p[1].pos, 23), "without: the anchor's position plus the time since it, less the input latency")
p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = 2.025 }, { n0 = 4000, t0 = 5004, playing = true, p0 = 0.025 } }, o)
assert(#p == 2 and near(p[1].pos, 2) and near(p[1].len, 4) and near(p[2].pos, 0) and near(p[2].offs, 4) and near(p[2].len, 6), "a loop back: each pass at its own bars")
p = double.place({ { n0 = 0, t0 = 4999.012, playing = false } }, { sr = 1000, frames = 3000, rec = 0, inp = 0.012, anchor = { t = 5000, pos = 0.5 } })
assert(#p == 1 and near(p[1].pos, 0) and near(p[1].offs, 0.5) and near(p[1].len, 2.5), "nothing before the project's start: the front is trimmed")
p = double.place({ { n0 = 0, t0 = 5000.012, playing = false }, { n0 = 2000, t0 = 5002.512, playing = false } }, o)
assert(#p == 2 and near(p[1].len, 2) and near(p[2].pos, 22.5) and near(p[2].offs, 2), "a dropped block: the rest where it was played, the gap kept")
p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = 8.025 }, { n0 = 3000, t0 = 5003, playing = true, p0 = 11.025 } }, o)
assert(#p == 1 and near(p[1].len, 10), "a stretch split for nothing: one item")
p = double.place({ { n0 = 0, t0 = 5000, playing = true, p0 = 8.025 }, { n0 = 9980, t0 = 5009.98, playing = false } }, o)
assert(#p == 1, "a stretch shorter than 50 ms: not placed")
assert(#double.place({ { n0 = 0, t0 = 1, playing = false } }, { sr = 1000, frames = 100, rec = 0, inp = 0 }) == 0, "no anchor, no transport: nowhere to go")
-- the stop's moment at the end of a jam with the transport: left out
local cs, cf = double.cut_tail({ { n0 = 0, playing = true }, { n0 = 5000, playing = false } }, 5100)
assert(#cs == 1 and cf == 5000, "a stop's tail: not placed")
cs, cf = double.cut_tail({ { n0 = 0, playing = false }, { n0 = 5000, playing = true } }, 5100)
assert(#cs == 2 and cf == 5100, "live, then the transport: all of it")
-- the jam's anchor
local a1, a2, a3 = { t = 10, pos = 0, user = "Bob" }, { t = 9, pos = 4, user = "Cy" }, { t = 9, pos = 8, user = "Ann" }
assert(double.pick(nil, a1) == a1 and double.pick(a1, nil) == a1 and double.pick(a1, a2) == a2 and double.pick(a2, a1) == a2, "the earliest start")
assert(double.pick(a2, a3) == a3 and double.pick(a3, a2) == a3, "the same moment: by name, so everyone picks the same")
-- when it records
assert(double.wanted(false, true, true, 1, true, false, false, true) == false, "off: never")
assert(select(2, double.wanted(true, false, true, 1, true, false, false, true)):find("newer StudioSync extension"), "an older extension: says so")
assert(select(2, double.wanted(true, true, true, 0, true, false, false, true)):find("arm a track"), "nothing armed")
assert(select(2, double.wanted(true, true, true, 1, false, false, false, true)):find("nobody"), "nobody here")
assert(double.wanted(true, true, true, 1, true, true, true, false) == true and double.wanted(true, true, true, 1, true, true, false, true) == false, "Jam: from play to stop")
assert(double.wanted(true, true, true, 1, true, false, false, true) == true and double.wanted(true, true, true, 1, true, false, true, false) == false, "otherwise: while live audio runs, transport or not")
assert(double.wanted(true, true, false, 1, true, false, false, true) == false, "the song's tab in front")
-- the message
local m = { run = "Ann-20261120-120000Z-001", user = "Ann", anchor = { t = 1.8e9, pos = 12.5, user = "Ann" }, tracks = { "Gtr" } }
local v = double.valid(m, "Bob")
assert(v and v.anchor.t == 1.8e9 and v.anchor.pos == 12.5 and v.tracks[1] == "Gtr" and not v.done, "a good one")
assert(double.valid({ run = m.run, user = "Ann", done = true, parts = 2, tracks = { "Gtr", "Vox" } }, "Bob").parts == 2, "done, with how many")
for _, bad in ipairs({ { run = "../x" }, { user = "Bob" }, { user = "a/b" }, { anchor = { t = 1.8e9, pos = -1, user = "Ann" } }, { anchor = { t = 0 / 0, pos = 1, user = "Ann" } },
  { anchor = { t = 5, pos = 1, user = "Ann" } }, { anchor = "x" }, { tracks = "x" }, { tracks = { 1 } }, { parts = 1.5 }, { parts = -1 } }) do
  local t = {}
  for k, x in pairs(m) do t[k] = x end
  for k, x in pairs(bad) do t[k] = x end
  assert(double.valid(t, "Bob") == nil, "refused: " .. next(bad))
end
local many = {}
for i = 1, 17 do many[i] = "T" .. i end
assert(double.valid({ run = m.run, user = "Ann", tracks = many }, "Bob") == nil, "at most 16 tracks")
-- the words
assert(double.running_text({ "Gtr", "Vox" }, 192.7, { "Ann", "Bob" }) == "Recording your part in full quality (Gtr, Vox) · 3:12 · Ann and Bob too", "while it runs")
assert(double.summary({ { user = "Me", tracks = { "Gtr" }, mine = true }, { user = "Ann", tracks = { "Vox" } }, { user = "Bob", tracks = { "Bass" } } }) ==
  "3 parts added, lined up (yours: Gtr; Ann: Vox; Bob: Bass)", "afterwards")
assert(double.summary({ { user = "Me", tracks = {}, mine = true } }, { "Locked isn't yours to change here" }):find("^No full%-quality part added; not added: Locked"), "nothing, and why")
assert(double.summary({ { user = "Me", tracks = { "Gtr" }, mine = true } }, nil, true):find("by this computer's clock"), "without the shared clock: says so")

-- ---- whole jams, stand-ins for REAPER, the extension and the link ----
local function track(guid, name, input, extra)
  local t = { guid = guid, name = name, arm = 1, input = input, mode = 0, info = {}, items = {} }
  for k, x in pairs(extra or {}) do t[k] = x end
  return t
end
local function world(name, o2)
  local w = { name = name, ext = { [band.SECTION .. "\0" .. double.KEY] = "1" }, tracks = o2.tracks, lat = o2.lat, manual = o2.manual or 0, skew = o2.skew or 0,
    len = o2.len or 0, peers = o2.peers, playing = false, song = { at = 0, pos = 0 }, live = false, jam = o2.jam, added = 0, specs = {}, file_start = {} }
  worlds[name] = w
  return w
end
local inst, cfgs, linked = {}, {}, {}
local function deliver()
  while #queue > 0 do
    local q = table.remove(queue, 1)
    for _, to in ipairs(q.to or {}) do
      if inst[to] and linked[q.from .. ">" .. to] ~= false then
        local was = cur
        cur = to
        inst[to].on_msg(cfgs[to], { song = "Song", room = "main" }, band.json_decode(q.d))
        cur = was
      end
    end
  end
end
local function step(secs, every)
  local stop_at = T + secs
  while T < stop_at - 1e-9 do
    T = T + 0.125
    for name, d in pairs(inst) do
      cur = name
      if every then every(name) end
      d.tick(name, cfgs[name], { song = "Song", room = "main" }, true)
    end
    deliver()
  end
end
-- Where a moment (shared clock) of a computer's own recording landed in its project: { pos, lane } of every item holding it.
local function landed(w, trname, t)
  local out = {}
  for _, tr in ipairs(w.tracks) do
    if tr.name == trname then
      for _, it in ipairs(tr.items) do
        local start = it.take and it.take.src and w.file_start[it.take.src.path]
        if start then
          local f = t - start
          local offs, len = it.take.info.D_STARTOFFS or 0, it.info.D_LENGTH
          if f >= offs - 1e-9 and f <= offs + len + 1e-9 then out[#out + 1] = { pos = it.info.D_POSITION + f - offs, lane = it.info.I_FIXEDLANE, item = it } end
        end
      end
    end
  end
  return out
end
local function state(name) return band.json_decode(worlds[name].ext[band.SECTION .. "\0" .. double.STATE] or "") or {} end

-- 1. Live (no transport): Ann, Bob and Cy, clocks far apart, different latencies and offsets; Cy drops off the link mid-jam.
local ann = world("Ann", { tracks = { track("ga", "Gtr", 1024), track("ka", "Keys", 4096 + 2016) }, lat = { 10, 10 }, peers = { "Bob", "Cy" } })
local bob = world("Bob", { tracks = { track("gb", "Bass", 2) }, lat = { 30, 20 }, manual = 5, skew = 322, len = 10, peers = { "Ann", "Cy" } })
local cy = world("Cy", { tracks = { track("gc", "Vox", 0) }, lat = { 5, 5 }, manual = -2, skew = -5.5, peers = { "Ann", "Bob" } })
for _, n in ipairs({ "Ann", "Bob", "Cy" }) do inst[n] = load_double(); cfgs[n] = { user = n, root = "R" } end
inst.Ann.FILE_BYTES = 4 * 2 * SR * 6 -- (a new file every 6 s of Ann's stereo guitar: the same jam goes on in new files)
ann.live = true
step(1.5, function(n) if n == "Cy" and T >= E + 1001.5 then cy.live = true end end)
step(2, function(n) if n == "Bob" and T >= E + 1003.25 then bob.live = true end end)
cur = "Ann"
assert(state("Ann").state == "recording" and state("Ann").text:find("^Recording your part in full quality %(Gtr%)"), "Ann: recording, and says so")
assert(state("Ann").skipped and state("Ann").skipped[1]:find("^Keys records MIDI"), "Ann's MIDI track: not copied, and says so")
assert(ann.specs[1]:match("^0,1\tP/Ann/StudioSync full quality/Song %- Gtr %- Ann .+%.wav\n$"), "Ann's stereo guitar: inputs 1-2, in the project's own folder")
assert(cy.keep.on and bob.keep.on, "Bob and Cy record too")
step(16.5) -- (to T = 1020)
assert(#ann.specs >= 3, "Ann's long take went on in new files")
for _, w in pairs(worlds) do assert(w.added == 0, w.name .. ": nothing in the project mid-jam") end
-- Cy's network goes: the link carries nothing either way, and Cy has nobody
linked["Cy>Ann"], linked["Cy>Bob"], linked["Ann>Cy"], linked["Bob>Cy"] = false, false, false, false
cy.peers, ann.peers, bob.peers = {}, { "Bob" }, { "Ann" }
step(9.5)
assert(cy.added == 0, "Cy: not yet (a blip isn't the end)")
step(1)
assert(cy.added == 1 and not cy.keep.on, "Cy, alone for 10 s: its part lands, on its own computer")
assert(ann.added == 0 and bob.added == 0, "Ann's and Bob's projects: still nothing mid-jam")
local cyl = landed(cy, "Vox", E + 1019.9)
assert(#cyl == 1, "Cy's part reaches past the drop")
step(10)
ann.live, bob.live = false, false -- (the jam ends: live audio off)
step(0.5)
assert(ann.added >= 1 and bob.added == 1, "Ann and Bob: their parts land when the jam stops")
-- a clap at 1010 on the shared clock, heard by all three mics: the same place in every project
local la_, lb_, lc_ = landed(ann, "Gtr", E + 1010), landed(bob, "Bass", E + 1010), landed(cy, "Vox", E + 1010)
assert(#la_ == 1 and #lb_ == 1 and #lc_ == 1, "each holds the clap once")
assert(near(la_[1].pos, lb_[1].pos, 1e-3) and near(la_[1].pos, lc_[1].pos, 1e-3), string.format("lined up: %.4f %.4f %.4f", la_[1].pos, lb_[1].pos, lc_[1].pos))
assert(near(la_[1].pos, 1010 - 1000.125, 1e-3), "from Ann's start, the earliest (Bob's own start would have gone after his project's end)")
local la2 = landed(ann, "Gtr", E + 1016.5)
assert(#la2 == 1 and near(la2[1].pos, 1016.5 - 1000.125, 1e-3), "Ann's later files follow on exactly")
for _, w in pairs(worlds) do
  for _, tr in ipairs(w.tracks) do for _, it in ipairs(tr.items) do
    assert(it.take.s.P_NAME:find("^Jam %d%d:%d%d %- " .. w.name .. " %(full quality%)$") and it.info.B_LOOPSRC == 0, "named, never looped")
    assert(touched[tr], "the look is told: it goes out as any new item does")
  end end
end
cur = "Ann"
local sa = state("Ann")
assert(sa.state == "done" and sa.text == "2 parts added, lined up (yours: Gtr; Bob: Bass)", "Ann's summary, with Bob's part: " .. tostring(sa.text))
cur = "Cy"
assert(state("Cy").text == "1 part added, lined up (yours: Vox)", "Cy's own: " .. tostring(state("Cy").text))

-- 2. Jam (the transport): three players from bar 3, latencies and clocks apart; Cy loops back over a take of theirs already there.
worlds, inst, cfgs, linked, queue, touched = {}, {}, {}, {}, {}, {}
T = E + 2000.0
ann = world("Ann", { tracks = { track("ga", "Gtr", 0) }, lat = { 10, 10 }, peers = { "Bob", "Cy" }, jam = true })
bob = world("Bob", { tracks = { track("gb", "Bass", 1) }, lat = { 30, 20 }, manual = 5, skew = 322, peers = { "Ann", "Cy" }, jam = true })
cy = world("Cy", { tracks = { track("gc", "Vox", 1024 + 4) }, lat = { 64, 64 }, skew = -77, peers = { "Ann", "Bob" }, jam = true })
local old = { tr = cy.tracks[1], info = { D_POSITION = 4, D_LENGTH = 2, I_FIXEDLANE = 0 }, take = { info = {}, s = {} } }
cy.tracks[1].items[1] = old
for _, n in ipairs({ "Ann", "Bob", "Cy" }) do inst[n] = load_double(); cfgs[n] = { user = n, root = "R" } end
step(1)
for _, w in pairs(worlds) do assert(not w.keep, w.name .. ": Jam, stopped: nothing recorded") end
local function play(w, pos) w.playing, w.song = true, { at = T, pos = pos }; if w.keep and w.keep.on then seg_now(w) end end
local function stop(w) w.playing = false; if w.keep and w.keep.on then seg_now(w) end end
local function seek(w, pos) w.song = { at = T, pos = pos }; if w.keep and w.keep.on then seg_now(w) end end
play(ann, 4); step(0.125); play(cy, 4); step(0.125); play(bob, 4) -- (Play together: each starts a hair apart, each on its own bar 3)
local starts = { Ann = T - 0.25, Cy = T - 0.125, Bob = T }
step(8 - 0.125, function(n) if n == "Cy" and cy.playing and songpos(cy, T) >= 12 - 1e-9 and not cy.looped then cy.looped = true; seek(cy, 4) end end)
for _, w in pairs(worlds) do assert(w.added == 0, w.name .. ": nothing in the project mid-jam") end
assert(state("Ann").state == "recording", "Ann: recording")
step(3)
stop(ann); stop(bob); stop(cy)
step(1)
for _, w in pairs(worlds) do assert(w.added >= 1, w.name .. ": landed at the stop") end
-- what each played at bar 4 (song time 6.0): at 6.0 in every project, whoever's latency
local function at_song(w, who, trname, s, pass)
  local t = starts[who] + (s - 4) + (pass or 0)
  return landed(w, trname, t)
end
local ja, jb, jc = at_song(ann, "Ann", "Gtr", 6), at_song(bob, "Bob", "Bass", 6), at_song(cy, "Cy", "Vox", 6)
assert(#ja == 1 and #jb == 1 and #jc == 1 and near(ja[1].pos, 6, 1e-3) and near(jb[1].pos, 6, 1e-3) and near(jc[1].pos, 6, 1e-3),
  string.format("on the bars they played to: %.4f %.4f %.4f", ja[1] and ja[1].pos or -1, jb[1] and jb[1].pos or -1, jc[1] and jc[1].pos or -1))
local jc2 = at_song(cy, "Cy", "Vox", 6, 8) -- (Cy's second pass, after the loop back)
assert(#jc2 == 1 and near(jc2[1].pos, 6, 1e-3), "Cy's second pass: at its bars too")
assert(jc[1].lane ~= 0 and jc2[1].lane ~= 0 and jc[1].lane ~= jc2[1].lane, "over a take already there, and over each other: lanes of their own")
local vtr = cy.tracks[1]
assert(vtr.info.I_FREEMODE == 2 and vtr.info["C_LANEPLAYS:" .. jc[1].lane] == 0 and vtr.info["P_LANENAME:" .. jc[1].lane]:find("^Jam "), "fixed lanes; the new ones don't play (the comp stays)")
assert(old.info.I_FIXEDLANE == 0, "the take already there stays where it was")
cur = "Ann"
assert(state("Ann").text == "3 parts added, lined up (yours: Gtr; Bob: Bass; Cy: Vox)", "Ann's summary: " .. tostring(state("Ann").text))
cur = "Bob"
assert(state("Bob").text == "3 parts added, lined up (yours: Bass; Ann: Gtr; Cy: Vox)", "Bob's: " .. tostring(state("Bob").text))
-- with "Takes become lanes" off: beside what's there, as REAPER would
worlds, inst, cfgs, queue = {}, {}, {}, {}
lanes_on = false
T = E + 3000.0
local dee = world("Dee", { tracks = { track("gd", "Gtr", 0), track("ld", "Locked", 1) }, lat = { 10, 10 }, peers = { "Eve" }, jam = true })
dee.tracks[1].items[1] = { tr = dee.tracks[1], info = { D_POSITION = 0, D_LENGTH = 100, I_FIXEDLANE = 0 }, take = { info = {}, s = {} } }
inst.Dee, cfgs.Dee = load_double(), { user = "Dee", root = "R" }
play(dee, 0)
step(2)
stop(dee)
step(0.5)
assert(dee.added == 1 and dee.tracks[1].info.I_FREEMODE == nil and dee.tracks[1].items[2].info.I_FIXEDLANE == 0, "lanes off: an item beside the one there, no lanes")
cur = "Dee"
assert(state("Dee").text:find("^1 part added, lined up %(yours: Gtr%); not added: Locked isn't yours to change here"), "a track not yours: not added, and why: " .. tostring(state("Dee").text))
-- the panel's "add it now" ends a live run at once
worlds, inst, cfgs, queue = {}, {}, {}, {}
T = E + 4000.0
local fay = world("Fay", { tracks = { track("gf", "Gtr", 0) }, lat = { 10, 10 }, peers = { "Gus" } })
inst.Fay, cfgs.Fay = load_double(), { user = "Fay", root = "R" }
fay.live = true
step(2)
assert(fay.keep.on and fay.added == 0, "recording")
fay.ext[band.SECTION .. "\0" .. inst.Fay.CMD] = "1"
step(0.125)
assert(fay.added == 1 and not fay.keep.on and fay.ext[band.SECTION .. "\0" .. inst.Fay.CMD] == nil, "Add it now: it lands, the ask cleared")
step(0.5)
assert(fay.keep.on, "and a new copy starts while live audio runs")
cur = "Fay"
inst.Fay.on_exit("Fay", cfgs.Fay, { song = "Song", room = "main" })
assert(fay.added == 2 and not fay.keep.on and fay.ext[band.SECTION .. "\0" .. inst.Fay.STATE] == nil, "Live sync ending: what's there lands, the state goes")
print("ok")
