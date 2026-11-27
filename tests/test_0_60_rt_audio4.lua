-- rt-audio4 (2026-11-27, docs/rt/rt-audio4.md): the Lua side of the live-audio relay (lib/liverelay.lua) and its version gate.
--   1. The gate: the relay is on only when this computer and every computer on its live-audio list say "lrelay" in their status (one that
--      doesn't, or has no status here, may be a 1.0.40: the room then runs exactly what it ran before).
--   2. The order: the hub first, then wired computers, then by name; the same list on every computer (this one as "").
--   3. The tick: the extension is told on a change only; the log says what changed.
--   4. hub_tick end to end: a big room whose computers all relay asks the extension for the relay and for no mix; one 1.0.40 computer in it
--      and hub_tick asks for the mix exactly as before.
--   5. Health's words.
-- The relay itself (forwarding, the lease, the merge) is in tests/rtaudio_test.cpp relay_test. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local ext, now_p, logged, relayed, hubbed = {}, 1000, {}, {}, {}
reaper = setmetatable({
  time_precise = function() return now_p end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  StudioSync_LiveAudioRelay = function(j) relayed[#relayed + 1] = j; return 1 end,
  StudioSync_LiveAudioHub = function(peer, serve) hubbed[#hubbed + 1] = tostring(peer) .. "|" .. tostring(serve); return 1 end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local statuses = {}
package.loaded.presence = { peers = function() return statuses end, here = function() return {} end }
package.loaded.groups = { live_hub = function() return 4 end, tailnet = function() return nil end }
package.loaded.livex = { mix_host = function(cfg, b, hub) return hub, nil, nil end, guests = function() return {} end, their_tick = function() end }
package.loaded.hub = { view = function() return { hub = "Bx" } end, fit = function() return true end, fits = function() return true end,
  NO_LA = { ext = true, tailscale = true, firewall = true, down = true }, VOUCH = 150, seen = function() return {} end }
local lr = require("liverelay")

-- ---- 1. the gate --------------------------------------------------------------------------------------------------------------------
do
  local users = { ["bx.ts.net:47281"] = "Bx", ["cy.ts.net:47281"] = "Cy" }
  local sts = { Bx = { user = "Bx", lrelay = true }, Cy = { user = "Cy", lrelay = true } }
  assert(lr.gate(sts, users, true) == "yes", "every computer here relays: yes")
  assert(lr.gate(sts, users, false) == "no", "this one doesn't: no")
  sts.Cy.lrelay = nil
  assert(lr.gate(sts, users, true) == "no", "one whose status doesn't say lrelay (1.0.40): no, the room as before")
  sts.Cy = nil
  assert(lr.gate(sts, users, true) == "wait", "one with no status here yet (heard before its status came): wait")
  assert(lr.gate({}, {}, true) == "yes", "alone: yes (nothing to relay, nothing lost)")
  assert(lr.can() and lr.mine() == true, "this extension has it: the status says lrelay")
  -- held: on after SETTLE s of yes, off at once on a no, a wait keeps what it was
  local m = {}
  assert(not lr.held("yes", m, 0) and not lr.held("yes", m, lr.SETTLE - 1) and lr.held("yes", m, lr.SETTLE), "on after SETTLE s of yes, not before")
  assert(lr.held("wait", m, lr.SETTLE + 5), "a status late for a moment: stays on (no switch to the mix and back)")
  assert(not lr.held("no", m, lr.SETTLE + 6), "an older extension appears: off at once")
  assert(not lr.held("wait", m, lr.SETTLE + 7) and not lr.held("yes", m, lr.SETTLE + 8), "and a wait or a fresh yes doesn't put it back on")
  assert(lr.held("yes", m, 2 * lr.SETTLE + 8), "until SETTLE s of yes again")
end

-- ---- 2. the order -------------------------------------------------------------------------------------------------------------------
do
  local users = { ["ax.ts.net:47281"] = "Ax", ["bx.ts.net:47281"] = "Bx", ["cy.ts.net:47281"] = "Cy" }
  local nets = { Ax = "wifi", Bx = "wifi", Cy = "wired", Me = "wifi" }
  local o = lr.order("Bx", "Me", users, nets)
  assert(o[1] == "bx.ts.net:47281" and o[2] == "cy.ts.net:47281" and o[3] == "ax.ts.net:47281" and o[4] == "", "the hub, then wired, then by name; me as \"\": " .. table.concat(o, " "))
  -- the same list on another computer, with its own entry as ""
  local users2 = { ["ax.ts.net:47281"] = "Ax", ["cy.ts.net:47281"] = "Cy", ["me.ts.net:47281"] = "Me" }
  local o2 = lr.order("Bx", "Bx", users2, nets)
  assert(o2[1] == "" and o2[2] == "cy.ts.net:47281" and o2[3] == "ax.ts.net:47281" and o2[4] == "me.ts.net:47281", "Bx's own list: the same order: " .. table.concat(o2, " "))
  local o3 = lr.order(nil, "Me", users, {})
  assert(o3[1] == "ax.ts.net:47281" and o3[4] == "", "no hub, no nets: by name")
  local two = lr.order("Bx", "Me", { ["b1:1"] = "Bx", ["b2:1"] = "Bx" }, {})
  assert(#two == 2 and two[1] == "b1:1", "a computer listed under two names: once, the first")
  local j = lr.json(true, true, o)
  assert(j:find('"on":1', 1, true) and j:find('"all":1', 1, true) and j:find('"order":["bx.ts.net:47281"', 1, true), "the extension's JSON: " .. j)
  assert(lr.json(false, true, o):find('"all":0', 1, true), "off: all off too")
end

-- ---- 3. the tick ----------------------------------------------------------------------------------------------------------------------
do
  relayed, logged = {}, {}
  local users = { ["bx.ts.net:47281"] = "Bx", ["cy.ts.net:47281"] = "Cy" }
  statuses = { { user = "Bx", lrelay = true, net = "wired" }, { user = "Cy", lrelay = true } }
  local mem, cfg, b = {}, { user = "Me" }, { song = "Cross Test" }
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == false and #relayed == 1 and relayed[1]:find('"on":0', 1, true), "everyone relays, not yet SETTLE s: off")
  now_p = now_p + lr.SETTLE
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == true and #relayed == 2, "on: the extension told")
  table.remove(relayed, 1)
  assert(relayed[1]:find('"on":1', 1, true) and relayed[1]:find('"all":1', 1, true), "everything through it")
  assert(logged[#logged]:find("through the room's relay", 1, true), "and the log says so")
  now_p = now_p + 2
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == true and #relayed == 1, "nothing changed: not told again")
  assert(lr.tick(cfg, b, users, { all = false, hub = "Bx", me = "Me" }, mem) == true and #relayed == 2 and relayed[2]:find('"all":0', 1, true), "a small room: only the gaps")
  assert(logged[#logged]:find("carries any bandmate whose stream can't reach you directly", 1, true), "said")
  statuses[2].lrelay = nil
  now_p = now_p + 2
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == false and relayed[3]:find('"on":0', 1, true), "Cy has an older extension: off at once")
  assert(logged[#logged]:find("older StudioSync extension", 1, true), "and the log says why")
  statuses[2] = { user = "Cy", lrelay = true } -- (its new status, read from the room)
  now_p = now_p + 0.5
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == false, "statuses looked at once a second: not yet")
  now_p = now_p + 1
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == false, "read: yes, but not yet SETTLE s")
  statuses[2] = nil -- (Cy's status late here for a moment: on its list, no status)
  now_p = now_p + lr.SETTLE
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == false, "a wait doesn't open it")
  statuses[2] = { user = "Cy", lrelay = true }
  now_p = now_p + 1.5
  lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem)
  now_p = now_p + lr.SETTLE
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == true, "then on again")
  statuses[2] = nil
  now_p = now_p + 2
  assert(lr.tick(cfg, b, users, { all = true, hub = "Bx", me = "Me" }, mem) == true, "and a status late for a moment leaves it on")
end

-- ---- 4. hub_tick end to end ---------------------------------------------------------------------------------------------------------
do
  local la = require("liveaudio")
  local users = { ["bx.ts.net:47281"] = "Bx", ["cy.ts.net:47281"] = "Cy", ["dz.ts.net:47281"] = "Dz" }
  local list = { "bx.ts.net:47281", "cy.ts.net:47281", "dz.ts.net:47281" }
  statuses = { { user = "Bx", lrelay = true, la = "on" }, { user = "Cy", lrelay = true, la = "on" }, { user = "Dz", lrelay = true, la = "on" } }
  ext[band.SECTION .. "/menu extension"] = "1.0.41"
  local cfg, b, st = { user = "Me", root = "R" }, { song = "Cross Test" }, { running = true, hub = {} }
  la.S.hub_mem, la.S.hub_asked, la.S.relay_json, la.S.srcs = nil, nil, nil, nil
  relayed, hubbed = {}, {}
  -- a room of four, all sending, held big for HUB_SETTLE s (hub_n), all relaying
  for _ = 1, 3 do la.hub_tick(cfg, b, list, users, st); now_p = now_p + la.HUB_SETTLE / 2 + 1 end
  la.hub_tick(cfg, b, list, users, st)
  assert(#relayed >= 1 and relayed[#relayed]:find('"on":1', 1, true) and relayed[#relayed]:find('"all":1', 1, true), "a big room that all relays: the relay, everything through it")
  assert(hubbed[#hubbed] == "|0" and la.S.hub.relay == true and la.S.hub.peer == "", "and no mix asked for (it would have been Bx's)")
  -- Dz with a 1.0.40: the gate closes, and the mix is asked for exactly as before
  statuses[3].lrelay = nil
  now_p = now_p + 2
  la.hub_tick(cfg, b, list, users, st)
  assert(relayed[#relayed]:find('"on":0', 1, true), "one old computer: the relay off")
  assert(hubbed[#hubbed] == "bx.ts.net:47281|0" and not la.S.hub.relay, "and Bx's mix asked for, as today: " .. tostring(hubbed[#hubbed]))
end

-- ---- 5. Health ------------------------------------------------------------------------------------------------------------------------
do
  assert(lr.text(nil) == nil and lr.text({ on = false }) == nil, "off: nothing said")
  local t = lr.text({ on = true, holder = "bx.ts.net:47281", relayed = 2 }, { ["bx.ts.net:47281"] = "Bx" })
  assert(t:find("Bx's computer holds it", 1, true) and t:find("2 bandmates reach you through it", 1, true), t)
  t = lr.text({ on = true, holder = "me", fwd_kbps = 5800.4, asking = 5 }, {})
  assert(t:find("this computer holds it (forwarding 5800 kbit/s to 5)", 1, true), t)
  assert(lr.text({ on = true, holder = "" }):find("nobody holds it yet", 1, true), "nobody yet")
  local la = require("liveaudio")
  local ok, text = la.health_text({ nch = 1, kbps = 128, peers = {}, relay = { on = true, holder = "me", fwd_kbps = 10, asking = 1 } }, {}, {}, nil, nil, nil, nil)
  assert(text:find("the room's relay: this computer holds it", 1, true), "in Health's live audio row: " .. tostring(text))
end
print("ok test_0_60_rt_audio4")
