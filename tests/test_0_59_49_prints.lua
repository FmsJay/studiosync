-- 0.59.49 (lupa or Lua 5.4, from the repo root): prints only where a plug-in is missing (MIDI as audio, sample players excepted), chained
-- prints' pure parts (the chain cut into runs, one computer per run, the hand-over cap, linked knobs), the master's Health line's data, the
-- stage files trimmed with their print, and the plug-in finder's switch on the master.
package.path = "lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "plugins", "prints", "trim", "fxpick" }) do package.loaded[m] = nil end
package.loaded.band = { SECTION = "BandSync" }
local clock = 1000
-- fake tracks: { fx = { { name, file, off } } }
local function track(...) local t = { fx = {} }; for i, f in ipairs({ ... }) do t.fx[i] = type(f) == "table" and f or { name = f } end; return t end
local MASTER = track()
reaper = setmetatable({
  GetExtState = function() return "" end,
  GetOS = function() return "Win64" end,
  time_precise = function() return clock end,
  ValidatePtr = function() return true end,
  TrackFX_GetCount = function(tr) return #tr.fx end,
  TrackFX_GetEnabled = function(tr, i) return not tr.fx[i + 1].off end,
  TrackFX_GetFXName = function(tr, i) return true, tr.fx[i + 1].name end,
  TrackFX_GetNamedConfigParm = function(tr, i, k)
    local f = tr.fx[i + 1]
    if k == "fx_name" then return true, f.name end
    if k == "FILE0" then return true, f.file or "" end
    return false, ""
  end,
  GetMasterTrack = function() return MASTER end,
}, { __index = function() return function() end end })
local plugins = require("plugins")
local prints = require("prints")

-- ---- prints only where a plug-in is missing (MIDI as audio) --------------------------------------------------------------------------
local everyone = { ["surge xt (surge synth team)"] = true, ["kontakt 7 (native instruments)"] = true, ["reasamplomatic5000 (cockos)"] = true, ["reaeq (cockos)"] = true }
plugins.band = function() return everyone, { "James", "Mac" }, { win = true, mac = true } end
local cfg = { root = "R", user = "James" }
local surge, serum = track("VST3i: Surge XT (Surge Synth Team)", "VST: ReaEQ (Cockos)"), track("VST3i: Serum (Xfer Records)")
assert(prints.midi_prints(surge, nil, cfg) == false, "everyone has the whole chain: a MIDI part doesn't print any more")
assert(prints.midi_prints(serum, nil, cfg) == true, "someone lacks the instrument: it prints, as an audio part would")
assert(prints.midi_prints(track("VST3i: Kontakt 7 (Native Instruments)"), nil, cfg) == true, "Kontakt, though everyone has it: what it plays can't be seen, so it prints")
assert(prints.midi_prints(track({ name = "VSTi: ReaSamplOmatic5000 (Cockos)" }), nil, cfg) == false, "ReaSamplOmatic5000 with no sample: nothing to miss")
assert(prints.midi_prints(track({ name = "VSTi: ReaSamplOmatic5000 (Cockos)", file = "C:/kick.wav" }), nil, cfg) == true, "with a sample: the file may not be everywhere")
assert(prints.midi_prints(track(), surge, cfg) == false, "a routed part playing an instrument everyone has: no print")
assert(prints.midi_prints(track(), serum, cfg) == true, "a routed part: the instrument track's chain counts too")
plugins.band = function() return everyone, { "James" }, { win = true } end
clock = clock + 120 -- (prints.lacking reads the lists once a minute)
assert(prints.midi_prints(serum, nil, cfg) == false, "alone in the studio: nobody to print for")
-- the sample players, matched like plugins.key, at the start of a word
assert(prints.sampler_name("VSTi: sforzando (Plogue)") and prints.sampler_name("VST3i: Superior Drummer 3 (Toontrack)"), "sforzando, Superior Drummer")
assert(prints.sampler_name("VST3i: BFD3 (inMusic)") and not prints.sampler_name("VST3: XBFDX (Nobody)"), "BFD by word, not inside one")
assert(prints.sampler_name("VST3i: LABS (Spitfire Audio) (2->8ch)") and prints.sampler_name("AUi: Decent Sampler (Decent Samples)"), "LABS, Decent Sampler")
assert(not prints.sampler_name("VST3i: Surge XT (Surge Synth Team)") and not prints.sampler_name("VST: ReaEQ (Cockos)"), "a synth or an EQ isn't one")

-- ---- chained prints: the chain cut into runs ----------------------------------------------------------------------------------------
local function set(...) local s = {}; for _, u in ipairs({ ... }) do s[u] = true end; return s end
-- the design's example: the laptop has the EQ, the desktop the amp after it
local runs = prints.split({ set("Laptop"), set("Desktop") }, 0)
assert(#runs == 2 and runs[1].from == 1 and runs[1].to == 1 and runs[2].from == 2 and runs[1].who.Laptop and runs[2].who.Desktop, "EQ on the laptop, then the amp on the desktop: two runs")
assert(#prints.split({ set("A", "B"), set("A") }, 0) == 1, "one computer has it all: one run, no hand-over")
runs = prints.split({ set("A", "B"), set("B"), set("A"), set("A", "C"), set("C") }, 0)
assert(#runs == 3 and runs[1].to == 2 and runs[2].from == 3 and runs[2].to == 4 and runs[3].from == 5, "greedy runs, fewest for the order: 1-2, 3-4, 5")
assert(runs[1].who.B and not runs[1].who.A and runs[2].who.A and not runs[2].who.C, "each run's computers have every plug-in in it")
local none, at = prints.split({ set("A"), {}, set("B") }, 0)
assert(none == nil and at == 2, "nobody has the second plug-in: no chain, and it says which")
none, at = prints.split({ set("A"), set("B"), set("B") }, 2)
assert(none == nil and at == 2, "a MIDI part's instrument and what comes before it can't be split (notes don't go through a file)")
assert(#prints.split({ set("A", "B"), set("B"), set("C") }, 2) == 2, "past the instrument it splits as audio")

-- a computer per run, the same on every computer
local counts = { A = 3, B = 2, C = 2 }
local function users(w) local o = {}; for k, x in ipairs(w) do o[k] = x.user .. (x.here and "" or "?") end; return table.concat(o, " ") end
local r2 = { { who = set("A", "B") }, { who = set("B", "C") } }
assert(users(prints.assign(r2, "B", set("A", "B", "C"), counts)) == "B B", "whoever changed the part, when here and able")
assert(users(prints.assign(r2, nil, set("A", "B", "C"), counts)) == "A B", "else whoever here has most of the chain, then by name (B before C)")
assert(users(prints.assign(r2, "C", set("A", "B"), counts)) == "A B", "the author away: someone here")
assert(users(prints.assign({ { who = set("C", "D") } }, nil, set("A"), { C = 1, D = 1 })) == "C?", "nobody here has it: the first by name, and it waits for them")
assert(users(prints.assign({ { who = set("C", "D") } }, "D", set("A"), { C = 1, D = 1 })) == "D?", "nobody here: whoever changed it, if they have it")
-- the cap
assert(prints.hops_cap(nil) == 2 and prints.hops_cap(0) == 0 and prints.hops_cap(3) == 3 and prints.hops_cap("1") == 1, "nil is 2; 0 to 3 as set")
assert(prints.hops_cap("any") == math.huge and prints.hops_cap(7) == 2 and prints.hops_cap("lots") == 2 and prints.hops_cap(1.5) == 2, "no cap, and anything else is the default")
-- linked knobs keep a part out
assert(prints.linked("<VST \"x\"\n<PROGRAMENV 3 0\nPARAMBASE 0\nPLINK 1 0:-1 5 0\n>\n>"), "a knob linked to another plug-in's")
assert(not prints.linked("<PROGRAMENV 3 0\nPLINK 1 0:-1 -1 0\n>"), "a link section with no knob: none")
assert(not prints.linked("<PROGRAMENV 3 1\nPLINK 1 0:-1 5 0\n>"), "its modulation switched off: none")
assert(not prints.linked(nil) and not prints.linked("<VST \"x\"\n>"), "no modulation at all")

-- ---- the master's Health line: who lacks which plug-in --------------------------------------------------------------------------------
local lists = { { user = "James", os = "Win64", names = { "pro-l 2 (fabfilter)", "reaeq (cockos)", "ozone 11 (izotope)" } },
  { user = "Mac", os = "OSX64", names = { "reaeq (cockos)", "ozone 11 (izotope)" } },
  { user = "Laptop", os = "Win64", names = { "reaeq (cockos)" } } }
local lack = prints.who_lacks({ "VST3: Pro-L 2 (FabFilter)", "VST: ReaEQ (Cockos)", "AU: Ozone 11 (iZotope)" }, lists)
assert(#lack == 2 and lack[1].fx == "Pro-L 2 (FabFilter)" and table.concat(lack[1].users, ",") == "Laptop,Mac", "Pro-L: the Mac and the laptop lack it")
assert(lack[2].fx == "Ozone 11 (iZotope)" and table.concat(lack[2].users, ",") == "James,Laptop", "an AU loads only on a Mac: the PC that has Ozone's VST3 still lacks this one")
assert(#prints.who_lacks({ "VST3: Pro-L 2 (FabFilter)" }, { lists[1] }) == 0, "one list: nothing to compare yet, as prints.lacking")
MASTER.fx = { { name = "VST3: Pro-L 2 (FabFilter)" }, { name = "VST: ReaEQ (Cockos)" }, { name = "VST3: Ozone 11 (iZotope)", off = true } }
plugins.lists = function() return lists end
lack = prints.master_lacks(0, cfg)
assert(#lack == 1 and lack[1].fx == "Pro-L 2 (FabFilter)", "the master: Pro-L, which two lack; a bypassed plug-in plays nowhere, so isn't named")

-- ---- stage files go with their print -------------------------------------------------------------------------------------------------
local trim = require("trim")
local files = { "print-I-a-1-0badf00d-James.flac", "stage-I-a-1-0badf00d-1-12345678-Mac.flac", "stage-I-a-1-0badf00d-1-12345678-Mac.opus",
  "stage-I-a-1-feedface-1-12345678-Mac.flac", "stage-I-a-12-0badf00d-1-12345678-Mac.flac" }
local st = trim.stage_files(files, { ["print-I-a-1-0badf00d-James"] = true })
assert(#st == 2 and st[1]:match("%.flac$") and st[2]:match("%.opus$"), "the print's own stages, both files; not another version's, nor another item's: " .. table.concat(st, " "))

-- ---- the plug-in finder on the master ------------------------------------------------------------------------------------------------
local fxpick = require("fxpick")
assert(fxpick.only_for(true, false, false) == true, "the master becomes the target: only what everyone has, on")
assert(fxpick.only_for(true, true, false) == false, "switched off while the master stays selected: off")
assert(fxpick.only_for(false, true, false) == false and fxpick.only_for(false, false, true) == true, "another track: as it was")
print("ok")
