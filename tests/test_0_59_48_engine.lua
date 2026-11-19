-- 0.59.48 (Round 3 review, sync engine): the round-2 fixes that stayed green when reverted, and round 3's engine fixes. Each block fails with
-- its fix reverted.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
local item_ext, calls = {}, {}
local function note(what) calls[#calls + 1] = what end
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function() return false end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  time_precise = function() return clock end,
  EnumProjects = function() return nil end,
  GetPlayStateEx = function() return 0 end,
  ValidatePtr = function() return true end,
  ValidatePtr2 = function() return true end,
  GetSetMediaItemInfo_String = function(it, k, v, set)
    item_ext[it] = item_ext[it] or {}
    if set then item_ext[it][k] = v end
    return true, item_ext[it][k] or ""
  end,
  GetSetMediaTrackInfo_String = function(it, k, v, set)
    item_ext[it] = item_ext[it] or {}
    if set then item_ext[it][k] = v end
    return true, item_ext[it][k] or ""
  end,
  GetMediaItemInfo_Value = function() return 0 end,
  GetMediaTrackInfo_Value = function() return 0 end,
  CountTakes = function() return 1 end,
  CountTracks = function() return 0 end,
  IsMediaItemSelected = function() return false end,
  GetTrackName = function() return true, "Keys" end,
}, { __index = function() return function() end end })

local files, written, removed, logged = {}, {}, {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then local c = {}; for k, x in pairs(v) do c[k] = x end; return c end end
proxy.files = function(dir, ext)
  local t = {}
  for path in pairs(files) do
    local d, f = path:match("^(.*)/([^/]+)$")
    if d == dir and (not ext or f:sub(-#ext) == ext) then t[#t + 1] = f end
  end
  table.sort(t)
  return t
end
proxy.listing = function() return {} end
proxy.write_json = function(path, v) written[path] = v; files[path] = v end
proxy.log = function(t) logged[#logged + 1] = t end
proxy.home = function() return "H" end
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
local real_remove = os.remove
os.remove = function(p) removed[p] = true; files[p] = nil; return true end
local real = { find = mirror.find, apply = mirror.apply, keep_item_copy = mirror.keep_item_copy, add_local_track = mirror.add_local_track }
local KT = { name = "kept track" }
mirror.add_local_track = function() return KT end

-- Round 2's only_shared at its apply site (codehealth 2: only the pure function was tested): a band item naming a file on your disk lands
-- with that path emptied
local TR, IT = { name = "TR" }, { name = "IT" }
local chunk_of = {}
reaper.GetItemStateChunk = function(it) return true, chunk_of[it] or "<ITEM\n>\n" end
reaper.SetItemStateChunk = function(it, ch) chunk_of[it] = ch; note("set " .. tostring(it.name)); return true end
reaper.AddMediaItemToTrack = function(tr) local it = { name = "new on " .. tostring(tr.name) }; note("add " .. it.name); return it end
reaper.GetMediaItem_Track = function() return TR end
reaper.file_exists = function() return true end
require("prints").choose = function() end
require("fxfiles").fetch = function() end
mirror.find = function(_, kind) if kind == "track" then return TR end end
reaper.AddMediaItemToTrack = function() return IT end
local ok = mirror.apply("PA", { obj = "item", oid = "I-A", track = "T-A", rev = 2,
  state = '<ITEM\n<SOURCE WAVE\nFILE "{media:main}/ok.wav"\n>\n<SOURCE WAVE\nFILE "C:/Users/v/taxes.wav"\n>\n>\n' }, "R/media", false)
assert(ok and chunk_of[IT] and not chunk_of[IT]:find("taxes", 1, true) and chunk_of[IT]:find('FILE ""', 1, true), "a planted path lands emptied: " .. tostring(chunk_of[IT]))

-- Round 2's receive waiting on Live sync's published unsent list (the panel's mirror.unsent is empty)
local applied = 0
mirror.apply = function() applied = applied + 1; return true, "h" end
gext[band.SECTION .. "\0unsent P2"] = "F-Q"
assert(mirror.receive("P2", { obj = "fx", oid = "F-Q", track = "T-Q", rev = 1, id = "Bo-1", state = "<FXCHAIN\n>\n" }, "R/media", false, "Me") == false and applied == 0,
  "a chain Live sync holds unsent here waits")

-- Round 2's held-back copy before the band's version replaces an item, and round 3's: once per version, and no replace without a copy
calls = {}
local IH = { name = "IH" }
mirror.find = function(_, kind, oid) if kind == "item" and oid == "I-H" then return IH end end
local copies = 0
mirror.keep_item_copy = function() copies = copies + 1; note("copy"); return {} end
mirror.apply = function() note("apply"); return false end -- (the band's audio still arriving: it waits)
mirror.held_back.P3 = { ["I-H"] = true }
mirror.receive("P3", { obj = "item", oid = "I-H", rev = 3, id = "Bo-20261119-100000Z-00001-0001", state = "<ITEM\n>\n" }, "R/media", false, "Me")
assert(calls[1] == "copy" and calls[2] == "apply" and not mirror.held_back.P3["I-H"], "a copy first, then the band's version: " .. table.concat(calls, ","))
mirror.held_back.P3["I-H"] = true -- (the next look holds it back again while the band's version waits)
mirror.receive("P3", { obj = "item", oid = "I-H", rev = 3, id = "Bo-20261119-100000Z-00001-0001", state = "<ITEM\n>\n" }, "R/media", false, "Me")
assert(copies == 1, "the retry makes no second copy (" .. copies .. ")")
mirror.keep_item_copy = function() copies = copies + 1; return nil end -- (a copy that fails)
mirror.held_back.P3["I-H"], calls = true, {}
assert(mirror.receive("P3", { obj = "item", oid = "I-H", rev = 4, id = "Bo-20261119-100100Z-00002-0001", state = "<ITEM\n>\n" }, "R/media", false, "Me") == false
  and mirror.held_back.P3["I-H"] and #calls == 0, "no copy: the band's version waits and the item stays held back")

-- Round 2's held edit's copy whatever is selected (W.put_back, why.held)
mirror.find, mirror.apply = real.find, function() return true, "" end
files["RW/events/Bo-7.json"] = { id = "Bo-7", type = "obj", obj = "item", oid = "I-E", rev = 2, state = "<ITEM\n>\n", user = "Bo" }
local made = 0
reaper.AddMediaItemToTrack = function() made = made + 1; return { name = "copy" } end
local w = { band = band, sync = sync, proj = "PW", cfg = { user = "Me" }, song = "S", room = "main", opts = { can = function() return true end, mode = "open" },
  me = "Me", room_dir = "RW", media = "RW/media", objs = {}, by_oid = {}, holds = {}, say_once = function() end, credit = {}, sent = 0, back = 0,
  kept_back = {}, bus_note = function() end, seen = {} }
local why = { copy = true, text = "Bo is editing it", held = true, name = "Keys" }
pcall(mirror.W.put_back, w, { kind = "item", oid = "I-E", ptr = { name = "edited" }, hash = "h1", track = "T-E" }, 2, "Bo-7", why)
assert(made == 1, "the held edit is copied though it isn't selected (" .. made .. ")")

-- Round 2's hold-back of a send that threw
local real_one = mirror.W.one
mirror.W.one = function() error("boom") end
mirror.held_back = {}
mirror.W.each({ objs = { { oid = "I-T" } }, seen = {}, proj = "PT", say_once = function() end })
assert(mirror.held_back.PT and mirror.held_back.PT["I-T"], "a send that threw is held back, so it's counted")
mirror.W.one = real_one

-- chg5: kept automation put back goes with the next send of it, whatever its text; one marked by 0.59.46/47 (`back` true) by its text
files["H/kept automation/Keys E-K 2026-11-19 100000.json"] = { oid = "E-K", back = 5000, state = "A" }
mirror.drop_kept_automation("E-K", "A read back another way", 5001)
assert(removed["H/kept automation/Keys E-K 2026-11-19 100000.json"], "the send after the put-back drops it")
files["H/kept automation/Keys E-K 2026-11-19 100001.json"] = { oid = "E-K", back = true, state = "A" }
files["H/kept automation/Keys E-K 2026-11-19 100002.json"] = { oid = "E-K", state = "A" }
mirror.drop_kept_automation("E-K", "B")
assert(files["H/kept automation/Keys E-K 2026-11-19 100001.json"], "an older mark: not by another text")
mirror.drop_kept_automation("E-K", "A")
assert(removed["H/kept automation/Keys E-K 2026-11-19 100001.json"] and files["H/kept automation/Keys E-K 2026-11-19 100002.json"], "by its own; never one not put back")

-- data L3: a track removed from the panel keeps an item Live sync holds unsent (its own table is empty here)
local TK, IZ = { name = "TK" }, { name = "IZ" }
item_ext[IZ] = { ["P_EXT:band_oid"] = "I-Z" }
mirror.find = function(_, kind, oid) if kind == "track" and oid == "T-K" then return TK end end
reaper.CountTrackMediaItems = function() return 1 end
reaper.GetTrackMediaItem = function() return IZ end
local moved = 0
reaper.MoveMediaItemToTrack = function() moved = moved + 1 end
mirror.track_colours, mirror.hold_colours = function() return {} end, function() end
reaper.SetProjExtState("PK", mirror.SEC, "I-Z", "2|abc|Bo-3|1")
gext[band.SECTION .. "\0unsent PK"] = "I-Z"
mirror.apply = real.apply
mirror.apply("PK", { obj = "track", oid = "T-K", gone = true, rev = 3 }, "R/media", false)
assert(moved == 1, "the held edit goes to (yours, not sent), not with the track")

-- sec L4: a declined suggestion's item comes back with only the studio's media paths
reaper.AddMediaItemToTrack = function() return IT end
chunk_of[IT] = nil
mirror.keep_suggested("PS", { obj = "item", oid = "I-S", rev = 2, name = "Keys", state = '<ITEM\n<SOURCE WAVE\nFILE "C:/Users/v/taxes.wav"\n>\n>\n' }, "R")
assert(chunk_of[IT] and not chunk_of[IT]:find("taxes", 1, true), "a path the parts file named is emptied")

-- sync2: the cheap first waits are known before an undo block opens
mirror.find = function(_, kind, oid) if kind == "track" then return TR end; if oid == "I-M" then return IH end end
gext[band.SECTION .. "\0unsent PU"] = "I-U"
assert(mirror.will_wait("PU", { obj = "item", oid = "I-U" }), "an edit of yours unsent")
reaper.GetPlayStateEx = function() return 1 end
assert(mirror.will_wait("PU", { obj = "fx", oid = "F-1", track = "T-1" }), "a chain while playing")
reaper.GetPlayStateEx = function() return 0 end
reaper.EnumProjects = function(i) if i == -1 then return "PU" end end
assert(not mirror.will_wait("PU", { obj = "fx", oid = "F-1", track = "T-1" }), "not stopped and in front")
local TKM = {}
reaper.MIDIEditor_GetActive = function() return "ed" end
reaper.MIDIEditor_GetTake = function() return TKM end
reaper.GetMediaItemTake_Item = function() return IH end
assert(mirror.will_wait("PU", { obj = "item", oid = "I-M" }) and not mirror.will_wait("PU", { obj = "item", oid = "I-N" }), "an item open in the MIDI editor, not another")
reaper.EnumProjects, reaper.MIDIEditor_GetActive = function() return nil end, nil
mirror.find = function() return nil end
assert(not mirror.will_wait("PU", { obj = "env", oid = "E-9", track = "T-9" }), "a part with no track here: not predicted")

-- sync3 / data L6: heal's newest leaves out a change too new for this version
files["R3/events/a.json"] = { id = "a", type = "obj", obj = "item", oid = "I-1", rev = 1, state = "s1", hlc = 1, user = "Al", format = 1 }
files["R3/events/b.json"] = { id = "b", type = "obj", obj = "item", oid = "I-1", rev = 2, state = "s2", hlc = 2, user = "Al", format = band.FORMAT + 1 }
assert(mirror.room_newest("R3")["I-1"].id == "a", "the newest this version can apply")

-- ux4 / chg8: Accept with nothing landing says "Try again" only when a part failed to apply
local suggest = require("suggest")
assert(suggest.none_landed(0, 0) == "It all changed since they suggested it: Decline, and they keep their version.", "all stale")
assert(not suggest.none_landed(2, 0):find("Try again", 1, true), "stale or not yours: no Try again")
assert(suggest.none_landed(1, 1):find("Try again", 1, true), "one that couldn't apply: Try again")

-- M6 / sec L6: a template keeps no recording or render path, and no master chain naming a file
local extras = require("extras")
local t = extras.template_text(table.concat({ "<REAPER_PROJECT 0.1", '  RECORD_PATH "D:/Shared/rooms" ""', '  RENDER_FILE "D:/x.wav"', "  <MASTERFXLIST",
  '    <VST "VST: ReaVerb" reaverb.dll 0', "      QzovVXNlcnMvdi9wcml2YXRlLndhdg==", "    >", "  >", "  <TRACK", "    NAME Keys", "  >", ">" }, "\n"))
assert(not t:find("RECORD_PATH", 1, true) and not t:find("RENDER_FILE", 1, true), "no recording or render path")
assert(not t:find("MASTERFXLIST", 1, true) and t:find("NAME Keys", 1, true), "a master chain naming a file goes, the tracks stay")
local t2 = extras.template_text("<REAPER_PROJECT 0.1\n  <MASTERFXLIST\n    <JS loser/limiter \"\"\n    >\n  >\n>\n")
assert(t2:find("MASTERFXLIST", 1, true), "a master chain naming no file stays")

-- M13: "behind" is the project's first catch-up (Live sync's, read through its published mark while it runs there), not any waiting change
local recall = require("recall")
reaper.CountMediaItems = function() return 0 end
band.capture_tempo, band.capture_markers = function() return {} end, function() return {} end
proxy.capture_tempo, proxy.capture_markers = band.capture_tempo, band.capture_markers
local cfg = { user = "Me", root = "root" }
local dir = recall.dir(cfg, "S", "main")
sync.pending_events = function() return 7 end -- (changes waiting under Hold: not catching up)
local f1 = recall.save("PR", cfg, "S", "main", "held", true)
assert(not written[dir .. "/" .. f1].behind and written[dir .. "/known/" .. f1], "waiting changes don't mark it: mapped")
gext[band.SECTION .. "\0loading PR"] = "1"
gext[band.SECTION .. "\0live PR"] = tostring(clock)
local f2 = recall.save("PR", cfg, "S", "main", "panel save", true)
assert(written[dir .. "/" .. f2].behind == true and not written[dir .. "/known/" .. f2], "Live sync loading it: behind")
local f3 = recall.save("PR", cfg, "S", "main", "yours before Bo", true, true)
assert(written[dir .. "/known/" .. f3], "the 'yours before' save keeps its map even so")
gext[band.SECTION .. "\0live PR"] = nil
local f4 = recall.save("PR", cfg, "S", "main", "no live sync", true)
assert(written[dir .. "/known/" .. f4], "a mark left by a Live sync that stopped counts for nothing")
-- code10: a map that couldn't be written is said
gext[band.SECTION .. "\0loading PR"] = nil
proxy.write_json = function(path, v) if path:find("/known/", 1, true) then error("disk full") end; written[path] = v end
logged = {}
recall.save("PR", cfg, "S", "main", "full disk", true)
assert(#logged == 1 and logged[1]:find("restores by time", 1, true), "said: " .. tostring(logged[1]))
proxy.write_json = function(path, v) written[path] = v; files[path] = v end

-- M2, M13, sync5: sync.receive publishes its loading mark and clears it; heal_due waits for the tab in front and stopped, and what it lands
-- gets an undo point of every kind of state (not Undo_OnStateChange2's items only)
local healed, points = 0, {}
local real_heal = mirror.heal
mirror.heal = function() healed = healed + 1; return 1 end
reaper.Undo_OnStateChangeEx2 = function(_, desc, which) points[#points + 1] = which end
reaper.Undo_OnStateChange2 = function() points[#points + 1] = "items only" end
local can = function() return true end
sync.loading.PH = true
mirror.heal_due.PH = true
reaper.EnumProjects = function(i) if i == -1 then return "other" end end
local published
local real_set = reaper.SetExtState
reaper.SetExtState = function(s, k, v, p) if k == "loading PH" then published = v end; real_set(s, k, v, p) end
sync.receive("PH", cfg, "S", "main", can)
assert(published == "1" and gext[band.SECTION .. "\0loading PH"] == nil and not sync.loading.PH, "published while loading, cleared once loaded")
assert(healed == 0 and mirror.heal_due.PH, "the heal waits while the tab is behind")
reaper.EnumProjects = function(i) if i == -1 then return "PH" end end
reaper.GetPlayStateEx = function() return 1 end
sync.receive("PH", cfg, "S", "main", can)
assert(healed == 0, "and while playing")
reaper.GetPlayStateEx = function() return 0 end
sync.receive("PH", cfg, "S", "main", can)
assert(healed == 1 and not mirror.heal_due.PH, "in front and stopped: it heals")
assert(#points == 1 and points[1] == -1, "with an undo point of every kind (" .. tostring(points[1]) .. ")")
mirror.heal = real_heal
reaper.SetExtState = real_set
-- sync2: a change that waits on its first pass (here an edit of yours to it unsent) opens no undo block, so leaves no empty undo point
local edir = sync.room_dir(cfg, "S", "main") .. "/events"
local eid = "Bo-20261119-110000Z-00001-0001"
files[edir .. "/" .. eid .. ".json"] = { id = eid, time = "2026-11-19T11:00:00Z", user = "Bo", type = "obj", obj = "fx", oid = "F-W", track = "T-W", rev = 1,
  state = "<FXCHAIN\n>\n", format = 1 }
proxy.listing = function(d) if d == edir then return { eid .. ".json" } end; return {} end
gext[band.SECTION .. "\0unsent PW2"] = "F-W"
local blocks = 0
reaper.Undo_BeginBlock2 = function() blocks = blocks + 1 end
sync.receive("PW2", cfg, "S", "main", can)
assert(sync.waited[eid] and blocks == 0, "it waits, with no undo block opened (" .. blocks .. ")")
-- sync3 / data L6: a change too new for this version isn't picked as an object's newest, so the older one it would have marked done lands
local e1, e2 = "Al-20261119-120000Z-00001-0001", "Al-20261119-120100Z-00002-0001"
files[edir .. "/" .. e1 .. ".json"] = { id = e1, time = "2026-11-19T12:00:00Z", user = "Al", type = "obj", obj = "fx", oid = "F-L", track = "T-L", rev = 1, state = "<FXCHAIN\n>\n", format = 1 }
files[edir .. "/" .. e2 .. ".json"] = { id = e2, time = "2026-11-19T12:01:00Z", user = "Al", type = "obj", obj = "fx", oid = "F-L", track = "T-L", rev = 2, state = "<FXCHAIN\n>\n", format = band.FORMAT + 1 }
proxy.listing = function(d) if d == edir then return { e1 .. ".json", e2 .. ".json" } end; return {} end
local landed = {}
mirror.apply = function(_, ev) landed[#landed + 1] = ev.id; return true, "h" end
sync.receive("PL", cfg, "S", "main", can)
assert(landed[1] == e1 and sync.deferred[e2], "the older one lands, the newer waits for an update (" .. tostring(landed[1]) .. ")")
mirror.apply = real.apply
proxy.listing = function() return {} end

-- perf2 (M8): a track whose whole chunk is the last look's reuses its items' states; a changed track reads its items again
local T1, T2 = { name = "T1" }, { name = "T2" }
local A1, A2, B1 = { name = "A1" }, { name = "A2" }, { name = "B1" }
chunk_of[A1], chunk_of[A2], chunk_of[B1] = "<ITEM\nPOSITION 1\n>\n", "<ITEM\nPOSITION 2\n>\n", "<ITEM\nPOSITION 3\n>\n"
local reads = 0
reaper.GetItemStateChunk = function(it) reads = reads + 1; return true, chunk_of[it] end
reaper.GetMediaItem_Track = function(it) return it == B1 and T2 or T1 end
local list = { { ptr = A1, tr = T1, guid = "{a1}" }, { ptr = A2, tr = T1, guid = "{a2}" }, { ptr = B1, tr = T2, guid = "{b1}" } }
local tchunks = { [T1] = "<TRACK\n" .. chunk_of[A1] .. chunk_of[A2] .. ">\n", [T2] = "<TRACK\n" .. chunk_of[B1] .. ">\n" }
local s1 = mirror.item_states("PM", list, tchunks, "R/media", {})
assert(reads == 3 and s1[1]:find("POSITION 1", 1, true) and s1[3]:find("POSITION 3", 1, true), "first look: every item read")
reads = 0
local s2 = mirror.item_states("PM", list, { [T1] = tchunks[T1], [T2] = tchunks[T2] }, "R/media", {})
assert(reads == 0 and s2[1] == s1[1] and s2[2] == s1[2] and s2[3] == s1[3], "unchanged tracks: none read again, the same states")
chunk_of[A2] = "<ITEM\nPOSITION 9\n>\n" -- (an edit: its track's chunk changes with it)
tchunks[T1] = "<TRACK\n" .. chunk_of[A1] .. chunk_of[A2] .. ">\n"
reads = 0
local s3 = mirror.item_states("PM", list, tchunks, "R/media", {})
assert(reads == 2 and s3[2]:find("POSITION 9", 1, true) and s3[1] == s1[1] and s3[3] == s1[3], "only the changed track's items are read, and the edit is in")
reads = 0
mirror.item_states("PM", list, tchunks, "R/media", { [T2] = true })
assert(reads == 1, "a track whose item got its id this look is read again")
reads = 0
mirror.item_states("PM", list, tchunks, "R/media2", {})
assert(reads == 3, "another media folder: all read")
local pooled = { [T1] = tchunks[T1] .. "POOLEDEVTS {x}\n", [T2] = tchunks[T2] }
mirror.item_states("PM", list, pooled, "R/media", {})
reads = 0
mirror.item_states("PM", list, pooled, "R/media", {})
assert(reads == 2, "a track with pooled MIDI is always read (its notes can be in another track's chunk)")

os.remove = real_remove
mirror.find, mirror.apply, mirror.keep_item_copy, mirror.add_local_track = real.find, real.apply, real.keep_item_copy, real.add_local_track
print("ok")
