-- rt-setup (findings 2026-11-27, small change: "Set the talk mic to the correct input (possibly another device), which could avoid switching
-- when armed"). Live audio's Talk is the input picked as the talk mic; in Auto, when it's an armed track's input, the mic goes once, as part of
-- that track's Play, so talk "switches" into the track as you arm it. The picker (Settings > Studio "Talk mic", Chat > Call) now names the
-- tracks recording from each input, warns when the talk mic is an armed track's, and offers the first input no track records from.
-- (A second audio device needs the extension: docs/rt/rt-setup.md.)
package.path = "lib/?.lua;" .. package.path
local ext = {}
local tracks = {
  { name = "Guitar", inp = 0, arm = 1 }, { name = "Vox", inp = 2, arm = 0 }, { name = "Keys", inp = 1024 | 4, arm = 1 }, { name = "Synth", inp = 4096 | 63, arm = 1 },
}
reaper = setmetatable({
  time_precise = function() return 0 end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end, SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetNumAudioInputs = function() return 8 end, GetInputChannelName = function(i) return "Input " .. (i + 1) end,
  EnumProjects = function() return "P", "" end, CountTracks = function() return #tracks end, GetTrack = function(_, i) return tracks[i + 1] end,
  GetTrackName = function(t) return true, t.name end,
  GetMediaTrackInfo_Value = function(t, k) return k == "I_RECINPUT" and t.inp or k == "I_RECARM" and t.arm or 0 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.track_ext = function() return "" end
local la = require("liveaudio")
local list = {}
for _, t in ipairs(tracks) do list[#list + 1] = { name = t.name, inp = t.inp, armed = t.arm == 1 } end
-- the talk mic on the guitar's input: it folds into Guitar's Play while armed; Input 2 is free
local users, clash, free = la.talk_advice(0, 1, 8, list)
assert(users[0] == "Guitar (armed)" and users[2] == "Vox" and users[4] == "Keys (armed)" and users[5] == "Keys (armed)" and users[1] == nil, "who records from each input")
assert(not users[63], "a MIDI input isn't an audio input")
assert(clash == "Guitar" and free == 1, "talk mic folds into Guitar; Input 2 (index 1) is free")
-- on a free input: no clash, and the next free one offered is past it
users, clash, free = la.talk_advice(1, 1, 8, list)
assert(clash == nil and free == 3, "no clash on Input 2")
-- an unarmed track on the talk mic is no clash (nothing folds), but the input still says who uses it
users, clash = la.talk_advice(2, 1, 8, list)
assert(clash == nil and users[2] == "Vox", "Vox isn't armed: no fold")
-- a stereo talk mic with no free pair left
users, clash, free = la.talk_advice(6, 2, 8, list)
assert(clash == nil and free == nil, "no free stereo pair outside the talk mic")
-- the picker: the warning, and the button that moves talk to the free input
local seen, click = {}, nil
local ImGui = setmetatable({
  BeginCombo = function() return true end, Selectable = function(_, s) seen[#seen + 1] = s; return false end,
  SmallButton = function(_, s) seen[#seen + 1] = s; return s:gsub("##.*$", "") == click end,
  TextColored = function(_, _, s) seen[#seen + 1] = s end, TextDisabled = function(_, s) seen[#seen + 1] = s end,
}, { __index = function() return function() end end })
la.input_picker({}, ImGui, "Talk mic##t", 200)
local text = table.concat(seen, "\n")
assert(text:find("Input 1  ·  Guitar (armed)##lai0", 1, true) and text:find("Input 3  ·  Vox##lai2", 1, true), "each input names its tracks")
assert(text:find("Your talk mic is what Guitar records from", 1, true), "the fold is said")
seen, click = {}, "Talk on Input 2 instead"
assert(la.input_picker({}, ImGui, "Talk mic##t", 200) and ext["BandSync/live audio input"] == "1", "one click: talk on the free input")
seen, click = {}, nil
la.input_picker({}, ImGui, "Talk mic##t", 200)
assert(not table.concat(seen, "\n"):find("Your talk mic is what", 1, true), "and the warning goes")
print("ok")
