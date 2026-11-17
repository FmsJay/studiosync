-- Syncing through each studio's own Tailscale network (0.58.80): services.tailnet_addresses (pure) and removal.publish keeping each
-- computer's name on every network it has been on (lupa or Lua 5.4, from the repo root, over a small in-memory REAPER and folder).
local ext, fs = {}, {}
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  file_exists = function(p) return fs[p] ~= nil end,
  GetResourcePath = function() return "/res" end,
  ExecProcess = function() return "0\n" end,
}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
band.read = function(p) return fs[p] end
band.write_atomic = function(p, s) fs[p] = s end
local services, removal = require("services"), require("removal")

local A, B, C = "AAAAAAA-1", "BBBBBBB-2", "CCCCCCC-3"
local smiley = { only = true, suffix = "tail99.ts.net", devices = {
  { device = A, ts = { ["tail99.ts.net"] = "james-main.tail99.ts.net" } },
  { device = B, ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net", ["tailc1.ts.net"] = "james.tailc1.ts.net" } },
  { device = C, ts = { ["tail99.ts.net"] = "chilis-macbook-pro.tail99.ts.net" } } } }
local chilio = { only = true, suffix = "tailc1.ts.net", devices = {
  { device = A, ts = { ["tailc1.ts.net"] = "james-main.tailc1.ts.net" } },
  { device = B, ts = { ["tail99.ts.net"] = "james-laptop.tail99.ts.net", ["tailc1.ts.net"] = "james.tailc1.ts.net" } },
  { device = C, ts = { ["tail99.ts.net"] = "chilis-macbook-pro.tail99.ts.net" } } } }

local out = services.tailnet_addresses({ smiley }, A)
assert(out[A] == nil, "not this computer")
assert(#out[B] == 1 and out[B][1] == "tcp://james-laptop.tail99.ts.net:22000", "the laptop at its name on the studio's network only")
out = services.tailnet_addresses({ smiley, chilio }, A)
assert(#out[B] == 2 and out[B][1] == "tcp://james-laptop.tail99.ts.net:22000" and out[B][2] == "tcp://james.tailc1.ts.net:22000",
  "in two studios: its name on each network")
assert(out[C][#out[C]] == "dynamic" and out[C][1] == "tcp://chilis-macbook-pro.tail99.ts.net:22000",
  "a name not known yet on one studio's network: found Syncthing's own way too, until it is")
local loose = { only = false, suffix = "tail99.ts.net", devices = smiley.devices }
out = services.tailnet_addresses({ loose }, A)
assert(#out[B] == 1 and out[B][1] == "dynamic", "a studio not set to Tailscale only: Syncthing's own way")
local bad = { only = true, suffix = "tail99.ts.net", devices = { { device = B, ts = { ["tail99.ts.net"] = "evil.example.com" } } } }
assert(services.tailnet_addresses({ bad }, A)[B][1] == "dynamic", "a name off the studio's network isn't used")

-- removal.publish: only the name on the studio's own network (0.58.87: a studio learned the names on every network its members had been on)
local root = "/s"
removal.publish(root, "Laptop", B, { "tail99.ts.net", "james-laptop.tail99.ts.net" }, "tailc1.ts.net")
local d = band.read_json(root .. "/_band/devices/Laptop.json")
assert(d.device == B and d.ts == nil, "on another network than the studio's: no name written")
removal.publish(root, "Laptop", B, { "tailc1.ts.net", "james.tailc1.ts.net" }, "tailc1.ts.net")
d = band.read_json(root .. "/_band/devices/Laptop.json")
assert(d.ts["tailc1.ts.net"] == "james.tailc1.ts.net" and d.ts["tail99.ts.net"] == nil, "on the studio's: that one, and no other")
fs[root .. "/_band/devices/Laptop.json"] = band.json_encode({ user = "Laptop", device = B, ts = { ["tailc1.ts.net"] = "james.tailc1.ts.net", ["tail99.ts.net"] = "james-laptop.tail99.ts.net" } })
removal.publish(root, "Laptop", B, nil, "tailc1.ts.net")
d = band.read_json(root .. "/_band/devices/Laptop.json")
assert(d.ts["tail99.ts.net"] == nil and d.ts["tailc1.ts.net"] == "james.tailc1.ts.net", "a name from before, on another network, goes")
local before = fs[root .. "/_band/devices/Laptop.json"]
removal.publish(root, "Laptop", B, { "tailc1.ts.net", "james.tailc1.ts.net" }, "tailc1.ts.net")
removal.publish(root, "Laptop", B, nil, "tailc1.ts.net")
assert(fs[root .. "/_band/devices/Laptop.json"] == before, "nothing new: not written again")
removal.publish(root, "Laptop", C, nil, "tailc1.ts.net")
assert(band.read_json(root .. "/_band/devices/Laptop.json").ts == nil, "another computer under that name: the old names go with it")
print("ok")
