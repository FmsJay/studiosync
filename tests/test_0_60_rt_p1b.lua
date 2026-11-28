-- rt-p1b (two sync-core leftovers from rt-p6, docs/rt/rt-history2.md round 2): (1) an item restored from a version made under another tempo
-- map is stretched as REAPER's "beats (position, length, rate)" timebase stretches it (snap offset, fades, an audio take's rate; a MIDI
-- take's rate stays), and an automation part's points and items go onto their beats the same way (mirror.retime, mirror.retime_env until
-- rt-sync2f; now a version from before is read into beats by the map it names and put in seconds on another: lib/beats.lua's upgrade and
-- seconds_on, the same numbers; the Restore end to end is in tests/test_0_60_rt_edits.lua); (2) a comp piece's change names the lane it came from (mirror.comp_from, the
-- change's from_lane), which the time lapse reads (lib/webhistory.lua, lib/webui/history.js). Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
reaper = setmetatable({}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return 0 end end end })
local mirror = require("mirror")
local wh = require("webhistory")
local function num(s, pat) return tonumber(s:match(pat)) end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end
local beats = require("beats")
-- (a version made under `from`, put on `to`: what mirror.retime did, now beats.upgrade then beats.seconds_on)
local function onto(kind, state, from, to, mode) return beats.seconds_on(kind, beats.upgrade(kind, state, from, mode), to) end
mirror.retime = function(state, from, to, mode) return onto("item", state, from, to, mode) end
mirror.retime_env = function(state, from, to, mode) return onto("env", state, from, to, mode) end

-- ---- 1. an item: 120 -> 60 bpm doubles it in mode 1 ----------------------------------------------------------------------------------------
local A, B = { { time = 0, bpm = 120 } }, { { time = 0, bpm = 60 } }
local ITEM = table.concat({ "<ITEM", "POSITION 8", "SNAPOFFS 0.5", "LENGTH 2", "LOOP 1", "FADEIN 1 0.25 0.1 1 0 0 0", "FADEOUT 2 0.5 0 1 0 0 0",
  "NAME \"x\"", "SOFFS 1.5", "PLAYRATE 1 1 0 -1 0 0.0025", "<SOURCE WAVE", "FILE \"a.flac\"", ">",
  "TAKE", "NAME \"m\"", "SOFFS 0", "PLAYRATE 1.25 1 0 -1 0 0.0025", "<SOURCE MIDI", "HASDATA 1 960 QN", "E 0 90 3c 60", ">",
  "TAKE SEL", "NAME \"b\"", "PLAYRATE 2 1 0 -1 0 0.0025", "<SOURCE WAVE", "FILE \"b.flac\"", ">", ">", "BANDLANE 1", "" }, "\n")
local r = mirror.retime(ITEM, A, B, 1)
assert(num(r, "\nPOSITION (%S+)") == 16 and num(r, "\nLENGTH (%S+)") == 4, "its beat and length in beats")
assert(near(num(r, "\nSNAPOFFS (%S+)"), 1), "the snap offset stretches with it (same place in the audio)")
assert(r:find("\nFADEIN 1 0.5 0.2 1 0 0 0\n", 1, true) and r:find("\nFADEOUT 2 1 0 1 0 0 0\n", 1, true), "fades stretch, auto length too: " .. r)
local rates = {}
for v in r:gmatch("\nPLAYRATE (%S+)") do rates[#rates + 1] = tonumber(v) end
assert(near(rates[1], 0.5) and near(rates[2], 1.25) and near(rates[3], 1), "an audio take's rate halves (twice as long), a MIDI take's stays: " .. table.concat(rates, " "))
assert(r:find("\nSOFFS 1.5\n", 1, true) and r:find("\nE 0 90 3c 60\n", 1, true) and r:find("\nBANDLANE 1\n$"), "the source position, the notes and what follows the item stay")
r = mirror.retime(ITEM, A, B, 2)
assert(num(r, "\nPOSITION (%S+)") == 16 and num(r, "\nLENGTH (%S+)") == 2 and r:find("\nSNAPOFFS 0.5\n", 1, true) and r:find("\nFADEIN 1 0.25 0.1 ", 1, true)
  and r:find("\nPLAYRATE 1 1 ", 1, true), "beats (position only): only the place")
assert(mirror.retime(ITEM, A, A, 1) == ITEM, "the same map: untouched")
assert(mirror.retime(ITEM, A, B, 0) == ITEM and mirror.retime(ITEM:gsub("\nLOOP 1", "\nBEAT 0\nLOOP 1"), A, B, 1) == ITEM:gsub("\nLOOP 1", "\nBEAT 0\nLOOP 1"), "time: stays")

-- ---- 2. automation: points and automation items onto their beats ---------------------------------------------------------------------------
local ENV = table.concat({ "<VOLENV2", "ACT 1 -1", "PT 0 1 0", "PT 4 0.5 0", "PT 6.5 1 0 0 1", "POOLEDENVINST 1 2 2 0 1 0 0 0 0 0 0 1", ">",
  "BANDAI VOLENV2 2 2 0.25 1.5 0 1 0 0 4", "BANDAIPT VOLENV2 0 2.5 0.3 0 0", "BANDFXEN 1", "" }, "\n")
local e = mirror.retime_env(ENV, A, B, 1)
assert(e:find("\nPT 0 1 0\nPT 8 0.5 0\nPT 13 1 0 0 1\n", 1, true), "each point on its beat, the rest of its line kept: " .. e)
assert(e:find("\nPOOLEDENVINST 1 4 4 0 1 ", 1, true) and e:find("\nBANDAI VOLENV2 4 4 0.25 1.5 0 1 0 0 4\n", 1, true), "an automation item's place and length in beats; its rate stays")
assert(e:find("\nBANDAIPT VOLENV2 0 5 0.3 0 0\n", 1, true) and e:find("\nBANDFXEN 1\n$") and e:find("^<VOLENV2\nACT 1 %-1\n"), "its points too; other lines stay")
e = mirror.retime_env(ENV, A, B, 2)
assert(e:find("\nPOOLEDENVINST 1 4 2 ", 1, true) and e:find("\nBANDAI VOLENV2 4 2 ", 1, true) and e:find("\nPT 8 0.5 0\n", 1, true), "position only: an item keeps its seconds' length")
assert(mirror.retime_env(ENV, A, A, 1) == ENV and mirror.retime_env(ENV, A, B, 0) == ENV, "the same map, or time: untouched")
assert(mirror.retime_env(ENV, A, { { time = 0, bpm = 60, linear = true } }, 1) == mirror.retime_env(ENV, A, B, 1), "(a lone gradual point holds its tempo: converted as 60, as REAPER's TimeMap2 counts it; rt-sync2f)")
-- a map with a change in it: 120 until 4 s (beat 8), then 60; under 120 throughout, a point at 6 s (beat 12) sits at 8 s
local AB = { { time = 0, bpm = 120 }, { time = 4, bpm = 60 } }
assert(mirror.retime_env("PT 2 1 0\nPT 6 1 0\n", A, AB, 1) == "PT 2 1 0\nPT 8 1 0\n", "points before the change stay, after it on their beat")

-- ---- 3. a comp piece's source lane ---------------------------------------------------------------------------------------------------------
local function it(lane, pos, len, file, soffs, rate)
  return string.format("<ITEM\nPOSITION %s\nLENGTH %s\nSOFFS %s\nPLAYRATE %s 1 0 -1 0 0.0025\n<SOURCE WAVE\nFILE \"%s\"\n>\n>\nBANDLANE %d\n", pos, len, soffs or 0, rate or 1, file, lane)
end
local src1, src2 = it(1, 10, 8, "C:/m/take1.flac"), it(2, 10, 8, "media/take2.flac")
assert(mirror.comp_from(it(0, 12, 3, "media/take2.flac", 2), "1,0,0", { src1, src2 }) == 2, "a stretch of lane 2's take, in the lane that plays")
assert(mirror.comp_from(it(0, 12, 3, "J:/x/TAKE2.FLAC", 2), "1,0,0", { src1, src2 }) == 2, "the same file by its name (the studio's path or this computer's)")
assert(mirror.comp_from(it(0, 12, 3, "media/take2.flac", 1), "1,0,0", { src1, src2 }) == nil, "off the source's alignment: not a piece of it")
assert(mirror.comp_from(it(0, 16, 3, "media/take2.flac", 6), "1,0,0", { src1, src2 }) == nil, "running past the source's end: not a piece of it")
assert(mirror.comp_from(it(0, 12, 3, "media/take2.flac", 4, 2), "1,0,0", { src1, src2 }) == nil, "another rate: not a piece of it")
assert(mirror.comp_from(it(0, 12, 3, "media/take2.flac", 2), "1,0,0", { src1, src2, it(1, 10, 8, "x/take2.flac") }) == 1, "two lanes hold it: the lowest")
assert(mirror.comp_from(src2, "1,0,0", { src1, it(0, 10, 8, "media/take2.flac") }) == nil, "a source take in a lane that doesn't play names none (a whole-take comp)")
assert(mirror.comp_from(it(0, 10, 8, "media/take2.flac"), "1,0,0", { src1, src2 }) == 2, "and the whole-take piece names its lane")
assert(mirror.comp_from(it(0, 12, 3, "media/take2.flac", 2), nil, { src2 }) == 2, "the track's lanes unknown: still found")
assert(mirror.comp_from(it(0, 12, 3, "media/take2.flac", 2):gsub("BANDLANE 0\n", ""), "1,0,0", { src2 }) == nil, "not on a lane: none")
assert(mirror.comp_from("<ITEM\nPOSITION 12\nLENGTH 3\n<SOURCE MIDI\n>\n>\nBANDLANE 0\n", "1,0,0", { src2 }) == nil, "MIDI: none")

-- ---- 4. the time lapse: a frame's item carries it when its change says, and not otherwise -------------------------------------------------
assert(wh.detail('{"type":"obj","obj":"item","from_lane":2,"state":"<ITEM\\nLENGTH 3\\n>\\nBANDLANE 0\\n"}', { obj = "item", rev = 2 }).from == 2, "read from the change's text")
assert(wh.detail('{"type":"obj","obj":"item","state":"<ITEM\\nLENGTH 3\\n>\\nBANDLANE 0\\n"}', { obj = "item", rev = 2 }).from == nil, "an older change says nothing")
local evs = {
  { type = "obj", obj = "item", oid = "I-1", rev = 1, user = "Bee", time = "2026-11-21T10:00:00Z", track = "T-1", name = "Vox", pos = 12, id = "e1" },
  { type = "obj", obj = "item", oid = "I-2", rev = 1, user = "Bee", time = "2026-11-21T10:00:05Z", track = "T-1", name = "Vox", pos = 20, id = "e2" },
}
local d = { [evs[1]] = { lane = 0, len = 3, from = 2 }, [evs[2]] = { lane = 0, len = 2 } }
local h = wh.build(evs, function(x) return d[x] end, { places = { ["T-1"] = 0 } })
local rows = {}
for _, f in ipairs(h.frames) do for _, a in ipairs(f.i or {}) do rows[a[3]] = a end end
assert(rows[12] and rows[12][7] == 0 and rows[12][8] == 2 and rows[20] and rows[20][8] == nil, "a frame's item row: lane, then its source lane only when known")
local f = assert(io.open("lib/webui/history.js", "rb")); local hj = f:read("a"); f:close()
assert(hj:find("const src = (a) => (Number.isInteger(a[7]) && a[7] >= 0 ? a[7] : -1);", 1, true) and hj:find("if (src(a) >= 0) return true;", 1, true)
  and hj:find("'from lane ' : 'L') + (src(a) + 1)", 1, true), "history.js: a piece with a source lane is a comp piece, labelled with the lane (1-based)")
print("ok rt-p1b")
