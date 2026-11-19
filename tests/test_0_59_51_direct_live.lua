-- The direct link's live layer (extension 1.0.8, lib/direct.lua): messages, the shared clock's reference and "shared now", stream names,
-- and nothing at all with an older extension. The sockets, the clock's accuracy and streams themselves: tests/direct_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  file_exists = function() return false end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end }) -- (the extension's: absent)

local band = require("band")
band.files = function() return {} end
band.home = function() return "H" end
band.info = function() return { id = "studiosync-smiley" } end
package.loaded.services = { run_hidden = function() return "StudioSync direct link C:\\REAPER\\reaper.exe 47281" end, TMP = "T",
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "MMMMMMMMMMMM" end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end,
  sonobus_secret = function() return "s3cret" end }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function() return true end }
local here = { "James-Laptop", "Chilio-Mac" }
package.loaded.presence = { peers = function() local t = {}; for _, u in ipairs(here) do t[#t + 1] = { user = u } end; return t end }
package.loaded.access = { read = function() return nil end, shows = function() return true end }
local direct = require("direct")
local cfg = { root = "J:/St/Smiley" }

-- Pure parts
local seq, studio, kind, data = direct.parse_msg("12\tstudiosync-smiley\tchat\t{\"t\":\"a\tb\"}")
assert(seq == 12 and studio == "studiosync-smiley" and kind == "chat" and data == '{"t":"a\tb"}', "a polled message, tabs in its data kept")
assert(direct.parse_msg("") == nil and direct.parse_msg("x\ty") == nil, "nothing, or not one")
assert(direct.stream_rel("Nostalgia", "J:\\St\\Smiley\\Nostalgia\\Media\\James take 03.WAV") == "Nostalgia/James take 03.WAV", "a take's stream name")
for _, bad in ipairs({ { "Nostalgia", "x.json" }, { "../x", "a.wav" }, { ".hid", "a.wav" }, { "S", ".a.wav" }, { "S", "a.wav." }, { "S", "noext" }, { "S:", "a.wav" } }) do
  assert(direct.stream_rel(bad[1], bad[2]) == nil, "refused: " .. bad[1] .. " " .. bad[2])
end
local devs = { ["a.tail99.ts.net:47281"] = "BBBBBBBBBBBB", ["b.tail99.ts.net:47281"] = "AAAAAAAAAAAA" }
local est = { ["a.tail99.ts.net:47281"] = { samples = 16, error = "" }, ["b.tail99.ts.net:47281"] = { samples = 16, error = "" } }
local p, d = direct.clock_reference("MMMMMMMMMMMM", devs, est)
assert(p == "b.tail99.ts.net:47281" and d == "AAAAAAAAAAAA", "the reference: the lowest device id reached")
est["b.tail99.ts.net:47281"].error = "no answer"
p, d = direct.clock_reference("MMMMMMMMMMMM", devs, est)
assert(p == "a.tail99.ts.net:47281" and d == "BBBBBBBBBBBB", "one that can't be reached is skipped")
est["a.tail99.ts.net:47281"].samples = 2
p, d = direct.clock_reference("MMMMMMMMMMMM", devs, est)
assert(p == nil and d == "MMMMMMMMMMMM", "nobody with an estimate yet: this computer's own clock")
p, d = direct.clock_reference("000000000000", devs, { ["a.tail99.ts.net:47281"] = { samples = 16 } })
assert(p == nil and d == "000000000000", "this computer, when its id is the lowest")
local list, dev_of = direct.peers_from({ { user = "L", device = "LLLLLLLLLLLL", ts = { ["tail99.ts.net"] = "l.tail99.ts.net" } } }, "tail99.ts.net", "ME", 47281)
assert(list[1] == "l.tail99.ts.net:47281" and dev_of["l.tail99.ts.net:47281"] == "LLLLLLLLLLLL", "peers_from also says which computer each peer is")

-- An older extension: nothing happens, nothing raises
assert(direct.live_available() == false and direct.msg(cfg, "chat", { t = 1 }, "S", "main") == false and #direct.messages(cfg) == 0, "no messages")
assert(direct.keep_clock(cfg, "S", "main") == false and direct.shared_now() == nil, "no clock: callers keep their own")
assert(direct.stream_start(cfg, "J:/x/S/a.wav", "S", "main") == nil and direct.stream_end(cfg, "S/a.wav") == false and #direct.streams(cfg).inn == 0, "no streams")

-- A stand-in 1.0.8 extension
local calls, inbox_msgs = {}, {}
local function call(name, ...) calls[#calls + 1] = { name, ... } end
reaper.StudioSync_DirectStart = function(...) call("start", ...); return 1 end
reaper.StudioSync_DirectStop = function() end
reaper.StudioSync_DirectSend = function() return 1 end
reaper.StudioSync_DirectStatus = function() return "{}" end
reaper.StudioSync_DirectPoll = function() return "" end
reaper.StudioSync_DirectMsg = function(...) call("msg", ...); return 1 end
reaper.StudioSync_DirectMsgPoll = function(after) for _, s in ipairs(inbox_msgs) do if tonumber(s:match("^%d+")) > after then return s end end; return "" end
reaper.StudioSync_DirectPeers = function(...) call("peers", ...); return 2 end
local clock_json = '{"now":1795100000.5,"peers":{}}'
reaper.StudioSync_DirectClock = function() return clock_json end
reaper.StudioSync_DirectNow = function() return 1795100000.5 end
reaper.StudioSync_DirectStream = function(...) call("stream", ...); return 1 end
reaper.StudioSync_DirectStreamEnd = function(...) call("end", ...); return 1 end
reaper.StudioSync_DirectStreams = function()
  return '{"out":[{"studio":"studiosync-smiley","rel":"S/a.wav","size":10,"ended":false,"finished":false,"peers":{}}],"in":[{"studio":"other","rel":"S/b.wav"},{"studio":"studiosync-smiley","rel":"S/c.wav","path":"H/direct/studiosync-smiley/.streams/S/c.wav","bytes":5,"done":false,"playable":true}]}'
end
local devfiles = { ["James-Laptop.json"] = { user = "James-Laptop", device = "LLLLLLLLLLLL", ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net" } },
  ["Chilio-Mac.json"] = { user = "Chilio-Mac", device = "CCCCCCCCCCCC", ts = { ["tail99.ts.net"] = "chilis-macbook-pro.tail99.ts.net" } } }
band.files = function(dir) if dir:find("_band/devices") then return { "James-Laptop.json", "Chilio-Mac.json" } end; return {} end
band.read_json = function(path) return devfiles[path:match("[^/]+$")] end
assert(direct.live_available(), "1.0.8")

assert(direct.msg(cfg, "chat", { user = "James", text = "hi" }, "S", "main") == true, "a message is queued")
local m = calls[#calls]
assert(m[1] == "msg" and m[2] == "studiosync-smiley" and m[3] == "chat" and m[4] == '{"text":"hi","user":"James"}'
  and m[5] == "chilis-macbook-pro.tail99.ts.net:47281 james-laptop.tail99.ts.net:47281", "as JSON, to whoever's here")
assert(direct.msg(cfg, "chat", string.rep("x", 70000), "S", "main") == false, "over 64 KB: not sent")
here = {}
assert(direct.msg(cfg, "chat", "x", "S", "main") == false, "nobody here: nothing sent")
here = { "James-Laptop", "Chilio-Mac" }

inbox_msgs = { "1\tstudiosync-smiley\tcue\t{\"bar\":17}", "2\tother-studio\tchat\thi", "3\tstudiosync-smiley\tchat\tplain text" }
local got = direct.messages(cfg)
assert(#got == 2 and got[1].kind == "cue" and got[1].data.bar == 17 and got[2].text == "plain text" and got[2].data == nil, "this studio's, JSON decoded")
assert(#direct.messages(cfg) == 0, "and not again: this script's own place")

assert(direct.keep_clock(cfg, "S", "main") == true, "the clock kept")
m = calls[#calls]
assert(m[1] == "peers" and m[3] == "chilis-macbook-pro.tail99.ts.net:47281 james-laptop.tail99.ts.net:47281", "with whoever's here")
local n = #calls
direct.keep_clock(cfg, "S", "main")
assert(#calls == n, "not handed over again within 10 s")
local now, ref, err = direct.shared_now()
assert(now == 1795100000.5 and ref == "MMMMMMMMMMMM" and err == 0, "no estimates yet: this computer's clock")
clock_json = '{"now":1795100000.5,"peers":{"chilis-macbook-pro.tail99.ts.net:47281":{"offset_ms":250,"rtt_ms":40,"samples":16,"error":""},' ..
  '"james-laptop.tail99.ts.net:47281":{"offset_ms":322.5,"rtt_ms":57,"samples":16,"error":""}}}'
now, ref, err = direct.shared_now()
assert(math.abs(now - 1795100000.75) < 1e-6 and ref == "CCCCCCCCCCCC" and err == 20, "the lowest device id's clock (the Mac's here), and its error bound")

local rel = direct.stream_start(cfg, "J:\\St\\Smiley\\S\\Media\\a.wav", "S", "main", 100)
m = calls[#calls]
assert(rel == "S/a.wav" and m[1] == "stream" and m[3] == "S/a.wav" and m[4] == "J:\\St\\Smiley\\S\\Media\\a.wav" and m[6] == 100, "a take streamed to whoever's here")
assert(direct.stream_end(cfg, rel) == true and calls[#calls][1] == "end", "ended")
local ss = direct.streams(cfg)
assert(#ss.out == 1 and #ss.inn == 1 and ss.inn[1].rel == "S/c.wav" and ss.inn[1].playable, "this studio's streams, out and in")
assert(direct.stream_path(cfg, "S/c.wav") == "H/direct/studiosync-smiley/.streams/S/c.wav", "where a stream arrives")
print("ok")
