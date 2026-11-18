-- 0.59.27 (lupa or Lua 5.4, from the repo root): the call apart from the playing. On real SonoBus 1.7.2 saved states (tests/fixtures):
-- this computer sends Music (stereo, input 1) and Talk (mono, input 3) as two groups; each bandmate's talk lands on the call's pair while
-- their playing stays on their own; done twice, nothing changes; and the live mix plays the call at its own level.
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
reaper.GetOS = reaper.GetOS or function() return "Win64" end
reaper.GetExtState = reaper.GetExtState or function() return "" end
for _, m in ipairs({ "band", "sonobus", "hear" }) do package.loaded[m] = nil end
local sonobus, hear = require("sonobus"), require("hear")
local function load(f) local h = assert(io.open(f, "rb")); local s = h:read("a"); h:close(); return sonobus.b64encode(s) end
local state, cache = load("tests/fixtures/sonobus_1.7.2_state.bin"), load("tests/fixtures/sonobus_1.7.2_cache.bin")

assert(hear.TALK == 14, "the call is the last pair: channels 15-16")
local outs = hear.order({ "A", "B", "C", "D", "E", "F", "G", "Me" }, "Me")
local n = 0
for _, start in pairs(outs) do n = n + 1; assert(start >= 2 and start <= 12, "a bandmate's pair is never the call's: " .. start) end
assert(n == 6, "six bandmates with pairs of their own: " .. n)

-- what this computer sends
assert(not sonobus.input_split_ok(state), "SonoBus's own: one group")
local split = assert(sonobus.set_input_split(state))
assert(sonobus.input_split_ok(split), "Music and Talk")
assert(sonobus.set_input_split(split) == split, "split twice: the same")
local raw = sonobus.b64decode(split)
assert(raw:find("name\0\7\5Music\0", 1, true) or raw:find("Music\0", 1, true), "named Music")
assert(raw:find("Talk\0", 1, true), "and Talk")
assert(raw:find("CompressorState", 1, true), "each group kept SonoBus's own processing settings")

-- each bandmate here
local mine = { James = 4 }
local routed = assert(sonobus.set_outputs(cache, mine))
assert(sonobus.output_of(routed, "James") == 4, "James's playing on his pair")
assert(not sonobus.talk_ok(routed, mine, hear.TALK), "his talk isn't apart yet")
local talked = assert(sonobus.set_talk(routed, mine, hear.TALK))
assert(sonobus.talk_ok(talked, mine, hear.TALK), "his talk on the call's pair")
assert(sonobus.output_of(talked, "James") == 4, "and his playing still on his own")
assert(sonobus.set_talk(talked, mine, hear.TALK) == talked, "twice: the same")
assert(sonobus.talk_ok(talked, {}, hear.TALK), "nobody to route: fine")
local d = sonobus.b64decode(talked)
-- (a property is its name, its size as a length byte and the size, then the value: size 1 is "\1\1")
assert(d:find("modifiedChanGroups\0\1\1\2", 1, true), "marked as set by hand, so SonoBus keeps it when he joins")
assert(d:find("numChanGroups\0\1\5\1" .. string.pack("<i4", 2), 1, true), "two groups for him")

-- the live mix: the call at its own level, everyone's playing at theirs
assert(hear.JSFX:find("slider9:1<0,2,0.01>The call", 1, true) and hear.JSFX:find("slider11:1<0,2,0.01>Their playing", 1, true), "the two levels")
assert(hear.JSFX:find("slider11 * (slider2 * spl2", 1, true) and hear.JSFX:find(") + slider9 * spl16;", 1, true), "playing times its level, the call apart")
print("ok")
