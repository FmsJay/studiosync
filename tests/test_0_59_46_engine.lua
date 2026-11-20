-- 0.59.46 (Round 2 review, sync engine and its neighbours): what round 2 found untested or wrong. Each block fails with its fix reverted.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
local item_ext = {}
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function(p, sec, i)
    local keys = {}
    for k in pairs(sec_of(p, sec)) do keys[#keys + 1] = k end
    table.sort(keys)
    local k = keys[i + 1]
    if k then return true, k, sec_of(p, sec)[k] end
    return false
  end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  time_precise = function() return clock end,
  EnumProjects = function() return nil end,
  GetSetMediaItemInfo_String = function(it, k, v, set)
    item_ext[it] = item_ext[it] or {}
    if set then item_ext[it][k] = v end
    return true, item_ext[it][k] or ""
  end,
}, { __index = function() return function() end end })

local files, reads, written, removed, logged = {}, 0, {}, {}, {}
local band = require("band")
local real = { read_json = band.read_json, files = band.files, log = band.log, write_json = band.write_json }
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) reads = reads + 1; local v = files[path]; if type(v) == "table" then return v end end
proxy.files = function(dir, ext)
  local t = {}
  for path in pairs(files) do
    local d, f = path:match("^(.*)/([^/]+)$")
    if d == dir and (not ext or f:sub(-#ext) == ext) then t[#t + 1] = f end
  end
  table.sort(t)
  return t
end
proxy.write_json = function(path, v) written[path] = v; files[path] = v end
proxy.log = function(t) logged[#logged + 1] = t end
package.loaded.band = proxy
local mirror = require("mirror")
local real_remove = os.remove
os.remove = function(p) removed[p] = true; files[p] = nil; return true end

-- Root fix (James: refuse non-shared paths): a band version's FILE that isn't the studio's media is emptied before it's applied
local s = mirror.only_shared('<ITEM\n<SOURCE WAVE\nFILE "{media:main}/a.wav"\n>\n<SOURCE WAVE\nFILE "C:/Users/v/taxes.wav"\n>\n<SOURCE WAVE\nFILE \'D:/x.wav\'\n>\n>\n')
assert(s:find('FILE "{media:main}/a.wav"', 1, true) and not s:find("taxes", 1, true) and not s:find("D:/x.wav", 1, true), "only the studio's media stays: " .. s)

-- H: redo after an undo that removed something. Me added I-N (Me-1), undid it (Me-2, gone), redid it (Me-3): a second redo has nothing to
-- redo, and Undo takes the add back, not the undo
local E = {
  { kind = "obj", obj = "item", id = "Me-1", oid = "I-N", rev = 1, base = 0, user = "Me", time = "2026-11-19T10:00:00Z", state = "a" },
  { kind = "obj", obj = "item", id = "Me-2", oid = "I-N", rev = 2, user = "Me", time = "2026-11-19T10:01:00Z", gone = true, undoes = "Me-1" },
  { kind = "obj", obj = "item", id = "Me-3", oid = "I-N", rev = 3, user = "Me", time = "2026-11-19T10:02:00Z", state = "a", restored = "Me-1", redoes = "Me-2" },
}
assert(mirror.last_undo(E, "Me") == nil, "nothing more to redo")
E[#E + 1] = { kind = "obj", obj = "item", id = "Me-0", oid = "I-Z", rev = 1, base = 0, user = "Me", time = "2026-11-19T09:00:00Z", state = "z" }
table.sort(E, function(a, b) return a.time < b.time end)
local i = mirror.last_mine(E, "Me")
assert(E[i].id == "Me-1", "Undo takes the redone add back, not the undo (" .. tostring(E[i].id) .. ")")
-- and a redo after two undos goes on to the second (it stopped at "nothing to redo")
local F = {
  { kind = "obj", obj = "item", id = "Me-1", oid = "I-A", rev = 1, base = 0, user = "Me", time = "2026-11-19T10:00:00Z", state = "a" },
  { kind = "obj", obj = "item", id = "Me-2", oid = "I-B", rev = 1, base = 0, user = "Me", time = "2026-11-19T10:00:05Z", state = "b" },
  { kind = "obj", obj = "item", id = "Me-3", oid = "I-B", rev = 2, user = "Me", time = "2026-11-19T10:01:00Z", gone = true, undoes = "Me-2" },
  { kind = "obj", obj = "item", id = "Me-4", oid = "I-A", rev = 2, user = "Me", time = "2026-11-19T10:02:00Z", gone = true, undoes = "Me-1" },
  { kind = "obj", obj = "item", id = "Me-5", oid = "I-A", rev = 3, user = "Me", time = "2026-11-19T10:03:00Z", state = "a", restored = "Me-1", redoes = "Me-4" },
}
local r = mirror.last_undo(F, "Me")
assert(r and F[r].id == "Me-3", "the second redo reaches the earlier undo (" .. tostring(r and F[r].id) .. ")")

-- D: a track deleted with its items, the items' deletions a second later (a quarter second a pass): undoing an item brings the track too
local G = {}
local function g(e) e.kind = "obj"; e.user = "Me"; e.name = "Keys"; G[#G + 1] = e end
g{ id = "Me-t", obj = "track", oid = "T-K", rev = 1, base = 0, time = "2026-11-19T09:00:00Z", state = { name = "Keys" } }
g{ id = "Me-a", obj = "item", oid = "I-A", rev = 1, base = 0, time = "2026-11-19T09:00:01Z", state = "<ITEM\n>\n", track = "T-K" }
g{ id = "Me-b", obj = "item", oid = "I-B", rev = 1, base = 0, time = "2026-11-19T09:00:01Z", state = "<ITEM\n>\n", track = "T-K" }
g{ id = "Me-tg", obj = "track", oid = "T-K", rev = 2, base = 1, base_ev = "Me-t", time = "2026-11-19T10:00:00Z", gone = true }
g{ id = "Me-ag", obj = "item", oid = "I-A", rev = 2, base = 1, base_ev = "Me-a", time = "2026-11-19T10:00:01Z", gone = true, track = "T-K" }
g{ id = "Me-bg", obj = "item", oid = "I-B", rev = 2, base = 1, base_ev = "Me-b", time = "2026-11-19T10:00:01Z", gone = true, track = "T-K" }
G[5].state = "<ITEM\n>\nBANDLANE 0\n"; G[6].state = "<ITEM\n>\nBANDLANE 1\n" -- (other lanes: same_moment doesn't take them together)
local plan = mirror.plan_undo_moment(G, mirror.last_mine(G, "Me"))
assert(plan["T-K"] and plan["T-K"].id == "Me-t", "the track deleted a second before comes back with its items")
assert(plan["I-A"] and plan["I-B"], "and both its items")

-- H: heal (mirror.settled) doesn't merge a change over a month older than the newest, as receive doesn't
local store = {}
proxy.read_json = function(path) reads = reaper and reads + 1; local id = path:match("/events/(.+)%.json$"); if id and store[id] then return store[id] end; local v = files[path]; if type(v) == "table" then return v end end
local function ev(id, t) t.id, t.type, t.obj, t.oid = id, "obj", "item", t.oid or "I-X"; store[id] = t; return t end
local st0 = "<ITEM\nPOSITION 0\nFADEIN 0\n>\n"
local B0 = ev("Zed-20260101-090000Z-00001-0001", { rev = 1, base = 0, state = st0, user = "Zed", hlc = 1 })
local Old = ev("Al-20260102-090000Z-00001-0001", { rev = 2, base = 1, base_ev = B0.id, state = "<ITEM\nPOSITION 5\nFADEIN 0\n>\n", user = "Al", hlc = 2 })
local New = ev("Bo-20260301-090000Z-00001-0001", { rev = 2, base = 1, base_ev = B0.id, state = "<ITEM\nPOSITION 0\nFADEIN 1\n>\n", user = "Bo", hlc = 3 })
assert(mirror.settled("R", New, { B0, Old, New }) == New, "a change two months older isn't merged in by heal")

-- E (performance): heal's history read once; later reads only what's new, and a state is read only when asked for
files["R2/events/a.json"] = { id = "a", type = "obj", obj = "item", oid = "I-1", rev = 1, state = "<ITEM\n>\n", hlc = 1, user = "Al" }
files["R2/events/b.json"] = { id = "b", type = "obj", obj = "item", oid = "I-1", rev = 2, state = "<ITEM\nX\n>\n", hlc = 2, user = "Al" }
proxy.read_json = function(path) reads = reads + 1; local v = files[path]; if type(v) == "table" then local c = {}; for k, x in pairs(v) do c[k] = x end; return c end end
reads = 0
local newest = mirror.room_newest("R2")
assert(newest["I-1"].id == "b" and reads == 2, "first read: every file")
files["R2/events/c.json"] = { id = "c", type = "obj", obj = "item", oid = "I-2", rev = 1, state = "s", hlc = 3, user = "Al" }
reads = 0
newest = mirror.room_newest("R2")
assert(reads == 1 and newest["I-2"], "then only the new one (" .. reads .. " reads)")
reads = 0
assert(newest["I-1"].state == "<ITEM\nX\n>\n" and reads == 1, "its state read from its file when asked for")
assert(newest["I-1"].state == "<ITEM\nX\n>\n" and reads == 1, "and kept")

-- Performance A: the memo turns over only between looks, so nothing a look uses is worked out again
local made = 0
local function look(n) mirror.memo_turn(); for k = 1, n do mirror.memo("t", "k" .. k, function() made = made + 1; return k end) end end
look(30000) -- (past the 25,000-entry limit, as a big song's look is)
assert(made == 30000, "first look: all of them")
made = 0
look(30000); look(30000)
assert(made == 0, "later looks over the limit recompute none (" .. made .. ")")

-- G / M3: what Live sync publishes as unsent counts as an edit here, for revert and heal in the panel
gext[band.SECTION .. "\0" .. "unsent P1"] = "F-1,E-2"
assert(mirror.edited_here("P1", "E-2", "h") and not mirror.edited_here("P1", "F-9", ""), "Live sync's unsent list is read")

-- 14: the driver's own restore takes the owner step outside Live sync
local sync = require("sync")
sync.driver_name = nil
assert(mirror.owned({ mode = "claims", driver = "Me", can = function() return false end }, "Me", "Keys", nil, function() return false end), "the driver, from opts")

-- (B, a timeline waiting on Hold: Hold my changes is gone, rt-nohold. What's below reads this timeline)
band.capture_tempo = function() return { { time = 0, bpm = 140 } } end
band.capture_markers, band.capture_project = function() return {} end, function() return {} end

-- install C: a change of a kind or format this version doesn't know is left for the version that does
assert(not sync.too_new({ type = "obj", format = 1 }) and not sync.too_new({ type = "driver" }), "known kinds land")
assert(sync.too_new({ type = "loop" }) and sync.too_new({ type = "obj", format = band.FORMAT + 1 }), "an unknown kind or a newer format waits")

-- C: a version saved while behind is marked and has no map; one caught up writes its map beside it, not inside
local recall = require("recall")
reaper.CountMediaItems, reaper.CountTracks = function() return 0 end, function() return 0 end
sync.loading.PR = true -- (its first catch-up: Round 3 review, 0.59.48, not any pending change)
local f1 = recall.save("PR", { user = "Me", root = "root" }, "S", "main", "end of session", true)
local dir = recall.dir({ user = "Me", root = "root" }, "S", "main")
assert(written[dir .. "/" .. f1].behind == true and written[dir .. "/known/" .. f1] == nil, "behind: marked, no map")
sync.loading.PR = nil
reaper.SetProjExtState("PR", mirror.SEC, "I-K", "2|abc|Me-7|1|Me")
clock = clock + 2
local f2 = recall.save("PR", { user = "Me", root = "root" }, "S", "main", "later", true)
assert(written[dir .. "/" .. f2].known == nil and written[dir .. "/known/" .. f2]["I-K"] == "Me-7", "the map in a file of its own")
assert(recall.known({ user = "Me", root = "root" }, "S", "main", f2)["I-K"] == "Me-7" and recall.known({ user = "Me", root = "root" }, "S", "main", f1) == nil,
  "read back from it; a behind one has none (restores by time)")

-- M1 and the suggestion keeps (codehealth: untested): accepted with parts left, a part whose keep throws keeps its file
local suggest = require("suggest")
local RD = "RD"
files[RD .. "/suggestions/s1.json"] = { id = "s1", oids = { "I-1", "I-2", "I-3" }, from = "Me", owner = "Bo", names = { "Keys" }, changes = 3 }
files[RD .. "/suggestions/s1.answer.json"] = { answer = "accepted", left = 2, left_oids = { "I-2", "I-3" } }
files[RD .. "/suggestions/parts/s1/I-1.json"] = { obj = "item", oid = "I-1", rev = 2, state = "x" }
files[RD .. "/suggestions/parts/s1/I-2.json"] = { obj = "item", oid = "I-2", rev = 2, state = "y" }
files[RD .. "/suggestions/parts/s1/I-3.json"] = { obj = "item", oid = "I-3", rev = 2, state = "z" }
local kept = {}
mirror.keep_suggested = function(_, c) if c.oid == "I-3" then error("disk full") end; kept[#kept + 1] = c.oid; return true end
suggest.notices("PS", { user = "Me" }, RD)
assert(#kept == 1 and kept[1] == "I-2", "only what didn't go in is kept")
assert(removed[RD .. "/suggestions/parts/s1/I-1.json"] and removed[RD .. "/suggestions/parts/s1/I-2.json"], "the rest go")
assert(not removed[RD .. "/suggestions/parts/s1/I-3.json"] and files[RD .. "/suggestions/parts/s1/I-3.json"], "a part whose keep failed keeps its file")
-- accept: a part that can't land is in `left` and nothing landing isn't an accept
files[RD .. "/suggestions/parts/s2/I-9.json"] = { obj = "item", oid = "I-9", rev = 0, state = "q", name = "Keys" }
reaper.GetPlayStateEx = function() return 0 end
reaper.EnumProjects = function() return "PA" end
mirror.apply = function() return false end
local did, stale, refused, left = suggest.accept("PA", { user = "Bo" }, RD, { id = "s2", oids = { "I-9" }, from = "Me" }, function() return true end, false)
assert(did == 0 and refused == 1 and left[1] == "I-9", "a part that couldn't land is left, for its sender to keep")
reaper.EnumProjects = function() return nil end

-- Held back (codehealth: W.send's marks untested): a send with its last version unreadable, and one whose audio copy fails, are counted
mirror.held_back = {}
local said = {}
local w = { band = band, sync = sync, proj = "PW", cfg = { user = "Me" }, song = "S", room = "main", opts = { can = function() return true end, mode = "open" },
  me = "Me", room_dir = "RW", media = "RW/media", say_once = function(k) said[#said + 1] = k end, credit = {}, sent = 0, back = 0,
  bus_note = function() end }
sync.post = function() return "Me-20261119-100000Z-00001-0001" end -- (without the fix the send goes on: kept off the disk)
mirror.W.send(w, { kind = "item", oid = "I-U", state = "<ITEM\n>\n", track = "T-1" }, "PWI-U", 1, "Gone-1", "", nil, "Keys")
assert(mirror.held_back.PW and mirror.held_back.PW["I-U"], "last version unreadable: held back and counted")
reaper.file_exists = function(p) return not p:find("RW/media/", 1, true) end
band.size = function() return 10 end
band.copy_atomic = function() error("disk full") end
local ptr = {}
mirror.W.send(w, { kind = "item", oid = "I-C", ptr = ptr, state = '<ITEM\n<SOURCE WAVE\nFILE "{media:main}/ok.wav"\n>\n<SOURCE WAVE\nFILE "D:/mine/take.wav"\n>\n>\n', track = "T-1" },
  "PWI-C", nil, "", "", nil, "Keys")
assert(mirror.held_back.PW["I-C"], "a failed copy: held back and counted")
assert(mirror.waiting("PW", false), "and Sync and exit says something waits")
-- and a path a band's version put on the item isn't copied at all (share_media and mirror.theirs)
local copies = 0
band.copy_atomic = function() copies = copies + 1 end
item_ext[ptr] = { [mirror.THEIRS] = "d:/mine/take.wav" }
mirror.copy_failed, mirror.copy_pending = nil, nil
mirror.share_media('<ITEM\n<SOURCE WAVE\nFILE "D:\\mine\\take.wav"\n>\n>\n', "RW/media", ptr, nil)
assert(copies == 0, "the band's own path is never copied out")

-- Security A: the end-of-session export copies only the project's or the studio's own files, never a band's path
local sessionfile = require("sessionfile")
local theirs = sessionfile.theirs('<ITEM\n<EXTI\nband_oid I-1\nband_theirs "c:/users/v/taxes.wav|d:/x.wav"\n>\n>\n')
assert(theirs["c:/users/v/taxes.wav"] and theirs["d:/x.wav"], "the band's paths read from the saved text")
assert(sessionfile.may_copy("D:/Songs/Demo/Audio/take.wav", { "D:/Songs/Demo", "J:/Studio" }, theirs), "a recording in the project's folder goes")
assert(sessionfile.may_copy("J:/Studio/x/media/a.wav", { "D:/Songs/Demo", "J:/Studio/" }, theirs), "one in the studio's folder goes")
assert(not sessionfile.may_copy("C:/Users/v/taxes.wav", { "D:/Songs/Demo", "J:/Studio" }, theirs), "a file elsewhere doesn't")
assert(not sessionfile.may_copy("D:/Songs/Demo/x.wav", { "D:/Songs/Demo" }, { ["d:/songs/demo/x.wav"] = true }), "nor a band's path, even inside")
-- the export itself (codehealth: band.save_copy's callers untested): one save of the copy, your local tracks out, only your own files queued
local saves = 0
reaper.Main_SaveProjectEx = function() saves = saves + 1 end
reaper.IsProjectDirty = function() return 0 end
reaper.EnumProjects = function(k) if k == 0 then return "PE", "D:/Songs/Demo/Demo.rpp" end end
reaper.file_exists = function(p) return p:find("^D:/Songs/Demo/") ~= nil or p:find("^C:/Users/v/") ~= nil end
band.size = function() return 10 end
local copied_from = {}
band.copy_atomic = function(from) copied_from[#copied_from + 1] = from end
local function trk(name, ext, file) -- (indented as REAPER writes a project)
  return table.concat({ "  <TRACK", "    NAME " .. name, ext and "    <EXT\n      band_local yours\n    >" or "    VOLPAN 1 0", "    <ITEM", "      <SOURCE WAVE",
    '        FILE "' .. file .. '"', "      >", "    >", "  >" }, "\n")
end
proxy.read = function() return table.concat({ "<REAPER_PROJECT", trk("Mine", false, "Audio/take.wav"), trk("Helper", true, "Audio/local.wav"),
  trk("Theirs", false, "C:/Users/v/taxes.wav"), ">" }, "\n") .. "\n" end
proxy.write_atomic = function(path, text) written[path] = text end
local out = sessionfile.export("PE", { user = "Me", root = "J:/Studio" }, { song = "Demo", room = "main" }, "G:/Drive", "J:/Studio/Demo/rooms/main")
assert(out and saves == 1, "the copy is saved once (" .. saves .. ")")
assert(#copied_from == 1 and copied_from[1] == "D:/Songs/Demo/Audio/take.wav", "only your own recording is copied: " .. table.concat(copied_from, ", "))
assert(not written[out]:find("Helper", 1, true), "and your local track isn't in the cloud copy")

-- a bandmate's path ending in "/" is refused, not an error that skips the whole chain (crossplatform 6)
assert(require("fxfiles").safe({ path = "D:/Samples/", copy = "plugin files/a.wav" }) == false, "refused quietly")

-- Security B: a print isn't made from a take playing a band's path
local prints = require("prints")
local itp, tkp = {}, {}
item_ext[itp] = { [mirror.THEIRS] = "c:/users/v/private.wav" }
reaper.GetMediaItemTake_Source = function() return "src" end
reaper.GetMediaSourceFileName = function() return "C:\\Users\\v\\private.wav" end
assert(prints.from_band(itp, tkp), "a take playing a band's path isn't printed here")
reaper.GetMediaSourceFileName = function() return "D:/mine.wav" end
assert(not prints.from_band(itp, tkp), "your own is")

os.remove = real_remove
print("ok")
