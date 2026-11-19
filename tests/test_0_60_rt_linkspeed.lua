-- Link speed per bandmate and "send anything" (extension 1.0.12, lib/direct.lua): which way Tailscale takes to each computer, whose computer
-- a peer is, the Health line ("Bo: 4.1 MB/s direct, 18 ms"), and the widened list of files the link takes. The window of frames in flight and
-- the rates themselves: tests/direct_test.cpp. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext = {}
local status_json = ""
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  file_exists = function() return false end,
  StudioSync_DirectStart = function() return 1 end,
  StudioSync_DirectSend = function() return 1 end,
  StudioSync_DirectStatus = function() return status_json end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
band.files = function() return { "Bo.json", "Chilio.json" } end
band.read_json = function(p)
  if p:find("Bo.json", 1, true) then return { user = "Bo", device = "BBBBBBBBBBBB", ts = { ["tail99.ts.net"] = "bo-pc.tail99.ts.net" } } end
  return { user = "Chilio", device = "CCCCCCCCCCCC", ts = { ["tail99.ts.net"] = "chilis-mac.tail99.ts.net" } }
end
band.home = function() return "H" end
band.info = function() return { id = "studiosync-smiley" } end
local ts_out = nil
package.loaded.services = { run_hidden = function(name) return name == "ts-peers" and ts_out or "" end, TMP = "T", tailscale_exe = function() return "C:/Program Files/Tailscale/tailscale.exe" end,
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "MMMMMMMMMMMM" end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function() return true end }
local direct = require("direct")

-- ---- send anything: the link's list ----
for _, n in ipairs({ "take.WAV", "ref.mp4", "ref.MOV", "clip.webm", "chart.pdf", "shot.png", "a.jpg", "a.jpeg", "notes.txt", "notes.md", "groove.mid",
    "patch.fxp", "bank.fxb", "p.vstpreset", "amp.nam", "kit.sfz", "set.als", "stems.zip" }) do
  assert(direct.stream_ext(n), "the link takes " .. n)
  assert(direct.stream_rel("Song", n) == "Song/" .. n, "a name the link takes: " .. n)
end
for _, n in ipairs({ "x.exe", "x.dll", "x.dylib", "x.so", "x.lua", "x.py", "x.sh", "x.bat", "x.cmd", "x.ps1", "x.js", "x.EXE", "x.rpp", "x.json", "noext", "x.zip.exe" }) do
  assert(not direct.stream_ext(n) and direct.stream_rel("Song", n) == nil, "never: " .. n)
end

-- ---- the way Tailscale takes (tailscale status --json, as 1.104 writes it) ----
local ts = [[{"BackendState":"Running","Peer":{
 "k1":{"HostName":"Bo-PC","DNSName":"bo-pc.tail99.ts.net.","CurAddr":"75.1.2.3:41641","Relay":"sea","PeerRelay":"","Active":true},
 "k2":{"HostName":"Chili's Mac","DNSName":"Chilis-Mac.tail99.ts.net.","CurAddr":"","Relay":"sea","PeerRelay":"","Active":true},
 "k3":{"HostName":"phone","DNSName":"phone.tail99.ts.net.","CurAddr":"","Relay":"ord","PeerRelay":"100.64.0.9:7","Active":true},
 "k4":{"HostName":"idle","DNSName":"idle.tail99.ts.net.","CurAddr":"","Relay":"sea","PeerRelay":"","Active":false}}}]]
local paths = direct.paths_in(ts)
assert(paths["bo-pc.tail99.ts.net"].path == "direct", "a current address: direct")
assert(paths["chilis-mac.tail99.ts.net"].path == "relay" and paths["chilis-mac.tail99.ts.net"].region == "sea", "no address, a DERP region: relayed (names lower case, no last dot)")
assert(paths["phone.tail99.ts.net"].path == "peer relay", "a peer relay")
assert(paths["idle.tail99.ts.net"] == nil, "a computer Tailscale isn't talking to: not known")
assert(next(direct.paths_in("")) == nil and next(direct.paths_in("{")) == nil and next(direct.paths_in('{"Peer":null}')) == nil, "no answer, half an answer: nothing")

-- ---- whose computer ----
local devs = { { user = "Bo", ts = { ["tail99.ts.net"] = "bo-pc.tail99.ts.net" } } }
assert(direct.who_of(devs, "Bo-PC.tail99.ts.net:47281") == "Bo", "the person, from the devices files")
assert(direct.who_of(devs, "someone.tail99.ts.net:47281") == "someone", "else the computer's first name")

-- ---- the Health line ----
local who = function(peer) return direct.who_of({ { user = "Bo", ts = { t = "bo-pc.tail99.ts.net" } }, { user = "Chilio", ts = { t = "chilis-mac.tail99.ts.net" } } }, peer) end
local ok, text = direct.speed_line_of({ { peer = "bo-pc.tail99.ts.net:47281", ok = true, rate = 4.1e6, rtt_ms = 18.2, ms = 30, path = "direct" } }, who)
assert(ok == true and text == "Link speed: Bo: 4.1 MB/s direct, 18 ms", text)
ok, text = direct.speed_line_of({ { peer = "bo-pc.tail99.ts.net:47281", ok = true, rate = 0, rtt_ms = -1, ms = 21, path = "direct" },
  { peer = "chilis-mac.tail99.ts.net:47281", ok = true, rate = 310e3, rtt_ms = 142, path = "relay", region = "sea" },
  { peer = "gone.tail99.ts.net:47281", ok = false, rate = 9e6 } }, who)
assert(ok == false and text:find("Bo: direct, 21 ms; Chilio: 310 KB/s relayed by Tailscale (sea), 142 ms", 1, true) and text:find("more bars", 1, true) and not text:find("gone", 1, true), text)
assert(direct.speed_line_of({ { peer = "x:1", ok = false } }, who) == nil and direct.speed_line_of({}, who) == nil, "nobody reached: no line")
ok, text = direct.speed_line_of({ { peer = "bo-pc.tail99.ts.net:47281", ok = true, rate = 2.5e6, ms = 40 } }, who)
assert(text == "Link speed: Bo: 2.5 MB/s, 40 ms", "no way known (Tailscale not asked yet): rate and round trip only: " .. text)

-- ---- through direct.status: the extension's JSON plus Tailscale's way ----
ts_out = ts
status_json = '{"listening":true,"bind":"100.64.0.1","port":47281,"received":3,"rejected":0,"queued":0,"messages":0,"error":"","last_reject":"","peers":{' ..
  '"bo-pc.tail99.ts.net:47281":{"ok":true,"ms":20.5,"at":1,"sent":4,"rate":4100000,"rate_at":2,"rtt_ms":18.0,"window":12,"error":""},' ..
  '"chilis-mac.tail99.ts.net:47281":{"ok":true,"ms":150.0,"at":1,"sent":1,"rate":0,"rate_at":0,"rtt_ms":141.0,"window":2,"error":""}}}'
local cfg = { root = "J:/St/Smiley" }
local s = direct.status(cfg)
assert(s.peers[1].rate == 4100000 and s.peers[1].window == 12 and s.peers[1].path == "direct" and s.peers[2].path == "relay" and s.peers[2].region == "sea", "status: rate, window and way")
ok, text = direct.speed_line(cfg)
assert(ok == false and text:find("Bo: 4.1 MB/s direct, 18 ms; Chilio: relayed by Tailscale (sea), 141 ms", 1, true), text)
print("ok   link speed and send anything")
