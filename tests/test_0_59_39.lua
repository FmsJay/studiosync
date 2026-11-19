-- 0.59.39: automation that differs only in its points' times is REAPER following a tempo change; a drawn point isn't (mirror.env_sans_tempo).
package.path = "lib/?.lua;" .. package.path
local mirror = require("mirror")
local env = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.5 0\n>"
local moved = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2.4 0.5 0\n>"
local drawn = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.5 0\nPT 3 0.25 0\n>"
local reshaped = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.7 0\n>"
assert(mirror.env_sans_tempo(env) == mirror.env_sans_tempo(moved), "only the times moved: the tempo")
assert(mirror.env_sans_tempo(env) ~= mirror.env_sans_tempo(drawn), "a point drawn: an edit")
assert(mirror.env_sans_tempo(env) ~= mirror.env_sans_tempo(reshaped), "a value changed: an edit")
local ai = "<PARMENV x\nPOOLEDENVINST 1 4 2 0 1 0 0 0 0 0 0 0\n>"
local ai_moved = "<PARMENV x\nPOOLEDENVINST 1 4.8 2.4 0 1 0 0 0 0 0 0 0\n>"
assert(mirror.env_sans_tempo(ai) == mirror.env_sans_tempo(ai_moved), "an automation item moved and stretched: the tempo")
print("ok")
