-- The drawing layer (rt-draw, docs/rt/rt-draw.md; lib/webdraw.lua, lib/webui/draw.js, anchor.js): what a page may send, the drawings as kept
-- (the panel's own files, read and written in its form), the pages' topic (compact, thinned, newest first, the author's colour), sync of
-- drawings and removals between two stand-in computers over a stand-in direct link with Syncthing arriving later, who may remove what (your
-- own; an admin anyone's; a bandmate's removal message only for what they may remove), the panel's Draw tool on the same storage, the
-- anchoring math (Node, when it's here), and a link check of every piece. (James, rt)
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
local logged = {}
band.log = function(s) logged[#logged + 1] = s end

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
local wire = {} -- the stand-in direct link: { from, kind, w }
package.loaded.direct = {
  plain = function(s) return type(s) == "string" and s ~= "" and not s:find("[/\\]") and s ~= ".." end,
  send_live = function(_, kind, d, song, room, id) wire[#wire + 1] = { from = cur, kind = kind, text = band.json_encode({ song = song, room = room, id = id, d = d }) }; return true end,
}
-- a stand-in REAPER's tracks, for the topic's track list
local tracks = { { oid = "T-JAMES-1", name = "Drums" }, { oid = "T-X-9", name = "Mine", own = true }, { oid = "T-BO-2", name = "Vox" } }
package.loaded.dawview = { shown = function(tr) return not tr.own end }
package.loaded.mirror = { track_oid = function(tr) return tr.oid end }
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return tracks[i + 1] end
reaper.GetTrackName = function(tr) return true, tr.name end
local cc = 1
reaper.GetProjectStateChangeCount = function() return cc end

-- each computer runs its own copy of the module (as Live sync on each does)
package.loaded.webdraw = nil
local WJ = require("webdraw")
package.loaded.webdraw = nil
local WB = require("webdraw")
assert(WJ ~= WB, "two copies")
local W = WJ -- (the pure parts: either)
local CJ, CB = { root = "R", user = "James" }, { root = "R", user = "Bo" }
local B = { song = "Song", room = "main" }
local DIR = "R/Song/rooms/main/drawings"
local function on(who, f, ...) cur = who; return f(...) end
local function deliver(to) -- the link's messages to `to` from the other computer, as JSON (each once)
  local cfg, mod = to == "James" and CJ or CB, to == "James" and WJ or WB
  local n = 0
  for _, m in ipairs(wire) do
    if m.from ~= to and not m["got_" .. to] then
      m["got_" .. to] = true
      local w = band.json_decode(m.text)
      if w.song == B.song and w.room == B.room then on(to, mod.from_msg, cfg, w.d); n = n + 1 end
    end
  end
  return n
end
local function ids(list) local out = {}; for _, s in ipairs(list) do out[#out + 1] = s.id end; return table.concat(out, ",") end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
assert(W.id_ok("James-20261120-101500-3") and W.id_ok("Bo_x-20261120-101500-1000042"), "ids as the panel names its files")
assert(not W.id_ok("../x-20261120-101500-3") and not W.id_ok("James-2026-101500-3") and not W.id_ok(("a"):rep(130) .. "-20261120-101500-3"), "nothing else")
assert(W.oid_ok("T-JAMES-20261120101010-11234") and not W.oid_ok("") and not W.oid_ok("T x") and not W.oid_ok(("T"):rep(81)), "track oids")
-- the panel's own files: a pen stroke without a kind (before 0.35.3), a point on one of StudioSync's own tracks (false)
assert(W.valid({ user = "James", time = "2026-11-01T10:00:00Z", points = { { 1, "T-A-1", 0.5 }, { 2, false, 0.4 } }, color = 0xFF5A5AFF, size = 4 }), "an old pen stroke")
assert(W.valid({ kind = "text", text = "here", points = { { 1, "T-A-1", 0.5 } } }), "a text")
for _, bad in ipairs({ {}, { points = {} }, { points = { { 1, "T-A-1" } } }, { points = { { "1", "T-A-1", 0 } } }, { points = { { 0 / 0, "T-A-1", 0 } } },
  { kind = "blob", points = { { 1, "T-A-1", 0 } } }, { view = "screen", points = { { 1, "T-A-1", 0 } } }, { color = -1, points = { { 1, "T-A-1", 0 } } },
  { text = ("x"):rep(900), points = { { 1, "T-A-1", 0 } } }, { user = 5, points = { { 1, "T-A-1", 0 } } } }) do
  assert(not W.valid(bad), "a bad drawing is skipped: " .. band.json_encode(bad))
end
assert(W.colour_in("#ff5a5a") == 0xFF5A5AFF and W.colour_in("red") == nil and W.colour_in("#ff5a5aff") == nil, "colours into the panel's form")
-- a page's new drawing
local s = assert(W.clean({ kind = "pen", pts = { { 1.23456, "T-A-1", 0.25 }, { 2, "T-A-1", 1.5 } }, color = "#4cc2ff", size = 8 }))
assert(s.kind == "pen" and s.points[1][1] == 1.235 and s.points[2][3] == 1 and s.color == 0x4CC2FFFF and s.size == 8 and s.view == nil, "rounded, kept 0-1 down the track, the panel's colour")
assert(W.clean({ kind = "arrow", pts = { { 1, "T-A-1", 0 } } }) == nil, "an arrow needs two points")
assert(W.clean({ kind = "circle", pts = { { 1, "T-A-1", 0 }, { 2, "T-A-1", 1 }, { 3, "T-A-1", 1 } } }) == nil, "a circle two exactly")
assert(W.clean({ kind = "pen", pts = { { 1, "T-A-1", 0 } } }) == nil, "a pen stroke at least two")
assert(W.clean({ kind = "text", pts = { { 1, "T-A-1", 0 } }, text = "  \t " }) == nil, "text needs words")
local tx = assert(W.clean({ kind = "text", pts = { { 1, "T-A-1", 0.3 } }, text = " louder\nhere ", size = 5 }))
assert(tx.text == "louder here" and tx.size == 4, "words cleaned, an odd size made M")
assert(W.clean({ kind = "text", pts = { { 1, "T-A-1", 0 } }, text = ("é"):rep(201) }) == nil, "200 characters at most")
local big = {}
for i = 1, 401 do big[i] = { i, "T-A-1", 0 } end
assert(W.clean({ kind = "pen", pts = big }) == nil, "400 points at most")
assert(W.clean({ kind = "pen", pts = { { 1, "T A", 0 }, { 2, "T-A-1", 0 } } }) == nil, "not a track oid")
assert(W.clean({ kind = "pen", pts = { { 1e8, "T-A-1", 0 }, { 2, "T-A-1", 0 } } }) == nil, "a time off the end of the world")
local mx = assert(W.clean({ kind = "circle", view = "mixer", pts = { { -0.05, "T-A-1", 0.5 }, { 0.7, "T-B-2", 1.1 } } }))
assert(mx.view == "mixer" and mx.points[1][1] == 0 and mx.points[2][3] == 1, "a Mixer drawing: places on the strip kept 0-1")
assert(W.clean({ kind = "line", view = "mixer", pts = { { 3, "T-A-1", 0.5 }, { 0.7, "T-B-2", 0.5 } } }) == nil, "not on a strip")
assert(W.clean({ kind = "line", view = "arrange", pts = { { 3, "T-A-1", 0.5 }, { 0.7, "T-B-2", 0.5 } } }) == nil, "only the views drawings go on")
assert(W.parse({ remove = "James-20261120-101500-3" }).remove[1] == "James-20261120-101500-3", "remove one")
assert(W.parse({ remove = { "x/../y" } }) == nil and W.parse({ clear = "everything" }) == nil and W.parse({ want = true }) == nil, "nothing else")
assert(W.parse({ clear = "all" }).clear == "all", "clear")
assert(W.may_remove("Bo", "Bo", false) and not W.may_remove("Bo", "James", false) and W.may_remove("Bo", "James", true) and not W.may_remove(nil, nil, true), "own, or an admin anyone's")
-- the topic: compact (each oid once), newest first, the author's colour when none was picked, times in UTC seconds
local m = W.model("Song/main", {
  { id = "James-20261120-100000-1", user = "James", time = "2026-11-20T10:00:00Z", kind = "pen", points = { { 1, "T-A-1", 0.5 }, { 2, "T-A-1", 0.5 }, { 3, "T-B-2", 0.25 } } },
  { id = "Bo-20261120-110000-1", user = "Bo", time = "2026-11-20T11:00:00Z", kind = "text", text = "hi", color = 0x4CC2FFFF, points = { { 4, "T-B-2", 0 } } },
  { id = "Bo-20261120-090000-1", user = "Bo", time = "2026-11-20T09:00:00Z", points = { { 1, false, 0 }, { 2, "T-B-2", 0 } } },
}, { { "T-A-1", 0, "Drums" } }, { James = 0xD9822B }, "James", false)
assert(m.list[1].id == "Bo-20261120-110000-1" and m.list[1].c == "#4cc2ff" and m.list[1].x == "hi", "newest first, its own colour")
assert(m.list[2].c == "#d9822b" and m.list[2].k == "pen" and #m.list[2].o == 2 and #m.list[2].p == 9 and m.list[2].p[8] == 1, "each oid once, points by number")
assert(m.list[2].t == 1795168800, "UTC seconds: " .. tostring(m.list[2].t))
assert(m.list[3].k == "pen" and #m.list[3].p == 3 and m.list[3].c == nil, "an old stroke: a pen, its own-track point left out, no colour known")
assert(m.me == "James" and m.admin == nil and m.tracks[1][1] == "T-A-1", "who's asking, the tracks")
local long = {}
for i = 1, 100000 do long[i] = { i / 100, "T-A-1", 0.5 } end
local ml = W.model("k", { { id = "James-20261120-100000-2", user = "James", time = "2026-11-20T10:00:00Z", kind = "pen", points = long } }, {}, {}, "James")
assert(#ml.list[1].p // 3 <= W.TOPIC_POINTS + 1 and ml.list[1].p[#ml.list[1].p - 2] == 1000, "a long stroke thinned for the page, still ending where it ended")

-- ---- two computers: drawn on James's page, at once on Bo's over the link, then the file arrives -------------------------------------------
on("James", WJ.action, nil, CJ, B, { topic = "draw", add = { kind = "arrow", pts = { { 15, "T-BO-2", 0.2 }, { 20, "T-BO-2", 0.6 } }, color = "#ff5a5a" } })
local jl = on("James", WJ.read, CJ, B)
assert(#jl == 1 and jl[1].user == "James" and jl[1].kind == "arrow" and not jl[1].live, "James's computer keeps it as a file")
local id1 = jl[1].id
assert(W.id_ok(id1) and id1:match("^James%-%d+%-%d+%-%d+$"), "named as the panel names its files: " .. id1)
local file = band.json_decode(disks.James[DIR .. "/" .. id1 .. ".json"])
assert(file.user == "James" and file.time:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") and file.points[1][2] == "T-BO-2" and file.color == 0xFF5A5AFF and file.size == 4
  and file.id == nil and file.file == nil and file.live == nil, "the file is in the panel's own form, nothing extra")
assert(#wire == 1 and wire[1].kind == "draw", "and it went over the link")
assert(#on("Bo", WB.read, CB, B) == 0, "not on Bo's disk yet")
assert(deliver("Bo") == 1, "the link brings it")
local bl = on("Bo", WB.read, CB, B)
assert(#bl == 1 and bl[1].id == id1 and bl[1].live and bl[1].user == "James", "on Bo's computer at once, with its author")
-- Bo's topic shows it
local published = {}
local function pub(t, v) published[t] = v end
clock = clock + 2
on("Bo", WB.tick, "proj", CB, B, pub, clock)
local bt = published.draw
assert(bt and bt.key == "Song/main" and bt.me == "Bo" and #bt.list == 1 and bt.list[1].u == "James" and bt.list[1].live and bt.list[1].c == "#ff5a5a", "Bo's pages get it")
assert(#bt.tracks == 2 and bt.tracks[1][1] == "T-JAMES-1" and bt.tracks[2][1] == "T-BO-2" and bt.tracks[2][2] == 2 and bt.tracks[2][3] == "Vox",
  "the tracks as the Project page shows them (this computer's own left out), with REAPER's numbers for History")
-- the same message again changes nothing; one claiming to be from Bo himself is refused
assert(not on("Bo", WB.from_msg, CB, band.json_decode(band.json_encode({ song = "Song", room = "main", name = id1, v = file }))), "once")
local spoof = band.json_decode(band.json_encode(file)); spoof.user = "Bo"
assert(not on("Bo", WB.from_msg, CB, { song = "Song", room = "main", name = "Bo-20261120-101500-7", v = spoof }), "a drawing 'by' this computer's own user isn't taken from the link")
assert(not on("Bo", WB.from_msg, CB, { song = "../x", room = "main", name = "James-20261120-101500-8", v = file }), "a song name that isn't plain")
local badv = band.json_decode(band.json_encode(file)); badv.points = { { "x", "T", 0 } }
assert(not on("Bo", WB.from_msg, CB, { song = "Song", room = "main", name = "James-20261120-101500-9", v = badv }), "a bad drawing from the link")
-- Syncthing brings the file: read from the file now
syncthing("James", "Bo")
clock = clock + 2
bl = on("Bo", WB.read, CB, B)
assert(#bl == 1 and bl[1].id == id1 and not bl[1].live, "the file is the record once it's here")

-- ---- who may remove what ----------------------------------------------------------------------------------------------------------------
logged = {}
assert(on("Bo", WB.action, nil, CB, B, { topic = "draw", remove = id1 }):find("only your own", 1, true), "Bo may not remove James's")
assert(disks.Bo[DIR .. "/" .. id1 .. ".json"] and disks.James[DIR .. "/" .. id1 .. ".json"], "still there")
assert(on("Bo", WB.action, nil, CB, B, { topic = "draw", clear = "all" }):find("only the studio's owner and admins", 1, true), "Clear all: admins only")
-- a message from Bo claiming to remove James's: refused (Bo isn't an admin)
assert(not on("James", WJ.from_msg, CJ, { song = "Song", room = "main", gone = { id1 }, by = "Bo" }), "a bandmate's removal of someone else's drawing isn't taken")
assert(#on("James", WJ.read, CJ, B) == 1, "James still sees it")
-- James removes his own: gone on his disk, and at once on Bo's (hidden until his deletion arrives)
assert(on("James", WJ.action, nil, CJ, B, { topic = "draw", remove = { id1 } }) == nil, "removing your own")
assert(disks.James[DIR .. "/" .. id1 .. ".json"] == nil and #on("James", WJ.read, CJ, B) == 0, "gone on James's computer")
assert(deliver("Bo") == 1 and #on("Bo", WB.read, CB, B) == 0 and disks.Bo[DIR .. "/" .. id1 .. ".json"], "hidden on Bo's at once; his file goes with Syncthing")
syncthing("James", "Bo")
assert(disks.Bo[DIR .. "/" .. id1 .. ".json"] == nil, "and then it has")

-- an admin removes anyone's, even one whose file hasn't come yet (it goes when it arrives)
on("James", WJ.action, nil, CJ, B, { topic = "draw", add = { kind = "text", pts = { { 3, "T-JAMES-1", 0.5 } }, text = "verse 2" } })
local id2 = on("James", WJ.read, CJ, B)[1].id
deliver("Bo")
admins.Bo = true
local bl2 = on("Bo", WB.read, CB, B)
assert(#bl2 == 1 and bl2[1].live and bl2[1].text == "verse 2", "Bo has it from the link")
clock = clock + 2
on("Bo", WB.tick, "proj", CB, B, pub, clock)
assert(published.draw.admin == true, "an admin's pages are told so (Clear all shows)")
assert(on("Bo", WB.action, nil, CB, B, { topic = "draw", remove = id2 }) == nil and #on("Bo", WB.read, CB, B) == 0, "an admin removes James's")
syncthing("James", "Bo") -- (the file reaches Bo after his removal)
clock = clock + 2
assert(#on("Bo", WB.read, CB, B) == 0 and disks.Bo[DIR .. "/" .. id2 .. ".json"] == nil, "it's deleted when it arrives")
deliver("James")
assert(#on("James", WJ.read, CJ, B) == 0, "James's computer takes an admin's removal at once")
syncthing("Bo", "James")
assert(disks.James[DIR .. "/" .. id2 .. ".json"] == nil, "and the deletion reaches his disk")

-- Clear mine, Clear all (with Bo an admin)
for i = 1, 3 do on("James", WJ.action, nil, CJ, B, { topic = "draw", add = { kind = "line", pts = { { i, "T-JAMES-1", 0 }, { i + 1, "T-JAMES-1", 1 } } } }) end
on("Bo", WB.action, nil, CB, B, { topic = "draw", add = { kind = "circle", view = "mixer", pts = { { 0.1, "T-BO-2", 0.2 }, { 0.4, "T-BO-2", 0.9 } } } })
syncthing("James", "Bo"); syncthing("Bo", "James")
-- (both disks now hold all four: James's three, Bo's circle)
local function count(d) local n = 0; for p in pairs(d) do if p:find(DIR, 1, true) then n = n + 1 end end; return n end
assert(count(disks.James) == 4 and count(disks.Bo) == 4, "four drawings in the room")
clock = clock + 2
assert(on("Bo", WB.action, nil, CB, B, { topic = "draw", clear = "mine" }):find("cleared 1", 1, true) and count(disks.Bo) == 3, "Clear mine: only Bo's")
assert(on("Bo", WB.action, nil, CB, B, { topic = "draw", clear = "all" }):find("cleared 3", 1, true) and count(disks.Bo) == 0, "Clear all, as an admin")
deliver("James")
clock = clock + 2
assert(#on("James", WJ.read, CJ, B) == 0, "everyone's gone on James's at once")
admins.Bo = nil
-- the room's limit
local saved_max = WB.ROOM_MAX
WB.ROOM_MAX = 1
on("Bo", WB.action, nil, CB, B, { topic = "draw", add = { kind = "line", pts = { { 1, "T-BO-2", 0 }, { 2, "T-BO-2", 1 } } } })
assert(on("Bo", WB.action, nil, CB, B, { topic = "draw", add = { kind = "line", pts = { { 1, "T-BO-2", 0 }, { 2, "T-BO-2", 1 } } } }):find("remove some first", 1, true), "a room full of drawings")
WB.ROOM_MAX = saved_max
assert(on("Bo", WB.action, nil, CB, B, { topic = "draw", add = { kind = "blob" } }):find("wasn't kept", 1, true), "a bad add is said")

-- ---- the panel's Draw tool: same files, same names, same check; a panel file shows on the web, a web one in the panel ------------------------
disks.James = {}
-- a file the panel wrote before (no kind: a pen stroke), and a damaged one
disks.James[DIR .. "/James-20261101-100000-1.json"] = band.json_encode({ user = "James", time = "2026-11-01T10:00:00Z", points = { { 1, "T-JAMES-1", 0.5 }, { 2, "T-JAMES-1", 0.6 } }, color = 0xFF5A5AFF, size = 4 })
disks.James[DIR .. "/James-20261101-100001-2.json"] = '{"user":"James","points":[[1,2,3]]}'
clock = clock + 2
jl = on("James", WJ.read, CJ, B)
assert(#jl == 1 and jl[1].id == "James-20261101-100000-1" and jl[1].kind == nil, "the panel's own file reads; a damaged one is skipped, as the panel skipped it")
-- the panel saves through webdraw: the same form, and over the link
wire = {}
local pid = on("James", WJ.save, CJ, B, { kind = "box", points = { { 1, "T-JAMES-1", 0 }, { 3, "T-JAMES-1", 1 } }, color = 0xFFFFFFFF, size = 2 })
assert(disks.James[DIR .. "/" .. pid .. ".json"] and #wire == 1, "the panel's drawing: its file, and over the link")
-- the panel's own poll of the link (another script): take_live
package.loaded.direct.messages = function() return { { kind = "draw", data = band.json_decode(wire[1].text) } } end
package.loaded.direct.dispatch = function(msgs, song, room, h) for _, mm in ipairs(msgs) do if mm.data.song == song and mm.data.room == room then h[mm.kind](mm.data.d) end end end
on("Bo", WB.take_live, CB, B)
local got = false
for _, x in ipairs(on("Bo", WB.read, CB, B)) do if x.id == pid and x.live and x.kind == "box" then got = true end end
assert(got, "the panel on Bo's computer reads the link itself")
local function read(p) local f = assert(io.open(p, "rb")); local t = f:read("a"); f:close(); return t end
local dl = read("StudioSync - Draw.lua")
assert(dl:find('require("webdraw")', 1, true) and dl:find("webdraw.read(cfg, b)", 1, true) and dl:find("webdraw.take_live(cfg, b)", 1, true), "Draw.lua reads the layer through webdraw")
assert(dl:find("if not s.view then", 1, true), "and leaves the Mixer's drawings off the arrange view")
assert(dl:find("webdraw.save(cfg, b, s)", 1, true) and not dl:find("band.write_json(string.format", 1, true), "saves through webdraw (the link too)")
assert(dl:find("webdraw.remove(cfg, b, { best.id }, cfg.user, false)", 1, true) and dl:find("webdraw.remove(cfg, b, { last.id }", 1, true)
  and dl:find("webdraw.remove(cfg, b, mine, cfg.user, false)", 1, true) and not dl:find("os.remove(", 1, true), "Eraser, Undo and Clear mine through webdraw")
assert(dl:find('kind == "circle"', 1, true) and dl:find('{ "circle", "Circle" }', 1, true), "the panel draws and makes circles")
local pc = read("lib/page_chat.lua")
assert(pc:find('s.view == nil and tonumber(s.points[1][1]) or nil', 1, true), "the Chat page's All has no Go for a Mixer drawing")

-- ---- the anchoring math (anchor.js), through Node when it's here --------------------------------------------------------------------------
local nh = io.popen and io.popen("node --version 2>&1")
local nv = nh and nh:read("a") or ""
if nh then nh:close() end
if nv:match("^v%d") then
  local h = io.popen("node tests/rt_draw_anchor_test.js 2>&1")
  local out = h:read("a"); h:close()
  assert(out:match("ok%s*$"), "anchor math: " .. out)
else
  print("note: node isn't here, so the anchoring math (tests/rt_draw_anchor_test.js) wasn't run")
end

-- ---- the pieces are linked ---------------------------------------------------------------------------------------------------------------
local ui, html, rec = read("lib/webui.lua"), read("lib/webui/index.html"), read("lib/webui/record.html")
assert(ui:find("webui.ACTIONS.draw = true", 1, true) and ui:find('require("webdraw").action(proj, cfg, b, a)', 1, true)
  and ui:find('require("webdraw").tick(proj, cfg, b, publish, now)', 1, true) and ui:find('handlers.draw = function(d) require("webdraw").from_msg(cfg, d) end', 1, true), "webui.lua routes it")
local ia, ic, idw, ih = html:find('src="anchor.js"', 1, true), html:find('src="call.js"', 1, true), html:find('src="draw.js"', 1, true), html:find('src="history.js"', 1, true)
assert(ia and ic and idw and ih and ia < ic and ih < idw and html:find('href="draw.css"', 1, true), "index.html: anchor.js before call.js, draw.js after history.js")
local ra, rp, rd = rec:find('src="anchor.js"', 1, true), rec:find('src="phonedaw.js"', 1, true), rec:find('src="draw.js"', 1, true)
assert(ra and rp and rd and rp < rd and ra < rd and rec:find('href="draw.css"', 1, true), "record.html: the phone's Project view")
local cj, an, dj = read("lib/webui/call.js"), read("lib/webui/anchor.js"), read("lib/webui/draw.js")
assert(cj:find("window.ssAnchor", 1, true) and not cj:find("function toPic", 1, true) and not cj:find("function fromPic", 1, true) and an:find("function fromPic", 1, true),
  "screen share's anchoring lives in anchor.js, once")
assert(read("lib/webui/daw.js"):find("if (X.over) X.over();", 1, true), "the Project page calls the layer as it draws")
assert(read("lib/webui/mixer.js"):find("el.dataset.o = s.o", 1, true), "the Mixer's strips say their track")
assert(read("lib/webui/history.js"):find("window.ssDrawLayer.hist(g,", 1, true), "History draws them at their time")
local pd = read("lib/webui/phonedaw.js")
assert(pd:find("window.ssPhoneDaw", 1, true) and select(2, pd:gsub("if %(PX%.over%) PX%.over%(%)", "")) == 2, "the phone's Project view calls the layer as it draws")
assert(not dj:find("innerHTML", 1, true) and not dj:find("insertAdjacentHTML", 1, true), "names and words go in as text")
for o in dj:gmatch("act%((%b{})%)") do assert(o:match("^{ add }") or o:match("^{ remove") or o:match("^{ clear"), "draw.js sends only add, remove, clear: " .. o) end
assert(dj:find("window.confirm", 1, true), "Clear asks first")

print("ok")
