-- One Tailscale access token per network (0.58.94-0.58.95), lupa or Lua 5.4 from the repo root: each studio on its own network keeps its own
-- token, an older token (network not known) is checked with Tailscale and moved under its network before any use, forgetting one leaves the
-- others, and a change made in one script reaches the others' copies.
package.path = "lib/?.lua;" .. package.path
local ext, ran = {}, {}
local answer -- (what "Tailscale" answers a devices list with)
reaper = setmetatable({
  GetOS = function() return "Other" end, -- (neither Windows nor a Mac: tokens stay in ExtState, so nothing runs to lock them away)
  time_precise = function() return 0 end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  DeleteExtState = function(_, k) ext[k] = nil end,
  RecursiveCreateDirectory = function() return 1 end,
  file_exists = function() return false end,
  ExecProcess = function(c) ran[#ran + 1] = c; return answer end,
}, { __index = function() return function() end end })
for _, m in ipairs({ "band", "services" }) do package.loaded[m] = nil end
local band = require("band")
local kept = {}
band.write_atomic = function(p, s) kept[p] = s; return true end -- (curl's config files: in memory, never the real temp folder)
local services = require("services")
local here = "tail2.ts.net"
services.tailnet_now = function() return "net2@example", here end
local function devices(net) return '0\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"devices":[{"name":"pc.' .. net .. '","id":"1"}]}' end

local nets = services.token_nets_in("tail1.ts.net bad.example.com tail2.ts.net tail1.ts.net", true)
assert(#nets == 3 and nets[1] == "" and nets[2] == "tail1.ts.net" and nets[3] == "tail2.ts.net", "the networks listed once each, the older token first, nothing else")

services.set_tailscale_token("tskey-api-ONE", "tail1.ts.net")
services.set_tailscale_token("tskey-api-TWO", "tail2.ts.net")
assert(services.tailscale_token("tail1.ts.net") == "tskey-api-ONE" and services.tailscale_token("tail2.ts.net") == "tskey-api-TWO", "each network its own token")
assert(services.tailscale_token() == "tskey-api-TWO", "no network named: the one this computer is on")
assert(services.tailscale_token("tail3.ts.net") == "", "a network with none: nothing")
services.set_tailscale_token("", "tail1.ts.net")
assert(services.tailscale_token("tail1.ts.net") == "" and services.tailscale_token("tail2.ts.net") == "tskey-api-TWO", "forgetting one leaves the others")
assert(ext["tailscale_token_nets"] == "tail2.ts.net", "and takes it off the list: " .. tostring(ext["tailscale_token_nets"]))
assert(services.set_tailscale_token("tskey-api-BAD", "evil'; rm -rf ~ #") == false and ext["tailscale_token_nets"] == "tail2.ts.net", "a name that isn't a network's: nothing saved")

-- an older token (saved before 0.58.94): never used for a network until Tailscale says it's that one's, then moved there (0.58.95)
ext["tailscale_token"] = "tskey-api-OLD"
ext["tailscale_token_gen"] = "from another script" -- (as a change elsewhere would: this script reads its tokens again)
assert(services.has_token_for("tail5.ts.net") and services.has_tailscale_token(), "drawing: it might be anyone's, so it counts (nothing asked)")
assert(#ran == 0, "nothing asked of Tailscale just to draw")
answer = devices("tail4.ts.net")
assert(services.tailscale_token("tail5.ts.net") == "", "for another network: not used (it could change that network's policy)")
assert(services.tailscale_token("tail4.ts.net") == "tskey-api-OLD" and ext["tailscale_token"] == nil, "moved under its own network, and out of the old place")
assert(ext["tailscale_token_nets"] == "tail2.ts.net tail4.ts.net", "listed with its network now: " .. tostring(ext["tailscale_token_nets"]))
for _, c in ipairs(ran) do assert(not c:find("tskey-api-", 1, true), "a token never on a command line") end

-- a change made by another script (Forget in the panel) reaches this one's copy
ext["tailscale_token tail2.ts.net"] = nil
local list = ext["tailscale_token_nets"]
ext["tailscale_token_nets"] = "tail4.ts.net"
ext["tailscale_token_gen"] = "panel forgot tail2"
assert(services.tailscale_token("tail2.ts.net") == "" and #services.tailscale_token_nets() == 1, "a token forgotten elsewhere isn't used here: " .. tostring(list))

-- a new token is kept under the network Tailscale says it's for, and only then
assert(services.devices_tailnet('{"devices":[{"name":"pc.tail7.ts.net","id":"1"}]}') == "tail7.ts.net", "the network from a devices list")
answer = devices("tail7.ts.net")
local net = services.add_tailscale_token("tskey-api-SEVEN")
assert(net == "tail7.ts.net" and services.tailscale_token("tail7.ts.net") == "tskey-api-SEVEN", "saved for its own network: " .. tostring(net))
answer = '0\nHTTP/1.1 401 Unauthorized\r\n\r\n{"message":"API token invalid"}'
local none, why = services.add_tailscale_token("tskey-api-WRONG")
assert(none == nil and tostring(why):find("401", 1, true), "a token Tailscale refuses isn't kept: " .. tostring(why))
answer = '0\nHTTP/1.1 200 OK\r\n\r\n{"devices":[]}'
none, why = services.add_tailscale_token("tskey-api-EMPTY")
assert(none == nil and tostring(why):find("which network", 1, true), "nor one whose network can't be told (not guessed from this computer's)")

-- a studio's network, else this computer's
package.loaded.groups = { tailnet = function(root) return root == "/a" and { name = "a@example", suffix = "tail1.ts.net" } or nil end }
assert(services.studio_net("/a") == "tail1.ts.net" and services.studio_net("/b") == here and services.studio_net(nil) == here, "the studio's network, or this computer's")
print("ok")
