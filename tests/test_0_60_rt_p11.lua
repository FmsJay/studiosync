-- rt-p11 (docs/rt/rt-p11.md, backlog package P11): audio on the browser side. The listening links' live indicator and "who's playing" count a
-- bandmate whose own status says their transport plays (live audio on here or not); the browser side's drift (the guest page, the screen
-- share's REAPER mix, the listening page) through Node (tests/rt_p11_drift_test.js) when it's here. The extension's halves:
-- tests/rtaudio_test.cpp (Play's resync, its counters, the ears tap) and tests/webui_test.cpp (four guests, hearing each other, heard by
-- listeners, the up ring's drift).
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({ time_precise = function() return 1000 end, GetOS = function() return "Win64" end },
  { __index = function() return function() return "" end end })
package.loaded.liveaudio = { status = function() return {} end, names = function() return {} end, name_of = function(p) return p end }
local au = require("audience")
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end

-- ---- the live indicator: a bandmate playing while this computer's live audio is off ----------------------------------------------------
local sts = { { user = "Chilio", playing = true }, { user = "Bo", recording = true }, { user = "Kim" }, { user = "Zed", playing = "yes" } }
local bp = au.band_playing(sts)
table.sort(bp)
assert(#bp == 2 and bp[1] == "Bo" and bp[2] == "Chilio", "band_playing: whose status says playing or recording (true only)")
assert(#au.band_playing(nil) == 0 and #au.band_playing({ "x", 3 }) == 0, "band_playing: nothing usable, nobody")
local who = au.who("James", false, {}, function(p) return p end, sts)
assert(#who == 2 and who[1] == "Bo" and who[2] == "Chilio", "who: bandmates playing by their status, live audio off here (it said nobody)")
local la = { peers = { ["chilio-mac:47281"] = { streaming = true, level = 0.2 } } }
who = au.who("James", true, la, function() return "Chilio" end, { { user = "Chilio", playing = true } })
assert(#who == 2 and who[1] == "James" and who[2] == "Chilio", "who: a bandmate heard and playing is named once")
assert(#au.who("James", false, {}, function(p) return p end) == 0, "who: no statuses given, as before")
local src = read("lib/audience.lua")
assert(src:find('local live = audience.playing(ps, la) or #audience.band_playing(sts) > 0', 1, true)
  and src:find('pcall(require("presence").peers, cfg, b.song, b.room or "main")', 1, true), "tick: the indicator and who come from the statuses too")

-- ---- a screen share's duck goes by computer: a bandmate's other computer in the room keeps its Play (backlog 1.24) ----------------------
do
  local ducks_applied = 0
  package.loaded.liveaudio.ducks, package.loaded.liveaudio.apply = {}, function() ducks_applied = ducks_applied + 1 end
  package.loaded.services = { is_device_id = function(s) return type(s) == "string" and s:match("^dev%w+$") ~= nil end, my_device_id = function() return "devme" end }
  local peers, dev_of = { "chilio-mac.ts.net:47281", "chilio-pc.ts.net:47281" }, { ["chilio-mac.ts.net:47281"] = "devmac", ["chilio-pc.ts.net:47281"] = "devpc" }
  package.loaded.direct = { peers = function() return peers, dev_of end }
  local wc = require("webcall")
  local cfg, b = { user = "James" }, { song = "S", room = "main" }
  assert(wc.link(cfg, b, { t = "here", user = "Chilio", dev = "devmac" }, 100) and wc.link(cfg, b, { t = "here", user = "Chilio", dev = "devpc" }, 100), "both of Chilio's pages open")
  assert(wc.local_msg({ t = "duck", to = "devmac", on = true }, 50), "a duck for the Mac's share")
  local la = package.loaded.liveaudio
  assert(la.ducks["chilio-mac.ts.net:47281"] == 50 + wc.DUCK_FOR and la.ducks.Chilio == nil and la.ducks["chilio-pc.ts.net:47281"] == nil,
    "only the sharing computer's Play is ducked (it was by name: both of Chilio's computers)")
  assert(wc.local_msg({ t = "duck", to = "devmac", on = false }, 60) and la.ducks["chilio-mac.ts.net:47281"] == nil and ducks_applied == 2, "and let go")
  local lsrc = read("lib/liveaudio.lua")
  assert(lsrc:find("(liveaudio.ducks[peer] or liveaudio.ducks[name] or -math.huge)", 1, true), "liveaudio.apply reads a duck by peer, or by name (Jam's)")
end

-- ---- the master's output pair (backlog 1.24: a master routed off the first pair wasn't heard in a share, by guests or listeners) --------
do
  local stub = package.loaded.liveaudio
  package.loaded.liveaudio = nil
  local ok, la = pcall(require, "liveaudio")
  assert(ok and type(la.out_pair) == "function", "liveaudio loads: " .. tostring(la))
  assert(la.out_pair({ 2 }) == 2 and la.out_pair({}) == 0 and la.out_pair(nil) == 0, "out_pair: the master's hardware output's first channel; none: the first pair")
  assert(la.out_pair({ 512 + 4, 2 | 1024 }) == 2, "out_pair: a ReaRoute output skipped; a mono one's channel")
  local lsrc = read("lib/liveaudio.lua")
  assert(lsrc:find("pcall(tell_out_pair, proj)", 1, true) and lsrc:find('reaper.StudioSync_LiveAudioOutPair(first)', 1, true), "the tick tells the extension")
  local rsrc = read("extension/rtaudio.cpp")
  assert(rsrc:find("hook_pair(reg, g_out_first.load(std::memory_order_relaxed), out)", 1, true), "the hook mixes into and feeds from that pair")
  package.loaded.liveaudio = stub
end

-- ---- System audio picked mid-share: asked for again, its sound only (backlog 1.24) ---------------------------------------------------
do
  local cj = read("lib/webui/call.js")
  local a = cj:find("let t = screen.getAudioTracks()[0], extra = null;", 1, true)
  local b2 = a and cj:find("extra = await navigator.mediaDevices.getDisplayMedia(", a, true)
  local c = b2 and cj:find("extra.getVideoTracks().forEach((v) => v.stop());", b2, true)
  assert(a and b2 and c and cj:find("src = systemSound(t, extra);", c, true), "call.js: a share without sound asks the picker again for it, keeps only its sound")
  assert(cj:find("if (extra) extra.getTracks().forEach((x) => x.stop()); } };", 1, true), "and that capture ends with the sound (No sound, another pick, the share's end)")
end

-- ---- the browser side's drift (Node) -----------------------------------------------------------------------------------------------------
for _, f in ipairs({ "lib/webui/guestworklet.js", "lib/webui/sharemix.js", "lib/webui/listen.js" }) do
  local s = read(f)
  assert(s:find("DRIFT_K", 1, true) or s:find("ssListenPace", 1, true), f .. ": the drift's rate")
end
local nh = io.popen and io.popen("node --version 2>&1")
local nv = nh and nh:read("a") or ""
if nh then nh:close() end
if nv:match("^v%d") then
  local h = io.popen("node tests/rt_p11_drift_test.js 2>&1")
  local out = h:read("a"); h:close()
  assert(out:match("ok, fails 0%s*$"), "the browser side's drift: " .. out)
else
  print("note: node isn't here, so the browser side's drift (tests/rt_p11_drift_test.js) wasn't run")
end
print("ok rt-p11")
