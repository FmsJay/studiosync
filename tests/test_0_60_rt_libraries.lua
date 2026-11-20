-- rt (lupa or Lua 5.4, from the repo root): who has which library (lib/libraries.lua: what a sampler's state says it plays, SFZ and Decent
-- Sampler instruments followed, opaque ones left alone, the print decision, the published report) and presets and small content
-- (lib/content.lua: kinds, never a program, the size cap, paid libraries' folders, presets' places on each system), and the print hook.
package.path = "lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "libraries", "content", "fxfiles", "plugins", "prints", "mirror", "direct" }) do package.loaded[m] = nil end
package.loaded.band = { SECTION = "BandSync", WIN = true }
package.loaded.mirror = { hash = function(s) return "h:" .. s end }
reaper = setmetatable({ time_precise = function() return 1000 end, GetOS = function() return "Win64" end },
  { __index = function() return function() end end })
local libraries, content = require("libraries"), require("content")

-- ---- what a sampler plays ------------------------------------------------------------------------------------------------------------
local sfz = table.concat({
  "// a kit",
  "<control> default_path=Samples\\Kit A\\",
  "<region> sample=kick 1.wav lokey=36 hikey=36",
  "<region> lokey=38 sample=snare.wav",
  "<region> sample=*sine",
  "/* <region> sample=old.wav */",
  "<region> sample=C:\\Shared\\clap.wav" }, "\n")
local got = libraries.sfz_samples(sfz, "D:/Kits")
assert(#got == 3, "three samples: " .. table.concat(got, " | "))
assert(got[1] == "D:/Kits/Samples/Kit A/kick 1.wav", "default_path and a name with a space: " .. got[1])
assert(got[2] == "D:/Kits/Samples/Kit A/snare.wav", "an opcode before sample= on the line: " .. got[2])
assert(got[3] == "C:/Shared/clap.wav", "an absolute sample stays itself: " .. got[3])
assert(libraries.sfz_samples("#include \"other.sfz\"\n<region> sample=a.wav", "D:/") == nil, "an #include isn't followed: opaque")
assert(libraries.sfz_samples("#define $KIT kit1\n<region> sample=$KIT/a.wav", "D:/") == nil, "a $variable isn't followed: opaque")
local ds = libraries.dspreset_samples('<DecentSampler><groups><group><sample path="Samples/A&amp;B.wav" rootNote="60"/>' ..
  '<sample  path="/Users/bo/Lib/c.flac"/></group></groups></DecentSampler>', "/Users/bo/DS")
assert(ds[1] == "/Users/bo/DS/Samples/A&B.wav" and ds[2] == "/Users/bo/Lib/c.flac", "Decent Sampler paths: " .. table.concat(ds, " | "))

local files = { ["D:/Kits/kit.sfz"] = sfz }
local function read(p) return files[p] end
local s = libraries.sounds({ "D:/Kits/kit.sfz", "D:/One shots/808.wav" }, read)
assert(s and #s == 5 and s[1] == "D:/Kits/kit.sfz" and s[5] == "D:/One shots/808.wav", "an sfz with its samples, and a sample: " .. table.concat(s or {}, " | "))
local missing = libraries.sounds({ "E:/Gone/kit.sfz" }, read)
assert(missing and #missing == 1, "an sfz not on this computer: the instrument file alone (lacked here)")
assert(libraries.sounds({ "C:/Users/Bo/Documents/Native Instruments/My Piano.nki" }, read) == nil, "Kontakt's .nki: opaque, never guessed")
assert(libraries.sounds({ "D:/a.wav", "D:/patch.json" }, read) == nil, "any file of a vendor's own kind makes the whole sampler opaque")
assert(libraries.sounds({}, read) == nil, "a state naming no file: opaque")

-- ---- the decision ---------------------------------------------------------------------------------------------------------------------
local members = { "James", "Bo", "Ann" }
local haves = { Bo = { a = true, b = true }, Ann = { a = true, b = true } }
assert(libraries.decide({ "a", "b" }, members, haves, "James") == false, "everyone else has both sounds: no print")
haves.Ann.b = nil
assert(libraries.decide({ "a", "b" }, members, haves, "James") == true, "Ann lacks one: a print")
assert(libraries.decide({ "a" }, { "James", "Cy" }, haves, "James") == true, "Cy hasn't said yet: lacks it, a print as before")
assert(libraries.decide(nil, members, haves, "James") == nil, "opaque: can't tell, prints.sample_player decides")
assert(libraries.decide({ "a" }, { "James" }, {}, "James") == false, "alone in the studio: nobody to print for")
local lacks = libraries.who_lacks({ { id = "a", what = "kick.wav", track = "Drums" }, { id = "b", what = "amp.nam", track = "Gtr", kind = "file" },
  { id = "b", what = "amp.nam", track = "Gtr 2" } }, members, haves, "James")
assert(#lacks == 1 and lacks[1].what == "amp.nam" and lacks[1].users[1] == "Ann", "Health: Ann lacks amp.nam, once")

-- ---- the report -------------------------------------------------------------------------------------------------------------------------
local have = libraries.merge({ "old1", "gone" }, { { id = "new", here = true }, { id = "gone", here = false }, { id = "new", here = false } })
assert(table.concat(have, ",") == "new,old1", "a sound found joins, one no longer here leaves, others stay: " .. table.concat(have, ","))
libraries.KEEP = 2
assert(#libraries.merge({ "x", "y", "z" }, { { id = "a", here = true } }) == 2, "at most KEEP")
libraries.KEEP = 20000
assert(libraries.id("C:\\Users\\Bo\\Kit\\kick.wav") == "h:c:/users/bo/kit/kick.wav", "an id hashes the path (lower case, \"/\"), never the path itself")

-- ---- small content: kinds, never programs, size, paid libraries ----------------------------------------------------------------------
assert(content.allowed("C:/Users/Bo/Documents/NAM/plexi.nam", 300000), "a NAM capture")
assert(content.allowed("D:/IRs/Room.wav", 2e6), "an impulse response")
assert(content.allowed("C:/Users/Bo/Documents/VST3 Presets/U-he/Diva/Lead.vstpreset", 9000), "a preset")
assert(content.kind("D:/x/Lead.vstpreset") == "preset" and content.kind("D:/x/ir.wav") == "file", "kinds")
for _, bad in ipairs({ "D:/Plugins/Diva.dll", "D:/Plugins/Diva.vst3", "/Library/Audio/Plug-Ins/Components/Diva.component", "/home/bo/.vst/x.so",
    "D:/tools/setup.exe", "D:/x/run.lua", "D:/x/patch.nki", "D:/x/notes.ini" }) do
  assert(not content.allowed(bad, 10), "never: " .. bad)
end
assert(not content.allowed("D:/IRs/Huge hall.wav", content.MAX + 1), "over the size cap")
assert(not content.allowed("D:/IRs/Room.wav", nil), "a size not known")
for _, paid in ipairs({ "D:/Native Instruments/Kontakt Factory Library/Samples/a.wav", "E:/Toontrack/Superior3/Sounds/kick.wav",
    "D:/Libraries/Spitfire Audio - BBC SO/Patches/x.json", "C:/Program Files/Common Files/Plugin/ir.wav", "C:/Users/Bo/Documents/Splice/Samples/loop.wav",
    "/Applications/Thing.app/Contents/Resources/ir.wav" }) do
  assert(content.paid(paid) and not content.allowed(paid, 10), "a paid library's or a program's folder: " .. paid)
end
assert(not content.paid("D:/Samples/Native Instruments.wav"), "a file's own name doesn't count, only its folders")
assert(not content.paid("D:/My Splicer/ir.wav") and not content.paid("D:/Battery acid/ir.wav"), "a whole word, not part of one")

-- ---- presets: where each system keeps them --------------------------------------------------------------------------------------------
assert(content.preset_tail("C:\\Users\\James\\Documents\\VST3 Presets\\u-he\\Diva\\Bass\\Fat.vstpreset") == "u-he/Diva/Bass/Fat.vstpreset", "Windows, with a sub-folder")
assert(content.preset_tail("/Users/bo/Library/Audio/Presets/Apple/AUSampler/Keys.aupreset") == "Apple/AUSampler/Keys.aupreset", "a Mac's AU preset")
assert(content.preset_tail("/home/ann/.vst3/presets/Surge Synth Team/Surge XT/Pad.vstpreset") == "Surge Synth Team/Surge XT/Pad.vstpreset", "Linux")
assert(content.preset_tail("C:/ProgramData/VST3 Presets/Vendor/Plug/Factory.vstpreset") == nil, "factory presets in ProgramData: the vendor's, never sent")
assert(content.preset_tail("/Library/Audio/Presets/Vendor/Plug/Factory.aupreset") == nil, "a Mac's system-wide presets: the vendor's")
assert(content.preset_tail("C:/Users/J/Documents/VST3 Presets/V/../../../evil.vstpreset") == nil, "nothing climbing out")
assert(content.preset_tail("C:/Users/J/Documents/VST3 Presets/V/.hidden/x.vstpreset") == nil, "nothing hidden")
assert(content.preset_tail("C:/Users/J/Documents/VST3 Presets/Lone.vstpreset") == nil, "not in <vendor>/<plug-in>/")
assert(content.preset_tail("C:/Users/J/Documents/VST3 Presets/V/P/x.fxp") == nil, "an .fxp has no standard folder: where the plug-in looks only")
local function none() return false end
assert(content.preset_dir("vstpreset", "win", "C:\\Users\\Bo", none) == "C:/Users/Bo/Documents/VST3 Presets", "Windows' VST3 presets")
assert(content.preset_dir("vstpreset", "win", "C:/Users/Bo", function(d) return d:find("OneDrive", 1, true) ~= nil end) == "C:/Users/Bo/OneDrive/Documents/VST3 Presets",
  "OneDrive's Documents when only it has the folder")
assert(content.preset_dir("vstpreset", "mac", "/Users/bo/", none) == "/Users/bo/Library/Audio/Presets", "a Mac's")
assert(content.preset_dir("vstpreset", "linux", "/home/ann", none) == "/home/ann/.vst3/presets", "Linux's")
assert(content.preset_dir("aupreset", "win", "C:/Users/Bo", none) == nil and content.preset_dir("aupreset", "mac", "/Users/bo", none) == "/Users/bo/Library/Audio/Presets", "an AU preset only on a Mac")
assert(content.preset_dir("fxp", "win", "C:/Users/Bo", none) == nil, "no standard place for an .fxp")
assert(content.root_of("J:/Studios/Chilio/My Song/rooms/main/media") == "J:/Studios/Chilio", "the studio from a room's media folder")
assert(content.root_of("J:/elsewhere/media") == nil, "not a room's media folder")

-- ---- the receiver: a bandmate's event can't place a preset outside this computer's preset folder ----------------------------------------
local copied = {}
reaper.file_exists = function(p) return p:find("plugin files", 1, true) ~= nil end
package.loaded.band.size = function() return 100 end
package.loaded.band.copy_atomic = function(src, dst) copied[#copied + 1] = dst end
package.loaded.band.log = function() end
content.my_preset_dir = function(e) return e == "vstpreset" and "C:/Users/Bo/Documents/VST3 Presets" or nil end
local done = content.fetch({ { path = "C:/Users/James/Documents/VST3 Presets/u-he/Diva/Fat.vstpreset", copy = "plugin files/1-Fat.vstpreset" },
  { path = "C:/Users/James/Documents/VST3 Presets/u-he/Diva/Evil.vstpreset", copy = "plugin files/../../x.vstpreset" },
  { path = "C:/Users/James/IRs/room.wav", copy = "plugin files/2-room.wav" } }, "J:/S/Song/rooms/main/media")
assert(done["C:/Users/James/Documents/VST3 Presets/u-he/Diva/Fat.vstpreset"] and not done["C:/Users/James/IRs/room.wav"], "presets handled here, the rest by fxfiles")
assert(#copied == 1 and copied[1] == "C:/Users/Bo/Documents/VST3 Presets/u-he/Diva/Fat.vstpreset",
  "into this computer's own preset folder, never the bandmate's home; a copy from outside plugin files/ refused: " .. table.concat(copied, " | "))

-- ---- the print hook ------------------------------------------------------------------------------------------------------------------
package.loaded.prints = nil
local prints = require("prints")
local rs5k = { fx = { { name = "VSTi: ReaSamplOmatic5000 (Cockos)", file = "C:/kick.wav" } } }
prints.lacking = function() return false end
package.loaded.libraries = { lacks = function() return false end }
assert(prints.midi_prints(rs5k, nil, {}) == false, "RS5k whose sample everyone has: no print")
package.loaded.libraries = { lacks = function() return true end }
assert(prints.midi_prints(rs5k, nil, {}) == true, "someone lacks the sample: a print")
package.loaded.libraries = { lacks = function() return nil end }
prints.sample_player = function() return true end
assert(prints.midi_prints(rs5k, nil, {}) == true, "opaque: the sample player rule, as before")
package.loaded.libraries = { lacks = function() error("broken") end }
assert(prints.midi_prints(rs5k, nil, {}) == true, "an error in the look: as before")
package.loaded.libraries = nil

print("ok")
