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
  sonobus_secret = function() return secret end, live_audio = function() return trusted.live_audio == true end }
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

tick()
assert(#E.calls == 0 and la.S.why == "off for this studio", "off by default: nothing starts")
assert(la.health_row(cfg) == nil, "and Health says nothing")
trusted.live_audio = true
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
assert(ok and text == "Live audio: sending 1 input at 128 kbit/s; bee-laptop 42 ms (buffer 35 ms, loss 0.2%)", text)
ok, text = la.health_text({ nch = 2, kbps = 192, rejected = 3, last_reject = "wrong studio secret", peers = {
  ["bee-laptop.tail99.ts.net:47281"] = { resolved = true, streaming = true, latency_ms = 60, buffer_ms = 50, loss = 0.08 },
  ["mac.tail99.ts.net:47281"] = { resolved = true, streaming = false },
  ["old.tail99.ts.net:47281"] = { resolved = false, error = "not a Tailscale address" } } })
assert(not ok and text:find("2 inputs at 192", 1, true) and text:find("loss 8.0%", 1, true) and text:find("mac: not heard yet", 1, true)
  and text:find("old: can't reach (not a Tailscale address)", 1, true) and text:find("refused 3 (last: wrong studio secret)", 1, true), text)
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
print("ok")
