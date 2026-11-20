-- The Mixer page, shared DAW view stage 4 (lib/webmixer.lua, lib/webui/mixer.js): what a page may send, the strips as read from a stand-in
-- REAPER (this computer's own tracks, hidden ones and sends to its own tracks left out; its own and Shared CPU plug-ins locked), each move
-- checked as dawedit checks a track edit (a claimed track refused, Local mixing's faders and pan and solo always yours), volume through
-- controllers.web_move (a bandmate's hold refuses it; a move of yours queued to go live), plug-in bypass and send levels, the monitor mix
-- through liveaudio's cue mix, topics only while a page shows the Mixer, and a link check of the page. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, logged, now = {}, {}, 1000
reaper = setmetatable({
  time_precise = function() return now end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end

-- ---- stand-ins: the mirror, who may change what, the link's clock, live audio ---------------------------------------------------------
package.loaded.mirror = {
  local_track = function(tr) return tr["local"] == true end,
  track_oid = function(tr) return (tr.oid or ""):upper() end,
}
package.loaded.direct = { shared_now = function() return 77 end, live_available = function() return true end, peers = function() return {} end }
package.loaded.groups = { trusted = function() return {} end, may_manage = function() return false end }
local asked_session -- (the 4th argument sync.authority got: the session, for its region claims, as dawedit asks)
local claims = { bass = "Bo" } -- (lower track name -> who claimed it)
package.loaded.sync = {
  authority = function(_, _, _, s)
    asked_session = s
    local who = { mode = "anyone", driver = "James", is_claimed = function(name) return claims[name:lower()] ~= nil end,
      owner_of = function(name) return claims[name:lower()] end }
    return function(user, name) return name == nil or claims[name:lower()] == nil or claims[name:lower()] == user end, who
  end,
  maker_may = function() return false end,
}
local la_set, la_vol = {}, nil
package.loaded.liveaudio = {
  enabled = function() return true end, available = function() return true end, can_play = function() return true end,
  status = function() return { running = true, peers = { ["bo-pc:47281"] = { level = 0.5, play_level = 0, streaming = true } } } end,
  names = function() return { ["bo-pc:47281"] = "Bo" } end,
  name_of = function(peer, names) return (names or { ["bo-pc:47281"] = "Bo" })[peer] or peer end,
  mix = function() return { Bo = { gain = 0.5, play = 2 } } end,
  me = function() return { volume = 1 } end,
  set_peer = function(peer, gain, mute, play) la_set = { peer = peer, gain = gain, mute = mute, play = play } end,
  set_volume = function(v) la_vol = v end,
}

-- ---- a stand-in REAPER --------------------------------------------------------------------------------------------------------------------
local tracks, undo, master = nil, {}, { vol = 0.5, peak = 0.25 }
local function song()
  tracks = {
    { name = "Drums", oid = "T-JAMES-1", vol = 1, pan = 0, mute = 0, solo = 0, peak = 0.5, ext = {},
      fx = { { name = "ReaEQ", guid = "{A}", on = true }, { name = "Drum map", guid = "{B}", on = true }, { name = "Amp", guid = "{C}", on = false } },
      sends = {} },
    { name = "Mine", ["local"] = true, oid = "T-X-9", vol = 1, pan = 0, mute = 0, solo = 0, peak = 0, ext = {}, fx = {}, sends = {} },
    { name = "Bass", oid = "T-BO-2", vol = 1, pan = 0, mute = 0, solo = 0, peak = 0, ext = {}, fx = {}, sends = {} },
    { name = "Hidden", oid = "T-JAMES-4", hidden = true, vol = 1, pan = 0, mute = 0, solo = 0, peak = 0, ext = {}, fx = {}, sends = {} },
    { name = "Verb", oid = "T-JAMES-5", vol = 1, pan = 0, mute = 0, solo = 0, peak = 0, ext = {}, fx = {}, sends = {} },
  }
  tracks[1].ext.band_local_fx = "{B}for=drums;{C}held=0;"
  tracks[1].sends = { { dest = tracks[5], vol = 0.5, mute = 0 }, { dest = tracks[2], vol = 1, mute = 0 }, { dest = tracks[3], vol = 0.25, mute = 1 } }
end
local TV = { D_VOL = "vol", D_PAN = "pan", B_MUTE = "mute", I_SOLO = "solo" }
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return tracks[i + 1] end
reaper.GetMasterTrack = function() return master end
reaper.GetMediaTrackInfo_Value = function(tr, k)
  if k == "B_SHOWINTCP" then return tr.hidden and 0 or 1 end
  if k == "I_CUSTOMCOLOR" then return 0 end
  return tr[TV[k]] or 0
end
reaper.SetMediaTrackInfo_Value = function(tr, k, v) tr[TV[k]] = v; return true end
reaper.GetSetMediaTrackInfo_String = function(tr, k)
  if k == "P_NAME" then return true, tr.name end
  local e = k:match("^P_EXT:(.+)$")
  return true, e and tr.ext and tr.ext[e] or ""
end
reaper.TrackFX_GetCount = function(tr) return #tr.fx end
reaper.TrackFX_GetFXGUID = function(tr, i) return tr.fx[i + 1].guid end
reaper.TrackFX_GetFXName = function(tr, i) return true, tr.fx[i + 1].name end
reaper.TrackFX_GetEnabled = function(tr, i) return tr.fx[i + 1].on end
reaper.TrackFX_SetEnabled = function(tr, i, on) tr.fx[i + 1].on = on end
reaper.GetTrackNumSends = function(tr) return #tr.sends end
reaper.GetTrackSendInfo_Value = function(tr, _, i, k)
  local s = tr.sends[i + 1]
  if k == "P_DESTTRACK" then return s.dest end
  return s[TV[k]] or 0
end
reaper.SetTrackSendInfo_Value = function(tr, _, i, k, v) tr.sends[i + 1][TV[k]] = v; return true end
reaper.Track_GetPeakInfo = function(tr) return tr.peak or 0 end
reaper.Undo_OnStateChangeEx2 = function(_, label) undo[#undo + 1] = label end
local projext = {}
reaper.GetProjExtState = function(_, s, k) local v = projext[s .. "/" .. k]; return v and 1 or 0, v or "" end
reaper.GetPlayStateEx = function() return 0 end

local webmixer = require("webmixer")
local controllers = require("controllers")
controllers.pass = { can = function() return true end, my_can = function(user, name) return claims[name:lower()] == nil or claims[name:lower()] == user end, who = { mode = "anyone" } }
local cfg, b, proj = { user = "James", root = "R" }, { song = "S", room = "main" }, {}

-- ---- parse ------------------------------------------------------------------------------------------------------------------------------
local d = webmixer.parse({ id = "mx1", set = { o = "T-JAMES-1", k = "v", v = 0.7, done = true } })
assert(d and d.set.v == 0.7 and d.set.done and d.id == "mx1", "a fader move")
assert(webmixer.parse({ set = { o = "T-JAMES-1", k = "m", v = 0.9 } }).set.v == 1, "mute is on or off")
assert(webmixer.parse({ want = true }).want and webmixer.parse({ want = false }).off, "want, and not any more")
assert(webmixer.parse({ mon = { peer = "bo-pc:47281", mute = false } }).mon.mute == false, "an unmute is kept as false")
assert(webmixer.parse({ mon = { peer = "bo-pc:47281", talk = 1 } }).mon.mute == nil, "no mute: left as it is")
local bad = {
  { set = { o = "T-JAMES-1", k = "v", v = 17 } }, { set = { o = "T-JAMES-1", k = "x", v = 0 } }, { set = { o = "<b>", k = "v", v = 1 } },
  { set = { o = "T-JAMES-1", k = "p", v = 0 / 0 } }, { fx = { o = "T-JAMES-1", i = -1, name = "a" } }, { fx = { o = "T-JAMES-1", i = 1.5, name = "a" } },
  { send = { o = "T-JAMES-1", i = 0, to = "nope", v = 1 } }, { mon = { peer = 5 } }, { all = 9 }, "nope",
}
for n, x in ipairs(bad) do assert(webmixer.parse(x) == nil, "refused: #" .. n) end
assert(select(3, webmixer.parse({ id = "mx9", set = { o = "T-1", k = "q" } })) == "mx9", "a refusal keeps its id")
assert(webmixer.parse({ id = "<x>" }).id == nil, "ids are plain")
assert(webmixer.db(1) == 0 and webmixer.db(0) == -60 and webmixer.db(0.5) == -6 and webmixer.db(100) == 12, "peaks in whole dB")

-- ---- the strips -------------------------------------------------------------------------------------------------------------------------
song()
local may = function(_, name, o) return require("dawedit").item_refusal(package.loaded.sync.authority(), select(2, package.loaded.sync.authority()), "James", name, o, nil, nil) end
local strips = webmixer.read(proj, may)
assert(#strips == 3 and strips[1].o == "T-JAMES-1" and strips[2].o == "T-BO-2" and strips[3].o == "T-JAMES-5", "own and hidden tracks left out")
assert(strips[1].fx[1].x == nil and strips[1].fx[2].x and strips[1].fx[3].x, "own and Shared CPU plug-ins locked")
assert(strips[1].fx[1].on and not strips[1].fx[3].on, "bypass read")
assert(#strips[1].sends == 2 and strips[1].sends[1].to == "T-JAMES-5" and strips[1].sends[2].i == 2 and strips[1].sends[2].m, "sends to own tracks left out, the real index kept")
assert(strips[2].why and strips[2].why:find("Bo has claimed"), "a track someone else claimed: why")
assert(strips[1].why == nil, "an unclaimed one: may")

-- ---- moves ------------------------------------------------------------------------------------------------------------------------------
local function act(a) return webmixer.action(proj, cfg, b, a) end
local read_json = band.read_json
band.read_json = function() return { regions = { verse = "Bo" } } end
act({ id = "a1", set = { o = "T-JAMES-1", k = "v", v = 0.7 } })
band.read_json = read_json
assert(type(asked_session) == "table" and asked_session.regions, "who may: asked with the session (its region claims), as dawedit asks")
assert(tracks[1].vol == 0.7 and webmixer.reply.ok and webmixer.reply.id == "a1", "a fader move set")
local m = controllers.state.mine["T-JAMES-1|v"]
assert(m and m.due and m.v == 0.7 and m.s == 77, "and queued to go live as yours (Shared controllers)")
assert(#undo == 0, "no undo point mid-drag")
act({ set = { o = "T-JAMES-1", k = "v", v = 0.8, done = true } })
assert(#undo == 1 and undo[1]:find("Drums volume"), "the drag's last move: one undo point")
local said = act({ id = "a2", set = { o = "T-BO-2", k = "v", v = 0.1 } })
assert(tracks[3].vol == 1 and webmixer.reply.why and webmixer.reply.id == "a2" and said:find("claimed"), "a claimed track: refused, unchanged, said")
assert(act({ set = { o = "T-BO-2", k = "v", v = 0.2 } }) == nil, "said once while the same refusal repeats (a drag)")
projext[band.SECTION .. "/local_mix"] = "1"
act({ set = { o = "T-BO-2", k = "v", v = 0.3 } })
assert(tracks[3].vol == 0.3 and webmixer.reply.ok, "Local mixing: your faders are yours")
act({ set = { o = "T-BO-2", k = "m", v = 1 } })
assert(tracks[3].mute == 0 and webmixer.reply.why, "but mute still goes to the band: refused")
projext[band.SECTION .. "/local_mix"] = nil
act({ set = { o = "T-BO-2", k = "s", v = 1 } })
assert(tracks[3].solo == 2 and webmixer.reply.ok and not controllers.state.mine["T-BO-2|s"], "solo: yours, on any track, never sent")
controllers.state.theirs["T-JAMES-1|p"] = { user = "Bo", s = 1, at = now, word = "Drums pan" }
act({ set = { o = "T-JAMES-1", k = "p", v = 0.5 } })
assert(tracks[1].pan == 0 and webmixer.reply.why == "Bo has Drums pan right now", "a bandmate moving it keeps it")
controllers.state.theirs["T-JAMES-1|p"] = nil
act({ set = { o = "T-NOPE-1", k = "v", v = 1 } })
assert(webmixer.reply.why:find("changed meanwhile"), "a track that's gone")
-- plug-ins
act({ fx = { o = "T-JAMES-1", i = 0, name = "ReaEQ", on = false } })
assert(tracks[1].fx[1].on == false and webmixer.reply.ok and undo[#undo]:find("bypass ReaEQ"), "bypassed, one undo point")
act({ fx = { o = "T-JAMES-1", i = 1, name = "Drum map", on = false } })
assert(tracks[1].fx[2].on and webmixer.reply.why:find("own"), "this computer's own plug-in: refused")
act({ fx = { o = "T-JAMES-1", i = 2, name = "Amp", on = true } })
assert(not tracks[1].fx[3].on and webmixer.reply.why, "one running on a bandmate's: refused")
act({ fx = { o = "T-JAMES-1", i = 0, name = "Other", on = true } })
assert(tracks[1].fx[1].on == false and webmixer.reply.why:find("changed"), "a plug-in not where the page saw it")
-- sends: checked on the track they go to
act({ send = { o = "T-JAMES-1", i = 0, to = "T-JAMES-5", v = 0.9, done = true } })
assert(tracks[1].sends[1].vol == 0.9 and webmixer.reply.ok and undo[#undo]:find("send to Verb"), "a send level")
act({ send = { o = "T-JAMES-1", i = 2, to = "T-BO-2", v = 0.9 } })
assert(tracks[1].sends[3].vol == 0.25 and webmixer.reply.why:find("Bo"), "a send onto a track Bo claimed: refused")
act({ send = { o = "T-JAMES-1", i = 1, to = "T-JAMES-5", v = 0.9 } })
assert(tracks[1].sends[2].vol == 1 and webmixer.reply.why:find("changed"), "a send not where the page saw it")
-- the monitor mix
act({ mon = { peer = "bo-pc:47281", play = 0.5 } })
assert(la_set.peer == "bo-pc:47281" and la_set.gain == 0.5 and la_set.play == 0.5 and la_set.mute == false, "Play volume: Talk and mute kept")
act({ mon = { peer = "bo-pc:47281", mute = true } })
assert(la_set.mute == true and la_set.gain == 0.5, "muted")
act({ mon = { peer = "someone:1", talk = 1 } })
assert(webmixer.reply.why, "a bandmate not heard here: refused")
act({ all = 2 })
assert(la_vol == 2, "Everyone")
local mon = webmixer.monitor(cfg)
assert(mon.on and #mon.peers == 1 and mon.peers[1].name == "Bo" and mon.peers[1].talk == 0.5 and mon.peers[1].play == 2 and mon.peers[1].lt == -6, "the monitor mix model")

-- ---- topics only while a page shows the Mixer -------------------------------------------------------------------------------------------
local pub = {}
local function publish(t, v) pub[t] = (pub[t] or 0) + 1; pub[t .. ":v"] = v end
act({ want = false })
webmixer.tick(proj, cfg, b, publish, now)
assert(next(pub) == nil, "nobody looking: nothing built")
act({ want = true })
webmixer.tick(proj, cfg, b, publish, now)
assert(pub.mix == 1 and pub.mixm == 1 and pub.mixmon == 1 and pub.mixr == 1, "looking: strips, meters, the monitor mix and the last answer")
assert(pub["mixm:v"].p["T-JAMES-1"] == -6 and pub["mixm:v"].master == -12, "peaks in dB, the master's too")
assert(pub["mix:v"].master.v == 0.5 and #pub["mix:v"].strips == 3, "the master read only")
controllers.state.theirs["T-JAMES-5|v"] = { user = "Bo", s = 1, at = now, word = "Verb volume" }
now = now + 0.05
webmixer.tick(proj, cfg, b, publish, now)
assert(pub.mixm == 1 and pub.mix == 1, "meters and strips rate-limited")
now = now + 0.07
tracks[1].peak = 1
webmixer.tick(proj, cfg, b, publish, now)
assert(pub.mixm == 2 and pub.mix == 1 and pub["mixm:v"].p["T-JAMES-1"] == 0, "meters 10 a second, strips less often")
now = now + 0.2
webmixer.tick(proj, cfg, b, publish, now)
assert(pub.mixm == 3 and pub.mix == 2 and pub["mix:v"].strips[3].by.v == "Bo", "again after their wait; a bandmate's hold shown")
now = now + webmixer.WANT_FOR + 1
webmixer.tick(proj, cfg, b, publish, now)
assert(pub.mix == 2, "the page stopped saying so: stops")

-- ---- the page's wiring --------------------------------------------------------------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local html, js, ui = read("lib/webui/index.html"), read("lib/webui/mixer.js"), read("lib/webui.lua")
assert(html:find('src="mixer.js"', 1, true) and html:find('href="mixer.css"', 1, true), "index.html loads the page")
assert(html:find("tabs.js", 1, true) < html:find("mixer.js", 1, true), "after tabs.js")
assert(ui:find("webui.ACTIONS.mixer = true", 1, true) and ui:find('require("webmixer").tick', 1, true) and ui:find('require("webmixer").action', 1, true), "webui.lua routes it")
for _, t in ipairs({ "'mix'", "mixm", "mixmon", "mixr", "ssTabs.add('mixer'", "want: on !== false" }) do assert(js:find(t, 1, true) or js:find(t:gsub("'", ""), 1, true), "mixer.js reads " .. t) end
assert(not js:find("innerHTML", 1, true), "names go in as text")
assert(js:find("startsWith(me)", 1, true), "only this page's own answers are taken")

print("ok")
