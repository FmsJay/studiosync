-- 0.60.0-rt (James): the direct link wired into the engine and UI (docs/realtime-roadmap.md steps 0 and 1). What arrived in the link's inbox
-- counts in receive, pending_events and forget_trimmed; messages go to their receivers by kind, once, and a file that comes after its message
-- is skipped; the peer list comes from a cache made on the Live sync tick (never a Syncthing call at send time); Play/Record together's start
-- on the shared clock; Health's rows for a missing or old extension.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function(p, sec, i)
    local keys = {}
    for k, v in pairs(sec_of(p, sec)) do if v ~= "" then keys[#keys + 1] = k end end
    table.sort(keys)
    local k = keys[i + 1]
    if k then return true, k, sec_of(p, sec)[k] end
    return false
  end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExePath = function() return "C:/REAPER" end,
  EnumProjects = function() return nil end,
  GetPlayStateEx = function() return 0 end,
  CountMediaItems = function() return 0 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end }) -- (the extension's: absent)

-- An in-memory studio folder
local files, reads = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) reads[#reads + 1] = path; local v = files[path]; if type(v) == "table" then return v end end
proxy.files = function(dir, ext)
  local t = {}
  for path in pairs(files) do
    local d, f = path:match("^(.*)/([^/]+)$")
    if d == dir and (not ext or f:sub(-#ext) == ext) then t[#t + 1] = f end
  end
  table.sort(t)
  return t
end
proxy.listing = function(dir, ext) return proxy.files(dir, ext) end
proxy.raw_listing = function(dir) return proxy.files(dir) end
proxy.subdirs = function(dir)
  local seen, t = {}, {}
  for path in pairs(files) do
    local s = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2):match("^([^/]+)/")
    if s and not seen[s] then seen[s] = true; t[#t + 1] = s end
  end
  table.sort(t)
  return t
end
proxy.write_json = function(path, v) files[path] = v end
proxy.home = function() return "H" end
proxy.info = function() return { id = "studiosync-smiley", name = "Smiley Studios" } end
proxy.song_dir = function(cfg, song) return cfg.root .. "/" .. song end
local logged = {}
proxy.log = function(t) logged[#logged + 1] = t end
package.loaded.band = proxy
reaper.file_exists = function(p) return files[p] ~= nil end

local device_asks = 0
package.loaded.services = { run_hidden = function() return nil end, TMP = "T", is_device_id = function(id) return type(id) == "string" and #id > 10 end,
  my_device_id = function() return "MMMMMMMMMMMM" end, rescan = function() end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end,
  sonobus_secret = function() return "s3cret" end, may_manage = function() return false end }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function() device_asks = device_asks + 1; return true end }
package.loaded.access = { read = function() return nil end, shows = function() return true end }
package.loaded.rooms = { list = function() return { { name = "main" } } end }

local R, S = "J:/St/Smiley", "Nostalgia"
local cfg = { root = R, user = "James" }
local edir = R .. "/" .. S .. "/rooms/main/events"
local idir = "H/direct/studiosync-smiley/" .. S .. "/rooms/main/events"
files[R .. "/_band/devices/Bee.json"] = { user = "Bee", device = "BBBBBBBBBBBB", ts = { ["tail99.ts.net"] = "bee-laptop.tail99.ts.net" } }
files[R .. "/_band/devices/Chilio.json"] = { user = "Chilio", device = "CCCCCCCCCCCC", ts = { ["tail99.ts.net"] = "chilis-mac.tail99.ts.net" } }

local sent, msg_box = {}, {}
local function ext_108()
  reaper.StudioSync_DirectStart = function() return 1 end
  reaper.StudioSync_DirectStop = function() end
  reaper.StudioSync_DirectSend = function(id, rel, path, peers) sent[#sent + 1] = { "send", rel, peers }; return 1 end
  reaper.StudioSync_DirectStatus = function() return '{"listening":true,"bind":"100.1.2.3:47281","peers":{}}' end
  reaper.StudioSync_DirectPoll = function() return "" end
  reaper.StudioSync_DirectMsg = function(id, kind, text, peers) sent[#sent + 1] = { "msg", kind, text, peers }; return 1 end
  reaper.StudioSync_DirectMsgPoll = function(after) for _, s in ipairs(msg_box) do if tonumber(s:match("^%d+")) > after then return s end end; return "" end
  reaper.StudioSync_DirectPeers = function() return 1 end
  reaper.StudioSync_DirectClock = function() return '{"peers":{}}' end
  reaper.StudioSync_DirectNow = function() return 1795100000 end
  reaper.StudioSync_DirectStream = function() return 1 end
  gext["BandSync\0menu extension"] = "1.0.8"
end
ext_108()
local direct = require("direct")
local sync = require("sync")
local json = require("json")

-- ---- 1. The inbox counts: pending_events, receive, forget_trimmed -------------------------------------------------------------------------
local proj = "P1"
files[edir .. "/Bee-20261119-120000Z-00001-0001.json"] = { id = "Bee-20261119-120000Z-00001-0001", type = "future", user = "Bee", time = "2026-11-19T12:00:00Z" }
files[idir .. "/Bee-20261119-120001Z-00002-0002.json"] = { id = "Bee-20261119-120001Z-00002-0002", type = "future", user = "Bee", time = "2026-11-19T12:00:01Z" }
assert(sync.pending_events(proj, cfg, S, "main") == 2, "the change only in the inbox is still to come too")
reads = {}
sync.receive(proj, cfg, S, "main", function() return true end)
local read_inbox = false
for _, p in ipairs(reads) do if p == idir .. "/Bee-20261119-120001Z-00002-0002.json" then read_inbox = true end end
assert(read_inbox, "receive read the inbox-only change from the inbox")
assert(sync.deferred["Bee-20261119-120001Z-00002-0002"], "and took it in (a kind this version doesn't know: set aside, as from the shared folder)")
sec_of(proj, sync.APPLIED)["Bee-20261119-120000Z-00001-0001"] = "1"
sec_of(proj, sync.APPLIED)["Bee-20261119-120001Z-00002-0002"] = "1"
sec_of(proj, sync.APPLIED)["Bee-20200101-000000Z-00001-0001"] = "1"
assert(sync.forget_trimmed(proj, cfg, S) == 1, "only the mark whose file is in neither place goes")
assert(sec_of(proj, sync.APPLIED)["Bee-20261119-120001Z-00002-0002"] == "1", "a change applied from the inbox keeps its mark (or it's applied again)")
assert(sec_of(proj, sync.APPLIED)["Bee-20200101-000000Z-00001-0001"] == "", "a trimmed one's goes")

-- ---- 2. The peer list: made on the tick, never asked at send time ------------------------------------------------------------------------
files[R .. "/" .. S .. "/rooms/main/status/Bee.json"] = { user = "Bee", time = os.date("!%Y-%m-%dT%H:%M:%SZ"), room = "main" }
local ok_rel = S .. "/rooms/main/events/James-20261119-120002Z-00003-0003.json"
sent, device_asks = {}, 0
assert(direct.offer(cfg, R .. "/" .. ok_rel) == false and device_asks == 0, "before a tick made the list: nothing sent, and Syncthing not asked")
local list = direct.refresh_peers(cfg, S, "main")
assert(#list == 1 and list[1] == "bee-laptop.tail99.ts.net:47281" and device_asks == 1, "the tick asks, for whoever's here")
device_asks = 0
assert(direct.offer(cfg, R .. "/" .. ok_rel) == true and device_asks == 0 and sent[#sent][3] == "bee-laptop.tail99.ts.net:47281", "sent from the cache, nothing asked")
direct.refresh_peers(cfg, S, "main")
assert(device_asks == 0, "not again within PEERS_EVERY")
-- a computer not asked before waits for the next refresh once this one has taken 50 ms (here: a first answer from Syncthing takes 0.06 s)
files[R .. "/_band/devices/Al.json"] = { user = "Al", device = "AAAAAAAAAAAA", ts = { ["tail99.ts.net"] = "al-pc.tail99.ts.net" } }
for _, u in ipairs({ "Al", "Chilio" }) do files[R .. "/" .. S .. "/rooms/main/status/" .. u .. ".json"] = { user = u, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), room = "main" } end
local answered = { Bee = true }
package.loaded.trust.device_ok = function(_, user) device_asks = device_asks + 1; if not answered[user] then answered[user] = true; clock = clock + 0.06 end; return true end
clock = clock + 31 -- (and the devices files read again)
list = direct.refresh_peers(cfg, S, "main")
assert(#list == 2 and not table.concat(list, " "):find("chilis"), "Al's computer asked (slowly), Chilio's not yet: " .. table.concat(list, " "))
clock = clock + 3
list = direct.refresh_peers(cfg, S, "main")
assert(#list == 3, "Chilio's asked at the next refresh")
files[R .. "/_band/devices/Al.json"], files[R .. "/" .. S .. "/rooms/main/status/Al.json"] = nil, nil
clock = clock + 31
list = direct.refresh_peers(cfg, S, "main")
package.loaded.trust.device_ok = function() device_asks = device_asks + 1; return true end
-- another script (the panel) has no cache of its own: it sends to the list Live sync made
package.loaded.direct = nil
local direct2 = require("direct")
assert(table.concat((direct2.peers(cfg, S, "main")), " ") == "bee-laptop.tail99.ts.net:47281 chilis-mac.tail99.ts.net:47281", "the panel reads Live sync's list")
package.loaded.direct = direct

-- ---- 3. Messages by kind, once, and the file after its message skipped ------------------------------------------------------------------
sent = {}
direct.send_live(cfg, "cue", { id = "Bee-1", type = "start" }, S, "main", "Bee-1")
local w = json.decode(sent[#sent][3])
assert(sent[#sent][2] == "cue" and w.song == S and w.room == "main" and w.id == "Bee-1" and w.d.type == "start", "a message says its song, room and id")
local got = {}
local handlers = { cue = function(d) got[#got + 1] = "cue " .. d.n end, presence = function(d) got[#got + 1] = "presence " .. d.user end }
local function m(kind, song, room, id, d) return { kind = kind, data = { song = song, room = room, id = id, d = d } } end
local n = direct.dispatch({ m("cue", S, "main", "c1", { n = 1 }), m("cue", S, "main", "c1", { n = 1 }), m("cue", "Other", "main", "c2", { n = 2 }),
  m("cue", S, "side", "c3", { n = 3 }), m("presence", S, "main", nil, { user = "Bee" }), m("unknown", S, "main", "u", {}), m("presence", S, "main", nil, { user = "Bee" }) },
  S, "main", handlers)
assert(n == 3 and table.concat(got, ",") == "cue 1,presence Bee,presence Bee", "this room's, each id once, by kind: " .. table.concat(got, ","))
got = {}
assert(direct.dispatch({ m("cue", "Other", "x", "c9", { n = 9 }) }, nil, nil, handlers) == 1 and got[1] == "cue 9", "nil song and room: any (the panel's chat)")
handlers.cue = function() error("bad") end
assert(direct.dispatch({ m("cue", S, "main", "c10", { n = 10 }) }, S, "main", handlers) == 0 and logged[#logged]:find("bad"), "a handler that fails is logged, nothing raised")

-- live MIDI: a message folds in under its file's name, so the file itself, coming after, is skipped
local lm = require("livemidi")
local draws = 0
lm.draw = function() draws = draws + 1 end
local mid = { user = "Bee", since = "20261119-120000Z", time = os.date("!%Y-%m-%dT%H:%M:%SZ"), at = 2, notes = { { i = 1, t = "Keys", s = 1, p = 60, v = 100 } } }
assert(lm.from_msg(proj, cfg, { song = S, room = "main" }, { f = "20261119-120000Z-0001.json", c = mid }, false) == true and draws == 1, "drawn at once")
assert(lm.from_msg(proj, cfg, { song = S, room = "main" }, { f = "20261119-120000Z-0001.json", c = mid }, false) == false and draws == 1, "the same one again: nothing")
assert(lm.from_msg(proj, cfg, { song = S, room = "main" }, { f = "../x.json", c = mid }, false) == false, "a name that isn't one of the files: refused")
assert(lm.from_msg(proj, cfg, { song = S, room = "main" }, { f = "20261119-120000Z-0009.json", c = { user = "James" } }, false) == false, "our own: nothing")
files[R .. "/" .. S .. "/rooms/main/live_midi/Bee/20261119-120000Z-0001.json"] = mid
lm.receive_tick(proj, cfg, { song = S, room = "main" })
assert(draws == 1, "its file arriving later is skipped: drawn once")
local mid2 = { user = "Bee", since = "20261119-120000Z", time = os.date("!%Y-%m-%dT%H:%M:%SZ"), at = 3, notes = { { i = 1, t = "Keys", s = 1, e = 2.5, p = 60, v = 100 } } }
assert(lm.from_msg(proj, cfg, { song = S, room = "main" }, { f = "20261119-120000Z-0002.json", c = mid2 }, true) == true and draws == 1, "recording here: not drawn now")
lm.receive_tick(proj, cfg, { song = S, room = "main" })
assert(draws == 2, "but by the next look")

-- presence: a status over the link is seen at once, used while newer than the file; a heartbeat moves its time on
local presence = require("presence")
local old = "2026-11-19T11:00:00Z"
files[R .. "/" .. S .. "/rooms/main/status/Bee.json"] = { user = "Bee", time = old, room = "main", view = { 1, 2 } }
local sts = presence.with_live({ { user = "Bee", time = old }, { user = "Chilio", time = old } }, { Bee = { user = "Bee", time = "2026-11-19T11:00:05Z" }, Al = { user = "Al", time = old } })
assert(#sts == 3 and sts[1].time == "2026-11-19T11:00:05Z" and sts[2].user == "Chilio" and sts[3].user == "Al", "newer live statuses in place, new ones added")
assert(presence.with_live({ { user = "Bee", time = "2026-11-19T11:00:09Z" } }, { Bee = { user = "Bee", time = old } })[1].time == "2026-11-19T11:00:09Z", "an older live one: the file's")
local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
clock = clock + 2
assert(presence.from_msg(cfg, S, "main", { user = "Bee", time = now_iso, room = "main", cursor = 4 }, "presence"), "taken")
clock = clock + 2
local here = presence.peers(cfg, S, "main")
local bee
for _, st in ipairs(here) do if st.user == "Bee" then bee = st end end
assert(bee and bee.cursor == 4 and bee.time == now_iso, "seen at once, the file being old")
assert(not presence.from_msg(cfg, S, "main", { user = "James", time = now_iso }, "presence"), "never our own")
assert(not presence.from_msg(cfg, S, "main", { user = "Bee", time = now_iso, room = "side" }, "presence"), "another room's: not this one's")
assert(not presence.from_msg(cfg, S, "main", { user = "Bee", time = 5 }, "presence"), "a malformed one")
local later = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 5)
assert(presence.from_msg(cfg, S, "main", { user = "Bee", time = later, room = "main" }, "heartbeat"), "a heartbeat")
clock = clock + 2
for _, st in ipairs(presence.peers(cfg, S, "main")) do if st.user == "Bee" then bee = st end end
assert(bee.time == later and bee.cursor == 4, "moves the time on, the rest kept")

-- claims: a newer claims set over the link counts at once; the file takes over when it says as much
files[R .. "/" .. S .. "/rooms/main/mode.json"] = { mode = "claims" }
files[R .. "/" .. S .. "/rooms/main/claims/Bee.json"] = { user = "Bee", time = "2026-11-19T12:00:00Z", tracks = { "Bass" } }
local _, who = sync.authority(cfg, S, "main", nil)
assert(who.tracks["bass"] and not who.tracks["keys"], "the file's claims")
assert(sync.live_claim(S, "main", { user = "Bee", time = "2026-11-19T12:00:05Z", tracks = { "Bass", "Keys" } }), "a claim message")
_, who = sync.authority(cfg, S, "main", nil)
assert(who.tracks["keys"] and who.tracks["keys"].user == "Bee", "counts before the file comes")
assert(not sync.live_claim(S, "main", { user = "Bee", time = "2026-11-19T12:00:01Z", tracks = {} }), "an older one: no")
assert(not sync.live_claim(S, "main", { user = "Bee", time = "2026-11-19T12:00:09Z", tracks = "Bass" }) and not sync.live_claim(S, "main", { user = "Bee", time = "x", tracks = { 5 } }),
  "malformed ones: no")
assert(not sync.live_claim(S, "main", { user = "Bee", time = "2026-11-19T12:00:09Z", given = true, tracks = {} }), "never a given one (those need the giver's computer)")
files[R .. "/" .. S .. "/rooms/main/claims/Bee.json"] = { user = "Bee", time = "2026-11-19T12:00:07Z", tracks = { "Drums" } }
_, who = sync.authority(cfg, S, "main", nil)
assert(who.tracks["drums"] and not who.tracks["keys"], "the file, once it's as new: it's the record")
sync.live_claim(S, "main", { user = "Al", time = "2026-11-19T12:00:00Z", tracks = { "Vox" } })
_, who = sync.authority(cfg, S, "main", nil)
assert(who.tracks["vox"] and who.tracks["vox"].user == "Al", "someone whose file hasn't come at all")

-- chat (the panel polls its own): shown until the file is here; checked before it names a path
local chat = require("page_chat")
local cmsg = { sc = "song", song = S, room = "main", name = "20261119-120000-Bee-1234", v = { text = "hi", user = "Bee", time = "2026-11-19T12:00:00Z" } }
assert(chat.from_msg(cfg, cmsg) == true and chat.from_msg(cfg, cmsg) == false, "taken once")
for _, bad in ipairs({ { sc = "song", song = "../x", room = "main", name = cmsg.name, v = cmsg.v }, { sc = "other", song = S, room = "main", name = cmsg.name, v = cmsg.v },
  { sc = "song", song = S, room = "main", name = "../../a", v = cmsg.v }, { sc = "song", song = S, room = "main", name = "20261119-120000-Bee-1", v = { text = 5, user = "Bee", time = "t" } },
  { sc = "song", song = S, room = "main", name = "20261119-120000-James-1", v = { text = "me", user = "James", time = "t" } } }) do
  assert(chat.from_msg(cfg, bad) == false, "refused: " .. tostring(bad.song) .. " " .. tostring(bad.sc) .. " " .. tostring(bad.name))
end
files[R .. "/" .. S .. "/chat/msgs/20261119-120001-Bee-5678.json"] = { text = "x" }
assert(chat.from_msg(cfg, { sc = "song", song = S, room = "main", name = "20261119-120001-Bee-5678", v = cmsg.v }) == false, "its file is here already: the file")

-- ---- 4. Play/Record together on the shared clock ----------------------------------------------------------------------------------------
local together = require("together")
assert(together.local_at(1000.5, 995.0, 50.0) == 55.5, "fires at this computer's now + (start_at - shared now)")
-- the laptop is 322.5 ms ahead: both compute the same instant in their own terms
local start_at = 2000 + 5
assert(math.abs(together.local_at(start_at, 2000, 7000) - 7005) < 1e-9 and math.abs(together.local_at(start_at, 2000, 7000.3225) - 7005.3225) < 1e-9, "each in its own clock")
-- the starter in the panel goes by the reference Live sync picked (ExtState), not its own empty view
reaper.StudioSync_DirectClock = function() return '{"peers":{"bee-laptop.tail99.ts.net:47281":{"offset_ms":322.5,"rtt_ms":57,"samples":16,"error":""}}}' end
package.loaded.direct = nil
local panel_direct = require("direct")
assert(panel_direct.shared_now() == nil, "nothing picked yet: unknown (not this computer's clock: the first 3-computer run, every computer its own reference)")
gext["BandSync\0direct reference"] = "bee-laptop.tail99.ts.net:47281\tBBBBBBBBBBBB"
local sn, ref, err, peer = panel_direct.shared_now()
assert(math.abs(sn - 1795100000.3225) < 1e-6 and ref == "BBBBBBBBBBBB" and err == 28.5 and peer == "bee-laptop.tail99.ts.net:47281", "Live sync's reference")
assert(math.abs(together.start_at(5) - 1795100005.3225) < 1e-6, "start_at = shared now + lead")
reaper.StudioSync_DirectClock = function() return '{"peers":{"bee-laptop.tail99.ts.net:47281":{"offset_ms":322.5,"rtt_ms":57,"samples":2,"error":""}}}' end
assert(panel_direct.shared_now() == nil, "its estimate not ready: unknown")
package.loaded.direct = direct
local saved_msg = reaper.StudioSync_DirectMsg
reaper.StudioSync_DirectMsg = nil
package.loaded.direct = nil
assert(together.start_at(5) == nil, "no live link: nil, and ev.at's internet time is used")
reaper.StudioSync_DirectMsg = saved_msg
package.loaded.direct = direct

-- ---- 5. Health: the extension is mandatory ---------------------------------------------------------------------------------------------
local rows = direct.health_rows(cfg)
assert(rows[1][1] == "direct" and rows[2][1] == "direct clock", "1.0.8 here: the link's row and the clock's")
assert(rows[1].action and rows[1].action[1] == "Set up direct link", "Windows without the firewall rule: the Set up direct link button")
package.loaded.services.run_hidden = function(name) return name == "direct-fw" and "Rule Name: StudioSync direct link\r\nProgram: C:\\REAPER\\reaper.exe\r\nLocalPort: 47281" or nil end
rows = direct.health_rows(cfg)
assert(rows[1].action == nil, "the rule there: no button")
assert(rows[2][5]:find("Shared clock", 1, true), "the clock's line: " .. rows[2][5])
gext["BandSync\0menu extension"] = "1.0.7"
reaper.StudioSync_DirectMsg = nil
rows = direct.health_rows(cfg)
assert(#rows == 1 and rows[1][1] == "menu ext" and rows[1][2] == false and rows[1][3] == "red" and rows[1][5]:find("1.0.7", 1, true) and rows[1][5]:find("1.0.8", 1, true)
  and rows[1][5]:find("ReaPack", 1, true), "older: a red problem, with the fix: " .. rows[1][5])
reaper.StudioSync_DirectStart = nil
gext["BandSync\0menu extension"] = nil
rows = direct.health_rows(cfg)
assert(#rows == 1 and rows[1][3] == "red" and rows[1][5]:find("isn't loaded", 1, true) and rows[1][5]:find("installer", 1, true), "missing: red, install it")
print("ok")
