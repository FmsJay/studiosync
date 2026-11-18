-- A saved Tailscale token that won't unlock (0.59.14 review: DPAPI ties it to the Windows user and computer, and REAPER here is portable), lupa
-- or Lua 5.4 from the repo root: tried once per 10 minutes, not on every call (each a PowerShell REAPER waits on), and Health is told.
package.path = "lib/?.lua;" .. package.path
local ext, ran, clock = {}, 0, 100
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
  file_exists = function() return false end,
  ExecProcess = function() ran = ran + 1; return "1\nConvertTo-SecureString : Key not valid for use in specified state.\n" end,
}, { __index = function() return function() end end })
for _, m in ipairs({ "band", "services" }) do package.loaded[m] = nil end
local band = require("band")
band.write_atomic = function() return true end
band.log = function() end
local services = require("services")
ext["tailscale_token_dpapi tail1.ts.net"] = "01000000d08c9ddf0115d1118c7a00c04fc297eb"
ext["tailscale_token_nets"] = "tail1.ts.net"
assert(services.tailscale_token("tail1.ts.net") == "" and ran == 1, "it won't unlock: no token")
for _ = 1, 50 do services.tailscale_token("tail1.ts.net"); services.tailscale_sweep_guests() end
assert(ran == 1, "and isn't tried again on every call: " .. ran)
local u = services.token_unreadable()
assert(#u == 1 and u[1] == "tail1.ts.net", "Health is told which one needs entering again")
clock = clock + 601
services.tailscale_token("tail1.ts.net")
assert(ran == 2, "tried again after 10 minutes")
services.set_tailscale_token("tskey-api-NEW", "tail1.ts.net")
assert(#services.token_unreadable() == 0, "entered again: Health stops asking")
print("ok")
