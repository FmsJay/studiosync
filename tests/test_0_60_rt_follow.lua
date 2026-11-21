-- Follow a bandmate, live, and "Bo is editing this" (lib/follow.lua; roadmap More big ideas 3 and 9): what a link message may carry, when the
-- view counts as moved by you, what counts as editing; then a fake project: a followed computer sends its view only while followed, the
-- follower's view, cursor and selection go there, a scroll pauses it, Resume and stopping (your selection back); an edit goes out at once
-- and its region and words show on the others, and go when they move on. Then the web Play page's Follow, the Project page's line, and the
-- editing region kept off the band's markers. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext = 100, {}
local view, playing, cursor, front = { 0, 20 }, false, 0, "P1"
local tracks, items, markers, cmds = {}, {}, {}, {}
local midi_take, mouse = nil, 0
local function T(name, oid) local t = { name = name, oid = oid, sel = false }; tracks[#tracks + 1] = t; return t end
local function I(tr, oid, pos, len) local it = { tr = tr, oid = oid, pos = pos, len = len, sel = false, take = { name = oid .. " take" } }; items[#items + 1] = it; return it end
local function sel_of(list) local out = {} for _, x in ipairs(list) do if x.sel then out[#out + 1] = x end end return out end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[k] or "" end,
  SetExtState = function(s, k, v) ext[k] = v end,
  DeleteExtState = function(s, k) ext[k] = nil end,
  GetSet_ArrangeView2 = function(p, set, _, _, a, z) if set then view = { a, z } end return view[1], view[2] end,
  GetPlayStateEx = function() return playing and 1 or 0 end,
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
  Main_OnCommandEx = function(c) cmds[#cmds + 1] = c end,
  UpdateArrange = function() end,
  GetTrackName = function(t) return true, t.name end,
  GetSetMediaItemTakeInfo_String = function(tk) return true, tk.name end,
  GetActiveTake = function(it) return it.take end,
  GetMediaItem_Track = function(it) return it.tr end,
  GetMediaItemTake_Item = function(tk) for _, it in ipairs(items) do if it.take == tk then return it end end end,
  GetMediaItemTake_Track = function(tk) for _, it in ipairs(items) do if it.take == tk then return it.tr end end end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or it.len end,
  MIDIEditor_GetActive = function() return midi_take and "ed" or nil end,
  MIDIEditor_GetTake = function() return midi_take end,
  GetFocusedFX2 = function() return 0, -1, -1, -1 end,
  JS_Mouse_GetState = function() return mouse end,
  CountProjectMarkers = function() return #markers end,
  EnumProjectMarkers3 = function(_, i) local m = markers[i + 1]; return 1, m.rgn, m.pos, m.rend, m.name end,
  DeleteProjectMarkerByIndex = function(_, i) table.remove(markers, i + 1) end,
  AddProjectMarker2 = function(_, rgn, pos, rend, name, _, col) markers[#markers + 1] = { rgn = rgn, pos = pos, rend = rend, name = name, col = col } end,
  ColorToNative = function(r, g, b) return (b << 16) | (g << 8) | r end,
  GetOS = function() return "Win64" end, GetExePath = function() return "C:/REAPER" end, GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) error("fake reaper has no " .. tostring(k)) end })
local logged = {}
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local sent, peers, followed_by = {}, { { user = "Bo" } }, false
package.loaded.mirror = { track_oid = function(t) return t.oid end, item_oid = function(it) return it.oid end,
  find = function(_, kind, oid) for _, it in ipairs(items) do if it.oid == oid then return it end end end }
package.loaded.presence = { peers = function() return peers end, followed = function() return followed_by end, all = function() return peers end }
package.loaded.sync = { driver_name = "Bo" }
package.loaded.direct = { live_available = function() return true end, send_live = function(_, kind, d) sent[#sent + 1] = { kind = kind, d = d } end }
local painted = 0
package.loaded.people = { colours = function(_, list) return { [list[1]] = 0x112233 } end, parity = function() return true end,
  paint = function() painted = painted + 1 end }
local follow = require("follow")

-- ---- 1. what a message may carry ---------------------------------------------------------------------------------------------------------
local v = follow.clean_view({ user = "Bo", v = { 10, 30 }, c = 12, tr = { "T1" }, it = { "I1", "I2" }, w = "Bass selected" }, "James")
assert(v and v.v[1] == 10 and v.v[2] == 30 and v.c == 12 and v.p == nil and #v.it == 2 and v.w == "Bass selected", "a view, cleaned")
assert(follow.clean_view({ user = "James", v = { 0, 1 } }, "James") == nil, "never your own")
assert(follow.clean_view({ user = "Bo", v = { 5, 5 } }, "James") == nil and follow.clean_view({ user = "Bo", v = "x" }, "James") == nil, "an empty or odd view: dropped")
local many = {}
for i = 1, follow.MAX + 1 do many[i] = "T" .. i end
assert(follow.clean_view({ user = "Bo", v = { 0, 1 }, tr = many }, "James") == nil, "more than MAX oids: dropped")
assert(follow.clean_view({ user = "Bo", v = { 0, 1 }, it = { 3 } }, "James") == nil, "an oid that isn't text: dropped")
assert(follow.clean_view({ user = ("x"):rep(65), v = { 0, 1 } }, "James") == nil, "a name too long")
assert(#follow.clean_view({ user = "Bo", v = { 0, 1 }, w = ("w"):rep(500) }, "James").w == follow.WORDS, "words cut to WORDS")
local e = follow.clean_editing({ user = "Bo", o = { "I1" }, w = "'Riff' on Bass" }, "James")
assert(e and e.o[1] == "I1" and e.w == "'Riff' on Bass", "an edit, cleaned")
assert(#follow.clean_editing({ user = "Bo" }, "James").o == 0, "no oids: moved on")
assert(follow.clean_editing({ user = "Bo", o = "I1" }, "James") == nil and follow.clean_editing(nil, "James") == nil, "odd ones: dropped")

-- ---- 2. moved by you? what counts as editing? --------------------------------------------------------------------------------------------
assert(not follow.moved(nil, 0, 10), "nothing applied yet: not moved")
assert(not follow.moved({ 0, 10 }, 0.05, 10.05), "within 1% of the view: REAPER's rounding")
assert(follow.moved({ 0, 10 }, 0.5, 10.5) and follow.moved({ 0, 10 }, 0, 12), "a scroll, a zoom")
local base = { editor = nil, editor_age = 0, changed_ago = 99, held = 0, items = {}, tracks = {} }
local function with(t) local s = {} for k, x in pairs(base) do s[k] = x end for k, x in pairs(t) do s[k] = x end return s end
assert(follow.claim_of(base) == nil, "nothing selected, nothing open: nothing")
assert(follow.claim_of(with({ items = { "I1" } })) == nil, "selected but no change in progress: nothing")
local kind, oids = follow.claim_of(with({ items = { "I1" }, tracks = { "T1" }, changed_ago = 0.5 }))
assert(kind == "items" and oids[1] == "I1", "a change in progress: the selected items first")
kind = follow.claim_of(with({ tracks = { "T1" }, held = 0.5 }))
assert(kind == "tracks", "the mouse held (a drag), no items: the selected tracks")
assert(follow.claim_of(with({ tracks = { "T1" }, held = 0.1 })) == nil, "a click isn't a drag")
kind, oids = follow.claim_of(with({ editor = { o = "I9", w = "x" }, items = { "I1" }, changed_ago = 0 }))
assert(kind == "editor" and oids[1] == "I9", "an open editor wins")
assert(follow.claim_of(with({ editor = { o = "I9", w = "x" }, editor_age = 500, changed_ago = 500 })) == nil, "an editor left open, idle: no longer")
assert(follow.claim_of(with({ editor = { o = "I9", w = "x" }, editor_age = 500, changed_ago = 5 })) == "editor", "left open but you're changing things: still")
local keys, regs = follow.regions({ Bo = { o = { "I1", "gone" } }, Al = { o = { "I2" } } },
  function(o) if o == "I1" then return 4, 2 elseif o == "I2" then return 0, 1 end end)
assert(#regs == 2 and regs[1].user == "Al" and regs[2].rend == 6 and keys[2]:find("^%[editing: Bo%]|4%.0+|6%.0+$"), "regions over the items here, by name")

-- ---- 3. a fake project: being followed sends your view -----------------------------------------------------------------------------------
local cfg, b, P = { root = "R", user = "James" }, { song = "S", room = "main" }, "P1"
local bass, keys_t = T("Bass", "T1"), T("Keys", "T2")
local riff, pad = I(bass, "I1", 4, 2), I(keys_t, "I2", 8, 4)
follow.tick(P, cfg, b, -math.huge)
assert(#sent == 0, "nobody follows, nothing edited: nothing sent")
followed_by = true
bass.sel, riff.sel = true, true
clock = clock + 1
follow.tick(P, cfg, b, -math.huge)
assert(#sent == 1 and sent[1].kind == "view" and sent[1].d.tr[1] == "T1" and sent[1].d.it[1] == "I1" and sent[1].d.v[2] == 20, "followed: the view goes")
assert(sent[1].d.w:find("Bass selected") and sent[1].d.w:find("'I1 take' on Bass"), "with words for what's selected: " .. sent[1].d.w)
clock = clock + 0.05
follow.tick(P, cfg, b, -math.huge)
assert(#sent == 1, "not faster than EVERY")
clock = clock + 0.3
follow.tick(P, cfg, b, -math.huge)
assert(#sent == 1, "unchanged: only every KEEP")
clock = clock + 1
follow.tick(P, cfg, b, -math.huge)
assert(#sent == 2, "KEEP: again, for a new follower")
followed_by = false
bass.sel, riff.sel = false, false
sent = {}

-- ---- 4. following: view, cursor, selection; a scroll pauses; Resume; stopping gives yours back -------------------------------------------
keys_t.sel = true -- (yours, before following)
ext["follow " .. P] = "Bo"
follow.on_view(cfg, { user = "Bo", v = { 30, 60 }, c = 33, tr = { "T1" }, it = { "I1" }, w = "Bass selected; editing the MIDI of 'Riff' on Bass" })
assert(follow.handles(P, "Bo"), "fresh link views: the status file's follow stays out")
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(view[1] == 30 and view[2] == 60 and cursor == 33, "the view and the edit cursor went to theirs")
assert(bass.sel and riff.sel and not keys_t.sel and not pad.sel and cmds[#cmds] == 40913, "their selection, their tracks scrolled into view")
assert(ext["follow seen " .. P] == "Bo: Bass selected; editing the MIDI of 'Riff' on Bass", "what you see of them, for the panel and web page")
local seen_ed, seen_line = follow.panel_lines(P, "Bo")
assert(seen_ed == nil and seen_line:find("^Bo: "), "the panel: the line on Bo's card")
assert(select(2, follow.panel_lines(P, "Al")) == nil, "not on anyone else's")
follow.on_view(cfg, { user = "Bo", v = { 30, 60 }, p = 50, c = 33, tr = { "T1" }, it = { "I1" } })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(cursor == 50, "they play, you don't: your edit cursor shows their play cursor")
view = { 40, 70 } -- (you scroll)
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(ext["follow paused " .. P] == "Bo" and logged[#logged]:find("paused"), "a scroll of yours pauses it")
assert(ext["follow seen " .. P]:find("^Paused: Bo"), "and says so")
follow.on_view(cfg, { user = "Bo", v = { 80, 100 }, c = 81, tr = {}, it = {} })
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(view[1] == 40 and bass.sel, "paused: left alone")
assert(follow.handles(P, "Bo"), "paused: the status file's follow stays out too")
ext["follow paused " .. P] = nil -- (Resume)
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(view[1] == 80 and view[2] == 100 and cursor == 81 and not bass.sel and not riff.sel, "resumed: straight to theirs")
ext["follow " .. P] = nil -- (stop following)
clock = clock + 0.1
follow.tick(P, cfg, b, -math.huge)
assert(keys_t.sel and not bass.sel and not riff.sel and ext["follow seen " .. P] == "", "stopped: your own selection back")
ext["follow " .. P] = "Bo"
clock = clock + follow.FRESH + 1
follow.tick(P, cfg, b, -math.huge)
assert(not follow.handles(P, "Bo") and view[1] == 80, "their views stopped coming: the status file's follow takes over")
ext["follow " .. P] = nil
follow.tick(P, cfg, b, -math.huge)
keys_t.sel = false

-- ---- 5. live claims: yours go out at once, theirs show ---------------------------------------------------------------------------------
sent = {}
riff.sel = true
clock = clock + 1
follow.tick(P, cfg, b, clock - 0.2) -- (you just changed something, Riff selected)
assert(#sent == 1 and sent[1].kind == "editing" and sent[1].d.o[1] == "I1" and sent[1].d.w == "'I1 take' on Bass", "an edit: out at once")
clock = clock + 0.15
follow.tick(P, cfg, b, clock - 0.3)
assert(#sent == 1, "the same edit: not again until KEEP")
clock = clock + 3
follow.tick(P, cfg, b, clock - 5)
assert(#sent == 2 and #sent[2].d.o == 0, "moved on (no change for CHANGED s): cleared once")
clock = clock + 0.2
follow.tick(P, cfg, b, clock - 5)
assert(#sent == 2, "and not again")
riff.sel = false
midi_take = pad.take
clock = clock + 0.2
follow.tick(P, cfg, b, clock - 50)
assert(#sent == 3 and sent[3].d.o[1] == "I2" and sent[3].d.w == "the MIDI of 'I2 take' on Keys", "opening the MIDI editor: that item")
midi_take = nil
peers = {}
clock = clock + 0.2
follow.tick(P, cfg, b, -math.huge)
assert(#sent == 3, "nobody here: nothing looked at or sent")
peers = { { user = "Bo" } }

-- theirs
follow.on_editing(cfg, { user = "Bo", o = { "I2" }, w = "the MIDI of 'Pad' on Keys" })
follow.tick(P, cfg, b, -math.huge)
assert(#markers == 1 and markers[1].rgn and markers[1].name == "[editing: Bo]" and markers[1].pos == 8 and markers[1].rend == 12, "a region over their item")
assert(follow.live_editing().I2 == "Bo" and follow.words_by_user().Bo == "the MIDI of 'Pad' on Keys", "for the tint and the web page")
assert(follow.panel_lines(P, "Bo") == "the MIDI of 'Pad' on Keys", "the panel's line on Bo's card")
assert(painted == 0, "Colour parity on: no tint")
package.loaded.people.parity = function() return false end
follow.on_editing(cfg, { user = "Bo", o = { "I1" }, w = "'Riff' on Bass" })
follow.tick(P, cfg, b, -math.huge)
assert(#markers == 1 and markers[1].pos == 4 and painted == 1, "they moved to Riff: the region moved, the tracks repainted")
follow.on_editing(cfg, { user = "Bo", o = {} })
follow.tick(P, cfg, b, -math.huge)
assert(#markers == 0 and next(follow.live_editing()) == nil and follow.panel_lines(P, "Bo") == nil, "they moved on: gone")
follow.on_editing(cfg, { user = "Bo", o = { "I1" } })
follow.tick(P, cfg, b, -math.huge)
clock = clock + follow.FRESH + 0.5
follow.tick(P, cfg, b, -math.huge)
assert(#markers == 0, "no word from them for FRESH s: gone too")
follow.on_editing(cfg, { user = "James", o = { "I1" } })
assert(next(follow.live_editing()) == nil, "never your own")

-- ---- 6. the band's markers, the web pages ------------------------------------------------------------------------------------------------
assert(band.is_local_mark("[editing: Bo]") and band.is_local_mark("[ping] Bo") and not band.is_local_mark("Verse") and not band.is_local_mark(nil),
  "an editing region is this computer's only")
local dv = require("dawview").cursor_model("k", { user = "James", cursor = 1, pos = 1 }, { { user = "Bo" }, { user = "Al" } }, {}, { Bo = "'Riff' on Bass" })
assert(dv.people[2].user == "Bo" and dv.people[2].ed == "'Riff' on Bass" and dv.people[1].ed == nil, "the Project page's people say what they're editing")
local webpages = require("webpages")
local pm = webpages.play_model({ side = "", cursor = "1", mate = "Bo", paused = true, seen = "Paused: Bo: Bass selected" })
assert(pm.mate == "Bo" and pm.paused and pm.seen == "Paused: Bo: Bass selected", "Play page: who you follow, paused, what you see")
pm = webpages.play_model({ side = "", cursor = "1", mate = "", paused = false, seen = "" })
assert(pm.mate == nil and pm.paused == nil and pm.seen == nil, "nobody")
ext["follow driver"] = "1"
assert(webpages.action(P, cfg, b, { topic = "play", mate = "Bo" }):find("watching Bo") and ext["follow " .. P] == "Bo" and ext["follow driver"] == "",
  "the web page watches Bo, as the panel's Follow does")
assert(webpages.action(P, cfg, b, { topic = "play", mate = "Mallory" }):find("left as it is") and ext["follow " .. P] == "Bo", "nobody by that name here: left")
assert(webpages.action(P, cfg, b, { topic = "play", mate = "James" }):find("left as it is"), "not yourself")
ext["follow paused " .. P] = "Bo"
webpages.action(P, cfg, b, { topic = "play", resume = true })
assert(ext["follow paused " .. P] == nil, "Resume from the web page")
webpages.action(P, cfg, b, { topic = "play", mate = "" })
assert(ext["follow " .. P] == nil, "Nobody: stopped")
print("ok follow: view, pause/resume, live claims, web")
