-- 0.58.98 (lupa or Lua 5.4, from the repo root): an invitation for someone new, someone with StudioSync, or both; the new item looks;
-- the call mic's setting.
package.path = "lib/?.lua;" .. package.path
local ext = {}
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  time_precise = function() return 0 end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
}, { __index = function() return function() end end })
for _, m in ipairs({ "band", "services", "colours", "live" }) do package.loaded[m] = nil end
local services = require("services")
local info = { id = "smiley", name = "Smiley Studios" }
local both = services.invite_text("AAAAAAA-BBB", info)
local new = services.invite_text("AAAAAAA-BBB", info, nil, "new")
local has = services.invite_text("AAAAAAA-BBB", info, nil, "has")
assert(both:find("install_windows.ps1", 1, true) and both:find("studiosync-join:", 1, true), "not sure: both ways")
assert(new:find("install_mac.sh", 1, true) and not new:find("studiosync-join:", 1, true), "someone new: the install lines, no join code")
assert(has:find("studiosync-join:AAAAAAA-BBB:smiley:Smiley Studios", 1, true) and not has:find("install_windows", 1, true), "someone with StudioSync: the join code only")
local key = "tskey-auth-kTest-1234"
local hasg = services.invite_text("AAAAAAA-BBB", info, key, "has")
assert(hasg:find(key, 1, true), "a guest with StudioSync gets the Tailscale key in the message")
local newg = services.invite_text("AAAAAAA-BBB", info, key, "new")
assert(newg:find("-TsKey " .. key, 1, true) and newg:find("within 2 days", 1, true), "a new guest's lines carry the key")

-- the new item looks
local colours = require("colours")
local stops = { 0x000000, 0xFFFFFF }
local plan = colours.plan_items({ { kind = "midi" }, { kind = "audio" }, { kind = "print" }, {} }, "kind", { stops = stops })
assert(plan[1] == 0x000000 and plan[2] == 0xFFFFFF and plan[3] ~= plan[1] and plan[3] ~= plan[2] and plan[4] == colours.OTHER, "by kind: MIDI, audio and prints apart")
plan = colours.plan_items({ { newest = "20261117-120000Z" }, { newest = "20261101-120000Z" }, { newest = "20261110-120000Z" } }, "newest", { stops = stops })
assert(plan[2] == 0x000000 and plan[1] == 0xFFFFFF and plan[3] ~= plan[1] and plan[3] ~= plan[2], "newest work: the oldest cool, the latest warm")

-- the call mic
local live = require("live")
assert(live.talk_input() == 0, "the first input until one's picked")
ext["talk input"] = "3"
assert(live.talk_input() == 3, "the one picked")
print("ok")
