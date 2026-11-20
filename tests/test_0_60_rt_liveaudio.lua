-- Live audio over the link (James, rt; lib/liveaudio.lua, the extension's side in extension/rtaudio.cpp and tests/rtaudio_test.cpp): the JSON
-- the extension takes, this computer's choice, the studio's setting (off by default), Live sync's tick against a stand-in extension (started
-- with the studio secret for those here, restarted on a new choice, the cue mix put back, stopped when the studio turns it off, only the song
-- in front drives it, the tab that started it stops it), Health's row and words, and the firewall rule's UDP twin.
package.path = "lib/?.lua;" .. package.path
local clock, ext, front = 1000, {}, "P1"
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  EnumProjects = function() return front end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end }) -- (the extension's: absent)

local band = require("band")
assert(band.WIN, "the stand-in REAPER is Windows")
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
local written = {}
band.write_atomic = function(p, s) written[p] = s; return true end
local hidden_out -- what the background netsh check last said
package.loaded.services = { run_hidden = function(name) return name == "direct-fw" and hidden_out or nil end, TMP = "T" }
local trusted, secret = {}, "s3cret"
package.loaded.groups = { trusted = function() return trusted end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end,
  sonobus_secret = function() return secret end, live_audio = function() return trusted.live_audio ~= false end }
local direct = require("direct")
local peers_here = { "bee-laptop.tail99.ts.net:47281", "mac.tail99.ts.net:47281" }
direct.peers = function() return peers_here, {} end
local la = require("liveaudio")
local cfg = { root = "J:/St/Smiley", user = "James" }

-- ---- 1. pure --------------------------------------------------------------------------------------------------------------------------
local j = band.json_decode(la.peers_json('se"cret', 47281.0, { "a.ts.net:47281" }))
assert(j.secret == 'se"cret' and j.port == 47281 and j.peers[1] == "a.ts.net:47281", "the JSON the extension takes")
assert(la.peers_json("s", 47281, {}):find('"peers":[]', 1, true), "nobody here: an empty list, not an object")
assert(la.why_not(false, true, "s", true) == "off for this studio", "off first")
assert(la.why_not(true, false, "s", true):find("extension", 1, true), "then the extension")
assert(la.why_not(true, true, nil, true):find("Tailscale", 1, true), "then the secret")
assert(la.why_not(true, true, "s", false):find("firewall", 1, true), "then Windows' rule")
assert(la.why_not(true, true, "s", true) == nil, "all there: it may run")
local f, n, k = la.mine()
assert(f == 0 and n == 1 and k == 128, "defaults: the first input, mono, 128 kbit/s")
la.set_mine(3, 12, 9999)
f, n, k = la.mine()
assert(f == 3 and n == 8 and k == 512, "kept within what the extension takes")
la.set_mine(0, 1, 128)

-- ---- 2. the firewall rule's UDP twin -----------------------------------------------------------------------------------------------------
local exe = "C:\\REAPER\\reaper.exe"
assert(direct.firewall_command(exe, 47281):find("protocol=TCP ", 1, true), "the link's rule stays TCP")
local udp = direct.firewall_command(exe, 47281, "UDP")
assert(udp:find("protocol=UDP ", 1, true) and udp:find("remoteip=100.64.0.0/10", 1, true) and udp:find("localport=47281", 1, true)
  and udp:find('program="C:\\REAPER\\reaper.exe"', 1, true) and udp:find("dir=in", 1, true), "its twin: UDP, the same port, Tailscale's addresses only")
local tcp_only = "Rule Name: StudioSync direct link\r\nLocalPort: 47281\r\nProtocol: TCP\r\nProgram: C:\\REAPER\\reaper.exe\r\n"
local both = tcp_only .. "\r\nRule Name: StudioSync direct link\r\nLocalPort: 47281\r\nProtocol: UDP\r\nProgram: C:\\REAPER\\reaper.exe\r\n"
assert(direct.firewall_in(tcp_only, exe, 47281) and not direct.firewall_in(tcp_only, exe, 47281, "UDP"), "the TCP rule alone: the link yes, live audio no")
assert(direct.firewall_in(both, exe, 47281, "UDP"), "both rules: live audio yes")
assert(not direct.firewall_in("Rule Name: StudioSync direct link\r\nProgram: C:\\REAPER\\reaper.exe\r\nLocalPort: 47281\r\nDescription: udpx", exe, 47281, "UDP"),
  "the word itself, not inside another")
assert(direct.setup_firewall() == true, "the button runs")
local ps1 = written["T/bandsync-direct-fw.ps1"] or ""
assert(ps1:find("protocol=TCP", 1, true) and ps1:find("protocol=UDP", 1, true) and ps1:find("delete rule", 1, true) and ps1:find("RunAs", 1, true),
  "one UAC: the old pair deleted, then the TCP rule and its UDP twin added: " .. ps1)

-- ---- 3. Live sync's tick against a stand-in extension -----------------------------------------------------------------------------------
local E = { running = false, calls = {}, peers = {} }
local function call(s) E.calls[#E.calls + 1] = s end
reaper.StudioSync_LiveAudioPeers = function(js) call("peers"); E.json = js; return #band.json_decode(js).peers end
reaper.StudioSync_LiveAudioStart = function(first, nch, kbps)
  call(string.format("start %d %d %d", first, nch, kbps))
  if E.fail then return 0 end
  E.running, E.first, E.nch, E.kbps = true, first, nch, kbps
  E.peers = {}
  for _, p in ipairs(band.json_decode(E.json).peers) do E.peers[p] = { resolved = true, streaming = true, latency_ms = 41.5, buffer_ms = 35, loss = 0.002, level = 0.3, gain = 1, mute = false } end
  return 1
end
reaper.StudioSync_LiveAudioStop = function() call("stop"); E.running = false end
reaper.StudioSync_LiveAudioPeerSet = function(peer, gain, mute) call("set " .. peer); if E.peers[peer] then E.peers[peer].gain, E.peers[peer].mute = gain, mute == 1 end; return 1 end
reaper.StudioSync_LiveAudioStatus = function()
  return band.json_encode({ running = E.running, first = E.first, nch = E.nch, kbps = E.kbps, error = E.fail and "UDP 47281 is taken" or "", peers = E.peers, rejected = 0 })
end
local b = { song = "Nostalgia", room = "main" }
local function tick() clock = clock + 1; la.tick(cfg, b, "P1") end

trusted.live_audio = false
tick()
assert(#E.calls == 0 and la.S.why == "off for this studio", "the studio turned it off: nothing starts")
assert(la.health_row(cfg) == nil, "and Health says nothing")
trusted.live_audio = nil -- (James: on by default, nothing to turn on)
assert(la.enabled(cfg.root), "a studio that never set it: on")
hidden_out = tcp_only
tick()
assert(#E.calls == 0 and la.S.why:find("firewall", 1, true), "on, but Windows has only the TCP rule: not started (Windows' own box would come up)")
local row = la.health_row(cfg)
assert(row and row[2] == false and row.action and row.action[1] == "Set up live audio", "Health: the Set up live audio button")
hidden_out = both
tick()
assert(E.calls[1] == "peers" and E.calls[2] == "start 0 1 128", "started: the peers JSON first, then the inputs: " .. table.concat(E.calls, ","))
j = band.json_decode(E.json)
assert(j.secret == "s3cret" and j.port == 47281 and #j.peers == 2 and j.peers[1] == peers_here[1], "with the studio secret, the link's port and those here")
assert(ext["BandSync/live audio by"] == "P1" or ext[band.SECTION .. "/live audio by"] == "P1", "this tab started it")
local before = #E.calls
tick()
assert(#E.calls == before, "the same next tick: nothing again")
la.set_peer("mac.tail99.ts.net:47281", 0.5, true)
assert(E.peers["mac.tail99.ts.net:47281"].mute == true and E.peers["mac.tail99.ts.net:47281"].gain == 0.5, "the cue mix: set at once")
E.peers["mac.tail99.ts.net:47281"].gain, E.peers["mac.tail99.ts.net:47281"].mute = 1, false -- (the extension restarted it)
tick()
assert(E.peers["mac.tail99.ts.net:47281"].mute == true and E.peers["mac.tail99.ts.net:47281"].gain == 0.5, "and put back by the tick")
peers_here = { "bee-laptop.tail99.ts.net:47281" }
before = #E.calls
tick()
assert(E.calls[before + 1] == "peers" and #E.calls == before + 1, "someone left: the new list, no restart")
la.set_mine(2, 2, 192)
tick()
assert(E.calls[#E.calls - 1] == "stop" and E.calls[#E.calls] == "start 2 2 192", "a new choice here: started again with it")
front = "P2"
before = #E.calls
tick()
assert(#E.calls == before, "another song in front: this tab leaves it alone")
front = "P1"
la.on_exit("P2")
assert(E.running, "a tab that didn't start it doesn't stop it")
trusted.live_audio = false
tick()
assert(E.calls[#E.calls] == "stop" and not E.running and logs[#logs]:find("off for this studio", 1, true), "the studio turns it off: stopped")
trusted.live_audio = true
tick()
assert(E.running, "on again: started")
la.on_exit("P1")
assert(not E.running and (ext["BandSync/live audio by"] or ext[band.SECTION .. "/live audio by"]) == nil, "its Live sync ends: stopped")
E.fail = true
tick()
before = #E.calls
tick()
assert(#E.calls == before + 1 and E.calls[#E.calls] == "peers", "a start that failed isn't tried again every tick")
clock = clock + la.RETRY
tick()
assert(E.calls[#E.calls]:find("^start"), "but again after a while")
row = la.health_row(cfg)
assert(row[3] == "yellow" and row[5]:find("taken", 1, true), "Health shows why it didn't start: " .. row[5])
E.fail = nil
clock = clock + la.RETRY
tick()
assert(E.running, "started once the port is free")

-- ---- 4. Health's words -------------------------------------------------------------------------------------------------------------------
local ok, text = la.health_text({ nch = 1, kbps = 128, peers = { ["bee-laptop.tail99.ts.net:47281"] = { resolved = true, streaming = true, latency_ms = 41.5, buffer_ms = 35, loss = 0.002 } } })
assert(ok and text == "Live audio: sending 1 input at 128 kbit/s; hearing bee-laptop 42 ms (buffer 35 ms, loss 0.2%)", text)
ok, text = la.health_text({ nch = 2, kbps = 192, rejected = 3, last_reject = "wrong studio secret", peers = {
  ["bee-laptop.tail99.ts.net:47281"] = { resolved = true, streaming = true, latency_ms = 60, buffer_ms = 50, loss = 0.08 },
  ["mac.tail99.ts.net:47281"] = { resolved = true, streaming = false },
  ["old.tail99.ts.net:47281"] = { resolved = false, error = "not a Tailscale address" } } })
assert(not ok and text:find("2 inputs at 192", 1, true) and text:find("loss 8.0%", 1, true) and text:find("mac: not heard yet", 1, true)
  and text:find("old: can't reach (not a Tailscale address)", 1, true) and text:find("refused 3 (last: wrong studio secret)", 1, true), text)
-- (the adaptive buffer, James, rt: grown well past its floor, Health says Wi-Fi?; a refusal says from where)
ok, text = la.health_text({ nch = 1, kbps = 128, rejected = 5, last_reject = "not one of the studio's computers here", last_reject_from = "100.70.1.2:47281", peers = {
  ["mac.tail99.ts.net:47281"] = { resolved = true, streaming = true, latency_ms = 120, buffer_ms = 85, target_ms = 90, floor_ms = 30, loss = 0 },
  ["bee-laptop.tail99.ts.net:47281"] = { resolved = true, streaming = true, latency_ms = 45, buffer_ms = 35, target_ms = 40, floor_ms = 30, loss = 0 } } })
assert(ok and text:find("mac 120 ms (buffer 85 ms (Wi-Fi?), loss 0.0%)", 1, true) and text:find("bee-laptop 45 ms (buffer 35 ms, loss 0.0%)", 1, true)
  and text:find("a wired network lowers it", 1, true) and text:find("refused 5 (last: not one of the studio's computers here from 100.70.1.2:47281)", 1, true), text)
-- (1.0.27: a studio computer this one doesn't list is counted apart, not_here, and doesn't make the row a refusal. rt-small)
ok, text = la.health_text({ nch = 1, kbps = 128, rejected = 0, not_here = 13589, not_here_from = "100.109.45.2:47281", peers = {
  ["mac.tail99.ts.net:47281"] = { resolved = true, streaming = true, latency_ms = 40, buffer_ms = 35, target_ms = 30, floor_ms = 30, loss = 0 } } })
assert(ok and not text:find("refused", 1, true) and text:find("100.109.45.2:47281 sends here but isn't in this room here yet", 1, true), text)
local f0, c0 = la.bounds(nil)
assert(f0 == 30 and c0 == 150, "a bandmate's buffer bounds: the defaults")
f0, c0 = la.bounds({ floor = 200, ceiling = 100 })
assert(f0 == 200 and c0 == 200, "a ceiling never under the floor")
assert(select(1, la.bounds({ floor = 1 })) == 10, "a floor kept to what the extension takes")
local bufcalls = {}
reaper.StudioSync_LiveAudioPeerBuffer = function(peer, fl, ce) bufcalls[#bufcalls + 1] = peer .. " " .. fl .. " " .. ce; E.peers[peer].floor_ms, E.peers[peer].ceiling_ms = fl, ce; return 1 end
la.apply()
assert(#bufcalls == 1 and bufcalls[1] == "bee-laptop.tail99.ts.net:47281 30 150", "an extension that adapts: the defaults handed over once: " .. table.concat(bufcalls, ","))
la.apply()
assert(#bufcalls == 1, "and not again while they hold")
la.set_buffer("bee-laptop.tail99.ts.net:47281", 20, 90)
assert(bufcalls[2] == "bee-laptop.tail99.ts.net:47281 20 90" and la.buffers()["bee-laptop"].floor == 20, "a bandmate's own bounds, kept by name")
la.set_buffer("bee-laptop.tail99.ts.net:47281", 30, 150)
assert(la.buffers()["bee-laptop"] == nil, "back to the defaults: nothing kept")
reaper.StudioSync_LiveAudioPeerBuffer = nil
ok, text = la.health_text({ nch = 1, kbps = 128, peers = {} })
assert(not ok and text:find("nobody else here yet", 1, true), "alone: said, not green")
row = la.health_row(cfg)
assert(row[1] == "live audio" and row[4]:find("bee-laptop 42 ms", 1, true), "running: per bandmate in Health")
local rows = direct.health_rows(cfg)
local found = false
for _, r in ipairs(rows) do found = found or r[1] == "live audio" end
assert(found or rows[1][1] == "menu ext", "the live audio row is among the link's Health rows")
local saved = reaper.StudioSync_LiveAudioStart
reaper.StudioSync_LiveAudioStart = nil
row = la.health_row(cfg)
assert(row[3] == "yellow" and row[5]:find("extension", 1, true), "an extension without live audio: said")
reaper.StudioSync_LiveAudioStart = saved

-- ---- 5. Talk and Play (James, rt: "hear what a bandmate plays when they arm") ---------------------------------------------------------
la.set_mine(0, 1, 128) -- (the call mic: input 1)
-- which sources go: Auto, Talk only, Play only, Both, and the never-twice guard
local function sp(...) local t, p = la.source_plan(...); return tostring(t) .. "," .. tostring(p) end
assert(sp("auto", false, false, true) == "true,false", "Auto, nothing armed: Talk")
assert(sp("auto", true, false, true) == "true,true", "Auto, a track armed: Play, plus Talk")
assert(sp("auto", true, true, true) == "false,true", "Auto, the call mic is the armed track's input: once, as Play")
assert(sp("auto", true, false, false) == "true,false", "Auto, armed but Play can't go (no Hop plug-in): Talk as before")
assert(sp("talk", true, true, true) == "true,false", "Talk only: Talk, whatever's armed")
assert(sp("play", false, false, true) == "false,true" and sp("play", true, false, false) == "false,false", "Play only: never Talk (nothing when Play can't go)")
assert(sp("both", false, false, true) == "true,true" and sp("both", true, true, true) == "false,true", "Both, with the same guard")
-- the mic's state on top: mute and deafen silence both; push-to-talk and talkback are Talk's; held talk opens Talk, or Play when the mic goes as Play
local function mp(s, talk, play, folded) local t, only, p = la.mic_plan(s, true, talk, play, folded); return tostring(t) .. "," .. tostring(only) .. "," .. tostring(p) end
assert(mp({}, true, true, false) == "true,nil,true", "nothing held: both go")
assert(mp({ mute = true }, true, true, false) == "false,nil,false", "Mute me: neither")
assert(mp({ deaf = true }, true, true, false) == "false,nil,false", "Deafen: neither")
assert(mp({ ptt = true }, true, true, false) == "false,nil,true", "push-to-talk gates Talk only: arming is the ask for Play")
assert(mp({ mute = true, talking = true }, true, true, false) == "true,nil,false", "held talk while muted: Talk, not Play")
assert(mp({ mute = true, talking = true }, false, true, true) == "false,nil,true", "held talk while muted, the mic going as Play: Play, never Talk too")
assert(mp({ talking = true }, false, true, false) == "true,nil,true", "Play only, held talk: Talk opens for as long as it's held")
assert(mp({ talkback = "Bee" }, true, true, false) == "true,Bee,true", "talkback: Talk to Bee only, Play to everyone")
assert(mp({ talkback = "Bee", recording = true }, true, true, false) == "false,Bee,true", "talkback quiet while recording; Play goes on")
assert(la.play_gain(nil, { volume = 0.5 }) == 0.5 and la.play_gain({ play = 0.25 }, { volume = 2 }) == 0.5, "a Play level times the master")
assert(la.their_src("both") == "Talk + Play" and la.their_src(nil, { streaming = true, play_streaming = true }) == "Talk + Play"
  and la.their_src(nil, { streaming = true }) == "Talk" and la.their_src(nil, {}) == nil, "a bandmate's sources: their word, else their streams")
local st5 = la.sends_text({ mode = "auto", play = true, folded = true, armed = { "Vox" } }, { talk = false, play = true }, { play_alive = true })
assert(st5 == "sends Play (Vox) [Auto]; the call mic is an armed track's input, so it goes once, as Play", st5)
st5 = la.sends_text({ mode = "both", play = true, armed = {} }, { talk = true, play = true }, { play_alive = false })
assert(st5 == "sends Talk + Play (nothing armed: silence): the live out track isn't running [Both]", st5)
ok, text = la.health_text({ nch = 1, kbps = 128, peers = { ["bee-laptop.tail99.ts.net:47281"] = { resolved = true, streaming = true, play_streaming = true, latency_ms = 41.5, buffer_ms = 35, loss = 0 } } },
  nil, nil, nil, { mode = "auto", play = true, armed = { "Gtr" } }, { talk = true, play = true })
assert(text:find("this computer sends Talk + Play (Gtr) [Auto]", 1, true) and text:find("bee-laptop 42 ms (buffer 35 ms, loss 0.0%), playing", 1, true), text)
-- the cue mix keeps a Play level apart from Talk's
la.set_peer("bee-laptop.tail99.ts.net:47281", 0.5, false, 0.25)
la.set_peer("bee-laptop.tail99.ts.net:47281", 0.7, false)
assert(la.mix()["bee-laptop"].play == 0.25 and la.mix()["bee-laptop"].gain == 0.7, "a new Talk level keeps the Play level")

-- the tick with an extension that has Play, against a stand-in project: the live out track made with its Hop, the armed tracks sent post-FX
local tracks, nextid = {}, 0
local function mk(name, armed, input, tag)
  nextid = nextid + 1
  local tr = { id = nextid, name = name, ext = { band_local = tag or "" }, v = { I_RECARM = armed and 1 or 0, I_RECINPUT = input or 0, I_PERFFLAGS = 0 }, fx = 0, recv = {}, sends = {} }
  tracks[#tracks + 1] = tr
  return tr
end
local function idx(tr) for i, t in ipairs(tracks) do if t == tr then return i - 1 end end end
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return tracks[i + 1] end
reaper.GetSetMediaTrackInfo_String = function(tr, k, v, set) local key = k:gsub("^P_EXT:", ""); if set then tr.ext[key] = v; return true, v end; return true, tr.ext[key] or "" end
reaper.GetMediaTrackInfo_Value = function(tr, k) return tr.v[k] or 0 end
reaper.SetMediaTrackInfo_Value = function(tr, k, v) tr.v[k] = v end
reaper.GetTrackName = function(tr) return true, tr.name end
reaper.TrackFX_GetCount = function(tr) return tr.fx end
reaper.DeleteTrack = function(tr) table.remove(tracks, idx(tr) + 1) end
reaper.GetTrackStateChunk = function(tr) local c = "<TRACK\n"; for _, s in ipairs(tr.recv) do c = c .. "AUXRECV " .. idx(s) .. " 3 1 0 0 0 0 0 0 -1:U 0 -1 ''\n" end; return true, c .. ">" end
reaper.RemoveTrackSend = function(tr, cat, i) assert(cat == -1); table.remove(tr.recv, i + 1) end
reaper.CreateTrackSend = function(src, dst) dst.recv[#dst.recv + 1] = src; src.sends[#src.sends + 1] = {}; return #src.sends - 1 end
reaper.SetTrackSendInfo_Value = function(src, cat, i, k, v) src.sends[i + 1][k] = v end
local hop_added
package.loaded.mirror = { add_local_track = function(_, name, tag) return mk(name, false, 0, tag) end }
package.loaded.hops = { free_id = function() return 64 end, used_ids = function() return {} end,
  add_hop = function(tr, pos, id) if E.no_hop then return nil end; hop_added = id; tr.fx = 1; return 0 end }
local plays = {}
reaper.StudioSync_LiveAudioPlay = function(hop, send) plays[#plays + 1] = hop .. ":" .. send; E.play, E.play_send = hop, send == 1; return 1 end
reaper.StudioSync_LiveAudioPeerPlay = function(peer, g) E.peers[peer].play_gain = g; return 1 end
reaper.StudioSync_LiveAudioSend = function(peer, on) if peer == "" then E.send = on end; return 1 end
local st_was = reaper.StudioSync_LiveAudioStatus
reaper.StudioSync_LiveAudioStatus = function() local s = band.json_decode(st_was()); s.play, s.play_send = E.play or 0, E.play_send == true; return band.json_encode(s) end
local gtr, vox = mk("Gtr", false, 1), mk("Vox", false, 0) -- (the call mic is input 1 = 0: Vox's input)
tick()
assert(#tracks == 2 and E.send == 1 and la.my_src() == "talk", "nothing armed: Talk, and no live out track made")
gtr.v.I_RECARM = 1
tick()
local out = tracks[3]
assert(out and out.ext.band_local == "liveout" and out.ext.band_liveout_hop == "64" and hop_added == 64, "a track armed: the hidden live out track with its Hop")
assert(out.v.B_MAINSEND == 0 and out.v.B_SHOWINTCP == 0 and out.v.I_PERFFLAGS & 2 == 2, "heard by nobody here, out of sight, real time")
assert(#out.recv == 1 and out.recv[1] == gtr and gtr.sends[1].I_SENDMODE == 3, "the armed track sends to it post-FX")
assert(plays[#plays] == "64:1" and E.send == 1 and la.my_src() == "both", "Play on (hop 64) beside Talk")
assert(E.peers["bee-laptop.tail99.ts.net:47281"].play_gain == 0.25, "each bandmate's Play level handed over")
vox.v.I_RECARM = 1
tick()
assert(#out.recv == 2 and E.send == 0 and E.play_send == true and la.my_src() == "play", "the call mic's track armed too: it goes once, as Play")
assert(la.health_row(cfg)[4]:find("sends Play (Gtr, Vox) [Auto]; the call mic is an armed track's input", 1, true), la.health_row(cfg)[4])
la.set("mute", true)
assert(E.send == 0 and E.play_send == false and la.my_src() == "none", "Mute me: Play silent too")
la.set("mute", false)
la.set_source_mode("talk")
tick()
assert(#out.recv == 0 and E.send == 1 and plays[#plays] == "0:0" and la.my_src() == "talk", "Talk only: the sends gone, no Play stream")
la.set_source_mode("auto")
gtr.v.I_RECARM, vox.v.I_RECARM = 0, 0
tick()
assert(#out.recv == 0 and la.my_src() == "talk", "disarmed: Talk again")
la.on_exit("P1")
assert(#tracks == 2 and plays[#plays] == "0:0", "Live sync ends: the live out track goes, Play off")
print("ok")
