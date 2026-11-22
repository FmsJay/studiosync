-- rt-audio3 (2026-11-22, from rt-r3's re-check on the real rig, docs/rt/rt-audio3.md): the Lua side of live audio's robustness.
--   1. Windows' firewall rule "missing" for one look (netsh's answer read while it was still being written) no longer stops live audio or
--      the direct link: a "no" after a "yes" counts once the rule hasn't been seen for direct.FW_HOLD s (the desktop restarted its live
--      audio 30 times in an evening on it, and the hub with it).
--   2. A computer whose live audio can't run never mixes for the room: its status says so (liveaudio.my_la "down" when the engine
--      didn't start), liveaudio.hub_plan asks nobody like that for a mix and doesn't serve with its own engine down, and lib/hub.lua
--      doesn't elect it while another can (LinuxBox2, off the tailnet, said "you're the hub").
--   3. A computer holding a hub role keeps it while its Syncthing is behind, unless it is also blind to someone in the room (hub.blind):
--      the desktop's Syncthing sat scanning and it handed Cross Test away and took it back 17 times in three hours.
-- The audio itself is in tests/rtaudio_test.cpp (device_test, vm_test, clock_tests) and tools/ears/test_ears.py. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local ext, files, now_p, logged = {}, {}, 1000, {}
reaper = setmetatable({
  time_precise = function() return now_p end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetExePath = function() return "C:/REAPER" end,
  GetPlayState = function() return 1 end, -- (playing: the restore-point job waits, so the tick is only the election)
  GetProjectStateChangeCount = function() return 1 end,
  EnumProjects = function() return "P" end,
}, { __index = function() return function() return "" end end })
local real_time, toff = os.time, 0
os.time = function(t) if t then return real_time(t) end return real_time() + toff end
local band = require("band")
band.info = function() return { id = "studio1", name = "Smiley" } end
band.log = function(s) logged[#logged + 1] = s end
band.read_json = function(p) return files[p] end
band.write_json = function(p, t) files[p] = t end
band.files = function() return {} end
band.listing = function() return {} end
package.loaded.groups = { trusted = function() return {} end, role = function() return "member" end }
local hub = require("hub")
local T = 2000000

-- ---- 1. the firewall rule, read while netsh is still writing its answer ------------------------------------------------------------------
do
  local direct = require("direct")
  local mem = {}
  assert(direct.firewall_held(mem, "UDP", false, 0) == false, "never seen: no rule, at once (Health's Set up button)")
  assert(direct.firewall_held(mem, "UDP", true, 10) == true, "seen")
  assert(direct.firewall_held(mem, "UDP", false, 10.5) == true, "a 'no' half a second after a 'yes': one look at a half-written answer, not a removed rule")
  assert(direct.firewall_held(mem, "UDP", false, 10 + direct.FW_HOLD - 1) == true, "nor just under FW_HOLD s")
  assert(direct.firewall_held(mem, "UDP", false, 10 + direct.FW_HOLD + 1) == false, "not seen for FW_HOLD s: really removed")
  assert(direct.firewall_held(mem, "TCP", false, 11) == false, "each rule has its own memory")
  assert(direct.firewall_held(mem, "UDP", true, 500) == true and direct.firewall_held(mem, "UDP", false, 501) == true, "seen again: held again")
  -- through direct.firewall_ok, as lib/liveaudio.lua and lib/hub.lua ask: netsh's own text, whole and then cut short
  local rule = function(proto)
    return "Rule Name:                            StudioSync direct link\n----------------------------------------------------------------------\n" ..
      "Enabled:                              Yes\nDirection:                            In\nRemoteIP:                             100.64.0.0/10\n" ..
      "Protocol:                             " .. proto .. "\nLocalPort:                            47281\nProgram:                              C:\\REAPER\\reaper.exe\nAction:                               Allow\n\n"
  end
  local whole = rule("TCP") .. rule("UDP") .. "Ok.\n"
  local half = whole:sub(1, #rule("TCP") + 40) -- (the TCP rule, and the second rule's name: no UDP word, no second program yet)
  local exe = "C:\\REAPER\\reaper.exe"
  assert(direct.firewall_in(whole, exe, 47281, "UDP") and direct.firewall_in(whole, exe, 47281), "the whole answer: both rules")
  assert(not direct.firewall_in(half, exe, 47281, "UDP"), "the half-written answer alone: no UDP rule (what stopped live audio)")
  assert(not direct.firewall_in(whole:sub(1, 200), exe, 47281), "cut shorter still: no program yet, so no TCP rule either (what restarted the link)")
  local answer = whole
  package.loaded.services = { run_hidden = function() return answer end }
  local win0 = band.WIN
  band.WIN = true
  assert(direct.firewall_ok("UDP") == true and direct.firewall_ok() == true, "both rules there")
  answer, now_p = half, now_p + 0.5
  assert(direct.firewall_ok("UDP") == true, "half-written half a second later: still there (it read as missing, and live audio stopped and started)")
  answer, now_p = whole:sub(1, 200), now_p + 0.5
  assert(direct.firewall_ok() == true, "and the link's rule too (the direct link restarted without listening)")
  answer, now_p = whole, now_p + 59
  assert(direct.firewall_ok("UDP") == true, "the next whole answer: there")
  answer, now_p = "No rules match the specified criteria.\n", now_p + direct.FW_HOLD + 1
  assert(direct.firewall_ok("UDP") == false and direct.firewall_ok() == false, "really removed: noticed FW_HOLD s later")
  -- and what goes by it: liveaudio.why_not stops live audio only on a held "no"
  local la = require("liveaudio")
  assert(select(2, la.why_not(true, true, "secret", false)) == "firewall" and la.why_not(true, true, "secret", true) == nil, "why_not goes by the answer it is handed")
  local src = assert(io.open("lib/liveaudio.lua", "rb")):read("a")
  assert(src:find('direct.firewall_ok("UDP")', 1, true), "and live audio's tick asks direct.firewall_ok, the held answer")
  band.WIN = win0
end

-- ---- 2. a computer whose live audio can't run mixes for nobody -------------------------------------------------------------------------
do
  local la = require("liveaudio")
  la.S.code, la.S.fail_why = nil, nil
  local was = la.my_la()
  assert(was ~= nil and not hub.NO_LA[was], "running: its mic's word (" .. tostring(was) .. ")")
  assert(la.fail_new("Tailscale isn't up here (no 100.64.0.0/10 address)"), "the engine didn't start")
  assert(la.my_la() == "down" and hub.NO_LA[la.my_la()], "its status says so: down (it said 'on' while nothing ran: LinuxBox2)")
  assert(la.THEM.down, "and the others' Health has words for it")
  la.S.fail_why = nil
  assert(la.my_la() == was, "started: its mic's word again")
  la.S.code = "firewall"
  assert(hub.NO_LA[la.my_la()], "the firewall rule missing: can't run either")
  la.S.code = nil
  for _, w in ipairs({ "on", "muted", "deaf", "ptt" }) do assert(not hub.NO_LA[w], w .. ": live audio runs") end
  -- hub_plan: this computer elected, its own engine not running
  local o = { n = 4, from = 4, hub = "Me", me = "Me", users = {}, can = true }
  local peer, serve, why = la.hub_plan(o)
  assert(peer == "" and serve == true and why == nil, "the song's hub, its engine running: it mixes")
  o.running = false
  peer, serve, why = la.hub_plan(o)
  assert(peer == "" and serve == false and why:find("isn't running on this computer", 1, true), "its engine not running: it doesn't say it mixes (it did, between failed starts): " .. tostring(why))
  -- hub_plan: another computer elected whose status says its live audio can't run
  o = { n = 4, from = 4, hub = "Bx", me = "Me", users = { ["bx.ts.net:47281"] = "Bx" }, can = true }
  peer, serve = la.hub_plan(o)
  assert(peer == "bx.ts.net:47281" and serve == false, "a hub whose live audio runs: asked for its mix")
  for w in pairs(hub.NO_LA) do
    o.hub_la = w
    peer, serve, why = la.hub_plan(o)
    assert(peer == "" and serve == false and why:find("Bx's live audio isn't running", 1, true), w .. ": not asked, everyone's own streams, and Health says why: " .. tostring(why))
  end
  o.hub_la = "muted"
  assert(la.hub_plan(o) == "bx.ts.net:47281", "muted is a mic's word: its live audio runs")
  local src = assert(io.open("lib/liveaudio.lua", "rb")):read("a")
  assert(src:find("running = st.running ~= false, hub_la = hub and (S.las or {})[hub] or nil", 1, true), "hub_tick hands hub_plan both")

  -- the election: a candidate whose status says so (nola) isn't elected while another can
  local function cand(user, since, x)
    x = x or {}
    return { user = user, machine = "m-" .. user, since = T - since, link = true, ext = "1.0.37", sees = {}, nola = x.nola, lag = x.lag, studio = x.studio,
      songs = { Song = { holds = x.holds, sees = {} } } }
  end
  local song, why2 = hub.elect_song({ cand("X2", 9000, { nola = true }), cand("La", 5000), cand("Bx", 4000) }, "Song", nil, nil, T)
  assert(song == "La", "online longest but no live audio: passed over for the next (" .. tostring(song) .. ", " .. tostring(why2) .. ")")
  song = hub.elect_song({ cand("X2", 9000, { nola = true, holds = true }), cand("La", 5000), cand("Bx", 4000) }, "Song", nil, nil, T)
  assert(song == "La", "saying it holds the role doesn't keep it either (cut off alone, it had elected itself): " .. tostring(song))
  song = hub.elect_song({ cand("X2", 9000, { nola = true }), cand("La", 5000), cand("Bx", 4000) }, "Song", "X2", nil, T)
  assert(song == "La", "nor being the song's home: " .. tostring(song))
  song = hub.elect_song({ cand("X2", 9000, { nola = true }) }, "Song", nil, nil, T)
  assert(song == "X2", "alone, it still keeps the project's restore points (they need no live audio)")
  song = hub.elect_song({ cand("X2", 9000, { nola = true }), cand("Y2", 5000, { nola = true }) }, "Song", nil, nil, T)
  assert(song == "X2", "nobody's live audio runs (a studio with it off for everyone): as before")
  song = hub.elect_song({ cand("Ja", 9000, { lag = true, holds = true }), cand("X2", 5000, { nola = true }) }, "Song", "Ja", nil, T)
  assert(song == "Ja", "behind on Syncthing against no live audio: the one that can still mix for the room (" .. tostring(song) .. ")")
  song = hub.elect_song({ cand("Ja", 9000, { lag = true, holds = true }), cand("La", 5000), cand("X2", 4000, { nola = true }) }, "Song", "Ja", nil, T)
  assert(song == "La", "and among those with live audio, one not behind, as before (" .. tostring(song) .. ")")
  local studio = hub.elect_studio({ cand("X2", 9000, { nola = true }), cand("La", 5000) }, "X2", T)
  assert(studio == "La", "the studio's hub the same, the owner's pick or not (" .. tostring(studio) .. ")")
  -- from the statuses: the word is each computer's own `la`
  local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", real_time() - ago) end
  local list = hub.candidates({
    { song = "Song", seen = real_time(), st = { user = "X2", time = iso(2), la = "down", hub = { since = 1, link = true, ext = "1.0.37" } } },
    { song = "Song", seen = real_time(), st = { user = "La", time = iso(2), la = "muted", hub = { since = 2, link = true, ext = "1.0.37" } } },
    { song = "Song", seen = real_time(), st = { user = "Bx", time = iso(2), hub = { since = 3, link = true, ext = "1.0.37" } } },
  }, real_time(), band.age)
  local by = {}
  for _, c in ipairs(list) do by[c.user] = c end
  assert(by.X2.nola == true and by.La.nola == nil and by.Bx.nola == nil, "candidates: 'down' can't run; a mic's word and no word can")
  list = hub.with_room(list, { { user = "La", time = iso(1), la = "tailscale", hub = { since = 2, link = true, ext = "1.0.37" } } }, "Song")
  by = {}
  for _, c in ipairs(list) do by[c.user] = c end
  assert(by.La.nola == true and by.X2.nola == true, "the link's newer status says so too")
  -- shared CPU's pick of who mixes: the same word
  local livex = require("livex")
  local me = { user = "Me", can = true, hub = { ext = "1.0.37", sees = { "Bx", "La" } } }
  local function sts(la_bx) return { { user = "Bx", lhub = true, la = la_bx, hub = { ext = "1.0.37", sees = { "Me", "La" } } }, { user = "La", lhub = true, la = "on", hub = { ext = "1.0.37", sees = { "Me", "Bx" } } } } end
  local cands = livex.mix_cands(sts("down"), { p1 = "Bx", p2 = "La" }, me, nil, {})
  for _, c in ipairs(cands) do if c.user == "Bx" then assert(c.can == false, "shared CPU's pick: one whose live audio is down can't mix") end
    if c.user == "La" then assert(c.can == true, "one whose runs can") end end
  cands = livex.mix_cands(sts("deaf"), { p1 = "Bx", p2 = "La" }, me, nil, {})
  for _, c in ipairs(cands) do if c.user == "Bx" then assert(c.can == true, "deafened: its live audio runs") end end
end

-- ---- 3. Syncthing behind on the computer holding the role: kept unless it is blind to someone too ----------------------------------------
do
  local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", real_time() - ago) end
  local function st(user, sees) return { user = user, time = iso(2), hub = { sees = sees } } end
  assert(hub.blind({ Pi = st("Pi", { "Ja", "Qu" }), Qu = st("Qu", { "Ja", "Pi" }) }, { "Pi", "Qu" }, "Ja") == false, "everyone the others reach, this one reaches: not blind")
  assert(hub.blind({ Pi = st("Pi", { "Ja", "Qu", "Zed" }), Qu = st("Qu", { "Ja", "Pi" }) }, { "Pi", "Qu" }, "Ja") == true, "Pi reaches Zed, this one doesn't: blind to Zed")
  assert(hub.blind({ Pi = { user = "Pi", time = iso(600), hub = { sees = { "Zed" } } } }, { "Pi" }, "Ja") == false, "a link status gone old says nothing")
  assert(hub.blind(nil, {}, "Ja") == false and hub.blind({}, nil, "Ja") == false, "nothing from the link: no word")

  local cfg, b = { root = "R", user = "Ja" }, { song = "Song", room = "main" }
  ext["BandSync/hub since"] = tostring(os.time() - 100000)
  ext["BandSync/menu extension"] = "1.0.37"
  band.songs = function() return { "Song" } end
  band.subdirs = function(d) return d == "R/Song/rooms" and { "main" } or {} end
  local listed = { "Pi.json", "Qu.json" }
  band.files = function(d) return d == "R/Song/rooms/main/status" and listed or {} end
  local qu_sees = { "Ja", "Pi", "Qu" }
  local function full(user, since, sees) return { user = user, machine = "m" .. user, time = iso(2), hub = { since = real_time() - since, link = true, ext = "1.0.37", sees = sees } } end
  files["R/Song/rooms/main/status/Pi.json"], files["R/Song/rooms/main/status/Qu.json"] = full("Pi", 500, { "Ja", "Pi", "Qu" }), full("Qu", 400, qu_sees)
  local function live_now() return { Pi = full("Pi", 500, { "Ja", "Pi", "Qu" }), Qu = full("Qu", 400, qu_sees) } end
  package.loaded.presence = { peers = function() local l = live_now(); return { l.Pi, l.Qu } end, live = function() return live_now() end }
  package.loaded.direct = { available = function() return true end, live_available = function() return true end, firewall_ok = function() return true end,
    reach = function() return { Pi = { ok = true, at = os.time() }, Qu = { ok = true, at = os.time() } } end }
  package.loaded.removal = { guest_names = function() return {} end }
  package.loaded.trust = { own_file_ok = function() return true end, user_file = function(n) return n .. ".json" end }
  package.loaded.sync = { machine = function() return "mJa" end, loading = {}, room_dir = function(_, s, rm) return "R/" .. s .. "/rooms/" .. rm end }
  package.loaded.recall = { dir = function() return "R/Song/rooms/main/recall" end, save = function() end }
  local function tick() now_p = now_p + hub.SCAN_EVERY + 1; hub.tick("P", cfg, b); return band.ext_json(band.SECTION, "hub view studio1 Song") end
  local v = tick()
  assert(v.hub == "Ja", "online longest: the song's hub (" .. tostring(v.hub) .. ")")
  -- its Syncthing stops bringing the files (a long scan), while its link reaches everyone the others reach
  listed, logged = {}, {}
  for i = 1, 6 do
    toff = i * hub.REACH_SETTLE
    v = tick()
    assert(v.hub == "Ja" and v.lag == nil and hub.status_part(cfg, b).lag == nil and hub.status_part(cfg, b).song == true,
      "behind for " .. toff .. " s but seeing the whole room: it keeps the role and says nothing (it handed it on after REACH_SETTLE s, 17 times in an evening) (" .. tostring(v.hub) .. ")")
  end
  assert(not table.concat(logged, "\n"):find("is its hub now", 1, true), "and no hand-off in the log")
  -- now a bandmate's link reaches someone this one's doesn't: its election may miss them, so after REACH_SETTLE s it steps down, as rt-fix7
  qu_sees = { "Ja", "Pi", "Qu", "Zed" }
  toff = 7 * hub.REACH_SETTLE
  v = tick()
  assert(v.hub == "Ja" and v.lag == nil, "blind to Zed now, at first sight: still kept")
  toff = 7 * hub.REACH_SETTLE + 10
  v = tick()
  assert(v.hub == "Ja", "nor before REACH_SETTLE s")
  toff = 8 * hub.REACH_SETTLE + 5
  logged = {}
  v = tick()
  assert(v.hub ~= "Ja" and v.lag == true and hub.status_part(cfg, b).lag == true, "behind and blind for REACH_SETTLE s: given up, and its status says so (" .. tostring(v.hub) .. ")")
  assert(table.concat(logged, "\n"):find("is its hub now (Syncthing is behind here)", 1, true), "the log says why")
  -- holding nothing, a computer behind takes none, blind or not (rt-p9, unchanged)
  qu_sees = { "Ja", "Pi", "Qu" }
  toff = 8 * hub.REACH_SETTLE + 20
  v = tick()
  assert(v.lag == true and v.hub ~= "Ja", "holding nothing now and still behind: takes no role, as before")
  local src = assert(io.open("lib/hub.lua", "rb")):read("a")
  assert(src:find("if not hub.blind(okl and live or nil, sees, cfg.user) then lag, lag_from[tk] = false, nil", 1, true), "hub.tick asks hub.blind before a holder steps down")
end

-- ---- 4. (round 2, from rt-r5) the hub's mix needs two computers that send, and a room that has been big enough for HUB_SETTLE s ---------
-- rt-r5: one computer sent, three listened muted, and Live sync still moved everyone to the desktop's mix for 103 s in the middle of the
-- run: the Mac, asleep, had come onto the link for 43 s and made the room four. Through the hub a lone sender's stream is decoded, mixed
-- with nothing and encoded again for each listener.
do
  local la4 = require("liveaudio")
  local users = { ["bx.ts.net:47281"] = "Bx", ["cy.ts.net:47281"] = "Cy", ["dz.ts.net:47281"] = "Dz" }
  -- who sends
  assert(la4.senders({ Bx = "muted", Cy = "deaf", Dz = "muted" }, users, "on") == 1, "one sender: the rest muted or deafened (rt-r5's sound test)")
  assert(la4.senders({ Bx = "on", Cy = "muted", Dz = "ptt" }, users, "muted") == 2, "on and push-to-talk send; muted doesn't, here neither")
  assert(la4.senders({ Bx = "down", Cy = "firewall" }, users, "on") == 2, "live audio that can't run doesn't send; one that hasn't said may (Dz)")
  assert(la4.senders({}, { a = "Bx", b = "Bx" }, "on") == 2, "a bandmate's two computers: counted once")
  -- the plan
  local o = { n = 4, from = 4, hub = "Bx", me = "Me", users = users, can = true, senders = 1 }
  local peer, serve, why = la4.hub_plan(o)
  assert(peer == "" and serve == false and why == nil, "a room of four where one sends: peer to peer, and nothing to say")
  o.hub = "Me"
  peer, serve = la4.hub_plan(o)
  assert(peer == "" and serve == false, "nor does its hub say it mixes")
  o.senders = 2
  assert(select(2, la4.hub_plan(o)) == true, "two send: the hub mixes")
  o.senders, o.hub = nil, "Bx"
  assert(la4.hub_plan(o) == "bx.ts.net:47281", "(not asked: as before)")
  -- a computer passing by: four for 43 s
  local m = {}
  assert(la4.hub_n(m, 3, 4, 0) == 3 and la4.hub_n(m, 4, 4, 100) == 3 and la4.hub_n(m, 4, 4, 143) == 3, "four for 43 s: still three (it was four at once, and for HUB_KEEP s after)")
  assert(la4.hub_n(m, 3, 4, 144) == 3 and la4.hub_n(m, 4, 4, 150) == 3, "gone, and back: counted from then")
  assert(la4.hub_n(m, 4, 4, 150 + la4.HUB_SETTLE) == 4, "four for HUB_SETTLE s: four")
  assert(la4.hub_n(m, 3, 4, 200 + la4.HUB_SETTLE) == 4 and la4.hub_n(m, 4, 4, 201 + la4.HUB_SETTLE) == 4, "then held: a status late for a moment, and back at once")
  -- how many send is held the same way (someone unmutes for a word: no switch; muted again: the mix stays HUB_KEEP s)
  local sm = {}
  assert(la4.hub_n(sm, 1, 2, 0) == 1 and la4.hub_n(sm, 2, 2, 5) == 1 and la4.hub_n(sm, 1, 2, 10) == 1, "a second sender for 5 s: one")
  assert(la4.hub_n(sm, 2, 2, 20) == 1 and la4.hub_n(sm, 2, 2, 20 + la4.HUB_SETTLE) == 2 and la4.hub_n(sm, 1, 2, 30 + la4.HUB_SETTLE) == 2, "for HUB_SETTLE s: two, and held")
  local src = assert(io.open("lib/liveaudio.lua", "rb")):read("a")
  assert(src:find("senders = liveaudio.hub_n(S.hub_mem.send, liveaudio.senders(S.las, users, liveaudio.my_la()), 2, reaper.time_precise())", 1, true), "hub_tick counts them")
  assert(la4.CEILING == 400, "the default ceiling: 400 ms (at 150 a link that holds packets longer ran dry at every hold, rt-r5)")
end

print("ok: rt-audio3 (the firewall rule's one bad look held; no live audio, no live mix and no hub while another can; a hub that sees the whole room keeps its role with Syncthing behind; a hub's mix only for two that send, in a room big enough for a while)")
