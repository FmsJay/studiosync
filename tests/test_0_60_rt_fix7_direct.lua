-- rt-fix7 (2026-11-21), docs/rt/rt-nat3.md "Round 2 re-check results": the direct link's Health row on a computer off the tailnet (LinuxBox2)
-- kept "can't reach james-laptop, james-main, linuxbox (its name doesn't resolve)" while it reached all three without Tailscale: their
-- Tailscale names are retried every ~10 s, so direct.STALE never drops them. A bandmate reached by any way isn't "can't reach" by another.
package.path = "lib/?.lua;" .. package.path
local ext, status_json, direct_status = {}, "{}", "{}"
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetOS = function() return "Other" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  StudioSync_NatStatus = function() return status_json end,
  StudioSync_DirectStart = function() return 1 end, StudioSync_DirectSend = function() return 1 end,
  StudioSync_DirectStatus = function() return direct_status end,
  StudioSync_DirectMsg = function() return 1 end, StudioSync_DirectClock = function() return '{"now":1,"peers":{}}' end, StudioSync_DirectStream = function() return 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
local listings, jsons = {}, {}
band.files = function(d, e) local out = {}; for _, f in ipairs(listings[d] or {}) do if not e or f:sub(-#e) == e then out[#out + 1] = f end end; return out end
band.read_json = function(p) return jsons[p] end
package.loaded.services = { run_hidden = function() end, TMP = "T", is_device_id = function(id) return type(id) == "string" and #id > 10 end,
  my_device_id = function() return "BOX2BOX2BOX2" end, tailnet_now = function() return false end }
package.loaded.groups = { trusted = function() return { nat = true } end, tailnet = function() return { name = "x", suffix = "tail99.ts.net" } end }
package.loaded.trust = { user_file = function(u) return u .. ".json" end, device_ok = function() return true end }
package.loaded.presence = { peers = function() return {} end }
package.loaded.access = { read = function() return nil end, shows = function() return true end }
package.loaded.removal = { mark = function() return false end }
package.loaded.hub = { view = function() return { studio = "James" } end }
local nat, direct = require("nat"), require("direct")
direct.enabled = function() return true end
direct.firewall_ok = function() return true end

local root = "S"
local function dev(user, id, ts) return { user = user, device = id, ts = ts and { ["tail99.ts.net"] = ts } or nil } end
listings[root .. "/_band/devices"] = { "James.json", "James-Laptop.json", "LinuxBox.json", "Chilio-Mac.json" }
jsons[root .. "/_band/devices/James.json"] = dev("James", "JAMESJAMES01", "james-main.tail99.ts.net")
jsons[root .. "/_band/devices/James-Laptop.json"] = dev("James-Laptop", "LAPTOPLAPTOP", "james-laptop.tail99.ts.net")
jsons[root .. "/_band/devices/LinuxBox.json"] = dev("LinuxBox", "LINUXBOXLINU", "linuxbox.tail99.ts.net")
jsons[root .. "/_band/devices/Chilio-Mac.json"] = dev("Chilio-Mac", "CHILIOMACMAC", "chilis-macbook-pro.tail99.ts.net")
nat.S.users["nat:JAMESJAMES01"], nat.S.users["nat:LAPTOPLAPTOP"], nat.S.users["nat:LINUXBOXLINU"] = "James", "James-Laptop", "LinuxBox"

local now = os.time()
local function peer(ok, err) return string.format('{"ok":%s,"ms":%d,"at":%d,"error":"%s"}', ok and "true" or "false", ok and 30 or -1, now - 3, err or "") end
local NORES = "its name doesn't resolve (Tailscale off there or here?)"
direct_status = '{"listening":false,"peers":{' ..
  '"james-main.tail99.ts.net:47281":' .. peer(false, NORES) .. ',' ..
  '"james-laptop.tail99.ts.net:47281":' .. peer(false, NORES) .. ',' ..
  '"linuxbox.tail99.ts.net:47281":' .. peer(false, NORES) .. ',' ..
  '"chilis-macbook-pro.tail99.ts.net:47281":' .. peer(false, NORES) .. ',' ..
  '"nat:JAMESJAMES01":' .. peer(true) .. ',"nat:LAPTOPLAPTOP":' .. peer(true) .. ',"nat:LINUXBOXLINU":' .. peer(true) .. '}}'
status_json = '{"on":true,"peers":{"JAMESJAMES01":{"state":"up","path":"direct"},"LAPTOPLAPTOP":{"state":"up","path":"direct"},"LINUXBOXLINU":{"state":"up","path":"direct"}}}'
local cfg = { root = root, user = "LinuxBox2" }
local ok, text = direct.health_line(cfg)
assert(text:find("reaches James (without Tailscale", 1, true) and text:find("James-Laptop (without Tailscale", 1, true), text)
assert(text:find("can't reach chilis-macbook-pro", 1, true), "the Mac, reached by no way: still said (" .. text .. ")")
assert(not text:find("james-main", 1, true) and not text:find("james-laptop (", 1, true) and not text:find("linuxbox (its", 1, true),
  "the Tailscale names of computers reached without Tailscale: not \"can't reach\" (" .. text .. ")")
assert(ok == false, "the Mac still counts against the row")
-- the Mac reached too (its own way): the row is all right
direct_status = direct_status:gsub('"chilis%-macbook%-pro%.tail99%.ts%.net:47281":%b{}', '"chilis-macbook-pro.tail99.ts.net:47281":' .. peer(false, NORES) .. ',"nat:CHILIOMACMAC":' .. peer(true))
status_json = status_json:gsub('}}$', ',"CHILIOMACMAC":{"state":"up","path":"direct"}}}')
nat.S.users["nat:CHILIOMACMAC"] = "Chilio-Mac"
ok, text = direct.health_line(cfg)
assert(ok == true and not text:find("can't reach", 1, true), text)
-- a Tailscale peer whose person isn't reached otherwise: still "can't reach" (P13's rule otherwise unchanged)
direct_status = direct_status:gsub('"nat:LAPTOPLAPTOP":%b{},', '')
ok, text = direct.health_line(cfg)
assert(ok == false and text:find("can't reach james-laptop", 1, true), text)

print("ok: rt-fix7 direct (a bandmate reached without Tailscale isn't \"can't reach\" by its Tailscale name)")
