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
assert(#d.ev == 4 and d.ev[1][2] == 60 and d.ev[2][1] == 0x80 and d.ev[3][1] == 0xC0 and d.ev[3][2] == 5 and d.ev[4][1] == 0xB0,
  "notes, program changes, controllers, bends and pressures with plain bytes and a sequence (nothing else: rt-p5 lets program changes through)")
assert(#lk.parse({ track = "{A}", sid = "p", ev = { { 0xC3, 9, nil, 4 } } }).ev == 1 and lk.parse({ track = "{A}", sid = "p", ev = { { 0xC3, 9, nil, 4 } } }).ev[1][3] == 0,
  "a program change has one data byte: the page may leave the second out")
assert(#lk.parse({ track = "{A}", sid = "p", ev = { { 0xC0, 200, 0, 1 }, { 0xF0, 1, 1, 2 }, { 0xF8, 0, 0, 3 } } }).ev == 0, "a program number past 127, system messages: dropped")
assert(lk.parse({ track = "{A}", sid = "p", pads = true }).pads and not lk.parse({ track = "{A}", sid = "p", pads = "yes" }).pads, "the page says whether it plays pads")
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
assert(lk.input(0) == lk.INPUT and lk.input(3) == lk.INPUT + 3, "the virtual keyboard on one channel")
assert(lk.takes_vkb(lk.input(3), 3) and not lk.takes_vkb(lk.input(3), 4) and lk.takes_vkb(lk.INPUT, 4) and lk.takes_vkb(4096 + (63 << 5) + 4, 4) and not lk.takes_vkb(4096 + (63 << 5) + 4, 5),
  "a track on another page's channel doesn't hear this one")
assert(lk.pick_channel({}, false) == 1 and lk.pick_channel({ [1] = true }, false) == 2 and lk.pick_channel({}, true) == 10 and lk.pick_channel({ [10] = true }, true) == 1, "channels: first free; pads want 10")
assert(lk.pick_channel({ [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true }, false) == 11, "keys keep off 10 while others are free")
local all16 = {}
for c = 1, 16 do all16[c] = true end
assert(lk.pick_channel(all16, false) == nil, "all 16 taken: none")

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
assert(keys.I_RECARM == 1 and keys.I_RECMON == 1 and keys.I_RECINPUT == lk.input(1), "the track armed, monitored, on the virtual keyboard, on the page's own channel")
assert(#sent == 2 and sent[1][1] == 0x90 and sent[1][2] == 60 and sent[2][2] == 64, "the notes went into REAPER's queue in order")
tick()
local pk = pub.phonekeys.pages.p1
assert(pk.seq == 2 and pk.sid == "p1" and pk.track == "{AA}" and pk.ch == 1 and not pk.why, "the topic says the last one applied: the page's round trip")
assert(pk.also and pk.also[1] == "Synth", "and which other armed tracks hear the virtual keyboard too")
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
assert(keys.I_RECARM == 0 and keys.I_RECMON == 0 and keys.I_RECINPUT == 1024 and pub.phonekeys.pages.p1.track == nil, "quiet for IDLE: put back as it was")
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
assert(pub.phonekeys.pages.p3.why:find("Chilio") and pub.phonekeys.pages.p3.sid == "p3", "and the page hears why")
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
assert(sent[1] and sent[1][1] == 0x80 and keys.I_RECARM == 0 and pub.phonekeys.pages.p5.why:find("Chilio"), "claimed meanwhile: notes off, put back, said")
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
assert(pub.phonekeys.pages.p8.track == nil and pub.phonekeys.pages.p8.why:find("deleted"), "a deleted track: let go, said")
room("driver")
tracks = { keys, synth, mine }
assert(play("Chilio", { track = "{AA}", sid = "p9" }):find("only the driver"), "Driver only")

-- ---- rt-p5: a channel for each page: two phones play two tracks; program changes; one page takes a track another holds -------------------------------
lk.reset()
local bass = { name = "Bass", guid = "{DD}", oid = "T-JAMES-4", I_RECINPUT = 1024, I_RECMON = 0, I_RECARM = 0 }
local lead = { name = "Lead", guid = "{EE}", oid = "T-JAMES-5", I_RECINPUT = 1024, I_RECMON = 0, I_RECARM = 0 }
keys.I_RECINPUT, keys.I_RECMON, keys.I_RECARM = 1024, 0, 0
synth.I_RECINPUT, synth.I_RECMON, synth.I_RECARM = 4096 + (63 << 5), 1, 1
tracks = { keys, synth, mine, bass, lead }
room("open")
sent = {}
play("James", { track = "{AA}", sid = "pa", ev = { { 0x90, 60, 100, 1 } } })
play("James", { track = "{DD}", sid = "pb", ev = { { 0x90, 40, 100, 1 }, { 0xC0, 33, nil, 2 } } })
assert(keys.I_RECINPUT == lk.input(1) and bass.I_RECINPUT == lk.input(2), "two pages, two tracks: each on a channel of its own")
assert(keys.I_RECARM == 1 and bass.I_RECARM == 1, "both armed at once (the old rule let the second take over)")
assert(sent[1][1] == 0x90 and sent[2][1] == 0x91 and sent[2][2] == 40, "each page's notes go in on its own channel")
assert(sent[3][1] == 0xC1 and sent[3][2] == 33 and sent[3][3] == 0, "a program change goes through, on its page's channel")
tick()
local pg = pub.phonekeys.pages
assert(pg.pa.ch == 1 and pg.pb.ch == 2 and pg.pa.track == "{AA}" and pg.pb.track == "{DD}", "the topic tells each page its own")
assert(pg.pb.also and #pg.pb.also == 1 and pg.pb.also[1] == "Synth" and pg.pa.also and #pg.pa.also == 1, "a track on another page's channel isn't said to hear it: only the all-input one")
-- a pad page wants channel 10, and sends whatever channel; it comes out on 10
sent = {}
play("James", { track = "{EE}", sid = "pc", pads = true, ev = { { 0x99, 36, 110, 1 } } })
assert(lead.I_RECINPUT == lk.input(10) and sent[1][1] == 0x99 and sent[1][2] == 36, "pads: channel 10")
-- a held note on one page isn't let go by another's panic or stop
play("James", { track = "{DD}", sid = "pb", ev = { { 0x90, 41, 100, 3 } } })
sent = {}
play("James", { on = false, sid = "pa" })
assert(keys.I_RECARM == 0 and keys.I_RECINPUT == 1024 and bass.I_RECARM == 1 and lead.I_RECARM == 1, "one page stops: only its own track is put back")
for _, e in ipairs(sent) do assert((e[1] & 15) == 0, "and only its own channel is let go") end
-- a second page asking for a track another holds takes it; the first is told
sent = {}
play("James", { track = "{DD}", sid = "pd", ev = { { 0x90, 50, 100, 1 } } })
tick()
assert(pub.phonekeys.pages.pb.track == nil and pub.phonekeys.pages.pb.why:find("another page"), "the page that had it hears why")
assert(bass.I_RECINPUT == lk.input(1) and pub.phonekeys.pages.pd.ch == 1 and sent[#sent][1] == 0x90 and sent[#sent][2] == 50, "and the new page plays it, on the channel that came free")
-- sixteen pages at most: the 17th is told no
lk.reset()
room("open")
local many = { mine }
for i = 1, 17 do many[#many + 1] = { name = "T" .. i, guid = "{F" .. i .. "}", oid = "T-JAMES-" .. (10 + i), I_RECINPUT = 1024, I_RECMON = 0, I_RECARM = 0 } end
tracks = many
for i = 1, 16 do play("James", { track = "{F" .. i .. "}", sid = "q" .. i, ev = { { 0x90, 60, 100, 1 } } }) end
local seventeen = play("James", { track = "{F17}", sid = "q17", ev = {} })
assert(seventeen and seventeen:find("16 pages"), "a 17th page: told no, nothing changed: " .. tostring(seventeen))
assert(many[18].I_RECARM == 0 and many[17].I_RECARM == 1, "the 17th track wasn't armed")
lk.on_exit()
for _, t in ipairs(tracks) do if t ~= mine then assert(t.I_RECARM == 0 and t.I_RECINPUT == 1024, "at exit every page's track is put back: " .. t.name) end end

-- ---- the pages' hooks (a link check, not a browser test: that ran in Chromium against a stand-in server) --------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local html, rec, pd, sw, vk, pr, webui, ls = read("lib/webui/record.html"), read("lib/webui/record.js"), read("lib/webui/phonedaw.js"),
  read("lib/webui/phone-sw.js"), read("lib/webui/vkeys.js"), read("lib/webui/pianoroll.js"), read("lib/webui.lua"), read("StudioSync - Live sync.lua")
assert(html:find('src="vkeys.js"', 1, true) and html:find('href="vkeys.css"', 1, true) and html:find('data-view="ply"', 1, true), "the phone app loads the instrument and has a Play view")
for _, f in ipairs({ "vkeys.js", "vkeys.css" }) do assert(sw:find("'" .. f .. "'", 1, true), "kept on the phone for offline: " .. f) end
assert(rec:find("ssKeysBus", 1, true) and pd:find("ssKeysBus", 1, true), "the on-screen notes reach a MIDI take")
assert(pd:find("keys:", 1, true) and pd:find("phonekeys", 1, true) and pd:find("panic", 1, true), "the Play view plays live, times it and lets go")
assert(pd:find("pages[K.sid]", 1, true) and pd:find("pads:", 1, true) and pd:find("channel", 1, true), "and reads its own channel's entry of the topic, asking for the pads' channel when it plays pads")
assert(vk:find("requestMIDIAccess", 1, true) and vk:find("pointerdown", 1, true) and vk:find("GM_PADS", 1, true), "Web MIDI, pointer events and the GM pads in vkeys.js")
assert(read("lib/webui/vkeys.css"):find("touch-action: none", 1, true), "no scrolling or zooming while playing")
assert(pr:find("vkeys.js", 1, true) and pr:find("Step", 1, true), "the piano roll's step input")
assert(webui:find('require("livekeys").tick', 1, true) and ls:find("livekeys.on_exit", 1, true), "Live sync ticks it and lets go at exit")
print("ok")
