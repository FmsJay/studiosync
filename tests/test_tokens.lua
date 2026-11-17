-- One Tailscale access token per network (0.58.94), lupa or Lua 5.4 from the repo root: each studio on its own network keeps its own token,
-- an older token (network not known) still works where there's none for the network, and forgetting one leaves the others.
package.path = "lib/?.lua;" .. package.path
local ext, ran = {}, {}
reaper = setmetatable({
  GetOS = function() return "Other" end, -- (neither Windows nor a Mac: tokens stay in ExtState, so nothing runs to lock them away)
  time_precise = function() return 0 end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
  RecursiveCreateDirectory = function() return 1 end,
  file_exists = function() return false end,
}, { __index = function() return function() end end })
for _, m in ipairs({ "band", "services" }) do package.loaded[m] = nil end
local band = require("band")
local kept = {}
band.write_atomic = function(p, s) kept[p] = s; return true end -- (curl's config files: in memory, never the real temp folder)
local services = require("services")
local here = "tail2.ts.net"
services.tailnet_now = function() return "net2@example", here end

local nets = services.token_nets_in("tail1.ts.net bad.example.com tail2.ts.net tail1.ts.net", true)
assert(#nets == 3 and nets[1] == "" and nets[2] == "tail1.ts.net" and nets[3] == "tail2.ts.net", "the networks listed once each, the older token first, nothing else")

ext["tailscale_token"] = "tskey-api-OLD" -- (one saved before tokens were per network)
services.set_tailscale_token("tskey-api-ONE", "tail1.ts.net")
services.set_tailscale_token("tskey-api-TWO", "tail2.ts.net")
assert(services.tailscale_token("tail1.ts.net") == "tskey-api-ONE" and services.tailscale_token("tail2.ts.net") == "tskey-api-TWO", "each network its own token")
assert(services.tailscale_token() == "tskey-api-TWO", "no network named: the one this computer is on")
assert(services.tailscale_token("tail3.ts.net") == "tskey-api-OLD", "a network with none: the older token (the invitation still checks its network)")
nets = services.tailscale_token_nets()
assert(#nets == 3 and nets[1] == "" and services.has_tailscale_token(), "all three listed")
services.set_tailscale_token("", "tail1.ts.net")
assert(services.tailscale_token("tail1.ts.net") == "tskey-api-OLD" and services.tailscale_token("tail2.ts.net") == "tskey-api-TWO", "forgetting one leaves the others")
assert(ext["tailscale_token_nets"] == "tail2.ts.net", "and takes it off the list: " .. tostring(ext["tailscale_token_nets"]))
services.set_tailscale_token("", "")
assert(services.tailscale_token("tail3.ts.net") == "" and #services.tailscale_token_nets() == 1, "the older one forgotten too")
services.set_tailscale_token("tskey-api-BAD", "evil'; rm -rf ~ #")
assert(ext["tailscale_token_nets"] == "tail2.ts.net" and services.tailscale_token("tail3.ts.net") == "", "a name that isn't a network's: nothing saved")
services.set_tailscale_token("", "")

-- a new token is kept under the network Tailscale says it's for
assert(services.devices_tailnet('{"devices":[{"name":"pc.tail7.ts.net","id":"1"}]}') == "tail7.ts.net", "the network from a devices list")
reaper.ExecProcess = function(c) ran[#ran + 1] = c; return '0\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"devices":[{"name":"mac.tail7.ts.net"}]}' end
local net = services.add_tailscale_token("tskey-api-SEVEN")
assert(net == "tail7.ts.net" and services.tailscale_token("tail7.ts.net") == "tskey-api-SEVEN", "saved for its own network: " .. tostring(net))
for _, c in ipairs(ran) do assert(not c:find("tskey-api-SEVEN", 1, true), "the token never on a command line") end
reaper.ExecProcess = function() return '0\nHTTP/1.1 401 Unauthorized\r\n\r\n{"message":"API token invalid"}' end
local none, why = services.add_tailscale_token("tskey-api-WRONG")
assert(none == nil and tostring(why):find("401", 1, true) and services.tailscale_token("tail9.ts.net") == "", "a token Tailscale refuses isn't kept: " .. tostring(why))

-- a studio's network, else this computer's
package.loaded.groups = { tailnet = function(root) return root == "/a" and { name = "a@example", suffix = "tail1.ts.net" } or nil end }
assert(services.studio_net("/a") == "tail1.ts.net" and services.studio_net("/b") == here and services.studio_net(nil) == here, "the studio's network, or this computer's")
print("ok")
