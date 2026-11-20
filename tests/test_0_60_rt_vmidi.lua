-- Live keys and the on-screen instrument (lib/livekeys.lua, lib/webui/vkeys.js; docs/rt/rt-vmidi.md): what a page may send, the order guard
-- (an off that overtook its on stays off), held notes let go (on a word, quiet, refusal, track change, exit), the track armed on the virtual
-- keyboard and put back as it was (only what's still ours), the room's rule (the real sync.authority over a stand-in shared folder), the topic
-- for the page's round trip, and a link check of the pages' hooks. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, logged = {}, {}
local clock = 1000
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end

-- ---- a stand-in shared folder, read by the real sync.authority -----------------------------------------------------------------------
local files = {}
band.read_json = function(path) return files[path] end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
local R = "R/S/rooms/main"
files["R/S/session.json"] = { host = "James" }
local function room(mode, claims)
  for p in pairs(files) do if p:find("^" .. R) then files[p] = nil end end
  files[R .. "/mode.json"] = { mode = mode }
  for user, c in pairs(claims or {}) do c.user, c.time = user, "2026-11-20T10:00:00Z"; files[R .. "/claims/" .. user .. ".json"] = c end
end
package.loaded.groups = { may_manage = function(_, user) return user == "Admin" end }
package.loaded.mirror = {
  local_track = function(tr) return tr["local"] == true end,
  track_oid = function(tr) return (tr.oid or ""):upper() end,
  item_oid = function() return "" end,
  is_creator = function(oid, user) return (oid or ""):match("^%a%-(.-)%-") == user:upper() end,
}
require("presence").peers = function() return {} end
local lk = require("livekeys")

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local d = lk.parse({ track = "{A-1}", sid = "p1", ev = { { 0x90, 60, 100, 1 }, { 0x80, 60, 0, 2 }, { 0xC0, 5, 0, 3 }, { 0x90, 200, 1, 4 },
  { 0xF0, 1, 1, 5 }, { 0x90, 61, 1, -1 }, { 0x90, 62, 1.5, 6 }, "x", { 0xB0, 64, 127, 7 } } })
assert(d and d.on and d.track == "{A-1}" and d.sid == "p1", "a keys message")
assert(#d.ev == 3 and d.ev[1][2] == 60 and d.ev[2][1] == 0x80 and d.ev[3][1] == 0xB0, "only notes, controllers, bends and pressures with plain bytes and a sequence")
assert(lk.parse({ on = false }).on == false, "an off needs no track")
assert(lk.parse({ track = "x", sid = "p" }) == nil, "a track is a GUID")
assert(lk.parse({ track = "{A}", sid = "<b>" }) == nil, "a page id is plain")
local many = {}
for i = 1, lk.EV_MAX + 1 do many[i] = { 0x90, 60, 1, i } end
assert(lk.parse({ track = "{A}", sid = "p", ev = many }) == nil, "a size limit on one action")
assert(lk.slot(0x90, 60) == lk.slot(0x80, 60) and lk.slot(0x91, 60) ~= lk.slot(0x90, 60) and lk.slot(0xB0, 60) ~= lk.slot(0x90, 60), "a note's on and off share a slot, per channel")
local held = {}
lk.hold(held, 0x90, 60, 100); lk.hold(held, 0x99, 36, 90); lk.hold(held, 0x90, 64, 100); lk.hold(held, 0x90, 64, 0); lk.hold(held, 0xB0, 64, 127)
local rel = lk.release(held)
assert(#rel == 6 and rel[1][1] == 0x80 and rel[1][2] == 60 and rel[2][1] == 0x89 and rel[2][2] == 36, "each held note's off (a note-on at 0 is an off)")
assert(rel[3][1] == 0xB0 and rel[3][2] == 64 and rel[4][2] == 123 and rel[5][1] == 0xB9, "then sustain up and all notes off on each channel used")
assert(lk.takes_vkb(lk.INPUT) and lk.takes_vkb(4096 + (63 << 5)) and not lk.takes_vkb(4096 + (3 << 5)) and not lk.takes_vkb(2), "the virtual keyboard, or all MIDI inputs")

-- ---- a stand-in REAPER -----------------------------------------------------------------------------------------------------------------
local tracks, sent = {}, {}
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return tracks[i + 1] end
reaper.GetTrackGUID = function(tr) return tr.guid end
reaper.GetTrackName = function(tr) return true, tr.name end
reaper.GetMediaTrackInfo_Value = function(tr, k) return tr[k] or 0 end
reaper.SetMediaTrackInfo_Value = function(tr, k, v) tr[k] = v end
reaper.ValidatePtr2 = function(_, tr) for _, t in ipairs(tracks) do if t == tr then return true end end return false end
reaper.StuffMIDIMessage = function(mode, a, b2, c) assert(mode == 0, "the virtual keyboard's queue"); sent[#sent + 1] = { a, b2, c } end
local keys = { name = "Keys", guid = "{AA}", oid = "T-JAMES-1", I_RECINPUT = 1024, I_RECMON = 0, I_RECARM = 0 }
local synth = { name = "Synth", guid = "{BB}", oid = "T-CHILIO-2", I_RECINPUT = 4096 + (63 << 5), I_RECMON = 1, I_RECARM = 1 }
local mine = { name = "Real time", guid = "{CC}", ["local"] = true }
tracks = { keys, synth, mine }
local b = { song = "S", room = "main" }
local function as(user) return { root = "R", user = user } end
local pub = {}
local function publish(topic, t) pub[topic] = t end
local function play(user, k) return require("phonedaw").action("P", as(user), b, { keys = k }) end
local function tick(user) lk.tick("P", as(user or "James"), b, publish, clock) end
local room0 = room
room = function(...) room0(...); clock = clock + lk.AUTH_EVERY end -- (who may is asked again at most every AUTH_EVERY s)

room("open")
local said = play("James", { track = "{AA}", sid = "p1", ev = { { 0x90, 60, 100, 1 }, { 0x90, 64, 90, 2 } } })
assert(said and said:find("playing Keys live"), "through phonedaw's action, said once: " .. tostring(said))
assert(keys.I_RECARM == 1 and keys.I_RECMON == 1 and keys.I_RECINPUT == lk.INPUT, "the track armed, monitored, on the virtual keyboard")
assert(#sent == 2 and sent[1][1] == 0x90 and sent[1][2] == 60 and sent[2][2] == 64, "the notes went into REAPER's queue in order")
tick()
assert(pub.phonekeys.seq == 2 and pub.phonekeys.sid == "p1" and pub.phonekeys.track == "{AA}" and not pub.phonekeys.why, "the topic says the last one applied: the page's round trip")
assert(pub.phonekeys.also and pub.phonekeys.also[1] == "Synth", "and which other armed tracks hear the virtual keyboard too")
-- overtaking: the off (4) came before its on (3)
sent = {}
play("James", { track = "{AA}", sid = "p1", ev = { { 0x80, 67, 0, 4 } } })
play("James", { track = "{AA}", sid = "p1", ev = { { 0x90, 67, 100, 3 }, { 0x80, 60, 0, 5 } } })
assert(#sent == 2 and sent[1][1] == 0x80 and sent[2][2] == 60, "an on older than its note's off is dropped: no stuck note")
-- the page goes quiet with a note held: let go after GRACE, the track kept until IDLE
sent = {}
clock = clock + lk.GRACE + 0.5
tick()
assert(#sent == 3 and sent[1][1] == 0x80 and sent[1][2] == 64 and sent[2][2] == 64 and sent[3][2] == 123, "quiet with notes held: each off, sustain up, all notes off")
assert(keys.I_RECARM == 1, "the track stays ready a while")
sent = {}
tick()
assert(#sent == 0, "let go once")
clock = clock + lk.IDLE
tick()
assert(keys.I_RECARM == 0 and keys.I_RECMON == 0 and keys.I_RECINPUT == 1024 and pub.phonekeys.track == nil, "quiet for IDLE: put back as it was")
-- a word from the page: off
play("James", { track = "{AA}", sid = "p2", ev = { { 0x90, 50, 100, 1 } } })
sent = {}
play("James", { on = false, sid = "p2" })
assert(#sent == 3 and sent[1][2] == 50 and keys.I_RECARM == 0, "the page stops: notes off, put back")
-- someone here changed something meanwhile: that part stays theirs
play("James", { track = "{AA}", sid = "p2", ev = {} })
keys.I_RECMON = 2
play("James", { on = false, sid = "p2" })
assert(keys.I_RECMON == 2 and keys.I_RECARM == 0 and keys.I_RECINPUT == 1024, "only what's still as this set it goes back")
keys.I_RECMON = 0
-- an already armed track stays armed
synth.I_RECARM, synth.I_RECMON = 1, 1
room("open", { Chilio = { tracks = { "Synth" } } })
local why = play("James", { track = "{BB}", sid = "p3", ev = { { 0x90, 60, 100, 1 } } })
assert(why and why:find("Chilio has claimed Synth"), "someone else's claimed track: refused: " .. tostring(why))
tick()
assert(pub.phonekeys.why:find("Chilio") and pub.phonekeys.sid == "p3", "and the page hears why")
play("Chilio", { track = "{BB}", sid = "p3", ev = { { 0x90, 60, 100, 1 } } })
play("Chilio", { on = false, sid = "p3" })
assert(synth.I_RECARM == 1 and synth.I_RECMON == 1 and synth.I_RECINPUT == 4096 + (63 << 5), "its claimant may; an armed track is left armed, its input as it was")
assert(play("James", { track = "{CC}", sid = "p4" }):find("own track"), "never this computer's own tracks")
-- a claim made while playing: let go and put back within AUTH_EVERY
room("open")
play("James", { track = "{AA}", sid = "p5", ev = { { 0x90, 60, 100, 1 } } })
room("open", { Chilio = { tracks = { "Keys" } } })
sent = {}
clock = clock + lk.AUTH_EVERY + 0.1
tick()
assert(sent[1] and sent[1][1] == 0x80 and keys.I_RECARM == 0 and pub.phonekeys.why:find("Chilio"), "claimed meanwhile: notes off, put back, said")
room("open")
-- another track taken over: the first let go and put back; Driver only
play("James", { track = "{AA}", sid = "p6", ev = { { 0x90, 60, 100, 1 } } })
synth.I_RECARM, synth.I_RECMON, synth.I_RECINPUT = 0, 0, 0
sent = {}
play("James", { track = "{BB}", sid = "p6", ev = { { 0x90, 61, 100, 2 } } })
assert(sent[1][1] == 0x80 and sent[1][2] == 60 and keys.I_RECARM == 0 and synth.I_RECARM == 1, "another track: the first let go and put back")
-- a page reloads (a new sid): its count starts again, the old page's notes let go
sent = {}
play("James", { track = "{BB}", sid = "p7", ev = { { 0x90, 62, 100, 1 } } })
assert(sent[1][1] == 0x80 and sent[1][2] == 61 and sent[#sent][2] == 62, "a new page id: the old one's notes off, the new one's seq 1 plays")
-- Live sync stops: everything off, put back
sent = {}
lk.on_exit()
assert(sent[1][2] == 62 and synth.I_RECARM == 0 and synth.I_RECINPUT == 0, "at exit: notes off, the track as it was")
-- the track deleted meanwhile
play("James", { track = "{AA}", sid = "p8", ev = {} })
tracks = { synth, mine }
tick()
assert(pub.phonekeys.track == nil and pub.phonekeys.why:find("deleted"), "a deleted track: let go, said")
room("driver")
tracks = { keys, synth, mine }
assert(play("Chilio", { track = "{AA}", sid = "p9" }):find("only the driver"), "Driver only")

-- ---- the pages' hooks (a link check, not a browser test: that ran in Chromium against a stand-in server) --------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local html, rec, pd, sw, vk, pr, webui, ls = read("lib/webui/record.html"), read("lib/webui/record.js"), read("lib/webui/phonedaw.js"),
  read("lib/webui/phone-sw.js"), read("lib/webui/vkeys.js"), read("lib/webui/pianoroll.js"), read("lib/webui.lua"), read("StudioSync - Live sync.lua")
assert(html:find('src="vkeys.js"', 1, true) and html:find('href="vkeys.css"', 1, true) and html:find('data-view="ply"', 1, true), "the phone app loads the instrument and has a Play view")
for _, f in ipairs({ "vkeys.js", "vkeys.css" }) do assert(sw:find("'" .. f .. "'", 1, true), "kept on the phone for offline: " .. f) end
assert(rec:find("ssKeysBus", 1, true) and pd:find("ssKeysBus", 1, true), "the on-screen notes reach a MIDI take")
assert(pd:find("keys:", 1, true) and pd:find("phonekeys", 1, true) and pd:find("panic", 1, true), "the Play view plays live, times it and lets go")
assert(vk:find("requestMIDIAccess", 1, true) and vk:find("pointerdown", 1, true) and vk:find("GM_PADS", 1, true), "Web MIDI, pointer events and the GM pads in vkeys.js")
assert(read("lib/webui/vkeys.css"):find("touch-action: none", 1, true), "no scrolling or zooming while playing")
assert(pr:find("vkeys.js", 1, true) and pr:find("Step", 1, true), "the piano roll's step input")
assert(webui:find('require("livekeys").tick', 1, true) and ls:find("livekeys.on_exit", 1, true), "Live sync ticks it and lets go at exit")
print("ok")
