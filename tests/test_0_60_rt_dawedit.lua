-- The shared DAW view, stage 2 (lib/dawedit.lua, lib/webui/daw.js): what a page may send, the permission rules (the real sync.authority over
-- a stand-in shared folder: driver, claims, a region claim, the maker's own track, Driver only), each edit applied to a stand-in REAPER in
-- one undo point (move, move to another track, trims, split, mute, colour, markers and regions), refusals that change nothing, the answer
-- published for the page, and a link check of the page's edit hooks. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, logged = {}, {}
reaper = setmetatable({
  time_precise = function() return 1000 end,
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
files["R/S/session.json"] = { host = "James", markers = { { region = true, name = "Verse", pos = 10, ["end"] = 30 } } }
local function room(mode, claims)
  for p in pairs(files) do if p:find("^" .. R) then files[p] = nil end end
  files[R .. "/mode.json"] = { mode = mode }
  for user, c in pairs(claims or {}) do c.user, c.time = user, "2026-11-19T10:00:00Z"; files[R .. "/claims/" .. user .. ".json"] = c end
end
package.loaded.groups = { may_manage = function(_, user) return user == "Admin" end }
package.loaded.mirror = {
  local_track = function(tr) return tr.t["local"] == true end,
  track_oid = function(tr) return (tr.t.oid or ""):upper() end,
  item_oid = function(it) return (it.oid or ""):upper() end,
  is_creator = function(oid, user) return (oid or ""):match("^%a%-(.-)%-") == user:upper() end,
}
local peers = {}
local presence = require("presence")
presence.peers = function() return peers end
local dawedit = require("dawedit")
local dawview = require("dawview")

-- ---- parse ------------------------------------------------------------------------------------------------------------------------------
local e = dawedit.parse({ id = "e1", op = "move", lane = 1, idx = 0, p = 4, l = 2, to = 6.2, tolane = 0 })
assert(e and e.op == "move" and e.to == 6.2 and e.tolane == 0 and e.id == "e1", "a move")
assert(dawedit.parse({ op = "colour", lane = 0, idx = 0, p = 0, l = 1, c = "#A0B0C0" }).c == "#a0b0c0", "a colour, lower-cased")
assert(dawedit.parse({ op = "colour", lane = 0, idx = 0, p = 0, l = 1, c = "" }).c == false, "no colour")
local bad = {
  { op = "delete", lane = 0, idx = 0, p = 0, l = 1 }, { op = "move", lane = -1, idx = 0, p = 0, l = 1, to = 1 }, { op = "move", lane = 0.5, idx = 0, p = 0, l = 1, to = 1 },
  { op = "move", lane = 0, idx = 0, p = 0, l = 1 }, { op = "move", lane = 0, idx = 0, p = 0 / 0, l = 1, to = 1 }, { op = "colour", lane = 0, idx = 0, p = 0, l = 1, c = "red" },
  { op = "add_marker", at = 1, name = "[ping] James" }, { op = "add_marker", at = 1, name = ("x"):rep(101) }, { op = "add_marker", at = 5, region = true, to = 5 },
  { op = "rename_marker", i = 1, p = 1, name = 7 }, { op = "move_marker", i = 1, p = 1 }, "nope",
}
for n, b in ipairs(bad) do assert(dawedit.parse(b) == nil, "refused: #" .. n) end
local _, why, id = dawedit.parse({ id = "e9", op = "move", lane = 0 })
assert(why and id == "e9", "a refusal keeps its id, so the page hears why")
assert(select(3, dawedit.parse({ id = "<script>", op = "nope" })) == nil, "ids are plain")
assert(dawedit.parse({ op = "rename_marker", i = 2, r = true, p = 3, name = " Chorus\n2 " }).name == "Chorus 2", "names cleaned")

-- ---- a stand-in REAPER ------------------------------------------------------------------------------------------------------------------
local undo, fake = {}, nil
local function setup(f)
  fake = f
  for _, t in ipairs(f.tracks) do
    t.ptr = { t = t }
    for _, it in ipairs(t.items) do it.track = t; for _, tk in ipairs(it.takes or {}) do tk.item = it end end
  end
end
local function tracks_of() return fake.tracks end
reaper.CountTracks = function() return #tracks_of() end
reaper.GetTrack = function(_, i) return tracks_of()[i + 1].ptr end
reaper.GetMediaTrackInfo_Value = function(tr, k) if k == "B_SHOWINTCP" then return tr.t.hidden and 0 or 1 end return 0 end
reaper.GetSetMediaTrackInfo_String = function(tr, k) if k == "P_NAME" then return true, tr.t.name end return true, "" end
reaper.CountTrackMediaItems = function(tr) return #tr.t.items end
reaper.GetTrackMediaItem = function(tr, j) return tr.t.items[j + 1] end
local IV = { D_POSITION = "pos", D_LENGTH = "len", B_MUTE = "mute", I_CUSTOMCOLOR = "color", B_LOOPSRC = "loop" }
reaper.GetMediaItemInfo_Value = function(it, k) return it[IV[k]] or 0 end
reaper.SetMediaItemInfo_Value = function(it, k, v) it[IV[k]] = v; return true end
reaper.GetActiveTake = function(it) return (it.takes or {})[1] end
reaper.CountTakes = function(it) return #(it.takes or {}) end
reaper.GetTake = function(it, k) return it.takes[k + 1] end
local TV = { D_STARTOFFS = "offs", D_PLAYRATE = "rate", I_CUSTOMCOLOR = "color" }
reaper.GetMediaItemTakeInfo_Value = function(tk, k) return tk[TV[k]] or (k == "D_PLAYRATE" and 1 or 0) end
reaper.SetMediaItemTakeInfo_Value = function(tk, k, v) tk[TV[k]] = v; return true end
reaper.MoveMediaItemToTrack = function(it, tr)
  for j, x in ipairs(it.track.items) do if x == it then table.remove(it.track.items, j) break end end
  tr.t.items[#tr.t.items + 1] = it; it.track = tr.t
  return true
end
local splits = {}
reaper.SplitMediaItem = function(it, at) splits[#splits + 1] = { it, at }; return {} end
reaper.SnapToGrid = function(_, t) return math.floor(t * 2 + 0.5) / 2 end -- (a half-second grid, snapping on)
reaper.Undo_BeginBlock2 = function() undo[#undo + 1] = { open = true } end
reaper.Undo_EndBlock2 = function(_, label) undo[#undo].open, undo[#undo].label = false, label end
local playing, playpos, cursor = false, 0, 5
reaper.GetPlayStateEx = function() return playing and 1 or 0 end
reaper.GetPlayPositionEx = function() return playpos end
reaper.GetCursorPositionEx = function() return cursor end
reaper.ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end
reaper.EnumProjectMarkers3 = function(_, i)
  local m = fake.markers[i + 1]
  if not m then return 0 end
  return 1, m.region or false, m.pos, m.rend or 0, m.name, m.num, m.color or 0
end
local added = {}
reaper.AddProjectMarker2 = function(_, rgn, pos, rend, name) added[#added + 1] = { rgn = rgn, pos = pos, rend = rend, name = name }; return 9 end
reaper.SetProjectMarker4 = function(_, num, rgn, pos, rend, name, color, flags)
  for _, m in ipairs(fake.markers) do
    if m.num == num and (m.region or false) == rgn then m.pos, m.rend = pos, rend; if flags & 1 == 1 then m.name = "" elseif name ~= "" then m.name = name end end
  end
  return true
end

local function song()
  setup({
    tracks = {
      { name = "Drums", oid = "T-JAMES-1", items = { { pos = 0, len = 4, oid = "I-JAMES-1", takes = { { offs = 1, rate = 1 } } } } },
      { name = "Mine", ["local"] = true, items = {} },
      { name = "Bass", oid = "T-CHILIO-2", items = { { pos = 4, len = 2, oid = "I-CHILIO-1", takes = { { offs = 0, rate = 2, color = 0x10000FF } } }, { pos = 12, len = 4, oid = "I-JAMES-9", takes = { {} } } } },
      { name = "Pad", oid = "T-ANDIE-3", items = { { pos = 34, len = 4, oid = "I-ANDIE-1", takes = { {} } } } },
    },
    markers = { { num = 1, pos = 2, name = "A" }, { num = 1, pos = 10, rend = 30, name = "Verse", region = true }, { num = 3, pos = 40, name = "[ping] Chilio" } },
  })
  undo, splits, added = {}, {}, {}
end
local b = { song = "S", room = "main" }
local function as(user) return { root = "R", user = user } end
local function act(user, edit)
  local said = dawview.action("P", as(user), b, { topic = "daw", edit = edit })
  return said, dawedit.reply
end
local function it(lane, j) local shown = {}; for _, t in ipairs(fake.tracks) do if not t["local"] then shown[#shown + 1] = t end end; return shown[lane + 1].items[j + 1] end

-- ---- items ------------------------------------------------------------------------------------------------------------------------------
-- Claims (open): Chilio claimed Bass and the Verse region; James drives
song(); room("open", { Chilio = { tracks = { "Bass" }, regions = { "Verse" } } })
local said, r = act("James", { id = "a1", op = "move", lane = 0, idx = 0, p = 0, l = 4, to = 1.2 })
assert(r.id == "a1" and r.ok and not r.why and it(0, 0).pos == 1, "an unclaimed item: moved, snapped to the grid as REAPER snaps: " .. tostring(r.why))
assert(#undo == 1 and not undo[1].open and undo[1].label == "StudioSync web page: move item" and said:find("move item"), "in one undo point, closed")
said, r = act("James", { id = "a2", op = "move", lane = 1, idx = 0, p = 4, l = 2, to = 5 })
assert(r.id == "a2" and r.why:find("Chilio has claimed Bass") and it(1, 0).pos == 4 and #undo == 1, "someone else's claimed track: refused, nothing changed: " .. tostring(r.why))
assert(said:find("wasn't made"), "and the log says so")
r = select(2, act("Chilio", { op = "move", lane = 1, idx = 0, p = 4, l = 2, to = 5.4 }))
assert(r.ok and it(1, 0).pos == 5.5, "its claimant moves it")
r = select(2, act("Chilio", { op = "move", lane = 1, idx = 0, p = 4, l = 2, to = 7 }))
assert(r.why:find("changed meanwhile"), "the page's view is stale (it's at 5.5 now): refused")
-- moving off a claimed track, or onto one, mustn't slip past the claim
song()
r = select(2, act("James", { op = "move", lane = 0, idx = 0, p = 0, l = 4, to = 0, tolane = 1 }))
assert(r.why and r.why:find("Chilio") and #fake.tracks[3].items == 2, "onto Chilio's claimed Bass: refused")
-- Claims, Chilio here: an edit to their claim isn't refused. It's made, and mirror.watch holds it and asks them (lib/claimask.lua, rt-claims)
local claimask = require("claimask")
claimask.present = function(_, _, u) return u == "Chilio" end
song()
said, r = act("James", { id = "a3", op = "mute", lane = 1, idx = 0, p = 4, l = 2, on = true })
assert(r.id == "a3" and r.ok and r.ask == "Chilio" and it(1, 0).mute == 1 and said:find("Chilio is asked"), "Chilio's claimed Bass, Chilio here: made, and asked for: " .. tostring(r.why))
r = select(2, act("James", { op = "move", lane = 0, idx = 0, p = 0, l = 4, to = 0, tolane = 1 }))
assert(r.ok and r.ask == "Chilio" and #fake.tracks[3].items == 3, "onto their Bass too")
claimask.present = function() return false end
song()
r = select(2, act("James", { op = "mute", lane = 1, idx = 0, p = 4, l = 2, on = true }))
assert(r.why and r.why:find("Chilio has claimed Bass") and not r.ask and (it(1, 0).mute or 0) == 0, "Chilio away: refused as before")
r = select(2, act("James", { op = "mute", lane = 0, idx = 0, p = 0, l = 4, on = true }))
assert(r.ok and not r.ask, "what nobody claimed: no ask")
r = select(2, act("James", { op = "move", lane = 0, idx = 0, p = 0, l = 4, to = 0.5, tolane = 2 }))
assert(r.ok and #fake.tracks[1].items == 0 and fake.tracks[4].items[2].pos == 0.5, "onto an unclaimed track: moved there (the shown lanes skip this computer's own track)")
-- a region claim: what starts in Verse is Chilio's; the maker of a track may change it while nobody claimed it
song()
files[R .. "/claims/Chilio.json"].tracks = {}
r = select(2, act("James", { op = "move", lane = 1, idx = 1, p = 12, l = 4, to = 2 }))
assert(r.why and r.why:find("Chilio has claimed"), "an item in Chilio's Verse region: refused for the driver: " .. tostring(r.why))
r = select(2, act("Andie", { op = "mute", lane = 0, idx = 0, p = 0, l = 4, on = true }))
assert(r.ok and it(0, 0).mute == 1, "open: anyone changes what nobody claimed")
-- a room saved as Driver + claims (removed in rt) works as Driver only: even a track's maker is refused
room("claims", { Chilio = { regions = { "Verse" } } })
r = select(2, act("Andie", { op = "mute", lane = 2, idx = 0, p = 34, l = 4, on = true }))
assert(r.why and r.why:find("only the driver %(James%)") and (it(2, 0).mute or 0) == 0, "Driver + claims reads as Driver only: " .. tostring(r.why))
-- Driver only, and admins
room("driver")
r = select(2, act("Andie", { op = "mute", lane = 2, idx = 0, p = 34, l = 4, on = false }))
assert(r.why:find("only the driver %(James%)"), "Driver only: even the maker is refused")
room("admins")
assert(select(2, act("Andie", { op = "mute", lane = 2, idx = 0, p = 34, l = 4, on = false })).why:find("admins"), "admins' room: not an admin")
assert(select(2, act("Admin", { op = "mute", lane = 2, idx = 0, p = 34, l = 4, on = false })).ok and it(2, 0).mute == 0, "an admin may")
-- someone editing it right now (presence's holds)
room("open")
peers = { { user = "Chilio", editing = { "I-JAMES-1" } } }
r = select(2, act("James", { op = "mute", lane = 0, idx = 0, p = 0, l = 4, on = true }))
assert(r.why:find("Chilio is editing that item"), "a bandmate's hold: refused")
peers = {}
-- trims: the content stays put; not before the source's start unless it loops
song()
r = select(2, act("James", { op = "trim_start", lane = 0, idx = 0, p = 0, l = 4, to = 1.5 }))
local d = it(0, 0)
assert(r.ok and d.pos == 1.5 and d.len == 2.5 and d.takes[1].offs == 2.5, "left edge in: position, length and the take's offset move together")
r = select(2, act("James", { op = "trim_start", lane = 0, idx = 0, p = 1.5, l = 2.5, to = 0 }))
assert(r.ok and d.pos == 0 and d.takes[1].offs == 1, "back out to the source's start")
d.pos, d.takes[1].offs = 3, 1
d.len = 1
r = select(2, act("James", { op = "trim_start", lane = 0, idx = 0, p = 3, l = 1, to = 0 }))
assert(r.ok and d.pos == 2 and d.takes[1].offs == 0, "but no further than the source's start (it doesn't loop)")
r = select(2, act("James", { op = "trim_end", lane = 0, idx = 0, p = 2, l = 2, to = 3.6 }))
assert(r.ok and d.len == 1.5, "right edge, snapped")
r = select(2, act("James", { op = "trim_end", lane = 0, idx = 0, p = 2, l = 1.5, to = 1 }))
assert(r.ok and math.abs(d.len - dawedit.MIN_LEN) < 1e-9, "never shorter than MIN_LEN")
-- split at the edit cursor, or the play cursor while playing
song()
cursor = 2
r = select(2, act("James", { op = "split", lane = 0, idx = 0, p = 0, l = 4 }))
assert(r.ok and #splits == 1 and splits[1][2] == 2, "split at the edit cursor")
playing, playpos = true, 7
r = select(2, act("James", { op = "split", lane = 0, idx = 0, p = 0, l = 4 }))
assert(r.why:find("play cursor isn't over") and #splits == 1, "playing: the play cursor, which isn't over it")
playing = false
-- colour: the active take's when it has its own, else the item's; none clears both
r = select(2, act("Chilio", { op = "colour", lane = 1, idx = 0, p = 4, l = 2, c = "#ff0000" }))
assert(r.ok and it(1, 0).takes[1].color == (0xFF | 0x1000000) and (it(1, 0).color or 0) == 0, "the take had its own colour: that one")
r = select(2, act("James", { op = "colour", lane = 0, idx = 0, p = 0, l = 4, c = "#0000ff" }))
assert(r.ok and it(0, 0).color == (0xFF0000 | 0x1000000), "else the item's")
r = select(2, act("Chilio", { op = "colour", lane = 1, idx = 0, p = 4, l = 2, c = "" }))
assert(r.ok and it(1, 0).takes[1].color == 0 and it(1, 0).color == 0, "none: both cleared")

-- ---- markers and regions ----------------------------------------------------------------------------------------------------------------
song(); room("driver", { Chilio = { regions = { "Verse" } } })
r = select(2, act("Andie", { op = "add_marker", at = 3.1, name = "Bridge" }))
assert(r.why:find("only the driver changes markers") and #added == 0, "the timeline is the driver's (Driver only)")
r = select(2, act("James", { op = "add_marker", at = 3.1, name = "Bridge" }))
assert(r.ok and added[1].pos == 3 and added[1].name == "Bridge" and not added[1].rgn, "the driver adds a marker, snapped")
r = select(2, act("James", { op = "add_marker", at = 44, region = true, to = 52, name = "" }))
assert(r.ok and added[2].rgn and added[2].rend == 52 and undo[#undo].label:find("add region"), "and a region")
r = select(2, act("James", { op = "move_marker", i = 1, r = false, p = 2, to = 6.2 }))
assert(r.ok and fake.markers[1].pos == 6 and fake.markers[1].name == "A", "a marker moved, its name kept")
r = select(2, act("James", { op = "move_marker", i = 1, r = true, p = 10, to = 12 }))
assert(r.why:find("Chilio has claimed the region Verse") and fake.markers[2].pos == 10, "a region Chilio claimed stays hers")
room("open")
r = select(2, act("Andie", { op = "move_marker", i = 1, r = true, p = 10, to = 12 }))
assert(r.ok and fake.markers[2].pos == 12 and fake.markers[2].rend == 32, "Anyone: a region moved whole")
r = select(2, act("Andie", { op = "rename_marker", i = 1, r = true, p = 12, name = "Verse 1" }))
assert(r.ok and fake.markers[2].name == "Verse 1" and undo[#undo].label:find("rename region"), "renamed")
r = select(2, act("Andie", { op = "rename_marker", i = 1, r = false, p = 6, name = "" }))
assert(r.ok and fake.markers[1].name == "", "a name cleared (SetProjectMarker4's flag)")
r = select(2, act("Andie", { op = "move_marker", i = 3, r = false, p = 40, to = 1 }))
assert(r.why:find("changed meanwhile") and fake.markers[3].pos == 40, "this computer's own marks (a ping) aren't the page's to move")
room("open", { Chilio = { regions = { "Chorus" } } })
r = select(2, act("Andie", { op = "rename_marker", i = 1, r = true, p = 12, name = "chorus" }))
assert(r.why:find("Chilio has claimed the region chorus"), "nor renamed onto a name someone claimed")

-- ---- the answer reaches the page: published by the tick while it looks --------------------------------------------------------------
local published = {}
reaper.GetProjectStateChangeCount = function() return 1 end
reaper.GetSet_ArrangeView2 = function() return 0, 30 end
reaper.Master_GetPlayRate = function() return 1 end
reaper.GetProjectLength = function() return 60 end
reaper.TimeMap_GetMeasureInfo = function(_, m) return m * 2, 0, 0, 4, 4, 120 end
reaper.GetSetProjectGrid = function() return 0, 0.25 end
reaper.GetToggleCommandStateEx = function(_, cmd) return cmd == 1157 and 1 or 0 end
reaper.CountTempoTimeSigMarkers = function() return 0 end
reaper.TimeMap_GetTimeSigAtTime = function() return 4, 4, 120 end
reaper.ColorFromNative = function(c) return c & 255, (c >> 8) & 255, (c >> 16) & 255 end
fake.tracks = { { name = "Drums", oid = "T-JAMES-1", items = {}, ptr = {} } } -- (no takes: the reader's peaks are dawview's own test)
fake.tracks[1].ptr.t = fake.tracks[1]
package.loaded.people = { colours = function() return {} end }
dawview.action("P", as("James"), b, { want = true })
dawview.tick("P", as("James"), b, function(topic, t) published[topic] = t end, { mode = "open", driver = "James" }, 1000)
assert(published.dawedit and published.dawedit.why and published.dawedit.why:find("chorus"), "the last answer, as the dawedit topic")
assert(published.daw.snap == 1 and published.daw.markers[1].i == 1 and published.daw.markers[2].i == 1, "the header says snapping is on, and names markers by number")
assert(#published.daw.markers == 2, "pings left out")

-- ---- the page's edit hooks ------------------------------------------------------------------------------------------------------------
local function read(path) local f = assert(io.open(path, "rb"), path); local s = f:read("a"); f:close(); return s end
local js, css = read("lib/webui/daw.js"), read("lib/webui/daw.css")
for _, want in ipairs({ "act({ edit: Object.assign({ id }, o) })", "t.dawedit", "snapBack(r.why)", "op: 'move_marker'", "op: 'rename_marker'", "op: 'add_marker'",
    "itemOp('split')", "itemOp('mute'", "itemOp('colour'", "'trim_start'", "'trim_end'", "head.snap", "'contextmenu'", "setTimeout(() => { lp = null; lpFired = true",
    "if (touch && !mine) return;", "edDown(e);", "if (edMove(e)) return;", "if (edUp(e, was)) return;", "edItems(g, first, last);", "edMarker(m0)" }) do
  assert(js:find(want, 1, true), "the Project page has " .. want)
end
assert(css:find(".dmenu", 1, true) and css:find(".dedit", 1, true), "the edit row and the menu are styled")
assert(js:find("if (r.ask) say(", 1, true), "the Project page says whom the edit asked (rt-claims)")
print("ok")
