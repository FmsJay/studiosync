-- The Ableton Link bridge (James, rt; lib/ablink.lua): phase math against the shared clock, echo suppression, the leader, what a Link app's
-- tempo change may do to the song, Health's line; then two studio computers in different places, each with its own Link session and a fake
-- ReaBlink, bridged over a simulated direct link: phases line up on the bar, a tempo from the network never comes back, the newest change leads.
package.path = "lib/?.lua;" .. package.path
package.loaded.band = { SECTION = "StudioSync", log = function() end }
reaper = { APIExists = function() return true end }
local ablink = require("ablink")
local function near(a, b, e) return math.abs(a - b) < (e or 1e-9) end

-- ---- 1. phase math ----------------------------------------------------------------------------------------------------------------------
assert(near(ablink.phase_error(5.25, 1.0, 4), 0.25), "a quarter beat ahead")
assert(near(ablink.phase_error(4.9, 1.0, 4), -0.1), "just behind, across the bar line")
assert(near(ablink.phase_error(3.0, 1.0, 4), 2.0) and near(ablink.phase_error(-1.0, 1.0, 4), 2.0), "half a bar is +q/2")
assert(near(ablink.phase_error(-7.75, 0.25, 4), 0), "negative beats wrap too")
assert(ablink.fix(8.005, 0, 4, 120) == nil, "5 ms off is within tolerance")
local to = ablink.fix(9.3, 0.5, 4, 120)
assert(to and near(ablink.phase_error(to, 0.5, 4), 0) and math.abs(to - 9.3) <= 2, "the fix lines the phase up and keeps the beat count near")
assert(near(ablink.beat_at({ beat = 10, at = 100, bpm = 120 }, 101.5), 13), "1.5 s at 120 BPM is 3 beats on")

-- ---- 2. echo suppression ----------------------------------------------------------------------------------------------------------------
local tr = {}
assert(ablink.seen(tr, 120, 0) == false, "the first look is nobody's change")
assert(ablink.seen(tr, 120, 0.1) == false, "no change")
ablink.set(tr, 125, 0.2)
assert(ablink.seen(tr, 120, 0.3) == false, "Link not showing ours yet")
assert(ablink.seen(tr, 125, 0.4) == false, "ours arriving isn't a change by anyone here")
local ch, before = ablink.seen(tr, 128, 0.5)
assert(ch == true and before == 125, "a Link app's change, and what it was")
ablink.set(tr, 130, 1); ablink.set(tr, 131, 1.1)
assert(ablink.seen(tr, 130, 1.2) == false and ablink.seen(tr, 131, 1.3) == false, "a ramp: Link a push behind is still ours")
ablink.set(tr, 140, 2)
ch = ablink.seen(tr, 140, 2 + ablink.SETTLE + 0.1)
assert(ch == true, "ours long after it was set: someone set it again, not us")

-- ---- 3. the leader ----------------------------------------------------------------------------------------------------------------------
local c = { a = { user = "James", heard = 9 }, b = { user = "Mac", mine = true }, c = { user = "Bo", heard = 9 } }
assert(ablink.leader(c, "Mac", 10) == "b", "nobody changed anything: the driver's computer")
assert(ablink.leader(c, "Zed", 10) == "a", "the driver has no Link here: the lowest device id")
c.c.stamp = 500
assert(ablink.leader(c, "Mac", 10) == "c", "whoever changed last leads")
c.a.stamp = 501
assert(ablink.leader(c, "Mac", 10) == "a", "a newer change takes over")
c.c.heard = 10 + ablink.STALE - 1
assert(ablink.leader(c, "Mac", 10 + ablink.STALE) == "c", "gone quiet: out of the bridge")
c.b.stamp = 400
assert(ablink.leader(c, "Mac", 1000) == "b", "everyone else gone: this computer, whatever its stamp")

-- ---- 4. messages, the song's tempo, Health ----------------------------------------------------------------------------------------------
local good = { dev = "D", user = "Mac", bpm = 120, beat = 3.5, at = 1e9, q = 4, playing = true, stamp = 1e9 }
assert(ablink.valid(good))
for k, v in pairs({ bpm = 0 / 0, q = 0, playing = "yes", at = math.huge, dev = 5, stamp = "x", bpm2 = nil }) do
  local d = {}
  for kk, vv in pairs(good) do d[kk] = vv end
  d[k] = v
  if k ~= "bpm2" then assert(not ablink.valid(d), "refused: bad " .. k) end
end
assert(not ablink.valid("x") and not ablink.valid({}))
assert(ablink.may_tempo(true, 1, false) == true)
local ok, why = ablink.may_tempo(true, 1, true)
assert(not ok and why:find("recording"), "never mid-take")
ok, why = ablink.may_tempo(false, 1, false)
assert(not ok and why:find("driver"), "not yours to change")
ok, why = ablink.may_tempo(true, 3, false)
assert(not ok and why:find("tempo changes"), "a song with tempo changes: REAPER's map leads")
assert(ablink.health_text({ apps = 3, bpm = 120, lead = "Mac", phase = true }) == "Ableton Link: 3 apps, 120.0 BPM, in phase with Mac")
assert(ablink.health_text({ apps = 1, bpm = 98.25, others = { "Bo", "Mac" }, clock = true }) == "Ableton Link: 1 app, 98.2 BPM, leading Bo, Mac"
  or ablink.health_text({ apps = 1, bpm = 98.25, others = { "Bo", "Mac" }, clock = true }) == "Ableton Link: 1 app, 98.3 BPM, leading Bo, Mac")
assert(ablink.health_text({ apps = 0, bpm = 120 }):find("this computer only"), "no shared clock: says so")

-- ---- 5. two computers, bridged ----------------------------------------------------------------------------------------------------------
local T = 1000 -- the studio's shared clock
local inbox = {}
local function computer(name, dev, link_off, local_off)
  local K = { name = name, dev = dev, rbpm = 120, tempos = 1, playing = false, pos = 0, rec = false, may = false, ext = {}, applied = 0,
    L = { bpm = 120, b0 = 0, t0 = 0, playing = false, q = 4, enabled = false } }
  local L = K.L
  local function lnow() return T + link_off end
  local function beat(t) return L.b0 + (t - L.t0) * L.bpm / 60 end
  K.beat = function() return beat(lnow()) end
  K.app_tempo = function(v) L.b0, L.t0, L.bpm = beat(lnow()), lnow(), v end -- (a Link app here: the session moves, keeping its beat)
  K.reaper = setmetatable({
    APIExists = function() return true end,
    GetExtState = function(_, k) return k == "ablink" and "1" or (K.ext[k] or "") end,
    SetExtState = function(_, k, v) K.ext[k] = v end,
    time_precise = function() return T + local_off end,
    EnumProjects = function() return "proj" end,
    GetPlayStateEx = function() return (K.playing and 1 or 0) | (K.rec and 4 or 0) end,
    GetPlayPositionEx = function() return K.pos end, GetCursorPositionEx = function() return K.pos end,
    TimeMap_GetTimeSigAtTime = function() return 4, 4, K.rbpm end,
    TimeMap2_timeToBeats = function(_, pos) local full = pos * K.rbpm / 60; return full % 4, math.floor(full / 4), 4, full, 4 end,
    Undo_BeginBlock2 = function() end, Undo_EndBlock2 = function() end,
    Blink_GetEnabled = function() return L.enabled end, Blink_SetEnabled = function(v) L.enabled = v end,
    Blink_SetStartStopSyncEnabled = function() end,
    Blink_GetClockNow = lnow, Blink_GetNumPeers = function() return 2 end, Blink_GetPuppet = function() return false end,
    Blink_GetTempo = function() return L.bpm end,
    Blink_SetTempo = function(v) L.b0, L.t0, L.bpm = beat(lnow()), lnow(), v end,
    Blink_GetQuantum = function() return L.q end, Blink_SetQuantum = function(q) L.q = q end,
    Blink_GetBeatAtTime = function(t) return beat(t) end,
    Blink_SetBeatAtTimeForce = function(b, t) L.b0, L.t0 = b, t end,
    Blink_GetPlaying = function() return L.playing end, Blink_SetPlaying = function(p) L.playing = p end,
  }, { __index = function(_, k) error("reaper." .. k .. " not stubbed") end })
  K.mods = {
    band = { SECTION = "StudioSync", log = function() end, json_encode = function(t) return t end, json_decode = function(t) return t end,
      recording_anywhere = function() return K.rec end,
      capture_tempo = function() local m = { { time = 0, bpm = K.rbpm, num = 4, denom = 4 } }; for i = 2, K.tempos do m[i] = { time = i, bpm = 90 } end; return m end,
      apply_tempo = function(_, map) K.rbpm, K.applied = map[1].bpm, K.applied + 1 end },
    sync = { driver_name = "James" },
    direct = { shared_now = function() return T end,
      send_live = function(_, kind, d) assert(kind == "ablink"); inbox[#inbox + 1] = { from = K, d = d } end },
    services = { my_device_id = function() return dev end },
    presence = { peers = function() return {} end },
  }
  return K
end
local A = computer("James", "AAA", 7.3, 50) -- (each computer's Link clock and REAPER clock are its own)
local B = computer("Mac", "BBB", -120.9, 3)
local function as(K, fn)
  reaper = K.reaper
  for k, m in pairs(K.mods) do package.loaded[k] = m end
  K.mods.sync.timeline_mine = K.may
  if not K.ab then package.loaded.ablink = nil; K.ab = require("ablink") end
  return fn(K.ab)
end
local sent_stamps = {}
local function run(secs)
  for _ = 1, math.floor(secs * 10 + 0.5) do
    T = T + 0.1
    for _, K in ipairs({ A, B }) do if K.playing then K.pos = K.pos + 0.1 end end
    for _, K in ipairs({ A, B }) do as(K, function(ab) ab.tick({ user = K.name }, { song = "s", room = "main" }, "proj") end) end
    local box = inbox
    inbox = {}
    for _, m in ipairs(box) do
      sent_stamps[m.from.name] = m.d.stamp
      local to = m.from == A and B or A
      as(to, function(ab) ab.on_msg({ user = to.name }, { song = "s", room = "main" }, "proj", m.d) end)
    end
  end
end
local function phase_gap() return math.abs(ablink.phase_error(A.beat(), B.beat(), 4)) * 60 / A.L.bpm end

B.L.b0 = 1.3 -- (Mac's Link session started on its own, 1.3 beats off James's)
run(3)
assert(A.L.enabled and B.L.enabled, "both joined their Link sessions")
assert(phase_gap() <= ablink.TOL, string.format("lined up on the bar: %.1f ms apart", phase_gap() * 1000))
assert(near(B.L.bpm, 120, 1e-6) and sent_stamps.James == nil and sent_stamps.Mac == nil, "nobody changed anything: the driver leads, no stamps")

-- a Link app on the Mac changes tempo; Mac isn't the driver: put back, nothing goes out as a change
B.app_tempo(128)
run(1)
assert(near(B.L.bpm, 120, 1e-6) and B.rbpm == 120 and B.applied == 0 and sent_stamps.Mac == nil, "not Mac's to change: put back on Link, the song untouched")
assert(B.ext["ablink status"].note:find("driver"), "Health says why")

-- a Link app on James's computer (the driver) changes tempo: it becomes the song's tempo there, and Mac's Link follows, once
A.may = true
A.app_tempo(125)
run(3)
assert(A.rbpm == 125 and A.applied == 1, "the driver's Link tempo is the song's tempo now (the timeline sends it on)")
assert(near(B.L.bpm, 125, 1e-6) and B.applied == 0 and B.rbpm == 120, "Mac's Link follows over the bridge; its REAPER waits for the timeline")
assert(sent_stamps.Mac == nil and A.applied == 1, "no echo: Mac never claimed the change, James never applied it twice")
assert(phase_gap() <= ablink.TOL, "still on the bar after the tempo change")
-- the timeline arrives on the Mac: its REAPER takes the map, its Link already has it, nothing goes back
B.rbpm = 125
run(2)
assert(near(A.L.bpm, 125, 1e-6) and A.applied == 1 and sent_stamps.Mac == nil, "the timeline's own arrival isn't a change by anyone")
assert(B.ext["ablink status"].lead == "James" and B.ext["ablink status"].phase == true, "Health: in phase with James")

-- recording: the driver's Link app changes tempo mid-take: put back, the song's map stays
A.rec, A.playing = true, true
run(1)
A.app_tempo(140)
run(1)
assert(A.rbpm == 125 and A.applied == 1 and near(A.L.bpm, 125, 1e-6), "never mid-take")
A.rec, A.playing = false, false
run(1)

-- Anyone mode: Mac may change the tempo too, and the newest change leads; James's Link follows Mac's now
B.may = true
B.app_tempo(132)
run(3)
assert(B.rbpm == 132 and near(A.L.bpm, 132, 1e-6) and sent_stamps.Mac ~= nil, "Mac changed it last: Mac leads")
assert(A.ext["ablink status"].lead == "Mac", "James's Health says who it follows")
A.rbpm = 132 -- (the timeline brings Mac's map to James)
run(2)
assert(A.applied == 1 and near(B.L.bpm, 132, 1e-6), "and that arrival goes nowhere")

-- REAPER plays on James's computer: its Link's bar is REAPER's bar, and its Link apps start with it; Mac's Link starts too
A.playing, A.pos = true, 10.37
run(1.5)
assert(A.L.playing and B.L.playing, "start/stop crosses the bridge")
local want = (A.pos * A.rbpm / 60) % 4
assert(math.abs(ablink.phase_error(A.beat(), want, 4)) * 60 / A.rbpm <= ablink.TOL, "James's Link bar is REAPER's bar")
assert(phase_gap() <= ablink.TOL, "and Mac's Link lines up with it")
A.playing = false
run(3)
assert(not A.L.playing and not B.L.playing, "stop crosses too")
print("ok ablink: phase, echo, leader, the song's tempo rules and a two-computer bridge")
