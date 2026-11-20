-- Session recaps and smart take names (James, rt; lib/recap.lua): the section under a take, the names and their numbers, REAPER's own names
-- told from typed ones, the session's window in the events, the recap's bullets, log line and Markdown; then name_takes on a fake project.
package.path = "lib/?.lua;" .. package.path
local studio = { smart_take_names = nil }
package.loaded.groups = { smart_take_names = function() return studio.smart_take_names ~= false end }
local markers = {}
package.loaded.band = { capture_markers = function() return markers end, log = function() end }
local recap = require("recap")

-- ---- 1. sections, names, numbers --------------------------------------------------------------------------------------------------------
local song = { { region = true, pos = 0, ["end"] = 30, name = "Verse" }, { region = true, pos = 30, ["end"] = 50, name = "Chorus" },
  { region = true, pos = 35, ["end"] = 40, name = "Stop" }, { region = false, pos = 60, name = "Bridge" }, { region = true, pos = 70, ["end"] = 80, name = "" } }
assert(recap.section_at(song, 10) == "Verse", "inside a region")
assert(recap.section_at(song, 30) == "Chorus", "a region's start is its own, not the one ending there")
assert(recap.section_at(song, 36) == "Stop", "nested: the latest-starting region")
assert(recap.section_at(song, 55) == nil, "past the regions, before any marker")
assert(recap.section_at(song, 65) == "Bridge", "no region: the last marker before it")
assert(recap.section_at(song, 75) == "Bridge", "an unnamed region doesn't count")
assert(recap.section_at({}, 3) == nil)
assert(recap.smart_name("Bridge", "James", 3) == "Bridge - James - take 3")
assert(recap.smart_name(nil, "James", 1) == "James - take 1", "no section: the player alone")
local s, p, n = recap.parse_name("Bridge - James - take 3")
assert(s == "Bridge" and p == "James" and n == 3)
s, p, n = recap.parse_name("Pre - Chorus - Bo - take 12")
assert(s == "Pre - Chorus" and p == "Bo" and n == 12, "a section with ' - ' in it")
s, p, n = recap.parse_name("James - take 2")
assert(s == nil and p == "James" and n == 2)
assert(recap.parse_name("my best take") == nil and recap.parse_name("") == nil)
local names = { "Verse - James - take 1", "Verse - James - take 4", "Verse - Bo - take 7", "Chorus - James - take 2", "James - take 5", "Guitar-001" }
assert(recap.next_n(names, "Verse", "James") == 5, "per section and player: the highest plus one")
assert(recap.next_n(names, "Verse", "Bo") == 8)
assert(recap.next_n(names, "Bridge", "James") == 1, "a new section starts at 1")
assert(recap.next_n(names, nil, "James") == 6, "no section counts on its own")

-- ---- 2. REAPER's names, never a typed one -----------------------------------------------------------------------------------------------
assert(recap.is_default_name("Guitar-001", "C:\\Songs\\Rec\\Guitar-001.flac"), "the recorded file's name")
assert(recap.is_default_name("Guitar-001.flac", "/x/Guitar-001.flac"), "with its extension")
-- (the desktop's real case: REAPER's name with the extension, the source already the band's shared copy)
assert(recap.is_default_name("03-XT Rec A-261119_1730.flac", "J:/S/Cross Test/rooms/main/media/4a2761dd-03-XT_Rec_A-261119_1730.flac"),
  "the shared copy of the recorded file, the take name with its extension")
assert(not recap.is_default_name("Verse keeper", "J:/S/media/4a2761dd-03-XT_Rec_A-261119_1730.flac"), "a typed name stays typed")
assert(recap.is_default_name("", "/x/a.wav") and recap.is_default_name("untitled MIDI item", ""), "empty, or a MIDI recording's")
assert(recap.is_default_name("Lead vox 01", "{media:main}/9f3a2b-Lead_vox_01.flac"), "the band's shared copy of the file")
assert(not recap.is_default_name("the keeper", "/x/Guitar-001.flac"), "typed: left alone")
assert(not recap.is_default_name("Verse - James - take 1", "/x/Guitar-001.flac"), "already named")
assert(not recap.is_default_name("Riff", nil), "no file, not empty: typed")

-- ---- 3. event times and the session's window ------------------------------------------------------------------------------------------
assert(recap.name_time("James-20261119-201502Z-00012-0042.json") == "2026-11-19T20:15:02Z")
assert(recap.name_time("Al-B_2-20261119-201502Z-00012-0042.json") == "2026-11-19T20:15:02Z", "a name with digits and dashes")
assert(recap.name_time("driver.json") == nil)
local function ev(t, x) x = x or {}; x.time = "2026-11-19T" .. t .. "Z"; x.id = x.id or (t .. tostring(x.user)); x.kind = x.kind or x.type; return x end
local evs = { ev("12:00:00", { user = "Bo", type = "obj", obj = "item", rev = 2 }), -- (the afternoon: hours before)
  ev("20:00:00", { user = "James", type = "obj", obj = "track", rev = 1, name = "Bass" }),
  ev("20:10:00", { user = "Bo", type = "obj", obj = "item", rev = 1, name = "Gtr", pos = 32, oid = "a" }),
  ev("20:25:00", { user = "James", type = "note", text = "chorus drags", pos = 95 }),
  ev("20:40:00", { user = "James", type = "obj", obj = "item", rev = 1, name = "Vox", pos = 5, oid = "b" }) }
assert(recap.window(evs, nil) == 2, "the trailing run with no gap over 20 minutes")
assert(recap.window(evs, "2026-11-19T20:10:00Z") == 4, "after the last recap's end")
assert(recap.window({ evs[1] }, nil) == 1)
assert(recap.window(evs, "2026-11-19T20:40:00Z") == 6, "nothing new: an empty window")

-- ---- 4. the recap ---------------------------------------------------------------------------------------------------------------------
local more = {
  ev("20:41:00", { user = "James", type = "obj", obj = "item", rev = 1, name = "Vox", pos = 5, oid = "c" }), -- (a lanes copy of the same take)
  ev("20:42:00", { user = "Bo", type = "obj", obj = "track", gone = true, name = "Old keys" }),
  ev("20:43:00", { user = "Bo", type = "timeline", tempo = { { bpm = 96, time = 0 } }, markers = { {}, {} } }),
  ev("20:44:00", { user = "Bo", type = "shift", len = 4, at = 64 }),
  ev("20:45:00", { user = "Bo", type = "like" }),
  ev("20:46:00", { user = "James", type = "obj", obj = "item", rev = 1, name = "Keys", pos = 40, oid = "d", auto = true }), -- (a print StudioSync made)
  ev("20:47:00", { user = "James", type = "obj", obj = "item", rev = 1, name = "Keys", pos = 40, oid = "e" }) } -- (pasted, typed name: not a take)
local sess = {}
for i = 2, #evs do sess[#sess + 1] = evs[i] end
for _, e in ipairs(more) do sess[#sess + 1] = e end
local take_names = { a = { "Gtr-003", "{media:main}/77aa-Gtr-003.flac" }, b = { "Verse - James - take 2", "x" }, c = { "Verse - James - take 2", "x" },
  d = { "wet - Keys", "y" }, e = { "pad idea", "{media:main}/1-loop.wav" } }
local r = recap.build(sess, { me = "James", peers = { "Mac" }, markers = song, now = "2026-11-19T21:10:00Z",
  versions = { { label = "end of session", by = "James", time = "2026-11-19T21:05:00Z" }, { label = "old", by = "Bo", time = "2026-11-18T10:00:00Z" } },
  take_name = function(e) local t = take_names[e.oid]; return t[1], t[2] end })
assert(table.concat(r.people, ",") == "Bo,James,Mac", "everyone who did something, this computer, and who's here now")
assert(r.mins == 47, "first change to last: " .. r.mins)
assert(#r.takes == 2, "a smart-named take and a REAPER-named one; a lanes copy once; no print, no pasted item: " .. #r.takes)
assert(r.takes[1].user == "Bo" and r.takes[1].track == "Gtr" and r.takes[1].section == "Chorus", "REAPER's name: section from the markers")
assert(r.takes[2].user == "James" and r.takes[2].section == "Verse" and r.takes[2].track == "Vox", "a smart name says it")
assert(r.added[1] == "Bass" and #r.added == 1 and r.removed[1] == "Old keys")
assert(#r.notes == 1 and r.notes[1] == "James at 1:35: chorus drags")
assert(r.likes == 1 and #r.versions == 1 and r.versions[1] == "end of session (James)", "only versions saved in the session")
assert(r.edits[1]:find("tempo or markers changed 1 time", 1, true) and r.edits[1]:find("96 bpm", 1, true), r.edits[1])
assert(r.edits[2] == "Bo inserted 4.0 s at 1:04 (every track)", r.edits[2])
assert(r.changes.James == 4 and r.changes.Bo == 2, "changes counted per person, StudioSync's own prints left out")
local lines = recap.lines(r)
assert(lines[1] == "Who: Bo, James, Mac" and lines[2] == "How long: 47 min" and lines[3] == "Takes: 2")
assert(lines[4] == "  Bo on Gtr, Chorus (Gtr-003)", lines[4])
local text = table.concat(lines, "\n")
assert(text:find("Tracks added: Bass", 1, true) and text:find("Tracks removed: Old keys", 1, true) and text:find("Note: James at 1:35", 1, true)
  and text:find("Saved version: end of session (James)", 1, true) and text:find("Changes: Bo 2, James 4", 1, true))
local line = recap.log_line(r)
assert(line == "last session (47 min; Bo, James, Mac): 2 takes, 1 track added, 1 track removed, 1 note, 1 saved version. Restore > Last session has it", line)
local md = recap.markdown(r, "Song A", "main", "2026-11-19 21:10", "James")
assert(md:find("^# Song A: session of 2026%-11%-19 21:10\n\n%- Who: Bo, James, Mac\n"), md)
assert(md:find("\n  %- Bo on Gtr, Chorus") and md:find("_As James's computer saw it", 1, true))
assert(recap.markdown(r, "Song A", "fork 1", "d", "J"):find("^# Song A %(fork 1%)"), "a side room says so")
local quiet = recap.build({ ev("09:00:00", { user = "Bo", type = "stop" }) }, { me = "Bo" })
assert(quiet.mins == 1 and recap.lines(quiet)[3] == "Takes: none", "a moment's session reads as a minute")
assert(recap.log_line(quiet):find("0 takes", 1, true))
assert(recap.markdown(r, "S", "main", "d", "J"):sub(-1) == "\n")

-- ---- 5. the newest recap in the room ----------------------------------------------------------------------------------------------------
local newest = recap.newest({ { recaps = { { to = "2026-11-19T20:00:00Z", by = "Bo" } } }, { recaps = { { to = "2026-11-19T21:00:00Z", by = "James" } } }, "junk", {} })
assert(newest and newest.by == "James", "whoever left last saw the most")
assert(recap.newest({}) == nil)

-- ---- 6. name_takes on a fake project ----------------------------------------------------------------------------------------------------
local function take(name, file, guid) return { name = name, file = file, guid = guid } end
local tracks = {
  { arm = 1, items = { { pos = 10, takes = { take("Guitar-001", "C:/rec/Guitar-001.flac", "g1") } },
                       { pos = 32, takes = { take("Verse - James - take 1", "C:/rec/a.flac", "g0"), take("Guitar-002", "C:/rec/Guitar-002.flac", "g2") } } } },
  { arm = 1, items = { { pos = 12, takes = { take("my keeper", "C:/rec/Bass-001.flac", "g3") } } } }, -- (typed: left alone)
  { arm = 0, items = { { pos = 15, takes = { take("Keys-001", "C:/rec/Keys-001.flac", "g4") } } } }, -- (not armed: not this recording's)
  { arm = 1, items = { { pos = 5, takes = { take("Old-001", "C:/rec/Old-001.flac", "g5") } } } } } -- (there before: not new)
-- (smart lanes: track 1 is in fixed lanes, its two new takes in lanes 2 and 3; lane 5 was named by someone already)
for _, tr in ipairs(tracks) do for _, it in ipairs(tr.items) do it.tr = tr; for _, tk in ipairs(it.takes) do tk.it = it end end end
tracks[1].freemode, tracks[1].lanenames = 2, { [5] = "my comp" }
tracks[1].items[1].lane, tracks[1].items[2].lane = 2, 3
reaper = {
  CountTracks = function() return #tracks end, GetTrack = function(_, i) return tracks[i + 1] end,
  GetMediaTrackInfo_Value = function(tr, k)
    if k == "I_FREEMODE" then return tr.freemode or 0 end
    assert(k == "I_RECARM"); return tr.arm
  end,
  GetSetMediaTrackInfo_String = function(tr, k, v, set)
    local lane = tonumber(k:match("^P_LANENAME:(%d+)$"))
    assert(lane, k)
    tr.lanenames = tr.lanenames or {}
    if set then tr.lanenames[lane] = v end
    return true, tr.lanenames[lane] or ""
  end,
  GetMediaItemTake_Item = function(tk) return tk.it end, GetMediaItem_Track = function(it) return it.tr end,
  CountTrackMediaItems = function(tr) return #tr.items end, GetTrackMediaItem = function(tr, j) return tr.items[j + 1] end,
  CountTakes = function(it) return #it.takes end, GetTake = function(it, k) return it.takes[k + 1] end,
  GetMediaItemInfo_Value = function(it, k)
    if k == "I_FIXEDLANE" then return it.lane or 0 end
    assert(k == "D_POSITION"); return it.pos
  end,
  GetMediaItemTake_Source = function(tk) return tk end, GetMediaSourceType = function() return "FLAC" end,
  GetMediaSourceFileName = function(src) return src.file end,
  GetSetMediaItemTakeInfo_String = function(tk, k, v, set)
    if k == "GUID" then return true, tk.guid end
    if set then tk.name = v end
    return true, tk.name
  end,
}
markers = song
local had = { g0 = true, g5 = true } -- (what recap.before_record would have found: the take already in the item, and the old part)
assert(recap.before_record(nil).g5 and recap.before_record(nil).g1 and not recap.before_record(nil).g4, "before_record: armed tracks' takes")
assert(recap.name_takes(nil, { user = "James", root = "R" }, had) == 2)
assert(tracks[1].items[1].takes[1].name == "Verse - James - take 2", "after the take already called take 1: " .. tracks[1].items[1].takes[1].name)
assert(tracks[1].items[2].takes[2].name == "Chorus - James - take 1", tracks[1].items[2].takes[2].name)
assert(tracks[2].items[1].takes[1].name == "my keeper" and tracks[3].items[1].takes[1].name == "Keys-001" and tracks[4].items[1].takes[1].name == "Old-001")
assert(tracks[1].lanenames[2] == "Verse - James - take 2" and tracks[1].lanenames[3] == "Chorus - James - take 1", "smart lanes: each lane as its take")
assert(tracks[1].lanenames[5] == "my comp" and tracks[2].lanenames == nil, "a named lane, and a track not in fixed lanes: left alone")
assert(recap.name_takes(nil, { user = "James", root = "R" }, nil) == 0, "no start seen: nothing named")
tracks[1].items[1].takes[1].name = "Guitar-001"
studio.smart_take_names = false
assert(recap.name_takes(nil, { user = "James", root = "R" }, had) == 0 and tracks[1].items[1].takes[1].name == "Guitar-001", "the studio turned it off")

-- smart lanes: a lane is named as its take, or as the pass when one pass put different sections' takes in it (James, rt)
local ln = recap.lane_names({ { lane = 2, section = "Verse", name = "Verse - James - take 2", pass = "James - take 2" },
  { lane = 3, section = "Chorus", name = "Chorus - James - take 1", pass = "James - take 1" },
  { lane = 3, section = "Bridge", name = "Bridge - James - take 1", pass = "James - take 1" },
  { lane = 4, section = nil, name = "James - take 5", pass = "James - take 5" }, { lane = 4, section = nil, name = "James - take 6", pass = "James - take 6" } })
assert(ln[2] == "Verse - James - take 2", "one section's take: the lane takes its name")
assert(ln[3] == "James - take 1", "two sections in one lane: the pass's name, no section")
assert(ln[4] == "James - take 5", "no sections, two takes: the first take's name")
assert(next(recap.lane_names({})) == nil and next(recap.lane_names(nil)) == nil, "nothing recorded: no lanes named")

print("ok")
