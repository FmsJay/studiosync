-- Live audio's mic (James, rt; lib/liveaudio.lua "My mic"): what's sent and heard from Mute me, Deafen, push-to-talk, held talk and talkback,
-- the master volume, the cue mix kept by bandmate name, the extension's send gate (StudioSync_LiveAudioSend) and the fallback without it (a
-- silent input), a held key's beat running out, the hold action's key and tail, the toggles' toolbar buttons, the echo warning, the word each
-- computer puts in its status and the Health row that reads it ("Mac not connected: needs extension 1.0.13").
package.path = "lib/?.lua;" .. package.path
local clock, ext, front = 1000, {}, "P1"
local toggles, deferred, at_exit, keys = {}, {}, nil, ""
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetAppVersion = function() return "7.79/win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  EnumProjects = function() return front end,
  get_action_context = function() return false, "x.lua", 0, 4242 end,
  SetToggleCommandState = function(sec, cmd, on) toggles[sec .. ":" .. cmd] = on end,
  RefreshToolbar2 = function() end,
  defer = function(f) deferred[#deferred + 1] = f end,
  atexit = function(f) at_exit = f end,
  set_action_options = function() end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") and not tostring(k):find("^JS_") then return function() return "" end end end })

local band = require("band")
band.log = function() end
package.loaded.services = { run_hidden = function() return "Rule Name: StudioSync direct link\r\nLocalPort: 47281\r\nProtocol: TCP\r\nProgram: C:\\REAPER\\reaper.exe\r\n\r\nRule Name: StudioSync direct link\r\nLocalPort: 47281\r\nProtocol: UDP\r\nProgram: C:\\REAPER\\reaper.exe\r\n" end, TMP = "T" }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end,
  sonobus_secret = function() return "s3cret" end, live_audio = function() return true end }
package.loaded.tools = { EXT_WANT = "1.0.13" }
local statuses = {}
package.loaded.presence = { peers = function() return statuses end }
local direct = require("direct")
local BO, MAC = "bo-pc.tail99.ts.net:47281", "chilis-mac.tail99.ts.net:47281"
direct.peers = function() return { BO, MAC }, {}, { [BO] = "Bo", [MAC] = "Chilio" } end
local la = require("liveaudio")
local cfg = { root = "J:/St/Smiley", user = "James" }
local K = band.SECTION .. "/live audio "

-- ---- 1. pure ----------------------------------------------------------------------------------------------------------------------------
assert(la.held("", 5) == false, "nothing held")
assert(la.held("4.8", 5) == true and la.held("4.3", 5) == false, "a beat counts for HELD seconds, so a dead script's runs out")
local on, name = la.held("latch Bo Smith", 99)
assert(on and name == "Bo Smith", "a latch, with a name that has a space")
on, name = la.held("4.9 Bo", 5)
assert(on and name == "Bo", "held, to Bo")
local function plan(s, gate) local o, only = la.send_plan(s, gate); return tostring(o) .. "/" .. tostring(only) end
assert(plan({}, true) == "true/nil", "the default: heard by everyone (sending on, the point of a live studio)")
assert(plan({ mute = true }, true) == "false/nil" and plan({ deaf = true }, true) == "false/nil" and plan({ ptt = true }, true) == "false/nil",
  "muted, deafened (as call apps: it stops sending too) or push-to-talk: nothing goes")
assert(plan({ mute = true, talking = true }, true) == "true/nil" and plan({ ptt = true, talking = true }, true) == "true/nil", "held talk wins while it's held")
assert(plan({ mute = true, talkback = "Bo" }, true) == "true/Bo", "talkback: only Bo")
assert(plan({ talkback = "Bo" }, false) == "false/Bo", "talkback without the extension's per-bandmate send: nothing, never everyone")
local g, m = la.hear_plan({ gain = 0.5 }, { volume = 2 })
assert(g == 1 and m == false, "their level times the master")
g, m = la.hear_plan(nil, { volume = 1, deaf = true })
assert(g == 1 and m == true, "deafened: everyone off")
g, m = la.hear_plan({ gain = 4, mute = true }, { volume = 4 })
assert(g == 4 and m == true, "kept within what the extension takes; their own mute stays")
assert(la.mic_label({}, true) == "Mic live" and la.mic_label({ mute = true }, true) == "Muted" and la.mic_label({ mute = true }, true, 0.3) == "Muted (you're talking)",
  "the top bar: live, muted, and muted while the input moves")
assert(la.mic_label({ ptt = true }, true) == "Push to talk" and la.mic_label({ ptt = true, talking = true }, true) == "Talking" and la.mic_label({ deaf = true }, true) == "Deafened"
  and la.mic_label({ talkback = "Bo" }, true) == "Talkback: Bo", "push-to-talk, talking, deafened, talkback")
assert(la.input_overlaps(2, 2, 1) and la.input_overlaps(1024 + 1, 2, 1) and not la.input_overlaps(1024 + 3, 2, 1) and la.input_overlaps(3, 2, 2),
  "a track's input against the inputs sent: mono, a stereo pair over it, one beside it, a sent pair")
assert(not la.input_overlaps(-1, 0, 1) and not la.input_overlaps(4096 + 2, 2, 1), "no input, or MIDI: never")
assert(la.echo_why({ "Stereo Mix (Realtek)" }, nil, 0, true):find("loopback", 1, true), "a loopback input: the others would hear themselves")
assert(la.echo_why({ "Mic 1" }, "Vox", 0.2, true):find("track Vox", 1, true), "REAPER monitoring the input sent while it's live")
assert(la.echo_why({ "Mic 1" }, "Vox", 0.001, true) == nil, "monitored but silent: nothing yet")
assert(la.echo_why({ "Stereo Mix" }, "Vox", 0.5, false) == nil, "muted: no echo to warn of")
assert(la.echo_why({ "Focusrite In 1" }, nil, 0.5, true) == nil, "an ordinary input, not monitored: fine")
assert(select(2, la.why_not(false)) == "off" and select(2, la.why_not(true, false)) == "ext" and select(2, la.why_not(true, true, nil)) == "tailscale"
  and select(2, la.why_not(true, true, "s", false)) == "firewall", "a word for each reason, for the status file")
local p, seen, users = direct.peers_from({ { user = "Bo", device = "BBBBBBBBBBBB", ts = { ["tail99.ts.net"] = "bo-pc.tail99.ts.net" } } }, "tail99.ts.net", "ME", 47281)
assert(p[1] == BO and seen[BO] == "BBBBBBBBBBBB" and users[BO] == "Bo", "the link's peers say whose computer each is")

-- ---- 2. Health: by name, and why someone isn't heard ----------------------------------------------------------------------------------
local st = { nch = 1, kbps = 128, peers = { [BO] = { resolved = true, streaming = true, latency_ms = 67.6, buffer_ms = 30, loss = 0 },
  [MAC] = { resolved = true, streaming = false } } }
local ok, text = la.health_text(st, { [BO] = "Bo", [MAC] = "Chilio" }, { Chilio = "ext", Bo = "muted" }, {})
assert(not ok and text:find("hearing Bo 68 ms (buffer 30 ms, loss 0.0%), muted", 1, true) and text:find("Chilio not connected: needs extension 1.0.13", 1, true), text)
ok, text = la.health_text({ nch = 1, kbps = 128, peers = { [BO] = st.peers[BO] } }, { [BO] = "Bo" }, { Kai = "tailscale" }, { mute = true })
assert(not ok and text:find("(muted)", 1, true) and text:find("Kai not connected: not on the studio's Tailscale", 1, true), "here but not on the list: still said: " .. text)
ok, text = la.health_text({ nch = 1, kbps = 128, peers = { [BO] = st.peers[BO] } }, { [BO] = "Bo" }, { Bo = "on" }, { ptt = true })
assert(ok and text:find("(push-to-talk)", 1, true) and not text:find("on)", 1, true), text)

-- ---- 3. against a stand-in extension -------------------------------------------------------------------------------------------------
local E = { running = false, calls = {}, send = {}, all = true }
local function reset_peers() E.peers = { [BO] = { resolved = true, streaming = true, gain = 1, mute = false, level = 0.2 }, [MAC] = { resolved = true, streaming = true, gain = 1, mute = false } } end
reset_peers()
reaper.StudioSync_LiveAudioPeers = function(js) E.json = js; return 2 end
reaper.StudioSync_LiveAudioStart = function(first, nch, kbps) E.calls[#E.calls + 1] = "start " .. first; E.running, E.first, E.nch, E.kbps = true, first, nch, kbps; reset_peers(); return 1 end
reaper.StudioSync_LiveAudioStop = function() E.calls[#E.calls + 1] = "stop"; E.running = false end
reaper.StudioSync_LiveAudioPeerSet = function(peer, gain, mute) if E.peers[peer] then E.peers[peer].gain, E.peers[peer].mute = gain, mute == 1 end; return 1 end
reaper.StudioSync_LiveAudioStatus = function() return band.json_encode({ running = E.running, first = E.first, nch = E.nch, kbps = E.kbps, level = 0.3, peers = E.peers }) end
reaper.StudioSync_LiveAudioSend = function(peer, v) if peer == "" then E.all = v == 1 else E.send[peer] = v == 1 end; return 1 end
local b = { song = "Nostalgia", room = "main" }
local function tick() clock = clock + 1; la.tick(cfg, b, "P1") end

tick()
assert(E.running and E.all and E.send[BO] and E.send[MAC], "on by default: heard by everyone")
assert(band.json_decode(ext[K .. "names"])[BO] == "Bo", "who's who, kept for the panel and the actions")
assert(la.my_la() == "on", "the status word: on")
la.set("mute", true)
assert(not E.all and ext[K .. "mute"] == "1", "Mute me: silence at once, no restart, kept")
assert(#E.calls == 1, "no restart for it")
assert(la.my_la() == "muted", "the status word: muted")
la.set("mute", false)
assert(E.all, "unmuted at once")
la.set("deaf", true)
assert(not E.all and E.peers[BO].mute and E.peers[MAC].mute, "Deafen: nobody heard, and nothing sent")
la.set("deaf", false)
assert(E.all and not E.peers[BO].mute and not E.peers[MAC].mute, "and back")
la.set_peer(BO, 0.5, false)
assert(E.peers[BO].gain == 0.5 and band.json_decode(ext[K .. "mix"]).Bo.gain == 0.5, "the cue mix: set at once, kept for Bo by name")
la.set_volume(2)
assert(E.peers[BO].gain == 1 and E.peers[MAC].gain == 2, "the master on top of each one's level")
la.set_volume(1)
-- Bo's computer gets a new name: the level follows Bo
E.peers = { ["bo-new.tail99.ts.net:47281"] = { resolved = true, streaming = true, gain = 1, mute = false } }
direct.peers = function() return { "bo-new.tail99.ts.net:47281" }, {}, { ["bo-new.tail99.ts.net:47281"] = "Bo" } end
tick()
assert(E.peers["bo-new.tail99.ts.net:47281"].gain == 0.5, "a new address, the same Bo: their level comes along")
direct.peers = function() return { BO, MAC }, {}, { [BO] = "Bo", [MAC] = "Chilio" } end
reset_peers()
tick()
-- an old mix kept by address still counts
ext[band.SECTION .. "/live audio mix"] = band.json_encode({ [MAC] = { gain = 0.25, mute = false } })
tick()
assert(E.peers[MAC].gain == 0.25, "a mix kept by address before still counts")
-- push-to-talk and held talk
la.set("ptt", true)
assert(not E.all and la.my_la() == "ptt", "push-to-talk: silent until held")
la.hold("talking", true)
assert(E.all, "held: heard at once")
clock = clock + la.HELD + 0.1
la.poll()
assert(not E.all, "a beat that isn't renewed runs out (a crashed script never leaves the mic open)")
la.hold("talking", true)
la.hold("talking", "tail")
assert(E.all, "let go: still heard for the tail")
clock = clock + la.TAIL + 0.01
la.poll()
assert(not E.all, "then not")
la.set("ptt", false)
-- talkback
la.set("mute", true)
la.hold("talkback", true, "Chilio")
assert(E.all and E.send[MAC] and not E.send[BO], "talkback to Chilio: only Chilio gets it")
la.hold("talkback", nil)
assert(not E.all and E.send[MAC] and E.send[BO], "let go: everyone again (muted)")
la.set("mute", false)
tick()

-- ---- 4. without the extension's send gate: Mute me as a silent input ---------------------------------------------------------------------
local gate = reaper.StudioSync_LiveAudioSend
reaper.StudioSync_LiveAudioSend = nil
la.set("mute", true)
tick()
assert(E.calls[#E.calls - 1] == "stop" and E.calls[#E.calls] == "start " .. la.SILENT, "muted, old extension: started again on an input that isn't there")
la.set("mute", false)
tick()
assert(E.calls[#E.calls] == "start 0", "unmuted: back on the real input")
la.hold("talkback", true, "Bo")
assert(not la.send_plan(la.me(), la.can_gate()), "talkback can't go to one alone: nothing goes")
la.hold("talkback", nil)
reaper.StudioSync_LiveAudioSend = gate
tick()

-- ---- 5. the actions -------------------------------------------------------------------------------------------------------------------
la.action_toggle("mute")
assert(ext[K .. "mute"] == "1" and toggles["0:4242"] == 1 and ext[K .. "mute cmd"] == "0:4242", "Mute me action: muted, its button lit")
la.set("mute", false) -- (the panel's click)
assert(toggles["0:4242"] == 0, "the panel unmutes: the action's button follows")
-- hold to talk with a key held
la.set("ptt", true)
reaper.JS_VKeys_GetState = function() return keys end
keys = string.rep("\0", 31) .. "\1" .. string.rep("\0", 223) -- (space down)
la.action_hold("talking")
assert(E.all and toggles["0:4242"] == 1, "the hold action: heard while the key is held, its button lit")
local function run_deferred() local f = table.remove(deferred, 1); if f then f() end; return f ~= nil end
clock = clock + 2
run_deferred()
assert(E.all, "still held after two seconds (the beat renewed)")
keys = string.rep("\0", 255)
clock = clock + 0.05
run_deferred()
assert(E.all, "let go: the tail")
clock = clock + la.TAIL
run_deferred()
assert(not E.all and toggles["0:4242"] == 0 and #deferred == 0, "then off, its button dark, and the script ends")
-- from a toolbar button: a latch
keys = string.rep("\0", 255)
la.action_hold("talking")
assert(E.all and ext[K .. "talking"] == "latch", "no key down: a latch")
clock = clock + 60
la.poll()
assert(E.all, "a latch doesn't run out")
la.action_hold("talking")
assert(not E.all and ext[K .. "talking"] == nil, "run again: off")
la.set("ptt", false)
-- talkback with nobody chosen
local said
band.msg = function(s) said = s end
la.action_hold("talkback")
assert(said and said:find("Chat > Call", 1, true), "talkback before anyone is chosen: says where to choose")
reaper.JS_VKeys_GetState = nil

-- ---- 6. the status word without live audio here, and the Health row reading it ------------------------------------------------------
local saved = reaper.StudioSync_LiveAudioStart
reaper.StudioSync_LiveAudioStart = nil
tick()
assert(la.my_la() == "ext", "no live audio in this extension: the others' Health says so")
reaper.StudioSync_LiveAudioStart = saved
tick()
statuses = { { user = "Chilio", la = "ext" }, { user = "Bo", la = "on" } }
E.peers[MAC].streaming = false
local row = la.health_row(cfg, b)
assert(row and row[1] == "live audio" and row[5]:find("Chilio not connected: needs extension 1.0.13", 1, true) and row[5]:find("hearing Bo", 1, true), row and row[5])
assert(band.shown_action("Live audio mute me", false, false) and band.shown_action("Live audio hold to talk", false, false), "the actions are in the list, to get a key")
print("ok")
