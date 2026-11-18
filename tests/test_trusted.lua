-- The studio's outward settings (lib/groups.lua groups.trusted, 0.58.87): from band.json only when someone in charge wrote it (lupa or Lua 5.4)
local clock, ext = 0, {}
reaper = setmetatable({ time_precise = function() clock = clock + 10; return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end, SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end },
  { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
local j, verdict = {}, true
band.read_json = function() return j end
package.loaded.trust = { from_manager_file = function() return verdict end, roles = function() return nil, {} end }
local groups = require("groups")
local alerts = require("alerts")
j, verdict = { alerts_server = "https://alerts.example.org", call = "https://meet.example.org/band", tailscale_only = true }, true
assert(alerts.server("/s") == "https://alerts.example.org" and alerts.call_link("/s") == "https://meet.example.org/band", "written by someone in charge: taken")
j, verdict = { alerts_server = "https://evil.example.com", call = "https://evil.example.com/x" }, false
assert(alerts.server("/s") == "https://alerts.example.org" and alerts.call_link("/s") == "https://meet.example.org/band", "from anyone else: the last trusted values stand")
assert(groups.trusted("/s").tailscale_only == true, "Sync only through Tailscale can't be switched off by a member")
j, verdict = { alerts_server = "https://new.example.org" }, nil
assert(alerts.server("/s") == "https://alerts.example.org", "Syncthing not saying yet: the last checked settings, not the file as anyone wrote it (0.58.98)")
ext = {} -- (a studio never checked here: from before owners, or the first look)
groups = nil; package.loaded.groups = nil; package.loaded.alerts = nil; groups = require("groups"); alerts = require("alerts")
assert(alerts.server("/t") == "https://new.example.org", "never checked here (a studio from before owners): band.json as it is")
print("ok")
