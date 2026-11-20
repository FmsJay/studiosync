-- A screen share's sound and "like your own timeline" (rt-share, docs/rt/rt-share.md): the page's two local messages (lib/webcall.lua: "view"
-- while sharing, "duck" while watching a share with its sound), live audio muting a ducked bandmate's Play (lib/liveaudio.lua), REAPER's
-- arrange view as the "rtview" topic (rects from JS_ReaScriptAPI or SWS, macOS's flipped y, hidden tracks left out, published only while
-- sharing and only when changed), and a link check of the pieces: the extension's REAPER mix (taken before live audio adds anyone), its
-- loopback-only stream, the worklet, and call.js's sound picker, notes and full screen. (rt-share)
package.path = "lib/?.lua;" .. package.path
local clock, ext, os_name = 1000, {}, "Win64"
local calls, pgain = {}, 1
local function dev(c) return (c:rep(7) .. "-"):rep(7) .. c:rep(7) end
local ME, CHI = dev("A"), dev("B")
local R = { -- (a stand-in REAPER: a window, its arrange view, three tracks; the extension's live audio with chilio's Play)
  time_precise = function() return clock end, GetOS = function() return os_name end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end, SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetPlayState = function() return 0 end,
  GetSet_ArrangeView2 = function() return 12.34567, 42.5 end,
  GetMainHwnd = function() return "main" end,
  JS_Window_FindChildByID = function(h, id) return h == "main" and id == 1000 and "tv" or nil end,
  JS_Window_GetClientRect = function(h) if h == "tv" then return true, 300, 180, 1900, 1000 end return true, 0, 23, 1920, 1040 end,
  JS_Window_GetRect = function(h) if h == "main" then return true, -7, 0, 1927, 1047 end end,
  my_getViewport = function() return 0, 0, 1920, 1080 end,
  CountTracks = function() return 3 end, GetTrack = function(_, i) return i end,
  GetMediaTrackInfo_Value = function(tr, k) return ({ [0] = { I_TCPH = 80, I_TCPY = -40 }, { I_TCPH = 0, I_TCPY = 40 }, { I_TCPH = 120, I_TCPY = 40 } })[tr][k] end,
  GetTrackName = function(tr) return true, ({ [0] = "Drums", "Hidden", "Vox <b>" })[tr] end,
  GetTrackGUID = function(tr) return ({ [0] = "{0A1B2C3D-0000-0000-0000-000000000000}", "{11111111-0000-0000-0000-000000000000}", "{FFEE0011-2222-0000-0000-000000000000}" })[tr] end,
  StudioSync_LiveAudioStart = function() end, StudioSync_LiveAudioStop = function() end, StudioSync_LiveAudioPeers = function() end,
  StudioSync_LiveAudioPeerSet = function() end, StudioSync_LiveAudioPlay = function() end,
  StudioSync_LiveAudioPeerPlay = function(peer, g) calls[#calls + 1] = { peer, g }; pgain = g end,
  StudioSync_LiveAudioStatus = function()
    return '{"running":true,"play_send":false,"peers":{"chilio-pc.tail9.ts.net:47281":{"gain":1,"play_gain":' .. pgain .. ',"mute":false}}}'
  end,
}
reaper = setmetatable(R, { __index = function(_, k) if not tostring(k):find("^StudioSync_") and not tostring(k):find("^JS_") and not tostring(k):find("^BR_") then return function() return "" end end end })
package.loaded.services = { is_device_id = function(id) return type(id) == "string" and #id == 63 end, my_device_id = function() return ME end }
local sent = {}
local peers, dev_of = { "chilio-pc.tail9.ts.net:47281" }, { ["chilio-pc.tail9.ts.net:47281"] = CHI }
package.loaded.direct = { peers = function() return peers, dev_of end, send_live = function(_, kind, d) sent[#sent + 1] = { kind = kind, d = d }; return true end }
local band = require("band")
local webcall = require("webcall")
local liveaudio = require("liveaudio")
local cfg, b = { user = "James", root = "R" }, { song = "Song", room = "main" }
ext[band.SECTION .. "/live audio names"] = band.json_encode({ ["chilio-pc.tail9.ts.net:47281"] = "chilio" })

-- "view": this computer shares; nothing goes over the link
webcall.reset()
assert(not webcall.viewing(clock), "not sharing at first")
assert(webcall.page(cfg, b, { t = "view" }, 100) == false and #sent == 0, "view: this computer only, nothing over the link")
assert(webcall.viewing(clock) and webcall.viewing(clock + webcall.VIEW_FOR - 0.1) and not webcall.viewing(clock + webcall.VIEW_FOR), "lasts VIEW_FOR s unless said again")

-- "duck": watching chilio's share with its sound mutes chilio's live Play here; their Talk stays
assert(webcall.page(cfg, b, { t = "duck", to = CHI, on = true }, 100) == false and liveaudio.ducks.chilio == nil, "a bandmate whose page isn't open: nothing")
webcall.link(cfg, b, { t = "here", user = "chilio", dev = CHI }, 100)
calls = {}
assert(webcall.page(cfg, b, { t = "duck", to = CHI, on = true }, 100) == false and #sent == 0, "duck: this computer only")
assert(liveaudio.ducks.chilio == clock + webcall.DUCK_FOR, "chilio's Play ducked for DUCK_FOR s, by name")
assert(#calls == 1 and calls[1][1] == "chilio-pc.tail9.ts.net:47281" and calls[1][2] == 0, "and live audio's Play level for chilio goes to 0 at once")
clock = clock + webcall.DUCK_FOR + 1
calls = {}
liveaudio.apply()
assert(#calls == 1 and calls[1][2] == 1, "a duck nobody renews runs out: Play back (a closed page never leaves it silent)")
clock = 1000
webcall.page(cfg, b, { t = "duck", to = CHI, on = true }, 100)
webcall.page(cfg, b, { t = "duck", to = CHI, on = false }, 100)
assert(liveaudio.ducks.chilio == nil, "duck off: gone")
assert(webcall.page(cfg, b, { t = "duck", to = "chilio", on = true }, 100) == false and liveaudio.ducks.chilio == nil, "only a device id")

-- REAPER's arrange view
local v = webcall.view_model(0)
assert(v.on == true and v.t0 == 12.3457 and v.t1 == 42.5, "the time shown, to 0.1 ms")
assert(v.arr.x == 300 and v.arr.y == 180 and v.arr.w == 1600 and v.arr.h == 820, "the arrange view's rect (its client area, id 1000)")
assert(v.win.x == -7 and v.win.y == 0 and v.win.w == 1934 and v.win.h == 1047, "REAPER's window, invisible borders and all")
assert(v.mon.x == 0 and v.mon.w == 1920 and v.mon.h == 1080, "the screen it's on")
assert(#v.tracks == 2 and v.tracks[1][1] == "0A1B2C3D" and v.tracks[1][2] == -40 and v.tracks[1][3] == 80 and v.tracks[1][4] == "Drums"
  and v.tracks[2][1] == "FFEE0011" and v.tracks[2][4] == "Vox <b>", "shown tracks only (hidden left out), scrolled place, 8-character ids, names as they are")
os_name = "OSX64" -- (macOS: y counts up from the bottom)
R.JS_Window_GetClientRect = function(h) if h == "tv" then return true, 300, 900, 1900, 80 end end
R.JS_Window_GetRect = function() return true, 0, 1000, 1920, 0 end
v = webcall.view_model(0)
assert(v.arr.y - v.win.y == 100 and v.arr.h == 820 and v.win.h == 1000 and v.mon == nil, "macOS: flipped, so the arrange view is still 100 below the window's top; no screen rect")
os_name = "Win64"
local js = { R.JS_Window_FindChildByID, R.JS_Window_GetClientRect, R.JS_Window_GetRect }
R.JS_Window_FindChildByID, R.JS_Window_GetClientRect, R.JS_Window_GetRect = nil, nil, nil
v = webcall.view_model(0)
assert(v.arr == nil and v.win == nil and #v.tracks == 2, "no JS_ReaScriptAPI or SWS: the timeline without its place (watchers point at the picture)")
R.BR_Win32_HwndToString = function(h) return "0x" .. h end
R.BR_Win32_FindWindowEx = function(parent, _, class) return parent == "0xmain" and class == "REAPERTrackListWindow" and "tv" or nil end
R.BR_Win32_GetWindowRect = function(h) if h == "tv" then return true, 300, 180, 1900, 1000 end return true, -7, 0, 1927, 1047 end
v = webcall.view_model(0)
assert(v.arr and v.arr.w == 1600 and v.win.w == 1934, "SWS instead")
R.JS_Window_FindChildByID, R.JS_Window_GetClientRect, R.JS_Window_GetRect = js[1], js[2], js[3]

-- published only while sharing, at most every VIEW_EVERY s, and "off" once when it ends
local pub = {}
local function publish(t, x) pub[#pub + 1] = { t, x } end
webcall.reset()
webcall.view_tick(0, publish, 1000)
assert(#pub == 0, "not sharing: nothing")
webcall.local_msg({ t = "view" }, 1000)
webcall.view_tick(0, publish, 1000)
assert(#pub == 1 and pub[1][1] == "rtview" and pub[1][2].on and #pub[1][2].tracks == 2, "sharing: the view")
webcall.view_tick(0, publish, 1000 + webcall.VIEW_EVERY / 2)
assert(#pub == 1, "not again within VIEW_EVERY")
webcall.view_tick(0, publish, 1000 + webcall.VIEW_EVERY)
assert(#pub == 2, "then again (lib/webui.lua's publish sends it only when it changed)")
webcall.view_tick(0, publish, 1000 + webcall.VIEW_FOR + 1)
assert(#pub == 3 and pub[3][2].on == false, "the share's page stopped saying view: off, once")
webcall.view_tick(0, publish, 1000 + webcall.VIEW_FOR + 2)
assert(#pub == 3, "and then nothing")
R.CountTracks = function() return 1000 end
R.GetTrack = function() return 2 end
assert(#webcall.view_model(0).tracks == webcall.TRACKS_MAX and #band.json_encode(webcall.view_model(0)) < 64 * 1024, "at most TRACKS_MAX tracks: the topic and the data channel's message stay small")

-- The pieces, linked
local function read(p) local f = assert(io.open(p, "rb"), p); local s = f:read("a"); f:close(); return s end
local cj, wk, cpp, rta, wl, la = read("lib/webui/call.js"), read("lib/webui/sharemix.js"), read("extension/webui.cpp"), read("extension/rtaudio.cpp"), read("lib/webui.lua"), read("lib/liveaudio.lua")
assert(cpp:find('r.path == "/api/mix"', 1, true) and cpp:find("if (!local || !header(r, \"x-forwarded-host\").empty()", 1, true), "the extension streams REAPER's mix to this computer's pages only")
local feed, mix = rta:find("webui_mix_feed(out, nout, len, srate);", 1, true), rta:find("rt_mix(g_rt, out, nout, len, srate);", 1, true)
assert(feed and mix and feed < mix, "REAPER's mix is taken before live audio adds the bandmates: nobody hears themselves back")
assert(rta:find('rec->Register("timer", (void *)mix_timer)', 1, true), "the hook stays in while a page streams it, live audio or not")
assert(cj:find("fetch('api/mix'", 1, true) and cj:find("addModule('sharemix.js')", 1, true) and wk:find("registerProcessor('ss-share-mix'", 1, true)
  and cj:find("'ss-share-mix'", 1, true), "call.js plays the stream through the worklet")
assert(cj:find("replaceTrack", 1, true) and cj:find("addTransceiver('audio', { direction: 'sendonly'", 1, true), "the sound changes without a new offer")
for _, w in ipairs({ "reaper: 'REAPER mix'", "system: 'System audio'", "none: 'No sound'" }) do assert(cj:find(w, 1, true), "the picker offers " .. w) end
assert(cj:find("t: 'duck'", 1, true) and cj:find("t: 'view'", 1, true) and cj:find("t.rtview", 1, true), "call.js says duck and view, and reads rtview")
assert(cj:find("act({ topic: 'chat' }, { text: where", 1, true), "notes saved to the project's chat, the place in front")
assert(cj:find("requestFullscreen", 1, true) and cj:find("Full screen: like your own REAPER", 1, true), "full screen, cropped when the timeline is known")
assert(not cj:find("innerHTML", 1, true) and not cj:find("insertAdjacentHTML", 1, true), "names and notes go in as text")
assert(cj:find("by: s.user, dev: s.dev", 1, true), "the sharer names a note's author from the connection, not the note")
assert(wl:find("webcall.view_tick(proj, publish, now)", 1, true), "Live sync's web UI tick publishes the view")
assert(la:find("liveaudio.ducks[name]", 1, true), "live audio honours a duck")
print("ok")
