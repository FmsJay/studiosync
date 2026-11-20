-- rt-sonox (James 2026-11-20): SonoBus's extras rebuilt on the studio's own live audio (Solo, Their time, a guest without Tailscale, Produce's
-- live route), and the live mix's host while shared CPU runs (the best-connected computer; otherwise the song's hub). With a stand-in REAPER:
-- the cue mix's mutes and Play levels as the extension gets them, Their time's delay and Play together, the ways Home offers, the guest's
-- readiness, the network probe's words, the host pick (ranking, holding, settling, the handover wait), Health's words, Produce's route, and the
-- wiring in the panel and Live sync's status.
package.path = "lib/?.lua;" .. package.path
local gext, pext = {}, {}
local now_t = 1000
local calls = {}
reaper = setmetatable({
  time_precise = function() return now_t end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  GetProjExtState = function(_, _, k) return 1, pext[k] or "" end,
  SetProjExtState = function(_, _, k, v) pext[k] = v end,
  GetPlayState = function() return 0 end,
  CountTracks = function() return 0 end, GetPlayStateEx = function() return 0 end,
  file_exists = function() return false end,
  StudioSync_LiveAudioStart = function() end, StudioSync_LiveAudioStop = function() end, StudioSync_LiveAudioPeers = function() end,
  StudioSync_LiveAudioStatus = function() return "{}" end,
  StudioSync_LiveAudioPeerSet = function(peer, g, m) calls[#calls + 1] = { "set", peer, g, m } end,
  StudioSync_LiveAudioPeerPlay = function(peer, g) calls[#calls + 1] = { "play", peer, g } end,
  StudioSync_LiveAudioPlay = function() end,
  StudioSync_LiveAudioSend = function() end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
local logged = {}
band.log = function(t) logged[#logged + 1] = t end
local S = band.SECTION
local function src(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return (s:gsub("\r\n", "\n")) end
local la = require("liveaudio")
local livex = require("livex")

-- ---- Solo: only them in your ears, while they're here -------------------------------------------------------------------------------
local A, B, C = "a.ts.net:47281", "b.ts.net:47281", "c.ts.net:47281"
band.set_ext_json(S, "live audio names", { [A] = "Ann", [B] = "Bo", [C] = "Cy" }, false)
assert(livex.solo_in({ [A] = {}, [B] = {} }, la.names(), "Bo") == "Bo", "Bo is here: soloed")
assert(livex.solo_in({ [A] = {} }, la.names(), "Bo") == nil, "Bo left: nobody's silenced")
assert(livex.solo_in({ [A] = {} }, la.names(), nil) == nil, "no Solo")
local function st3() return { running = true, peers = { [A] = { gain = 1, play_gain = 1 }, [B] = { gain = 1, play_gain = 1 }, [C] = { gain = 1, play_gain = 1 } } } end
local function muted(list)
  local m = {}
  for _, c in ipairs(list) do if c[1] == "set" then m[c[2]] = c[4] == 1 end end
  return m
end
livex.set_solo("Bo")
assert(livex.solo() == "Bo" and logged[#logged]:find("only Bo", 1, true), "Solo said")
calls = {}
la.apply(st3())
local m = muted(calls)
assert(m[A] == true and m[C] == true and not m[B], "Ann and Cy muted in the cue mix, Bo heard")
livex.set_solo(nil)
calls = {}
la.apply({ running = true, peers = { [A] = { gain = 1, play_gain = 1, mute = true }, [B] = { gain = 1, play_gain = 1 }, [C] = { gain = 1, play_gain = 1, mute = true } } })
m = muted(calls)
assert(m[A] == false and m[C] == false, "un-Soloed: everyone back")
-- a bandmate's own mute stays with Solo on someone else
band.set_ext_json(S, "live audio mix", { Bo = { gain = 1, mute = true } }, true)
livex.set_solo("Bo")
calls = {}
la.apply(st3())
assert(muted(calls)[A] == true, "Solo on Bo mutes the rest")
livex.set_solo(nil)
band.set_ext_json(S, "live audio mix", {}, true)

-- ---- Produce's live route: their Play quiet here while their take streams ----
reaper.SetExtState(S, "live audio duck play", "Cy", false)
calls = {}
la.apply(st3())
local cy_play
for _, c in ipairs(calls) do if c[1] == "play" and c[2] == C then cy_play = c[3] end end
assert(cy_play == 0, "producing Cy, who records: their Play at 0 here")
reaper.DeleteExtState(S, "live audio duck play")

-- ---- Their time: whom to line up with, and how late ----
local st = { hub = { latency_ms = 210 }, peers = {
  [A] = { streaming = true, latency_ms = 90 }, [B] = { streaming = true, latency_ms = 60, play_streaming = true }, [C] = { via_hub = true } } }
local ms, who = livex.their_ms(st, la.names())
assert(ms == 60 and who == "Bo", "the one playing an armed track first, whatever the others' latency: " .. tostring(ms) .. " " .. tostring(who))
st.peers[B].play_streaming = nil
ms, who = livex.their_ms(st, la.names())
assert(ms == 210 and who == "Cy", "nobody playing: the latest, and Cy in the hub's mix arrives as late as the mix")
ms, who = livex.their_ms(st, la.names(), "Ann")
assert(ms == 90 and who == "Ann", "the soloed one")
assert(livex.their_ms({ peers = { [A] = { streaming = false, latency_ms = 50 } } }, la.names()) == nil, "nothing heard yet: nothing measured")
assert(livex.their_next(120, 0, 115) == nil, "under 10 ms off: not moved (a delay change clicks)")
assert(livex.their_next(120, 0, 100) == 120, "moved")
assert(livex.their_next(120, -20, nil) == 100, "the nudge counts")
assert(livex.their_next(1500, 0, 0) == 1000, "within the live mix's most")
assert(livex.their_next(10, -50, 30) == 0, "never below 0")
assert(livex.their_next(nil, 0, 0) == nil, "nothing measured: left as it is")
local line = livex.their_line({ ms = 130, who = "Bo" }, 142.4, 12)
assert(line == "Your backing 142 ms later: Bo arrives 130 ms late, +12 ms nudge", line)
assert(livex.their_line(nil, 100, 0):find("measured once someone plays", 1, true), "before any measurement")

-- on and off: the live mix on the master delays the backing; Play together (0 bars) carries the transport; what was there comes back
local delay, mixed = 0, false
package.loaded.hear = { MAX_MS = 1000, mix = function(_, add) if add then mixed = true end return mixed and "m" or nil, 0 end,
  set_delay = function(_, v) delay = v end, delay = function() return delay end }
pext.side = "2"
assert(livex.set_their("P", true) == true and mixed and pext.side == "0" and pext["their time live"] == "1", "on: Play together, the flag")
assert(delay == livex.THEIR_START and pext["side before their"] == "2", "starts at 100 ms until measured; the bars behind kept")
assert(livex.their_on("P"), "on")
-- Live sync's tick: the delay follows the measurement
la.names() -- (the names stay as above)
now_t = now_t + 10
livex.their_tick("P", { peers = { [B] = { streaming = true, latency_ms = 160, play_streaming = true } } })
assert(delay == 160, "follows Bo's 160 ms: " .. tostring(delay))
local mm = band.ext_json(S, "their measured P")
assert(mm.ms == 160 and mm.who == "Bo", "the measurement kept for Home")
livex.set_nudge("P", 25)
now_t = now_t + 10
livex.their_tick("P", { peers = { [B] = { streaming = true, latency_ms = 160, play_streaming = true } } })
assert(delay == 185, "with the nudge")
livex.set_nudge("P", 999)
assert(livex.nudge("P") == livex.NUDGE, "the nudge kept within its range")
livex.set_nudge("P", 0)
assert(livex.set_their("P", false) and pext.side == "2" and pext["their time live"] == "" and delay == 0, "off: backing on time, the bars behind back")
-- Play together turned off another way (a reopened project: all_off clears side): Their time goes with it
livex.set_their("P", true)
pext.side = ""
now_t = now_t + 10
livex.their_tick("P", {})
assert(not livex.their_on("P") and delay == 0 and logged[#logged]:find("Play together went off", 1, true), "self-healing off")
-- no live mix on the master: nothing turned on
mixed = false
package.loaded.hear.mix = function() return nil end
local ok_t, why_t = livex.set_their("P", true)
assert(not ok_t and why_t:find("master", 1, true) and pext["their time live"] == "", "refused before anything changed")
package.loaded.hear = nil

-- ---- the ways Home offers ----
local KINDS = { { "my", sonobus = true }, { "their", sonobus = true }, { "their", builtin = true }, { "intime" } }
local function ids(list) local t = {}; for i, k in ipairs(list) do t[i] = k[1] .. (k.builtin and "*" or "") end; return table.concat(t, ",") end
assert(ids(livex.offered(KINDS, true, nil)) == "their*,intime", "built in: its Their time and In time: " .. ids(livex.offered(KINDS, true, nil)))
assert(ids(livex.offered(KINDS, false, nil)) == "my,their,intime", "SonoBus's three without the studio's live audio")
assert(ids(livex.offered(KINDS, true, "my")) == "my,their*,intime", "SonoBus's My time still on: shown so it can go")
assert(ids(livex.offered(KINDS, true, "their")) == "their*,intime", "never two Their times")

-- ---- a guest without Tailscale ----
assert(livex.guest_ready(true, true, false) == true, "Connect without Tailscale on, the extension has it: ready")
local g1, g2 = livex.guest_ready(false, true, true)
assert(not g1 and g2 == "off", "off, owner or admin: asked to turn it on")
g1, g2 = livex.guest_ready(false, true, false)
assert(not g1 and g2:find("owner or an admin", 1, true), "a member: told who can")
g1, g2 = livex.guest_ready(true, false, true)
assert(not g1 and g2:find("extension", 1, true), "no NAT in this extension")
assert(livex.GUEST_TIP:find("never a hub", 1, true) and livex.GUEST_TIP:find("Browser guests", 1, true), "the guest limits are said")

-- ---- the network probe ----
assert(livex.net_parse("802.3\r\n") == "wired", "Windows Ethernet")
assert(livex.net_parse("Native 802.11\r\n") == "wifi", "Windows Wi-Fi")
assert(livex.net_parse("Hardware Port: Wi-Fi\n") == "wifi", "macOS Wi-Fi")
assert(livex.net_parse("Hardware Port: Thunderbolt Ethernet Slot 1\n") == "wired", "macOS Ethernet")
assert(livex.net_parse("linux wifi\n") == "wifi" and livex.net_parse("linux wired\n") == "wired", "Linux")
assert(livex.net_parse("Unspecified") == nil and livex.net_parse(nil) == nil and livex.net_parse("") == nil, "not known")
assert(livex.rtt_of({ peers = { [A] = { rtt_ms = 20 }, [B] = { rtt_ms = 41 }, [C] = { rtt_ms = -1 } } }) == 31, "the mean of what's measured")
assert(livex.rtt_tens({ peers = { [A] = { rtt_ms = 34 } } }) == 30 and livex.rtt_of({ peers = {} }) == nil, "in tens, as the status carries it")

-- ---- the host pick ----
local function c(user, net, rtt, cpu, x) x = x or {}; x.user, x.net, x.rtt, x.cpu = user, net, rtt, cpu; if x.can == nil then x.can = true end; return x end
local p, why = livex.mix_pick({ c("lap", "wifi", 20, 10), c("desk", "wired", 60, 50), c("mac", "wifi", 10, 0) })
assert(p.user == "desk" and why == "best", "wired over Wi-Fi, whatever the round trip")
p = livex.mix_pick({ c("lap", "wired", 45, 10), c("desk", "wired", 22, 50) })
assert(p.user == "desk", "both wired: the lower round trip band")
p = livex.mix_pick({ c("lap", "wired", 25, 10), c("desk", "wired", 22, 50) })
assert(p.user == "lap", "the same band: more CPU headroom")
p = livex.mix_pick({ c("lap", "wired", 25, 50), c("desk", "wired", 22, 50, { home = true }) })
assert(p.user == "desk", "all else equal: the song's hub")
p = livex.mix_pick({ c("guest", "wired", 5, 0, { guest = true }), c("off", "wired", 5, 0, { off = true }), c("old", "wired", 5, 0, { can = false }), c("lap", "wifi", 80, 60) })
assert(p.user == "lap", "never a guest, a computer handed on, or one whose extension can't mix")
p, why = livex.mix_pick({ c("desk", "wired", 10, 90), c("lap", "wifi", 60, 40) })
assert(p.user == "lap" and why == "best", "past shared CPU's busy line: not while another has headroom")
p, why = livex.mix_pick({ c("desk", "wired", 10, 90), c("lap", "wifi", 60, 80) })
assert(p.user == "desk" and why == "busy", "everyone busy: the best-connected of them")
assert(livex.mix_pick({ c("g", "wired", 5, 0, { guest = true }) }) == nil, "nobody who may")
-- the one mixing keeps it unless another is clearly better
p, why = livex.mix_pick({ c("lap", "wired", 50, 10, { lmix = true }), c("desk", "wired", 38, 10) })
assert(p.user == "lap" and why == "kept", "12 ms better isn't clearly better: kept")
p = livex.mix_pick({ c("lap", "wired", 50, 10, { lmix = true }), c("desk", "wired", 30, 10) })
assert(p.user == "desk", "20 ms better: handed over")
p = livex.mix_pick({ c("lap", "wifi", 20, 10, { lmix = true }), c("desk", "wired", 30, 10) })
assert(p.user == "desk", "wired against its Wi-Fi: handed over")
p = livex.mix_pick({ c("lap", "wired", 20, 90, { lmix = true }), c("desk", "wired", 30, 10) })
assert(p.user == "desk", "the one mixing got busy: handed over")
p = livex.mix_pick({ c("lap", "wired", 10, 10, { lmix = true }), c("desk", "wired", 30, 10, { lmix = true }) })
assert(p.user == "lap", "two say they mix (a handover in flight): the better of them")
-- Health's words
local w = livex.mix_words(c("desk", "wired", 22, 30), "best", "lap")
assert(w == "shared CPU is on in this room, so desk mixes the live audio: wired, 22 ms round trip to the others, CPU 30% (the best-connected computer here)", w)
assert(livex.mix_words(c("lap", "wifi", nil, nil), "kept", "lap"):find("so you mix the live audio: on Wi-Fi (it was mixing already", 1, true), "this computer, kept")

-- the candidates from the statuses: only those live audio reaches here; shared CPU on if anyone offloads
local sts = { { user = "desk", net = "wired", lrtt = 20, cpu = 30, lhub = true, hub = {} }, { user = "lap", lhub = true, scpu = true, hub = { off = true } },
  { user = "far", net = "wired", lrtt = 1, cpu = 0, lhub = true } }
local list, scpu = livex.mix_cands(sts, { [A] = "desk", [B] = "lap" }, { user = "mac", net = "wifi", rtt = 30, cpu = 10, can = true }, "desk", { mac = true })
local by = {}
for _, x in ipairs(list) do by[x.user] = x end
assert(scpu == true and by.desk and by.lap and by.mac and not by.far, "far isn't on the link here: not a candidate; lap offloads: shared CPU on")
assert(by.desk.home and by.desk.rtt == 20 and by.lap.off and by.mac.guest, "fields: the song's hub, round trip, handed on, guest")
local _, scpu2 = livex.mix_cands({ { user = "desk", lhub = true } }, { [A] = "desk" }, { user = "mac" }, nil, {})
assert(scpu2 == false, "nobody offloads: off")

-- deciding: the song's hub without shared CPU; the pick with it, held steady, the handover waits for the new host to mix
local mem = {}
local L1 = { c("desk", "wired", 20, 10, { lmix = true }), c("lap", "wifi", 30, 10), c("me", "wifi", 40, 10) }
local h, words, wait = livex.mix_decide(mem, L1, false, "lap", "me", 0)
assert(h == "lap" and words == nil and wait == nil, "no shared CPU: the song's hub, as today")
h, words, wait = livex.mix_decide(mem, L1, true, "lap", "me", 0)
assert(h == "desk" and words:find("desk mixes", 1, true) and not wait, "shared CPU: the best-connected, already mixing")
local L2 = { c("desk", "wired", 60, 10, { lmix = true }), c("lap", "wired", 20, 10), c("me", "wifi", 40, 10) }
h = livex.mix_decide(mem, L2, true, "lap", "me", 1)
assert(h == "desk", "a better one: not taken at once (statuses arrive at different moments)")
h, words, wait = livex.mix_decide(mem, L2, true, "lap", "me", 1 + livex.SETTLE)
assert(h == nil and wait:find("handing the live mix to lap", 1, true) and words:find("lap mixes", 1, true), "after SETTLE s: lap, but it doesn't mix yet, so own streams meanwhile")
L2[1].lmix, L2[2].lmix = nil, true
h, _, wait = livex.mix_decide(mem, L2, true, "lap", "me", 6)
assert(h == "lap" and not wait, "lap mixes now: through its mix")
-- the host gone: the next at once
h = livex.mix_decide(mem, { c("desk", "wired", 20, 10, { lmix = true }), c("me", "wifi", 40, 10) }, true, "lap", "me", 7)
assert(h == "desk", "lap left: desk at once, no settling")
-- this computer picked: it mixes at once (its own status follows)
local mem2 = {}
h = livex.mix_decide(mem2, { c("me", "wired", 10, 10), c("lap", "wifi", 30, 10) }, true, "lap", "me", 0)
assert(h == "me", "me: mix now")
-- a pick that flips back doesn't keep an old clock
local mem3 = {}
livex.mix_decide(mem3, { c("a", "wired", 20, 10, { lmix = true }), c("b", "wired", 20, 20) }, true, nil, "z", 0)
livex.mix_decide(mem3, { c("a", "wired", 40, 10, { lmix = true }), c("b", "wired", 10, 20) }, true, nil, "z", 1)
livex.mix_decide(mem3, { c("a", "wired", 20, 10, { lmix = true }), c("b", "wired", 20, 20) }, true, nil, "z", 2)
h = livex.mix_decide(mem3, { c("a", "wired", 40, 10, { lmix = true }), c("b", "wired", 10, 20, { lmix = true }) }, true, nil, "z", 2 + livex.SETTLE - 1)
assert(h == "a", "b came back as the pick only a moment ago: still a")
-- shared CPU off again: the song's hub, the memory cleared
h = livex.mix_decide(mem, L1, false, "lap", "me", 8)
assert(h == "lap" and mem.cur == nil, "off again: the song's hub")

-- Health: why this computer mixes
local ht = la.hub_text({ serve = true, serving = 3, load = 0.05 }, {}, { pick = "shared CPU is on in this room, so you mix the live audio: wired" })
assert(ht:find("you mix it for 3", 1, true) and ht:find("so you mix the live audio: wired", 1, true), ht)

-- ---- Produce's live route ----
local builtin = true
package.loaded.live = setmetatable({ builtin_audio = function() return builtin end, fx = function() return nil end, rt_track = function() return nil end,
  talking = function() return false end, talk = function() end, realtime_on = function() return false end, sonobus_wanted = function() return false end },
  { __index = function() return function() end end })
local sonobus_asked = 0
package.loaded.setup = { sonobus = function() sonobus_asked = sonobus_asked + 1; return nil, "no" end }
package.loaded.stamp = { read = function() return true end, send = function() return true end, status = function() return {} end }
package.loaded.hear = { pairs = function() return {} end, set_stamped = function() end }
package.loaded.latency = { tick = function() end }
pext.song, pext.root = "Song", "R"
local producer = require("producer")
assert(producer.via("P") == "live", "the studio's own live audio here: the live route")
assert(producer.lag("P") == producer.LAG.live, "its own lag")
assert(producer.start("P", { user = "me" }, { song = "Song" }, "Cy") == true and sonobus_asked == 0, "no SonoBus, no stamps")
assert(reaper.GetExtState(S, "follow P") == "Cy", "following them")
-- the producer's tick: their Play quiet here only while they record
producer.tick("P", { user = "me" }, { song = "Song", room = "main" }, { { user = "Cy", recording = true } })
assert(reaper.GetExtState(S, "live audio duck play") == "Cy", "they record: their take streams, their live Play quiet")
producer.tick("P", { user = "me" }, { song = "Song", room = "main" }, { { user = "Cy" } })
assert(reaper.GetExtState(S, "live audio duck play") == "", "between takes: heard live")
local lines = producer.lines("P", "Cy", { recording = true }, {}, true)
assert(lines[2][1]:find("as it streams", 1, true), "said on Home")
-- the performer's side: produced through the live route, nothing starts
reaper.DeleteExtState(S, "produce P")
sonobus_asked = 0
producer.tick("P", { user = "me" }, { song = "Song", room = "main" }, { { user = "Bo", produce = "me", produce_via = "live" } })
assert(sonobus_asked == 0 and reaper.GetExtState(S, "produced by P") == "Bo", "produced live: no SonoBus or stamps here, and said")
producer.tick("P", { user = "me" }, { song = "Song", room = "main" }, { { user = "Bo", produce = "me", produce_via = "stamp" } })
assert(sonobus_asked == 1, "an older producer through SonoBus: as before")
builtin = false
assert(producer.via("P") == "stamp", "without the studio's live audio: SonoBus's route as before")
producer.stop("P", { user = "me" }, { song = "Song" })
assert(reaper.GetExtState(S, "live audio duck play") == "", "stopped: nobody quiet")

-- ---- the wiring ----
local panel = src("StudioSync - Panel.lua")
assert(panel:find('{ "their", "Their time", require("livex").THEIR_TIP, builtin = true }', 1, true), "Home's built-in Their time")
assert(panel:find("ipairs(livex.offered(RT_KINDS, builtin, kind))", 1, true), "Home lists livex's offered ways")
assert(panel:find('if b and require("livex").their_on(proj) then return "their" end', 1, true), "the way read back")
assert(panel:find('require("livex").set_their(proj, true)', 1, true) and panel:find('require("livex").set_their(proj, false); now = "their_live"', 1, true), "on and off")
assert(panel:find('elseif now ~= "intime" and now ~= "their_live" then set_same_room(false) end', 1, true), "built-in Their time off doesn't touch SonoBus's")
assert(panel:find("livex.their_ui(ctx, ImGui, proj)", 1, true), "its delay and nudge on Home")
assert(panel:find("livex.set_solo(not lon and p.user or nil)", 1, true), "Solo on the cue mix with built-in audio")
assert(panel:find('require("livex").guest_button(ctx, ImGui, cfg, my_id)', 1, true), "the guest without Tailscale in place of SonoBus's")
local ls = src("StudioSync - Live sync.lua")
assert(ls:find('pcall(require("livex").status_part, proj)', 1, true) and ls:find("info.net, info.lrtt, info.scpu, info.lmix", 1, true), "Live sync's status carries the pick's fields")
local lsrc = src("lib/liveaudio.lua")
assert(lsrc:find('pcall(require("livex").mix_host, cfg, b, hub, users, st, S)', 1, true) and lsrc:find('pcall(require("livex").their_tick, proj, st)', 1, true), "live audio's tick")
local tools = src("lib/tools.lua")
assert(tools:find("function tools.open_guest_invite(ctx, ImGui, root, no_ts)", 1, true) and tools:find("if not guest_pick.no_ts and services.has_token_for", 1, true),
  "no Tailscale key in a guest-without-Tailscale invitation")
local ph = src("lib/page_hear.lua")
assert(ph:find('la.hold("talkback", not talking and "latch" or nil, name)', 1, true), "Produce's Talk is built-in talkback")

print("ok: rt-sonox (Solo, Their time, guest without Tailscale, Produce live, the live mix's host while shared CPU runs)")
