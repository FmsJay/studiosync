-- The drawing layer, finished (rt-draw2, docs/rt/rt-draw2.md; lib/webdraw.lua, lib/webui/draw.js, call.js): Line, Box and Highlighter from the
-- pages kept in the panel's own form; the pages' Undo and Redo (your own drawings only, live for everyone, the time a drawing was made kept
-- through a Redo); a screen share's notes kept as their author's drawings and wiped by Clear share notes; the Mixer's drawings reaching the
-- History page; and a link check of every piece. Two stand-in computers as tests/test_0_60_rt_draw.lua has them. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  RecursiveCreateDirectory = function() return 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function() end

-- ---- two stand-in computers: each its own disk; the shared folder's files reach the other only when "Syncthing" runs -------------------
local disks = { James = {}, Bo = {} }
local cur = "James"
local function disk() return disks[cur] end
band.files = function(dir, ext2)
  local out = {}
  for path in pairs(disk()) do
    local d, f = path:match("^(.*)/([^/]+)$")
    if d == dir and (not ext2 or f:sub(-#ext2) == ext2) then out[#out + 1] = f end
  end
  table.sort(out)
  return out
end
band.read_json = function(path) local s = disk()[path]; return s and band.json_decode(s) or nil end
band.write_json = function(path, t) disk()[path] = band.json_encode(t) end
reaper.file_exists = function(path) return disk()[path] ~= nil end
local deleted = { James = {}, Bo = {} }
os.remove = function(path) local had = disk()[path] ~= nil; disk()[path] = nil; if had then deleted[cur][path] = true end; return had end
local function syncthing(from, to) -- every file made and every file deleted on one disk, onto the other
  for p in pairs(deleted[from]) do disks[to][p] = nil end
  deleted[from] = {}
  for p, s in pairs(disks[from]) do if not disks[to][p] then disks[to][p] = s end end
end
local admins = {}
package.loaded.groups = { may_manage = function(_, user) return admins[user] == true end }
package.loaded.people = { colours = function(_, names) local out = {}; for _, n in ipairs(names) do out[n] = ({ James = 0xD9822B, Bo = 0x2A9CB0 })[n] end; return out end }
local wire = {} -- the stand-in direct link: { from, kind, text }
package.loaded.direct = {
  plain = function(s) return type(s) == "string" and s ~= "" and not s:find("[/\\]") and s ~= ".." end,
  send_live = function(_, kind, d, song, room, id) wire[#wire + 1] = { from = cur, kind = kind, text = band.json_encode({ song = song, room = room, id = id, d = d }) }; return true end,
}
local tracks = { { oid = "T-JAMES-1", name = "Drums", guid = "{1A2B3C4D-0000-1111-2222-333344445555}" }, { oid = "T-X-9", name = "Mine", own = true, guid = "{99999999-0000-0000-0000-000000000000}" },
  { oid = "T-BO-2", name = "Vox", guid = "{AABBCCDD-EEFF-0011-2233-445566778899}" } }
package.loaded.dawview = { shown = function(tr) return not tr.own end }
package.loaded.mirror = { track_oid = function(tr) return tr.oid end }
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return tracks[i + 1] end
reaper.GetTrackName = function(tr) return true, tr.name end
reaper.GetTrackGUID = function(tr) return tr.guid end
reaper.GetProjectStateChangeCount = function() return 1 end

package.loaded.webdraw = nil
local WJ = require("webdraw")
package.loaded.webdraw = nil
local WB = require("webdraw")
local W = WJ
local CJ, CB = { root = "R", user = "James" }, { root = "R", user = "Bo" }
local B = { song = "Song", room = "main" }
local DIR = "R/Song/rooms/main/drawings"
local function on(who, f, ...) cur = who; return f(...) end
local function deliver(to) -- the link's messages to `to` from the other computer (each once)
  local cfg, mod = to == "James" and CJ or CB, to == "James" and WJ or WB
  for _, m in ipairs(wire) do
    if m.from ~= to and not m["got_" .. to] then
      m["got_" .. to] = true
      local w = band.json_decode(m.text)
      on(to, mod.from_msg, cfg, w.d)
    end
  end
end
local function page(who, a) a.topic = "draw"; return on(who, who == "James" and WJ.action or WB.action, nil, who == "James" and CJ or CB, B, a) end
local function list(who) clock = clock + 2; return on(who, who == "James" and WJ.read or WB.read, who == "James" and CJ or CB, B) end
local function S(names) local out = {}; for n in names:gmatch("[^,]+") do out[#out + 1] = n end; table.sort(out); return table.concat(out, ",") end
local function kinds(who, view) -- what `who`'s computer shows on one view, in alphabetical order (compare with S("line,box")): someone else's as "line:Bo"
  local out = {}
  for _, s in ipairs(list(who)) do if s.view == view then out[#out + 1] = (s.kind or "pen") .. (s.user == who and "" or ":" .. s.user) end end
  return S(table.concat(out, ","))
end
local function file_of(who, id) return band.json_decode(disks[who][DIR .. "/" .. id .. ".json"]) end
local published = {}
local function topic(who)
  clock = clock + 2
  on(who, who == "James" and WJ.tick or WB.tick, "proj", who == "James" and CJ or CB, B, function(t, v) published[t] = v end, clock)
  return published.draw
end

-- ---- Line, Box, Highlighter: a page's drawing is kept as the panel keeps its own ------------------------------------------------------------
local ln = assert(W.clean({ kind = "line", pts = { { 1, "T-A-1", 0.2 }, { 4, "T-B-2", 0.9 } }, color = "#fff04d", size = 2 }))
assert(ln.kind == "line" and #ln.points == 2 and ln.points[2][2] == "T-B-2" and ln.color == 0xFFF04DFF and ln.size == 2, "a line: its two ends, the panel's colour form")
local bx = assert(W.clean({ kind = "box", pts = { { 1, "T-A-1", 0 }, { 4, "T-A-1", 1 } } }))
assert(bx.kind == "box" and #bx.points == 2 and bx.color == nil and bx.size == 4, "a box: two corners; no colour is the author's own")
local hl = assert(W.clean({ kind = "marker", pts = { { 1, "T-A-1", 0.5 }, { 2, "T-A-1", 0.5 }, { 3, "T-A-1", 0.6 } }, size = 8 }))
assert(hl.kind == "marker" and #hl.points == 3 and hl.size == 8, "a highlighter stroke: every point, the panel's kind 'marker'")
assert(W.clean({ kind = "line", pts = { { 1, "T-A-1", 0 } } }) == nil and W.clean({ kind = "box", pts = { { 1, "T-A-1", 0 }, { 2, "T-A-1", 0 }, { 3, "T-A-1", 0 } } }) == nil
  and W.clean({ kind = "marker", pts = { { 1, "T-A-1", 0 } } }) == nil, "a line and a box two points exactly, a highlighter stroke at least two")
for _, s in ipairs({ ln, bx, hl }) do assert(W.valid(s), "and each is a drawing the panel's check takes") end
-- the panel's toolbar and the page's offer the same kinds
local function read(p) local f = assert(io.open(p, "rb")); local t = f:read("a"); f:close(); return t end
local dj, panel = read("lib/webui/draw.js"), read("StudioSync - Draw.lua")
local function tool_kinds(src, pat) local out = {}; for k in src:match(pat):gmatch("[%[{]%s*['\"](%l+)['\"],") do out[#out + 1] = k end; return table.concat(out, ",") end
local web_tools, panel_tools = tool_kinds(dj, "const TOOLS = (%b[]);"), tool_kinds(panel, "local TOOLS = (%b{})")
assert(web_tools == "pen,marker,line,arrow,box,circle,text,erase" and web_tools == panel_tools, "the page's tools are the panel's, in its order: " .. web_tools .. " / " .. panel_tools)
for k in web_tools:gmatch("%l+") do assert(k == "erase" or W.KINDS[k], "and each is a kind the layer keeps: " .. k) end

-- ---- parse: undo, redo, the share's clear ------------------------------------------------------------------------------------------------
assert(W.parse({ undo = true }).step == "undo" and W.parse({ redo = true, view = "mixer" }).view == "mixer" and W.parse({ redo = true }).step == "redo", "undo and redo, on a view")
assert(W.parse({ undo = true, view = "screen" }) == nil and W.parse({ undo = "yes" }) == nil, "nothing else")
assert(W.parse({ clear = "mine", share = true }).share == true and W.parse({ clear = "all", share = true }) == nil and W.parse({ clear = "mine", share = 1 }) == nil
  and W.parse({ clear = "mine" }).share == nil, "Clear share notes is only ever your own (and never falls through to Clear all)")

-- ---- two computers: drawn on James's page, Undo and Redo live for Bo ------------------------------------------------------------------------
page("James", { add = { kind = "line", pts = { { 1, "T-JAMES-1", 0.2 }, { 5, "T-BO-2", 0.8 } }, color = "#fff04d" } })
page("James", { add = { kind = "box", pts = { { 2, "T-JAMES-1", 0 }, { 6, "T-JAMES-1", 1 } } } })
page("James", { add = { kind = "marker", pts = { { 3, "T-BO-2", 0.5 }, { 4, "T-BO-2", 0.5 }, { 5, "T-BO-2", 0.5 } }, size = 8 } })
assert(kinds("James") == S("line,box,marker"), "James's three: " .. kinds("James"))
local f1 = file_of("James", list("James")[3].id)
assert(f1.kind == "marker" and f1.user == "James" and f1.size == 8 and #f1.points == 3 and f1.points[1][2] == "T-BO-2" and f1.id == nil and f1.from == nil,
  "the highlighter's file, in the panel's form")
deliver("Bo")
assert(kinds("Bo") == S("line:James,box:James,marker:James"), "on Bo's at once: " .. kinds("Bo"))
local jt = topic("James")
assert(jt.un[1] == true and jt.un[2] == false and jt.un[3] == false and jt.un[4] == false, "James's pages: Undo here, nothing to Redo, nothing on the Mixer")
assert(jt.list[1].k == "marker" and jt.list[2].k == "box" and jt.list[3].k == "line" and jt.list[3].c == "#fff04d", "the pages get each kind")
assert(jt.tracks[1][4] == "1A2B3C4D" and jt.tracks[2][4] == "AABBCCDD" and jt.tracks[2][1] == "T-BO-2", "each track with screen share's name for it (the GUID's start)")
local bt = topic("Bo")
assert(bt.un[1] == false and bt.un[2] == false, "Bo has nothing of his own to undo")

-- Undo: James's newest goes, for Bo too
page("James", { undo = true })
assert(kinds("James") == S("line,box"), "Undo takes the highlighter: " .. kinds("James"))
deliver("Bo")
assert(kinds("Bo") == S("line:James,box:James"), "gone on Bo's at once")
assert(topic("James").un[2] == true, "and there's something to Redo")
-- Redo: back, for Bo too, as a new file with the time it was drawn
page("James", { redo = true })
assert(kinds("James") == S("line,box,marker"), "Redo puts it back: " .. kinds("James"))
deliver("Bo")
assert(kinds("Bo") == S("line:James,box:James,marker:James"), "back on Bo's at once: " .. kinds("Bo"))
local f2 = file_of("James", list("James")[3].id)
assert(f2.kind == "marker" and f2.time == f1.time and f2.size == 8 and #f2.points == 3, "the same drawing, the time it was first drawn")
-- two Undos, then a new drawing: Redo has nothing to put back any more
page("James", { undo = true }); page("James", { undo = true })
assert(kinds("James") == S("line"), "two Undos: " .. kinds("James"))
page("James", { redo = true })
assert(kinds("James") == S("line,box"), "Redo brings them back in order: " .. kinds("James"))
page("James", { add = { kind = "arrow", pts = { { 7, "T-JAMES-1", 0.5 }, { 9, "T-JAMES-1", 0.5 } } } })
assert(topic("James").un[2] == false, "a new drawing: nothing to Redo")
page("James", { redo = true })
assert(kinds("James") == S("line,box,arrow"), "and Redo does nothing: " .. kinds("James"))
deliver("Bo"); syncthing("James", "Bo")
assert(kinds("Bo") == S("line:James,box:James,arrow:James"), "Bo's computer agrees: " .. kinds("Bo"))

-- never someone else's: Bo, with nothing of his own, undoes nothing; nor as an admin
page("Bo", { undo = true }); page("Bo", { redo = true })
admins.Bo = true
page("Bo", { undo = true })
assert(kinds("Bo") == S("line:James,box:James,arrow:James") and kinds("James") == S("line,box,arrow"), "Undo never takes someone else's drawing, not even an admin's Undo")
-- an admin's Eraser on someone else's isn't a step of theirs: Undo doesn't bring it back, and takes nothing else
local arrow_id
for _, s in ipairs(list("Bo")) do if s.kind == "arrow" then arrow_id = s.id end end
assert(page("Bo", { remove = arrow_id }) == nil and kinds("Bo") == S("line:James,box:James"), "an admin erases James's arrow")
assert(topic("Bo").un[1] == false, "which gives Bo nothing to Undo")
page("Bo", { undo = true })
assert(kinds("Bo") == S("line:James,box:James"), "so Undo leaves it gone")
deliver("James"); syncthing("Bo", "James")
admins.Bo = nil
assert(kinds("James") == S("line,box"), "James's computer took the admin's removal")
-- ... and James's Undo of his arrow's step finds it gone, so it takes the step before (the box, put back by Redo earlier)
page("James", { undo = true })
assert(kinds("James") == S("line"), "a step whose drawing went some other way is passed over: " .. kinds("James"))
page("James", { redo = true })
assert(kinds("James") == S("line,box"), "and Redo still works: " .. kinds("James"))

-- the Eraser on your own is a step: Undo puts it back, Redo erases it again
local box_id
for _, s in ipairs(list("James")) do if s.kind == "box" then box_id = s.id end end
page("James", { remove = box_id })
assert(kinds("James") == S("line"), "erased")
page("James", { undo = true })
assert(kinds("James") == S("line,box"), "Undo puts back what the Eraser took: " .. kinds("James"))
page("James", { redo = true })
assert(kinds("James") == S("line"), "Redo erases it again")
page("James", { undo = true })
deliver("Bo"); syncthing("James", "Bo")
assert(kinds("Bo") == S("line:James,box:James"), "all of it reached Bo: " .. kinds("Bo"))

-- each view its own: a Mixer drawing isn't undone from the Project page, nor the other way
page("James", { add = { kind = "circle", view = "mixer", pts = { { 0.1, "T-BO-2", 0.2 }, { 0.4, "T-BO-2", 0.9 } } } })
local t2 = topic("James")
assert(t2.un[3] == true and t2.un[4] == false, "the Mixer's own Undo")
page("James", { undo = true })
assert(kinds("James", "mixer") == S("circle") and kinds("James") == S("line"), "Undo on the Project page leaves the Mixer's drawing: " .. kinds("James"))
page("James", { undo = true, view = "mixer" })
assert(kinds("James", "mixer") == S("") and kinds("James") == S("line"), "Undo on the Mixer takes it")
page("James", { redo = true, view = "mixer" }); page("James", { redo = true })
assert(kinds("James", "mixer") == S("circle") and kinds("James") == S("line,box"), "and each Redo puts its own back")

-- Clear mine can't be undone, and starts Undo afresh
assert(page("James", { clear = "mine" }):find("cleared 3 drawings", 1, true), "Clear mine")
page("James", { undo = true }); page("James", { redo = true }); page("James", { undo = true, view = "mixer" })
assert(kinds("James") == S("") and kinds("James", "mixer") == S(""), "nothing comes back after Clear mine")
local t3 = topic("James")
assert(not t3.un[1] and not t3.un[2] and not t3.un[3] and not t3.un[4], "and the buttons say so")
deliver("Bo"); syncthing("James", "Bo")

-- with nothing a page did since Live sync started: Undo takes your newest drawing on that view (as the panel's Undo), and Redo puts it back
-- with the time it was drawn (a panel drawing from the 1st of November stays one on History)
disks.James[DIR .. "/James-20261101-100000-1.json"] = band.json_encode({ user = "James", time = "2026-11-01T10:00:00Z", kind = "box",
  points = { { 1, "T-JAMES-1", 0.1 }, { 2, "T-JAMES-1", 0.9 } }, color = 0xFF5A5AFF, size = 4 })
disks.James[DIR .. "/Bo-20261102-100000-1.json"] = band.json_encode({ user = "Bo", time = "2026-11-02T10:00:00Z", kind = "line",
  points = { { 1, "T-BO-2", 0.1 }, { 2, "T-BO-2", 0.9 } }, size = 4 })
assert(kinds("James") == S("box,line:Bo"), "the panel's files: " .. kinds("James"))
page("James", { undo = true })
assert(kinds("James") == S("line:Bo") and disks.James[DIR .. "/James-20261101-100000-1.json"] == nil, "Undo takes James's newest, not Bo's newer one")
page("James", { undo = true })
assert(kinds("James") == S("line:Bo"), "and then there's nothing of his left")
page("James", { redo = true })
local back = list("James")
assert(#back == 2 and back[1].kind == "box" and back[1].time == "2026-11-01T10:00:00Z" and back[1].color == 0xFF5A5AFF and back[1].id ~= "James-20261101-100000-1",
  "Redo: the same drawing, a new file, the time it was drawn")
assert(W.id_ok(back[1].id), "named as drawings are")
page("James", { clear = "mine" })
disks.James[DIR .. "/Bo-20261102-100000-1.json"] = nil

-- Undo remembers STEPS_MAX things, and a put-back stops at the room's limit
local saved_steps, saved_room = WJ.STEPS_MAX, WJ.ROOM_MAX
WJ.STEPS_MAX = 2
for i = 1, 3 do page("James", { add = { kind = "line", pts = { { i, "T-JAMES-1", 0 }, { i + 1, "T-JAMES-1", 1 } } } }) end
for _ = 1, 3 do page("James", { undo = true }) end
assert(kinds("James") == S(""), "three Undos take all three (the third as your newest)")
for _ = 1, 3 do page("James", { redo = true }) end
assert(kinds("James") == S("line,line"), "but only two steps were remembered to Redo: " .. kinds("James"))
WJ.STEPS_MAX = saved_steps
page("James", { undo = true })
WJ.ROOM_MAX = 1
page("James", { redo = true })
assert(kinds("James") == S("line"), "a room full of drawings: Redo puts nothing back")
WJ.ROOM_MAX = saved_room
page("James", { clear = "mine" })
deliver("Bo"); syncthing("James", "Bo")
assert(kinds("Bo") == S("") and kinds("James") == S(""), "a clean room")

-- ---- a screen share's notes: kept as their author's drawings, marked, wiped by Clear share notes ------------------------------------------------
local sn = assert(W.clean({ kind = "arrow", pts = { { 15, "T-BO-2", 0.2 }, { 20, "T-BO-2", 0.6 } }, size = 4, from = "share" }))
assert(sn.from == "share" and W.valid(sn), "a note from a share says so")
assert(W.clean({ kind = "arrow", pts = { { 15, "T-BO-2", 0.2 }, { 20, "T-BO-2", 0.6 } }, from = "elsewhere" }).from == nil
  and W.clean({ kind = "circle", view = "mixer", pts = { { 0.1, "T-BO-2", 0.2 }, { 0.4, "T-BO-2", 0.9 } }, from = "share" }).from == nil, "only that, and only on the arrange view")
wire = {}
page("Bo", { add = { kind = "arrow", pts = { { 15, "T-BO-2", 0.2 }, { 20, "T-BO-2", 0.6 } }, size = 4, from = "share" } })      -- Bo's note on James's share
page("Bo", { add = { kind = "text", pts = { { 30, "T-JAMES-1", 0.5 } }, text = "too loud here", from = "share" } })
page("Bo", { add = { kind = "pen", pts = { { 1, "T-BO-2", 0.5 }, { 2, "T-BO-2", 0.5 } } } })                                   -- and a drawing of Bo's own
page("James", { add = { kind = "circle", pts = { { 40, "T-JAMES-1", 0 }, { 45, "T-JAMES-1", 1 } }, from = "share" } })           -- the sharer's own note
local bn = list("Bo")
assert(#bn == 3 and bn[1].user == "Bo" and bn[1].from == "share" and file_of("Bo", bn[1].id).from == "share" and file_of("Bo", bn[3].id).from == nil,
  "Bo's notes are Bo's own drawings, on his disk, marked as from a share")
deliver("James"); deliver("Bo")
assert(kinds("James") == S("arrow:Bo,text:Bo,pen:Bo,circle") and kinds("Bo") == S("arrow,text,pen,circle:James"), "everyone has them, live: " .. kinds("James"))
local st = topic("James")
local shared = 0
for _, d in ipairs(st.list) do if d.sh then shared = shared + 1; assert(d.k ~= "pen", "the pen stroke isn't a share note") end end
assert(shared == 3, "the pages are told which came from a share (a bandmate's too, over the link): " .. shared)
syncthing("Bo", "James"); syncthing("James", "Bo")
-- they outlive the share: nothing here depends on one. Bo wipes his: only his share notes go
assert(page("Bo", { clear = "mine", share = true }):find("cleared 2 share notes", 1, true), "Clear share notes")
assert(kinds("Bo") == S("pen,circle:James"), "Bo's own drawing and James's note stay: " .. kinds("Bo"))
assert(topic("Bo").un[1] == true, "and Bo's Undo wasn't started afresh by it")
deliver("James")
assert(kinds("James") == S("pen:Bo,circle"), "gone on James's at once")
-- a note is its author's like any drawing: James's Undo takes his own note
page("James", { undo = true })
assert(kinds("James") == S("pen:Bo"), "Undo takes the sharer's own note")

-- ---- the pieces are linked ---------------------------------------------------------------------------------------------------------------
local cj, css, hj = read("lib/webui/call.js"), read("lib/webui/draw.css"), read("lib/webui/history.js")
assert(dj:find("s.undoB = button('Undo'", 1, true) and dj:find("s.redoB = button('Redo'", 1, true) and dj:find("o[which] = true;", 1, true), "the pages' Undo and Redo")
assert(dj:find("s.undoB.disabled = !un[i]; s.redoB.disabled = !un[i + 1];", 1, true), "greyed when there's nothing to take")
assert(dj:find("FREE[s.drag.k]", 1, true) and dj:find("FREE[d.k]", 1, true) and dj:find("const FREE = { pen: true, marker: true }", 1, true), "the highlighter is drawn as the pen is")
assert(dj:find("from: 'share'", 1, true) and dj:find("act({ clear: 'mine', share: true })", 1, true) and dj:find("shareTag, shareNote, shareClear }", 1, true), "the share's notes")
assert(cj:find("window.ssDrawLayer.shareTag(view)", 1, true) and cj:find("window.ssDrawLayer.shareNote(n, f.view)", 1, true)
  and cj:find("window.ssDrawLayer.shareClear(say)", 1, true), "call.js: the view carries the oids, a note is kept, and Clear kept notes wipes")
assert(dj:find("OID.test(tr[4])", 1, true) and dj:find("v.key !== D.key", 1, true), "a share's oids are checked, and only for this room")
assert(dj:find("function histMixer(o, cols)", 1, true) and dj:find("list('mixer')", 1, true) and dj:find("document.querySelector('.hsstage')", 1, true)
  and css:find(".drhist canvas", 1, true) and hj:find("window.ssDrawLayer.hist(g,", 1, true), "History: the Mixer's drawings on their own row")
assert(not dj:find("innerHTML", 1, true) and not dj:find("insertAdjacentHTML", 1, true) and not dj:find("outerHTML", 1, true), "names and words still go in as text")
assert(read("lib/webui.lua"):find('require("webdraw").action(proj, cfg, b, a)', 1, true), "webui.lua routes every draw action as before")

print("ok")
