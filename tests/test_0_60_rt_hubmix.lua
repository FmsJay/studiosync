-- The hub's live mix (James, rt; docs/realtime-roadmap.md "More big ideas" 1; lib/liveaudio.lua hub_plan, the extension's side in
-- extension/rtaudio.cpp and tests/rtaudio_test.cpp): when the song's hub mixes (the studio's threshold, everyone's extension), the hub's
-- budget (paused while it records if it costs too much, or for a while past its share of a core), Health's words (through whose mix, the
-- hop's latency, how many it mixes for, fallbacks), and Live sync's tick handing it to a stand-in extension.
package.path = "lib/?.lua;" .. package.path
local clock, ext, front, playstate = 1000, {}, "P1", 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  EnumProjects = function() return front end,
  GetPlayState = function() return playstate end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end }) -- (the extension's: absent)

local band = require("band")
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
package.loaded.services = { run_hidden = function(name) return name == "direct-fw" and
  "Rule Name: StudioSync direct link\r\nLocalPort: 47281\r\nProtocol: UDP\r\nProgram: C:\\REAPER\\reaper.exe\r\n" or nil end, TMP = "T" }
local trusted = {}
package.loaded.groups = { trusted = function() return trusted end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end,
  sonobus_secret = function() return "s3cret" end, live_audio = function() return true end, live_hub = function() return tonumber(trusted.live_hub) end }
local view = nil
package.loaded.hub = { view = function() return view end, fit = function(e) return e == "1.0.28" end } -- (fit: lib/hub.lua's, the extension the hub's jobs need)
local statuses = {}
package.loaded.presence = { peers = function() return statuses end }
local direct = require("direct")
local BEE, MAC, LIN = "bee-laptop.tail99.ts.net:47281", "mac.tail99.ts.net:47281", "linuxbox.tail99.ts.net:47281"
local peers_here, users_here = { BEE, MAC }, { [BEE] = "Bee", [MAC] = "Chilio" }
direct.peers = function() return peers_here, {}, users_here end
local la = require("liveaudio")
local cfg = { root = "J:/St/Smiley", user = "James" }

-- ---- 1. who mixes (pure) ---------------------------------------------------------------------------------------------------------------
local all = { Bee = true, Chilio = true, Lin = true }
local four = { [BEE] = "Bee", [MAC] = "Chilio", [LIN] = "Lin" }
local function plan(o) local p, s, w = la.hub_plan(o); return p, s, w end
local p, s, w = plan({ n = 3, hub = "Bee", me = "James", users = { [BEE] = "Bee", [MAC] = "Chilio" }, caps = all, can = true })
assert(p == "" and s == false and w == nil, "three people: peer to peer (the default threshold is " .. la.HUB_FROM .. ")")
p, s, w = plan({ n = 4, hub = "Bee", me = "James", users = four, caps = all, can = true })
assert(p == BEE and s == false and w == nil, "four: through the song's hub, Bee")
p, s, w = plan({ n = 4, from = 0, hub = "Bee", me = "James", users = four, caps = all, can = true })
assert(p == "" and not s and w == nil, "the studio set never: peer to peer")
p, s, w = plan({ n = 3, from = 3, hub = "Bee", me = "James", users = { [BEE] = "Bee", [MAC] = "Chilio" }, caps = all, can = true })
assert(p == BEE, "the studio set three: three is enough")
p, s, w = plan({ n = 4, hub = "James", me = "James", users = four, caps = all, can = true })
assert(p == "" and s == true and w == nil, "this computer is the song's hub: it mixes")
p, s, w = plan({ n = 4, hub = "James", me = "James", users = four, caps = all, can = true, budget = false, budget_why = "paused while you record" })
assert(p == "" and s == false and w == "paused while you record", "its budget paused it: peer to peer, and Health says why")
-- (rt-hubfix: nobody waits for a bandmate's extension. It was: "waiting for Lin to have the newer StudioSync extension", and the room's audio
-- switched whenever Lin's status file came late. An older one keeps its own streams; only the hub's own must be new enough.)
p, s, w = plan({ n = 4, hub = "Bee", me = "James", users = four, caps = { Bee = true, Chilio = true }, can = true })
assert(p == BEE and w == nil, "someone's extension is older (or their status is late): the others still go through the hub")
p, s, w = plan({ n = 4, hub = "Bee", me = "James", users = four, can = true, hub_fit = false })
assert(p == "" and not s and w:find("Bee's StudioSync extension is too old", 1, true), "the hub's own extension is too old to mix: peer to peer, and why: " .. tostring(w))
p, s, w = plan({ n = 4, hub = "James", me = "James", users = four, can = true, hub_fit = false })
assert(p == "" and s == true, "(this computer as the hub goes by its own `can`)")
-- the room's size is held: big enough once, it stays so until it has been smaller for HUB_KEEP s
-- (rt-audio3: and big enough only once it has been so for HUB_SETTLE s: tests/test_0_60_rt_audio3.lua part 4; t0: the fourth is counted)
local nm, t0 = {}, 10 + la.HUB_SETTLE
assert(la.hub_n(nm, 3, 4, 0) == 3 and la.hub_n(nm, 4, 4, 10) == 3 and la.hub_n(nm, 4, 4, t0) == 4, "three, then four (once it has been four for HUB_SETTLE s)")
assert(la.hub_n(nm, 3, 4, t0 + 10) == 4 and la.hub_n(nm, 3, 4, t0 + la.HUB_KEEP - 1) == 4, "someone's status late for a moment: still counted as four")
assert(la.hub_n(nm, 3, 4, t0 + la.HUB_KEEP + 1) == 3, "gone for good: three")
p, s, w = plan({ n = 4, hub = "Bee", me = "James", users = four, caps = all, can = false })
assert(p == "" and w:find("extension here", 1, true), "this extension can't: said")
p, s, w = plan({ n = 4, hub = nil, me = "James", users = four, caps = all, can = true })
assert(p == "" and w:find("no hub", 1, true), "no song hub here (the cloud copy stands in): peer to peer")
p, s, w = plan({ n = 4, hub = "Dana", me = "James", users = four, caps = all, can = true })
assert(p == "" and w:find("Dana", 1, true) and w:find("direct link", 1, true), "a hub the link doesn't reach here: peer to peer")

-- ---- 2. the hub's budget (pure) --------------------------------------------------------------------------------------------------------
local mem = {}
local ok, why = la.hub_budget({ serve = true, serving = 3, load = 0.05, skipped = 0 }, false, mem, 0)
assert(ok and why == nil, "5% of a core: fine")
ok, why = la.hub_budget({ serve = true, serving = 3, load = 0.05, skipped = 0 }, true, mem, 1)
assert(ok, "recording at 5%: fine (under " .. la.HUB_REC_BUDGET * 100 .. "%)")
ok, why = la.hub_budget({ serve = true, serving = 3, load = 0.15, skipped = 0 }, true, mem, 2)
assert(not ok and why:find("while you record", 1, true) and why:find("15%", 1, true), "recording at 15%: paused: " .. tostring(why))
ok = la.hub_budget({ serve = false, serving = 0, load = 0, skipped = 0 }, true, mem, 3)
assert(not ok, "paused until the take ends (its load reads 0 meanwhile)")
ok = la.hub_budget({ serve = false, serving = 0, load = 0, skipped = 0 }, false, mem, 4)
assert(ok, "the take ended: mixing again")
ok, why = la.hub_budget({ serve = true, serving = 3, load = 0.3, skipped = 0 }, false, mem, 5)
assert(not ok and why:find("30%", 1, true), "past " .. la.HUB_BUDGET * 100 .. "% of a core: paused for a while")
assert(not la.hub_budget({ serve = false, serving = 0, load = 0, skipped = 0 }, false, mem, 5 + la.HUB_COOL - 1), "still within the pause")
assert(la.hub_budget({ serve = false, serving = 0, load = 0, skipped = 0 }, false, mem, 5 + la.HUB_COOL + 1), "and back after it")
ok, why = la.hub_budget({ serve = true, serving = 3, load = 0.02, skipped = 4 }, false, mem, 200)
assert(not ok and why:find("fell behind", 1, true), "blocks skipped (the mixing fell behind REAPER): paused")
assert(la.hub_budget({ serve = true, serving = 0, load = 0.9, skipped = 4 }, false, {}, 0), "a stale load while nobody's served isn't judged")

-- ---- 3. Health's words (pure) ----------------------------------------------------------------------------------------------------------
local names = { [BEE] = "Bee", [MAC] = "Chilio", [LIN] = "Lin" }
local t = la.hub_text({ peer = BEE, state = "hub", latency_ms = 76, direct_ms = 38, fallbacks = 0 }, names)
assert(t == " through Bee's mix, 76 ms (38 ms directly: +38 ms for the hub's hop)", t)
t = la.hub_text({ peer = "", serve = true, serving = 3, load = 0.047 }, names)
assert(t:find("you mix it for 3 here", 1, true) and t:find("5% of a core", 1, true), t)
t = la.hub_text({ peer = BEE, state = "direct", fallbacks = 2 }, names, { why = nil })
assert(t == "; back to everyone's own streams 2 times when the hub's mix stopped", t)
t = la.hub_text({ peer = BEE, state = "joining" }, names)
assert(t == "; joining Bee's mix", t)
assert(la.hub_text({ peer = "", state = "direct" }, names) == nil, "peer to peer, nothing to say")
assert(la.hub_text({ peer = "", state = "direct" }, names, { why = "waiting for Lin to have the newer StudioSync extension" }):find("Lin", 1, true), "why it isn't used")
local hok, text = la.health_text({ nch = 1, kbps = 128, hub = { peer = BEE, state = "hub", latency_ms = 80, direct_ms = 41 }, peers = {
  [BEE] = { resolved = true, streaming = false, via_hub = true }, [MAC] = { resolved = true, streaming = false, via_hub = true },
  [LIN] = { resolved = true, streaming = false, via_hub = true } } }, names)
assert(hok and text:find("hearing Bee, Chilio, Lin through Bee's mix, 80 ms (41 ms directly: +39 ms", 1, true), "through the hub: everyone heard, green: " .. text)

-- ---- 4. Live sync's tick hands it to a stand-in extension -------------------------------------------------------------------------------
local E = { running = false, calls = {}, peers = {}, hub = { peer = "", state = "direct", serve = false, serving = 0, load = 0, skipped = 0 } }
reaper.StudioSync_LiveAudioPeers = function(js) E.json = js; return #band.json_decode(js).peers end
reaper.StudioSync_LiveAudioStart = function()
  E.running, E.peers = true, {}
  for _, q in ipairs(band.json_decode(E.json).peers) do E.peers[q] = { resolved = true, streaming = true, latency_ms = 40, buffer_ms = 30, loss = 0, gain = 1, mute = false } end
  return 1
end
reaper.StudioSync_LiveAudioStop = function() E.running = false end
reaper.StudioSync_LiveAudioPeerSet = function() return 1 end
reaper.StudioSync_LiveAudioStatus = function() return band.json_encode({ running = E.running, first = 0, nch = 1, kbps = 128, error = "", peers = E.peers, rejected = 0, hub = E.hub }) end
local b = { song = "Nostalgia", room = "main" }
local function tick() clock = clock + 1; la.tick(cfg, b, "P1") end
tick()
assert(E.running and #E.calls == 0 and la.S.hub == nil, "an extension without the hub's mix: live audio as before")
assert(la.my_lhub() == nil, "and its status doesn't say lhub")
reaper.StudioSync_LiveAudioHub = function(peer, serve) E.calls[#E.calls + 1] = peer .. " " .. serve; E.hub.peer, E.hub.serve = peer, serve == 1; return 1 end
assert(la.my_lhub() == true, "a newer one: lhub in this computer's status")
view = { hub = "Bee" }
statuses = { { user = "Bee", lhub = true }, { user = "Chilio", lhub = true } }
local before = #logs
tick()
assert(E.calls[1] == " 0" and #logs == before, "three people: peer to peer handed over once, quietly: " .. table.concat(E.calls, ","))
tick()
assert(#E.calls == 1, "and not again")
peers_here, users_here = { BEE, MAC, LIN }, { [BEE] = "Bee", [MAC] = "Chilio", [LIN] = "Lin" }
statuses[#statuses + 1] = { user = "Lin" } -- (an older extension: no lhub)
clock = clock + 1 -- (their statuses are read once a second)
tick()
assert(#E.calls == 1 and la.S.hub.why == nil, "four, but only just: peer to peer still (a room counts as big enough once it has been so for HUB_SETTLE s. rt-audio3)")
clock = clock + la.HUB_SETTLE
tick()
assert(#E.calls == 1 and la.S.hub.why:find("extension here", 1, true), "four, but this computer's extension is older than the hub's mix needs: its own streams, and why")
ext["BandSync/menu extension"] = "1.0.28"
view = { hub = "Bee", hub_fit = false }
tick()
assert(#E.calls == 1 and la.S.hub.why:find("Bee's StudioSync extension is too old", 1, true), "the hub's own extension is too old: peer to peer, and why")
view = { hub = "Bee", hub_fit = true }
tick()
assert(E.calls[2] == BEE .. " 0" and logs[#logs]:find("Bee's computer mixes it", 1, true), "Lin's older extension makes nobody wait: through Bee's mix: " .. tostring(E.calls[2]))
view = { hub = "James" }
tick()
assert(E.calls[3] == " 1" and logs[#logs]:find("you mix it", 1, true), "the hub moves here: this computer mixes")
E.hub.serving, E.hub.load = 3, 0.04
tick()
local row = la.health_row(cfg, b)
assert(#E.calls == 3 and row[4]:find("you mix it for 3 here", 1, true), "its load within budget: still mixing; Health says so: " .. row[4])
playstate = 5 -- (recording)
E.hub.load = 0.2
tick()
assert(E.calls[4] == " 0" and la.S.hub.why:find("while you record", 1, true), "recording, and mixing costs 20% of a core: paused (the others go back to their own streams)")
E.hub.serving, E.hub.load = 0, 0
tick()
assert(#E.calls == 4, "still paused while the take goes on")
playstate = 0
tick()
assert(E.calls[5] == " 1", "the take ended: mixing again")
trusted.live_hub = 0
tick()
assert(E.calls[6] == " 0" and logs[#logs]:find("peer to peer", 1, true), "the studio sets never: peer to peer")
trusted.live_hub = nil
trusted.live_audio = false
package.loaded.groups.live_audio = function() return trusted.live_audio ~= false end
tick()
assert(not E.running and la.S.hub == nil, "the studio turns live audio off: stopped, and the hub's mix forgotten")

print("ok: the hub's live mix (who mixes, its budget, Health, the tick)")
