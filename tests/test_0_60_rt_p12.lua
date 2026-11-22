-- rt-p12, the rest of package P12 (docs/rt/rt-p12.md):
--   1. Their time (backlog 1.16): a take recorded in it moves earlier by the delay held while recording (new items on the tracks armed for
--      it only, not a streamed placeholder, not what was there, nothing when nothing was noted before the take), in one undo point;
--   2. Produce (1.16): the performer's computer says a take started or ended the tick it happens, and the producer's duck follows that word
--      at once (not their status, read about once a second) for FAST_FOR s;
--   3. live audio's peer and vouch merges (rt-perfcut4 section 4) kept while what they read is the same, at most MERGE_HOLD s.
package.path = "lib/?.lua;" .. package.path
local clock, ext, pext = 1000, {}, {}
local front = { proj = true }
local play_state = 0
local tracks = {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetProjExtState = function(_, s, k) return 1, pext[s .. "/" .. k] or "" end,
  SetProjExtState = function(_, s, k, v) pext[s .. "/" .. k] = v end,
  EnumProjects = function() return front end,
  GetPlayStateEx = function() return play_state end,
  CountTracks = function() return #tracks end,
  GetTrack = function(_, i) return tracks[i + 1] end,
  GetTrackGUID = function(tr) return tr.guid end,
  GetMediaTrackInfo_Value = function(tr, k) if k == "I_RECARM" then return tr.arm end return 0 end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end,
  GetSetMediaItemInfo_String = function(it, k, v, set)
    if k == "GUID" then return true, it.guid end
    local key = k:match("^P_EXT:(.*)$")
    if set then it.ext[key] = v end
    return true, it.ext[key] or ""
  end,
  GetActiveTake = function(it) return it.take end,
  GetMediaItemInfo_Value = function(it, k) return it.v[k] or 0 end,
  SetMediaItemInfo_Value = function(it, k, v) it.v[k] = v end,
  GetMediaItemTakeInfo_Value = function(tk, k) return tk.v[k] or (k == "D_PLAYRATE" and 1 or 0) end,
  SetMediaItemTakeInfo_Value = function(tk, k, v) tk.v[k] = v end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end
local function src(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return (s:gsub("\r\n", "\n")) end

-- ---- 1. Their time: takes moved back by the delay ----
local livex = require("livex")
local m = livex.take_moves({ { id = "old", pos = 4, len = 2, offs = 0 }, { id = "new", pos = 8.15, len = 3, offs = 0.5 }, { id = "early", pos = 0.05, len = 2, offs = 0, rate = 2 } },
  { old = true }, 0.15)
assert(#m == 2 and m[1].id == "new" and near(m[1].pos, 8) and near(m[1].len, 3) and near(m[1].offs, 0.5), "a new take: 150 ms earlier, nothing else changed")
assert(m[2].id == "early" and m[2].pos == 0 and near(m[2].len, 1.9) and near(m[2].offs, 0.2), "before the project's start: the front trimmed (at its play rate)")
assert(#livex.take_moves({ { id = "new", pos = 8, len = 1 } }, {}, 0) == 0, "no delay: nothing moves")
-- with stand-ins: Live sync's ticks, Their time on at 150 ms
local delay = 150
package.loaded.hear = { delay = function() return delay end, set_delay = function(_, ms) delay = ms end, MAX_MS = 1000 }
package.loaded.liveaudio = { names = function() return {} end, apply = function() end }
local undo = {}
rawset(reaper, "Undo_BeginBlock2", function() undo[#undo + 1] = "begin" end)
rawset(reaper, "Undo_EndBlock2", function(_, what) undo[#undo + 1] = what end)
local function item(guid, pos, len, extra) local it = { guid = guid, v = { D_POSITION = pos, D_LENGTH = len }, ext = {}, take = { v = {} } }; for k, x in pairs(extra or {}) do it[k] = x end; return it end
local vox = { guid = "tv", arm = 1, items = { item("i1", 2, 4) } }
local gtr = { guid = "tg", arm = 0, items = {} }
tracks = { vox, gtr }
local proj = front
pext[band.SECTION .. "/their time live"] = "1"
pext[band.SECTION .. "/side"] = "0"
local function tick() clock = clock + livex.THEIR_EVERY; livex.their_tick(proj, { peers = { a = { streaming = true, latency_ms = 260 } } }) end
tick()
assert(delay == 260, "not recording: the delay follows the measurement")
delay = 150
tick() -- (noted: what's on the armed tracks)
delay = 150
play_state = 5 -- (recording)
tick()
assert(delay == 150, "recording: the delay is held, so a take moves back by one value")
vox.items[#vox.items + 1] = item("take", 10.15, 3) -- (REAPER's take, as recording ends)
vox.items[#vox.items + 1] = item("ph", 20, 1)
vox.items[#vox.items].ext.band_arriving = "1" -- (a bandmate's streamed placeholder: never ours to move)
gtr.items[1] = item("synced", 5, 1) -- (arrived from a bandmate on a track that wasn't armed)
vox.arm = 0 -- (disarmed right after the take: the take still moves)
play_state = 0
tick()
assert(near(vox.items[2].v.D_POSITION, 10), "the take: 150 ms earlier, onto the beat played to")
assert(vox.items[1].v.D_POSITION == 2 and vox.items[3].v.D_POSITION == 20 and gtr.items[1].v.D_POSITION == 5, "what was there, the placeholder, another track: untouched")
assert(#undo == 2 and undo[2]:find("Their time moved 150 ms earlier"), "one undo point")
assert(delay == 260, "after the take: the delay follows again")
-- Their time came on mid-take (nothing noted before it): nothing moves
livex.S.seen, livex.S.rec = nil, nil
vox.arm = 1
play_state = 5
tick()
vox.items[#vox.items + 1] = item("take2", 30.15, 2)
play_state = 0
tick()
assert(vox.items[#vox.items].v.D_POSITION == 30.15 and #undo == 2, "nothing noted before the take: nothing moved")

-- ---- 2. Produce: the duck on the performer's word ----
package.loaded.live = { builtin_audio = function() return true end }
band.binding = function() return { root = "R" } end
local applied = 0
package.loaded.liveaudio.apply = function() applied = applied + 1 end
local producer = require("producer")
assert(producer.rec_state(false, { rec = true, at = 100 }, 101) == true and producer.rec_state(true, { rec = false, at = 100 }, 102) == false, "their word goes before their (late) status")
assert(producer.rec_state(false, { rec = true, at = 100 }, 100 + producer.FAST_FOR + 0.1) == false and producer.rec_state(true, nil, 0) == true, "after FAST_FOR s, or without a word: the status")
-- the performer's side: a take starting and ending goes to whoever produces them, once each
local direct = require("direct")
local sent = {}
direct.live_available = function() return true end
direct.peers = function() return { "bob:1", "cy:1" }, {}, { ["bob:1"] = "Bob", ["cy:1"] = "Cy" } end
direct.send_live = function(_, kind, d, _, _, _, to) sent[#sent + 1] = { kind = kind, d = d, to = to } end
local ann_cfg, b = { user = "Ann", root = "R" }, { song = "Song", room = "main" }
ext[band.SECTION .. "/produced by " .. tostring(proj)] = "Bob"
play_state = 0
producer.rec_tick(proj, ann_cfg, b)
assert(#sent == 0, "nothing changed: nothing said")
play_state = 5
producer.rec_tick(proj, ann_cfg, b)
assert(#sent == 1 and sent[1].kind == "produce_rec" and sent[1].d.rec == true and #sent[1].to == 1 and sent[1].to[1] == "bob:1", "the take starts: Bob (who produces Ann) told at once")
producer.rec_tick(proj, ann_cfg, b)
assert(#sent == 1, "once")
play_state = 1
producer.rec_tick(proj, ann_cfg, b)
assert(#sent == 2 and sent[2].d.rec == false, "and when it ends")
-- the producer's side: Bob produces Ann over the live route
ext[band.SECTION .. "/produce " .. tostring(proj)] = "Ann"
assert(producer.on_rec({ user = "Ann", rec = true }) and ext[band.SECTION .. "/" .. producer.DUCK] == "Ann" and applied == 1, "her take started: her live Play ducked at once")
assert(producer.on_rec({ user = "Ann", rec = false }) and ext[band.SECTION .. "/" .. producer.DUCK] == "" and applied == 2, "ended: back")
assert(not producer.on_rec({ user = "Cy", rec = true }) and ext[band.SECTION .. "/" .. producer.DUCK] == "", "someone this computer doesn't produce: ignored")
assert(src("lib/producer.lua"):find("producer.rec_state(them and them.recording, fast_rec[name], reaper.time_precise())", 1, true),
  "the once-a-second tick goes by the same word, so it doesn't put a stale status back")
local ls = src("StudioSync - Live sync.lua")
assert(ls:find('produce_rec = function(d) require("producer").on_rec(d) end', 1, true) and ls:find('band.try("producer.rec_tick", require("producer").rec_tick, proj, cfg, b)', 1, true) and
  ls:find('jam_hear = function(d) require("jam").on_hear(cfg, b, d) end', 1, true), "Live sync hands both on, and ticks the performer's side each tick")

-- ---- 3. live audio's merges kept while what they read is the same ----
package.loaded.liveaudio, package.loaded.livex = nil, nil
package.loaded.services = { run_hidden = function(name) return name == "direct-fw" and
  "Rule Name: StudioSync direct link\r\nLocalPort: 47281\r\nProtocol: UDP\r\nProgram: C:\\REAPER\\reaper.exe\r\n" or nil end, TMP = "T",
  is_device_id = function(id) return type(id) == "string" and #id > 10 end, my_device_id = function() return "MEMEMEMEMEME" end }
package.loaded.groups = { trusted = function() return {} end, tailnet = function() return { name = "x", suffix = "t.ts.net" } end,
  sonobus_secret = function() return "s3cret" end, live_audio = function() return true end, live_hub = function() return 0 end }
package.loaded.removal = { guest_names = function() return {} end }
local fresh, here = {}, {}
package.loaded.presence = { peers = function() return fresh end,
  here = function(_, _, _, within) local t = {}; for u, age in pairs(here) do if age < within then t[#t + 1] = u end end; table.sort(t); return t end }
local E = { running = false, json = nil, nhp = {} }
for k, f in pairs({
  StudioSync_LiveAudioStart = function() E.running = true; return 1 end,
  StudioSync_LiveAudioStop = function() E.running = false end,
  StudioSync_LiveAudioPeers = function(js) E.json = js; return 1 end,
  StudioSync_LiveAudioPeerSet = function() return 1 end,
  StudioSync_LiveAudioStatus = function() return band.json_encode({ running = E.running, first = 0, nch = 1, kbps = 128, peers = {}, not_here_peers = E.nhp }) end,
}) do rawset(reaper, k, f) end
direct = require("direct")
local DESK, LAP = "desk.t.ts.net:47281", "lap.t.ts.net:47281"
local peers_here = { DESK }
direct.peers = function() return peers_here, {}, { [DESK] = "Desk", [LAP] = "Lap" } end
direct.port = function() return 47281 end
local la = require("liveaudio")
local merges = 0
local hm = la.heard_merge
la.heard_merge = function(...) merges = merges + 1; return hm(...) end
local cfg = { root = "R", user = "Lin" }
local bb = { song = "Song", room = "main" }
local function lt(dt) clock = clock + (dt or la.EVERY); la.tick(cfg, bb, front) end
fresh, here = { { user = "Desk", time = "t1", hub = { sees = { "Lin" } } } }, { Desk = 1 }
lt(); lt()
local n0 = merges
lt(); lt() -- (1 and 1.5 s after the merge)
assert(merges == n0, "idle ticks inside MERGE_HOLD: the merges skipped (" .. (merges - n0) .. " more)")
peers_here = { DESK, LAP }
lt()
assert(merges == n0 + 1 and band.json_decode(E.json).peers[2] == LAP, "the room's list changes: merged again at once, and the new list goes out")
lt()
fresh = { { user = "Desk", time = "t2", hub = { sees = { "Lin", "Mac" } } } }
lt()
assert(merges == n0 + 2, "a fresh status (its time, whom it reaches): merged again")
E.nhp = { ["100.9.9.9:47281"] = { ago = 0.2 } }
lt()
assert(merges == n0 + 3, "someone heard that the room doesn't list: merged again")
local n1 = merges
lt(); lt()
assert(merges == n1 or merges == n1 + 1, "then held")
lt(la.MERGE_HOLD)
assert(merges > n1, "past MERGE_HOLD s: merged again anyway (the time-based parts)")
print("ok p12: Their time's takes moved back, Produce's duck on the word, live audio's merges held")
