-- rt-follow (findings 2026-11-27 items 5 and 12, and the bug "said following but wasn't actually following for a bit"): one Follow (a person,
-- their active computer or one picked; everyone; the driver), kept in the old keys so older computers read it; the view mirrored exactly
-- (vertical zoom and scroll, the MIDI editor), throttled and only while someone follows or a web page watches; following said only once it
-- is (their view names you, and your transport was put where theirs is); recording together on your armed tracks. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext, pext = 100, {}, {}
local view, playstate, cursor, front = { 0, 20 }, 0, 0, "P1"
local tracks, items, cmds, midi_cmds = {}, {}, {}, {}
local midi_take, vz_now, vpos = nil, 4, 300
local tcpy = {} -- track oid -> its I_TCPY here
local function T(name, oid) local t = { name = name, oid = oid, sel = false }; tracks[#tracks + 1] = t; return t end
local function I(tr, oid, pos, len) local it = { tr = tr, oid = oid, pos = pos, len = len, sel = false, take = { name = oid .. " take" } }; items[#items + 1] = it; return it end
local function sel_of(list) local out = {} for _, x in ipairs(list) do if x.sel then out[#out + 1] = x end end return out end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[k] or "" end,
  SetExtState = function(s, k, v) ext[k] = v end,
  DeleteExtState = function(s, k) ext[k] = nil end,
  GetProjExtState = function(p, s, k) return 1, pext[k] or "" end,
  SetProjExtState = function(p, s, k, v) pext[k] = v end,
  GetSet_ArrangeView2 = function(p, set, _, _, a, z) if set then view = { a, z } end return view[1], view[2] end,
  GetPlayStateEx = function() return playstate end,
  GetCursorPositionEx = function() return cursor end,
  GetPlayPositionEx = function() return 42.5 end,
  SetEditCurPos2 = function(_, t) cursor = t end,
  EnumProjects = function() return front end,
  CountTracks = function() return #tracks end,
  GetTrack = function(_, i) return tracks[i + 1] end,
  CountMediaItems = function() return #items end,
  GetMediaItem = function(_, i) return items[i + 1] end,
  CountSelectedTracks = function() return #sel_of(tracks) end,
  GetSelectedTrack = function(_, i) return sel_of(tracks)[i + 1] end,
  CountSelectedMediaItems = function() return #sel_of(items) end,
  GetSelectedMediaItem = function(_, i) return sel_of(items)[i + 1] end,
  SetTrackSelected = function(t, on) t.sel = on end,
  SetMediaItemSelected = function(it, on) it.sel = on end,
  SelectAllMediaItems = function(_, on) for _, it in ipairs(items) do it.sel = on end end,
  ValidatePtr2 = function() return true end,
  Main_OnCommandEx = function(c) cmds[#cmds + 1] = c; if c == 40153 then midi_take = sel_of(items)[1].take end end,
  UpdateArrange = function() end,
  GetTrackName = function(t) return true, t.name end,
  GetSetMediaItemTakeInfo_String = function(tk) return true, tk.name end,
  GetActiveTake = function(it) return it.take end,
  GetMediaItem_Track = function(it) return it.tr end,
  GetMediaItemTake_Item = function(tk) for _, it in ipairs(items) do if it.take == tk then return it end end end,
  GetMediaItemTake_Track = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.tr end end end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or it.len end,
  GetMediaTrackInfo_Value = function(t, k) if k == "I_TCPH" then return 60 end return tcpy[t.oid] or 0 end,
  MIDIEditor_GetActive = function() return midi_take and "ed" or nil end,
  MIDIEditor_GetTake = function() return midi_take end,
  MIDIEditor_OnCommand = function(ed, c) midi_cmds[#midi_cmds + 1] = c; if c == 2 then midi_take = nil end end,
  GetFocusedFX2 = function() return 0, -1, -1, -1 end,
  JS_Mouse_GetState = function() return 0 end,
  GetMousePosition = false, GetThingFromPoint = false,
  SNM_GetIntConfigVar = function(k, d) return k == "vzoom2" and vz_now or d end,
  SNM_SetIntConfigVar = function(k, v) if k == "vzoom2" then vz_now = v end return true end,
  TrackList_AdjustWindows = function() end,
  GetMainHwnd = function() return "main" end,
  JS_Window_FindChildByID = function(h, id) return h == "main" and id == 1000 and "arrange" or nil end,
  JS_Window_GetScrollInfo = function() return true, vpos, 400, 0, 2000 end,
  JS_Window_SetScrollPos = function(_, _, pos)
    local d = pos - vpos
    vpos = pos
    for o, y in pairs(tcpy) do tcpy[o] = y - d end
    return true
  end,
  CountProjectMarkers = function() return 0 end,
  GetOS = function() return "Win64" end, GetExePath = function() return "C:/REAPER" end, GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) error("fake reaper has no " .. tostring(k)) end })
local logged = {}
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local sent, peers = {}, { { user = "Bo-Laptop" } }
package.loaded.mirror = { track_oid = function(t) return t.oid end, item_oid = function(it) return it.oid end,
  find = function(_, kind, oid)
    for _, x in ipairs(kind == "track" and tracks or items) do if x.oid == oid then return x end end
  end }
package.loaded.presence = { peers = function() return peers end }
package.loaded.sync = { driver_name = "Al" }
local shared = 5000
package.loaded.direct = { live_available = function() return true end, shared_now = function() return shared end,
  send_live = function(_, kind, d) sent[#sent + 1] = { kind = kind, d = d } end }
package.loaded.people = { colours = function() return {} end, parity = function() return true end, paint = function() end }
local rt_on = false
package.loaded.live = { realtime_on = function() return rt_on end }
-- rt-people's folding (lib/persons.lua): Bo-Laptop and Bo-Main are one person, "Bo"
package.loaded.persons = { map = function() return { ["Bo-Laptop"] = { key = "Bo-Laptop", name = "Bo", users = { "Bo-Laptop", "Bo-Main" } },
  ["Bo-Main"] = { key = "Bo-Laptop", name = "Bo", users = { "Bo-Laptop", "Bo-Main" } } } end }
local follow = require("follow")
local cfg, b, P = { root = "R", user = "James" }, { song = "S", room = "main" }, "P1"

-- ---- 1. a view message's new parts (each optional, each checked) ------------------------------------------------------------------------
assert(follow.EVERY <= 0.1 and follow.KEEP >= 1, "10 a second at most, on a change")
local v = follow.clean_view({ user = "Bo", v = { 10, 30 }, vz = 6, top = { "T2", -12 }, ed = "I1", ps = 5, sn = 4999.5, fw = { "James", 7, "Al" } }, "James")
assert(v.vz == 6 and v.top[1] == "T2" and v.top[2] == -12 and v.ed == "I1" and v.ps == 5 and v.sn == 4999.5, "vertical zoom, top track, MIDI editor, play state, clock")
assert(#v.fw == 2 and v.fw[1] == "James" and v.fw[2] == "Al", "who they know follows them (names only)")
v = follow.clean_view({ user = "Bo", v = { 10, 30 }, vz = -1, top = { ("x"):rep(81), 0 }, ed = 5, ps = 9, sn = "x", fw = "James" }, "James")
assert(v.vz == nil and v.top == nil and v.ed == nil and v.ps == nil and v.sn == nil and v.fw == nil, "odd ones dropped")
assert(follow.clean_view({ user = "Bo", v = { 10, 30 } }, "James").fw == nil, "an older StudioSync: no fw")

-- ---- 2. who follows you; a person's computers ------------------------------------------------------------------------------------------
local fw = follow.followers({ { user = "Bo", follow = "James" }, { user = "Al", watch = "James" }, { user = "Cy", follow_driver = true }, { user = "Di", follow = "Bo" } }, "James", "James")
assert(table.concat(fw, ",") == "Al,Bo,Cy", "following you, a web page watching you, following the driver while you drive")
local fold = follow.fold(cfg)
local ppl = follow.people({ { user = "Bo-Main", front = true }, { user = "Bo-Laptop" }, { user = "Al" } }, "James", nil, fold)
assert(#ppl == 2 and ppl[2].label == "Bo" and ppl[2].key == "Bo-Laptop" and table.concat(ppl[2].users, ",") == "Bo-Laptop,Bo-Main", "Bo's computers folded, by name")
assert(ppl[2].active == "Bo-Main", "their active one: the project in front")
assert(#follow.people({ { user = "Bo-Main" }, { user = "Bo-Laptop" } }, "James") == 2, "without rt-people's folding: each computer its own")
assert(follow.active({ { user = "A", playing = true }, { user = "B", recording = true } }, "A") == "A", "the one you follow while it still plays")
assert(follow.active({ { user = "A" }, { user = "B", playing = true } }, "A") == "B", "it stopped and another of theirs plays: that one")
assert(follow.active({ { user = "A" }, { user = "B" } }, "A") == "A", "nothing playing: stays")
assert(follow.active({ { user = "A", last_at = 5 }, { user = "B", last_at = 9 } }, "gone") == "B", "the one you were on left: the latest active")

-- ---- 3. one Follow, stored in the old keys --------------------------------------------------------------------------------------------
peers = { { user = "Bo-Laptop" }, { user = "Bo-Main", playing = true }, { user = "Al" } }
assert(follow.set_choice(P, cfg, peers, "*", nil, 1):find("everyone") and pext.side == "1" and follow.choice_of(P) == "*", "Everyone: the project's side, 1 bar")
local said = follow.set_choice(P, cfg, peers, "Bo-Laptop")
assert(said:find("Bo%-Laptop") and ext["follow P1"] == "Bo-Main" and ext["follow person P1"] == "Bo-Laptop" and ext["follow pinned P1"] == nil and pext.side == "",
  "Bo: their active computer (Bo-Main plays), the person kept, Everyone off: " .. said)
local c, comp = follow.choice_of(P)
assert(c == "Bo-Laptop" and comp == "Bo-Main", "the choice: the person, on Bo-Main")
follow.set_choice(P, cfg, peers, "Bo-Laptop", "Bo-Laptop")
assert(ext["follow P1"] == "Bo-Laptop" and ext["follow pinned P1"] == "Bo-Laptop", "one of theirs picked: pinned")
follow.set_choice(P, cfg, peers, "Bo-Main")
assert(ext["follow P1"] == "Bo-Main" and ext["follow pinned P1"] == "Bo-Main" and ext["follow person P1"] == "Bo-Laptop", "a computer's name (the older pages): that person, pinned to it")
follow.set_choice(P, cfg, peers, "Al")
assert(ext["follow P1"] == "Al" and ext["follow person P1"] == "Al", "one computer: the person is it")
assert(follow.set_choice(P, cfg, peers, "@driver") and ext["follow driver"] == "1" and ext["follow P1"] == nil and follow.choice_of(P) == "@driver", "the driver")
assert(follow.set_choice(P, cfg, peers, "Mallory") == nil and ext["follow driver"] == "1", "nobody by that name: left")
assert(follow.set_choice(P, cfg, peers, "James") == nil, "never yourself")
follow.set_choice(P, cfg, peers, "")
assert(ext["follow driver"] == "" and ext["follow P1"] == nil and follow.choice_of(P) == "", "nobody")
rt_on, pext.side = true, "0"
assert(follow.set_choice(P, cfg, peers, "*") == nil, "Real time holds Everyone itself")
follow.set_choice(P, cfg, peers, "Al")
assert(pext.side == "0" and ext["follow P1"] == "Al", "a person while Real time is on: Real time's side left as it is")
rt_on, pext.side = false, ""
follow.set_choice(P, cfg, peers, "")

-- ---- 4. sending: only while followed (or watched), with the vertical view, the MIDI editor and who follows -------------------------------
local bass, keys_t = T("Bass", "T1"), T("Keys", "T2")
local riff = I(bass, "I1", 4, 2)
I(keys_t, "I2", 8, 4)
tcpy = { T1 = -70, T2 = -10 }
follow.tick(P, cfg, b, -math.huge)
assert(#sent == 0, "nobody follows: nothing sent")
peers = { { user = "Bo-Laptop", watch = "James" } }
midi_take = riff.take
clock = clock + 1
follow.tick(P, cfg, b, -math.huge)
local d
for _, m in ipairs(sent) do if m.kind == "view" then d = m.d end end
assert(d and d.vz == 4 and d.top[1] == "T2" and d.top[2] == -10 and d.ed == "I1" and d.ps == 0 and d.sn == shared and d.fw[1] == "Bo-Laptop",
  "a web page watching you is enough; vertical zoom, top track (Bass is scrolled past), the MIDI editor's item, who follows: " .. band.json_encode(d))
midi_take, peers, sent = nil, {}, {}

-- ---- 5. following: "Connecting" until they know you, then the first sync, then Following (the bug) --------------------------------------
peers = { { user = "Bo-Laptop" } }
follow.set_choice(P, cfg, peers, "Bo-Laptop")
clock = clock + 1
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow state P1"] == "waiting" and ext["follow seen P1"] == "Connecting to Bo-Laptop...", "nothing from them yet: Connecting, not Following")
follow.on_view(cfg, { user = "Bo-Laptop", v = { 30, 60 }, c = 33, p = 50, ps = 1, sn = shared, tr = {}, it = {}, fw = { "Al" }, w = "Bass selected" })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow state P1"] == "waiting" and ext["transport P1"] == nil, "their view arrives, but they don't know you follow yet: still Connecting, nothing fired")
assert(follow.words({ choice = "Bo-Laptop", state = "waiting", label = "Bo" }):find("^Connecting to Bo"), "the pages' line says so")
follow.on_view(cfg, { user = "Bo-Laptop", v = { 30, 60 }, c = 33, p = 50, ps = 1, sn = shared, tr = {}, it = {}, fw = { "James" }, w = "Bass selected" })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
local cue = band.json_decode(ext["transport P1"] or "")
assert(cue and cue.type == "start" and cue.follow and cue.lead == "Bo-Laptop" and cue.pos == 50 and cue.start_at == shared and not cue.rec,
  "they know now and they're playing: your transport starts where they are (Live sync's follow cue): " .. tostring(ext["transport P1"]))
assert(ext["follow state P1"] == "live" and ext["follow seen P1"] == "Bo-Laptop: Bass selected", "and only now: Following")
assert(follow.words({ choice = "Bo-Laptop", state = "live", seen = "Bo-Laptop: Bass selected", label = "Bo", multi = true, computer = "Bo-Laptop" }) == "Following Bo on Bo-Laptop: Bass selected.", "the line")
ext["transport P1"] = nil
playstate = 1
follow.on_view(cfg, { user = "Bo-Laptop", v = { 30, 60 }, c = 33, ps = 0, tr = {}, it = {}, fw = { "James" } })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(ext["transport P1"] == nil, "synced once: their next presses come as their own cues")
clock = clock + follow.FRESH + 0.5
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow state P1"] == "waiting", "their views stopped: not Following any more")
peers = { { user = "Bo-Laptop", view = { 0, 10 } } }
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow state P1"] == "slow" and ext["follow seen P1"]:find("shared folder"), "the shared folder's follow: said as slow")
follow.on_view(cfg, { user = "Bo-Laptop", v = { 30, 60 }, c = 33, ps = 0, tr = {}, it = {}, fw = { "James" } })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
cue = band.json_decode(ext["transport P1"] or "")
assert(cue and cue.type == "stop" and ext["follow state P1"] == "live", "back on the link: synced again (they're stopped, you were playing: you stop)")
ext["transport P1"], playstate = nil, 0
-- an older StudioSync (no fw, no ps): its view arriving is the sign; playing is its play position
follow.set_choice(P, cfg, peers, "")
follow.tick(P, cfg, b, -math.huge)
peers = { { user = "Old" } }
follow.set_choice(P, cfg, peers, "Old")
follow.on_view(cfg, { user = "Old", v = { 30, 60 }, c = 33, p = 12, tr = {}, it = {} })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
cue = band.json_decode(ext["transport P1"] or "")
assert(ext["follow state P1"] == "live" and cue and cue.pos == 12, "an older StudioSync: Following once its view comes, synced by its play position")
ext["transport P1"] = nil
assert(follow.first_cue({ ps = 5, p = 3 }, { playing = false, recording = true }, "Bo", 1) == nil, "never into a take of yours")
follow.set_choice(P, cfg, peers, "")
follow.tick(P, cfg, b, -math.huge)

-- ---- 6. the view exactly: vertical zoom and scroll, the MIDI editor; your own scroll pauses it --------------------------------------------
peers = { { user = "Bo-Laptop" } }
follow.set_choice(P, cfg, peers, "Bo-Laptop")
vz_now, vpos, tcpy = 4, 300, { T1 = -70, T2 = -10 }
follow.on_view(cfg, { user = "Bo-Laptop", v = { 30, 60 }, c = 33, ps = 0, tr = { "T1" }, it = {}, fw = { "James" }, vz = 9, top = { "T1", -5 }, ed = "I2" })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(vz_now == 9, "their vertical zoom")
assert(tcpy.T1 == -5 and vpos == 235, "scrolled so their top track sits where theirs does: " .. tostring(tcpy.T1) .. " " .. vpos)
local n40913 = 0
for _, x in ipairs(cmds) do if x == 40913 then n40913 = n40913 + 1 end end
assert(n40913 == 0, "not REAPER's scroll-selected-into-view when the view says where it's scrolled")
assert(cmds[#cmds] == 40153 and midi_take == items[2].take, "their MIDI editor's item opened here")
assert(bass.sel and not items[2].sel, "and their selection back after")
sent = {}
peers[1].follow = nil
clock = clock + 1
follow.tick(P, cfg, b, clock - 0.5) -- (a change of yours just now: what's open would count as your editing)
for _, m in ipairs(sent) do assert(m.kind ~= "editing" or m.d.o[1] ~= "I2", "an editor following opened isn't your editing") end
follow.on_view(cfg, { user = "Bo-Laptop", v = { 30, 60 }, c = 33, ps = 0, tr = { "T1" }, it = {}, fw = { "James" }, vz = 9, top = { "T1", -5 } })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(midi_cmds[#midi_cmds] == 2 and midi_take == nil, "they closed theirs: the one following opened closes")
assert(not follow.user_moved({ 0, 10 }, 3, 13, true), "playing: a scroll is REAPER's own")
assert(follow.user_moved({ 0, 10 }, 0, 14, true), "playing: a zoom is yours")
assert(follow.user_moved({ 0, 10 }, 0, 10, false, 100, 140) and not follow.user_moved({ 0, 10 }, 0, 10, false, 100, 101), "your vertical scroll")
vpos = vpos + 80 -- (you scroll down)
for o, y in pairs(tcpy) do tcpy[o] = y - 80 end
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow paused P1"] == "Bo-Laptop" and ext["follow state P1"] == "paused", "your own scroll pauses following the view")
follow.on_view(cfg, { user = "Bo-Laptop", v = { 70, 90 }, c = 71, ps = 0, tr = {}, it = {}, fw = { "James" }, vz = 9, top = { "T1", -5 } })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(view[1] == 30, "paused: never moved while you look around")
ext["follow paused P1"] = nil -- (Resume)
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(view[1] == 70 and tcpy.T1 == -5 and ext["follow state P1"] == "live", "Resume: straight back to theirs")
follow.set_choice(P, cfg, peers, "")
follow.tick(P, cfg, b, -math.huge)

-- ---- 7. migration: a follow set by an older StudioSync (a computer's name alone) ------------------------------------------------------
ext["follow P1"] = "Bo-Main"
peers = { { user = "Bo-Laptop", playing = true }, { user = "Bo-Main" } }
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow P1"] == "Bo-Main" and ext["follow person P1"] == "Bo-Laptop" and ext["follow pinned P1"] == "Bo-Main", "kept exactly: Bo, pinned to Bo-Main")
ext["follow pinned P1"] = nil
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow P1"] == "Bo-Laptop" and logged[#logged]:find("active"), "unpinned: their active computer")
ext["follow P1"] = nil -- (an older Follow button stops it)
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow person P1"] == nil, "the person goes with it")

-- ---- 8. recording together, the pages, the Project page ---------------------------------------------------------------------------------
local function src(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local live = src("StudioSync - Live sync.lua")
assert(live:find('together_take = transport.rec and not (transport.follow and theirs and not require("follow").records_along())', 1, true),
  "following someone who records: you record with them (nothing armed: you play along, together.NO_ARM)")
assert(live:find('info.watch = require("dawview").watched_user()', 1, true), "a page's watch goes in the status")
assert(follow.records_along() and (function() ext["follow no rec"] = "1"; return not follow.records_along() end)(), "the box: play along instead")
ext["follow no rec"] = nil
local dv = require("dawview")
assert(dv.parse({ want = true, watch = "Bo" }).watch == "Bo" and dv.parse({ watch = ("x"):rep(65) }).watch == nil and dv.parse({ watch = "a\nb" }).watch == nil, "watch: a name, checked")
dv.action(P, cfg, b, { want = true, watch = "Bo" })
assert(dv.watched_user() == "Bo", "watched")
clock = clock + dv.WANT_FOR + 1
assert(dv.watched_user() == nil, "until the page stops saying so")
local cm = dv.cursor_model("k", { user = "James", cursor = 1, pos = 1 }, { { user = "Bo", view = { 0, 5 }, cursor = 2 } }, {}, {},
  { Bo = { v = { 30, 60 }, c = 33, top = { "T2", -4 } } }, { T2 = 1 })
assert(cm.people[1].view[1] == 30 and cm.people[1].cur == 33 and cm.people[1].top == 1 and cm.people[1].live == 1, "the Project page: their live view, cursor and top track's place")
local webpages = require("webpages")
local pm = webpages.play_model({ side = "", cursor = "1", choice = "Bo-Laptop", people = { { key = "Bo-Laptop", label = "Bo", users = { "Bo-Laptop", "Bo-Main" } } }, state = "waiting", line = "Connecting to Bo..." })
assert(pm.choice == "Bo-Laptop" and pm.people[1].label == "Bo" and pm.state == "waiting" and pm.line == "Connecting to Bo...", "the play topic: the choice, the people, the truthful line")
peers = { { user = "Bo-Laptop" }, { user = "Bo-Main" } }
said = webpages.action(P, cfg, b, { topic = "play", choice = "Bo-Laptop", computer = "Bo-Main" })
assert(said:find("from the web page") and ext["follow P1"] == "Bo-Main" and ext["follow pinned P1"] == "Bo-Main", "the web page picks Bo, on Bo-Main")
webpages.action(P, cfg, b, { topic = "play", choice = "*", bars = 0 })
assert(pext.side == "0" and ext["follow P1"] == nil, "Everyone, right along")
webpages.action(P, cfg, b, { topic = "play", norec = true })
assert(ext["follow no rec"] == "1", "the web page's box")
webpages.action(P, cfg, b, { topic = "play", choice = "" })
local js = src("lib/webui/play.js")
assert(not js:find("'Play together'", 1, true) and not js:find("'Record together'", 1, true) and js:find("Record with them on my armed tracks", 1, true) and js:find("choice: pick.value", 1, true),
  "the web Play page: Follow only, no Start/Record/Stop together")
local pp = src("lib/page_play.lua")
assert(not pp:find('"Record together"', 1, true) and pp:find("follow.set_choice", 1, true), "the panel's Play page too")
assert(src("lib/webui/daw.js"):find("watch: watched()", 1, true) and src("lib/webui/daw.js"):find("y0 = tops[p.top]", 1, true), "the Project page says whose view it follows and scrolls as theirs")
print("ok rt-follow: one Follow, exact view, following only once it is")
