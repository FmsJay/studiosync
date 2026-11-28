-- 0.59.39: automation that differs only in its points' times as REAPER moves them for a tempo change is the same automation; a drawn point
-- isn't. (mirror.env_sans_tempo until rt-sync2f; now automation travels in beats, lib/beats.lua, and the move reads the same there.)
package.path = "lib/?.lua;" .. package.path
local beats = require("beats")
local at120 = function(t) return t * 2 end -- (quarter notes at 120 bpm)
local at100 = function(t) return t * 100 / 60 end -- (and at 100: REAPER moved every point by 1.2)
local env = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.5 0\n>"
local moved = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2.4 0.5 0\n>"
local drawn = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.5 0\nPT 3 0.25 0\n>"
local reshaped = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.7 0\n>"
assert(beats.env(env, 1, at120) == beats.env(moved, 1, at100), "only the times moved, as the tempo moved them: the same in beats")
assert(beats.env(env, 1, at120) ~= beats.env(drawn, 1, at100), "a point drawn: an edit")
assert(beats.env(env, 1, at120) ~= beats.env(reshaped, 1, at100), "a value changed: an edit")
local ai = "<PARMENV x\nPOOLEDENVINST 1 4 2 0 1 0 0 0 0 0 0 0\n>"
local ai_moved = "<PARMENV x\nPOOLEDENVINST 1 4.8 2.4 0 1 0 0 0 0 0 0 0\n>"
assert(beats.env(ai, 1, at120) == beats.env(ai_moved, 1, at100), "an automation item moved and stretched: the same in beats")
assert(beats.env(env, 0, at120) == env, "a project in time: its seconds as they are")
print("ok")
