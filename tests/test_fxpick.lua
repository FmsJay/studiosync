-- 0.59.24 (lupa or Lua 5.4, from the repo root): the plug-in finder's list, categories and filter.
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
reaper.GetOS = reaper.GetOS or function() return "Win64" end
reaper.GetExtState = reaper.GetExtState or function() return "" end
for _, m in ipairs({ "band", "plugins", "fxpick" }) do package.loaded[m] = nil end
local fxpick = require("fxpick")
local tags = "[developer]\nreaeq.dll=Cockos\n[category]\nreaeq.dll=EQ|StudioSync\nSurge XT.vst3=StudioSync\nFabFilter_Pro_C_2.vst3=Dynamics\n"
local installed = {
  { name = "VST: ReaEQ (Cockos)", ident = "reaeq.dll" },
  { name = "VST3i: Surge XT (Surge Synth Team)", ident = "C:\\Program Files\\Common Files\\VST3\\Surge XT.vst3" },
  { name = "CLAPi: Surge XT (Surge Synth Team)", ident = "org.surge-synth-team.surge-xt" },
  { name = "VST3: Pro-C 2 (FabFilter)", ident = "C:\\Program Files\\Common Files\\VST3\\FabFilter_Pro_C_2.vst3" },
  { name = "JS: Saike Tanh Saturation", ident = "Saike/tanh.jsfx" },
}
local everyone = { ["reaeq (cockos)"] = true, ["surge xt (surge synth team)"] = true }
local list = fxpick.list(installed, tags, everyone)
local by = {}
for _, it in ipairs(list) do by[it.label] = it end
assert(#list == 4, "Surge XT once, in its best format: " .. #list)
assert(by["Surge XT (Surge Synth Team)"].kind == "VST3i", "VST3 before CLAP")
assert(by["Surge XT (Surge Synth Team)"].cats[1] == "Instruments", "an instrument is under Instruments")
assert(by["ReaEQ (Cockos)"].cats[1] == "EQ", "REAPER's own category")
assert(by["Pro-C 2 (FabFilter)"].cats[1] == "Dynamics" and not by["Pro-C 2 (FabFilter)"].everyone, "Dynamics, and not everyone has it")
assert(by["Saike Tanh Saturation"].everyone and by["Saike Tanh Saturation"].cats[1] == "JSFX", "JSFX: everyone has them")
for _, it in ipairs(list) do for _, c in ipairs(it.cats) do assert(c ~= "StudioSync", "StudioSync's own tag isn't a category here") end end
assert(fxpick.matches(by["ReaEQ (Cockos)"], "", "EQ", true), "EQ, everyone has it")
assert(not fxpick.matches(by["Pro-C 2 (FabFilter)"], "", "All", true), "only what everyone has: Pro-C hidden")
assert(fxpick.matches(by["Pro-C 2 (FabFilter)"], "pro-c", "All", false), "all of mine, found by name")
assert(fxpick.matches(by["Pro-C 2 (FabFilter)"], "dynam", "All", false), "found by its category's name too")
assert(not fxpick.matches(by["Surge XT (Surge Synth Team)"], "", "EQ", false), "not in EQ")
print("ok")
